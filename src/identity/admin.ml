(** Право администратора.

    Список логинов администраторов приходит из окружения
    ([DOSKA_ADMIN_HANDLES]): это конфигурация развёртывания, а не данные
    проекта.

    Правило живёт здесь, а не в HTTP-слое: право спрашивает сервисный слой,
    когда решает, может ли агент закрыть задачу сам. *)

let admin_handles () : string list =
  match Sys.getenv_opt "DOSKA_ADMIN_HANDLES" with
  | None -> []
  | Some raw ->
      String.split_on_char ',' raw
      |> List.map String.trim
      |> List.filter (fun handle -> handle <> "")

let is_admin (actor : Domain.Actor.t) : bool =
  List.mem actor.Domain.Actor.handle (admin_handles ())
