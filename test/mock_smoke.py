#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mock 全流程冒烟：起 mock NagiBridge → 跑 main.exe 完整剧情链 → 断言。

用法: python mock_smoke.py
依赖: 已构建的 _build/default/bin/main.exe（bash build.sh build）

剧情链: 握手 → 17 工具核对 → get_state → go_to → till 2x2 → plant 1x4 →
        water（自动扫描 12 格）→ harvest → get_inventory → 菜单流程 →
        动作工具抽查 → warp → 错误路径。
"""

import json
import os
import socket
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXE = os.path.join(ROOT, "_build", "default", "bin", "main.exe")
MOCK = os.path.join(HERE, "mock_nagibridge.py")
PORT = 8792
PY = sys.executable

results = []


def check(name, cond, extra=""):
    ok = bool(cond)
    results.append((name, ok))
    suffix = ""
    if not ok and extra:
        suffix = "  [" + str(extra)[:230].replace("\n", " / ") + "]"
    print(("ok   - " if ok else "FAIL - ") + name + suffix)


def wait_port(port, timeout=10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        with socket.socket() as s:
            s.settimeout(0.3)
            try:
                s.connect(("127.0.0.1", port))
                return True
            except OSError:
                time.sleep(0.1)
    return False


def mock_get(path):
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=10) as r:
        return json.loads(r.read().decode("utf-8"))


def mock_post(path, body):
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode("utf-8"))


class Client:
    """通过 main.exe 的 stdio 说话（MCP 客户端仿真）。"""

    def __init__(self, env_extra=None):
        env = dict(os.environ)
        env["STARDEW_API_URL"] = f"http://localhost:{PORT}"
        if env_extra:
            env.update({k: str(v) for k, v in env_extra.items()})
        self.p = subprocess.Popen(
            [EXE],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.next_id = 1
        self.init_resp = self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}})
        self.notify("notifications/initialized")

    def _write(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def request(self, method, params=None):
        i = self.next_id
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": i, "method": method, "params": params or {}})
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError(f"no response for {method}")
        resp = json.loads(line)
        assert resp.get("id") == i, f"id mismatch: {resp}"
        return resp

    def call(self, name, args=None):
        resp = self.request("tools/call", {"name": name, "arguments": args or {}})
        r = resp.get("result", {})
        text = ""
        if r.get("content"):
            text = r["content"][0].get("text", "")
        return text, bool(r.get("isError", False))

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


TOOLS_EXPECTED = [
    "get_state", "look", "get_inventory",
    "go_to", "warp", "face",
    "swing_tool", "use_held", "interact", "press_key",
    "menu_read", "menu_click", "story",
    "select_item",
    "till", "plant", "water", "harvest",
    "sleep", "buy", "ship", "chest_read", "chest_store", "map_info",
    "pause_time", "resume_time",
    "eat", "gift", "friendship", "find_npc",
    "chest_scan", "chest_take", "chest_take_list",
    "festival", "festival_interact", "festival_answer",
]


def run_chain(c):
    # ---- 握手与工具清单 ----
    check(
        "initialize: serverInfo",
        c.init_resp.get("result", {}).get("serverInfo", {}).get("name") == "junimo-mcp",
        str(c.init_resp)[:200],
    )
    tl = c.request("tools/list")
    tools = tl.get("result", {}).get("tools", [])
    check("tools/list: 共 36 个", len(tools) == 36, f"got {len(tools)}")
    names = {t["name"] for t in tools}
    for n in TOOLS_EXPECTED:
        check(f"工具存在: {n}", n in names)
    check("schema 均有 inputSchema", all("inputSchema" in t for t in tools))

    # ---- 感知 ----
    t, err = c.call("get_state")
    check("get_state: 玩家 Tester", (not err) and "Tester" in t, t)
    check("get_state: 位置 (9,9)", (not err) and "(9,9)" in t, t)
    check("get_state: 季节渲染", "春 13日" in t, t)

    # ---- 移动 ----
    t, err = c.call("go_to", {"x": 5, "y": 4})
    check("go_to: 已到达", (not err) and "已到达" in t, t)
    st = mock_get("/state")
    check("go_to: mock 坐标 (5,4)", (st["player"]["x"], st["player"]["y"]) == (5, 4), st["player"])

    # ---- 锄地 2x2 ----
    t, err = c.call("till", {"x": 3, "y": 2, "rows": 2, "length": 2})
    check("till: 成功 4/4", (not err) and "成功 4/4" in t, t)
    sur = mock_get("/surroundings?radius=25")
    tile = next((tt for tt in sur["tiles"] if tt["x"] == 3 and tt["y"] == 2), None)
    check("till: (3,2) 变 HoeDirt", tile and tile.get("terrain") == "HoeDirt", str(tile))
    t, err = c.call("till", {"x": 3, "y": 2, "rows": 2, "length": 2})
    check("till 重跑: 4 格幂等跳过", (not err) and "另有 4 格已完成" in t, t)

    # ---- 批量蓄力（/tool_area）：工具升级后自动启用（0 级时自动不启用）----
    mock_post("/mock/set", {"toolUpgrade": 1})
    t, err = c.call("till", {"x": 5, "y": 2, "rows": 2, "length": 2})
    check("till(升级): 走蓄力批量", (not err) and "批量蓄力" in t and "成功 4/4" in t, t)
    sur = mock_get("/surroundings?radius=25")
    tile = next((tt for tt in sur["tiles"] if tt["x"] == 6 and tt["y"] == 3), None)
    check("till(升级): (6,3) 成 HoeDirt", tile and tile.get("terrain") == "HoeDirt", str(tile))
    mock_post("/mock/set", {"toolUpgrade": 0})
    t, err = c.call("till", {"x": 5, "y": 2, "rows": 2, "length": 2})
    check("till(0级): 不启用批量（逐格幂等）", (not err) and "批量蓄力" not in t, t)

    # ---- 播种 1x4 ----
    t, err = c.call("plant", {"seed": "Parsnip Seeds", "x": 3, "y": 4, "length": 4})
    check("plant: 成功 4/4", (not err) and "成功 4/4" in t, t)
    inv = mock_get("/state")["inventory"]
    seeds = next((it for it in inv if it["name"] == "Parsnip Seeds"), None)
    check("plant: 种子 15→11", seeds and seeds["stack"] == 11, str(seeds))
    t, err = c.call("plant", {"seed": "Parsnip Seeds", "x": 3, "y": 4, "length": 4})
    check("plant 重跑: 已占用格跳过", (not err) and "另有 4 格已完成" in t, t)

    # ---- 浇水（自动扫描：c区4 + R区4 + 新种4 = 12）----
    t, err = c.call("water", {"radius": 15})
    check("water: 成功 12/12", (not err) and "成功 12/12" in t, t)
    sur = mock_get("/surroundings?radius=25")
    watered_cells = {
        (tt["x"], tt["y"]) for tt in sur["tiles"] if tt.get("watered") and tt.get("crop")
    }
    expect = {(x, y) for x in range(3, 7) for y in (4, 5, 7)}
    check("water: 12 格全浇上", expect.issubset(watered_cells), f"missing {expect - watered_cells}")
    wc = next(it for it in mock_get("/state")["inventory"] if it["name"] == "Watering Can")
    check("water: 水壶有消耗", 0 < wc["waterLeft"] <= 40, str(wc))
    t, err = c.call("water", {"radius": 15})
    check("water 重跑: 无待浇作物", (not err) and "没有找到需要浇水的作物" in t, t)

    # ---- 批量浇水（/tool_area water）：升级后自动启用；force 时 0 级也走 ----
    mock_post("/mock/set", {"unwater": True})
    mock_post("/mock/set", {"toolUpgrade": 1})
    t, err = c.call("water", {"radius": 15})
    # unwater 把 C 区（原本已浇）也一并清了 ⇒ 16 格（c4 + C4 + R4 + 新种4）都要浇
    check("water(升级): 走蓄力批量", (not err) and "批量蓄力" in t and "成功 16/16" in t, t)
    sur = mock_get("/surroundings?radius=25")
    watered_now = {
        (tt["x"], tt["y"]) for tt in sur["tiles"] if tt.get("watered") and tt.get("crop")
    }
    check("water(升级): 12 格全浇上", expect.issubset(watered_now), f"missing {expect - watered_now}")
    c3 = Client(env_extra={"STARDEW_AREA": "force"})
    try:
        mock_post("/mock/set", {"unwater": True})
        t, err = c3.call("water", {"radius": 15})
        check("water(STARDEW_AREA=force): 0 级也走批量", (not err) and "批量蓄力" in t, t)
    finally:
        c3.close()
    mock_post("/mock/set", {"toolUpgrade": 0})

    # ---- 收割 ----
    t, err = c.call("harvest", {"radius": 15})
    check("harvest: 4 个", (not err) and "4 个" in t, t)

    # ---- 背包 ----
    t, err = c.call("get_inventory")
    check("get_inventory: Parsnip x4", (not err) and "Parsnip x4" in t, t)
    check("get_inventory: 水壶带水量", "水" in t and "/40" in t, t)

    # ---- 环视 ----
    t, err = c.call("look", {"radius": 10})
    check("look: 有作物段", (not err) and "作物" in t, t)
    check("look: 已浇水状态可见", "已浇水" in t, t)

    # ---- 菜单流程 ----
    t, err = c.call("menu_read")
    check("menu_read: 无菜单", "没有菜单" in t, t)
    mock_post("/mock/set", {"menu": "dialogue"})
    t, err = c.call("menu_read")
    check("menu_read: 读到对话", "DialogueBox" in t and "你好" in t, t)
    t, err = c.call("menu_click", {"option": 0})
    check("menu_click: 选项后关闭", "菜单已关闭" in t, t)

    # ---- 模态界面两档处理：无选项对话自动推进 / 带选项绝不代答 ----
    mock_post("/mock/set", {"menu": "plain"})
    t, err = c.call("select_item", {"name": "Axe"})
    check("无选项对话: 自动按掉后动作照常", (not err) and "Axe" in t, t)
    check("无选项对话: 已被自动关闭", not mock_get("/state").get("activeMenu"),
          str(mock_get("/state").get("activeMenu")))
    mock_post("/mock/set", {"menu": "dialogue"})
    t, err = c.call("select_item", {"name": "Axe"})
    check("带选项对话: 不代答 + 报错里带选项与原文",
          err and "可选项" in t and "[0]" in t and "你好" in t, t)
    check("带选项对话: 保持原样（一个键都没按）",
          mock_get("/state").get("activeMenu") is not None, "菜单被意外关闭")
    mock_post("/mock/set", {"menu": None})

    # ---- 剧本事件：默认不跳（快速失败）；STARDEW_AUTO_EVENT=1 才自动 skip ----
    mock_post("/mock/set", {"event": "pet"})
    t, err = c.call("select_item", {"name": "Axe"})
    check("剧本事件: 默认不自动跳过（含事件信息与台词）",
          err and "正在演剧情" in t and "收养" in t and "story" in t, t)
    ce = Client(env_extra={"STARDEW_AUTO_EVENT": "1"})
    try:
        mock_post("/mock/set", {"event": "pet"})
        t, err = ce.call("select_item", {"name": "Axe"})
        check("AUTO_EVENT=1: 事件被跳过、动作照常", (not err) and "Axe" in t, t)
        check("AUTO_EVENT=1: 事件与菜单都已清",
              mock_get("/state").get("activeMenu") is None and mock_get("/state").get("activeEvent") is None,
              str(mock_get("/state").get("activeMenu")))
    finally:
        ce.close()
    mock_post("/mock/set", {"menu": None})

    # ---- 剧情：能感知 / 能读台词 / 能一屏一屏玩到结束 ----
    mock_post("/mock/set", {"event": "story"})
    t, err = c.call("get_state")
    check("get_state: 直接报出剧情与当前台词",
          ("【剧情】" in t) and ("无家可归" in t) and ("story" in t), t)
    t, err = c.call("story")
    check("story read: 说话人 + 台词 + 下一步指引",
          (not err) and "玛妮" in t and "无家可归" in t and "action=next" in t, t)
    t, err = c.call("story", {"action": "next"})
    check("story next: 推进到第二屏", (not err) and "带回家" in t, t)
    t, err = c.call("story", {"action": "next"})
    check("story next: 到问题屏并列出选项 + 点击坐标兜底",
          (not err) and "收养" in t and "[0] 是" in t and "[1] 否" in t
          and "也可点 (640,558)" in t and "choose" in t, t)
    t, err = c.call("story", {"action": "choose"})
    check("story choose: 缺 option 如实报错", err and "需要 option" in t, t)
    t, err = c.call("story", {"action": "choose", "option": 0})
    check("story choose: 选完剧情结束", (not err) and "已结束" in t, t)
    check("story: 事件已清空", mock_get("/state").get("activeEvent") is None, "还有事件")
    t, err = c.call("story")
    check("story: 无剧情时如实说没有", (not err) and "没有剧情" in t, t)

    # ---- 剧情进行中：动作被挡，且**绝不能把剧情自动按掉** ----
    mock_post("/mock/set", {"event": "story"})
    t, err = c.call("select_item", {"name": "Axe"})
    check("剧情中: 动作被挡且指向 story", err and "正在演剧情" in t and "story" in t, t)
    check("剧情中: 剧情仍在（没被自动吃掉）",
          mock_get("/state").get("activeEvent") is not None, "剧情被吃掉了！")
    check("剧情中: 还停在第 0 屏",
          "无家可归" in json.dumps(mock_get("/state").get("activeMenu"), ensure_ascii=False),
          str(mock_get("/state").get("activeMenu")))
    # skip 能整段跳过
    t, err = c.call("story", {"action": "skip"})
    check("story skip: 整段跳过", (not err) and "跳过" in t, t)
    check("story skip: 事件已清", mock_get("/state").get("activeEvent") is None, "还有事件")
    mock_post("/mock/set", {"menu": None})

    # ---- 动作工具抽查 ----
    t, err = c.call("press_key", {"key": "confirm"})
    check("press_key", (not err) and "confirm" in t, t)
    t, err = c.call("face", {"direction": 2})
    check("face", (not err) and "已转向" in t, t)
    t, err = c.call("select_item", {"name": "Axe"})
    check("select_item: Axe", (not err) and "Axe" in t, t)
    t, err = c.call("swing_tool", {})
    check("swing_tool: 挥了 Axe", (not err) and "Axe" in t, t)
    t, err = c.call("use_held")
    check("use_held", (not err) and "已使用手持物" in t, t)
    t, err = c.call("interact")
    check("interact", (not err) and "交互面向格" in t, t)

    # ---- warp ----
    t, err = c.call("warp", {"location": "Farm"})
    check("warp: 到 Farm", (not err) and "已到达" in t, t)

    # ---- 长距导航（/walk_to 一次走全程；真 mod 的 walk_to 无 BFS 步数上限）----
    mock_post("/mock/set", {"x": 1, "y": 1})
    mock_post("/mock/set", {"no_path_long": 22})
    t, err = c.call("go_to", {"x": 18, "y": 11})
    check("go_to: 长距一次走完（/walk_to）", (not err) and "已到达" in t, t)
    st = mock_get("/state")
    check("go_to: 精确到达 (18,11)",
          (st["player"]["x"], st["player"]["y"]) == (18, 11), st["player"])
    mock_post("/mock/set", {"no_path_long": 0})

    # ---- /walk_to 入口校验（出发前拒绝，三类原因）----
    mock_post("/mock/set", {"x": 5, "y": 5})
    t, err = c.call("go_to", {"x": 99, "y": 5})
    check("go_to: 越界当场拒绝", err and "拒绝走位" in t and "越界" in t, t)
    mock_post("/mock/set", {"walk_door": True})
    t, err = c.call("go_to", {"x": 6, "y": 5})
    check("go_to: 门/传送格当场拒绝", err and "拒绝走位" in t and "门/传送格" in t, t)
    mock_post("/mock/set", {"walk_door": False})
    mock_post("/mock/set", {"no_path": True})
    t, err = c.call("go_to", {"x": 6, "y": 5})
    check("go_to: 四周站不住当场拒绝", err and "拒绝走位" in t and "站不住" in t, t)
    mock_post("/mock/set", {"no_path": False})

    # ---- 强制回退：STARDEW_WALK=move 时仍走分段接力（老路兜底）----
    c2 = Client(env_extra={"STARDEW_WALK": "move"})
    try:
        mock_post("/mock/set", {"x": 1, "y": 1})
        mock_post("/mock/set", {"no_path_long": 22})
        t, err = c2.call("go_to", {"x": 18, "y": 11})
        check("go_to(move 模式): 分段接力仍可用", (not err) and "已到达" in t, t)
        mock_post("/mock/set", {"no_path_long": 0})
        mock_post("/mock/set", {"no_path": True})
        t, err = c2.call("go_to", {"x": 20, "y": 11})
        check("go_to(move 模式): 直线回退被拒绝", err and "寻路失败" in t, t)
        mock_post("/mock/set", {"no_path": False})
    finally:
        c2.close()

    # ---- /walk_to 卡住（出发后没挪窝）时由分段接力兜底 ----
    # 真机 2026-10-14 压测抓到：mod 的 /walk_to 不校验"可达性"，目标被墙/水隔断时
    # 照样回 ok:true 然后原地不动 ⇒ 停滞检测应在 ~5s 放手，交回接力判定。
    mock_post("/mock/set", {"x": 1, "y": 1})
    mock_post("/mock/set", {"walk_stall": True})
    t, err = c.call("go_to", {"x": 10, "y": 6, "timeout": 14})
    check("go_to: /walk_to 卡住时接力兜底", (not err) and "已到达" in t, t)
    st = mock_get("/state")
    check("go_to: 兜底后精确到达 (10,6)",
          (st["player"]["x"], st["player"]["y"]) == (10, 6), st["player"])
    mock_post("/mock/set", {"walk_stall": False})

    # ---- 模态界面下 go_to 快速失败（不干等超时；对话/菜单开着时角色无法移动）----
    mock_post("/mock/set", {"menu": "dialogue"})
    t, err = c.call("go_to", {"x": 6, "y": 5})
    check("go_to: 菜单开着时快速失败（带选项也一并报出）",
          err and "已中止走位" in t and "可选项" in t, t)
    mock_post("/mock/set", {"menu": None})

    # ---- 错误路径 ----
    mock_post("/mock/set", {"world": 0})
    t, err = c.call("go_to", {"x": 1, "y": 1})
    check("未就绪: go_to isError", err and "存档" in t, t)
    t, err = c.call("look", {"radius": 3})
    check("未就绪: look isError", err, t)
    t, err = c.call("get_state")
    check("未就绪: get_state isError", err and "存档" in t, t)
    mock_post("/mock/set", {"world": 1})

    # ---- 生计工具（v2）----
    t, err = c.call("map_info")
    check("map_info: 建筑与传送点", (not err) and "Farmhouse" in t and "BusStop" in t, t)

    t, err = c.call("chest_read", {"x": 5, "y": 9})
    check("chest_read: 读到箱子内容", (not err) and "Maple Seed x4" in t, t)

    t, err = c.call("buy", {"id": "472", "quantity": 2})
    check("buy: 买入 2 颗种子", (not err) and "Parsnip Seeds x2" in t, t)
    t, err = c.call("buy", {"id": "999999"})
    check("buy: 无效 id 报错", err, t)

    t, err = c.call("ship", {})
    check("ship: 没给 name/all 报错", err and "all=true" in t, t)
    t, err = c.call("ship", {"name": "Parsnip"})
    check("ship: 发货 Parsnip", (not err) and "发货箱" in t and "Parsnip x4" in t, t)

    t, err = c.call("chest_store", {"x": 5, "y": 9, "name": "Parsnip Seeds"})
    check("chest_store: 存种子进箱", (not err) and "Parsnip Seeds x13" in t, t)
    t, err = c.call("chest_read", {"x": 5, "y": 9})
    check("chest_read: 存入后可见", (not err) and "Parsnip Seeds" in t, t)

    t, err = c.call("pause_time")
    check("pause_time: 已冻结", (not err) and "冻结" in t, t)
    t, err = c.call("resume_time")
    check("resume_time: 已恢复", (not err) and "恢复" in t, t)

    t, err = c.call("sleep")
    check("sleep: 翻日成功", (not err) and "睡醒" in t and "14 日" in t, t)

    # ---- v3 工具（Remix：天气/吃/社交/箱子/节日）----
    t, err = c.call("get_state")
    check("get_state: 天气渲染（晴天）", (not err) and "【天气】晴天" in t, t)
    mock_post("/mock/set", {"weather": 1})
    t, err = c.call("get_state")
    check("get_state: 雨天渲染", (not err) and "【天气】雨天" in t, t)
    t, err = c.call("get_inventory")
    check("strip: 速报行含天气词", "雨天" in t, t)
    mock_post("/mock/set", {"weather": 0})

    mock_post("/mock/set", {"stamina": 100})
    t, err = c.call("eat", {"name": "Cheese"})
    check("eat: 吃 Cheese 回体力", (not err) and "已吃下 Cheese" in t and "体力 100→150" in t, t)
    inv = mock_get("/state")["inventory"]
    cheese = next((it for it in inv if it["name"] == "Cheese"), None)
    check("eat: Cheese 2→1", cheese and cheese["stack"] == 1, str(cheese))
    t, err = c.call("eat", {"name": "Hoe"})
    check("eat: 工具不可食用报错", err and "不可食用" in t, t)

    t, err = c.call("friendship", {"npc": "Abigail"})
    check("friendship: 直查 Abigail", (not err) and "好感 100 点（0 心）" in t, t)
    t, err = c.call("friendship", {"npc": "阿比盖尔"})
    check("friendship: 中文名自动解析", (not err) and "Abigail" in t and "100 点" in t, t)

    t, err = c.call("find_npc", {"name": "阿比盖尔"})
    check("find_npc: 找到并带位置", (not err) and "Abigail" in t and "Farm(6,3)" in t, t)
    t, err = c.call("find_npc", {"name": "不存在的人"})
    check("find_npc: 找不到报错", err and "没有找到" in t, t)

    t, err = c.call("gift", {"target": "Abigail", "item": "Daffodil"})
    check("gift: 送 Daffodil 成功", (not err) and "好感 100→180" in t and "最爱" in t, t)
    t, err = c.call("gift", {"target": "Abigail", "item": "Daffodil"})
    check("gift: 今日重复被拒", err and "送过" in t, t)
    t, err = c.call("friendship", {"npc": "Abigail"})
    check("friendship: 送礼后记账", (not err) and "180 点" in t and "今天已送 1/1" in t, t)

    t, err = c.call("chest_scan")
    check("chest_scan: 列出箱子 (5,9)", (not err) and "(5,9)" in t and "Fiber x2" in t, t)
    t, err = c.call("chest_take", {"x": 5, "y": 9, "name": "Fiber"})
    check("chest_take: 取出 Fiber x2", (not err) and "Fiber x2" in t, t)
    inv = mock_get("/state")["inventory"]
    check("chest_take: Fiber 进背包", any(it["name"] == "Fiber" and it["stack"] == 2 for it in inv), str(inv))
    t, err = c.call("chest_take", {"x": 5, "y": 9, "name": "NotExist"})
    check("chest_take: 取不到如实报", (not err) and "没有取出任何物品" in t, t)
    t, err = c.call("chest_take", {"x": 5, "y": 9})
    check("chest_take: 缺 name/slot 报错", err and "至少给" in t, t)

    mock_post("/mock/set", {"x": 18, "y": 11})
    t, err = c.call("chest_take_list", {"items": ["Maple Seed x2"]})
    check("chest_take_list: 远箱列 tooFar", (not err) and "够不着" in t and "(5,9)" in t, t)
    mock_post("/mock/set", {"x": 3, "y": 9})
    t, err = c.call("chest_take_list", {"items": ["Maple Seed x2"]})
    check("chest_take_list: 近距取到 Maple Seed", (not err) and "Maple Seed：取到 2 个" in t, t)
    t, err = c.call("chest_take_list", {"items": ["Nope Thing"]})
    check("chest_take_list: 找不到如实列", (not err) and "没找到" in t, t)
    t, err = c.call("chest_take_list", {})
    check("chest_take_list: 空清单报错", err and "items" in t, t)

    t, err = c.call("festival")
    check("festival: 无活动 + 下一个花舞节", (not err) and "花舞节" in t and "没有节日活动" in t, t)
    mock_post("/mock/set", {"festival": True})
    t, err = c.call("festival")
    check("festival: 活动进行中", (not err) and "Egg Festival" in t and "分数 3" in t, t)
    t, err = c.call("festival_interact", {"name": "Abigail"})
    check("festival_interact: 成功", (not err) and "已与 Abigail 交互" in t, t)
    t, err = c.call("festival_answer", {"answer": 1})
    check("festival_answer: 提交选项", (not err) and "已提交选项 1" in t, t)
    mock_post("/mock/set", {"festival": False})
    t, err = c.call("festival_interact", {})
    check("festival_interact: 无活动报错", err and "No active event" in t, t)

    t, err = c.call("nope")
    check("未知工具 isError", err and "未知工具" in t, t)
    t, err = c.call("till", {})
    check("缺参数 isError", err and "缺少必填参数" in t, t)


def main():
    if not os.path.exists(EXE):
        print(f"ERROR: 未找到 {EXE}，先跑 bash build.sh build")
        return 2

    mock = subprocess.Popen(
        [PY, MOCK, "--port", str(PORT)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        if not wait_port(PORT):
            print("ERROR: mock 未能启动")
            return 2
        c = Client()
        try:
            run_chain(c)
        finally:
            c.close()
    finally:
        mock.terminate()
        try:
            mock.wait(timeout=5)
        except Exception:
            mock.kill()

    failed = [n for n, ok in results if not ok]
    total = len(results)
    print(f"\n=== mock_smoke: {total - len(failed)}/{total} passed ===")
    if failed:
        print("FAILURES:")
        for n in failed:
            print("  -", n)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
