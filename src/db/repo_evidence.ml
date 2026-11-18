(** Доступ к доказательствам — ссылкам на факты внешнего мира.

    Трекер помнит ссылку и не пересчитывает факт: существование коммита или PR
    проверяет владелец факта (§3.4 архитектуры). *)

open Domain

(** Связка для result-промиссов: ошибка пробрасывается как есть, успешное
    значение разбирается в ветке. *)
let ( let* ) t f = Lwt.bind t f

let of_json (json : Yojson.Safe.t) : Evidence.t =
  let kind =
    match Row.opt_string json "kind" with
    | Some k -> ( match Evidence.kind_of_string k with
        | Some kind -> kind
        | None -> Evidence.Note)
    | None -> Evidence.Note
  in
  {
    id = Row.string_ json "id" ~default:"";
    task_id = Row.string_ json "task_id" ~default:"";
    kind;
    ref_ = Row.string_ json "ref" ~default:"";
    uri = Row.opt_string json "uri";
    title = Row.opt_string json "title";
    note = Row.opt_string json "note";
    author_id = Row.opt_string json "author_id";
    created_at = Row.string_ json "created_at" ~default:"";
  }

let list_for_task conn ~task_id : (Evidence.t list, string) result Lwt.t =
  match Conn.uuid_literal task_id with
  | None -> Lwt_result.lift (Ok [])
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf
           "SELECT row_to_json(e)::text FROM evidence e WHERE e.task_id = %s \
            ORDER BY e.created_at"
           literal)
      |> Lwt_result.map (List.map of_json)

(** Есть ли у задачи доказательство: правило «желательно evidence» смотрит на
    этот счёт, а не на наличие комментария. *)
let count conn ~task_id : (int, string) result Lwt.t =
  match Conn.uuid_literal task_id with
  | None -> Lwt_result.lift (Ok 0)
  | Some literal ->
      Conn.query_strings conn
        (Printf.sprintf "SELECT count(*)::text FROM evidence WHERE task_id = %s" literal)
      |> Lwt_result.map (function
           | count :: _ -> ( match int_of_string_opt count with
               | Some n -> n
               | None -> 0)
           | [] -> 0)

let add conn ~task_id ~kind ~ref_ ?uri ?title ?note ?author_id () :
    (Evidence.t, string) result Lwt.t =
  let author =
    match author_id with
    | None -> "NULL"
    | Some id -> ( match Conn.uuid_literal id with
        | Some literal -> literal
        | None -> "NULL")
  in
  let sql =
    Printf.sprintf
      "INSERT INTO evidence (task_id, kind, ref, uri, title, note, author_id) \
       VALUES (%s, %s::evidence_kind, %s, %s, %s, %s, %s) RETURNING id::text"
      (match Conn.uuid_literal task_id with
      | Some literal -> literal
      | None -> "NULL")
      (Conn.quote (Evidence.kind_to_string kind))
      (Conn.quote ref_)
      (match uri with None -> "NULL" | Some u -> Conn.quote u)
      (match title with None -> "NULL" | Some t -> Conn.quote t)
      (match note with None -> "NULL" | Some n -> Conn.quote n)
      author
  in
  let* outcome = Conn.query_strings conn sql in
  match outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok [] -> Lwt_result.lift (Error "доказательство создано, но его id не прочитан")
  | Ok (id :: _) ->
      let* found =
        Conn.query_json_rows conn
          (Printf.sprintf
             "SELECT row_to_json(e)::text FROM evidence e WHERE e.id = %s::uuid"
             (Conn.quote id))
      in
      match found with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (json :: _) -> Lwt_result.lift (Ok (of_json json))
      | Ok [] -> Lwt_result.lift (Error "доказательство создано, но не найдено")
