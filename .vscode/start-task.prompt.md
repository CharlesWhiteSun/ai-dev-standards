---
agent: agent
description: "開始新任務前，自動載入精簡知識庫並啟動問題分析流程"
---

# 任務啟動：載入知識庫（4 層階梯）

> 規範定義於 `copilot-instructions.md`（單一真實來源），此 prompt 僅啟動讀取流程。

## OpenSpec 預讀（新功能 / 規格變更才需要）

若任務屬於**新功能**、**規格變更**或**行為契約調整**：

1. 查 [openspec/specs/INDEX.md](openspec/specs/INDEX.md) 確認是否已有對應規格；若有，讀取後才進行知識庫讀取
2. 以 `/opsx:explore` 釐清需求邊界
3. 以 `/opsx:propose` 建立 change

> 若為 **bug 修復 / 陷阱修補**，跳過此區塊，直接從「啟動步驟」開始。

## 啟動步驟（依序執行）

0. **先讀 Agent 操作守門**：[agent/INDEX.md](knowledge/agent/INDEX.md)

   - 不得直接執行含 `<模組>`、`<檔案>`、`<關鍵字>` 等 placeholder 的命令；必須先由任務內容推導實值。
   - 若工具/命令失敗，不得原樣重試；先執行 `repair-record` 記錄，再用 `repair-status` 檢查是否已是重複錯誤。
   - 搜尋 `.vscode` / `.vscode/knowledge` 失敗時，改用直接讀取、列目錄或 include ignored，不得只重複一般搜尋工具。

1. **優先執行定位守門**（若 module/file/query 不明，先說明待探索，不執行 placeholder）：

  node .vscode/knowledge/scripts/kb.mjs start-check --module=<模組> --file=<檔案> --query="<關鍵字>"

2. **讀 [INDEX.md](knowledge/INDEX.md)**（< 80 行，30 秒掌握全貌）
3. **讀涉及模組的 `modules/{m}/quickref.md`**（< 150 行，強制讀）
4. **讀 [traps/topics/INDEX.md](knowledge/traps/topics/INDEX.md)**（主題目錄，掌握「這類問題以前發生過幾次、分布在哪」）
5. **命中相關主題 → 讀 `traps/topics/{slug}.md`**（含相關 trap 表 + 防呆原則）
6. **必要時讀 `traps/trap-NNN.md`**（細節：症狀/根因/修正/測試）

## 模糊查詢（替代上述 4 / 5）

無法確定主題時：

    node .vscode/knowledge/scripts/kb.mjs search "<關鍵字或檔名>"

支援 FTS5 語法：`OR`、`"短語"`、`topics:"slug"`、`module:WorkPermit`。

## Facet 精準切片（程式碼任務常用）

依「我要修這個檔，以前在這檔踩過什麼坑？」查 [traps/by-file.json](knowledge/traps/by-file.json)；依「這個 tag 的歷史 bug」查 by-tag.json / by-topic.json / by-module.json / by-symptom.json。

## 回報

讀完上述後向用戶回報：涉及模組、命中主題（topic slug）、命中陷阱編號、操作守門摘要（preflight / pending repair / 替代讀取方式）、待探索範圍。

## 我的任務描述

（請在此描述你的任務內容）