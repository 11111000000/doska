(** Замкнутые типы домена: каждый вариант умеет назвать себя и умеет быть
    разобранным обратно.

    Машина состояний задачи — это набор вариантов, а не строки: добавление
    нового обязано ломать сборку в местах, где статус разбирается (§4.2
    архитектуры). Здесь проверяется другое свойство того же типа: имя
    варианта однозначно и обратимо — на этом держатся API, база и импорт из
    Mattermost. *)

open Domain

(** Имя варианта непустое, разбирается обратно в тот же вариант и не путается
    с выдумкой. *)
let check_round_trip name to_string of_string variants =
  List.iter
    (fun variant ->
      let printed = to_string variant in
      Alcotest.(check bool) (name ^ ": имя непустое") true (printed <> "");
      match of_string printed with
      | Some parsed ->
          Alcotest.(check bool) (name ^ ": разбор обратно") true (parsed = variant)
      | None ->
          Alcotest.fail
            (Printf.sprintf "%s: «%s» не разбирается обратно" name printed))
    variants;
  Alcotest.(check bool) (name ^ ": выдумка не принимается") true
    (of_string "выдумка" = None)

let test_status_round_trip () =
  check_round_trip "статус" Status.to_string Status.of_string
    [
      Status.Backlog;
      Status.Todo;
      Status.In_progress;
      Status.Blocked;
      Status.Needs_input;
      Status.In_review;
      Status.Done;
      Status.Cancelled;
    ];
  Alcotest.(check int) "все статусы перечислены" 8 (List.length Status.all)

let test_status_helpers () =
  Alcotest.(check bool) "todo открыт" true (Status.is_open Status.Todo);
  Alcotest.(check bool) "done закрыт" false (Status.is_open Status.Done);
  Alcotest.(check bool) "cancelled терминален" true
    (Status.is_terminal Status.Cancelled);
  Alcotest.(check bool) "todo не терминален" false
    (Status.is_terminal Status.Todo);
  Alcotest.(check bool) "needs_input ждёт человека" true
    (Status.waits_for_human Status.Needs_input);
  Alcotest.(check bool) "in_review не ждёт человека" false
    (Status.waits_for_human Status.In_review)

let test_task_kind_round_trip () =
  check_round_trip "вид задачи" Task.kind_to_string Task.kind_of_string
    [
      Task.Task;
      Task.Bug;
      Task.Feature;
      Task.Chore;
      Task.Decision;
      Task.Research;
      Task.Question;
      Task.Spike;
      Task.Risk;
    ]

let test_task_priority_round_trip () =
  check_round_trip "приоритет" Task.priority_to_string Task.priority_of_string
    [ Task.P0; Task.P1; Task.P2; Task.P3 ];
  Alcotest.(check int) "раньше — значит важнее" 0 (Task.priority_rank Task.P0);
  Alcotest.(check bool) "порядок приоритетов строгий" true
    (Task.priority_rank Task.P0 < Task.priority_rank Task.P3)

let test_actor_round_trip () =
  check_round_trip "вид актора" Actor.kind_to_string Actor.kind_of_string
    [ Actor.Human; Actor.Agent; Actor.Service; Actor.Placeholder ];
  check_round_trip "режим приёмки" Actor.autonomy_to_string Actor.autonomy_of_string
    [ Actor.Human_gate; Actor.Auto ];
  let human =
    Actor.make ~id:"u-1" ~kind:Actor.Human ~handle:"petr" ~display_name:"Пётр" ()
  in
  let agent =
    Actor.make ~id:"a-1" ~kind:Actor.Agent ~handle:"legist" ~display_name:"legist" ()
  in
  Alcotest.(check bool) "человек — человек" true (Actor.is_human human);
  Alcotest.(check bool) "агент — не человек" false (Actor.is_human agent);
  Alcotest.(check bool) "агент — агент" true (Actor.is_agent agent);
  Alcotest.(check bool) "заглушка не разрешена" true
    (Actor.placeholder ~id:"p-1" ~handle:"?" ~display_name:"?").Actor.unresolved

let test_project_round_trip () =
  check_round_trip "статус проекта" Project.status_to_string Project.status_of_string
    [ Project.Active; Project.Paused; Project.Archived ]

let test_evidence_round_trip () =
  check_round_trip "вид доказательства" Evidence.kind_to_string
    Evidence.kind_of_string
    [
      Evidence.Commit;
      Evidence.Branch;
      Evidence.Pr;
      Evidence.File;
      Evidence.Url;
      Evidence.Doc;
      Evidence.Note;
      Evidence.Review;
      Evidence.Test;
    ];
  Alcotest.(check int) "все виды перечислены" 9 (List.length Evidence.all)

let test_activity_round_trip () =
  check_round_trip "действие" Activity.action_to_string Activity.action_of_string
    [
      Activity.Created;
      Activity.Status_changed;
      Activity.Assigned;
      Activity.Unassigned;
      Activity.Reassigned;
      Activity.Commented;
      Activity.Evidence_added;
      Activity.Due_changed;
      Activity.Priority_changed;
      Activity.Linked;
      Activity.Unlinked;
      Activity.Review_requested;
      Activity.Accepted;
      Activity.Rejected;
      Activity.Claimed;
      Activity.Released;
      Activity.Cancelled;
      Activity.Deleted;
      Activity.Restored;
      Activity.Updated;
    ]

let test_interface_round_trip () =
  check_round_trip "интерфейс" Interface.to_string Interface.of_string
    [
      Interface.Api;
      Interface.Mcp;
      Interface.Cli;
      Interface.Web;
      Interface.Mattermost;
      Interface.Paseo;
      Interface.Import;
      Interface.System;
    ];
  Alcotest.(check string) "интерфейс: неизвестное имя читается как system" "system"
    (Interface.to_string (Interface.of_string_default "выдумка"))

let () =
  Alcotest.run "типы домена"
    [
      ( "статусы",
        [
          Alcotest.test_case "имя статуса разбирается обратно" `Quick
            test_status_round_trip;
          Alcotest.test_case "открыт, терминален, ждёт человека" `Quick
            test_status_helpers;
        ] );
      ( "задачи",
        [
          Alcotest.test_case "вид задачи разбирается обратно" `Quick
            test_task_kind_round_trip;
          Alcotest.test_case "приоритет разбирается обратно" `Quick
            test_task_priority_round_trip;
        ] );
      ( "акторы и проекты",
        [
          Alcotest.test_case "вид актора и режим приёмки" `Quick
            test_actor_round_trip;
          Alcotest.test_case "статус проекта" `Quick test_project_round_trip;
        ] );
      ( "доказательства и журнал",
        [
          Alcotest.test_case "вид доказательства" `Quick test_evidence_round_trip;
          Alcotest.test_case "действие журнала" `Quick test_activity_round_trip;
          Alcotest.test_case "интерфейс действия" `Quick test_interface_round_trip;
        ] );
    ]
