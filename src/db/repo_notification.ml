(** Очередь уведомлений — outbox (§3.8 архитектуры).

    Уведомление не уходит сразу: запись ложится в таблицу и ждёт отдельного
    прохода доставки. Так упавший Mattermost не ломает переход задачи. *)

(** Идентификатор актора или задачи — uuid-литералом. Неверная форма — это
    «такого актора нет», а не поломка базы. *)
let uuid_sql = function
  | None -> Ok "NULL"
  | Some id -> (
      match Conn.uuid_literal id with
      | Some literal -> Ok literal
      | None -> Error (Printf.sprintf "неверный идентификатор: %s" id))

(** Поставить уведомление в очередь доставки. Канал — DM: ADR §3.8
    (outbox) перечисляет DM-уведомления для needs_input. *)
let enqueue conn ~task_id ~actor_id ~kind ~payload : (unit, string) result Lwt.t =
  match (uuid_sql task_id, uuid_sql actor_id) with
  | Error e, _ | _, Error e -> Lwt_result.lift (Error e)
  | Ok task, Ok actor ->
      let sql =
        Printf.sprintf
          "INSERT INTO notification (task_id, actor_id, channel, kind, payload) \
           VALUES (%s, %s, 'mattermost_dm', %s, %s::jsonb)"
          task actor (Conn.quote kind) (Conn.quote (Yojson.Safe.to_string payload))
      in
      Conn.exec_sql conn sql

(** Ожидающие доставки уведомления: очередь читается по одному разу,
    результат доставки пишется отдельным вызовом — процесс доставки не
    держит транзакцию открытым на время отправки. *)
type pending = {
  id : string;
  task_id : string option;
  actor_id : string option;
  kind : string;
  payload : Yojson.Safe.t;
}

let of_pending_json (json : Yojson.Safe.t) : pending =
  {
    id = Row.string_ json "id" ~default:"";
    task_id = Row.opt_string json "task_id";
    actor_id = Row.opt_string json "actor_id";
    kind = Row.string_ json "kind" ~default:"";
    payload =
      (match Row.opt_string json "payload" with
      | Some raw -> ( try Yojson.Safe.from_string raw with _ -> `Assoc [])
      | None -> `Assoc []);
  }

let list_pending conn : (pending list, string) result Lwt.t =
  Conn.query_json_rows conn
    "SELECT row_to_json(c)::text FROM (SELECT id::text, task_id::text, \
     actor_id::text, kind, payload::text AS payload FROM notification \
     WHERE delivery_state = 'pending' ORDER BY created_at) c"
  |> Lwt_result.map (List.map of_pending_json)

let mark_sent conn id : (unit, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Error "неверный идентификатор уведомления")
  | Some literal ->
      Conn.exec_sql conn
        (Printf.sprintf
           "UPDATE notification SET delivery_state = 'sent', delivered_at = now() \
            WHERE id = %s"
           literal)

let mark_failed conn id ~error : (unit, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Error "неверный идентификатор уведомления")
  | Some literal ->
      Conn.exec_sql conn
        (Printf.sprintf
           "UPDATE notification SET delivery_state = 'failed', attempts = attempts + 1, \
            last_error = %s WHERE id = %s"
           (Conn.quote error) literal)
