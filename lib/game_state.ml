(** /state 与 /surroundings 的解析与渲染（面向 Agent 的可读文本）。

    设计纪律：
    - worldReady:false 时 /state 只有 {ok, worldReady} 两个字段，解析必须容错。
    - 渲染层负责把 mod 的英文枚举/字段翻成中文速报（状态速报见 strip）。 *)

(* ---------- JSON 取值小工具（全部容错） ---------- *)

let to_int = function
  | `Int n -> n
  | `Float f -> int_of_float f
  | `String s -> (try int_of_string s with _ -> 0)
  | _ -> 0

let to_float = function
  | `Int n -> float_of_int n
  | `Float f -> f
  | `String s -> (try float_of_string s with _ -> 0.0)
  | _ -> 0.0

let to_str = function `String s -> s | `Int n -> string_of_int n | _ -> ""

let member k j = match j with `Assoc f -> List.assoc_opt k f | _ -> None

(* 按路径取值：get_in j ["location"; "name"] *)
let get_in j path =
  List.fold_left (fun acc k -> Option.bind acc (fun obj -> member k obj)) (Some j) path

let get_int j path = match get_in j path with Some v -> to_int v | None -> 0
let get_str j path = match get_in j path with Some v -> to_str v | None -> ""

(* ---------- 类型 ---------- *)

type player = {
  p_name : string;
  px : int;
  py : int;
  health : int;
  max_health : int;
  stamina : float;
  max_stamina : float;
  money : int;
  current_tool : string;
  facing : int;
  is_moving : bool;
}

type inv_item = {
  iname : string;
  stack : int;
  category : string;
  water : (int * int) option; (* 水壶：waterLeft / waterMax *)
}

type t = {
  world_ready : bool;
  player : player option;
  loc_name : string;
  loc_w : int;
  loc_h : int;
  time_of_day : int;
  day : int;
  season : string;
  year : int;
  weather : int option; (* /state.time.weather：0晴 1雨 2雷 3落叶 5雪 7绿雨（Remix 才有该字段） *)
  active_menu : string option;
  inventory : inv_item list;
  raw : Yojson.Safe.t;
}

(* ---------- 解析 ---------- *)

let parse_player j =
  match j with
  | `Assoc _ ->
      Some
        {
          p_name = (match member "name" j with Some v -> to_str v | None -> "?");
          px = get_int j [ "x" ];
          py = get_int j [ "y" ];
          health = get_int j [ "health" ];
          max_health = get_int j [ "maxHealth" ];
          stamina =
            (match member "stamina" j with Some v -> to_float v | None -> 0.0);
          max_stamina =
            (match member "maxStamina" j with Some v -> to_float v | None -> 0.0);
          money = get_int j [ "money" ];
          current_tool =
            (match member "currentTool" j with Some v -> to_str v | None -> "无");
          facing = get_int j [ "facingDirection" ];
          is_moving = (match member "isMoving" j with Some (`Bool b) -> b | _ -> false);
        }
  | _ -> None

let parse_item j =
  let water =
    match member "waterLeft" j with
    | Some wl -> (
        match member "waterMax" j with
        | Some wm -> Some (to_int wl, to_int wm)
        | None -> Some (to_int wl, 0))
    | None -> None
  in
  {
    iname = (match member "name" j with Some v -> to_str v | None -> "?");
    stack = (match member "stack" j with Some v -> to_int v | None -> 1);
    category = (match member "category" j with Some v -> to_str v | None -> "");
    water;
  }

let of_json (j : Yojson.Safe.t) : t =
  let world_ready =
    match member "worldReady" j with Some (`Bool b) -> b | _ -> false
  in
  {
    world_ready;
    player = (match member "player" j with Some p -> parse_player p | None -> None);
    loc_name = get_str j [ "location"; "name" ];
    loc_w = get_int j [ "location"; "mapWidth" ];
    loc_h = get_int j [ "location"; "mapHeight" ];
    time_of_day = get_int j [ "time"; "timeOfDay" ];
    day = get_int j [ "time"; "dayOfMonth" ];
    season = get_str j [ "time"; "season" ];
    year = get_int j [ "time"; "year" ];
    weather =
      (match get_in j [ "time"; "weather" ] with
      | Some v -> Some (to_int v)
      | None -> None);
    active_menu =
      (match member "activeMenu" j with
      | Some (`Assoc _ as m) -> (
          match member "type" m with
          | Some (`String s) -> Some s
          | _ -> Some "未知菜单")
      | Some (`String s) -> Some s
      | _ -> None);
    inventory =
      (match member "inventory" j with
      | Some (`List items) -> List.map parse_item items
      | _ -> []);
    raw = j;
  }

(* ---------- 状态读取的来源追踪 ----------

   状态速报（strip）原本会重新拉一次 /state（多一次完整 curl 往返）。这里记录
   "最近一次状态读取"及其代际计数，供速报复用**本次工具调用内**已经取过的状态——
   速报是给人的摘要，与实时差几百毫秒无妨，省下的是每个工具一次完整拉取。 *)

let fetch_gen = ref 0
let last_fetch : (t * int) option ref = ref None

(** 当前代际（调用方在工具执行前取快照，作为"本次调用"的基线） *)
let fetch_gen_count () : int = !fetch_gen

(** 若在 [gen_min] 代之后成功取过状态，则返回该状态；否则 None *)
let recent_fetch_since (gen_min : int) : t option =
  match !last_fetch with
  | Some (st, g) when g > gen_min -> Some st
  | _ -> None

let fetch () : t =
  let st = Game_api.state () |> of_json in
  incr fetch_gen;
  last_fetch := Some (st, !fetch_gen);
  st

(* ---------- 渲染 ---------- *)

let season_cn = function
  | "spring" -> "春"
  | "summer" -> "夏"
  | "fall" -> "秋"
  | "winter" -> "冬"
  | s -> s

(* /state.time.weather 枚举 → 中文（Remix 端点；旧 mod 无该字段时上层不显示） *)
let weather_cn = function
  | 0 -> "晴天"
  | 1 -> "雨天"
  | 2 -> "雷雨天"
  | 3 -> "大风天"
  | 5 -> "下雪"
  | 7 -> "绿雨"
  | n -> Printf.sprintf "天气%d" n

let facing_cn = function
  | 0 -> "上"
  | 1 -> "右"
  | 2 -> "下"
  | 3 -> "左"
  | _ -> "?"

let fmt_time t = Printf.sprintf "%02d:%02d" (t / 100) (t mod 100)

let fmt_num (f : float) =
  if Float.is_integer f then string_of_int (int_of_float f)
  else Printf.sprintf "%.0f" f

(* 单行物品渲染（含水壶水量） *)
let render_item_line i (it : inv_item) =
  let water_note =
    match it.water with
    | Some (left, max) -> Printf.sprintf "，水 %d/%d" left max
    | None -> ""
  in
  Printf.sprintf "  %d. %s x%d（%s%s）" (i + 1) it.iname it.stack it.category water_note

(* 状态速报单行。未就绪或无法解析时给最小信息。 *)
let strip (s : t) : string =
  if Config.no_strip () then ""
  else
    match s.player with
    | None -> "── [游戏未进档]"
    | Some p ->
        let menu_part =
          match s.active_menu with
          | Some m -> Printf.sprintf " · [菜单:%s]" m
          | None -> ""
        in
        let weather_part =
          match s.weather with Some w -> weather_cn w ^ " · " | None -> ""
        in
        Printf.sprintf
          "── [%s %d日 Y%d %s · %s(%d,%d) · %sHP %d/%d · 体力 %s/%s · %dg · 手持:%s%s]"
          (season_cn s.season) s.day s.year (fmt_time s.time_of_day) s.loc_name
          p.px p.py weather_part p.health p.max_health (fmt_num p.stamina)
          (fmt_num p.max_stamina) p.money p.current_tool menu_part

(* 完整状态文本 *)
let render (s : t) : string =
  if not s.world_ready then
    "游戏还没有进入存档（当前在标题界面或加载中）。请先在游戏里载入存档后再操作。"
  else
    match s.player with
    | None -> "无法解析 /state 的 player 字段（mod 响应异常）。"
    | Some p ->
        let b = Buffer.create 512 in
        Buffer.add_string b
          (Printf.sprintf "【玩家】%s · 位置 %s(%d,%d) · 朝向 %s\n" p.p_name
             s.loc_name p.px p.py (facing_cn p.facing));
        Buffer.add_string b
          (Printf.sprintf "【状态】HP %d/%d · 体力 %s/%s · %dg · 手持 %s%s\n"
             p.health p.max_health (fmt_num p.stamina) (fmt_num p.max_stamina)
             p.money p.current_tool
             (if p.is_moving then "（移动中）" else ""));
        Buffer.add_string b
          (Printf.sprintf "【时间】%s %d日 · 第 %d 年 · %s\n" (season_cn s.season)
             s.day s.year (fmt_time s.time_of_day));
        (match s.weather with
        | Some w -> Buffer.add_string b (Printf.sprintf "【天气】%s\n" (weather_cn w))
        | None -> ());
        Buffer.add_string b
          (Printf.sprintf "【地图】%s（%dx%d）\n" s.loc_name s.loc_w s.loc_h);
        Buffer.add_string b
          (match s.active_menu with
          | Some m -> Printf.sprintf "【菜单】当前打开：%s（可用 menu_read 查看内容）\n" m
          | None -> "【菜单】无\n");
        Buffer.add_string b
          (Printf.sprintf "【背包】%d 格：\n" (List.length s.inventory));
        List.iteri
          (fun i it ->
            Buffer.add_string b (render_item_line i it);
            Buffer.add_char b '\n')
          s.inventory;
        String.trim (Buffer.contents b)

(* ---------- 背包渲染 ---------- *)

let render_inventory (s : t) : string =
  match s.inventory with
  | [] -> "背包是空的（0 格）。"
  | items ->
      let b = Buffer.create 256 in
      Buffer.add_string b (Printf.sprintf "背包共 %d 格：\n" (List.length items));
      List.iteri
        (fun i it ->
          Buffer.add_string b (render_item_line i it);
          Buffer.add_char b '\n')
        items;
      String.trim (Buffer.contents b)

(* ---------- /surroundings 渲染 ---------- *)

let render_surroundings (j : Yojson.Safe.t) : string =
  let loc = get_str j [ "location" ] in
  let cx = get_int j [ "center"; "x" ] in
  let cy = get_int j [ "center"; "y" ] in
  let tiles = match member "tiles" j with Some (`List ts) -> ts | _ -> [] in
  let npcs = match member "npcs" j with Some (`List l) -> l | _ -> [] in
  let monsters = match member "monsters" j with Some (`List l) -> l | _ -> [] in
  let objects = ref [] in
  let crops = ref [] in
  let other_terrains = ref [] in
  let soils = ref 0 in
  let diggables = ref 0 in
  let blocked_count = ref 0 in
  List.iter
    (fun t ->
      let x = get_int t [ "x" ] in
      let y = get_int t [ "y" ] in
      let passable = match member "passable" t with Some (`Bool b) -> b | _ -> true in
      let terrain = get_str t [ "terrain" ] in
      let obj =
        match member "object" t with
        | Some v when to_str v <> "" -> Some (to_str v)
        | _ -> None
      in
      let diggable = member "diggable" t <> None in
      match obj with
      | Some o -> objects := (o, x, y) :: !objects
      | None ->
          if terrain = "HoeDirt" then (
            match member "crop" t with
            | Some _ ->
                let watered = member "watered" t <> None in
                let harvestable =
                  match member "harvestable" t with
                  | Some (`Bool b) -> b
                  | _ -> false
                in
                let phase = get_int t [ "cropPhase" ] in
                crops := (x, y, phase, watered, harvestable) :: !crops
            | None -> incr soils)
          else if terrain <> "" then
            other_terrains := (terrain, x, y) :: !other_terrains
          else if diggable then incr diggables
          else if not passable then incr blocked_count)
    tiles;
  let b = Buffer.create 256 in
  Buffer.add_string b (Printf.sprintf "位置：%s，中心 (%d,%d)\n" loc cx cy);
  let empty =
    !objects = [] && !crops = [] && !other_terrains = [] && !soils = 0
    && !diggables = 0 && !blocked_count = 0 && npcs = [] && monsters = []
  in
  if empty then Buffer.add_string b "周围很空旷，没有可交互物、作物、障碍、NPC 或怪物。"
  else begin
    if !objects <> [] then begin
      Buffer.add_string b
        (Printf.sprintf "可交互物/物件（%d）：\n" (List.length !objects));
      List.iter
        (fun (o, x, y) ->
          Buffer.add_string b (Printf.sprintf "  · %s at (%d,%d)\n" o x y))
        (List.rev !objects)
    end;
    if !crops <> [] then begin
      Buffer.add_string b (Printf.sprintf "作物（%d）：\n" (List.length !crops));
      List.iter
        (fun (x, y, phase, watered, harvestable) ->
          Buffer.add_string b
            (Printf.sprintf "  · (%d,%d) 阶段%d %s%s\n" x y phase
               (if watered then "已浇水" else "未浇水")
               (if harvestable then " [可收获]" else "")))
        (List.rev !crops)
    end;
    if !other_terrains <> [] then begin
      Buffer.add_string b
        (Printf.sprintf "其他地形（%d）：\n" (List.length !other_terrains));
      List.iter
        (fun (tn, x, y) ->
          Buffer.add_string b (Printf.sprintf "  · %s at (%d,%d)\n" tn x y))
        (List.rev !other_terrains)
    end;
    if !soils > 0 then
      Buffer.add_string b (Printf.sprintf "锄过的空地：%d 格\n" !soils);
    if !diggables > 0 then
      Buffer.add_string b (Printf.sprintf "可锄的泥地：%d 格\n" !diggables);
    if npcs <> [] then begin
      Buffer.add_string b (Printf.sprintf "NPC（%d）：\n" (List.length npcs));
      List.iter
        (fun n ->
          let nm = get_str n [ "name" ] in
          let x = get_int n [ "x" ] in
          let y = get_int n [ "y" ] in
          Buffer.add_string b (Printf.sprintf "  · %s at (%d,%d)\n" nm x y))
        npcs
    end;
    if monsters <> [] then begin
      Buffer.add_string b (Printf.sprintf "怪物（%d）：\n" (List.length monsters));
      List.iter
        (fun n ->
          let nm = get_str n [ "name" ] in
          let x = get_int n [ "x" ] in
          let y = get_int n [ "y" ] in
          Buffer.add_string b (Printf.sprintf "  · %s at (%d,%d)\n" nm x y))
        monsters
    end;
    if !blocked_count > 0 then
      Buffer.add_string b
        (Printf.sprintf "障碍/墙体：%d 格（不可通行）\n" !blocked_count)
  end;
  String.trim (Buffer.contents b)

(* ---------- /menu 渲染 ---------- *)

let render_menu (j : Yojson.Safe.t) : string =
  let is_open = match member "open" j with Some (`Bool b) -> b | _ -> false in
  if not is_open then begin
    let ev =
      match member "activeEvent" j with
      | Some (`Assoc _ as e) when get_str e [ "id" ] <> "" ->
          Some (get_str e [ "id" ])
      | _ -> None
    in
    match ev with
    | Some id -> Printf.sprintf "当前没有菜单打开。但有事件进行中（id: %s）。" id
    | None -> "当前没有菜单打开。"
  end
  else begin
    let b = Buffer.create 256 in
    Buffer.add_string b (Printf.sprintf "【菜单】%s\n" (get_str j [ "type" ]));
    (match member "dialogue" j with
    | Some (`String d) when d <> "" ->
        Buffer.add_string b (Printf.sprintf "【对话】%s\n" d)
    | _ -> ());
    (match member "responses" j with
    | Some (`List rs) when rs <> [] ->
        Buffer.add_string b "【选项】\n";
        List.iter
          (fun r ->
            Buffer.add_string b
              (Printf.sprintf "  %d. [%s] %s\n" (get_int r [ "index" ])
                 (get_str r [ "key" ]) (get_str r [ "text" ])))
          rs
    | _ -> ());
    (match member "shopItems" j with
    | Some (`List items) when items <> [] ->
        Buffer.add_string b
          (Printf.sprintf "【商店】%d 件：\n" (List.length items));
        List.iter
          (fun it ->
            Buffer.add_string b
              (Printf.sprintf "  · %s  %dG  库存 %d\n" (get_str it [ "name" ])
                 (get_int it [ "price" ]) (get_int it [ "stock" ])))
          items
    | _ -> ());
    (match member "buttons" j with
    | Some (`List btns) when btns <> [] ->
        Buffer.add_string b "【按钮】（可用 menu_click {button:名字} 或按坐标点）\n";
        List.iter
          (fun bt ->
            Buffer.add_string b
              (Printf.sprintf "  · %s at (%d,%d)\n" (get_str bt [ "name" ])
                 (get_int bt [ "x" ]) (get_int bt [ "y" ])))
          btns
    | _ -> ());
    String.trim (Buffer.contents b)
  end

(* ---------- /interact 渲染 ---------- *)

let render_interact (j : Yojson.Safe.t) : string =
  let ftx = get_int j [ "facingTile"; "x" ] in
  let fty = get_int j [ "facingTile"; "y" ] in
  let acted = match member "actionTriggered" j with Some (`Bool b) -> b | _ -> false in
  let b = Buffer.create 128 in
  Buffer.add_string b
    (Printf.sprintf "交互面向格 (%d,%d)：%s\n" ftx fty
       (if acted then "触发了交互" else "未触发交互（该格没有可交互内容）"));
  (match member "object" j with
  | Some v when to_str v <> "" ->
      Buffer.add_string b (Printf.sprintf "  物件：%s\n" (to_str v))
  | _ -> ());
  (match member "terrain" j with
  | Some v when to_str v <> "" ->
      Buffer.add_string b (Printf.sprintf "  地形：%s\n" (to_str v))
  | _ -> ());
  (match member "harvestable" j with
  | Some (`Bool true) -> Buffer.add_string b "  有成熟作物（可收获）\n"
  | _ -> ());
  (match member "npc" j with
  | Some v when to_str v <> "" ->
      Buffer.add_string b (Printf.sprintf "  NPC：%s\n" (to_str v))
  | _ -> ());
  String.trim (Buffer.contents b)
