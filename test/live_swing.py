#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""swing_tool 真机抽检：正面（对可锄空地）与负面（对已锄地）都要给出真实结果。

自适应：先读玩家位置与朝向格的实际状态，再断言"游戏侧就该给这个结果"。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from live_e2e import Client, raw_get  # noqa: E402

FACE_OFF = {0: (0, -1), 1: (1, 0), 2: (0, 1), 3: (-1, 0)}
results = []


def check(name, cond, extra=""):
    results.append(cond)
    print(("ok   - " if cond else "FAIL - ") + name + ("" if cond else f"  [{extra}]"))


def facing_tile():
    st = raw_get("/state")
    p = st["player"]
    dx, dy = FACE_OFF[p["facingDirection"]]
    return (p["x"], p["y"]), (p["x"] + dx, p["y"] + dy)


def tile_state(x, y):
    sur = raw_get("/surroundings?radius=3")
    for t in sur["tiles"]:
        if t["x"] == x and t["y"] == y:
            return t
    return {"x": x, "y": y}


c = Client()
try:
    # 先站到一个已知可锄的空地旁：直接让 go_to 走，随后按实际朝向格判定
    t, e = c.call("go_to", {"x": 55, "y": 12})
    c.call("face", {"direction": 2})
    pos, (fx, fy) = facing_tile()
    tile = tile_state(fx, fy)
    print(f"玩家 {pos}，朝向格 ({fx},{fy}) 现状: {tile}")
    if tile.get("terrain") == "HoeDirt":
        print("（朝向格已是 HoeDirt，走负面用例）")
        t, e = c.call("swing_tool", {"name": "Hoe"})
        check("swing_tool 对已锄地：诚实拒绝", e and "already tilled" in t, t)
    else:
        t, e = c.call("swing_tool", {"name": "Hoe"})
        check("swing_tool 对可锄空地：成功且报告作用格", (not e) and f"({fx},{fy})" in t, t)
        after = tile_state(fx, fy)
        check(f"swing_tool 后 ({fx},{fy}) 变 HoeDirt", after.get("terrain") == "HoeDirt", after)
        # 紧接着对同一格再挥一次 → 应被拒绝（证明不是假成功）
        t2, e2 = c.call("swing_tool", {"name": "Hoe"})
        check("swing_tool 重复挥同一格：诚实拒绝", e2 and "already tilled" in t2, t2)
finally:
    c.close()

print(f"\nlive_swing: {sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
