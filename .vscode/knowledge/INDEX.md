# 專案知識庫索引

> AI 啟動任務時依「4 層階梯」讀取；詳細規範見 `.vscode/copilot-instructions.md`。

## Quick Context（30 秒）

**技術棧**：（請填入）
**程式碼路徑**：（請填入）
**測試**：（請填入）
**Agent 操作守門**：[agent/INDEX.md](agent/INDEX.md)
**OpenSpec 行為規格**：[../openspec/specs/INDEX.md](../openspec/specs/INDEX.md)（WHAT；新功能前必查）

## 4 層階梯閱讀路徑

  agent/INDEX.md  →  INDEX.md  →  modules/{m}/quickref.md  →  traps/topics/INDEX.md  →  traps/topics/{slug}.md  →  traps/trap-NNN.md

## 模組導航（第 2 層）

| 模組 | quickref | 一句話 |
|------|----------|--------|
| Tooling | [modules/tooling/quickref.md](modules/tooling/quickref.md) | 腳本、AI 工作流程、外部工具選配整合與升級策略 |

## 已知陷阱（第 3 / 4 / 5 層）

- **第 3 層**：[traps/topics/INDEX.md](traps/topics/INDEX.md)（主題目錄，看「這類問題以前發生過幾次」）
- **第 4 層**：[traps/topics/{slug}.md](traps/topics/)（主題集群，含相關 trap 表 + 防呆原則）
- **第 5 層**：[traps/trap-NNN.md](traps/)（細節：症狀/根因/修正/測試）

主題分類學定義見 [traps/topics-taxonomy.yml](traps/topics-taxonomy.yml)（白名單，禁止繞過）。

## 多種查詢方式

| 場景 | 工具 |
|------|------|
| 模糊關鍵字 / 全文檢索 | `node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"`（SQLite FTS5） |
| 任務啟動必讀包 | `node .vscode/knowledge/scripts/kb.mjs start-check --module=<Module> --file=path.ext --query="keyword"` |
| 執行前操作守門 | `node .vscode/knowledge/scripts/kb.mjs repair-preflight --tool=terminal --command="..."` |
| 失敗記錄 / 重複檢查 | `repair-record` / `repair-status` / `repair-health` |
| 我要修這個檔，以前踩過什麼坑？ | 查 [traps/by-file.json](traps/by-file.json) |
| 某主題的所有 trap | 查 [traps/by-topic.json](traps/by-topic.json) 或讀 `topics/{slug}.md` |
| 某模組的所有 trap | 查 [traps/by-module.json](traps/by-module.json) |
| 某 tag 的所有 trap | 查 [traps/by-tag.json](traps/by-tag.json) |
| 症狀關鍵字命中 | 查 [traps/by-symptom.json](traps/by-symptom.json) |
| 機器可讀全表 | 讀 [traps/index.jsonl](traps/index.jsonl)（每行一個 JSON） |

## 變更歷程

按月封存於 [changelog/](changelog/)。任務結束時於當月檔案最上方加一行。

## 工具（CLI）

工具位於 [scripts/kb.mjs](scripts/kb.mjs)（Node 純 ESM）。

| 命令 | 用途 |
|------|------|
| `kb.mjs new-trap --module=X --title="..." --topics=slug --symptoms="A;B"` | 建新 trap fragment |
| `kb.mjs rebuild` | 重建 index.jsonl + facets + topics + fts.db |
| `kb.mjs taxonomy lint` | 校驗所有 trap 的 topics 都在白名單內 |
| `kb.mjs taxonomy stats` | 列出每個 topic 的 trap 覆蓋數 |
| `kb.mjs search "<query>"` | FTS5 全文檢索（需 Node 22.5+） |
| `kb.mjs start-check` | 任務啟動必讀包與 Agent Repair Context |
| `kb.mjs repair-preflight` | 執行 shell / 搜尋 / 改檔前的操作守門 |
| `kb.mjs repair-record` / `repair-status` / `repair-health` | runtime failure fingerprint 閉環 |
| `kb.mjs finish-check` | 任務結束總守門（taxonomy + health + repair-health + audit） |
| `kb.mjs facets` / `topics` | 只重建單項 |
| `kb.mjs audit` | 找拆分候選（多議題混在一個 trap） |
| `kb.mjs health` | 檢查 id / 編碼 / quickref 行數 / topics 對應 |

## 任務結束 Checklist

依序執行（缺一不可）：

1. 新增/編輯 trap fragment（必帶 `--topics --symptoms`），需要時補 taxonomy.yml
2. 在當月 `changelog/YYYY-MM.md` 最上方新增一行
3. 若本任務有失敗或重複嘗試，執行 `repair-status` / `repair-health`
4. `node .vscode/knowledge/scripts/kb.mjs rebuild`
5. `node .vscode/knowledge/scripts/kb.mjs finish-check`（必須 0 errors）
6. 最後輸出 commit 訊息（純文字，不放 fenced code block）