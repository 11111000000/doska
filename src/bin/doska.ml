(** Точка входа: [doska serve | migrate | health | version].

    Все команды возвращают [(unit, string) result]: успех — [Ok ()],
    ошибка — [Error "текст"]. Их оценивает [Cmd.eval_result], который сам
    печатает ошибку и возвращает код выхода. *)

open Cmdliner

(** Связка для result-промисов: ошибка пробрасывается как есть, успешное
    значение разбирается в ветке. *)
let ( let* ) t f = Lwt.bind t f

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

let source =
  let doc = "Источник импорта: mattermost." in
  Arg.(value & opt string "mattermost" & info [ "source" ] ~docv:"SOURCE" ~doc)

(** Адрес Mattermost: сервер Mattermost на этой машине слушает 8065.

    Значение приходит из окружения: адрес развёртывания — не то, что
    должно быть зашито в программу. *)
let mattermost_url () : string =
  match Sys.getenv_opt "DOSKA_MATTERMOST_URL" with
  | Some url when String.trim url <> "" -> String.trim url
  | _ -> "http://127.0.0.1:8065"

(** Токен Mattermost.

    Секрет живёт только в окружении: в коде его быть не должно, и печатать
    его нельзя даже в ошибке. *)
let mattermost_token () : (string, string) result =
  match Sys.getenv_opt "DOSKA_MATTERMOST_TOKEN" with
  | Some token when String.trim token <> "" -> Ok (String.trim token)
  | _ -> Error "нет токена Mattermost: задайте DOSKA_MATTERMOST_TOKEN"

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

(** Импорт из внешнего источника.

    Импорт идемпотентен: ключ актёра — пара (source, source_ref), поэтому
    повторный запуск обновляет те же строки, а не создаёт новые (§10.2). *)
let run_import uri source : (unit, string) result =
  match source with
  | "mattermost" -> (
      match mattermost_token () with
      | Error e -> Error e
      | Ok token ->
          let outcome =
            with_db uri (fun conn ->
                let* users =
                  Service.Mattermost.list_users ~base_url:(mattermost_url ()) ~token
                in
                match users with
                | Error e -> Lwt_result.lift (Error e)
                | Ok users ->
                    let* report =
                      Service.Import_actors.import_users conn
                        ~namespace:Service.Import_actors.namespace users
                    in
                    match report with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok report ->
                        Printf.printf
                          "mattermost: пользователей %d (людей %d, агентов %d); \
                           создано %d, обновлено %d; алиасов %d\n"
                          report.Service.Import_actors.total report.humans report.agents
                          report.created report.updated report.aliases;
                        Lwt_result.lift (Ok ()))
          in
          (match outcome with
          | Ok () -> Ok ()
          | Error e -> Error (Printf.sprintf "ошибка импорта: %s" e)))
  | other -> Error ("неизвестный источник импорта: " ^ other)

(** MCP over stdio: агент без HTTP говорит JSON-RPC через stdin/stdout.
    Токен агента — DOSKA_MCP_TOKEN, секрет только из окружения. *)
let run_mcp_stdio () : (unit, string) result =
  Mcp.Server.run_stdio ();
  Ok ()

let cmd_mcp =
  Cmd.v
    (Cmd.info "mcp" ~doc:"MCP-сервер через stdio (токен: DOSKA_MCP_TOKEN).")
    Term.(const run_mcp_stdio $ const ())

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

let cmd_import =
  Cmd.v
    (Cmd.info "import" ~doc:"Импортировать данные из внешнего источника.")
    Term.(const run_import $ db_uri $ source)

let () =
  let info =
    Cmd.info "doska" ~version:Version.version
      ~doc:"Трекер обязательств для людей и агентов."
  in
  exit
    (Cmd.eval_result
       (Cmd.group info [ cmd_migrate; cmd_health; cmd_serve; cmd_version; cmd_import; cmd_mcp ]))
