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

(** Перевод ошибки use case'а в код ответа.

    Маппинг живёт здесь, а не в сервисе: коды ответа — понятие интерфейса,
    а сервис о HTTP не знает. *)
let of_failure (failure : Service.Failure.t) : t =
  match failure with
  | Service.Failure.Bad_request { message } -> make Bad_request message
  | Service.Failure.Forbidden { message; details } ->
      make Forbidden message
        ~details:(List.map (fun (key, value) -> (key, `String value)) details)
  | Service.Failure.Not_found { message } -> make Not_found message
  | Service.Failure.Conflict { message } -> make Conflict message
  | Service.Failure.Storage { message } -> make Internal message

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
