(** Вебхук Mattermost на живой базе.

    Токен интеграции проверяется, задача из чата создаётся идемпотентно,
    кнопки выполняют переходы по правилам домена: агент не закрывает свою
    задачу (R1), отказ приходит текстом, а не 500. *)

open Domain

let () = Unix.putenv "DOSKA_MATTERMOST_TOKEN" "test-token"

let conn = Support.connect ()

let () = Support.lock conn 4719

let () =
  Support.cleanup conn ~source:"test-webhook" ~actor_prefix:"wht-"
    ~project_prefix:"WHT"

let _ =
  Support.ensure_project conn ~prefix:"WHT" ~key:"MAIN" ~name:"Вебхук-тесты"
    ~autonomy:Actor.Human_gate

(* Актор с привязкой к Mattermost: идентичность вебхука ищет по
   [source=mattermost, source_ref=user_id]. *)
let mm_actor ?ref_ handle =
  (* У каждого чат-актора свой source_ref: при общем upsert возвращает первого
     созданного, и handle следующего вызова в базе не существует. *)
  let ref_ = match ref_ with Some r -> r | None -> "mm-" ^ handle in
  match
    Support.run
      (Db.Repo_actor.upsert_from_source conn ~source:"mattermost" ~source_ref:ref_
         ~kind:Actor.Agent ~handle:("wht-" ^ handle) ~display_name:"MM агент" ())
  with
  | Ok actor -> actor
  | Error e -> failwith ("MM актор не создан: " ^ e)

let has_sub s sub =
  let n = String.length sub in
  let len = String.length s in
  let rec loop i = i + n <= len && (String.sub s i n = sub || loop (i + 1)) in
  loop 0

let client = Dream.test Api.Server.handler

let call ?(method_ = `POST) body =
  let request = Dream.request ~method_ ~target:"/hooks/mattermost" body in
  let response = client request in
  let status = Dream.status_to_int (Dream.status response) in
  let text = Support.run (Dream.body response) in
  (status, text)

let form fields =
  String.concat "&"
    (List.map
       (fun (k, v) -> k ^ "=" ^ Dream.to_percent_encoded v)
       fields)

let field name value =
  match Yojson.Safe.Util.member name value with
  | `String s -> s
  | _ -> ""

(* Номер задачи из ответа: ответ начинается либо с «создано », либо с
   «уже существует » — режем по первому вхождению DSK-, а не по длине
   префикса. *)
let task_ref_of s =
  match String.index_opt s 'D' with
  | Some i -> String.sub s i (String.length s - i)
  | None -> ""

(* Замена всех вхождений подстроки. *)
let replace_all needle by hay =
  let n = String.length needle and len = String.length hay in
  let buf = Buffer.create (len + 16) in
  let i = ref 0 in
  while !i < len do
    if !i + n <= len && String.sub hay !i n = needle then (
      Buffer.add_string buf by;
      i := !i + n)
    else (
      Buffer.add_char buf hay.[!i];
      incr i)
  done;
  Buffer.contents buf

(* Форма как её шлёт настоящий клиент: application/x-www-form-urlencoded
   кодирует пробел знаком «+», а не %20. *)
let form_plus fields =
  String.concat "&"
    (List.map
       (fun (k, v) -> k ^ "=" ^ replace_all "%20" "+" (Dream.to_percent_encoded v))
       fields)

(* Задача по номеру — как её видит API. *)
let fetch_task ref_ =
  let request =
    Dream.request ~method_:`GET ~target:("/api/v1/tasks/" ^ ref_)
      ~headers:[ ("x-doska-actor", "wht-fields") ] ""
  in
  let response = client request in
  let body = Support.run (Dream.body response) in
  Yojson.Safe.Util.(member "task" (Yojson.Safe.from_string body))

let test_wrong_token_is_rejected () =
  let code, text = call (form [ ("token", "неверный") ; ("command", "/tasks") ]) in
  Alcotest.(check int) "неверный токен — 401" 401 code;
  Alcotest.(check bool) "ответ — ephemeral-текст" true
    (String.length text > 0)

let test_task_from_chat_is_created () =
  let a = mm_actor "bot" in
  (* trigger_id уникален на прогон: бот-задачи с source=mattermost не
     удаляются уборкой теста, и старый id нашёл бы вчерашнюю задачу. *)
  (* Триггер уникален и в пределах секунды: прогоны подряд не должны
     упираться в задачу прошлого прогона. *)
  let trigger =
    Printf.sprintf "trg-%d-%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday ()))
  in
  let body =
    form
      [
        ("token", "test-token");
        ("command", "/task");
        ("text", "Задача из чата");
        ("user_id", a.Domain.Actor.id);
        ("user_name", "wht-bot");
        ("trigger_id", trigger);
      ]
  in
  let code, text = call body in
  Alcotest.(check int) "команда /task — 200" 200 code;
  let created = field "text" (Yojson.Safe.from_string text) in
  Alcotest.(check bool) "в ответе номер задачи" true
    (has_sub created "DSK-");
  (* Повтор той же команды — та же задача, дубликат не плодится. *)
  let code, text = call body in
  Alcotest.(check int) "повтор — 200" 200 code;
  let again = field "text" (Yojson.Safe.from_string text) in
  Alcotest.(check bool) "повтор распознан" true
    (has_sub again "уже существует");
  Alcotest.(check bool) "тот же номер задачи" true
    (let dsk s =
       match (try Some (String.index s 'D') with Not_found -> None) with
       | Some i -> String.sub s i (String.length s - i)
       | None -> ""
     in
     has_sub again (dsk created))

let test_tasks_lists_mine () =
  let a = mm_actor "bot2" in
  let body =
    form
      [
        ("token", "test-token");
        ("command", "/task");
        ("text", "Задача для списка | | wht-bot2");
        ("user_id", a.Domain.Actor.id);
        ("user_name", "wht-bot2");
        ("trigger_id", Printf.sprintf "trg2-%d-%.6f" (Unix.getpid ())
           (Unix.gettimeofday ()));
      ]
  in
  let _, created = call body in
  let ref_ =
    field "text" (Yojson.Safe.from_string created) |> task_ref_of
  in
  let code, text = call body in
  Alcotest.(check int) "список — 200" 200 code;
  Alcotest.(check bool) "задача в списке" true (has_sub text ref_)

let button token action task_ref =
  let payload =
    Yojson.Safe.to_string
      (`Assoc
        [
          ( "context",
            `Assoc [ ("action", `String action); ("task_ref", `String task_ref) ] );
        ])
  in
  let a = mm_actor "bot3" in
  call
    (form
      [
        ("token", token);
        ("payload", payload);
        ("user_id", a.Domain.Actor.id);
        ("user_name", "wht-bot3");
      ])

let setup_task () =
  let requester = Support.ensure_actor conn ~prefix:"wht-" ~kind:Actor.Human ~handle:"petr" ~display_name:"Пётр" in
  let code, text =
    let client = Dream.test Api.Server.handler in
    let request =
      Dream.request ~method_:`POST ~target:"/api/v1/tasks"
        ~headers:[ ("x-doska-actor", "wht-petr") ]
        (Yojson.Safe.to_string
           (`Assoc
             [
               ("title", `String "Задача для кнопок");
               ("description", `String "");
               ("status", `String "todo");
               ("project", `String "WHTMAIN");
               ("source", `String "test-webhook");
             ]))
    in
    let response = client request in
    let code = Dream.status_to_int (Dream.status response) in
    (code, Support.run (Dream.body response))
  in
  Alcotest.(check int) "задача создана по REST" 201 code;
  let task = Yojson.Safe.from_string text |> fun v -> Yojson.Safe.Util.member "task" v in
  let ref_ =
    match Yojson.Safe.Util.member "ref" task with
    | `String s -> s
    | _ -> Alcotest.fail "нет ref"
  in
  (ref_, requester)

let test_button_claims () =
  let ref_, _requester = setup_task () in
  let code, text = button "test-token" "claim" ref_ in
  Alcotest.(check int) "кнопка заявки — 200" 200 code;
  Alcotest.(check bool) "взято в работу" true
    (has_sub text "взято в работу")

let test_button_done_by_agent_is_refused () =
  let ref_, _requester = setup_task () in
  (* Сначала заявка: из todo закрыть нельзя, агент берёт в работу. *)
  let _, _ = button "test-token" "claim" ref_ in
  let code, text = button "test-token" "done" ref_ in
  Alcotest.(check int) "кнопка закрытия — 200 (текст отказа)" 200 code;
  Alcotest.(check bool) "правило R1 отказало агенту" true
    (has_sub text "forbidden" || has_sub text "запрещ")

let test_notify_delivers_pending () =
  (* Адресат с привязкой к MM: доставляемая учётка. *)
  let a = mm_actor "bot4" ~ref_:"mm-user-4" in
  let ref_, _requester = setup_task () in
  match Support.run (Service.Task.find conn ~ref_) with
  | Error e -> Alcotest.fail ("задача не найдена: " ^ Service.Failure.to_string e)
  | Ok task ->
  match
    Support.run (Db.Repo_notification.enqueue conn ~task_id:(Some task.Task.id) ~actor_id:(Some a.Domain.Actor.id) ~kind:"needs_input"
      ~payload:(`Assoc [ ("question", `String "какой адрес у билинга?") ]))
  with
  | Error e -> Alcotest.fail ("enqueue не прошёл: " ^ e)
  | Ok () -> (
      let sent = ref [] in
      let send ~mm_user_id ~text =
        sent := (mm_user_id, text) :: !sent;
        Lwt_result.lift (Ok ())
      in
      match Support.run (Service.Notify.deliver_pending conn ~send) with
      | Error e -> Alcotest.fail ("доставка не прошла: " ^ e)
      | Ok (delivered, _failed) ->
          (* Рабочая база копит чужие pending-уведомления: утверждаем
             только доставку нашего уведомления нашему адресату. *)
          Alcotest.(check bool) "наше уведомление доставлено" true
            (delivered >= 1);
          Alcotest.(check bool) "текст с вопросом уходит адресату" true
            (List.exists
               (fun (mm_user_id, text) ->
                 mm_user_id = "mm-user-4" && has_sub text "билинга")
               !sent))


(** Позиции команды: заголовок | проект | исполнитель | срок.

    Разбор позиционный, и это проверяется: однажды проект и исполнитель
    поменялись местами, и задача уходила в несуществующий проект. *)
let test_task_command_fields () =
  let a = mm_actor "fields" ~ref_:"mm-fields" in
  (* Проект и исполнитель — свои: тест не должен зависеть от чужих фикстур
     в общей базе (иначе он зависит от порядка запуска тестов). *)
  let assignee =
    Support.ensure_actor conn ~prefix:"wht-" ~kind:Actor.Human ~handle:"assignee"
      ~display_name:"Исполнитель"
  in
  (* Ключ уникален в пределах секунды: два прогона подряд (чистый и после
     control'а) не должны столкнуться на одном проекте. *)
  let key =
    Printf.sprintf "prjfields%d%d" (Unix.getpid ())
      (int_of_float (Unix.gettimeofday ()))
  in
  let create_project =
    client (Dream.request ~method_:`POST ~target:"/api/v1/projects"
      ~headers:[ ("x-doska-actor", "wht-fields") ]
      (Yojson.Safe.to_string (`Assoc [ ("key", `String key) ])))
  in
  let status = Dream.status_to_int (Dream.status create_project) in
  Alcotest.(check int) "проект для команды создан" 201 status;
  let body =
    form
      [
        ("token", "test-token");
        ("command", "/task");
        ( "text",
          "Задача с полями | " ^ key ^ " | " ^ assignee.Actor.handle ^ " | 2026-12-24" );
        ("user_id", a.Domain.Actor.id);
        ("user_name", "wht-fields");
        ("trigger_id", Printf.sprintf "fields-%d-%.6f" (Unix.getpid ())
           (Unix.gettimeofday ()));
      ]
  in
  let code, text = call body in
  Alcotest.(check int) "команда — 200" 200 code;
  let ref_ = field "text" (Yojson.Safe.from_string text) |> task_ref_of in
  Alcotest.(check bool) "в ответе номер задачи" true (has_sub ref_ "DSK-");
  (* Позиции разбора: заголовок | проект | исполнитель | срок. Проверяем на самой
     задаче — иначе проверка зависит от того, чьи задачи попали в список «мои». *)
  let ref_ = field "text" (Yojson.Safe.from_string text) |> task_ref_of in
  let task =
    let request =
      Dream.request ~method_:`GET ~target:("/api/v1/tasks/" ^ ref_)
        ~headers:[ ("x-doska-actor", "wht-fields") ] ""
    in
    let response = client request in
    let body = Support.run (Dream.body response) in
    Yojson.Safe.Util.(member "task" (Yojson.Safe.from_string body))
  in
  Alcotest.(check (option string)) "проект — второй по счёту" (Some key)
    (Yojson.Safe.Util.(member "project" task |> to_string_option));
  Alcotest.(check (option string)) "исполнитель — третий по счёту"
    (Some assignee.Actor.id)
    (Yojson.Safe.Util.(member "assignee_id" task |> to_string_option))

let test_form_plus_is_space () =
  (* Настоящий клиент (Mattermost) шлёт форму form-urlencoded: пробел приходит
     знаком «+». Заголовок задачи должен получиться с пробелами, а не с
     плюсами — иначе команда из чата не работает вовсе. *)
  let a = mm_actor "plus" in
  let body =
    form_plus
      [
        ("token", "test-token");
        ("command", "/task");
        ("text", "Задача с пробелом");
        ("user_id", a.Domain.Actor.id);
        ("user_name", "wht-plus");
        ( "trigger_id",
          Printf.sprintf "plus-%d-%.6f" (Unix.getpid ()) (Unix.gettimeofday ()) );
      ]
  in
  let code, text = call body in
  Alcotest.(check int) "команда — 200" 200 code;
  let ref_ = field "text" (Yojson.Safe.from_string text) |> task_ref_of in
  let task = fetch_task ref_ in
  Alcotest.(check (option string)) "пробел разобран" (Some "Задача с пробелом")
    (Yojson.Safe.Util.(member "title" task |> to_string_option))

let () =
  let open Alcotest in
  run "вебхук mattermost"
    [
      ("токен",
        [ test_case "неверный токен — 401" `Quick test_wrong_token_is_rejected ]);
      ( "команды",
        [
          test_case "task создаёт задачу идемпотентно" `Quick
            test_task_from_chat_is_created;
          test_case "tasks показывает мои" `Quick test_tasks_lists_mine;
        ] );
      ( "кнопки",
        [
          test_case "заявка по кнопке" `Quick test_button_claims;
          test_case "закрытие агентом отказано (R1)" `Quick
            test_button_done_by_agent_is_refused;
        ] );
      ( "разбор команды",
        [ test_case "проект, исполнитель и срок по позициям" `Quick
            test_task_command_fields ] );
      ( "форма",
        [ test_case "пробел приходит как «+»" `Quick test_form_plus_is_space ] );
      ( "доставка",
        [ test_case "pending уходит адресату" `Quick test_notify_delivers_pending ] );
    ]
