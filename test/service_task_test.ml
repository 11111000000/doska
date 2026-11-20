(** Сервисный слой задач на живой базе.

    Сервис выделен ради одного свойства: правило и транзакция живут в одном
    месте, а интерфейсы — адаптеры. Поэтому здесь проверяется не «какой код
    ответа», а вид отказа: запрет правила приходит как запрет правила, а не
    как ошибка хранилища; журнал пишет интерфейс, через который пришло
    действие; правка задачи не выдаёт себя за смену статуса. *)

open Domain

let conn = Support.connect ()

(* Фикстуры этого теста общие с другим его прогоном: блокируемся, чтобы
   уборка одного прогона не удалила фикстуры другого. *)
let () = Support.lock conn 4715

(* Уборка — до фикстур: [Alcotest.run] завершает процесс, код после него не
   выполняется, поэтому строки прошлого прогона убираем на входе. *)
let () =
  Support.cleanup conn ~source:"test-service" ~actor_prefix:"svc-"
    ~project_prefix:"SVC"

let human =
  Support.ensure_actor conn ~prefix:"svc-" ~kind:Actor.Human ~handle:"petr"
    ~display_name:"Пётр"

let agent =
  Support.ensure_actor conn ~prefix:"svc-" ~kind:Actor.Agent ~handle:"legist"
    ~display_name:"legist"

let colleague =
  Support.ensure_actor conn ~prefix:"svc-" ~kind:Actor.Human ~handle:"other"
    ~display_name:"Другой"

let project =
  Support.ensure_project conn ~prefix:"SVC" ~key:"MAIN" ~name:"Основной"
    ~autonomy:Actor.Human_gate

let counter = ref 0

let next_source_ref () =
  incr counter;
  Printf.sprintf "svc-%d" !counter

(** Вход создания: проект, исполнитель и заявитель заданы логинами — клиент
    знает человека по имени, а не по идентификатору. *)
let input ?(status = Status.Backlog) ?assignee ?requester () :
    Service.Task.create_input =
  let source_ref = next_source_ref () in
  {
    title = Printf.sprintf "Сервисная задача %d" !counter;
    description = "описание задачи";
    kind = Task.Task;
    status;
    priority = Task.P2;
    due_at = None;
    labels = [];
    source = Some "test-service";
    source_ref = Some source_ref;
    project = Some project.Project.key;
    assignee;
    requester;
  }

let create ?status ?assignee ?requester ?interface_ () =
  let interface_ =
    match interface_ with Some interface_ -> interface_ | None -> Interface.Api
  in
  match
    Support.run
      (Service.Task.create conn ~actor:human ~interface_
         (input ?status ?assignee ?requester ()))
  with
  | Ok (Db.Repo_task.Created task) -> task
  | Ok (Db.Repo_task.Existing _) -> Alcotest.fail "задача уже существовала"
  | Error e ->
      Alcotest.fail ("задача не создана: " ^ Service.Failure.to_string e)

(** Журнал задачи: последние события первыми. *)
let events_for ref_ =
  let filters : Db.Repo_activity.filters =
    {
      Db.Repo_activity.project = None;
      task = Some ref_;
      actor = None;
      since = None;
      limit = 100;
      cursor = None;
    }
  in
  match Support.run (Db.Repo_activity.list conn filters) with
  | Ok events -> events
  | Error e -> Alcotest.fail ("журнал не прочитан: " ^ e)

let expect_failure what promise =
  match Support.run promise with
  | Ok _ -> Alcotest.fail (what ^ ": ожидался отказ")
  | Error failure -> failure

(* ------------------------------------------------------------------ журнал --- *)

(** Журнал должен помнить, откуда пришло действие: агентский вызов иначе
    неотличим от человеческого (D5). *)
let test_journal_records_interface () =
  let task = create ~interface_:Interface.Mcp () in
  match events_for task.Task.ref_ with
  | event :: _ ->
      Alcotest.(check string) "interface" "mcp"
        (Interface.to_string event.Activity.interface_);
      Alcotest.(check string) "action" "created"
        (Activity.action_to_string event.Activity.action)
  | [] -> Alcotest.fail "создание не оставило следа в журнале"

let test_transition_records_interface () =
  let task = create () in
  match
    Support.run
      (Service.Task.transition conn ~actor:human ~interface_:Interface.Paseo
         ~ref_:task.Task.ref_ ~target:Status.Todo ~version:task.Task.version
         ~note:None)
  with
  | Error e -> Alcotest.fail ("переход не прошёл: " ^ Service.Failure.to_string e)
  | Ok _ -> (
      match events_for task.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "interface" "paseo"
            (Interface.to_string event.Activity.interface_);
          Alcotest.(check string) "action" "status_changed"
            (Activity.action_to_string event.Activity.action)
      | [] -> Alcotest.fail "переход не оставил следа в журнале")

(** Правка задачи — не смена статуса: в журнале должно быть [updated] со
    сводкой изменённых полей. *)
let test_patch_journal_is_updated () =
  let task = create () in
  let fields : Db.Repo_task.patch =
    {
      title = Some "Переименованная задача";
      description = None;
      priority = None;
      due_at = None;
      labels = None;
    }
  in
  match
    Support.run
      (Service.Task.patch conn ~actor:human ~interface_:Interface.Web
         ~ref_:task.Task.ref_ ~version:task.Task.version fields)
  with
  | Error e -> Alcotest.fail ("правка не прошла: " ^ Service.Failure.to_string e)
  | Ok updated -> (
      Alcotest.(check string) "title" "Переименованная задача" updated.Task.title;
      match events_for task.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "action" "updated"
            (Activity.action_to_string event.Activity.action);
          Alcotest.(check string) "summary" "изменены поля: title"
            (match event.Activity.summary with
            | Some summary -> summary
            | None -> "");
          Alcotest.(check string) "interface" "web"
            (Interface.to_string event.Activity.interface_)
      | [] -> Alcotest.fail "правка не оставила следа в журнале")

(* ------------------------------------------------------------------ правила --- *)

(** Агент не может назначить задачу другому: отказ приходит как запрет
    правила, а не как ошибка хранилища. *)
let test_agent_cannot_assign_to_other () =
  let task = create () in
  let failure =
    expect_failure "назначение чужой задачи"
      (Service.Task.assign conn ~actor:agent ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~assignee:colleague.Actor.handle
         ~version:task.Task.version ~note:None)
  in
  match failure with
  | Service.Failure.Forbidden { message; _ } ->
      Alcotest.(check bool) "сообщение" true (String.length message > 0)
  | other ->
      Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other)

(** Запрещённый переход — отказ правила с деталями перехода. *)
let test_forbidden_transition_is_rule_refusal () =
  let task = create () in
  (* Отмена задачи — действие человека: агент получает отказ правила. *)
  let failure =
    expect_failure "отмена задачи агентом"
      (Service.Task.transition conn ~actor:agent ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~target:Status.Cancelled ~version:task.Task.version
         ~note:(Some "не актуально"))
  in
  match failure with
  | Service.Failure.Forbidden { details; _ } ->
      let detail key =
        match List.assoc_opt key details with Some value -> value | None -> ""
      in
      Alcotest.(check string) "from" "backlog" (detail "from");
      Alcotest.(check string) "to" "cancelled" (detail "to")
  | other ->
      Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other)

(** Устаревшая версия — конфликт, а не запрет: версию можно обновить и
    повторить, а правило — нельзя. *)
let test_stale_version_is_conflict () =
  let task = create () in
  let failure =
    expect_failure "переход по устаревшей версии"
      (Service.Task.transition conn ~actor:human ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~target:Status.Todo
         ~version:(task.Task.version + 100) ~note:None)
  in
  match failure with
  | Service.Failure.Conflict { message = _ } -> ()
  | other ->
      Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other)

(** Несуществующая задача — «нет ресурса», а не «сломано». *)
let test_missing_task_is_not_found () =
  let failure =
    expect_failure "чтение несуществующей задачи"
      (Service.Task.find conn ~ref_:"DSK-NOT-EXISTS")
  in
  match failure with
  | Service.Failure.Not_found { message = _ } -> ()
  | other ->
      Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other)

(* ------------------------------------------------------- классы отказов --- *)

(** Классы отказов различаются и на выходе: «правило запрещает» — 403,
    «сломалось у нас» — 500. Иначе клиент не отличит вину сервера от вины
    правила. *)
let test_failure_classes_are_distinct () =
  let forbidden =
    Api.Errors.of_failure
      (Service.Failure.Forbidden { message = "правило запрещает"; details = [] })
  in
  Alcotest.(check string) "код запрета" "forbidden"
    (Api.Errors.code_to_string forbidden.code);
  let storage =
    Api.Errors.of_failure (Service.Failure.Storage { message = "сломалось" })
  in
  Alcotest.(check string) "код сбоя" "internal"
    (Api.Errors.code_to_string storage.code)

let () =
  Alcotest.run "сервисный слой задач"
    [
      ( "журнал",
        [
          Alcotest.test_case "интерфейс действия" `Quick
            test_journal_records_interface;
          Alcotest.test_case "интерфейс перехода" `Quick
            test_transition_records_interface;
          Alcotest.test_case "правка пишет updated" `Quick
            test_patch_journal_is_updated;
        ] );
      ( "правила",
        [
          Alcotest.test_case "агент не назначает другому" `Quick
            test_agent_cannot_assign_to_other;
          Alcotest.test_case "запрещённый переход — отказ правила" `Quick
            test_forbidden_transition_is_rule_refusal;
          Alcotest.test_case "устаревшая версия — конфликт" `Quick
            test_stale_version_is_conflict;
          Alcotest.test_case "нет задачи — not found" `Quick
            test_missing_task_is_not_found;
        ] );
      ( "классы отказов",
        [
          Alcotest.test_case "запрет и сбой различаются" `Quick
            test_failure_classes_are_distinct;
        ] );
    ]
