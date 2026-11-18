(** Машина состояний и правила приёмки.

    Правила живут в коде, а не в таблице: переход разрешён или запрещён
    с причиной, которую можно показать человеку. Набор переходов совпадает
    с таблицей §4.1 архитектуры; покрытие всех статусов проверяется тестом
    [test/domain_test.ml]. *)

open Status

(** Кто может выполнить переход. *)
type permission =
  | Anyone
  | Human_only
  | Assignee_or_claimant
  | Requester_or_supervisor
  | Acceptance

(** Что переход требует. [Evidence_preferred] — рекомендация, а не запрет. *)
type requirement =
  | Reason
  | Question
  | Summary
  | Evidence_preferred

(** Контекст решения: кто действует и в каких условиях. *)
type context = {
  actor : Actor.t;
  project_autonomy : Actor.autonomy;
  (** Текущий исполнитель задачи, если он назначен. *)
  assignee_id : string option;
  is_requester : bool;
  (** Актор — руководитель исполнителя (или заявителя). *)
  is_supervisor : bool;
  is_admin : bool;
  (** Явное право приёмки, выданное отдельно от роли. *)
  has_accept_right : bool;
  (** Причина, вопрос или резюме — в зависимости от перехода. *)
  note : string option;
  has_evidence : bool;
}

(** Конструктор контекста: собирает проверку из ролей и фактов. *)
let make_context ~actor ~project_autonomy ~assignee_id ~is_requester ~is_supervisor
    ~is_admin ~has_accept_right ~note ~has_evidence : context =
  {
    actor;
    project_autonomy;
    assignee_id;
    is_requester;
    is_supervisor;
    is_admin;
    has_accept_right;
    note;
    has_evidence;
  }

(** Разрешённый переход: кому и что требуется. *)
type transition = {
  permission : permission;
  requirements : requirement list;
}

(** Таблица переходов (§4.1 архитектуры). *)
let transition_table : (Status.t * Status.t * transition) list =
  [
    (Backlog, Todo, { permission = Anyone; requirements = [] });
    (Backlog, Cancelled, { permission = Human_only; requirements = [ Reason ] });
    ( Todo,
      In_progress,
      { permission = Assignee_or_claimant; requirements = [] } );
    (Todo, Backlog, { permission = Anyone; requirements = [] });
    (In_progress, Blocked, { permission = Anyone; requirements = [ Reason ] });
    ( In_progress,
      Needs_input,
      { permission = Anyone; requirements = [ Question ] } );
    (In_progress, In_review, { permission = Anyone; requirements = [ Summary ] });
    (In_progress, Todo, { permission = Anyone; requirements = [] });
    ( Needs_input,
      In_progress,
      { permission = Requester_or_supervisor; requirements = [] } );
    (Needs_input, Cancelled, { permission = Human_only; requirements = [ Reason ] });
    (In_review, Done, { permission = Acceptance; requirements = [] });
    ( In_review,
      In_progress,
      { permission = Requester_or_supervisor; requirements = [ Reason ] } );
    (Done, In_progress, { permission = Human_only; requirements = [] });
    (Cancelled, Backlog, { permission = Human_only; requirements = [] });
  ]

let find_transition from_ to_ =
  List.find_opt
    (fun (f, t, _) -> f = from_ && t = to_)
    transition_table
  |> Option.map (fun (_, _, tr) -> tr)

let check_permission ctx permission =
  match permission with
  | Anyone -> Ok ()
  | Human_only ->
      if Actor.is_human ctx.actor then Ok ()
      else Error "Это действие доступно только человеку"
  | Assignee_or_claimant ->
      if Actor.is_human ctx.actor then Ok ()
      else if ctx.assignee_id = None then Ok ()
      else if ctx.assignee_id = Some ctx.actor.id then Ok ()
      else Error "Задача назначена другому исполнителю"
  | Requester_or_supervisor ->
      if ctx.is_requester || ctx.is_supervisor then Ok ()
      else if Actor.is_human ctx.actor && (ctx.has_accept_right || ctx.is_admin)
      then Ok ()
      else Error "Это действие доступно заявителю или руководителю"
  | Acceptance ->
      (* R1: агент закрывает задачу сам только в доверенных проектах. *)
      if Actor.is_agent ctx.actor then
        if ctx.project_autonomy = Actor.Auto then Ok ()
        else
          Error
            "Агент не закрывает задачу сам: приёмка за заявителем или руководителем \
             (режим проекта autonomy = human_gate)"
      else if
        ctx.is_requester || ctx.is_supervisor || ctx.has_accept_right || ctx.is_admin
      then Ok ()
      else Error "Закрыть задачу может заявитель, руководитель или администратор"

let check_requirement ctx = function
  | Reason -> (
      match ctx.note with
      | Some s when String.trim s <> "" -> Ok ()
      | _ -> Error "Нужно указать причину")
  | Question -> (
      match ctx.note with
      | Some s when String.trim s <> "" -> Ok ()
      | _ -> Error "Нужно указать вопрос, на который ждём ответа")
  | Summary -> (
      match ctx.note with
      | Some s when String.trim s <> "" -> Ok ()
      | _ -> Error "Нужно указать резюме работы")
  | Evidence_preferred -> Ok ()

let check_requirements ctx requirements =
  List.fold_left
    (fun acc requirement ->
      match acc with
      | Error e -> Error e
      | Ok () -> check_requirement ctx requirement)
    (Ok ())
    requirements

(** Проверка перехода. Возвращает причину отказа — её можно показать. *)
let check ctx from_ to_ : (unit, string) result =
  match find_transition from_ to_ with
  | None ->
      Error
        (Printf.sprintf "Переход %s → %s не предусмотрен правилами"
           (Status.to_string from_) (Status.to_string to_))
  | Some tr ->
      Result.bind (check_permission ctx tr.permission) (fun () ->
          check_requirements ctx tr.requirements)

(** Необязательные замечания: не блокируют переход, но видны. *)
let advisory ctx from_ to_ : string list =
  match find_transition from_ to_ with
  | Some tr
    when List.mem Evidence_preferred tr.requirements && not ctx.has_evidence ->
      [ "Желательно приложить доказательство: ссылку на PR, коммит или файл" ]
  | _ -> []

(** Все статусы, участвующие хотя бы в одном переходе. *)
let covered_statuses : Status.t list =
  List.fold_left
    (fun acc (f, t, _) ->
      let acc = if List.mem t acc then acc else t :: acc in
      if List.mem f acc then acc else f :: acc)
    [] transition_table
  |> List.rev
