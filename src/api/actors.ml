(** Разрешение имени в актора: [POST /api/v1/actors/resolve] (§6.1).

    Это главный вопрос трекера: «кто это». Клиент присылает имя так, как оно
    написано в источнике («Пётр», «@пётр», «petr»), а сервер отвечает
    актёром — или заглушкой, если имя не удалось разрешить.

    Ответ всегда содержит актёра: потерять имя нельзя (§3.1). Поле
    [unresolved] у актёра говорит, что это заглушка. *)

open Domain

let ( let* ) t f = Lwt.bind t f

(** Пространство имён по умолчанию.

    Для людей это [mattermost] (§5.2): в этом пространстве лежат имена,
    которыми человека называют в чате. Другие пространства — [teamboard],
    [git], [email], [manual]. *)
let default_namespace = "mattermost"

let ok payload = Dream.json (Yojson.Safe.to_string payload)

let opt = function None -> `Null | Some value -> `String value

(** Ответ-промис: [Dream.json] уже возвращает промис, и оборачивать его в
    [Lwt.return] нельзя — получится промис в промисе. *)
let send (p : 'a Lwt.t) : 'a Lwt.t = Lwt.bind p (fun x -> Lwt.return x)

(** Пространство имён из тела запроса: пустое значение — значение по
    умолчанию, а не ошибка. *)
let namespace_of body =
  match Params.string_field body "namespace" with
  | Some value ->
      let value = String.trim value in
      if value = "" then default_namespace else value
  | None -> default_namespace

let resolve req =
  Context.with_body req (fun conn principal body ->
      match Params.string_field body "raw" with
      | None ->
          Errors.respond
            (Errors.make Errors.Bad_request "нужно поле raw: имя, которое разрешаем")
      | Some raw when String.trim raw = "" ->
          (* Пустое имя — это не имя, а его отсутствие. Заглушка такому имени
             не нужна: терять нечего. *)
          Errors.respond (Errors.make Errors.Bad_request "имя пустое: разрешать нечего")
      | Some raw ->
          let namespace = namespace_of body in
          let* outcome = Service.Resolve.resolve conn ~namespace ~principal ~raw in
          match outcome with
          | Error e -> Errors.respond (Errors.make Errors.Internal e)
          | Ok (Service.Resolve.Resolved { actor; new_alias }) ->
              send
                (ok
                   (`Assoc
                      [
                        ("actor", View.actor actor);
                        ("resolved", `Bool (not actor.Actor.unresolved));
                        ("new_alias", opt new_alias);
                      ]))
          | Ok (Service.Resolve.Placeholder { actor; raw; normalized }) ->
              send
                (ok
                   (`Assoc
                      [
                        ("actor", View.actor actor);
                        ("resolved", `Bool false);
                        ("raw", `String raw);
                        ("normalized", `String normalized);
                      ])))
