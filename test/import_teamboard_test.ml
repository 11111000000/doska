(** Импорт данных Teamboard на живой базе.

    Фикстуры — свои: ключи карточек с префиксом [impfixture], чтобы уборка
    не тронула настоящий импорт (117 задач). Проверяются три вещи:
    перевод колонки в статус, разрешение владельца (заглушка для неизвестного)
    и идемпотентность — повторный запуск обновляет, а не плодит. *)

open Domain

let conn = Support.connect ()

let () = Support.lock conn 4717

(* Фикстуры удаляются точечно: только строки этого теста. *)
(* Уборка: по одному запросу — драйвер не принимает несколько команд
   в одном подготовленном запросе. *)
let cleanup () =
  let statements =
    [
      "DELETE FROM evidence WHERE task_id IN (SELECT id FROM task WHERE source = 'teamboard' AND (source_ref LIKE 'impfixture%' OR source_ref LIKE 'epic:impfixture%'))";
      "DELETE FROM task_link WHERE from_id IN (SELECT id FROM task WHERE source = 'teamboard' AND (source_ref LIKE 'impfixture%' OR source_ref LIKE 'epic:impfixture%')) OR to_id IN (SELECT id FROM task WHERE source = 'teamboard' AND (source_ref LIKE 'impfixture%' OR source_ref LIKE 'epic:impfixture%'))";
      "DELETE FROM task WHERE source = 'teamboard' AND (source_ref LIKE 'impfixture%' OR source_ref LIKE 'epic:impfixture%')";
      "DELETE FROM project WHERE key LIKE 'impfixture%'";
      "DELETE FROM actor_alias WHERE alias LIKE 'impfixture%'";
      "DELETE FROM actor WHERE handle LIKE 'impfixture%'";
    ]
  in
  List.iter
    (fun sql ->
      match Support.run (Db.Conn.exec_sql conn sql) with
      | Ok () -> ()
      | Error e -> Alcotest.fail ("уборка не удалась: " ^ e))
    statements

let fixture_dir = Filename.temp_dir "doska-teamboard" ""

let write_file name content =
  let path = Filename.concat fixture_dir name in
  let channel = open_out path in
  output_string channel content;
  close_out channel;
  path

let registry =
  write_file "registry.json"
    {|{"projects":[{"id":"impfixture-alpha","name":"Импорт-альфа","asset":"product","paths":["/tmp/alpha"]},{"id":"impfixture-beta","name":"Импорт-бета","asset":"knowledge","paths":["/tmp/beta"]}]}|}

let annotations =
  write_file "annotations.json"
    {|{"annotations":{
       "impfixture-alpha::branch:one":{"title":"Отгружено","why":"сделано","owner":"","column":"shipped","source":"git: feat/x","evidence":"abc123, 2026-11-01"},
       "impfixture-alpha::branch:two":{"title":"В работе","why":"делаем","owner":"impfixture-owner","column":"wip","source":"","evidence":""},
       "impfixture-beta::plan:three":{"title":"Запланировано","why":"в очереди","owner":"","column":"planned","source":"","evidence":""}}}|}

let epics =
  write_file "epics.json"
    {|{"epics":{"impfixture-epic":{"title":"Инициатива фикстуры","why":"цель","outcome":"результат","owner":"","status":"active","projects":["impfixture-alpha"],"cards":["impfixture-alpha::branch:one","impfixture-alpha::branch:two"]}}}|}

let import () =
  match
    Support.run
      (Service.Import_teamboard.import_all conn ~registry ~annotations ~epics)
  with
  | Error failure -> Alcotest.fail ("импорт не прошёл: " ^ Service.Failure.to_string failure)
  | Ok report -> report

let task_by_source_ref source_ref =
  match Support.run (Db.Repo_task.by_source_ref conn ~source:"teamboard" ~source_ref) with
  | Ok (Some task) -> task
  | Ok None -> Alcotest.fail ("задача не найдена: " ^ source_ref)
  | Error e -> Alcotest.fail ("задача не прочитана: " ^ e)

let count_fixture_tasks () =
  match
    Support.run
      (Db.Conn.query_int64s conn
         "SELECT count(*) FROM task WHERE source = 'teamboard' \
          AND (source_ref LIKE 'impfixture%' OR source_ref LIKE 'epic:impfixture%')")
  with
  | Ok counts -> ( match counts with n :: _ -> n | [] -> 0L)
  | Error e -> Alcotest.fail ("счёт не прочитан: " ^ e)

let test_import_maps_columns_and_owners () =
  cleanup ();
  let report = import () in
  Alcotest.(check int) "проектов импортировано" 2 report.Service.Import_teamboard.projects;
  Alcotest.(check int) "задач импортировано" 4 report.Service.Import_teamboard.tasks;
  Alcotest.(check int) "создано сразу" 4 report.Service.Import_teamboard.created;
  Alcotest.(check int) "связей инициативы" 2 report.Service.Import_teamboard.links;
  Alcotest.(check int) "заглушек для неизвестного владельца" 1
    report.Service.Import_teamboard.placeholders;
  (* Колонка Teamboard → статус doska. *)
  let shipped = task_by_source_ref "impfixture-alpha::branch:one" in
  Alcotest.(check string) "shipped → done" "done"
    (Status.to_string shipped.Task.status);
  let wip = task_by_source_ref "impfixture-alpha::branch:two" in
  Alcotest.(check string) "wip → in_progress" "in_progress"
    (Status.to_string wip.Task.status);
  let planned = task_by_source_ref "impfixture-beta::plan:three" in
  Alcotest.(check string) "planned → todo" "todo" (Status.to_string planned.Task.status);
  (* Инициатива — задача вида decision. *)
  let epic = task_by_source_ref "epic:impfixture-epic" in
  Alcotest.(check string) "инициатива — решение" "decision"
    (Domain.Task.kind_to_string epic.Task.kind);
  cleanup ()

let test_reimport_updates_without_duplicates () =
  cleanup ();
  let _ = import () in
  let second = import () in
  Alcotest.(check int) "повтор не создаёт задач" 0 second.Service.Import_teamboard.created;
  Alcotest.(check int) "повтор обновляет задачи" 4 second.Service.Import_teamboard.updated;
  Alcotest.(check int64) "в базе те же четыре задачи" 4L (count_fixture_tasks ());
  cleanup ()

let () =
  let open Alcotest in
  run "импорт teamboard"
    [
      ( "импорт",
        [
          test_case "колонки и владельцы переводятся" `Quick
            test_import_maps_columns_and_owners;
          test_case "повтор обновляет, а не плодит" `Quick
            test_reimport_updates_without_duplicates;
        ] );
    ]
