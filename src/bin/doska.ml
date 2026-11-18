(** Точка входа: [doska serve | migrate | health | version].

    Все команды возвращают [(unit, string) result]: успех — [Ok ()],
    ошибка — [Error "текст"]. Их оценивает [Cmd.eval_result], который сам
    печатает ошибку и возвращает код выхода. *)

open Cmdliner

let db_uri =
  let doc =
    "URI базы данных PostgreSQL. Значение по умолчанию берётся из переменной \
     окружения DOSKA_DATABASE_URL; явный --db-url перекрывает её."
  in
  Arg.(
    value & opt string (Db.Conn.default_uri ()) & info [ "db-url" ] ~docv:"URI" ~doc)

let migrations_dir =
  let doc = "Каталог с файлами миграций." in
  Arg.(value & opt string "migrations" & info [ "migrations-dir" ] ~docv:"DIR" ~doc)

let port =
  let doc = "Порт HTTP-сервера." in
  Arg.(value & opt int 8500 & info [ "port" ] ~docv:"PORT" ~doc)

(** Подключение, выполнение действия и закрытие соединения.

    [Lwt.bind] здесь явный: встроенный в stdlib [>>=] работает с обычными
    значениями, а не с промиссами. *)
let with_db uri f =
  Lwt_main.run
    (Lwt.bind (Db.Conn.connect ~uri ()) (fun outcome ->
         match outcome with
         | Error e -> Lwt.return (Error e)
         | Ok conn ->
             Db.Conn.set_current conn;
             f conn))

let run_migrate uri dir : (unit, string) result =
  match with_db uri (fun conn -> Db.Migrate.run conn ~dir) with
  | Ok applied ->
      if applied = [] then print_endline "миграции: нечего применять"
      else List.iter (fun name -> Printf.printf "применено: %s\n" name) applied;
      Ok ()
  | Error e -> Error (Printf.sprintf "ошибка миграции: %s" e)

let run_health uri : (unit, string) result =
  match with_db uri (fun conn -> Db.Conn.ping conn) with
  | Ok true ->
      print_endline "ok";
      Ok ()
  | Ok false -> Error "база не отвечает"
  | Error e -> Error (Printf.sprintf "ошибка: %s" e)

let run_serve uri port : (unit, string) result =
  match with_db uri (fun _ -> Lwt.return (Ok ())) with
  | Ok () ->
      Api.Server.serve ~port;
      Ok ()
  | Error e -> Error (Printf.sprintf "ошибка подключения: %s" e)

let run_version () : (unit, string) result =
  Printf.printf "%s %s\n" Version.name Version.version;
  Ok ()

let cmd_migrate =
  Cmd.v
    (Cmd.info "migrate" ~doc:"Применить миграции к базе данных.")
    Term.(const run_migrate $ db_uri $ migrations_dir)

let cmd_health =
  Cmd.v
    (Cmd.info "health" ~doc:"Проверить связь с базой данных.")
    Term.(const run_health $ db_uri)

let cmd_serve =
  Cmd.v
    (Cmd.info "serve" ~doc:"Запустить HTTP-сервер трекера.")
    Term.(const run_serve $ db_uri $ port)

let cmd_version =
  Cmd.v
    (Cmd.info "version" ~doc:"Показать версию трекера.")
    (* Пустой терм нужен, чтобы результат команды совпадал с результатом
       остальных: в cmdliner тип команды — это тип её терма. *)
    Term.(const run_version $ Term.const ())

let () =
  let info =
    Cmd.info "doska" ~version:Version.version
      ~doc:"Трекер обязательств для людей и агентов."
  in
  exit (Cmd.eval_result (Cmd.group info [ cmd_migrate; cmd_health; cmd_serve; cmd_version ]))
