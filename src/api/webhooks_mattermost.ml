(** Вебхук Mattermost: задачи заводятся прямо из чата (D3, бот-путь).

    Mattermost присылает form-encoded: slash-команды ([token], [command],
    [text], [user_id], [user_name], [trigger_id]) и колбэки кнопок
    ([payload] — urlencoded JSON с [context.action] и [context.task_ref]).

    Личность: [user_id] ищется среди акторов с [source=mattermost] — это
    те же записи, что делает импорт идентичности. Действия выполняет
    сервисный слой, журнал пишет [interface=mattermost]: вызов из чата
    неотличим по правилам от REST-вызова, отличен только в журнале.

    Секрет — только из окружения: [DOSKA_MATTERMOST_TOKEN] общий для
    проверки команд и для отправки DM. Переменной нет — интеграция
    честно отвечает 503, а не молча пропускает. *)

open Domain

let ( let* ) t f = Lwt.bind t f

type config = { base_url : string; token : string; bot_id : string }

(** Конфигурация из окружения на каждый запрос: секрет не живёт в памяти
    дольше обработки. [Error] — интеграция не настроена. *)
let config () : (config, string) result =
  let read name = match Sys.getenv_opt name with Some v -> String.trim v | None -> "" in
  let token = read "DOSKA_MATTERMOST_TOKEN" in
  if token = "" then Error "DOSKA_MATTERMOST_TOKEN не задана"
  else
    Ok
      {
        base_url =
          (match read "DOSKA_MATTERMOST_URL" with "" -> "http://127.0.0.1:8065" | v -> v);
        token;
        bot_id = read "DOSKA_MATTERMOST_BOT_ID";
      }

let respond_mm ?(status = `OK) text =
  Dream.json ~status
    (Yojson.Safe.to_string
       (`Assoc [ ("response_type", `String "ephemeral"); ("text", `String text) ]))

(* ------------------------------------------------------------- разбор --- *)

let urldecode = Dream.from_percent_encoded

(** form-encoded тело: пары [k=v], разделённые [&]. *)
let parse_form (body : string) : (string * string) list =
  body
  |> String.split_on_char '&'
  |> List.filter_map (fun pair ->
         match String.index_opt pair '=' with
         | None -> None
         | Some eq ->
             let key = String.sub pair 0 eq in
             let value = String.sub pair (eq + 1) (String.length pair - eq - 1) in
             Some (urldecode key, urldecode value))

let field fields name =
  match List.assoc_opt name fields with Some v -> String.trim v | None -> ""

(* -------------------------------------------------------- актор чата --- *)

(** Актор — по идентификатору пользователя MM (импорт идентичности даёт
    запись с [source=mattermost, source_ref=user_id]); запасной путь —
    логин ([user_name] → handle). *)
let actor_of_chat conn ~user_id ~user_name : (Actor.t, string) result Lwt.t =
  let* by_id = Db.Repo_actor.by_source conn ~source:"mattermost" ~source_ref:user_id in
  match by_id with
  | Ok (Some actor) -> Lwt_result.lift (Ok actor)
  | Ok None -> (
      let* by_handle = Db.Repo_actor.by_handle conn user_name in
      match by_handle with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (Some actor) -> Lwt_result.lift (Ok actor)
      | Ok None ->
          Lwt_result.lift
            (Error ("актор не найден: " ^ user_name ^ " не привязан к doska")))
  | Error e -> Lwt_result.lift (Error e)

(* ------------------------------------------------------------ команды --- *)

let respond_failure = Errors.respond (Errors.make Errors.Internal "")

let task_from_chat conn ~actor ~text ~trigger_id =
  let parts = List.map String.trim (String.split_on_char '|' text) in
  let title = match parts with first :: _ -> first | [] -> "" in
  match title with
  | "" ->
      Lwt_result.lift
        (Error (Service.Failure.Bad_request { message = "формат: /task заголовок | проект | исполнитель | срок" }))
  | title -> (
      let optional name = function
        | [] | [ _ ] -> None
        | _ :: second :: more -> (
            let value = if name = "assignee" then second else List.nth more 0 in
            if String.trim value = "" then None else Some (String.trim value))
      in
      let project = optional "project" parts in
      let assignee = optional "assignee" parts in
      let due_at = optional "due_at" parts in
      let input : Service.Task.create_input =
        {
          title;
          description = "из Mattermost";
          kind = Task.Task;
          status = Status.Todo;
          priority = Task.P2;
          due_at;
          labels = [];
          source = Some "mattermost";
          source_ref = Some ("cmd:" ^ trigger_id);
          project;
          assignee;
          requester = None;
          parent = None;
        }
      in
      let* outcome =
        Service.Task.create conn ~actor ~interface_:Interface.Mattermost input
      in
      match outcome with
      | Error failure -> Lwt_result.lift (Error failure)
      | Ok (Db.Repo_task.Created task) ->
          Lwt_result.lift (Ok ("создано " ^ task.Task.ref_))
      | Ok (Db.Repo_task.Existing task) ->
          Lwt_result.lift (Ok ("уже существует " ^ task.Task.ref_)))

let list_my conn ~actor =
  let* page_outcome = Service.Task.mine conn ~actor ~limit:20 ~cursor:None in
  match page_outcome with
  | Error failure -> Lwt_result.lift (Error failure)
  | Ok page -> (
      match page.Db.Repo_task.items with
      | [] -> Lwt_result.lift (Ok "открытых задач нет")
      | items -> (
          let lines =
            List.map
              (fun t ->
                Printf.sprintf "%s %s (%s)" t.Task.ref_ t.Task.title
                  (Status.to_string t.Task.status))
              items
          in
          Lwt_result.lift (Ok (String.concat "\n" lines))))

(* ------------------------------------------------------------- кнопки --- *)

(** Колбэк кнопки: [payload] — urlencoded JSON с [context.action],
    [context.task_ref] и пользователем. *)
let button conn ~actor ~payload_json =
  let action =
    Yojson.Safe.Util.(member "context" payload_json |> member "action")
    |> Yojson.Safe.Util.to_string
  in
  let task_ref =
    Yojson.Safe.Util.(member "context" payload_json |> member "task_ref")
    |> Yojson.Safe.Util.to_string
  in
  let* found_outcome = Service.Task.find conn ~ref_:task_ref in
  match found_outcome with
  | Error failure -> Lwt_result.lift (Error failure)
  | Ok task -> (
      let version = task.Task.version in
      match action with
  | "claim" ->
      let* outcome =
        Service.Task.claim conn ~actor ~interface_:Interface.Mattermost
          ~ref_:task_ref ~version ~note:None
      in
      (match outcome with
      | Ok task -> Lwt_result.lift (Ok ("взято в работу " ^ task.Task.ref_))
      | Error failure -> Lwt_result.lift (Error failure))
  | "done" ->
      let* outcome =
        Service.Task.transition conn ~actor ~interface_:Interface.Mattermost
          ~ref_:task_ref ~target:Status.Done ~version ~note:None
      in
      (match outcome with
      | Ok task -> Lwt_result.lift (Ok ("закрыто " ^ task.Task.ref_))
      | Error failure -> Lwt_result.lift (Error failure))
  | other ->
      Lwt_result.lift
        (Error (Service.Failure.Bad_request { message = "неизвестное действие кнопки: " ^ other })))

(* -------------------------------------------------------- доставка DM --- *)

(** Доставить ожидающие уведомления: отправитель — настоящий, через
    Mattermost API; интеграция не настроена — тихо пропускаем, уведомления
    остаются pending до следующего прохода. *)
let deliver conn =
  match config () with
  | Error _ -> Lwt_result.lift (Ok (0, 0))
  | Ok cfg -> (
      let bot_id = cfg.bot_id in
      if bot_id = "" then Lwt_result.lift (Ok (0, 0))
      else
        Service.Notify.deliver_pending conn ~send:(fun ~mm_user_id ~text ->
            Service.Mattermost.send_dm ~base_url:cfg.base_url ~token:cfg.token
              ~me_id:bot_id ~user_id:mm_user_id ~text))

(* ------------------------------------------------------------ обработчик --- *)

let handle req =
  let* body = Dream.body req in
  match config () with
  | Error e ->
      Dream.json ~status:`Service_Unavailable
        (Yojson.Safe.to_string (`Assoc [ ("text", `String ("интеграция не настроена: " ^ e)) ]))
  | Ok cfg -> (
      let fields = parse_form body in
      match field fields "token" with
      | value when value <> cfg.token ->
          Dream.json ~status:`Unauthorized
            (Yojson.Safe.to_string (`Assoc [ ("text", `String "токен не признан") ]))
      | _ -> (
          let conn =
            match Db.Conn.get_current () with Some conn -> conn | None -> invalid_arg "нет базы"
          in
          let user_id = field fields "user_id" in
          let user_name = field fields "user_name" in
          let* outcome =
            let* actor = actor_of_chat conn ~user_id ~user_name in
            match actor with
            | Error e -> Lwt_result.lift (Error (Service.Failure.Unauthorized { message = e }))
            | Ok actor -> (
                match field fields "payload" with
                | "" -> (
                    (* slash-команда *)
                    match field fields "command" with
                    | "/task" -> task_from_chat conn ~actor ~text:(field fields "text") ~trigger_id:(field fields "trigger_id")
                    | "/tasks" -> list_my conn ~actor
                    | other ->
                        Lwt_result.lift
                          (Error (Service.Failure.Bad_request { message = "неизвестная команда: " ^ other })))
                | payload_encoded -> (
                    match Yojson.Safe.from_string payload_encoded with
                    | payload_json -> button conn ~actor ~payload_json
                    | exception _ ->
                        Lwt_result.lift
                          (Error (Service.Failure.Bad_request { message = "payload не разобран" }))))
          in
          (* После изменения задачи — доставка накопленных DM: сбой доставки
             не ломает ответ чату. *)
          let* _deliver = deliver conn in
          match outcome with
          | Ok text -> respond_mm text
          | Error failure ->
              respond_mm ~status:`OK (Service.Failure.to_string failure)))
