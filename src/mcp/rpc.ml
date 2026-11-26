(* JSON-RPC 2.0: сборка ответов и ошибок. *)

let ok id result = `Assoc [ ("jsonrpc", `String "2.0"); ("id", id); ("result", result) ]

let error id code message =
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", id);
      ("error", `Assoc [ ("code", `Int code); ("message", `String message) ]);
    ]

(* Коды протокола: parse-error, invalid-request, method-not-found,
   invalid-params, internal-error — стандарт JSON-RPC 2.0. *)
let parse_error = -32700
let invalid_request = -32600
let method_not_found = -32601
let invalid_params = -32602
let internal_error = -32603
