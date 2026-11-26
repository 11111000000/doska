(** Кто выполняет запрос.

    На этапе 1 идентификации ещё нет: токены и учётные записи — этап 2.
    Временный способ сказать «кто я» — заголовок [X-Doska-Actor] с логином
    актора. Это **не** аутентификация: заголовок подделывается тривиально,
    и сервер до этапа 2 должен слушать только доверенную сеть.

    Право администратора задаётся переменной окружения
    [DOSKA_ADMIN_HANDLES] и живёт в [Identity.Admin]: сервисный слой решает
    по нему, может ли агент закрыть задачу сам. *)

open Domain

let ( let* ) t f = Lwt.bind t f

let header = "x-doska-actor"

(** Актор запроса по заголовку. *)
let actor_of conn req : (Actor.t, Errors.t) result Lwt.t =
  match Dream.headers req header with
  | [] ->
      Lwt_result.lift
        (Error
           (Errors.make Errors.Unauthorized
              "не указан актор: пришлите заголовок X-Doska-Actor (временный механизм \
               до этапа 2 — bearer-токены)"))
  | handle :: _ ->
      let* found = Db.Repo_actor.by_handle conn handle in
      (match found with
      | Error e -> Lwt_result.lift (Error (Errors.make Errors.Internal e))
      | Ok (Some actor) -> Lwt_result.lift (Ok actor)
      | Ok None ->
          Lwt_result.lift
            (Error (Errors.make Errors.Unauthorized ("актор не найден: " ^ handle))))
