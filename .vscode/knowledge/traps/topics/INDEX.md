# 主題目錄（Topics Index）

> 由 `kb.mjs rebuild` 自動產生。AI 啟動任務時讀本檔即可掌握所有主題分布。

| slug | 名稱 | 相關 trap 數 | 連結 |
|------|------|-------------|------|
| agent-runtime-failure | Agent runtime failure 閉環 | 0 | [→](agent-runtime-failure.md) |
| tool-search-visibility | 工具搜尋可見性與 .vscode 讀取 | 0 | [→](tool-search-visibility.md) |
| command-preflight | 命令執行前 preflight | 0 | [→](command-preflight.md) |
| prompt-agent-compat | VS Code prompt agent 相容性 | 0 | [→](prompt-agent-compat.md) |
| vscode-settings-encoding | VS Code settings encoding id | 0 | [→](vscode-settings-encoding.md) |
| powershell-encoding | PowerShell UTF-8 編碼損毀 | 0 | [→](powershell-encoding.md) |
| misc | 雜項 | 0 | [→](misc.md) |

## 用法

- 想知道某類問題以前發生過幾次 → 看上表的「相關 trap 數」
- 命中主題 → 讀對應 `topics/{slug}.md`（含相關 trap 表 + 防呆原則）
- 模糊查詢 → `node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"`
