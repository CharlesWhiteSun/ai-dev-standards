---
agent: agent
description: "任務結束後，更新知識庫並輸出 Commit 訊息"
---

# 任務結束：更新知識庫與 Commit

> 依 `copilot-instructions.md`「任務結束後」固定順序執行。

## 執行步驟

1. **若有新陷阱** → 執行（`--topics --symptoms` 強烈建議帶上）：

       node .vscode/knowledge/scripts/kb.mjs new-trap `
         --module=SomeModule `
         --title="..." `
         --topics=slug1,slug2 `
         --symptoms="症狀短語A;症狀短語B" `
         --files=path/to/file.ext `
         --tests=tests/path/test.ext

   再編輯生成的 `traps/trap-NNN.md` 補完症狀/根因/修正/測試。
   **若僅修訂既有陷阱** → 直接編輯對應 `traps/trap-NNN.md`，必要時更新 `topics:` / `symptoms:`。

2. **若需新主題 slug** → 編輯 [traps/topics-taxonomy.yml](knowledge/traps/topics-taxonomy.yml) 新增條目（slug / name / desc / keywords）。

3. **若主題防呆原則需更新** → 編輯 `traps/topics/{slug}.md` 的 `<!-- AUTO_END -->` **以下** 段落（AUTO 區會被 rebuild 覆寫，不要動）。

4. **更新模組 quickref**（若有商務規則或設計變動）

5. **在當月 `changelog/YYYY-MM.md` 最上方新增一行**（| 日期 | 模組 | 摘要 | 異動檔案 | 備註 |）

6. **若本任務發生工具/命令失敗或重複嘗試** → 執行：

    node .vscode/knowledge/scripts/kb.mjs repair-status
  node .vscode/knowledge/scripts/kb.mjs repair-health

  若有 unresolved repeated failure，必須新增/更新 operational trap 或標註 false positive，再繼續收尾。

7. **若本任務有建立 OpenSpec change**（新功能 / 規格變更任務）：

   a. 確認所有 tasks 已完成：`.\opsx status --change <change-name>`
   b. 執行 `/opsx:archive` 封存 change（archive 後立即接 rebuild）

   > 若為純 bug 修復（無 OpenSpec change），跳過此步驟。

8. **執行**：

       node .vscode/knowledge/scripts/kb.mjs rebuild
  node .vscode/knowledge/scripts/kb.mjs finish-check

  `finish-check` 必須 0 errors 才算完成。`rebuild` 會自動：
   - 重建 `traps/index.jsonl`
   - 重建 `traps/by-{module,tag,topic,file,symptom}.json` facet 索引
   - 重建 `traps/topics/{slug}.md` 與 `topics/INDEX.md`（AUTO 區）
  - 重建 `traps/fts.db`（SQLite FTS5 全文檢索；需 Node 22.5+）

9. **輸出 Commit 訊息**（純文字段落，禁止 fenced code block；格式見 `copilot-instructions.md`「Commit 訊息格式」）

## 本次任務摘要

（可選填：若需補充背景，在此說明）