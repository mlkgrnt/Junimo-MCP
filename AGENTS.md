# AGENTS.md — 给 AI Agent 的使用指南

> 人类读者请看 [README.md](./README.md)；本文件写给**第一次接触本项目的 Agent**。
> 读完这一份，你应该能独立、安全地操控这个项目里的星露谷工具链，或对本仓库做开发。

## 这是什么

本项目是一个**手写 MCP 服务器**（OCaml，单 exe），通过 NagiBridge-Remix mod 的 HTTP 接口（`localhost:7842`）操控《星露谷物语》里一个角色。提供 **36 个意图工具**，覆盖：感知 / 移动 / 交互 / 界面 / 农活 / 箱子取物 / 吃 / 社交 / 节日 / 生计。

数据流：**你（MCP 客户端）→ stdio JSON-RPC → junimo-mcp.exe → HTTP → mod → 游戏**。你只管调工具；翻译与可靠性（时序等待、游戏侧校验、失败回滚）由服务器内部处理。

## 部署安装（从零到能用）

> 触发场景：用户说"帮我装上 / 一键部署 / 让 AI 玩星露谷"，或下方自检发现服务未就绪。
> 前置条件：**Windows** + 已安装《星露谷物语》本体（Steam 版）。没有本体时先请用户安装（Agent 无法代购）。

### 步骤 1 · 定位游戏目录

- 常见位置：`D:\SteamLibrary\steamapps\common\Stardew Valley`（Steam 库可能在任意盘）
- 验证：该目录下存在 `Stardew Valley.exe`。记下路径为 `<GAME>`。

### 步骤 2 · 安装 SMAPI（若未装）

先检查：`<GAME>\StardewModdingAPI.exe` 存在 = 已装，跳过本步。

从零安装（免交互流程，不需要运行安装器的 GUI）：

1. 从 `https://github.com/Pathoschild/SMAPI/releases` 下载最新 4.x 的 `SMAPI-*-installer.zip`
2. 解压后进入 `internal/windows/`，把 `install.dat` 复制一份、改名为 `install.zip` 再解压
3. 把解压出的全部内容复制进 `<GAME>`
4. 把 `<GAME>\Stardew Valley.deps.json` 复制一份、改名为 `StardewModdingAPI.deps.json`

### 步骤 3 · 安装 NagiBridge-Remix（执行器 mod）

1. 检查 `<GAME>\Mods\` 下是否已有**原版** NagiBridge（manifest UniqueID = `Nagi.NagiBridge`）——**若有，先移出 Mods 目录**（两者 UniqueID 不同、会抢 7842 端口，不能共存）
2. 从 `https://github.com/pendel001/NagiBridge-Remix/releases` 下载最新 zip（如 `NagiBridge.0.9.0.zip`）
3. 解压，将其中的 `NagiBridge\` 文件夹整个放入 `<GAME>\Mods\`
4. 许可提醒（向用户说明一次即可）：此为 PolyForm Noncommercial 授权，个人/非商业使用免费；本仓库不打包其代码、仅作指引

### 步骤 4 · 部署 MCP 服务器

获取**免编译二进制** `junimo-mcp.exe`（不需要 OCaml 工具链），二选一：

1. **从 Releases 下载**（推荐）：`https://github.com/mlkgrnt/Junimo-MCP/releases/latest/download/junimo-mcp.exe`
   （同一发布页有 `junimo-mcp.exe.sha256` 校验文件，谨慎起见先比对再使用）
2. **本地已构建**：若手中是开发副本且存在 `release/v3/junimo-mcp.exe`（或 `release/junimo-mcp.exe`），直接使用

把 exe 放到固定位置（建议非 C 盘、路径不含空格），记下其绝对路径 `<EXE>`。

> 仅当用户要改代码时才需要构建，见文末《开发 Agent》章节。

### 步骤 5 · 注册到 MCP 客户端

四家主流客户端的接入方式（`<EXE>` 替换为步骤 4 里的 exe 绝对路径；均需重启客户端生效）。

#### WorkBuddy

配置 `~/.workbuddy/mcp.json`（无则新建；已有其它服务器则把 `junimo` 条目合并进去）：

```json
{
  "mcpServers": {
    "junimo": {
      "command": "<EXE>",
      "env": { "STARDEW_API_URL": "http://localhost:7842" }
    }
  }
}
```

然后在「连接器管理 → 右上角自定义连接器」给 `junimo` 点 **Trust**，重启 WorkBuddy。

#### Claude Code

一条命令：

```bash
claude mcp add --transport stdio junimo -- "<EXE>"
```

- 检查：`claude mcp list`（应显示 Connected）；管理：`claude mcp get junimo` / `claude mcp remove junimo`
- 如需覆盖地址：`claude mcp add --env STARDEW_API_URL=http://localhost:7842 --transport stdio junimo -- "<EXE>"`（`--env` 要放在 `--` 之前）
- 团队共享：把 `{"mcpServers":{"junimo":{"command":"<EXE>","env":{...}}}}` 写进项目根的 `.mcp.json`（首次使用会请求批准）

#### Codex（OpenAI）

编辑 `~/.codex/config.toml` 追加：

```toml
[mcp_servers.junimo]
command = "<EXE>"
env = { STARDEW_API_URL = "http://localhost:7842" }
```

- 或一条命令：`codex mcp add junimo -- "<EXE>"`；验证：`codex mcp list`
- 项目级配置可放仓库内 `.codex/config.toml`（受信任项目才加载）

#### DeepSeek Harness（dsh）

通过 cordis patch 插入 `mcp-client` 插件条目——把下面整条**合并**进 `$DSH_HOME/profiles/<name>/cordis.patch.yml`（单 profile 常驻；`$DSH_HOME/cordis.patch.yml` 则全 profile 生效），或存成文件用 `dsh web --patch <file>` 一次性加载：

```yaml
- insert:
    - id: junimo-mcp
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: junimo
        transport: stdio
        command: "<EXE>"
        args: []
        env:
          STARDEW_API_URL: http://localhost:7842
        cwd: !!js process.cwd()
```

- 工具会以 `mcp__junimo__<工具名>` 形式出现；首次发现是异步的，稍等片刻再发第一条指令
- 注意：dsh 的 stdio 桥接会主动移除环境里"看起来像凭据"的变量与全部 `DSH_*` 变量——本项目不需要额外凭据，无需处理

> 其它任何支持 stdio MCP 的客户端（Claude Desktop / Cursor 等）：在其 MCP 配置文件里按 `command` + `env` 加一个 `junimo` 条目即可。

### 步骤 6 · 验收

1. 请用户启动游戏：运行 `<GAME>\StardewModdingAPI.exe`（**不要走 Steam 启动**——会加载不到 mod；代价是 Steam 成就不可用，属正常现象）
2. 调用 `get_state`：
   - 正常返回 = 全链路通了 ✓
   - "连接失败" = 检查：游戏在跑吗 / `Mods\NagiBridge\` 是否就位（应有 `NagiBridge.dll` + `manifest.json`）/ 7842 是否被占（`netstat -ano | findstr 7842`）
   - "还没有进入存档" = 正常，请用户进档后再操作
3. 确认工具列表为 36 个

### 部署常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 游戏开着但连不上 | mod 没到位，或旧版 mod 残留（UniqueID 冲突，检查 `Mods` 下是否同时有新旧两个 NagiBridge） |
| 动作"没反应"/报不可达 | ① 有菜单/对话/事件开着（模态界面下动作端点会挂到超时、角色也不能移动）→ 看报错里给的原文与选项处理（`menu_click {"option":N}` / `press_key confirm` / 剧本事件 `press_key skip`）；② **游戏窗口失焦**（SDV 失焦会暂停，动作不生效）→ 把游戏窗口切到前台 |
| GitHub 下载 exe 缓慢 / 不通 | 换时段或让用户手动下载 Releases；也可从源码构建（见文末《开发 Agent》） |
| 手写调试请求被拒 | 只能 `http://localhost:7842`（不能 127.0.0.1）；命令行调用要带 `--noproxy '*'`（绕系统代理） |
| SMAPI 控制台红字 "Steam achievements won't work" | 正常（非 Steam 启动的代价，不影响功能） |
| 启动报缺 .NET | 装 .NET 6 运行时（Desktop Runtime）；多数机器游戏本体已自带，不会遇到 |

## 开工前 30 秒自检

> 任何一项不过 → 转到上方的《部署安装》章节。

1. **游戏在跑吗**：直接调 `get_state`。报"连接失败 / 游戏未启动"→ 游戏没开（提醒用户运行 `StardewModdingAPI.exe`，别走 Steam）。
2. **进档了吗**：`get_state` 回答"游戏还没有进入存档"→ 在标题菜单，先让用户进档；未进档时所有动作工具都会拒绝。
3. **工具齐吗**：你的工具列表应有 36 个（`get_state` … `festival_answer`）。少于 36 说明连接的是旧版本服务器（请确保指向最新版 `junimo-mcp.exe`）。

## 十条铁律（先背，不然会翻车）

1. **收尾必睡**。游戏只在睡觉时存档（`sleep` 工具）。干完一天的活不睡、直接关窗口 = **当天所有操作回滚**。任何"今天到此为止"的会话，最后必须 `sleep`（或如实告诉用户未落盘）。
2. **信任工具反馈，不要脑补**。本项目全程"不假成功"：**报成功 = 游戏里真的发生了**；**报错误 = 真的没发生**。而且失败大多无副作用（送礼失败自动退礼、吃东西失败不扣食物、取物放不下会留在箱里）——可以放心重试或换方法。
3. **工具是同步的，且内含等待**。每次调用会阻塞到动作在游戏里完成（含内部时序与校验），按返回决定下一步。**你不需要、也不应该自己加延时或连发动作**。
4. **长时间挂机先冻结时钟**：`pause_time`。游戏时间会流逝——现实约 12 分钟就到凌晨 2:00，角色晕倒并**扣钱**。干完记得 `resume_time`。
5. **移动失败别硬刚**：`go_to` 报"寻路失败"就是真到不了（服务器拒绝"直穿墙"作弊回退）；报"已到达目标附近"= 目标格站不住、停在相邻格，**视为到达**（游戏里很多格子不可站立，这是设计行为）。
6. **菜单/剧情基本不用你操心**：动作前会**自动按掉"无选项对话"**（NPC 招呼 / 送礼答谢 / 提示框——按 confirm 是唯一能做的事）。但**剧情（剧本事件）永不自动按掉**——那是内容，读了就没了。想要**看完剧情**就用 `story`：`read` 读当前一屏（说话人 + 台词 + 选项）、`next` 下一屏、`choose option=N` 选回答；不想看才 `press_key skip`（**不可回放**）。只有**带选项的问题框 / 商店 / 箱子 / 背包**会挡下来，报错里**直接给原文和带序号的选项**，`menu_click {"option":N}` 一步就能处理（不必先 `menu_read`）。
7. **背包容量**：`harvest` 或大量取物前，先 `get_inventory` 确认空位（背包满时收获物会掉地上）。
8. **体力管理**：批量农活在体力 <15% 时会主动中止；低了就 `eat`（回体力/HP）或回家 `sleep`。
9. **"没有需要浇水的作物"不是错误**：雨天、洒水器覆盖、或刚浇过时，`water` 会这样回答——如实接受即可。
10. **节日查询用 `festival`**（今天/明天/下一个）；参加节日要走游戏原生入口（别 `warp` 到节日场地，不触发场景）。

## 工具速查（36 个，按"我想…"找）

| 我想… | 工具 | 关键说明 |
|---|---|---|
| 看状态（位置/时间/天气/钱/背包） | `get_state` | 返回末尾的 `── [..]` 行是**状态速报**——多数工具的返回都带它，日常查询可省一次调用 |
| 看周围有什么（作物/物件/NPC） | `look` | 带半径参数 |
| 只看背包 | `get_inventory` | 水壶会附余水量 |
| 看地图情报（建筑/传送点） | `map_info` | 导航规划用 |
| 走到某处 | `go_to` | 长距自动分段；≤1 格容差 |
| 换地图 | `warp` | 落点由游戏决定（安全落点），回执里有实际位置 |
| 转向 | `face` | 0上/1右/2下/3左 |
| 锄地 / 播种 / 浇水 / 收割（批量） | `till` / `plant` / `water` / `harvest` | 支持区域与自动扫描——**别一格一格调** |
| 找东西在哪个箱子 | `chest_scan` | 全图箱子 + 内容 + 格号 |
| 从箱子取物 | `chest_take` | 按 `name` 或 `slot`；`count` 缺省=全部 |
| 跨箱凑齐一份清单 | `chest_take_list` | items 写 `"物品名 xN"`；只从玩家 4 格内的箱子取，够不着的会列出来（附坐标，走过去再叫一次） |
| 存东西进箱子 | `chest_store` | 按名字存；工具默认不存 |
| 快速读某个箱子 | `chest_read` | 不用开箱 |
| 吃（回体力/HP/拿 buff） | `eat` | 给 `name` 会自动选中；不给=吃当前手持 |
| 找 NPC | `find_npc` | 中英文名，全地图（连对方在说什么都读得到） |
| 查好感 | `friendship` | 点数/心数/本周与今日送礼数；中文名自动解析 |
| 送礼 | `gift` | 真实送礼流程；每天 1 次/每周 2 次，送满会明确报错并退礼 |
| 节日情报 | `festival` | 今天/明天/下一个节日 + 进行中活动状态 |
| 节日现场互动 / 问答 | `festival_interact` / `festival_answer` | 仅活动进行中可用 |
| 买东西 | `buy` | 远程购买（无商店界面，按售价×2 计价） |
| 卖东西（发货箱） | `ship` | 给 `name` 或 `all=true`；需在农场 |
| 睡觉（★落盘） | `sleep` | **唯一存档方式**；返回新一天状态 |
| 冻结 / 恢复时间 | `pause_time` / `resume_time` | 长任务与挂机必用 |
| 菜单操作 | `menu_read` / `menu_click` / `press_key` | 先读后点；press_key 可发 confirm/cancel/数字键 |
| **看剧情 / 推进剧情** | `story` | `read` 读当前一屏（说话人+台词+选项）、`next` 下一屏、`choose option=N` 选回答、`skip` 跳过整段。剧情**不会**被自动按掉；`get_state` 也会报出当前剧情 |
| 选中物品 / 使用手持 / 挥工具 / 与面前格交互 | `select_item` / `use_held` / `swing_tool` / `interact` | 播种放置用 `use_held`；对话 NPC 用 `interact` |

## 一个标准工作日（照抄即可）

1. `get_state` — 看日期、天气、体力、位置（速报行就够）
2. `look` — 看作物：哪些要浇水、哪些能收
3. `water` → `harvest` — 浇需要浇的、收成熟的
4. 要扩种：`buy`（买种子）→ `till` → `plant` → `water`
5. 体力不足：`eat`；（真的累了才）`sleep`
6. 其他任务：社交用 `find_npc`/`friendship`/`gift`；取物资用 `chest_scan`/`chest_take(_list)`
7. 收尾：跑过 `pause_time` 就 `resume_time`；然后 **`sleep` 落盘**，进入下一天

## 常见错误 → 正确姿势

| ❌ 错误做法 | ✅ 正确做法 |
|---|---|
| 干完活直接结束回合 | 先 `sleep` 落盘，或明确告诉用户"尚未存档" |
| `go_to` 失败后对同一目标反复重试 | 改 `warp`（跨图）/ 换目标格 / 如实报告（服务器已判定不可达） |
| 动作弹出菜单后继续发动作 | 先看报错里给的内容：带选项的 `menu_click {"option":N}`；无选项的对话已自动按掉，不用管 |
| 假设"应该成功了" | 读返回文本；报错就按文案处理（**错误文案是中文人话，可直接转给用户看**） |
| 手动逐格移动干活 | 用批量工具的区域/自动扫描参数 |
| 连发多个动作"抢进度" | 一等一：等当前工具返回再发下一个 |

## 如果你是开发 Agent（要改本仓库）

- **构建**：`bash build.sh build`（→ `_build/default/bin/main.exe`）；`bash build.sh runtest`（单测）；`bash build.sh release`（拷进 `release/`）。受管 Cygwin 环境走 `build.sh`（Windows 细节见 README）；标准 opam 环境直接用 `dune build` / `dune runtest`。
- **测试四层**：单测（`dune runtest`）→ mock 冒烟（`python test/mock_smoke.py`，**不需要游戏**，114 项）→ 真机脚本（`test/live_*.py`，需要游戏在跑）→ 压测（`live_soak.py`）。
- **改行为 → 必须同步测试**：新增/修改端点要同步改 `test/mock_nagibridge.py` + `test/mock_smoke.py` 断言；涉及真机语义的补 `test/live_*.py`。
- **代码地图**：`lib/mcp.ml`（协议核心）/ `lib/intents.ml`（36 个工具实现与渲染，最大文件；含**效果核验式动作** `op_use_effect`）/ `lib/game_api.ml`（端点封装）/ `lib/game_state.ml`（状态解析与中文渲染）/ `lib/wait.ml`（等待器 + 自适应结算 + `/walk_to` 到达轮询）/ `lib/http_client.ml`（HTTP 层：原生 socket + keep-alive，唯一 IO；`STARDEW_HTTP=curl` 回退）。依赖极简：仅 `yojson`。
- **两条"快路径"（`till`/`water`/`go_to` 内部自动选，无需 Agent 关心）**：`go_to` 走 mod 的 `/walk_to`（一次请求走全程 + 出发前校验越界/门格/站不住；`STARDEW_WALK=move` 可回退旧的分段接力）；`till`/`water` 在**工具升级等级 ≥1** 且格数 ≥4 时走 mod 的 `/tool_area`（矩形蓄力批量；`STARDEW_AREA=off|force` 可强制切换，`STARDEW_AREA_TIMEOUT` 调等待上限）。
- **纪律**：不发假成功（报成功必须在游戏里真发生；失败必须有可读中文原因）。⚠️ **挥动的生效帧在 `/use` 返回后约 550ms 才落**（真机实测）：所以农活动作一律用 `op_use_effect` **回读地块直到终态出现**再继续下一格——睡固定时长会打断上一格的挥动，造成"3 格一行必丢中间格"式假成功。工具描述要写明"什么时候用 + 注意事项"。
- **部署**：本地开发用新二进制放 `release/vN/junimo-mcp.exe`（`release/` 已 gitignore、不入库），更新 `~/.workbuddy/mcp.json` 指向它；**重启 WorkBuddy 后连接器才加载新版**。对外分发走 GitHub Releases（README 有下载链接）。
- **发版格式（务必保持一致，别每个版本各写一套）**：
  - tag = 标题 = `Junimo-MCP vX.Y.Z`（标题只放"名字+版本"，**描述性文案一律写进 release body**，不要塞进标题）；
  - 资产文件名恒为 `junimo-mcp.exe` + `junimo-mcp.exe.sha256`（**不带版本号**，这样 `releases/latest/download/` 的固定链接永远有效）；
  - 校验和内容格式 = `<hash>␣␣junimo-mcp.exe`（两个空格，不带 GNU 的 `*`）；
  - 版本号同步点：`lib/mcp.ml` 的 `server_version`。
  - 发布命令：
    ```bash
    bash build.sh release && cp release/junimo-mcp.exe release/v3/junimo-mcp.exe
    (cd release/v3 && sha256sum junimo-mcp.exe | cut -d' ' -f1 | xargs -I{} printf '{}  junimo-mcp.exe\n') > release/v3/junimo-mcp.exe.sha256
    gh release create vX.Y.Z release/v3/junimo-mcp.exe release/v3/junimo-mcp.exe.sha256 \
      --title "Junimo-MCP vX.Y.Z" --notes-file <UTF8文件> --target main
    ```
  - 发完做**三重一致性**校验：本地 hash == `gh release view --json assets` 的 digest == 公开下载实测 hash。
  - 中文 release notes 一律走文件（`--notes-file`），不要上命令行（编码会乱）。

## 参考

- `README.md` — 安装、工具全表、已知限制
- `test/` — 四层测试套件
