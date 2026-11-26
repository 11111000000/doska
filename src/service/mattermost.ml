(** Клиент Mattermost: список пользователей.

    HTTP-клиента на OCaml в наборе нет, а тащить TLS-стек ради одного
    запроса — лишняя зависимость в замыкании пакета. Поэтому запрос уходит в
    [curl]: он есть в nixpkgs и уже работает в этой системе.

    Токен не попадает в аргументы процесса: [curl] читает конфигурацию из
    stdin, поэтому в списке процессов видно только адрес. Секрет приходит из
    окружения и в код не попадает. *)

type user = {
  id : string;
  username : string;
  first_name : string;
  last_name : string;
  nickname : string;
  position : string;
  email : string;
  (** Удалённый пользователь в списке остаётся, но в трекер не попадает. *)
  deleted : bool;
}

let ( let* ) t f = Lwt.bind t f

(* ------------------------------------------------------------- разбор --- *)

let parse_user (json : Yojson.Safe.t) : user option =
  match json with
  | `Assoc _ ->
      let id = Db.Row.string_ json "id" ~default:"" in
      let username = Db.Row.string_ json "username" ~default:"" in
      if id = "" || username = "" then None
      else
        Some
          {
            id;
            username;
            first_name = Db.Row.string_ json "first_name" ~default:"";
            last_name = Db.Row.string_ json "last_name" ~default:"";
            nickname = Db.Row.string_ json "nickname" ~default:"";
            position = Db.Row.string_ json "position" ~default:"";
            email = Db.Row.string_ json "email" ~default:"";
            deleted = Db.Row.int64_ json "delete_at" ~default:0L > 0L;
          }
  | _ -> None

let parse_users (json : Yojson.Safe.t) : (user list, string) result =
  match json with
  | `List items ->
      let users = List.filter_map parse_user items in
      Ok (List.filter (fun user -> not user.deleted) users)
  | _ -> Error "ответ Mattermost — не список пользователей"

(* -------------------------------------------------------------- вызов --- *)

(** Чтение до конца файла. [Unix.read] возвращает 0 на конце файла, в отличие
    от каналов OCaml, которые бросают [End_of_file]. *)
let read_all fd : string =
  let buffer = Buffer.create 4096 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buffer chunk 0 n;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ();
  Buffer.contents buffer

(** Конфигурация [curl] с заголовком авторизации.

    [curl] читает конфигурацию из файла, а не из аргументов: значение в
    кавычках, кавычка и обратный слэш внутри — экранируются. *)
let config_of token : string =
  let escape value =
    let buffer = Buffer.create (String.length value) in
    String.iter
      (fun c ->
        match c with
        | '"' -> Buffer.add_string buffer "\\\""
        | '\\' -> Buffer.add_string buffer "\\\\"
        | c -> Buffer.add_char buffer c)
      value;
    Buffer.contents buffer
  in
  Printf.sprintf "header = \"Authorization: Bearer %s\"\n" (escape token)

(** Выполнить запрос [curl] и вернуть тело ответа.

    Блокирующий вызов: используется только в командной строке импорта, где
    до ответа больше делать нечего. *)
let run ~url ~token : (string, string) result =
  (* Труба: первый конец — читающий, второй — пишущий. *)
  let in_r, in_w = Unix.pipe () in
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  (* Дочерний процесс не должен унаследовать родительские концы труб. *)
  List.iter Unix.set_close_on_exec [ in_w; out_r; err_r ];
  let argv =
    [|
      "curl";
      "--silent";
      "--show-error";
      "--fail-with-body";
      "--max-time";
      "30";
      "--config";
      "-";
      "--url";
      url;
    |]
  in
  (* Окружение минимальное: токен в нём не нужен, а лишние переменные в
     окружении дочернего процесса — лишняя утечка. *)
  let env =
    [|
      "PATH="
      ^ (match Sys.getenv_opt "PATH" with Some path -> path | None -> "/usr/bin:/bin");
    |]
  in
  (* Ребёнок читает конфигурацию из своего stdin и пишет ответ в stdout. *)
  let pid = Unix.create_process_env "curl" argv env in_r out_w err_w in
  Unix.close in_r;
  Unix.close out_w;
  Unix.close err_w;
  (* Конфигурация с токеном уходит в stdin дочернего процесса. *)
  (try
     let config = Bytes.of_string (config_of token) in
     let length = Bytes.length config in
     let written = ref 0 in
     while !written < length do
       let n = Unix.write in_w config !written (length - !written) in
       written := !written + n
     done
   with Unix.Unix_error _ -> ());
  Unix.close in_w;
  let body = read_all out_r in
  let errors = read_all err_r in
  let status = snd (Unix.waitpid [] pid) in
  Unix.close out_r;
  Unix.close err_r;
  match status with
  | Unix.WEXITED 0 -> Ok body
  | Unix.WEXITED code ->
      Error
        (Printf.sprintf "curl завершился с кодом %d: %s" code (String.trim errors))
  | Unix.WSIGNALED signal -> Error (Printf.sprintf "curl убит сигналом %d" signal)
  | Unix.WSTOPPED signal -> Error (Printf.sprintf "curl остановлен сигналом %d" signal)

(** Активные пользователи Mattermost.

    [base_url] — адрес сервера, [token] — токен бота. Оба приходят из
    окружения: секрет в коде не живёт. *)
let list_users ~base_url ~token : (user list, string) result Lwt.t =
  let base = String.trim base_url in
  let base = if base = "" then "http://127.0.0.1:8065" else base in
  let url = Printf.sprintf "%s/api/v4/users?per_page=200&page=0&active=false" base in
  match run ~url ~token with
  | Error e -> Lwt_result.lift (Error e)
  | Ok body -> (
      match Yojson.Safe.from_string body with
      | json -> Lwt_result.lift (parse_users json)
      | exception Yojson.Json_error e ->
          Lwt_result.lift (Error ("ответ Mattermost не разобран: " ^ e)))

(** POST с JSON-телом: тот же curl, тот же секрет в stdin-конфиге. Тело —
    не секрет, поэтому уходит аргументом. *)
let run_post ~url ~token ~body : (string, string) result =
  let in_r, in_w = Unix.pipe () in
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  List.iter Unix.set_close_on_exec [ in_w; out_r; err_r ];
  let argv =
    [|
      "curl";
      "--silent";
      "--show-error";
      "--fail-with-body";
      "--max-time";
      "30";
      "--config";
      "-";
      "--request";
      "POST";
      "--header";
      "Content-Type: application/json";
      "--data";
      body;
      "--url";
      url;
    |]
  in
  let env =
    [|
      "PATH="
      ^ (match Sys.getenv_opt "PATH" with Some path -> path | None -> "/usr/bin:/bin");
    |]
  in
  let pid = Unix.create_process_env "curl" argv env in_r out_w err_w in
  Unix.close in_r;
  Unix.close out_w;
  Unix.close err_r;
  (try
     let config = Bytes.of_string (config_of token) in
     let length = Bytes.length config in
     let written = ref 0 in
     while !written < length do
       let n = Unix.write in_w config !written (length - !written) in
       written := !written + n
     done
   with Unix.Unix_error _ -> ());
  Unix.close in_w;
  let response = read_all out_r in
  let errors = read_all err_r in
  let status = snd (Unix.waitpid [] pid) in
  Unix.close out_r;
  Unix.close err_r;
  match status with
  | Unix.WEXITED 0 -> Ok response
  | Unix.WEXITED code ->
      Error
        (Printf.sprintf "curl завершился с кодом %d: %s" code (String.trim errors))
  | Unix.WSIGNALED signal -> Error (Printf.sprintf "curl убит сигналом %d" signal)
  | Unix.WSTOPPED signal -> Error (Printf.sprintf "curl остановлен сигналом %d" signal)

let base_url_of = function
  | "" -> "http://127.0.0.1:8065"
  | base -> String.trim base

(** Личный канал бота и пользователя: MM отдаёт его GET-ом, канал создаётся
    неявно при первом чтении. *)
let direct_channel ~base_url ~token ~me_id ~user_id : (string, string) result Lwt.t =
  let base = base_url_of base_url in
  let url = Printf.sprintf "%s/api/v4/channels/direct/%s/%s" base me_id user_id in
  match run ~url ~token with
  | Error e -> Lwt_result.lift (Error e)
  | Ok body -> (
      match Yojson.Safe.from_string body with
      | json -> Lwt_result.lift (Ok (Db.Row.string_ json "id" ~default:""))
      | exception Yojson.Json_error e ->
          Lwt_result.lift (Error ("ответ Mattermost не разобран: " ^ e)))

(** Отправить пользователю личное сообщение от имени бота. *)
let send_dm ~base_url ~token ~me_id ~user_id ~text : (unit, string) result Lwt.t =
  let* outcome = direct_channel ~base_url ~token ~me_id ~user_id in
  match outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok channel_id ->
      if channel_id = "" then Lwt_result.lift (Error "MM не вернул канал")
      else
        let base = base_url_of base_url in
        let url = Printf.sprintf "%s/api/v4/posts" base in
        let body =
          Yojson.Safe.to_string
            (`Assoc
              [ ("channel_id", `String channel_id); ("message", `String text) ])
        in
        match run_post ~url ~token ~body with
        | Ok _ -> Lwt_result.lift (Ok ())
        | Error e -> Lwt_result.lift (Error e)
