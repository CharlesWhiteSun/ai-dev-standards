# Agent 操作守門

> 目的：把 AI Agent 的讀取失敗、錯誤命令、錯誤搜尋路徑與重複嘗試，轉成可記錄、可阻斷、可回歸的知識。

## 任務開始

1. 先讀本檔，再執行 `start-check`。
2. 執行 shell、搜尋 `.vscode`、批次改檔、或重跑曾失敗命令前，先執行：

  node .vscode/knowledge/scripts/kb.mjs repair-preflight --tool=<tool> --command="..." --path=path --intent="..."

3. preflight 回傳 `deny` 時不得執行原命令；改用輸出的替代方式。
4. preflight 回傳 `warn` 時可繼續，但需先說明風險與替代策略。

## 失敗閉環

1. 任一工具/命令失敗後，不得原樣重試。
2. 先記錄 sanitized failure：

  node .vscode/knowledge/scripts/kb.mjs repair-record --tool=<tool> --command="..." --path=path --exit-code=1 --intent="..." --error="摘要"

3. 再檢查是否重複：

  node .vscode/knowledge/scripts/kb.mjs repair-status

4. 同一 fingerprint 第 2 次失敗即視為 pending repair；必須改方法或新增/更新 operational trap。

## Fingerprint 欄位

| 欄位 | 說明 |
|------|------|
| tool | terminal / search / read / edit / browser / subagent |
| cwd | 執行目錄，預設為專案根目錄 |
| command | 正規化後的命令或工具摘要 |
| path | 主要操作路徑 |
| exit_code | 命令或工具失敗代碼 |
| error_hash | 錯誤摘要 hash，不保存完整敏感輸出 |
| intent | 本次嘗試目的 |

## 收尾規則

- `repair-health` 必須 0 errors，任務才可結束。
- repeated failure 必須升級成 `traps/trap-NNN.md` 的 operational trap，或寫入 false positive 並附到期日。
- runtime ledger 僅保存摘要與 hash；禁止保存 `.env`、token、密碼、完整 API key 或大段 stdout。

## 既知高風險

- `.vscode` / `.vscode/knowledge` 可能被一般搜尋忽略；請改用直接讀檔、列目錄或 include ignored。
- Windows PowerShell 5.1 不使用 `&&`；請用分號或分開命令。
- 禁止 `Get-Content | Set-Content`、`Set-Content`、`(Get-Content) -replace` 改寫知識庫 UTF-8 檔案。
- `/start-plan` 的 `agent` 值以本機 VS Code diagnostics 為準；若 `Plan` 合法，不要擅自改成 lowercase `plan`。
- VS Code `files.encoding` 應使用 `utf8`，不是 `utf-8`。