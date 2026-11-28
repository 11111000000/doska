(* 16 инструментов MCP над сервисным слоем (§6.2).

    Схема аргументов и обработчик живут в одной записи: tools/list и
    валидация не могут разойтись. Бизнес-отказ — значение Failure, его
    превращает в isError-результат сервер. *)

open Domain

type tool = {
  name : string;
  description : string;
  input_schema : Yojson.Safe.t;
  run : Db.Conn.t -> Actor.t -> Yojson.Safe.t -> (Yojson.Safe.t, Service.Failure.t) result Lwt.t;
}

let ( let* ) t f = Lwt.bind t f

(* ------------------------------------------------------------- разбор --- *)

(* Поле arguments по спецификации MCP необязательно: отсутствие или null —
   не повод ронять сервер на исключении разбора, а пустой набор аргументов. *)
let arg_member (args : Yojson.Safe.t) name : Yojson.Safe.t =
  match args with `Assoc _ -> Yojson.Safe.Util.member name args | _ -> `Null

let arg_string (args : Yojson.Safe.t) name : string option =
  match arg_member args name with
  | `String s when String.trim s <> "" -> Some (String.trim s)
  | _ -> None

let arg_int (args : Yojson.Safe.t) name : int option =
  match arg_member args name with
  | `Int n -> Some n
  | _ -> None

let arg_list_string (args : Yojson.Safe.t) name : string list option =
  match arg_member args name with
  | `List items ->
      Some (List.filter_map (function `String s -> Some s | _ -> None) items)
  | _ -> None

let storage = function Error e -> Error (Service.Failure.Storage { message = e }) | Ok v -> Ok v

let ok json = Ok json

let task_json (t : Task.t) : Yojson.Safe.t =
  `String (Printf.sprintf "%s %s [%s] версия %d" t.ref_ t.title (Status.to_string t.status) t.version)

let text_result text = ok (`Assoc [ ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ]) ])

let json_result (json : Yojson.Safe.t) =
  ok (`Assoc [ ("content", `List [ `Assoc [ ("type", `String "text"); ("text", `String (Yojson.Safe.to_string json)) ] ]) ])

let find_task conn ref_ =
  let* outcome = Service.Task.find conn ~ref_ in
  match outcome with Error f -> Lwt_result.lift (Error f) | Ok t -> Lwt_result.lift (Ok t)

(* инструменты: [conn] — база, [actor] — bearer-токен запроса. *)
let version_of conn ref_ =
  let* found = Service.Task.find conn ~ref_ in
  match found with Error f -> Lwt_result.lift (Error f) | Ok t -> Lwt_result.lift (Ok t.Task.version)

let tools : tool list =
  [
    { name = "whoami";
      description = "кто я: логин, вид, привязка к источнику";
      input_schema = `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
      run = (fun _conn actor _args ->
          ok
            (`Assoc
              [
                ("handle", `String actor.Actor.handle);
                ("kind", `String (Actor.kind_to_string actor.Actor.kind));
                ("display_name", `String actor.Actor.display_name);
              ])
          |> Lwt_result.lift); };
    { name = "my_tasks";
      description = "мои открытые задачи по всем проектам, порядок по срочности";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("limit", `Assoc [ ("type", `String "integer") ]) ] );
          ];
      run = (fun conn actor args ->
          let limit = match arg_int args "limit" with Some n -> n | None -> 20 in
          let* outcome = Service.Task.mine conn ~actor ~limit ~cursor:None in
          (match outcome with
          | Ok page ->
              ok
                (`Assoc
                  [
                    ( "items",
                      `List (List.map task_json page.Db.Repo_task.items) );
                  ])
              |> Lwt_result.lift
          | Error f -> Lwt_result.lift (Error f))); };
    { name = "list_tasks";
      description = "поиск задач: проект, исполнитель, статус, вид, срок, текст";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("project", `Assoc [ ("type", `String "string") ]);
                  ("assignee", `Assoc [ ("type", `String "string") ]);
                  ("status", `Assoc [ ("type", `String "string") ]);
                  ("q", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
      run = (fun conn _actor args ->
          let filters : Db.Repo_task.filters =
            {
              project = arg_string args "project";
              assignee = arg_string args "assignee";
              status = arg_string args "status";
              kind = arg_string args "kind";
              due = arg_string args "due";
              label = arg_string args "label";
              query = arg_string args "q";
              limit = (match arg_int args "limit" with Some n -> n | None -> 20);
              cursor = arg_string args "cursor";
            }
          in
          let* outcome = Service.Task.list conn filters in
          (match outcome with
          | Ok page ->
              ok (`Assoc [ ("items", `List (List.map task_json page.Db.Repo_task.items)) ])
              |> Lwt_result.lift
          | Error f -> Lwt_result.lift (Error f))); };
    { name = "get_task";
      description = "одна задача: поля, версия, вопрос, блокировки";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref" ] );
            ( "properties", `Assoc [ ("ref", `Assoc [ ("type", `String "string") ]) ] );
          ];
      run = (fun conn _actor args ->
          match arg_string args "ref" with
          | None -> Lwt_result.lift (Error (Service.Failure.Bad_request { message = "нужен ref" }))
          | Some ref_ ->
              let* outcome = Service.Task.find conn ~ref_ in
              (match outcome with
              | Ok task -> text_result (Printf.sprintf "%s %s [%s] версия %d\n%s" task.Task.ref_ task.Task.title (Status.to_string task.Task.status) task.Task.version task.Task.description) |> Lwt_result.lift
              | Error f -> Lwt_result.lift (Error f))); };
    { name = "create_task";
      description = "завести задачу: title обязателен; project, assignee, due_at, kind, priority по желанию";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "title" ] );
            ( "properties",
              `Assoc
                [
                  ("title", `Assoc [ ("type", `String "string") ]);
                  ("description", `Assoc [ ("type", `String "string") ]);
                  ("project", `Assoc [ ("type", `String "string") ]);
                  ("assignee", `Assoc [ ("type", `String "string") ]);
                  ("due_at", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
      run = (fun conn actor args ->
          match arg_string args "title" with
          | None ->
              Lwt_result.lift (Error (Service.Failure.Bad_request { message = "нужен title" }))
          | Some title -> (
              let input : Service.Task.create_input =
                {
                  title;
                  description = (match arg_string args "description" with Some d -> d | None -> "");
                  kind = Task.Task;
                  status = Status.Backlog;
                  priority = Task.P2;
                  due_at = arg_string args "due_at";
                  labels = [];
                  source = Some "agent";
                  source_ref = None;
                  project = arg_string args "project";
                  assignee = arg_string args "assignee";
                  requester = None;
                  parent = None;
                }
              in
              let* outcome = Service.Task.create conn ~actor ~interface_:Interface.Mcp input in
              (match outcome with
              | Ok (Db.Repo_task.Created task) -> text_result ("создано " ^ task.Task.ref_) |> Lwt_result.lift
              | Ok (Db.Repo_task.Existing task) -> text_result ("уже существует " ^ task.Task.ref_) |> Lwt_result.lift
              | Error f -> Lwt_result.lift (Error f)))); };
    { name = "claim_task";
      description = "взять задачу в работу (из todo; версия читается автоматически)";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref" ] );
            ( "properties", `Assoc [ ("ref", `Assoc [ ("type", `String "string") ]) ] );
          ];
      run = (fun conn actor args ->
          match arg_string args "ref" with
          | None -> Lwt_result.lift (Error (Service.Failure.Bad_request { message = "нужен ref" }))
          | Some ref_ -> (
              let* version_outcome = version_of conn ref_ in
              match version_outcome with
              | Error f -> Lwt_result.lift (Error f)
              | Ok version -> (
                  let* outcome =
                    Service.Task.claim conn ~actor ~interface_:Interface.Mcp ~ref_
                      ~version ~note:None
                  in
                  (match outcome with
                  | Ok task -> Lwt_result.lift (text_result ("взято в работу " ^ task.Task.ref_))
                  | Error f -> Lwt_result.lift (Error f)))));};
    { name = "release_task";
      description = "вернуть задачу в пул (из in_progress)";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref" ] );
            ( "properties", `Assoc [ ("ref", `Assoc [ ("type", `String "string") ]) ] );
          ];
      run = (fun conn actor args ->
          match arg_string args "ref" with
          | None ->
              Lwt_result.lift
                (Error (Service.Failure.Bad_request { message = "нужен ref" }))
          | Some ref_ -> (
              let* version_outcome = version_of conn ref_ in
              match version_outcome with
              | Error f -> Lwt_result.lift (Error f)
              | Ok version -> (
                  let* outcome =
                    Service.Task.release conn ~actor ~interface_:Interface.Mcp ~ref_
                  ~version ~note:None
                  in
                  (match outcome with
                  | Ok task -> Lwt_result.lift (text_result ("вернуто в пул " ^ task.Task.ref_))
                  | Error f -> Lwt_result.lift (Error f))))) ;};
    { name = "assign_task";
      description = "назначить задачу человеку (право can_assign)";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref"; `String "assignee" ] );
            ( "properties",
              `Assoc
                [
                  ("ref", `Assoc [ ("type", `String "string") ]);
                  ("assignee", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
      run = (fun conn actor args ->
          match (arg_string args "ref", arg_string args "assignee") with
          | Some ref_, Some assignee -> (
              let* version_outcome = version_of conn ref_ in
              match version_outcome with
              | Error f -> Lwt_result.lift (Error f)
              | Ok version -> (
                  let* outcome =
                    Service.Task.assign conn ~actor ~interface_:Interface.Mcp ~ref_
                      ~assignee ~version ~note:None
                  in
                  (match outcome with
                  | Ok task -> Lwt_result.lift (text_result ("назначено " ^ task.Task.ref_))
                  | Error f -> Lwt_result.lift (Error f))))
          | _ ->
              Lwt_result.lift
                (Error (Service.Failure.Bad_request { message = "нужны ref и assignee" }))); };
    { name = "update_task";
      description = "изменить поля: title, description, priority, due_at (версия читается автоматически)";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref" ] );
            ( "properties",
              `Assoc
                [
                  ("ref", `Assoc [ ("type", `String "string") ]);
                  ("title", `Assoc [ ("type", `String "string") ]);
                  ("description", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
      run = (fun conn actor args ->
          match arg_string args "ref" with
          | None ->
              Lwt_result.lift
                (Error (Service.Failure.Bad_request { message = "нужен ref" }))
          | Some ref_ -> (
              let* version_outcome = version_of conn ref_ in
              match version_outcome with
              | Error f -> Lwt_result.lift (Error f)
              | Ok version -> (
                  let fields : Db.Repo_task.patch =
                    {
                      title = arg_string args "title";
                      description = arg_string args "description";
                      priority = None;
                      due_at =
                        (match arg_string args "due_at" with
                        | Some d -> Some (Some d)
                        | None -> None);
                      labels = None;
                    }
                  in
                  let* outcome =
                    Service.Task.patch conn ~actor ~interface_:Interface.Mcp ~ref_
                      ~version fields
                  in
                  (match outcome with
                  | Ok task -> Lwt_result.lift (text_result ("изменено " ^ task.Task.ref_))
                  | Error f -> Lwt_result.lift (Error f))))) ;};
    { name = "comment_on_task";
      description = "комментарий к задаче";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref"; `String "body" ] );
            ( "properties",
              `Assoc
                [
                  ("ref", `Assoc [ ("type", `String "string") ]);
                  ("body", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
      run = (fun conn actor args ->
          match (arg_string args "ref", arg_string args "body") with
          | Some ref_, Some body -> (
              let* outcome =
                Service.Task.comment conn ~actor ~interface_:Interface.Mcp ~ref_ ~body
                  ~parent_id:None
              in
              (match outcome with
              | Ok _ -> text_result "комментарий добавлен" |> Lwt_result.lift
              | Error f -> Lwt_result.lift (Error f)))
          | _ -> Lwt_result.lift (Error (Service.Failure.Bad_request { message = "нужны ref и body" }))); };
    { name = "add_evidence";
      description = "приложить доказательство: kind (branch|commit|pr|link|verification), ref_value, uri?, note?";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref"; `String "kind"; `String "ref_value" ] );
            ( "properties",
              `Assoc
                [
                  ("ref", `Assoc [ ("type", `String "string") ]);
                  ("kind", `Assoc [ ("type", `String "string") ]);
                  ("ref_value", `Assoc [ ("type", `String "string") ]);
                  ("uri", `Assoc [ ("type", `String "string") ]);
                  ("note", `Assoc [ ("type", `String "string") ]);
                ] );
          ];
      run = (fun conn actor args ->
          match
            ( arg_string args "ref",
              Option.bind (arg_string args "kind") Evidence.kind_of_string,
              arg_string args "ref_value" )
          with
          | Some ref_, Some kind, Some ref_value -> (
              let* outcome =
                Service.Task.evidence conn ~actor ~interface_:Interface.Mcp ~ref_ ~kind
                  ~evidence_ref:ref_value
                  ~uri:(arg_string args "uri")
                  ~title:(arg_string args "note")
                  ~note:None
              in
              (match outcome with
              | Ok _ -> text_result "доказательство приложено" |> Lwt_result.lift
              | Error f -> Lwt_result.lift (Error f)))
          | _ ->
              Lwt_result.lift
                (Error (Service.Failure.Bad_request { message = "нужны ref, kind и ref_value" }))); };
    { name = "request_review";
      description = "попросить приёмку: переход в in_review";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref" ] );
            ( "properties", `Assoc [ ("ref", `Assoc [ ("type", `String "string") ]) ] );
          ];
      run = (fun conn actor args ->
          match arg_string args "ref" with
          | None ->
              Lwt_result.lift
                (Error (Service.Failure.Bad_request { message = "нужен ref" }))
          | Some ref_ -> (
              let* version_outcome = version_of conn ref_ in
              match version_outcome with
              | Error f -> Lwt_result.lift (Error f)
              | Ok version -> (
                  let* outcome =
                    Service.Task.transition conn ~actor ~interface_:Interface.Mcp ~ref_
                  ~target:Status.In_review ~version ~note:None
                  in
                  (match outcome with
                  | Ok task -> Lwt_result.lift (text_result ("на приёмке " ^ task.Task.ref_))
                  | Error f -> Lwt_result.lift (Error f))))) ;};
    { name = "complete_task";
      description = "закрыть задачу (может быть отклонено правилами приёмки)";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "ref" ] );
            ( "properties", `Assoc [ ("ref", `Assoc [ ("type", `String "string") ]) ] );
          ];
      run = (fun conn actor args ->
          match arg_string args "ref" with
          | None ->
              Lwt_result.lift
                (Error (Service.Failure.Bad_request { message = "нужен ref" }))
          | Some ref_ -> (
              let* version_outcome = version_of conn ref_ in
              match version_outcome with
              | Error f -> Lwt_result.lift (Error f)
              | Ok version -> (
                  let* outcome =
                    Service.Task.transition conn ~actor ~interface_:Interface.Mcp ~ref_
                  ~target:Status.Done ~version ~note:None
                  in
                  (match outcome with
                  | Ok task -> Lwt_result.lift (text_result ("закрыто " ^ task.Task.ref_))
                  | Error f -> Lwt_result.lift (Error f))))) ;};
    { name = "list_projects";
      description = "проекты трекера";
      input_schema = `Assoc [ ("type", `String "object"); ("properties", `Assoc []) ];
      run = (fun conn _actor _args ->
          let* outcome = Db.Repo_project.list conn in
          (match storage outcome with
          | Ok projects ->
              ok
                (`Assoc
                  [
                    ( "projects",
                      `List
                        (List.map
                           (fun p ->
                             `Assoc
                               [
                                 ("key", `String p.Project.key);
                                 ("name", `String p.Project.name);
                               ])
                           projects) );
                  ])
              |> Lwt_result.lift
          | Error f -> Lwt_result.lift (Error f))); };
    { name = "activity_feed";
      description = "лента активности: последние события";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties", `Assoc [ ("limit", `Assoc [ ("type", `String "integer") ]) ] );
          ];
      run = (fun conn _actor args ->
          let limit = match arg_int args "limit" with Some n -> n | None -> 20 in
          let filters : Db.Repo_activity.filters =
            { Db.Repo_activity.project = None; task = None; actor = None; since = None; limit; cursor = None }
          in
          let* outcome = Db.Repo_activity.list conn filters in
          (match storage outcome with
          | Ok events ->
              ok
                (`Assoc
                  [
                    ( "events",
                      `List
                        (List.map
                           (fun e ->
                             `Assoc
                               [
                                 ("action", `String (Activity.action_to_string e.Activity.action));
                                 ("summary", `String (match e.Activity.summary with Some s -> s | None -> ""));
                               ])
                           events) );
                  ])
              |> Lwt_result.lift
          | Error f -> Lwt_result.lift (Error f))); };
    { name = "search_tasks";
      description = "полнотекстовый поиск по задачам";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "required", `List [ `String "query" ] );
            ( "properties", `Assoc [ ("query", `Assoc [ ("type", `String "string") ]) ] );
          ];
      run = (fun conn _actor args ->
          let filters : Db.Repo_task.filters =
            {
              project = None;
              assignee = None;
              status = None;
              kind = None;
              due = None;
              label = None;
              query = arg_string args "query";
              limit = (match arg_int args "limit" with Some n -> n | None -> 20);
              cursor = None;
            }
          in
          let* outcome = Service.Task.list conn filters in
          (match outcome with
          | Ok page ->
              ok (`Assoc [ ("items", `List (List.map task_json page.Db.Repo_task.items)) ])
              |> Lwt_result.lift
          | Error f -> Lwt_result.lift (Error f))); };
  ]

let find name = List.find_opt (fun tool -> String.equal tool.name name) tools

let schema_of tool = tool.input_schema

let run conn actor name args =
  match find name with
  | None -> Lwt_result.lift (Error (Service.Failure.Not_found { message = "нет такого инструмента: " ^ name }))
  | Some tool -> tool.run conn actor args
