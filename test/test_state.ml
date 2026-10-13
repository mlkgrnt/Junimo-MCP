(* /state 与 /surroundings、/menu 解析/渲染单测。 *)

open Stardew_mcp

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n" name
  else (
    incr failures;
    Printf.printf "FAIL - %s\n" name)

let contains s sub =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then false else String.sub s i m = sub || go (i + 1)
  in
  m = 0 || go 0

(* 模拟真机 /state（对照 M0 实测结构） *)
let sample_state =
  {|{
 "ok": true, "worldReady": true,
 "player": {"name":"Clementine","x":9,"y":15,"health":100,"maxHealth":100,
            "stamina":268.0,"maxStamina":270,"money":1539,"currentTool":"Hoe",
            "facingDirection":2,"isMoving":false,"fishing":null},
 "location": {"name":"Farm","mapWidth":80,"mapHeight":65},
 "time": {"timeOfDay":610,"dayOfMonth":13,"season":"spring","year":1},
 "activeMenu": null, "activeEvent": null, "npcs": [],
 "inventory": [{"name":"Hoe","stack":1,"category":"工具"},
               {"name":"Watering Can","stack":1,"category":"工具","waterLeft":10,"waterMax":40}]
}|}

let sample_surroundings =
  {|{
 "ok":true,"center":{"x":9,"y":9},"radius":6,"location":"Farm",
 "tiles":[
   {"x":3,"y":5,"passable":true,"terrain":"HoeDirt","crop":"24","cropPhase":2,"harvestable":false},
   {"x":4,"y":5,"passable":true,"terrain":"HoeDirt","crop":"24","cropPhase":4,"harvestable":true,"watered":true},
   {"x":9,"y":3,"passable":false},
   {"x":5,"y":9,"passable":true,"object":"Chest"},
   {"x":6,"y":2,"passable":true,"diggable":true}
 ],
 "npcs":[],"monsters":[],"farmers":[]}|}

let () =
  (* ---- /state 解析 ---- *)
  let st = Game_state.of_json (Yojson.Safe.from_string sample_state) in
  check "world_ready" st.world_ready;
  check "player.name"
    (match st.player with Some p -> p.p_name = "Clementine" | None -> false);
  check "player.pos"
    (match st.player with Some p -> p.px = 9 && p.py = 15 | None -> false);
  check "player.stamina float" (match st.player with Some p -> p.stamina = 268.0 | None -> false);
  check "location" (st.loc_name = "Farm" && st.loc_w = 80 && st.loc_h = 65);
  check "time" (st.time_of_day = 610 && st.day = 13 && st.season = "spring" && st.year = 1);
  check "inventory.len" (List.length st.inventory = 2);
  check "水壶水量解析"
    (match List.nth_opt st.inventory 1 with
    | Some it -> it.Game_state.water = Some (10, 40)
    | None -> false);
  check "无水量物品 water=None"
    (match List.nth_opt st.inventory 0 with
    | Some it -> it.Game_state.water = None
    | None -> false);

  (* strip 格式 *)
  let s = Game_state.strip st in
  check "strip: 时间 06:10" (contains s "06:10");
  check "strip: 位置 Farm(9,15)" (contains s "Farm(9,15)");
  check "strip: 季节 春" (contains s "春 13日");
  check "strip: 手持" (contains s "手持:Hoe");

  (* render *)
  let r = Game_state.render st in
  check "render: 玩家" (contains r "Clementine");
  check "render: 体力" (contains r "268/270");
  check "render: 背包" (contains r "Watering Can x1（工具，水 10/40）");

  (* 未就绪 *)
  let st2 =
    Game_state.of_json (Yojson.Safe.from_string {|{"ok":true,"worldReady":false}|})
  in
  check "未就绪: world_ready=false" (not st2.world_ready);
  check "未就绪: player=None" (st2.player = None);
  check "未就绪: strip" (Game_state.strip st2 = "── [游戏未进档]");
  check "未就绪: render 提示" (contains (Game_state.render st2) "还没有进入存档");

  (* ---- /surroundings 渲染 ---- *)
  let sur = Game_state.render_surroundings (Yojson.Safe.from_string sample_surroundings) in
  check "sur: 作物未浇水" (contains sur "(3,5) 阶段2 未浇水");
  check "sur: 作物可收获" (contains sur "(4,5) 阶段4 已浇水 [可收获]");
  check "sur: 物件" (contains sur "Chest at (5,9)");
  check "sur: 可锄泥地" (contains sur "可锄的泥地：1 格");
  check "sur: 障碍" (contains sur "障碍/墙体：1 格");

  (* ---- /menu 渲染 ---- *)
  let menu_open =
    {|{"ok":true,"open":true,"type":"DialogueBox","dialogue":"你好，旅行者！",
       "responses":[{"index":0,"key":"1","text":"你好"},{"index":1,"key":"2","text":"再见"}],
       "shopItems":null,"buttons":null}|}
  in
  let m = Game_state.render_menu (Yojson.Safe.from_string menu_open) in
  check "menu: 类型" (contains m "DialogueBox");
  check "menu: 对话" (contains m "你好，旅行者！");
  check "menu: 选项" (contains m "0. [1] 你好");
  let menu_closed =
    Game_state.render_menu (Yojson.Safe.from_string {|{"ok":true,"open":false,"activeEvent":null}|})
  in
  check "menu: 未打开" (menu_closed = "当前没有菜单打开。");

  (* ---- /interact 渲染 ---- *)
  let ai =
    Game_state.render_interact
      (Yojson.Safe.from_string
         {|{"ok":true,"actionTriggered":true,"facingTile":{"x":5,"y":9},"object":"Chest"}|})
  in
  check "interact: 坐标" (contains ai "(5,9)");
  check "interact: 物件" (contains ai "Chest");
  check "interact: 触发" (contains ai "触发了交互");

  (* ---- UTF-8 安全截断与清洗（http_client） ---- *)
  check "safe_prefix: 短串原样" (Http_client.safe_prefix "abc" 10 = "abc");
  (* "由"=e7 94 b1，"于"=e4 ba 8e；截 4 字节必须切在"由"后（不切"于"） *)
  check "safe_prefix: 不切多字节" (Http_client.safe_prefix "由于目" 4 = "由");
  check "safe_prefix: 恰好边界" (Http_client.safe_prefix "由于目" 3 = "由");
  check "safe_prefix: 取全" (Http_client.safe_prefix "由于目" 9 = "由于目");
  check "sanitize: 合法串不变" (Http_client.sanitize_utf8 "工具 OK" = "工具 OK");
  check "sanitize: ASCII 不变" (Http_client.sanitize_utf8 "hello" = "hello");
  (* 截断的"于"（缺尾字节）→ 2 个 '?'；0xFF 非法字节 → '?' *)
  check "sanitize: 截断序列" (Http_client.sanitize_utf8 "\xe4\xba" = "??");
  check "sanitize: 非法字节" (Http_client.sanitize_utf8 "a\xffb" = "a?b");
  check "sanitize: 合法多字节保留" (Http_client.sanitize_utf8 "a\xe4\xba\x8eb" = "a\xe4\xba\x8eb");

  Printf.printf "\ntest_state: %s\n"
    (if !failures = 0 then "ALL PASS"
     else Printf.sprintf "%d FAILURE(S)" !failures);
  if !failures > 0 then exit 1
