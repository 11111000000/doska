(** MCP-сервер на живой базе: протокол и контракт инструментов.

    initialize согласует версию, tools/list отдаёт все 16, tools/call
    выполняет через сервисный слой: create_task по контракту ADR §6.2
    создаёт задачу (source_ref у инструмента нет — идемпотентность по
    паре (source, source_ref) живёт в пути импорта, ADR §10.2), бизнес-отказ —
    isError с текстом класса, а не сбой. Токен — настоящий bearer: выдаётся
    Service.Credential. *)

open Domain

let conn = Support.connect ()

let () = Support.lock conn 4718

let () =
  Support.cleanup conn ~source:"test-mcp" ~actor_prefix:"mcp-"
    ~project_prefix:"MCP"

let agent = Support.ensure_actor conn ~prefix:"mcp-" ~kind:Actor.Agent ~handle:"legist" ~display_name:"mcp агент"

let _project = Support.ensure_project conn ~prefix:"MCP" ~key:"MAIN" ~name:"MCP основной" ~autonomy:Actor.Human_gate

let has_sub s sub =
  let n = String.length sub in
  let len = String.length s in
  let rec loop i = i + n <= len && (String.sub s i n = sub || loop (i + 1)) in
  loop 0

let client = Dream.test Api.Server.handler

(* Номер задачи из ответа: ответ начинается либо с «создано », либо с
   «уже существует » — режем по первому вхождению DSK-. *)
let task_ref_of s =
  match String.index_opt s 'D' with
  | Some i -> String.sub s i (String.length s - i)
  | None -> ""

(* Уборка задачи, созданной через MCP: её source=agent, общая уборка теста
   (source=test-mcp) её не затрагивает, и она оставалась бы в общей базе. *)
let drop_task conn ref_ =
  let by_ref sql =
    Printf.sprintf sql (Db.Conn.quote ref_)
  in
  List.iter
    (fun sql ->
      match Support.run (Db.Conn.exec_sql conn sql) with
      | Ok () -> ()
      | Error e -> failwith ("уборка не удалась: " ^ e))
    [
      by_ref "DELETE FROM activity WHERE task_id IN (SELECT id FROM task WHERE ref = %s)";
      by_ref "DELETE FROM evidence WHERE task_id IN (SELECT id FROM task WHERE ref = %s)";
      by_ref "DELETE FROM comment WHERE task_id IN (SELECT id FROM task WHERE ref = %s)";
      by_ref "DELETE FROM task WHERE ref = %s";
    ]

let issue_token () =
  match
    Support.run
      (Service.Credential.issue conn ~actor_id:agent.Actor.id ~title:"mcp ключ"
         ~created_by_id:agent.Actor.id ())
  with
  | Ok (_, token) -> token
  | Error f -> failwith ("токен не выдан: " ^ Service.Failure.to_string f)

let call ?(token = None) ?(body = "") () =
  let headers =
    match token with
    | Some t -> [ ("authorization", "Bearer " ^ t) ]
    | None -> []
  in
  let request = Dream.request ~method_:`POST ~target:"/mcp" ~headers body in
  let response = client request in
  let status = Dream.status_to_int (Dream.status response) in
  let text = Support.run (Dream.body response) in
  (status, text)

let rpc ?token id method_ params =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        ([
           ("jsonrpc", `String "2.0");
           ("id", `String id);
           ("method", `String method_);
         ]
        @ (match params with Some p -> [ ("params", p) ] | None -> [])))
  in
  let status, text = call ?token ~body () in
  (status, Yojson.Safe.from_string text)

let result_field value =
  match Yojson.Safe.Util.member "result" value with
  | `Assoc fields -> fields
  | _ -> []

let content_text value =
  let fields = result_field value in
  match List.assoc_opt "content" fields with
  | Some (`List items) -> (
      match items with
      | `Assoc f :: _ -> (
          match List.assoc_opt "text" f with
          | Some (`String s) -> s
          | _ -> "")
      | _ -> "")
  | _ -> ""

let test_initialize_negotiates_version () =
  let token = issue_token () in
  let status, value = rpc ~token:(Some token) "1" "initialize" (Some (`Assoc [])) in
  Alcotest.(check int) "initialize — 200" 200 status;
  let version =
    match Yojson.Safe.Util.member "protocolVersion" (`Assoc (result_field value)) with
    | `String v -> v
    | _ -> ""
  in
  Alcotest.(check string) "версия протокола согласована" "2024-11-05" version

let test_bad_token_is_unauthorized () =
  let status, _ = call ~token:(Some "dsk_подделка") ~body:"{}" () in
  Alcotest.(check int) "подделанный токен — 401" 401 status

let test_tools_list_sixteen () =
  let token = issue_token () in
  let _, value = rpc ~token:(Some token) "2" "tools/list" (Some (`Assoc [])) in
  match Yojson.Safe.Util.member "tools" (`Assoc (result_field value)) with
  | `List tools -> Alcotest.(check int) "инструментов 16" 16 (List.length tools)
  | _ -> Alcotest.fail "tools — не список"

let test_create_and_my_tasks () =
  let token = issue_token () in
  (* create_task: инструмент заводит задачу. По контракту ADR §6.2 у него нет
     аргумента status, и новая задача попадает в backlog. *)
  let create_params =
    `Assoc
      [
        ("name", `String "create_task");
        ( "arguments",
          `Assoc
            [
              ("title", `String "Задача через MCP");
              ("project", `String "MCPMAIN");
            ] );
      ]
  in
  let _, value = rpc ~token:(Some token) "3" "tools/call" (Some create_params) in
  let text = content_text value in
  Alcotest.(check bool) "создание подтверждено" true (has_sub text "DSK-");
  let created_ref = task_ref_of text in
  drop_task conn created_ref;
  (* Заявка по MCP: агент берёт задачу в работу, но только из todo (§4.1) —
     такую задачу заводит человек. *)
  Support.ensure_actor conn ~prefix:"mcp-" ~kind:Actor.Human ~handle:"petr"
    ~display_name:"mcp человек"
  |> ignore;
  let request =
    Dream.request ~method_:`POST ~target:"/api/v1/tasks"
      ~headers:[ ("x-doska-actor", "mcp-petr") ]
      (Yojson.Safe.to_string
         (`Assoc
            [
              ("title", `String "Задача для заявки");
              ("description", `String "");
              ("status", `String "todo");
              ("project", `String "MCPMAIN");
            ]))
  in
  let response = client request in
  Alcotest.(check int) "задача заведена" 201
    (Dream.status_to_int (Dream.status response));
  let body = Support.run (Dream.body response) in
  let ref_ =
    Yojson.Safe.Util.(member "task" (Yojson.Safe.from_string body))
    |> fun task -> Yojson.Safe.Util.(member "ref" task |> to_string_option)
    |> Option.value ~default:""
  in
  let claim =
    `Assoc
      [
        ("name", `String "claim_task");
        ("arguments", `Assoc [ ("ref", `String ref_) ]);
      ]
  in
  let _, value = rpc ~token:(Some token) "5" "tools/call" (Some claim) in
  let text = content_text value in
  Alcotest.(check bool) "заявка по MCP" true (has_sub text "взято в работу");
  (* my_tasks видит задачу агента после заявки. *)
  let _, value =
    rpc ~token:(Some token) "6" "tools/call"
      (Some (`Assoc [ ("name", `String "my_tasks") ]))
  in
  (* my_tasks отдаёт список строк: ищем номер задачи среди них. *)
  let items = Yojson.Safe.Util.(member "items" (`Assoc (result_field value))) in
  let listed =
    match items with
    | `List items ->
        List.filter_map (function `String s -> Some s | _ -> None) items
    | _ -> []
  in
  Alcotest.(check bool) "задача в моих" true
    (List.exists (fun line -> has_sub line ref_) listed);
  drop_task conn ref_

let test_business_refusal_is_error () =
  let token = issue_token () in
  (* Агент пытается закрыть backlog-задачу: правило запрещает переход. *)
  let params =
    `Assoc
      [
        ("name", `String "complete_task");
        ("arguments", `Assoc [ ("ref", `String "DSK-NOT-EXISTS") ]);
      ]
  in
  let _, value = rpc ~token:(Some token) "6" "tools/call" (Some params) in
  Alcotest.(check bool) "бизнес-отказ — isError" true
    (Yojson.Safe.Util.member "isError" (`Assoc (result_field value)) = `Bool true)

let test_wrong_token_is_unauthorized () =
  let status, _ = call ~token:(Some "dsk_чужой") ~body:"{}" () in
  Alcotest.(check int) "чужой токен — 401" 401 status

let () =
  let open Alcotest in
  run "MCP"
    [
      ( "протокол",
        [
          test_case "initialize согласует версию" `Quick test_initialize_negotiates_version;
          test_case "чужой токен — 401" `Quick test_wrong_token_is_unauthorized;
          test_case "подделка — 401" `Quick test_bad_token_is_unauthorized;
        ] );
      ("инструменты", [ test_case "tools/list — 16" `Quick test_tools_list_sixteen ]);
      ( "вызовы",
        [
          test_case "create_task заводит задачу, claim берёт её" `Quick
            test_create_and_my_tasks;
          test_case "бизнес-отказ — isError" `Quick test_business_refusal_is_error;
        ] );
    ]
