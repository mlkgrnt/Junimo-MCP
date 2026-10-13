# Junimo-MCP — PRD（产品需求文档）

> 项目：让 AI Agent 通过 MCP 协议游玩《星露谷物语》
> 版本：v0.1 草案（2026-10-13）· 状态：**待评审，确认后开工**
> 目标环境：Windows · 星露谷 v1.6.15（Steam）· SMAPI 4.x · NagiBridge v1.1.0 · OCaml 5.5.0

---

## 1. 背景与目标

### 1.1 一句话

用 **OCaml 手写一个 stdio MCP server**，内置一套「意图工具」，通过 **NagiBridge mod 的本地 HTTP API** 操控游戏角色，让任意 MCP 客户端（WorkBuddy / Claude Code 等）里的 Agent 真的能「下地干活」。

### 1.2 为什么这样架构

- **不自研游戏内插件**：mod 端（C#，NagiBridge 原作，MIT）已经提供了 47 个经过实战检验的 HTTP 端点，自己写 C# mod 是无谓工作。
- **不自研 MCP 层用库**：OCaml 生态无成熟 MCP SDK（已核实 5 个社区项目，最高 61★ 且依赖实验性 effects 库或已停更）。本任务的 MCP 需求子集很小（initialize / tools list / tools call），手写 ~300 行即可，且完全可控。
- **编排智能放 OCaml 侧**：原作 mod 是「低层原语」（走一步、挥一次工具），「锄一片地」这种意图级编排由我们实现——这是本项目「自研含量」的核心，也是可迭代、可测试的部分。

### 1.3 目标（成功标准）

| 级别 | 标准 |
|---|---|
| 硬指标 1 | mock 环境下 17 个工具全绿 + `dune runtest` 通过 + 接入 WorkBuddy 可见工具 |
| 硬指标 2 | 真机最小闭环：Agent 在游戏里完成「走到田里 → 锄地 → 播种 → 浇水」 |
| 软指标 | 一次完整农活（锄 3×3 → 种 → 浇 → 收）流畅跑通；工具返回对 Agent 友好（状态速报、错误可恢复） |
| 降级条款 | 若单人档控制主角路线实测不通，允许切「联机 farmhand」方案 B，不算烂尾 |

### 1.4 非目标（明确不做）

- ❌ 视觉/截图感知（v1 纯文本；原作无截图端点，后续另评估）
- ❌ 联机双人协作、多客户端同时控制
- ❌ 作弊端点（`/give` `/money` `/heal` `/ripen` `/pause`）——默认不暴露
- ❌ 矿洞/节日/小游戏/社交深度（v2+ 候选，架构预留扩展位）
- ❌ 图形界面、打包分发（自用工具，`exe` + 注册说明即交付）

---

## 2. 系统总览

### 2.1 架构

```
┌─────────────────────────────────────────────────┐
│  MCP 客户端（WorkBuddy / Claude Code / …）       │
└──────────────────────┬──────────────────────────┘
                       │ stdio：一行一条 JSON-RPC 2.0
┌──────────────────────▼──────────────────────────┐
│  junimo-mcp.exe（本项目，OCaml 5.5.0）           │
│   bin/main.ml        入口：stdio 循环            │
│   lib/mcp.ml         MCP 核心（initialize/list/call）│
│   lib/intents.ml     17 个意图工具（schema+handler）│
│   lib/game_api.ml    NagiBridge 端点语义封装      │
│   lib/game_state.ml  /state 解析 + 精简渲染       │
│   lib/wait.ml        轮询等待器                   │
│   lib/http_client.ml curl 子进程 HTTP            │
└──────────────────────┬──────────────────────────┘
                       │ HTTP http://localhost:7842（自动探测 7842-7849）
┌──────────────────────▼──────────────────────────┐
│  NagiBridge mod（C#，SMAPI 4.x，游戏内）         │
│   47 端点：状态/移动/工具/菜单/收割/传送/睡觉…    │
└──────────────────────┬──────────────────────────┘
                       │ SMAPI
              星露谷物语 v1.6.15（单人档）
```

### 2.2 一次「锄一格地」的完整链路（示例）

```
Agent 调 tools/call {name:"till", arguments:{x:64,y:15}}
  → intents.ml 计算格子 [(64,15)]
  → game_api.position(64,14)         # /position 站到目标格上方
  → game_state.get() 校验          # 站对了吗？不对就报错停
  → game_api.face(2)                 # 朝下
  → game_api.tool("Hoe")             # /tool 挥锄
  → sleep 0.55s                      # 动作结算
  → 返回："锄地完成：1/1（64,15）" + 状态速报
```

---

## 3. 执行器：NagiBridge mod（游戏侧）

### 3.1 版本与安装（M0 执行）

| 项 | 值 |
|---|---|
| mod | NagiBridge 原作 v1.1.0（github.com/anqinou-art/NagiBridge，MIT） |
| 安装 | download Releases 的 `NagiBridge.zip` → 解压出 `NagiBridge` 文件夹 → 放进 `D:\SteamLibrary\steamapps\common\Stardew Valley\Mods\` |
| 前置 | SMAPI 4.x（smapi.io 安装器，自动检测 Steam 目录） |
| 编译 | 不需要（zip 内含编译好的 `NagiBridge.dll`） |
| 兼容 | 游戏 1.6+ / SMAPI 4.0+；本机 1.6.15 匹配 |

### 3.2 端口与运行模式

- 端口**自动探测**：从 7842 起找空位（`for (_port = 7842; _port < 7850; _port++)`，源码已确认）。
- **单人档**：唯一游戏进程 → 拿 **7842** → AI 控制主角。✅ **M0 已实测确认**（`isMultiplayer:false`，`/move`/`/position` 实际驱动主角移动）。
- 联机双开时：host=7842、farmhand=7843（方案 B 备用，不在 v1 范围）。
- ⚠️ **M0 实测发现：必须用 `http://localhost:7842` 访问，不能用 `127.0.0.1`**。mod 用 `HttpListener.Prefixes.Add($"http://localhost:{_port}/")` 只注册了 localhost 前缀，访问 127.0.0.1 会被 HTTP.sys 以 `400 Bad Request - Invalid Hostname` 拒绝。所有客户端配置和默认值一律写 `localhost`。

### 3.3 本方案使用的端点子集（全部经源码核实）

| 方法 | 端点 | 参数 | 返回（关键字段） | 语义 |
|---|---|---|---|---|
| GET | `/status` | — | `ok, server, version, port, worldReady, isMultiplayer` | 存活探测 + 世界就绪 |
| GET | `/state` | — | 见 3.4.1 | 全量状态 |
| GET | `/surroundings` | `?radius=1..30`(默认10) | `center, location, tiles[], npcs[], monsters[]` | 环视；tiles 只含有内容的格；`watered` 仅在为真时出现（M3 实测） |
| POST | `/move` | `{x,y}` | `{ok, message, steps}` | **异步**寻路移动；⚠️ 寻路失败会回退"直线穿墙"（`steps=1` 且距离>1）——客户端必须拒绝（4.5，M3 实测） |
| POST | `/stop` | — | `{ok}` | 停止移动 |
| POST | `/position` | `{x,y}` | `{ok}` | **瞬移**到格左上角（`Position=xy·64`）——不是读坐标（读坐标用 `/state`）；自带清残留走动（M3 实测） |
| POST | `/face` | `{direction:0-3}` | `{ok}` | 0上 1右 2下 3左 |
| POST | `/warp` | `{location,x?,y?}` | `{ok}` | 跨图/同图传送（异步生效，回读 `/state` 确认） |
| POST | `/tool` | `{name}` | `{ok, tool}` | ⚠️ **盲触发**（`BeginUsingTool`，无游戏侧校验）——只作低层裸挥；农活一律走 `/use`（M3 定案） |
| POST | `/use` | `{}` | `{ok, action, item, tile}` 或 `{ok:false, error, tile}` | 使用手持物；**带游戏侧真实校验**（Hoe→not diggable/already tilled/blocked；WateringCan→no tilled soil/already watered；返回实际校验格 `tile`）（M3 实测） |
| POST | `/interact` | `{}` | 面前格信息 | 与面前格交互（=确认键） |
| POST | `/key` | `{key,count}` | `{ok}` | 模拟按键（confirm/cancel/数字） |
| POST | `/select` | `{name}` | `{ok}` | 选中背包物品（拿手上） |
| GET | `/menu` | — | `{open, dialogue?, responses[], shopItems?, buttons[]}` | 读当前菜单/对话 |
| POST | `/menu/click` | `{option?\|button?\|x,y?}` | `{ok}` | 点菜单项 |
| POST | `/harvest` | `?radius=1..50`(15) | `{ok, harvested:N}` | **批量**收割范围内成熟作物（瞬间完成） |
| POST | `/refill` | — | `{ok, water, max}` | 补满水壶 |
| POST | `/buy` | `{id,quantity?,price?}` | `{ok,bought,unitPrice,totalCost,remainingGold}` | 远程商店（按售价×2 计价、直接进包，不用开商店界面；M3 实测用来买种子） |
| POST | `/pause` `/resume` | — | `{ok}` | 冻结/恢复游戏时钟（长测辅助：M3 实测挂机 ~12 分钟现实时间游戏就到 2:00 晕倒） |
| POST | `/chest` `/store` `/sell` | 见附录 A | — | v1 暂不用，v2 候选 |

### 3.4 关键语义与纪律（源码确认，编排必须遵守）

**3.4.1 `/state` 响应结构（精简后 Agent 可见）**

```json
{
  "ok": true, "worldReady": true,
  "player": { "name":"…", "x":64, "y":15,
              "health":100, "maxHealth":100,
              "stamina":268.0, "maxStamina":270,
              "money":500, "currentTool":"Hoe",
              "facingDirection":2, "isMoving":false },
  "location": { "name":"Farm", "mapWidth":80, "mapHeight":65 },
  "time": { "timeOfDay":620, "dayOfMonth":5, "season":"spring", "year":1 },
  "activeMenu": null | { "type":"DialogueBox", "dialogue":"…" },
  "activeEvent": null | { "id":"…", "skippable":true, "message":"…" },
  "inventory": [ { "name":"Hoe","stack":1,"category":"Tool" },
                 { "name":"Watering Can","stack":1,"category":"Tool",
                   "waterLeft":40,"waterMax":40 } ]
}
```
- `worldReady:false` 时**只有** `{ok, worldReady}` 两个字段（未进档/加载中）——所有工具先检查这个。
- `isMoving` 是**派生值**（内部路径队列非空），刚发 `/move` 的瞬间可能还是 `false`（race）——见 4.5 等待器。

**3.4.2 从原作脚本（farm_row.py / water_crops.py）提炼的硬纪律**

1. **站位约定**：对格子 `(tx,ty)` 操作 = 站到 `(tx, ty-1)`（正上方）→ 面朝 `2`（下）。这是全项目统一操作姿态（mod 端 farmhand 吸 GrabTile 有偏移，原作者实测结论）。
2. **站位校验（M3 加固）**：瞬移/移动后**必须回读 `/state` 确认坐标完全相等（不允许差 1 格）**；瞬移目标必须在当前地图 bounds 内（防"室内越界"事故）；走位 fallback 若检测到直线回退（4.5）→ 该格记失败，绝不盲发动作。
3. **动作延迟**：每次 `/tool` `/use` `/interact` 后固定等待 **0.55s**（原作 TOOL_DELAY=0.45~0.55），再进下一步。
4. **体力红线**：每格动作前检查 `stamina/maxStamina`，< 15% 时停止并回报（v1 不自动吃食物）。
5. **水壶检查**：浇水前查 `waterLeft`，空了调 `/refill`（mod 直接补满，不需要真去水边）→ `/select "Watering Can"`。
6. **背包空间**：`/give` `/craft` 背包满会**静默掉落到地上**——收割/收获前若背包接近满，v1 只在返回文本里警告（自动清包 v2 做）。
7. **菜单卡住检测**：每个动作后若 `activeMenu != null` → **中止并报告**（v1 定案，不自动推进；Agent 用 menu_read/menu_click 显式处理）。
8. **睡觉期间禁止移动**（多人限制；单人档 v1 不用 `/sleep` 工具，先不涉及）。
9. **站位以 `/position` 瞬移为主，失败 fallback `/move` 再精确校验**：`/position` 落点是格左上角，实测不影响挥动命中（命中格由 TilePoint+朝向决定）。
10. **动作走 `/use` 而非 `/tool`（M3 定案）**：`/use` 有游戏侧校验且返回命中格 `tile`，客户端须核对 `tile == 期望格`；`/tool` 是盲触发（无校验），只保底裸挥。
11. **幂等软跳过（M3 定案）**：`/use` 的 `ok:false` 中 `Tile already tilled` / `Already watered`、播种位"已有作物"（反查 `/surroundings` 确认）→ 记"已完成"（软成功），不算失败。

---

## 4. 自研 OCaml MCP Server 设计

### 4.1 技术栈（已核实可用）

| 项 | 值 | 备注 |
|---|---|---|
| OCaml | **5.5.0** @ `E:\ocaml\pi` | ⚠️ 用户要求勿用 4.14.3（mini-pi switch 弃用） |
| dune | 3.24.2 | 在 pi/bin 内 |
| yojson | 3.0.0 | 已装入 pi/lib |
| lwt | **不用** | 全同步实现；HTTP 走 curl 子进程（沿用 pi 项目既有约定） |
| HTTP | `curl.exe` 子进程 | Windows 系统自带（`C:\Windows\System32\curl.exe`） |
| 构建 | 受管 Cygwin bash + `pi-env.sh` | 详见 5.3 |

### 4.2 MCP 协议实现（手写核心）

**传输**：stdio，**一行一条 JSON 消息**（换行分隔）。纪律：**stdout 只写协议消息，一切日志走 stderr**。

**方法清单（v1 全部实现）**：

| 方向 | 方法 | 处理 |
|---|---|---|
| client→server | `initialize` | 回 `protocolVersion`（**回显客户端版本**，缺省 `2024-11-05`）、`capabilities:{tools:{}}`、`serverInfo:{name:"junimo-mcp",version}` |
| client→server | `notifications/initialized` | 记录，无响应 |
| client→server | `tools/list` | 返回 17 个工具（name/description/inputSchema） |
| client→server | `tools/call` | `{name, arguments}` → 执行 → `{content:[{type:"text",text}], isError}` |
| client→server | `ping` | `{}` |
| 任意未知 | — | JSON-RPC error `-32601`；解析失败 `-32700` |

**错误约定**：
- 工具的业务错误（游戏没开、坐标不可达、站位失败等）→ **`result.isError=true` + 可读文本 + 恢复建议**（不抛 JSON-RPC error，保持会话存活）。
- JSON-RPC error 只用于协议层错误。
- `id` 原样回显（number 或 string）。

### 4.3 工具清单 v1（17 个）

> 命名全 `snake_case`；`description` 用中文、写清「什么时候用/不能用」。
> 所有工具返回 = **结果文本 + 状态速报**（见 4.4；`get_state` 除外——它返回的本来就是全量）。

#### 感知组（3）

| 工具 | 参数 | 行为 / 底层调用 | 返回 |
|---|---|---|---|
| `get_state` | — | GET `/state` | 完整状态的可读文本（含背包摘要、activeMenu、event） |
| `look` | `radius?`(默认10，1-30) | GET `/surroundings?radius` | 附近内容归类文本：作物（含是否成熟/已浇水）、水源、可交互物、NPC/怪物；空则说"周围很空旷" |
| `get_inventory` | — | GET `/state` 取 inventory | 逐格列表（名字×数量、类别、水壶余量） |

#### 移动组（3）

| 工具 | 参数 | 行为 / 底层调用 | 返回 |
|---|---|---|---|
| `go_to` | `x,y`(必填)、`timeout?`(默认30s) | POST `/move` → 轮询 `/state` 直到「连续2次 isMoving=false 且切比雪夫距离≤1」；超时 → POST `/stop` | 到达坐标、耗时、或超时报告（含实际停在何处） |
| `warp` | `location`(必填)、`x?,y?` | POST `/warp` → 轮询直到 location 变化或坐标到位 | 新位置 |
| `face` | `direction`(0-3) | POST `/face` | ok |

#### 交互组（4）

| 工具 | 参数 | 行为 / 底层调用 | 返回 |
|---|---|---|---|
| `swing_tool` | `name?`(默认"current") | POST `/tool` → settle 0.55s → 检查 activeMenu（触发则报告） | 挥了什么 + 之后状态 |
| `use_held` | — | POST `/use` → settle → 同上 | ok + 状态 |
| `interact` | — | POST `/interact` → settle → 检查菜单 | 面前格子内容 + 状态 |
| `press_key` | `key`(confirm/cancel/数字等)、`count?`(默认1) | POST `/key` × count → settle | ok |

#### 界面组（2）

| 工具 | 参数 | 行为 / 底层调用 | 返回 |
|---|---|---|---|
| `menu_read` | — | GET `/menu` | 结构化文本：菜单类型 / 对话全文 / 选项列表（含 index）/ 商店清单 / 按钮 |
| `menu_click` | `option?` `button?` `x?` `y?`（至少一个） | POST `/menu/click` → settle | ok + 之后状态 |

#### 物品组（1）

| 工具 | 参数 | 行为 / 底层调用 | 返回 |
|---|---|---|---|
| `select_item` | `name`(必填) | POST `/select` | ok + 手持物确认 |

#### 农活组（4，复合编排——本项目核心价值）

| 工具 | 参数 | 编排逻辑（内部步骤） | 返回 |
|---|---|---|---|
| `till` | `x,y`(起点)、`rows?`(1)、`length?`(1)、`direction?`("horizontal"/"vertical") | 算格子列表（蛇形，奇行反向）→ 逐格：`/position (tx,ty-1)` → 校验 → `face(2)` → `/tool "Hoe"` → 0.55s；每格查体力；失败格记录不中断 | `已锄 N/M 格`+失败格清单 |
| `plant` | `seed`(必填，如"Parsnip Seeds")、`x,y,rows?,length?,direction?` | 先 `/select seed` 确认选中 → 逐格同上（`/use` 播种）→ 播种后顺手查一次（没有直接反馈，靠 surroundings 抽查） | `已播 N/M 格` |
| `water` | `radius?`(默认15) | GET `/surroundings` 找 `terrain=HoeDirt ∧ !watered ∧ crop` 的格子 → 蛇形排序 → `/refill` + `/select "Watering Can"` → 逐格站上方浇水；水量耗尽即 `/refill` 续 | `已浇 N 格（自动识别未浇作物）` |
| `harvest` | `radius?`(默认15) | POST `/harvest?radius`（mod 端批量收，瞬间完成）| `收获 N 个` |

> 扩展位：v2 按同一模式加 `mine`（下矿）、`buy_sell`、`sleep`（过天）等。

### 4.4 状态速报（state strip）

每个工具返回文本的**最后一行**统一附带：

```
── [春 5日 Y1 06:40 · Farm(64,15) · HP 100/100 · 体力 268/270 · 500g · 手持:Hoe]
```

- 时间换算：`timeOfDay` 620 → `06:20`（前 1-2 位小时 ×100+分钟）。
- `activeMenu` 非空时追加 `· ⚠菜单:Dialog` 提示（emoji 不用，用 `[菜单:...]`）。
- 目的：Agent 不用额外调 `get_state` 就知道全局（参考 Remix 的 state strip 设计）。
- 开关：环境变量 `STARDEW_NO_STRIP=1` 可关（调试用）。

### 4.5 等待器与错误处理策略

```
poll_until ~timeout ~interval(250ms) ~f  →  直到 f() 为 true 或超时
```

- **`go_to` 的 race 处理**：/move 返回后先 sleep 300ms（等寻路启动），再开始轮询；"到达"判定 = 连续 2 次 `isMoving=false ∧ chebyshev(now,target) ≤ 1`。
- **"≤1 格即到达"是刻意的（M3/M4 实测）**：部分目标格（如紧邻建筑/温室的格子）在游戏侧不可站立——mod 的走位能走进去，但游戏碰撞会把角色推回邻格，此时永远无法精确到达。因此 `go_to` 接受 ≤1 格并**如实回报实际坐标**（精确=「已到达」；邻格=「已到达目标附近」）；农活站位的精确性由 `stand_and_face` 的瞬移+校验独立保证，不受此容差影响。
- **直线回退防护（M3 实测新增）**：`/move` 响应里 `steps=1` 且当前距离>1 ⇒ mod 的 BFS 没找到路径、已回退"直线穿墙"（无视障碍、甚至越出地图边界）——立即 `/stop` 并按寻路失败报错，**绝不盲走**。
- **长距分段导航（M4 新增）**：mod 的 BFS 有 500 步上限，长距（约 30+ 格）必然触发回退——`go_to` 改为**分段接力**：每段 ≤10 格逐段 `/move`（每段都过直线回退防护），失败自动缩减段长，全部走完即精确到达；原地打转/超时则如实报错。
- **动作 settle**：`/tool` `/use` `/interact` `/key` 后固定 0.55s。
- **超时纪律**：任何轮询超时 → 尝试 `/stop` 恢复 → 返回 `isError=true` + 「停在了 (x,y)，原因…」。
- **世界未就绪**：任何工具在 `worldReady:false` 时返回「游戏还没进档或正在加载，请在游戏里进入存档」。
- **NagiBridge 不可达**（curl 连不上）：返回「NagiBridge 不可达：确认游戏正在运行且加载了 NagiBridge mod（默认端口 7842）」。
- **可恢复错误优先自愈**：水壶空 → 自动 refill；站位失败 → fallback `/move` 一次。**菜单被触发时（v1 定案）：不自动推进，如实中止并报告**——让 Agent 用 menu_read/menu_click 显式处理（自动 confirm 有替 Agent 做决定的风险）。
- **批量农活中止语义（M3 定案）**：`run_cells` 逐格三态计分（成功 / 软跳过 / 失败带原因）；体力<15%、菜单被触发、HTTP 层异常 → 中止并回报已完成格数与中止原因（不吞不骗）。

### 4.6 配置（环境变量）

| 变量 | 默认 | 说明 |
|---|---|---|
| `STARDEW_API_URL` | `http://localhost:7842` | NagiBridge 地址（**必须 localhost**，见 3.2；端口变了在这里改） |
| `STARDEW_CURL` | 自动探测 | curl.exe 路径覆盖 |
| `STARDEW_TIMEOUT` | `30` | 轮询总超时（秒） |
| `STARDEW_NO_STRIP` | 未设 | 设 1 关闭状态速报 |
| `STARDEW_LOG` | `warn` | stderr 日志级别 debug/info/warn |

---

## 5. OCaml 工程结构

### 5.1 目录树（工程放 `E:\junimo-mcp`，避开 D 盘不稳）

```
E:\junimo-mcp\
├── dune-project              # (lang dune 3.24) (name stardew_mcp)
├── build.sh                  # Cygwin 包装：source pi-env.sh + dune（见 5.3）
├── bin/
│   ├── dune                  # (executable (name main) (libraries stardew_mcp))
│   └── main.ml               # 入口：读 stdin 循环 → mcp.dispatch → 写 stdout
├── lib/
│   ├── dune                  # (library (name stardew_mcp) (libraries yojson unix))
│   ├── config.ml             # 环境变量
│   ├── http_client.ml        # curl 子进程封装（唯一碰 IO 的底层模块）
│   ├── game_api.ml           # 端点语义封装（move/face/tool/… 返回解析好的 JSON）
│   ├── game_state.ml         # /state 解析（类型化）+ 渲染（状态速报/可读文本）
│   ├── wait.ml               # poll_until / move_to / settle
│   ├── jsonrpc.ml            # JSON-RPC 2.0 编解码 + 错误码
│   ├── mcp.ml                # initialize / tools list / tools call 分发
│   └── intents.ml            # 17 工具注册表（schema + handler）
├── test/
│   ├── dune                  # (rule (alias runtest) → 跑单测 + mock 冒烟)
│   ├── mock_nagibridge.py    # 假 NagiBridge（Python 标准库）
│   ├── test_jsonrpc.ml       # 编解码单测
│   ├── test_state.ml         # 状态解析/渲染单测
│   └── test_till_math.ml     # 蛇形格子计算单测
└── README.md                 # 安装/注册/使用说明
```

### 5.2 模块依赖

```
main → mcp → intents → {game_api, game_state, wait}
game_api → {http_client, config}
game_state → {http_client, config}
wait → {game_state, game_api}
```

### 5.3 构建链（复用 skill《ocaml-windows-toolchain》已验证模式）

`build.sh` 核心（所有 dune 命令的唯一入口）：

```sh
#!/bin/sh
# 用法：bash build.sh build | bash build.sh runtest | bash build.sh exec
MSYS2_ARG_CONV_EXCL='*' "E:/ocaml/opam/.cygwin/root/bin/bash.exe" --noprofile --norc -c "
  . /cygdrive/e/ocaml/pi-env.sh >/dev/null 2>&1
  cd /cygdrive/e/junimo-mcp
  export OCAMLPATH='E:\ocaml\pi\lib'      # dune 是原生程序，要用 Windows 形式路径
  rm -f _build/.lock                       # 无条件清陈旧锁（skill 坑 3）
  dune $*
"
```

已知要点（skill 存档，构建时自动规避）：
- 一切在**受管 Cygwin bash**里跑（Git Bash 会改写 /cygdrive 参数，skill 坑 7）。
- `dune build -p X` 不能再写 `--root`（坑 2）；dune 报任何怪错先 `rm -f _build/.lock`（坑 3）。
- 若 dune 找不到 yojson → 确认 `OCAMLPATH` 生效（首次构建时验证，fallback 用 `dune-workspace` 显式挂载）。
- 产物：`_build/default/bin/main.exe`（约 5-10MB，原生编译，无需 runtime 依赖除 curl）。

### 5.4 HTTP 层规格（curl 子进程）

- 执行：`Unix.create_process` 起 `curl.exe`（手动三个管道）；**body 经 stdin 管道**（`--data-binary @-`），避免命令行引号转义问题。
- GET：`curl -sS --noproxy '*' --max-time 15 "<url>?<qs>"`；POST：`curl -sS --noproxy '*' --max-time 15 -X POST -H "Content-Type: application/json" --data-binary @- "<url>"`。
- ⚠️ **`--noproxy '*'` 为必需**（M2 实测坑）：Windows 环境常有系统代理（本机实测 `http_proxy=http://127.0.0.1:58874`），curl 默认把 localhost 请求也发给代理；代理连不上 upstream 时返回自己的错误文本（非 UTF-8），污染 JSON 解析与呈现。本机桥永远直连。
- ⚠️ **`in_w`（stdin 管道写端）必须 `Unix.set_close_on_exec`**（M2 实测死锁坑）：Windows 的 CreateProcess 会无差别继承"可继承句柄"，若 curl 拿到写端副本，`--data-binary @-` 读 stdin 永远等不到 EOF（自己攥着写端）→ POST 永久死锁（GET 不受影响）。详见附录 E。
- 错误消息里的响应原文按 **UTF-8 边界安全截断 + sanitize**（非法字节替换 `?`）——曾因 `String.sub 0 200` 按字节切断多字节字符导致客户端解码崩溃（附录 E）。
- 捕获 stdout（JSON）、stderr（错误）、退出码；非 0 → 统一错误类型 `Unreachable of string`。
- 返回 JSON 一律用 yojson 解析；解析失败保留原文前 200 字符报错。
- **接口隔离**：整个工程只有 `http_client.ml` 直接碰 IO；未来若要换成原生 socket 实现（去 curl 依赖），只改这一个模块。

---

## 6. 测试与验证

### 6.1 mock 服务器（`test/mock_nagibridge.py`）

- Python 3 标准库 `http.server`，零依赖，单文件 ~250 行。
- 内存状态机：`location/x/y/facing/moving(带完成时间戳)/time/day/season/money/inventory(含 Hoe、Watering Can、种子)`。
- 页面农场数据：`/surroundings` 返回一小块「农场」含几格 `HoeDirt`（部分 watered 部分不）+ 成熟作物，让 `water`/`harvest` 工具有真实素材。
- 行为仿真：`/move` 设 moving=true，0.8s 后坐标跳到目标；`/tool` 返回 ok 并变换日志；站位不符时按真实风险返回错误。
- 用途：M2 全绿 + 日常回归 + 无游戏时演示。

### 6.2 验证三阶段

| 阶段 | 环境 | 验收 |
|---|---|---|
| A. mock | 纯本地 | 17 工具全绿；`dune runtest` 通过；JSON-RPC 握手序列正确 |
| B. 真机冒烟 | 游戏运行 | 在 WorkBuddy 注册后：`get_state` 返回真实坐标；`go_to` 走一步成功 |
| C. 真机玩法 | 游戏运行 | 完整农活：`till 3×3` → `plant` → `water` → `harvest`，游戏画面可见、无卡死 |

---

## 7. 客户端接入

### 7.1 WorkBuddy（主用）

`~/.workbuddy/mcp.json` 添加：

```json
{
  "mcpServers": {
    "junimo": {
      "command": "E:\\junimo-mcp\\_build\\default\\bin\\main.exe",
      "args": [],
      "env": { "STARDEW_API_URL": "http://127.0.0.1:7842" }
    }
  }
}
```

（或经连接器管理页「添加自定义连接器 → 信任」流程。）

### 7.2 其他客户端

Claude Code：项目 `.mcp.json` 同结构；任何支持 stdio MCP 的客户端均可（协议子集实现即为此设计）。

---

## 8. 里程碑

| 阶段 | 内容 | 交付物 | 验收 |
|---|---|---|---|
| **M0** | 装 SMAPI + NagiBridge | 环境就绪 | ✅ **已完成（2026-10-13）**：SMAPI 4.5.2 + NagiBridge v1.1.0 装毕；`/status`→`worldReady:true`；`/state`、`/surroundings`、`/move`（实测移动 2 格）、`/position`、`/face` 全过；**单人档 7842 控制主角实测成立**（关键风险解除）。实测纪要见附录 D |
| **M1** | OCaml 骨架 | 可运行 exe | dune 工程编译通过；MCP 握手（initialize→list→call）用测试脚本跑通；`get_state`+`look` 两个工具接 mock 返回数据 |
| **M2** | mock 全绿 | 17 工具 + 测试套件 | ✅ **已完成（2026-10-13）**：mock 服务器（460 行，完整状态机）+ 17 工具全量 + 3 套单测全绿 + mock 冒烟 **52/52**；真实环境回归揪出并修复两个 bug（代理劫持 / UTF-8 截断，见附录 E）。WorkBuddy 注册留待 M3 |
| **M3** | 真机最小闭环 | 验收录像/截图 | ✅ **已完成（2026-10-13 深夜）**：真机四段闭环跑通——Clementine 档实测 till→plant→water，4 格防风草种下并浇水（另有田里 15 株原有作物顺带补水）；三套真机测试 16+3 项全绿、mock 升到 56/56；揪出并根治"假成功"三连、`/move` 直线穿墙回退、`check` 误抛三个真机专属坑（附录 F）。WorkBuddy 注册已写入 `~/.workbuddy/mcp.json`，待 Trust |
| **M4** | 打磨交付 | README + 终版 | ✅ **已完成（2026-10-13 深夜）**：README + `release/stardew-mcp.exe` + `docs/PRD.md`；`go_to` **分段接力**、`run_cells` 异常收尾、到达消息细分；真机完整农活（3×3 锄→种→浇→催熟→收割）**16/17**（唯一失败为测试断言过严——查明"不可站立目标格"后修正为 ≤1 容差，独立复核双路径全过）；8 分钟压测 **488 次调用 0 错误、curl 无泄漏**；mock **58/58**。详见附录 G |
| **M5（v2）** | 生计工具扩展 | 8 新工具 + 真机验收 | ✅ **已完成（2026-10-13 深夜）**：`sleep`（翻日落盘）/`buy`/`ship`/`chest_read`/`chest_store`/`map_info`/`pause_time`/`resume_time` 上线（工具总数 17→25）；mock **77/77**；真机 **17/17**（含 sleep 翻日 15→16 实测写盘）；用户成功接入 WorkBuddy 连接器并经原生工具完成 warp→water(15/15)。详见附录 H |
| **M5.1（v3）** | Remix 迁移 + 生活工具 | 10 新工具 + 真机验收 | ✅ **已完成（2026-10-13 深夜）**：Remix v0.9 换装（超集兼容 DLL 级验证）+ 10 新工具（总数 25→35，含天气渲染）；mock **114/114**；真机回归 **16/16 + 17/17 + 3/3**、`live_v3` **22/23 → 修复后全过**；详见附录 I |
| **M6** | 开源发布 | MIT + CI + Release | ✅ **已完成（2026-10-13 深夜）**：仓库 [mlkgrnt/Junimo-MCP](https://github.com/mlkgrnt/Junimo-MCP)（public / **MIT**）；二进制不再入库、改走 Releases（v3.0.0 附 `junimo-mcp.exe` + sha256）；GitHub Actions CI（ubuntu：构建 + 单测 + 114 项 mock 冒烟）；`build.sh` 去仓库路径硬编码（支持任意克隆位置）；serverInfo 版本 0.1.0 → 3.0.0 |

预估工作量：M0 半小时（含安装器交互）；M1 ~半天；M2 ~1-1.5 天；M3-M4 ~半天-1 天（视真机调参量）。

---

## 9. 风险与对策

| # | 风险 | 概率 | 对策 |
|---|---|---|---|
| 1 | 单人档下 7842 端口/主角控制不如预期 | 低 | M0 首条实测；不通则方案 B（联机 farmhand，mod 原生支持） |
| 2 | `/surroundings` 信息量对 Agent 不友好（格子数组太大） | 中 | 渲染层做归类裁剪（按作物/水/物件/NPC 归纳，不逐格罗列）；radius 默认收紧到 10 |
| 3 | `/move` 寻路卡墙角/失败 | 中 | `go_to` 超时后 `/stop` + 报告；农活编排用 `/position` 站位（不依赖寻路）；偶发失败退出不卡死 |
| 4 | 动作时序（延迟不够导致漏检） | 中 | 统一 0.55s settle + 关键步骤二次校验；实测后调参 |
| 5 | Windows OCaml 工具链坑 | 低 | skill《ocaml-windows-toolchain》已存档全部 9 类坑与解法 |
| 6 | 游戏/mod 更新导致 API 漂移 | 低 | 锁版本（1.6.15 + NagiBridge v1.1.0）；升级前回归 mock+真机冒烟 |
| 7 | 长时间挂机稳定性 | 低 | M4 压测 30 分钟操作流；curl 子进程无泄漏（每次回收）；状态全无持久化 |

---

## 10. 附录

### A. NagiBridge 其余端点（v2 候选，摘自 AGENTS.md）

`/buy /sell /store /chest /placechest /scan /map /alerts /queue /emote /chat /chat/push /sleep /wakeup /craft /machines /animals /festival* /minigame* /fishbot /pause /resume` + 作弊类 `/give /money /heal /ripen /refill`。

### B. AGENTS.md 踩坑摘录（编排内置）

1. 站位统一 y-1 朝下（GrabTile 偏移）。
2. `BeginUsingTool` 有延迟，等 0.45-0.55s 再检查。
3. 水壶补水用 `/refill`，别对水源用工具。
4. 操作前检查背包空间（满则静默掉落）。
5. 收割前查背包。
6. 放箱子用 `/placechest`（v2）。
7. 精确站位用传送类 API，不要硬磕寻路。
8. 砍树要砍树桩（v2）。
9. 背包满 `/give` `/craft` 静默掉落。
10. 大树桩需铜斧（v2）。
11. 菜单卡住：反复 `/key confirm` 直到 `activeMenu` 为 null。

### C. 参考资源

- NagiBridge 原作：github.com/anqinou-art/NagiBridge（README / AGENTS.md / PROJECT.md / scripts/*.py）
- NagiBridge-Remix（规格参考）：github.com/pendel001/NagiBridge-Remix（scripts/TOOL_INVENTORY.md —— 意图工具设计范本）
- 本机环境：OCaml 5.5.0 `E:\ocaml\pi`；构建参考 `E:\ocaml\pi-env.sh`、`E:\ocaml\build-deps-pi.sh`
- 工具链坑：skill《ocaml-windows-toolchain》

---

### D. M0 实测纪要（2026-10-13，全部实测）

**安装方式（已执行）**
- SMAPI 4.5.2 手动安装：`SMAPI-4.5.2-installer.zip` → 解压 `internal/windows/install.dat`（改名 .zip 再解压）→ 内容复制到游戏目录 → 复制 `Stardew Valley.deps.json` 为 `StardewModdingAPI.deps.json`。启动直接运行 `StardewModdingAPI.exe`（非 Steam 启动，成就不可用但功能完整）。
- NagiBridge：`NagiBridge.zip` → `Mods/NagiBridge/`（manifest + dll）。
- 安装包缓存：`E:\ocaml\tmp\m0\`。

**端点实测返回（与设计对齐用）**
| 端点 | 实测返回 |
|---|---|
| `/status`（世界就绪） | `{"ok":true,"server":"NagiBridge","version":"1.0.0","port":7842,"worldReady":true,"isMultiplayer":false}` |
| `/status`（未进档） | 同上，`worldReady:false` |
| `/state`（未进档） | `{"ok":true,"worldReady":false}`（仅两字段） |
| `/state`（就绪） | 含 `player{name,x,y,health,maxHealth,stamina,maxStamina,money,currentTool,facingDirection,isMoving,fishing}`、`location{name,mapWidth,mapHeight}`、`time{timeOfDay,dayOfMonth,season,year}`、`activeMenu`、`activeEvent`、`npcs[]`、`inventory[]{name,stack,category}` |
| 动作类未就绪 | `{"error":"World not ready"}`（JSON 体；HTTP 均为 200） |
| `/surroundings` | `{ok,center{x,y},radius,location,tiles[{x,y,passable,object?}],npcs[],monsters[],farmers[]}`；tiles **只含有内容的格**（墙=passable:false 也列出；空地板不出现） |
| `/move` | `{"ok":true,"message":"Moving to (6,9), steps=3"}`；异步，实测约 1s/格 |
| `/position` | `{"ok":true,"action":"positioned","location":"FarmHouse","x":8,"y":8}` |
| `/face` | `{"ok":true,"direction":2}`；0上/1右/2下/3左（实测确认） |
| `/menu`（TitleMenu） | `{ok,open:true,type:"TitleMenu",dialogue:null,responses:null,shopItems:null,buttons:[{name:"backButton",x,y}]}` |
| `/menu/click` | `{"ok":true,"clicked":"position","x":..,"y":..}` |

**进档自动化已验证（冷启动→世界）**：`/menu/click` 可点击标题界面任意坐标（receiveLeftClick 直通，无 worldReady 限制）。
- 2560x1600 窗口下（各坐标按分辨率成比例通用）：Load 按钮中心 = (width/2 − 480 + 246 + 111, height−198+87) = **(1157,1489)**；存档槽 i 中心 = (width/2, height/2 − 312 + 16 + i×156 + 80) = 槽0 **(1280,584)**。
- ⚠️ LoadGameMenu 打开时 `Game1.activeClickableMenu` 仍是 TitleMenu（subMenu 机制），`/menu.type` 不变——"是否已进 Load 界面"只能通过行为（点击槽位后 worldReady）判断。
- 注意：世界载入本身需数秒（实测第 3 次轮询 /status 变 true，约 9s）。

**杂项实测**
- 主角名 Clementine，起始农舍 FarmHouse (12×12)，实测从 (9,9) 调用 `/move (6,9)` 停在 (7,9)（差 1 步，待 M3 复查——疑似室内家具碰撞）。
- 物品名英文（Axe/Scythe/…），category 已本地化中文（"工具"/"垃圾"）。
- 冒烟环境：游戏 1.6.15 (build 24356)、SMAPI 4.5.2 直接启动（日志确认 mod 加载 + 端口 7842 起服）。

---

### E. M2 实测纪要（2026-10-13 晚，全部实测）

**交付物**
- `test/mock_nagibridge.py`：假 NagiBridge（Python 标准库，~460 行）。完整状态机：地图 20×13（可锄泥地/已锄地/未浇作物/已浇作物/成熟作物/石/树/箱）、玩家/背包（含带水量的水壶）、移动仿真（起步 100ms race 窗口 + 0.8s 到位的异步移动）、菜单状态、`/mock/set` 测试控制端点。
- OCaml 侧：`farm.ml`（蛇形格子计算/站位/排序）、`wait.ml` 的 `move_to` 等待器、`game_state.ml` 的 menu/interact 渲染与水量字段、**17 工具全量**（intents.ml 重写，含 run_cells 农活执行器：逐格卫检→站位校验→面朝→动作→settle，失败记格不中断，体力<15%/菜单触发即中止）。
- 测试：`test/test_{jsonrpc,state,till_math}.ml`（~60 断言，`dune runtest` 全绿）+ `test/mock_smoke.py`（**52/52**，完整剧情链：握手→17工具→go_to→till 2×2→plant→water 自动扫 12 格→harvest→背包→菜单流程→warp→错误路径）。

**真实环境回归揪出的两个 bug（都是 mock 测不出来的）**
1. **curl 代理劫持**：本机开发环境存在系统代理（`http_proxy=http://127.0.0.1:58874`，WorkBuddy 注入）。curl 默认把 localhost 请求也发给代理——游戏在监听时"恰好能通"（代理转发），**游戏一关就返回代理自己的错误文本**（`upstream connect failed: 由于目标计算机积极拒绝…`，非 UTF-8）。修复：所有 curl 加 `--noproxy '*'`。
2. **UTF-8 字节截断**：错误消息里 `String.sub s 0 200` 按字节截断，恰切在多字节字符中间 → 输出非法 UTF-8 → MCP 客户端解码崩溃（`invalid continuation byte`）。修复：`safe_prefix`（退到字符边界）+ `sanitize_utf8`（非法字节替换 `?`）；两者均有单测覆盖。

**Windows 死锁大坑（最值钱的一条）**
- 现象：`main.exe` 发 POST 时永久卡在"读 curl stdout"；curl 进程活着但**从未把请求发出去**（mock 端零日志）。
- 根因：Windows `CreateProcess(bInheritHandles=TRUE)` 会无差别继承"可继承句柄"——**管道写端 `in_w` 被 curl 继承**；curl 读 stdin（`--data-binary @-`）永远等不到 EOF（它自己就攥着写端副本）→ 死锁。GET 不读 stdin 所以一直正常。
- 修复：`Unix.set_close_on_exec in_w`（win32 上即 `SetHandleInformation(HANDLE_FLAG_INHERIT, 0)`）。

**其他实现定案**
- 菜单被触发时 v1 **不自动推进**（报告 + 中止）——已回填 3.4.2/4.3/4.5。
- mock 测试端口 8792（避开真游戏 7842）；冒烟用 `STARDEW_API_URL` 指过去，与真机完全同一代码路径。

---

### F. M3 实测纪要（2026-10-13 深夜，全部实测）

> 本节为 M3 真机实测的语义修正汇总。**3.3/3.4/4.5 正文已按本节回填（M4 完成）**；此处保留实测经过与细节。

**M3 战果（真机闭环全部跑通）**
- 真档（Clementine，春 14→15 日）实测完成：走位 → 锄地 → 播种 → 浇水。4 格防风草（起点 (53,12)，农舍西侧可耕地）从开垦到浇完水；顺带把田里 15 株原有作物全部补水。
- 消耗：金币 −200（远程买种）、体力 ~40、水壶 17+2 格。地块最终态独立核验：4 格 HoeDirt + crop 24 + watered=true。
- 三套测试：`test/live_e2e.py` **16/16**（首跑 9/16 暴露 check 误抛，修复后复跑 16/16，再复跑仍 16/16 全幂等跳过）；`test/live_swing.py` **3/3**；`test/mock_smoke.py` **56/56**（新增幂等重跑 ×2 + 直线回退拒绝断言）。

**游戏侧语义修正（源码 + 实测）**
1. **`/position` 是瞬移端点**（直接 Set `farmer.Position`），不是读坐标——读坐标一律用 `/state`。瞬移落点是格左上角（x·64,y·64），实测不影响挥动命中（命中格由 TilePoint+朝向决定）。瞬移自带 `ClearMovementState`，可清掉残留走动。
2. **`/move` 寻路失败会回退"直线穿墙"**：BFS 未找到路径时把目标直接塞进队列、移动 tick 无视碰撞直线逼近——实测把角色从室内 (9,9) 一路推出 12×12 地图边界。客户端判据：响应 `steps=1` 且实际距离 >1 ⇒ 回退，必须 `/stop` 并拒绝（已实现 `Wait.linear_fallback`，Mock 已加 `no_path` 开关覆盖）。
3. **`/use` 带游戏侧真实校验**（`ValidateToolUse`）：Hoe→`Tile is not diggable`/`Tile already tilled`/`Tile blocked by object: X`；WateringCan→`No tilled soil here — till first`/`Already watered`；返回体带 `tile`（实际校验/命中格）。**农活统一走 /use；`/tool` 是盲触发（BeginUsingTool，无校验），只留低层裸挥。**
4. **`/surroundings` 的 `watered` 字段仅在为真时出现**（`dirt.state.Value==1`）；缺席 = 未浇水。
5. **`/buy` 是远程商店**：`salePrice×2` 计价、直接扣钱进背包，不需开商店界面（防风草种子 40g/颗，Pierre 店里 20g）。
6. **`/pause` / `/resume` 冻结游戏时钟**（覆写 timeOfDay）——长挂机测试必备：现实 ~12 分钟游戏内 8:00→2:00 会**晕倒**（实测损失 10% 金币 = 133g 后回屋，天翻页）。
7. 移动 tick 会把角色吸附到目标格中心（diff<6px 出队）；`/move` 单段即精确到格。M0 纪要"(9,9)→(7,9) 差 1 步"未再复现，判定为当时环境的偶发。

**M3 根治的"假成功"三连（全部真机专属、mock 测不出）**
1. `/tool` 盲返 ok ⇒ till 曾报 4/4、实际一格没锄（当时角色甚至不在 Farm 上）。⇒ 农活全部改走 `/use`，并核对返回的 `tile` == 期望格。
2. `run_cells` 不统计动作结果 ⇒ 站上位就记 ok。⇒ op 三态计分：`Op_ok / Op_skip / Op_fail`（带原因逐格列出）。
3. 站位判定过宽（cheb≤1 即算到达）⇒ 可站偏一格挥错行。⇒ `snap_or_move`：瞬移 + **精确回读**（坐标必须完全相等）+ 越界防护（站位须在当前地图 bounds 内，防"室内越界瞬移"）+ 直线回退侦测。
4. 附带：`game_api.check` 把 `/use` 的 `{"ok":false,"error":...}`（正常校验失败）当致命错误抛 ⇒ till/plant 在第一格处整个中止。⇒ `/use` 改为原样返回由调用方判读；软跳过语义定案："Tile already tilled"→幂等成功；"Already watered"→跳过；播种"已有作物"（反查 /surroundings 确认）→跳过。

**M4 对遗留项的处置**
- ✅ 长距寻路：`go_to` 已实现**分段接力**（≤10 格/段、失败自动缩段、原地打转即如实报错）；真机实测 30 格跨场到达（目标格不可站立时停在邻格，属设计内行为——见 4.5）。
- ✅ 正文回填：3.3/3.4/4.5 已按本节修订（新增"≤1 格到达"语义、批量中止语义、`/use` 校验路径）。
- ✅ 长稳压测：见附录 G。
- 残留走位：设计上由下一次瞬移（`/position` 自带 `ClearMovementState`）自动清理，压测未见累积。

---

### G. M4 实测纪要（2026-10-13 深夜，打磨交付）

**交付物**
- `README.md`（架构/依赖/构建/注册步骤/17 工具/限制）、`docs/PRD.md`（本文档进仓）、`release/stardew-mcp.exe`（`bash build.sh release` 一条命令刷新，已处理 dune 产物只读位）。
- 代码增强：① `go_to` **分段接力**（`Wait.travel_to`：≤10 格/段、失败自动缩段、原地打转即如实报错，专治 mod BFS 500 步上限 → 直线穿墙回退）；② `run_cells` 遇游戏侧错误/异常**中止批次并回报**已完成格数（不再裸抛）；③ `go_to` 到达消息细分「已到达」/「已到达目标附近」。
- 测试新增：`test/live_m4.py`（真机完整农活验收，含自动进档）、`test/live_soak.py`（稳定性压测）；mock 侧新增 `no_path_long`（BFS 上限模拟）与分段/回退断言 → **58/58**。

**真机完整农活验收（live_m4.py）**
- 首跑 **16/17**：自动进档（第 2 次尝试成功）→ warp 回场 → 远程买种 10（400g）→ **till 3×3 = 9/9** → **plant = 9/9** → **water = 24/24**（含用户田 15 株，半径内 0 遗留旱作物）→ 精确站田中心 `/ripen?radius=1` **恰好催熟 9 株**（未波及用户作物）→ **harvest = 9 个入包**（背包 Parsnip x9；锄地还刨出 Clay x1）→ 长距 **30 格**分段导航到达。
- 唯一失败项与结论：断言"精确到达 (25,9)"实测停在邻格 (26,9)——查明**目标格紧邻温室、游戏侧不可站立**（mod 走位能进入，但会被游戏碰撞推回；`/surroundings` 的 `passable` 与游戏实际站立性不同源）。`go_to`「≤1 格即到达」确认为设计行为；断言修正为 ≤1 后，用两个独立用例复核双路径：不可站立目标 → 「已到达目标附近 (26,9)」✓；可站立目标（35 格长距）→ 「已到达 (53,11)（耗时 13.4s）」精确 ✓。

**稳定性压测（live_soak.py，8 分钟，时钟 /pause）**
- **122 轮 / 488 次工具调用 / 0 错误**；每轮平均 3.9s、最慢 5.7s；**curl 子进程 0 → 0（无泄漏）**。

**M4 剩余事项 / 限制**
- 截图/录像仍不可用（GDI 对 OpenGL 黑屏）——验收证据 = 游戏内 API 读数 + 测试输出（一贯做法）。
- 存档纪律复述：SDV 只在睡觉/翻日写盘；测试完直接关窗 = 当天内存进度回滚（M3 曾因此丢过第 15 天操作）。
- v2 候选：`/chest` 取物（v1 用 SendInput 绕行）、雨天/季节策略、自动吃饭回体力、`/give` 类调试端点暴露控制。

---

### H. v2（M5）实测纪要（2026-10-13 深夜）

**背景**：用户接入 WorkBuddy 连接器后要求实施 v2。范围定案：只做**纯 HTTP 端点**（零窗口焦点依赖、零外部进程依赖），排除三类 mod 缺口。

**新增 8 工具（生计组，总数 17→25）**

| 工具 | 端点 | 说明 |
|---|---|---|
| `sleep` | `/sleep` | 睡觉翻日（mod 自动回床→验证→翻日，单人为即时）；**落盘机制**——SDV 只在翻日写盘 |
| `buy` | `/buy` | 远程买（售价×2，直接进包；id 472=防风草种子已实测） |
| `ship` | `/sell` | 发货箱卖出（name 或 all=true；工具/种子/装备自动保留；需在 Farm） |
| `chest_read` | `/chest` | 读箱子（同地图任意距离，无需开箱；v1 开箱痛点的只读解） |
| `chest_store` | `/store` | 存物品进箱子（keepTools 默认 true） |
| `map_info` | `/map` | 建筑/传送点/NPC/动物（导航情报） |
| `pause_time` / `resume_time` | `/pause` `/resume` | 冻结/恢复游戏时钟（长任务防晕倒） |

**mod 缺口（已源码核实，记入 v3 候选）**
1. **开箱取物**：无取物端点；`/menu` 不支持 ItemGrabMenu；chest 的 checkAction 需真实右键标志（v1 靠 SendInput 绕行）。取物仍需手动。
2. **吃东西**：无 `/eat`；`/use` 对食物走 placementAction（不能吃）。体力恢复在自动化之外。
3. **天气**：无任何端点暴露；"雨天免浇水"策略需 fork mod。

**测试**
- mock：`/sleep` 翻日模拟、`/buy` 扣钱/钱不够、`/sell`、`/chest`、`/store`、`/map`、`/pause`、`/resume` 全实现 → **77/77**（+19 条断言）。
- 真机 `test/live_v2.py`：**17/17**——
  - `map_info` 实读：农舍/温室/发货箱/宠物碗 + 10 个传送点全列出；
  - `chest_read` 实读农舍工具箱（26/36 格：煤×13、防风草×15、纤维×87、木头×190、镐子×1、枫树种子×4…），空箱复读验证；
  - `chest_store` 存 Fiber×2 → 复读可见；
  - `pause_time`/`resume_time`；
  - **`sleep` 翻日 15→16 实测写盘**（起床体力 270/270，Fiber 确认已不在背包）。
- 连接器实测：用户接入后，本会话经连接器**原生工具**完成 warp→water（15/15 株作物）全流程 ✓。

**部署**
- v2 二进制：`release/v2/stardew-mcp.exe`（运行中的连接器服务锁定了旧文件 `release/stardew-mcp.exe`，无法原地覆盖）。
- `~/.workbuddy/mcp.json` 已指向 v2 路径，**下次 WorkBuddy 启动即生效**（届时工具列表 17→25）。

---

### I. v3（Remix 迁移 + 生活工具）（2026-10-13 深夜）

**背景与调研（GitHub 源码级核实）**

v2 遗留 mod 三缺口（取物/吃/天气）+ 节日/社交未接入。调研结论：上游 NagiBridge v1.1.0（MIT）无这些端点，但**原作授权二改版 [NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix)**（pendel001，PolyForm NC）有 **180+ 端点**，且是上游**严格超集**：

- v0.9 发布包 dll（1.45MB）经 UTF-16LE 字符串扫描：v1/v2 全部 25 工具的端点 **100% 命中**、v3 新端点全在（dll sha256 `4e7291ae…`）。
- 关键端点（源码核实）：`/chest_take`（`{x,y,name|slot,count}`）、`/chest_take_list`（`{items:[…]}` 跨箱智能取 + **≤4 格"够得着"闸** + `tooFar` 回执）、`/scan_chests`、`/chest_open`、`/eat`（吃**手持**，先 `/select`；带 doneEating 结算校验，打断不扣物）、`/gift`（`{target,item}`；带 GiftsToday 记账校验，没真送到自动退礼）、`/friendship`（GET `?npc=`）、`/find_npc`（GET `?name=`，中英模糊）、`/festival` `/festival/interact` `/festival/answer`。
- **天气无需新端点**：在 `/state.time.weather`（0晴/1雨/2雷/3落叶/5雪/7绿雨 + isRaining 等 4 个布尔）；**无明天预报**。
- Remix 官方定位为"房主 + AI farmhand 双开"；本项目为**单机档**——兼容性由本阶段真机回归验证。

**换装（10-13 深夜）**

- 旧 `Mods/NagiBridge/`（v1.1.0，ID `Nagi.NagiBridge`）→ 移至 `D:\SteamLibrary\...\Stardew Valley\_mod_backups\NagiBridge-v1.1.0-orig\`（含 config.json 备份）。
- 新版解压（ID `pendel001.NagiBridge`，v0.9）→ `Mods/NagiBridge/`，dll sha256 校验一致。**不可同装**（两者 UniqueID 不同，同装会抢 7842 端口）。
- 许可：PolyForm Noncommercial 1.0.0（个人/非商业使用免费，需署名）；本项目仅通过 HTTP 交互、不打包其代码。

**v3 工具（10 个，总数 25→35）**

- 箱子：`chest_scan`（全图箱子：位置+内容+格号）/ `chest_take`（name 或 slot；count 缺省=全部）/ `chest_take_list`（清单批量取，每项 "物品名" 或 "物品名 xN"/"×N"）。
- 吃：`eat`（给 name 自动 select 再吃；报 HP/体力/buff 前后值；失败不扣物、可站定重试）。
- 社交：`find_npc` / `friendship`（**中文名自动经 find_npc 解析内部英文名重查**）/ `gift`（返喜好档位 + 好感前后 + delta）。
- 节日：`festival`（**"今天/明天/下个节日"由 OCaml 侧内置日历计算**——mod 的 `/festival` 只反映"正在进行中的活动"；同时探测现场状态）/ `festival_interact` / `festival_answer`。
- `get_state` 渲染增量：`【天气】` 行 + strip 速报携带天气词（`weather_cn`：晴/雨/雷雨/大风/雪/绿雨）。

**mock 扩展**

- 10 个新端点全实现（吃：扣库存+回体力+前后数值；送礼：记账/重复拒绝/物品校验；箱子：≤4 格"够得着"判定 + tooFar；节日：无活动 `ok:false` 属正常态 + 开关模拟；`/state` 带 weather）。
- 冒烟 **114/114**（77 → 114，+37 条 v3 断言，全正/负路径）。

**真机验收（v3）（2026-10-13 深夜，单机档实测）**

- **换装验证**：SMAPI 日志确认 `【SDV1.6 × AI】NagiBridge二改版 0.9.0`（`pendel001.NagiBridge`）加载成功、无报错；旧版已不在加载列表。自动进档一次成功。
- **回归（Remix 对旧工具链）全绿**：`live_e2e` **16/16**（锄/种/浇/长距/交叉核验）；`live_v2` **17/17**（map / 箱子读写 / 时钟控制 / `sleep` 翻日 16→17 实测落盘）；`live_swing` **3/3**。
- **`live_v3` 22/23**，唯一 FAIL 为 festival 工具**判定过宽**：`/festival` 只要"有事件播放中"就返回 `ok:true`（连送礼对话也算！）——原来只看 `ok` 误判"节日进行中"。改为 `isFestival || festivalName` 判定后**单项复测 PASS**。（同场发现并解决：Remix 的 `/menu_close` HTTP 层要求 Content-Length，`curl -d ''` 即可。）
- **实测确认**：`/state.time.weather` 真实工作（速报显示"晴天"）；`/chest_take` 取 Coal x1 再存回（可逆、账实一致）；`/chest_take_list` 跨箱取（含 ≤4 格闸）；`/eat` 喝下 Joja Cola——体力 226→239、buffs 0→1（**真实结算，非假成功**）；`/find_npc` 连 NPC 当前台词都读到；`/gift` 实送黄水仙——好感 12→32（+20）、`giftsToday` +1 记账复查一致、对方弹出收礼对话。
- **Remix 与上游的行为差异（已记录口径）**：
  1. `/position` 新增"防穿地图"护栏（目标格超出当前地图 → `ok:false, position_rejected`；同图内正常——护栏对正常使用无害且更安全）；
  2. `/warp` 落点为"安全落点"（请求坐标可能被重定向：请求 (56,10) 实际落 (64,15)）——`warp` 工具不带坐标时不受影响；
  3. `/menu_close` 需 Content-Length（HTTP 层细节）。
- **单机档兼容性结论：成立**——Remix 虽以"房主 + AI farmhand 双开"为设计中心，上述全部实测在单机档无碍。

---

*本 PRD 中所有 mod 侧行为（端点、返回结构、时序、纪律）均经 ModEntry.cs 源码与原作者脚本核实；OCaml 侧为设计稿，M1-M2 期间按实际情况微调并回填本文件。M0 实测后已修正：API 地址 localhost、进档流程（附录 D）；M2 实测后已修正：--noproxy、close_on_exec 死锁、UTF-8 截断、菜单策略（附录 E）；M3 实测后已修正：/position 瞬移语义、/move 直线回退防护、/use 校验路径与幂等语义、精确站位纪律（附录 F）；M4 实测后已补充：分段接力导航、≤1 格到达语义、批量异常收尾、完整农活与压测数据（附录 G）；M5(v2) 实测后已补充：生计八工具、sleep 落盘、mod 三缺口（附录 H）；v3 迁移 Remix 后已补充：取物/吃/社交/节日十工具、天气渲染、换装与许可说明（附录 I）。*




