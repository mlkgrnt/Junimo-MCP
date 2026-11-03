# 更新日志

每个版本的完整验收纪要另见 `release/notes-v<版本>.md`；这里只留对使用者的关键变化。

## [3.2.2] - 2026-11-04

### 变更
- **默认后端切到自研 [JunimoBridge](https://github.com/mlkgrnt/junimo-bridge)（7850）**；NagiBridge / NagiBridge-Remix（7842）降为兼容路径。
  - ⚠️ **破坏性**：老配置里写死 `STARDEW_API_URL=http://localhost:7842` 的会连不上；不设该变量则默认连 7850。
  - 两个执行器可以并存（端口不同），本机实测 7850 / 7842 同时在听。
- 工具数量与名称不变，仍是 37 个 —— 这次只换传输层，不改协议。

## 更早

3.2.2 之前没有单独的 CHANGELOG；完整验收纪要只有 `release/notes-v3.2.2.md`（含「升级须知」一节）。
更早版本的变化看 git 提交历史。