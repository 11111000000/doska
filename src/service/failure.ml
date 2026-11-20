(** Ошибка use case'а.

    Домен возвращает причину отказа строкой, репозиторий — текстом SQL-ошибки.
    HTTP-слой должен различать «запрос неправильный», «правило запрещает»,
    «ресурса нет», «конфликт версии» и «сломалось у нас» — поэтому use case
    возвращает закрытый тип ошибки, а не строку.

    Тип живёт в сервисном слое: домен о базе и HTTP не знает, а HTTP зависит от
    сервиса, а не наоборот. *)

type t =
  | Bad_request of { message : string }
  | Forbidden of { message : string; details : (string * string) list }
  | Not_found of { message : string }
  | Conflict of { message : string }
  | Storage of { message : string }

(** Класс отказа одной строкой: в логе и в тесте важно различать «правило
    запрещает» и «сломалось хранилище», а не читать сообщение целиком. *)
let to_string (failure : t) : string =
  match failure with
  | Bad_request { message } -> "bad_request: " ^ message
  | Forbidden { message; _ } -> "forbidden: " ^ message
  | Not_found { message } -> "not_found: " ^ message
  | Conflict { message } -> "conflict: " ^ message
  | Storage { message } -> "storage: " ^ message
