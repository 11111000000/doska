(** Представление домена в JSON: то, что видит клиент.

    Формат ответа — часть контракта, поэтому он собран в одном месте, а не
    по одному полю в каждом обработчике. *)

open Domain

let opt = function None -> `Null | Some s -> `String s

let task (t : Task.t) : Yojson.Safe.t =
  `Assoc
    [
      ("ref", `String t.Task.ref_);
      ("id", `String t.Task.id);
      ("title", `String t.Task.title);
      ("description", `String t.Task.description);
      ("status", `String (Status.to_string t.Task.status));
      ("kind", `String (Task.kind_to_string t.Task.kind));
      ("priority", `String (Task.priority_to_string t.Task.priority));
      ("project", opt t.Task.project_key);
      ("parent_id", opt t.Task.parent_id);
      ("assignee_id", opt t.Task.assignee_id);
      ("assignee", opt t.Task.assignee_name);
      ("requester_id", opt t.Task.requester_id);
      ("reporter_id", opt t.Task.reporter_id);
      ("due_at", opt t.Task.due_at);
      ("labels", `List (List.map (fun label -> `String label) t.Task.labels));
      ("source", opt t.Task.source);
      ("source_ref", opt t.Task.source_ref);
      ("blocked_reason", opt t.Task.blocked_reason);
      ("question", opt t.Task.question);
      ("asked_to_id", opt t.Task.asked_to_id);
      ("asked_to", opt t.Task.asked_to_name);
      ("answer", opt t.Task.answer);
      ("answered_at", opt t.Task.answered_at);
      ("version", `Int t.Task.version);
      ("created_at", `String t.Task.created_at);
      ("updated_at", `String t.Task.updated_at);
      ("started_at", opt t.Task.started_at);
      ("completed_at", opt t.Task.completed_at);
    ]

(** Задача или пусто: родителя может не быть. *)
let opt_task (t : Task.t option) : Yojson.Safe.t =
  match t with
  | None -> `Null
  | Some t -> task t

(** Связь между задачами: своя сущность со своим идентификатором. *)
let link (l : Db.Repo_link.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String l.Db.Repo_link.id);
      ("from_id", `String l.Db.Repo_link.from_id);
      ("to_id", `String l.Db.Repo_link.to_id);
      ("kind", `String (Link.to_string l.Db.Repo_link.kind));
      ("created_by_id", opt l.Db.Repo_link.created_by_id);
      ("created_at", `String l.Db.Repo_link.created_at);
    ]

let comment (c : Comment.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String c.Comment.id);
      ("author_id", opt c.Comment.author_id);
      ("parent_id", opt c.Comment.parent_id);
      ("body", `String c.Comment.body);
      ("created_at", `String c.Comment.created_at);
      ("edited_at", opt c.Comment.edited_at);
    ]

let evidence (e : Evidence.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String e.Evidence.id);
      ("kind", `String (Evidence.kind_to_string e.Evidence.kind));
      ("ref", `String e.Evidence.ref_);
      ("uri", opt e.Evidence.uri);
      ("title", opt e.Evidence.title);
      ("note", opt e.Evidence.note);
      ("author_id", opt e.Evidence.author_id);
      ("created_at", `String e.Evidence.created_at);
    ]

let actor (a : Actor.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String a.Actor.id);
      ("kind", `String (Actor.kind_to_string a.Actor.kind));
      ("handle", `String a.Actor.handle);
      ("display_name", `String a.Actor.display_name);
      ("supervisor_id", opt a.Actor.supervisor_id);
      ("unresolved", `Bool a.Actor.unresolved);
    ]

let project (p : Project.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String p.Project.id);
      ("key", `String p.Project.key);
      ("name", `String p.Project.name);
      ("autonomy", `String (Actor.autonomy_to_string p.Project.autonomy));
      ("status", `String (Project.status_to_string p.Project.status));
    ]

let activity (a : Activity.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `Int (Int64.to_int a.Activity.id));
      ("task_id", opt a.Activity.task_id);
      ("project_id", opt a.Activity.project_id);
      ("actor_id", opt a.Activity.actor_id);
      ("action", `String (Activity.action_to_string a.Activity.action));
      ("from_value", opt a.Activity.from_value);
      ("to_value", opt a.Activity.to_value);
      ("summary", opt a.Activity.summary);
      ("interface", `String (Interface.to_string a.Activity.interface_));
      ("created_at", `String a.Activity.created_at);
    ]
