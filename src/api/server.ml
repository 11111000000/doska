(** HTTP-интерфейс трекера.

    На этапе 0 сервер отвечает только на служебные маршруты: [/healthz]
    и [/version]. Остальные маршруты появятся вместе с REST API (§6.1). *)

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

let routes =
  [
    Dream.get "/" version;
    Dream.get "/version" version;
    Dream.get "/healthz" healthz;
  ]

let handler = Dream.router routes

let serve ~port =
  (* Dream слушает [localhost], а не [127.0.0.1]: на этом хосте [localhost]
     резолвится в IPv6 [::1], и IPv4-подключения отклоняются. Сообщение
     говорит ровно то, что происходит, чтобы его не приняли за гарантию. *)
  Printf.printf "doska %s: слушаю localhost:%d (dream биндит [::1])\n"
    Version.version port;
  Dream.run ~port handler
