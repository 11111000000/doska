(** Разбор строки базы в значения.

    Репозитории читают строки как JSON ([row_to_json] в SQL), поэтому
    разбор однотипных полей живёт здесь, а не размазан по репозиториям. *)

let field (json : Yojson.Safe.t) (name : string) : Yojson.Safe.t option =
  match json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

(** Текстовое поле. NULL и отсутствующее поле — «нет значения». *)
let opt_string (json : Yojson.Safe.t) (name : string) : string option =
  match field json name with
  | Some (`String s) -> Some s
  | Some `Null -> None
  | Some (`Int i) -> Some (string_of_int i)
  | Some (`Bool b) -> Some (string_of_bool b)
  | Some _ -> None
  | None -> None

(** Текстовое поле с запасным значением: описание задачи может быть пустым. *)
let string_ (json : Yojson.Safe.t) (name : string) ~(default : string) : string =
  match opt_string json name with Some s -> s | None -> default

let int_ (json : Yojson.Safe.t) (name : string) ~(default : int) : int =
  match field json name with
  | Some (`Int i) -> i
  | Some (`Intlit s) -> ( match int_of_string_opt s with Some i -> i | None -> default)
  | Some (`Float f) -> int_of_float f
  | _ -> default

let int64_ (json : Yojson.Safe.t) (name : string) ~(default : int64) : int64 =
  match field json name with
  | Some (`Int i) -> Int64.of_int i
  | Some (`Intlit s) -> ( match Int64.of_string_opt s with Some i -> i | None -> default)
  | _ -> default

let bool_ (json : Yojson.Safe.t) (name : string) ~(default : bool) : bool =
  match field json name with
  | Some (`Bool b) -> b
  | Some (`String s) -> s = "true"
  | _ -> default

let string_list (json : Yojson.Safe.t) (name : string) : string list =
  match field json name with
  | Some (`List items) ->
      List.filter_map
        (function `String s -> Some s | _ -> None)
        items
  | _ -> []
