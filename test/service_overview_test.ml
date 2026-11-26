(** Сводка по трекеру на живой базе.

    Сводка отвечает на вопрос «что сейчас происходит в трекере», и ответ
    глобальный: открытые задачи, нагрузка, застой. Значит, числа нельзя
    проверять на общей базе проекта — там чужие задачи, и счётчик «открыто»
    зависит от чужой работы. Поэтому у этого теста своя база: имя
    подставляется в [DOSKA_DATABASE_URL], способ подключения остаётся тем же,
    что и в окружении. *)

open Domain

(* ------------------------------------------------------------------- база --- *)

let test_db = "doska_overview_test"

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

    В CI база одна на весь прогон, а сводке нужна своя: иначе числа в ответе
    зависят от чужих задач, и проверка перестаёт быть проверкой. *)
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
let () = Support.lock conn 4716

(* Уборка — до фикстур: [Alcotest.run] завершает процесс, код после него не
   выполняется, поэтому строки прошлого прогона убираем на входе. *)
let () =
  Support.cleanup conn ~source:"test-overview" ~actor_prefix:"ov-"
    ~project_prefix:"OV"

(* --------------------------------------------------------------- фикстуры --- *)

let petr =
  Support.ensure_actor conn ~prefix:"ov-" ~kind:Actor.Human ~handle:"petr"
    ~display_name:"Пётр"

let legist =
  Support.ensure_actor conn ~prefix:"ov-" ~kind:Actor.Agent ~handle:"legist"
    ~display_name:"legist"

let other =
  Support.ensure_actor conn ~prefix:"ov-" ~kind:Actor.Human ~handle:"other"
    ~display_name:"Другой"

let main_project =
  Support.ensure_project conn ~prefix:"OV" ~key:"MAIN" ~name:"Основной"
    ~autonomy:Actor.Human_gate

(* Проект без задач: в сводке он — шум, и проверяется именно этим. *)
let empty_project =
  Support.ensure_project conn ~prefix:"OV" ~key:"EMPTY" ~name:"Пустой"
    ~autonomy:Actor.Human_gate

let counter = ref 0

let next_source_ref () =
  incr counter;
  Printf.sprintf "ov-%d" !counter

let create ~title ~status ~assignee ~project () =
  let input : Service.Task.create_input =
    {
      title;
      description = "описание задачи";
      kind = Task.Task;
      status;
      priority = Task.P2;
      due_at = None;
      labels = [];
      source = Some "test-overview";
      source_ref = Some (next_source_ref ());
      project;
      assignee;
      requester = None;
      parent = None;
    }
  in
  match
    Support.run
      (Service.Task.create conn ~actor:petr ~interface_:Interface.Api input)
  with
  | Ok (Db.Repo_task.Created task) -> task
  | Ok (Db.Repo_task.Existing _) -> Alcotest.fail "задача уже существовала"
  | Error e ->
      Alcotest.fail ("задача не создана: " ^ Service.Failure.to_string e)

(** Задать возраст задачи: [updated_at] двигается назад, чтобы сводка увидела
    застой.

    Прямой [UPDATE], а не доменный переход: «состарить» задачу домен не умеет,
    а проверять надо именно срез по времени. *)
let age task days =
  let sql =
    Printf.sprintf
      "UPDATE task SET updated_at = now() - make_interval(days => %d) WHERE id = %s"
      days (Db.Conn.quote task.Task.id)
  in
  match Support.run (Db.Conn.exec_sql conn sql) with
  | Ok () -> ()
  | Error e -> Alcotest.fail ("возраст задачи не задан: " ^ e)

let todo_petr = create ~title:"todo у Пётра" ~status:Status.Todo ~assignee:(Some petr.Actor.handle) ~project:(Some main_project.Project.key) ()
let in_progress_legist = create ~title:"в работе у legist" ~status:Status.In_progress ~assignee:(Some legist.Actor.handle) ~project:(Some main_project.Project.key) ()
let blocked_legist = create ~title:"заблокирована у legist" ~status:Status.Blocked ~assignee:(Some legist.Actor.handle) ~project:(Some main_project.Project.key) ()
let needs_input_petr = create ~title:"ждёт ответа" ~status:Status.Needs_input ~assignee:(Some petr.Actor.handle) ~project:(Some main_project.Project.key) ()
let unassigned = create ~title:"без исполнителя" ~status:Status.Todo ~assignee:None ~project:(Some main_project.Project.key) ()
let no_project = create ~title:"вне проекта" ~status:Status.Todo ~assignee:(Some other.Actor.handle) ~project:None ()
let done_task = create ~title:"сделана" ~status:Status.Done ~assignee:(Some other.Actor.handle) ~project:(Some main_project.Project.key) ()
let cancelled_task = create ~title:"отменена" ~status:Status.Cancelled ~assignee:(Some other.Actor.handle) ~project:(Some main_project.Project.key) ()
let stuck_50 = create ~title:"застряла 50 дней" ~status:Status.In_progress ~assignee:(Some legist.Actor.handle) ~project:(Some main_project.Project.key) ()
let stuck_40 = create ~title:"застряла 40 дней" ~status:Status.In_progress ~assignee:(Some legist.Actor.handle) ~project:(Some main_project.Project.key) ()
let stuck_30 = create ~title:"застряла 30 дней" ~status:Status.In_progress ~assignee:(Some legist.Actor.handle) ~project:(Some main_project.Project.key) ()
let fresh_3 = create ~title:"начата три дня назад" ~status:Status.In_progress ~assignee:(Some legist.Actor.handle) ~project:(Some main_project.Project.key) ()

(* Возраст задач: застой наступает после недели молчания. *)
let () =
  age needs_input_petr 30;
  age stuck_50 50;
  age stuck_40 40;
  age stuck_30 30;
  age fresh_3 3

(* ------------------------------------------------------------------ сводка --- *)

let overview ?stuck_days ?limit () =
  match Support.run (Service.Overview.get conn ?stuck_days ?limit ()) with
  | Ok s -> s
  | Error e ->
      Alcotest.fail ("сводка не получена: " ^ Service.Failure.to_string e)

let wip_by_handle s =
  List.map (fun w -> w.Db.Repo_overview.handle) s.Service.Overview.wip_by_actor

let wip s handle =
  List.find_opt
    (fun w -> w.Db.Repo_overview.handle = handle)
    s.Service.Overview.wip_by_actor

let project_load s key =
  List.find_opt
    (fun l -> l.Db.Repo_overview.key = key)
    s.Service.Overview.by_project

let stuck_refs s = List.map (fun a -> a.Db.Repo_overview.task.Task.ref_) s.Service.Overview.stuck

let needs_input_refs s =
  List.map (fun a -> a.Db.Repo_overview.task.Task.ref_) s.Service.Overview.needs_input

(* ------------------------------------------------------------------ тесты --- *)

let test_totals_count_open_tasks () =
  let s = overview () in
  let totals = s.Service.Overview.totals in
  Alcotest.(check int) "открытых задач" 10 totals.Db.Repo_overview.open_tasks;
  Alcotest.(check int) "в работе" 5 totals.Db.Repo_overview.in_progress;
  Alcotest.(check int) "заблокировано" 1 totals.Db.Repo_overview.blocked;
  Alcotest.(check int) "ждут ответа" 1 totals.Db.Repo_overview.needs_input;
  Alcotest.(check int) "без исполнителя" 1 totals.Db.Repo_overview.unassigned;
  Alcotest.(check int) "вне проекта" 1 totals.Db.Repo_overview.without_project

let test_wip_counts_open_tasks_by_actor () =
  let s = overview () in
  Alcotest.(check (list string)) "порядок нагрузки"
    [ "ov-legist"; "ov-petr"; "ov-other" ]
    (wip_by_handle s);
  let legist = Option.get (wip s "ov-legist") in
  Alcotest.(check int) "задач у legist" 6 legist.Db.Repo_overview.open_tasks;
  Alcotest.(check int) "в работе у legist" 5 legist.Db.Repo_overview.in_progress;
  Alcotest.(check int) "ждут ответа у legist" 0 legist.Db.Repo_overview.needs_input;
  let petr = Option.get (wip s "ov-petr") in
  Alcotest.(check int) "задач у Пётра" 2 petr.Db.Repo_overview.open_tasks;
  Alcotest.(check int) "ждут ответа у Пётра" 1 petr.Db.Repo_overview.needs_input;
  let other = Option.get (wip s "ov-other") in
  Alcotest.(check int) "задач у Другого" 1 other.Db.Repo_overview.open_tasks

let test_closed_tasks_are_not_counted () =
  let s = overview () in
  let refs = stuck_refs s @ needs_input_refs s in
  Alcotest.(check bool) "сделанная задача не в списках" false
    (List.mem done_task.Task.ref_ refs);
  Alcotest.(check bool) "отменённая задача не в списках" false
    (List.mem cancelled_task.Task.ref_ refs);
  Alcotest.(check bool) "задача без проекта не в нагрузке по проектам" false
    (project_load s "OVEMPTY" <> None)

let test_project_load_only_with_open_tasks () =
  let s = overview () in
  let load = Option.get (project_load s "OVMAIN") in
  Alcotest.(check int) "открытых задач в проекте" 9 load.Db.Repo_overview.open_tasks;
  Alcotest.(check int) "застрявших в проекте" 3 load.Db.Repo_overview.stuck;
  Alcotest.(check bool) "пустой проект не попал в сводку" false
    (project_load s "OVEMPTY" <> None)

let test_stuck_lists_oldest_started_tasks () =
  let s = overview () in
  Alcotest.(check (list string)) "застрявшие по убыванию возраста"
    [ stuck_50.Task.ref_; stuck_40.Task.ref_; stuck_30.Task.ref_ ]
    (stuck_refs s);
  let ages = List.map (fun a -> a.Db.Repo_overview.age_days) s.Service.Overview.stuck in
  Alcotest.(check (list int)) "возраст в сутках" [ 50; 40; 30 ] ages

let test_needs_input_is_separate_list () =
  let s = overview () in
  Alcotest.(check (list string)) "ждущие ответа"
    [ needs_input_petr.Task.ref_ ]
    (needs_input_refs s);
  Alcotest.(check bool) "ждущая ответа не попала в застой" false
    (List.mem needs_input_petr.Task.ref_ (stuck_refs s))

let test_stuck_days_threshold () =
  let s = overview ~stuck_days:2 () in
  Alcotest.(check int) "порог применён" 2 s.Service.Overview.stuck_days;
  Alcotest.(check bool) "начатая три дня назад стала застойкой" true
    (List.mem fresh_3.Task.ref_ (stuck_refs s));
  let strict = overview ~stuck_days:100 () in
  Alcotest.(check int) "при пороге в 100 суток застоя нет" 0
    (List.length strict.Service.Overview.stuck)

let test_limit_truncates_lists () =
  let s = overview ~limit:2 () in
  Alcotest.(check int) "предел применён" 2 s.Service.Overview.limit;
  Alcotest.(check int) "список обрезан" 2 (List.length s.Service.Overview.stuck);
  Alcotest.(check (list string)) "первые двое по возрасту"
    [ stuck_50.Task.ref_; stuck_40.Task.ref_ ]
    (stuck_refs s)

let test_bad_parameters_are_rejected () =
  let cases =
    [
      ("stuck_days меньше суток", Some 0, None);
      ("предел меньше единицы", None, Some 0);
      ("предел больше максимума", None, Some 1000);
    ]
  in
  List.iter
    (fun (what, stuck_days, limit) ->
      let outcome =
        Support.run (Service.Overview.get conn ?stuck_days ?limit ())
      in
      match outcome with
      | Error (Service.Failure.Bad_request _) -> ()
      | Error e ->
          Alcotest.fail
            (what ^ ": ожидался отказ запроса, а пришёл "
           ^ Service.Failure.to_string e)
      | Ok _ -> Alcotest.fail (what ^ ": ожидался отказ запроса, а пришёл ответ"))
    cases

let test_generated_at_is_a_moment () =
  let s = overview () in
  Alcotest.(check bool) "момент посчитан" true
    (String.length s.Service.Overview.generated_at > 0)

let () =
  Alcotest.run "service overview"
    [
      ( "сводка",
        [
          Alcotest.test_case "считает открытые задачи" `Quick
            test_totals_count_open_tasks;
          Alcotest.test_case "считает нагрузку по людям" `Quick
            test_wip_counts_open_tasks_by_actor;
          Alcotest.test_case "закрытые задачи не считаются" `Quick
            test_closed_tasks_are_not_counted;
          Alcotest.test_case "нагрузка по проектам" `Quick
            test_project_load_only_with_open_tasks;
          Alcotest.test_case "застой: начатые статусы" `Quick
            test_stuck_lists_oldest_started_tasks;
          Alcotest.test_case "needs_input живёт отдельно" `Quick
            test_needs_input_is_separate_list;
          Alcotest.test_case "порог застоя настраивается" `Quick
            test_stuck_days_threshold;
          Alcotest.test_case "предел длины обрезает списки" `Quick
            test_limit_truncates_lists;
          Alcotest.test_case "неверные параметры отклоняются" `Quick
            test_bad_parameters_are_rejected;
          Alcotest.test_case "момент посчитан" `Quick
            test_generated_at_is_a_moment;
        ] );
    ];
  ignore todo_petr;
  ignore in_progress_legist;
  ignore blocked_legist;
  ignore unassigned;
  ignore no_project;
  ignore empty_project
