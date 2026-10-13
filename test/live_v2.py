#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v2 生计工具真机验收：map_info / chest_read / chest_store / pause_time / resume_time / sleep。

流程：
  0) 等游戏在线；未进档则自动点标题界面进档（复用 live_m4 的流程）
  1) /pause 冻结时钟
  2) MCP: get_state → map_info（真机建筑/传送点）
  3) MCP: warp FarmHouse → chest_read（读农舍两个箱子）→ chest_store(Fiber x2 → (3,7)) → 再读验证
  4) MCP: pause_time / resume_time
  5) warp 回 Farm → （此处由外层用连接器原生工具浇一次水）
  6) MCP: sleep → 翻日验证 + 落盘
前置: 游戏进程在跑。
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from live_e2e import Client, raw_get, check, results  # noqa: E402
from live_m4 import raw_post, wait_status, load_save  # noqa: E402


def main():
    st = wait_status()
    check("游戏在线（/status 可达）", st is not None, "game not reachable")
    if st is None:
        return finish()

    if not st.get("worldReady"):
        time.sleep(6)
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
        check("get_state 正常", not e, t)
        print(t.split("\n")[0])

        # 1) map_info
        t, e = c.call("map_info")
        print("map_info ->\n" + t)
        check("map_info: 含农舍", (not e) and "Farmhouse" in t, t)
        check("map_info: 含温室", "Greenhouse" in t, t)
        check("map_info: 含送货箱/传送点", ("Shipping Bin" in t or "传送点" in t), t)

        # 2) 箱子（农舍内）
        t, e = c.call("warp", {"location": "FarmHouse"})
        check("warp 农舍", (not e) and ("已到达" in t), t)
        t, e = c.call("chest_read", {"x": 1, "y": 7})
        print("chest(1,7) ->\n" + t)
        check("chest_read: 读到工具箱", (not e) and ("格" in t) and ("x" in t), t)
        t, e = c.call("chest_read", {"x": 3, "y": 7})
        print("chest(3,7) -> " + t.replace("\n", " / "))
        check("chest_read: 读到空箱", not e, t)
        t, e = c.call("chest_store", {"x": 3, "y": 7, "name": "Fiber"})
        print("chest_store ->", t.replace("\n", " "))
        check("chest_store: 存入 Fiber", (not e) and ("Fiber" in t), t)
        t, e = c.call("chest_read", {"x": 3, "y": 7})
        check("chest_read: 存入后可见 Fiber", "Fiber" in t, t)

        # 3) 时钟控制
        t, e = c.call("pause_time")
        check("pause_time", (not e) and "冻结" in t, t)
        t, e = c.call("resume_time")
        check("resume_time", (not e) and "恢复" in t, t)

        # 4) 回农场（随后由外层用连接器原生工具浇水）
        t, e = c.call("warp", {"location": "Farm"})
        check("warp 回农场", (not e) and ("已到达" in t), t)

        # 5) 睡觉翻日（落盘）
        day0 = raw_get("/state")["time"]["dayOfMonth"]
        print(f"→ sleep（翻日会写盘，较慢；当前 day={day0}）")
        t, e = c.call("sleep")
        print("sleep ->", t.replace("\n", " / "))
        check("sleep: 翻日成功", (not e) and ("睡醒" in t), t)
        st2 = raw_get("/state")
        check(f"翻日后 day={day0 + 1}", st2["time"]["dayOfMonth"] == day0 + 1,
              st2["time"])
        p = st2["player"]
        check("翻日后体力满", p["stamina"] >= p["maxStamina"] - 0.5, p["stamina"])
        t, e = c.call("get_inventory")
        check("起床后 Fiber 不在背包（已存入箱）", "Fiber" not in t, t)
    finally:
        c.close()
    return finish()


def finish():
    n_ok = sum(1 for _, ok in results if ok)
    n_all = len(results)
    print("-" * 60)
    print(f"v2 LIVE: {n_ok}/{n_all} 通过")
    sys.exit(0 if n_ok == n_all else 1)


if __name__ == "__main__":
    main()
