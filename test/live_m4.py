#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M4 真机验收：完整农活闭环 + 长距分段导航（农活全程经 MCP stdio 工具调用）。

流程:
  0) 等游戏在线（/status）；若未进档 → 自动点标题界面进档（2560x1600 布局，M0 实测坐标）
  1) /pause 冻结游戏时钟（防测试期间 2:00 晕倒）
  2) warp 回 Farm（经 MCP warp 工具）
  3) /buy 10 颗防风草种子（原价 40g/颗）
  4) till 3x3 @(54,22)（经 MCP）
  5) plant 3x3（经 MCP）
  6) water 半径 15（经 MCP；顺带把用户田里作物浇了）
  7) /position 精确到试验田中心 → /ripen?radius=1 催熟 9 株 → harvest（经 MCP）→ 验证入包
  8) 长距 go_to（自适应选 ≥25 格目标）验证分段导航
  9) /resume 恢复时钟

前置: 游戏进程已启动（StardewModdingAPI.exe）；本脚本不负责启动游戏。
"""
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from live_e2e import Client, raw_get, check, results  # noqa: E402

BASE = "http://localhost:7842"
PLOT = dict(x=54, y=22, rows=3, length=3)


def raw_post(path, body=None):
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    data = json.dumps(body or {}).encode("utf-8")
    req = urllib.request.Request(
        BASE + path, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with op.open(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def wait_status(timeout=120):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            return raw_get("/status")
        except Exception:
            time.sleep(1.5)
    return None


def load_save(slot=0):
    """标题界面 → 自动进档。

    ⚠️ 三条真机经验（2026-10-15 全部实测踩过）：
      1. **必须用 `/click`**，不能用 `/menu/click` —— 前者会先 `Game1.setMousePosition`
         把光标挪到位；而标题页读的是**真实鼠标位置**（mod 的 `_MENUS_READING_REAL_MOUSE`
         名单 2026-09-26 已清空），不挪光标就是"点了没反应"。
      2. 存档格中心 = **(640, 129 + slot*166)** —— 由 `loadgamemenu.cs` 的布局公式推出
         （xPos=uiW/2-582、yPos=uiH/2-332、每格高 height/4+4=166；1280×720 UI）。
      3. Load 界面是 TitleMenu 的**内部 subMenu**，`/menu` 永远报 `TitleMenu`——别被它误导。
    """
    for attempt in range(3):
        print(f"→ 进档尝试 {attempt + 1}: /click Load(517,609) + 存档槽{slot}(640,{129 + slot * 166})")
        raw_post("/focus", {})
        time.sleep(0.5)
        raw_post("/click", {"x": 517, "y": 609})  # Load
        time.sleep(3.5)
        raw_post("/click", {"x": 640, "y": 129 + slot * 166})  # 存档格
        t0 = time.time()
        while time.time() - t0 < 25:
            if raw_get("/status").get("worldReady"):
                return True
            time.sleep(1.5)
        time.sleep(1.0)
    return False


def main():
    st = wait_status()
    check("游戏在线（/status 可达）", st is not None, "game not reachable")
    if st is None:
        return finish()

    if not st.get("worldReady"):
        time.sleep(6)  # 等标题界面完全就绪
        ok = load_save()
        check("自动进档成功", ok, "3 次尝试均未进档")
        if not ok:
            return finish()
    else:
        print("（已进档，跳过点击进档）")

    print("→ /pause 冻结时钟")
    print("   ", raw_post("/pause"))

    c = Client()
    try:
        t, e = c.call("get_state")
        print(t)
        check("get_state 正常", not e, t)

        # 1) 回农场
        t, e = c.call("warp", {"location": "Farm"})
        check("warp 回 Farm", (not e) and "已到达" in t, t)

        # 2) 买种
        r = raw_post("/buy", {"id": "472", "quantity": 10})
        check("远程买 10 颗防风草种子", bool(r.get("ok")) and r.get("bought") == "Parsnip Seeds", r)
        print("   ", r)

        # 3) 锄地 3x3（试验田可能已是耕地——重复锄会如实报"已完成"而不是假成功）
        t, e = c.call("till", dict(PLOT))
        print("till ->", t)
        check("till 3x3 = 全部到位（锄成 9/9 或 9 格已完成）",
              (not e) and ("成功 9/9" in t or "另有 9 格已完成" in t), t)
        sur = raw_get("/surroundings?radius=8")
        cells = [(PLOT["x"] + i, PLOT["y"] + r_) for r_ in range(PLOT["rows"]) for i in range(PLOT["length"])]
        hoe = {(tt["x"], tt["y"]) for tt in sur["tiles"] if tt.get("terrain") == "HoeDirt"}
        check("till 后 9 格全为 HoeDirt", all(cl in hoe for cl in cells),
              f"missing {[cl for cl in cells if cl not in hoe]}")

        # 4) 播种 3x3
        t, e = c.call("plant", dict(seed="Parsnip Seeds", **PLOT))
        print("plant ->", t)
        check("plant 3x3 = 成功 9/9", (not e) and "成功 9/9" in t, t)
        sur = raw_get("/surroundings?radius=8")
        planted = {(tt["x"], tt["y"]) for tt in sur["tiles"] if tt.get("crop")}
        check("播种后 9 格有作物", all(cl in planted for cl in cells),
              f"missing {[cl for cl in cells if cl not in planted]}")

        # 5) 浇水
        t, e = c.call("water", {"radius": 15})
        print("water ->", t)
        check("water 调用成功", not e, t)
        sur = raw_get("/surroundings?radius=15")
        watered = {(tt["x"], tt["y"]) for tt in sur["tiles"] if tt.get("watered") and tt.get("crop")}
        check("试验田 9 格已浇水", all(cl in watered for cl in cells),
              f"missing {[cl for cl in cells if cl not in watered]}")
        dry = [tt for tt in sur["tiles"] if tt.get("crop") and not tt.get("watered")]
        check("半径内无遗留旱作物", not dry, f"{[(d['x'], d['y']) for d in dry]}")

        # 6) 催熟（只催我的 9 株：精确站到田中心，radius=1 恰好覆盖试验田）
        raw_post("/position", {"x": 55, "y": 23})
        time.sleep(0.4)
        r = raw_get("/ripen?radius=1")
        check("催熟恰好 9 株（未波及用户作物）", bool(r.get("ok")) and r.get("ripened") == 9, r)
        print("   ", r)

        # 7) 收割（只收成熟作物）
        t, e = c.call("harvest", {"radius": 3})
        print("harvest ->", t)
        check("harvest 收获 9 个", (not e) and "9 个" in t, t)
        t, e = c.call("get_inventory")
        # 防风草可能分叠存放（多轮测试累积），按总量统计而不是匹配 "Parsnip x9"
        total_parsnip = sum(
            it["stack"] for it in raw_get("/state")["inventory"] if it["name"] == "Parsnip"
        )
        check("背包防风草总量 ≥9", total_parsnip >= 9, f"共 {total_parsnip} 个 / {t[:120]}")

        # 8) 长距分段导航
        sur = raw_get("/surroundings?radius=30")
        me = sur["center"]
        cands = [
            tt for tt in sur["tiles"]
            if tt.get("passable") and tt.get("diggable")
            and "object" not in tt and "resource" not in tt and "terrain" not in tt
            and max(abs(tt["x"] - me["x"]), abs(tt["y"] - me["y"])) >= 25
        ]
        if cands:
            tgt = max(cands, key=lambda tt: max(abs(tt["x"] - me["x"]), abs(tt["y"] - me["y"])))
            dist = max(abs(tgt["x"] - me["x"]), abs(tgt["y"] - me["y"]))
            print(f"→ 长距目标 ({tgt['x']},{tgt['y']})，切比雪夫距离 {dist}")
            t, e = c.call("go_to", {"x": tgt["x"], "y": tgt["y"], "timeout": 90})
            check(f"长距分段导航到达（{dist} 格）", (not e) and "已到达" in t, t)
            pos = raw_get("/state")["player"]
            # 到达判定为 cheb<=1（设计如此）：紧邻建筑等目标格可能游戏侧不可站立
            off = max(abs(pos["x"] - tgt["x"]), abs(pos["y"] - tgt["y"]))
            check("长距目标到达（≤1 格容差）", off <= 1,
                  f"停在 ({pos['x']},{pos['y']})，目标 ({tgt['x']},{tgt['y']})")
        else:
            print("（半径 30 内没有 ≥25 格的干净目标，跳过长距测试）")

        # 9) 收尾
        print("→ /resume 恢复时钟")
        print("   ", raw_post("/resume"))
        t, e = c.call("get_state")
        print(t)
    finally:
        c.close()
    return finish()


def finish():
    n_ok = sum(1 for _, ok in results if ok)
    n_all = len(results)
    print("-" * 60)
    print(f"M4 LIVE FARM: {n_ok}/{n_all} 通过")
    sys.exit(0 if n_ok == n_all else 1)


if __name__ == "__main__":
    main()
