(** Сводка по трекеру: [GET /api/v1/overview] (§6.1).

    Адаптер: разбирает параметры, зовёт сервис и переводит отказ в код
    ответа. Правил здесь нет — они в [Service.Overview]; форма ответа — здесь,
    потому что это часть контракта HTTP. *)

let ( let* ) t f = Lwt.bind t f

let ok payload = Dream.json (Yojson.Safe.to_string payload)

(** Ответ-промис: [Dream.json] уже возвращает промис, оборачивать его в
    [Lwt.return] нельзя — получится промис в промисе. *)
let send (p : 'a Lwt.t) : 'a Lwt.t = Lwt.bind p (fun x -> Lwt.return x)

let fail (failure : Service.Failure.t) : Dream.response Lwt.t =
  Errors.respond (Errors.of_failure failure)

let answer (r : ('a, Service.Failure.t) result Lwt.t)
    (build : 'a -> Dream.response Lwt.t) : Dream.response Lwt.t =
  Lwt.bind r (fun result ->
      match result with
      | Error failure -> fail failure
      | Ok value -> send (build value))

let bad_request message = fail (Service.Failure.Bad_request { message })

(* --------------------------------------------------------------- параметры --- *)

(** Параметр сводки: число или его отсутствие.

    Неразобранное значение — ошибка запроса, а не молчаливая замена: клиент
    должен узнать, что его параметр не поняли, иначе он прочитает чужой
    ответ как свой. *)
let int_param req name =
  match Dream.query req name with
  | None -> Ok None
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some n -> Ok (Some n)
      | None -> Error ("неизвестное значение параметра " ^ name ^ ": " ^ raw))

(* ------------------------------------------------------------------- ответ --- *)

let totals_json (totals : Db.Repo_overview.totals) : Yojson.Safe.t =
  `Assoc
    [
      ("open_tasks", `Int totals.Db.Repo_overview.open_tasks);
      ("in_progress", `Int totals.Db.Repo_overview.in_progress);
      ("blocked", `Int totals.Db.Repo_overview.blocked);
      ("needs_input", `Int totals.Db.Repo_overview.needs_input);
      ("unassigned", `Int totals.Db.Repo_overview.unassigned);
      ("without_project", `Int totals.Db.Repo_overview.without_project);
    ]

let wip_json (w : Db.Repo_overview.wip) : Yojson.Safe.t =
  `Assoc
    [
      ("actor_id", `String w.Db.Repo_overview.actor_id);
      ("handle", `String w.Db.Repo_overview.handle);
      ("display_name", `String w.Db.Repo_overview.display_name);
      ("kind", `String (Domain.Actor.kind_to_string w.Db.Repo_overview.kind));
      ("open_tasks", `Int w.Db.Repo_overview.open_tasks);
      ("in_progress", `Int w.Db.Repo_overview.in_progress);
      ("needs_input", `Int w.Db.Repo_overview.needs_input);
    ]

let load_json (l : Db.Repo_overview.load) : Yojson.Safe.t =
  `Assoc
    [
      ("project_id", `String l.Db.Repo_overview.project_id);
      ("key", `String l.Db.Repo_overview.key);
      ("name", `String l.Db.Repo_overview.name);
      ("open_tasks", `Int l.Db.Repo_overview.open_tasks);
      ("stuck", `Int l.Db.Repo_overview.stuck);
    ]

(** Задача с возрастом: сама задача — в общем виде [View.task], возраст —
    сколько суток она лежит без движения. *)
let aged_json (a : Db.Repo_overview.aged) : Yojson.Safe.t =
  `Assoc
    [
      ("task", View.task a.Db.Repo_overview.task);
      ("age_days", `Int a.Db.Repo_overview.age_days);
    ]

let body (s : Service.Overview.t) : Yojson.Safe.t =
  `Assoc
    [
      ("generated_at", `String s.Service.Overview.generated_at);
      ("stuck_days", `Int s.Service.Overview.stuck_days);
      ("limit", `Int s.Service.Overview.limit);
      ("totals", totals_json s.Service.Overview.totals);
      ("wip_by_actor", `List (List.map wip_json s.Service.Overview.wip_by_actor));
      ("by_project", `List (List.map load_json s.Service.Overview.by_project));
      ("stuck", `List (List.map aged_json s.Service.Overview.stuck));
      ("needs_input", `List (List.map aged_json s.Service.Overview.needs_input));
    ]

let overview req =
  match (int_param req "stuck_days", int_param req "limit") with
  | Error message, _ -> bad_request message
  | _, Error message -> bad_request message
  | Ok stuck_days, Ok limit ->
      Context.with_actor req (fun conn _actor ->
          answer
            (Service.Overview.get conn ?stuck_days ?limit ())
            (fun (s : Service.Overview.t) -> ok (body s)))
