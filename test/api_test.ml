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

(* Второй агент — посторонний для правила отпуска: задачу отпускает её
   исполнитель или любой человек, а не всякий агент. *)
let other_agent =
  Support.ensure_actor conn ~prefix:"api-" ~kind:Actor.Agent ~handle:"legist2"
    ~display_name:"legist2"

let project =
  Support.ensure_project conn ~prefix:"API" ~key:"MAIN" ~name:"Основной"
    ~autonomy:Actor.Human_gate

let auto_project =
  Support.ensure_project conn ~prefix:"API" ~key:"AUTO" ~name:"Автономный"
    ~autonomy:Actor.Auto

(* Актёр для проверки резолва: логин и отображаемое имя различаются, и
   резолвер обязан находить по обоим. *)
let resolvable =
  Support.ensure_actor conn ~prefix:"api-" ~kind:Actor.Human ~handle:"resolver"
    ~display_name:"api-тестовый"

(* ------------------------------------------------------------------ клиент --- *)

let client = Dream.test Api.Server.handler

let call ?(method_ = `GET) ?(actor = None) ?(bearer = None) ?(body = "") target =
  let headers =
    (match bearer with
    | Some token -> [ ("authorization", "Bearer " ^ token) ]
    | None -> [])
    @ (match actor with
      | None -> []
      | Some handle -> [ ("x-doska-actor", handle) ])
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

(* Список из тела: связи и дети приходят списками. *)
let list_field name value =
  match field name value with Some (`List items) -> items | _ -> []

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

let bool_field name value =
  match field name value with Some (`Bool b) -> b | _ -> false

(* Число из тела: в сводке их много, и по умолчанию «нет числа» должно
   отличаться от нуля, иначе проверка проходит на пустом месте. *)
let int_field name value =
  match field name value with Some (`Int n) -> n | _ -> -1

let actor_of value =
  match field "actor" value with Some actor -> actor | None -> `Null

let task_status value = text_field "status" (task_of value)

let task_ref value = text_field "ref" (task_of value)

(* ------------------------------------------------------------------ помощники --- *)

let create_body ?(status = "backlog") ?source_ref ?project ?title ?assignee ?due_at ?parent
    () =
  let project = match project with Some p -> p | None -> "APIMAIN" in
  let fields =
    [
      ("title", `String (match title with Some t -> t | None -> "Задача из API"));
      ("description", `String "описание задачи");
      ("status", `String status);
      ("project", `String project);
      ("source", `String "test-api");
    ]
    @ (match source_ref with
      | None -> []
      | Some ref_ -> [ ("source_ref", `String ref_) ])
    @ (match assignee with
      | None -> []
      | Some handle -> [ ("assignee", `String handle) ])
    @ (match due_at with
      | None -> []
      | Some value -> [ ("due_at", `String value) ])
    @ (match parent with
      | None -> []
      | Some ref_ -> [ ("parent", `String ref_) ])
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

(** Переход с вопросом или ответом.

    [reason] — текст вопроса, [asked_to] — кому адресован, [answer] — ответ
    на открытый вопрос. *)
let transition_with ?reason ?asked_to ?answer actor ref_ to_ version =
  let fields =
    [ ("to", `String to_); ("version", `Int version) ]
    @ (match reason with
      | None -> []
      | Some text -> [ ("reason", `String text) ])
    @ (match asked_to with
      | None -> []
      | Some handle -> [ ("asked_to", `String handle) ])
    @ (match answer with
      | None -> []
      | Some text -> [ ("answer", `String text) ])
  in
  call ~method_:`POST ~actor:(Some actor)
    ~body:(Yojson.Safe.to_string (`Assoc fields))
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

(* ------------------------------------------------------- вопрос и ответ --- *)

(** Вопрос доезжает до карточки: клиенту видно, о чём спросили и кого. *)
let test_question_is_stored_in_card () =
  let _, created = create_task ~status:"in_progress" () in
  let ref_ = task_ref created in
  let code, text =
    transition_with ~reason:"Какой формат отчёта нужен?" ~asked_to:"api-other"
      "api-petr" ref_ "needs_input" 1
  in
  Alcotest.(check int) "код ответа" 200 code;
  let card = task_of (json text) in
  Alcotest.(check string) "статус" "needs_input" (text_field "status" card);
  Alcotest.(check string) "вопрос" "Какой формат отчёта нужен?"
    (text_field "question" card);
  Alcotest.(check string) "адресат" "api-other" (text_field "asked_to" card)

(** Версия обязательна и для вопроса: без неё — плохой запрос. *)
let test_question_without_version_is_bad_request () =
  let _, created = create_task ~status:"in_progress" () in
  let ref_ = task_ref created in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(Yojson.Safe.to_string (`Assoc [ ("to", `String "needs_input") ]))
      (Printf.sprintf "/api/v1/tasks/%s/transition" ref_)
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Неизвестная задача — 404, а не 500: опечатку в ref видно сразу. *)
let test_question_of_unknown_task_is_not_found () =
  let code, text =
    transition_with ~reason:"Нужен отчёт?" ~asked_to:"api-other" "api-petr"
      "DSK-НЕТ-ТАКОЙ" "needs_input" 1
  in
  Alcotest.(check int) "код ответа" 404 code;
  Alcotest.(check string) "код ошибки" "not_found" (error_code (json text))

(** Адресат-нечеловек — плохой запрос: от агента ответа не будет. *)
let test_addressee_must_be_human () =
  let _, created = create_task ~status:"in_progress" () in
  let ref_ = task_ref created in
  let code, text =
    transition_with ~reason:"Нужен отчёт?" ~asked_to:"api-legist" "api-petr" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Неизвестный адресат — плохой запрос: клиент ошибся в логине. *)
let test_unknown_addressee_is_bad_request () =
  let _, created = create_task ~status:"in_progress" () in
  let ref_ = task_ref created in
  let code, text =
    transition_with ~reason:"Нужен отчёт?" ~asked_to:"api-нет-такого" "api-petr"
      ref_ "needs_input" 1
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Из needs_input нельзя выйти молча: без ответа переход запрещён. *)
let test_answer_is_required_to_leave_needs_input () =
  let _, created = create_task ~status:"in_progress" () in
  let ref_ = task_ref created in
  let code, _ =
    transition_with ~reason:"Нужен отчёт?" ~asked_to:"api-other" "api-petr" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "вопрос задан" 200 code;
  let code, text = transition_with "api-other" ref_ "in_progress" 2 in
  Alcotest.(check int) "код ответа" 403 code;
  Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text))

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

(* ------------------------------------------------------- главный запрос --- *)

(** Момент через [hours] часов от сейчас.

    Сроки задаются относительно текущего момента: зашитый в тест календарь
    рассыпался бы после полуночи. *)
let in_hours hours =
  let stamp = Unix.gmtime (Unix.time () +. (float_of_int hours *. 3600.)) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (stamp.Unix.tm_year + 1900)
    (stamp.Unix.tm_mon + 1)
    stamp.Unix.tm_mday stamp.Unix.tm_hour stamp.Unix.tm_min stamp.Unix.tm_sec

(** Задача для главного запроса.

    Свой [source_ref] — по нему задачу узнают в ответе: у исполнителя могут
    быть и чужие задачи, заведённые другими тестами, и их нельзя путать со
    нашими. *)
let create_mine_task ~source_ref ?assignee ?due_at ?status () =
  let status = match status with Some s -> s | None -> "backlog" in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(create_body ~status ~source_ref ?assignee ?due_at ())
      "/api/v1/tasks"
  in
  (code, json text)

let mine_items value =
  match field "items" value with
  | Some (`List items) -> items
  | _ -> Alcotest.fail "в ответе нет списка задач"

let mine_refs value = List.map (fun item -> text_field "ref" item) (mine_items value)

let mine_call ?cursor ?(limit = 50) () =
  let target =
    Printf.sprintf "/api/v1/tasks/mine?limit=%d%s" limit
      (match cursor with None -> "" | Some c -> "&cursor=" ^ c)
  in
  let code, text = call ~actor:(Some "api-legist") target in
  (code, json text)

let index_of item items =
  let rec go i = function
    | [] -> None
    | x :: rest -> if x = item then Some i else go (i + 1) rest
  in
  go 0 items

(** «Мои» — это исполнитель из заголовка актора, а не то, что попросил клиент:
    подставив чужой логин в запрос, клиент запросил бы чужие задачи. *)
let test_mine_returns_only_own_tasks () =
  let _, own =
    create_mine_task ~source_ref:"api-mine-own" ~assignee:"api-legist" ()
  in
  let _, foreign =
    create_mine_task ~source_ref:"api-mine-foreign" ~assignee:"api-petr" ()
  in
  let code, value = mine_call () in
  Alcotest.(check int) "код ответа" 200 code;
  let refs = mine_refs value in
  Alcotest.(check bool) "моя задача в списке" true (List.mem (task_ref own) refs);
  Alcotest.(check bool) "чужая задача не в списке" false
    (List.mem (task_ref foreign) refs)

(** Порядок главного запроса: сначала просроченные, потом срок в ближайшие
    сутки, потом остальные, и только потом без срока (§6.1).

    Задачи заводятся в обратном порядке срочности — иначе порядок «по
    давности» совпал бы с правильным и ничего не проверял. *)
let test_mine_orders_by_urgency () =
  let _, nodue =
    create_mine_task ~source_ref:"api-mine-nodue" ~assignee:"api-legist" ()
  in
  let _, later =
    create_mine_task ~source_ref:"api-mine-later" ~assignee:"api-legist"
      ~due_at:(in_hours 240) ()
  in
  let _, today =
    create_mine_task ~source_ref:"api-mine-today" ~assignee:"api-legist"
      ~due_at:(in_hours 2) ()
  in
  let _, overdue =
    create_mine_task ~source_ref:"api-mine-overdue" ~assignee:"api-legist"
      ~due_at:(in_hours (-48)) ()
  in
  let code, value = mine_call () in
  Alcotest.(check int) "код ответа" 200 code;
  let refs = mine_refs value in
  let position ref_ =
    match index_of ref_ refs with
    | Some i -> i
    | None -> Alcotest.fail ("задачи " ^ ref_ ^ " нет в главном запросе")
  in
  let overdue_at = position (task_ref overdue) in
  let today_at = position (task_ref today) in
  let later_at = position (task_ref later) in
  let nodue_at = position (task_ref nodue) in
  Alcotest.(check bool) "просроченная раньше сегодняшней" true (overdue_at < today_at);
  Alcotest.(check bool) "сегодняшняя раньше поздней" true (today_at < later_at);
  Alcotest.(check bool) "поздняя раньше безсрочной" true (later_at < nodue_at)

(** Закрытое не значит «моё»: ни закрытое при создании, ни принятое задачей
    не попадают в главный запрос. *)
let test_mine_excludes_closed_tasks () =
  let _, done_task =
    create_mine_task ~source_ref:"api-mine-done" ~assignee:"api-legist" ~status:"done" ()
  in
  let _, review =
    create_mine_task ~source_ref:"api-mine-review" ~assignee:"api-legist"
      ~status:"in_review" ()
  in
  let code, _ = transition "api-petr" (task_ref review) "done" 1 in
  Alcotest.(check int) "приёмка удалась" 200 code;
  let code, value = mine_call () in
  Alcotest.(check int) "код ответа" 200 code;
  let refs = mine_refs value in
  Alcotest.(check bool) "закрытая при создании не в списке" false
    (List.mem (task_ref done_task) refs);
  Alcotest.(check bool) "принятая задача не в списке" false
    (List.mem (task_ref review) refs)

(** Курсорная пагинация: обход страниц возвращает каждую задачу ровно один
    раз — ни потерянных строк, ни повторов. *)
let walk_mine () =
  let rec go cursor seen count =
    if count > 200 then Alcotest.fail "обход страниц не завершился"
    else
      let code, value = mine_call ?cursor ~limit:1 () in
      Alcotest.(check int) "код ответа" 200 code;
      let refs = mine_refs value in
      let seen = List.fold_left (fun acc r -> if List.mem r acc then acc else r :: acc) seen refs in
      match field "next_cursor" value with
      | Some (`String cursor) when cursor <> "" -> go (Some cursor) seen (count + 1)
      | _ -> List.rev seen
  in
  go None [] 0

let test_mine_pagination_keeps_rows () =
  let _, first =
    create_mine_task ~source_ref:"api-mine-page-1" ~assignee:"api-legist"
      ~due_at:(in_hours 3) ()
  in
  let _, second =
    create_mine_task ~source_ref:"api-mine-page-2" ~assignee:"api-legist"
      ~due_at:(in_hours 5) ()
  in
  let seen = walk_mine () in
  Alcotest.(check bool) "первая задача пришла" true (List.mem (task_ref first) seen);
  Alcotest.(check bool) "вторая задача пришла" true (List.mem (task_ref second) seen);
  let repeated =
    List.filter
      (fun ref_ -> List.length (List.filter (fun x -> x = ref_) seen) > 1)
      seen
  in
  Alcotest.(check (list string)) "повторов нет" [] repeated

(** Неверный курсор — не ошибка запроса: клиент с испорченным курсором
    получает первую страницу, а не 400. *)
let test_mine_ignores_broken_cursor () =
  let code, value = mine_call ~cursor:"not-a-uuid" () in
  Alcotest.(check int) "код ответа" 200 code;
  Alcotest.(check bool) "список не пуст" true (List.length (mine_items value) > 0)

let test_mine_without_actor_is_unauthorized () =
  let code, text = call "/api/v1/tasks/mine" in
  Alcotest.(check int) "код ответа" 401 code;
  Alcotest.(check string) "код ошибки" "unauthorized" (error_code (json text))

(* ------------------------------------------------------- заявка и отпуск --- *)

(** Заявка: взять задачу в работу. Тело — версия: без неё два претендента
    записали бы свои изменения по очереди, и второй затёр бы первого. *)
let claim actor ref_ version =
  call ~method_:`POST ~actor:(Some actor)
    ~body:(Yojson.Safe.to_string (`Assoc [ ("version", `Int version) ]))
    (Printf.sprintf "/api/v1/tasks/%s/claim" ref_)

(** Отпуск: вернуть задачу в пул. *)
let release actor ref_ version =
  call ~method_:`POST ~actor:(Some actor)
    ~body:(Yojson.Safe.to_string (`Assoc [ ("version", `Int version) ]))
    (Printf.sprintf "/api/v1/tasks/%s/release" ref_)

(** Задача для заявки: свой [source_ref] — по нему её узнают в ответе. *)
let create_claim_task ~source_ref ?assignee () =
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(create_body ~status:"todo" ~source_ref ?assignee ())
      "/api/v1/tasks"
  in
  (code, json text)

(** Свободную задачу агент забирает себе: заявка — это и есть назначение
    себе, если задача ещё ни за кем не закреплена. *)
let test_claim_takes_free_task () =
  let _, created = create_claim_task ~source_ref:"api-claim-free" () in
  let ref_ = task_ref created in
  let code, text = claim "api-legist" ref_ 1 in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  Alcotest.(check string) "статус" "in_progress" (task_status value);
  Alcotest.(check string) "исполнитель" "legist"
    (text_field "assignee" (task_of value));
  Alcotest.(check bool) "исполнитель записан" true
    (text_field "assignee_id" (task_of value) <> "")

(** Назначенную задачу чужой агент не отнимает: правило претендента. *)
let test_claim_refuses_task_of_other () =
  let _, created =
    create_claim_task ~source_ref:"api-claim-assigned" ~assignee:"api-other" ()
  in
  let ref_ = task_ref created in
  let code, text = claim "api-legist" ref_ 1 in
  Alcotest.(check int) "код ответа" 403 code;
  Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text))

(** Повторная заявка — конфликт, а не запрет: задача уже в работе, её
    состояние можно перечитать и повторить. *)
let test_second_claim_is_conflict () =
  let _, created = create_claim_task ~source_ref:"api-claim-twice" () in
  let ref_ = task_ref created in
  let code, _ = claim "api-legist" ref_ 1 in
  Alcotest.(check int) "первая заявка удалась" 200 code;
  let code, text = claim "api-legist" ref_ 2 in
  Alcotest.(check int) "код ответа" 409 code;
  Alcotest.(check string) "код ошибки" "conflict" (error_code (json text))

(** Без версии заявка невозможна: блокировка обязательна. *)
let test_claim_without_version_is_bad_request () =
  let _, created = create_claim_task ~source_ref:"api-claim-noversion" () in
  let ref_ = task_ref created in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-legist") ~body:"{}"
      (Printf.sprintf "/api/v1/tasks/%s/claim" ref_)
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Отпуск возвращает задачу в пул: статус — снова todo, исполнитель снят. *)
let test_release_returns_task_to_pool () =
  let _, created = create_claim_task ~source_ref:"api-release-own" () in
  let ref_ = task_ref created in
  let code, _ = claim "api-legist" ref_ 1 in
  Alcotest.(check int) "заявка удалась" 200 code;
  let code, text = release "api-legist" ref_ 2 in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  Alcotest.(check string) "статус" "todo" (task_status value);
  Alcotest.(check bool) "исполнитель снят" true
    (text_field "assignee_id" (task_of value) = "")

(** Посторонний агент чужую работу отпустить не может. *)
let test_other_agent_cannot_release () =
  let _, created = create_claim_task ~source_ref:"api-release-stranger" () in
  let ref_ = task_ref created in
  let code, _ = claim "api-legist" ref_ 1 in
  Alcotest.(check int) "заявка удалась" 200 code;
  let code, text = release "api-legist2" ref_ 2 in
  Alcotest.(check int) "код ответа" 403 code;
  Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text))

(** Человек отпустить может: работа застряла — человек её снимает. *)
let test_human_can_release () =
  let _, created = create_claim_task ~source_ref:"api-release-human" () in
  let ref_ = task_ref created in
  let code, _ = claim "api-legist" ref_ 1 in
  Alcotest.(check int) "заявка удалась" 200 code;
  let code, text = release "api-petr" ref_ 2 in
  Alcotest.(check int) "код ответа" 200 code;
  Alcotest.(check string) "статус" "todo" (task_status (json text))

(* ------------------------------------------------- иерархия и связи --- *)

(** Связь между задачами: тело — ссылка другой задачи и вид связи.

    Версии нет: связь — отдельная сущность со своим идентификатором, версия
    задачи её не касается. *)
let link_body ~to_ref ~kind =
  Yojson.Safe.to_string
    (`Assoc [ ("to", `String to_ref); ("kind", `String kind) ])

let link actor ref_ ~to_ref ~kind =
  call ~method_:`POST ~actor:(Some actor)
    ~body:(link_body ~to_ref ~kind)
    (Printf.sprintf "/api/v1/tasks/%s/links" ref_)

let unlink actor ref_ link_id =
  call ~method_:`DELETE ~actor:(Some actor)
    (Printf.sprintf "/api/v1/tasks/%s/links/%s" ref_ link_id)

(** Смена родителя: [parent] — ссылка родителя, [None] — отвязать. *)
let set_parent actor ref_ parent version =
  let parent = match parent with Some ref_ -> `String ref_ | None -> `Null in
  call ~method_:`POST ~actor:(Some actor)
    ~body:
      (Yojson.Safe.to_string
         (`Assoc [ ("parent", parent); ("version", `Int version) ]))
    (Printf.sprintf "/api/v1/tasks/%s/parent" ref_)

(** Карточка задачи со всем, что её касается. *)
let card ref_ =
  let code, text =
    call ~actor:(Some "api-petr") (Printf.sprintf "/api/v1/tasks/%s" ref_)
  in
  (code, json text)

(** Задача для проверки связей: свой [source_ref] — по нему её узнают. *)
let create_link_task ~source_ref ?parent () =
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(create_body ~source_ref ?parent ())
      "/api/v1/tasks"
  in
  (code, json text)

(** Связь записана: у неё свой идентификатор, и она видна в карточке. *)
let test_link_is_created () =
  let _, from_ = create_link_task ~source_ref:"api-link-from" () in
  let _, to_ = create_link_task ~source_ref:"api-link-to" () in
  let from_ref = task_ref from_ in
  let to_ref = task_ref to_ in
  let code, text = link "api-petr" from_ref ~to_ref ~kind:"blocks" in
  Alcotest.(check int) "код ответа" 201 code;
  let value = json text in
  let created = match field "link" value with Some l -> l | None -> `Null in
  Alcotest.(check string) "вид" "blocks" (text_field "kind" created);
  Alcotest.(check bool) "связь получила свой id" true
    (text_field "id" created <> "");
  (* Связь видна с обеих сторон: отношение читается одинаково. *)
  let _, from_card = card from_ref in
  let _, to_card = card to_ref in
  Alcotest.(check int) "связей у источника" 1
    (List.length (list_field "links" from_card));
  Alcotest.(check int) "связей у цели" 1
    (List.length (list_field "links" to_card))

(** Неизвестный вид связи — ошибка запроса: клиент перепутал имя. *)
let test_link_unknown_kind_is_bad_request () =
  let _, from_ = create_link_task ~source_ref:"api-link-badkind" () in
  let _, to_ = create_link_task ~source_ref:"api-link-badkind-to" () in
  let code, text =
    link "api-petr" (task_ref from_) ~to_ref:(task_ref to_) ~kind:"мешает"
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Без адресата связь не о чем: 400, а не пустая связь. *)
let test_link_without_target_is_bad_request () =
  let _, from_ = create_link_task ~source_ref:"api-link-noto" () in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(Yojson.Safe.to_string (`Assoc [ ("kind", `String "blocks") ]))
      (Printf.sprintf "/api/v1/tasks/%s/links" (task_ref from_))
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Связь задачи с собой бессмысленна — 400. *)
let test_link_to_self_is_bad_request () =
  let _, task = create_link_task ~source_ref:"api-link-self" () in
  let ref_ = task_ref task in
  let code, text = link "api-petr" ref_ ~to_ref:ref_ ~kind:"relates_to" in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Повторная связь — конфликт: тот же факт уже записан. *)
let test_duplicate_link_is_conflict () =
  let _, from_ = create_link_task ~source_ref:"api-link-twice" () in
  let _, to_ = create_link_task ~source_ref:"api-link-twice-to" () in
  let from_ref = task_ref from_ in
  let to_ref = task_ref to_ in
  let code, _ = link "api-petr" from_ref ~to_ref ~kind:"relates_to" in
  Alcotest.(check int) "первая связь удалась" 201 code;
  let code, text = link "api-petr" from_ref ~to_ref ~kind:"relates_to" in
  Alcotest.(check int) "код ответа" 409 code;
  Alcotest.(check string) "код ошибки" "conflict" (error_code (json text))

(** Снятие связи убирает её из графа; задачи остаются на месте. *)
let test_unlink_removes_link () =
  let _, from_ = create_link_task ~source_ref:"api-unlink" () in
  let _, to_ = create_link_task ~source_ref:"api-unlink-to" () in
  let from_ref = task_ref from_ in
  let to_ref = task_ref to_ in
  let _, text = link "api-petr" from_ref ~to_ref ~kind:"relates_to" in
  let link_id =
    match field "link" (json text) with
    | Some l -> text_field "id" l
    | None -> ""
  in
  let code, text = unlink "api-petr" from_ref link_id in
  Alcotest.(check int) "код ответа" 200 code;
  Alcotest.(check bool) "связь снята" true
    (bool_field "removed" (json text));
  let _, card_value = card from_ref in
  Alcotest.(check int) "связей не осталось" 0
    (List.length (list_field "links" card_value))

(** Снять чужую связь из чужой задачи — 404: это не то действие. *)
let test_unlink_of_foreign_link_is_not_found () =
  let _, owner = create_link_task ~source_ref:"api-unlink-owner" () in
  let _, other = create_link_task ~source_ref:"api-unlink-other" () in
  let _, target = create_link_task ~source_ref:"api-unlink-target" () in
  let _, text =
    link "api-petr" (task_ref owner) ~to_ref:(task_ref target) ~kind:"relates_to"
  in
  let link_id =
    match field "link" (json text) with
    | Some l -> text_field "id" l
    | None -> ""
  in
  let code, text = unlink "api-petr" (task_ref other) link_id in
  Alcotest.(check int) "код ответа" 404 code;
  Alcotest.(check string) "код ошибки" "not_found" (error_code (json text))

(** Родитель задаётся при создании: ребёнок сразу попадает в ветку. *)
let test_create_with_parent () =
  let _, parent = create_link_task ~source_ref:"api-tree-parent" () in
  let parent_ref = task_ref parent in
  let code, child =
    create_link_task ~source_ref:"api-tree-child" ~parent:parent_ref ()
  in
  Alcotest.(check int) "код ответа" 201 code;
  Alcotest.(check bool) "родитель записан" true
    (text_field "parent_id" (task_of child) <> "");
  let _, parent_card = card parent_ref in
  Alcotest.(check int) "у родителя один ребёнок" 1
    (List.length (list_field "children" parent_card))

(** Смена родителя переносит задачу в другую ветку. *)
let test_set_parent_moves_task () =
  let _, first = create_link_task ~source_ref:"api-move-first" () in
  let _, second = create_link_task ~source_ref:"api-move-second" () in
  let first_ref = task_ref first in
  let second_ref = task_ref second in
  let code, text = set_parent "api-petr" first_ref (Some second_ref) 1 in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  Alcotest.(check bool) "родитель записан" true
    (text_field "parent_id" (task_of value) <> "");
  let _, card_value = card second_ref in
  Alcotest.(check int) "у нового родителя один ребёнок" 1
    (List.length (list_field "children" card_value));
  let _, old_card = card first_ref in
  Alcotest.(check int) "у прежнего родителя детей нет" 0
    (List.length (list_field "children" old_card))

(** Отвязка: [parent] = null — ребёнок снова сам по себе. *)
let test_set_parent_null_detaches () =
  let _, parent = create_link_task ~source_ref:"api-detach-parent" () in
  let parent_ref = task_ref parent in
  let _, child =
    create_link_task ~source_ref:"api-detach-child" ~parent:parent_ref ()
  in
  let child_ref = task_ref child in
  let code, text = set_parent "api-petr" child_ref None 1 in
  Alcotest.(check int) "код ответа" 200 code;
  Alcotest.(check string) "родителя нет" ""
    (text_field "parent_id" (task_of (json text)));
  let _, parent_card = card parent_ref in
  Alcotest.(check int) "у родителя детей нет" 0
    (List.length (list_field "children" parent_card))

(** Версия обязательна: смена родителя меняет задачу, а значит ломает её
    оптимистичную блокировку. Родитель здесь — другая задача: иначе отказ
    пришёл бы от запрета самородителя и тест прошёл бы по неверной причине. *)
let test_set_parent_without_version_is_bad_request () =
  let _, task = create_link_task ~source_ref:"api-parent-noversion" () in
  let _, parent = create_link_task ~source_ref:"api-parent-noversion-to" () in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:
        (Yojson.Safe.to_string
           (`Assoc [ ("parent", `String (task_ref parent)) ]))
      (Printf.sprintf "/api/v1/tasks/%s/parent" (task_ref task))
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(** Родителем нельзя назначить собственного потомка: дерево замкнулось бы
    в кольцо. *)
let test_set_parent_cycle_is_bad_request () =
  let _, parent = create_link_task ~source_ref:"api-cycle-parent" () in
  let parent_ref = task_ref parent in
  let _, child =
    create_link_task ~source_ref:"api-cycle-child" ~parent:parent_ref ()
  in
  let code, text = set_parent "api-petr" parent_ref (Some (task_ref child)) 1 in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

(* --------------------------------------------------- разрешение имён --- *)

let resolve_body ?namespace raw =
  let fields =
    [ ("raw", `String raw) ]
    @ (match namespace with
      | None -> []
      | Some value -> [ ("namespace", `String value) ])
  in
  Yojson.Safe.to_string (`Assoc fields)

let resolve ?namespace ?actor raw =
  call ~method_:`POST ?actor ~body:(resolve_body ?namespace raw)
    "/api/v1/actors/resolve"

let test_resolve_finds_actor_by_handle () =
  let code, text = resolve ~actor:(Some "api-petr") "api-resolver" in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  Alcotest.(check bool) "разрешено" true (bool_field "resolved" value);
  Alcotest.(check string) "актёр" "api-resolver"
    (text_field "handle" (actor_of value));
  Alcotest.(check bool) "не заглушка" false
    (bool_field "unresolved" (actor_of value))

let test_resolve_finds_actor_by_display_name () =
  let code, text = resolve ~actor:(Some "api-petr") "api-тестовый" in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  Alcotest.(check bool) "разрешено" true (bool_field "resolved" value);
  Alcotest.(check string) "актёр" "api-resolver"
    (text_field "handle" (actor_of value))

let test_resolve_unknown_name_creates_placeholder () =
  (* Имя не теряется: сервер отвечает заглушкой, а не ошибкой (§3.1). *)
  let code, text = resolve ~actor:(Some "api-petr") "api-незнакомец" in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  Alcotest.(check bool) "не разрешено" false (bool_field "resolved" value);
  Alcotest.(check string) "вид — заглушка" "placeholder"
    (text_field "kind" (actor_of value));
  Alcotest.(check bool) "помечена как неразрешённая" true
    (bool_field "unresolved" (actor_of value));
  Alcotest.(check string) "исходное имя" "api-незнакомец" (text_field "raw" value)

let test_resolve_empty_name_is_bad_request () =
  let code, text = resolve ~actor:(Some "api-petr") "" in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

let test_resolve_without_raw_is_bad_request () =
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr") ~body:"{}"
      "/api/v1/actors/resolve"
  in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code (json text))

let test_resolve_without_actor_is_unauthorized () =
  let code, text = call ~method_:`POST ~body:(resolve_body "api-resolver") "/api/v1/actors/resolve" in
  Alcotest.(check int) "код ответа" 401 code;
  Alcotest.(check string) "код ошибки" "unauthorized" (error_code (json text))

(* ------------------------------------------------------------------- сводка --- *)

(** Сводка — ресурс про трекер целиком: актёр нужен, чтобы знать, чьими
    глазами смотреть, но правил доступа у неё нет. *)
let overview ?(actor = Some "api-petr") target =
  let code, text = call ~actor target in
  (code, json text)

let test_overview_without_actor_is_unauthorized () =
  let code, body = overview ~actor:None "/api/v1/overview" in
  Alcotest.(check int) "код ответа" 401 code;
  Alcotest.(check string) "код ошибки" "unauthorized" (error_code body)

let test_overview_has_contract_shape () =
  let code, body = overview "/api/v1/overview" in
  Alcotest.(check int) "код ответа" 200 code;
  List.iter
    (fun name ->
      Alcotest.(check bool) ("поле " ^ name) true (field name body <> None))
    [
      "generated_at";
      "stuck_days";
      "limit";
      "totals";
      "wip_by_actor";
      "by_project";
      "stuck";
      "needs_input";
    ];
  let totals = match field "totals" body with Some t -> t | None -> `Null in
  List.iter
    (fun name ->
      Alcotest.(check bool) ("счётчик " ^ name) true (field name totals <> None))
    [
      "open_tasks";
      "in_progress";
      "blocked";
      "needs_input";
      "unassigned";
      "without_project";
    ]

let test_overview_echoes_parameters () =
  let code, body = overview "/api/v1/overview?stuck_days=3&limit=5" in
  Alcotest.(check int) "код ответа" 200 code;
  Alcotest.(check int) "порог застоя" 3 (int_field "stuck_days" body);
  Alcotest.(check int) "предел" 5 (int_field "limit" body)

let test_overview_unparsable_parameter_is_bad_request () =
  let code, body = overview "/api/v1/overview?stuck_days=abc" in
  Alcotest.(check int) "код ответа" 400 code;
  Alcotest.(check string) "код ошибки" "bad_request" (error_code body)

let test_overview_rejects_out_of_range_parameters () =
  let cases =
    [
      "/api/v1/overview?stuck_days=0";
      "/api/v1/overview?limit=0";
      "/api/v1/overview?limit=1000";
    ]
  in
  List.iter
    (fun target ->
      let code, body = overview target in
      Alcotest.(check int) ("код ответа для " ^ target) 400 code;
      Alcotest.(check string) "код ошибки" "bad_request" (error_code body))
    cases

let test_overview_shows_actor_load () =
  (* Задача с исполнитетелем обязана появиться в нагрузке этого человека:
     иначе сводка отвечает не на тот вопрос. *)
  let code, _ =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:
        (create_body ~status:"todo" ~source_ref:"overview-load"
           ~assignee:"api-legist" ())
      "/api/v1/tasks"
  in
  Alcotest.(check int) "задача создана" 201 code;
  let code, body = overview ~actor:(Some "api-legist") "/api/v1/overview" in
  Alcotest.(check int) "код ответа" 200 code;
  let load =
    List.find_opt
      (fun w -> text_field "handle" w = "api-legist")
      (list_field "wip_by_actor" body)
  in
  match load with
  | None -> Alcotest.fail "исполнитель не попал в нагрузку"
  | Some w ->
      Alcotest.(check bool) "есть открытые задачи" true
        (int_field "open_tasks" w >= 1)

(* ---------------------------------------------------------------- токены --- *)

(* Выпуск учётки на уровне сервиса: для HTTP-тестов нужен живой токен,
   а сам выпуск и его свойства проверяет Service.Credential отдельно. *)
let issue_token_for actor_id title =
  match
    Support.run
      (Service.Credential.issue conn ~actor_id ~title ~created_by_id:actor_id ())
  with
  | Ok (cred, token) -> (cred, token)
  | Error failure ->
      failwith ("токен не выдан: " ^ Service.Failure.to_string failure)

(* Ссылки задач из тела списка: для приоритета bearer над заголовком. *)
let items_refs text =
  match field "items" (json text) with
  | Some (`List items) ->
      List.filter_map
        (fun item ->
          match field "ref" item with
          | Some (`String ref_) -> Some ref_
          | _ -> None)
        items
  | _ -> []

let test_bearer_authenticates () =
  let _, token = issue_token_for agent.Actor.id "ключ для списка" in
  let code, _ = call ~bearer:(Some token) "/api/v1/tasks" in
  Alcotest.(check int) "запрос с bearer — 200" 200 code

let test_credentials_routes () =
  let _, token = issue_token_for agent.Actor.id "ключ учёток" in
  let code, text =
    call ~method_:`POST ~bearer:(Some token)
      ~body:(Yojson.Safe.to_string (`Assoc [ ("title", `String "ключ из HTTP") ]))
      "/api/v1/credentials"
  in
  Alcotest.(check int) "выпуск по маршруту — 201" 201 code;
  Alcotest.(check bool) "токен приходит только в ответе выпуска" true
    (match field "token" (json text) with
    | Some (`String t) -> String.starts_with ~prefix:"dsk_" t
    | _ -> false);
  let code, text = call ~bearer:(Some token) "/api/v1/credentials" in
  Alcotest.(check int) "список учёток — 200" 200 code;
  (match json text with
  | `List items ->
      Alcotest.(check bool) "обе учётки актора в списке" true
        (List.length items >= 2);
      Alcotest.(check bool) "в списке нет открытых токенов" true
        (List.for_all
           (fun item -> field "token" item = None)
           items)
  | _ -> Alcotest.fail "список учёток — не массив")

let test_revoked_bearer_is_unauthorized () =
  let cred, token = issue_token_for agent.Actor.id "ключ на отзыв" in
  let code, _ = call ~bearer:(Some token) "/api/v1/tasks" in
  Alcotest.(check int) "живой токен — 200" 200 code;
  (match
     Support.run
       (Service.Credential.revoke conn ~id:cred.id ~by_actor_id:agent.Actor.id
          ~admin:false)
   with
  | Ok () -> ()
  | Error failure -> Alcotest.fail ("отзыв не прошёл: " ^ Service.Failure.to_string failure));
  let code, _ = call ~bearer:(Some token) "/api/v1/tasks" in
  Alcotest.(check int) "отозванный токен — 401" 401 code

let test_forged_bearer_is_unauthorized () =
  let code, _ = call ~bearer:(Some ("dsk_" ^ String.make 64 'a')) "/api/v1/tasks" in
  Alcotest.(check int) "выдуманный токен — 401" 401 code

let test_bearer_wins_over_legacy_header () =
  (* Оба заголовка сразу: bearer агента и запасной заголовок Петра.
     «Мои» обязаны показать задачи агента — иначе запасной путь
     подменял бы личность при живом токене. *)
  let _, agent_token = issue_token_for agent.Actor.id "ключ приоритета" in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:
        (create_body ~assignee:"api-legist" ~source_ref:"bearer-agent" ())
      "/api/v1/tasks"
  in
  Alcotest.(check int) "задача агенту создана" 201 code;
  let agent_ref = task_ref (json text) in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(create_body ~assignee:"api-petr" ~source_ref:"bearer-petr" ())
      "/api/v1/tasks"
  in
  Alcotest.(check int) "задача Петру создана" 201 code;
  let petr_ref = task_ref (json text) in
  let code, text =
    call ~bearer:(Some agent_token) ~actor:(Some "api-petr") "/api/v1/tasks/mine"
  in
  Alcotest.(check int) "«мои» с bearer — 200" 200 code;
  let refs = items_refs text in
  Alcotest.(check bool) "видна задача агента" true
    (List.mem agent_ref refs);
  Alcotest.(check bool) "задача Петра не подменяет личность" true
    (not (List.mem petr_ref refs))

(* --------------------------------------------------------------------- run --- *)


(* --------------------------------------------------------------- проекты --- *)

(** Проекты: список и создание. Ключ уникален, неверный ключ — 400, повтор
    ключа — конфликт, а не сбой. *)
let test_projects_list_and_create () =
  (* Ключ уникален в пределах секунды: прогоны подряд не должны
     столкнуться на одном проекте. *)
  let key =
    Printf.sprintf "prj%d%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday ()))
  in
  let code, text =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(Yojson.Safe.to_string (`Assoc [ ("key", `String key); ("name", `String "Проект доськи") ]))
      "/api/v1/projects"
  in
  Alcotest.(check int) "создание проекта — 201" 201 code;
  let created = json text in
  Alcotest.(check string) "ключ проекта" key (text_field "key" created);
  Alcotest.(check string) "режим приёмки по умолчанию" "human_gate"
    (text_field "autonomy" created);
  let code, text = call ~actor:(Some "api-petr") "/api/v1/projects" in
  Alcotest.(check int) "список проектов — 200" 200 code;
  let keys =
    match json text with
    | `List items ->
        List.filter_map
          (fun item -> match field "key" item with Some (`String k) -> Some k | _ -> None)
          items
    | _ -> []
  in
  Alcotest.(check bool) "созданный проект в списке" true (List.mem key keys)

let test_project_key_is_validated () =
  let code, _ =
    call ~method_:`POST ~actor:(Some "api-petr")
      ~body:(Yojson.Safe.to_string (`Assoc [ ("key", `String "Плохой Ключ") ]))
      "/api/v1/projects"
  in
  Alcotest.(check int) "неверный ключ — 400" 400 code

let test_project_key_is_unique () =
  let key =
    Printf.sprintf "dup%d%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday ()))
  in
  let body = Yojson.Safe.to_string (`Assoc [ ("key", `String key) ]) in
  let code, _ =
    call ~method_:`POST ~actor:(Some "api-petr") ~body "/api/v1/projects"
  in
  Alcotest.(check int) "первое создание — 201" 201 code;
  let code, _ =
    call ~method_:`POST ~actor:(Some "api-petr") ~body "/api/v1/projects"
  in
  Alcotest.(check int) "повтор ключа — 409" 409 code

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
      ( "вопрос и ответ",
        [
          Alcotest.test_case "вопрос попадает в карточку" `Quick
            test_question_is_stored_in_card;
          Alcotest.test_case "без версии — 400" `Quick
            test_question_without_version_is_bad_request;
          Alcotest.test_case "неизвестная задача — 404" `Quick
            test_question_of_unknown_task_is_not_found;
          Alcotest.test_case "адресат-нечеловек — 400" `Quick
            test_addressee_must_be_human;
          Alcotest.test_case "неизвестный адресат — 400" `Quick
            test_unknown_addressee_is_bad_request;
          Alcotest.test_case "выход без ответа — 403" `Quick
            test_answer_is_required_to_leave_needs_input;
        ] );
      ( "списки и карточки",
        [
          Alcotest.test_case "список пагинирован" `Quick test_list_is_paginated;
          Alcotest.test_case "повторное создание не плодит дубль" `Quick
            test_create_is_idempotent;
          Alcotest.test_case "карточка содержит комментарии и доказательства" `Quick
            test_task_card_has_comments_and_evidence;
        ] );
      ( "токены",
        [
          Alcotest.test_case "bearer опознаёт актора" `Quick
            test_bearer_authenticates;
          Alcotest.test_case "маршруты учёток работают" `Quick
            test_credentials_routes;
          Alcotest.test_case "отзыв гасит доступ" `Quick
            test_revoked_bearer_is_unauthorized;
          Alcotest.test_case "выдуманный токен — 401" `Quick
            test_forged_bearer_is_unauthorized;
          Alcotest.test_case "bearer важнее запасного заголовка" `Quick
            test_bearer_wins_over_legacy_header;
        ] );
      ( "проекты",
        [
          Alcotest.test_case "список и создание" `Quick
            test_projects_list_and_create;
          Alcotest.test_case "неверный ключ — 400" `Quick
            test_project_key_is_validated;
          Alcotest.test_case "повтор ключа — 409" `Quick
            test_project_key_is_unique;
        ] );
      ( "назначение",
        [
          Alcotest.test_case "агент не назначает задачу другому" `Quick
            test_agent_cannot_assign_to_another;
          Alcotest.test_case "человек назначает задачу" `Quick test_human_can_assign;
        ] );
      ( "главный запрос",
        [
          Alcotest.test_case "мои задачи — только мои" `Quick
            test_mine_returns_only_own_tasks;
          Alcotest.test_case "порядок — по срочности" `Quick
            test_mine_orders_by_urgency;
          Alcotest.test_case "закрытые не попадают" `Quick
            test_mine_excludes_closed_tasks;
          Alcotest.test_case "пагинация не теряет и не повторяет" `Quick
            test_mine_pagination_keeps_rows;
          Alcotest.test_case "испорченный курсор — не ошибка" `Quick
            test_mine_ignores_broken_cursor;
          Alcotest.test_case "без актора — 401" `Quick
            test_mine_without_actor_is_unauthorized;
        ] );
      ( "заявка и отпуск",
        [
          Alcotest.test_case "свободную задачу агент берёт себе" `Quick
            test_claim_takes_free_task;
          Alcotest.test_case "назначенную задачу не отнимает" `Quick
            test_claim_refuses_task_of_other;
          Alcotest.test_case "повторная заявка — конфликт" `Quick
            test_second_claim_is_conflict;
          Alcotest.test_case "без версии — 400" `Quick
            test_claim_without_version_is_bad_request;
          Alcotest.test_case "отпуск возвращает в пул" `Quick
            test_release_returns_task_to_pool;
          Alcotest.test_case "посторонний агент не отпускает" `Quick
            test_other_agent_cannot_release;
          Alcotest.test_case "человек отпускает" `Quick test_human_can_release;
        ] );
      ( "иерархия и связи",
        [
          Alcotest.test_case "связь записана" `Quick test_link_is_created;
          Alcotest.test_case "неизвестный вид связи — 400" `Quick
            test_link_unknown_kind_is_bad_request;
          Alcotest.test_case "без адресата — 400" `Quick
            test_link_without_target_is_bad_request;
          Alcotest.test_case "связь с собой — 400" `Quick
            test_link_to_self_is_bad_request;
          Alcotest.test_case "повторная связь — конфликт" `Quick
            test_duplicate_link_is_conflict;
          Alcotest.test_case "снятие связи убирает её" `Quick
            test_unlink_removes_link;
          Alcotest.test_case "чужая связь — 404" `Quick
            test_unlink_of_foreign_link_is_not_found;
          Alcotest.test_case "родитель задаётся при создании" `Quick
            test_create_with_parent;
          Alcotest.test_case "смена родителя переносит задачу" `Quick
            test_set_parent_moves_task;
          Alcotest.test_case "null отвязывает" `Quick
            test_set_parent_null_detaches;
          Alcotest.test_case "без версии — 400" `Quick
            test_set_parent_without_version_is_bad_request;
          Alcotest.test_case "цикл по родителю — 400" `Quick
            test_set_parent_cycle_is_bad_request;
        ] );
      ( "разрешение имён",
        [
          Alcotest.test_case "по логину" `Quick test_resolve_finds_actor_by_handle;
          Alcotest.test_case "по отображаемому имени" `Quick
            test_resolve_finds_actor_by_display_name;
          Alcotest.test_case "неизвестное имя — заглушка" `Quick
            test_resolve_unknown_name_creates_placeholder;
          Alcotest.test_case "пустое имя — 400" `Quick
            test_resolve_empty_name_is_bad_request;
          Alcotest.test_case "без raw — 400" `Quick
            test_resolve_without_raw_is_bad_request;
          Alcotest.test_case "без актора — 401" `Quick
            test_resolve_without_actor_is_unauthorized;
        ] );
      ( "сводка",
        [
          Alcotest.test_case "без актора — 401" `Quick
            test_overview_without_actor_is_unauthorized;
          Alcotest.test_case "форма ответа" `Quick test_overview_has_contract_shape;
          Alcotest.test_case "параметры возвращаются эхом" `Quick
            test_overview_echoes_parameters;
          Alcotest.test_case "неразобранный параметр — 400" `Quick
            test_overview_unparsable_parameter_is_bad_request;
          Alcotest.test_case "параметры вне диапазона — 400" `Quick
            test_overview_rejects_out_of_range_parameters;
          Alcotest.test_case "нагрузка по исполнителю" `Quick
            test_overview_shows_actor_load;
        ] );
    ];
  ignore requester;
  ignore agent;
  ignore stranger;
  ignore other_agent;
  ignore project;
  ignore resolvable
