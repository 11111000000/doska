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
let mm_actor ?(ref_ = "mm-user-1") handle =
  match
    Support.run
      (Db.Repo_actor.upsert_from_source conn ~source:"mattermost" ~source_ref:ref_
         ~kind:Actor.Agent ~handle:("wht-" ^ handle) ~display_name:"MM агент" ())
  with
  | Ok actor -> actor
  | Error e -> failwith ("MM актор не создан: " ^ e)

let has_sub s sub =
  let n = String.length sub in
  let rec loop i = i + n > String.length s || String.sub s i n = sub || loop (i + 1) in
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

let test_wrong_token_is_rejected () =
  let code, text = call (form [ ("token", "неверный") ; ("command", "/tasks") ]) in
  Alcotest.(check int) "неверный токен — 401" 401 code;
  Alcotest.(check bool) "ответ — ephemeral-текст" true
    (String.length text > 0)

let test_task_from_chat_is_created () =
  let a = mm_actor "bot" in
  (* trigger_id уникален на прогон: бот-задачи с source=mattermost не
     удаляются уборкой теста, и старый id нашёл бы вчерашнюю задачу. *)
  let trigger = Printf.sprintf "trg-%d" (int_of_float (Unix.gettimeofday ())) in
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
        ("text", "Задача для списка");
        ("user_id", a.Domain.Actor.id);
        ("user_name", "wht-bot2");
        ("trigger_id", "trg-2");
      ]
  in
  let _, created = call body in
  let ref_ =
    field "text" (Yojson.Safe.from_string created) |> fun s ->
    String.sub s 8 (String.length s - 8)
  in
  let body = form [ ("token", "test-token") ; ("command", "/tasks") ; ("user_id", a.Domain.Actor.id) ; ("user_name", "wht-bot2") ] in
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
      ( "доставка",
        [ test_case "pending уходит адресату" `Quick test_notify_delivers_pending ] );
    ]
