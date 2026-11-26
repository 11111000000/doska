(** Учётные записи агентов: выпуск, проверка и отзыв bearer-токенов.

    Токен рождается один раз и показывается один раз: в ответ на выпуск
    уходит открытым текстом, в базе остаётся только SHA-256-хэш. Префикс —
    первые 12 символов открытого токена — хранится для различения учёток
    в списке и в логах.

    Случайные байты берутся из [/dev/urandom] через [Unix]: без отдельного
    RNG, чья инициализация легко забывается и молча даёт предсказуемые
    токены. *)

let ( let* ) t f = Lwt.bind t f

let token_entropy_bytes = 32

(** Сколько символов открытого токена хранится рядом с хэшем. *)
let prefix_length = 12

let random_bytes n =
  let ic = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY ] 0 in
  let buf = Bytes.create n in
  Fun.protect
    ~finally:(fun () -> Unix.close ic)
    (fun () ->
      let rec fill offset =
        if offset = n then ()
        else
          let count = Unix.read ic buf offset (n - offset) in
          fill (offset + count)
      in
      fill 0);
  buf

let to_hex bytes =
  let hex = "0123456789abcdef" in
  let len = Bytes.length bytes in
  let out = Bytes.create (len * 2) in
  for i = 0 to len - 1 do
    let b = Char.code (Bytes.get bytes i) in
    Bytes.set out (i * 2) hex.[b lsr 4];
    Bytes.set out ((i * 2) + 1) hex.[b land 0xf]
  done;
  Bytes.to_string out

let hash_hex token = Digestif.SHA256.(to_hex (digest_string token))

(** Выпуск токена. Открытый текст возвращается только здесь: следующий
    выпуск того же актора даст новый токен, старый хэш не восстановить. *)
let issue conn ~actor_id ~title ?(scopes = [ "task:read"; "task:write" ])
    ?(can_assign = false) ?expires_at ~created_by_id () :
    ((Db.Repo_credential.t * string), Failure.t) result Lwt.t =
  let token = "dsk_" ^ to_hex (random_bytes token_entropy_bytes) in
  let prefix =
    String.sub token 0 (Int.min prefix_length (String.length token))
  in
  Db.Repo_credential.create conn ~actor_id ~title ~token_prefix:prefix
    ~token_hash:(hash_hex token) ~scopes ~can_assign ?expires_at
    ~created_by_id ()
  |> Lwt_result.map (fun cred -> (cred, token))
  |> Lwt_result.map_error (fun e -> Failure.Storage { message = e })

type verified =
  | Verified of Db.Repo_credential.t * Domain.Actor.t
  | Invalid of Failure.t

(** Проверка предъявленного токена.

    Отказ проверки — значение [Invalid], а не промисс-ошибка: «токен
    неправильный» — обычный исход проверки, а не сбой хранилища. Причина
    не различается (просрочен, отозван, неизвестен): клиенту от этого
    легче только подобрать токен. *)
let verify conn token : verified Lwt.t =
  let* found = Db.Repo_credential.usable_by_token_hash conn (hash_hex token) in
  match found with
  | Error e -> Lwt.return (Invalid (Failure.Storage { message = e }))
  | Ok None ->
      Lwt.return (Invalid (Failure.Unauthorized { message = "токен не признан" }))
  | Ok Some cred -> (
      let* actor = Db.Repo_actor.by_id conn cred.actor_id in
      match actor with
      | Error e -> Lwt.return (Invalid (Failure.Storage { message = e }))
      | Ok None ->
          Lwt.return
            (Invalid (Failure.Unauthorized { message = "владелец токена не найден" }))
      | Ok Some a ->
          let* _touch = Db.Repo_credential.touch_last_used conn cred.id in
          Lwt.return (Verified (cred, a)))

(** Список учёток актора: хэши и открытые токены не возвращаются. *)
let list conn ~actor_id : (Db.Repo_credential.t list, Failure.t) result Lwt.t =
  Db.Repo_credential.list_by_actor conn actor_id
  |> Lwt_result.map_error (fun e -> Failure.Storage { message = e })

(** Отзыв учётки. Свою отзывает владелец; чужую — только администратор:
    признак [admin] считает HTTP-слой по [DOSKA_ADMIN_HANDLES]. *)
let revoke conn ~id ~by_actor_id ~admin : (unit, Failure.t) result Lwt.t =
  let* found = Db.Repo_credential.by_id conn id in
  match found with
  | Error e -> Lwt_result.lift (Error (Failure.Storage { message = e }))
  | Ok None ->
      Lwt_result.lift (Error (Failure.Not_found { message = "учётка не найдена" }))
  | Ok Some cred ->
      if cred.actor_id <> by_actor_id && not admin then
        Lwt_result.lift
          (Error
             (Failure.Forbidden
                {
                  message = "чужую учётку отзывает только администратор";
                  details = [];
                }))
      else
        Db.Repo_credential.revoke conn id
        |> Lwt_result.map_error (fun e -> Failure.Storage { message = e })
