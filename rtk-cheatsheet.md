# RTK 指令速查（選配）

> RTK（Rust Token Killer）是 terminal 輸出壓縮工具，可減少 AI 讀取命令輸出的 token 成本。
> 本專案只提供可選提示與文件，不會安裝 RTK、不會修改全域 hook，也不會讓 RTK 成為必要相依。

---

## 何時使用

RTK 適合輸出量大的命令：

- `git status` / `git diff` / `git log`
- `rg` / `grep` / `find` / `ls`
- 測試、lint、build、type check
- 大型 log、JSON、docker / kubectl 輸出

RTK 不適合取代：

- `.vscode/knowledge/` 的 trap、facet、FTS5 與 repair closure
- `.vscode/openspec/` 的行為規格與 change artifacts
- VS Code / Copilot 內建 read/search 工具

---

## 安裝狀態檢查

PowerShell：

    Get-Command rtk -ErrorAction SilentlyContinue
    rtk --version

若找不到 RTK，使用原命令即可；不要讓任務因缺少 RTK 中止。

---

## Native Windows 使用方式

Native Windows 可顯式使用 RTK，但 auto-rewrite hook 不完整：

    rtk git status
    rtk git diff
    rtk git log -n 10
    rtk grep "keyword" .
    rtk find "*.php" .
    rtk test npm test
    rtk err npm run build

若 RTK 輸出不足，改用原命令或 RTK verbose 取得完整上下文。

---

## WSL 使用方式

WSL 可使用 RTK 的完整 hook / auto-rewrite 流程，但仍建議保留原命令 fallback。若專案主要在 Windows PowerShell 執行，不要假設 hook 已啟用。

---

## 與 Agent Guard 搭配

1. 執行高輸出命令前，可優先選 RTK 顯式命令。
2. RTK 命令失敗時，不得原樣重試；先使用 `repair-record` 記錄 sanitized failure。
3. 若 RTK 壓縮後資訊不足，回退原命令取得完整資訊。
4. 不得把 RTK tee raw output、`.env`、token、密碼、完整 API key 或大段 stdout 寫入知識庫。

---

## 隱私與 telemetry

RTK telemetry 是外部工具的 opt-in 功能。本專案不自動啟用 telemetry，不代替使用者同意，也不把 RTK telemetry 當成任務完成條件。