(** Обвязка тестов, которым нужна живая база.

    Тест без базы падает с понятным сообщением: «тест прошёл» не должен
    означать «тест не запускался». *)

let run = Lwt_main.run

let database_url () =
  match Sys.getenv_opt "DOSKA_DATABASE_URL" with
  | Some u when String.trim u <> "" -> u
  | _ -> "postgresql:///doska"

(** Каталог миграций.

    dune запускает тест из каталога сборки, а миграции лежат в дереве
    исходников: ищем корень вверх по дереву. *)
let migrations_dir () =
  let has_file path = Sys.file_exists path in
  match Sys.getenv_opt "DOSKA_MIGRATIONS_DIR" with
  | Some dir when has_file (Filename.concat dir "001_init.sql") -> dir
  | _ ->
      let rec search dir depth =
        if depth > 8 then None
        else
          let candidate = Filename.concat dir "migrations" in
          if has_file (Filename.concat candidate "001_init.sql") then Some candidate
          else
            let parent = Filename.dirname dir in
            if parent = dir then None else search parent (depth + 1)
      in
      match search (Sys.getcwd ()) 0 with
      | Some dir -> dir
      | None ->
          failwith
            "не найден каталог миграций: задайте DOSKA_MIGRATIONS_DIR или запускайте \
             тест из дерева исходников"

(** Подключение и применение миграций: тест работает на базе с актуальной схемой.

    Миграции применяются под advisory lock: dune запускает тестовые программы
    параллельно, и два процесса не должны применять один файл одновременно. *)
let migrate conn : Db.Conn.t =
  let acquired =
    run (Db.Conn.query_strings conn "SELECT 'locked'::text FROM pg_advisory_lock(4711)")
  in
  let applied = run (Db.Migrate.run conn ~dir:(migrations_dir ())) in
  let released =
    run (Db.Conn.query_strings conn "SELECT pg_advisory_unlock(4711)::text")
  in
  (match acquired with
  | Ok _ -> ()
  | Error e -> failwith ("не удалось взять advisory lock: " ^ e));
  (match released with
  | Ok _ -> ()
  | Error e -> failwith ("не удалось отпустить advisory lock: " ^ e));
  match applied with
  | Ok _ -> conn
  | Error e -> failwith ("миграции не применились: " ^ e)

let connect () : Db.Conn.t =
  let url = database_url () in
  match run (Db.Conn.connect ~uri:url ()) with
  | Error e ->
      failwith
        (Printf.sprintf
           "нет подключения к базе (%s): %s\nзадайте DOSKA_DATABASE_URL или запустите \
            PostgreSQL"
           url e)
  | Ok conn ->
      Db.Conn.set_current conn;
      migrate conn

(** Актёр с заданным логином: если он уже есть — берём существующего.

    Тестовые программы dune запускает параллельно, поэтому у каждой свой
    префикс логинов: чужие строки трогать нельзя. *)
let ensure_actor conn ~prefix ~kind ~handle ~display_name : Domain.Actor.t =
  let handle = prefix ^ handle in
  match run (Db.Repo_actor.by_handle conn handle) with
  | Ok (Some actor) -> actor
  | Ok None -> (
      match run (Db.Repo_actor.create conn ~kind ~handle ~display_name ()) with
      | Ok actor -> actor
      | Error e -> failwith ("актор не создан: " ^ e))
  | Error e -> failwith ("актор не прочитан: " ^ e)

let ensure_project conn ~prefix ~key ~name ~autonomy : Domain.Project.t =
  let key = prefix ^ key in
  match run (Db.Repo_project.by_key conn key) with
  | Ok (Some project) -> project
  | Ok None -> (
      match run (Db.Repo_project.create conn ~key ~name ~autonomy) with
      | Ok project -> project
      | Error e -> failwith ("проект не создан: " ^ e))
  | Error e -> failwith ("проект не прочитан: " ^ e)

(** Убрать за собой: тесты не должны оставлять мусор в рабочей базе. *)
let cleanup conn ~source ~actor_prefix ~project_prefix =
  let statements =
    [
      Printf.sprintf
        "DELETE FROM activity WHERE task_id IN (SELECT id FROM task WHERE source = %s)"
        (Db.Conn.quote source);
      Printf.sprintf
        "DELETE FROM evidence WHERE task_id IN (SELECT id FROM task WHERE source = %s)"
        (Db.Conn.quote source);
      Printf.sprintf
        "DELETE FROM comment WHERE task_id IN (SELECT id FROM task WHERE source = %s)"
        (Db.Conn.quote source);
      Printf.sprintf "DELETE FROM task WHERE source = %s" (Db.Conn.quote source);
      Printf.sprintf "DELETE FROM actor WHERE handle LIKE %s"
        (Db.Conn.quote (actor_prefix ^ "%"));
      Printf.sprintf "DELETE FROM project WHERE key LIKE %s"
        (Db.Conn.quote (project_prefix ^ "%"));
    ]
  in
  List.iter
    (fun sql ->
      match run (Db.Conn.exec_sql conn sql) with
      | Ok () -> ()
      | Error e -> failwith ("уборка не удалась: " ^ e))
    statements
