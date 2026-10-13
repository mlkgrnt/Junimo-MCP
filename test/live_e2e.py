#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M3 真机最小闭环 e2e：锄地 → 播种 → 浇水（全程经 MCP stdio 工具调用）。

用法: python live_e2e.py [x] [y] [rows] [length]
     默认地块 (53,12) 2x2（农舍西侧可耕地，M3 实测选点）。
依赖: 游戏在跑且 NagiBridge :7842 可用；_build/default/bin/main.exe 已构建。

与 mock_smoke.py 的区别：目标是真游戏，不做剧情断言，而是
1) 逐工具打印回读结果；2) 用独立 HTTP 读回游戏数据做交叉验证（锄后是 HoeDirt、
   播种后有 crop、浇水后 watered=true）。
"""

import json
import os
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
EXE = os.path.join(ROOT, "_build", "default", "bin", "main.exe")
BASE = "http://localhost:7842"

results = []


def check(name, cond, extra=""):
    ok = bool(cond)
    results.append((name, ok))
    suffix = ""
    if not ok and extra:
        suffix = "  [" + str(extra)[:300].replace("\n", " / ") + "]"
    print(("ok   - " if ok else "FAIL - ") + name + suffix)
    return ok


def raw_get(path):
    """独立于 MCP 的直读（绕过任何代理）。"""
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with op.open(BASE + path, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def tiles_around(x, y, radius=6):
    d = raw_get(f"/surroundings?radius={radius}")
    return {(t["x"], t["y"]): t for t in d.get("tiles", [])}, d


class Client:
    def __init__(self):
        env = dict(os.environ)
        env["STARDEW_API_URL"] = BASE
        self.errlog = open(os.path.join(HERE, ".live_e2e_stderr.log"), "w", encoding="utf-8")
        self.p = subprocess.Popen(
            [EXE],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.errlog,
            env=env,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.next_id = 1
        self.request("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}})
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
            err = ""
            try:
                self.errlog.flush()
                with open(os.path.join(HERE, ".live_e2e_stderr.log"), encoding="utf-8") as f:
                    err = f.read()[-800:]
            except Exception:
                pass
            raise RuntimeError(f"main.exe 无响应（{method}）。stderr: {err}")
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


def main():
    x = int(sys.argv[1]) if len(sys.argv) > 1 else 53
    y = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else 2
    length = int(sys.argv[4]) if len(sys.argv) > 4 else 2
    cells = []
    for r in range(rows):
        cx = x + (length - 1) if r % 2 == 1 else x
        step = -1 if r % 2 == 1 else 1
        for k in range(length):
            cells.append((cx + step * k, y + r))

    print(f"### M3 真机闭环：地块起点 ({x},{y}) {rows}行x{length}格，格子 {cells}")

    # ---------- 前置快照（直读） ----------
    before, st = tiles_around(x, y, radius=8)
    print(
        "位置:",
        st["center"],
        "地图:",
        st["location"],
        "| 地块内已有作物:",
        [(c, before.get(c, {}).get("crop")) for c in cells if before.get(c, {}).get("crop")],
    )
    state0 = raw_get("/state")
    print("金币:", state0["player"]["money"], "体力:", round(state0["player"]["stamina"], 1))

    c = Client()
    try:
        # ---------- 1. get_state ----------
        t, e = c.call("get_state")
        check("get_state 正常返回", (not e) and ("玩家" in t or "位置" in t), t)
        print(t)
        print("-" * 60)

        # ---------- 2. till ----------
        t, e = c.call("till", {"x": x, "y": y, "rows": rows, "length": length})
        print("till ->", t)
        check("till 工具调用成功（无 isError）", not e, t)
        after_till, _ = tiles_around(x, y, radius=8)
        for cell in cells:
            terr = after_till.get(cell, {}).get("terrain")
            check(f"锄地验证 {cell} 是 HoeDirt", terr == "HoeDirt", after_till.get(cell))
        print("-" * 60)

        # ---------- 3. plant ----------
        t, e = c.call("plant", {"seed": "Parsnip Seeds", "x": x, "y": y, "rows": rows, "length": length})
        print("plant ->", t)
        check("plant 工具调用成功（无 isError）", not e, t)
        after_plant, _ = tiles_around(x, y, radius=8)
        for cell in cells:
            tinfo = after_plant.get(cell, {})
            check(f"播种验证 {cell} 有作物", bool(tinfo.get("crop")), tinfo)
        print("-" * 60)

        # ---------- 4. water ----------
        t, e = c.call("water", {"radius": 15})
        print("water ->", t)
        check("water 工具调用成功（无 isError）", not e, t)
        after_water, _ = tiles_around(x, y, radius=15)
        for cell in cells:
            tinfo = after_water.get(cell, {})
            check(f"浇水验证 {cell} watered=true", tinfo.get("watered") is True, tinfo)
        # 用户原有作物是否也浇上了
        crops = [tinfo for tinfo in after_water.values() if tinfo.get("crop")]
        unwatered = [tinfo for tinfo in crops if tinfo.get("watered") is not True]
        print(f"半径内作物共 {len(crops)} 株，未浇水 {len(unwatered)} 株")
        print("-" * 60)

        # ---------- 5. 收尾 get_state ----------
        t, e = c.call("get_state")
        print(t)
    finally:
        c.close()

    state1 = raw_get("/state")
    print("金币:", state1["player"]["money"], "体力:", round(state1["player"]["stamina"], 1))

    n_ok = sum(1 for _, ok in results if ok)
    n_all = len(results)
    print("-" * 60)
    print(f"M3 LIVE E2E: {n_ok}/{n_all} 通过")
    sys.exit(0 if n_ok == n_all else 1)


if __name__ == "__main__":
    main()
