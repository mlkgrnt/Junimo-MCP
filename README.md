# Junimo-MCP

[![CI](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml/badge.svg)](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml)

**简体中文** · [繁體中文](README.zh-Hant.md) · [English](README.en-US.md) · [Español](README.es-ES.md)

用 **OCaml 手写**的 MCP 服务器：给 AI Agent 一副在《星露谷物语》里干活的手——**37 个意图工具（含剧情阅读与菜单关闭）**，从种地收割到取物聚餐、社交过节，全流程可靠执行。

- **协议层**：JSON-RPC 2.0 over stdio，手写实现（`initialize` / `tools/list` / `tools/call`），零 MCP 框架依赖
- **控制层**：原生 HTTP + keep-alive（OCaml socket）→ [NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix)（默认 `http://localhost:7842`）→ 游戏内角色
- **不假成功**：工具报成功 = 游戏里真的发生了（挥动/浇水后会**回读地块直到效果真的落地**才记账）；失败大多无副作用（送礼失败自动退礼、吃失败不扣物），可放心重试
- **会挑快的路**：`go_to` 一次请求走全程（出发前就否掉越界/大门/站不住的坐标）；`till`/`water` 在**工具已升级**时自动改用蓄力批量（一片地几挥搞定）
- **依赖极简**：唯一第三方 OCaml 库是 yojson；**运行零外部依赖**（HTTP 走原生 socket，不需要系统 curl；`STARDEW_HTTP=curl` 可回退到旧路径）

## 只想用、不想开发？让 Agent 一键部署

```bash
git clone https://github.com/mlkgrnt/Junimo-MCP.git
```

把仓库交给你的 AI 客户端（WorkBuddy / Claude Code / Cursor / 任意能读文件、能跑命令的 Agent），对它说：

> **"读 AGENTS.md，把 Junimo-MCP 部署到能用。"**

Agent 会照 `AGENTS.md` 的《部署安装》章节自动完成全部步骤：
**装 SMAPI → 装执行器 mod → 部署服务器 → 注册 MCP 连接器 → 调通验收。**

你只需要两件事：① 一台 Windows + 已安装《星露谷物语》本体；② 在注册那一步按提示点一次 **Trust** 并重启客户端。

> **成品二进制在 Releases**：从[最新发布](https://github.com/mlkgrnt/Junimo-MCP/releases/latest)下载 `junimo-mcp.exe`（附 SHA-256 校验文件）——不需要装任何开发环境。
> 喜欢自己动手，见下方《手动安装》。

## 它长什么样

```
┌────────────┐   stdio (JSON-RPC)   ┌──────────────────┐   HTTP localhost:7842   ┌──────────────────┐
│ MCP 客户端  │ ◄──────────────────► │ junimo-mcp.exe  │ ◄─────────────────────► │ NagiBridge-Remix │ ──► 星露谷
│  (你的 AI)  │     37 个意图工具     │    (OCaml 5.5)   │     原生 HTTP(socket)   │    (SMAPI mod)   │
└────────────┘                       └──────────────────┘                         └──────────────────┘
```

工程亮点：

- **可靠性三纪律**：游戏侧校验、逐格三态计分（成功 / 幂等跳过 / 失败带原因）、精确回读——"绝不假成功"；
- **四层测试防线**：单元测试 + **114 项 mock 冒烟**（不用开游戏）+ 真机测试套件 + 压测；
- **全中文人话回执**：工具返回的错误文案可直接展示给用户，Agent 无需二次翻译。

## 前置依赖

| 项 | 版本 / 说明 |
|---|---|
| 游戏 | Stardew Valley **1.6.15**（Steam 版实测） |
| SMAPI | **4.5.2**（或 4.x 兼容版本） |
| NagiBridge-Remix | **v0.9**（解压到 `Mods/NagiBridge/`） |
| OCaml（仅开发 / 构建需要） | **5.5.0** + dune 3.24 + yojson 3.0（Windows：opam + 受管 Cygwin，见下） |

> ⚠️ **Remix 与原版 NagiBridge 不可同时安装**：两者 UniqueID 不同（`pendel001.NagiBridge` vs `Nagi.NagiBridge`），同装会抢 7842 端口。从原版换装时，把旧的 `Mods/NagiBridge/` 文件夹移出 Mods 目录再解压新版。
>
> 许可说明：Remix 为原作授权二改（PolyForm Noncommercial 1.0.0，个人 / 非商业使用免费）；本项目与之通过 HTTP 交互，不打包其代码。

启动游戏：运行游戏目录里的 `StardewModdingAPI.exe`（**不要走 Steam 启动**，否则加载不到 mod；代价是 Steam 成就不可用）。进入存档后 NagiBridge 自动在 7842 端口起服。

## 手动安装（4 步）

> 与 `AGENTS.md` 的《部署安装》章节一致，这里是人类版速览；每一步的校验方法与常见问题见那边的详细版。

| 步骤 | 做什么 | 要点 |
|---|---|---|
| 1 · SMAPI | 装 mod 加载器 | 若游戏目录已有 `StardewModdingAPI.exe` 则跳过 |
| 2 · 执行器 mod | 装 NagiBridge-Remix | 解压到 `<游戏目录>\Mods\`；**如有原版 NagiBridge 必须先移走** |
| 3 · 服务器 | 从 [Releases](https://github.com/mlkgrnt/Junimo-MCP/releases/latest) 下载并放好 `junimo-mcp.exe` | 免编译；建议放非 C 盘、路径不含空格 |
| 4 · 注册 | 写 `~/.workbuddy/mcp.json` → Trust → 重启 | 格式见下 |

`~/.workbuddy/mcp.json`：

```json
{
  "mcpServers": {
    "junimo": {
      "command": "D:/junimo-mcp/junimo-mcp.exe",
      "env": { "STARDEW_API_URL": "http://localhost:7842" }
    }
  }
}
```

写入后**不会自动生效**：到 WorkBuddy「连接器管理 → 右上角自定义连接器」给 `junimo` 点 **Trust**，并重启 WorkBuddy。

**接入其它客户端？四家主流客户端都有现成配置**（复制粘贴级，详见 `AGENTS.md` 的《步骤 5 · 注册到 MCP 客户端》）：

| 客户端 | 配置位置 | 快速接入 |
|---|---|---|
| WorkBuddy | `~/.workbuddy/mcp.json` | 图形界面点 Trust |
| Claude Code | `~/.claude.json` / 项目 `.mcp.json` | `claude mcp add --transport stdio junimo -- "<EXE>"` |
| Codex | `~/.codex/config.toml` | `codex mcp add junimo -- "<EXE>"` |
| DeepSeek Harness | dsh profile（`dsh plugin add`） | 使用 [dsh-junimo](https://github.com/mlkgrnt/dsh-junimo) 插件，一条命令，exe 已内置 |

> **DeepSeek Harness 用户**：无需手工编写 cordis patch。[dsh-junimo](https://github.com/mlkgrnt/dsh-junimo) 已将本项目的 37 个工具封装为 dsh 组合包，内含 `junimo-mcp.exe`、部署自检（`junimo_doctor`）与游戏生命周期工具（聚焦 / 启动 / 读档），以及随包 skill 与操作纪律提示词。
>
> ```bash
> dsh plugin --profile web add github:mlkgrnt/dsh-junimo
> ```
>
> 安装后重启 dsh，先执行 `junimo_doctor` 完成链路检查。

## 冒烟验证

```bash
# 桥通了吗（必须带 --noproxy '*'：绕开系统代理）
curl -sS --noproxy '*' http://localhost:7842/status
# {"ok":true,"server":"NagiBridge",...,"worldReady":true,...}
```

> ⚠️ 地址必须用 `http://localhost:7842`，**不能用 `127.0.0.1`**——mod 的 HttpListener 只注册了 localhost 前缀，127.0.0.1 会被系统以 400 拒绝（实机实测）。

## 工具清单（37）

| 组 | 工具 | 说明 |
|---|---|---|
| 感知 | `get_state` | 全量状态（玩家 / 位置 / 时间 / **天气** / 背包 / 菜单）+ 状态速报 |
| | `look` | 环视半径内：作物（含阶段 / 浇水 / 可收）、物件、树石、NPC |
| | `get_inventory` | 背包清单（水壶附余水量） |
| 移动 | `go_to` | 寻路移动（**长距自动分段接力**；拒绝直线穿墙回退；距离 ≤1 即视为到达——部分目标格游戏侧不可站立，会停在邻格并如实回报坐标） |
| | `warp` | 跨地图传送（异步，自动回读确认落地位置） |
| | `face` | 转向 0上 / 1右 / 2下 / 3左 |
| 交互 | `swing_tool` | 挥动工具单次（走 `/use`：带游戏侧校验，报告实际作用格） |
| | `use_held` | 使用手持物（播种 / 放置） |
| | `interact` | 与面前格交互（=确认键），返回面前格信息 |
| | `press_key` | 模拟按键（confirm / cancel / 数字 / 方向…） |
| 界面 | `menu_read` | 读当前菜单 / 对话 / 商店 / 按钮 |
| | `story` | **读/推进剧情**：read 读当前一屏、next 下一屏、choose 选回答（会自动补一发「真实点击」让选择落地）、skip 跳过整段 |
| | `menu_close` | 关掉当前菜单/文本框（睡完的 SaveGameMenu、夜里的 ShippingMenu 靠它） |
| | `menu_click` | 点菜单（选项 index / 按钮名 / 坐标） |
| 物品 | `select_item` | 选中背包物品拿在手上 |
| 农活 | `till` | 批量锄地（蛇形走位；幂等："已锄"记软跳过；体力 <15% 中止） |
| | `plant` | 批量播种（目标格必须已锄；"已有作物"记软跳过） |
| | `water` | 自动扫描"种了作物且未浇水"的格子逐格浇水（自动补水） |
| | `harvest` | 批量收割成熟作物（游戏内瞬间完成，直接进包） |
| 箱子 | `chest_scan` | 扫描当前地图所有箱子（位置 + 内容 + 格号） |
| | `chest_take` | 单箱取物（`name` 或 `slot`；`count` 缺省 = 全部；放不下留在箱里并如实回报） |
| | `chest_take_list` | 跨箱批量取物（只从"够得着"≤4 格的箱子凑清单；远箱列入 tooFar 附坐标） |
| 吃 | `eat` | 吃东西回体力 / HP / 拿 buff（给名字自动选中；报前后数值；失败不扣物） |
| 社交 | `find_npc` | 全地图找 NPC（中英文模糊匹配；位置 / 朝向 / 是否睡觉 / 正在说的话） |
| | `friendship` | 查好感（点数 / 心数 / 本周与今日已送次数；中文名自动解析） |
| | `gift` | 给 NPC 送礼（真实流程；返喜好档位与好感变化；送满 / 被拒自动退礼） |
| 节日 | `festival` | 节日情报（今天 / 明天 / 下一个节日 + 正在进行中的活动现场状态） |
| | `festival_interact` | 节日现场与 NPC 互动（自动走位 + 触发；仅活动进行中） |
| | `festival_answer` | 节日问答 / 分支提交（`answer` 序号） |
| 生计 | `sleep` | 睡觉翻日（**唯一落盘方式**——SDV 只在睡觉 / 翻日时存档）；返回新一天状态 |
| | `buy` | 远程购买（售价×2，直接进包；id 472 = 防风草种子） |
| | `ship` | 发货箱卖出（给 `name` 或 `all=true`；工具 / 种子 / 装备自动保留；需在农场） |
| | `chest_read` | 读取箱子内容（同地图任意距离，无需开箱） |
| | `chest_store` | 把背包物品存进箱子（工具默认保留） |
| | `map_info` | 建筑 / 传送点 / NPC / 动物情报（导航规划用） |
| | `pause_time` | 冻结游戏时钟（长任务防晕倒；记得恢复） |
| | `resume_time` | 恢复被冻结的游戏时钟 |

农活组统一纪律：站 `(tx, ty-1)` 朝下 → **瞬移 + 精确回读校验** → `/use`（核对返回命中格 == 期望格）→ settle 0.55s；每格失败带原因列出，绝不盲挥。

## 从源码构建（开发者）

标准 opam 环境（Linux / macOS / 常规 Windows）直接使用 dune：

```bash
opam install yojson      # 唯一的第三方依赖
dune build               # → _build/default/bin/main.exe
dune runtest             # 单元测试
```

Windows 受管 Cygwin 工具链（本项目的开发环境）则走 `build.sh` 统一入口——它负责：受管 Cygwin bash + `pi-env.sh` + `OCAMLPATH` + 无条件清 `_build/.lock`（陈旧锁会引发莫名报错）：

```bash
bash build.sh build          # dune build → _build/default/bin/main.exe
bash build.sh runtest        # 单元测试
bash build.sh release        # 构建并复制到 release/junimo-mcp.exe
bash build.sh exec -- ...    # 透传任意 dune 子命令
```

工具链踩坑记录（装配方式、Cygwin 参数重写、lock 坑等）见配套 skill「ocaml-windows-toolchain」。

## 测试

| 套件 | 命令 | 说明 |
|---|---|---|
| 单元测试 | `bash build.sh runtest` | JSON-RPC 编解码、状态解析 / 渲染、蛇形地块数学 |
| mock 冒烟 | `python test/mock_smoke.py`（自动起 mock） | 假 NagiBridge（完整状态机：地图 / 移动 / 菜单 / 校验 / 生计 / 取物 / 社交 / 节日），**114 项**全流程断言，**不需要游戏** |
| 真机闭环 | `python test/live_e2e.py` | 需游戏在跑：锄地 → 播种 → 浇水 + 独立 HTTP 交叉核验 |
| 真机完整农活 | `python test/live_m4.py` | 需游戏在跑：自动进档 → 买种 → 3×3 锄 / 种 / 浇 → 催熟收割 → 长距分段导航 |
| 真机 v2 生计 | `python test/live_v2.py` | 需游戏在跑：map / 箱子读写 / 时钟控制 / **睡觉翻日（会推进一天并写盘）** |
| 真机 v3 生活 | `python test/live_v3.py` | 需游戏在跑：天气 / 箱子扫描取物 / 吃 / 找人与送礼 / 节日（改动最小可逆） |
| 真机抽检 | `python test/live_swing.py` | 单次挥动工具的正 / 负用例 |
| 稳定性压测 | `python test/live_soak.py [分钟]` | 连续读写 + 走位，统计错误率与 curl 子进程回收 |

mock 与真机使用同一代码路径（只换 `STARDEW_API_URL`），mock 的 `/use` 校验语义与真 mod 逐字对齐。

CI（GitHub Actions，ubuntu）在每次 push / PR 上自动跑：构建 + 单元测试 + mock 冒烟。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `STARDEW_API_URL` | `http://localhost:7842` | NagiBridge 地址（必须 localhost） |
| `STARDEW_HTTP` | `native` | HTTP 实现：`native`（原生 socket + keep-alive）/ `curl`（回退，排查用） |
| `STARDEW_HTTP_TIMEOUT` | `30` | 单次 HTTP 调用超时（秒；批量端点可调大） |
| `STARDEW_SETTLE` | 自适应 | 通用动作结算等待：不设=自适应（400ms 起，失败 +150 / 连续成功 −50）；`NNN` 固定毫秒；`fixed` = 旧行为 550ms。农活（till/plant/water）现在按**效果核验**自定步，不受此项影响 |
| `STARDEW_AUTO_MENU` | `1` | 动作前自动按掉"无选项对话"（NPC 招呼 / 提示框）；`=0` 关闭（一律交回 Agent 处理） |
| `STARDEW_AUTO_EVENT` | 未设 | `=1` 时剧本事件（过场）自动 `skip`；**默认不跳**（跳剧情是口味问题） |
| `STARDEW_WALK` | `walk` | `go_to` 走位实现：`walk`（默认，一次请求走全程，出发前校验越界/门格/站不住）/ `move`（旧的分段接力，排查对照用） |
| `STARDEW_AREA` | `auto` | `till`/`water` 是否走 mod 的批量蓄力端点：`auto`（**工具升级后**自动启用）/ `force`（达格数阈值就启用）/ `off`（一律逐格） |
| `STARDEW_AREA_MIN` | `4` | 批量最少作用格数（低于此值逐格更可控） |
| `STARDEW_AREA_TIMEOUT` | `90` | 批量端点单次等待上限（秒） |
| `STARDEW_TIMEOUT` | `30` | 轮询总超时（秒） |
| `STARDEW_CURL` | 自动探测 | curl.exe 路径覆盖（仅 `STARDEW_HTTP=curl` 时用） |
| `STARDEW_NO_STRIP` | 未设 | `=1` 关闭返回文本末尾的状态速报 |
| `STARDEW_LOG` | `warn` | stderr 日志级别（debug / info / warn） |

## 已知限制

- **截图 / 录像不可用**：本机 GDI 抓不到 OpenGL 画面——验证一律走游戏内 API 读数（比截图更精确）。
- **长距移动**：mod 的 BFS 有 500 步上限，`go_to` 已内置分段接力（≤10 格/段）绕过；跨地图请用 `warp`。
- **给宠物起名（NamingMenu）是 mod 盲区**：`/menu` 不暴露它的文本框与按钮。工具输出里会直接给出办法——`menu_click {"x":800,"y":352}` 接受默认名字（16:9 布局实测有效），`press_key cancel` 则退回上一步。
- **长时段挂机**：先 `pause_time` 冻结游戏时钟（现实 ~12 分钟游戏内就从早到 2:00 晕倒，实测会扣 10% 金币），结束 `resume_time`。
- **远程购买**：mod 的 `/buy` 端点按售价 ×2 计价（无商店界面的便利费 / 调试端点）。
- **无"明天天气预报"**：只有当天天气（`get_state` 的【天气】行）；"今天 / 明天是不是节日"由工具内置日历计算。
- **节日到场需自行导航**：`festival` 系列负责情报与现场交互；去节日场地走游戏原生入口，别用 `warp` 直接传非节日地图（不会触发节日场景）。
- 收割 / 取物前请用 `get_inventory` 确认背包空间（背包满会掉地上）。
- **游戏进度靠 `sleep` 落盘**：不睡觉直接关游戏，当天操作会回滚——让 Agent 每天收尾时 `sleep`。

## 文档导航

| 文档 | 给谁看 | 内容 |
|---|---|---|
| `AGENTS.md` | **AI Agent** | 部署安装 + 十条铁律 + 37 工具速查 + 开发纪律 |
| `README.md` | 人类 | 本文件（简体中文 zh-Hans） |
| `README.zh-Hant.md` / `README.en-US.md` / `README.es-ES.md` | 人类 | 繁中 / 英文 / 西语版本 |
| [dsh-junimo](https://github.com/mlkgrnt/dsh-junimo) | DeepSeek Harness 用户 | dsh 插件版：内置 exe、一条命令安装、含部署自检与游戏生命周期工具 |
| `test/` | 开发者 | 四层测试套件 |

## 许可与致谢

本项目自身代码以 **MIT** 许可开源，见 [LICENSE](./LICENSE)。

- 执行器 mod：[NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix)（PolyForm Noncommercial 1.0.0，作者 pendel001）——个人 / 非商业使用免费；本项目与其通过 HTTP 交互，不打包其代码
- 上游原作：[NagiBridge](https://github.com/anqinou-art/NagiBridge)（MIT）
- 控制层理念与端点语义：NagiBridge 原作者（`farm_row.py` / `water_crops.py` 的站姿 / 时序纪律）
- 状态速报（state strip）设计参考 NagiBridge-Remix
