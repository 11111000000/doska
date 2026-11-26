(* MCP-сервер: JSON-RPC 2.0 поверх streamable HTTP и stdio (§6.2).

   Аутентификация — bearer-токен агента: тот же Service.Credential, что и
   REST. Бизнес-отказ инструмента — isError:true с текстом класса отказа:
   клиент агента должен отличать «правило запрещает» от «сломалось у нас».
   Маршрут [/mcp] подключает Api.Server; stdio-мост — [doska mcp]. *)

open Domain

let ( let* ) t f = Lwt.bind t f

let protocol_version = "2024-11-05"

let json_response (json : Yojson.Safe.t) =
  Dream.json (Yojson.Safe.to_string json)

(* Bearer-токен из заголовка Authorization (RFC 7235): схема без учёта
   регистра, токен после одного пробола. *)
let bearer_token (req : Dream.request) : string option =
  match Dream.header req "authorization" with
  | Some value -> (
      match String.index_opt value ' ' with
      | Some space when String.lowercase_ascii (String.sub value 0 space) = "bearer" ->
          let token = String.trim (String.sub value (space + 1) (String.length value - space - 1)) in
          if token = "" then None else Some token
      | _ -> None)
  | None -> None

(* Бизнес-отказ → isError:true с классом и сообщением: агент должен
   отличать «правило запрещает» от «сломалось хранилище». *)
let call_result (outcome : (Yojson.Safe.t, Service.Failure.t) result Lwt.t) :
    Yojson.Safe.t Lwt.t =
  let* result = outcome in
  match result with
  | Ok json ->
      Lwt.return
        (`Assoc
          [
            ("content",
              `List
                [
                  `Assoc
                    [
                      ("type", `String "text");
                      ("text", `String (Yojson.Safe.to_string json));
                    ];
                ]);
          ])
  | Error failure ->
      Lwt.return
        (`Assoc
          [
            ("isError", `Bool true);
            ( "content",
              `List
                [
                  `Assoc
                    [
                      ("type", `String "text");
                      ("text", `String (Service.Failure.to_string failure));
                    ];
                ] );
          ])

let tool_descriptors =
  `List
    (List.map
       (fun tool ->
         `Assoc
           [
             ("name", `String tool.Tools.name);
             ("description", `String tool.Tools.description);
             ("inputSchema", tool.Tools.input_schema);
           ])
       Tools.tools)

(* Обработка одного JSON-RPC-запроса: [conn] — база, [actor] — агент. *)
let process conn (actor : Actor.t) (request : Yojson.Safe.t) : Yojson.Safe.t Lwt.t =
  let id = Yojson.Safe.Util.member "id" request in
  let method_ = Yojson.Safe.Util.(member "method" request |> Yojson.Safe.Util.to_string) in
  match method_ with
  | "initialize" ->
      Lwt.return
        (Rpc.ok id
           (`Assoc
             [
               ("protocolVersion", `String protocol_version);
               ("capabilities", `Assoc [ ("tools", `Assoc [ ("listChanged", `Bool false) ]) ]);
               ( "serverInfo",
                 `Assoc
                   [
                     ("name", `String Version.name);
                     ("version", `String Version.version);
                   ] );
             ]))
  | "notifications/initialized" ->
      (* Уведомление: ответа нет — пустой 202 делает Dream.json нет, поэтому
         отдаём null без id. *)
      Lwt.return `Null
  | "tools/list" -> Lwt.return (Rpc.ok id (`Assoc [ ("tools", tool_descriptors) ]))
  | "tools/call" -> (
      let params = Yojson.Safe.Util.member "params" request in
      let name =
        Yojson.Safe.Util.(member "name" params |> Yojson.Safe.Util.to_string)
      in
      let args = Yojson.Safe.Util.member "arguments" params in
      if Tools.find name = None then
        Lwt.return (Rpc.error id Rpc.method_not_found ("нет инструмента: " ^ name))
      else
        let* result = Tools.run conn actor name args in
        match result with
        | Ok json -> Lwt.return (Rpc.ok id json)
        | Error failure ->
            Lwt.return
              (Rpc.ok id
                 (`Assoc
                   [
                     ("isError", `Bool true);
                     ( "content",
                       `List
                         [
                           `Assoc
                             [
                               ("type", `String "text");
                               ( "text",
                                 `String (Service.Failure.to_string failure) );
                             ];
                         ] );
                   ])))
  | other -> Lwt.return (Rpc.error id Rpc.method_not_found ("нет метода: " ^ other))

(** Обработка потока запросов: [actor] уже опознан. Ответ — JSON-RPC-ответ
    или null для уведомлений. *)
let process_line conn actor line =
  match Yojson.Safe.from_string line with
  | request -> process conn actor request
  | exception Yojson.Json_error e ->
      Lwt.return (Rpc.error `Null Rpc.parse_error ("не разобрано: " ^ e))

(** HTTP-handler: токен → актор → JSON-RPC. Ошибки аутентификации
    отвечают 401 без тела JSON-RPC: клиент ещё не в протоколе. *)
let handler : Dream.handler =
 fun req ->
  let* body = Dream.body req in
  match Db.Conn.get_current () with
  | None ->
      json_response (`Assoc [ ("error", `String "нет соединения с базой данных") ])
  | Some conn -> (
      match bearer_token req with
      | None ->
          Dream.json ~status:`Unauthorized
            (Yojson.Safe.to_string
               (`Assoc [ ("error", `String "нужен Authorization: Bearer dsk_…") ]))
      | Some token -> (
          let* verified = Service.Credential.verify conn token in
          match verified with
          | Service.Credential.Invalid failure ->
              Dream.json ~status:`Unauthorized
                (Yojson.Safe.to_string
                   (`Assoc [ ("error", `String (Service.Failure.to_string failure)) ]))
          | Service.Credential.Verified (_, actor) ->
              let* response = process_line conn actor body in
              json_response response))

(** stdio-мост: строки JSON-RPC на stdin, ответы на stdout (§6.2). *)
let run_stdio () =
  let rec loop () =
    match input_line stdin with
    | line ->
        let* response =
          Lwt.bind (Db.Conn.connect ~uri:(Sys.getenv_opt "DOSKA_DATABASE_URL" |> Option.value ~default:"postgresql:///doska") ())
            (function
              | Error e -> Lwt.return (Rpc.error `Null Rpc.internal_error e)
              | Ok conn -> (
                  let* actor_outcome =
                    (* stdio-клиент представляется токеном в переменной
                       окружения: секрет не живёт в конфиге. *)
                    (match Sys.getenv_opt "DOSKA_MCP_TOKEN" with
                     | Some token -> Service.Credential.verify conn token
                     | None -> Lwt.return (Service.Credential.Invalid (Service.Failure.Unauthorized { message = "нет DOSKA_MCP_TOKEN" })))
                  in
                  match actor_outcome with
                  | Service.Credential.Invalid failure ->
                      Lwt.return (Rpc.error `Null Rpc.invalid_request (Service.Failure.to_string failure))
                  | Service.Credential.Verified (_, actor) -> process_line conn actor line))
        in
        output_string stdout (Yojson.Safe.to_string response ^ "\n");
        flush stdout;
        loop ()
    | exception End_of_file -> Lwt.return ()
  in
  Lwt_main.run (loop ())
