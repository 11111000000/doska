(** Общий контекст запроса: кто выполняет и что в теле.

    Актор обязателен для всех маршрутов [/api/v1]: сервер должен знать, чьё
    это действие, иначе правила приёмки не к кому привязать. Разбор тела —
    тоже общий: почти все изменяющие маршруты принимают JSON.

    Здесь нет ничего предметного: ни задач, ни актёров. *)

let ( let* ) t f = Lwt.bind t f

(** Актор запроса и соединение с базой. *)
let with_actor req f =
  match Db.Conn.get_current () with
  | None ->
      Errors.respond (Errors.make Errors.Internal "нет соединения с базой данных")
  | Some conn ->
      let* outcome = Auth.actor_of conn req in
      match outcome with
      | Error e -> Errors.respond e
      | Ok actor -> f conn actor

(** То же, но с разбором тела запроса. *)
let with_body req f =
  with_actor req (fun conn actor ->
      let* body_result = Params.body_json req in
      match body_result with
      | Error e ->
          Errors.respond (Errors.make Errors.Bad_request ("неверное тело запроса: " ^ e))
      | Ok body -> f conn actor body)
