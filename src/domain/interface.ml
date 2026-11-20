(** Откуда пришло действие.

    Журнал должен различать интерфейсы: «это сделал агент через MCP» и «это
    сделал человек через REST» — разные следы с разными последствиями. Пока
    интерфейс был строкой, в журнале писалась константа [api] в шести местах,
    и агентский вызов выглядел как человеческий REST.

    Тип закрытый: новый интерфейс — это новое место в списке, а не строка,
    которую можно ошибиться при наборе. В базу пишется текстовое имя
    ([to_string]), а при чтении неизвестное значение не ломает чтение журнала. *)

type t =
  | Api
  | Mcp
  | Cli
  | Web
  | Mattermost
  | Paseo
  | Import
  | System

let to_string : t -> string = function
  | Api -> "api"
  | Mcp -> "mcp"
  | Cli -> "cli"
  | Web -> "web"
  | Mattermost -> "mattermost"
  | Paseo -> "paseo"
  | Import -> "import"
  | System -> "system"

let of_string : string -> t option = function
  | "api" -> Some Api
  | "mcp" -> Some Mcp
  | "cli" -> Some Cli
  | "web" -> Some Web
  | "mattermost" -> Some Mattermost
  | "paseo" -> Some Paseo
  | "import" -> Some Import
  | "system" -> Some System
  | _ -> None

(** Чтение значения из базы.

    Неизвестное имя — не повод отказать: старые строки журнала должны читаться
    и после появления новых интерфейсов. Неизвестное имя трактуем как
    [system] — действие без интерфейса. *)
let of_string_default s = match of_string s with Some i -> i | None -> System
