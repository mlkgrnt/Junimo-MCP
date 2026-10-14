# Junimo-MCP

[![CI](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml/badge.svg)](https://github.com/mlkgrnt/Junimo-MCP/actions/workflows/ci.yml)

[简体中文](README.md) · **繁體中文** · [English](README.en-US.md) · [Español](README.es-ES.md)

以 **OCaml 手寫**的 MCP 伺服器：給 AI Agent 一雙在《星露谷物語》裡幹活的手——**35 個意圖工具**，從種田採收到取物聚餐、社交過節，全流程可靠執行。

- **協定層**：JSON-RPC 2.0 over stdio，手寫實作（`initialize` / `tools/list` / `tools/call`），零 MCP 框架相依
- **控制層**：原生 HTTP + keep-alive（OCaml socket）→ [NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix)（預設 `http://localhost:7842`）→ 遊戲內角色
- **不假成功**：工具回報成功 = 遊戲裡真的發生了（揮動／澆水後會**回讀地塊直到效果真的落地**才記帳）；失敗大多無副作用（送禮失敗自動退禮、吃東西失敗不扣物），可放心重試
- **會挑快的路**：`go_to` 一次請求走完全程（出發前就先否掉越界／大門／站不住的座標）；`till`／`water` 在**工具已升級**時自動改用蓄力批量（一片地幾揮搞定）
- **相依極簡**：唯一的第三方 OCaml 函式庫是 yojson；**執行零外部相依**（HTTP 走原生 socket，不需要系統 curl；`STARDEW_HTTP=curl` 可回退）

## 只想使用、不想開發？讓 Agent 一鍵部署

```bash
git clone https://github.com/mlkgrnt/Junimo-MCP.git
```

把本倉庫交給你的 AI 客戶端（WorkBuddy / Claude Code / Cursor / 任何能讀檔案、能跑指令的 Agent），對它說：

> **「讀 AGENTS.md，把 Junimo-MCP 部署到能用。」**

Agent 會照 `AGENTS.md` 的《部署安裝》章節自動完成所有步驟：
**裝 SMAPI → 裝執行器 mod → 部署伺服器 → 註冊 MCP 連接器 → 調通驗收。**

你只需要兩件事：① 一台 Windows + 已安裝《星露谷物語》本體；② 在註冊那一步依提示按一次 **Trust** 並重新啟動客戶端。

> **成品二進位檔在 Releases**：從[最新發布](https://github.com/mlkgrnt/Junimo-MCP/releases/latest)下載 `junimo-mcp.exe`（附 SHA-256 校驗檔）——不需要安裝任何開發環境。
> 想自己動手，見下方《手動安裝》。

## 它長什麼樣

```
┌────────────┐   stdio (JSON-RPC)   ┌──────────────────┐   HTTP localhost:7842   ┌──────────────────┐
│ MCP 客戶端  │ ◄──────────────────► │ junimo-mcp.exe  │ ◄─────────────────────► │ NagiBridge-Remix │ ──► 星露谷物語
│  (你的 AI)  │     35 個意圖工具     │    (OCaml 5.5)   │       curl 子行程       │    (SMAPI mod)   │
└────────────┘                       └──────────────────┘                         └──────────────────┘
```

專案亮點：

- **可靠性三紀律**：遊戲端校驗、逐格三態計分（成功 / 冪等跳過 / 失敗附原因）、精確回讀——「絕不假成功」；
- **四層測試防線**：單元測試 + **114 項 mock 冒煙**（不用開遊戲）+ 實機測試套件 + 壓力測試；
- **全中文人話回執**：工具回傳的錯誤訊息可直接展示給使用者，Agent 無需二次翻譯。

## 前置需求

| 項目 | 版本 / 說明 |
|---|---|
| 遊戲 | Stardew Valley **1.6.15**（Steam 版實測） |
| SMAPI | **4.5.2**（或 4.x 相容版本） |
| NagiBridge-Remix | **v0.9**（解壓縮到 `Mods/NagiBridge/`） |
| OCaml（僅開發 / 建置需要） | **5.5.0** + dune 3.24 + yojson 3.0（Windows：opam + 受管 Cygwin，見下） |

> ⚠️ **Remix 與原版 NagiBridge 不可同時安裝**：兩者 UniqueID 不同（`pendel001.NagiBridge` vs `Nagi.NagiBridge`），同時安裝會搶佔 7842 連接埠。從原版換裝時，先把舊的 `Mods/NagiBridge/` 資料夾移出 Mods 目錄，再解壓縮新版。
>
> 授權說明：Remix 為原作授權二改（PolyForm Noncommercial 1.0.0，個人 / 非商業使用免費）；本專案與其透過 HTTP 互動，不打包其程式碼。

啟動遊戲：執行遊戲目錄裡的 `StardewModdingAPI.exe`（**不要從 Steam 啟動**，否則載入不到 mod；代價是 Steam 成就無法使用）。進入存檔後 NagiBridge 會自動在 7842 連接埠啟動服務。

## 手動安裝（4 個步驟）

> 與 `AGENTS.md` 的《部署安裝》章節一致，這裡是給人類的速覽；每個步驟的驗證方法與常見問題見該處詳細版。

| 步驟 | 做什麼 | 要點 |
|---|---|---|
| 1 · SMAPI | 安裝 mod 載入器 | 若遊戲目錄已有 `StardewModdingAPI.exe` 則跳過 |
| 2 · 執行器 mod | 安裝 NagiBridge-Remix | 解壓縮到 `<遊戲目錄>\Mods\`；**如有原版 NagiBridge 必須先移走** |
| 3 · 伺服器 | 從 [Releases](https://github.com/mlkgrnt/Junimo-MCP/releases/latest) 下載並放好 `junimo-mcp.exe` | 免編譯；建議放非 C 槽、路徑不含空格 |
| 4 · 註冊 | 寫入 `~/.workbuddy/mcp.json` → Trust → 重新啟動 | 格式見下 |

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

寫入後**不會自動生效**：到 WorkBuddy「連接器管理 → 右上角自訂連接器」給 `junimo` 按 **Trust**，並重新啟動 WorkBuddy。

**要接入其它客戶端？四家主流客戶端都有現成設定**（複製貼上即可，詳見 `AGENTS.md` 的《步驟 5 · 註冊到 MCP 客戶端》）：

| 客戶端 | 設定檔位置 | 快速接入 |
|---|---|---|
| WorkBuddy | `~/.workbuddy/mcp.json` | 圖形介面按 Trust |
| Claude Code | `~/.claude.json` / 專案 `.mcp.json` | `claude mcp add --transport stdio junimo -- "<EXE>"` |
| Codex | `~/.codex/config.toml` | `codex mcp add junimo -- "<EXE>"` |
| DeepSeek Harness | `$DSH_HOME/profiles/<name>/cordis.patch.yml` | cordis patch 條目（見 AGENTS.md） |

## 冒煙驗證

```bash
# 橋接通了嗎（必須加上 --noproxy '*'：繞過系統代理）
curl -sS --noproxy '*' http://localhost:7842/status
# {"ok":true,"server":"NagiBridge",...,"worldReady":true,...}
```

> ⚠️ 位址必須用 `http://localhost:7842`，**不能用 `127.0.0.1`**——mod 的 HttpListener 只註冊了 localhost 前綴，127.0.0.1 會被系統以 400 拒絕（實機實測）。

## 工具清單（35）

| 群組 | 工具 | 說明 |
|---|---|---|
| 感知 | `get_state` | 全量狀態（玩家 / 位置 / 時間 / **天氣** / 背包 / 選單）+ 狀態速報 |
| | `look` | 環視半徑內：作物（含階段 / 澆水 / 可採收）、物件、樹木石頭、NPC |
| | `get_inventory` | 背包清單（澆水壺附剩餘水量） |
| 移動 | `go_to` | 尋路移動（**長距離自動分段接力**；拒絕直線穿牆回退；距離 ≤1 即視為到達——部分目標格遊戲端不可站立，會停在鄰格並如實回報座標） |
| | `warp` | 跨地圖傳送（非同步，自動回讀確認落地位置） |
| | `face` | 轉向 0上 / 1右 / 2下 / 3左 |
| 互動 | `swing_tool` | 揮動工具單次（走 `/use`：帶遊戲端校驗，回報實際作用格） |
| | `use_held` | 使用手持物（播種 / 放置） |
| | `interact` | 與面前格互動（=確認鍵），回傳面前格資訊 |
| | `press_key` | 模擬按鍵（confirm / cancel / 數字 / 方向…） |
| 介面 | `menu_read` | 讀取目前選單 / 對話 / 商店 / 按鈕 |
| | `menu_click` | 點選單（選項 index / 按鈕名稱 / 座標） |
| 物品 | `select_item` | 選取背包物品拿在手上 |
| 農活 | `till` | 批次鋤地（蛇行移動；冪等：「已鋤」記為軟性略過；體力 <15% 中止） |
| | `plant` | 批次播種（目標格必須已鋤；「已有作物」記為軟性略過） |
| | `water` | 自動掃描「種了作物且未澆水」的格子逐格澆水（自動補水） |
| | `harvest` | 批次採收成熟作物（遊戲內瞬間完成，直接進背包） |
| 箱子 | `chest_scan` | 掃描目前地圖所有箱子（位置 + 內容 + 格位） |
| | `chest_take` | 單箱取物（`name` 或 `slot`；`count` 預設 = 全部；放不下會留在箱裡並如實回報） |
| | `chest_take_list` | 跨箱批次取物（只從「搆得到」≤4 格的箱子湊清單；遠箱列入 tooFar 附座標） |
| 吃 | `eat` | 吃東西回體力 / HP / 拿 buff（給名稱會自動選取；回報前後數值；失敗不扣物） |
| 社交 | `find_npc` | 全地圖找 NPC（中英文模糊比對；位置 / 朝向 / 是否睡覺 / 正在說的話） |
| | `friendship` | 查好感度（點數 / 心心數 / 本週與今日已送次數；中文名自動解析） |
| | `gift` | 給 NPC 送禮（真實流程；回傳喜好等級與好感變化；送滿 / 被拒自動退禮） |
| 節日 | `festival` | 節日資訊（今天 / 明天 / 下一個節日 + 進行中的活動現場狀態） |
| | `festival_interact` | 節日現場與 NPC 互動（自動走位 + 觸發；僅活動進行中） |
| | `festival_answer` | 節日問答 / 分支提交（`answer` 序號） |
| 生計 | `sleep` | 睡覺跨日（**唯一寫入存檔的方式**——SDV 只在睡覺 / 跨日時存檔）；回傳新的一天狀態 |
| | `buy` | 遠端購買（售價×2，直接進背包；id 472 = 防風草種子） |
| | `ship` | 出貨箱賣出（給 `name` 或 `all=true`；工具 / 種子 / 裝備自動保留；需在農場） |
| | `chest_read` | 讀取箱子內容（同地圖任意距離，無需開箱） |
| | `chest_store` | 把背包物品存進箱子（工具預設保留） |
| | `map_info` | 建築 / 傳送點 / NPC / 動物資訊（導航規劃用） |
| | `pause_time` | 凍結遊戲時鐘（長任務防昏倒；記得恢復） |
| | `resume_time` | 恢復被凍結的遊戲時鐘 |

農活組統一紀律：站 `(tx, ty-1)` 朝下 → **瞬移 + 精確回讀驗證** → `/use`（核對回傳命中格 == 期望格）→ settle 0.55s；每格失敗附原因列出，絕不盲目揮動。

## 從原始碼建置（開發者）

標準 opam 環境（Linux / macOS / 一般 Windows）直接使用 dune：

```bash
opam install yojson      # 唯一的第三方相依
dune build               # → _build/default/bin/main.exe
dune runtest             # 單元測試
```

Windows 受管 Cygwin 工具鏈（本專案的開發環境）則走 `build.sh` 統一入口——它負責：受管 Cygwin bash + `pi-env.sh` + `OCAMLPATH` + 無條件清除 `_build/.lock`（過期的鎖會引發莫名錯誤）：

```bash
bash build.sh build          # dune build → _build/default/bin/main.exe
bash build.sh runtest        # 單元測試
bash build.sh release        # 建置並複製到 release/junimo-mcp.exe
bash build.sh exec -- ...    # 透傳任意 dune 子指令
```

工具鏈踩坑紀錄（組裝方式、Cygwin 參數重寫、lock 坑等）見配套 skill「ocaml-windows-toolchain」。

## 測試

| 套件 | 指令 | 說明 |
|---|---|---|
| 單元測試 | `bash build.sh runtest` | JSON-RPC 編解碼、狀態解析 / 渲染、蛇行格位數學 |
| mock 冒煙 | `python test/mock_smoke.py`（自動啟動 mock） | 假 NagiBridge（完整狀態機：地圖 / 移動 / 選單 / 校驗 / 生計 / 取物 / 社交 / 節日），**114 項**全流程斷言，**不需要遊戲** |
| 實機閉環 | `python test/live_e2e.py` | 需遊戲執行中：鋤地 → 播種 → 澆水 + 獨立 HTTP 交叉核驗 |
| 實機完整農活 | `python test/live_m4.py` | 需遊戲執行中：自動進檔 → 買種 → 3×3 鋤 / 種 / 澆 → 催熟採收 → 長距離分段導航 |
| 實機 v2 生計 | `python test/live_v2.py` | 需遊戲執行中：map / 箱子讀寫 / 時鐘控制 / **睡覺跨日（會推進一天並寫入存檔）** |
| 實機 v3 生活 | `python test/live_v3.py` | 需遊戲執行中：天氣 / 箱子掃描取物 / 吃 / 找人和送禮 / 節日（變動最小且可逆） |
| 實機抽檢 | `python test/live_swing.py` | 單次揮動工具的正 / 負用例 |
| 穩定性壓力測試 | `python test/live_soak.py [分鐘]` | 連續讀寫 + 走位，統計錯誤率與 curl 子行程回收 |

mock 與實機使用同一條程式路徑（只換 `STARDEW_API_URL`），mock 的 `/use` 校驗語意與真 mod 逐字對齊。

CI（GitHub Actions，ubuntu）在每次 push / PR 自動執行：建置 + 單元測試 + mock 冒煙。

## 環境變數

| 變數 | 預設 | 說明 |
|---|---|---|
| `STARDEW_API_URL` | `http://localhost:7842` | NagiBridge 位址（必須 localhost） |
| `STARDEW_HTTP` | `native` | HTTP 實作：`native`（原生 socket + keep-alive）/ `curl`（回退） |
| `STARDEW_HTTP_TIMEOUT` | `30` | 單次 HTTP 呼叫逾時（秒；批次端點可調大） |
| `STARDEW_SETTLE` | 自適應 | 通用動作結算等待：不設=自適應（400ms 起，失敗 +150 / 連續成功 −50）；`NNN` 固定毫秒；`fixed` = 舊行為 550ms。農活（till/plant/water）現在按**效果核驗**自訂步，不受此項影響 |
| `STARDEW_WALK` | `walk` | `go_to` 走位實作：`walk`（預設，一次請求走完全程，出發前校驗越界／門格／站不住）/ `move`（舊的分段接力，排查對照用） |
| `STARDEW_AREA` | `auto` | `till`／`water` 是否走 mod 的批量蓄力端點：`auto`（**工具升級後**自動啟用）/ `force`（達格數門檻就啟用）/ `off`（一律逐格） |
| `STARDEW_AREA_MIN` | `4` | 批量最少作用格數（低於此值逐格更可控） |
| `STARDEW_AREA_TIMEOUT` | `90` | 批量端點單次等待上限（秒） |
| `STARDEW_TIMEOUT` | `30` | 輪詢總逾時（秒） |
| `STARDEW_CURL` | 自動偵測 | curl.exe 路徑覆寫（僅 `STARDEW_HTTP=curl` 時用） |
| `STARDEW_NO_STRIP` | 未設 | `=1` 關閉回傳文字末尾的狀態速報 |
| `STARDEW_LOG` | `warn` | stderr 日誌等級（debug / info / warn） |

## 已知限制

- **截圖 / 錄影不可用**：本機 GDI 抓不到 OpenGL 畫面——驗證一律走遊戲內 API 讀數（比截圖更精確）。
- **長距離移動**：mod 的 BFS 有 500 步上限，`go_to` 已內建分段接力（≤10 格/段）繞過；跨地圖請用 `warp`。
- **選單不自動推進**：任何動作觸發選單（對話 / 商店）即中止並回報，由 Agent 明確 `menu_read` / `menu_click` 處理。
- **長時間掛機**：先 `pause_time` 凍結遊戲時鐘（現實約 12 分鐘，遊戲內就從早到 2:00 昏倒，實測會扣 10% 金幣），結束後 `resume_time`。
- **遠端購買**：mod 的 `/buy` 端點按售價 ×2 計價（無商店介面的便利費 / 除錯端點）。
- **無「明天天氣預報」**：只有當天天氣（`get_state` 的【天气】行）；「今天 / 明天是不是節日」由工具內建日曆計算。
- **節日到場需自行導航**：`festival` 系列負責資訊與現場互動；前往節日場地走遊戲原生入口，別用 `warp` 直接傳送到非節日地圖（不會觸發節日場景）。
- 採收 / 取物前請用 `get_inventory` 確認背包空間（背包滿會掉在地上）。
- **遊戲進度靠 `sleep` 寫入存檔**：不睡覺直接關遊戲，當天的操作不會被保留——讓 Agent 每天收尾時 `sleep`。

## 文件導覽

| 文件 | 給誰看 | 內容 |
|---|---|---|
| `AGENTS.md`（簡體中文） | **AI Agent** | 部署安裝 + 十條鐵律 + 35 工具速查 + 開發紀律 |
| `README.md` / `README.zh-Hant.md` / `README.en-US.md` / `README.es-ES.md` | 人類 | 簡中（zh-Hans，預設）/ 繁中（本檔）/ 英文 / 西語 |
| `test/` | 開發者 | 四層測試套件 |

## 授權與致謝

本專案自身程式碼以 **MIT** 授權開源，見 [LICENSE](./LICENSE)。

- 執行器 mod：[NagiBridge-Remix](https://github.com/pendel001/NagiBridge-Remix)（PolyForm Noncommercial 1.0.0，作者 pendel001）——個人 / 非商業使用免費；本專案與其透過 HTTP 互動，不打包其程式碼
- 上游原作：[NagiBridge](https://github.com/anqinou-art/NagiBridge)（MIT）
- 控制層理念與端點語意：NagiBridge 原作者（`farm_row.py` / `water_crops.py` 的站姿 / 時序紀律）
- 狀態速報（state strip）設計參考 NagiBridge-Remix
