(** Статусы задачи.

    Варианты, а не строки: компилятор заставляет обновить все места, где
    статус разбирается, если добавить новый. *)

type t =
  | Backlog
  | Todo
  | In_progress
  | Blocked
  | Needs_input
  | In_review
  | Done
  | Cancelled

let to_string : t -> string = function
  | Backlog -> "backlog"
  | Todo -> "todo"
  | In_progress -> "in_progress"
  | Blocked -> "blocked"
  | Needs_input -> "needs_input"
  | In_review -> "in_review"
  | Done -> "done"
  | Cancelled -> "cancelled"

let of_string (s : string) : t option =
  match String.lowercase_ascii (String.trim s) with
  | "backlog" -> Some Backlog
  | "todo" -> Some Todo
  | "in_progress" -> Some In_progress
  | "blocked" -> Some Blocked
  | "needs_input" -> Some Needs_input
  | "in_review" -> Some In_review
  | "done" -> Some Done
  | "cancelled" -> Some Cancelled
  | _ -> None

let all =
  [ Backlog; Todo; In_progress; Blocked; Needs_input; In_review; Done; Cancelled ]

(** Задача ещё не закрыта — такие задачи попадают в «мои задачи» и в отчёты. *)
let is_open : t -> bool = function Done | Cancelled -> false | _ -> true

let is_terminal : t -> bool = function Done | Cancelled -> true | _ -> false

(** Статусы, в которых задача ждёт человека: [needs_input] — явное «жду ответа». *)
let waits_for_human : t -> bool = function Needs_input -> true | _ -> false

let pp fmt t = Format.pp_print_string fmt (to_string t)
