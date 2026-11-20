(** Адаптер REST для задач: разбор запроса, вызов сервиса, ответ.

    Здесь нет ни правил, ни транзакций: use case'ы живут в [Service.Task].
    Обработчик только спрашивает сервис и переводит [Service.Failure.t] в
    код ответа — поэтому MCP и CLI получат те же правила, не переписывая их
    (D5).

    Обработчики написаны плоско: разбор запроса, вызов сервиса и ответ —
    три отдельных шага, а не вложенность из шести [match]. *)

open Domain

let ( let* ) t f = Lwt.bind t f

(* --------------------------------------------------------------- ответы --- *)

let ok payload = Dream.json (Yojson.Safe.to_string payload)

let created payload = Dream.json ~status:`Created (Yojson.Safe.to_string payload)

(** Ответ-промис.

    [Dream.json] уже возвращает промис, поэтому оборачивать его в
    [Lwt.return] нельзя: получится промис в промисе, и обработчик вернёт
    не [response promise], а promise от promise. *)
let send (p : 'a Lwt.t) : 'a Lwt.t = Lwt.bind p (fun x -> Lwt.return x)

(** Отказ use case'а — код ответа: правила, конфликт версии и отсутствие
    ресурса сервис различает сам, HTTP только переводит класс ошибки в код. *)
let fail (failure : Service.Failure.t) : Dream.response Lwt.t =
  Errors.respond (Errors.of_failure failure)

(** Ответ по результату use case'а: успех строит тело, отказ переводится в
    код ответа. Сервис отдаёт промис, значение которого — сам результат, поэтому
    разбор идёт внутри [Lwt.bind]. *)
let answer (r : ('a, Service.Failure.t) result Lwt.t)
    (build : 'a -> Dream.response Lwt.t) : Dream.response Lwt.t =
  Lwt.bind r (fun result ->
      match result with
      | Error failure -> fail failure
      | Ok value -> send (build value))

let bad_request message =
  fail (Service.Failure.Bad_request { message })

(* ------------------------------------------------------------------ список --- *)

let default_limit = 50

let max_limit = 200

let limit_of req =
  match Dream.query req "limit" with
  | None -> default_limit
  | Some raw -> (
      match int_of_string_opt raw with
      | Some n when n > 0 && n <= max_limit -> n
      | _ -> default_limit)

let due_filters = [ "overdue"; "today"; "week"; "none" ]

(** Фильтры списка. Неизвестное значение фильтра — ошибка запроса, а не
    молчаливое «ничего не найдено»: иначе клиент не поймёт, что искал не то. *)
let filters_of req : (Db.Repo_task.filters, string) result =
  let status = Dream.query req "status" in
  let kind = Dream.query req "kind" in
  let due = Dream.query req "due" in
  let error =
    match status with
    | Some s when Status.of_string s = None -> Some ("неизвестный статус: " ^ s)
    | _ -> (
        match kind with
        | Some k when Task.kind_of_string k = None -> Some ("неизвестный вид: " ^ k)
        | _ -> (
            match due with
            | Some d when not (List.mem d due_filters) ->
                Some ("неизвестный фильтр срока: " ^ d)
            | _ -> None))
  in
  match error with
  | Some message -> Error message
  | None ->
      Ok
        {
          Db.Repo_task.project = Dream.query req "project";
          assignee = Dream.query req "assignee";
          status;
          kind;
          due;
          query = Dream.query req "q";
          label = Dream.query req "label";
          limit = limit_of req;
          cursor = Dream.query req "cursor";
        }

let list req =
  Context.with_actor req (fun conn _actor ->
      match filters_of req with
      | Error message -> bad_request message
      | Ok filters ->
          answer (Service.Task.list conn filters) (fun page ->
              ok
                (`Assoc
                  [
                    ("items", `List (List.map View.task page.Db.Repo_task.items));
                    ("next_cursor", View.opt page.Db.Repo_task.next_cursor);
                    ("limit", `Int filters.Db.Repo_task.limit);
                  ])))

(* ------------------------------------------------------------------ чтение --- *)

let get req =
  let ref_ = Dream.param req "ref" in
  Context.with_actor req (fun conn _actor ->
      answer (Service.Task.get conn ~ref_) (fun (details : Service.Task.details) ->
          ok
            (`Assoc
              [
                ("task", View.task details.task);
                ("comments", `List (List.map View.comment details.comments));
                ("evidence", `List (List.map View.evidence details.evidence));
              ])))

(* ---------------------------------------------------------------- создание --- *)

(** Разбор тела создания: значения, которые не понимает сервис, — ошибка
    запроса, а не отказ правила. *)
let parse_create body : (Service.Task.create_input, string) result =
  let title =
    match Params.string_field body "title" with
    | Some t when String.trim t <> "" -> Some (String.trim t)
    | _ -> None
  in
  let kind =
    match Params.string_field body "kind" with
    | None -> Some Task.Task
    | Some k -> Task.kind_of_string k
  in
  let status =
    match Params.string_field body "status" with
    | None -> Some Status.Backlog
    | Some s -> Status.of_string s
  in
  let priority =
    match Params.string_field body "priority" with
    | None -> Some Task.P2
    | Some p -> Task.priority_of_string p
  in
  match (title, kind, status, priority) with
  | Some title, Some kind, Some status, Some priority ->
      Ok
        {
          title;
          description =
            (match Params.string_field body "description" with
            | Some d -> d
            | None -> "");
          kind;
          status;
          priority;
          due_at = Params.string_field body "due_at";
          labels =
            (match Params.string_list_field body "labels" with
            | Some l -> l
            | None -> []);
          source =
            (match Params.string_field body "source" with
            | Some s -> Some s
            | None -> Some "api");
          source_ref = Params.string_field body "source_ref";
          project = Params.string_field body "project";
          assignee = Params.string_field body "assignee";
          requester = Params.string_field body "requester";
        }
  | None, _, _, _ -> Error "нужно поле title"
  | _, None, _, _ -> Error "неизвестный вид задачи"
  | _, _, None, _ -> Error "неизвестный статус"
  | _, _, _, None -> Error "неизвестный приоритет"

let create req =
  Context.with_body req (fun conn actor body ->
      match parse_create body with
      | Error message -> bad_request message
      | Ok input ->
          answer
            (Service.Task.create conn ~actor ~interface_:Interface.Api input)
            (fun created_task ->
              match created_task with
              | Db.Repo_task.Created task ->
                  created (`Assoc [ ("task", View.task task) ])
              | Db.Repo_task.Existing task ->
                  ok
                    (`Assoc
                       [
                         ("task", View.task task);
                         ("idempotent", `Bool true);
                       ])))

(* ------------------------------------------------------------------ правка --- *)

let parse_patch body : (Db.Repo_task.patch, string) result =
  let priority =
    match Params.string_field body "priority" with
    | None -> Ok None
    | Some p -> (
        match Task.priority_of_string p with
        | Some priority -> Ok (Some priority)
        | None -> Error ("неизвестный приоритет: " ^ p))
  in
  match priority with
  | Error e -> Error e
  | Ok priority ->
      Ok
        {
          title = Params.string_field body "title";
          description = Params.string_field body "description";
          priority;
          due_at =
            (match Params.json_field body "due_at" with
            | None -> None
            | Some `Null -> Some None
            | Some (`String s) -> Some (Some s)
            | Some _ -> Some None);
          labels = Params.string_list_field body "labels";
        }

let patch req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match parse_patch body with
      | Error message -> bad_request message
      | Ok fields -> (
          match Params.int_field body "version" with
          | None ->
              bad_request
                "нужно поле version: правка защищена оптимистичной блокировкой"
          | Some version ->
              answer
                (Service.Task.patch conn ~actor ~interface_:Interface.Api ~ref_ ~version
                   fields)
                (fun task -> ok (`Assoc [ ("task", View.task task) ]))))

(* --------------------------------------------------------------- переходы --- *)

let transition req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match (Params.string_field body "to", Params.int_field body "version") with
      | None, _ -> bad_request "нужно поле to"
      | _, None ->
          bad_request
            "нужно поле version: переход защищён оптимистичной блокировкой"
      | Some target_name, Some version -> (
          match Status.of_string target_name with
          | None -> bad_request ("неизвестный статус: " ^ target_name)
          | Some target ->
              answer
                (Service.Task.transition conn ~actor ~interface_:Interface.Api ~ref_
                   ~target ~version
                   ~note:(Params.string_field body "reason"))
                (fun task -> ok (`Assoc [ ("task", View.task task) ]))))

(* --------------------------------------------------------------- назначение --- *)

let assign req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match (Params.string_field body "assignee", Params.int_field body "version") with
      | None, _ -> bad_request "нужно поле assignee"
      | _, None ->
          bad_request
            "нужно поле version: назначение защищено оптимистичной блокировкой"
      | Some handle, Some version ->
          answer
            (Service.Task.assign conn ~actor ~interface_:Interface.Api ~ref_ ~assignee:handle
               ~version ~note:(Params.string_field body "note"))
            (fun task -> ok (`Assoc [ ("task", View.task task) ])))

(* ------------------------------------------------------- комментарии и факты --- *)

let comment req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match Params.string_field body "body" with
      | None | Some "" -> bad_request "нужно поле body"
      | Some text ->
          answer
            (Service.Task.comment conn ~actor ~interface_:Interface.Api ~ref_ ~body:text
               ~parent_id:(Params.string_field body "parent_id"))
            (fun comment -> created (`Assoc [ ("comment", View.comment comment) ])))

let evidence req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match
        (Params.string_field body "kind", Params.string_field body "ref")
      with
      | None, _ | _, None -> bad_request "нужны поля kind и ref"
      | Some kind_name, Some evidence_ref -> (
          match Evidence.kind_of_string kind_name with
          | None ->
              bad_request ("неизвестный вид доказательства: " ^ kind_name)
          | Some kind ->
              answer
                (Service.Task.evidence conn ~actor ~interface_:Interface.Api ~ref_ ~kind
                   ~evidence_ref
                   ~uri:(Params.string_field body "uri")
                   ~title:(Params.string_field body "title")
                   ~note:(Params.string_field body "note"))
                (fun evidence ->
                  created (`Assoc [ ("evidence", View.evidence evidence) ]))))

(* --------------------------------------------------------------- журнал и люди --- *)

let activity req =
  Context.with_actor req (fun conn _actor ->
      let filters : Db.Repo_activity.filters =
        {
          Db.Repo_activity.project = Dream.query req "project";
          task = Dream.query req "task";
          actor = Dream.query req "actor";
          since = Dream.query req "since";
          limit = limit_of req;
          cursor = Dream.query req "cursor";
        }
      in
      let* items = Db.Repo_activity.list conn filters in
      match items with
      | Error e -> fail (Service.Failure.Storage { message = e })
      | Ok items ->
          send
            (ok
               (`Assoc
                  [
                    ("items", `List (List.map View.activity items));
                    ("limit", `Int filters.Db.Repo_activity.limit);
                  ])))

let actors _req =
  Context.with_actor _req (fun conn _actor ->
      let* items = Db.Repo_actor.list conn in
      match items with
      | Error e -> fail (Service.Failure.Storage { message = e })
      | Ok items ->
          send (ok (`Assoc [ ("items", `List (List.map View.actor items)) ])))
