#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mock NagiBridge：内存状态机仿真服务器（测试/回归/演示用，不依赖游戏）。

用法:
    python mock_nagibridge.py [--port 8792] [--no-world]

真机行为仿真要点（均对照 ModEntry.cs 源码）:
- /state 未就绪时只返回 {ok, worldReady}
- 动作端点在未就绪时返回 {"error": "World not ready"}（HTTP 200）
- /move 异步：起步 100ms 内 isMoving=false（race 窗口），(lag+duration) 后坐标跳到位
- /tool /use /select 失败时返回 {ok:false, error:"..."}（顶层带 error 键）
- /surroundings: tiles 只含有信息的格子（墙/物件/terrain/diggable/crop）
- watered 字段仅在 true 时出现

仅 mock 提供的控制端点: POST /mock/set {world,x,y,facing,stamina,water,menu}
"""

import argparse
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PLAYER_NAME = "Tester"
MOVE_LAG = 0.1  # 起步 race 窗口（秒）
MOVE_DURATION = 0.8  # 移动时长（秒）

# 多屏剧情（真机：SDV 剧本事件就是这样一屏一屏推进的；最后一屏是问题框，必须选）
# 形如 (台词, 选项列表或 None)
STORY_LINES = [
    ("我看到它坐在你的农场门口！它可能是无家可归了……可怜的小东西。", None),
    ("你要把它带回家吗？", None),
    (
        "你打算收养这只猫吗？",
        [
            {"index": 0, "key": "Yes", "text": "是",
             "bounds": {"x": 48, "y": 528, "w": 1184, "h": 60}},
            {"index": 1, "key": "No", "text": "否",
             "bounds": {"x": 48, "y": 596, "w": 1184, "h": 60}},
        ],
    ),
]

# 地图字符:
#   # 墙  . 空地  D 可锄泥地  d 已锄(无作物)  c 作物未浇水  C 作物已浇水
#   R 成熟作物(未浇水)  X 石头  E 箱子  T 树
RAW_MAP = [
    "####################",
    "#..................#",
    "#..DDDD............#",
    "#..DDDD............#",
    "#..dddd............#",
    "#..cccc......X.....#",
    "#..CCCC............#",
    "#..RRRR............#",
    "#..................#",
    "#....E.........X...#",
    "#..................#",
    "#..T...............#",
    "####################",
]


def make_tile(ch, r, c):
    if ch == "#":
        return {"kind": "wall"}
    if ch == ".":
        return {"kind": "empty"}
    if ch == "D":
        return {"kind": "diggable"}
    if ch == "d":
        return {"kind": "soil"}
    if ch == "c":
        return {"kind": "soil", "has_crop": True, "phase": 2, "watered": False, "harvestable": False}
    if ch == "C":
        return {"kind": "soil", "has_crop": True, "phase": 2, "watered": True, "harvestable": False}
    if ch == "R":
        return {"kind": "soil", "has_crop": True, "phase": 4, "watered": False, "harvestable": True}
    if ch == "X":
        return {"kind": "object", "name": "Stone", "block": True}
    if ch == "E":
        return {
            "kind": "object",
            "name": "Chest",
            "block": False,
            "chest_items": [
                {"name": "Maple Seed", "count": 4},
                {"name": "Fiber", "count": 2},
            ],
        }
    if ch == "T":
        return {"kind": "tree"}
    raise ValueError(f"unknown map char {ch!r} at ({c},{r})")


class World:
    def __init__(self):
        self.reset()

    def reset(self):
        self.w = len(RAW_MAP[0])
        self.h = len(RAW_MAP)
        self.grid = [
            [make_tile(ch, r, c) for c, ch in enumerate(row)]
            for r, row in enumerate(RAW_MAP)
        ]
        self.world_ready = True
        self.px, self.py, self.facing = 9, 9, 0
        self.health, self.max_health = 100, 100
        self.stamina, self.max_stamina = 270.0, 270.0
        self.money = 1539
        self.current = "Hoe"
        self.tool_upgrade = 0
        self.day = 13
        self.time_of_day = 610
        self.season = "spring"
        self.year = 1
        self.inv = [
            {"name": "Hoe", "stack": 1, "category": "工具"},
            {"name": "Axe", "stack": 1, "category": "工具"},
            {"name": "Watering Can", "stack": 1, "category": "工具", "waterLeft": 10, "waterMax": 40},
            {"name": "Parsnip Seeds", "stack": 15, "category": "种子"},
            {"name": "Cheese", "stack": 2, "category": "食物"},
            {"name": "Daffodil", "stack": 2, "category": "物资"},
        ]
        self.menu = None
        self.active_event = None
        self.story_idx = 0
        self.pending_answer = None
        self.move_target = None
        self.move_start = 0.0
        # v3（Remix 仿真）：NPC / 好感 / 天气 / 节日活动
        self.npcs = [
            {"name": "Abigail", "displayName": "阿比盖尔", "x": 6, "y": 3, "facing": 2},
        ]
        self.friendship = {
            "Abigail": {"points": 100, "giftsThisWeek": 0, "giftsToday": 0},
        }
        self.weather = 0
        self.festival_active = False

    # ---------- 移动仿真 ----------

    def tick(self):
        if self.move_target is not None:
            if time.time() - self.move_start >= MOVE_LAG + MOVE_DURATION:
                self.px, self.py = self.move_target
                self.move_target = None

    def is_moving(self):
        if self.move_target is None:
            return False
        return (time.time() - self.move_start) >= MOVE_LAG

    def facing_tile(self):
        dx, dy = {0: (0, -1), 1: (1, 0), 2: (0, 1), 3: (-1, 0)}[self.facing]
        return self.px + dx, self.py + dy

    def tile_at(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.grid[y][x]
        return None

    def need_world(self):
        if not self.world_ready:
            raise MockError("World not ready")

    # ---------- 端点实现 ----------

    def status(self):
        return {
            "ok": True,
            "server": "NagiBridge(mock)",
            "version": "1.0.0",
            "port": PORT,
            "worldReady": self.world_ready,
            "isMultiplayer": False,
        }

    def state(self):
        self.tick()
        if not self.world_ready:
            return {"ok": True, "worldReady": False}
        return {
            "ok": True,
            "worldReady": True,
            "player": {
                "name": PLAYER_NAME,
                "x": self.px,
                "y": self.py,
                "health": self.health,
                "maxHealth": self.max_health,
                "stamina": self.stamina,
                "maxStamina": self.max_stamina,
                "money": self.money,
                "currentTool": self.current,
                "currentToolUpgrade": self.tool_upgrade,
                "facingDirection": self.facing,
                "isMoving": self.is_moving(),
                "fishing": None,
            },
            "location": {"name": "Farm", "mapWidth": self.w, "mapHeight": self.h},
            "time": {
                "timeOfDay": self.time_of_day,
                "dayOfMonth": self.day,
                "season": self.season,
                "year": self.year,
                "weather": self.weather,
            },
            "activeMenu": self.menu,
            "activeEvent": self.active_event,
            "npcs": [],
            "inventory": self.inv,
        }

    def surroundings(self, radius):
        self.tick()
        self.need_world()
        radius = max(1, min(30, radius))
        tiles = []
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                tx, ty = self.px + dx, self.py + dy
                t = self.tile_at(tx, ty)
                if t is None:
                    continue
                k = t["kind"]
                passable = not (k in ("wall", "tree") or (k == "object" and t.get("block")))
                e = {"x": tx, "y": ty, "passable": passable}
                if k == "diggable":
                    e["diggable"] = True
                if k == "object":
                    e["object"] = t["name"]
                if k == "soil":
                    e["terrain"] = "HoeDirt"
                    if t.get("has_crop"):
                        e["crop"] = "24"
                        e["cropPhase"] = t.get("phase", 0)
                        e["harvestable"] = t.get("harvestable", False)
                    if t.get("watered"):
                        e["watered"] = True
                if k == "tree":
                    e["terrain"] = "Tree:1"
                has_info = (not passable) or ("object" in e) or ("terrain" in e) or ("diggable" in e)
                if has_info:
                    tiles.append(e)
        return {
            "ok": True,
            "center": {"x": self.px, "y": self.py},
            "radius": radius,
            "location": "Farm",
            "tiles": tiles,
            "npcs": [],
            "monsters": [],
            "farmers": [],
        }

    def move(self, body):
        self.need_world()
        x, y = int(body["x"]), int(body["y"])
        steps = abs(x - self.px) + abs(y - self.py)
        thr_long = getattr(self, "no_path_long", 0)
        if getattr(self, "no_path", False) and steps > 1:
            # 模拟真 mod 的"直线穿墙"回退（BFS 失败 → 直接把目标塞进队列，steps=1）
            steps = 1
        elif thr_long and steps > thr_long:
            # 模拟 BFS 步数上限：超过阈值的长距才失败（用于测分段接力）
            steps = 1
        self.move_target = (x, y)
        self.move_start = time.time()
        return {"ok": True, "message": f"Moving to ({x},{y}), steps={steps}"}

    def stop(self):
        self.move_target = None
        return {
            "ok": True,
            "message": "Movement stopped",
            "location": "Farm",
            "x": self.px,
            "y": self.py,
        }

    def position(self, body):
        self.need_world()
        self.px, self.py = int(body["x"]), int(body["y"])
        self.move_target = None
        return {"ok": True, "action": "positioned", "location": "Farm", "x": self.px, "y": self.py}

    def face(self, body):
        self.need_world()
        d = int(body["direction"])
        if d < 0 or d > 3:
            raise MockError("direction must be 0-3 (up/right/down/left)")
        self.facing = d
        return {"ok": True, "direction": d}

    def warp(self, body):
        self.need_world()
        loc = body.get("location", "Farm")
        if "x" in body:
            self.px = int(body["x"])
        if "y" in body:
            self.py = int(body["y"])
        self.move_target = None
        return {"ok": True, "location": loc, "x": self.px, "y": self.py}

    def tool(self, body):
        self.need_world()
        name = body.get("name", "current")
        if name != "current":
            found = next(
                (it for it in self.inv if it["name"].lower() == name.lower() and it["category"] == "工具"),
                None,
            )
            if found is None:
                return {"ok": False, "error": f"Tool '{name}' not found in inventory"}
            self.current = found["name"]
        fx, fy = self.facing_tile()
        self.apply_tool_effect(self.current, fx, fy)
        self.stamina = max(0.0, self.stamina - 2.0)
        return {"ok": True, "tool": self.current}

    def apply_tool_effect(self, tool, fx, fy):
        t = self.tile_at(fx, fy)
        if t is None:
            return
        if tool == "Hoe" and t["kind"] == "diggable":
            self.grid[fy][fx] = {"kind": "soil", "watered": False}
        elif tool == "Watering Can":
            if t["kind"] == "soil":
                wc = next((it for it in self.inv if it["name"] == "Watering Can"), None)
                if wc is not None and wc.get("waterLeft", 0) > 0:
                    wc["waterLeft"] -= 1
                    t["watered"] = True
        elif tool == "Axe" and t["kind"] == "tree":
            self.grid[fy][fx] = {"kind": "empty"}

    def use(self, body):
        self.need_world()
        item = self.current
        fx, fy = self.facing_tile()
        t = self.tile_at(fx, fy)
        if t is None:
            return {"ok": False, "error": "Facing tile out of bounds"}
        if "Seeds" in item:
            if t["kind"] == "soil" and not t.get("has_crop"):
                t["has_crop"] = True
                t["phase"] = 0
                t["harvestable"] = False
                for it in self.inv:
                    if it["name"] == item:
                        it["stack"] -= 1
                        if it["stack"] <= 0:
                            self.inv.remove(it)
                        break
                return {"ok": True, "action": "placed", "item": item, "tile": {"x": fx, "y": fy}}
            return {"ok": False, "error": f"Cannot place '{item}' here", "tile": {"x": fx, "y": fy}}
        # 工具路径：与真 mod 的 ValidateToolUse 对齐（Hoe / Watering Can 精确校验）
        if item == "Hoe":
            if t["kind"] == "soil":
                return {"ok": False, "error": "Tile already tilled",
                        "tile": {"x": fx, "y": fy}, "tool": item}
            if t["kind"] != "diggable":
                return {"ok": False, "error": "Tile is not diggable",
                        "tile": {"x": fx, "y": fy}, "tool": item}
        elif item == "Watering Can":
            if t["kind"] != "soil":
                return {"ok": False, "error": "No tilled soil here — till first",
                        "tile": {"x": fx, "y": fy}, "tool": item}
            if t.get("watered"):
                return {"ok": False, "error": "Already watered",
                        "tile": {"x": fx, "y": fy}, "tool": item}
        self.apply_tool_effect(item, fx, fy)
        self.stamina = max(0.0, self.stamina - 2.0)
        return {"ok": True, "action": "tool", "item": item, "tile": {"x": fx, "y": fy}}

    def interact(self, body):
        self.need_world()
        fx, fy = self.facing_tile()
        t = self.tile_at(fx, fy)
        result = {"ok": True, "actionTriggered": False, "facingTile": {"x": fx, "y": fy}}
        if t is not None:
            if t["kind"] == "object":
                result["object"] = t["name"]
                result["actionTriggered"] = t["name"] == "Chest"
            if t["kind"] == "soil":
                result["terrain"] = "HoeDirt"
                if t.get("has_crop") and t.get("harvestable"):
                    result["harvestable"] = True
        return result

    def _story_advance(self):
        """剧情一屏一屏推进（真机就是按 confirm 推进 DialogueBox）。"""
        i = self.story_idx + 1
        if i >= len(STORY_LINES):
            self.story_idx = 0
            self.active_event = None
            self.menu = None
            return
        self.story_idx = i
        line, opts = STORY_LINES[i]
        self.active_event["message"] = line
        self.menu = {
            "type": "DialogueBox",
            "dialogue": line,
            "responses": opts,
            "speaker": "玛妮",
        }

    def key(self, body):
        self.need_world()
        key = body.get("key", "confirm")
        count = int(body.get("count", 1))
        if key.lower() in ("confirm", "action"):
            if self.active_event is not None:
                # 剧情：一屏一屏推进；最后一屏是问题框（带 options），confirm 推不动
                if self.menu is not None and not self.menu.get("responses"):
                    self._story_advance()
            elif self.menu is not None and not self.menu.get("responses"):
                # 无选项对话（NPC 招呼/提示框）⇒ confirm 关掉
                self.menu = None
        if key.lower() == "skip" and self.menu is not None:
            # 剧本事件跳过：真机上 press_key skip 能整段结束事件（含问题框）
            self.menu = None
            self.active_event = None
            self.story_idx = 0
        return {"ok": True, "key": key, "count": count}

    def select(self, body):
        self.need_world()
        name = body.get("name", "")
        for i, it in enumerate(self.inv):
            if it["name"].lower() == name.lower():
                self.current = it["name"]
                return {"ok": True, "selected": name, "slot": i}
        return {"ok": False, "error": f"Item '{name}' not found in inventory"}

    def refill(self):
        self.need_world()
        wc = next((it for it in self.inv if it["name"] == "Watering Can"), None)
        if wc is None:
            return {"ok": False, "error": "No watering can in inventory"}
        wc["waterLeft"] = wc.get("waterMax", 40)
        return {"ok": True, "water": wc["waterLeft"], "max": wc.get("waterMax", 40)}

    # ---------- v2 生计端点 ----------

    def sleep(self, body=None):
        self.need_world()
        self.day += 1
        self.time_of_day = 600
        self.stamina = self.max_stamina
        return {
            "ok": True,
            "state": "slept",
            "home": "FarmHouse",
            "bed": "9,9",
            "note": "the day is ending",
        }

    def buy(self, body):
        self.need_world()
        item_id = str(body.get("id", "")).replace("(O)", "")
        qty = int(body.get("quantity", 1))
        table = {
            "472": ("Parsnip Seeds", 40, "种子"),
            "473": ("Green Bean Seeds", 120, "种子"),
        }
        row = table.get(item_id)
        if row is None:
            return {"ok": False, "error": f"Cannot create item: {item_id}"}
        name, unit, cat = row
        total = unit * qty
        if self.money < total:
            return {
                "ok": False,
                "error": f"Not enough gold. Need {total}g, have {self.money}g",
                "need": total,
                "have": self.money,
            }
        self.money -= total
        for it in self.inv:
            if it["name"] == name:
                it["stack"] += qty
                break
        else:
            self.inv.append({"name": name, "stack": qty, "category": cat})
        return {
            "ok": True,
            "bought": name,
            "quantity": qty,
            "unitPrice": unit,
            "totalCost": total,
            "remainingGold": self.money,
        }

    def sell(self, body):
        self.need_world()
        name = body.get("name", "")
        allf = bool(body.get("all", False))
        if not allf and not name:
            return {"ok": False, "error": "specify name or all"}
        sold = []
        for it in list(self.inv):
            if it.get("category") == "工具":
                continue
            if allf and "Seeds" in it["name"]:
                continue
            if (not allf) and it["name"].lower() != name.lower():
                continue
            sold.append({"item": it["name"], "count": it["stack"], "price": it["stack"]})
            self.inv.remove(it)
        return {"ok": True, "sold": sold, "totalItems": len(sold)}

    def chest(self, body):
        x, y = int(body["x"]), int(body["y"])
        t = self.tile_at(x, y)
        if t is None or t.get("name") != "Chest":
            return {"ok": False, "error": f"No chest at ({x},{y})"}
        items = list(t.get("chest_items", []))
        return {"ok": True, "items": items, "capacity": 36, "used": len(items)}

    def store(self, body):
        x, y = int(body["x"]), int(body["y"])
        t = self.tile_at(x, y)
        if t is None or t.get("name") != "Chest":
            return {"ok": False, "error": f"No chest at ({x},{y})"}
        name = body.get("name", "")
        keep_tools = bool(body.get("keepTools", True))
        stored = []
        for it in list(self.inv):
            if keep_tools and it.get("category") == "工具":
                continue
            if name and it["name"].lower() != name.lower():
                continue
            t.setdefault("chest_items", []).append(
                {"name": it["name"], "count": it["stack"]}
            )
            stored.append({"item": it["name"], "count": it["stack"]})
            self.inv.remove(it)
        return {"ok": True, "stored": stored, "chestAt": {"x": x, "y": y}}

    def map(self):
        self.need_world()
        return {
            "ok": True,
            "location": {"name": "Farm", "width": self.w, "height": self.h},
            "buildings": [
                {
                    "type": "Farmhouse",
                    "x": 8,
                    "y": 1,
                    "width": 4,
                    "height": 3,
                    "doorX": 9,
                    "doorY": 4,
                },
            ],
            "warps": [
                {
                    "x": 19,
                    "y": 8,
                    "targetLocation": "BusStop",
                    "targetX": 11,
                    "targetY": 23,
                },
            ],
            "npcs": [],
            "farmers": [],
            "animals": [],
        }

    def pause(self, body=None):
        return {"ok": True, "action": "paused", "frozenAt": self.time_of_day}

    def resume(self, body=None):
        return {"ok": True, "action": "resumed"}

    def harvest(self, radius):
        self.need_world()
        radius = max(1, min(50, radius))
        count = 0
        for dy in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                t = self.tile_at(self.px + dx, self.py + dy)
                if t is not None and t["kind"] == "soil" and t.get("harvestable"):
                    t["has_crop"] = False
                    t["harvestable"] = False
                    count += 1
        if count:
            for it in self.inv:
                if it["name"] == "Parsnip":
                    it["stack"] += count
                    break
            else:
                self.inv.append({"name": "Parsnip", "stack": count, "category": "作物"})
        return {"ok": True, "harvested": count}

    # ---------- 批次 3：/walk_to 与 /tool_area ----------

    def walk_to(self, body):
        """仿真 POST /walk_to：入口校验（越界/门格/站不住）+ 发射后不管。

        ⚠️ 与真 mod 一致：ok:true 只代表"路线布好了"，人还在走 —— 调用方必须轮询坐标。
        与 /move 不同，真 mod 的 walk_to 内部寻路**没有 500 步上限**，故不受 no_path_long 影响。
        """
        self.need_world()
        loc = body.get("location") or ""
        if not loc:
            # 不传 location 会被当成跨图 → 找不到该图（真 mod 行为）
            return {"ok": False, "error": "Location '' not found"}
        x = int(body.get("x", -1))
        y = int(body.get("y", -1))
        if x < 0 or y < 0:
            x, y = self.px, self.py
        if not (0 <= x < self.w and 0 <= y < self.h):
            return {
                "ok": False,
                "error": f"目标 ({x},{y}) 越界：{loc} 只有 {self.w}x{self.h} 格"
                f"（0..{self.w - 1}, 0..{self.h - 1}）",
            }
        if getattr(self, "walk_door", False):
            return {
                "ok": False,
                "warp_tile": True,
                "error": "那格是门/传送格（踩上去会换图）—— 要进门请用 interact；跨图请用 map ops=go",
            }
        if getattr(self, "no_path", False):
            return {
                "ok": False,
                "error": f"目标 ({x},{y}) 及周围 8 圈都站不住（被墙/物体/牲畜堵死）",
            }
        if getattr(self, "walk_stall", False):
            # 仿真真机偶发（328 次里 1 次）：路线布好了却走不动
            # ⇒ 调用方应回退分段接力兜底，而不是干等超时
            return {
                "ok": True,
                "action": "walk_to",
                "destination": {"location": loc, "x": x, "y": y},
                "segments": 1,
            }
        self.move_target = (x, y)
        self.move_start = time.time()
        return {
            "ok": True,
            "action": "walk_to",
            "destination": {"location": loc, "x": x, "y": y},
            "segments": 1,
        }

    def tool_area(self, body):
        """仿真 POST /tool_area：矩形批量蓄力农活（真挥动语义，不直写地块）。"""
        self.need_world()
        op = body.get("operation")
        if op not in ("water", "till"):
            return {"ok": False, "error": "operation must be 'water' or 'till'"}
        x1 = int(body.get("x1", -1))
        y1 = int(body.get("y1", -1))
        x2 = int(body.get("x2", -1))
        y2 = int(body.get("y2", -1))
        if min(x1, y1, x2, y2) < 0:
            return {"ok": False, "error": "need rect x1/y1/x2/y2 or no target tiles"}
        targets = []
        for x in range(min(x1, x2), max(x1, x2) + 1):
            for y in range(min(y1, y2), max(y1, y2) + 1):
                t = self.tile_at(x, y)
                if t is None:
                    continue
                if op == "till":
                    # 真 mod 的 IsTillTarget：可耕 + 无物件/建筑（mock 里 object 就算占格）
                    if t["kind"] == "diggable":
                        targets.append((x, y))
                else:
                    # 真 mod 的 IsWaterTarget：有作物 + 还没浇
                    if t["kind"] == "soil" and t.get("has_crop") and not t.get("watered"):
                        targets.append((x, y))
        if not targets:
            what = "unwatered crops" if op == "water" else "diggable tiles"
            return {"ok": False, "error": f"No {what} nearby"}
        done = []
        out_of_water = False
        for x, y in targets:
            if op == "till":
                self.grid[y][x] = {"kind": "soil", "watered": False}
                done.append((x, y))
            else:
                wc = next((it for it in self.inv if it["name"] == "Watering Can"), None)
                if wc is None or wc.get("waterLeft", 0) <= 0:
                    out_of_water = True
                    continue
                wc["waterLeft"] -= 1
                self.grid[y][x]["watered"] = True
                done.append((x, y))
        still = [
            {"x": x, "y": y, "reason": "water_short" if op == "water" else "blocked"}
            for (x, y) in targets
            if (x, y) not in done
        ]
        return {
            "ok": True,
            "operation": op,
            "swings": len(targets),
            "patches": 0,
            "still_missing": still,
            "out_of_water": out_of_water,
            "equipment_avoided": [],
            "anchors_skipped_by_equipment": 0,
            "anchors_moved_by_equipment": 0,
            "result": [],
        }

    def menu_get(self):
        if self.menu is None:
            return {"ok": True, "open": False, "activeEvent": self.active_event}
        m = {"ok": True, "open": True, "type": self.menu.get("type", "Menu"),
             "dialogue": self.menu.get("dialogue"),
             "responses": self.menu.get("responses"),
             "shopItems": self.menu.get("shopItems"),
             "buttons": self.menu.get("buttons")}
        return m

    def menu_close(self):
        """关掉当前菜单（真机 /menu_close 语义：只关界面，不等于回答问题）。"""
        if self.menu is None:
            return {"ok": True, "closed": False, "reason": "no menu"}
        t = self.menu.get("type", "Menu")
        self.menu = None
        return {"ok": True, "closed": True, "menu": t, "clearedCursor": 0, "dropped": None}

    def menu_click(self, body):
        if self.menu is None:
            return {"ok": False, "error": "No menu open"}
        if "option" in body:
            # 回答剧情里的问题 ⇒ 整段事件结束（真机 event_answerDialogueQuestion 后走完剩余脚本，
            # mock 简化为"事件结束"）
            if self.active_event is not None:
                # ⚠️ 真机语义（2026-10-15 实测）：剧情问题框上**默认点击只登记答案、不关框**，
                #    事件也不推进；必须再来一发 `real=true`（mod 先设 selectedResponse 再真实点击）
                #    才会关框。这里如实仿真，用来守住 story 的"两段式"兜底。
                if body.get("real"):
                    self.active_event = None
                    self.story_idx = 0
                    self.menu = None
                    return {"ok": True, "clicked": "response", "option": int(body["option"]),
                            "real": True}
                self.pending_answer = int(body["option"])
                return {"ok": True, "clicked": "response", "option": int(body["option"]),
                        "key": "Yes" if int(body["option"]) == 0 else "No",
                        "method": "event_answerDialogueQuestion"}
            self.menu = None
            return {"ok": True, "clicked": "response", "option": int(body["option"])}
        if "button" in body:
            self.menu = None
            return {"ok": True, "clicked": "button", "button": body["button"]}
        if "x" in body and "y" in body:
            self.menu = None
            return {"ok": True, "clicked": "position", "x": int(body["x"]), "y": int(body["y"])}
        self.menu = None
        return {"ok": True, "clicked": "center"}

    # ---------- v3 端点（Remix 仿真，2026-10-13） ----------

    def eat(self, body=None):
        self.need_world()
        item = self.current
        cur = next((it for it in self.inv if it["name"] == item), None)
        if cur is None or cur.get("category") != "食物":
            return {"ok": False, "error": "当前物品不可食用（先 /select 选个食物）"}
        hp0, sta0 = self.health, int(self.stamina)
        cur["stack"] -= 1
        if cur["stack"] <= 0:
            self.inv.remove(cur)
        self.health = min(self.max_health, self.health + 30)
        self.stamina = min(self.max_stamina, self.stamina + 50.0)
        return {
            "ok": True,
            "ate": item,
            "settledMs": 2400,
            "hpBefore": hp0, "hpAfter": self.health,
            "staBefore": sta0, "staAfter": int(self.stamina),
            "buffsBefore": 0, "buffsAfter": 0,
            "statsChanged": (hp0 != self.health) or (sta0 != int(self.stamina)),
            "health": self.health, "stamina": int(self.stamina),
        }

    def gift(self, body):
        self.need_world()
        target = str(body.get("target", "")).strip()
        item_name = str(body.get("item", "")).strip()
        npc = next(
            (n for n in self.npcs
             if n["name"].lower() == target.lower() or n["displayName"] == target),
            None,
        )
        if npc is None:
            return {"ok": False, "error": f"找不到目标 {target}（当前地图无此 NPC，也不在玩家列表）"}
        it = next((x for x in self.inv if x["name"].lower() == item_name.lower()), None)
        if it is None:
            return {"ok": False, "error": f"背包里没有 {item_name}"}
        if it.get("category") == "工具":
            return {"ok": False, "error": f"{it['name']} 不能作为礼物"}
        fs = self.friendship.setdefault(
            npc["name"], {"points": 0, "giftsThisWeek": 0, "giftsToday": 0}
        )
        if fs["giftsToday"] >= 1:
            return {"ok": False,
                    "error": f"今天已经给 {npc['name']} 送过礼物了（SDV 每天 1 次、每周 2 次）——物品没动，明天再来"}
        before = fs["points"]
        it["stack"] -= 1
        if it["stack"] <= 0:
            self.inv.remove(it)
        fs["giftsToday"] += 1
        fs["giftsThisWeek"] += 1
        fs["points"] += 80
        return {
            "ok": True, "action": "gifted_npc",
            "target": npc["name"], "item": it["name"],
            "taste": 0, "tasteLabel": "最爱",
            "friendshipBefore": before, "friendshipAfter": fs["points"], "delta": 80,
        }

    def friendship_get(self, qs):
        self.need_world()
        name = qs.get("npc", [""])[0]
        fs = self.friendship.get(name)
        if fs is None:
            return {"ok": True, "npc": name, "points": 0, "hearts": 0,
                    "giftsThisWeek": 0, "giftsToday": 0, "known": False}
        return {"ok": True, "npc": name, "points": fs["points"],
                "hearts": fs["points"] // 250,
                "giftsThisWeek": fs["giftsThisWeek"],
                "giftsToday": fs["giftsToday"], "known": True}

    def find_npc(self, qs):
        self.need_world()
        name = qs.get("name", [""])[0].strip()
        hits = []
        if name:
            for n in self.npcs:
                if (name.lower() in n["name"].lower()) or (name in n["displayName"]):
                    hits.append({
                        "name": n["name"], "displayName": n["displayName"],
                        "location": "Farm", "locUnique": "Farm",
                        "x": n["x"], "y": n["y"], "facing": n.get("facing", 2),
                        "isSleeping": False, "isVillager": True, "dialogue": None,
                    })
        return {"ok": True, "name": name, "count": len(hits), "npcs": hits}

    def scan_chests(self):
        self.need_world()
        chests = []
        for y, row in enumerate(self.grid):
            for x, t in enumerate(row):
                if t.get("kind") == "object" and t.get("name") == "Chest":
                    items = []
                    for idx, it in enumerate(t.get("chest_items", [])):
                        items.append({
                            "name": it["name"], "displayName": it["name"],
                            "count": it["count"], "qualifiedId": "(O)0",
                            "slot": idx, "quality": 0,
                        })
                    chests.append({
                        "x": x, "y": y, "items": items, "capacity": 36,
                        "used": len(items), "location": "Farm",
                        "name": "", "typeId": "(BC)130", "typeName": "Chest",
                        "color": "", "autoTag": "", "freeSlots": 36 - len(items),
                    })
        return {"ok": True, "location": "Farm", "count": len(chests), "chests": chests}

    def _chest_take_one(self, items, name, slot, count):
        """从 chest_items 里取；返回 (taken, taken_name)。"""
        taken, taken_name = 0, ""
        i = 0
        while i < len(items):
            it = items[i]
            if slot >= 0 and i != slot:
                i += 1
                continue
            if name and it["name"].lower() != name.lower():
                i += 1
                continue
            if taken_name == "":
                taken_name = it["name"]
            want = min(count - taken, it["count"])
            if want <= 0:
                break
            for inv_it in self.inv:
                if inv_it["name"] == it["name"]:
                    inv_it["stack"] += want
                    break
            else:
                self.inv.append({"name": it["name"], "stack": want, "category": "物资"})
            it["count"] -= want
            taken += want
            if it["count"] <= 0:
                items.pop(i)
            else:
                i += 1
        return taken, taken_name

    def chest_take(self, body):
        self.need_world()
        x, y = int(body["x"]), int(body["y"])
        t = self.tile_at(x, y)
        if t is None or t.get("name") != "Chest":
            return {"ok": False, "error": f"No chest at ({x},{y})"}
        name = str(body.get("name", "") or "")
        slot = int(body.get("slot", -1))
        count = int(body.get("count", 2**31 - 1))
        if slot < 0 and not name:
            return {"ok": False, "error": "要么给 name（物品名），要么给 slot（箱子里的格号）"}
        taken, taken_name = self._chest_take_one(
            t.setdefault("chest_items", []), name, slot, count
        )
        return {"ok": True, "taken": taken,
                "item": name if name else taken_name,
                "slot": slot if slot >= 0 else -1,
                "chestAt": {"x": x, "y": y}}

    def chest_take_list(self, body):
        self.need_world()
        reqs = []
        for el in body.get("items", []):
            if isinstance(el, str):
                reqs.append((el, -1))
            elif isinstance(el, dict):
                reqs.append((str(el.get("name", "")), int(el.get("count", -1))))
        all_chests = []
        for y, row in enumerate(self.grid):
            for x, t in enumerate(row):
                if t.get("kind") == "object" and t.get("name") == "Chest":
                    all_chests.append((x, y, t))
        near, too_far = [], []
        for (x, y, t) in all_chests:
            cheb = max(abs(x - self.px), abs(y - self.py))
            if cheb <= 4:
                near.append((x, y, t))
            else:
                too_far.append({"x": x, "y": y, "name": "Chest"})
        results = []
        for (req_name, want_count) in reqs:
            target = 2**31 - 1 if want_count <= 0 else want_count
            taken = 0
            from_list = []
            for (x, y, t) in near:
                if taken >= target:
                    break
                items = t.setdefault("chest_items", [])
                got, _ = self._chest_take_one(items, req_name, -1, target - taken)
                if got > 0:
                    from_list.append({"x": x, "y": y, "name": "Chest",
                                      "color": "", "autoTag": "", "got": got})
                    taken += got
            results.append({
                "item": req_name,
                "wanted": -1 if want_count <= 0 else target,
                "taken": taken,
                "from": from_list,
            })
        return {"ok": True, "location": "Farm", "items": results,
                "tooFar": too_far, "reachTiles": 4}

    def festival_get(self):
        self.need_world()
        if not self.festival_active:
            return {"ok": False, "error": "No active event"}
        return {
            "ok": True, "isFestival": True, "festivalName": "Egg Festival",
            "location": "Temp", "actorCount": 1, "festivalTimer": 60000,
            "festivalScore": 3,
            "actors": [{"name": "Abigail", "displayName": "阿比盖尔", "x": 30, "y": 20}],
        }

    def festival_interact(self, body):
        self.need_world()
        if not self.festival_active:
            return {"ok": False, "error": "No active event"}
        name = str(body.get("name", "") or "")
        return {"ok": True, "target": name or "Abigail",
                "targetTile": {"x": 30, "y": 20},
                "playerTile": {"x": 30, "y": 21},
                "standPicked": True, "triggered": True}

    def festival_answer(self, body):
        self.need_world()
        if not self.festival_active:
            return {"ok": False, "error": "No active event"}
        ans = int(body.get("answer", 0))
        return {"ok": True, "method": "answerDialogueQuestion",
                "answer": ans, "key": str(ans)}

    # ---------- mock 专用控制 ----------

    def mock_set(self, body):
        if "world" in body:
            self.world_ready = bool(body["world"])
        if "x" in body:
            self.px = int(body["x"])
            self.move_target = None
        if "y" in body:
            self.py = int(body["y"])
            self.move_target = None
        if "facing" in body:
            self.facing = int(body["facing"])
        if "stamina" in body:
            self.stamina = float(body["stamina"])
        if "water" in body:
            wc = next((it for it in self.inv if it["name"] == "Watering Can"), None)
            if wc is not None:
                wc["waterLeft"] = int(body["water"])
        if "no_path" in body:
            self.no_path = bool(body["no_path"])
        if "no_path_long" in body:
            self.no_path_long = int(body["no_path_long"])
        if "toolUpgrade" in body:
            self.tool_upgrade = int(body["toolUpgrade"])
        if "walk_door" in body:
            self.walk_door = bool(body["walk_door"])
        if "walk_stall" in body:
            self.walk_stall = bool(body["walk_stall"])
        if "unwater" in body and body["unwater"]:
            # 把所有作物的浇水状态清掉（测批量浇水用；真 mod 的 IsWaterTarget 只挑未浇作物）
            for row in self.grid:
                for t in row:
                    if t.get("kind") == "soil":
                        t["watered"] = False
        if "weather" in body:
            self.weather = int(body["weather"])
        if "festival" in body:
            self.festival_active = bool(body["festival"])
        if "menu" in body:
            v = body["menu"]
            self.active_event = None  # 设菜单 = 清掉上一场事件（测试隔离）
            self.story_idx = 0
            if v is None:
                self.menu = None
            elif v == "dialogue":
                self.menu = {
                    "type": "DialogueBox",
                    "dialogue": "你好，旅行者！要不要看看我的货？",
                    "responses": [
                        {"index": 0, "key": "1", "text": "你好"},
                        {"index": 1, "key": "2", "text": "再见"},
                    ],
                }
            elif v == "confirm":
                self.menu = {"type": "ConfirmationDialog", "dialogue": "确定要这么做吗？"}
            elif v == "plain":
                # 无选项对话（NPC 招呼 / 送礼答谢 那类）：responses 为 null
                self.menu = {
                    "type": "DialogueBox",
                    "dialogue": "嗨，你好呀！今天天气不错。",
                    "responses": None,
                    "speaker": "阿比盖尔",
                }
        if "event" in body:
            v = body["event"]
            if v is None:
                self.active_event = None
                self.story_idx = 0
            elif v == "story":
                # 多屏剧情：read → next → next → 问题屏 → choose → 结束
                self.story_idx = 0
                line, opts = STORY_LINES[0]
                self.active_event = {
                    "id": "1590166",
                    "skippable": True,
                    "message": line,
                }
                self.menu = {
                    "type": "DialogueBox",
                    "dialogue": line,
                    "responses": opts,
                    "speaker": "玛妮",
                }
            elif v == "pet":
                # 仿真真机的"宠物领养"剧本事件：走位触发 → 弹问题框 → 角色不能移动
                self.active_event = {
                    "id": "1590166",
                    "skippable": True,
                    "message": "我看到它坐在你的农场门口！它可能是无家可归了……",
                }
                self.menu = {
                    "type": "DialogueBox",
                    "dialogue": "你打算收养这只猫吗？",
                    "responses": ["是", "否"],
                    "speaker": None,
                }
        return {"ok": True}


class MockError(Exception):
    pass


PORT = 8792


class Handler(BaseHTTPRequestHandler):
    world = None

    def log_message(self, fmt, *args):
        # 请求日志走 stderr（调试排查用）；平时可被调用方重定向掉
        sys.stderr.write("[mock] " + (fmt % args) + "\n")
        sys.stderr.flush()

    def _send(self, obj, status=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n <= 0:
            return {}
        try:
            data = self.rfile.read(n)
            return json.loads(data.decode("utf-8"))
        except Exception:
            return {}

    def _route(self):
        u = urlparse(self.path)
        path = u.path
        qs = parse_qs(u.query)
        body = self._read_body()
        w = Handler.world
        try:
            if path == "/status":
                return self._send(w.status())
            if path == "/state":
                return self._send(w.state())
            if path == "/surroundings":
                radius = int(qs.get("radius", ["10"])[0])
                return self._send(w.surroundings(radius))
            if path == "/move":
                return self._send(w.move(body))
            if path == "/stop":
                return self._send(w.stop())
            if path == "/position":
                return self._send(w.position(body))
            if path == "/face":
                return self._send(w.face(body))
            if path == "/warp":
                return self._send(w.warp(body))
            if path == "/tool":
                return self._send(w.tool(body))
            if path == "/use":
                return self._send(w.use(body))
            if path == "/interact":
                return self._send(w.interact(body))
            if path == "/key":
                return self._send(w.key(body))
            if path == "/select":
                return self._send(w.select(body))
            if path == "/refill":
                return self._send(w.refill())
            if path == "/sleep":
                return self._send(w.sleep())
            if path == "/buy":
                return self._send(w.buy(body))
            if path == "/sell":
                return self._send(w.sell(body))
            if path == "/chest":
                return self._send(w.chest(body))
            if path == "/store":
                return self._send(w.store(body))
            if path == "/map":
                return self._send(w.map())
            if path == "/pause":
                return self._send(w.pause())
            if path == "/resume":
                return self._send(w.resume())
            if path == "/harvest":
                radius = int(qs.get("radius", ["15"])[0])
                return self._send(w.harvest(radius))
            # 批次 3（2026-10-14）：一次走全程 + 矩形批量农活
            if path == "/walk_to":
                return self._send(w.walk_to(body))
            if path == "/tool_area":
                return self._send(w.tool_area(body))
            if path == "/menu":
                return self._send(w.menu_get())
            if path == "/menu/click":
                return self._send(w.menu_click(body))
            if path == "/menu_close":
                return self._send(w.menu_close())
            # v3（Remix 仿真）
            if path == "/eat":
                return self._send(w.eat(body))
            if path == "/gift":
                return self._send(w.gift(body))
            if path == "/friendship":
                return self._send(w.friendship_get(qs))
            if path == "/find_npc":
                return self._send(w.find_npc(qs))
            if path == "/scan_chests":
                return self._send(w.scan_chests())
            if path == "/chest_take":
                return self._send(w.chest_take(body))
            if path == "/chest_take_list":
                return self._send(w.chest_take_list(body))
            if path == "/festival":
                return self._send(w.festival_get())
            if path == "/festival/interact":
                return self._send(w.festival_interact(body))
            if path == "/festival/answer":
                return self._send(w.festival_answer(body))
            if path == "/mock/set":
                return self._send(w.mock_set(body))
            return self._send({"error": f"Unknown endpoint {path}"}, status=404)
        except MockError as e:
            return self._send({"error": str(e)})

    def do_GET(self):
        self._route()

    def do_POST(self):
        self._route()


def main():
    global PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8792)
    ap.add_argument("--no-world", action="store_true", help="启动时为未进档状态")
    args = ap.parse_args()
    PORT = args.port
    world = World()
    if args.no_world:
        world.world_ready = False
    Handler.world = world
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock NagiBridge listening on http://localhost:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
