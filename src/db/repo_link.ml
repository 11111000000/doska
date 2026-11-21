(** Связи между задачами.

    Связь — отдельная строка с собственным идентификатором: она не часть
    задачи, поэтому удаление связи не трогает ни одну из задач и не требует
    блокировки версии. *)

open Domain

let ( let* ) t f = Lwt.bind t f

type t = {
  id : string;
  from_id : string;
  to_id : string;
  kind : Link.kind;
  created_by_id : string option;
  created_at : string;
}

let of_json (json : Yojson.Safe.t) : t =
  let kind =
    match Row.opt_string json "kind" with
    | Some s -> (
        match Link.of_string s with
        | Some kind -> kind
        | None -> Link.Relates_to)
    | None -> Link.Relates_to
  in
  {
    id = Row.string_ json "id" ~default:"";
    from_id = Row.string_ json "from_id" ~default:"";
    to_id = Row.string_ json "to_id" ~default:"";
    kind;
    created_by_id = Row.opt_string json "created_by_id";
    created_at = Row.string_ json "created_at" ~default:"";
  }

let link_select =
  "SELECT row_to_json(x)::text FROM (SELECT * FROM task_link"

let by_id conn id : (t option, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf "%s WHERE id = %s) x" link_select literal)
      |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

(** Поиск связи по тройке (от кого, к кому, вид): она уникальна в базе,
    поэтому повторная попытка — это не новая связь, а тот же самый факт. *)
let find conn ~from_id ~to_id ~kind : (t option, string) result Lwt.t =
  match (Conn.uuid_literal from_id, Conn.uuid_literal to_id) with
  | None, _ | _, None -> Lwt_result.lift (Ok None)
  | Some from_literal, Some to_literal ->
      Conn.query_json_rows conn
        (Printf.sprintf "%s WHERE from_id = %s AND to_id = %s AND kind = %s::link_kind) x"
           link_select from_literal to_literal
           (Conn.quote (Link.to_string kind)))
      |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let create conn ~from_id ~to_id ~kind ~created_by_id : (t, string) result Lwt.t =
  match (Conn.uuid_literal from_id, Conn.uuid_literal to_id) with
  | None, _ | _, None ->
      Lwt_result.lift (Error "неверный идентификатор связи")
  | Some from_literal, Some to_literal ->
      let created_by =
        match created_by_id with
        | None -> "NULL"
        | Some id -> (
            match Conn.uuid_literal id with
            | Some literal -> literal
            | None -> "NULL")
      in
      let sql =
        Printf.sprintf
          "INSERT INTO task_link (from_id, to_id, kind, created_by_id) VALUES (%s, %s, \
           %s::link_kind, %s) RETURNING id::text"
          from_literal to_literal (Conn.quote (Link.to_string kind)) created_by
      in
      let* id = Conn.query_strings conn sql in
      (match id with
      | Error e -> Lwt_result.lift (Error e)
      | Ok [] -> Lwt_result.lift (Error "связь создана, но её id не прочитан")
      | Ok (id :: _) -> (
          let* found = by_id conn id in
          match found with
          | Error e -> Lwt_result.lift (Error e)
          | Ok (Some link) -> Lwt_result.lift (Ok link)
          | Ok None -> Lwt_result.lift (Error "связь создана, но не прочитана")))

let delete conn id : (bool, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok false)
  | Some literal ->
      let sql =
        Printf.sprintf "DELETE FROM task_link WHERE id = %s RETURNING id::text" literal
      in
      let* rows = Conn.query_strings conn sql in
      match rows with
      | Error e -> Lwt_result.lift (Error e)
      | Ok [] -> Lwt_result.lift (Ok false)
      | Ok _ -> Lwt_result.lift (Ok true)

(** Все связи задачи — и исходящие, и входящие: читатель видит relation
    одинаково с обеих сторон. *)
let list_for_task conn ~task_id : (t list, string) result Lwt.t =
  match Conn.uuid_literal task_id with
  | None -> Lwt_result.lift (Ok [])
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf
           "%s WHERE from_id = %s OR to_id = %s ORDER BY created_at, id) x"
           link_select literal literal)
      |> Lwt_result.map (List.map of_json)

(** Обратная запись того же отношения.

    [blocks] и [blocked_by] — одна связь, записанная с двух сторон: «A мешает
    B» и «B ждёт A». Если такая уже есть, новая связь не создаётся — иначе
    читатель увидит одно и то же отношение дважды, а граф блокировок
    посчитает его за два ребра. *)
let mirror_kind kind =
  match kind with
  | Link.Blocks -> Link.Blocked_by
  | Link.Blocked_by -> Link.Blocks
  | other -> other

let find_mirror conn ~from_id ~to_id ~kind : (t option, string) result Lwt.t =
  find conn ~from_id:to_id ~to_id:from_id ~kind:(mirror_kind kind)

(** Кого задача блокирует напрямую.

    Обе нотации блокировки дают одно ребро графа: из [task_id] — к тем, кого
    он мешает. Именно по этим рёбрам ищется кольцо. *)
let blocks_out conn ~task_id : (string list, string) result Lwt.t =
  match Conn.uuid_literal task_id with
  | None -> Lwt_result.lift (Ok [])
  | Some literal ->
      Conn.query_strings conn
        (Printf.sprintf
           "SELECT to_id::text FROM task_link WHERE from_id = %s AND kind = 'blocks' \
            UNION SELECT from_id::text FROM task_link WHERE to_id = %s AND kind = 'blocked_by'"
           literal literal)
      |> Lwt_result.map (fun rows ->
          List.filter_map
            (fun row ->
              match row with
              | "" -> None
              | id -> Some id)
            rows)
