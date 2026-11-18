(** Доступ к акторам: люди, агенты, сервисы и заглушки.

    Одна сущность вместо раздельных «пользователей» и «учёток»: различаются
    только вид ([kind]) и руководитель ([supervisor_id]). *)

open Domain

(** Связка для result-промиссов: ошибка пробрасывается как есть, успешное
    значение разбирается в ветке. *)
let ( let* ) t f = Lwt.bind t f

let of_json (json : Yojson.Safe.t) : Actor.t =
  let kind =
    match Row.opt_string json "kind" with
    | Some k -> ( match Actor.kind_of_string k with
        | Some kind -> kind
        | None -> Actor.Human)
    | None -> Actor.Human
  in
  {
    id = Row.string_ json "id" ~default:"";
    kind;
    handle = Row.string_ json "handle" ~default:"";
    display_name = Row.string_ json "display_name" ~default:"";
    supervisor_id = Row.opt_string json "supervisor_id";
    unresolved = Row.bool_ json "unresolved" ~default:false;
  }

let select =
  "SELECT row_to_json(a)::text FROM actor a"

let by_id conn id : (Actor.t option, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf "%s WHERE a.id = %s" select literal)
      |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let by_handle conn handle : (Actor.t option, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf "%s WHERE a.handle = %s" select (Conn.quote handle))
  |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let list conn : (Actor.t list, string) result Lwt.t =
  Conn.query_json_rows conn (select ^ " ORDER BY a.handle")
  |> Lwt_result.map (List.map of_json)

(** Создание актора. Нужен наполнению и тестам: на этапе 1 актёров ещё не
    импортируют из Mattermost, но задачу некому назначить без них. *)
let create conn ~kind ~handle ~display_name ?supervisor_id ?(unresolved = false) () :
    (Actor.t, string) result Lwt.t =
  let supervisor =
    match supervisor_id with
    | None -> "NULL"
    | Some id -> (
        match Conn.uuid_literal id with
        | None -> "NULL"
        | Some literal -> literal)
  in
  let sql =
    Printf.sprintf
      "INSERT INTO actor (kind, handle, display_name, supervisor_id, unresolved) \
       VALUES (%s::actor_kind, %s, %s, %s, %s) RETURNING id::text"
      (Conn.quote (Actor.kind_to_string kind))
      (Conn.quote handle)
      (Conn.quote display_name)
      supervisor
      (if unresolved then "true" else "false")
  in
  let* outcome = Conn.query_strings conn sql in
  match outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok [] -> Lwt_result.lift (Error "актор создан, но его id не прочитан")
  | Ok (id :: _) ->
      let* found = by_id conn id in
      match found with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (Some actor) -> Lwt_result.lift (Ok actor)
      | Ok None -> Lwt_result.lift (Error "актор создан, но не найден")

(** Руководитель актора: «кому отвечает агент». *)
let supervisor_of conn actor_id : (string option, string) result Lwt.t =
  match Conn.uuid_literal actor_id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_strings conn
        (Printf.sprintf
           "SELECT supervisor_id::text FROM actor WHERE id = %s AND supervisor_id IS NOT NULL"
           literal)
      |> Lwt_result.map (function [] -> None | id :: _ -> Some id)

(** Все алиасы актора: резолвер идентичности (§5.2) ищет по ним. *)
let aliases conn : (Identity.Resolve.alias list, string) result Lwt.t =
  Conn.query_json_rows conn
    "SELECT row_to_json(x)::text FROM (SELECT id::text AS id, actor_id::text AS actor_id, \
     namespace, alias AS value FROM actor_alias) x"
  |> Lwt_result.map (List.map (fun json ->
         {
           Identity.Resolve.namespace = Row.string_ json "namespace" ~default:"";
           value = Row.string_ json "value" ~default:"";
           actor_id = Row.string_ json "actor_id" ~default:"";
         }))
