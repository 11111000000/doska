(** HTTP-интерфейс трекера.

    Служебные маршруты ([/], [/version], [/healthz]) и REST API задач
    ([/api/v1], §6.1 архитектуры). *)

(** Тело ответа — JSON-строка: Dream принимает тело строкой, сериализацию
    делаем сами через Yojson. *)
let respond ?(status = `OK) (json : Yojson.Safe.t) =
  Dream.json ~status (Yojson.Safe.to_string json)

let error_json message =
  `Assoc [ ("status", `String "error"); ("error", `String message) ]

let healthz _req =
  match Db.Conn.get_current () with
  | None ->
      respond ~status:`Internal_Server_Error
        (error_json "нет соединения с базой данных")
  | Some conn ->
      (* [ping] — промисс, который разрешается в [result]: сначала ждём базу,
         потом отвечаем. *)
      Lwt.bind (Db.Conn.ping conn) (fun outcome ->
          match outcome with
          | Ok true -> respond (`Assoc [ ("status", `String "ok") ])
          | Ok false ->
              respond ~status:`Internal_Server_Error (error_json "база не отвечает")
          | Error e -> respond ~status:`Internal_Server_Error (error_json e))

let version _req =
  respond
    (`Assoc
      [
        ("service", `String Version.name);
        ("version", `String Version.version);
      ])

(** Актор обязателен для всех маршрутов [/api/v1]: сервер должен знать, чьё
    это действие, иначе правила приёмки не к кому привязать.

    Здесь проверяется только наличие заголовка; существование актора и его
    права проверяет обработчик ([Auth.actor_of]) — так заголовок не подменяет
    проверку личности.

    Идентификация этапа 1 — заголовок [X-Doska-Actor] (см. [Auth]); это не
    аутентификация, её заменит этап 2. *)
let require_actor (handler : Dream.handler) : Dream.handler =
 fun req ->
  match Dream.headers req Auth.header with
  | [] ->
      Errors.respond
        (Errors.make Errors.Unauthorized
           "не указан актор: пришлите заголовок X-Doska-Actor (временный механизм \
            до этапа 2 — bearer-токены)")
  | _handle :: _ -> handler req

let api_routes =
  [
    Dream.get "/tasks" Tasks.list;
    Dream.post "/tasks" Tasks.create;
    (* Статический сегмент раньше параметризованного: [Dream] проверяет
       маршруты по порядку, и "/tasks/:ref" иначе перехватил бы "mine". *)
    Dream.get "/tasks/mine" Tasks.mine;
    Dream.get "/tasks/:ref" Tasks.get;
    Dream.patch "/tasks/:ref" Tasks.patch;
    Dream.post "/tasks/:ref/transition" Tasks.transition;
    Dream.post "/tasks/:ref/claim" Tasks.claim;
    Dream.post "/tasks/:ref/release" Tasks.release;
    (* Связи и родитель — отдельные сущности со своими идентификаторами, поэтому
       у них нет [version] задачи. *)
    Dream.post "/tasks/:ref/links" Tasks.link;
    Dream.delete "/tasks/:ref/links/:link_id" Tasks.unlink;
    Dream.post "/tasks/:ref/parent" Tasks.set_parent;
    Dream.post "/tasks/:ref/assign" Tasks.assign;
    Dream.post "/tasks/:ref/comment" Tasks.comment;
    Dream.post "/tasks/:ref/evidence" Tasks.evidence;
    Dream.get "/activity" Tasks.activity;
    Dream.get "/actors" Tasks.actors;
    Dream.post "/actors/resolve" Actors.resolve;
  ]

let routes =
  [
    Dream.get "/" version;
    Dream.get "/version" version;
    Dream.get "/healthz" healthz;
    (* [/api/v1/healthz] — вне области с актором: проверка живости сервера
       не должна требовать заголовка. *)
    Dream.get "/api/v1/healthz" healthz;
    Dream.scope "/api/v1" [ require_actor ] api_routes;
  ]

let handler = Dream.router routes

let serve ~port =
  (* Dream слушает [localhost], а не [127.0.0.1]: на этом хосте [localhost]
     резолвится в IPv6 [::1], и IPv4-подключения отклоняются. Сообщение
     говорит ровно то, что происходит, чтобы его не приняли за гарантию. *)
  Printf.printf "doska %s: слушаю localhost:%d (dream биндит [::1])\n"
    Version.version port;
  Dream.run ~port handler
