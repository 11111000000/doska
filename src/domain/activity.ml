(** Журнал активности — append-only след каждого изменения (P4).

    Журнал отвечает на вопрос «кто, что и откуда изменил», поэтому он пишется
    вместе с изменением, в той же транзакции. *)

type action =
  | Created
  | Status_changed
  | Assigned
  | Unassigned
  | Reassigned
  | Commented
  | Evidence_added
  | Due_changed
  | Priority_changed
  | Linked
  | Unlinked
  | Review_requested
  | Accepted
  | Rejected
  | Claimed
  | Released
  | Cancelled
  | Deleted
  | Restored
  | Updated

type t = {
  id : int64;
  task_id : string option;
  project_id : string option;
  actor_id : string option;
  action : action;
  from_value : string option;
  to_value : string option;
  summary : string option;
  (** Откуда пришло: REST, MCP, CLI, веб, чат, Paseo, импорт или система. *)
  interface_ : Interface.t;
  request_id : string option;
  created_at : string;
}

let action_to_string : action -> string = function
  | Created -> "created"
  | Status_changed -> "status_changed"
  | Assigned -> "assigned"
  | Unassigned -> "unassigned"
  | Reassigned -> "reassigned"
  | Commented -> "commented"
  | Evidence_added -> "evidence_added"
  | Due_changed -> "due_changed"
  | Priority_changed -> "priority_changed"
  | Linked -> "linked"
  | Unlinked -> "unlinked"
  | Review_requested -> "review_requested"
  | Accepted -> "accepted"
  | Rejected -> "rejected"
  | Claimed -> "claimed"
  | Released -> "released"
  | Cancelled -> "cancelled"
  | Deleted -> "deleted"
  | Restored -> "restored"
  | Updated -> "updated"

let action_of_string : string -> action option = function
  | "created" -> Some Created
  | "status_changed" -> Some Status_changed
  | "assigned" -> Some Assigned
  | "unassigned" -> Some Unassigned
  | "reassigned" -> Some Reassigned
  | "commented" -> Some Commented
  | "evidence_added" -> Some Evidence_added
  | "due_changed" -> Some Due_changed
  | "priority_changed" -> Some Priority_changed
  | "linked" -> Some Linked
  | "unlinked" -> Some Unlinked
  | "review_requested" -> Some Review_requested
  | "accepted" -> Some Accepted
  | "rejected" -> Some Rejected
  | "claimed" -> Some Claimed
  | "released" -> Some Released
  | "cancelled" -> Some Cancelled
  | "deleted" -> Some Deleted
  | "restored" -> Some Restored
  | "updated" -> Some Updated
  | _ -> None
