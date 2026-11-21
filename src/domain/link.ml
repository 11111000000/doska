(** Связь между задачами.

    Родитель ([Task.parent_id]) задаёт дерево и влияет на приёмку: родителя
    нельзя закрыть, пока открыты дети. Связь — другое отношение: она
    ничего не блокирует сама по себе, а лишь говорит читателю, как задачи
    соотносятся ([blocks] — «мешает», [relates_to] — «просто рядом»).

    Связи образуют граф, поэтому циклы в них возможны — значит, их надо
    проверять, а не полагаться на добрые намерения. *)

type kind =
  | Blocks
  | Blocked_by
  | Relates_to
  | Duplicates
  | Implements
  | Split_from
  | Follows_up

let to_string : kind -> string = function
  | Blocks -> "blocks"
  | Blocked_by -> "blocked_by"
  | Relates_to -> "relates_to"
  | Duplicates -> "duplicates"
  | Implements -> "implements"
  | Split_from -> "split_from"
  | Follows_up -> "follows_up"

let of_string : string -> kind option = function
  | "blocks" -> Some Blocks
  | "blocked_by" -> Some Blocked_by
  | "relates_to" -> Some Relates_to
  | "duplicates" -> Some Duplicates
  | "implements" -> Some Implements
  | "split_from" -> Some Split_from
  | "follows_up" -> Some Follows_up
  | _ -> None

(** Направление блокировки: кто мешает кому.

    [blocks] — «from мешает to», [blocked_by] — «to мешает from»: это одно и
    то же отношение, записанное с двух сторон. Остальные виды ничего не
    блокируют, поэтому ребра в графе блокировок не строят. *)
let blocking_edge (kind : kind) ~(from_id : string) ~(to_id : string) :
    (string * string) option =
  match kind with
  | Blocks -> Some (from_id, to_id)
  | Blocked_by -> Some (to_id, from_id)
  | Relates_to | Duplicates | Implements | Split_from | Follows_up -> None

type t = {
  id : string;
  from_id : string;
  to_id : string;
  kind : kind;
  created_by_id : string option;
  created_at : string;
}
