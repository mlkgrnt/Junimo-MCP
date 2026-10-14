(** HTTP 层：原生 socket + keep-alive（默认），或 curl 子进程（回退）。

    历史：本模块原本是「每次请求起一个 curl 进程」的封装（沿用 pi 项目约定）。
    2026-10-14 性能实测：本机**进程创建 151ms**，而真 mod 的 HTTP 往返只有
    0–40ms ⇒ 每次请求的成本几乎全是自家的架构税。改为原生连接复用后：
      - 单请求 ~150ms → ~1–3ms（本机 loopback）
      - 不再读 *_proxy 环境变量（历史踩坑：代理劫持 localhost 请求，返回非 JSON 文本）
      - 不再依赖系统 curl（少一个部署前提）

    协议：HTTP/1.1 + keep-alive；响应体支持 Content-Length / chunked / 读到 EOF。
    - 连接建立或发送**前**失败 → 自动重连重试一次（安全）；
    - 已发出但读响应失败：GET 可安全重试一次；**POST 不重试**（避免动作重复执行，
      代价是偶发假失败——工具本就可安全重试）。
    - 空闲超过 5s 的连接主动重连（规避对端 keep-alive 超时带来的陈旧连接）。

    回退：STARDEW_HTTP=curl 走旧实现（排查/对照用）。 *)

exception Unreachable of string

(* ---------- URL 解析（只支持 http://host[:port][/path?query]） ---------- *)

let parse_url (url : string) : string * int * string =
  let lp = String.length "http://" in
  if String.length url < lp || String.sub url 0 lp <> "http://" then
    raise (Unreachable (Printf.sprintf "不支持的 URL（只支持 http://）：%s" url))
  else
    let rest = String.sub url lp (String.length url - lp) in
    let host_port, target =
      match String.index_opt rest '/' with
      | Some i -> (String.sub rest 0 i, String.sub rest i (String.length rest - i))
      | None -> (rest, "/")
    in
    let host, port =
      match String.index_opt host_port ':' with
      | Some i ->
          let p = int_of_string_opt (String.sub host_port (i + 1) (String.length host_port - i - 1)) in
          (String.sub host_port 0 i, match p with Some p -> p | None -> 80)
      | None -> (host_port, 80)
    in
    (host, port, target)

(* ---------- 连接管理 ---------- *)

let idle_limit = 5.0
(* 空闲超过这个秒数的连接主动重连（对端 keep-alive 可能已经关了） *)

let conn : (string * int * Unix.file_descr) option ref = ref None
let last_used = ref 0.0

let close_conn () =
  (match !conn with
  | Some (_, _, fd) -> (try Unix.close fd with _ -> ())
  | None -> ());
  conn := None

(* 解析主机 → （域, 地址）。IPv4 优先：NagiBridge 的 HttpListener 只注册了
   localhost 前缀，连接走 127.0.0.1、Host 头写 localhost（与 curl 行为一致）。 *)
let resolve (host : string) (port : int) : Unix.socket_domain * Unix.sockaddr =
  let addrs =
    try Unix.getaddrinfo host (string_of_int port) [ Unix.AI_SOCKTYPE Unix.SOCK_STREAM ]
    with _ -> []
  in
  let pick =
    match List.find_opt (fun (ai : Unix.addr_info) -> ai.Unix.ai_family = Unix.PF_INET) addrs with
    | Some ai -> Some ai
    | None -> (match addrs with ai :: _ -> Some ai | [] -> None)
  in
  match pick with
  | Some ai -> (ai.Unix.ai_family, ai.Unix.ai_addr)
  | None -> raise (Unreachable (Printf.sprintf "无法解析主机 %s:%d" host port))

let connect (host : string) (port : int) ~(timeout : float) : Unix.file_descr =
  ignore timeout;
  let domain, addr = resolve host port in
  let fd = Unix.socket domain Unix.SOCK_STREAM 0 in
  (try Unix.set_close_on_exec fd with _ -> ());
  (* ⚠️ 不用 SO_RCVTIMEO/SO_SNDTIMEO：OCaml 文档说单位是秒，但 Windows 实现实际按
     毫秒生效（实测：设 30.0 → 约 30ms 就 ETIMEDOUT，响应稍慢的端点必炸）。
     超时一律走 Unix.select 显式截止时间（见 read_with_deadline / send_all_socket）。 *)
  (try Unix.connect fd addr
   with e ->
     (try Unix.close fd with _ -> ());
     raise
       (Unreachable (Printf.sprintf "无法连接 %s:%d（%s）" host port (Printexc.to_string e))));
  fd

let ensure_conn (host : string) (port : int) (timeout : float) : Unix.file_descr =
  match !conn with
  | Some (h, p, fd) when h = host && p = port && Unix.gettimeofday () -. !last_used < idle_limit -> fd
  | _ ->
      close_conn ();
      let fd = connect host port ~timeout in
      conn := Some (host, port, fd);
      last_used := Unix.gettimeofday ();
      fd

(* ---------- 读写 ---------- *)

let write_all fd s =
  let len = String.length s in
  let rec loop off =
    if off < len then
      let n = Unix.write_substring fd s off (len - off) in
      if n > 0 then loop (off + n)
  in
  loop 0

let find_sub_from (hay : string) (needle : string) (from : int) : int option =
  let nl = String.length needle and hl = String.length hay in
  let rec go i =
    if i + nl > hl then None else if String.sub hay i nl = needle then Some i else go (i + 1)
  in
  go from

let contains_sub (hay : string) (needle : string) : bool =
  match find_sub_from hay needle 0 with Some _ -> true | None -> false

(* ---------- 带截止时间的读写（Windows 上 SO_*TIMEO 单位不可靠，统一用 select） ---------- *)

let read_with_deadline (fd : Unix.file_descr) (buf : Bytes.t) (off : int) (len : int) (deadline : float) : int =
  let remain = deadline -. Unix.gettimeofday () in
  if remain <= 0.0 then raise (Unreachable "读取超时（对端未在超时内返回响应）");
  let r, _, _ =
    try Unix.select [ fd ] [] [] remain
    with e -> raise (Unreachable (Printf.sprintf "等待响应失败：%s" (Printexc.to_string e)))
  in
  if r = [] then raise (Unreachable "读取超时（对端未在超时内返回响应）")
  else
    try Unix.read fd buf off len
    with e -> raise (Unreachable (Printf.sprintf "读取响应失败：%s" (Printexc.to_string e)))

let send_all_socket (fd : Unix.file_descr) (s : string) (deadline : float) : unit =
  let len = String.length s in
  let rec loop off =
    if off < len then begin
      let remain = deadline -. Unix.gettimeofday () in
      if remain <= 0.0 then raise (Unreachable "发送超时");
      let _, w, _ = Unix.select [] [ fd ] [] remain in
      if w = [] then raise (Unreachable "发送超时");
      let n = Unix.write_substring fd s off (len - off) in
      if n > 0 then loop (off + n)
    end
  in
  loop 0

type resp = {
  status : int;
  http10 : bool;
  headers : (string * string) list;
  body : string;
  keep_alive : bool;
}

let read_response ~(deadline : float) (fd : Unix.file_descr) : resp =
  let chunk = Bytes.create 16384 in
  let buf = Buffer.create 8192 in
  let rec read_headers () =
    match find_sub_from (Buffer.contents buf) "\r\n\r\n" 0 with
    | Some i -> i
    | None ->
        let n = read_with_deadline fd chunk 0 (Bytes.length chunk) deadline in
        if n <= 0 then raise (Unreachable "连接被对端关闭（读取响应头时）");
        Buffer.add_subbytes buf chunk 0 n;
        read_headers ()
  in
  let hdr_end = read_headers () in
  let full = Buffer.contents buf in
  let head = String.sub full 0 hdr_end in
  let pending = ref (String.sub full (hdr_end + 4) (String.length full - hdr_end - 4)) in
  let lines = String.split_on_char '\n' head |> List.map String.trim in
  let first = match lines with l :: _ -> l | [] -> "" in
  let status =
    match String.split_on_char ' ' first with
    | _ :: code :: _ -> (match int_of_string_opt code with Some c -> c | None -> 0)
    | _ -> 0
  in
  let http10 = String.length first >= 8 && String.sub first 0 8 = "HTTP/1.0" in
  let headers =
    match lines with
    | [] | [ _ ] -> []
    | _ :: rest ->
        List.filter_map
          (fun l ->
            match String.index_opt l ':' with
            | Some i ->
                Some
                  ( String.lowercase_ascii (String.trim (String.sub l 0 i)),
                    String.trim (String.sub l (i + 1) (String.length l - i - 1)) )
            | None -> None)
          rest
  in
  let get k = List.assoc_opt k headers in
  let read_exact n =
    let b = Buffer.create n in
    let take = min n (String.length !pending) in
    Buffer.add_string b (String.sub !pending 0 take);
    pending := String.sub !pending take (String.length !pending - take);
    while Buffer.length b < n do
      let need = n - Buffer.length b in
      let tmp = Bytes.create (min 65536 need) in
      let got = read_with_deadline fd tmp 0 (Bytes.length tmp) deadline in
      if got <= 0 then raise (Unreachable "连接被对端关闭（读取响应体时）");
      Buffer.add_subbytes b tmp 0 got
    done;
    Buffer.contents b
  in
  let read_line_crlf () =
    let rec go () =
      match find_sub_from !pending "\r\n" 0 with
      | Some i ->
          let line = String.sub !pending 0 i in
          pending := String.sub !pending (i + 2) (String.length !pending - i - 2);
          line
      | None ->
          let tmp = Bytes.create 4096 in
          let got = read_with_deadline fd tmp 0 4096 deadline in
          if got <= 0 then raise (Unreachable "连接被对端关闭（读取分块长度时）");
          pending := !pending ^ Bytes.sub_string tmp 0 got;
          go ()
    in
    go ()
  in
  let read_until_eof () =
    let b = Buffer.create 4096 in
    Buffer.add_string b !pending;
    pending := "";
    let tmp = Bytes.create 65536 in
    let rec go () =
      let got = try read_with_deadline fd tmp 0 (Bytes.length tmp) deadline with Unreachable _ -> 0 in
      if got > 0 then begin
        Buffer.add_subbytes b tmp 0 got;
        go ()
      end
    in
    go ();
    Buffer.contents b
  in
  let chunked =
    match get "transfer-encoding" with
    | Some v -> contains_sub (String.lowercase_ascii v) "chunked"
    | None -> false
  in
  let body, exact_len =
    if chunked then begin
      let out = Buffer.create 4096 in
      let rec next () =
        let line = read_line_crlf () in
        let size_str =
          match String.index_opt line ';' with Some i -> String.sub line 0 i | None -> line
        in
        let size =
          match int_of_string_opt ("0x" ^ String.trim size_str) with Some s -> s | None -> 0
        in
        if size = 0 then ignore (read_line_crlf ())
        else begin
          Buffer.add_string out (read_exact size);
          ignore (read_line_crlf ());
          next ()
        end
      in
      next ();
      (Buffer.contents out, true)
    end
    else
      match get "content-length" with
      | Some v -> (
          match int_of_string_opt (String.trim v) with
          | Some n -> (read_exact n, true)
          | None -> (read_until_eof (), false))
      | None -> (read_until_eof (), false)
  in
  let conn_hdr = Option.map String.lowercase_ascii (get "connection") in
  let keep_alive =
    match conn_hdr with Some v when v = "close" -> false | _ -> (not http10) && exact_len
  in
  { status; http10; headers; body; keep_alive }

(* ---------- 单次请求（native） ---------- *)

type outcome = Ok_body of string | Failed_unsent of string | Failed_sent of string

let native_request ~(method_ : string) ~(url : string) ~(body : string option) ~(timeout : float) : string =
  let host, port, target = parse_url url in
  let req =
    let base =
      [
        Printf.sprintf "%s %s HTTP/1.1" method_ target;
        Printf.sprintf "Host: %s:%d" host port;
        "Connection: keep-alive";
        "User-Agent: junimo-mcp";
        "Accept: */*";
      ]
    in
    let with_body =
      match body with
      | Some b ->
          base
          @ [ "Content-Type: application/json"; Printf.sprintf "Content-Length: %d" (String.length b) ]
      | None -> base
    in
    String.concat "\r\n" with_body ^ "\r\n\r\n"
    ^ (match body with Some b -> b | None -> "")
  in
  let one_attempt () : outcome =
    let deadline = Unix.gettimeofday () +. timeout in
    match (try Ok (ensure_conn host port timeout) with e -> Error (Printexc.to_string e)) with
    | Error m -> Failed_unsent m
    | Ok fd ->
        let sent = ref false in
        let t0 = Unix.gettimeofday () in
        (try
           send_all_socket fd req deadline;
           sent := true;
           let r = read_response ~deadline fd in
           if not r.keep_alive then close_conn () else last_used := Unix.gettimeofday ();
           Config.debug "HTTP %s %s → %d（%d 字节, keep_alive=%b, %.0fms）" method_ target r.status
             (String.length r.body) r.keep_alive
             ((Unix.gettimeofday () -. t0) *. 1000.);
           Ok_body r.body
         with e ->
           close_conn ();
           let m = match e with Unreachable s -> s | e -> Printexc.to_string e in
           Config.debug "HTTP %s %s 失败（已发出=%b, %.0fms）：%s" method_ target !sent
             ((Unix.gettimeofday () -. t0) *. 1000.) m;
           if !sent then Failed_sent m else Failed_unsent m)
  in
  match one_attempt () with
  | Ok_body b -> b
  | Failed_unsent _ -> (
      (* 连接没建立或请求没发出去 → 重连再试一次（安全） *)
      match one_attempt () with
      | Ok_body b -> b
      | Failed_unsent m | Failed_sent m -> raise (Unreachable m))
  | Failed_sent m ->
      if String.uppercase_ascii method_ = "GET" then
        (* GET 幂等 → 可安全重试一次 *)
        match one_attempt () with
        | Ok_body b -> b
        | Failed_unsent m2 | Failed_sent m2 ->
            raise (Unreachable (Printf.sprintf "%s；重试后仍失败：%s" m m2))
      else raise (Unreachable m)

(* ---------- 单次请求（curl 回退路径，保留旧行为） ---------- *)

let base_args ~max_time = [ "-sS"; "--noproxy"; "*"; "--max-time"; string_of_int max_time ]

let read_all_fd fd =
  let buf = Buffer.create 65536 in
  let bytes = Bytes.create 65536 in
  let rec loop () =
    let n = try Unix.read fd bytes 0 (Bytes.length bytes) with _ -> 0 in
    if n > 0 then begin
      Buffer.add_subbytes buf bytes 0 n;
      loop ()
    end
  in
  loop ();
  Buffer.contents buf

let run_curl ~args ~body =
  let curl = Config.curl_path () in
  let argv = Array.of_list (curl :: args) in
  let in_r, in_w = Unix.pipe () in
  let out_r, out_w = Unix.pipe () in
  let err_r, err_w = Unix.pipe () in
  (* Windows：in_w 必须不可继承，否则 curl 攥着写端会让 --data-binary @- 等不到 EOF *)
  Unix.set_close_on_exec in_w;
  let close fds = List.iter (fun fd -> try Unix.close fd with _ -> ()) fds in
  let pid =
    try Unix.create_process curl argv in_r out_w err_w
    with e ->
      close [ in_r; in_w; out_r; out_w; err_r; err_w ];
      raise (Unreachable (Printf.sprintf "无法启动 curl（%s）：%s" curl (Printexc.to_string e)))
  in
  Unix.close in_r;
  Unix.close out_w;
  Unix.close err_w;
  (match body with Some b -> (try write_all in_w b with _ -> ()) | None -> ());
  Unix.close in_w;
  let out = read_all_fd out_r in
  let err = read_all_fd err_r in
  Unix.close out_r;
  Unix.close err_r;
  let _, status = Unix.waitpid [] pid in
  let code = match status with Unix.WEXITED c -> c | _ -> -1 in
  if code <> 0 then
    raise (Unreachable (Printf.sprintf "curl 退出码 %d：%s" code (String.trim err)))
  else out

let curl_request ~(method_ : string) ~(url : string) ~(body : string option) ~(max_time : int) : string =
  let args =
    match body with
    | Some _ ->
        base_args ~max_time
        @ [ "-X"; method_; "-H"; "Content-Type: application/json"; "--data-binary"; "@-"; url ]
    | None -> if method_ = "GET" then base_args ~max_time @ [ url ] else base_args ~max_time @ [ "-X"; method_; url ]
  in
  run_curl ~args ~body

(* ---------- 统一入口 ---------- *)

let request ~(method_ : string) ~(url : string) ~(body : string option) ~(max_time : int) : string =
  if String.lowercase_ascii (Config.http_impl ()) = "curl" then
    curl_request ~method_ ~url ~body ~max_time
  else native_request ~method_ ~url ~body ~timeout:(float_of_int max_time)

let get ?max_time url =
  let max_time = match max_time with Some t -> t | None -> Config.http_timeout () in
  request ~method_:"GET" ~url ~body:None ~max_time

let post_json ?max_time url body =
  let max_time = match max_time with Some t -> t | None -> Config.http_timeout () in
  request ~method_:"POST" ~url ~body:(Some body) ~max_time

(* ---------- 文本清洗与解析（沿用旧实现） ---------- *)

(* 按 UTF-8 字符边界安全截断（不切断多字节字符，避免产生非法 UTF-8 输出）。 *)
let safe_prefix (s : string) (max_bytes : int) : string =
  if String.length s <= max_bytes then s
  else begin
    let cut = ref max_bytes in
    while !cut > 0 && Char.code s.[!cut] land 0xC0 = 0x80 do
      decr cut
    done;
    String.sub s 0 !cut
  end

(* 简易 UTF-8 清洗：把非法字节序列替换为 '?'。 *)
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
      let shown = if String.length s > 200 then safe_prefix s 200 ^ "..." else s in
      raise
        (Unreachable
           (Printf.sprintf "响应不是有效 JSON（%s）：%s" e (sanitize_utf8 shown)))

let get_json ?max_time url = get ?max_time url |> parse_or_fail
let post_json_json ?max_time url body = post_json ?max_time url body |> parse_or_fail
