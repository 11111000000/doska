(** Правила приёмки и машина состояний.

    Это самые ценные тесты в системе: они идут без базы и проверяют
    ровно то, ради чего трекер существует. *)

open Domain

let petr =
  Actor.make ~id:"u-petr" ~kind:Actor.Human ~handle:"petr" ~display_name:"Пётр" ()

let agent =
  Actor.make ~id:"a-legist" ~kind:Actor.Agent ~handle:"legist"
    ~display_name:"legist" ()

let make_ctx ?(autonomy = Actor.Human_gate) ?(assignee = None) ?(requester = false)
    ?(supervisor = false) ?(admin = false) ?(accept = false) ?(note = None)
    ?(open_children = 0) ?(asked_to = None) ?(answer = None) actor =
  Rules.make_context ~actor ~project_autonomy:autonomy ~assignee_id:assignee
    ~is_requester:requester ~is_supervisor:supervisor ~is_admin:admin
    ~has_accept_right:accept ~note ~has_evidence:false ~open_children
    ~asked_to_id:asked_to ~answer

let expect_ok name ctx from_ to_ =
  match Rules.check ctx from_ to_ with
  | Ok () -> ()
  | Error e -> Alcotest.fail (Printf.sprintf "%s: ожидался разрешённый переход, получено «%s»" name e)

let expect_error name ctx from_ to_ =
  match Rules.check ctx from_ to_ with
  | Error _ -> ()
  | Ok () -> Alcotest.fail (Printf.sprintf "%s: переход следовало запретить" name)

(** Проверка, что причина отказа называет именно то, чего не хватило:
    иначе «нет адресата» и «нет ответа» выглядят одинаково. *)
let mentions text fragment =
  let t = String.length text and f = String.length fragment in
  if f = 0 then true
  else
    let rec loop i =
      i + f <= t && (String.sub text i f = fragment || loop (i + 1))
    in
    loop 0

let expect_error_about name fragment ctx from_ to_ =
  match Rules.check ctx from_ to_ with
  | Error e ->
      Alcotest.(check bool)
        (Printf.sprintf "%s: причина отказа упоминает «%s»" name fragment)
        true
        (mentions e fragment)
  | Ok () -> Alcotest.fail (Printf.sprintf "%s: переход следовало запретить" name)

let tests_transitions =
  [
    Alcotest.test_case "агент не закрывает задачу сам (R1)" `Quick (fun () ->
        expect_error "R1" (make_ctx agent) Status.In_review Status.Done);
    Alcotest.test_case "в доверенном проекте агент закрывает сам" `Quick (fun () ->
        expect_ok "auto" (make_ctx ~autonomy:Actor.Auto agent) Status.In_review
          Status.Done);
    Alcotest.test_case "заявитель принимает работу" `Quick (fun () ->
        expect_ok "requester" (make_ctx ~requester:true petr) Status.In_review
          Status.Done);
    Alcotest.test_case "руководитель принимает работу" `Quick (fun () ->
        expect_ok "supervisor" (make_ctx ~supervisor:true petr) Status.In_review
          Status.Done);
    Alcotest.test_case "посторонний человек не принимает работу" `Quick (fun () ->
        expect_error "stranger" (make_ctx petr) Status.In_review Status.Done);
    Alcotest.test_case "администратор принимает работу" `Quick (fun () ->
        expect_ok "admin" (make_ctx ~admin:true petr) Status.In_review Status.Done);
    Alcotest.test_case "needs_input требует вопрос" `Quick (fun () ->
        (* Адресат назван, вопроса нет: отказ должен быть именно про вопрос.
           Иначе тест не отличит это от отказа «нет адресата» — и требование
           вопроса можно будет убрать из правил незаметно. *)
        expect_error_about "no question" "вопрос, на который ждём ответа"
          (make_ctx ~asked_to:(Some "u-petr") agent)
          Status.In_progress Status.Needs_input;
        expect_ok "with question"
          (make_ctx ~note:(Some "какой формат отчёта?") ~asked_to:(Some "u-petr")
             agent)
          Status.In_progress Status.Needs_input);
    Alcotest.test_case "вопрос без адресата запрещён" `Quick (fun () ->
        expect_error_about "no addressee" "кому адресован вопрос"
          (make_ctx ~note:(Some "какой формат отчёта?") agent)
          Status.In_progress Status.Needs_input);
    Alcotest.test_case "выход из needs_input требует ответа" `Quick (fun () ->
        expect_error_about "no answer" "ответ на вопрос"
          (make_ctx ~asked_to:(Some "u-petr") petr)
          Status.Needs_input Status.In_progress);
    Alcotest.test_case "агент не отвечает на вопрос" `Quick (fun () ->
        expect_error_about "agent" "только человек"
          (make_ctx ~asked_to:(Some "a-legist") ~answer:(Some "вот ответ") agent)
          Status.Needs_input Status.In_progress);
    Alcotest.test_case "посторонний человек не отвечает на вопрос" `Quick (fun () ->
        expect_error_about "stranger" "адресат, заявитель или руководитель"
          (make_ctx ~asked_to:(Some "u-other") ~answer:(Some "вот ответ") petr)
          Status.Needs_input Status.In_progress);
    Alcotest.test_case "адресат отвечает на вопрос" `Quick (fun () ->
        expect_ok "answerer"
          (make_ctx ~asked_to:(Some "u-petr") ~answer:(Some "вот ответ") petr)
          Status.Needs_input Status.In_progress);
    Alcotest.test_case "blocked требует причину" `Quick (fun () ->
        expect_error "no reason" (make_ctx agent) Status.In_progress Status.Blocked;
        expect_ok "with reason"
          (make_ctx ~note:(Some "нет доступа к стенду") agent)
          Status.In_progress Status.Blocked);
    Alcotest.test_case "in_review требует резюме" `Quick (fun () ->
        expect_error "no summary" (make_ctx agent) Status.In_progress
          Status.In_review;
        expect_ok "with summary"
          (make_ctx ~note:(Some "сделал, проверил") agent)
          Status.In_progress Status.In_review);
    Alcotest.test_case "агент забирает свободную задачу" `Quick (fun () ->
        expect_ok "claim" (make_ctx agent) Status.Todo Status.In_progress);
    Alcotest.test_case "агент не забирает задачу другого" `Quick (fun () ->
        expect_error "assigned" (make_ctx ~assignee:(Some "u-petr") agent)
          Status.Todo Status.In_progress);
    Alcotest.test_case "назначенный забирает свою задачу" `Quick (fun () ->
        expect_ok "own" (make_ctx ~assignee:(Some agent.Actor.id) agent) Status.Todo
          Status.In_progress);
    Alcotest.test_case "отклонение приёмки — только заявитель или руководитель" `Quick
      (fun () ->
        expect_error "reject" (make_ctx agent) Status.In_review Status.In_progress;
        (* Отклонение требует причины: заявитель должен сказать, что не так. *)
        expect_error "reject without reason" (make_ctx ~requester:true petr)
          Status.In_review Status.In_progress;
        expect_ok "reject by requester"
          (make_ctx ~requester:true ~note:(Some "не хватает проверки") petr)
          Status.In_review Status.In_progress);
    Alcotest.test_case "запрещённый переход отклоняется" `Quick (fun () ->
        expect_error "done to todo" (make_ctx petr) Status.Done Status.Todo);
    Alcotest.test_case "переоткрытие — только человек" `Quick (fun () ->
        expect_error "reopen by agent" (make_ctx agent) Status.Done
          Status.In_progress;
        expect_ok "reopen by human" (make_ctx petr) Status.Done
          Status.In_progress);
  ]

(* ------------------------------------------------------------- иерархия --- *)

(** Родителя не закрывают, пока открыты дети: закрытый родитель с живыми
    детьми обманывает читателя сводки. *)
let test_parent_with_open_children_is_not_closed () =
  expect_error "children" (make_ctx ~admin:true ~open_children:2 petr)
    Status.In_review Status.Done;
  expect_ok "no children" (make_ctx ~admin:true ~open_children:0 petr)
    Status.In_review Status.Done

(** Правило о детях не мешает прочим переходам: заросшая ветка не
    блокирует работу по самой задаче. *)
let test_open_children_do_not_block_other_transitions () =
  expect_ok "todo to backlog" (make_ctx ~open_children:3 agent) Status.Todo
    Status.Backlog

(** Направление блокировки: [blocked_by] — то же отношение «X мешает Y»,
    записанное с другой стороны. Остальные виды ничего не блокируют. *)
let blocking_edge_text kind ~from_id ~to_id =
  match Link.blocking_edge kind ~from_id ~to_id with
  | None -> "нет"
  | Some (u, v) -> u ^ "->" ^ v

let test_blocking_edge_direction () =
  Alcotest.(check string) "blocks" "a->b"
    (blocking_edge_text Link.Blocks ~from_id:"a" ~to_id:"b");
  Alcotest.(check string) "blocked_by" "b->a"
    (blocking_edge_text Link.Blocked_by ~from_id:"a" ~to_id:"b");
  Alcotest.(check string) "relates_to" "нет"
    (blocking_edge_text Link.Relates_to ~from_id:"a" ~to_id:"b")

(** Вид связи переживает круг: наружу — строка, внутрь — вид. *)
let test_link_kind_roundtrip () =
  List.iter
    (fun kind ->
      Alcotest.(check bool)
        (Printf.sprintf "вид %s" (Link.to_string kind))
        true
        (Link.of_string (Link.to_string kind) = Some kind))
    [
      Link.Blocks;
      Link.Blocked_by;
      Link.Relates_to;
      Link.Duplicates;
      Link.Implements;
      Link.Split_from;
      Link.Follows_up;
    ];
  Alcotest.(check bool) "чужой вид не опознан" true
    (Link.of_string "nonsense" = None)

let tests_hierarchy =
  [
    Alcotest.test_case "родитель с открытыми детьми не закрывается" `Quick
      test_parent_with_open_children_is_not_closed;
    Alcotest.test_case "открытые дети не мешают прочим переходам" `Quick
      test_open_children_do_not_block_other_transitions;
    Alcotest.test_case "направление блокировки" `Quick test_blocking_edge_direction;
    Alcotest.test_case "вид связи переживает круг" `Quick test_link_kind_roundtrip;
  ]

let tests_coverage =  [
    Alcotest.test_case "все статусы участвуют в переходах" `Quick (fun () ->
        List.iter
          (fun status ->
            Alcotest.(check bool)
              (Printf.sprintf "статус %s покрыт" (Status.to_string status))
              true
              (List.mem status Rules.covered_statuses))
          Status.all);
    Alcotest.test_case "каждый переход из таблицы определён" `Quick (fun () ->
        List.iter
          (fun (from_, to_, _) ->
            Alcotest.(check bool)
              (Printf.sprintf "%s → %s определён" (Status.to_string from_)
                 (Status.to_string to_))
              true
              (Rules.find_transition from_ to_ <> None))
          Rules.transition_table);
  ]

let () =
  Alcotest.run "домен"
    [
      ("переходы", tests_transitions);
      ("иерархия", tests_hierarchy);
      ("покрытие", tests_coverage);
    ]
