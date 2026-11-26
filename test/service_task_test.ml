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

(* Второй агент — посторонний для правила отпуска. *)
let other_agent =
  Support.ensure_actor conn ~prefix:"svc-" ~kind:Actor.Agent ~handle:"legist2"
    ~display_name:"legist2"

let project =
  Support.ensure_project conn ~prefix:"SVC" ~key:"MAIN" ~name:"Основной"
    ~autonomy:Actor.Human_gate

let counter = ref 0

let next_source_ref () =
  incr counter;
  Printf.sprintf "svc-%d" !counter

(** Вход создания: проект, исполнитель и заявитель заданы логинами — клиент
    знает человека по имени, а не по идентификатору. *)
let input ?(status = Status.Backlog) ?assignee ?requester ?parent () :
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
    parent;
  }

let create ?status ?assignee ?requester ?parent ?interface_ () =
  let interface_ =
    match interface_ with Some interface_ -> interface_ | None -> Interface.Api
  in
  match
    Support.run
      (Service.Task.create conn ~actor:human ~interface_
         (input ?status ?assignee ?requester ?parent ()))
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

(* ------------------------------------------------------------------ импорт --- *)

(** Повторный импорт обновляет контент, а не плодит дубль (§10.2): тот же
    ключ источника, другие данные — та же задача с выросшей версией и
    записью [updated] в журнале. *)
let test_upsert_updates_existing_task () =
  let task = create () in
  let revised : Service.Task.create_input =
    {
      title = "Обновлённая импортом задача";
      description = "новое описание из источника";
      kind = Task.Task;
      status = Status.Backlog;
      priority = Task.P1;
      due_at = None;
      labels = [ "импорт" ];
      source = task.Task.source;
      source_ref = task.Task.source_ref;
      project = Some project.Project.key;
      assignee = None;
      requester = None;
      parent = None;
    }
  in
  match
    Support.run
      (Service.Task.upsert conn ~actor:human ~interface_:Interface.Api revised)
  with
  | Error e -> Alcotest.fail ("upsert не прошёл: " ^ Service.Failure.to_string e)
  | Ok (Service.Task.Created _) -> Alcotest.fail "существующая задача создана заново"
  | Ok (Service.Task.Unchanged _) -> Alcotest.fail "изменения молча пропущены"
  | Ok (Service.Task.Updated updated) ->
      Alcotest.(check string) "ref" task.Task.ref_ updated.Task.ref_;
      Alcotest.(check string) "title" revised.title updated.Task.title;
      Alcotest.(check string) "description" revised.description
        updated.Task.description;
      Alcotest.(check string) "priority" "p1"
        (Task.priority_to_string updated.Task.priority);
      Alcotest.(check int) "version" (task.Task.version + 1) updated.Task.version;
      match events_for task.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "action" "updated"
            (Activity.action_to_string event.Activity.action);
          Alcotest.(check string) "summary"
            "изменены поля: title, description, priority, labels"
            (match event.Activity.summary with
            | Some summary -> summary
            | None -> "");
          Alcotest.(check string) "interface" "api"
            (Interface.to_string event.Activity.interface_)
      | [] -> Alcotest.fail "upsert не оставил следа в журнале"

(** Повторный импорт с теми же данными не трогает задачу: версия не растёт,
    журнал не пополняется. Иначе повтор поднимал бы версию всей базы. *)
let test_upsert_unchanged_data_keeps_version () =
  let task = create () in
  let same : Service.Task.create_input =
    {
      title = task.Task.title;
      description = task.Task.description;
      kind = task.Task.kind;
      status = task.Task.status;
      priority = task.Task.priority;
      due_at = task.Task.due_at;
      labels = task.Task.labels;
      source = task.Task.source;
      source_ref = task.Task.source_ref;
      project = Some project.Project.key;
      assignee = None;
      requester = None;
      parent = None;
    }
  in
  match
    Support.run (Service.Task.upsert conn ~actor:human ~interface_:Interface.Api same)
  with
  | Error e -> Alcotest.fail ("upsert не прошёл: " ^ Service.Failure.to_string e)
  | Ok (Service.Task.Updated _) -> Alcotest.fail "без изменений версия выросла"
  | Ok (Service.Task.Created _) -> Alcotest.fail "существующая задача создана заново"
  | Ok (Service.Task.Unchanged unchanged) ->
      Alcotest.(check string) "ref" task.Task.ref_ unchanged.Task.ref_;
      Alcotest.(check int) "version" task.Task.version unchanged.Task.version;
      match events_for task.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "action" "created"
            (Activity.action_to_string event.Activity.action)
      | [] -> Alcotest.fail "создание не оставило следа в журнале"

(** Upsert без ключа источника — плохой запрос: обновлять не по чему. *)
let test_upsert_requires_source_pair () =
  let bad = { (input ()) with source = None; source_ref = None } in
  let failure =
    expect_failure "upsert без ключа источника"
      (Service.Task.upsert conn ~actor:human ~interface_:Interface.Api bad)
  in
  match failure with
  | Service.Failure.Bad_request { message = _ } -> ()
  | other ->
      Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other)

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

(* ------------------------------------------------------- заявка и отпуск --- *)

(** Свободную задачу агент забирает себе: заявка — это и есть назначение
    себе, если задача ещё ни за кем не закреплена. *)
let test_claim_assigns_claimer () =
  let task = create ~status:Status.Todo () in
  match
    Support.run
      (Service.Task.claim conn ~actor:agent ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  with
  | Error e -> Alcotest.fail ("заявка не прошла: " ^ Service.Failure.to_string e)
  | Ok claimed ->
      Alcotest.(check string) "статус" "in_progress"
        (Status.to_string claimed.Task.status);
      Alcotest.(check bool) "исполнитель — заявитель" true
        (claimed.Task.assignee_id = Some agent.Actor.id)

(** Заявка не отменяет назначение, принятое ранее: назначенная задача
    остаётся у прежнего исполнителя. *)
let test_claim_keeps_existing_assignee () =
  let task = create ~status:Status.Todo ~assignee:colleague.Actor.handle () in
  match
    Support.run
      (Service.Task.claim conn ~actor:human ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  with
  | Error e -> Alcotest.fail ("заявка не прошла: " ^ Service.Failure.to_string e)
  | Ok claimed ->
      Alcotest.(check bool) "исполнитель прежний" true
        (claimed.Task.assignee_id = Some colleague.Actor.id)

(** Заявка только из todo: из backlog претендентов нет, из in_progress — тем
    более. *)
let test_claim_only_from_todo () =
  let task = create ~status:Status.Backlog () in
  let failure =
    expect_failure "заявка не из todo"
      (Service.Task.claim conn ~actor:agent ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  in
  match failure with
  | Service.Failure.Conflict { message = _ } -> ()
  | other -> Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other)

(** Отпуск только из in_progress: нечего отпускать у задачи, которую не
    брали в работу. *)
let test_release_only_from_in_progress () =
  let task = create ~status:Status.Todo () in
  let failure =
    expect_failure "отпуск не из in_progress"
      (Service.Task.release conn ~actor:agent ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  in
  match failure with
  | Service.Failure.Conflict { message = _ } -> ()
  | other -> Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other)

(** Посторонний агент чужую работу отпустить не может — отказ правила, а не
    сбой. *)
let test_stranger_agent_cannot_release () =
  let task = create ~status:Status.Todo () in
  match
    Support.run
      (Service.Task.claim conn ~actor:agent ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  with
  | Error e -> Alcotest.fail ("заявка не прошла: " ^ Service.Failure.to_string e)
  | Ok claimed ->
      let failure =
        expect_failure "отпуск посторонним агентом"
          (Service.Task.release conn ~actor:other_agent ~interface_:Interface.Cli
             ~ref_:task.Task.ref_ ~version:claimed.Task.version ~note:None)
      in
      (match failure with
      | Service.Failure.Forbidden { message; _ } ->
          Alcotest.(check bool) "сообщение" true (String.length message > 0)
      | other ->
          Alcotest.fail ("не тот отказ: " ^ Service.Failure.to_string other))

(** Отпуск возвращает задачу в пул: статус — todo, исполнитель снят. *)
let test_release_returns_task_to_pool () =
  let task = create ~status:Status.Todo () in
  match
    Support.run
      (Service.Task.claim conn ~actor:agent ~interface_:Interface.Cli
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  with
  | Error e -> Alcotest.fail ("заявка не прошла: " ^ Service.Failure.to_string e)
  | Ok claimed ->
      (match
         Support.run
           (Service.Task.release conn ~actor:agent ~interface_:Interface.Cli
              ~ref_:task.Task.ref_ ~version:claimed.Task.version ~note:None)
       with
      | Error e -> Alcotest.fail ("отпуск не прошёл: " ^ Service.Failure.to_string e)
      | Ok released ->
          Alcotest.(check string) "статус" "todo"
            (Status.to_string released.Task.status);
          Alcotest.(check bool) "исполнитель снят" true
            (released.Task.assignee_id = None))

(** Журнал помнит, что задачу заявили: действие [claimed]. *)
let test_claim_writes_journal () =
  let task = create ~status:Status.Todo () in
  match
    Support.run
      (Service.Task.claim conn ~actor:agent ~interface_:Interface.Mcp
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  with
  | Error e -> Alcotest.fail ("заявка не прошла: " ^ Service.Failure.to_string e)
  | Ok _ -> (
      match events_for task.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "action" "claimed"
            (Activity.action_to_string event.Activity.action);
          Alcotest.(check string) "from" "todo"
            (match event.Activity.from_value with
            | Some value -> value
            | None -> "");
          Alcotest.(check string) "to" "in_progress"
            (match event.Activity.to_value with
            | Some value -> value
            | None -> "");
          Alcotest.(check string) "interface" "mcp"
            (Interface.to_string event.Activity.interface_)
      | [] -> Alcotest.fail "заявка не оставила следа в журнале")

(** Журнал помнит, что задачу отпустили: действие [released]. *)
let test_release_writes_journal () =
  let task = create ~status:Status.Todo () in
  match
    Support.run
      (Service.Task.claim conn ~actor:agent ~interface_:Interface.Api
         ~ref_:task.Task.ref_ ~version:task.Task.version ~note:None)
  with
  | Error e -> Alcotest.fail ("заявка не прошла: " ^ Service.Failure.to_string e)
  | Ok claimed ->
      (match
         Support.run
           (Service.Task.release conn ~actor:agent ~interface_:Interface.Api
              ~ref_:task.Task.ref_ ~version:claimed.Task.version ~note:None)
       with
      | Error e -> Alcotest.fail ("отпуск не прошёл: " ^ Service.Failure.to_string e)
      | Ok _ -> (
          match events_for task.Task.ref_ with
          | event :: _ ->
              Alcotest.(check string) "action" "released"
                (Activity.action_to_string event.Activity.action);
              Alcotest.(check string) "from" "in_progress"
                (match event.Activity.from_value with
                | Some value -> value
                | None -> "");
              Alcotest.(check string) "to" "todo"
                (match event.Activity.to_value with
                | Some value -> value
                | None -> "")
          | [] -> Alcotest.fail "отпуск не оставил следа в журнале"))

(* ------------------------------------------------------ иерархия и связи --- *)

(** Класс отказа: по нему видно, чья это была вина — правила, клиента или
    хранилища. *)
let failure_class (failure : Service.Failure.t) =
  match failure with
  | Service.Failure.Bad_request _ -> "bad_request"
  | Service.Failure.Forbidden _ -> "forbidden"
  | Service.Failure.Not_found _ -> "not_found"
  | Service.Failure.Conflict _ -> "conflict"
  | Service.Failure.Unauthorized _ -> "unauthorized"
  | Service.Failure.Storage _ -> "storage"

(** Связь между задачами — отдельная сущность: у неё свой идентификатор,
    и журнал помнит, что связь записали. *)
let test_link_is_created () =
  let from_ = create () in
  let to_ = create () in
  match
    Support.run
      (Service.Task.link conn ~actor:human ~interface_:Interface.Api
         ~ref_:from_.Task.ref_ ~to_ref:to_.Task.ref_ ~kind:Link.Blocks)
  with
  | Error e -> Alcotest.fail ("связь не создана: " ^ Service.Failure.to_string e)
  | Ok link ->
      Alcotest.(check string) "вид" "blocks"
        (Link.to_string link.Db.Repo_link.kind);
      Alcotest.(check string) "откуда" from_.Task.id link.Db.Repo_link.from_id;
      Alcotest.(check string) "куда" to_.Task.id link.Db.Repo_link.to_id;
      (match events_for from_.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "action" "linked"
            (Activity.action_to_string event.Activity.action)
      | [] -> Alcotest.fail "связь не оставила следа в журнале")

(** Связь задачи с собой бессмысленна: это ошибка запроса, а не правила. *)
let test_link_to_self_is_refused () =
  let task = create () in
  let failure =
    expect_failure "самосвязь"
      (Service.Task.link conn ~actor:human ~interface_:Interface.Api
         ~ref_:task.Task.ref_ ~to_ref:task.Task.ref_ ~kind:Link.Relates_to)
  in
  Alcotest.(check string) "класс отказа" "bad_request" (failure_class failure)

(** Повторная связь — конфликт: тот же факт уже записан, а не новый. *)
let test_duplicate_link_is_conflict () =
  let from_ = create () in
  let to_ = create () in
  let ok_link =
    Support.run
      (Service.Task.link conn ~actor:human ~interface_:Interface.Api
         ~ref_:from_.Task.ref_ ~to_ref:to_.Task.ref_ ~kind:Link.Relates_to)
  in
  (match ok_link with
  | Error e -> Alcotest.fail ("связь не создана: " ^ Service.Failure.to_string e)
  | Ok _ -> ());
  let failure =
    expect_failure "повтор"
      (Service.Task.link conn ~actor:human ~interface_:Interface.Api
         ~ref_:from_.Task.ref_ ~to_ref:to_.Task.ref_ ~kind:Link.Relates_to)
  in
  Alcotest.(check string) "класс отказа" "conflict" (failure_class failure)

(** Кольцо блокировок превращает вопрос «кто мешает» в «все мешают всем» —
    поэтому кольцо запрещают, а с цепочкой в сообщении. *)
let test_blocking_cycle_is_refused () =
  let first = create () in
  let second = create () in
  let ok_link =
    Support.run
      (Service.Task.link conn ~actor:human ~interface_:Interface.Api
         ~ref_:first.Task.ref_ ~to_ref:second.Task.ref_ ~kind:Link.Blocks)
  in
  (match ok_link with
  | Error e -> Alcotest.fail ("связь не создана: " ^ Service.Failure.to_string e)
  | Ok _ -> ());
  let failure =
    expect_failure "кольцо"
      (Service.Task.link conn ~actor:human ~interface_:Interface.Api
         ~ref_:second.Task.ref_ ~to_ref:first.Task.ref_ ~kind:Link.Blocks)
  in
  Alcotest.(check string) "класс отказа" "bad_request" (failure_class failure);
  match failure with
  | Service.Failure.Bad_request { message } ->
      Alcotest.(check bool) "в сообщении есть цепочка" true
        (String.length message > 0)
  | _ -> Alcotest.fail "не тот класс отказа"

(** Снятие связи убирает её из графа; задачи остаются на месте. *)
let test_unlink_removes_link () =
  let from_ = create () in
  let to_ = create () in
  let link =
    match
      Support.run
        (Service.Task.link conn ~actor:human ~interface_:Interface.Api
           ~ref_:from_.Task.ref_ ~to_ref:to_.Task.ref_ ~kind:Link.Relates_to)
    with
    | Error e -> Alcotest.fail ("связь не создана: " ^ Service.Failure.to_string e)
    | Ok link -> link
  in
  match
    Support.run
      (Service.Task.unlink conn ~actor:human ~interface_:Interface.Api
         ~ref_:from_.Task.ref_ ~link_id:link.Db.Repo_link.id)
  with
  | Error e -> Alcotest.fail ("связь не снята: " ^ Service.Failure.to_string e)
  | Ok () ->
      let details =
        match Support.run (Service.Task.get conn ~ref_:from_.Task.ref_) with
        | Ok details -> details
        | Error e -> Alcotest.fail ("задача не прочитана: " ^ Service.Failure.to_string e)
      in
      Alcotest.(check int) "связей не осталось" 0
        (List.length details.Service.Task.links);
      (match events_for from_.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "action" "unlinked"
            (Activity.action_to_string event.Activity.action)
      | [] -> Alcotest.fail "снятие связи не оставило следа в журнале")

(** Снять чужую связь из чужой задачи — не то действие, о котором просили. *)
let test_unlink_of_foreign_link_is_not_found () =
  let owner = create () in
  let other = create () in
  let target = create () in
  let link =
    match
      Support.run
        (Service.Task.link conn ~actor:human ~interface_:Interface.Api
           ~ref_:owner.Task.ref_ ~to_ref:target.Task.ref_ ~kind:Link.Relates_to)
    with
    | Error e -> Alcotest.fail ("связь не создана: " ^ Service.Failure.to_string e)
    | Ok link -> link
  in
  let failure =
    expect_failure "чужая связь"
      (Service.Task.unlink conn ~actor:human ~interface_:Interface.Api
         ~ref_:other.Task.ref_ ~link_id:link.Db.Repo_link.id)
  in
  Alcotest.(check string) "класс отказа" "not_found" (failure_class failure)

(** Смена родителя переносит задачу в ветку; журнал помнит, что сменили. *)
let test_set_parent_moves_task () =
  let parent = create () in
  let child = create () in
  match
    Support.run
      (Service.Task.set_parent conn ~actor:human ~interface_:Interface.Api
         ~ref_:child.Task.ref_ ~parent_ref:(Some parent.Task.ref_)
         ~version:child.Task.version)
  with
  | Error e -> Alcotest.fail ("родитель не сменён: " ^ Service.Failure.to_string e)
  | Ok moved ->
      Alcotest.(check string) "родитель записан" parent.Task.id
        (match moved.Task.parent_id with Some id -> id | None -> "");
      (match events_for child.Task.ref_ with
      | event :: _ ->
          Alcotest.(check string) "action" "updated"
            (Activity.action_to_string event.Activity.action)
      | [] -> Alcotest.fail "смена родителя не оставила следа в журнале")

(** Родителем нельзя назначить собственного потомка: дерево замкнулось бы
    в кольцо. *)
let test_parent_cycle_is_refused () =
  let parent = create () in
  let child = create ~parent:parent.Task.ref_ () in
  let failure =
    expect_failure "потомок в родители"
      (Service.Task.set_parent conn ~actor:human ~interface_:Interface.Api
         ~ref_:parent.Task.ref_ ~parent_ref:(Some child.Task.ref_)
         ~version:parent.Task.version)
  in
  Alcotest.(check string) "класс отказа" "bad_request" (failure_class failure)

(** Родителя не закрывают, пока открыты дети: сводка не должна врать. *)
let test_parent_with_open_child_is_not_closed () =
  let parent = create () in
  let _child = create ~parent:parent.Task.ref_ () in
  let step target version note =
    match
      Support.run
        (Service.Task.transition conn ~actor:human ~interface_:Interface.Api
           ~ref_:parent.Task.ref_ ~target ~version ~note)
    with
    | Error e ->
        Alcotest.fail
          ("переход не прошёл: " ^ Service.Failure.to_string e ^ " (ожидался успех)")
    | Ok task -> task
  in
  let todo = step Status.Todo parent.Task.version None in
  let started = step Status.In_progress todo.Task.version None in
  let review =
    step Status.In_review started.Task.version (Some "сделал, проверил")
  in
  let failure =
    expect_failure "приёмка с открытым ребёнком"
      (Service.Task.transition conn ~actor:human ~interface_:Interface.Api
         ~ref_:parent.Task.ref_ ~target:Status.Done
         ~version:review.Task.version ~note:None)
  in
  Alcotest.(check string) "класс отказа" "forbidden" (failure_class failure)

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
      ( "импорт",
        [
          Alcotest.test_case "повтор обновляет задачу" `Quick
            test_upsert_updates_existing_task;
          Alcotest.test_case "без изменений версия не растёт" `Quick
            test_upsert_unchanged_data_keeps_version;
          Alcotest.test_case "без ключа источника — плохой запрос" `Quick
            test_upsert_requires_source_pair;
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
      ( "заявка и отпуск",
        [
          Alcotest.test_case "свободную задачу забирает заявитель" `Quick
            test_claim_assigns_claimer;
          Alcotest.test_case "назначение не отменяется" `Quick
            test_claim_keeps_existing_assignee;
          Alcotest.test_case "заявка только из todo" `Quick
            test_claim_only_from_todo;
          Alcotest.test_case "отпуск только из in_progress" `Quick
            test_release_only_from_in_progress;
          Alcotest.test_case "посторонний агент не отпускает" `Quick
            test_stranger_agent_cannot_release;
          Alcotest.test_case "отпуск возвращает в пул" `Quick
            test_release_returns_task_to_pool;
          Alcotest.test_case "заявка пишет в журнал" `Quick
            test_claim_writes_journal;
          Alcotest.test_case "отпуск пишет в журнал" `Quick
            test_release_writes_journal;
        ] );
      ( "иерархия и связи",
        [
          Alcotest.test_case "связь записана" `Quick
            test_link_is_created;
          Alcotest.test_case "связь с собой отклонена" `Quick
            test_link_to_self_is_refused;
          Alcotest.test_case "повторная связь — конфликт" `Quick
            test_duplicate_link_is_conflict;
          Alcotest.test_case "кольцо блокировок отклонено" `Quick
            test_blocking_cycle_is_refused;
          Alcotest.test_case "снятие связи убирает её" `Quick
            test_unlink_removes_link;
          Alcotest.test_case "чужая связь — не найдена" `Quick
            test_unlink_of_foreign_link_is_not_found;
          Alcotest.test_case "смена родителя переносит задачу" `Quick
            test_set_parent_moves_task;
          Alcotest.test_case "цикл по родителю отклонён" `Quick
            test_parent_cycle_is_refused;
          Alcotest.test_case "родитель с открытым ребёнком не закрыт" `Quick
            test_parent_with_open_child_is_not_closed;
        ] );
      ( "классы отказов",
        [
          Alcotest.test_case "запрет и сбой различаются" `Quick
            test_failure_classes_are_distinct;
        ] );
    ]
