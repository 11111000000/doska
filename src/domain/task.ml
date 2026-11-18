(** Задача — обязательство, а не единица кода.

    Ветка, PR и коммит — это доказательства ([evidence]) внутри задачи,
    а не отдельные задачи. *)

type kind =
  | Task
  | Bug
  | Feature
  | Chore
  | Decision
  | Research
  | Question
  | Spike
  | Risk

type priority =
  | P0
  | P1
  | P2
  | P3

type t = {
  id : string;
  (** Человекочитаемый номер: [DSK-142]. Не переиспользуется. *)
  ref_ : string;
  project_id : string option;
  (** Ключ проекта — денормализовано: человек читает «doska», а не uuid. *)
  project_key : string option;
  parent_id : string option;
  kind : kind;
  status : Status.t;
  priority : priority;
  title : string;
  description : string;
  assignee_id : string option;
  assignee_name : string option;
  (** Заявитель: тот, кому важен результат. Он же принимает приёмку. *)
  requester_id : string option;
  reporter_id : string option;
  created_by_id : string option;
  due_at : string option;
  blocked_reason : string option;
  labels : string list;
  (** Происхождение: [mattermost | teamboard | pm-global | api | agent]. *)
  source : string option;
  (** Обратная ссылка: post_id, json-путь. По паре (source, source_ref)
      импорт не плодит дубли. *)
  source_ref : string option;
  version : int;
  created_at : string;
  updated_at : string;
  started_at : string option;
  completed_at : string option;
}

let kind_to_string : kind -> string = function
  | Task -> "task"
  | Bug -> "bug"
  | Feature -> "feature"
  | Chore -> "chore"
  | Decision -> "decision"
  | Research -> "research"
  | Question -> "question"
  | Spike -> "spike"
  | Risk -> "risk"

let kind_of_string : string -> kind option = function
  | "task" -> Some Task
  | "bug" -> Some Bug
  | "feature" -> Some Feature
  | "chore" -> Some Chore
  | "decision" -> Some Decision
  | "research" -> Some Research
  | "question" -> Some Question
  | "spike" -> Some Spike
  | "risk" -> Some Risk
  | _ -> None

let priority_to_string : priority -> string = function
  | P0 -> "p0"
  | P1 -> "p1"
  | P2 -> "p2"
  | P3 -> "p3"

let priority_of_string : string -> priority option = function
  | "p0" -> Some P0
  | "p1" -> Some P1
  | "p2" -> Some P2
  | "p3" -> Some P3
  | _ -> None

let priority_rank : priority -> int = function
  | P0 -> 0
  | P1 -> 1
  | P2 -> 2
  | P3 -> 3
