(** Проекты трекера: [GET /api/v1/projects], [POST /api/v1/projects].

    Адаптер над хранилищем: правил здесь нет, форма ответа — как в
    [View.project]. Клиенту нужен список, чтобы выбрать проект для доски. *)

let ( let* ) t f = Lwt.bind t f

let json_of (p : Domain.Project.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String p.Domain.Project.id);
      ("key", `String p.Domain.Project.key);
      ("name", `String p.Domain.Project.name);
      ("autonomy", `String (Domain.Actor.autonomy_to_string p.Domain.Project.autonomy));
    ]

(** Ключ проекта: строчные буквы, цифры, дефис — как в ADR §3.1. Ключ
    попадает в подпись и в адрес, поэтому пробелы и регистр ломают
    ссылку на проект. *)
let valid_key key =
  let ok = ref true in
  String.iter
    (fun c ->
      let lower = Char.lowercase_ascii c in
      if
        not
          ((lower >= 'a' && lower <= 'z') || (c >= '0' && c <= '9') || c = '-'
          || c = '_')
      then ok := false)
    key;
  if !ok then Ok () else Error ("неверный key проекта: " ^ key)

let list req =
  Context.with_actor req (fun conn _actor ->
      let* outcome = Db.Repo_project.list conn in
      match outcome with
      | Error e -> Errors.respond (Errors.make Errors.Internal e)
      | Ok projects ->
          Dream.json
            (Yojson.Safe.to_string
               (`List (List.map json_of projects))))


(** Есть ли подстрока в строке: свой поиск вместо Str — лишняя зависимость
    ради двух проверок. *)
let has_sub hay needle =
  let n = String.length needle and m = String.length hay in
  let rec loop i = i + n <= m && (String.sub hay i n = needle || loop (i + 1)) in
  n = 0 || loop 0

(* Создание проекта: [POST /api/v1/projects].

    Ключ проекта уникален, поэтому повтор ключа — конфликт, а не тихая
    подмена: два проекта с одним ключом слились бы в один, а это молча
    меняет смысл задач. *)

let key_of body =
  match Yojson.Safe.Util.member "key" body with
  | `String key when String.trim key <> "" -> Ok (String.trim key)
  | _ -> Error "нужен непустой key"

let name_of body key =
  match Yojson.Safe.Util.member "name" body with
  | `String name when String.trim name <> "" -> Ok (String.trim name)
  | _ -> Ok key

let autonomy_of body =
  match Yojson.Safe.Util.member "autonomy" body with
  | `String value ->
      (match Domain.Actor.autonomy_of_string (String.trim value) with
      | Some autonomy -> Ok autonomy
      | None -> Error ("неизвестная autonomy: " ^ value))
  | _ -> Ok Domain.Actor.Human_gate

let create req =
  Context.with_body req (fun conn _actor body ->
      match (key_of body, name_of body "", autonomy_of body) with
      | Error message, _, _ | _, Error message, _ | _, _, Error message ->
          Errors.respond (Errors.make Errors.Bad_request message)
      | Ok key, Ok name, Ok autonomy -> (
          match valid_key key with
          | Error message ->
              Errors.respond (Errors.make Errors.Bad_request message)
          | Ok () ->
              let* outcome = Db.Repo_project.create conn ~key ~name ~autonomy () in
              (match outcome with
              | Error e ->
                  (* Повтор ключа — конфликт, а не сбой: клиент должен
                     отличить «занято» от «сломано у нас». *)
                  if has_sub e "duplicate" || has_sub e "unique"
                  then Errors.respond (Errors.make Errors.Conflict ("ключ проекта уже занят: " ^ key))
                  else Errors.respond (Errors.make Errors.Internal e)
              | Ok project ->
                  Dream.json ~status:`Created
                    (Yojson.Safe.to_string (json_of project)))))
