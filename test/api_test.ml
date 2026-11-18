(** REST API на живой базе.

    Главное свойство этапа: переход, запрещённый правилами домена, даёт 403
    с понятным телом — а не 500. Остальное — контракт: коды ответов, формат
    ошибки, пагинация и идемпотентность создания. *)

open Domain

let conn = Support.connect ()

(* Фикстуры этого теста общие с другим его прогоном: блокируемся, чтобы
   уборка одного прогона не удалила фикстуры другого. *)
let () = Support.lock conn 4712

(* Уборка — до фикстур: [Alcotest.run] завершает процесс, код после него не
   выполняется, поэтому строки прошлого прогона убираем на входе. *)
let () =
  Support.cleanup conn ~source:"test-api" ~actor_prefix:"api-" ~project_prefix:"API"

let requester =
  Support.ensure_actor conn ~prefix:"api-" ~kind:Actor.Human ~handle:"petr"
    ~display_name:"Пётр"

let agent =
  Support.ensure_actor conn ~prefix:"api-" ~kind:Actor.Agent ~handle:"legist"
    ~display_name:"legist"

let stranger =
  Support.ensure_actor conn ~prefix:"api-" ~kind:Actor.Human ~handle:"other"
    ~display_name:"Другой"

let project =
  Support.ensure_project conn ~prefix:"API" ~key:"MAIN" ~name:"Основной"
    ~autonomy:Actor.Human_gate

let auto_project =
  Support.ensure_project conn ~prefix:"API" ~key:"AUTO" ~name:"Автономный"
    ~autonomy:Actor.Auto

(* ------------------------------------------------------------------ клиент --- *)

let client = Dream.test Api.Server.handler

let call ?(method_ = `GET) ?(actor = None) ?(body = "") target =
  let headers =
    match actor with
    | None -> []
    | Some handle -> [ ("x-doska-actor", handle) ]
  in
  let response = client (Dream.request ~method_ ~target ~headers body) in
  let status = Dream.status_to_int (Dream.status response) in
  let text = Support.run (Dream.body response) in
  (status, text)

let json text = Yojson.Safe.from_string text

let field name value =
  match value with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let text_field name value =
  match field name value with Some (`String s) -> s | _ -> ""

let error_code value =
  match field "error" value with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "code" fields with Some (`String code) -> code | _ -> "")
  | _ -> ""

let error_message value =
  match field "error" value with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "message" fields with Some (`String m) -> m | _ -> "")
  | _ -> ""

let task_of value =
  match field "task" value with Some task -> task | None -> `Null

let task_status value = text_field "status" (task_of value)

let task_ref value = text_field "ref" (task_of value)

(* ------------------------------------------------------------------ помощники --- *)

let create_body ?(status = "backlog") ?source_ref ?project () =
  let project = match project with Some p -> p | None -> "APIMAIN" in
  let fields =
    [
      ("title", `String "Задача из API");
      ("description", `String "описание задачи");
      ("status", `String status);
      ("project", `String project);
      ("source", `String "test-api");
    ]
    @ (match source_ref with
      | None -> []
      | Some ref_ -> [ ("source_ref", `String ref_) ])
  in
  Yojson.Safe.to_string (`Assoc fields)

let create_task ?(status = "backlog") ?source_ref ?project () =
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(create_body ~status ?source_ref ?project ())
      "/api/v1/tasks"
  in
  (code, json text)

(** Переход по HTTP: [to_] — целевой статус, [version] — версия задачи. *)
let transition actor ref_ to_ version =
  call ~method_:`POST ~actor:(Some actor)
    ~body:
      (Yojson.Safe.to_string
         (`Assoc [ ("to", `String to_); ("version", `Int version) ]))
    (Printf.sprintf "/api/v1/tasks/%s/transition" ref_)

(* --------------------------------------------------------------------- тесты --- *)

let test_create_task () =
  let code, value = create_task () in
  Alcotest.(check int) "код ответа" 201 code;
  Alcotest.(check bool) "задаче присвоен ref" true (task_ref value <> "");
  Alcotest.(check string) "статус" "backlog" (task_status value)

let test_without_actor_is_unauthorized () =
  let code, text = call "/api/v1/tasks" in
  Alcotest.(check int) "код ответа" 401 code;
  Alcotest.(check string) "код ошибки" "unauthorized" (error_code (json text))

(** Тело ошибки — один и тот же формат для всех классов ошибки: клиент
    отличает «запрос неправильный» от «правило запрещает» по коду, а не по
    тексту (§6.1). *)
let test_error_body_is_uniform () =
  let code, text = call "/api/v1/tasks" in
  Alcotest.(check int) "код ответа" 401 code;
  let value = json text in
  Alcotest.(check string) "код ошибки" "unauthorized" (error_code value);
  Alcotest.(check bool) "в теле есть сообщение" true (error_message value <> "");
  (match value with
  | `Assoc fields ->
      Alcotest.(check (list string)) "в теле только error" [ "error" ]
        (List.map fst fields)
  | _ -> Alcotest.fail "тело ошибки — не объект")

(** Битое тело — ошибка запроса, а не поломка сервера: 400, а не 500. *)
let test_broken_body_is_bad_request () =
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr") ~body:"{\"title\": " "/api/v1/tasks"
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

let test_forbidden_transition_is_403 () =
  let _, created = create_task ~status:"in_review" () in
  let ref_ = task_ref created in
  let code, text = transition "api-legist" ref_ "done" 1 in
  Alcotest.(check int) "код ответа" 403 code;
  let value = json text in
  Alcotest.(check string) "код ошибки" "forbidden" (error_code value);
  (* В теле — что именно запрещено: клиенту это показывать. *)
  let details =
    match field "error" value with
    | Some (`Assoc fields) -> List.assoc_opt "details" fields
    | _ -> None
  in
  Alcotest.(check bool) "в теле есть детали перехода" true (details <> None)

let test_agent_accepts_work_in_trusted_project () =
  (* Обратная сторона правила R1: в доверенном проекте агент закрывает сам. *)
  let _, created =
    create_task ~status:"in_review" ~project:auto_project.Project.key ()
  in
  let ref_ = task_ref created in
  let code, text = transition "api-legist" ref_ "done" 1 in
  Alcotest.(check int) "код ответа" 200 code;
  Alcotest.(check string) "статус после приёмки" "done" (task_status (json text))

let test_requester_accepts_work () =
  let _, created = create_task ~status:"in_review" () in
  let ref_ = task_ref created in
  let code, text = transition "api-petr" ref_ "done" 1 in
  Alcotest.(check int) "код ответа" 200 code;
  Alcotest.(check string) "статус после приёмки" "done" (task_status (json text))

let test_admin_accepts_work () =
  let _, created = create_task ~status:"in_review" () in
  let ref_ = task_ref created in
  Unix.putenv "DOSKA_ADMIN_HANDLES" "api-other";
  let code, _text = transition "api-other" ref_ "done" 1 in
  Unix.putenv "DOSKA_ADMIN_HANDLES" "";
  Alcotest.(check int) "код ответа" 200 code

let test_unknown_status_is_bad_request () =
  let _, created = create_task () in
  let ref_ = task_ref created in
  let code, text = transition "api-petr" ref_ "выдумка" 1 in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

let test_stale_version_is_conflict () =
  let _, created = create_task ~status:"in_review" () in
  let ref_ = task_ref created in
  let code, text = transition "api-petr" ref_ "done" 999 in
  Alcotest.(check int) "код ответа" 409 code;
  Alcotest.(check string) "код ошибки" "conflict" (error_code (json text))

let test_list_is_paginated () =
  let code, text = call ~actor:(Some "api-petr") "/api/v1/tasks?project=APIMAIN&limit=1" in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  (match field "items" value with
  | Some (`List items) -> Alcotest.(check int) "задач на странице" 1 (List.length items)
  | _ -> Alcotest.fail "в ответе нет списка задач");
  Alcotest.(check bool) "есть курсор следующей страницы" true
    (match field "next_cursor" value with Some (`String s) -> s <> "" | _ -> false)

let test_create_is_idempotent () =
  let source_ref = "api-fixed-1" in
  let code_first, first = create_task ~source_ref () in
  let code_second, second = create_task ~source_ref () in
  Alcotest.(check int) "первый ответ" 201 code_first;
  Alcotest.(check int) "повторный ответ" 200 code_second;
  Alcotest.(check string) "та же задача" (task_ref first) (task_ref second);
  Alcotest.(check bool) "повтор помечен как идемпотентным" true
    (match field "idempotent" second with Some (`Bool true) -> true | _ -> false)

let test_task_card_has_comments_and_evidence () =
  let _, created = create_task () in
  let ref_ = task_ref created in
  let comment_code, _ =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(Yojson.Safe.to_string (`Assoc [ ("body", `String "комментарий") ]))
      (Printf.sprintf "/api/v1/tasks/%s/comment" ref_)
  in
  Alcotest.(check int) "код комментария" 201 comment_code;
  let evidence_code, _ =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
              [
                ("kind", `String "commit");
                ("ref", `String "abc123");
                ("uri", `String "https://example.org/abc123");
              ]))
      (Printf.sprintf "/api/v1/tasks/%s/evidence" ref_)
  in
  Alcotest.(check int) "код доказательства" 201 evidence_code;
  let code, text =
    call ~actor:(Some "api-petr") (Printf.sprintf "/api/v1/tasks/%s" ref_)
  in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  (match field "comments" value with
  | Some (`List comments) -> Alcotest.(check int) "комментариев" 1 (List.length comments)
  | _ -> Alcotest.fail "в карточке нет комментариев");
  (match field "evidence" value with
  | Some (`List evidence) -> Alcotest.(check int) "доказательств" 1 (List.length evidence)
  | _ -> Alcotest.fail "в карточке нет доказательств")

let test_agent_cannot_assign_to_another () =
  let _, created = create_task () in
  let ref_ = task_ref created in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-legist")
      ~body:
        (Yojson.Safe.to_string
           (`Assoc [ ("assignee", `String "api-petr"); ("version", `Int 1) ]))
      (Printf.sprintf "/api/v1/tasks/%s/assign" ref_)
  in
  Alcotest.(check int) "код ответа" 403 code;
  Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text))

let test_human_can_assign () =
  let _, created = create_task () in
  let ref_ = task_ref created in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:
        (Yojson.Safe.to_string
           (`Assoc
              [
                ("assignee", `String "api-legist");
                ("version", `Int 1);
              ]))
      (Printf.sprintf "/api/v1/tasks/%s/assign" ref_)
  in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  Alcotest.(check string) "исполнитель назначен" "legist"
    (text_field "assignee" (task_of value));
  Alcotest.(check bool) "исполнитель записан" true
    (text_field "assignee_id" (task_of value) <> "")

(* --------------------------------------------------------------------- run --- *)

let () =
  Alcotest.run "api"
    [
      ( "задачи",
        [
          Alcotest.test_case "задача создаётся" `Quick test_create_task;
          Alcotest.test_case "без актора — 401" `Quick test_without_actor_is_unauthorized;
          Alcotest.test_case "тело ошибки — единый формат" `Quick
            test_error_body_is_uniform;
          Alcotest.test_case "битое тело — 400" `Quick test_broken_body_is_bad_request;
          Alcotest.test_case "запрещённый переход — 403, а не 500" `Quick
            test_forbidden_transition_is_403;
          Alcotest.test_case "в доверенном проекте агент принимает работу" `Quick
            test_agent_accepts_work_in_trusted_project;
          Alcotest.test_case "заявитель принимает работу" `Quick
            test_requester_accepts_work;
          Alcotest.test_case "администратор принимает работу" `Quick
            test_admin_accepts_work;
          Alcotest.test_case "неизвестный статус — 400" `Quick
            test_unknown_status_is_bad_request;
          Alcotest.test_case "устаревшая версия — 409" `Quick
            test_stale_version_is_conflict;
        ] );
      ( "списки и карточки",
        [
          Alcotest.test_case "список пагинирован" `Quick test_list_is_paginated;
          Alcotest.test_case "повторное создание не плодит дубль" `Quick
            test_create_is_idempotent;
          Alcotest.test_case "карточка содержит комментарии и доказательства" `Quick
            test_task_card_has_comments_and_evidence;
        ] );
      ( "назначение",
        [
          Alcotest.test_case "агент не назначает задачу другому" `Quick
            test_agent_cannot_assign_to_another;
          Alcotest.test_case "человек назначает задачу" `Quick test_human_can_assign;
        ] );
    ];
  ignore requester;
  ignore agent;
  ignore stranger;
  ignore project
