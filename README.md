# VS Code 本機 AI 知識庫初始化工具

透過一鍵 PowerShell 腳本，在任何專案中建立**可隨知識量擴張的結構化 AI 協作知識庫**，讓 GitHub Copilot Chat 在每次對話中都能高效率地讀取歷史踩坑、遵守統一規範，並在任務結束時自動歸檔新陷阱。

> 適用 v3 架構：**4 層階梯 + facets + topics + SQLite FTS5 全文檢索**。

---

## 目錄

- [核心特色](#核心特色)
- [建立的目錄結構](#建立的目錄結構)
- [4 層階梯閱讀路徑](#4-層階梯閱讀路徑)
- [快速開始](#快速開始)
- [Copilot Chat 指令](#copilot-chat-指令)
- [kb.mjs CLI 指令](#kbmjs-cli-指令)
- [腳本參數](#腳本參數)
- [設計理念](#設計理念)
- [系統需求](#系統需求)
- [注意事項](#注意事項)
- [授權條款](#授權條款)

---

## 核心特色

| 特色 | 說明 |
|------|------|
| **4 層階梯讀取** | INDEX → modules/quickref → traps/topics/INDEX → topics/{slug} → trap-NNN，AI 只讀必要層級 |
| **主題化（topics）** | 把同類踩坑歸到一個 slug，看一次 `topics/INDEX.md` 就知道「這類問題以前發生過幾次」 |
| **5 種 facet 索引** | by-module / by-tag / by-topic / **by-file** / by-symptom，「我要修這個檔，以前踩過什麼坑？」一查就有 |
| **SQLite FTS5 全文檢索** | BM25 排序 + snippet 預覽，採 Node 22.5+ 內建 `node:sqlite`，**零外部相依** |
| **CLI 自動產生衍生物** | `kb.mjs rebuild` 一次重建 index.jsonl + 5 facets + topics + fts.db |
| **編碼安全** | 全程 UTF-8 without BOM；`kb.mjs health` 自動檢測 BOM / U+FFFD / quickref 行數 |
| **Topic 防呆原則手動保留** | `topics/{slug}.md` 用 `<!-- AUTO_BEGIN/END -->` 分隔，AUTO 區自動覆寫，防呆原則段落手動維護不會被洗掉 |
| **本機隔離** | 全部存於 `.vscode/`，建議加 `.gitignore`，不影響其他協作者 |

---

## 建立的目錄結構

```
專案根目錄/
├── init-kb.ps1                          ← 本腳本
└── .vscode/
    ├── settings.json                    ← Copilot prompt 路徑設定
    ├── copilot-instructions.md          ← 單一規範來源（SSOT）
    ├── start-task.prompt.md             ← /start-task：4 層階梯讀取
    ├── start-plan.prompt.md             ← /start-plan：Plan 模式（讀 → 計劃 → 等待確認）
    ├── end-task.prompt.md               ← /end-task：更新 KB + commit 訊息
    └── knowledge/
        ├── INDEX.md                     ← <80 行純導航（第 1 層）
        ├── changelog/
        │   └── YYYY-MM.md               ← 當月變更歷程
        ├── modules/                     ← 第 2 層：各模組 quickref（使用者自填）
        ├── traps/
        │   ├── topics-taxonomy.yml      ← 主題白名單（人工維護）
        │   ├── topics/
        │   │   ├── INDEX.md             ← 第 3 層：主題目錄（rebuild 自動）
        │   │   └── {slug}.md            ← 第 4 層：主題集群（AUTO + 防呆原則）
        │   ├── trap-NNN.md              ← 第 5 層：陷阱片段（new-trap 產生）
        │   ├── index.jsonl              ← 機器可讀大表（自動）
        │   ├── by-module.json           ← facet 索引（自動）
        │   ├── by-tag.json
        │   ├── by-topic.json
        │   ├── by-file.json
        │   ├── by-symptom.json
        │   └── fts.db                   ← SQLite FTS5（自動）
        └── scripts/
            └── kb.mjs                   ← v3 CLI（純 Node ESM）
```

---

## 4 層階梯閱讀路徑

AI 啟動任務時依下列順序讀取，**不命中就停在那一層**：

    INDEX.md  →  modules/{m}/quickref.md  →  traps/topics/INDEX.md  →  traps/topics/{slug}.md  →  traps/trap-NNN.md
    (<80 行)         (<150 行)                (主題目錄)                (主題集群+防呆原則)        (細節)

當無法判斷主題時改用全文檢索：

    node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"

或修檔前直接查「這個檔以前踩過什麼坑」：

    cat .vscode/knowledge/traps/by-file.json | grep "src/path/to/file.ext"

---

## 快速開始

### 前置需求

- Windows PowerShell 5.1 或更新版本（macOS/Linux 用 pwsh）
- Visual Studio Code（含 GitHub Copilot Chat 擴充功能）
- **Node.js 16+**（rebuild / new-trap / facets / topics / health 全部可用）
- **Node.js 22.5+**（額外解鎖 `kb.mjs search` SQLite FTS5 全文檢索）

### 步驟

**1. 將腳本複製到專案根目錄**

```
專案根目錄/
└── init-kb.ps1
```

**2. 在專案根目錄執行**

```powershell
.\init-kb.ps1
```

腳本會自動：

- 建立 `.vscode/` 結構與所有規範檔
- 執行 `node kb.mjs rebuild` 初始化索引
- 執行 `node kb.mjs health` 確認狀態
- 詢問是否重新載入 VSCode 視窗

**3. 填入專案特定資訊**

至少完成以下兩個檔案的「（請填入）」段落：

- `.vscode/copilot-instructions.md` — 技術棧、專案架構、測試規範
- `.vscode/knowledge/INDEX.md` — Quick Context、模組導航表

**4. 在 Copilot Chat 輸入 `/start-task` 開始使用**

---

## Copilot Chat 指令

初始化完成後，可在 VS Code Copilot Chat 中使用以下三個 `/` 指令：

### `/start-task` — 任務啟動（4 層階梯讀取）

執行流程：依序讀 INDEX → modules/quickref → topics/INDEX → 命中的 topic → 必要的 trap，向使用者回報「涉及模組、命中主題、命中陷阱、待探索範圍」後接收任務。

### `/start-plan` — Plan 模式（讀取 → 計劃 → 等待確認）

執行流程：完成 4 層階梯讀取後**只輸出計劃**（知識庫確認摘要、風險評估、執行計劃、預計異動檔案清單），等使用者回覆「**確認**」才開始執行。**嚴禁在確認前寫入任何檔案**。

### `/end-task` — 任務結束（強制歸檔）

執行流程：

1. 輸出 commit 訊息（純文字，不放 fenced code block）
2. 新增/編輯 trap fragment（**必帶 `--topics --symptoms`**）
3. 需要時更新 `topics-taxonomy.yml`
4. 需要時更新 `topics/{slug}.md` 的防呆原則段落（`<!-- AUTO_END -->` 之下）
5. 在 `changelog/YYYY-MM.md` 最上方新增一行
6. `node kb.mjs rebuild`
7. `node kb.mjs health`（必須 0 errors）

---

## kb.mjs CLI 指令

純 Node ESM，無 npm 依賴。

| 指令 | 用途 |
|------|------|
| `node kb.mjs rebuild [--no-fts]` | 重建 `index.jsonl` + 5 facet JSON + `topics/{slug}.md` AUTO 區 + `fts.db` |
| `node kb.mjs new-trap --module=X --title="..." --topics=slug1,slug2 --symptoms="A;B" [--files=...] [--tests=...] [--related=12,34] [--tags=...]` | 自動取下一個 id、校驗 topics 白名單，產生 `trap-NNN.md` 並 rebuild |
| `node kb.mjs new-decision --module=X --title="..."` | 在 `modules/{m}/decisions/` 新增決策片段 |
| `node kb.mjs taxonomy lint` | 校驗所有 trap 的 topics 都在 `topics-taxonomy.yml` 白名單內，列出 unmapped |
| `node kb.mjs taxonomy stats` | 列出每個 topic 的 trap 覆蓋數（TSV 格式） |
| `node kb.mjs facets` | 只重建 5 種 facet JSON |
| `node kb.mjs topics` | 只重建 `topics/{slug}.md` 與 `topics/INDEX.md`（保留手動防呆原則段落） |
| `node kb.mjs audit` | 找拆分候選（行數 > 60 且多段症狀/根因，建議拆成多筆 trap） |
| `node kb.mjs bulk-tag --file=mapping.json` | 一次性套用 `{ "trap_id": [topic_slug, ...] }` 對照表 |
| `node kb.mjs search "<query>" [--limit=20] [--json]` | SQLite FTS5 全文檢索；支援 `OR`、`"短語"`、`topics:"slug"` 語法 |
| `node kb.mjs health` | 健康檢查：id 唯一性、檔名 / id 一致、UTF-8 BOM、U+FFFD、quickref 行數、index.jsonl 過期 |

---

## 腳本參數

```powershell
.\init-kb.ps1 [-Force]
```

| 參數 | 說明 |
|------|------|
| （無參數） | 預設執行；已存在的知識庫檔案**不覆蓋**，`settings.json` 永遠不覆蓋 |
| `-Force` | 強制覆蓋所有知識庫檔案（`settings.json` 仍不覆蓋） |

---

## 設計理念

### 為什麼要 4 層階梯？

當 trap 累積到 100 筆以上，AI 每次任務都掃完整個 `index.jsonl` 成本太高。4 層設計讓 AI 用「主題密度」決定要不要往下挖：看 `topics/INDEX.md` 一眼就知道「這類問題以前發生過 8 次」，命中後再讀單一 topic 集群頁，最後才是個別 trap 細節。

### 為什麼要 facet 索引？

傳統「按時間排序的 changelog」回答不了「我要修這個檔以前踩過什麼坑」。`by-file.json` 直接把檔名映射到 trap id 列表，修 bug 前一查就知道歷史。其他 facet（topic / module / tag / symptom）同理。

### 為什麼用 SQLite FTS5？

`grep` 不能做 BM25 相關度排序，也沒有 snippet 預覽。FTS5 提供毫秒級全文檢索，且 Node 22.5+ 內建 `node:sqlite` 模組，**完全無需 npm install**。Node 版本不足時，CLI 會印 `[fts] skipped` 並優雅降級，其他功能不受影響。

### 為什麼是「自動 + 手動」混合？

`topics/{slug}.md` 的 AUTO 區（相關 trap 表、定義、關鍵字）由 CLI 自動產生，但「**防呆原則**」段落由 AI/人工累積撰寫，CLI 用 `<!-- AUTO_BEGIN/END -->` 標記分隔，rebuild 時只覆寫 AUTO 區，手動內容永久保留。

### 本機隔離，不干擾協作

知識庫存於 `.vscode/`，建議加入 `.gitignore`。每位開發者維護自己的本機 AI 知識庫，不強制所有協作者都使用相同的 AI 工作流程。

### 非破壞性設計

- 預設不覆蓋已存在的檔案（`-Force` 才會）
- `settings.json` 永遠不覆蓋，只在缺少必要設定時提示
- `topics/{slug}.md` 防呆原則段落、`changelog/YYYY-MM.md` 歷史列**只增不改**

---

## 系統需求

| 元件 | 最低版本 | 用途 |
|------|---------|------|
| PowerShell | 5.1 | 執行 `init-kb.ps1` |
| Node.js | 16+ | rebuild / new-trap / facets / topics / health / taxonomy / audit / bulk-tag |
| Node.js | 22.5+ | 額外啟用 `kb.mjs search` 全文檢索 |
| VS Code + Copilot Chat | 最新 | 三個 `/` prompt 指令 |

> **無 npm 依賴**：`kb.mjs` 是純 Node ESM，使用 Node 內建模組（`fs/promises`、`path`、`url`、`sqlite`）。

---

## 注意事項

1. **首次使用必須重新載入 VS Code 視窗**：`Ctrl+Shift+P` → `Reload Window`，`/start-task` 等指令才會出現在 Copilot Chat 的 `/` 選單。
2. **編碼絕對禁止 PowerShell `Set-Content`**：CP950 會永久毀掉中文。改用 `kb.mjs new-trap` / Node `fs.writeFileSync` / VS Code 直接編輯。
3. **新增 trap 必須走 `kb.mjs new-trap`**：自動取下一個 id 避免衝突，自動校驗 topic 白名單。
4. **`traps/index.jsonl` / `by-*.json` / `topics/{slug}.md` 的 AUTO 區 / `fts.db` 全部禁止手動編輯**：rebuild 會覆寫。
5. **新主題 slug 必須先登記**：在 `topics-taxonomy.yml` 加條目後再用，否則 `taxonomy lint` 會擋。

---

## 授權條款

見 [LICENSE](LICENSE)。
