(** Доказательства — мост к git и внешнему миру.

    Трекер помнит ссылку и ничего не пересчитывает: существование коммита
    или PR проверяет владелец факта, а не трекер (§3.4 архитектуры). *)

type kind =
  | Commit
  | Branch
  | Pr
  | File
  | Url
  | Doc
  | Note
  | Review
  | Test

type t = {
  id : string;
  task_id : string;
  kind : kind;
  (** Ссылка на факт: sha, имя ветки, номер PR, путь. *)
  ref_ : string;
  uri : string option;
  title : string option;
  note : string option;
  author_id : string option;
  created_at : string;
}

let kind_to_string : kind -> string = function
  | Commit -> "commit"
  | Branch -> "branch"
  | Pr -> "pr"
  | File -> "file"
  | Url -> "url"
  | Doc -> "doc"
  | Note -> "note"
  | Review -> "review"
  | Test -> "test"

let kind_of_string : string -> kind option = function
  | "commit" -> Some Commit
  | "branch" -> Some Branch
  | "pr" -> Some Pr
  | "file" -> Some File
  | "url" -> Some Url
  | "doc" -> Some Doc
  | "note" -> Some Note
  | "review" -> Some Review
  | "test" -> Some Test
  | _ -> None

let all = [ Commit; Branch; Pr; File; Url; Doc; Note; Review; Test ]
