(** 配置：环境变量读取 + 日志。

    | 变量            | 默认                     | 说明                     |
    |-----------------|--------------------------|--------------------------|
    | STARDEW_API_URL | http://localhost:7842    | NagiBridge 地址          |
    | STARDEW_CURL    | 自动探测                 | curl.exe 路径覆盖        |
    | STARDEW_TIMEOUT | 30                       | 轮询总超时（秒）         |
    | STARDEW_HTTP | native                      | HTTP 实现：native / curl |
    | STARDEW_HTTP_TIMEOUT | 30                 | 单次 HTTP 调用超时（秒） |
    | STARDEW_SETTLE | 自适应                    | 结算等待；NNN 固定毫秒 / fixed=550 |
    | STARDEW_WALK    | walk                     | go_to 实现：walk(/walk_to) / move(分段接力) |
    | STARDEW_AREA    | auto                     | till/water 是否走 /tool_area 批量：auto/force/off |
    | STARDEW_AREA_MIN| 4                        | /tool_area 最少作用格数（低于此值逐格） |
    | STARDEW_AREA_TIMEOUT | 90                 | /tool_area 单次等待上限（秒） |
    | STARDEW_AUTO_MENU | 1                      | 自动推进"无选项对话"（NPC 招呼等） |
    | STARDEW_AUTO_EVENT | 未设                  | 设 1 = 剧本事件自动跳过（默认不跳） |
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

(** HTTP 层实现：native（默认：原生 socket + keep-alive）/ curl（旧路径，回退与对照用）。
    切换见 README 环境变量表。 *)
let http_impl () = String.lowercase_ascii (getenv "STARDEW_HTTP" "native")

(** HTTP 层：单次请求的最大等待（秒）。默认 30。
    实测（2026-10-14 真机）：地图加载期间 mod 的动作用主线程排队，可超过 15s ⇒ 默认从
    15 提到 30；批量端点（/tool_area 等）可能更久，用 STARDEW_HTTP_TIMEOUT 再调大。 *)
let http_timeout () =
  match Sys.getenv_opt "STARDEW_HTTP_TIMEOUT" with
  | Some v -> (
      match int_of_string_opt v with Some n when n > 0 -> n | _ -> 30)
  | None -> 30

let no_strip () = Sys.getenv_opt "STARDEW_NO_STRIP" = Some "1"

(** go_to 的走位实现：walk（默认，`/walk_to` 一次走全程）/ move（旧的分段接力）。
    `STARDEW_WALK=move` 回退到分段 `/move`（排查 / 对照用）。 *)
let walk_impl () = String.lowercase_ascii (getenv "STARDEW_WALK" "walk")

(** till/water 是否走 mod 的 `/tool_area` 批量端点：
    - auto（默认）：仅当**工具升级等级 ≥1**（蓄力范围 >1 格）且目标格数 ≥ 阈值时启用；
    - force：达到格数阈值就启用（也用于测试 / 用户明确想试）；
    - off：一律逐格。
    0 级工具 1 格/挥，批量没有收益（mod 会为每格生成一个锚点），故 auto 不启用。 *)
let area_impl () = String.lowercase_ascii (getenv "STARDEW_AREA" "auto")

(** /tool_area 最少作用格数（低于此值逐格更可控）。默认 4。 *)
let area_min_cells () =
  match Sys.getenv_opt "STARDEW_AREA_MIN" with
  | Some v -> (match int_of_string_opt v with Some n when n > 0 -> n | _ -> 4)
  | None -> 4

(** 自动推进"无选项对话"（默认开）。

    模态界面会挡住动作，但其中有一类**不需要任何决策**：NPC 打招呼、送礼答谢、
    "背包满了东西掉地上"这类 DialogueBox —— 没有选项，按 confirm 是**唯一**能做的事，
    不丢信息也不做选择。工具会先自动把它按掉再干活（关掉本开关则一律快速失败，
    交回 Agent 处理）。带选项的问题框、商店、箱子、背包**永不自动处理**。 *)
let auto_menu () = getenv "STARDEW_AUTO_MENU" "1" <> "0"

(** 剧本事件（过场）自动跳过：默认**关**——跳剧情是口味问题，而且会跳过你可能想看的
    内容。设 `STARDEW_AUTO_EVENT=1` 后，遇到可跳过的事件（activeEvent.skippable）
    会自动按一次 skip，让 Agent 不被卡在过场里。 *)
let auto_event () = getenv "STARDEW_AUTO_EVENT" "0" = "1"

(** /tool_area 单次等待上限（秒）。默认 90——mod 内部要逐锚点走位+蓄力，
    地块大时可达数十秒（mod 自身最多等 10 分钟，我们不等那么久）。 *)
let area_timeout () =
  match Sys.getenv_opt "STARDEW_AREA_TIMEOUT" with
  | Some v -> (match int_of_string_opt v with Some n when n > 0 -> n | _ -> 90)
  | None -> 90

let init () =
  current_level := level_of_string (String.lowercase_ascii (getenv "STARDEW_LOG" "warn"))
