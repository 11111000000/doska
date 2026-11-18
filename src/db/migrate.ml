(** Собственный мигратор: идемпотентные SQL-файлы + таблица [schema_version].

    Готового мигратора для OCaml в пине нет, поэтому он пишется здесь.
    Правила: каждый файл применяется целиком в одной транзакции, уже
    применённые версии пропускаются, порядок — по имени файла.

    Все промиссы здесь — result-промиссы ([Lwt_result.t]), потому что ошибка
    миграции — это данные, а не исключение. *)

(** Связка для result-промиссов: [let* x = promise in ...].
    Именно [Lwt.bind], а не [Lwt_result.bind]: он отдаёт наружу весь
    [result], а не только успешное значение, — так ошибка разбирается
    в одном месте, рядом с вызовом. *)
let ( let* ) t f = Lwt.bind t f

let ensure_table conn =
  Conn.exec_sql conn
    "CREATE TABLE IF NOT EXISTS schema_version (\
     version   text PRIMARY KEY,\
     checksum  text NOT NULL,\
     applied_at timestamptz NOT NULL DEFAULT now())"

(** Применённые версии вместе с их контрольными суммами. *)
let applied_versions conn =
  Conn.query_pairs conn "SELECT version, checksum FROM schema_version ORDER BY version"

let migration_files dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".sql")
  |> List.sort String.compare

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

(** Контрольная сумма файла миграции: MD5 из стандартной библиотеки.
    Это отпечаток для проверки «файл не менялся после применения», а не
    криптографическая защита. *)
let checksum sql = Digest.to_hex (Digest.string sql)

(** Проверка: применённый файл не менялся после применения.

    Если сумма файла на диске разошлась с записанной в базе, миграция
    «поехала»: у базы и у репозитория разные представления о схеме. Молча
    продолжать нельзя — это ровно тот случай, где тихая рассинхронизация
    дороже всего обойдётся. *)
let verify_checksums ~dir applied =
  let rec check = function
    | [] -> Ok ()
    | (version, recorded) :: rest ->
        let path = Filename.concat dir version in
        if not (Sys.file_exists path) then
          Error
            (Printf.sprintf
               "%s: файл миграции отсутствует, но отмечен как применённый \
                (записанная сумма %s)"
               version recorded)
        else
          let actual = checksum (read_file path) in
          if actual = recorded then check rest
          else
            Error
              (Printf.sprintf
                 "%s: файл изменился после применения (в базе %s, на диске %s) \
                  — применённые миграции не правятся"
                 version recorded actual)
  in
  check applied

(** Разбор SQL-файла на отдельные выражения.

    Почему: драйвер готовит запрос (extended protocol), а такой протокол
    не допускает нескольких операторов в одном запросе. Файл делится
    на операторы, и каждый выполняется отдельно. *)
let split_statements (sql : string) : string list =
  let n = String.length sql in
  let buf = Buffer.create n in
  let statements = ref [] in
  let i = ref 0 in
  let flush () =
    let text = String.trim (Buffer.contents buf) in
    Buffer.clear buf;
    if text <> "" then statements := text :: !statements
  in
  let starts_with s pos =
    let len = String.length s in
    pos + len <= n && String.sub sql pos len = s
  in
  while !i < n do
    let c = sql.[!i] in
    match c with
    | '\'' | '"' ->
        let quote = c in
        Buffer.add_char buf c;
        incr i;
        let rec literal () =
          if !i >= n then ()
          else (
            let c = sql.[!i] in
            Buffer.add_char buf c;
            incr i;
            if c = quote then
              if !i < n && sql.[!i] = quote then (
                (* удвоенная кавычка — экранированная кавычка внутри строки *)
                Buffer.add_char buf quote;
                incr i;
                literal ())
              else ()
              (* одиночная кавычка закрывает строку *)
            else literal ())
        in
        literal ()
    | '$' when starts_with "$$" !i ->
        Buffer.add_string buf "$$";
        i := !i + 2;
        while !i < n && not (starts_with "$$" !i) do
          Buffer.add_char buf sql.[!i];
          incr i
        done;
        if !i < n then (
          Buffer.add_string buf "$$";
          i := !i + 2)
    | '-' when starts_with "--" !i ->
        while !i < n && sql.[!i] <> '\n' do
          incr i
        done
    | '/' when starts_with "/*" !i ->
        i := !i + 2;
        while !i < n && not (starts_with "*/" !i) do
          incr i
        done;
        if !i < n then i := !i + 2
    | ';' ->
        flush ();
        incr i
    | _ ->
        Buffer.add_char buf c;
        incr i
  done;
  flush ();
  List.rev !statements

(** Применение одного файла в одной транзакции. *)
let apply_file conn ~dir name =
  let path = Filename.concat dir name in
  let sql = read_file path in
  let statements = split_statements sql in
  let rec run = function
    | [] -> Lwt_result.lift (Ok ())
    | statement :: rest ->
        let* outcome = Conn.exec_sql conn statement in
        (match outcome with
        | Error e -> Lwt_result.lift (Error e)
        | Ok () -> run rest)
  in
  let* begun = Conn.exec_sql conn "BEGIN" in
  (match begun with
  | Error e -> Lwt_result.lift (Error e)
  | Ok () ->
      let* applied = run statements in
      (match applied with
      | Error e ->
          let* _ = Conn.exec_sql conn "ROLLBACK" in
          Lwt_result.lift (Error e)
      | Ok () ->
          let insert =
            Printf.sprintf
              "INSERT INTO schema_version (version, checksum) VALUES (%s, %s)"
              (Conn.quote name) (Conn.quote (checksum sql))
          in
          let* recorded = Conn.exec_sql conn insert in
          (match recorded with
          | Error e -> Lwt_result.lift (Error e)
          | Ok () ->
              let* committed = Conn.exec_sql conn "COMMIT" in
              (match committed with
              | Error e -> Lwt_result.lift (Error e)
              | Ok () -> Lwt_result.lift (Ok ())))))

(** Применяет все недостающие миграции. Возвращает список применённых версий. *)
let run conn ~dir : (string list, string) result Lwt.t =
  let* table = ensure_table conn in
  (match table with
  | Error e -> Lwt_result.lift (Error e)
  | Ok () ->
      let* applied = applied_versions conn in
      (match applied with
      | Error e -> Lwt_result.lift (Error e)
      | Ok applied ->
          (match verify_checksums ~dir applied with
          | Error e -> Lwt_result.lift (Error e)
          | Ok () ->
              let versions = List.map fst applied in
              let pending =
                migration_files dir
                |> List.filter (fun name -> not (List.mem name versions))
              in
              let rec go acc = function
                | [] -> Lwt_result.lift (Ok (List.rev acc))
                | name :: rest ->
                    let* outcome = apply_file conn ~dir name in
                    (match outcome with
                    | Error e ->
                        Lwt_result.lift (Error (Printf.sprintf "%s: %s" name e))
                    | Ok () -> go (name :: acc) rest)
              in
              go [] pending)))
