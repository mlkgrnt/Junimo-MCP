(* JSON-RPC 编解码单测（无依赖手写断言）。 *)

open Stardew_mcp

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (
    incr failures;
    Printf.printf "FAIL - %s\n" name)

let () =
  (* parse: 正常请求 *)
  (match Jsonrpc.parse {|{"jsonrpc":"2.0","id":1,"method":"initialize"}|} with
  | Ok r ->
      check "parse: method" (r.meth = "initialize");
      check "parse: number id" (r.id = Some (`Int 1))
  | Error _ -> check "parse: 正常请求" false);
  (* parse: notification（无 id） *)
  (match Jsonrpc.parse {|{"jsonrpc":"2.0","method":"notifications/initialized"}|} with
  | Ok r -> check "parse: notification id=None" (r.id = None)
  | Error _ -> check "parse: notification" false);
  (* parse: string id 与 params *)
  (match Jsonrpc.parse {|{"jsonrpc":"2.0","id":"abc","method":"x","params":{"a":1}}|} with
  | Ok r -> (
      check "parse: string id" (r.id = Some (`String "abc"));
      check "parse: params" (r.params <> None))
  | Error _ -> check "parse: string id" false);
  (* parse: 显式 null id *)
  (match Jsonrpc.parse {|{"jsonrpc":"2.0","id":null,"method":"x"}|} with
  | Ok r -> check "parse: null id 视为有 id" (r.id = Some `Null)
  | Error _ -> check "parse: null id" false);
  (* parse: 缺 method，id 可提取 *)
  (match Jsonrpc.parse {|{"jsonrpc":"2.0","id":7}|} with
  | Error (Some (`Int 7), code, _) ->
      check "parse: 缺method带id" (code = Jsonrpc.err_invalid_request)
  | _ -> check "parse: 缺method带id" false);
  (* parse: 非法 JSON *)
  (match Jsonrpc.parse "not json" with
  | Error (None, code, _) -> check "parse: 非法JSON" (code = Jsonrpc.err_parse)
  | _ -> check "parse: 非法JSON" false);
  (* parse: 顶层非对象 *)
  (match Jsonrpc.parse "[1,2,3]" with
  | Error (None, code, _) ->
      check "parse: 顶非对象" (code = Jsonrpc.err_invalid_request)
  | _ -> check "parse: 顶非对象" false);
  (* ok_response：结构 + id 回显 *)
  let r = Jsonrpc.ok_response (Some (`Int 42)) (`Assoc [ ("a", `Int 1) ]) in
  let j = Yojson.Safe.from_string r in
  check "ok_response: id" (Game_state.get_int j [ "id" ] = 42);
  check "ok_response: jsonrpc 2.0" (Game_state.get_str j [ "jsonrpc" ] = "2.0");
  check "ok_response: result" (Game_state.get_int j [ "result"; "a" ] = 1);
  (* err_response：结构 + null id *)
  let r = Jsonrpc.err_response None Jsonrpc.err_method_not_found "no" in
  let j = Yojson.Safe.from_string r in
  check "err_response: code" (Game_state.get_int j [ "error"; "code" ] = -32601);
  check "err_response: id null" (Game_state.member "id" j = Some `Null);
  (* 响应一行化（无换行） *)
  let r2 = Jsonrpc.ok_response (Some (`Int 1)) (`Assoc []) in
  check "响应无换行" (not (String.contains r2 '\n'));
  Printf.printf "\ntest_jsonrpc: %s\n"
    (if !failures = 0 then "ALL PASS"
     else Printf.sprintf "%d FAILURE(S)" !failures);
  if !failures > 0 then exit 1
