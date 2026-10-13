(** HTTP 层：curl 子进程封装（本工程唯一直接碰 IO 的底层模块）。

    设计沿用 pi 项目既有约定：同步 loop + curl 外挂 HTTP，不引 lwt/cohttp。
    POST body 经 stdin 管道（--data-binary @-），避免命令行引号转义问题。

    未来想换原生 socket 实现（去 curl 依赖）时，只需重写本模块。 *)

exception Unreachable of string
(* curl 起不来 / 连不上 / 响应不是 JSON *)

let read_all fd =
  let buf = Buffer.create 65536 in
  let bytes = Bytes.create 65536 in
  let rec loop () =
    let n = Unix.read fd bytes 0 (Bytes.length bytes) in
    if n > 0 then (
      Buffer.add_subbytes buf bytes 0 n;
      loop ())
  in
  (try loop () with _ -> ());
  Buffer.contents buf

let write_all fd s =
  let len = String.length s in
  let rec loop off =
    if off < len then
      let n = Unix.write_substring fd s off (len - off) in
      if n > 0 then loop (off + n)
  in
  loop 0

(* 运行 curl；返回 (exit_code, stdout, stderr)。body=None 表示 GET。 *)
let run_curl ~args ~body =
  let curl = Config.curl_path () in
  let argv = Array.of_list (curl :: args) in
  let in_r, in_w = Unix.pipe () in
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  (* Windows 关键修复：in_w（父进程写 body 的那端）必须标记为不可继承。
     CreateProcess(bInheritHandles=TRUE) 会无差别继承"可继承句柄"——
     若 in_w 被 curl 继承，curl 读 stdin（--data-binary @-）永远等不到
     EOF（它自己就持有写端副本），POST 请求死锁。
     set_close_on_exec 在 win32 上即 SetHandleInformation(HANDLE_FLAG_INHERIT, 0)。 *)
  Unix.set_close_on_exec in_w;
  let close fds = List.iter (fun fd -> try Unix.close fd with _ -> ()) fds in
  let pid =
    try Unix.create_process curl argv in_r out_w err_w
    with e ->
      close [ in_r; in_w; out_r; out_w; err_r; err_w ];
      raise
        (Unreachable
           (Printf.sprintf "无法启动 curl（%s）：%s" curl (Printexc.to_string e)))
  in
  Unix.close in_r;
  Unix.close out_w;
  Unix.close err_w;
  Config.debug "curl 已启动 pid=%d args=%s" pid (String.concat " " args);
  (match body with
  | Some b ->
      Config.debug "写 body（%d 字节）到 curl stdin..." (String.length b);
      (try write_all in_w b with _ -> ());
      Config.debug "body 写完"
  | None -> ());
  Unix.close in_w;
  Config.debug "stdin 已关闭（送 EOF），开始读 stdout...";
  let out = read_all out_r in
  Config.debug "stdout 读完（%d 字节），开始读 stderr..." (String.length out);
  let err = read_all err_r in
  Config.debug "stderr 读完（%d 字节）" (String.length err);
  Unix.close out_r;
  Unix.close err_r;
  Config.debug "等待 curl 退出...";
  let _, status = Unix.waitpid [] pid in
  Config.debug "curl 已退出";
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> -1
  in
  (code, out, err)

(* base args：--noproxy '*' 是关键——本机桥接服务（localhost）绝不能走代理。
   理由（实测踩坑）：Windows/企业环境常注入 http_proxy/https_proxy 环境变量，
   curl 默认会把这些应用到 localhost 请求上；一旦代理连不上 upstream
   （游戏未开/端口变化），返回的是代理自己的错误文本（可能非 UTF-8），
   我们的 JSON 解析、错误呈现全部被污染。直连永远最干净。 *)
let base_args ~max_time =
  [ "-sS"; "--noproxy"; "*"; "--max-time"; string_of_int max_time ]

let get ?(max_time = 15) url =
  let args = base_args ~max_time @ [ url ] in
  let code, out, err = run_curl ~args ~body:None in
  if code <> 0 then
    raise
      (Unreachable
         (Printf.sprintf "curl 退出码 %d：%s" code (String.trim err)))
  else out

let post_json ?(max_time = 15) url body =
  let args =
    base_args ~max_time
    @ [ "-X"; "POST"; "-H"; "Content-Type: application/json"; "--data-binary"; "@-"; url ]
  in
  let code, out, err = run_curl ~args ~body:(Some body) in
  if code <> 0 then
    raise
      (Unreachable
         (Printf.sprintf "curl 退出码 %d：%s" code (String.trim err)))
  else out

(* 按 UTF-8 字符边界安全截断（不切断多字节字符，避免产生非法 UTF-8 输出）。
   踩坑背景：曾用 String.sub s 0 200 截断错误消息，当第 200 字节恰好落在
   多字节字符中间时，输出非法 UTF-8，导致 MCP 客户端解码崩溃。 *)
let safe_prefix (s : string) (max_bytes : int) : string =
  if String.length s <= max_bytes then s
  else begin
    let cut = ref max_bytes in
    while !cut > 0 && Char.code s.[!cut] land 0xC0 = 0x80 do
      decr cut
    done;
    String.sub s 0 !cut
  end

(* 简易 UTF-8 清洗：把非法字节序列替换为 '?'。
   输出（MCP stdout）必须是合法 UTF-8——外部数据（curl 响应、系统错误文本）
   可能夹带非 UTF-8 字节，凡是要透传给客户端的文本先过一次清洗。 *)
let sanitize_utf8 (s : string) : string =
  let b = Bytes.of_string s in
  let n = Bytes.length b in
  let out = Buffer.create n in
  let is_cont c = Char.code c land 0xC0 = 0x80 in
  let i = ref 0 in
  while !i < n do
    let k = Char.code (Bytes.get b !i) in
    let need =
      if k < 0x80 then 0
      else if k >= 0xC2 && k <= 0xDF then 1
      else if k >= 0xE0 && k <= 0xEF then 2
      else if k >= 0xF0 && k <= 0xF4 then 3
      else -1
    in
    let seq_ok =
      need >= 0 && !i + need < n
      &&
      let ok = ref true in
      for j = !i + 1 to !i + need do
        if not (is_cont (Bytes.get b j)) then ok := false
      done;
      !ok
    in
    if seq_ok then begin
      Buffer.add_subbytes out b !i (need + 1);
      i := !i + need + 1
    end
    else begin
      Buffer.add_char out '?';
      incr i
    end
  done;
  Buffer.contents out

let parse_or_fail s =
  match Yojson.Safe.from_string s with
  | j -> j
  | exception Yojson.Json_error e ->
      let shown =
        if String.length s > 200 then safe_prefix s 200 ^ "..." else s
      in
      raise
        (Unreachable
           (Printf.sprintf "响应不是有效 JSON（%s）：%s" e
              (sanitize_utf8 shown)))

let get_json ?(max_time = 15) url = get ~max_time url |> parse_or_fail
let post_json_json ?(max_time = 15) url body = post_json ~max_time url body |> parse_or_fail
