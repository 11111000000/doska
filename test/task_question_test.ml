(** Вопрос при переходе задачи в needs_input.

    Инкремент «вопрос при needs_input»: задача ждёт не «кого-то», а конкретного
    человека — с текстом вопроса, адресатом и ответом. Отсюда всё, что
    проверяется: адресат явный или выведенный по цепочке, вопрос обязателен,
    ответ обязателен, отвечает только человек, история переживает смену
    статуса, а адресату уходит уведомление.

    Тест живёт на своей базе: адресат выводится по цепочке (заявитель →
    руководитель исполнителя → руководитель заявителя → администратор), и
    чужие задачи в общей базе сделали бы вывод адресата зависимым от чужой
    работы. *)

open Domain

(* ------------------------------------------------------------------- база --- *)

let test_db = "doska_question_test"

(** Тот же адрес, но с другим именем базы.

    Меняется только имя: хост, порт и пользователь приходят из окружения, и
    проверка обязана работать там, где её запускают — в том числе в CI, где
    postgres доступен по TCP, а не через unix-сокет. *)
let url_with_db base name =
  let base, query =
    match String.index_opt base '?' with
    | Some i -> (String.sub base 0 i, String.sub base i (String.length base - i))
    | None -> (base, "")
  in
  let prefix =
    match String.rindex_opt base '/' with
    | Some i -> String.sub base 0 (i + 1)
    | None -> base ^ "/"
  in
  prefix ^ name ^ query

let connect url =
  match Support.run (Db.Conn.connect ~uri:url ()) with
  | Ok conn -> conn
  | Error e -> failwith ("нет подключения к базе (" ^ url ^ "): " ^ e)

(** Имя базы — идентификатор, а не строка: кавычки добавляются руками. *)
let quote_ident name = "\"" ^ String.concat "\"\"" (String.split_on_char '"' name) ^ "\""

(** База теста создаётся, если её нет.

    В CI база одна на весь прогон, а вопросу нужна своя: иначе вывод адресата
    зависит от чужих задач, и проверка перестаёт быть проверкой. *)
let ensure_database () =
  let base = Support.database_url () in
  let target = url_with_db base test_db in
  match Support.run (Db.Conn.connect ~uri:target ()) with
  | Ok conn -> conn
  | Error _ ->
      let maintenance = connect (url_with_db base "postgres") in
      let exists =
        match
          Support.run
            (Db.Conn.query_int64s maintenance
               (Printf.sprintf "SELECT count(*) FROM pg_database WHERE datname = %s"
                  (Db.Conn.quote test_db)))
        with
        | Ok [ count ] -> count > 0L
        | Ok _ -> false
        | Error e -> failwith ("не удалось проверить наличие базы: " ^ e)
      in
      if not exists then begin
        match
          Support.run
            (Db.Conn.exec_sql maintenance
               (Printf.sprintf "CREATE DATABASE %s" (quote_ident test_db)))
        with
        | Ok () -> ()
        | Error e -> failwith ("база теста не создана: " ^ e)
      end;
      connect target

let conn = ensure_database ()
let () = Db.Conn.set_current conn
let () = ignore (Support.migrate conn)

(* Фикстуры этого теста общие с другим его прогоном: блокируемся, чтобы
   уборка одного прогона не удалила фикстуры другого. *)
let () = Support.lock conn 4717

(* Уборка — до фикстур: [Alcotest.run] завершает процесс, код после него не
   выполняется, поэтому строки прошлого прогона убираем на входе. *)
let () =
  Support.cleanup conn ~source:"test-question" ~actor_prefix:"q-"
    ~project_prefix:"Q"

(* --------------------------------------------------------------- фикстуры --- *)

(* Заявитель: он же автор задачи, он же адресат по умолчанию. *)
let petr =
  Support.ensure_actor conn ~prefix:"q-" ~kind:Actor.Human ~handle:"petr"
    ~display_name:"Пётр"

(* Исполнитель-агент. *)
let legist =
  Support.ensure_actor conn ~prefix:"q-" ~kind:Actor.Agent ~handle:"legist"
    ~display_name:"legist"

(* Посторонний человек: ни адресат, ни заявитель, ни руководитель. *)
let other =
  Support.ensure_actor conn ~prefix:"q-" ~kind:Actor.Human ~handle:"other"
    ~display_name:"Другой"

(* Руководитель исполнителя: от него выводится адресат по цепочке. *)
let chief =
  Support.ensure_actor conn ~prefix:"q-" ~kind:Actor.Human ~handle:"chief"
    ~display_name:"Начальник"

(* Администратор: последний адресат в цепочке вывода. *)
let admin =
  Support.ensure_actor conn ~prefix:"q-" ~kind:Actor.Human ~handle:"admin"
    ~display_name:"Администратор"

(* Агент без руководителя: от него адресат не выводится. *)
let solo =
  Support.ensure_actor conn ~prefix:"q-" ~kind:Actor.Agent ~handle:"solo"
    ~display_name:"solo"

let project =
  Support.ensure_project conn ~prefix:"Q" ~key:"MAIN" ~name:"Основной"
    ~autonomy:Actor.Human_gate

(** Руководитель исполнителя.

    Без этой связи цепочка вывода адресата укоротилась бы, и проверка вывода
    проходила бы вхолостую: адресатом всегда оказывался бы заявитель. *)
let set_supervisor ~of_actor ~supervisor =
  let sql =
    Printf.sprintf "UPDATE actor SET supervisor_id = %s WHERE id = %s"
      (Db.Conn.quote supervisor.Actor.id) (Db.Conn.quote of_actor.Actor.id)
  in
  match Support.run (Db.Conn.exec_sql conn sql) with
  | Ok () -> ()
  | Error e -> Alcotest.fail ("руководитель не задан: " ^ e)

let () = set_supervisor ~of_actor:legist ~supervisor:chief

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

let task_of value =
  match field "task" value with Some task -> task | None -> `Null

let task_status value = text_field "status" (task_of value)

let task_ref value = text_field "ref" (task_of value)

(* ------------------------------------------------------------------ помощники --- *)

let counter = ref 0

let next_source_ref () =
  incr counter;
  Printf.sprintf "q-%d" !counter

let create_body ?(status = "in_progress") ?assignee ?requester () =
  let fields =
    [
      ("title", `String "Задача с вопросом");
      ("description", `String "описание задачи");
      ("status", `String status);
      ("project", `String "QMAIN");
      ("source", `String "test-question");
      ("source_ref", `String (next_source_ref ()));
    ]
    @ (match assignee with
      | None -> []
      | Some handle -> [ ("assignee", `String handle) ])
    @ (match requester with
      | None -> []
      | Some handle -> [ ("requester", `String handle) ])
  in
  Yojson.Safe.to_string (`Assoc fields)

(** Задача в работе.

    [author] — кто заводит задачу: заявителем становится автор, и от него
    выводится адресат по умолчанию. *)
let create_task ?(status = "in_progress") ?(author = "q-legist") ?assignee
    ?requester () =
  let code, text =
    call ~method_:`POST ~actor:(Some author)
      ~body:(create_body ~status ?assignee ?requester ())
      "/api/v1/tasks"
  in
  if code <> 201 then
    Alcotest.fail ("задача не создана: " ^ string_of_int code ^ " " ^ text);
  json text

(** Переход по HTTP.

    [to_] — целевой статус, [version] — версия задачи, [reason] — текст
    вопроса, [asked_to] — адресат, [answer] — ответ на вопрос. *)
let transition ?reason ?asked_to ?answer actor ref_ to_ version =
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

(** Карточка задачи: что человек видит после перехода. *)
let card_of ref_ =
  let code, text = call ~actor:(Some "q-legist") (Printf.sprintf "/api/v1/tasks/%s" ref_) in
  if code <> 200 then Alcotest.fail ("карточка не прочитана: " ^ string_of_int code);
  task_of (json text)

(** Администраторы из окружения: список один на процесс.

    Тест, который проверяет отказ, обязан убрать список из вида — иначе
    проверка прошла бы вхолостую: администратор ответил бы вместо того, кому
    вопрос не достался. *)
let with_admin_handles handles run =
  let saved = Sys.getenv_opt "DOSKA_ADMIN_HANDLES" in
  let restore () =
    match saved with
    | Some value -> Unix.putenv "DOSKA_ADMIN_HANDLES" value
    | None -> Unix.putenv "DOSKA_ADMIN_HANDLES" ""
  in
  (match handles with
  | Some value -> Unix.putenv "DOSKA_ADMIN_HANDLES" value
  | None -> Unix.putenv "DOSKA_ADMIN_HANDLES" "");
  Fun.protect ~finally:restore (fun () -> run ())

(* --------------------------------------------------- проверки по базе --- *)

(** Уведомления задачи: outbox ждёт доставки, и в нём видно адресата. *)
let notifications_of ref_ =
  let sql =
    Printf.sprintf
      "SELECT row_to_json(n)::text FROM notification n \
       WHERE n.task_id = (SELECT id FROM task WHERE ref = %s) ORDER BY n.created_at, n.id"
      (Db.Conn.quote ref_)
  in
  match Support.run (Db.Conn.query_json_rows conn sql) with
  | Ok rows -> rows
  | Error e -> Alcotest.fail ("уведомления не прочитаны: " ^ e)

(** Действия журнала задачи: по ним видно, что вопрос задан и ответ получен. *)
let actions_of ref_ =
  let sql =
    Printf.sprintf
      "SELECT action::text FROM activity \
       WHERE task_id = (SELECT id FROM task WHERE ref = %s) ORDER BY id"
      (Db.Conn.quote ref_)
  in
  match Support.run (Db.Conn.query_strings conn sql) with
  | Ok rows -> rows
  | Error e -> Alcotest.fail ("журнал не прочитан: " ^ e)

(* ------------------------------------------------------------------ тесты --- *)

(** Вопрос сохраняется вместе с адресатом: карточка показывает и то, что
    спросили, и к кому. *)
let test_question_is_saved () =
  let created = create_task ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, text =
    transition ~reason:"Какой формат отчёта нужен?" ~asked_to:"q-petr" "q-legist"
      ref_ "needs_input" 1
  in
  Alcotest.(check int) "код ответа" 200 code;
  let value = json text in
  let card = task_of value in
  Alcotest.(check string) "статус" "needs_input" (task_status value);
  Alcotest.(check string) "вопрос" "Какой формат отчёта нужен?"
    (text_field "question" card);
  Alcotest.(check string) "адресат" "q-petr" (text_field "asked_to" card);
  Alcotest.(check bool) "адресат записан" true (text_field "asked_to_id" card <> "")

(** Явный адресат: handle из запроса попадает в задачу как есть. *)
let test_explicit_addressee_is_recorded () =
  let created = create_task ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, text =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-other" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "код ответа" 200 code;
  let card = task_of (json text) in
  Alcotest.(check string) "адресат" "q-other" (text_field "asked_to" card);
  Alcotest.(check string) "адресат записан тем же человеком" other.Actor.id
    (text_field "asked_to_id" card)

(** Выведенный адресат: без явного адресата вопрос уходит заявителю. *)
let test_derived_addressee_is_requester () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, text = transition ~reason:"Нужен отчёт?" "q-legist" ref_ "needs_input" 1 in
  Alcotest.(check int) "код ответа" 200 code;
  let card = task_of (json text) in
  Alcotest.(check string) "адресат — заявитель" "q-petr" (text_field "asked_to" card);
  Alcotest.(check string) "адресат записан" petr.Actor.id
    (text_field "asked_to_id" card)

(** Администратор — последний адресат в цепочке: спросить больше некого. *)
let test_admin_is_the_last_addressee () =
  with_admin_handles (Some "q-admin") (fun () ->
      let created = create_task ~author:"q-solo" ~assignee:"q-solo" () in
      let ref_ = task_ref created in
      let code, text = transition ~reason:"Нужен отчёт?" "q-solo" ref_ "needs_input" 1 in
      Alcotest.(check int) "код ответа" 200 code;
      let card = task_of (json text) in
      Alcotest.(check string) "адресат — администратор" "q-admin"
        (text_field "asked_to" card))

(** Вопрос обязателен: без него переход запрещён, и задача ждёт как была. *)
let test_question_is_required () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, text = transition ~asked_to:"q-petr" "q-legist" ref_ "needs_input" 1 in
  Alcotest.(check int) "код ответа" 403 code;
  Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text));
  let card = card_of ref_ in
  Alcotest.(check string) "статус прежний" "in_progress" (text_field "status" card);
  Alcotest.(check string) "вопрос не записан" "" (text_field "question" card)

(** Адресат обязателен: спросить некого — переход запрещён. *)
let test_addressee_is_required () =
  with_admin_handles None (fun () ->
      let created = create_task ~author:"q-solo" ~assignee:"q-solo" () in
      let ref_ = task_ref created in
      let code, text = transition ~reason:"Нужен отчёт?" "q-solo" ref_ "needs_input" 1 in
      Alcotest.(check int) "код ответа" 403 code;
      Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text));
      let card = card_of ref_ in
      Alcotest.(check string) "статус прежний" "in_progress"
        (text_field "status" card))

(** Ответ обязателен: из needs_input нельзя выйти молча. *)
let test_answer_is_required () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, _ =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-petr" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "вопрос задан" 200 code;
  let code, text = transition "q-petr" ref_ "in_progress" 2 in
  Alcotest.(check int) "код ответа" 403 code;
  Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text));
  let card = card_of ref_ in
  Alcotest.(check string) "задача ждёт ответа" "needs_input"
    (text_field "status" card)

(** Агент ответить не может: вопрос ждёт живого ответа. *)
let test_agent_cannot_answer () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, _ =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-petr" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "вопрос задан" 200 code;
  let code, text =
    transition ~answer:"Отчёт в Markdown" "q-legist" ref_ "in_progress" 2
  in
  Alcotest.(check int) "код ответа" 403 code;
  Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text))

(** Посторонний человек ответить не может: ответ не его. *)
let test_stranger_cannot_answer () =
  with_admin_handles None (fun () ->
      let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
      let ref_ = task_ref created in
      let code, _ =
        transition ~reason:"Нужен отчёт?" ~asked_to:"q-petr" "q-legist" ref_
          "needs_input" 1
      in
      Alcotest.(check int) "вопрос задан" 200 code;
      let code, text =
        transition ~answer:"Ответ постороннего" "q-other" ref_ "in_progress" 2
      in
      Alcotest.(check int) "код ответа" 403 code;
      Alcotest.(check string) "код ошибки" "forbidden" (error_code (json text)))

(** Адресат отвечает: его ждали — и он ответил. *)
let test_addressee_can_answer () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, _ =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-other" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "вопрос задан" 200 code;
  let code, text =
    transition ~answer:"Отчёт в Markdown" "q-other" ref_ "in_progress" 2
  in
  Alcotest.(check int) "код ответа" 200 code;
  let card = task_of (json text) in
  Alcotest.(check string) "статус" "in_progress" (text_field "status" card);
  Alcotest.(check string) "ответ" "Отчёт в Markdown" (text_field "answer" card)

(** Вопрос и ответ переживают смену статуса: карточка помнит, о чём был
    разговор. *)
let test_history_survives_status_change () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, _ =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-other" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "вопрос задан" 200 code;
  let code, _ =
    transition ~answer:"Отчёт в Markdown" "q-other" ref_ "in_progress" 2
  in
  Alcotest.(check int) "ответ принят" 200 code;
  let card = card_of ref_ in
  Alcotest.(check string) "вопрос остался" "Нужен отчёт?" (text_field "question" card);
  Alcotest.(check string) "ответ остался" "Отчёт в Markdown"
    (text_field "answer" card);
  Alcotest.(check bool) "когда ответили — записано" true
    (text_field "answered_at" card <> "")

(** Новый вопрос — новое ожидание: прежний ответ обнуляется. *)
let test_new_question_clears_previous_answer () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, _ =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-other" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "вопрос задан" 200 code;
  let code, _ =
    transition ~answer:"Отчёт в Markdown" "q-other" ref_ "in_progress" 2
  in
  Alcotest.(check int) "ответ принят" 200 code;
  let code, text =
    transition ~reason:"Нужен ещё и бюджет?" ~asked_to:"q-petr" "q-legist" ref_
      "needs_input" 3
  in
  Alcotest.(check int) "новый вопрос задан" 200 code;
  let card = task_of (json text) in
  Alcotest.(check string) "новый вопрос" "Нужен ещё и бюджет?"
    (text_field "question" card);
  Alcotest.(check string) "прежний ответ обнулён" "" (text_field "answer" card);
  Alcotest.(check string) "время ответа обнулено" ""
    (text_field "answered_at" card)

(** Адресату кладётся уведомление: вопрос без вести пропадает. *)
let test_notification_is_queued () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, _ =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-other" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "код ответа" 200 code;
  let notifications = notifications_of ref_ in
  let notification =
    match notifications with
    | [ one ] -> one
    | many ->
        Alcotest.fail
          ("ожидалось одно уведомление, а пришло "
          ^ string_of_int (List.length many))
  in
  Alcotest.(check string) "канал" "mattermost_dm"
    (text_field "channel" notification);
  Alcotest.(check string) "вид" "needs_input" (text_field "kind" notification);
  Alcotest.(check string) "получатель — адресат" other.Actor.id
    (text_field "actor_id" notification);
  Alcotest.(check string) "доставка не начата" "pending"
    (text_field "delivery_state" notification)

(** Вопрос и ответ попадают в журнал: по истории видно, что было спрошено. *)
let test_question_and_answer_are_journaled () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, _ =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-other" "q-legist" ref_
      "needs_input" 1
  in
  Alcotest.(check int) "вопрос задан" 200 code;
  let code, _ =
    transition ~answer:"Отчёт в Markdown" "q-other" ref_ "in_progress" 2
  in
  Alcotest.(check int) "ответ принят" 200 code;
  let actions = actions_of ref_ in
  Alcotest.(check bool) "вопрос записан в журнал" true
    (List.mem "questioned" actions);
  Alcotest.(check bool) "ответ записан в журнал" true (List.mem "answered" actions)

(** Устаревшая версия — конфликт: задачу уже кто-то изменил. *)
let test_stale_version_is_conflict () =
  let created = create_task ~author:"q-petr" ~assignee:"q-legist" () in
  let ref_ = task_ref created in
  let code, text =
    transition ~reason:"Нужен отчёт?" ~asked_to:"q-petr" "q-legist" ref_
      "needs_input" 999
  in
  Alcotest.(check int) "код ответа" 409 code;
  Alcotest.(check string) "код ошибки" "conflict" (error_code (json text));
  let card = card_of ref_ in
  Alcotest.(check string) "статус прежний" "in_progress" (text_field "status" card)

(* --------------------------------------------------------------------- run --- *)

let () =
  Alcotest.run "вопрос при needs_input"
    [
      ( "вопрос",
        [
          Alcotest.test_case "вопрос сохраняется вместе с адресатом" `Quick
            test_question_is_saved;
          Alcotest.test_case "явный адресат записан" `Quick
            test_explicit_addressee_is_recorded;
          Alcotest.test_case "адресат выводится по цепочке" `Quick
            test_derived_addressee_is_requester;
          Alcotest.test_case "администратор — последний в цепочке" `Quick
            test_admin_is_the_last_addressee;
          Alcotest.test_case "без вопроса — 403" `Quick test_question_is_required;
          Alcotest.test_case "без адресата — 403" `Quick
            test_addressee_is_required;
          Alcotest.test_case "без ответа — 403" `Quick test_answer_is_required;
        ] );
      ( "ответ",
        [
          Alcotest.test_case "агент не отвечает" `Quick test_agent_cannot_answer;
          Alcotest.test_case "посторонний не отвечает" `Quick
            test_stranger_cannot_answer;
          Alcotest.test_case "адресат отвечает" `Quick test_addressee_can_answer;
        ] );
      ( "история",
        [
          Alcotest.test_case "вопрос и ответ переживают смену статуса" `Quick
            test_history_survives_status_change;
          Alcotest.test_case "новый вопрос обнуляет прежний ответ" `Quick
            test_new_question_clears_previous_answer;
          Alcotest.test_case "вопрос и ответ попадают в журнал" `Quick
            test_question_and_answer_are_journaled;
        ] );
      ( "уведомление и версия",
        [
          Alcotest.test_case "адресату кладётся уведомление" `Quick
            test_notification_is_queued;
          Alcotest.test_case "устаревшая версия — 409" `Quick
            test_stale_version_is_conflict;
        ] );
    ];
  ignore petr;
  ignore legist;
  ignore other;
  ignore chief;
  ignore admin;
  ignore solo;
  ignore project;
  ignore set_supervisor
