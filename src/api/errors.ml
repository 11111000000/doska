(** Единый формат ошибок API.

    Клиент должен отличать «запрос неправильный» от «правило запрещает» от
    «ресурса нет» — поэтому у ошибки есть код, а не только текст. *)

type code =
  | Bad_request
  | Unauthorized
  | Forbidden
  | Not_found
  | Conflict
  | Internal

type t = {
  code : code;
  message : string;
  details : (string * Yojson.Safe.t) list;
}

let code_to_string = function
  | Bad_request -> "bad_request"
  | Unauthorized -> "unauthorized"
  | Forbidden -> "forbidden"
  | Not_found -> "not_found"
  | Conflict -> "conflict"
  | Internal -> "internal"

let status = function
  | Bad_request -> `Bad_Request
  | Unauthorized -> `Unauthorized
  | Forbidden -> `Forbidden
  | Not_found -> `Not_Found
  | Conflict -> `Conflict
  | Internal -> `Internal_Server_Error

let make ?(details = []) code message : t = { code; message; details }

let to_json (e : t) : Yojson.Safe.t =
  let base =
    [ ("code", `String (code_to_string e.code)); ("message", `String e.message) ]
  in
  let base =
    if e.details = [] then base else base @ [ ("details", `Assoc e.details) ]
  in
  `Assoc [ ("error", `Assoc base) ]

let respond (e : t) : Dream.response Lwt.t =
  Dream.json ~status:(status e.code) (Yojson.Safe.to_string (to_json e))
