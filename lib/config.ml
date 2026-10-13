(** 配置：环境变量读取 + 日志。

    | 变量            | 默认                     | 说明                     |
    |-----------------|--------------------------|--------------------------|
    | STARDEW_API_URL | http://localhost:7842    | NagiBridge 地址          |
    | STARDEW_CURL    | 自动探测                 | curl.exe 路径覆盖        |
    | STARDEW_TIMEOUT | 30                       | 轮询总超时（秒）         |
    | STARDEW_NO_STRIP| 未设                     | 设 1 关闭状态速报        |
    | STARDEW_LOG     | warn                     | stderr 日志 debug/info/warn |

    注意：必须使用 localhost 而不是 127.0.0.1——NagiBridge 只注册了
    http://localhost:<port>/ 前缀，访问 127.0.0.1 会被 HTTP.sys 400 拒绝。 *)

let getenv name default =
  match Sys.getenv_opt name with
  | Some v when v <> "" -> v
  | _ -> default

(* ---------- 日志（仅 stderr；stdout 是 MCP 协议通道，绝不能碰） ---------- *)

type log_level = Debug | Info | Warn

let level_of_string = function
  | "debug" -> Debug
  | "info" -> Info
  | _ -> Warn

let level_to_int = function Debug -> 0 | Info -> 1 | Warn -> 2
let current_level = ref Warn

let log lvl fmt =
  Printf.ksprintf
    (fun msg ->
      if level_to_int lvl >= level_to_int !current_level then
        prerr_endline ("[junimo-mcp] " ^ msg))
    fmt

let debug fmt = log Debug fmt
let info fmt = log Info fmt
let warn fmt = log Warn fmt

(* ---------- 配置项 ---------- *)

let api_url () = getenv "STARDEW_API_URL" "http://localhost:7842"

let curl_path () =
  match Sys.getenv_opt "STARDEW_CURL" with
  | Some v when v <> "" -> v
  | _ ->
      let candidates =
        [ "C:\\Windows\\System32\\curl.exe"; "C:/Windows/System32/curl.exe"; "curl" ]
      in
      let exists p = try Sys.file_exists p with _ -> false in
      (match List.find_opt exists candidates with Some p -> p | None -> "curl")

let timeout_secs () =
  match Sys.getenv_opt "STARDEW_TIMEOUT" with
  | Some v -> (
      match int_of_string_opt v with Some n when n > 0 -> n | _ -> 30)
  | None -> 30

let no_strip () = Sys.getenv_opt "STARDEW_NO_STRIP" = Some "1"

let init () =
  current_level := level_of_string (String.lowercase_ascii (getenv "STARDEW_LOG" "warn"))
