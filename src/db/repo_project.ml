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

let create conn ~key ~name ~autonomy ?repo_path ?asset_class ?external_ref () :
    (Project.t, string) result Lwt.t =
  (* Путь репозитория, класс актива и внешний ключ приходят из импорта
     (registry.json): проект из трекера должен помнить, откуда он взят, иначе
     связь с источником теряется. *)
  let sql =
    Printf.sprintf
      "INSERT INTO project (key, name, autonomy, repo_path, asset_class, external_ref) \
       VALUES (%s, %s, %s, %s, %s, %s) RETURNING id::text"
      (Conn.quote key)
      (Conn.quote name)
      (Conn.quote (Actor.autonomy_to_string autonomy))
      (match repo_path with None -> "NULL" | Some path -> Conn.quote path)
      (match asset_class with None -> "NULL" | Some asset -> Conn.quote asset)
      (match external_ref with None -> "NULL" | Some ref_ -> Conn.quote ref_)
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


(** Обновить путь репозитория и класс актива.

    Импорт повторяет эти поля из registry.json: реестр меняется, и проект
    в трекере должен смотреть в тот же репозиторий. Имя и ключ не трогаем —
    они идентичность проекта. *)
let update_sources conn ~id ~repo_path ~asset_class : (unit, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Error "неверный идентификатор проекта")
  | Some literal ->
      Conn.exec_sql conn
        (Printf.sprintf
           "UPDATE project SET repo_path = %s, asset_class = %s, updated_at = now() \
            WHERE id = %s"
           (Conn.quote repo_path)
           (Conn.quote asset_class)
           literal)
