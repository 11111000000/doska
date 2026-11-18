(** Акторы: люди, агенты, сервисы и неразрешённые имена.

    Одна сущность вместо раздельных «пользователей» и «учёток агентов»:
    различаются только [kind] и [supervisor_id] — кому агент отвечает. *)

type kind =
  | Human
  | Agent
  | Service
  | Placeholder

type autonomy =
  | Human_gate
  | Auto

type t = {
  id : string;
  kind : kind;
  (** Нормализованный логин: см. [Identity.Resolve.normalize]. *)
  handle : string;
  display_name : string;
  (** Руководитель агента. Для людей — [None]. *)
  supervisor_id : string option;
  (** [true] — имя не удалось разрешить, запись создана как заглушка. *)
  unresolved : bool;
}

let kind_to_string : kind -> string = function
  | Human -> "human"
  | Agent -> "agent"
  | Service -> "service"
  | Placeholder -> "placeholder"

let kind_of_string : string -> kind option = function
  | "human" -> Some Human
  | "agent" -> Some Agent
  | "service" -> Some Service
  | "placeholder" -> Some Placeholder
  | _ -> None

let autonomy_to_string : autonomy -> string = function
  | Human_gate -> "human_gate"
  | Auto -> "auto"

let autonomy_of_string : string -> autonomy option = function
  | "human_gate" -> Some Human_gate
  | "auto" -> Some Auto
  | _ -> None

let is_human a = a.kind = Human
let is_agent a = a.kind = Agent || a.kind = Service

let make ~id ~kind ~handle ~display_name ?supervisor_id () : t =
  {
    id;
    kind;
    handle;
    display_name;
    supervisor_id;
    unresolved = false;
  }

let placeholder ~id ~handle ~display_name : t =
  { id; kind = Placeholder; handle; display_name; supervisor_id = None; unresolved = true }
