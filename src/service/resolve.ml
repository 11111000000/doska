(** Разрешение имени в актора по данным базы (§5.2 архитектуры).

    Доменный алгоритм живёт в [Identity.Resolve] и ничего не знает про базу:
    он получает склад и возвращает решение. Здесь алгоритм оборачивается —
    склад собирается из базы, а решение превращается в запись:

    - алиас, найденный в чужом пространстве имён, дописывается в своё;
    - неизвестное имя не теряется, а превращается в заглушку
      ([unresolved = true], §3.1): терять имя нельзя, человек потом
      свяжет заглушку с настоящим актёром.

    И то и другое — запись в базу, поэтому здесь нужен [Db]. *)

open Domain

type outcome =
  | Resolved of {
      actor : Actor.t;
      (** Алиас, дописанный в текущее пространство имён. *)
      new_alias : string option;
    }
  | Placeholder of {
      actor : Actor.t;
      raw : string;
      normalized : string;
    }

let ( let* ) t f = Lwt.bind t f

(** Склад для доменного алгоритма: актёры и алиасы из базы. *)
let load_store conn : (Identity.Resolve.store, string) result Lwt.t =
  let* actors = Db.Repo_actor.list conn in
  let* aliases = Db.Repo_actor.aliases conn in
  match (actors, aliases) with
  | Ok actors, Ok aliases ->
      let store : Identity.Resolve.store = { actors; aliases } in
      Lwt_result.lift (Ok store)
  | Error e, _ -> Lwt_result.lift (Error e)
  | _, Error e -> Lwt_result.lift (Error e)

(** Разрешить имя в готовом складе. *)
let resolve_in_store conn store ~namespace ~principal ~raw :
    (outcome, string) result Lwt.t =
  match Identity.Resolve.resolve store ~namespace ~principal ~raw with
  | Identity.Resolve.Resolved { actor; new_alias = None } ->
      Lwt_result.lift (Ok (Resolved { actor; new_alias = None }))
  | Identity.Resolve.Resolved { actor; new_alias = Some value } ->
      let* written =
        Db.Repo_actor_alias.add conn ~actor_id:actor.Actor.id ~namespace ~value ()
      in
      (match written with
      | Error e -> Lwt_result.lift (Error e)
      | Ok _ -> Lwt_result.lift (Ok (Resolved { actor; new_alias = Some value })))
  | Identity.Resolve.Placeholder { raw; normalized } ->
      let* created =
        Db.Repo_actor.create_placeholder conn ~handle:normalized ~display_name:raw
      in
      (match created with
      | Error e -> Lwt_result.lift (Error e)
      | Ok actor ->
          let* written =
            Db.Repo_actor_alias.add conn ~actor_id:actor.Actor.id ~namespace
              ~value:normalized ()
          in
          (match written with
          | Error e -> Lwt_result.lift (Error e)
          | Ok _ ->
              Lwt_result.lift (Ok (Placeholder { actor; raw; normalized }))))

(** Разрешить имя.

    [namespace] — пространство имён, в котором ищется алиас и в которое
    дописывается найденный в чужом пространстве. *)
let resolve conn ~namespace ~principal ~raw : (outcome, string) result Lwt.t =
  let* loaded = load_store conn in
  match loaded with
  | Error e -> Lwt_result.lift (Error e)
  | Ok store -> resolve_in_store conn store ~namespace ~principal ~raw
