#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""稳定性压测（M4）：连续多轮只读+走位操作，观察错误率、延迟与 curl 子进程回收。

用法: python live_soak.py [分钟数]   默认 8。
前置: 游戏在跑（建议先 /pause 冻结时钟，避免测试期间游戏翻夜）。
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from live_e2e import Client, raw_get  # noqa: E402

RUN_MIN = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0


def curl_count():
    try:
        r = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq curl.exe"],
            capture_output=True, text=True, timeout=30,
        )
        return r.stdout.lower().count("curl.exe")
    except Exception:
        return -1


def pick_step_target(px, py):
    sur = raw_get("/surroundings?radius=8")
    cands = [
        t for t in sur["tiles"]
        if t.get("passable") and t.get("diggable")
        and "object" not in t and "resource" not in t and "terrain" not in t
        and 2 <= max(abs(t["x"] - px), abs(t["y"] - py)) <= 8
    ]
    if not cands:
        return None
    cands.sort(key=lambda t: max(abs(t["x"] - px), abs(t["y"] - py)))
    pool = cands[: max(1, len(cands) // 3)]  # 最近的 1/3 里挑，避免大范围漂移
    return pool[int(time.time() * 1000) % len(pool)]


def main():
    c = Client()
    t0 = time.time()
    n_cycle = n_ops = n_err = n_unreach = 0
    lat = []
    curl_before = curl_count()
    while time.time() - t0 < RUN_MIN * 60:
        n_cycle += 1
        cyc0 = time.time()
        ops = []
        t, e = c.call("get_state")
        ops.append(("get_state", e, t))
        t, e = c.call("look", {"radius": 6})
        ops.append(("look", e, t))
        st = raw_get("/state")["player"]
        tgt = pick_step_target(st["x"], st["y"])
        if tgt:
            t, e = c.call("go_to", {"x": tgt["x"], "y": tgt["y"], "timeout": 25})
            ops.append(("go_to", e, t))
        t, e = c.call("get_inventory")
        ops.append(("get_inventory", e, t))
        lat.append(time.time() - cyc0)
        for name, err, txt in ops:
            n_ops += 1
            if err:
                # 目标格是随机挑的，可能天然不可达（被墙/水隔断）。工具如实报
                # "无路可走"是**正确行为**（不是稳定性问题）⇒ 单列，不计入错误。
                if name == "go_to" and any(
                    k in txt for k in ("寻路失败", "No path", "不可达", "拒绝走位", "站不住")
                ):
                    n_unreach += 1
                    print(f"[cycle {n_cycle}] {name} 目标不可达（如实报错，不计错）: {txt[:120]}")
                    continue
                n_err += 1
                print(f"[cycle {n_cycle}] {name} isError: {txt[:160]}")
        if n_cycle % 10 == 0:
            print(f"... {n_cycle} 轮 / {n_ops} 次调用 / 错误 {n_err}"
                  f" / 不可达 {n_unreach} / curl 进程 {curl_count()}")
    curl_after = curl_count()
    c.close()
    dt = time.time() - t0
    print("-" * 60)
    print(f"SOAK: {dt:.0f}s, {n_cycle} 轮, {n_ops} 次工具调用, 错误 {n_err}, 目标不可达 {n_unreach}")
    print(f"每轮耗时: avg {sum(lat) / len(lat):.1f}s, max {max(lat):.1f}s")
    print(f"curl 子进程: 开始 {curl_before} → 结束 {curl_after}（应无增长 = 无泄漏）")
    ok = n_err == 0 and (curl_after < 0 or curl_after <= curl_before + 2)
    print("SOAK:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
