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

(* ------------------------------------------------- источник и заглушки --- *)

(** Актёр по ключу источника: пара (source, source_ref) — уникальный ключ
    внешнего объекта (§10.2). *)
let by_source conn ~source ~source_ref : (Actor.t option, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf "%s WHERE a.source = %s AND a.source_ref = %s" select
       (Conn.quote source) (Conn.quote source_ref))
  |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

(** Источник актёра: [None] — актёра создали вручную, источника у него нет. *)
let source_of conn actor_id : ((string * string) option, string) result Lwt.t =
  match Conn.uuid_literal actor_id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_strings conn
        (Printf.sprintf
           "SELECT source || E'\\t' || source_ref FROM actor \
            WHERE id = %s AND source IS NOT NULL AND source_ref IS NOT NULL"
           literal)
      |> Lwt_result.map (function
           | [] -> None
           | row :: _ -> (
               match String.split_on_char '\t' row with
               | [ source; source_ref ] -> Some (source, source_ref)
               | _ -> None))

(** Свободен ли адрес почты: он уникален, и занятый адрес не должен ронять
    импорт целиком — просто не записывается. *)
let email_free conn ~email ~except_id : (bool, string) result Lwt.t =
  let except =
    match Conn.uuid_literal except_id with
    | Some literal -> Printf.sprintf " AND id <> %s" literal
    | None -> ""
  in
  Conn.query_int64s conn
    (Printf.sprintf "SELECT count(*) FROM actor WHERE email = %s%s"
       (Conn.quote email) except)
  |> Lwt_result.map (function count :: _ -> count = 0L | [] -> true)

(** Создать заглушку: имя не удалось разрешить, но терять его нельзя
    (§3.1). Логин заглушки — нормализованное имя, чтобы повторный резолв
    нашёл ту же заглушку, а не создал вторую. *)
let create_placeholder conn ~handle ~display_name : (Actor.t, string) result Lwt.t =
  let sql =
    Printf.sprintf
      "INSERT INTO actor (kind, handle, display_name, unresolved) \
       VALUES ('placeholder'::actor_kind, %s, %s, true) RETURNING id::text"
      (Conn.quote handle) (Conn.quote display_name)
  in
  let* outcome = Conn.query_strings conn sql in
  match outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok [] -> Lwt_result.lift (Error "заглушка создана, но её id не прочитан")
  | Ok (id :: _) ->
      let* found = by_id conn id in
      (match found with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (Some actor) -> Lwt_result.lift (Ok actor)
      | Ok None -> Lwt_result.lift (Error "заглушка создана, но не найдена"))

(** Обновить профиль актёра, не трогая его логин.

    Почта записывается, только если свободна: занятый адрес — это другой
    человек, и перетирать импорт не должен. *)
let update_profile conn actor ~kind ~display_name ?email () :
    (Actor.t, string) result Lwt.t =
  let resolve_email () =
    match email with
    | None -> Lwt_result.lift (Ok "email")
    | Some address ->
        let* free = email_free conn ~email:address ~except_id:actor.Actor.id in
        (match free with
        | Error e -> Lwt_result.lift (Error e)
        | Ok true -> Lwt_result.lift (Ok (Conn.quote address))
        | Ok false -> Lwt_result.lift (Ok "email"))
  in
  let* email_outcome = resolve_email () in
  match email_outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok email_sql ->
      let sql =
        Printf.sprintf
          "UPDATE actor SET kind = %s::actor_kind, display_name = %s, email = %s, \
           unresolved = false, updated_at = now() WHERE id = %s RETURNING id::text"
          (Conn.quote (Actor.kind_to_string kind))
          (Conn.quote display_name) email_sql
          (match Conn.uuid_literal actor.Actor.id with
          | Some literal -> literal
          | None -> "'00000000-0000-0000-0000-000000000000'::uuid")
      in
      let* outcome = Conn.query_strings conn sql in
      match outcome with
      | Error e -> Lwt_result.lift (Error e)
      | Ok [] -> Lwt_result.lift (Error "актор не обновлён: строка не найдена")
      | Ok (id :: _) ->
          let* found = by_id conn id in
          (match found with
          | Error e -> Lwt_result.lift (Error e)
          | Ok (Some updated) -> Lwt_result.lift (Ok updated)
          | Ok None -> Lwt_result.lift (Error "актор обновлён, но не найден"))

(** Привязать актёра к источнику: заполнить source/source_ref, которых у
    созданного вручную актёра нет. *)
let adopt_source conn actor_id ~source ~source_ref : (unit, string) result Lwt.t =
  match Conn.uuid_literal actor_id with
  | None -> Lwt_result.lift (Error ("id актора не похож на uuid: " ^ actor_id))
  | Some literal ->
      Conn.exec_sql conn
        (Printf.sprintf
           "UPDATE actor SET source = %s, source_ref = %s, updated_at = now() \
            WHERE id = %s AND source IS NULL"
           (Conn.quote source) (Conn.quote source_ref) literal)

(** Идемпотентное создание или обновление актёра из внешнего источника.

    Ключ источника — пара (source, source_ref): повторный импорт обновляет ту
    же строку, а не создаёт вторую (§10.2).

    Если актёр с таким логином уже есть — импорт его не дублирует, а
    «усыновляет»: пустая заглушка, созданная резолвером, превращается в
    настоящего актёра, и алиасы, указывающие на неё, остаются в силе. *)
let upsert_from_source conn ~source ~source_ref ~kind ~handle ~display_name ?email () :
    (Actor.t, string) result Lwt.t =
  let* existing = by_source conn ~source ~source_ref in
  match existing with
  | Ok (Some actor) -> update_profile conn actor ~kind ~display_name ?email ()
  | Error e -> Lwt_result.lift (Error e)
  | Ok None -> (
      let* by_handle = by_handle conn handle in
      match by_handle with
      | Error e -> Lwt_result.lift (Error e)
      | Ok None ->
          let sql =
            Printf.sprintf
              "INSERT INTO actor (kind, handle, display_name, email, source, source_ref) \
               VALUES (%s::actor_kind, %s, %s, %s, %s, %s) RETURNING id::text"
              (Conn.quote (Actor.kind_to_string kind))
              (Conn.quote handle)
              (Conn.quote display_name)
              (match email with None -> "NULL" | Some address -> Conn.quote address)
              (Conn.quote source)
              (Conn.quote source_ref)
          in
          let* outcome = Conn.query_strings conn sql in
          (match outcome with
          | Error e -> Lwt_result.lift (Error e)
          | Ok [] -> Lwt_result.lift (Error "актор создан, но его id не прочитан")
          | Ok (id :: _) ->
              let* found = by_id conn id in
              (match found with
              | Error e -> Lwt_result.lift (Error e)
              | Ok (Some actor) -> Lwt_result.lift (Ok actor)
              | Ok None -> Lwt_result.lift (Error "актор создан, но не найден")))
      | Ok (Some actor) -> (
          let* owner = source_of conn actor.Actor.id in
          match owner with
          | Ok (Some (source', source_ref'))
            when source' = source && source_ref' = source_ref ->
              update_profile conn actor ~kind ~display_name ?email ()
          | Ok (Some (source', owner_ref)) ->
              Lwt_result.lift
                (Error
                   (Printf.sprintf
                      "логин %s уже занят актёром из другого источника (%s/%s)" handle
                      source' owner_ref))
          | Error e -> Lwt_result.lift (Error e)
          | Ok None ->
              let* adopted =
                adopt_source conn actor.Actor.id ~source ~source_ref
              in
              (match adopted with
              | Error e -> Lwt_result.lift (Error e)
              | Ok () ->
                  let* refreshed = by_id conn actor.Actor.id in
                  (match refreshed with
                  | Error e -> Lwt_result.lift (Error e)
                  | Ok (Some adopted_actor) ->
                      update_profile conn adopted_actor ~kind ~display_name ?email ()
                  | Ok None ->
                      Lwt_result.lift
                        (Error "актор усыновлён источником, но не найден")))))

(** Идентификатор актора в конкретном внешнем источнике — по нему строится
    адрес доставки (личный канал Mattermost). [None] — актор из другого
    источника или вовсе без идентификатора. *)
let source_ref conn id ~source : (string option, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf
           "SELECT row_to_json(x)::text FROM (SELECT source_ref FROM actor \
            WHERE id = %s AND source = %s) x"
           literal
           (Conn.quote source))
      |> Lwt_result.map (function
          | [] -> None
          | json :: _ -> Row.opt_string json "source_ref")
