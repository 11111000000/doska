(** Идентичность на живой базе: алиасы, ключ источника, заглушки, импорт.

    Доменный алгоритм разрешения имён проверяется в [test/identity_test.ml] —
    там нет базы. Здесь проверяется другое: склад для алгоритма собирается из
    настоящих строк, резолвер пишет в базу (дописывает алиас, создаёт
    заглушку), а импорт из Mattermost идемпотентен.

    Тест живёт в собственных пространствах имён и на собственном префиксе
    логинов ([idn-]): живые данные Mattermost он не трогает и не спорит с
    ними за имена. У каждого проверяемого свойства своё пространство — тесты
    не зависят от порядка друг друга. *)

open Domain

let conn = Support.connect ()

(* Фикстуры теста общие с его повторным прогоном: блокируемся, чтобы уборка
   одного прогона не удалила фикстуры другого. *)
let () = Support.lock conn 4714

(* Уборка — до фикстур: [Alcotest.run] завершает процесс, код после него не
   выполняется. *)
let () =
  Support.cleanup conn ~source:"test-identity" ~actor_prefix:"idn-"
    ~project_prefix:"IDN"

let run = Support.run

let fail fmt = Printf.ksprintf failwith fmt

(** Успех ожидался: ошибка — это падение теста с понятным текстом. *)
let get f =
  match run f with
  | Ok value -> value
  | Error e -> fail "ожидался успех, получено: %s" e

(* --------------------------------------------------------- пространства имён --- *)

(* У каждого проверяемого свойства своё пространство: тесты не зависят от
   порядка друг друга и не спорят за алиасы. *)
let ns_alias = "idn-alias"
let ns_foreign = "idn-foreign"
let ns_source = "idn-source"
let ns_import = "idn-import"
let ns_kind = "idn-kind"
let ns_alias_import = "idn-alias-import"
let ns_resolve = "idn-resolve"
let ns_placeholder = "idn-placeholder"
let ns_adopt = "idn-adopt"

(** Сколько строк вернул счётчик. *)
let count_of sql =
  match get (Db.Conn.query_int64s conn sql) with
  | count :: _ -> Int64.to_int count
  | [] -> 0

(** Сколько актёров пришло из источника. *)
let actors_of_source source =
  count_of
    (Printf.sprintf "SELECT count(*) FROM actor WHERE source = %s"
       (Db.Conn.quote source))

(** Количество алиасов пространства. *)
let alias_count namespace =
  count_of
    (Printf.sprintf "SELECT count(*) FROM actor_alias WHERE namespace = %s"
       (Db.Conn.quote namespace))

(* ------------------------------------------------------------- фикстуры --- *)

let requester =
  Support.ensure_actor conn ~prefix:"idn-" ~kind:Actor.Human ~handle:"requester"
    ~display_name:"Заявитель"

let resolver =
  Support.ensure_actor conn ~prefix:"idn-" ~kind:Actor.Human ~handle:"resolver"
    ~display_name:"idn-тестовый"

(** Пользователь Mattermost: та же форма, что и в ответе API. *)
let mm_user ~id ~username ~first ~last ~position ~email : Service.Mattermost.user =
  {
    Service.Mattermost.id;
    username;
    first_name = first;
    last_name = last;
    nickname = "";
    position;
    email;
    deleted = false;
  }

(** Трое пользователей для импорта: человек, агент по должности и агент по
    служебному адресу. Префикс разный у каждого набора — логин уникален в
    базе, и два набора в разных пространствах не должны спорить за него. *)
let users_for prefix =
  [
    mm_user ~id:(prefix ^ "-u-petr") ~username:(prefix ^ "-petrik") ~first:"Пётр"
      ~last:"Косов" ~position:"" ~email:(prefix ^ "-peter@example.org");
    mm_user ~id:(prefix ^ "-u-analyst") ~username:(prefix ^ "-analitik") ~first:""
      ~last:"" ~position:"Аналитик" ~email:(prefix ^ "-analyst@example.org");
    mm_user ~id:(prefix ^ "-u-bot") ~username:(prefix ^ "-botik") ~first:"" ~last:""
      ~position:"" ~email:(prefix ^ "-bot@localhost");
  ]

(* ------------------------------------------------------------- алиасы --- *)

let test_alias_repository () =
  let actor = resolver in
  let alias =
    get
      (Db.Repo_actor_alias.add conn ~actor_id:actor.Actor.id ~namespace:ns_alias
         ~value:"Пётр Тестовый" ())
  in
  Alcotest.(check string) "алиас принадлежит актёру" actor.Actor.id alias.Db.Repo_actor_alias.actor_id;
  Alcotest.(check string) "пространство" ns_alias alias.namespace;

  (* Повторная запись того же имени в том же пространстве не создаёт второй
     строки: импорт одного и того же источника идёт много раз. *)
  let again =
    get
      (Db.Repo_actor_alias.add conn ~actor_id:actor.Actor.id ~namespace:ns_alias
         ~value:"Пётр Тестовый" ())
  in
  Alcotest.(check string) "тот же алиас" alias.id again.id;
  Alcotest.(check int) "строк ровно одна" 1 (alias_count ns_alias);

  (* Имя в базе — citext: «пётр тестовый» и «Пётр Тестовый» — один алиас. *)
  let found =
    get (Db.Repo_actor_alias.find conn ~namespace:ns_alias ~value:"пётр тестовый")
  in
  Alcotest.(check (option string)) "регистр не важен" (Some alias.id)
    (Option.map (fun a -> a.Db.Repo_actor_alias.id) found);

  (* Пространство имён разделяет: то же имя в чужом пространстве — другой
     алиас (§5.2). *)
  let other =
    get (Db.Repo_actor_alias.find conn ~namespace:ns_foreign ~value:"Пётр Тестовый")
  in
  Alcotest.(check (option string)) "в чужом пространстве пусто" None
    (Option.map (fun a -> a.Db.Repo_actor_alias.id) other);

  let list = get (Db.Repo_actor_alias.by_namespace conn ns_alias) in
  Alcotest.(check int) "в списке одна строка" 1 (List.length list)

(* ------------------------------------------------- ключ источника (§10.2) --- *)

let test_actor_source_key () =
  let actor =
    get
      (Db.Repo_actor.upsert_from_source conn ~source:ns_source ~source_ref:"u-1"
         ~kind:Actor.Human ~handle:"idn-src1" ~display_name:"Источник Первый" ())
  in

  let found =
    get (Db.Repo_actor.by_source conn ~source:ns_source ~source_ref:"u-1")
  in
  Alcotest.(check (option string)) "найден по паре (source, source_ref)"
    (Some actor.Actor.id)
    (Option.map (fun a -> a.Actor.id) found);

  (* Ключ составной: то же source_ref из другого источника — другой актёр. *)
  let other_source =
    get (Db.Repo_actor.by_source conn ~source:"idn-другой" ~source_ref:"u-1")
  in
  Alcotest.(check (option string)) "чужой источник не подходит" None
    (Option.map (fun a -> a.Actor.id) other_source);

  let other_ref =
    get (Db.Repo_actor.by_source conn ~source:ns_source ~source_ref:"u-2")
  in
  Alcotest.(check (option string)) "чужой source_ref не подходит" None
    (Option.map (fun a -> a.Actor.id) other_ref);

  let source = get (Db.Repo_actor.source_of conn actor.Actor.id) in
  Alcotest.(check (option string)) "источник записан" (Some ns_source)
    (Option.map fst source);
  Alcotest.(check (option string)) "ключ источника записан" (Some "u-1")
    (Option.map snd source)

(* ------------------------------------------- импорт из Mattermost (§5.3) --- *)

let test_import_is_idempotent () =
  let users = users_for ns_import in
  let report =
    get (Service.Import_actors.import_users conn ~namespace:ns_import users)
  in
  Alcotest.(check int) "всего" 3 report.Service.Import_actors.total;
  Alcotest.(check int) "создано" 3 report.created;
  Alcotest.(check int) "обновлено" 0 report.updated;
  Alcotest.(check int) "людей" 1 report.humans;
  Alcotest.(check int) "агентов" 2 report.agents;
  Alcotest.(check int) "актёров в базе" 3 (actors_of_source ns_import);

  (* Повторный импорт — те же строки, а не новые. *)
  let again =
    get (Service.Import_actors.import_users conn ~namespace:ns_import users)
  in
  Alcotest.(check int) "повторно создано" 0 again.created;
  Alcotest.(check int) "повторно обновлено" 3 again.updated;
  Alcotest.(check int) "актёров в базе" 3 (actors_of_source ns_import);

  (* Порядок пользователей не влияет на результат. *)
  let shuffled =
    get
      (Service.Import_actors.import_users conn ~namespace:ns_import
         (List.rev users))
  in
  Alcotest.(check int) "порядок не важен" 0 shuffled.created;
  Alcotest.(check int) "актёров в базе" 3 (actors_of_source ns_import)

let test_import_distinguishes_human_and_agent () =
  let users = users_for ns_kind in
  ignore (get (Service.Import_actors.import_users conn ~namespace:ns_kind users));

  let kind_of_user id =
    match get (Db.Repo_actor.by_source conn ~source:ns_kind ~source_ref:id) with
    | Some actor -> actor.Actor.kind
    | None -> fail "актёр с ключом %s не импортирован" id
  in

  (* Человек: нет ни должности, ни служебного адреса. *)
  Alcotest.(check bool) "человек" true (kind_of_user (ns_kind ^ "-u-petr") = Actor.Human);
  (* Агент: должность. *)
  Alcotest.(check bool) "агент по должности" true
    (kind_of_user (ns_kind ^ "-u-analyst") = Actor.Agent);
  (* Агент: служебный адрес, должности нет. *)
  Alcotest.(check bool) "агент по адресу" true
    (kind_of_user (ns_kind ^ "-u-bot") = Actor.Agent)

let test_import_writes_aliases () =
  let users = [ List.hd (users_for ns_alias_import) ] in
  ignore
    (get (Service.Import_actors.import_users conn ~namespace:ns_alias_import users));

  let actor =
    match
      get
        (Db.Repo_actor.by_source conn ~source:ns_alias_import
           ~source_ref:(ns_alias_import ^ "-u-petr"))
    with
    | Some actor -> actor
    | None -> fail "актёр не импортирован"
  in

  (* Алиасы: логин, полное имя и имя без фамилии — по имени человека и
     зовут, а не по «Пётр Косов» (§5.3). *)
  List.iter
    (fun value ->
      let found = get (Db.Repo_actor_alias.find conn ~namespace:ns_alias_import ~value) in
      Alcotest.(check (option string)) ("алиас «" ^ value ^ "»")
        (Some actor.Actor.id)
        (Option.map (fun a -> a.Db.Repo_actor_alias.actor_id) found))
    [ ns_alias_import ^ "-petrik"; "Пётр Косов"; "Пётр" ]

(* ------------------------------------------- резолвер против базы (§5.2) --- *)

let test_resolve_finds_alias_in_own_namespace () =
  ignore
    (get
       (Db.Repo_actor_alias.add conn ~actor_id:resolver.Actor.id
          ~namespace:ns_resolve ~value:"idn-свой" ()));

  match get (Service.Resolve.resolve conn ~namespace:ns_resolve ~principal:requester ~raw:"idn-свой") with
  | Service.Resolve.Resolved { actor; new_alias } ->
      Alcotest.(check string) "найден свой алиас" resolver.Actor.id actor.Actor.id;
      Alcotest.(check (option string)) "ничего не дописывать" None new_alias
  | Service.Resolve.Placeholder _ -> fail "свой алиас не найден"

let test_resolve_by_display_name () =
  match
    get
      (Service.Resolve.resolve conn ~namespace:ns_resolve ~principal:requester
         ~raw:"idn-тестовый")
  with
  | Service.Resolve.Resolved { actor; _ } ->
      Alcotest.(check string) "найден по отображаемому имени" resolver.Actor.id
        actor.Actor.id
  | Service.Resolve.Placeholder _ -> fail "по отображаемому имени не нашлось"

let test_resolve_copies_alias_from_foreign_namespace () =
  (* Алиас лежит в чужом пространстве: резолвер находит его и дописывает в
     своё — иначе имя пришлось бы вводить заново в каждом пространстве. *)
  ignore
    (get
       (Db.Repo_actor_alias.add conn ~actor_id:resolver.Actor.id
          ~namespace:ns_foreign ~value:"idn-чужак" ()));

  let before = alias_count ns_resolve in
  match
    get
      (Service.Resolve.resolve conn ~namespace:ns_resolve ~principal:requester
         ~raw:"idn-чужак")
  with
  | Service.Resolve.Resolved { actor; new_alias } ->
      Alcotest.(check string) "найден по чужому алиасу" resolver.Actor.id
        actor.Actor.id;
      Alcotest.(check (option string)) "алиас дописан" (Some "idn-чужак") new_alias;
      Alcotest.(check int) "в своём пространстве появилась строка" (before + 1)
        (alias_count ns_resolve);
      let written =
        get (Db.Repo_actor_alias.find conn ~namespace:ns_resolve ~value:"idn-чужак")
      in
      Alcotest.(check (option string)) "алиас записан в базу"
        (Some resolver.Actor.id)
        (Option.map (fun a -> a.Db.Repo_actor_alias.actor_id) written)
  | Service.Resolve.Placeholder _ -> fail "чужой алиас не найден"

(* --------------------------------------------- заглушки (§3.1, §5.2) --- *)

let test_unknown_name_becomes_placeholder () =
  let first =
    get
      (Service.Resolve.resolve conn ~namespace:ns_placeholder ~principal:requester
         ~raw:"idn-незнакомец")
  in
  match first with
  | Service.Resolve.Placeholder { actor; raw; normalized } ->
      Alcotest.(check string) "исходное имя сохранено" "idn-незнакомец" raw;
      Alcotest.(check string) "нормализованное имя" "idn-незнакомец" normalized;
      Alcotest.(check bool) "это заглушка" true actor.Actor.unresolved;
      Alcotest.(check bool) "вид — заглушка" true (actor.Actor.kind = Actor.Placeholder);

      (* На заглушку заведён алиас: имя не потеряно, его можно найти. *)
      let alias =
        get
          (Db.Repo_actor_alias.find conn ~namespace:ns_placeholder
             ~value:"idn-незнакомец")
      in
      Alcotest.(check (option string)) "алиас заглушки" (Some actor.Actor.id)
        (Option.map (fun a -> a.Db.Repo_actor_alias.actor_id) alias);

      (* Повторный резолв находит ту же заглушку, а не заводит вторую. *)
      let placeholder_id = actor.Actor.id in
      let second =
        get
          (Service.Resolve.resolve conn ~namespace:ns_placeholder ~principal:requester
             ~raw:"idn-незнакомец")
      in
      (match second with
      | Service.Resolve.Resolved { actor; _ } ->
          Alcotest.(check string) "та же заглушка" placeholder_id actor.Actor.id;
          Alcotest.(check bool) "всё ещё заглушка" true actor.Actor.unresolved
      | Service.Resolve.Placeholder { actor; _ } ->
          Alcotest.(check string) "та же заглушка" placeholder_id actor.Actor.id)
  | Service.Resolve.Resolved { actor; _ } ->
      fail "имя без владельца разрешилось в %s" actor.Actor.handle

(* ------------------------------------------- заглушка и импорт (§5.3) --- *)

let test_placeholder_is_adopted_by_import () =
  (* Резолвер завёл заглушку для имени, которого он не знает. *)
  let placeholder =
    match
      get
        (Service.Resolve.resolve conn ~namespace:ns_adopt ~principal:requester
           ~raw:"idn-adoptee")
    with
    | Service.Resolve.Placeholder { actor; _ } -> actor
    | Service.Resolve.Resolved { actor; _ } ->
        fail "имя должно было стать заглушкой, а разрешилось в %s" actor.Actor.handle
  in
  Alcotest.(check bool) "заглушка" true placeholder.Actor.unresolved;

  (* Импорт приносит настоящего владельца этого имени. *)
  let user =
    mm_user ~id:"u-adopt" ~username:"idn-adoptee" ~first:"Анатолий" ~last:"Иванов"
      ~position:"" ~email:"anatoly@example.org"
  in
  ignore (get (Service.Import_actors.import_users conn ~namespace:ns_adopt [ user ]));

  let imported =
    match
      get (Db.Repo_actor.by_source conn ~source:ns_adopt ~source_ref:"u-adopt")
    with
    | Some actor -> actor
    | None -> fail "актёр не импортирован"
  in

  (* Заглушка превращается в настоящего актёра — тот же самый, а не новый:
     алиасы, указывающие на заглушку, остаются в силе. *)
  Alcotest.(check string) "тот же id" placeholder.Actor.id imported.Actor.id;
  Alcotest.(check bool) "больше не заглушка" false imported.Actor.unresolved;
  Alcotest.(check bool) "вид — человек" true (imported.Actor.kind = Actor.Human);

  let alias =
    get (Db.Repo_actor_alias.find conn ~namespace:ns_adopt ~value:"idn-adoptee")
  in
  Alcotest.(check (option string)) "алиас остался на месте"
    (Some placeholder.Actor.id)
    (Option.map (fun a -> a.Db.Repo_actor_alias.actor_id) alias)

(* --------------------------------------------------------------- запуск --- *)

let () =
  Alcotest.run "идентичность на базе"
    [
      ( "алиасы",
        [
          Alcotest.test_case "репозиторий алиасов" `Quick test_alias_repository;
        ] );
      ( "источник",
        [
          Alcotest.test_case "ключ (source, source_ref)" `Quick test_actor_source_key;
        ] );
      ( "импорт",
        [
          Alcotest.test_case "идемпотентность" `Quick test_import_is_idempotent;
          Alcotest.test_case "человек или агент" `Quick
            test_import_distinguishes_human_and_agent;
          Alcotest.test_case "алиасы при импорте" `Quick test_import_writes_aliases;
        ] );
      ( "резолвер",
        [
          Alcotest.test_case "свой алиас" `Quick
            test_resolve_finds_alias_in_own_namespace;
          Alcotest.test_case "по отображаемому имени" `Quick
            test_resolve_by_display_name;
          Alcotest.test_case "чужой алиас дописывается" `Quick
            test_resolve_copies_alias_from_foreign_namespace;
        ] );
      ( "заглушки",
        [
          Alcotest.test_case "неизвестное имя" `Quick
            test_unknown_name_becomes_placeholder;
          Alcotest.test_case "заглушка усыновляется импортом" `Quick
            test_placeholder_is_adopted_by_import;
        ] );
    ]
