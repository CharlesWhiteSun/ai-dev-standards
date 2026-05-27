# Tooling quickref

> 專案腳本、AI 工作流程、可選外部工具與升級策略的快速索引。

## 目前決策

| 決策 | 摘要 |
|------|------|
| [decision-001](decisions/decision-001.md) | RTK terminal hints 採 opt-in，僅作為輸出壓縮提示，不取代 KB / OpenSpec |
| [decision-002](decisions/decision-002.md) | 程式碼修改必須先經 TDD / SOLID / 可驗證範圍守門，避免超出可控管或驗證範圍 |

## 操作規則

- 新增外部工具整合時，預設不得成為硬性相依；需保留 fallback。
- 修改 `init-kb.ps1` / `update-kb.ps1` 後，至少執行 PowerShell parse check 與 update dry-run。
- 涉及 prompt 模板的升級需使用非破壞策略，既有手寫內容不得被覆蓋。

## 程式碼修改守門

- TDD 優先：bug 修復先補可重現失敗的測試，功能新增先補行為測試或 OpenSpec scenario；若不能 TDD，需寫明例外與替代驗證。
- SOLID 約束：維持單一職責，不新增無效抽象，不破壞公共契約；新增依賴或跨模組調整需說明理由。
- 可驗證範圍：計劃先列預計異動檔案、對應測試/驗證命令與 out-of-scope；若範圍擴大，先暫停確認。
- 收尾回顧：每個行為變更都要能對應到測試、OpenSpec 規格或明確手動驗證。
