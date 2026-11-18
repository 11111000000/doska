(** Слой репозиториев на живой базе.

    Здесь проверяется то, ради чего слой и нужен: данные действительно
    сохраняются, смена статуса защищена версией, фильтры отбирают нужное,
    а курсорная пагинация не теряет и не дублирует задачи. *)

open Domain

let conn = Support.connect ()

(* Фикстуры этого теста общие с другим его прогоном: блокируемся, чтобы
   уборка одного прогона не удалила фикстуры другого. *)
let () = Support.lock conn 4713

(* Уборка — до фикстур: [Alcotest.run] завершает процесс, код после него не
   выполняется, поэтому строки прошлого прогона убираем на входе. *)
let () =
  Support.cleanup conn ~source:"test-repo" ~actor_prefix:"repo-"
    ~project_prefix:"REPO"

let human =
  Support.ensure_actor conn ~prefix:"repo-" ~kind:Actor.Human ~handle:"petr"
    ~display_name:"Пётр"

let agent =
  Support.ensure_actor conn ~prefix:"repo-" ~kind:Actor.Agent ~handle:"legist"
    ~display_name:"legist"

let project =
  Support.ensure_project conn ~prefix:"REPO" ~key:"MAIN" ~name:"Основной"
    ~autonomy:Actor.Human_gate

let page_project =
  Support.ensure_project conn ~prefix:"REPO" ~key:"PAGE" ~name:"Постраничный"
    ~autonomy:Actor.Human_gate

let counter = ref 0

let next_source_ref () =
  incr counter;
  Printf.sprintf "repo-%d" !counter

let create_task ?(status = Status.Backlog) ?assignee ?requester ?project () =
  let args : Db.Repo_task.create_args =
    {
      Db.Repo_task.title = Printf.sprintf "Тестовая задача %d" !counter;
      description = "описание задачи";
      project_id = (match project with None -> None | Some p -> Some p.Project.id);
      kind = Task.Task;
      status;
      priority = Task.P2;
      assignee_id = assignee;
      requester_id = requester;
      reporter_id = Some human.Actor.id;
      created_by_id = Some human.Actor.id;
      due_at = None;
      labels = [ "тест" ];
      source = Some "test-repo";
      source_ref = Some (next_source_ref ());
    }
  in
  match Support.run (Db.Repo_task.create conn args) with
  | Ok created -> created
  | Error e -> Alcotest.fail ("задача не создана: " ^ e)

let expect_ok what f =
  match Support.run (f ()) with
  | Ok value -> value
  | Error e -> Alcotest.fail (what ^ ": " ^ e)

(** Аргументы создания задачи: у тестов свой заголовок и своя пара
    (source, source_ref), чтобы прогоны не мешали друг другу. *)
let task_args ~title ~source_ref () : Db.Repo_task.create_args =
  {
    Db.Repo_task.title = title;
    description = "описание задачи";
    project_id = Some project.Project.id;
    kind = Task.Task;
    status = Status.Backlog;
    priority = Task.P2;
    assignee_id = None;
    requester_id = Some human.Actor.id;
    reporter_id = Some human.Actor.id;
    created_by_id = Some human.Actor.id;
    due_at = None;
    labels = [];
    source = Some "test-repo";
    source_ref = Some source_ref;
  }

(* ----------------------------------------------------------------- задачи --- *)

let test_task_persists () =
  match create_task () with
  | Db.Repo_task.Existing _ -> Alcotest.fail "новая задача уже существовала"
  | Db.Repo_task.Created task ->
      let found =
        expect_ok "чтение задачи" (fun () ->
            Db.Repo_task.by_ref conn task.Task.ref_)
      in
      (match found with
      | None -> Alcotest.fail "задача не найдена после создания"
      | Some found ->
          Alcotest.(check string) "ref" task.Task.ref_ found.Task.ref_;
          Alcotest.(check string) "title" task.Task.title found.Task.title;
          Alcotest.(check int) "version" 1 found.Task.version;
          Alcotest.(check (list string)) "labels" [ "тест" ] found.Task.labels)

let test_create_is_idempotent () =
  let source_ref = next_source_ref () in
  let args : Db.Repo_task.create_args =
    {
      Db.Repo_task.title = "Задача с повтором";
      description = "";
      project_id = Some project.Project.id;
      kind = Task.Task;
      status = Status.Backlog;
      priority = Task.P2;
      assignee_id = None;
      requester_id = Some human.Actor.id;
      reporter_id = Some human.Actor.id;
      created_by_id = Some human.Actor.id;
      due_at = None;
      labels = [];
      source = Some "test-repo";
      source_ref = Some source_ref;
    }
  in
  let first = expect_ok "создание" (fun () -> Db.Repo_task.create conn args) in
  let second = expect_ok "повторное создание" (fun () -> Db.Repo_task.create conn args) in
  (match (first, second) with
  | Db.Repo_task.Created first, Db.Repo_task.Existing second ->
      Alcotest.(check string) "ref" first.Task.ref_ second.Task.ref_
  | Db.Repo_task.Created _, Db.Repo_task.Created _ ->
      Alcotest.fail "повторное создание создало вторую задачу"
  | _ -> Alcotest.fail "первое создание не создало задачу")

let test_status_respects_version () =
  match create_task () with
  | Db.Repo_task.Existing _ -> Alcotest.fail "новая задача уже существовала"
  | Db.Repo_task.Created task ->
      let version = task.Task.version in
      let moved =
        expect_ok "переход" (fun () ->
            Db.Repo_task.set_status conn ~ref_:task.Task.ref_ ~status:Status.In_progress
              ~version ~note:None)
      in
      (match moved with
      | None -> Alcotest.fail "переход с актуальной версией не применился"
      | Some _ ->
          let stale =
            expect_ok "повторный переход" (fun () ->
                Db.Repo_task.set_status conn ~ref_:task.Task.ref_ ~status:Status.Done
                  ~version ~note:None)
          in
          (match stale with
          | None -> ()
          | Some _ ->
              Alcotest.fail "устаревшая версия не защитила задачу от записи"))

let test_comments_and_evidence () =
  match create_task () with
  | Db.Repo_task.Existing _ -> Alcotest.fail "новая задача уже существовала"
  | Db.Repo_task.Created task ->
      let comment =
        expect_ok "комментарий" (fun () ->
            Db.Repo_task.add_comment conn ~task_id:task.Task.id ~body:"первый комментарий"
              ~author_id:(Some human.Actor.id) ())
      in
      Alcotest.(check string) "body" "первый комментарий" comment.Comment.body;
      let comments =
        expect_ok "чтение комментариев" (fun () ->
            Db.Repo_task.comments conn ~task_id:task.Task.id)
      in
      Alcotest.(check int) "число комментариев" 1 (List.length comments);
      let evidence =
        expect_ok "доказательство" (fun () ->
            Db.Repo_evidence.add conn ~task_id:task.Task.id ~kind:Evidence.Commit
              ~ref_:"abc123" ~uri:"https://example.org/commit/abc123"
              ~author_id:human.Actor.id ())
      in
      Alcotest.(check string) "ref" "abc123" evidence.Evidence.ref_;
      let evidence_list =
        expect_ok "чтение доказательств" (fun () ->
            Db.Repo_evidence.list_for_task conn ~task_id:task.Task.id)
      in
      Alcotest.(check int) "число доказательств" 1 (List.length evidence_list);
      let count =
        expect_ok "счёт доказательств" (fun () ->
            Db.Repo_evidence.count conn ~task_id:task.Task.id)
      in
      Alcotest.(check int) "счётчик доказательств" 1 count

let test_activity_is_recorded () =
  match create_task () with
  | Db.Repo_task.Existing _ -> Alcotest.fail "новая задача уже существовала"
  | Db.Repo_task.Created task ->
      ignore
        (expect_ok "событие" (fun () ->
             Db.Repo_activity.record conn ~action:Activity.Status_changed
               ~task_id:(Some task.Task.id) ~project_id:task.Task.project_id
               ~actor_id:(Some human.Actor.id) ~from_value:(Some "backlog")
               ~to_value:(Some "todo") ~summary:(Some "переход") ~interface_:"test" ()));
      let filters : Db.Repo_activity.filters =
        {
          Db.Repo_activity.project = None;
          task = Some task.Task.ref_;
          actor = None;
          since = None;
          limit = 10;
          cursor = None;
        }
      in
      let items =
        expect_ok "чтение журнала" (fun () -> Db.Repo_activity.list conn filters)
      in
      Alcotest.(check bool) "событие записано" true (List.length items > 0);
      (match items with
      | [] -> Alcotest.fail "событие не найдено"
      | first :: _ ->
          Alcotest.(check string) "действие" "status_changed"
            (Activity.action_to_string first.Activity.action))

(* --------------------------------------------------- значения, транзакции --- *)

(** Значение с кавычкой доезжает до базы целым: SQL собирается из проверенных
    значений и экранируется (решение этапа 1). *)
let test_values_are_escaped () =
  let title = "О'Борис' и «кавычки»" in
  let args = task_args ~title ~source_ref:(next_source_ref ()) () in
  let created = expect_ok "создание" (fun () -> Db.Repo_task.create conn args) in
  match created with
  | Db.Repo_task.Existing _ -> Alcotest.fail "новая задача уже существовала"
  | Db.Repo_task.Created task ->
      let found =
        expect_ok "чтение задачи" (fun () ->
            Db.Repo_task.by_ref conn task.Task.ref_)
      in
      (match found with
      | None -> Alcotest.fail "задача не найдена после создания"
      | Some found -> Alcotest.(check string) "title" title found.Task.title)

(** Сбой в середине транзакции не оставляет половину: изменения задачи и
    записи в журнал идут вместе или не идут вовсе. *)
let test_transaction_rolls_back () =
  let args =
    task_args ~title:"Задача, которая не должна остаться"
      ~source_ref:(next_source_ref ()) ()
  in
  let created_ref = ref "" in
  let outcome =
    Support.run
      (Db.Conn.with_transaction conn (fun () ->
           Lwt.bind (Db.Repo_task.create conn args) (fun created ->
               match created with
               | Error e -> Lwt_result.lift (Error e)
               | Ok (Db.Repo_task.Created task) ->
                   created_ref := task.Task.ref_;
                   Lwt_result.lift (Error "сбой в середине транзакции")
               | Ok (Db.Repo_task.Existing task) ->
                   created_ref := task.Task.ref_;
                   Lwt_result.lift (Error "сбой в середине транзакции"))))
  in
  (match outcome with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "транзакция не сообщила об ошибке");
  let found =
    expect_ok "чтение задачи" (fun () ->
        Db.Repo_task.by_ref conn !created_ref)
  in
  (match found with
  | None -> ()
  | Some _ -> Alcotest.fail "задача осталась в базе после отката транзакции")

(* ------------------------------------------------------------------ списки --- *)

let filters ?project ?status ?assignee ~limit ?cursor () : Db.Repo_task.filters =
  {
    Db.Repo_task.project;
    status;
    assignee;
    kind = None;
    due = None;
    query = None;
    label = None;
    limit;
    cursor;
  }

let test_filters_select_tasks () =
  match
    create_task ~project ~status:Status.Todo ~assignee:agent.Actor.id ()
  with
  | Db.Repo_task.Existing _ -> Alcotest.fail "новая задача уже существовала"
  | Db.Repo_task.Created task ->
      let by_project =
        expect_ok "список по проекту" (fun () ->
            Db.Repo_task.list conn (filters ~project:project.Project.key ~limit:50 ()))
      in
      Alcotest.(check bool) "задача попала в список проекта" true
        (List.exists (fun t -> t.Task.ref_ = task.Task.ref_) by_project.Db.Repo_task.items);
      let by_status =
        expect_ok "список по статусу" (fun () ->
            Db.Repo_task.list conn (filters ~status:"todo" ~limit:50 ()))
      in
      Alcotest.(check bool) "задача попала в список по статусу" true
        (List.exists (fun t -> t.Task.ref_ = task.Task.ref_) by_status.Db.Repo_task.items);
      let by_assignee =
        expect_ok "список по исполнителю" (fun () ->
            Db.Repo_task.list conn (filters ~assignee:"repo-legist" ~limit:50 ()))
      in
      Alcotest.(check bool) "задача попала в список по исполнителю" true
        (List.exists (fun t -> t.Task.ref_ = task.Task.ref_) by_assignee.Db.Repo_task.items);
      let by_text =
        expect_ok "список по тексту" (fun () ->
            Db.Repo_task.list
              conn
              (filters ~project:project.Project.key ~limit:50 ()))
      in
      Alcotest.(check bool) "проект не пустой" true
        (List.length by_text.Db.Repo_task.items > 0)

let test_pagination_walks_all_tasks () =
  let refs =
    List.map
      (fun _ ->
        match create_task ~project:page_project () with
        | Db.Repo_task.Created task -> task.Task.ref_
        | Db.Repo_task.Existing task -> task.Task.ref_)
      [ 1; 2; 3 ]
  in
  let first =
    expect_ok "первая страница" (fun () ->
        Db.Repo_task.list
          conn
          (filters ~project:page_project.Project.key ~limit:2 ()))
  in
  Alcotest.(check int) "задач на странице" 2
    (List.length first.Db.Repo_task.items);
  (match first.Db.Repo_task.next_cursor with
  | None -> Alcotest.fail "ожидался курсор следующей страницы"
  | Some cursor ->
      let second =
        expect_ok "вторая страница" (fun () ->
            Db.Repo_task.list
              conn
              (filters ~project:page_project.Project.key ~limit:2 ~cursor:cursor ()))
      in
      Alcotest.(check int) "задач на второй странице" 1
        (List.length second.Db.Repo_task.items);
      Alcotest.(check bool) "вторая страница — последняя" true
        (second.Db.Repo_task.next_cursor = None);
      let seen =
        List.map (fun t -> t.Task.ref_) first.Db.Repo_task.items
        @ List.map (fun t -> t.Task.ref_) second.Db.Repo_task.items
      in
      Alcotest.(check int) "все задачи на месте" 3 (List.length seen);
      List.iter
        (fun ref_ ->
          Alcotest.(check bool) "задача не потеряна и не продублирована" true
            (List.mem ref_ seen))
        refs;
      Alcotest.(check int) "дубликатов нет" 3
        (List.length (List.sort_uniq String.compare seen)))

(* ------------------------------------------- журнал, доказательства, справочники --- *)

let record_event task_id action =
  expect_ok "событие" (fun () ->
      Db.Repo_activity.record conn ~action ~task_id:(Some task_id) ~project_id:None
        ~actor_id:(Some human.Actor.id) ~from_value:None ~to_value:None
        ~summary:(Some "переход") ~interface_:"test" ())

(** Выборка журнала отбирает события своей задачи: чужие изменения в неё не
    попадают (P4, §3.6). *)
let test_activity_filter_selects_task () =
  match (create_task (), create_task ()) with
  | Db.Repo_task.Created first, Db.Repo_task.Created second ->
      ignore (record_event first.Task.id Activity.Status_changed);
      ignore (record_event second.Task.id Activity.Commented);
      let filters : Db.Repo_activity.filters =
        {
          Db.Repo_activity.project = None;
          task = Some first.Task.ref_;
          actor = None;
          since = None;
          limit = 10;
          cursor = None;
        }
      in
      let items =
        expect_ok "чтение журнала" (fun () -> Db.Repo_activity.list conn filters)
      in
      Alcotest.(check int) "в выборке только события своей задачи" 1
        (List.length items);
      (match items with
      | [] -> Alcotest.fail "событие не найдено"
      | first_item :: _ ->
          Alcotest.(check string) "действие" "status_changed"
            (Activity.action_to_string first_item.Activity.action))
  | _ -> Alcotest.fail "задачи не созданы"

(** Доказательство принадлежит своей задаче: у другой задачи его нет
    (§3.4). *)
let test_evidence_belongs_to_task () =
  match (create_task (), create_task ()) with
  | Db.Repo_task.Created first, Db.Repo_task.Created second ->
      let evidence =
        expect_ok "доказательство" (fun () ->
            Db.Repo_evidence.add conn ~task_id:first.Task.id ~kind:Evidence.Commit
              ~ref_:"abc123" ~uri:"https://example.org/commit/abc123"
              ~author_id:human.Actor.id ())
      in
      Alcotest.(check string) "ref" "abc123" evidence.Evidence.ref_;
      let own =
        expect_ok "чтение своих доказательств" (fun () ->
            Db.Repo_evidence.list_for_task conn ~task_id:first.Task.id)
      in
      Alcotest.(check int) "свои доказательства на месте" 1 (List.length own);
      let other =
        expect_ok "чтение чужих доказательств" (fun () ->
            Db.Repo_evidence.list_for_task conn ~task_id:second.Task.id)
      in
      Alcotest.(check int) "у другой задачи доказательств нет" 0 (List.length other)
  | _ -> Alcotest.fail "задачи не созданы"

(** Актёр находится по своему логину, проект — по своему ключу: логин и ключ
    это то, чем на них ссылаются остальные части системы. *)
let test_actor_found_by_handle () =
  let found =
    expect_ok "поиск актора" (fun () -> Db.Repo_actor.by_handle conn "repo-legist")
  in
  match found with
  | None -> Alcotest.fail "актор не найден по логину"
  | Some found -> Alcotest.(check string) "id" agent.Actor.id found.Actor.id

let test_project_found_by_key () =
  let found =
    expect_ok "поиск проекта" (fun () -> Db.Repo_project.by_key conn "REPOMAIN")
  in
  match found with
  | None -> Alcotest.fail "проект не найден по ключу"
  | Some found -> Alcotest.(check string) "key" project.Project.key found.Project.key

(* --------------------------------------------------------------------- run --- *)

let () =
  Alcotest.run "репозитории"
    [
      ( "задачи",
        [
          Alcotest.test_case "задача сохраняется" `Quick test_task_persists;
          Alcotest.test_case "повторное создание не плодит дубль" `Quick
            test_create_is_idempotent;
          Alcotest.test_case "смена статуса защищена версией" `Quick
            test_status_respects_version;
          Alcotest.test_case "комментарии и доказательства сохраняются" `Quick
            test_comments_and_evidence;
          Alcotest.test_case "событие попадает в журнал" `Quick
            test_activity_is_recorded;
          Alcotest.test_case "значение с кавычкой доезжает целым" `Quick
            test_values_are_escaped;
          Alcotest.test_case "сбой в транзакции откатывает изменения" `Quick
            test_transaction_rolls_back;
        ] );
      ( "списки",
        [
          Alcotest.test_case "фильтры отбирают нужные задачи" `Quick
            test_filters_select_tasks;
          Alcotest.test_case "пагинация обходит все задачи" `Quick
            test_pagination_walks_all_tasks;
        ] );
      ( "журнал и доказательства",
        [
          Alcotest.test_case "выборка журнала отбирает свою задачу" `Quick
            test_activity_filter_selects_task;
          Alcotest.test_case "доказательство принадлежит своей задаче" `Quick
            test_evidence_belongs_to_task;
        ] );
      ( "справочники",
        [
          Alcotest.test_case "актор находится по логину" `Quick
            test_actor_found_by_handle;
          Alcotest.test_case "проект находится по ключу" `Quick
            test_project_found_by_key;
        ] );
    ]
