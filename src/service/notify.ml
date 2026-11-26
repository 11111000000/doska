(** Доставка outbox-уведомлений в Mattermost (§3.8).

    Отправитель внедряется: сервис знает КОМУ и ЧТО, но не умеет ходить
    в сеть — сетевую часть привязывает вызывающий слой. Так тест проверяет
    доставку на заглушке, а живой прогон получает настоящего отправителя,
    не меняя ни строчки в сервисе.

    Актор уведомления должен быть из Mattermost: у него есть source_ref —
    идентификатор пользователя MM, по которому строится личный канал.
    Учётка из другого источника не доставляется и помечается failed
    с причиной. *)

let ( let* ) t f = Lwt.bind t f

type send = mm_user_id:string -> text:string -> (unit, string) result Lwt.t

(** Текст уведомления по виду: человек читает его в чате без контекста. *)
let text_of kind payload =
  let field name =
    match Yojson.Safe.Util.(member name payload) with
    | `String s -> s
    | _ -> ""
  in
  let title = field "title" in
  let question = field "question" in
  match kind with
  | "needs_input" when question <> "" -> "Задача ждёт вашего ответа: " ^ question
  | "needs_input" when title <> "" -> "Задача ждёт вашего ответа: " ^ title
  | _ when title <> "" -> "Уведомление по задаче: " ^ title
  | _ -> "Уведомление: " ^ kind

(** Доставить все ожидающие уведомления. Возвращает (доставлено, не
    доставлено): сбой одного уведомления не отменяет остальные —
    каждый помечается своим состоянием. *)
let deliver_pending conn ~(send : send) :
    (int * int, string) result Lwt.t =
  let* pending_outcome = Db.Repo_notification.list_pending conn in
  match pending_outcome with
  | Error e -> Lwt_result.lift (Error e)
  | Ok pending ->
  let rec loop sent failed = function
    | [] -> Lwt_result.lift (Ok (sent, failed))
    | item :: rest -> (
        match item.Db.Repo_notification.actor_id with
        | None ->
            let* _ =
              Db.Repo_notification.mark_failed conn item.id
                ~error:"у уведомления нет адресата"
            in
            loop sent (failed + 1) rest
        | Some actor_id -> (
            let* found = Db.Repo_actor.by_id conn actor_id in
            match found with
            | Error e ->
                let* _ = Db.Repo_notification.mark_failed conn item.id ~error:e in
                loop sent (failed + 1) rest
            | Ok None ->
                let* _ =
                  Db.Repo_notification.mark_failed conn item.id
                    ~error:"адресат не найден"
                in
                loop sent (failed + 1) rest
            | Ok Some actor -> (
                let* ref_outcome =
                  Db.Repo_actor.source_ref conn actor.Domain.Actor.id
                    ~source:"mattermost"
                in
                match ref_outcome with
                | Error e ->
                    let* _ = Db.Repo_notification.mark_failed conn item.id ~error:e in
                    loop sent (failed + 1) rest
                | Ok None ->
                    let* _ =
                      Db.Repo_notification.mark_failed conn item.id
                        ~error:"адресат не из Mattermost или без идентификатора"
                    in
                    loop sent (failed + 1) rest
                | Ok Some mm_user_id -> (
                    let text = text_of item.kind item.payload in
                    let* send_outcome = send ~mm_user_id ~text in
                    match send_outcome with
                    | Ok () ->
                        let* _ = Db.Repo_notification.mark_sent conn item.id in
                        loop (sent + 1) failed rest
                    | Error e ->
                        let* _ =
                          Db.Repo_notification.mark_failed conn item.id ~error:e
                        in
                        loop sent (failed + 1) rest))))
  in
  loop 0 0 pending
