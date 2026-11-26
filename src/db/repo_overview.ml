(** Сводка по трекеру: что открыто, кто завален, что застряло.

    Считает база: сводка — это запрос, а не перебор задач в памяти. Репозиторий
    отдаёт готовые числа и списки, сервис собирает из них ответ, адаптер
    рендерит. *)

open Domain

(** Открытая задача — не закрытая и не удалённая.

    Открытость определяется статусом, а не [completed_at]: при переоткрытии
    задачи [completed_at] остаётся от прошлого закрытия, и по нему задача
    выглядела бы закрытой. *)
let open_condition = "t.deleted_at IS NULL AND t.status NOT IN ('done','cancelled')"

(** Застрявшей считается задача, которую взяли в работу, но с тех пор не
    трогали. [needs_input] сюда не входит: там ждут ответа человека, и это
    ожидание, а не застой (R2, ADR §4.2). *)
let stuck_statuses = "'in_progress','blocked','in_review'"

(** Возраст в целых сутках с последнего касания задачи. *)
let age_expr = "FLOOR(EXTRACT(EPOCH FROM (now() - t.updated_at)) / 86400)::int"

type totals = {
  open_tasks : int;
  in_progress : int;
  blocked : int;
  needs_input : int;
  unassigned : int;
  without_project : int;
}

(** Нагрузка на человека: сколько открытых задач у него на руках. *)
type wip = {
  actor_id : string;
  handle : string;
  display_name : string;
  kind : Actor.kind;
  open_tasks : int;
  in_progress : int;
  needs_input : int;
}

(** Нагрузка на проект: сколько открытых задач и сколько из них застряли. *)
type load = {
  project_id : string;
  key : string;
  name : string;
  open_tasks : int;
  stuck : int;
}

(** Задача с её возрастом: сколько суток она лежит без движения. *)
type aged = {
  task : Task.t;
  age_days : int;
}

let totals_of_json (json : Yojson.Safe.t) : totals =
  {
    open_tasks = Row.int_ json "open_tasks" ~default:0;
    in_progress = Row.int_ json "in_progress" ~default:0;
    blocked = Row.int_ json "blocked" ~default:0;
    needs_input = Row.int_ json "needs_input" ~default:0;
    unassigned = Row.int_ json "unassigned" ~default:0;
    without_project = Row.int_ json "without_project" ~default:0;
  }

let wip_of_json (json : Yojson.Safe.t) : wip =
  let kind =
    match Row.opt_string json "kind" with
    | Some s -> ( match Actor.kind_of_string s with Some kind -> kind | None -> Actor.Human)
    | None -> Actor.Human
  in
  {
    actor_id = Row.string_ json "actor_id" ~default:"";
    handle = Row.string_ json "handle" ~default:"";
    display_name = Row.string_ json "display_name" ~default:"";
    kind;
    open_tasks = Row.int_ json "open_tasks" ~default:0;
    in_progress = Row.int_ json "in_progress" ~default:0;
    needs_input = Row.int_ json "needs_input" ~default:0;
  }

let load_of_json (json : Yojson.Safe.t) : load =
  {
    project_id = Row.string_ json "project_id" ~default:"";
    key = Row.string_ json "key" ~default:"";
    name = Row.string_ json "name" ~default:"";
    open_tasks = Row.int_ json "open_tasks" ~default:0;
    stuck = Row.int_ json "stuck" ~default:0;
  }

let aged_of_json (json : Yojson.Safe.t) : aged =
  {
    task = Repo_task.of_json json;
    age_days = Row.int_ json "age_days" ~default:0;
  }

(** Момент, на который посчитана сводка.

    Внутри транзакции [now()] один и тот же, поэтому все числа отвечают на
    один и тот же вопрос «а когда?». *)
let generated_at conn : (string, string) result Lwt.t =
  Conn.query_strings conn "SELECT now()::text"
  |> Lwt_result.map (function [] -> "" | moment :: _ -> moment)

let totals conn : (totals, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf
       "SELECT row_to_json(x)::text FROM (SELECT count(*)::int AS open_tasks, \
        (count(*) FILTER (WHERE t.status = 'in_progress'))::int AS in_progress, \
        (count(*) FILTER (WHERE t.status = 'blocked'))::int AS blocked, \
        (count(*) FILTER (WHERE t.status = 'needs_input'))::int AS needs_input, \
        (count(*) FILTER (WHERE t.assignee_id IS NULL))::int AS unassigned, \
        (count(*) FILTER (WHERE t.project_id IS NULL))::int AS without_project \
        FROM task t WHERE %s) x"
       open_condition)
  |> Lwt_result.map (function
       | [] -> totals_of_json (`Assoc [])
       | json :: _ -> totals_of_json json)

(** Нагрузка по людям: сначала те, у кого больше задач, при равенстве — по
    логину, чтобы порядок был устойчивым. *)
let wip conn : (wip list, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf
       "SELECT row_to_json(x)::text FROM (SELECT a.id AS actor_id, a.handle AS handle, \
        a.display_name AS display_name, a.kind AS kind, \
        count(*)::int AS open_tasks, \
        (count(*) FILTER (WHERE t.status = 'in_progress'))::int AS in_progress, \
        (count(*) FILTER (WHERE t.status = 'needs_input'))::int AS needs_input \
        FROM task t JOIN actor a ON a.id = t.assignee_id WHERE %s \
        GROUP BY a.id, a.handle, a.display_name, a.kind \
        ORDER BY count(*) DESC, a.handle) x"
       open_condition)
  |> Lwt_result.map (List.map wip_of_json)

(** Нагрузка по проектам: только проекты, где есть открытые задачи. Пустой
    проект в сводке — шум. *)
let by_project conn ~stuck_days : (load list, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf
       "SELECT row_to_json(x)::text FROM (SELECT p.id AS project_id, p.key AS key, \
        p.name AS name, count(t.id)::int AS open_tasks, \
        (count(t.id) FILTER (WHERE t.status IN (%s) AND t.updated_at < now() - \
        make_interval(days => %d)))::int AS stuck \
        FROM project p LEFT JOIN task t ON t.project_id = p.id AND %s \
        GROUP BY p.id, p.key, p.name \
        HAVING count(t.id) > 0 \
        ORDER BY count(t.id) DESC, p.key) x"
       stuck_statuses stuck_days open_condition)
  |> Lwt_result.map (List.map load_of_json)

(** Застрявшие задачи: дольше всех пролежавшие — первыми. *)
let stuck conn ~stuck_days ~limit : (aged list, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf
       "SELECT row_to_json(x)::text FROM (SELECT t.*, p.key AS project_key, \
        a.display_name AS assignee_name, %s AS age_days \
        FROM task t LEFT JOIN project p ON p.id = t.project_id \
        LEFT JOIN actor a ON a.id = t.assignee_id \
        WHERE %s AND t.status IN (%s) \
        AND t.updated_at < now() - make_interval(days => %d) \
        ORDER BY t.updated_at ASC LIMIT %d) x"
       age_expr open_condition stuck_statuses stuck_days limit)
  |> Lwt_result.map (List.map aged_of_json)

(** Задачи, ждущие ответа человека: их никто не двинет, пока не ответят. *)
let needs_input conn ~limit : (aged list, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf
       "SELECT row_to_json(x)::text FROM (SELECT t.*, p.key AS project_key, \
        a.display_name AS assignee_name, %s AS age_days \
        FROM task t LEFT JOIN project p ON p.id = t.project_id \
        LEFT JOIN actor a ON a.id = t.assignee_id \
        WHERE %s AND t.status = 'needs_input' \
        ORDER BY t.updated_at ASC LIMIT %d) x"
       age_expr open_condition limit)
  |> Lwt_result.map (List.map aged_of_json)
