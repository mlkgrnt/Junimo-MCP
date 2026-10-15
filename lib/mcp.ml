(** MCP 协议核心：initialize / tools list / tools call / notifications。

    传输：stdio，一行一条 JSON 消息。
    纪律：stdout 只写协议消息；一切日志走 stderr（见 Config.log）。 *)

let server_name = "junimo-mcp"
let server_version = "3.2.1"
let default_protocol = "2024-11-05"

let handle_initialize (params : Yojson.Safe.t option) : Yojson.Safe.t =
  let protocol =
    match params with
    | Some (`Assoc f) -> (
        match List.assoc_opt "protocolVersion" f with
        | Some (`String v) -> v
        | _ -> default_protocol)
    | _ -> default_protocol
  in
  `Assoc
    [
      ("protocolVersion", `String protocol);
      ("capabilities", `Assoc [ ("tools", `Assoc []) ]);
      ( "serverInfo",
        `Assoc [ ("name", `String server_name); ("version", `String server_version) ]
      );
    ]

let tool_result text is_error : Yojson.Safe.t =
  `Assoc
    [
      ( "content",
        `List [ `Assoc [ ("type", `String "text"); ("text", `String text) ] ] );
      ("isError", `Bool is_error);
    ]

let handle_tools_call (params : Yojson.Safe.t option) : (Yojson.Safe.t, string) result =
  match params with
  | Some (`Assoc f) -> (
      match List.assoc_opt "name" f with
      | Some (`String name) ->
          let args =
            match List.assoc_opt "arguments" f with Some j -> j | None -> `Assoc []
          in
          Ok
            (match Intents.call name args with
            | Ok text -> tool_result text false
            | Error text -> tool_result text true)
      | _ -> Error "tools/call 缺少 name 参数")
  | _ -> Error "tools/call 缺少 params"

(** 处理一行消息。返回需要写回 stdout 的行；notification 返回 None。 *)
let handle_message (line : string) : string option =
  match Jsonrpc.parse line with
  | Error (id, code, msg) -> Some (Jsonrpc.err_response id code msg)
  | Ok req -> (
      Config.debug "收到请求: method=%s id=%s" req.meth
        (match req.id with Some j -> Yojson.Safe.to_string j | None -> "(notification)");
      match req.meth with
      | "initialize" ->
          Some (Jsonrpc.ok_response req.id (handle_initialize req.params))
      | "notifications/initialized" ->
          Config.info "客户端握手完成（notifications/initialized）";
          None
      | "ping" -> Some (Jsonrpc.ok_response req.id (`Assoc []))
      | "tools/list" -> Some (Jsonrpc.ok_response req.id (Intents.list_json ()))
      | "tools/call" -> (
          match handle_tools_call req.params with
          | Ok result -> Some (Jsonrpc.ok_response req.id result)
          | Error msg ->
              Some (Jsonrpc.err_response req.id Jsonrpc.err_invalid_params msg))
      | m -> (
          match req.id with
          | Some _ ->
              Some
                (Jsonrpc.err_response req.id Jsonrpc.err_method_not_found
                   ("未知方法：" ^ m))
          | None -> None (* 未知 notification 直接忽略 *)))
