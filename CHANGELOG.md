# 更新日志

每个版本的完整验收纪要另见 `release/notes-v<版本>.md`；这里只留对使用者的关键变化。

## [3.2.3] - 2026-11-04

### 修复
- **`press_key` 的方向键真正能走了**。以前 `press_key up/down/left/right` 回
  「已按键」但游戏里什么都不发生 —— 因为 SDV 的 `options.moveXButton` 默认
  只绑 `W`/`A`/`S`/`D`，**箭头键压根没绑**，注入 `Keys.Up` 等于按空气。
  现在由 [JunimoBridge v0.1.1](https://github.com/mlkgrnt/junimo-bridge/releases/tag/v0.1.1)
  把语义名解析成游戏内实际绑定，改键位也能跟上。
- **`press_key` 不认识的键名会报错**（以前静默回 ok，看起来成功其实没按）。

### 变更
- `press_key` 描述里写清：方向名走游戏内绑定、`cancel` 关掉当前一层、
  要整段跳过对话/事件用 `escape`/`menu`/`skip`。
- 配套执行器建议升到 **JunimoBridge v0.1.1**（`/key` 的回执新增 `resolvedKeys`，
  一眼能看出实际按了哪个键）。

## [3.2.4] - 2026-11-04

### 修复
- **`sleep` 谎报写盘**：原来只轮询到「日期变了」就返回「进度已写盘」。实测白天
  强行触发睡觉时，游戏会把日期推进到第二天但**跳过存盘环节** —— 回执说写了，关掉游戏
  重开还是前一天，当天进度全丢。现在睡之前记下存档目录里最新 `SaveGameInfo` 的 mtime，
  睡完轮询 20 秒确认它变了：变了才说「已写盘（已核对存档文件时间）」；没变就直接报错并
  提示「再睡一觉（正常夜里睡会真正写盘）」。取不到存档目录（非 Windows 等）时如实说明未核对。

## [3.2.2] - 2026-11-04


### 变更
- **默认后端切到自研 [JunimoBridge](https://github.com/mlkgrnt/junimo-bridge)（7850）**；NagiBridge / NagiBridge-Remix（7842）降为兼容路径。
  - ⚠️ **破坏性**：老配置里写死 `STARDEW_API_URL=http://localhost:7842` 的会连不上；不设该变量则默认连 7850。
  - 两个执行器可以并存（端口不同），本机实测 7850 / 7842 同时在听。
- 工具数量与名称不变，仍是 37 个 —— 这次只换传输层，不改协议。

## 更早

3.2.2 之前没有单独的 CHANGELOG；完整验收纪要只有 `release/notes-v3.2.2.md`（含「升级须知」一节）。
更早版本的变化看 git 提交历史。