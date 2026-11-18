(** Комментарии — обсуждение внутри задачи, а не переписка из Mattermost.

    Трекер не хранит разговор: комментарий — короткая заметка по существу
    обязательства (§3.6 архитектуры). *)

type t = {
  id : string;
  task_id : string;
  parent_id : string option;
  author_id : string option;
  body : string;
  created_at : string;
  edited_at : string option;
}
