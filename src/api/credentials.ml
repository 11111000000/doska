(** Учётные записи агентов: REST-маршруты.

    Токен в ответе на выпуск — единственный раз, когда секрет уходит из
    сервера. Список учёток показывает префиксы, не секреты. *)

let json_of_credential (cred : Db.Repo_credential.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String cred.id);
      ("actor_id", `String cred.actor_id);
      ("title", `String cred.title);
      ("token_prefix", `String cred.token_prefix);
      ("scopes", `List (List.map (fun s -> `String s) cred.scopes));
      ("can_assign", `Bool cred.can_assign);
      ("expires_at",
        match cred.expires_at with Some s -> `String s | None -> `Null);
      ("last_used_at",
        match cred.last_used_at with Some s -> `String s | None -> `Null);
      ("revoked_at",
        match cred.revoked_at with Some s -> `String s | None -> `Null);
      ("created_at",
        match cred.created_at with Some s -> `String s | None -> `Null);
    ]

let ( let* ) t f = Lwt.bind t f

let respond ?(status = `OK) (json : Yojson.Safe.t) =
  Dream.json ~status (Yojson.Safe.to_string json)

let respond_failure failure = Errors.respond (Errors.of_failure failure)

(** Список учёток текущего актора. *)
let list req =
  Context.with_actor req (fun conn actor ->
      let* outcome = Service.Credential.list conn ~actor_id:actor.id in
      match outcome with
      | Error failure -> respond_failure failure
      | Ok credentials ->
          respond
            (`List (List.map json_of_credential credentials)))

(** Выпуск токена.

    Тело: {"title": string, "expires_at"?: ISO-строка, "can_assign"?: bool,
    "scopes"?: [string]}. Адресат — сам актор из заголовка/токена: выпуск
    токена для другого — операция администратора, она появится вместе с
    настоящими ролями. *)
let issue req =
  Context.with_body req (fun conn actor body ->
      match body with
      | `Assoc fields -> (
          let title =
            match List.assoc_opt "title" fields with
            | Some (`String s) when String.trim s <> "" -> Some (String.trim s)
            | _ -> None
          in
          match title with
          | None ->
              Errors.respond
                (Errors.make Errors.Bad_request "укажите непустое поле title")
          | Some title ->
              let scopes =
                match List.assoc_opt "scopes" fields with
                | Some (`List items) ->
                    Some
                      (List.filter_map
                         (function `String s -> Some s | _ -> None)
                         items)
                | _ -> None
              in
              let can_assign =
                match List.assoc_opt "can_assign" fields with
                | Some (`Bool b) -> b
                | _ -> false
              in
              let expires_at =
                match List.assoc_opt "expires_at" fields with
                | Some (`String s) -> Some s
                | _ -> None
              in
              let* outcome =
                Service.Credential.issue conn ~actor_id:actor.id ~title
                  ?scopes ~can_assign ?expires_at ~created_by_id:actor.id ()
              in
              match outcome with
              | Error failure -> respond_failure failure
              | Ok (cred, token) ->
                  respond ~status:`Created
                    (`Assoc
                      [
                        ("credential", json_of_credential cred);
                        ("token", `String token);
                      ]))
      | _ ->
          Errors.respond
            (Errors.make Errors.Bad_request "ожидался JSON-объект"))

(** Отзыв учётки: своей — по праву владельца, чужой — только администратор. *)
let revoke req =
  Context.with_actor req (fun conn actor ->
      let id = Dream.param req "id" in
      let admin = Identity.Admin.is_admin actor in
      let* outcome =
        Service.Credential.revoke conn ~id ~by_actor_id:actor.id ~admin
      in
      match outcome with
      | Error failure -> respond_failure failure
      | Ok () -> respond (`Assoc [ ("revoked", `Bool true) ]))
