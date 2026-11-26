(** Доступ к учётным записям агентов: bearer-токены.

    Токен хранится хэшем ([token_hash]); [token_prefix] — первые символы
    открытого токена, чтобы в списке учёток их можно было различить, не
    храня секрет. Запись ищется по хэшу: утечка таблицы не даёт ни одного
    рабочего токена. *)

let ( let* ) t f = Lwt.bind t f

type t = {
  id : string;
  actor_id : string;
  title : string;
  token_prefix : string;
  scopes : string list;
  can_assign : bool;
  expires_at : string option;
  last_used_at : string option;
  revoked_at : string option;
  created_by_id : string option;
  created_at : string option;
}

let of_json (json : Yojson.Safe.t) : t =
  {
    id = Row.string_ json "id" ~default:"";
    actor_id = Row.string_ json "actor_id" ~default:"";
    title = Row.string_ json "title" ~default:"";
    token_prefix = Row.string_ json "token_prefix" ~default:"";
    scopes = Row.string_list json "scopes";
    can_assign = Row.bool_ json "can_assign" ~default:false;
    expires_at = Row.opt_string json "expires_at";
    last_used_at = Row.opt_string json "last_used_at";
    revoked_at = Row.opt_string json "revoked_at";
    created_by_id = Row.opt_string json "created_by_id";
    created_at = Row.opt_string json "created_at";
  }

let select =
  "SELECT row_to_json(c)::text FROM credential c"

let by_id conn id : (t option, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf "%s WHERE c.id = %s" select literal)
      |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

(* Годная учётка: не отозвана и не просрочена. Проверка срока здесь,
   а не в сервисе: база сравнивает даты, сервису разбор дат не нужен. *)
let usable_by_token_hash conn hash : (t option, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf
       "%s WHERE c.token_hash = %s AND c.revoked_at IS NULL \
        AND (c.expires_at IS NULL OR c.expires_at > now())"
       select (Conn.quote hash))
  |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let list_by_actor conn actor_id : (t list, string) result Lwt.t =
  match Conn.uuid_literal actor_id with
  | None -> Lwt_result.lift (Ok [])
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf
           "%s WHERE c.actor_id = %s ORDER BY c.created_at DESC" select literal)
      |> Lwt_result.map (List.map of_json)

(** Создание учётки. Хэш и префикс считает сервис: репозиторий хранит то,
    что ему дали, и не знает, как токен выглядит. *)
let create conn ~actor_id ~title ~token_prefix ~token_hash
    ?(scopes = [ "task:read"; "task:write" ]) ?(can_assign = false) ?expires_at
    ?created_by_id () : (t, string) result Lwt.t =
  let uuid = function
    | None -> "NULL"
    | Some id -> (
        match Conn.uuid_literal id with
        | None -> "NULL"
        | Some literal -> literal)
  in
  let scope_sql = "{" ^ String.concat "," scopes ^ "}" in
  let sql =
    Printf.sprintf
      "INSERT INTO credential \
       (actor_id, title, token_prefix, token_hash, scopes, can_assign, \
       expires_at, created_by_id) \
       VALUES (%s, %s, %s, %s, '%s', %s, %s, %s) RETURNING id::text"
      (uuid (Some actor_id))
      (Conn.quote title)
      (Conn.quote token_prefix)
      (Conn.quote token_hash)
      scope_sql
      (if can_assign then "true" else "false")
      (match expires_at with None -> "NULL" | Some s -> "'" ^ s ^ "'::timestamptz")
      (uuid created_by_id)
  in
  let* outcome = Conn.query_strings conn sql in
  match outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok [] -> Lwt_result.lift (Error "учётка создана, но её id не прочитан")
  | Ok (id :: _) -> (
      let* found = by_id conn id in
      match found with
      | Error e -> Lwt_result.lift (Error e)
      | Ok Some cred -> Lwt_result.lift (Ok cred)
      | Ok None -> Lwt_result.lift (Error "учётка создана, но не найдена"))

let revoke conn id : (unit, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Error "неверный идентификатор учётки")
  | Some literal ->
      Conn.exec_sql conn
        (Printf.sprintf
           "UPDATE credential SET revoked_at = now() \
            WHERE id = %s AND revoked_at IS NULL" literal)

let touch_last_used conn id : (unit, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Error "неверный идентификатор учётки")
  | Some literal ->
      Conn.exec_sql conn
        (Printf.sprintf "UPDATE credential SET last_used_at = now() WHERE id = %s" literal)
