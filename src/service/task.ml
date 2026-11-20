(** Use case'ы задач — единственное место, где живут правила доступа и
    транзакции над задачами.

    HTTP-слой — адаптер: он разбирает запрос, зовёт сервис и переводит
    [Failure.t] в код ответа. Пока use case'ы жили в обработчике, правило
    перехода пришлось бы повторять в каждом интерфейсе, а журнал писал
    интерфейс константой — и агентский вызов неотличим от человеческого
    (D5).

    Ответ use case'а — данные: [Task.t], [Comment.t], [Evidence.t] либо
    [Failure.t]. Исключений сервис не бросает.

    Слой репозитория отдаёт промис-результат [('a, string) result Lwt.t], то
    есть значением промисса является сам результат. Поэтому каждый вызов
    разбирается явно: [Ok] — значение, [Error] — отказ. *)

open Domain

let ( let* ) t f = Lwt.bind t f

(* ------------------------------------------------------------------ ошибки --- *)

(** Ошибка хранилища: текст SQL-ошибки не должен выглядеть как отказ правила,
    поэтому у него собственный класс — клиент получит «сломалось у нас». *)
let storage message = Failure.Storage { message }

(** Репозиторий отвечает строкой ошибки; сервис превращает её в [Failure.t].
    Ошибка хранилища не смешивается с отказом правила. *)
let storage_result (r : ('a, string) result Lwt.t) : ('a, Failure.t) result Lwt.t =
  Lwt.bind r (fun v ->
      match v with
      | Ok x -> Lwt_result.lift (Ok x)
      | Error e -> Lwt_result.lift (Error (storage e)))

let bad_request message = Failure.Bad_request { message }

let not_found ref_ = Failure.Not_found { message = "задача не найдена: " ^ ref_ }

let stale_version () =
  Failure.Conflict
    { message = "задача изменилась: версия устарела, перечитайте задачу" }

(** Репозиторий ждёт у [parent_id] значение вида "опция внутри опции": [None] —
    комментарий без ответа, [Some (Some id)] — ответ на комментарий. *)
let opt_arg = function None -> None | Some v -> Some (Some v)

(* ------------------------------------------------------------------ чтение --- *)

(** Задача со всем, что к ней относится. *)
type details = {
  task : Task.t;
  comments : Comment.t list;
  evidence : Evidence.t list;
}

let list conn (filters : Db.Repo_task.filters) :
    (Db.Repo_task.page, Failure.t) result Lwt.t =
  storage_result (Db.Repo_task.list conn filters)

let find conn ~ref_ : (Task.t, Failure.t) result Lwt.t =
  let* found = storage_result (Db.Repo_task.by_ref conn ref_) in
  match found with
  | Ok None -> Lwt_result.lift (Error (not_found ref_))
  | Ok (Some task) -> Lwt_result.lift (Ok task)
  | Error e -> Lwt_result.lift (Error e)

let get conn ~ref_ : (details, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task ->
      let* comments =
        storage_result (Db.Repo_task.comments conn ~task_id:task.Task.id)
      in
      let* evidence =
        storage_result (Db.Repo_evidence.list_for_task conn ~task_id:task.Task.id)
      in
      (match (comments, evidence) with
      | Ok comments, Ok evidence -> Lwt_result.lift (Ok { task; comments; evidence })
      | Error e, _ -> Lwt_result.lift (Error e)
      | _, Error e -> Lwt_result.lift (Error e))

(** Перечитать задачу после изменения: вернуться клиенту надо свежее
    состояние, а не то, что было до записи. *)
let refresh conn id ~ref_ : (Task.t, Failure.t) result Lwt.t =
  let* found = storage_result (Db.Repo_task.by_id conn id) in
  match found with
  | Ok None -> Lwt_result.lift (Error (not_found ref_))
  | Ok (Some task) -> Lwt_result.lift (Ok task)
  | Error e -> Lwt_result.lift (Error e)

(* ---------------------------------------------------------------- создание --- *)

(** Вход создания задачи.

    Проект, исполнитель и заявитель заданы логинами, а не идентификаторами:
    клиент знает человека по имени, а не по uuid. *)
type create_input = {
  title : string;
  description : string;
  kind : Task.kind;
  status : Status.t;
  priority : Task.priority;
  due_at : string option;
  labels : string list;
  source : string option;
  source_ref : string option;
  project : string option;
  assignee : string option;
  requester : string option;
}

let resolve_project conn key : (string option, Failure.t) result Lwt.t =
  match key with
  | None -> Lwt_result.lift (Ok None)
  | Some key ->
      let* found = storage_result (Db.Repo_project.by_key conn key) in
      (match found with
      | Ok (Some project) -> Lwt_result.lift (Ok (Some project.Project.id))
      | Ok None -> Lwt_result.lift (Error (bad_request ("проект не найден: " ^ key)))
      | Error e -> Lwt_result.lift (Error e))

let resolve_actor conn handle : (string option, Failure.t) result Lwt.t =
  match handle with
  | None -> Lwt_result.lift (Ok None)
  | Some handle ->
      let* found = storage_result (Db.Repo_actor.by_handle conn handle) in
      (match found with
      | Ok (Some actor) -> Lwt_result.lift (Ok (Some actor.Actor.id))
      | Ok None -> Lwt_result.lift (Error (bad_request ("актор не найден: " ^ handle)))
      | Error e -> Lwt_result.lift (Error e))

let create conn ~actor ~interface_ (input : create_input) :
    (Db.Repo_task.created, Failure.t) result Lwt.t =
  let* project = resolve_project conn input.project in
  let* assignee = resolve_actor conn input.assignee in
  let* requester = resolve_actor conn input.requester in
  match (project, assignee, requester) with
  | Ok project_id, Ok assignee_id, Ok requester_id ->
      let args : Db.Repo_task.create_args =
        {
          Db.Repo_task.title = input.title;
          description = input.description;
          project_id;
          kind = input.kind;
          status = input.status;
          priority = input.priority;
          assignee_id;
          requester_id =
            (match requester_id with
            | Some id -> Some id
            | None -> Some actor.Actor.id);
          reporter_id = Some actor.Actor.id;
          created_by_id = Some actor.Actor.id;
          due_at = input.due_at;
          labels = input.labels;
          source = input.source;
          source_ref = input.source_ref;
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
                    ~summary:(Some task.Task.title) ~interface_ ()
                in
                Lwt_result.lift (Ok (Db.Repo_task.Created task)))
      in
      (match outcome with
      | Error e -> Lwt_result.lift (Error (storage e))
      | Ok created -> Lwt_result.lift (Ok created))
  | Error e, _, _ -> Lwt_result.lift (Error e)
  | _, Error e, _ -> Lwt_result.lift (Error e)
  | _, _, Error e -> Lwt_result.lift (Error e)

(* ------------------------------------------------------------------ правка --- *)

(** Какие поля правка действительно меняет: [None] — поле не трогали,
    [Some None] — срок сняли. *)
let changed_fields (p : Db.Repo_task.patch) : string list =
  let names = ref [] in
  let add name = names := name :: !names in
  (match p.title with Some _ -> add "title" | None -> ());
  (match p.description with Some _ -> add "description" | None -> ());
  (match p.priority with Some _ -> add "priority" | None -> ());
  (match p.due_at with Some _ -> add "due_at" | None -> ());
  (match p.labels with Some _ -> add "labels" | None -> ());
  List.rev !names

let patch conn ~actor ~interface_ ~ref_ ~version (fields : Db.Repo_task.patch) :
    (Task.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task ->
      let* outcome =
        Db.Conn.with_transaction conn (fun () ->
            let* updated = Db.Repo_task.update conn ~ref_ ~version fields in
            match updated with
            | Error e -> Lwt_result.lift (Error e)
            | Ok None -> Lwt_result.lift (Ok None)
            | Ok (Some id) ->
                let summary =
                  match changed_fields fields with
                  | [] -> "поля не изменены"
                  | names -> "изменены поля: " ^ String.concat ", " names
                in
                let* _ =
                  Db.Repo_activity.record conn ~action:Activity.Updated
                    ~task_id:(Some task.Task.id)
                    ~project_id:task.Task.project_id
                    ~actor_id:(Some actor.Actor.id)
                    ~from_value:None ~to_value:None ~summary:(Some summary)
                    ~interface_ ()
                in
                Lwt_result.lift (Ok (Some id)))
      in
      (match outcome with
      | Error e -> Lwt_result.lift (Error (storage e))
      | Ok None -> Lwt_result.lift (Error (stale_version ()))
      | Ok (Some id) -> refresh conn id ~ref_)

(* --------------------------------------------------------------- переходы --- *)

(** Режим приёмки проекта: в доверенном проекте агент закрывает задачу сам
    (D1), в остальных — за заявителем или руководителем. *)
let autonomy_of conn task : (Actor.autonomy, Failure.t) result Lwt.t =
  match task.Task.project_id with
  | None -> Lwt_result.lift (Ok Actor.Human_gate)
  | Some id ->
      let* found = storage_result (Db.Repo_project.by_id conn id) in
      (match found with
      | Ok (Some project) -> Lwt_result.lift (Ok project.Project.autonomy)
      | Ok None -> Lwt_result.lift (Ok Actor.Human_gate)
      | Error e -> Lwt_result.lift (Error e))

(** Руководитель актора-исполнителя (или заявителя, если исполнителя нет):
    ему положена приёмка и разбор «нужна информация». *)
let is_supervisor_of conn task actor : (bool, Failure.t) result Lwt.t =
  let subject =
    match task.Task.assignee_id with Some id -> Some id | None -> task.Task.requester_id
  in
  match subject with
  | None -> Lwt_result.lift (Ok false)
  | Some id ->
      let* found = storage_result (Db.Repo_actor.supervisor_of conn id) in
      (match found with
      | Ok (Some supervisor_id) -> Lwt_result.lift (Ok (supervisor_id = actor.Actor.id))
      | Ok None -> Lwt_result.lift (Ok false)
      | Error e -> Lwt_result.lift (Error e))

(** Решение о переходе принимает домен; здесь мы только собираем его контекст
    и переводим отказ в [Failure.Forbidden] с понятными деталями. *)
let decide conn ~actor task target note : (unit, Failure.t) result Lwt.t =
  let* autonomy = autonomy_of conn task in
  let* supervisor = is_supervisor_of conn task actor in
  let* evidence = storage_result (Db.Repo_evidence.count conn ~task_id:task.Task.id) in
  match (autonomy, supervisor, evidence) with
  | Ok autonomy, Ok supervisor, Ok evidence ->
      let context =
        Rules.make_context ~actor ~project_autonomy:autonomy
          ~assignee_id:task.Task.assignee_id
          ~is_requester:(task.Task.requester_id = Some actor.Actor.id)
          ~is_supervisor:supervisor ~is_admin:(Identity.Admin.is_admin actor)
          ~has_accept_right:false ~note ~has_evidence:(evidence > 0)
      in
      (match Rules.check context task.Task.status target with
      | Error message ->
          Lwt_result.lift
            (Error
               (Failure.Forbidden
                  {
                    message;
                    details =
                      [
                        ("task", task.Task.ref_);
                        ("from", Status.to_string task.Task.status);
                        ("to", Status.to_string target);
                      ];
                  }))
      | Ok () -> Lwt_result.lift (Ok ()))
  | Error e, _, _ -> Lwt_result.lift (Error e)
  | _, Error e, _ -> Lwt_result.lift (Error e)
  | _, _, Error e -> Lwt_result.lift (Error e)

let transition conn ~actor ~interface_ ~ref_ ~target ~version ~note :
    (Task.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task -> (
      let* decision = decide conn ~actor task target note in
      match decision with
      | Error e -> Lwt_result.lift (Error e)
      | Ok () ->
          let* outcome =
            Db.Conn.with_transaction conn (fun () ->
                let* updated =
                  Db.Repo_task.set_status conn ~ref_:task.Task.ref_ ~status:target
                    ~version ~note
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
                        ~interface_ ()
                    in
                    Lwt_result.lift (Ok (Some id)))
          in
          (match outcome with
          | Error e -> Lwt_result.lift (Error (storage e))
          | Ok None -> Lwt_result.lift (Error (stale_version ()))
          | Ok (Some id) -> refresh conn id ~ref_:task.Task.ref_))

(* ----------------------------------------------------------- назначение --- *)

let assign conn ~actor ~interface_ ~ref_ ~assignee ~version ~note :
    (Task.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task -> (
      let* target = storage_result (Db.Repo_actor.by_handle conn assignee) in
      match target with
      | Ok None -> Lwt_result.lift (Error (bad_request ("актор не найден: " ^ assignee)))
      | Error e -> Lwt_result.lift (Error e)
      | Ok (Some target) -> (
          match Rules.may_assign ~actor ~target with
          | Error message ->
              Lwt_result.lift (Error (Failure.Forbidden { message; details = [] }))
          | Ok () ->
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
                            ~to_value:(Some target.Actor.id) ~summary:note ~interface_ ()
                        in
                        Lwt_result.lift (Ok (Some id)))
              in
              (match outcome with
              | Error e -> Lwt_result.lift (Error (storage e))
              | Ok None -> Lwt_result.lift (Error (stale_version ()))
              | Ok (Some id) -> refresh conn id ~ref_)))

(* --------------------------------------------------- комментарии и факты --- *)

let comment conn ~actor ~interface_ ~ref_ ~body ~parent_id :
    (Comment.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task ->
      let* outcome =
        Db.Conn.with_transaction conn (fun () ->
            let* comment =
              Db.Repo_task.add_comment conn ~task_id:task.Task.id ~body
                ~author_id:(Some actor.Actor.id)
                ?parent_id:(opt_arg parent_id) ()
            in
            match comment with
            | Error e -> Lwt_result.lift (Error e)
            | Ok comment ->
                let* _ =
                  Db.Repo_activity.record conn ~action:Activity.Commented
                    ~task_id:(Some task.Task.id)
                    ~project_id:task.Task.project_id
                    ~actor_id:(Some actor.Actor.id)
                    ~from_value:None ~to_value:None ~summary:(Some body) ~interface_ ()
                in
                Lwt_result.lift (Ok comment))
      in
      match outcome with
      | Error e -> Lwt_result.lift (Error (storage e))
      | Ok comment -> Lwt_result.lift (Ok comment)

let evidence conn ~actor ~interface_ ~ref_ ~kind ~evidence_ref ~uri ~title ~note :
    (Evidence.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task ->
      let* outcome =
        Db.Conn.with_transaction conn (fun () ->
            let* evidence =
              Db.Repo_evidence.add conn ~task_id:task.Task.id ~kind ~ref_:evidence_ref
                ?uri:(uri) ?title:(title) ?note:(note)
                ?author_id:(Some actor.Actor.id) ()
            in
            match evidence with
            | Error e -> Lwt_result.lift (Error e)
            | Ok evidence ->
                let* _ =
                  Db.Repo_activity.record conn ~action:Activity.Evidence_added
                    ~task_id:(Some task.Task.id)
                    ~project_id:task.Task.project_id
                    ~actor_id:(Some actor.Actor.id)
                    ~from_value:None ~to_value:(Some evidence_ref) ~summary:None
                    ~interface_ ()
                in
                Lwt_result.lift (Ok evidence))
      in
      match outcome with
      | Error e -> Lwt_result.lift (Error (storage e))
      | Ok evidence -> Lwt_result.lift (Ok evidence)
