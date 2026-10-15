(** 工具注册表：MCP tools/list 与 tools/call 的实现（v1 全量 17 个）。

    工具成功返回可读文本；失败抛异常，由 call 统一转为 (Error 可读文本)。

    编排纪律（来自原作者脚本实测 + M3 真机教训）：
    - 统一操作姿态：站 (tx, ty-1) 朝下(2)
    - 站位用 /position 瞬移 + 精确回读校验（坐标必须完全相等）；失败再走位一次；
      走位若检测到 mod "直线穿墙"回退则放弃（绝不盲走）
    - 动作走 /use（带游戏侧校验），并核对实际作用格 = 期望格；
      真错误、命中错格都计为失败（不接受"盲挥算成功"）
    - 动作后固定 settle 0.55s
    - 体力 < 15% 停止；菜单被触发则中止并报告（v1 不自动推进） *)

let no_world_msg =
  "游戏还没有进入存档（当前在标题界面或加载中）。请先在游戏里载入存档后再操作。"

type tool = {
  name : string;
  description : string;
  schema : Yojson.Safe.t; (* JSON Schema（inputSchema） *)
  with_strip : bool; (* 是否在返回文本末尾附状态速报 *)
  run : Yojson.Safe.t -> string; (* 成功返回文本；失败抛异常 *)
}

(* ---------- 参数小工具 ---------- *)

let arg_int args k = match Game_state.member k args with Some v -> Some (Game_state.to_int v) | None -> None
let arg_str args k = match Game_state.member k args with Some v -> Some (Game_state.to_str v) | None -> None

let arg_bool args k =
  match Game_state.member k args with
  | Some (`Bool b) -> Some b
  | Some (`String s) -> Some (String.lowercase_ascii s = "true" || s = "1")
  | Some (`Int i) -> Some (i <> 0)
  | _ -> None

let get_int args k default = match arg_int args k with Some v -> v | None -> default
let get_str args k default = match arg_str args k with Some v -> v | None -> default
let get_bool args k default = match arg_bool args k with Some v -> v | None -> default

let need_int args k =
  match arg_int args k with
  | Some v -> v
  | None -> failwith (Printf.sprintf "缺少必填参数 %s（整数）" k)

let need_str args k =
  match arg_str args k with
  | Some v when v <> "" -> v
  | _ -> failwith (Printf.sprintf "缺少必填参数 %s（字符串）" k)

let require_world () : Game_state.t =
  let st = Game_state.fetch () in
  if not st.world_ready then failwith no_world_msg;
  st

(* ---------- 模态界面：摘要 / 自动推进 / 富信息报错 ----------

   动作前卫检：模态界面（对话/菜单/事件）打开时，mod 的动作端点（/select /use …）会挂到
   HTTP 超时才回（真机实测：读档问候对话开着时 till 的 /select 等了 30s），而且**角色
   根本无法移动**（真机压测：剧本事件弹对话时 go_to 连干等 25s）。

   但"有菜单"里有一大类**不需要 Agent 决策**：NPC 招呼、送礼答谢、提示框——没有选项，
   按 confirm 是唯一能做的事。于是这里分两档：
     · 无选项对话 ⇒ 自动按 confirm 推进（`STARDEW_AUTO_MENU=0` 可关）；
     · 剧本事件 ⇒ **默认不跳**（跳剧情是口味问题），`STARDEW_AUTO_EVENT=1` 才自动 skip；
     · 带选项的问题框 / 商店 / 箱子 / 背包 ⇒ **永不自动动**，快速失败并把**内容与选项
       一起回报**，让 Agent 一步就能处理（不必先 menu_read 再回来）。 *)

(* 递归取「activeMenu.responses」里第 i 个选项的可读文本（真机是纯字符串列表，
   mock/旧版可能是 {index,key,text} 对象）。 *)
let menu_option_text (r : Yojson.Safe.t) : string =
  match r with
  | `String s -> s
  | `Assoc _ ->
      let t = Game_state.get_str r [ "text" ] in
      if t <> "" then t else Game_state.to_str r
  | other -> Game_state.to_str other

let clip ?(n = 120) (s : string) =
  if String.length s > n then String.sub s 0 n ^ "…" else s

(* 菜单/对话框摘要：类型 + 说话人 + 原文 + 带序号的选项。 *)
let menu_summary (st : Game_state.t) : string =
  let j = st.raw in
  let mtype = match st.active_menu with Some m -> m | None -> "菜单" in
  let speaker = Game_state.get_str j [ "activeMenu"; "speaker" ] in
  let text = Game_state.get_str j [ "activeMenu"; "dialogue" ] in
  let opts =
    match Game_state.get_in j [ "activeMenu"; "responses" ] with
    | Some (`List l) ->
        let items =
          List.mapi
            (fun i r -> Printf.sprintf "[%d] %s" i (clip ~n:40 (menu_option_text r)))
            l
        in
        if items = [] then "" else "　可选项：" ^ String.concat " / " items
    | _ -> ""
  in
  Printf.sprintf "%s%s%s%s" mtype
    (if speaker = "" then "" else "（" ^ speaker ^ "）")
    (if text = "" then "" else "：" ^ clip text)
    opts

(* 无选项对话：DialogueBox 且没有 responses —— 按 confirm 是唯一能做的事。 *)
let is_plain_dialogue (st : Game_state.t) : bool =
  let is_dlg =
    match st.active_menu with
    | Some m ->
        m = "DialogueBox"
        || (String.length m >= 8 && String.sub m 0 8 = "Dialogue")
    | None -> false
  in
  let no_opts =
    match Game_state.get_in st.raw [ "activeMenu"; "responses" ] with
    | None | Some `Null | Some (`List []) -> true
    | _ -> false
  in
  is_dlg && no_opts

let event_skippable = Game_state.event_skippable
(* 保留别名，避免调用点改动；实现已收敛到 game_state.ml（也供渲染层复用） *)

(* 尝试自动清掉"不需要决策"的模态界面。返回 true = 现在没有菜单了。

   🎬 **剧情例外（2026-10-14，用户要求"希望 agent 能玩到剧情"）**：事件进行中时
   **绝不替 Agent 按掉**——那是在念台词，按过去就等于把剧情吃了。只有显式开了
   `STARDEW_AUTO_EVENT=1` 才整段跳过。 *)
let auto_clear_menu () : bool =
  if not (Config.auto_menu ()) then false
  else
    let st0 = Game_state.fetch () in
    if st0.active_menu = None then true
    else
      match Game_state.active_event st0 with
      | Some _ ->
          if Config.auto_event () && Game_state.event_skippable (Game_state.active_event st0)
          then begin
            (try ignore (Game_api.key ~key:"skip" ()) with _ -> ());
            Wait.sleep_ms 500;
            (Game_state.fetch ()).active_menu = None
          end
          else false
      | None ->
          (* 无选项对话：按 confirm 推进（最多 6 屏，防止连环对话把我们拖住） *)
          let cleared = ref false and steps = ref 0 in
          while (not !cleared) && !steps < 6 do
            let st = Game_state.fetch () in
            match st.active_menu with
            | None -> cleared := true
            | Some _ when is_plain_dialogue st ->
                incr steps;
                (try ignore (Game_api.key ~key:"confirm" ()) with _ -> ());
                Wait.sleep_ms 350
            | Some _ -> steps := 6 (* 要 Agent 决策的 ⇒ 立刻停手，一个键都不按 *)
          done;
          !cleared

let menu_block_msg ?(what = "动作") (st : Game_state.t) : string =
  match Game_state.active_event st with
  | Some (id, sk, msg) ->
      (* 屏幕上正在显示的那一句：优先取当前对话（和 story 的取法一致），退回事件 message *)
      let on_screen =
        let d = Game_state.get_str st.raw [ "activeMenu"; "dialogue" ] in
        if d <> "" then d else msg
      in
      Printf.sprintf
        "当前正在演剧情（事件 id %s%s），已中止%s——剧情期间角色不能移动。%s\
         处理办法：用 **story** 一屏一屏读/推进（action=read 读当前屏、next 下一屏、\
         choose 选回答）；不想看就 press_key skip 跳过整段（**跳过不可回放**）。"
        id
        (if sk then "，可跳过" else "，不可跳过")
        what
        (if on_screen = "" then ""
         else Printf.sprintf "当前台词：「%s」。\n" (clip on_screen))
  | None ->
      Printf.sprintf
        "当前有菜单/对话打开（%s），已中止%s——模态界面下动作会挂住、角色也不能移动。\
         处理办法：带选项的用 menu_click {\"option\":N} 直接选（或 story action=choose \
         option=N）；要看全貌用 menu_read / story；无选项的对话按 press_key confirm。"
        (menu_summary st) what

(* ---------- 剧情 / 对话：一屏一屏读的原料 ----------

   用户诉求（2026-10-14）：**"希望 agent 能玩到剧情"**。所以除了"别把它按掉"，
   还要让它**读得到台词**：SDV 的剧情是一屏一屏推进的，台词在
   `activeMenu.dialogue`（当前屏）与 `activeEvent.message`（同一句，事件路径）里，
   说话人在 `activeMenu.speaker`，选项在 `activeMenu.responses`。 *)

type story_view = {
  sv_event : (string * bool) option; (* 事件 id、是否可跳过 *)
  sv_kind : string; (* 当前菜单类型；无菜单时 "" *)
  sv_speaker : string;
  sv_line : string; (* 当前这一屏的台词 *)
  sv_options : string list;
  sv_is_dialogue : bool; (* 是"剧情/对话"（而不是商店/箱子这类界面）*)
}

let story_view (st : Game_state.t) : story_view =
  let ev =
    match Game_state.active_event st with
    | Some (id, sk, _) -> Some (id, sk)
    | None -> None
  in
  let kind = match st.active_menu with Some k -> k | None -> "" in
  let speaker = Game_state.get_str st.raw [ "activeMenu"; "speaker" ] in
  let line =
    let d = Game_state.get_str st.raw [ "activeMenu"; "dialogue" ] in
    if d <> "" then d
    else match Game_state.active_event st with Some (_, _, m) -> m | None -> ""
  in
  let options =
    match Game_state.get_in st.raw [ "activeMenu"; "responses" ] with
    | Some (`List l) -> List.map menu_option_text l
    | _ -> []
  in
  let is_dialogue =
    match st.active_menu with
    | Some k ->
        k = "DialogueBox"
        || (String.length k >= 8 && String.sub k 0 8 = "Dialogue")
    | None -> ev <> None
    (* 事件进行中但这一瞬没弹框（过场/换场）也算剧情 *)
  in
  {
    sv_event = ev;
    sv_kind = kind;
    sv_speaker = speaker;
    sv_line = line;
    sv_options = options;
    sv_is_dialogue = is_dialogue;
  }

(* 从 `/menu` 取每个选项的点击坐标中心（`/state` 的 responses 只有文本，没有 bounds）。

   真机用途（2026-10-15 实测）：**剧本事件的问题框**用 `menu_click {"option":N}` 点了
   **不生效**——mod 的 `event_answerDialogueQuestion` 明明登记了答案（回包 key="No"），
   但对话框不关、事件也不推进；`menu_close`、confirm、按 bounds 点坐标也都试过，同样不动。
   所以多给 Agent 一条路：**像真人一样点选项坐标**（`/menu` 给的 bounds 就是 menu_click
   认的 UI 空间坐标）。哪条路通就用哪条。 *)
let option_clicks () : (int * int) list =
  try
    let j = Game_api.menu () in
    match Game_state.get_in j [ "responses" ] with
    | Some (`List l) ->
        List.filter_map
          (fun r ->
            match Game_state.get_in r [ "bounds" ] with
            | Some (`Assoc _ as b) ->
                let x = Game_state.get_int b [ "x" ]
                and y = Game_state.get_int b [ "y" ]
                and w = Game_state.get_int b [ "w" ]
                and h = Game_state.get_int b [ "h" ] in
                if w <= 0 || h <= 0 then None
                else Some (x + (w / 2), y + (h / 2))
            | _ -> None)
          l
    | _ -> []
  with _ -> []

(* 🩹 真机 workaround（2026-10-15，源码级根因）：

   mod 回答"剧情问题"时，把"谁在提问"猜成了
   `Game1.currentLocation.isCharacterAtTile(Game1.player.GetGrabTile())`
   —— 也就是**玩家面前那一格站着的角色**。而剧情里提问的 NPC 常常不在玩家正前方
   ⇒ 这个参数是 null ⇒ 游戏侧把回答**静默丢弃**（mod 回包却看着成功：
   ok:true / key:"No" / method:"event_answerDialogueQuestion"）。这就是"选项点了没反应"的根因
   （同样也解释了为什么 option 点击 / 坐标点击 / menu_close / confirm 五条路全废：
   坐标那条更早失败——`receiveLeftClick` 在 `selectedResponse==-1` 时会直接 return）。

   对策：回答之前先**转身面朝最近的 NPC**，让"面前那一格"正好是她。纯字段设置、无副作用；
   附近没有 NPC（半径 3 内）就原样不动。

   ⚠️ **真机实测（2026-10-15）：对宠物领养事件无效** —— 提问的那一刻，整个农场
   **一个 NPC 都没有**（`/state` 与 `/surroundings?radius=20` 的 npcs 都是空数组；
   事件的说话者是临时 actor，不在 location.characters 里）。**没有"谁在提问"这个对象**，
   所以 `answerDialogueQuestion(null, key)` 永远被丢，转身/挪位都救不了。
   这个 workaround 只可能在"提问的 NPC 确实站在玩家正前方"的事件里派上用场 —— 那一类
   尚未取得实例验证，**别当成已修**。要真修得上游 mod 改用事件自己的说话人。 *)
let face_nearest_npc () : unit =
  try
    let sur = Game_api.surroundings ~radius:3 () in
    match Game_state.member "npcs" sur with
    | Some (`List l) when l <> [] -> (
        match (Game_state.fetch ()).player with
        | Some p ->
            let cands =
              List.filter_map
                (fun n ->
                  let x = Game_state.get_int n [ "x" ]
                  and y = Game_state.get_int n [ "y" ] in
                  let cheb = max (abs (x - p.px)) (abs (y - p.py)) in
                  if cheb <= 0 || cheb > 3 then None else Some (cheb, x, y))
                l
            in
            (match List.sort compare cands with
            | (_, x, y) :: _ ->
                let dx = x - p.px and dy = y - p.py in
                let dir =
                  if abs dx > abs dy then if dx > 0 then 1 else 3
                  else if dy > 0 then 2
                  else 0
                in
                ignore (Game_api.face ~direction:dir ());
                Wait.sleep_ms 120
            | [] -> ())
        | None -> ())
    | _ -> ()
  with _ -> ()

let render_story ?(clicks = []) (v : story_view) : string =
  let b = Buffer.create 256 in
  (match v.sv_event with
  | Some (id, sk) ->
      Buffer.add_string b
        (Printf.sprintf "【剧情】事件进行中（id %s%s）\n" id
           (if sk then "，可跳过" else "，不可跳过"))
  | None -> ());
  if not v.sv_is_dialogue then
    if v.sv_kind = "NamingMenu" then
      Buffer.add_string b
        "【剧情】正在**给宠物起名**（NamingMenu）——mod 对它是盲区（`/menu` 不暴露文本框，\
         按钮名也点不到）。办法：\n\
         · 接受默认名字：`menu_click {\"x\":800,\"y\":352}`（16:9 / 1280×720 布局，真机实测\
         这一步就让游戏认下名字、剧情继续；换名字目前得人来输入）；\n\
         · 不想继续这个收养：`press_key cancel`（会退回上一个问题，不留痕迹）。"
    else
      Buffer.add_string b
        (Printf.sprintf "【剧情】当前没有剧情/对话在进行%s\n"
           (if v.sv_kind = "" then ""
            else Printf.sprintf "（打开的是 %s，内容用 menu_read 看）" v.sv_kind))
  else begin
    if v.sv_line <> "" then
      Buffer.add_string b
        (Printf.sprintf "【%s】%s\n"
           (if v.sv_speaker = "" then "台词" else v.sv_speaker)
           v.sv_line)
    else Buffer.add_string b "【台词】（这一屏没有文字，可能是过场画面）\n";
    if v.sv_options <> [] then begin
      Buffer.add_string b "【选项】（不会替你选）\n";
      List.iteri
        (fun i o ->
          let xy =
            match List.nth_opt clicks i with
            | Some (x, y) -> Printf.sprintf "（也可点 (%d,%d)）" x y
            | None -> ""
          in
          Buffer.add_string b (Printf.sprintf "  [%d] %s%s\n" i o xy))
        v.sv_options
    end;
    Buffer.add_string b
      (if v.sv_options <> [] then
         "【下一步】story action=choose option=N 选一项；若没反应就 menu_click {\"x\":N,\"y\":N} 按坐标点"
       else
         "【下一步】story action=next 读下一屏；action=skip 跳过整段剧情")
  end;
  String.trim (Buffer.contents b)

(* 动作/走位前的模态界面卫检：能自动清的先自动清，清不掉再快速失败并说清要做什么。 *)
let require_no_menu ?(what = "动作") () : unit =
  let st = require_world () in
  match st.active_menu with
  | None -> ()
  | Some _ ->
      if auto_clear_menu () then ()
      else begin
        let st = Game_state.fetch () in
        match st.active_menu with
        | None -> ()
        | Some _ -> failwith (menu_block_msg ~what st)
      end

(* schema 帮助 *)
let p_int ?minimum ?maximum ?default desc =
  let fields =
    [ ("type", `String "integer") ]
    @ (match minimum with Some m -> [ ("minimum", `Int m) ] | None -> [])
    @ (match maximum with Some m -> [ ("maximum", `Int m) ] | None -> [])
    @ (match default with Some d -> [ ("default", `Int d) ] | None -> [])
    @ [ ("description", `String desc) ]
  in
  `Assoc fields

let p_str ?default desc =
  let fields =
    [ ("type", `String "string") ]
    @ (match default with Some d -> [ ("default", `String d) ] | None -> [])
    @ [ ("description", `String desc) ]
  in
  `Assoc fields

let p_bool ?default desc =
  let fields =
    [ ("type", `String "boolean") ]
    @ (match default with Some d -> [ ("default", `Bool d) ] | None -> [])
    @ [ ("description", `String desc) ]
  in
  `Assoc fields

let obj_schema props =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc props);
      ("additionalProperties", `Bool false);
    ]

(* ---------- 编排原语 ---------- *)

(* 瞬移站位 + 精确校验（/position 是瞬移端点）；失败再走位一次。
   走位若落入 mod 的"直线穿墙"回退（steps=1 而距离>1），立即停止放弃——绝不盲走。
   返回 Ok / Error 原因。 *)
let snap_or_move ~(sx : int) ~(sy : int) : (unit, string) result =
  let st0 = Game_state.fetch () in
  let in_bounds =
    sx >= 0 && sy >= 0
    && (st0.loc_w <= 0 || sx < st0.loc_w)
    && (st0.loc_h <= 0 || sy < st0.loc_h)
  in
  if not in_bounds then
    Error
      (Printf.sprintf "站位 (%d,%d) 超出当前地图 %s（%dx%d）范围，拒绝瞬移" sx sy
         st0.loc_name st0.loc_w st0.loc_h)
  else begin
    ignore (Game_api.position ~x:sx ~y:sy ());
    Wait.sleep_ms 150;
    let here () =
      match (Game_state.fetch ()).player with
      | Some p -> p.px = sx && p.py = sy
      | None -> false
    in
    if here () then Ok ()
    else begin
      (* fallback：走位一次；先侦测直线回退 *)
      let dist =
        match (Game_state.fetch ()).player with
        | Some p -> max (abs (p.px - sx)) (abs (p.py - sy))
        | None -> 0
      in
      let resp = Game_api.move ~x:sx ~y:sy () in
      if Wait.linear_fallback resp ~dist then begin
        (try ignore (Game_api.stop ()) with _ -> ());
        Error "走位时 mod 寻路失败（直线回退），已放弃（避免穿墙/越界乱走）"
      end
      else
        let ok =
          Wait.poll_until ~timeout:8.0 ~interval:0.3 (fun () ->
              match (Game_state.fetch ()).player with
              | Some p -> (not p.is_moving) && p.px = sx && p.py = sy
              | None -> false)
        in
        if ok then Ok ()
        else Error (Printf.sprintf "走位后未到精确站位（目标 %d,%d）" sx sy)
    end
  end

(* 把玩家精确站到 (tx,ty-1) 并面朝下。返回 Ok / Error 原因。
   真机偶发（2026-10-14 live_m4，9 格里撞到 1 格）：/face 之后立刻 /use 会用到**旧朝向**——
   走位刚结束时游戏的移动逻辑把朝向改回，/face 被覆盖 ⇒ 锄头挥到隔壁格（被 op_use 的
   "命中格不符"抓到并如实报失败）。故转身后**轮询确认**（朝向=下 且 不再移动）再动手；
   原生 HTTP 下单次轮询仅几毫秒，代价可忽略。确认不了就再补发一次 /face，仍不行则如实失败
   （绝不带着错朝向挥下去）。 *)
let stand_and_face (tx, ty) : (unit, string) result =
  let sx, sy = Farm.stand_pos (tx, ty) in
  match snap_or_move ~sx ~sy with
  | Error e -> Error e
  | Ok () ->
      let facing_ready () =
        match (Game_state.fetch ()).player with
        | Some p -> p.facing = 2 && not p.is_moving
        | None -> true
      in
      let confirm () = Wait.poll_until ~timeout:1.5 ~interval:0.03 facing_ready in
      ignore (Game_api.face ~direction:2 ());
      if confirm () then Ok ()
      else begin
        ignore (Game_api.face ~direction:2 ());
        if confirm () then Ok ()
        else Error "转身未生效（朝向仍不是向下），已放弃该格（避免挥到隔壁格）"
      end

type op_outcome =
  | Op_ok
  | Op_skip of string (* 无害的"已做过"（已锄/已浇水），计为软成功 *)
  | Op_fail of string

type exec_result = {
  total : int;
  ok_n : int;
  skip_n : int;
  failed : (int * int * string) list;
  stop_reason : string option;
}

(* /use 结果 → op_outcome。
   - ok:true 且带 tile 字段时核对 tile == 期望格（不符 = 站位/朝向不对，判失败）；
   - ok:false 的错误在 soft 列表里（如 "Tile already tilled" / "Already watered"）
     → Op_skip；其余错误 → Op_fail。 *)
let op_use ?tile ~(soft : string list) () : op_outcome =
  let res = Game_api.use_held () in
  let ok = match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false in
  if ok then begin
    match (tile, Game_state.member "tile" res) with
    | Some (tx, ty), Some t ->
        let rx = Game_state.get_int t [ "x" ] in
        let ry = Game_state.get_int t [ "y" ] in
        if rx <> tx || ry <> ty then
          Op_fail
            (Printf.sprintf "命中格不符：预期 (%d,%d)、实际 (%d,%d)" tx ty rx ry)
        else Op_ok
    | _ -> Op_ok
  end
  else begin
    let err =
      match Game_state.member "error" res with
      | Some v -> Game_state.to_str v
      | None -> "未知错误"
    in
    if List.mem err soft then Op_skip err else Op_fail err
  end

(* 读单格信息（/surroundings 小半径反查；失败给 None）。用于失败时的二次确认。 *)
let tile_info ~(tx : int) ~(ty : int) : Yojson.Safe.t option =
  try
    let sur = Game_api.surroundings ~radius:2 () in
    match Game_state.member "tiles" sur with
    | Some (`List ts) ->
        List.find_opt
          (fun t ->
            Game_state.get_int t [ "x" ] = tx && Game_state.get_int t [ "y" ] = ty)
          ts
    | _ -> None
  with _ -> None

(* 效果核验式动作：/use 报 ok 之后，**轮询目标格直到终态真的出现**。

   🚨 真机铁证（2026-10-14，确定性复现）：`/use` 的 Tool 分支只做
   `BeginUsingTool(); EndUsingTool();` 就回 `ok:true`，而挥动的**生效帧在几百毫秒之后**。
   我们原来是"回 ok 后睡固定时长（自适应 250~900ms）再动下一格"——只要那一睡短于生效帧，
   紧接着的下一格 `/position`（瞬移）就会把未落地的挥动打断 ⇒ **效果落空、工具却已经记账**。
   实测形态：一行 3 格浇过去，**每次都恰好丢中间那格**（首格 settle 较长、末格后面没有打断）。
   这是标准的"假成功"，也是本项目最不能容忍的失败模式。

   ⇒ 改为"等效果"而不是"睡固定时长"：轮询（本机一次请求仅几毫秒）到 expect 成立为止，
   成立才继续下一格——下一格的动作因此永远不会打断上一格。轮询不到就重试一次
   （重新站位转身再挥），仍不成立则**如实报失败**，绝不记账。 *)
let op_use_effect ~tile:(tx, ty) ~(expect : Yojson.Safe.t -> bool)
    ~(soft : string list) () : op_outcome =
  let verify () =
    match tile_info ~tx ~ty with Some t -> expect t | None -> false
  in
  let landed () = Wait.poll_until ~timeout:2.0 ~interval:0.03 verify in
  match op_use ~tile:(tx, ty) ~soft () with
  | Op_ok ->
      if landed () then Op_ok
      else begin
        match stand_and_face (tx, ty) with
        | Error why ->
            Op_fail (Printf.sprintf "挥动已发出但地块未见变化；重试时无法就位：%s" why)
        | Ok () -> (
            match op_use ~tile:(tx, ty) ~soft () with
            | Op_ok ->
                if landed () then Op_ok
                else Op_fail "挥动已发出但地块始终未见变化（重试后仍未生效）"
            | other -> other)
      end
  | other -> other

(* 对一组格子逐格执行 op：每格（卫检 → 站位 → 动作 → settle）。
   卫检失败中止整批；站位失败/动作失败都记录该格（带原因）继续。 *)
let run_cells ~(op : int -> int -> op_outcome) (cells : (int * int) list) : exec_result =
  let total = List.length cells in
  let ok_n = ref 0 in
  let skip_n = ref 0 in
  let failed = ref [] in
  let stop_reason = ref None in
  (try
     List.iter
       (fun (tx, ty) ->
         let st = Game_state.fetch () in
         (match st.active_menu with
         | Some m ->
             stop_reason :=
               Some
                 (Printf.sprintf
                    "有菜单打开（%s），已中止。请先处理菜单（menu_read / \
                     menu_click / press_key confirm）后重试剩余格子。"
                    m);
             raise Exit
         | None -> ());
         (match st.player with
         | Some p when p.max_stamina > 0.0 && p.stamina /. p.max_stamina < 0.15 ->
             stop_reason :=
               Some
                 (Printf.sprintf "体力不足（%.0f/%.0f，低于 15%%），已停止。" p.stamina
                    p.max_stamina);
             raise Exit
         | _ -> ());
         (try
            match stand_and_face (tx, ty) with
            | Error why ->
                Wait.adapt ~ok:false;
                failed := (tx, ty, why) :: !failed
            | Ok () -> (
                match op tx ty with
                | Op_ok ->
                    (* 不再睡固定时长：op 内部已用"轮询到终态出现"替代（见 op_use_effect），
                       睡短了会打断上一格的挥动（真机铁证：一行 3 格必丢中间格）。 *)
                    Wait.adapt ~ok:true;
                    incr ok_n
                | Op_skip _ ->
                    Wait.adapt ~ok:true;
                    incr skip_n
                | Op_fail why ->
                    Wait.adapt ~ok:false;
                    failed := (tx, ty, why) :: !failed)
          with
         | Exit -> raise Exit
         | Game_api.Api_error m ->
             stop_reason :=
               Some
                 (Printf.sprintf "第 (%d,%d) 格遇游戏侧错误：%s。已中止该批次。" tx ty m);
             raise Exit
         | e ->
             stop_reason :=
               Some
                 (Printf.sprintf "第 (%d,%d) 格执行异常：%s。已中止该批次。" tx ty
                    (Printexc.to_string e));
             raise Exit))
       cells
   with Exit -> ());
  {
    total;
    ok_n = !ok_n;
    skip_n = !skip_n;
    failed = List.rev !failed;
    stop_reason = !stop_reason;
  }

let render_exec_result ?(notes = []) ~what (r : exec_result) : string =
  let b = Buffer.create 128 in
  Buffer.add_string b (Printf.sprintf "%s：成功 %d/%d 格" what r.ok_n r.total);
  if r.skip_n > 0 then
    Buffer.add_string b (Printf.sprintf "（另有 %d 格已完成/无需再做）" r.skip_n);
  if r.failed <> [] then begin
    Buffer.add_string b
      (Printf.sprintf "，%d 格失败：" (List.length r.failed));
    Buffer.add_string b
      (String.concat "；"
         (List.map
            (fun (x, y, why) -> Printf.sprintf "(%d,%d) %s" x y why)
            r.failed))
  end;
  Buffer.add_string b "。";
  (match r.stop_reason with
  | Some why -> Buffer.add_string b ("\n中止原因：" ^ why)
  | None -> ());
  List.iter (fun n -> Buffer.add_string b ("\n" ^ n)) notes;
  Buffer.contents b

(* ---------- 感知组 ---------- *)

let tool_get_state =
  {
    name = "get_state";
    description =
      "获取游戏当前完整状态：玩家名字/坐标/朝向/HP/体力/金钱/手持物、所在位置与地图大小、\
       游戏内日期时间、当前打开的菜单、背包格列表。\
       什么时候用：每轮行动开始前先看全局；任何操作后确认结果；感觉迷路或不知道进行到哪一步时。\
       注意：若游戏还没进档（停在标题界面/加载中），会返回错误提示。";
    schema = obj_schema [];
    with_strip = false;
    run =
      (fun _ ->
        let st = Game_state.fetch () in
        if not st.world_ready then failwith no_world_msg;
        Game_state.render st);
  }

let tool_look =
  {
    name = "look";
    description =
      "环视玩家周围半径内的环境：作物（含阶段/是否浇水/是否可收获）、可交互物/物件、\
       树石类地形、可锄泥地、锄过的空地、NPC、怪物。\
       什么时候用：想知道周围有什么、找东西、找路；对某位置操作前确认那里有什么。\
       注意：只在游戏内（进档后）可用；半径越大返回越多。";
    schema =
      obj_schema
        [
          ( "radius",
            p_int ~minimum:1 ~maximum:30 ~default:10 "视野半径（格），1-30，默认 10" );
        ];
    with_strip = true;
    run =
      (fun args ->
        let radius = get_int args "radius" 10 in
        let _ = require_world () in
        Game_api.surroundings ~radius () |> Game_state.render_surroundings);
  }

let tool_get_inventory =
  {
    name = "get_inventory";
    description =
      "列出背包内容：每格的名字、数量、类别（水壶附带余水量）。\
       什么时候用：确认种子/工具/物品是否在身上、确认当前手持物、播种或收割前检查。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let st = require_world () in
        Game_state.render_inventory st);
  }

(* ---------- 移动组 ---------- *)

let tool_go_to =
  {
    name = "go_to";
    description =
      "走到指定格子（寻路移动，等待到达后返回）。什么时候用：去田里、去某个物件旁。\
       注意：可能被障碍阻挡而走不到（会自动改用逐段走位兜底），超时会自动停止并回报实际位置；\
       目标越界/是大门或传送格/四周站不住时，会在**出发前**就被拒绝并说明原因；\
       菜单/对话/事件开着时角色无法移动，会当场快速失败（对话按 confirm、剧本事件按 skip）；\
       若要精确站位做农活，通常不必先 go_to（农活工具自带站位）。";
    schema =
      obj_schema
        [
          ("x", p_int "目标格 x 坐标（必填）");
          ("y", p_int "目标格 y 坐标（必填）");
          ("timeout", p_int ~minimum:1 ~maximum:180 ~default:60 "超时秒数，默认 60");
        ];
    with_strip = true;
    run =
      (fun args ->
        let x = need_int args "x" in
        let y = need_int args "y" in
        let timeout = float_of_int (get_int args "timeout" 60) in
        let st0 = require_world () in
        (* 模态界面卫检：菜单/对话开着时角色**根本无法移动**（真机压测逮到：送礼后的对话框
           没关，go_to 连着 3 轮各干等 25s 才超时）。无选项对话会自动按掉再走；
           带选项的当场快速失败并把选项一并回报。 *)
        require_no_menu ~what:"走位" ();
        let x0, y0 =
          match st0.player with Some p -> (p.px, p.py) | None -> (0, 0)
        in
        let loc0 = st0.loc_name in
        let t1 = Unix.gettimeofday () in
        let elapsed () = Unix.gettimeofday () -. t1 in
        let remaining () = max 3.0 (timeout -. elapsed ()) in
        (* 优先 /walk_to：一次请求走全程，mod 内部寻路 + 出发前入口校验（越界 / 门格 /
           站不住当场拒绝，不再"走一半才发现"）。
           安全网：端点不可用（旧版 mod / 连接错误）**或**路线没按时走到（真机压测
           328 次里 1 次 mod 路线卡在障碍后）→ 交回分段接力（M4 的老路）收尾。
           先给 /walk_to 一半预算，剩下的留给接力，总预算仍是 timeout。 *)
        let st, outcome =
          if Config.walk_impl () = "move" then
            let st, r = Wait.travel_to ~timeout ~x ~y () in
            (st, `Legacy r)
          else
            let sub = max 2.0 (min 20.0 (timeout /. 2.)) in
            match Wait.walk_to_and_wait ~timeout:sub ~loc:loc0 ~x ~y () with
            | _, Wait.Walk_unavailable why ->
                Config.info "go_to: /walk_to 不可用（%s）→ 回退分段接力" why;
                let st, r = Wait.travel_to ~timeout:(remaining ()) ~x ~y () in
                (st, `Legacy r)
            | _, Wait.Walk_timeout ->
                Config.info "go_to: /walk_to 未在 %.0fs 内到达 → 分段接力收尾" sub;
                let st, r = Wait.travel_to ~timeout:(remaining ()) ~x ~y () in
                (st, `Legacy r)
            | _, Wait.Walk_stalled ->
                Config.info "go_to: /walk_to 出发后没挪窝（目标多半被墙/水隔断）→ 分段接力判定";
                let st, r = Wait.travel_to ~timeout:(remaining ()) ~x ~y () in
                (st, `Legacy r)
            | st, o -> (st, `Walk o)
        in
        let dt = Unix.gettimeofday () -. t1 in
        let px, py =
          match st.player with Some p -> (p.px, p.py) | None -> (0, 0)
        in
        let arrived () =
          if px = x && py = y then
            Printf.sprintf "已到达 (%d,%d)（从 (%d,%d) 出发，耗时 %.1fs）。" x y x0 y0
              dt
          else
            Printf.sprintf
              "已到达目标附近 (%d,%d)（目标 (%d,%d) 可能不可站立/被占用，停在邻格属正常；\
               从 (%d,%d) 出发，耗时 %.1fs）。"
              px py x y x0 y0 dt
        in
        (match outcome with
        | `Walk Wait.Walked | `Legacy Wait.Arrived -> arrived ()
        | `Walk (Wait.Walk_rejected why) ->
            failwith
              (Printf.sprintf
                 "拒绝走位：%s（未移动，仍在 (%d,%d)，地图 %s）。越界请改用地图内合法坐标；\
                  门/传送格请改用 interact（进门）或 warp（跨图）。"
                 why px py st.loc_name)
        | `Walk (Wait.Walk_unavailable why) ->
            failwith
              (Printf.sprintf "走位失败：/walk_to 与分段接力都不可用（%s）。" why)
        | `Walk Wait.Walk_timeout | `Walk Wait.Walk_stalled | `Legacy Wait.Timeout ->
            failwith
              (Printf.sprintf
                 "移动超时（%.0fs）：目标 (%d,%d)，实际停在 (%d,%d)。可能被障碍阻挡，可用 \
                  look 查看。已发送停止命令。"
                 timeout x y px py)
        | `Legacy Wait.No_path ->
            failwith
              (Printf.sprintf
                 "寻路失败：目标 (%d,%d) 不可达（已尝试分段接力；可能跨地图或被完全隔开）。\
                  为避免直线穿墙乱走，已拒绝移动并停止。当前 (%d,%d)（地图 %s）。"
                 x y px py st.loc_name)));
  }

let tool_warp =
  {
    name = "warp";
    description =
      "传送到另一个地图（可选指定格坐标）。什么时候用：跨区域赶路（如从农舍去农场、去镇上）。\
       注意：目标是游戏内的地图名（如 Farm / FarmHouse / Town / Mine），名字不对不会生效。";
    schema =
      obj_schema
        [
          ("location", p_str "目标地图名（必填），如 Farm、FarmHouse、Town");
          ("x", p_int "目标格 x（可选）");
          ("y", p_int "目标格 y（可选）");
        ];
    with_strip = true;
    run =
      (fun args ->
        let loc = need_str args "location" in
        let x = arg_int args "x" in
        let y = arg_int args "y" in
        let _ = require_world () in
        let _ = Game_api.warp ~location:loc ?x ?y () in
        let ok =
          Wait.poll_until ~timeout:15.0 ~interval:0.3 (fun () ->
              let st = Game_state.fetch () in
              st.loc_name = loc
              && (match x with
                 | None -> true
                 | Some xx -> (
                     match st.player with
                     | Some p -> abs (p.px - xx) <= 2
                     | None -> false)))
        in
        let st = Game_state.fetch () in
        let px, py =
          match st.player with Some p -> (p.px, p.py) | None -> (0, 0)
        in
        if ok then
          Printf.sprintf "已到达 %s(%d,%d)。" st.loc_name px py
        else
          failwith
            (Printf.sprintf
               "warp 后未在预期位置：请求 %s，当前在 %s(%d,%d)。检查地图名是否正确。"
               loc st.loc_name px py));
  }

let tool_face =
  {
    name = "face";
    description = "让角色转向：0=上 1=右 2=下 3=左。什么时候用：面向要交互/操作的格子。";
    schema = obj_schema [ ("direction", p_int ~minimum:0 ~maximum:3 "方向：0上 1右 2下 3左") ];
    with_strip = true;
    run =
      (fun args ->
        let d = need_int args "direction" in
        if d < 0 || d > 3 then failwith "direction 必须是 0-3（0上 1右 2下 3左）";
        let _ = require_world () in
        ignore (Game_api.face ~direction:d ());
        Printf.sprintf "已转向：%s。" (Game_state.facing_cn d));
  }

(* ---------- 交互组 ---------- *)

let menu_note (st : Game_state.t) : string =
  match st.active_menu with
  | Some m ->
      Printf.sprintf "\n注意：动作触发了菜单（%s），可用 menu_read 查看内容。" m
  | None -> ""

let tool_swing_tool =
  {
    name = "swing_tool";
    description =
      "挥动一次工具（锄头/斧头/镐/水壶等），对面前一格生效。\
       什么时候用：单次精度操作（砍树、挖矿、单独锄一格、清杂物）。\
       不带名字默认挥当前手持工具；可传名字（如 Hoe / Axe / Watering Can）自动切换。\
       注意：批量农活优先用 till/water 等专用工具；若当前有菜单打开，先处理菜单。";
    schema = obj_schema [ ("name", p_str ~default:"current" "工具名，默认 current（当前手持）") ];
    with_strip = true;
    run =
      (fun args ->
        let name = get_str args "name" "current" in
        let st0 = require_world () in
        (match st0.active_menu with
        | Some m ->
            failwith
              (Printf.sprintf
                 "当前有菜单打开（%s）。请先用 menu_read/menu_click 处理后再挥工具。" m)
        | None -> ());
        if name <> "current" then ignore (Game_api.select ~name ());
        let hx, hy =
          match st0.player with
          | Some p -> (
              match p.facing with
              | 0 -> (p.px, p.py - 1)
              | 1 -> (p.px + 1, p.py)
              | 2 -> (p.px, p.py + 1)
              | _ -> (p.px - 1, p.py))
          | None -> (0, 0)
        in
        let res = Game_api.use_held () in
        let ok = match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false in
        if not ok then begin
          let err =
            match Game_state.member "error" res with
            | Some v -> Game_state.to_str v
            | None -> "未知错误"
          in
          failwith
            (Printf.sprintf
               "工具使用被游戏拒绝：%s（目标格 (%d,%d)）。这是游戏侧真实校验结果，未发生挥动。"
               err hx hy)
        end;
        let item =
          match Game_state.member "item" res with
          | Some v -> Game_state.to_str v
          | None -> (
              match st0.player with Some p -> p.current_tool | None -> name)
        in
        let rx, ry =
          match Game_state.member "tile" res with
          | Some t -> (Game_state.get_int t [ "x" ], Game_state.get_int t [ "y" ])
          | None -> (hx, hy)
        in
        Wait.settle ();
        let st = Game_state.fetch () in
        Printf.sprintf "已挥动/使用 %s，作用格 (%d,%d)。%s" item rx ry (menu_note st));
  }

let tool_use_held =
  {
    name = "use_held";
    description =
      "使用当前手持物（播种、放置物品、吃东西等）。什么时候用：在锄过的地上播种、摆放物件。\
       注意：播种前先用 select_item 选中种子（或直接用 plant 工具做批量播种）。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let st0 = require_world () in
        (match st0.active_menu with
        | Some m ->
            failwith
              (Printf.sprintf "当前有菜单打开（%s）。请先处理菜单后再使用物品。" m)
        | None -> ());
        let res = Game_api.use_held () in
        let ok = match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false in
        if not ok then begin
          let err =
            match Game_state.member "error" res with
            | Some v -> Game_state.to_str v
            | None -> "未知错误"
          in
          failwith (Printf.sprintf "使用手持物被游戏拒绝：%s。" err)
        end;
        let item =
          match Game_state.member "item" res with
          | Some v -> Game_state.to_str v
          | None -> (
              match st0.player with Some p -> p.current_tool | None -> "?")
        in
        Wait.settle ();
        let st = Game_state.fetch () in
        Printf.sprintf "已使用手持物：%s。%s" item (menu_note st));
  }

let tool_interact =
  {
    name = "interact";
    description =
      "与面前一格交互（相当于按确认键）：开箱子、捡东西、查看告示、和 NPC 对话等。\
       什么时候用：站在目标旁面朝它、想触发交互时。返回面前格的内容信息。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let _ = require_world () in
        let res = Game_api.interact () in
        Wait.settle ();
        Game_state.render_interact res);
  }

let tool_press_key =
  {
    name = "press_key";
    description =
      "模拟按键。支持：confirm/action（确认/交互键）、cancel/back（取消/ESC）、\
       menu（Esc 或开背包）、skip/escape（跳过事件）、up/down/left/right、space、enter、w/a/s/d、f1-f12。\
       什么时候用：推进对话、关闭菜单、跳过过场。注意：count 为按键次数（默认 1）。";
    schema =
      obj_schema
        [
          ("key", p_str ~default:"confirm" "键名，默认 confirm");
          ("count", p_int ~minimum:1 ~maximum:20 ~default:1 "连按次数");
        ];
    with_strip = true;
    run =
      (fun args ->
        let key = get_str args "key" "confirm" in
        let count = max 1 (get_int args "count" 1) in
        let _ = require_world () in
        let _ = Game_api.key ~key ~count () in
        Wait.settle ();
        Printf.sprintf "已按键 %s x%d。" key count);
  }

(* ---------- 界面组 ---------- *)

let tool_menu_read =
  {
    name = "menu_read";
    description =
      "读取当前打开的菜单/对话：菜单类型、对话全文、选项列表（带 index 和 key）、\
       商店清单、可点按钮。什么时候用：任何菜单出现后（对话、商店、确认框）；\
       返回值配合 menu_click / press_key 操作。注意：没有菜单时返回提示，不是错误。";
    schema = obj_schema [];
    with_strip = false;
    run =
      (fun _ ->
        let j = Game_api.menu () in
        Game_state.render_menu j);
  }

let tool_menu_close =
  {
    name = "menu_close";
    description =
      "关掉当前打开的菜单 / 文本框（等价游戏里按 Esc 或点关闭）。\
       什么时候用：菜单挡住动作时（动作类工具遇到菜单会快速失败并说明）；\
       睡完觉的 SaveGameMenu、夜间结算的 ShippingMenu 也会挂在屏幕上，**连续睡第二天前要先关**。\
       注意：关的是**界面**，不等于回答了里面的问题——带选项的框请用 menu_click / story choose。";
    schema = obj_schema [];
    with_strip = false;
    run =
      (fun _ ->
        let before =
          match (Game_state.fetch ()).active_menu with Some m -> m | None -> ""
        in
        if before = "" then "当前没有菜单打开。"
        else begin
          let res = Game_api.menu_close () in
          let closed =
            match Game_state.member "closed" res with
            | Some (`Bool b) -> b
            | _ -> false
          in
          Wait.sleep_ms 250;
          let still =
            match (Game_state.fetch ()).active_menu with Some m -> m | None -> ""
          in
          if closed && still = "" then Printf.sprintf "已关闭菜单（%s）。" before
          else if still = "" then Printf.sprintf "菜单（%s）已经不在了。" before
          else begin
            let why =
              match Game_state.member "reason" res with
              | Some v -> Game_state.to_str v
              | None -> "未给原因"
            in
            Printf.sprintf
              "没能关掉菜单（%s；mod 回：%s）。这类界面得按内容处理：menu_read 看内容，\
               带选项的用 menu_click / story choose；NamingMenu 可用 menu_click {\"x\":800,\"y\":352} \
               接受默认名字。"
              still why
          end
        end);
  }

let tool_story =
  {
    name = "story";
    description =
      "阅读并推进剧情 / 对话（剧本事件、NPC 对话、问答选项）。\
       什么时候用：走到某处触发了剧情、跟 NPC 说完话、节日过场时——**想看/想玩剧情就用它**；\
       动作工具报「正在演剧情」时也用它读完/跳过再继续。\
       action=read（默认）只读当前一屏、不改变任何东西；next 推进一屏并返回新的一屏台词；\
       choose 配合 option:N 回答（**选项不会替你选**）；skip 跳过整段事件。\
       注意：剧情是一屏一屏推进的——读完一屏再 next，下一屏才有内容；\
       跳过剧情会永久错过内容（游戏不提供回放）。";
    schema =
      obj_schema
        [
          ( "action",
            p_str ~default:"read"
              "read（只读当前屏）/ next（推进一屏）/ choose（需 option）/ skip（跳过整段）"
          );
          ("option", p_int ~minimum:0 "choose 时的选项序号（从 0 开始）");
          ( "real",
            p_bool
              "choose 时走 mod 的真实点击路径（默认 false）。仅当默认路径点了没反应时再试；\
               对**剧本事件**的对话它可能「关掉框但不认选择」，慎用" );
        ];
    with_strip = false;
    run =
      (fun args ->
        let action = String.lowercase_ascii (get_str args "action" "read") in
        let _ = require_world () in
        match action with
        | "read" ->
            let v = story_view (Game_state.fetch ()) in
            let clicks = if v.sv_options = [] then [] else option_clicks () in
            render_story ~clicks v
        | "next" | "choose" ->
            let before = story_view (Game_state.fetch ()) in
            if (not before.sv_is_dialogue) && before.sv_event = None then
              "当前没有剧情/对话在进行，无需推进。"
            else begin
              (match action with
              | "choose" ->
                  let opt = get_int args "option" (-1) in
                  if opt < 0 then
                    failwith
                      "choose 需要 option（选项序号，从 0 开始）——先 story action=read 看有哪几个选项。"
                  else begin
                    (* 🩹 先转身面朝最近 NPC —— mod 把"提问者"猜成玩家面前那一格的角色，
                       不转身的话它拿到 null、游戏侧静默丢弃我们的回答（详见 face_nearest_npc）。 *)
                    face_nearest_npc ();
                    let use_real = get_bool args "real" false in
                    ignore (Game_api.menu_click ~option:opt ~real:use_real ());
                    Printf.eprintf "[junimo-mcp] story: 选了选项 %d（real=%b）\n%!" opt use_real
                  end
              | _ -> ignore (Game_api.key ~key:"confirm" ()));
              (* 等界面真的换屏：台词变了 / 选项变了 / 事件结束 / 对话关掉。 *)
              let changed () =
                let v = story_view (Game_state.fetch ()) in
                v.sv_line <> before.sv_line
                || v.sv_options <> before.sv_options
                || v.sv_event <> before.sv_event
                || v.sv_is_dialogue <> before.sv_is_dialogue
              in
              (* ⚠️ 只按一次（next）。绝不在"没等到变化"时补按第二下——那会跳掉一屏台词，
                 而剧情是不可回放的（用户明确要求"想玩到剧情"）。等不到就如实报当前状态。 *)
              let landed = Wait.poll_until ~timeout:2.5 ~interval:0.12 changed in
              (* 🎯 choose 的**两段式**（真机实测 2026-10-15，宠物领养事件）：
                 默认路径把答案**登记**给游戏（mod 回包 ok / key="Yes"），但**不关问题框**、
                 事件也不推进；紧接着补一发 `real=true`（mod 先设 selectedResponse 再真实点击）
                 **才让框关掉**，游戏立刻推进到下一幕（"给宠物起名"）。
                 ⇒ 默认没推进时自动补这一发。用户显式给了 real 就尊重他的选择，不自动补。 *)
              if
                (not landed) && action = "choose"
                && not (get_bool args "real" false)
              then begin
                Config.info "story: 默认回答没推进 ⇒ 补一发 real=true 真实点击";
                ignore
                  (Game_api.menu_click ~option:(get_int args "option" (-1)) ~real:true ());
                ignore (Wait.poll_until ~timeout:3.0 ~interval:0.15 changed)
              end;
              let after = story_view (Game_state.fetch ()) in
              if (not after.sv_is_dialogue) && after.sv_event = None then
                "剧情 / 对话已结束（上面那一屏就是最后一句）。"
              else if
                after.sv_line = before.sv_line
                && after.sv_options = before.sv_options
              then
                let clicks =
                  if after.sv_options = [] then [] else option_clicks ()
                in
                (if action = "choose" then
                   "⚠️ 选项似乎没被接受。已知根因：mod 回答剧情问题时，把「谁在提问」猜成了\
                    玩家面前那一格的角色（`isCharacterAtTile(player.GetGrabTile())`）——剧情里\
                    提问的 NPC 常不在正前方 ⇒ 参数为 null ⇒ 游戏侧**静默丢弃**这次回答（mod 回包\
                    却看着成功）。本工具已先试着转身面朝最近的 NPC。\n\
                    还可以试：① 用 menu_click 按坐标点；② story action=choose 加 real=true（走\
                    mod 的真实点击路径，但对剧本事件可能「关掉框、不认选择」）；③ 都不行就\
                    story action=skip 跳过整段。\n"
                 else "这一屏似乎没有变化（多半是过场画面/正在播动画），再 next 一次通常就过去了。\n")
                ^ render_story ~clicks after
              else begin
                let clicks =
                  if after.sv_options = [] then [] else option_clicks ()
                in
                render_story ~clicks after
              end
            end
        | "skip" ->
            let v = story_view (Game_state.fetch ()) in
            if v.sv_event = None then "当前没有剧情事件在进行，无需跳过。"
            else begin
              ignore (Game_api.key ~key:"skip" ());
              if
                Wait.poll_until ~timeout:5.0 ~interval:0.2 (fun () ->
                    Game_state.active_event (Game_state.fetch ()) = None)
              then "已跳过整段剧情（跳过的内容不会回放）。"
              else "已发送跳过，但事件似乎还没结束——可 story action=read 看看当前状态。"
            end
        | other ->
            failwith
              (Printf.sprintf "未知 action「%s」：只支持 read / next / choose / skip。" other));
  }

let tool_menu_click =
  {
    name = "menu_click";
    description =
      "点击当前菜单：按选项 index（对话选项）、按按钮名（ok/cancel/back/close 或按钮名）、\
       或按屏幕坐标 x+y。什么时候用：处理对话选项、商店购买、确认框。\
       注意：至少提供 option / button / x+y 之一；选项的 index 从 menu_read 结果里取。";
    schema =
      obj_schema
        [
          ("option", p_int ~minimum:0 "对话选项 index（从 menu_read 取）");
          ("button", p_str "按钮名（ok/cancel/back/close 等）");
          ("x", p_int "点击坐标 x（需同时给 y）");
          ("y", p_int "点击坐标 y（需同时给 x）");
          ( "real",
            p_bool
              "对话选项走 mod 的真实点击路径（默认 false，走 Event.answerDialogueQuestion）。\
               剧本事件的问题框若默认点了没反应可试 true——但脚本可能不认这次选择，慎用" );
        ];
    with_strip = true;
    run =
      (fun args ->
        let option = arg_int args "option" in
        let button = arg_str args "button" in
        let x = arg_int args "x" in
        let y = arg_int args "y" in
        let real = arg_bool args "real" in
        if option = None && button = None && not (x <> None && y <> None) then
          failwith "至少提供 option / button / x+y 之一作为点击目标";
        let res = Game_api.menu_click ?option ?button ?x ?y ?real () in
        Wait.settle ();
        let clicked =
          match Game_state.member "clicked" res with
          | Some v -> Game_state.to_str v
          | None -> "ok"
        in
        let st = Game_state.fetch () in
        let after =
          match st.active_menu with
          | Some m -> Printf.sprintf "菜单仍开着：%s。" m
          | None -> "菜单已关闭。"
        in
        Printf.sprintf "已点击菜单（%s）。%s" clicked after);
  }

(* ---------- 物品组 ---------- *)

let tool_select_item =
  {
    name = "select_item";
    description =
      "从背包选中一件物品拿在手上（工具栏槽位）。什么时候用：播种前选种子、换手持工具。\
       注意：名字要和背包里的一致（不区分大小写），如 Parsnip Seeds / Hoe / Watering Can。";
    schema = obj_schema [ ("name", p_str "物品名（必填），如 Parsnip Seeds") ];
    with_strip = true;
    run =
      (fun args ->
        let name = need_str args "name" in
        let _ = require_no_menu () in
        let res = Game_api.select ~name () in
        let sel =
          match Game_state.member "selected" res with
          | Some v -> Game_state.to_str v
          | None -> name
        in
        let slot = Game_state.get_int res [ "slot" ] in
        Printf.sprintf "已选中：%s（工具栏槽位 %d）。" sel slot);
  }

(* ---------- 农活组（复合编排） ---------- *)

(* ---------- /tool_area 批量快路径（批次 3，2026-10-14） ----------

   逐格路径每格要「站位→转身→挥动→结算」（约 0.55~0.9s/格），格数一多就线性堆积。
   mod 的 `/tool_area` 用**真蓄力挥动**按矩形一次干完整片（自带补漏、壶空如实报、
   设备避让），格数越多越划算。

   但**升级等级 = 0 时批量毫无收益**（蓄力范围 1×1 ⇒ mod 每格生成一个锚点），
   所以 auto 模式只在 `currentToolUpgrade ≥ 1` 且格数 ≥ 阈值时启用。
   无论走哪条路，**成功与否都由我们独立回读核验**（不拿 mod 的回执当结论）。 *)

(* 当前手持工具的升级等级（0=铜/基础，1=铜，2=钢，3=金，4=铱）。
   Remix 的 /state 给 player.currentToolUpgrade；旧 mod 没这字段 → 0（= 不启用批量）。 *)
let tool_upgrade_of (st : Game_state.t) : int =
  Game_state.get_int st.raw [ "player"; "currentToolUpgrade" ]

let area_enabled ~(cells : int) ~(upgrade : int) : bool =
  match Config.area_impl () with
  | "off" -> false
  | "force" -> cells >= Config.area_min_cells ()
  | _ -> upgrade >= 1 && cells >= Config.area_min_cells ()

let tile_tilled (t : Yojson.Safe.t) =
  Game_state.get_str t [ "terrain" ] = "HoeDirt"

let tile_watered (t : Yojson.Safe.t) =
  match Game_state.member "watered" t with Some (`Bool b) -> b | _ -> false

(* 用 /tool_area 干完整片矩形，并**独立回读**核验。
   返回 None ⇒ 本路径不可用 / 被 mod 拒绝（调用方回退逐格，行为与旧版一致）。
   verify t = 目标终态是否已达成（till=已成 HoeDirt；water=已浇水）。 *)
let run_area ~(operation : string) ~(cells : (int * int) list)
    ~(verify : Yojson.Safe.t option -> bool) : (exec_result * string list) option
    =
  let xs = List.map fst cells and ys = List.map snd cells in
  let x1 = List.fold_left min max_int xs and x2 = List.fold_left max min_int xs in
  let y1 = List.fold_left min max_int ys and y2 = List.fold_left max min_int ys in
  let select_tool () =
    ignore
      (Game_api.select
         ~name:(if operation = "water" then "Watering Can" else "Hoe")
         ())
  in
  let attempt () =
    match
      try Ok (Game_api.tool_area ~max_time:(Config.area_timeout ()) ~operation
                ~x1 ~y1 ~x2 ~y2 ())
      with e -> Error (Printexc.to_string e)
    with
    | Error e -> `Unavailable e
    | Ok j ->
        let ok =
          match Game_state.member "ok" j with Some (`Bool b) -> b | _ -> false
        in
        if ok then `Done j
        else
          `Rejected
            (match Game_state.member "error" j with
            | Some v -> Game_state.to_str v
            | None -> "未给原因")
  in
  select_tool ();
  match attempt () with
  | `Unavailable e ->
      Config.info "tool_area 不可用（%s）→ 回退逐格" e;
      None
  | `Rejected why ->
      Config.info "tool_area 被拒（%s）→ 回退逐格" why;
      None
  | `Done j ->
      let out_of_water j =
        match Game_state.member "out_of_water" j with
        | Some (`Bool b) -> b
        | _ -> false
      in
      (* 壶空 ⇒ 补满再浇一遍（mod 的矩形过滤只挑"还没浇的"，重浇幂等） *)
      let j =
        if out_of_water j && operation = "water" then begin
          (try ignore (Game_api.refill ()) with _ -> ());
          select_tool ();
          match attempt () with `Done j2 -> j2 | _ -> j
        end
        else j
      in
      (* 独立回读：把玩家瞬移到矩形中心再 /surroundings 覆盖整片（不是信 mod 的回执） *)
      let cx = (x1 + x2) / 2 and cy = (y1 + y2) / 2 in
      (try ignore (Game_api.position ~x:cx ~y:cy ()) with _ -> ());
      Wait.sleep_ms 150;
      let radius =
        max 1 (min 30 (max (((x2 - x1) / 2) + 1) (((y2 - y1) / 2) + 1)))
      in
      let tiles =
        try
          match Game_state.member "tiles" (Game_api.surroundings ~radius ()) with
          | Some (`List ts) -> ts
          | _ -> []
        with _ -> []
      in
      let lookup x y =
        List.find_opt
          (fun t ->
            Game_state.get_int t [ "x" ] = x && Game_state.get_int t [ "y" ] = y)
          tiles
      in
      let still =
        match Game_state.member "still_missing" j with
        | Some (`List l) -> l
        | _ -> []
      in
      let reason_of x y =
        match
          List.find_opt
            (fun m ->
              Game_state.get_int m [ "x" ] = x && Game_state.get_int m [ "y" ] = y)
            still
        with
        | Some m -> Game_state.get_str m [ "reason" ]
        | None -> ""
      in
      let ok_n = ref 0 and failed = ref [] in
      List.iter
        (fun (x, y) ->
          if verify (lookup x y) then incr ok_n
          else
            let r = reason_of x y in
            failed :=
              (x, y, if r = "" then "批量后仍未达成目标状态" else "mod 报：" ^ r)
              :: !failed)
        cells;
      (* 如实旁注：壶空、设备避让（mod 自己报的账，原样转述） *)
      let notes = ref [] in
      if out_of_water j then
        notes :=
          !notes
          @ [ "注意：浇水过程中水壶耗尽，mod 中途停手；已尝试补满重浇，剩余未浇的格见上。" ];
      (match Game_state.member "equipment_avoided" j with
      | Some (`List l) when l <> [] ->
          let names =
            l
            |> List.filter_map (fun e ->
                   let what = Game_state.get_str e [ "what" ] in
                   if what = "" then None else Some what)
          in
          notes :=
            !notes
            @ [
                Printf.sprintf
                  "注意：蓄力范围压到 %d 件设备，mod 已让开（未锄到设备上）%s。" (List.length l)
                  (if names = [] then "" else "：" ^ String.concat "、" names);
              ]
      | _ -> ());
      Some
        ( {
            total = List.length cells;
            ok_n = !ok_n;
            skip_n = 0;
            failed = List.rev !failed;
            stop_reason = None;
          },
          !notes )

let tool_till =
  {
    name = "till";
    description =
      "批量锄地：从起点 (x,y) 开始，按行数×长度锄一片地（自动站位、面朝、逐格执行）。\
       方向：horizontal（行沿 x 展开、逐行沿 y 推进）或 vertical（列沿 y 展开、逐列沿 x 推进）；\
       行序为蛇形（奇行反向），减少来回走动。什么时候用：开垦农田。\
       注意：只对可锄的泥地有效；自动跳过无法就位的格子（会在结果里列出）；体力低于 15% 自动停止。\
       锄头已升级（蓄力范围 >1 格）时，会自动改用蓄力批量（一次覆盖一片，明显更快）。";
    schema =
      obj_schema
        [
          ("x", p_int "起点格 x（必填）");
          ("y", p_int "起点格 y（必填）");
          ("rows", p_int ~minimum:1 ~maximum:30 ~default:1 "行数（默认 1）");
          ("length", p_int ~minimum:1 ~maximum:30 ~default:1 "每行格数（默认 1）");
          ("direction", p_str ~default:"horizontal" "方向：horizontal / vertical");
        ];
    with_strip = true;
    run =
      (fun args ->
        let x = need_int args "x" in
        let y = need_int args "y" in
        let rows = get_int args "rows" 1 in
        let length = get_int args "length" 1 in
        let dir = Farm.direction_of_string (get_str args "direction" "horizontal") in
        let _ = require_no_menu () in
        let cells = Farm.snake_cells ~start_x:x ~start_y:y ~rows ~length ~direction:dir () in
        (* 先选中锄头；/use 会做游戏侧校验（不可锄的格返回明确错误，而不是假成功） *)
        let _ = Game_api.select ~name:"Hoe" () in
        let what = Printf.sprintf "锄地（起点(%d,%d)，%d行×%d格）" x y rows length in
        (* 批量快路径：工具升级 ≥1（蓄力范围 >1 格）时一次干完整片；否则/失败则逐格。
           体力低于 15% 时不用批量（逐格路径会在体力耗尽前主动停手）。 *)
        let st_now = Game_state.fetch () in
        let upgrade = tool_upgrade_of st_now in
        let stamina_ok =
          match st_now.player with
          | Some p -> p.max_stamina <= 0.0 || p.stamina /. p.max_stamina >= 0.15
          | None -> true
        in
        let batch =
          if stamina_ok && area_enabled ~cells:(List.length cells) ~upgrade then
            run_area ~operation:"till" ~cells
              ~verify:(function Some t -> tile_tilled t | None -> false)
          else None
        in
        match batch with
        | Some (r, notes) -> render_exec_result ~notes ~what:(what ^ "〔批量蓄力〕") r
        | None ->
            let r =
              run_cells
                ~op:(fun tx ty ->
                  (* 不可锄的格上，mod 的 /use 会"空挥 + 假成功"（真机实测 2026-10-14：
                     返回 ok:true + 目标格，但地块毫无变化、体力照扣）——故先按 /surroundings
                     的 diggable 判一次；明确不可锄就直接记失败（不空挥，省体力）。 *)
                  match tile_info ~tx ~ty with
                  | Some t
                    when Game_state.member "diggable" t = None
                         && Game_state.get_str t [ "terrain" ] <> "HoeDirt" ->
                      Op_fail "该格不可锄（游戏侧无可耕地属性），已跳过"
                  | _ ->
                      op_use_effect ~tile:(tx, ty) ~expect:tile_tilled
                        ~soft:[ "Tile already tilled" ] ())
                cells
            in
            render_exec_result ~what r);
  }

let tool_plant =
  {
    name = "plant";
    description =
      "批量播种：先在背包选中种子，然后从起点 (x,y) 按行数×长度逐格播种（自动站位、面朝、逐格执行）。\
       什么时候用：种子种到已锄好的地里。参数与 till 相同（rows/length/direction）。\
       注意：目标格必须已经锄过且没有作物；种子必须带在身上；体力低于 15% 自动停止。";
    schema =
      obj_schema
        [
          ("seed", p_str "种子物品名（必填），如 Parsnip Seeds");
          ("x", p_int "起点格 x（必填）");
          ("y", p_int "起点格 y（必填）");
          ("rows", p_int ~minimum:1 ~maximum:30 ~default:1 "行数（默认 1）");
          ("length", p_int ~minimum:1 ~maximum:30 ~default:1 "每行格数（默认 1）");
          ("direction", p_str ~default:"horizontal" "方向：horizontal / vertical");
        ];
    with_strip = true;
    run =
      (fun args ->
        let seed = need_str args "seed" in
        let x = need_int args "x" in
        let y = need_int args "y" in
        let rows = get_int args "rows" 1 in
        let length = get_int args "length" 1 in
        let dir = Farm.direction_of_string (get_str args "direction" "horizontal") in
        let _ = require_no_menu () in
        let _ = Game_api.select ~name:seed () in
        Printf.eprintf "[junimo-mcp] plant: 已选中种子 %s\n%!" seed;
        let cells = Farm.snake_cells ~start_x:x ~start_y:y ~rows ~length ~direction:dir () in
        let r =
          run_cells
            ~op:(fun tx ty ->
              match
                op_use_effect ~tile:(tx, ty)
                  ~expect:(fun t -> Game_state.member "crop" t <> None)
                  ~soft:[] ()
              with
              | Op_fail why -> (
                  (* "Cannot place" 多为该格已有作物（重复播种）；反查确认后记软跳过 *)
                  match tile_info ~tx ~ty with
                  | Some t when Game_state.member "crop" t <> None ->
                      Op_skip "该格已有作物"
                  | _ -> Op_fail why)
              | other -> other)
            cells
        in
        render_exec_result
          ~what:
            (Printf.sprintf "播种 %s（起点(%d,%d)，%d行×%d格）" seed x y rows length)
          r);
  }

let tool_water =
  {
    name = "water";
    description =
      "自动浇水：扫描半径内所有【种了作物且未浇水】的格子，逐格浇水（自动补水、自动站位）。\
       不需要手动指定坐标——工具自己找目标。什么时候用：每天给作物浇水时首选。\
       注意：水壶空了会自动补满；体力低于 15% 自动停止；返回已浇格数。\
       水壶已升级（蓄力范围 >1 格）时会自动改用蓄力批量（一次覆盖一片，明显更快）。";
    schema =
      obj_schema
        [ ("radius", p_int ~minimum:1 ~maximum:30 ~default:15 "扫描半径（格），默认 15") ];
    with_strip = true;
    run =
      (fun args ->
        let radius = get_int args "radius" 15 in
        let _ = require_no_menu () in
        let sur = Game_api.surroundings ~radius () in
        let cells =
          match Game_state.member "tiles" sur with
          | Some (`List ts) ->
              ts
              |> List.filter_map (fun t ->
                     let terrain = Game_state.get_str t [ "terrain" ] in
                     let has_crop = Game_state.member "crop" t <> None in
                     let watered =
                       match Game_state.member "watered" t with
                       | Some (`Bool b) -> b
                       | _ -> false
                     in
                     if terrain = "HoeDirt" && has_crop && not watered then
                       Some (Game_state.get_int t [ "x" ], Game_state.get_int t [ "y" ])
                     else None)
              |> Farm.sort_row_snake
          | _ -> []
        in
        if cells = [] then "没有找到需要浇水的作物（半径内的作物都已浇水）。"
        else begin
          let _ = Game_api.refill () in
          let _ = Game_api.select ~name:"Watering Can" () in
          let what = Printf.sprintf "浇水（自动扫描半径 %d）" radius in
          (* 批量快路径：升级 ≥1 时一次浇完整片（mod 侧同样只挑"有作物且没浇的"格） *)
          let st_now = Game_state.fetch () in
          let upgrade = tool_upgrade_of st_now in
          let stamina_ok =
            match st_now.player with
            | Some p -> p.max_stamina <= 0.0 || p.stamina /. p.max_stamina >= 0.15
            | None -> true
          in
          let batch =
            if stamina_ok && area_enabled ~cells:(List.length cells) ~upgrade then
              run_area ~operation:"water" ~cells
                ~verify:(function Some t -> tile_watered t | None -> false)
            else None
          in
          match batch with
          | Some (r, notes) ->
              render_exec_result ~notes ~what:(what ^ "〔批量蓄力〕") r
          | None ->
              let r =
                run_cells
                  ~op:(fun tx ty ->
                    (* 水壶空则先补满（干活中途耗尽的情况） *)
                    (match
                       List.find_opt
                         (fun it -> it.Game_state.iname = "Watering Can")
                         (Game_state.fetch ()).inventory
                     with
                    | Some it -> (
                        match it.water with
                        | Some (left, _) when left <= 0 ->
                            ignore (Game_api.refill ());
                            ignore (Game_api.select ~name:"Watering Can" ())
                        | _ -> ())
                    | None -> ());
                    op_use_effect ~tile:(tx, ty) ~expect:tile_watered
                      ~soft:[ "Already watered" ] ())
                  cells
              in
              render_exec_result ~what r
        end);
  }

let tool_harvest =
  {
    name = "harvest";
    description =
      "收割半径内所有成熟作物（游戏内一次性完成，作物直接进背包）。什么时候用：作物成熟后收集。\
       注意：收割前用 get_inventory 确认背包有空间（背包满会掉落地面）；\
       会同时收掉所有成熟作物（不只是某几格）。";
    schema =
      obj_schema
        [ ("radius", p_int ~minimum:1 ~maximum:50 ~default:15 "收割半径（格），默认 15") ];
    with_strip = true;
    run =
      (fun args ->
        let radius = get_int args "radius" 15 in
        let _ = require_world () in
        let res = Game_api.harvest ~radius () in
        let n = Game_state.get_int res [ "harvested" ] in
        Printf.sprintf "收获完成：%d 个作物已进入背包。" n);
  }

(* ---------- 生计组（v2 新增） ---------- *)

let tool_sleep =
  {
    name = "sleep";
    description =
      "睡觉，结束当前这一天（mod 自动回床上、验证后翻日）。\
       什么时候用：一天干完要「落盘」时——星露谷只在睡觉/翻日时存档，直接关游戏会让当天白干；\
       长任务收尾建议睡一觉保住成果。返回新一天的日期/季节/体力/金币。\
       注意：睡觉后当天剩余时间不可再干活；有菜单开着会失败（先处理菜单）。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let st0 = require_world () in
        (match st0.active_menu with
        | Some m ->
            failwith (Printf.sprintf "当前有菜单打开（%s），无法睡觉。请先处理菜单。" m)
        | None -> ());
        let d0 = st0.day in
        let res = Game_api.sleep () in
        let ok =
          match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false
        in
        let state =
          match Game_state.member "state" res with
          | Some v -> Game_state.to_str v
          | None -> ""
        in
        if not ok then begin
          let err =
            match Game_state.member "error" res with
            | Some v -> Game_state.to_str v
            | None -> "未知错误"
          in
          if state = "unknown" then
            failwith
              (Printf.sprintf
                 "睡觉结果未知：%s。请先用 get_state 确认当前状态（是否在翻日），不要盲目重试。"
                 err)
          else failwith (Printf.sprintf "睡觉失败：%s" err)
        end;
        Printf.eprintf "[junimo-mcp] sleep: state=%s，等待翻日…\n%!" state;
        let rolled =
          Wait.poll_until ~timeout:150.0 ~interval:1.0 (fun () ->
              let st = Game_state.fetch () in
              st.world_ready && st.day <> d0)
        in
        let st = Game_state.fetch () in
        if not rolled then
          failwith
            (Printf.sprintf
               "已发出睡觉（state=%s），但 150 秒内没有等到翻日。请用 get_state 确认当前状态。"
               state)
        else begin
          (* 🧹 睡完常挂着 SaveGameMenu（有时还有夜间的 ShippingMenu），会把**下一次动作**
             挡掉——实测连睡第二天会被"当前有菜单打开"直接拒。这里顺手关掉，
             让"连翻多天"这种用法不用调用方自己操心。 *)
          (match st.active_menu with
          | Some m when m = "SaveGameMenu" || m = "ShippingMenu" ->
              (try ignore (Game_api.menu_close ()) with _ -> ());
              ignore
                (Wait.poll_until ~timeout:3.0 ~interval:0.25 (fun () ->
                     (Game_state.fetch ()).active_menu = None))
          | _ -> ());
          let p_desc =
            match st.player with
            | Some p ->
                Printf.sprintf "体力 %.0f/%.0f，金币 %d" p.stamina p.max_stamina
                  p.money
            | None -> "?"
          in
          Printf.sprintf "睡醒了：%s %d 日（第 %d 年）。%s。进度已写盘。"
            (Game_state.season_cn st.season) st.day st.year p_desc
        end);
  }

let tool_buy =
  {
    name = "buy";
    description =
      "远程购买物品（不开商店界面，直接扣钱进背包）。按售价 ×2 计价（mod 的便利端点）。\
       什么时候用：买种子/补给，不用跑去镇上。\
       注意：id 是游戏物品 id 字符串（\"472\" 或 \"(O)472\"）；防风草种子 = 472（已实测）；\
       其他 id 可查星露谷 wiki；钱不够会明确报错（不扣钱）。";
    schema =
      obj_schema
        [
          ("id", p_str "物品 id（必填），如 472（防风草种子）");
          ("quantity", p_int ~minimum:1 ~maximum:999 ~default:1 "购买数量，默认 1");
        ];
    with_strip = true;
    run =
      (fun args ->
        let id = need_str args "id" in
        let quantity = max 1 (get_int args "quantity" 1) in
        let _ = require_world () in
        let res = Game_api.buy ~quantity ~id () in
        Printf.sprintf "已买入：%s x%d（单价 %dg，共 %dg，余额 %dg）。"
          (Game_state.get_str res [ "bought" ])
          (Game_state.get_int res [ "quantity" ])
          (Game_state.get_int res [ "unitPrice" ])
          (Game_state.get_int res [ "totalCost" ])
          (Game_state.get_int res [ "remainingGold" ]));
  }

let tool_ship =
  {
    name = "ship";
    description =
      "把背包物品放进发货箱（=卖东西，钱次日早上结算）。需要人站在农场上（发货箱在农场）。\
       什么时候用：卖掉收获的作物/杂物。\
       注意：指定 name 只发该物品；all=true 发所有可卖品（工具/种子/装备自动保留）；\
       两者至少要给一个。";
    schema =
      obj_schema
        [
          ("name", p_str "物品名（可选），如 Parsnip");
          ( "all",
            `Assoc
              [
                ("type", `String "boolean");
                ("default", `Bool false);
                ("description", `String "发货所有可卖物品（保留工具/种子/装备）");
              ] );
        ];
    with_strip = true;
    run =
      (fun args ->
        let name = arg_str args "name" in
        let all =
          match Game_state.member "all" args with Some (`Bool b) -> b | _ -> false
        in
        if (not all)
           && match name with None | Some "" -> true | _ -> false
        then failwith "至少指定 name（发某物品）或 all=true（发所有可卖品）之一";
        let _ = require_world () in
        let res = Game_api.sell ?name ~all () in
        let sold =
          match Game_state.member "sold" res with Some (`List l) -> l | _ -> []
        in
        if sold = [] then "没有物品被放入发货箱（背包里没有匹配的可卖物品）。"
        else begin
          let total =
            List.fold_left
              (fun acc it -> acc + Game_state.get_int it [ "price" ])
              0 sold
          in
          let lines =
            List.map
              (fun it ->
                Printf.sprintf "%s x%d（%dg）"
                  (Game_state.get_str it [ "item" ])
                  (Game_state.get_int it [ "count" ])
                  (Game_state.get_int it [ "price" ]))
              sold
          in
          Printf.sprintf "已放入发货箱 %d 项（预计明早结算，合计约 %dg）：%s。"
            (List.length sold) total (String.concat "、" lines)
        end);
  }

let tool_chest_read =
  {
    name = "chest_read";
    description =
      "读取指定格上箱子的内容（不需要打开箱子，同地图任意距离可读）。\
       什么时候用：查看箱子里有什么（找工具/材料/种子）。返回物品名+数量清单。\
       注意：只读；「从箱子取出来」不在自动化范围内（mod 没有该端点），需要手动操作。";
    schema =
      obj_schema
        [ ("x", p_int "箱子所在格 x（必填）"); ("y", p_int "箱子所在格 y（必填）") ];
    with_strip = true;
    run =
      (fun args ->
        let x = need_int args "x" in
        let y = need_int args "y" in
        let _ = require_world () in
        let res = Game_api.chest ~x ~y () in
        let items =
          match Game_state.member "items" res with Some (`List l) -> l | _ -> []
        in
        let used = Game_state.get_int res [ "used" ] in
        let cap = Game_state.get_int res [ "capacity" ] in
        let lines =
          List.mapi
            (fun i it ->
              Printf.sprintf "  %d. %s x%d" (i + 1)
                (Game_state.get_str it [ "name" ])
                (Game_state.get_int it [ "count" ]))
            items
        in
        Printf.sprintf "箱子 (%d,%d)：%d/%d 格。\n%s" x y used cap
          (String.concat "\n" lines));
  }

let tool_chest_store =
  {
    name = "chest_store";
    description =
      "把背包里的物品存进指定格的箱子（需同地图；工具默认保留）。\
       什么时候用：清理背包、把杂物/材料收进箱子。\
       注意：mod 只提供「存进箱子」；「取出来」需手动。";
    schema =
      obj_schema
        [
          ("x", p_int "箱子所在格 x（必填）");
          ("y", p_int "箱子所在格 y（必填）");
          ("name", p_str "只存这个物品名（可选；不填=存所有非工具物品）");
          ("keepTools", `Assoc [
             ("type", `String "boolean");
             ("default", `Bool true);
             ("description", `String "保留工具不存（默认 true）");
           ]);
        ];
    with_strip = true;
    run =
      (fun args ->
        let x = need_int args "x" in
        let y = need_int args "y" in
        let name = arg_str args "name" in
        let keep_tools =
          match Game_state.member "keepTools" args with
          | Some (`Bool b) -> b
          | _ -> true
        in
        let _ = require_world () in
        let res = Game_api.store ~x ~y ?name ~keep_tools () in
        let stored =
          match Game_state.member "stored" res with Some (`List l) -> l | _ -> []
        in
        if stored = [] then "没有物品被存入（背包里没有匹配项，或工具被 keepTools 保留）。"
        else
          let lines =
            List.map
              (fun it ->
                Printf.sprintf "%s x%d"
                  (Game_state.get_str it [ "item" ])
                  (Game_state.get_int it [ "count" ]))
              stored
          in
          Printf.sprintf "已存入箱子 (%d,%d)：%s。" x y (String.concat "、" lines));
  }

let tool_map_info =
  {
    name = "map_info";
    description =
      "读取当前地图的建筑、传送点、NPC/动物情报（结构化）。\
       什么时候用：规划路线（知道门在哪、哪能传送）、了解设施布局。\
       注意：这是静态布局信息；实时格子通行性用 look。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let _ = require_world () in
        let res = Game_api.map () in
        let b = Buffer.create 256 in
        Buffer.add_string b
          (Printf.sprintf "【地图】%s（%dx%d）\n"
             (Game_state.get_str res [ "location"; "name" ])
             (Game_state.get_int res [ "location"; "width" ])
             (Game_state.get_int res [ "location"; "height" ]));
        (match Game_state.member "buildings" res with
        | Some (`List bl) when bl <> [] ->
            Buffer.add_string b "【建筑】\n";
            List.iter
              (fun t ->
                let door =
                  match
                    (Game_state.member "doorX" t, Game_state.member "doorY" t)
                  with
                  | Some dx, Some dy ->
                      Printf.sprintf "，门(%d,%d)" (Game_state.to_int dx)
                        (Game_state.to_int dy)
                  | _ -> ""
                in
                Buffer.add_string b
                  (Printf.sprintf "  %s (%d,%d) %dx%d%s\n"
                     (Game_state.get_str t [ "type" ])
                     (Game_state.get_int t [ "x" ])
                     (Game_state.get_int t [ "y" ])
                     (Game_state.get_int t [ "width" ])
                     (Game_state.get_int t [ "height" ])
                     door))
              bl
        | _ -> ());
        (match Game_state.member "warps" res with
        | Some (`List wl) when wl <> [] ->
            Buffer.add_string b "【传送点】（走过去即切换地图）\n";
            List.iter
              (fun t ->
                Buffer.add_string b
                  (Printf.sprintf "  (%d,%d) → %s(%d,%d)\n"
                     (Game_state.get_int t [ "x" ])
                     (Game_state.get_int t [ "y" ])
                     (Game_state.get_str t [ "targetLocation" ])
                     (Game_state.get_int t [ "targetX" ])
                     (Game_state.get_int t [ "targetY" ])))
              wl
        | _ -> ());
        let cnt k =
          match Game_state.member k res with
          | Some (`List l) -> List.length l
          | _ -> 0
        in
        Buffer.add_string b
          (Printf.sprintf "【NPC】%d 人；【动物】%d 只" (cnt "npcs") (cnt "animals"));
        Buffer.contents b);
  }

let tool_pause_time =
  {
    name = "pause_time";
    description =
      "冻结游戏内时钟（角色仍可活动、全部 API 可用）。\
       什么时候用：连续干活/长测试但不想让时间流逝（游戏内到 2:00 会晕倒扣 10% 金币）；\
       让 Agent 慢慢规划也不消耗游戏时间。\
       注意：干完记得 resume_time，否则时间一直停着。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let _ = require_world () in
        let res = Game_api.pause () in
        let t = Game_state.get_int res [ "frozenAt" ] in
        Printf.sprintf
          "游戏时钟已冻结在 %02d:%02d（角色仍可活动）。完成后请用 resume_time 恢复。"
          (t / 100) (t mod 100));
  }

let tool_resume_time =
  {
    name = "resume_time";
    description = "恢复被 pause_time 冻结的游戏时钟。什么时候用：冻结时间的长任务干完了。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let _ = require_world () in
        let _ = Game_api.resume () in
        "游戏时钟已恢复流动。");
  }

(* ---------- v3 组（NagiBridge-Remix 新端点，2026-10-13） ---------- *)

(* 找子串最后一次出现的位置（支持多字节字符，如 "×"；OCaml 的 char 字面量装不下） *)
let rfind_sub (s : string) (sub : string) : int option =
  let n = String.length s and m = String.length sub in
  if m = 0 || m > n then None
  else
    let rec go i =
      if i < 0 then None
      else if String.sub s i m = sub then Some i
      else go (i - 1)
    in
    go (n - m)

(* "Potato x 5" / "Fiber×2" / "Salad" → ("Potato", Some 5) / ("Fiber", Some 2) / ("Salad", None) *)
let parse_item_spec (s : string) : (string * int option) option =
  let s = String.trim s in
  if s = "" then None
  else
    let try_split sep =
      match rfind_sub s sep with
      | Some i ->
          let name = String.trim (String.sub s 0 i) in
          let num =
            String.trim
              (String.sub s (i + String.length sep)
                 (String.length s - i - String.length sep))
          in
          if name <> "" && num <> ""
             && (try ignore (int_of_string num); true with _ -> false)
          then Some (name, Some (int_of_string num))
          else None
      | None -> None
    in
    match try_split "×" with
    | Some r -> Some r
    | None -> (
        match try_split "x" with
        | Some r -> Some r
        | None -> (
            match try_split "X" with
            | Some r -> Some r
            | None -> Some (s, None)))

let tool_eat =
  {
    name = "eat";
    description =
      "吃东西（消耗 1 个）：回复体力/HP、获得食物 buff。给 name 就先从背包选中该食物再吃；\
       不给则吃当前手持物。什么时候用：体力不够时回体力、吃饭拿 buff（如加速/幸运）。\
       注意：吃的时候会清掉进行中的走位（边走边吃吃不上，属正常）；\
       若返回「没结算/被打断」（物品没扣），站稳原地再吃一次即可。";
    schema = obj_schema [ ("name", p_str "食物名（可选），如 Cheese、Salad；不填=吃手持物") ];
    with_strip = true;
    run =
      (fun args ->
        let name = arg_str args "name" in
        let st0 = require_world () in
        (match st0.active_menu with
        | Some m ->
            failwith (Printf.sprintf "当前有菜单打开（%s），先处理菜单再吃东西。" m)
        | None -> ());
        (match name with
        | Some n when n <> "" -> ignore (Game_api.select ~name:n ())
        | _ -> ());
        let res = Game_api.eat () in
        let ok = match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false in
        if not ok then begin
          let err =
            match Game_state.member "error" res with
            | Some v -> Game_state.to_str v
            | None -> "未知错误"
          in
          failwith (Printf.sprintf "吃东西失败：%s" err)
        end;
        let ate = Game_state.get_str res [ "ate" ] in
        let hp0 = Game_state.get_int res [ "hpBefore" ] in
        let hp1 = Game_state.get_int res [ "hpAfter" ] in
        let sta0 = Game_state.get_int res [ "staBefore" ] in
        let sta1 = Game_state.get_int res [ "staAfter" ] in
        let nb0 = Game_state.get_int res [ "buffsBefore" ] in
        let nb1 = Game_state.get_int res [ "buffsAfter" ] in
        let changed =
          match Game_state.member "statsChanged" res with
          | Some (`Bool b) -> b
          | _ -> true
        in
        let b = Buffer.create 128 in
        Buffer.add_string b
          (Printf.sprintf "已吃下 %s：HP %d→%d，体力 %d→%d" ate hp0 hp1 sta0 sta1);
        if nb1 <> nb0 then Buffer.add_string b (Printf.sprintf "，buffs %d→%d" nb0 nb1);
        Buffer.add_string b "。";
        if not changed then
          Buffer.add_string b "（数值没变——多半本来就满，或续了同一个 buff 槽）";
        Buffer.contents b);
  }

let tool_gift =
  {
    name = "gift";
    description =
      "给 NPC 送礼（真实送礼流程，消耗 1 个物品）：返回对方喜好档位和好感变化。\
       什么时候用：提升与 NPC 的好感度（好感影响剧情/奖励）。\
       注意：游戏规则每天每人 1 次、每周 2 次（送满会明确报错并退回物品，不白花）；\
       target 中英文名均可；人要在这个 NPC 所在的地图（同图即可触发）；不能作为礼物的物品会被拒绝。";
    schema =
      obj_schema
        [
          ("target", p_str "NPC 名（必填），如 Abigail 或 阿比盖尔");
          ("item", p_str "礼物物品名（必填），如 Cheese");
        ];
    with_strip = true;
    run =
      (fun args ->
        let target = need_str args "target" in
        let item = need_str args "item" in
        let _ = require_world () in
        let res = Game_api.gift ~target ~item () in
        let ok = match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false in
        if not ok then begin
          let err =
            match Game_state.member "error" res with
            | Some v -> Game_state.to_str v
            | None -> "未知错误"
          in
          failwith (Printf.sprintf "送礼失败：%s" err)
        end;
        let act = Game_state.get_str res [ "action" ] in
        if act <> "gifted_npc" then
          Printf.sprintf "已执行送礼动作（%s）：%s。" act
            (Game_state.get_str res [ "note" ])
        else
          let tgt = Game_state.get_str res [ "target" ] in
          let it = Game_state.get_str res [ "item" ] in
          let taste = Game_state.get_str res [ "tasteLabel" ] in
          let fb = Game_state.get_int res [ "friendshipBefore" ] in
          let fa = Game_state.get_int res [ "friendshipAfter" ] in
          let delta = Game_state.get_int res [ "delta" ] in
          Printf.sprintf "已给 %s 送 %s（评价：%s）。好感 %d→%d（%+d 点）。" tgt it taste
            fb fa delta);
  }

let tool_friendship =
  {
    name = "friendship";
    description =
      "查询与某个 NPC 的好感度：点数、心数、本周已送次数、今天已送次数。\
       什么时候用：送礼前后查变化；了解关系进度。\
       注意：中英文名均可（中文名会自动解析成内部名再查）；没认识/没记录的人返回 0。";
    schema = obj_schema [ ("npc", p_str "NPC 名（必填），如 Abigail 或 阿比盖尔") ];
    with_strip = true;
    run =
      (fun args ->
        let npc = need_str args "npc" in
        let _ = require_world () in
        let render res =
          let known =
            match Game_state.member "known" res with
            | Some (`Bool b) -> b
            | _ -> false
          in
          let name = Game_state.get_str res [ "npc" ] in
          if not known then
            Printf.sprintf "没有与 %s 的好感记录（名字可能不对，或还没认识该 NPC）。" name
          else
            Printf.sprintf "%s：好感 %d 点（%d 心），本周已送 %d/2 次，今天已送 %d/1 次。"
              name
              (Game_state.get_int res [ "points" ])
              (Game_state.get_int res [ "hearts" ])
              (Game_state.get_int res [ "giftsThisWeek" ])
              (Game_state.get_int res [ "giftsToday" ])
        in
        let res = Game_api.friendship ~npc () in
        let known =
          match Game_state.member "known" res with
          | Some (`Bool b) -> b
          | _ -> false
        in
        if known then render res
        else begin
          (* 中文名/别名 → 通过 find_npc 解析内部英文名后重查一次 *)
          let fres = Game_api.find_npc ~name:npc () in
          match Game_state.member "npcs" fres with
          | Some (`List (first :: _)) ->
              let en = Game_state.get_str first [ "name" ] in
              if en <> "" && en <> npc then render (Game_api.friendship ~npc:en ())
              else render res
          | _ -> render res
        end);
  }

let tool_find_npc =
  {
    name = "find_npc";
    description =
      "在全部地图里查找 NPC（中英文名，支持模糊匹配）：返回所在位置、坐标、朝向、\
       是否在睡觉、正在说的话。什么时候用：送礼/对话前定位某人；确认对方在不在家。\
       注意：跨区域也能找到（含建筑内部）；但只有当前地图的人才能当面互动（送礼/对话）。";
    schema = obj_schema [ ("name", p_str "NPC 名（必填），如 Abigail、罗宾") ];
    with_strip = true;
    run =
      (fun args ->
        let name = need_str args "name" in
        let _ = require_world () in
        let res = Game_api.find_npc ~name () in
        let cnt = Game_state.get_int res [ "count" ] in
        let npcs =
          match Game_state.member "npcs" res with Some (`List l) -> l | _ -> []
        in
        if cnt = 0 then
          failwith (Printf.sprintf "没有找到叫「%s」的 NPC（试试别的写法/英文名）。" name);
        let b = Buffer.create 200 in
        Buffer.add_string b (Printf.sprintf "找到 %d 个匹配「%s」：" cnt name);
        List.iter
          (fun n ->
            let nm = Game_state.get_str n [ "name" ] in
            let dn = Game_state.get_str n [ "displayName" ] in
            let loc = Game_state.get_str n [ "location" ] in
            let x = Game_state.get_int n [ "x" ] in
            let y = Game_state.get_int n [ "y" ] in
            let sleeping =
              match Game_state.member "isSleeping" n with
              | Some (`Bool true) -> "（睡觉中）"
              | _ -> ""
            in
            let dlg =
              match Game_state.member "dialogue" n with
              | Some (`String d) when d <> "" -> Printf.sprintf "，说：「%s」" d
              | _ -> ""
            in
            let name_part =
              if dn = "" || dn = nm then nm
              else Printf.sprintf "%s（%s）" nm dn
            in
            Buffer.add_string b
              (Printf.sprintf "\n  · %s @ %s(%d,%d)%s%s" name_part loc x y sleeping
                 dlg))
          npcs;
        Buffer.contents b);
  }

let tool_chest_scan =
  {
    name = "chest_scan";
    description =
      "扫描当前地图所有箱子的位置和内容（只读，不打开箱子）。什么时候用：找东西在哪个箱子、\
       盘点库存、取物（chest_take）前确认箱子和格号。\
       注意：只列当前地图；跨地图要找箱先换图再扫。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let _ = require_world () in
        let res = Game_api.scan_chests () in
        let loc = Game_state.get_str res [ "location" ] in
        let count = Game_state.get_int res [ "count" ] in
        let chests =
          match Game_state.member "chests" res with Some (`List l) -> l | _ -> []
        in
        if chests = [] then Printf.sprintf "当前地图（%s）没有找到箱子。" loc
        else begin
          let b = Buffer.create 400 in
          Buffer.add_string b (Printf.sprintf "当前地图 %s 共 %d 个箱子：" loc count);
          List.iter
            (fun c ->
              let x = Game_state.get_int c [ "x" ] in
              let y = Game_state.get_int c [ "y" ] in
              let nm = Game_state.get_str c [ "name" ] in
              let tag = Game_state.get_str c [ "autoTag" ] in
              let used = Game_state.get_int c [ "used" ] in
              let cap = Game_state.get_int c [ "capacity" ] in
              let label =
                match (nm, tag) with
                | "", "" -> ""
                | "", t -> Printf.sprintf " [%s]" t
                | n, "" -> Printf.sprintf " %s" n
                | n, t -> Printf.sprintf " %s[%s]" n t
              in
              Buffer.add_string b
                (Printf.sprintf "\n【(%d,%d)%s】%d/%d 格" x y label used cap);
              (match Game_state.member "items" c with
              | Some (`List items) when items <> [] ->
                  Buffer.add_string b "\n";
                  List.iter
                    (fun it ->
                      let iname =
                        match Game_state.get_str it [ "displayName" ] with
                        | "" -> Game_state.get_str it [ "name" ]
                        | d -> d
                      in
                      Buffer.add_string b
                        (Printf.sprintf "    %d. %s x%d\n"
                           (Game_state.get_int it [ "slot" ])
                           iname
                           (Game_state.get_int it [ "count" ])))
                    items
              | _ -> Buffer.add_string b "（空）"))
            chests;
          String.trim (Buffer.contents b)
        end);
  }

let tool_chest_take =
  {
    name = "chest_take";
    description =
      "从指定位置的箱子里取出物品（取到背包）。什么时候用：取物资/材料/工具——\
       先用 chest_scan 找到箱子，再用 name（物品名）或 slot（箱子里的格号）取。\
       注意：name 支持中英文；同名多格用 slot 精确挑；count 不填 = 取全部；\
       背包放不下时未取的部分留在箱子里（回执如实）。";
    schema =
      obj_schema
        [
          ("x", p_int "箱子格 x（必填）");
          ("y", p_int "箱子格 y（必填）");
          ("name", p_str "物品名（给 name 或 slot 至少一个）");
          ("slot", p_int "箱子里的格号（给 name 或 slot 至少一个，见 chest_scan）");
          ("count", p_int ~minimum:1 "取的数量（不填=全部）");
        ];
    with_strip = true;
    run =
      (fun args ->
        let x = need_int args "x" in
        let y = need_int args "y" in
        let name = arg_str args "name" in
        let slot = arg_int args "slot" in
        let count = arg_int args "count" in
        if (match name with None | Some "" -> true | _ -> false) && slot = None
        then failwith "至少给 name（物品名）或 slot（箱子格号）之一";
        let _ = require_world () in
        let res = Game_api.chest_take ~x ~y ?name ?slot ?count () in
        let taken = Game_state.get_int res [ "taken" ] in
        let item = Game_state.get_str res [ "item" ] in
        if taken <= 0 then
          Printf.sprintf
            "没有取出任何物品（箱子 (%d,%d) 里没有匹配「%s」的东西，或背包放不下）。" x y
            item
        else Printf.sprintf "已取出 %s x%d（来自箱子 (%d,%d)）。" item taken x y);
  }

let tool_chest_take_list =
  {
    name = "chest_take_list";
    description =
      "跨箱批量取物：自动从「够得着」（约 4 格内）的所有箱子里凑齐清单物品，一次取完。\
       items 数组每项格式：\"物品名\"（取全部）或 \"物品名 xN\" / \"物品名×N\"（取 N 个）。\
       什么时候用：要好几样东西、又记不清哪个箱子有。\
       注意：先人肉走到箱子附近（远箱会列在「够不着」里给出坐标）；取不到的如实列出。";
    schema =
      obj_schema
        [
          ( "items",
            `Assoc
              [
                ("type", `String "array");
                ("items", `Assoc [ ("type", `String "string") ]);
                ("description", `String "物品清单，如 [\"Parsnip Seeds x5\", \"Fiber\"]");
              ] );
        ];
    with_strip = true;
    run =
      (fun args ->
        let raw_items =
          match Game_state.member "items" args with
          | Some (`List l) -> l
          | _ -> []
        in
        let specs =
          List.filter_map
            (fun j -> parse_item_spec (Game_state.to_str j))
            raw_items
        in
        if specs = [] then failwith "items 至少给一项（字符串数组）";
        let _ = require_world () in
        let res = Game_api.chest_take_list ~items:specs () in
        let loc = Game_state.get_str res [ "location" ] in
        let items =
          match Game_state.member "items" res with Some (`List l) -> l | _ -> []
        in
        let too_far =
          match Game_state.member "tooFar" res with Some (`List l) -> l | _ -> []
        in
        let b = Buffer.create 300 in
        Buffer.add_string b (Printf.sprintf "跨箱取物（%s）：" loc);
        List.iter
          (fun it ->
            let nm = Game_state.get_str it [ "item" ] in
            let taken = Game_state.get_int it [ "taken" ] in
            let wanted = Game_state.get_int it [ "wanted" ] in
            match Game_state.member "from" it with
            | Some (`List srcs) when taken > 0 ->
                let parts =
                  List.map
                    (fun s ->
                      let nm = Game_state.get_str s [ "name" ] in
                      let label =
                        if nm <> "" then nm
                        else
                          Printf.sprintf "(%d,%d)"
                            (Game_state.get_int s [ "x" ])
                            (Game_state.get_int s [ "y" ])
                      in
                      Printf.sprintf "%s x%d" label (Game_state.get_int s [ "got" ]))
                    srcs
                in
                Buffer.add_string b
                  (Printf.sprintf "\n  · %s：取到 %d 个（%s）" nm taken
                     (String.concat "、" parts))
            | _ ->
                let want_note =
                  if wanted > 0 then Printf.sprintf "（想要 %d 个）" wanted else ""
                in
                Buffer.add_string b (Printf.sprintf "\n  · %s：没找到%s" nm want_note))
          items;
        if too_far <> [] then begin
          Buffer.add_string b "\n还有箱子够不着（走到 4 格内再叫一次）：";
          List.iter
            (fun t ->
              let nm = Game_state.get_str t [ "name" ] in
              Buffer.add_string b
                (Printf.sprintf " (%d,%d)%s" (Game_state.get_int t [ "x" ])
                   (Game_state.get_int t [ "y" ])
                   (if nm = "" then "" else nm)))
            too_far
        end;
        Buffer.contents b);
  }

(* 节日日历（SDV 1.6 原版固定日期） *)
let festival_calendar =
  [
    ("spring", 13, "蛋蛋节（Egg Festival）");
    ("spring", 24, "花舞节（Flower Dance）");
    ("summer", 11, "夏威夷宴会（Luau）");
    ("summer", 28, "月光水母节（Dance of the Moonlight Jellies）");
    ("fall", 16, "星露谷集市（Stardew Valley Fair）");
    ("fall", 27, "万灵节（Spirit's Eve）");
    ("winter", 8, "冰雪节（Festival of Ice）");
    ("winter", 25, "冬星节（Feast of the Winter Star）");
  ]

let season_idx_of = function
  | "spring" -> 0
  | "summer" -> 1
  | "fall" -> 2
  | "winter" -> 3
  | _ -> 0

let festival_name_on season day =
  match
    List.find_opt (fun (s, d, _) -> s = season && d = day) festival_calendar
  with
  | Some (_, _, n) -> Some n
  | None -> None

let tool_festival =
  {
    name = "festival";
    description =
      "节日情报：今天/明天是不是节日、下一个节日还有几天；若节日活动正在进行，\
       额外返回现场状态（地点、限时小游戏倒计时、当前分数）。\
       什么时候用：规划节日当天行程；进节日场地后看活动进度。\
       注意：参加节日要自己走到节日场地（游戏原生入口触发）；节日当天 NPC 都在场地里。";
    schema = obj_schema [];
    with_strip = true;
    run =
      (fun _ ->
        let st = require_world () in
        let b = Buffer.create 200 in
        let today_f = festival_name_on st.season st.day in
        let tomorrow_season, tomorrow_day =
          if st.day < 28 then (st.season, st.day + 1)
          else
            match season_idx_of st.season with
            | 0 -> ("summer", 1)
            | 1 -> ("fall", 1)
            | 2 -> ("winter", 1)
            | _ -> ("spring", 1)
        in
        let tomorrow_f = festival_name_on tomorrow_season tomorrow_day in
        (match today_f with
        | Some n ->
            Buffer.add_string b
              (Printf.sprintf "【今天】%s 是%s！\n" (Game_state.season_cn st.season) n)
        | None -> ());
        (match tomorrow_f with
        | Some n ->
            Buffer.add_string b
              (Printf.sprintf "【明天】%s %d 日是%s。\n"
                 (Game_state.season_cn tomorrow_season)
                 tomorrow_day n)
        | None -> ());
        let td = (season_idx_of st.season * 28) + st.day in
        let upcoming =
          festival_calendar
          |> List.filter_map (fun (s, d, n) ->
                 let yd = (season_idx_of s * 28) + d in
                 let delta = if yd > td then yd - td else yd + 112 - td in
                 if delta <= 0 then None else Some (delta, n))
          |> List.sort compare
        in
        (match upcoming with
        | (delta, n) :: _ ->
            Buffer.add_string b
              (Printf.sprintf "【下一个节日】还有 %d 天：%s。\n" delta n)
        | [] -> ());
        let live = try Some (Game_api.festival_raw ()) with _ -> None in
        (* ⚠️ /festival 只要「有事件播放中」就返回 ok:true（不等于在过节！）——
           必须再看 isFestival / festivalName 才能判定"节日活动进行中"（v3 真机修正）。 *)
        let is_live res =
          (match Game_state.member "ok" res with
          | Some (`Bool true) -> true
          | _ -> false)
          && (match Game_state.member "isFestival" res with
             | Some (`Bool true) -> true
             | _ -> Game_state.get_str res [ "festivalName" ] <> "")
        in
        (match live with
        | Some res when is_live res ->
            let name = Game_state.get_str res [ "festivalName" ] in
            let loc = Game_state.get_str res [ "location" ] in
            let timer = Game_state.get_int res [ "festivalTimer" ] in
            let score = Game_state.get_int res [ "festivalScore" ] in
            Buffer.add_string b
              (Printf.sprintf "【进行中】节日活动正在 %s 进行（%s）" loc name);
            if timer > 0 then
              Buffer.add_string b (Printf.sprintf "，限时小游戏计数 %d" timer);
            Buffer.add_string b (Printf.sprintf "，当前分数 %d。" score)
        | _ ->
            Buffer.add_string b
              "【进行中】当前没有节日活动（不在节日场地/今天不是节日）。");
        Buffer.contents b);
  }

let tool_festival_interact =
  {
    name = "festival_interact";
    description =
      "节日/活动场景里与指定 NPC 交互（自动在活动场地内站到其身旁并触发动作）。\
       什么时候用：节日小游戏、节日里的 NPC 互动推进。\
       注意：只适用于「活动进行中」的场景（没有活动时调用会报 No active event）；\
       name 不给则选活动里第一个 actor；普通过场事件用 interact/press_key 更通用。";
    schema = obj_schema [ ("name", p_str "NPC 名（可选），如 罗宾 / Robin") ];
    with_strip = true;
    run =
      (fun args ->
        let name = arg_str args "name" in
        let _ = require_world () in
        let res = Game_api.festival_interact ?name () in
        let ok =
          match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false
        in
        if not ok then begin
          let err =
            match Game_state.member "error" res with
            | Some v -> Game_state.to_str v
            | None -> "未知错误"
          in
          failwith (Printf.sprintf "节日交互失败：%s" err)
        end;
        Wait.settle ();
        Printf.sprintf "已与 %s 交互（站位 %s）。"
          (Game_state.get_str res [ "target" ])
          (match Game_state.member "standPicked" res with
          | Some (`Bool true) -> "已挑好"
          | _ -> "退回了默认位"));
  }

let tool_festival_answer =
  {
    name = "festival_answer";
    description =
      "在活动/对话中提交选项答案（节日问答类小游戏专用通道）。answer 是选项序号（0 起）。\
       什么时候用：节日问答、活动中的分支选择（比 menu_click 更低层的节日通道）。\
       注意：只在活动进行中可用；选项序号与 menu_read 显示的 index 对应。";
    schema = obj_schema [ ("answer", p_int ~minimum:0 "选项序号（0 起，必填）") ];
    with_strip = true;
    run =
      (fun args ->
        let answer = need_int args "answer" in
        let _ = require_world () in
        let res = Game_api.festival_answer ~answer () in
        let ok =
          match Game_state.member "ok" res with Some (`Bool b) -> b | _ -> false
        in
        if not ok then begin
          let err =
            match Game_state.member "error" res with
            | Some v -> Game_state.to_str v
            | None -> "未知错误"
          in
          failwith (Printf.sprintf "节日应答失败：%s" err)
        end;
        Wait.settle ();
        Printf.sprintf "已提交选项 %d（通道 %s）。" answer
          (Game_state.get_str res [ "method" ]));
  }

let all : tool list =
  [
    tool_get_state;
    tool_look;
    tool_get_inventory;
    tool_go_to;
    tool_warp;
    tool_face;
    tool_swing_tool;
    tool_use_held;
    tool_interact;
    tool_press_key;
    tool_menu_read;
    tool_story;
    tool_menu_click;
    tool_menu_close;
    tool_select_item;
    tool_till;
    tool_plant;
    tool_water;
    tool_harvest;
    (* 生计组（v2） *)
    tool_sleep;
    tool_buy;
    tool_ship;
    tool_chest_read;
    tool_chest_store;
    tool_map_info;
    tool_pause_time;
    tool_resume_time;
    (* v3 组（NagiBridge-Remix：取物/吃/社交/节日） *)
    tool_eat;
    tool_gift;
    tool_friendship;
    tool_find_npc;
    tool_chest_scan;
    tool_chest_take;
    tool_chest_take_list;
    tool_festival;
    tool_festival_interact;
    tool_festival_answer;
  ]

(* ---------- 注册表接口 ---------- *)

let find name = List.find_opt (fun t -> t.name = name) all

let tool_to_json (t : tool) : Yojson.Safe.t =
  `Assoc
    [
      ("name", `String t.name);
      ("description", `String t.description);
      ("inputSchema", t.schema);
    ]

let list_json () : Yojson.Safe.t =
  `Assoc [ ("tools", `List (List.map tool_to_json all)) ]

(* ---------- 调用与错误包装 ---------- *)

let friendly_error (t : tool) (raw : string) : string =
  match raw with
  | "World not ready" -> no_world_msg
  | msg -> Printf.sprintf "工具 %s 执行失败：%s" t.name msg

let call (name : string) (args : Yojson.Safe.t) : (string, string) result =
  match find name with
  | None ->
      Error (Printf.sprintf "未知工具：%s（可用工具见 tools/list）" name)
  | Some tool -> (
      try
        (* 基线代际：状态速报只复用"本次调用内"取过的状态（见 game_state.ml） *)
        let gen0 = Game_state.fetch_gen_count () in
        let text = tool.run args in
        let text =
          if tool.with_strip && not (Config.no_strip ()) then
            let get_st () =
              match Game_state.recent_fetch_since gen0 with
              | Some st -> st
              | None -> Game_state.fetch ()
            in
            (match get_st () with
            | st -> text ^ "\n" ^ Game_state.strip st
            | exception _ -> text)
          else text
        in
        Ok text
      with
      | Http_client.Unreachable msg ->
          Error
            (Printf.sprintf
               "NagiBridge 不可达：确认游戏正在运行且已加载 NagiBridge mod（地址 \
                http://localhost:7842）。底层错误：%s"
               msg)
      | Game_api.Api_error msg -> Error (friendly_error tool msg)
      | Failure msg -> Error msg
      | e -> Error (Printf.sprintf "工具 %s 内部错误：%s" name (Printexc.to_string e)))
