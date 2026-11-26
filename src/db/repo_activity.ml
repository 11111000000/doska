(** Журнал активности — append-only (P4).

    Каждое изменение обязательства оставляет след: кто, что и откуда. *)

open Domain

(** Связка для result-промиссов: ошибка пробрасывается как есть, успешное
    значение разбирается в ветке. *)
let ( let* ) t f = Lwt.bind t f

type filters = {
  project : string option;
  task : string option;
  actor : string option;
  since : string option;
  limit : int;
  cursor : string option;
}

let of_json (json : Yojson.Safe.t) : Activity.t =
  let action =
    match Row.opt_string json "action" with
    | Some a -> ( match Activity.action_of_string a with
        | Some action -> action
        | None -> Activity.Created)
    | None -> Activity.Created
  in
  {
    id = Row.int64_ json "id" ~default:0L;
    task_id = Row.opt_string json "task_id";
    project_id = Row.opt_string json "project_id";
    actor_id = Row.opt_string json "actor_id";
    action;
    from_value = Row.opt_string json "from_value";
    to_value = Row.opt_string json "to_value";
    summary = Row.opt_string json "summary";
    interface_ = Interface.of_string_default (Row.string_ json "interface" ~default:"api");
    request_id = Row.opt_string json "request_id";
    created_at = Row.string_ json "created_at" ~default:"";
  }

(** Запись события. Пишется в той же транзакции, что и само изменение:
    след без изменения или изменение без следа — оба случая плохи. *)
let record_sql ~action ~task_id ~project_id ~actor_id ~from_value ~to_value ~summary
    ~interface_ : (string, string) result =
  let ( let* ) = Result.bind in
  let uuid = function
    | None -> Ok "NULL"
    | Some id -> (
        match Conn.uuid_literal id with
        | Some literal -> Ok literal
        | None -> Error (Printf.sprintf "неверный идентификатор: %s" id))
  in
  let* task = uuid task_id in
  let* project = uuid project_id in
  let* actor = uuid actor_id in
  Ok
    (Printf.sprintf
       "INSERT INTO activity (task_id, project_id, actor_id, action, from_value, \
        to_value, summary, interface) VALUES (%s, %s, %s, %s::activity_action, %s, %s, \
        %s, %s) RETURNING id::text"
       task
       project
       actor
       (Conn.quote (Activity.action_to_string action))
       (match from_value with None -> "NULL" | Some v -> Conn.quote v)
       (match to_value with None -> "NULL" | Some v -> Conn.quote v)
       (match summary with None -> "NULL" | Some s -> Conn.quote s)
       (Conn.quote (Interface.to_string interface_)))

let record conn ~action ~task_id ~project_id ~actor_id ~from_value ~to_value ~summary
    ~interface_ () : (Activity.t, string) result Lwt.t =
  match
    record_sql ~action ~task_id ~project_id ~actor_id ~from_value ~to_value ~summary
      ~interface_
  with
  | Error e -> Lwt_result.lift (Error e)
  | Ok sql ->
      let* outcome = Conn.query_strings conn sql in
  match outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok [] -> Lwt_result.lift (Error "событие записано, но его id не прочитан")
  | Ok (id :: _) ->
      let* found =
        Conn.query_json_rows conn
          (Printf.sprintf
             "SELECT row_to_json(a)::text FROM activity a WHERE a.id = %s::bigint"
             (Conn.quote id))
      in
      match found with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (json :: _) -> Lwt_result.lift (Ok (of_json json))
      | Ok [] -> Lwt_result.lift (Error "событие записано, но не найдено")

let list conn (f : filters) : (Activity.t list, string) result Lwt.t =
  let conditions = ref [ "TRUE" ] in
  let add c = conditions := c :: !conditions in
  (match f.project with
  | Some p -> add (Printf.sprintf "p.key = %s" (Conn.quote p))
  | None -> ());
  (match f.task with
  | Some t -> add (Printf.sprintf "t.ref = %s" (Conn.quote t))
  | None -> ());
  (match f.actor with
  | Some a -> add (Printf.sprintf "ac.handle = %s" (Conn.quote a))
  | None -> ());
  (match f.since with
  | Some s -> add (Printf.sprintf "a.created_at > %s::timestamptz" (Conn.quote s))
  | None -> ());
  (match f.cursor with
  | Some c -> (
      match int_of_string_opt c with
      | Some id -> add (Printf.sprintf "a.id < %d" id)
      | None -> ())
  | None -> ());
  let sql =
    Printf.sprintf
      "SELECT row_to_json(x)::text FROM (SELECT a.*, p.key AS project_key, t.ref AS task_ref, \
       ac.handle AS actor_handle FROM activity a LEFT JOIN project p ON p.id = a.project_id \
       LEFT JOIN task t ON t.id = a.task_id LEFT JOIN actor ac ON ac.id = a.actor_id \
       WHERE %s) x ORDER BY x.id DESC LIMIT %d"
      (String.concat " AND " (List.rev !conditions))
      f.limit
  in
  Conn.query_json_rows conn sql |> Lwt_result.map (List.map of_json)
