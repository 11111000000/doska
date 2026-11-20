(** Алиасы актёров: один и тот же человек называется по-разному.

    Пространство имён ([namespace]) — откуда пришло имя: `mattermost`,
    `teamboard`, `git`, `email`, `manual`. Один человек может иметь по
    алиасу в каждом пространстве, но внутри пространства имя принадлежит
    ровно одному человеку: это и держит [UNIQUE (namespace, alias)].

    Резолвер идентичности (§5.2) ищет сначала алиас своего пространства, а
    потом — любой; найденный в чужом пространстве дописывается в своё. *)

type t = {
  id : string;
  actor_id : string;
  namespace : string;
  value : string;
  source_ref : string option;
}

let ( let* ) t f = Lwt.bind t f

let of_json (json : Yojson.Safe.t) : t =
  {
    id = Row.string_ json "id" ~default:"";
    actor_id = Row.string_ json "actor_id" ~default:"";
    namespace = Row.string_ json "namespace" ~default:"";
    value = Row.string_ json "value" ~default:"";
    source_ref = Row.opt_string json "source_ref";
  }

let select =
  "SELECT row_to_json(x)::text FROM (SELECT id::text AS id, actor_id::text AS actor_id, \
   namespace, alias::text AS value, alias AS citext_value, source_ref FROM actor_alias) x"

let by_id conn id : (t option, string) result Lwt.t =
  if not (Conn.is_uuid id) then Lwt_result.lift (Ok None)
  else
    Conn.query_json_rows conn
      (Printf.sprintf "%s WHERE x.id = %s" select (Conn.quote id))
    |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

(** Алиас по паре «пространство + имя».

    Имя в базе — [citext], поэтому сравнение регистронезависимое: «Пётр» и
    «петр» — один и тот же алиас. Сравнивать надо с [citext]: приведённое к
    [text] значение сравнивалось бы посимвольно и не нашло бы существующий
    алиас, записанный в другом регистре. *)
let find conn ~namespace ~value : (t option, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf "%s WHERE x.namespace = %s AND x.citext_value = %s" select
       (Conn.quote namespace) (Conn.quote value))
  |> Lwt_result.map (function [] -> None | json :: _ -> Some (of_json json))

let list conn : (t list, string) result Lwt.t =
  Conn.query_json_rows conn (select ^ " ORDER BY x.namespace, x.value")
  |> Lwt_result.map (List.map of_json)

let by_namespace conn namespace : (t list, string) result Lwt.t =
  Conn.query_json_rows conn
    (Printf.sprintf "%s WHERE x.namespace = %s ORDER BY x.value" select
       (Conn.quote namespace))
  |> Lwt_result.map (List.map of_json)

(** Дописать алиас.

    Запись идемпотентна: повторный вызов с тем же именем в том же
    пространстве не создаёт второй строки, а возвращает уже существующую.
    Иначе повторный импорт одного и того же источника плодил бы дубли. *)
let add conn ~actor_id ~namespace ~value ?source_ref () : (t, string) result Lwt.t =
  match Conn.uuid_literal actor_id with
  | None -> Lwt_result.lift (Error ("id актора не похож на uuid: " ^ actor_id))
  | Some literal ->
      let source_ref_sql =
        match source_ref with None -> "NULL" | Some ref_ -> Conn.quote ref_
      in
      let sql =
        Printf.sprintf
          "INSERT INTO actor_alias (actor_id, namespace, alias, source_ref) \
           VALUES (%s, %s, %s, %s) \
           ON CONFLICT (namespace, alias) DO NOTHING RETURNING id::text"
          literal (Conn.quote namespace) (Conn.quote value) source_ref_sql
      in
      let* inserted = Conn.query_strings conn sql in
      (match inserted with
      | Error e -> Lwt_result.lift (Error e)
      | Ok (id :: _) -> (
          let* found = by_id conn id in
          match found with
          | Error e -> Lwt_result.lift (Error e)
          | Ok (Some alias) -> Lwt_result.lift (Ok alias)
          | Ok None -> Lwt_result.lift (Error "алиас записан, но не прочитан"))
      | Ok [] -> (
          (* Алиас уже был: вернуть существующий, а не пустоту. *)
          let* found = find conn ~namespace ~value in
          match found with
          | Error e -> Lwt_result.lift (Error e)
          | Ok (Some alias) -> Lwt_result.lift (Ok alias)
          | Ok None -> Lwt_result.lift (Error "алиас занят, но не найден")))
