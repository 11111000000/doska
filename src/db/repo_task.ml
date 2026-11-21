(** Доступ к задачам — ядру трекера.

    Задача = обязательство. Здесь она читается, создаётся, меняется по
    правилам домена и дополняется комментариями. *)

open Domain

(** Связка для result-промиссов: ошибка пробрасывается как есть, успешное
    значение разбирается в ветке. *)
let ( let* ) t f = Lwt.bind t f

type filters = {
  project : string option;
  assignee : string option;
  status : string option;
  kind : string option;
  due : string option;
  query : string option;
  label : string option;
  limit : int;
  cursor : string option;
}

type page = {
  items : Task.t list;
  (** Курсор следующей страницы: [None], если страница последняя. *)
  next_cursor : string option;
}

let of_json (json : Yojson.Safe.t) : Task.t =
  let status =
    match Row.opt_string json "status" with
    | Some s -> ( match Status.of_string s with
        | Some status -> status
        | None -> Status.Backlog)
    | None -> Status.Backlog
  in
  let kind =
    match Row.opt_string json "kind" with
    | Some s -> ( match Task.kind_of_string s with
        | Some kind -> kind
        | None -> Task.Task)
    | None -> Task.Task
  in
  let priority =
    match Row.opt_string json "priority" with
    | Some s -> ( match Task.priority_of_string s with
        | Some priority -> priority
        | None -> Task.P2)
    | None -> Task.P2
  in
  {
    id = Row.string_ json "id" ~default:"";
    ref_ = Row.string_ json "ref" ~default:"";
    project_id = Row.opt_string json "project_id";
    project_key = Row.opt_string json "project_key";
    parent_id = Row.opt_string json "parent_id";
    kind;
    status;
    priority;
    title = Row.string_ json "title" ~default:"";
    description = Row.string_ json "description" ~default:"";
    assignee_id = Row.opt_string json "assignee_id";
    assignee_name = Row.opt_string json "assignee_name";
    requester_id = Row.opt_string json "requester_id";
    reporter_id = Row.opt_string json "reporter_id";
    created_by_id = Row.opt_string json "created_by_id";
    due_at = Row.opt_string json "due_at";
    blocked_reason = Row.opt_string json "blocked_reason";
    labels = Row.string_list json "labels";
    source = Row.opt_string json "source";
    source_ref = Row.opt_string json "source_ref";
    version = Row.int_ json "version" ~default:1;
    created_at = Row.string_ json "created_at" ~default:"";
    updated_at = Row.string_ json "updated_at" ~default:"";
    started_at = Row.opt_string json "started_at";
    completed_at = Row.opt_string json "completed_at";
  }

(** Общий подзапрос задачи: сама задача плюс ключ проекта и имя исполнителя —
    то, что человек читает в списке. *)
let task_select =
  "SELECT row_to_json(x)::text FROM (SELECT t.*, p.key AS project_key, \
   a.display_name AS assignee_name FROM task t \
   LEFT JOIN project p ON p.id = t.project_id \
   LEFT JOIN actor a ON a.id = t.assignee_id"

let by_id conn id : (Task.t option, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf "%s WHERE t.id = %s AND t.deleted_at IS NULL) x" task_select literal)
      |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let by_ref conn ref_ : (Task.t option, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf "%s WHERE t.ref = %s AND t.deleted_at IS NULL) x" task_select
       (Conn.quote ref_))
  |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

(** Поиск по паре (source, source_ref): по ней импорт не плодит дубли. *)
let by_source_ref conn ~source ~source_ref : (Task.t option, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf
       "%s WHERE t.source = %s AND t.source_ref = %s AND t.deleted_at IS NULL) x"
       task_select
       (Conn.quote source)
       (Conn.quote source_ref))
  |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

(** Экранирование спецсимволов шаблона LIKE: пользовательский «%» не должен
    превращаться в «найди всё». *)
let like_escape (s : string) : string =
  let b = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      match c with
      | '\\' -> Buffer.add_string b "\\\\"
      | '%' -> Buffer.add_string b "\\%"
      | '_' -> Buffer.add_string b "\\_"
      | c -> Buffer.add_char b c)
    s;
  Buffer.contents b

let due_condition = function
  | "overdue" -> Some "(t.due_at IS NOT NULL AND t.due_at < now())"
  | "today" ->
      Some
        "(t.due_at >= date_trunc('day', now()) AND t.due_at < date_trunc('day', now()) \
         + interval '1 day')"
  | "week" -> Some "(t.due_at IS NOT NULL AND t.due_at < now() + interval '7 days')"
  | "none" -> Some "t.due_at IS NULL"
  | _ -> None

(** Список задач по фильтрам. Пагинация — курсорная: курсор равен id последней
    выданной задачи, следующая страница начинается строго после неё. *)
let list conn (f : filters) : (page, string) result Lwt.t =
  let conditions = ref [ "t.deleted_at IS NULL" ] in
  let add c = conditions := c :: !conditions in
  (match f.project with
  | Some p -> add (Printf.sprintf "p.key = %s" (Conn.quote p))
  | None -> ());
  (match f.assignee with
  | Some a -> add (Printf.sprintf "a.handle = %s" (Conn.quote a))
  | None -> ());
  (match f.status with
  | Some s -> add (Printf.sprintf "t.status = %s::task_status" (Conn.quote s))
  | None -> ());
  (match f.kind with
  | Some k -> add (Printf.sprintf "t.kind = %s::task_kind" (Conn.quote k))
  | None -> ());
  (match f.due with
  | Some d -> (
      match due_condition d with
      | Some c -> add c
      | None -> ())
  | None -> ());
  (match f.query with
  | Some q when String.trim q <> "" ->
      let pattern = Conn.quote ("%" ^ like_escape (String.trim q) ^ "%") in
      add
        (Printf.sprintf
           "(t.title ILIKE %s ESCAPE '\\' OR t.description ILIKE %s ESCAPE '\\')"
           pattern pattern)
  | _ -> ());
  (match f.label with
  | Some l -> add (Printf.sprintf "%s = ANY(t.labels)" (Conn.quote l))
  | None -> ());
  (match f.cursor with
  | Some c -> (
      match Conn.uuid_literal c with
      | Some literal ->
          add
            (Printf.sprintf
               "(t.created_at, t.id) < (SELECT created_at, id FROM task WHERE id = %s)"
               literal)
      | None -> ())
  | None -> ());
  let where = String.concat " AND " (List.rev !conditions) in
  (* На одну строку больше лимита: так видно, есть ли следующая страница. *)
  let sql =
    Printf.sprintf "%s WHERE %s) x ORDER BY x.created_at DESC, x.id DESC LIMIT %d"
      task_select where (f.limit + 1)
  in
  Conn.query_json_rows conn sql
  |> Lwt_result.map (fun rows ->
         let items = List.map of_json rows in
         let rec take n l =
           if n <= 0 then [] else match l with [] -> [] | x :: rest -> x :: take (n - 1) rest
         in
         let page_items = take f.limit items in
         let next_cursor =
           if List.length items > f.limit then
             match List.rev page_items with
             | last :: _ -> Some last.Task.id
             | [] -> None
           else None
         in
         { items = page_items; next_cursor })

(* ------------------------------------------------------------ главный запрос --- *)

(** Корзина срочности: 0 — просрочено, 1 — срок в ближайшие сутки, 2 — срок
    позже, 3 — срока нет. Считается от [now()], поэтому один и тот же запрос
    внутри транзакции всегда видит одну и ту же картину. *)
let mine_bucket alias =
  Printf.sprintf
    "CASE WHEN %s.due_at IS NULL THEN 3 WHEN %s.due_at < now() THEN 0 \
     WHEN %s.due_at < now() + interval '1 day' THEN 1 ELSE 2 END"
    alias alias alias

(** Ключ порядка главного запроса: корзина, срок, приоритет, давность и
    идентификатор. Идентификатор в конце нужен, чтобы порядок был полным:
    без него равные строки переставлялись бы между страницами.

    [COALESCE] вместо пустого срока — не вкус: в сравнении кортежей NULL даёт
    «неизвестно», а не «больше», и задачи без срока тогда нельзя было бы
    расставить между собой. [infinity] больше любого настоящего момента, то
    же, что [NULLS LAST]. *)
let mine_key alias =
  Printf.sprintf
    "(%s, COALESCE(%s.due_at, 'infinity'::timestamptz), %s.priority, %s.created_at, \
     %s.id)"
    (mine_bucket alias) alias alias alias alias

(** Тот же ключ отдельными колонками: подзапрос курсора должен отдавать
    столько же колонок, сколько их в сравниваемом кортеже. *)
let mine_key_columns alias =
  Printf.sprintf
    "%s, COALESCE(%s.due_at, 'infinity'::timestamptz), %s.priority, %s.created_at, \
     %s.id"
    (mine_bucket alias) alias alias alias alias

(** Главный запрос: мои задачи по всем проектам (ADR §6.1).

    Открытые задачи исполнителя, отсортированные по срочности: просроченные
    первыми, потом срок в ближайшие сутки, потом остальные, потом без срока;
    внутри — по сроку, приоритету и давности.

    Курсор — идентификатор последней выданной задачи. Следующая страница
    начинается со строго следующей по порядку, поэтому строки не теряются и не
    повторяются. Неверный курсор игнорируется, а курсор на несуществующую
    задачу даёт пустую страницу — так же, как в [list]. *)
let mine conn ~assignee_id ~limit ~cursor : (page, string) result Lwt.t =
  match Conn.uuid_literal assignee_id with
  | None -> Lwt_result.lift (Error "идентификатор исполнителя — не uuid")
  | Some assignee ->
      let conditions =
        ref
          [
            Printf.sprintf "t.assignee_id = %s" assignee;
            "t.deleted_at IS NULL";
            "t.completed_at IS NULL";
            "t.status NOT IN ('done','cancelled')";
          ]
      in
      (match cursor with
      | Some c -> (
          match Conn.uuid_literal c with
          | Some literal ->
              conditions :=
                Printf.sprintf
                  "(%s > (SELECT %s FROM task c WHERE c.id = %s))"
                  (mine_key "t") (mine_key_columns "c") literal
                :: !conditions
          | None -> ())
      | None -> ());
      let where = String.concat " AND " (List.rev !conditions) in
      let sql =
        Printf.sprintf
          "SELECT row_to_json(x)::text FROM (SELECT t.*, p.key AS project_key, \
           a.display_name AS assignee_name FROM task t \
           LEFT JOIN project p ON p.id = t.project_id \
           LEFT JOIN actor a ON a.id = t.assignee_id \
           WHERE %s ORDER BY %s ASC, COALESCE(t.due_at, 'infinity'::timestamptz) ASC, \
           t.priority ASC, t.created_at ASC, t.id ASC LIMIT %d) x"
          where (mine_bucket "t") (limit + 1)
      in
      Conn.query_json_rows conn sql
      |> Lwt_result.map (fun rows ->
             let items = List.map of_json rows in
             let rec take n l =
               if n <= 0 then [] else match l with [] -> [] | x :: rest -> x :: take (n - 1) rest
             in
             let page_items = take limit items in
             let next_cursor =
               if List.length items > limit then
                 match List.rev page_items with
                 | last :: _ -> Some last.Task.id
                 | [] -> None
               else None
             in
             { items = page_items; next_cursor })

type create_args = {
  title : string;
  description : string;
  project_id : string option;
  parent_id : string option;
  kind : Task.kind;
  status : Status.t;
  priority : Task.priority;
  assignee_id : string option;
  requester_id : string option;
  reporter_id : string option;
  created_by_id : string option;
  due_at : string option;
  labels : string list;
  source : string option;
  source_ref : string option;
}

(** Результат создания: [Created] — новая задача, [Existing] — такая уже была
    (повтор по (source, source_ref) не плодит дубль). *)
type created =
  | Created of Task.t
  | Existing of Task.t

let uuid_sql = function
  | None -> Ok "NULL"
  | Some id -> (
      match Conn.uuid_literal id with
      | Some literal -> Ok literal
      | None -> Error (Printf.sprintf "неверный идентификатор: %s" id))

let labels_sql labels =
  match labels with
  | [] -> "ARRAY[]::text[]"
  | items ->
      Printf.sprintf "ARRAY[%s]::text[]"
        (String.concat "," (List.map Conn.quote items))

let insert_sql (a : create_args) : (string, string) result =
  let ( let* ) = Result.bind in
  let* project_id = uuid_sql a.project_id in
  let* parent_id = uuid_sql a.parent_id in
  let* assignee_id = uuid_sql a.assignee_id in
  let* requester_id = uuid_sql a.requester_id in
  let* reporter_id = uuid_sql a.reporter_id in
  let* created_by_id = uuid_sql a.created_by_id in
  let sql =
    Printf.sprintf
      "INSERT INTO task (ref, project_id, parent_id, kind, status, priority, title, \
       description, assignee_id, requester_id, reporter_id, created_by_id, due_at, labels, \
       source, source_ref) VALUES ('DSK-' || nextval('task_ref_seq'), %s, %s, %s::task_kind, \
       %s::task_status, %s::task_priority, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) \
       RETURNING id::text"
      project_id
      parent_id
      (Conn.quote (Task.kind_to_string a.kind))
      (Conn.quote (Status.to_string a.status))
      (Conn.quote (Task.priority_to_string a.priority))
      (Conn.quote a.title)
      (Conn.quote a.description)
      assignee_id
      requester_id
      reporter_id
      created_by_id
      (match a.due_at with None -> "NULL" | Some d -> Conn.quote d)
      (labels_sql a.labels)
      (match a.source with None -> "NULL" | Some s -> Conn.quote s)
      (match a.source_ref with None -> "NULL" | Some s -> Conn.quote s)
  in
  Ok sql

let insert conn (a : create_args) : (string, string) result Lwt.t =
  match insert_sql a with
  | Error e -> Lwt_result.lift (Error e)
  | Ok sql ->
      let* outcome = Conn.query_strings conn sql in
      match outcome with
      | Error e -> Lwt_result.lift (Error e)
      | Ok [] -> Lwt_result.lift (Error "задача создана, но её id не прочитан")
      | Ok (id :: _) -> Lwt_result.lift (Ok id)

(** Создание задачи.

    Повтор с той же парой (source, source_ref) возвращает ту же задачу: импорт
    из внешних систем не должен плодить дубли (§8 архитектуры). *)
let create conn (a : create_args) : (created, string) result Lwt.t =
  let find_existing () =
    match (a.source, a.source_ref) with
    | Some source, Some source_ref -> by_source_ref conn ~source ~source_ref
    | _ -> Lwt_result.lift (Ok None)
  in
  let* existing = find_existing () in
  match existing with
  | Error e -> Lwt_result.lift (Error e)
  | Ok (Some task) -> Lwt_result.lift (Ok (Existing task))
  | Ok None -> (
      let* inserted = insert conn a in
      match inserted with
      | Error e -> Lwt_result.lift (Error e)
      | Ok id ->
          let* found = by_id conn id in
          match found with
          | Error e -> Lwt_result.lift (Error e)
          | Ok (Some task) -> Lwt_result.lift (Ok (Created task))
          | Ok None -> Lwt_result.lift (Error "задача создана, но не прочитана"))

(** Смена статуса и исполнителя одной записью: [version] — оптимистичная
    блокировка (§3.3 архитектуры). Пустой результат означает «строка не
    обновлена»: либо задачи нет, либо версия устарела.

    [assignee] — «опция внутри опции»: [None] — исполнителя не трогать,
    [Some None] — снять, [Some (Some id)] — назначить. Заявка и отпуск меняют
    исполнителя вместе со статусом: двумя записями между ними задача была бы
    в работе без исполнителя. *)
let set_status_and_assignee conn ~ref_ ~status ~assignee ~version ~note :
    (string option, string) result Lwt.t =
  let started =
    match status with
    | Status.In_progress -> "COALESCE(started_at, now())"
    | _ -> "started_at"
  in
  let completed =
    match status with
    | Status.Done -> "now()"
    | _ -> "completed_at"
  in
  let blocked =
    match status with
    | Status.Blocked -> ( match note with
        | None -> "blocked_reason"
        | Some reason -> Conn.quote reason)
    | _ -> "NULL"
  in
  let assignee_fragment =
    match assignee with
    | None -> Ok ""
    | Some None -> Ok ", assignee_id = NULL"
    | Some (Some id) -> (
        match uuid_sql (Some id) with
        | Error e -> Error e
        | Ok literal -> Ok (", assignee_id = " ^ literal))
  in
  match assignee_fragment with
  | Error e -> Lwt_result.lift (Error e)
  | Ok fragment ->
      let sql =
        Printf.sprintf
          "UPDATE task SET status = %s::task_status, version = version + 1, \
           updated_at = now(), started_at = %s, completed_at = %s, blocked_reason = %s%s \
           WHERE ref = %s AND version = %d AND deleted_at IS NULL RETURNING id::text"
          (Conn.quote (Status.to_string status))
          started
          completed
          blocked
          fragment
          (Conn.quote ref_)
          version
      in
      Conn.query_strings conn sql
      |> Lwt_result.map (function [] -> None | id :: _ -> Some id)

(** Смена статуса без изменения исполнителя. *)
let set_status conn ~ref_ ~status ~version ~note =
  set_status_and_assignee conn ~ref_ ~status ~assignee:None ~version ~note

(** Назначение исполнителя. *)
let set_assignee conn ~ref_ ~assignee_id ~version :
    (string option, string) result Lwt.t =
  match uuid_sql assignee_id with
  | Error e -> Lwt_result.lift (Error e)
  | Ok assignee ->
      let sql =
        Printf.sprintf
          "UPDATE task SET assignee_id = %s, version = version + 1, updated_at = now() \
           WHERE ref = %s AND version = %d AND deleted_at IS NULL RETURNING id::text"
          assignee
          (Conn.quote ref_)
          version
      in
      Conn.query_strings conn sql
      |> Lwt_result.map (function [] -> None | id :: _ -> Some id)

(** Дети задачи: ветка дерева ниже [parent_id]. *)
let children conn ~parent_id : (Task.t list, string) result Lwt.t =
  match Conn.uuid_literal parent_id with
  | None -> Lwt_result.lift (Ok [])
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf
           "%s WHERE t.parent_id = %s AND t.deleted_at IS NULL ORDER BY t.ref) x"
           task_select literal)
      |> Lwt_result.map (List.map of_json)

(** Сколько детей задачи ещё открыто.

    Открыта задача, которая не в [done] и не в [cancelled]: пока живы её
    дети, родителя закрывать рано (D7). *)
let open_children_count conn ~parent_id : (int, string) result Lwt.t =
  match Conn.uuid_literal parent_id with
  | None -> Lwt_result.lift (Ok 0)
  | Some literal ->
      Conn.query_int64s conn
        (Printf.sprintf
           "SELECT count(*) FROM task WHERE parent_id = %s AND deleted_at IS NULL \
            AND status NOT IN ('done','cancelled')"
           literal)
      |> Lwt_result.map (fun counts ->
          match counts with [] -> 0 | count :: _ -> Int64.to_int count)

(** Родитель задачи — на один уровень вверх. Нужен для проверки цикла:
    цепочка родителей поднимается от предполагаемого родителя вверх. *)
let parent_id_of conn id : (string option, string) result Lwt.t =
  match Conn.uuid_literal id with
  | None -> Lwt_result.lift (Ok None)
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf
           "SELECT row_to_json(x)::text FROM (SELECT parent_id::text AS parent_id FROM task \
            WHERE id = %s AND deleted_at IS NULL) x"
           literal)
      |> Lwt_result.map (function
          | [] -> None
          | json :: _ -> Row.opt_string json "parent_id")

(** Смена родителя. [parent_id = None] — отвязать задачу от родителя. *)
let set_parent conn ~ref_ ~parent_id ~version :
    (string option, string) result Lwt.t =
  let parent_fragment =
    match parent_id with
    | None -> Ok "NULL"
    | Some id -> uuid_sql (Some id)
  in
  match parent_fragment with
  | Error e -> Lwt_result.lift (Error e)
  | Ok literal ->
      let sql =
        Printf.sprintf
          "UPDATE task SET parent_id = %s, version = version + 1, updated_at = now() \
           WHERE ref = %s AND version = %d AND deleted_at IS NULL RETURNING id::text"
          literal
          (Conn.quote ref_)
          version
      in
      Conn.query_strings conn sql
      |> Lwt_result.map (function [] -> None | id :: _ -> Some id)

type patch = {
  title : string option;
  description : string option;
  priority : Task.priority option;
  (** [None] — срок не трогать, [Some None] — срок снять. *)
  due_at : (string option) option;
  labels : string list option;
}

let update conn ~ref_ ~version (p : patch) : (string option, string) result Lwt.t =
  let sets = ref [ "version = version + 1" ] in
  let add c = sets := c :: !sets in
  (match p.title with
  | Some t -> add (Printf.sprintf "title = %s" (Conn.quote t))
  | None -> ());
  (match p.description with
  | Some d -> add (Printf.sprintf "description = %s" (Conn.quote d))
  | None -> ());
  (match p.priority with
  | Some pr ->
      add (Printf.sprintf "priority = %s::task_priority" (Conn.quote (Task.priority_to_string pr)))
  | None -> ());
  (match p.due_at with
  | Some (Some d) -> add (Printf.sprintf "due_at = %s" (Conn.quote d))
  | Some None -> add "due_at = NULL"
  | None -> ());
  (match p.labels with
  | Some l -> add (Printf.sprintf "labels = %s" (labels_sql l))
  | None -> ());
  let sql =
    Printf.sprintf
      "UPDATE task SET %s, updated_at = now() WHERE ref = %s AND version = %d \
       AND deleted_at IS NULL RETURNING id::text"
      (String.concat ", " (List.rev !sets))
      (Conn.quote ref_)
      version
  in
  Conn.query_strings conn sql
  |> Lwt_result.map (function [] -> None | id :: _ -> Some id)

(** Комментарии задачи — часть карточки: обсуждение ведётся внутри
    обязательства, а не в переписке Mattermost. *)
let comments conn ~task_id : (Comment.t list, string) result Lwt.t =
  match Conn.uuid_literal task_id with
  | None -> Lwt_result.lift (Ok [])
  | Some literal ->
      Conn.query_json_rows conn
        (Printf.sprintf
           "SELECT row_to_json(c)::text FROM comment c WHERE c.task_id = %s \
            ORDER BY c.created_at"
           literal)
      |> Lwt_result.map (List.map (fun json ->
             {
               Comment.id = Row.string_ json "id" ~default:"";
               task_id = Row.string_ json "task_id" ~default:"";
               parent_id = Row.opt_string json "parent_id";
               author_id = Row.opt_string json "author_id";
               body = Row.string_ json "body" ~default:"";
               created_at = Row.string_ json "created_at" ~default:"";
               edited_at = Row.opt_string json "edited_at";
             }))

let add_comment conn ~task_id ~body ~author_id ?parent_id () :
    (Comment.t, string) result Lwt.t =
  match uuid_sql author_id with
  | Error e -> Lwt_result.lift (Error e)
  | Ok author -> (
      match (match parent_id with None -> Ok "NULL" | Some id -> uuid_sql id) with
      | Error e -> Lwt_result.lift (Error e)
      | Ok parent ->
          let sql =
            Printf.sprintf
              "INSERT INTO comment (task_id, author_id, body, parent_id) \
               VALUES (%s, %s, %s, %s) RETURNING id::text"
              (match Conn.uuid_literal task_id with
              | Some literal -> literal
              | None -> "NULL")
              author
              (Conn.quote body)
              parent
          in
          let* outcome = Conn.query_strings conn sql in
          match outcome with
          | Error e -> Lwt_result.lift (Error e)
          | Ok [] -> Lwt_result.lift (Error "комментарий создан, но его id не прочитан")
          | Ok (id :: _) ->
              let* found =
                Conn.query_json_rows conn
                  (Printf.sprintf
                     "SELECT row_to_json(c)::text FROM comment c WHERE c.id = %s::uuid"
                     (Conn.quote id))
              in
              match found with
              | Error e -> Lwt_result.lift (Error e)
              | Ok (json :: _) ->
                  Lwt_result.lift
                    (Ok
                       {
                         Comment.id = Row.string_ json "id" ~default:"";
                         task_id = Row.string_ json "task_id" ~default:"";
                         parent_id = Row.opt_string json "parent_id";
                         author_id = Row.opt_string json "author_id";
                         body = Row.string_ json "body" ~default:"";
                         created_at = Row.string_ json "created_at" ~default:"";
                         edited_at = Row.opt_string json "edited_at";
                       })
              | Ok [] -> Lwt_result.lift (Error "комментарий создан, но не найден"))
