(** Разбор запроса: тело — JSON, параметры — строки. *)

let json_field (json : Yojson.Safe.t) (name : string) : Yojson.Safe.t option =
  match json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_field (json : Yojson.Safe.t) (name : string) : string option =
  match json_field json name with
  | Some (`String s) -> Some s
  | _ -> None

let int_field (json : Yojson.Safe.t) (name : string) : int option =
  match json_field json name with
  | Some (`Int i) -> Some i
  | Some (`Intlit s) -> int_of_string_opt s
  | Some (`String s) -> int_of_string_opt s
  | _ -> None

let string_list_field (json : Yojson.Safe.t) (name : string) : string list option =
  match json_field json name with
  | Some (`List items) ->
      Some (List.filter_map (function `String s -> Some s | _ -> None) items)
  | _ -> None

(** Тело запроса как JSON. Пустое тело — пустой объект, а не ошибка:
    вызов без параметров должен быть таким же предсказуемым, как вызов с ними. *)
let body_json req : (Yojson.Safe.t, string) result Lwt.t =
  Lwt.bind (Dream.body req) (fun raw ->
      let raw = String.trim raw in
      if raw = "" then Lwt.return (Ok (`Assoc []))
      else
        match Yojson.Safe.from_string raw with
        | json -> Lwt.return (Ok json)
        | exception Yojson.Json_error e -> Lwt.return (Error e))
