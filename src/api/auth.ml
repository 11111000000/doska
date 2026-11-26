(** Кто выполняет запрос.

    Основной путь — bearer-токен из заголовка [Authorization]: SHA-256
    предъявленного токена ищется в [credential], отозванные и просроченные
    учётки запрос не проходят (см. [Service.Credential.verify]).

    Заголовок [X-Doska-Actor] остаётся запасным путём на время перехода:
    этап 1 годился только в доверенной сети, и подделать его по-прежнему
    тривиально. Он отключается, когда все клиенты перейдут на токены.

    Право администратора задаётся переменной окружения
    [DOSKA_ADMIN_HANDLES] и живёт в [Identity.Admin]: сервисный слой решает
    по нему, может ли агент закрыть задачу сам. *)

open Domain

let ( let* ) t f = Lwt.bind t f

let legacy_header = "x-doska-actor"
let authorization_header = "authorization"

(** Выделение токена из значения заголовка [Authorization]: схема «Bearer»
    и токен разделяет один пробел; сравнение схемы без учёта регистра —
    так требует RFC 7235. *)
let bearer_token (value : string) : string option =
  match String.index_opt value ' ' with
  | None -> None
  | Some space ->
      let scheme = String.lowercase_ascii (String.sub value 0 space) in
      if scheme = "bearer" then
        let token = String.trim (String.sub value (space + 1) (String.length value - space - 1)) in
        if token = "" then None else Some token
      else None

(** Актор запроса по bearer-токену. *)
let actor_of_token conn token : (Actor.t, Errors.t) result Lwt.t =
  let* verified = Service.Credential.verify conn token in
  match verified with
  | Invalid failure -> Lwt_result.lift (Error (Errors.of_failure failure))
  | Verified (_, actor) -> Lwt_result.lift (Ok actor)

(** Актор запроса: токен, иначе — запасной заголовок. *)
let actor_of conn req : (Actor.t, Errors.t) result Lwt.t =
  match Dream.headers req authorization_header with
  | value :: _ -> (
      match bearer_token value with
      | Some token -> actor_of_token conn token
      | None ->
          Lwt_result.lift
            (Error
               (Errors.make Errors.Bad_request
                  "заголовок Authorization есть, но bearer-токен в нём не разобран")))
  | [] -> (
      match Dream.headers req legacy_header with
      | [] ->
          Lwt_result.lift
            (Error
               (Errors.make Errors.Unauthorized
                  "нет токена: пришлите Authorization: Bearer dsk_… (или X-Doska-Actor до конца перехода)"))
      | handle :: _ ->
          let* found = Db.Repo_actor.by_handle conn handle in
          (match found with
          | Error e -> Lwt_result.lift (Error (Errors.make Errors.Internal e))
          | Ok (Some actor) -> Lwt_result.lift (Ok actor)
          | Ok None ->
              Lwt_result.lift
                (Error (Errors.make Errors.Unauthorized ("актор не найден: " ^ handle)))))
