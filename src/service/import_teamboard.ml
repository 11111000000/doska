(** Импорт данных Teamboard в трекер (ADR §10.1, этап 3).

    Три файла: реестр проектов, суждения по карточкам, инициативы. Ключ
    идемпотентности — пара (source, source_ref): source="teamboard",
    source_ref=ключ карточки ("проект::вид:слаг"). Повторный запуск обновляет
    содержимое и не плодит дублей.

    Статус приходит из колонки Teamboard и переводится по таблице ADR §10.1.
    Владелец — алиас в пространстве "teamboard"; неразрешённое имя не
    теряется, а превращается в заглушку (§3.1): человек потом свяжет её с
    настоящим актёром.

    Инициатива — задача вида decision, а её карточки — связи relates_to. *)


let ( let* ) t f = Lwt.bind t f

(** Ошибка хранилища — в класс отказа сервисного слоя: наружу уходит
    [Failure], а не строка из репозитория. *)
let storage_error (message : string) : Failure.t = Failure.Storage { message }

type report = {
  projects : int;
  tasks : int;
  created : int;
  updated : int;
  links : int;
  placeholders : int;
  unresolved_owners : string list;
}

let empty_report =
  { projects = 0; tasks = 0; created = 0; updated = 0; links = 0; placeholders = 0;
    unresolved_owners = [] }

(* --------------------------------------------------------- разбор файлов --- *)

let read_json path : (Yojson.Safe.t, Failure.t) result =
  try Ok (Yojson.Safe.from_file path) with
  | Yojson.Json_error e ->
      Error (Failure.Storage { message = Printf.sprintf "%s: %s" path e })
  | Sys_error e ->
      Error (Failure.Storage { message = Printf.sprintf "%s: %s" path e })

let member name json =
  match json with
  | `Assoc fields -> ( match List.assoc_opt name fields with Some v -> v | None -> `Null)
  | _ -> `Null

let str name json = match member name json with `String s -> s | _ -> ""

let list name json = match member name json with `List items -> items | _ -> []

let fields name json = match member name json with `Assoc fields -> fields | _ -> []

(* ------------------------------------------------------- переводы полей --- *)

(** Колонка Teamboard → статус doska (ADR §10.1). *)
let status_of_column column =
  match String.lowercase_ascii (String.trim column) with
  | "shipped" -> Some Domain.Status.Done
  | "review" -> Some Domain.Status.In_review
  | "wip" -> Some Domain.Status.In_progress
  | "blocked" -> Some Domain.Status.Blocked
  | "planned" | "unverified" | "stale" -> Some Domain.Status.Todo
  | "" -> Some Domain.Status.Backlog
  | _ -> None

(** Статус инициативы → статус doska (ADR §10.1). *)
let status_of_epic status =
  match String.lowercase_ascii (String.trim status) with
  | "planned" -> Some Domain.Status.Todo
  | "active" -> Some Domain.Status.In_progress
  | "blocked" -> Some Domain.Status.Blocked
  | "done" -> Some Domain.Status.Done
  | "dropped" -> Some Domain.Status.Cancelled
  | _ -> None

(** Ключ проекта: строчные буквы, цифры, дефис (ADR §3.1). Ключ попадает в
    подпись и в адрес, поэтому пробел и регистр ломают ссылку. *)
let sanitize_key raw =
  let buffer = Buffer.create (String.length raw) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_' then
        Buffer.add_char buffer c
      else if c >= 'A' && c <= 'Z' then Buffer.add_char buffer (Char.lowercase_ascii c)
      else if c = ' ' then Buffer.add_char buffer '-'
      else ())
    raw;
  let key = Buffer.contents buffer in
  if key = "" then "project" else key

(** Проект карточки: часть ключа до "::" ("проект::вид:слаг"). *)
let project_of_card key =
  match String.index_opt key ':' with
  | None -> None
  | Some index ->
      let head = String.sub key 0 index in
      let head =
        match String.index_opt head ':' with
        | Some second -> String.sub head 0 second
        | None -> head
      in
      if head = "" then None else Some (sanitize_key head)

(* ------------------------------------------------------------- владельцы --- *)

(** Владелец из annotations/epics: алиас в пространстве "teamboard", иначе
    заглушка. Возвращает актёра (или отсутствие) и признак, что имя осталось
    неразрешённым. *)
let resolve_owner conn ~owner :
    (Domain.Actor.t option * bool, Failure.t) result Lwt.t =
  let name = String.trim owner in
  if name = "" then Lwt_result.lift (Ok (None, false))
  else
    let* alias = Db.Repo_actor_alias.find conn ~namespace:"teamboard" ~value:name in
    match alias with
    | Error e -> Lwt_result.lift (Error (storage_error e))
    | Ok (Some alias) ->
        let* actor = Db.Repo_actor.by_id conn alias.Db.Repo_actor_alias.actor_id in
        (match actor with
        | Error e -> Lwt_result.lift (Error (storage_error e))
        | Ok (Some actor) -> Lwt_result.lift (Ok (Some actor, false))
        | Ok None ->
            Lwt_result.lift
              (Error (Failure.Not_found { message = "актор алиаса не найден: " ^ name })))
    | Ok None ->
        let handle = Identity.Resolve.normalize name in
        (* Актёр с таким логином может уже быть: имена из annotations
           исторически совпадают с логинами импортированных людей. Второго
           актёра с тем же логином завести нельзя (логин уникален) — вместо
           этого дописываем алиас в пространство "teamboard" тому, кто
           уже есть. *)
        Lwt.bind
          (Db.Repo_actor.by_handle conn handle
          |> Lwt_result.map_error storage_error)
          (fun existing ->
            match existing with
            | Error e -> Lwt_result.lift (Error e)
            | Ok (Some actor) ->
                Lwt.bind
                  (Db.Repo_actor_alias.add conn ~actor_id:actor.Domain.Actor.id
                     ~namespace:"teamboard" ~value:name ()
                  |> Lwt_result.map_error storage_error)
                  (fun _ -> Lwt_result.lift (Ok (Some actor, false)))
            | Ok None ->
                Lwt.bind
                  (Db.Repo_actor.create_placeholder conn ~handle
                     ~display_name:name
                  |> Lwt_result.map_error storage_error)
                  (fun created ->
                    match created with
                    | Error e -> Lwt_result.lift (Error e)
                    | Ok actor ->
                        Lwt.bind
                          (Db.Repo_actor_alias.add conn
                             ~actor_id:actor.Domain.Actor.id
                             ~namespace:"teamboard" ~value:name ()
                          |> Lwt_result.map_error storage_error)
                          (fun _ -> Lwt_result.lift (Ok (Some actor, true)))))

(** Актёр-исполнитель импорта: журнал и авторство задач не должны остаться
    пустыми. Создаётся один раз и переиспользуется. *)
let system_actor conn : (Domain.Actor.t, Failure.t) result Lwt.t =
  let* found = Db.Repo_actor.by_handle conn "teamboard-import" in
  match found with
  | Ok (Some actor) -> Lwt_result.lift (Ok actor)
  | Ok None -> (
      Lwt.bind
        (Db.Repo_actor.create conn ~kind:Domain.Actor.Agent
           ~handle:"teamboard-import" ~display_name:"Импорт Teamboard" ()
        |> Lwt_result.map_error storage_error)
        (fun created ->
          match created with
          | Ok actor -> Lwt_result.lift (Ok actor)
          | Error failure -> Lwt_result.lift (Error failure)))
  | Error e -> Lwt_result.lift (Error (storage_error e))

(* ------------------------------------------------------------- проекты --- *)

let import_projects conn (data : Yojson.Safe.t) :
    (int, Failure.t) result Lwt.t =
  let projects = list "projects" data in
  let rec loop count = function
    | [] -> Lwt_result.lift (Ok count)
    | project :: rest ->
        let raw_id = str "id" project in
        if raw_id = "" then loop count rest
        else
          let key = sanitize_key raw_id in
          let name = let n = str "name" project in if n = "" then raw_id else n in
          let repo_path =
            match list "paths" project with `String path :: _ -> path | _ -> ""
          in
          let asset = str "asset" project in
          let* existing = Db.Repo_project.by_key conn key in
          (match existing with
          | Error e -> Lwt_result.lift (Error (storage_error e))
          | Ok (Some project) ->
              Lwt.bind
                (Db.Repo_project.update_sources conn
                   ~id:project.Domain.Project.id ~repo_path ~asset_class:asset
                |> Lwt_result.map_error storage_error)
                (fun _ -> loop (count + 1) rest)
          | Ok None ->
              Lwt.bind
                (Db.Repo_project.create conn ~key ~name
                   ~autonomy:Domain.Actor.Human_gate ~repo_path ~asset_class:asset
                   ~external_ref:raw_id ()
                |> Lwt_result.map_error storage_error)
                (fun _ -> loop (count + 1) rest))
  in
  loop 0 projects

(* --------------------------------------------------------------- задачи --- *)

(** Доказательство из строки "git: ветка" — ветка; из "sha, дата" — коммит
    с датой в примечании. *)
let evidence_of_annotation source evidence =
  let source = String.trim source in
  let evidence = String.trim evidence in
  match (source, evidence) with
  | _, "" -> []
  | s, _ when String.length s > 0 && s.[0] = '#' ->
      [ (Domain.Evidence.Branch, s, None, None) ]
  | s, _ when String.length s > 0 && s.[0] = '@' ->
      [ (Domain.Evidence.Branch, s, None, None) ]
  | s, e ->
      let kind = if String.contains s ':' then Domain.Evidence.Branch else Domain.Evidence.Commit in
      let ref_value = if String.contains s ':' then s else e in
      let note = if String.contains s ':' then Some e else None in
      [ (kind, ref_value, None, note) ]

let add_evidence conn ~task ~source ~evidence =
  let entries = evidence_of_annotation source evidence in
  let rec loop = function
    | [] -> Lwt_result.lift (Ok ())
    | (kind, ref_value, uri, note) :: rest ->
        Lwt.bind
          (Db.Repo_evidence.add conn ~task_id:task.Domain.Task.id ~kind
             ~ref_:ref_value ?uri:uri ?title:None ?note:note ()
          |> Lwt_result.map_error storage_error)
          (fun _ -> loop rest)
  in
  loop entries

(* ------------------------------------------------------------ инициативы --- *)

let import_annotations conn (data : Yojson.Safe.t) ~actor :
    (int * int * int * int * string list, Failure.t) result Lwt.t =
  let annotations = fields "annotations" data in
  let rec loop tasks created updated placeholders unresolved = function
    | [] -> Lwt_result.lift (Ok (tasks, created, updated, placeholders, unresolved))
    | (card_key, value) :: rest ->
        let title = str "title" value in
        let column = str "column" value in
        if title = "" then loop tasks created updated placeholders unresolved rest
        else
          match status_of_column column with
          | None ->
              (* Неизвестная колонка — не молчаливый бэклог: карточка
                 пропускается, и импорт говорит почему. *)
              Lwt_result.lift
                (Error
                   (Failure.Bad_request
                      { message =
                          Printf.sprintf "неизвестная колонка %s в карточке %s" column
                            card_key }))
          | Some status ->
              let description = str "why" value in
              let owner = str "owner" value in
              Lwt.bind
                (resolve_owner conn ~owner)
                (fun owner_result ->
                  match owner_result with
                  | Error failure -> Lwt_result.lift (Error failure)
                  | Ok (owner_actor, unresolved_flag) ->
                      let assignee =
                        match owner_actor with
                        | None -> None
                        | Some owner_actor -> Some owner_actor.Domain.Actor.handle
                      in
                      let placeholders =
                        if unresolved_flag then placeholders + 1 else placeholders
                      in
                      let unresolved =
                        if unresolved_flag then owner :: unresolved else unresolved
                      in
                      let project = project_of_card card_key in
                      let input : Task.create_input =
                        { title;
                          description;
                          kind = Domain.Task.Task;
                          status;
                          priority = Domain.Task.P2;
                          due_at = None;
                          labels = [];
                          source = Some "teamboard";
                          source_ref = Some card_key;
                          project;
                          assignee;
                          requester = None;
                          parent = None }
                      in
                      Lwt.bind
                        (Task.create conn ~actor ~interface_:Domain.Interface.Import input)
                        (fun outcome ->
                          match outcome with
                          | Error failure -> Lwt_result.lift (Error failure)
                          | Ok (Db.Repo_task.Created task) ->
                              Lwt.bind
                                (add_evidence conn ~task
                                   ~source:(str "source" value)
                                   ~evidence:(str "evidence" value))
                                (fun _ ->
                                                                      (loop (tasks + 1) (created + 1) updated placeholders unresolved rest))
                          | Ok (Db.Repo_task.Existing _task) ->
                              (* Повторный импорт: задача уже есть — обновляем
                                 содержимое, но не спорим с человеком: статус и
                                 исполнитель остаются как есть (правила приёмки
                                 принадлежат людям). *)
                              Lwt.bind
                                (Task.upsert conn ~actor
                                   ~interface_:Domain.Interface.Import input)
                                (fun _ ->
                                                                      (loop (tasks + 1) created (updated + 1) placeholders unresolved rest))))
  in
  loop 0 0 0 0 [] annotations

(* ------------------------------------------------------------ инициативы --- *)

(** Карточки инициативы: список строк из JSON. *)
let cards_of value : string list =
  List.filter_map (function `String s -> Some s | _ -> None) (list "cards" value)

let link_cards conn ~epic ~cards : (int, Failure.t) result Lwt.t =
  (* Каждая карточка инициативы — связь relates_to с задачей инициативы.
     Повторный импорт не плодит связи: уже существующая связь считается
     найденной и пропускается. *)
  let rec loop count = function
    | [] -> Lwt_result.lift (Ok count)
    | card :: rest ->
        Lwt.bind
          (Db.Repo_task.by_source_ref conn ~source:"teamboard" ~source_ref:card
          |> Lwt_result.map_error storage_error)
          (fun found ->
            match found with
            | Error _ ->
                Lwt_result.lift
                  (Error
                     (Failure.Not_found
                        { message = "карточка инициативы не найдена: " ^ card }))
            | Ok None ->
                (* Карточка ещё не импортирована: связь появится при её
                   импорте, а сейчас пропускаем — инициатива без своего
                   состава не теряется. *)
                loop count rest
            | Ok (Some task) ->
                Lwt.bind
                  (Db.Repo_link.find conn ~from_id:epic.Domain.Task.id
                     ~to_id:task.Domain.Task.id ~kind:Domain.Link.Relates_to
                  |> Lwt_result.map_error storage_error)
                  (fun existing ->
                    match existing with
                    | Error _ ->
                        Lwt_result.lift
                          (Error
                             (Failure.Storage
                                { message = "связь не прочитана: " ^ card }))
                    | Ok (Some _) -> loop (count + 1) rest
                    | Ok None ->
                        Lwt.bind
                          (Db.Repo_link.create conn ~from_id:epic.Domain.Task.id
                             ~to_id:task.Domain.Task.id
                             ~kind:Domain.Link.Relates_to ~created_by_id:None
                          |> Lwt_result.map_error storage_error)
                          (fun _ -> loop (count + 1) rest)))
  in
  loop 0 cards

let import_epics conn (data : Yojson.Safe.t) ~actor :
    (int * int * int * int, Failure.t) result Lwt.t =
  let epics = fields "epics" data in
  let rec loop tasks created updated links = function
    | [] -> Lwt_result.lift (Ok (tasks, created, updated, links))
    | (slug, value) :: rest ->
        let title = str "title" value in
        let owner = str "owner" value in
        if title = "" then loop tasks created updated links rest
        else
          match status_of_epic (str "status" value) with
          | None ->
              Lwt_result.lift
                (Error
                   (Failure.Bad_request
                      { message = Printf.sprintf "неизвестный статус инициативы %s" slug }))
          | Some status ->
              let project =
                match list "projects" value with
                | `String first :: _ -> Some (sanitize_key first)
                | _ -> None
              in
              (* Владелец инициативы — тот же алиас, что и у суждений. *)
              let* owner_result = resolve_owner conn ~owner in
              (match owner_result with
              | Error failure -> Lwt_result.lift (Error failure)
              | Ok (owner_actor, _unresolved) ->
                  let assignee =
                    match owner_actor with
                    | None -> None
                    | Some owner_actor -> Some owner_actor.Domain.Actor.handle
                  in
                  let input : Task.create_input =
                    { title;
                      description = str "why" value;
                      kind = Domain.Task.Decision;
                      status;
                      priority = Domain.Task.P2;
                      due_at = None;
                      labels = [];
                      source = Some "teamboard";
                      source_ref = Some ("epic:" ^ slug);
                      project;
                      assignee;
                      requester = None;
                      parent = None }
                  in
                  let* outcome =
                    Task.create conn ~actor ~interface_:Domain.Interface.Import input
                  in
                  (match outcome with
                  | Error failure -> Lwt_result.lift (Error failure)
                  | Ok (Db.Repo_task.Created task) ->
                      Lwt.bind
                        (link_cards conn ~epic:task ~cards:(cards_of value))
                        (fun added ->
                      match added with
                      | Error failure -> Lwt_result.lift (Error failure)
                      | Ok added ->
                          loop (tasks + 1) (created + 1) updated (links + added) rest)
                  | Ok (Db.Repo_task.Existing _task) ->
                      Lwt.bind
                        (link_cards conn ~epic:_task ~cards:(cards_of value))
                        (fun added ->
                      match added with
                      | Error failure -> Lwt_result.lift (Error failure)
                      | Ok added ->
                          loop (tasks + 1) created (updated + 1) (links + added) rest)))
  in
  loop 0 0 0 0 epics

(** Прочитать файл и передать данные дальше.

    Ошибка чтения останавливает импорт на этом шаге: импортировать половину
    файла молча нельзя. *)
let with_json path k =
  Lwt.bind (Lwt_result.lift (read_json path)) (fun result ->
      match result with
      | Error failure -> Lwt_result.lift (Error failure)
      | Ok data -> k data)

let import_data conn ~registry_data ~annotations_data ~epics_data :
    (report, Failure.t) result Lwt.t =
  Lwt.bind (system_actor conn) (fun actor_result ->
      match actor_result with
      | Error failure -> Lwt_result.lift (Error failure)
      | Ok actor ->
          Lwt.bind (import_projects conn registry_data) (fun projects_result ->
              match projects_result with
              | Error failure -> Lwt_result.lift (Error failure)
              | Ok projects ->
                  Lwt.bind (import_annotations conn annotations_data ~actor)
                    (fun annotations ->
                      match annotations with
                      | Error failure -> Lwt_result.lift (Error failure)
                      | Ok (tasks, created, updated, placeholders, unresolved) ->
                          Lwt.bind (import_epics conn epics_data ~actor) (fun epics ->
                              match epics with
                              | Error failure -> Lwt_result.lift (Error failure)
                              | Ok (epic_tasks, epic_created, epic_updated, links) ->
                                  Lwt_result.lift
                                    (Ok
                                       {
                                         projects;
                                         tasks = tasks + epic_tasks;
                                         created = created + epic_created;
                                         updated = updated + epic_updated;
                                         links;
                                         placeholders;
                                         unresolved_owners = unresolved;
                                       })))))
let import_all conn ~registry ~annotations ~epics :
    (report, Failure.t) result Lwt.t =
  with_json registry (fun registry_data ->
      with_json annotations (fun annotations_data ->
          with_json epics (fun epics_data ->
              import_data conn ~registry_data ~annotations_data ~epics_data)))

