(** Проект — рамка обязательств.

    Политика приёмки живёт здесь: [autonomy] решает, может ли агент закрыть
    свою задачу сам (D1, §4.2 архитектуры). *)

type status =
  | Active
  | Paused
  | Archived

type t = {
  id : string;
  (** Канонический ключ проекта: [doska], [angarachat]. *)
  key : string;
  name : string;
  (** Режим приёмки: [Human_gate] — закрывает человек, [Auto] — доверенный
      агент закрывает сам. *)
  autonomy : Actor.autonomy;
  status : status;
}

let status_to_string : status -> string = function
  | Active -> "active"
  | Paused -> "paused"
  | Archived -> "archived"

let status_of_string : string -> status option = function
  | "active" -> Some Active
  | "paused" -> Some Paused
  | "archived" -> Some Archived
  | _ -> None
