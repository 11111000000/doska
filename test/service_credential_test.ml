(** Учётные записи агентов на живой базе.

    Токен рождается один раз, хэш не восстанавливается, отзыв гасит доступ.
    Эти свойства нельзя проверить без базы: выпуск пишет в неё, проверка
    читает. Фикстуры с префиксом — как в других сервисных тестах: чужие
    строки трогать нельзя. *)

open Domain

let prefix = "crd-"

let conn = lazy (Support.connect ())

let cleanup () =
  Support.cleanup (Lazy.force conn) ~source:"cred-test" ~actor_prefix:prefix
    ~project_prefix:"CRED-"

let agent () =
  Support.ensure_actor (Lazy.force conn) ~prefix ~kind:Actor.Agent
    ~handle:"bot" ~display_name:"Тестовый агент"

let human () =
  Support.ensure_actor (Lazy.force conn) ~prefix ~kind:Actor.Human
    ~handle:"petr" ~display_name:"Пётр"

let expect_ok (outcome : ('a, Service.Failure.t) result Lwt.t) : 'a =
  match Support.run outcome with
  | Ok value -> value
  | Error failure -> failwith ("ожидали успех, получили: " ^ Service.Failure.to_string failure)

(* Проверка токена возвращает значение, а не result: исход «токен не признан»
   — часть проверки, а не сбой. *)
let verify token =
  Support.run (Service.Credential.verify (Lazy.force conn) token)

let test_issue_returns_token_once () =
  cleanup ();
  let a = agent () in
  let cred, token = expect_ok (Service.Credential.issue (Lazy.force conn)
      ~actor_id:a.id ~title:"первый ключ" ~created_by_id:a.id ()) in
  Alcotest.(check bool "токен начинается с префикса doska"
    (String.starts_with ~prefix:"dsk_" token) true);
  Alcotest.(check int "токен: dsk_ + 64 hex" 68 (String.length token));
  Alcotest.(check string "префикс учётки — первые 12 символов токена"
    (String.sub token 0 12) cred.token_prefix);
  Alcotest.(check bool "хэш не равен токену" (cred.token_prefix <> token) true);
  Alcotest.(check bool "в записи нет открытого токена"
    (String.length cred.token_prefix < String.length token) true);
  cleanup ()

let test_verify_roundtrip () =
  cleanup ();
  let a = agent () in
  let _, token = expect_ok (Service.Credential.issue (Lazy.force conn)
      ~actor_id:a.id ~title:"ключ проверки" ~created_by_id:a.id ()) in
  (match verify token with
  | Service.Credential.Verified (cred, actor) ->
      Alcotest.(check string "актёр — владелец учётки" a.id actor.id);
      Alcotest.(check bool "учётка жива" (cred.revoked_at = None) true)
  | Service.Credential.Invalid failure ->
      failwith ("правильный токен не признан: " ^ Service.Failure.to_string failure));
  (* Другой токен той же формы не проходит: хэш другой. *)
  (match verify ("dsk_" ^ String.make 64 'a') with
  | Service.Credential.Invalid (Service.Failure.Unauthorized _) -> ()
  | Service.Credential.Invalid failure ->
      failwith ("чужой токен дал не тот отказ: " ^ Service.Failure.to_string failure)
  | Service.Credential.Verified _ -> failwith "выдуманный токен признан");
  cleanup ()

let test_revoke_blocks_access () =
  cleanup ();
  let a = agent () in
  let cred, token = expect_ok (Service.Credential.issue (Lazy.force conn)
      ~actor_id:a.id ~title:"ключ на отзыв" ~created_by_id:a.id ()) in
  expect_ok (Service.Credential.revoke (Lazy.force conn) ~id:cred.id ~by_actor_id:a.id ~admin:false);
  (match verify token with
  | Service.Credential.Invalid (Service.Failure.Unauthorized _) -> ()
  | Service.Credential.Invalid failure ->
      failwith ("отозванный токен дал не тот отказ: " ^ Service.Failure.to_string failure)
  | Service.Credential.Verified _ -> failwith "отозванный токен признан");
  cleanup ()

let test_revoke_foreign_needs_admin () =
  cleanup ();
  let a = agent () in
  let p = human () in
  let cred, _token = expect_ok (Service.Credential.issue (Lazy.force conn)
      ~actor_id:a.id ~title:"чужой ключ" ~created_by_id:p.id ()) in
  (match Support.run (Service.Credential.revoke (Lazy.force conn)
           ~id:cred.id ~by_actor_id:p.id ~admin:false) with
  | Error (Service.Failure.Forbidden _) -> ()
  | Error failure ->
      failwith ("чужой отзыв дал не тот отказ: " ^ Service.Failure.to_string failure)
  | Ok () -> failwith "чужой отзыв прошёл без прав администратора");
  expect_ok (Service.Credential.revoke (Lazy.force conn) ~id:cred.id ~by_actor_id:p.id ~admin:true);
  cleanup ()

let () =
  let open Alcotest in
  run "Service.Credential"
    [
      ("issue",
        [ test_case "токен показывается один раз" `Quick test_issue_returns_token_once ]);
      ("verify",
        [ test_case "правильный признаётся, выдуманный нет" `Quick test_verify_roundtrip ]);
      ("revoke",
        [ test_case "отзыв гасит токен" `Quick test_revoke_blocks_access ]);
      ("ownership",
        [ test_case "чужой отзыв требует администратора" `Quick test_revoke_foreign_needs_admin ]);
    ]
