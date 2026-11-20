(** Идемпотентный импорт актёров из Mattermost (§5.3, §10.2 архитектуры).

    Ключ актёра — пара (source, source_ref), где source_ref — идентификатор
    пользователя в Mattermost. Повторный импорт обновляет те же строки, а не
    создаёт новые: импорт можно запускать сколько угодно раз.

    Импорт заодно заводит алиасы: по логину, по отображаемому имени и по
    имени без фамилии. Последнее — потому что в чужих данных человека
    называют по имени («Пётр»), а не по полному имени («Пётр Косов»). *)

open Domain

let ( let* ) t f = Lwt.bind t f

(** Пространство имён, в котором живут имена из Mattermost. *)
let namespace = "mattermost"

(** Вид актёра по данным Mattermost.

    Различатель ADR §5.3 — непустая должность ([position]). Проверка живой
    базы Mattermost показала, что у трёх служебных учётных записей
    ([calls], [system-bot], [kb-publisher]) должность пуста, хотя это боты, и
    что у ботов адрес в служебном домене [@localhost], а у людей — нет.
    Поэтому правило: бот — это непустая должность **или** адрес в домене
    [@localhost]. *)
let kind_of (user : Mattermost.user) : Actor.kind =
  let position = String.trim user.Mattermost.position in
  let email = String.trim user.Mattermost.email in
  if position <> "" then Actor.Agent
  else if String.ends_with ~suffix:"@localhost" email then Actor.Agent
  else Actor.Human

(** Отображаемое имя: имя и фамилия, как в ADR §5.3. *)
let display_name_of (user : Mattermost.user) : string =
  let first = String.trim user.Mattermost.first_name in
  let last = String.trim user.Mattermost.last_name in
  let nickname = String.trim user.Mattermost.nickname in
  match (first, last) with
  | "", "" -> if nickname <> "" then nickname else user.Mattermost.username
  | first, "" -> first
  | "", last -> last
  | first, last -> first ^ " " ^ last

(** Имена, по которым человека называют: логин, полное имя и имя без
    фамилии. *)
let names_of (user : Mattermost.user) : string list =
  let display = display_name_of user in
  let first = String.trim user.Mattermost.first_name in
  [ user.Mattermost.username; display; first ]
  |> List.map String.trim
  |> List.filter (fun name -> name <> "")
  |> List.sort_uniq String.compare

type report = {
  total : int;
  humans : int;
  agents : int;
  created : int;
  updated : int;
  aliases : int;
}

let empty_report : report =
  { total = 0; humans = 0; agents = 0; created = 0; updated = 0; aliases = 0 }

(** Дописать алиасы актёра: логин, полное имя, имя без фамилии. *)
let write_aliases conn ~namespace actor (user : Mattermost.user) :
    (int, string) result Lwt.t =
  let rec loop count names =
    match names with
    | [] -> Lwt_result.lift (Ok count)
    | name :: rest ->
        let* alias =
          Db.Repo_actor_alias.add conn ~actor_id:actor.Actor.id ~namespace ~value:name
            ~source_ref:user.Mattermost.id ()
        in
        (match alias with
        | Error e -> Lwt_result.lift (Error e)
        | Ok _ -> loop (count + 1) rest)
  in
  loop 0 (names_of user)

(** Тело импорта одного пользователя: вызывается внутри транзакции. *)
let import_one conn ~namespace user ~handle ~kind ~display_name ~email :
    (bool * int, string) result Lwt.t =
  let* existing =
    Db.Repo_actor.by_source conn ~source:namespace ~source_ref:user.Mattermost.id
  in
  match existing with
  | Error e -> Lwt_result.lift (Error e)
  | Ok found ->
      let created = found = None in
      let* actor =
        Db.Repo_actor.upsert_from_source conn ~source:namespace
          ~source_ref:user.Mattermost.id ~kind ~handle ~display_name ?email ()
      in
      (match actor with
      | Error e -> Lwt_result.lift (Error e)
      | Ok actor ->
          let* written = write_aliases conn ~namespace actor user in
          (match written with
          | Error e -> Lwt_result.lift (Error e)
          | Ok count -> Lwt_result.lift (Ok (created, count))))

(** Импортировать одного пользователя.

    Всё внутри одной транзакции: актёр и его алиасы либо появляются вместе,
    либо не появляются вовсе. *)
let import_user conn ~namespace (user : Mattermost.user) :
    (bool * int, string) result Lwt.t =
  let handle = Identity.Resolve.normalize user.Mattermost.username in
  let kind = kind_of user in
  let display_name = display_name_of user in
  let email =
    let value = String.trim user.Mattermost.email in
    if value = "" then None else Some value
  in
  Db.Conn.with_transaction conn (fun () ->
      import_one conn ~namespace user ~handle ~kind ~display_name ~email)

(** Импортировать список пользователей.

    Порядок пользователей не влияет на результат: ключ источника один и тот
    же, а алиасы уникальны внутри пространства имён. *)
let import_users conn ~namespace (users : Mattermost.user list) :
    (report, string) result Lwt.t =
  let rec loop report users =
    match users with
    | [] -> Lwt_result.lift (Ok report)
    | user :: rest ->
        let* outcome = import_user conn ~namespace user in
        (match outcome with
        | Error e -> Lwt_result.lift (Error e)
        | Ok (created, aliases) ->
            let report =
              {
                total = report.total + 1;
                humans = report.humans + (if kind_of user = Actor.Human then 1 else 0);
                agents = report.agents + (if kind_of user = Actor.Agent then 1 else 0);
                created = report.created + (if created then 1 else 0);
                updated = report.updated + (if created then 0 else 1);
                aliases = report.aliases + aliases;
              }
            in
            loop report rest)
  in
  loop empty_report users
