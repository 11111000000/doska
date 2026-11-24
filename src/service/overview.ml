(** Сводка по трекеру: что открыто, кто завален, что застряло (ADR §6.1).

    Сводка — чтение, а не действие: правил доступа здесь нет, есть отбор.
    Use case отдаёт данные, адаптер превращает их в JSON — так же, как
    [Service.Task.list] отдаёт страницу задач.

    Все числа считаются в одной транзакции: [now()] внутри транзакции один и
    тот же, поэтому сводка отвечает на один вопрос «а когда?», а не на
    полдюжины разных. *)

let ( let* ) t f = Lwt.bind t f

(** Связка промисов, в значении которых лежит результат: [Ok] продолжает
    цепочку, [Error] останавливает её. *)
let ( let*! ) (r : ('a, string) result Lwt.t) (f : 'a -> ('b, string) result Lwt.t) :
    ('b, string) result Lwt.t =
  Lwt.bind r (fun v ->
      match v with
      | Ok x -> f x
      | Error e -> Lwt_result.lift (Error e))

(* --------------------------------------------------------------- параметры --- *)

(** Порог застоя в сутках: неделя молчания — разумное умолчание. *)
let default_stuck_days = 7

(** Сколько задач показывать в списках. *)
let default_limit = 20

let max_limit = 200

(* ------------------------------------------------------------------- отказ --- *)

let bad_request message = Failure.Bad_request { message }

let storage message = Failure.Storage { message }

(** Порог застоя меньше суток означал бы «застряло всё, что начато», а это не
    застой, а шум. *)
let check_stuck_days n =
  if n < 1 then
    Error (bad_request "stuck_days должен быть не меньше 1: порог застоя в сутках")
  else Ok n

let check_limit n =
  if n < 1 then Error (bad_request "limit должен быть не меньше 1")
  else if n > max_limit then
    Error (bad_request (Printf.sprintf "limit не может быть больше %d" max_limit))
  else Ok n

(* ------------------------------------------------------------------- сводка --- *)

type t = {
  (* Момент, на который посчитано. *)
  generated_at : string;
  (* Порог застоя, применённый к ответам. *)
  stuck_days : int;
  (* Ограничение длины списков. *)
  limit : int;
  totals : Db.Repo_overview.totals;
  wip_by_actor : Db.Repo_overview.wip list;
  by_project : Db.Repo_overview.load list;
  stuck : Db.Repo_overview.aged list;
  needs_input : Db.Repo_overview.aged list;
}

let get conn ?stuck_days ?limit () : (t, Failure.t) result Lwt.t =
  let stuck_days = match stuck_days with Some n -> n | None -> default_stuck_days in
  let limit = match limit with Some n -> n | None -> default_limit in
  match (check_stuck_days stuck_days, check_limit limit) with
  | Error e, _ -> Lwt_result.lift (Error e)
  | _, Error e -> Lwt_result.lift (Error e)
  | Ok stuck_days, Ok limit ->
      let* outcome =
        Db.Conn.with_transaction conn (fun () ->
            let*! generated_at = Db.Repo_overview.generated_at conn in
            let*! totals = Db.Repo_overview.totals conn in
            let*! wip = Db.Repo_overview.wip conn in
            let*! by_project = Db.Repo_overview.by_project conn ~stuck_days in
            let*! stuck = Db.Repo_overview.stuck conn ~stuck_days ~limit in
            let*! needs_input = Db.Repo_overview.needs_input conn ~limit in
            Lwt_result.lift
              (Ok (generated_at, totals, wip, by_project, stuck, needs_input)))
      in
      (match outcome with
      | Error e -> Lwt_result.lift (Error (storage e))
      | Ok (generated_at, totals, wip, by_project, stuck, needs_input) ->
          Lwt_result.lift
            (Ok
               {
                 generated_at;
                 stuck_days;
                 limit;
                 totals;
                 wip_by_actor = wip;
                 by_project;
                 stuck;
                 needs_input;
               }))
