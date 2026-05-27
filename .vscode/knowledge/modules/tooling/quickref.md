# Tooling quickref

> 專案腳本、AI 工作流程、可選外部工具與升級策略的快速索引。

## 目前決策

| 決策 | 摘要 |
|------|------|
| [decision-001](decisions/decision-001.md) | RTK terminal hints 採 opt-in，僅作為輸出壓縮提示，不取代 KB / OpenSpec |

## 操作規則

- 新增外部工具整合時，預設不得成為硬性相依；需保留 fallback。
- 修改 `init-kb.ps1` / `update-kb.ps1` 後，至少執行 PowerShell parse check 與 update dry-run。
- 涉及 prompt 模板的升級需使用非破壞策略，既有手寫內容不得被覆蓋。