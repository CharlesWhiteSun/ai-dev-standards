---
agent: Plan
description: "規劃模式：讀取精簡知識庫 → 輸出執行計劃 → 等待確認後才執行"
---

# 規劃啟動：讀取知識庫 → 輸出計劃 → **等待確認**

> **重要：本 prompt 僅進行知識庫讀取與規劃，嚴禁在取得使用者確認前執行任何寫入操作。**
> 規範定義於 `copilot-instructions.md`（單一真實來源）。

## OpenSpec 預讀（新功能 / 規格變更才需要）

若任務屬於**新功能**、**規格變更**或**行為契約調整**：

1. 查 [openspec/specs/INDEX.md](openspec/specs/INDEX.md) 確認是否已有對應規格；若有，讀取後才輸出計劃
2. 以 `/opsx:explore` 釐清需求邊界
3. 以 `/opsx:propose` 建立 change（**待使用者確認計劃後**再手動觸發）

> 若為 **bug 修復 / 陷阱修補**，跳過此區塊，直接從「步驟一」開始。

## 步驟一：讀取知識庫與操作守門

0. 先讀 [agent/INDEX.md](knowledge/agent/INDEX.md)，確認 Agent 操作守門規則。

   - 不得直接執行含 `<模組>`、`<檔案>`、`<關鍵字>` 等 placeholder 的命令；必須先由任務內容推導實值。
   - 若工具/命令失敗，不得原樣重試；先執行 `repair-record` 記錄，再用 `repair-status` 檢查是否已是重複錯誤。
   - 若要執行已知高風險命令或搜尋 `.vscode` / `.vscode/knowledge`，先用 `repair-preflight` 檢查。

1. 優先執行定位守門（只讀；若 module/file/query 不明，先說明待探索，不執行 placeholder）：

  node .vscode/knowledge/scripts/kb.mjs start-check --module=<模組> --file=<檔案> --query="<關鍵字>"

2. 讀 [INDEX.md](knowledge/INDEX.md)（< 80 行）
3. 讀涉及模組的 `modules/{m}/quickref.md`（< 150 行）
4. 讀 [traps/topics/INDEX.md](knowledge/traps/topics/INDEX.md)（主題目錄）
5. 命中相關主題 → 讀 `traps/topics/{slug}.md`
6. 必要時讀 `traps/trap-NNN.md`

模糊查詢：

    node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"

Facet 精準切片：直接查 `traps/by-{file,topic,tag,module,symptom}.json`。

## 步驟二：TDD / SOLID / 範圍守門（只規劃，不寫檔）

若任務涉及程式碼修改，計劃必須先列出：

1. **TDD 入口**：要先新增/修改哪個測試、預期先失敗的行為是什麼；若不能 TDD，說明例外理由與替代驗證方式。
2. **SOLID 檢查**：本次修改如何維持單一職責、避免不必要抽象、避免破壞既有契約。
3. **可控管範圍**：預計異動檔案、對應測試/驗證命令、不得順手處理的 out-of-scope 項目。

若計劃需要擴大到未列入的檔案、跨模組設計或行為契約變更，必須先列為待確認事項，不得直接實作。

## 步驟三：輸出執行計劃（只輸出文字，不執行）

### 知識庫確認摘要

| 項目 | 內容 |
|------|------|
| 涉及模組 | （列出） |
| 命中主題 | （topic slug，附 `topics/{slug}.md` 路徑） |
| 命中陷阱 | （Trap #N，附 fragment 路徑） |
| 操作守門 | （preflight 結果、pending repair、需改用的替代讀取方式） |
| TDD 入口 | （先寫/改哪個測試；若例外，列理由與替代驗證） |
| SOLID / 範圍 | （設計約束、預計異動檔案、out-of-scope） |
| 已有規則 | （從 quickref / topic 防呆原則摘錄） |
| 需探索 | （不確定的部分） |

### 風險評估

列出潛在風險與須注意的已知陷阱。

### 執行計劃

以 `[探索]` / `[TDD]` / `[新增]` / `[修改]` / `[測試]` / `[SOLID檢查]` / `[知識庫]` 標籤列出步驟。

### 預計異動檔案清單

| 操作 | 檔案路徑 | 說明 |
|------|---------|------|

## ⏸ 等待確認

- 「**確認**」→ 依計劃執行
- 「**調整 N**」→ 修改第 N 步
- 「**取消**」→ 中止

## 我的任務描述

（請在此描述你的任務內容）
