(** Доступ к проектам.

    Проект несёт политику приёмки ([autonomy]): в доверенном проекте агент
    закрывает задачу сам, в остальных — человек (D1, §4.2 архитектуры). *)

open Domain

(** Связка для result-промиссов: ошибка пробрасывается как есть, успешное
    значение разбирается в ветке. *)
let ( let* ) t f = Lwt.bind t f

let of_json (json : Yojson.Safe.t) : Project.t =
  let autonomy =
    match Row.opt_string json "autonomy" with
    | Some a -> ( match Actor.autonomy_of_string a with
        | Some autonomy -> autonomy
        | None -> Actor.Human_gate)
    | None -> Actor.Human_gate
  in
  let status =
    match Row.opt_string json "status" with
    | Some s -> ( match Project.status_of_string s with
        | Some status -> status
        | None -> Project.Active)
    | None -> Project.Active
  in
  {
    id = Row.string_ json "id" ~default:"";
    key = Row.string_ json "key" ~default:"";
    name = Row.string_ json "name" ~default:"";
    autonomy;
    status;
  }

let select = "SELECT row_to_json(p)::text FROM project p"

let by_id conn id : (Project.t option, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf "%s WHERE p.id = %s" select literal)
      |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let by_key conn key : (Project.t option, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf "%s WHERE p.key = %s" select (Conn.quote key))
  |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let list conn : (Project.t list, string) result Lwt.t =
  Conn.query_json_rows conn (select ^ " ORDER BY p.key")
  |> Lwt_result.map (List.map of_json)

let create conn ~key ~name ~autonomy : (Project.t, string) result Lwt.t =
  let sql =
    Printf.sprintf
      "INSERT INTO project (key, name, autonomy) VALUES (%s, %s, %s) RETURNING id::text"
      (Conn.quote key)
      (Conn.quote name)
      (Conn.quote (Actor.autonomy_to_string autonomy))
  in
  let* outcome = Conn.query_strings conn sql in
  match outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok [] -> Lwt_result.lift (Error "проект создан, но его id не прочитан")
  | Ok (id :: _) ->
      let* found = by_id conn id in
      match found with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (Some project) -> Lwt_result.lift (Ok project)
      | Ok None -> Lwt_result.lift (Error "проект создан, но не найден")
