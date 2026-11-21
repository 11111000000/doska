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
  (** Родитель по дереву — задача, а не идентификатор: читателю нужен
      заголовок. *)
  parent : Task.t option;
  (** Дети по дереву: ветка ниже задачи. *)
  children : Task.t list;
  (** Связи по графу — входящие и исходящие, читатель видит отношение
      одинаково с обеих сторон. *)
  links : Db.Repo_link.t list;
}

let list conn (filters : Db.Repo_task.filters) :
    (Db.Repo_task.page, Failure.t) result Lwt.t =
  storage_result (Db.Repo_task.list conn filters)

(** Главный запрос: мои задачи по всем проектам (ADR §6.1).

    Исполнитель — актор запроса: правила тут нет, есть отбор. Поэтому use case
    берёт актора, а не логин: кто «я» — решает сервер, клиент подставлять
    ничего не должен. *)
let mine conn ~actor ~limit ~cursor :
    (Db.Repo_task.page, Failure.t) result Lwt.t =
  storage_result
    (Db.Repo_task.mine conn ~assignee_id:actor.Actor.id ~limit ~cursor)

let find conn ~ref_ : (Task.t, Failure.t) result Lwt.t =
  let* found = storage_result (Db.Repo_task.by_ref conn ref_) in
  match found with
  | Ok None -> Lwt_result.lift (Error (not_found ref_))
  | Ok (Some task) -> Lwt_result.lift (Ok task)
  | Error e -> Lwt_result.lift (Error e)

(** Родитель задачи — задача, а не идентификатор: читателю нужен заголовок. *)
let parent_of conn task : (Task.t option, Failure.t) result Lwt.t =
  match task.Task.parent_id with
  | None -> Lwt_result.lift (Ok None)
  | Some id ->
      let* found = storage_result (Db.Repo_task.by_id conn id) in
      (match found with
      | Ok (Some parent) -> Lwt_result.lift (Ok (Some parent))
      | Ok None -> Lwt_result.lift (Ok None)
      | Error e -> Lwt_result.lift (Error e))

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
      let* parent = parent_of conn task in
      let* children =
        storage_result (Db.Repo_task.children conn ~parent_id:task.Task.id)
      in
      let* links =
        storage_result (Db.Repo_link.list_for_task conn ~task_id:task.Task.id)
      in
      (match (comments, evidence, parent, children, links) with
      | Ok comments, Ok evidence, Ok parent, Ok children, Ok links ->
          Lwt_result.lift (Ok { task; comments; evidence; parent; children; links })
      | Error e, _, _, _, _ -> Lwt_result.lift (Error e)
      | _, Error e, _, _, _ -> Lwt_result.lift (Error e)
      | _, _, Error e, _, _ -> Lwt_result.lift (Error e)
      | _, _, _, Error e, _ -> Lwt_result.lift (Error e)
      | _, _, _, _, Error e -> Lwt_result.lift (Error e))

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
  (** Родитель по дереву — его ссылка ([DSK-N]), а не идентификатор: клиент
      знает родителя по номеру. *)
  parent : string option;
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

(** Родитель по ссылке: клиент знает родителя по номеру [DSK-N], а не по
    внутреннему идентификатору. *)
let resolve_parent conn ref_ : (string option, Failure.t) result Lwt.t =
  match ref_ with
  | None -> Lwt_result.lift (Ok None)
  | Some ref_ ->
      let* found = storage_result (Db.Repo_task.by_ref conn ref_) in
      (match found with
      | Ok (Some task) -> Lwt_result.lift (Ok (Some task.Task.id))
      | Ok None ->
          Lwt_result.lift (Error (bad_request ("родитель не найден: " ^ ref_)))
      | Error e -> Lwt_result.lift (Error e))

let create conn ~actor ~interface_ (input : create_input) :
    (Db.Repo_task.created, Failure.t) result Lwt.t =
  let* project = resolve_project conn input.project in
  let* assignee = resolve_actor conn input.assignee in
  let* requester = resolve_actor conn input.requester in
  let* parent = resolve_parent conn input.parent in
  match (project, assignee, requester, parent) with
  | Ok project_id, Ok assignee_id, Ok requester_id, Ok parent_id ->
      let args : Db.Repo_task.create_args =
        {
          Db.Repo_task.title = input.title;
          description = input.description;
          project_id;
          parent_id;
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
  | Error e, _, _, _ -> Lwt_result.lift (Error e)
  | _, Error e, _, _ -> Lwt_result.lift (Error e)
  | _, _, Error e, _ -> Lwt_result.lift (Error e)
  | _, _, _, Error e -> Lwt_result.lift (Error e)

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
  (* Сколько детей задачи ещё открыто: родителя закрывают после детей (D7).
     Число считает сервис, решение принимает домен. *)
  let* open_children =
    storage_result (Db.Repo_task.open_children_count conn ~parent_id:task.Task.id)
  in
  match (autonomy, supervisor, evidence, open_children) with
  | Ok autonomy, Ok supervisor, Ok evidence, Ok open_children ->
      let context =
        Rules.make_context ~actor ~project_autonomy:autonomy
          ~assignee_id:task.Task.assignee_id
          ~is_requester:(task.Task.requester_id = Some actor.Actor.id)
          ~is_supervisor:supervisor ~is_admin:(Identity.Admin.is_admin actor)
          ~has_accept_right:false ~note ~has_evidence:(evidence > 0)
          ~open_children
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
  | Error e, _, _, _ -> Lwt_result.lift (Error e)
  | _, Error e, _, _ -> Lwt_result.lift (Error e)
  | _, _, Error e, _ -> Lwt_result.lift (Error e)
  | _, _, _, Error e -> Lwt_result.lift (Error e)

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

(* ------------------------------------------------------ заявка и отпуск --- *)

(** Заявка на задачу: актор берёт её в работу.

    Кто может претендовать — правило таблицы переходов
    ([Assignee_or_claimant]): свободную задачу берёт любой агент, назначенную —
    только её исполнитель. Исполнитель меняется, если задача была свободна:
    заявка не отменяет назначение, принятое человеком. *)
let claim conn ~actor ~interface_ ~ref_ ~version ~note :
    (Task.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task -> (
      match Rules.check_claim_source task.Task.status with
      | Error message ->
          Lwt_result.lift (Error (Failure.Conflict { message }))
      | Ok () -> (
          let* decision = decide conn ~actor task Status.In_progress note in
          match decision with
          | Error e -> Lwt_result.lift (Error e)
          | Ok () ->
              let assignee =
                match task.Task.assignee_id with
                | None -> Some (Some actor.Actor.id)
                | Some _ -> None
              in
              let* outcome =
                Db.Conn.with_transaction conn (fun () ->
                    let* updated =
                      Db.Repo_task.set_status_and_assignee conn ~ref_:task.Task.ref_
                        ~status:Status.In_progress ~assignee ~version ~note
                    in
                    match updated with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok None -> Lwt_result.lift (Ok None)
                    | Ok (Some id) ->
                        let* _ =
                          Db.Repo_activity.record conn ~action:Activity.Claimed
                            ~task_id:(Some task.Task.id)
                            ~project_id:task.Task.project_id
                            ~actor_id:(Some actor.Actor.id)
                            ~from_value:(Some (Status.to_string task.Task.status))
                            ~to_value:(Some (Status.to_string Status.In_progress))
                            ~summary:note ~interface_ ()
                        in
                        Lwt_result.lift (Ok (Some id)))
              in
              (match outcome with
              | Error e -> Lwt_result.lift (Error (storage e))
              | Ok None -> Lwt_result.lift (Error (stale_version ()))
              | Ok (Some id) -> refresh conn id ~ref_:task.Task.ref_)))

(** Отпуск задачи: работа откатывается, исполнитель снимается — задача
    возвращается в пул (§6.2, [release_task]).

    Отпустить может её исполнитель-агент или любой человек; посторонний агент —
    нет. В отличие от обычного перехода в [todo] отпуск снимает исполнителя:
    «вернуть в пул» и «откатить работу» — разные действия. *)
let release conn ~actor ~interface_ ~ref_ ~version ~note :
    (Task.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task -> (
      match Rules.check_release_source task.Task.status with
      | Error message ->
          Lwt_result.lift (Error (Failure.Conflict { message }))
      | Ok () -> (
          let* decision = decide conn ~actor task Status.Todo note in
          match decision with
          | Error e -> Lwt_result.lift (Error e)
          | Ok () ->
              let* outcome =
                Db.Conn.with_transaction conn (fun () ->
                    let* updated =
                      Db.Repo_task.set_status_and_assignee conn ~ref_:task.Task.ref_
                        ~status:Status.Todo ~assignee:(Some None) ~version ~note
                    in
                    match updated with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok None -> Lwt_result.lift (Ok None)
                    | Ok (Some id) ->
                        let* _ =
                          Db.Repo_activity.record conn ~action:Activity.Released
                            ~task_id:(Some task.Task.id)
                            ~project_id:task.Task.project_id
                            ~actor_id:(Some actor.Actor.id)
                            ~from_value:(Some (Status.to_string task.Task.status))
                            ~to_value:(Some (Status.to_string Status.Todo))
                            ~summary:note ~interface_ ()
                        in
                        Lwt_result.lift (Ok (Some id)))
              in
              (match outcome with
              | Error e -> Lwt_result.lift (Error (storage e))
              | Ok None -> Lwt_result.lift (Error (stale_version ()))
              | Ok (Some id) -> refresh conn id ~ref_:task.Task.ref_)))

(* ------------------------------------------------------- иерархия и связи --- *)

(** Ссылки задач по их идентификаторам: цепочку показывают человеку, а не
    показывают uuid. *)
let refs_of conn ids : (string list, Failure.t) result Lwt.t =
  let rec go acc = function
    | [] -> Lwt_result.lift (Ok (List.rev acc))
    | id :: rest ->
        let* found = storage_result (Db.Repo_task.by_id conn id) in
        (match found with
        | Error e -> Lwt_result.lift (Error e)
        | Ok (Some task) -> go (task.Task.ref_ :: acc) rest
        | Ok None -> go acc rest)
  in
  go [] ids

(** Цепочка блокировок от [current] к [target]: пустая — цепочки нет.

    Идём по рёбрам графа блокировок («X мешает Y»). Глубина ограничена:
    граф небольшой, но защита от бесконечного обхода при испорченных данных
    обязана быть. *)
let rec blocking_chain conn ~visited ~chain current target :
    (string list, Failure.t) result Lwt.t =
  if List.length chain > 64 then Lwt_result.lift (Ok [])
  else if current = target then Lwt_result.lift (Ok chain)
  else if List.mem current visited then Lwt_result.lift (Ok [])
  else
    let* neighbours = storage_result (Db.Repo_link.blocks_out conn ~task_id:current) in
    (match neighbours with
    | Error e -> Lwt_result.lift (Error e)
    | Ok neighbours ->
        let rec try_next = function
          | [] -> Lwt_result.lift (Ok [])
          | next :: rest ->
              let* found =
                blocking_chain conn ~visited:(current :: visited)
                  ~chain:(chain @ [ next ]) next target
              in
              (match found with
              | Ok [] -> try_next rest
              | Ok found -> Lwt_result.lift (Ok found)
              | Error e -> Lwt_result.lift (Error e))
        in
        try_next neighbours)

(** Кольцо в графе блокировок: новая связь замкнула бы «X мешает … мешает
    X». Возвращает сообщение с цепочкой — человеку понятнее, чем «цикл». *)
let check_blocking_cycle conn ~from_id ~to_id ~kind :
    (string option, Failure.t) result Lwt.t =
  match Link.blocking_edge kind ~from_id ~to_id with
  | None -> Lwt_result.lift (Ok None)
  | Some (u, v) ->
      (* Новое ребро u → v; кольцо есть, если уже есть путь v → … → u. *)
      let* chain = blocking_chain conn ~visited:[] ~chain:[ v ] v u in
      (match chain with
      | Error e -> Lwt_result.lift (Error e)
      | Ok [] -> Lwt_result.lift (Ok None)
      | Ok chain ->
          let* refs = refs_of conn chain in
          (match refs with
          | Error e -> Lwt_result.lift (Error e)
          | Ok refs ->
              Lwt_result.lift
                (Ok
                   (Some
                      ("связь замыкает кольцо блокировок: "
                      ^ String.concat " → " refs)))))

(** Цепочка родителей вверх: если в ней сама задача — родителем станет её
    потомок, и дерево замкнётся в кольцо. *)
let parent_chain conn ~task_id current : (string list, Failure.t) result Lwt.t =
  let rec up visited current =
    if List.mem current visited then Lwt_result.lift (Ok [])
    else
      let* parent = storage_result (Db.Repo_task.parent_id_of conn current) in
      (match parent with
      | Error e -> Lwt_result.lift (Error e)
      | Ok None -> Lwt_result.lift (Ok [])
      | Ok (Some pid) ->
          if pid = task_id then Lwt_result.lift (Ok [ pid ])
          else
            let* rest = up (current :: visited) pid in
            (match rest with
            | Error e -> Lwt_result.lift (Error e)
            | Ok [] -> Lwt_result.lift (Ok [])
            | Ok rest -> Lwt_result.lift (Ok (pid :: rest))))
  in
  up [] current

(** Предварительные проверки связи: что не так с парой задач и видом связи.
    [None] — создавать можно. *)
let link_problem conn ~from_task ~to_task ~kind :
    (Failure.t option, Failure.t) result Lwt.t =
  if from_task.Task.id = to_task.Task.id then
    Lwt_result.lift (Ok (Some (bad_request "связь задачи с собой")))
  else
    let* existing =
      storage_result
        (Db.Repo_link.find conn ~from_id:from_task.Task.id ~to_id:to_task.Task.id ~kind)
    in
    (match existing with
    | Error e -> Lwt_result.lift (Error e)
    | Ok (Some _) ->
        Lwt_result.lift (Ok (Some (Failure.Conflict { message = "связь уже есть" })))
    | Ok None ->
        let* mirrored =
          storage_result
            (Db.Repo_link.find_mirror conn ~from_id:from_task.Task.id
               ~to_id:to_task.Task.id ~kind)
        in
        (match mirrored with
        | Error e -> Lwt_result.lift (Error e)
        | Ok (Some _) ->
            Lwt_result.lift
              (Ok
                 (Some
                    (Failure.Conflict
                       { message = "связь уже записана с другой стороны" })))
        | Ok None ->
            let* cycle =
              check_blocking_cycle conn ~from_id:from_task.Task.id
                ~to_id:to_task.Task.id ~kind
            in
            (match cycle with
            | Error e -> Lwt_result.lift (Error e)
            | Ok (Some message) -> Lwt_result.lift (Ok (Some (bad_request message)))
            | Ok None -> Lwt_result.lift (Ok None))))

(** Связь между задачами.

    Связь — отдельная сущность со своим идентификатором: снятие связи не
    трогает ни одну из задач и не требует версии. Но у неё есть два
    ограничения: связь задачи с собой бессмысленна, а в графе блокировок не
    должно быть кольца — иначе «кто мешает» превращается в «все мешают
    всем». *)
let link conn ~actor ~interface_ ~ref_ ~to_ref ~kind :
    (Db.Repo_link.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task -> (
      let* target = find conn ~ref_:to_ref in
      match target with
      | Error e -> Lwt_result.lift (Error e)
      | Ok target ->
          let* problem = link_problem conn ~from_task:task ~to_task:target ~kind in
          (match problem with
          | Error e -> Lwt_result.lift (Error e)
          | Ok (Some failure) -> Lwt_result.lift (Error failure)
          | Ok None ->
              let* outcome =
                Db.Conn.with_transaction conn (fun () ->
                    let* created =
                      Db.Repo_link.create conn ~from_id:task.Task.id
                        ~to_id:target.Task.id ~kind
                        ~created_by_id:(Some actor.Actor.id)
                    in
                    match created with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok link ->
                        let summary =
                          Printf.sprintf "%s %s %s" task.Task.ref_ (Link.to_string kind)
                            target.Task.ref_
                        in
                        let* _ =
                          Db.Repo_activity.record conn ~action:Activity.Linked
                            ~task_id:(Some task.Task.id)
                            ~project_id:task.Task.project_id
                            ~actor_id:(Some actor.Actor.id)
                            ~from_value:(Some target.Task.ref_)
                            ~to_value:(Some (Link.to_string kind))
                            ~summary:(Some summary) ~interface_ ()
                        in
                        Lwt_result.lift (Ok link))
              in
              (match outcome with
              | Error e -> Lwt_result.lift (Error (storage e))
              | Ok link -> Lwt_result.lift (Ok link))))

(** Снятие связи: связь удаляется, задачи остаются как были.

    Связь должна быть у этой задачи: снять чужую связь из чужой задачи —
    не то действие, о котором просили. *)
let unlink conn ~actor ~interface_ ~ref_ ~link_id : (unit, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task ->
      let* found_link = storage_result (Db.Repo_link.by_id conn link_id) in
      (match found_link with
      | Error e -> Lwt_result.lift (Error e)
      | Ok None ->
          Lwt_result.lift
            (Error (Failure.Not_found { message = "связь не найдена: " ^ link_id }))
      | Ok (Some link) ->
          let touches =
            link.Db.Repo_link.from_id = task.Task.id
            || link.Db.Repo_link.to_id = task.Task.id
          in
          if not touches then
            Lwt_result.lift
              (Error (Failure.Not_found { message = "связь не найдена: " ^ link_id }))
          else
            let* outcome =
              Db.Conn.with_transaction conn (fun () ->
                  let* deleted = Db.Repo_link.delete conn link_id in
                  match deleted with
                  | Error e -> Lwt_result.lift (Error e)
                  | Ok false -> Lwt_result.lift (Ok false)
                  | Ok true ->
                      let other =
                        if link.Db.Repo_link.from_id = task.Task.id then
                          link.Db.Repo_link.to_id
                        else link.Db.Repo_link.from_id
                      in
                      let* other_task = Db.Repo_task.by_id conn other in
                      (match other_task with
                      | Error e -> Lwt_result.lift (Error e)
                      | Ok (Some other_task) ->
                          let summary =
                            Printf.sprintf "снята связь %s %s" task.Task.ref_
                              (Link.to_string link.Db.Repo_link.kind)
                          in
                          let* _ =
                            Db.Repo_activity.record conn ~action:Activity.Unlinked
                              ~task_id:(Some task.Task.id)
                              ~project_id:task.Task.project_id
                              ~actor_id:(Some actor.Actor.id)
                              ~from_value:(Some other_task.Task.ref_)
                              ~to_value:(Some (Link.to_string link.Db.Repo_link.kind))
                              ~summary:(Some summary) ~interface_ ()
                          in
                          Lwt_result.lift (Ok true)
                      | Ok None -> Lwt_result.lift (Ok true)))
            in
            (match outcome with
            | Error e -> Lwt_result.lift (Error (storage e))
            | Ok _ -> Lwt_result.lift (Ok ())))

(** Предварительные проверки смены родителя. *)
let parent_problem conn ~task ~parent : (Failure.t option, Failure.t) result Lwt.t =
  match parent with
  | None -> Lwt_result.lift (Ok None)
  | Some parent ->
      if parent.Task.id = task.Task.id then
        Lwt_result.lift
          (Ok (Some (bad_request "задача не может быть своим родителем")))
      else
        let* chain = parent_chain conn ~task_id:task.Task.id parent.Task.id in
        (match chain with
        | Error e -> Lwt_result.lift (Error e)
        | Ok [] -> Lwt_result.lift (Ok None)
        | Ok chain ->
            let* refs = refs_of conn chain in
            (match refs with
            | Error e -> Lwt_result.lift (Error e)
            | Ok refs ->
                Lwt_result.lift
                  (Ok
                     (Some
                        (bad_request
                           ("родитель не может быть потомком задачи: "
                           ^ String.concat " → " refs))))))

(** Смена родителя: задача встаёт в дерево или выходит из него.

    Родителя задают его ссылкой ([DSK-N]) — так же, как его видят в списке.
    Версия обязательна: смена родителя меняет задачу, а значит ломает её
    оптимистичную блокировку. *)
let set_parent conn ~actor ~interface_ ~ref_ ~parent_ref ~version :
    (Task.t, Failure.t) result Lwt.t =
  let* found = find conn ~ref_ in
  match found with
  | Error e -> Lwt_result.lift (Error e)
  | Ok task ->
      let* parent =
        match parent_ref with
        | None -> Lwt_result.lift (Ok None)
        | Some parent_ref ->
            let* parent_task = find conn ~ref_:parent_ref in
            (match parent_task with
            | Error e -> Lwt_result.lift (Error e)
            | Ok parent -> Lwt_result.lift (Ok (Some parent)))
      in
      (match parent with
      | Error e -> Lwt_result.lift (Error e)
      | Ok parent ->
          let* problem = parent_problem conn ~task ~parent in
          (match problem with
          | Error e -> Lwt_result.lift (Error e)
          | Ok (Some failure) -> Lwt_result.lift (Error failure)
          | Ok None ->
              let parent_id =
                match parent with Some p -> Some p.Task.id | None -> None
              in
              let summary =
                match parent with
                | Some p -> "изменён родитель: " ^ p.Task.ref_
                | None -> "родитель снят"
              in
              let* outcome =
                Db.Conn.with_transaction conn (fun () ->
                    let* updated =
                      Db.Repo_task.set_parent conn ~ref_:task.Task.ref_ ~parent_id ~version
                    in
                    match updated with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok None -> Lwt_result.lift (Ok None)
                    | Ok (Some id) ->
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
              | Ok (Some id) -> refresh conn id ~ref_:task.Task.ref_)))

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
