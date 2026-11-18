(** Разрешение имён: «Пётр», «petr», «@пётр» — один и тот же человек.

    Алгоритм §5.2 архитектуры. Если имя не найдено, оно не теряется:
    возвращается заглушка [Placeholder], которую видно в админке и которую
    потом можно связать с настоящим актором. *)

open Domain

type alias = {
  namespace : string;
  value : string;
  actor_id : string;
}

type store = {
  actors : Actor.t list;
  aliases : alias list;
}

type resolution =
  | Resolved of {
      actor : Actor.t;
      (** Алиас, который стоит дописать в текущее пространство имён. *)
      new_alias : string option;
    }
  | Placeholder of {
      raw : string;
      normalized : string;
    }

(** «ё» и «Ё» — это два байта UTF-8, а не символ OCaml: литерал ['ё'] в
    исходнике просто не компилируется. Поэтому замена идёт по байтам:
    D1 91 («ё») и D0 81 («Ё») заменяются на D0 B5 («е»). *)
let e_lower = "\xd0\xb5"

let replace_yo (s : string) : string =
  let n = String.length s in
  let buf = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    if !i + 1 < n && s.[!i] = '\xd1' && s.[!i + 1] = '\x91' then (
      Buffer.add_string buf e_lower;
      i := !i + 2)
    else if !i + 1 < n && s.[!i] = '\xd0' && s.[!i + 1] = '\x81' then (
      Buffer.add_string buf e_lower;
      i := !i + 2)
    else (
      Buffer.add_char buf s.[!i];
      incr i)
  done;
  Buffer.contents buf

(** Приведение к нижнему регистру.

    [String.lowercase_ascii] умеет только ASCII: «Пётр» остался бы с
    заглавной «П» и не совпал бы с «пётр». Поэтому отдельно разбираем
    латиницу (Latin-1) и кириллицу — это тот алфавит, в котором живут
    имена людей и агентов. *)
let lowercase (s : string) : string =
  let n = String.length s in
  let buf = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c >= 'A' && c <= 'Z' then (
      Buffer.add_char buf (Char.lowercase_ascii c);
      incr i)
    else if c = '\xd0' && !i + 1 < n then (
      (* Кириллица всегда двухбайтная:
         U+0400–U+040F (D0 80–D0 8F) → U+0450–U+045F (D1 90–D1 9F),
         U+0410–U+042F (D0 90–D0 9F) → U+0430–U+044F (D0 B0–D0 BF).
         Эту ветку надо проверять раньше латинской: D0 входит в диапазон
         C0–DE, но в кириллице это ведущий байт, а не буква. *)
      let b = s.[!i + 1] in
      if b >= '\x80' && b <= '\x8f' then (
        Buffer.add_char buf '\xd1';
        Buffer.add_char buf (Char.chr (Char.code b + 0x10));
        i := !i + 2)
      else if b >= '\x90' && b <= '\x9f' then (
        Buffer.add_char buf '\xd0';
        Buffer.add_char buf (Char.chr (Char.code b + 0x20));
        i := !i + 2)
      else (
        Buffer.add_char buf c;
        incr i))
    else if (c >= '\xc0' && c <= '\xcf') || (c >= '\xd7' && c <= '\xde') then (
      (* Латиница с диакритикой: À–Ï, ×–Þ → à–ï, ÷–þ. *)
      Buffer.add_char buf (Char.chr (Char.code c + 0x20));
      incr i)
    else (
      Buffer.add_char buf c;
      incr i)
  done;
  Buffer.contents buf

(** Нормализация имени: пробелы, регистр, «ё» и ведущий «@». *)
let normalize (s : string) : string =
  let s = String.trim s in
  let s =
    if String.length s > 0 && s.[0] = '@' then
      String.sub s 1 (String.length s - 1)
    else s
  in
  let s = replace_yo s in
  let s = lowercase s in
  String.split_on_char ' '
    s
    |> List.map (fun word ->
           String.map
             (fun c ->
               match c with
               | '\t' | '\n' | '\r' -> ' '
               | c -> c)
             word)
    |> List.filter (fun word -> word <> "")
    |> String.concat " "

(** «я», «мне», «me» — сам заявитель. *)
let is_self (raw : string) : bool =
  match String.lowercase_ascii (String.trim raw) with
  | "me" | "я" | "мне" | "мной" | "себе" -> true
  | _ -> false

let find_actor store id = List.find_opt (fun (a : Actor.t) -> a.id = id) store.actors

let resolve store ~namespace ~principal ~(raw : string) : resolution =
  if is_self raw then Resolved { actor = principal; new_alias = None }
  else
    let n = normalize raw in
    match List.find_opt (fun (a : Actor.t) -> a.handle = n) store.actors with
    | Some actor -> Resolved { actor; new_alias = None }
    | None -> (
        match
          List.find_opt
            (fun (al : alias) -> al.namespace = namespace && normalize al.value = n)
            store.aliases
        with
        | Some al -> (
            match find_actor store al.actor_id with
            | Some actor -> Resolved { actor; new_alias = None }
            | None -> Placeholder { raw; normalized = n })
        | None -> (
            match
              List.find_opt (fun (al : alias) -> normalize al.value = n) store.aliases
            with
            | Some al -> (
                match find_actor store al.actor_id with
                | Some actor -> Resolved { actor; new_alias = Some n }
                | None -> Placeholder { raw; normalized = n })
            | None -> (
                match
                  List.find_opt
                    (fun (a : Actor.t) -> normalize a.display_name = n)
                    store.actors
                with
                | Some actor -> Resolved { actor; new_alias = None }
                | None -> Placeholder { raw; normalized = n })))

(** Пустой склад: используется в тестах и как стартовое состояние до импорта. *)
let empty : store = { actors = []; aliases = [] }
