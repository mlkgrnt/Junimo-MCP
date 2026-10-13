#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v3 工具真机验收（NagiBridge-Remix）：天气 / 箱子取物 / 吃 / 社交 / 节日。

流程：
  0) 等游戏在线；未进档自动进档（复用 live_m4 流程）
  1) /pause 冻结时钟（NPC 也停住，便于定位）
  2) 天气：raw /state.time.weather + get_state 渲染【天气】行
  3) 农舍箱子：chest_scan → chest_take（取 1 个测完放回）→ chest_take_list（同上 + 找不到路径）
  4) eat：吃 1 个 Parsnip（若背包有）；工具不可食用报错路径
  5) 社交：find_npc → friendship（英文直查 + 中文解析）→ gift（送 1 个）→ 好感记账复查
  6) festival：无活动 + 列出下个节日
  7) warp 回农场（sleep 落盘由外层处理）
前置: 游戏进程在跑。所有对存档的改动均为最小可逆（取物放回；吃/送礼为一次性小消耗）。
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from live_e2e import Client, raw_get, check, results  # noqa: E402
from live_m4 import raw_post, wait_status, load_save  # noqa: E402


def inv_of():
    return raw_get("/state").get("inventory", [])


def inv_count(name):
    return sum(it.get("stack", 0) for it in inv_of() if it.get("name") == name)


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
        # ---- 1) 天气 ----
        stj = raw_get("/state")
        w = (stj.get("time") or {}).get("weather")
        check("remix /state 含 weather（0-7）", isinstance(w, int) and 0 <= w <= 7,
              str(stj.get("time")))
        t, e = c.call("get_state")
        check("get_state: 渲染【天气】行", (not e) and "【天气】" in t, t)

        # ---- 2) 箱子：找一个"背包里没有的物品"作测试目标，取 1 个测完放回 ----
        t, e = c.call("warp", {"location": "FarmHouse"})
        check("warp 农舍", (not e) and ("已到达" in t), t)

        t, e = c.call("chest_scan")
        print("chest_scan ->\n" + t)
        check("chest_scan: 列出农舍箱子", (not e) and "格" in t and "(" in t, t)

        inv_names = {it.get("name") for it in inv_of()}
        target = None
        for (cx, cy) in [(3, 7), (1, 7)]:
            ch = raw_post("/chest", {"x": cx, "y": cy})
            for it in ch.get("items", []):
                if it.get("name") not in inv_names:
                    target = (cx, cy, it["name"], it.get("count", 1))
                    break
            if target:
                break
        check("找到可测箱子物品（背包没有的）", target is not None, "两个箱子都无可测物？")
        if target:
            cx, cy, iname, c0 = target
            t, e = c.call("chest_take", {"x": cx, "y": cy, "name": iname, "count": 1})
            print("chest_take ->", t.replace("\n", " / "))
            check("chest_take: 取出 x1", (not e) and ("x1" in t), t)
            check("chest_take: 进背包", inv_count(iname) == 1, str(inv_of()))
            n1 = raw_post("/chest", {"x": cx, "y": cy})
            got1 = next((it["count"] for it in n1.get("items", []) if it["name"] == iname), 0)
            check("chest_take: 箱子数量-1", got1 == max(0, c0 - 1), f"{c0}->{got1}")
            t, e = c.call("chest_store", {"x": cx, "y": cy, "name": iname})
            check("chest_take: 已还原（存回）", (not e), t)

            # chest_take_list（站近箱子；取 1 个再放回）
            raw_post("/position", {"x": cx, "y": cy + 1})
            time.sleep(0.4)
            t, e = c.call("chest_take_list", {"items": [f"{iname} x1"]})
            print("chest_take_list ->", t.replace("\n", " / "))
            check("chest_take_list: 取到 x1", (not e) and (iname in t) and ("取到 1 个" in t), t)
            t, e = c.call("chest_store", {"x": cx, "y": cy, "name": iname})
            check("chest_take_list: 已还原（存回）", (not e), t)

        t, e = c.call("chest_take_list", {"items": ["No Such Item ZZ"]})
        check("chest_take_list: 找不到如实列", (not e) and "没找到" in t, t)

        # ---- 3) eat ----
        food = next((n for n in ("Parsnip", "Joja Cola") if inv_count(n) >= 1), None)
        if food:
            n0 = inv_count(food)
            t, e = c.call("eat", {"name": food})
            print("eat ->", t.replace("\n", " / "))
            check(f"eat: 吃下 {food}", (not e) and (f"已吃下 {food}" in t), t)
            check(f"eat: {food} 数量-1", inv_count(food) == n0 - 1,
                  f"{n0}->{inv_count(food)}")
        else:
            print("（背包没有可吃食物，跳过成功路径）")
            check("eat: 背包无可吃食物（跳过，记录）", True, "")
        t, e = c.call("eat", {"name": "Hoe"})
        check("eat: 工具不可食用报错", e and "不可食用" in t, t)

        # ---- 4) 社交：find_npc / friendship / gift ----
        t, e = c.call("find_npc", {"name": "Abigail"})
        print("find_npc ->", t.replace("\n", " / "))
        check("find_npc: 找到 Abigail", (not e) and "Abigail" in t, t)

        t, e = c.call("friendship", {"npc": "Abigail"})
        check("friendship: 直查渲染", (not e) and "好感" in t, t)
        t, e = c.call("friendship", {"npc": "阿比盖尔"})
        check("friendship: 中文名解析", (not e) and "Abigail" in t and "好感" in t, t)

        # 选一个"醒着"的 NPC 送礼（优先列表，找不到就跳过）
        gift_npc = None
        for cand in ["Abigail", "Robin", "Caroline", "Pierre", "Lewis"]:
            fres = raw_get(f"/find_npc?name={cand}")
            for n in fres.get("npcs", []):
                if n.get("name") == cand and not n.get("isSleeping"):
                    gift_npc = n
                    break
            if gift_npc:
                break
        if gift_npc is None:
            print("（候选 NPC 都在睡觉，跳过送礼）")
            check("gift: 无醒着的 NPC（跳过，记录）", True, "")
        else:
            gname = gift_npc["name"]
            gloc = gift_npc["location"]
            print(f"→ 送礼目标: {gname} @ {gloc}({gift_npc['x']},{gift_npc['y']})")
            # 礼物：优先 Daffodil（从工具箱取 1 朵，普遍受欢迎）→ 兜底 Fiber
            if inv_count("Daffodil") < 1:
                raw_post("/chest_take", {"x": 1, "y": 7, "name": "Daffodil", "count": 1})
                time.sleep(0.3)
            gift_item = None
            if inv_count("Daffodil") >= 1:
                gift_item = "Daffodil"
            elif inv_count("Fiber") >= 1:
                gift_item = "Fiber"
            if gift_item is None:
                print("（背包没有可用礼物，跳过送礼）")
                check("gift: 无礼物（跳过，记录）", True, "")
            else:
                fr0 = raw_get(f"/friendship?npc={gname}")
                raw_post("/warp", {"location": gloc})
                time.sleep(1.0)
                f2 = raw_get(f"/find_npc?name={gname}")
                n2 = next((x for x in f2.get("npcs", []) if x.get("name") == gname), None)
                if n2:
                    t, e = c.call("go_to", {"x": n2["x"], "y": n2["y"] + 1, "timeout": 40})
                    print("go_to ->", t.replace("\n", " / "))
                    time.sleep(0.5)
                t, e = c.call("gift", {"target": gname, "item": gift_item})
                print(f"gift {gift_item} ->", t.replace("\n", " / "))
                check("gift: 送出成功", (not e) and ("好感" in t or "已给" in t), t)
                fr1 = raw_get(f"/friendship?npc={gname}")
                check("gift: 好感记账（giftsToday +1）",
                      fr1.get("giftsToday", 0) == fr0.get("giftsToday", 0) + 1,
                      f"{fr0.get('giftsToday')}->{fr1.get('giftsToday')}")

        # ---- 5) 节日 ----
        t, e = c.call("festival")
        print("festival ->", t.replace("\n", " / "))
        check("festival: 无活动 + 列出下个节日",
              (not e) and ("没有节日活动" in t) and ("【下一个节日】" in t), t)

        # ---- 6) 回农场收尾 ----
        t, e = c.call("warp", {"location": "Farm"})
        check("warp 回农场", (not e) and ("已到达" in t), t)
    finally:
        c.close()
    return finish()


def finish():
    n_ok = sum(1 for _, ok in results if ok)
    n_all = len(results)
    print("-" * 60)
    print(f"v3 LIVE: {n_ok}/{n_all} 通过")
    sys.exit(0 if n_ok == n_all else 1)


if __name__ == "__main__":
    main()
