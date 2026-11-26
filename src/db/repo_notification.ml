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
