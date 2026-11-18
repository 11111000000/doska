(** Доступ к PostgreSQL через caqti.

    Весь SQL сосредоточен здесь: доменный слой не знает про базу. *)

(** Соединение — это first-class модуль с сигнатурой [Caqti_lwt.CONNECTION].
    Так caqti устроен: драйвер подставляется во время выполнения, а тип
    соединения остаётся абстрактным до вызова [exec]. *)
type t = Caqti_lwt.connection

(** Ошибка caqti в строку: у caqti нет [to_string], только печать через [pp].
    Тип аргумента — верхняя граница [Caqti_error.t], чтобы подходили и ошибки
    соединения, и ошибки выполнения запроса. *)
let error_to_string (e : [< Caqti_error.t]) = Format.asprintf "%a" Caqti_error.pp e

(** Соединение по умолчанию берётся из переменной окружения, чтобы секрет
    не жил в коде и не попадал в репозиторий. *)
let default_uri () =
  match Sys.getenv_opt "DOSKA_DATABASE_URL" with
  | Some u when String.trim u <> "" -> u
  | _ -> "postgresql://127.0.0.1/doska"

let connect ?uri () : (t, string) result Lwt.t =
  let uri = match uri with Some u -> u | None -> default_uri () in
  Caqti_lwt_unix.connect (Uri.of_string uri) |> Lwt_result.map_error error_to_string

(** Текущее соединение процесса: сервер и CLI работают с одним. *)
let current : t option ref = ref None

let set_current conn = current := Some conn

let get_current () = !current

let exec_sql conn sql : (unit, string) result Lwt.t =
  let (module C : Caqti_lwt.CONNECTION) = conn in
  let req : (unit, unit, [`Zero]) Caqti_request.t =
    Caqti_request.create Caqti_type.unit Caqti_type.unit Caqti_mult.zero
      (fun _ -> Caqti_query.of_string_exn sql)
  in
  C.exec req () |> Lwt_result.map_error error_to_string

let query_strings conn sql : (string list, string) result Lwt.t =
  let (module C : Caqti_lwt.CONNECTION) = conn in
  let req : (unit, string, [`Zero | `One | `Many]) Caqti_request.t =
    Caqti_request.create Caqti_type.unit Caqti_type.string Caqti_mult.zero_or_more
      (fun _ -> Caqti_query.of_string_exn sql)
  in
  C.collect_list req () |> Lwt_result.map_error error_to_string

(** Пары «столбец — столбец»: мигратору нужны версия и контрольная сумма
    применённого файла вместе.

    Тип строки в запросе — пара; [collect_list] собирает такие строки в
    список, поэтому тип результата здесь — список пар. *)
let query_pairs conn sql : ((string * string) list, string) result Lwt.t =
  let (module C : Caqti_lwt.CONNECTION) = conn in
  let req : (unit, string * string, [`Zero | `One | `Many]) Caqti_request.t =
    Caqti_request.create Caqti_type.unit
      (Caqti_type.t2 Caqti_type.string Caqti_type.string)
      Caqti_mult.zero_or_more
      (fun _ -> Caqti_query.of_string_exn sql)
  in
  C.collect_list req () |> Lwt_result.map_error error_to_string

(** Целые числа Postgres приходят в 64 битах — [int64], а не машинный [int]. *)
let query_int64s conn sql : (int64 list, string) result Lwt.t =
  let (module C : Caqti_lwt.CONNECTION) = conn in
  let req : (unit, int64, [`Zero | `One | `Many]) Caqti_request.t =
    Caqti_request.create Caqti_type.unit Caqti_type.int64 Caqti_mult.zero_or_more
      (fun _ -> Caqti_query.of_string_exn sql)
  in
  C.collect_list req () |> Lwt_result.map_error error_to_string

(** Проверка живости соединения и базы. *)
let ping conn : (bool, string) result Lwt.t =
  query_strings conn "SELECT 'ok'"
  |> Lwt_result.map (fun rows -> List.exists (( = ) "ok") rows)

(** Экранирование строки для вставки в SQL. *)
let quote (s : string) : string =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '\'';
  String.iter
    (fun c ->
      if c = '\'' then Buffer.add_string b "''"
      else Buffer.add_char b c)
    s;
  Buffer.add_char b '\'';
  Buffer.contents b
