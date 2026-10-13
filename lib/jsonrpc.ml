(** JSON-RPC 2.0 编解码（MCP 所用子集）。

    - 输入：一行 JSON 文本。
    - 输出：一行 JSON 文本（无响应时返回 None，即 notification）。 *)

type request = {
  id : Yojson.Safe.t option; (* None = notification（无 id 字段） *)
  meth : string;
  params : Yojson.Safe.t option;
}

(* 标准错误码 *)
let err_parse = -32700
let err_invalid_request = -32600
let err_method_not_found = -32601
let err_invalid_params = -32602
let err_internal = -32603

let parse (line : string) :
    (request, Yojson.Safe.t option * int * string) result =
  match Yojson.Safe.from_string line with
  | `Assoc fields -> (
      let id = List.assoc_opt "id" fields in
      match List.assoc_opt "method" fields with
      | Some (`String meth) ->
          Ok { id; meth; params = List.assoc_opt "params" fields }
      | _ -> Error (id, err_invalid_request, "缺少 method 字段或类型不对"))
  | _ -> Error (None, err_invalid_request, "顶层不是 JSON 对象")
  | exception Yojson.Json_error e -> Error (None, err_parse, "JSON 解析失败: " ^ e)

let id_field = function Some i -> [ ("id", i) ] | None -> [ ("id", `Null) ]

let ok_response id (result : Yojson.Safe.t) : string =
  `Assoc ([ ("jsonrpc", `String "2.0") ] @ id_field id @ [ ("result", result) ])
  |> Yojson.Safe.to_string

let err_response id code message : string =
  `Assoc
    ([ ("jsonrpc", `String "2.0") ]
    @ id_field id
    @ [
        ( "error",
          `Assoc [ ("code", `Int code); ("message", `String message) ] );
      ])
  |> Yojson.Safe.to_string
