(** Обработчики REST API для задач (§6.1 архитектуры).

    Правило доступа одно: переход статуса проверяет домен
    ([Domain.Rules]), а не API. API переводит отказ правила в 403 с понятным
    текстом — никогда в 500.

    Обработчики написаны плоско: разбор запроса, поиск в базе и ответ — три
    отдельных шага, а не вложенность из шести [match]. *)

open Domain

let ( let* ) t f = Lwt.bind t f

let db_error e = Errors.make Errors.Internal e

let ok payload = Dream.json (Yojson.Safe.to_string payload)

let created payload = Dream.json ~status:`Created (Yojson.Safe.to_string payload)

(** Ответ-промис.

    [Dream.json] уже возвращает промис, поэтому оборачивать его в
    [Lwt.return] нельзя: получится промис в промисе, и обработчик вернёт
    не [response promise], а promise от promise. *)
let send (p : 'a Lwt.t) : 'a Lwt.t = Lwt.bind p (fun x -> Lwt.return x)

(* --------------------------------------------------------------- ответы --- *)

let bad_request message = Errors.respond (Errors.make Errors.Bad_request message)

let forbidden message = Errors.respond (Errors.make Errors.Forbidden message)

let not_found ref_ =
  Errors.respond (Errors.make Errors.Not_found ("задача не найдена: " ^ ref_))

let db_failure e = Errors.respond (db_error e)

let conflict message = Errors.respond (Errors.make Errors.Conflict message)

(** Значение необязательного аргумента: [None] — аргумента нет,
    [Some (Some v)] — аргумент есть и равен [v]. *)
let opt_arg = function None -> None | Some v -> Some (Some v)

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
let filters_of req : (Db.Repo_task.filters, Errors.t) result =
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
  | Some message -> Error (Errors.make Errors.Bad_request message)
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
      | Error e -> Errors.respond e
      | Ok filters ->
          let* page = Db.Repo_task.list conn filters in
          match page with
          | Error e -> db_failure e
          | Ok page ->
              send
                (ok
                   (`Assoc
                      [
                        ( "items",
                          `List (List.map View.task page.Db.Repo_task.items) );
                        ("next_cursor", View.opt page.Db.Repo_task.next_cursor);
                        ("limit", `Int filters.Db.Repo_task.limit);
                      ])))

(* ------------------------------------------------------------------ чтение --- *)

let get req =
  let ref_ = Dream.param req "ref" in
  Context.with_actor req (fun conn _actor ->
      let* found = Db.Repo_task.by_ref conn ref_ in
      match found with
      | Error e -> db_failure e
      | Ok None -> not_found ref_
      | Ok (Some task) ->
          let* comments = Db.Repo_task.comments conn ~task_id:task.Task.id in
          let* evidence = Db.Repo_evidence.list_for_task conn ~task_id:task.Task.id in
          match (comments, evidence) with
          | Error e, _ | _, Error e -> db_failure e
          | Ok comments, Ok evidence ->
              send
                (ok
                   (`Assoc
                      [
                        ("task", View.task task);
                        ("comments", `List (List.map View.comment comments));
                        ("evidence", `List (List.map View.evidence evidence));
                      ])))

(* ---------------------------------------------------------------- создание --- *)

type parsed = {
  title : string;
  description : string;
  kind : Task.kind;
  status : Status.t;
  priority : Task.priority;
  due_at : string option;
  labels : string list;
  source : string option;
  source_ref : string option;
}

let parse_create body : (parsed, string) result =
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
        }
  | None, _, _, _ -> Error "нужно поле title"
  | _, None, _, _ -> Error "неизвестный вид задачи"
  | _, _, None, _ -> Error "неизвестный статус"
  | _, _, _, None -> Error "неизвестный приоритет"

let lookup_project conn body : (string option, Errors.t) result Lwt.t =
  match Params.string_field body "project" with
  | None -> Lwt_result.lift (Ok None)
  | Some key -> (
      let* found = Db.Repo_project.by_key conn key in
      match found with
      | Error e -> Lwt_result.lift (Error (db_error e))
      | Ok (Some project) -> Lwt_result.lift (Ok (Some project.Project.id))
      | Ok None ->
          Lwt_result.lift
            (Error (Errors.make Errors.Bad_request ("проект не найден: " ^ key))))

let lookup_actor conn body name : (string option, Errors.t) result Lwt.t =
  match Params.string_field body name with
  | None -> Lwt_result.lift (Ok None)
  | Some handle -> (
      let* found = Db.Repo_actor.by_handle conn handle in
      match found with
      | Error e -> Lwt_result.lift (Error (db_error e))
      | Ok (Some actor) -> Lwt_result.lift (Ok (Some actor.Actor.id))
      | Ok None ->
          Lwt_result.lift
            (Error (Errors.make Errors.Bad_request ("актор не найден: " ^ handle))))

let create req =
  Context.with_body req (fun conn actor body ->
      match parse_create body with
      | Error message -> bad_request message
      | Ok parsed ->
          let* project = lookup_project conn body in
          let* assignee = lookup_actor conn body "assignee" in
          let* requester = lookup_actor conn body "requester" in
          match (project, assignee, requester) with
          | Error e, _, _ | _, Error e, _ | _, _, Error e -> Errors.respond e
          | Ok project_id, Ok assignee_id, Ok requester_id ->
              let args : Db.Repo_task.create_args =
                {
                  Db.Repo_task.title = parsed.title;
                  description = parsed.description;
                  project_id;
                  kind = parsed.kind;
                  status = parsed.status;
                  priority = parsed.priority;
                  assignee_id;
                  requester_id =
                    (match requester_id with
                    | Some id -> Some id
                    | None -> Some actor.Actor.id);
                  reporter_id = Some actor.Actor.id;
                  created_by_id = Some actor.Actor.id;
                  due_at = parsed.due_at;
                  labels = parsed.labels;
                  source = parsed.source;
                  source_ref = parsed.source_ref;
                }
              in
              let* outcome =
                Db.Conn.with_transaction conn (fun () ->
                    let* created_task = Db.Repo_task.create conn args in
                    match created_task with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok (Db.Repo_task.Existing task) ->
                        Lwt_result.lift (Ok (Db.Repo_task.Existing task))
                    | Ok (Db.Repo_task.Created task) ->
                        let* _ =
                          Db.Repo_activity.record conn ~action:Activity.Created
                            ~task_id:(Some task.Task.id)
                            ~project_id:task.Task.project_id
                            ~actor_id:(Some actor.Actor.id)
                            ~from_value:None ~to_value:None
                            ~summary:(Some task.Task.title) ~interface_:"api" ()
                        in
                        Lwt_result.lift (Ok (Db.Repo_task.Created task)))
              in
              match outcome with
              | Error e -> db_failure e
              | Ok (Db.Repo_task.Created task) ->
                  send (created (`Assoc [ ("task", View.task task) ]))
              | Ok (Db.Repo_task.Existing task) ->
                  send
                    (ok
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
              let* found = Db.Repo_task.by_ref conn ref_ in
              match found with
              | Error e -> db_failure e
              | Ok None -> not_found ref_
              | Ok (Some task) ->
                  let* outcome =
                    Db.Conn.with_transaction conn (fun () ->
                        let* updated =
                          Db.Repo_task.update conn ~ref_ ~version fields
                        in
                        match updated with
                        | Error e -> Lwt_result.lift (Error e)
                        | Ok None -> Lwt_result.lift (Ok None)
                        | Ok (Some id) ->
                            let* _ =
                              Db.Repo_activity.record conn ~action:Activity.Status_changed
                                ~task_id:(Some task.Task.id)
                                ~project_id:task.Task.project_id
                                ~actor_id:(Some actor.Actor.id)
                                ~from_value:(Some (string_of_int task.Task.version))
                                ~to_value:(Some (string_of_int (task.Task.version + 1)))
                                ~summary:None ~interface_:"api" ()
                            in
                            Lwt_result.lift (Ok (Some id)))
                  in
                  match outcome with
                  | Error e -> db_failure e
                  | Ok None ->
                      conflict
                        "задача изменилась: версия устарела, перечитайте задачу"
                  | Ok (Some id) ->
                      let* refreshed = Db.Repo_task.by_id conn id in
                      match refreshed with
                      | Error e -> db_failure e
                      | Ok (Some task) ->
                          send (ok (`Assoc [ ("task", View.task task) ]))
                      | Ok None -> not_found ref_))

(* --------------------------------------------------------------- переходы --- *)

let autonomy_of conn task : (Actor.autonomy, string) result Lwt.t =
  match task.Task.project_id with
  | None -> Lwt_result.lift (Ok Actor.Human_gate)
  | Some id -> (
      let* found = Db.Repo_project.by_id conn id in
      match found with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (Some project) -> Lwt_result.lift (Ok project.Project.autonomy)
      | Ok None -> Lwt_result.lift (Ok Actor.Human_gate))

(** Руководитель актора-исполнителя (или заявителя, если исполнителя нет):
    ему положена приёмка и разбор «нужна информация». *)
let is_supervisor_of conn task actor : (bool, string) result Lwt.t =
  let subject =
    match task.Task.assignee_id with Some id -> Some id | None -> task.Task.requester_id
  in
  match subject with
  | None -> Lwt_result.lift (Ok false)
  | Some id -> (
      let* supervisor = Db.Repo_actor.supervisor_of conn id in
      match supervisor with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (Some supervisor_id) -> Lwt_result.lift (Ok (supervisor_id = actor.Actor.id))
      | Ok None -> Lwt_result.lift (Ok false))

(** Решение о переходе принимает домен; здесь мы только собираем его контекст
    и переводим отказ в 403 с понятным телом. *)
let decide conn actor task target note =
  let* autonomy = autonomy_of conn task in
  let* supervisor = is_supervisor_of conn task actor in
  let* evidence = Db.Repo_evidence.count conn ~task_id:task.Task.id in
  match (autonomy, supervisor, evidence) with
  | Error e, _, _ | _, Error e, _ | _, _, Error e -> Lwt_result.lift (Error (db_error e))
  | Ok autonomy, Ok supervisor, Ok evidence ->
      let context =
        Rules.make_context ~actor ~project_autonomy:autonomy
          ~assignee_id:task.Task.assignee_id
          ~is_requester:(task.Task.requester_id = Some actor.Actor.id)
          ~is_supervisor:supervisor ~is_admin:(Auth.is_admin actor)
          ~has_accept_right:false ~note ~has_evidence:(evidence > 0)
      in
      (match Rules.check context task.Task.status target with
      | Error message ->
          Lwt_result.lift
            (Error
               (Errors.make Errors.Forbidden message
                  ~details:
                    [
                      ("task", `String task.Task.ref_);
                      ("from", `String (Status.to_string task.Task.status));
                      ("to", `String (Status.to_string target));
                    ]))
      | Ok () -> Lwt_result.lift (Ok ()))

let apply_transition conn actor task target version note =
  let* decision = decide conn actor task target note in
  match decision with
  | Error e -> Errors.respond e
  | Ok () ->
      let* outcome =
        Db.Conn.with_transaction conn (fun () ->
            let* updated =
              Db.Repo_task.set_status conn ~ref_:task.Task.ref_ ~status:target ~version
                ~note
            in
            match updated with
            | Error e -> Lwt_result.lift (Error e)
            | Ok None -> Lwt_result.lift (Ok None)
            | Ok (Some id) ->
                let* _ =
                  Db.Repo_activity.record conn ~action:Activity.Status_changed
                    ~task_id:(Some task.Task.id)
                    ~project_id:task.Task.project_id
                    ~actor_id:(Some actor.Actor.id)
                    ~from_value:(Some (Status.to_string task.Task.status))
                    ~to_value:(Some (Status.to_string target)) ~summary:note
                    ~interface_:"api" ()
                in
                Lwt_result.lift (Ok (Some id)))
      in
      match outcome with
      | Error e -> db_failure e
      | Ok None ->
          conflict "задача изменилась: версия устарела, перечитайте задачу"
      | Ok (Some id) ->
          let* refreshed = Db.Repo_task.by_id conn id in
          match refreshed with
          | Error e -> db_failure e
          | Ok (Some task) -> send (ok (`Assoc [ ("task", View.task task) ]))
          | Ok None -> not_found task.Task.ref_

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
              let* found = Db.Repo_task.by_ref conn ref_ in
              match found with
              | Error e -> db_failure e
              | Ok None -> not_found ref_
              | Ok (Some task) ->
                  let note = Params.string_field body "reason" in
                  apply_transition conn actor task target version note))

(* --------------------------------------------------------------- назначение --- *)

(** Кто может назначать.

    На этапе 1 у агента нет ни учётной записи, ни флага [can_assign]: право
    назначать другого человека агент не получает вовсе. Человек назначает
    кого угодно. На этапе 2 это правило переедет в домен и будет опираться на
    scope учётной записи. *)
let may_assign actor target =
  if Actor.is_agent actor then target.Actor.id = actor.Actor.id else true

let assign req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match (Params.string_field body "assignee", Params.int_field body "version") with
      | None, _ -> bad_request "нужно поле assignee"
      | _, None ->
          bad_request
            "нужно поле version: назначение защищено оптимистичной блокировкой"
      | Some handle, Some version ->
          let* found = Db.Repo_task.by_ref conn ref_ in
          let* target = Db.Repo_actor.by_handle conn handle in
          match (found, target) with
          | Error e, _ | _, Error e -> db_failure e
          | Ok None, _ -> not_found ref_
          | _, Ok None -> bad_request ("актор не найден: " ^ handle)
          | Ok (Some task), Ok (Some target) ->
              if not (may_assign actor target) then
                forbidden
                  "агент не может назначать задачу другому человеку: право can_assign \
                   появится вместе с учётными записями на этапе 2"
              else
                let* outcome =
                  Db.Conn.with_transaction conn (fun () ->
                      let* updated =
                        Db.Repo_task.set_assignee conn ~ref_ ~version
                          ~assignee_id:(Some target.Actor.id)
                      in
                      match updated with
                      | Error e -> Lwt_result.lift (Error e)
                      | Ok None -> Lwt_result.lift (Ok None)
                      | Ok (Some id) ->
                          let action =
                            match task.Task.assignee_id with
                            | None -> Activity.Assigned
                            | Some _ -> Activity.Reassigned
                          in
                          let* _ =
                            Db.Repo_activity.record conn ~action
                              ~task_id:(Some task.Task.id)
                              ~project_id:task.Task.project_id
                              ~actor_id:(Some actor.Actor.id)
                              ~from_value:task.Task.assignee_id
                              ~to_value:(Some target.Actor.id)
                              ~summary:(Params.string_field body "note")
                              ~interface_:"api" ()
                          in
                          Lwt_result.lift (Ok (Some id)))
                in
                match outcome with
                | Error e -> db_failure e
                | Ok None ->
                    conflict
                      "задача изменилась: версия устарела, перечитайте задачу"
                | Ok (Some id) ->
                    let* refreshed = Db.Repo_task.by_id conn id in
                    match refreshed with
                    | Error e -> db_failure e
                    | Ok (Some task) ->
                        send (ok (`Assoc [ ("task", View.task task) ]))
                    | Ok None -> not_found ref_)

(* ------------------------------------------------------- комментарии и факты --- *)

let comment req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match Params.string_field body "body" with
      | None | Some "" -> bad_request "нужно поле body"
      | Some text ->
          let* found = Db.Repo_task.by_ref conn ref_ in
          match found with
          | Error e -> db_failure e
          | Ok None -> not_found ref_
          | Ok (Some task) ->
              let* outcome =
                Db.Conn.with_transaction conn (fun () ->
                    let* comment =
                      Db.Repo_task.add_comment conn ~task_id:task.Task.id ~body:text
                        ~author_id:(Some actor.Actor.id)
                        ?parent_id:(opt_arg (Params.string_field body "parent_id")) ()
                    in
                    match comment with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok comment ->
                        let* _ =
                          Db.Repo_activity.record conn ~action:Activity.Commented
                            ~task_id:(Some task.Task.id)
                            ~project_id:task.Task.project_id
                            ~actor_id:(Some actor.Actor.id)
                            ~from_value:None ~to_value:None ~summary:(Some text)
                            ~interface_:"api" ()
                        in
                        Lwt_result.lift (Ok comment))
              in
              match outcome with
              | Error e -> db_failure e
              | Ok comment ->
                  send (created (`Assoc [ ("comment", View.comment comment) ])))

let evidence req =
  let ref_ = Dream.param req "ref" in
  Context.with_body req (fun conn actor body ->
      match
        (Params.string_field body "kind", Params.string_field body "ref")
      with
      | None, _ | _, None -> bad_request "нужны поля kind и ref"
      | Some kind_name, Some evidence_ref ->
          let* found = Db.Repo_task.by_ref conn ref_ in
          match found with
          | Error e -> db_failure e
          | Ok None -> not_found ref_
          | Ok (Some task) -> (
              match Evidence.kind_of_string kind_name with
              | None ->
                  bad_request ("неизвестный вид доказательства: " ^ kind_name)
              | Some kind ->
                  let* outcome =
                    Db.Conn.with_transaction conn (fun () ->
                        let* evidence =
                          Db.Repo_evidence.add conn ~task_id:task.Task.id ~kind
                            ~ref_:evidence_ref
                            ?uri:(Params.string_field body "uri")
                            ?title:(Params.string_field body "title")
                            ?note:(Params.string_field body "note")
                            ?author_id:(Some actor.Actor.id) ()
                        in
                        match evidence with
                        | Error e -> Lwt_result.lift (Error e)
                        | Ok evidence ->
                            let* _ =
                              Db.Repo_activity.record conn
                                ~action:Activity.Evidence_added
                                ~task_id:(Some task.Task.id)
                                ~project_id:task.Task.project_id
                                ~actor_id:(Some actor.Actor.id)
                                ~from_value:None ~to_value:(Some evidence_ref)
                                ~summary:None ~interface_:"api" ()
                            in
                            Lwt_result.lift (Ok evidence))
                  in
                  match outcome with
                  | Error e -> db_failure e
                  | Ok evidence ->
                      send
                        (created (`Assoc [ ("evidence", View.evidence evidence) ]))))

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
      | Error e -> db_failure e
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
      | Error e -> db_failure e
      | Ok items ->
          send (ok (`Assoc [ ("items", `List (List.map View.actor items)) ])))
