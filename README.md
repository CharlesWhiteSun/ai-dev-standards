# VS Code 本機 AI 知識庫初始化工具

透過一鍵 PowerShell 腳本，在任何專案中建立**可隨知識量擴張的結構化 AI 協作知識庫**，讓 GitHub Copilot Chat 在每次對話中都能高效率地讀取歷史踩坑、遵守統一規範，並在任務結束時自動歸檔新陷阱。

> **v3.2（目前版本）**：**4 層階梯 + facets + topics + SQLite FTS5 全文檢索 + Agent Guard / repair closure + OpenSpec 雙軌流程**
> **v3.2.1（本版新增）**：加入 **RTK terminal 輸出壓縮選配提示**（opt-in，不安裝、不強制、不取代 KB / OpenSpec）
> **v3.3（後續規劃）**：RTK doctor / 本機成效摘要 / RTK tee 與 repair closure 橋接

---

## 目錄

- [v3.2 升級路線（KB + OpenSpec）](#v32-升級路線kb--openspec)
- [核心特色](#核心特色)
- [建立的目錄結構](#建立的目錄結構)
- [4 層階梯閱讀路徑](#4-層階梯閱讀路徑)
- [快速開始](#快速開始)
- [既有知識庫升級](#既有知識庫升級)
- [opsx.bat / opsx.ps1](#opsxbat--opsxps1)
- [RTK 選配整合](#rtk-選配整合)
- [Copilot Chat 指令](#copilot-chat-指令)
- [kb.mjs CLI 指令](#kbmjs-cli-指令)
- [腳本參數](#腳本參數)
- [設計理念](#設計理念)
- [系統需求](#系統需求)
- [注意事項](#注意事項)
- [授權條款](#授權條款)

---

## v3.2 升級路線（KB + OpenSpec）

> **v3.1** = Knowledge Base only（4 層階梯 + facets + topics + Agent Guard + repair closure + finish-check）
> **v3.2** = Knowledge Base + OpenSpec 雙軌（在 v3.1 基礎上加入行為規格層）

### 兩套系統分工

| 維度 | OpenSpec（`.vscode/openspec/`）| 知識庫（`.vscode/knowledge/`）|
|------|----------------------|-------------------------------|
| **回答問題** | WHAT（行為契約、需求規格）| WHY/HOW-NOT-TO（根因、修正歷程）|
| **觸發時機** | 新功能 / 規格變更 / 跨模組行為設計 | 踩坑、bug 修復、設計決策補錄 |
| **入口指令** | `/opsx:explore`、`/opsx:propose` | `kb.mjs new-trap` |
| **結束動作** | `/opsx:archive` → `kb.mjs rebuild` | `kb.mjs rebuild` |
| **產出位置** | `.vscode/openspec/changes/{name}/`（change artifacts）`.vscode/openspec/specs/{module}/`（行為契約）| `traps/trap-NNN.md`（陷阱）`traps/topics/{slug}.md`（主題集群）|

### v3.2 架構概觀

    ┌──────────────────────────────────────────────────────────────┐
    │                      雙軌儲存系統                            │
    │  ┌──────────────────────┐      ┌────────────────────────┐  │
    │  │      OpenSpec        │      │    Knowledge Base      │  │
    │  │  .vscode/openspec/   │      │  .vscode/knowledge/    │  │
    │  │  WHAT：行為規格      │      │  WHY / HOW-NOT-TO      │  │
    │  │  changes/{name}/     │      │  traps/trap-NNN.md     │  │
    │  │  specs/{module}/     │      │  traps/topics/         │  │
    │  └──────────────────────┘      └────────────────────────┘  │
    └──────────────────────────────────────────────────────────────┘

    ┌──────────────┬─────────────────┬──────────────┬────────────────┐
    │ #start-plan  │  /opsx:propose  │ #start-task  │   #end-task    │
    │  預讀+計劃   │   建立 change   │ KB讀取+實作  │  KB更新+歸檔   │
    │ （等待確認） │    artifacts    │ /opsx:apply  │ /opsx:archive  │
    │              │  確認計劃後觸發 │   執行測試   │   rebuild      │
    │              │                 │              │   finish-check │
    └──────────────┴─────────────────┴──────────────┴────────────────┘

### v3.2 完整開發流程

初始化或升級後，可在 Copilot Chat 以以下流程作業：

    Step 0  /opsx:explore        釐清需求邊界與設計假設          ← #start-plan 觸發
    Step 1  /opsx:propose        建立 change，產出 artifacts     ← 確認計劃後手動觸發
    Step 2  kb.mjs start-check   知識庫預讀（陷阱、主題、quickref）← #start-task 觸發
    Step 3  /opsx:apply          實作 tasks                      ← #start-task 執行
    Step 4  （語言對應測試指令）  執行測試，確認 0 failures         ← #start-task 執行
    Step 5  kb.mjs new-trap      若發現新陷阱，登錄知識庫          ← #end-task 執行
    Step 6  /opsx:archive        封存 change                     ← #end-task 執行
    Step 7  kb.mjs rebuild       重建知識庫索引                   ← #end-task 執行
    Step 8  kb.mjs finish-check  體檢（errors=0）                 ← #end-task 執行

### Prompt 入口對照（v3.2）

| Prompt / 指令 | 涵蓋步驟 | 用途 | 注意 |
|--------------|---------|------|------|
| `#start-plan` | Step 0, Step 2 | 分析需求、讀 KB、輸出計劃表，**等待確認才繼續** | Read-only；不寫入任何檔案 |
| `/opsx:propose` | Step 1 | 確認計劃後，建立 change artifacts（tasks.md、design.md、spec.md） | 確認計劃後**手動觸發**；bug 修復通常跳過 |
| `#start-task` | Step 2~4 | KB 讀取 + 實作 + 測試 | 新功能含 `/opsx:apply`；bug 修復跳過 Step 0~1 |
| `#end-task` | Step 5~8 | KB 更新 + archive + rebuild + finish-check | archive（Step 6）在 rebuild（Step 7）之前 |

### 何時觸發 `/opsx:propose`

`/opsx:propose` 負責把「確認的計劃」轉為具體 change artifacts，供後續 `/opsx:apply` 追蹤實作進度：

**應該觸發：**

- 新功能、新頁面、新 API 端點
- 規格變更（改變已定義的行為契約）
- 跨模組設計決策（影響兩個以上的 Controller / Service / 資料流）

**可以跳過：**

- 純 bug 修復（已知問題，不改行為契約）
- 陷阱修補（只補 KB，不涉及新規格）
- 技術債清理（對外行為不變）
- 一次性 migration / seed / 資料修補腳本

> 若不確定，先用 `#start-plan` 搭配 `/opsx:explore` 釐清邊界，確認後再決定是否執行 `/opsx:propose`。

### 依任務類型選擇流程

    新功能 / 規格變更                            Bug 修復 / 陷阱修補
    ──────────────────────────────               ─────────────────────
    #start-plan                                  │
      ↓ OpenSpec 預讀 + KB 讀取                  │
      ↓ 輸出計劃（等待確認，不寫檔）               │
      ↓                                          │
    （確認計劃）                                  │
      ↓                                          │
    /opsx:propose                                │
      ↓ 建立 change artifacts                    │
      ↓ tasks.md / design.md / spec.md           │
      ↓                                          │
    #start-task ──────────────────────────► #start-task
      ↓ KB 讀取 (start-check)                    ↓ KB 讀取 (start-check)
      ↓ /opsx:apply 實作 tasks                   ↓ 直接實作
      ↓ 執行測試                                 ↓ 執行測試
      ↓                                          ↓
    #end-task  ────────────────────────────► #end-task
      ↓ kb.mjs new-trap（若有新陷阱）              ↓ kb.mjs new-trap（若有新陷阱）
      ↓ /opsx:archive（封存 change）               ↓ （跳過 /opsx:archive）
      ↓ kb.mjs rebuild                           ↓ kb.mjs rebuild
      ↓ kb.mjs finish-check（0 errors）           ↓ kb.mjs finish-check（0 errors）

### v3.1 → v3.2 重構路線

v3.2 採**漸進式、非破壞**設計，v3.1 功能完全保留：

| 階段 | 內容 | 影響範圍 |
|------|------|----------|
| **Phase 0**（✅） | 定義升級邊界、更新 README | 文件，無程式碼異動 |
| **Phase 1**（✅） | OpenSpec scaffold + `opsx` wrapper + cheatsheet | `init-kb.ps1` 新增產出物 |
| **Phase 2**（✅） | Prompt 模板整合 OpenSpec 雙軌流程 | `init-kb.ps1` 三個 prompt template |
| **Phase 3**（✅） | `update-kb.ps1` 補 OpenSpec 升級能力 | `update-kb.ps1` |
| **Phase 4**（✅） | `kb.mjs finish-check` 補 OpenSpec 靜態驗證 | `kb.mjs` template |
| **Phase 5**（✅） | README 使用者心智模型更新 | `README.md` |
| **Phase 6**（✅） | RTK terminal hints 選配整合 | `init-kb.ps1`、`update-kb.ps1`、`README.md`、`rtk-cheatsheet.md` |
| Phase 7 | 端對端驗證與回歸 | 測試矩陣 |
| Phase 8 | RTK doctor / 本機成效摘要 / tee 橋接 | `kb.mjs` 後續升版 |

> **`-SkipOpenSpec` 參數**（Phase 1 加入）：讓不需要 OpenSpec 的小型專案略過 scaffold，保持純 v3.1 KB 行為。

---

## 核心特色

| 特色 | 說明 |
|------|------|
| **4 層階梯讀取** | agent/INDEX → INDEX → modules/quickref → traps/topics/INDEX → topics/{slug} → trap-NNN，AI 只讀必要層級 |
| **主題化（topics）** | 把同類踩坑歸到一個 slug，看一次 `topics/INDEX.md` 就知道「這類問題以前發生過幾次」 |
| **5 種 facet 索引** | by-module / by-tag / by-topic / **by-file** / by-symptom，「我要修這個檔，以前踩過什麼坑？」一查就有 |
| **SQLite FTS5 全文檢索** | BM25 排序 + snippet 預覽，採 Node 22.5+ 內建 `node:sqlite`，**零外部相依** |
| **CLI 自動產生衍生物** | `kb.mjs rebuild` 一次重建 index.jsonl + 5 facets + topics + fts.db |
| **Agent Guard** | 任務開始先讀 `agent/INDEX.md`，執行前用 `repair-preflight` 阻擋 placeholder、錯誤 shell 與已知重複坑 |
| **Repair closure** | 工具/命令失敗後用 `repair-record` 記錄 sanitized fingerprint；同一錯誤重複會被 `repair-health` 擋下 |
| **Finish gate** | `finish-check` 整合 taxonomy、health、repair-health，確保任務結束前可回歸檢查 |
| **RTK terminal hints（選配）** | 使用 `-EnableRtkHints` 才產生 RTK 指引；RTK 只壓縮 terminal 輸出，不取代 KB / OpenSpec，未安裝時自動回退原命令 |
| **編碼安全** | 全程 UTF-8 without BOM；`kb.mjs health` 自動檢測 BOM / U+FFFD / quickref 行數 |
| **Topic 防呆原則手動保留** | `topics/{slug}.md` 用 `<!-- AUTO_BEGIN/END -->` 分隔，AUTO 區自動覆寫，防呆原則段落手動維護不會被洗掉 |
| **本機隔離** | 全部存於 `.vscode/`，建議加 `.gitignore`，不影響其他協作者 |

---

## 建立的目錄結構

```
專案根目錄/
├── init-kb.ps1                          ← 新專案初始化腳本
├── update-kb.ps1                        ← 既有知識庫非破壞性升級腳本
├── opsx.bat                             ← openspec wrapper（建議不入版控）
├── opsx.ps1                             ← openspec wrapper（建議不入版控）
├── openspec-cheatsheet.md               ← opsx 指令速查表
├── rtk-cheatsheet.md                    ← RTK 指令速查表（僅 -EnableRtkHints 產生）
└── .vscode/
    ├── settings.json                    ← Copilot prompt 路徑設定
    ├── copilot-instructions.md          ← 單一規範來源（SSOT）
    ├── start-task.prompt.md             ← /start-task：4 層階梯讀取
    ├── start-plan.prompt.md             ← /start-plan：Plan 模式（讀 → 計劃 → 等待確認）
    ├── end-task.prompt.md               ← /end-task：更新 KB + commit 訊息
    ├── openspec/                        ← OpenSpec 行為規格系統（v3.2）
    │   ├── config.yaml                  ← openspec CLI 組態
    │   ├── schemas/                     ← spec JSON Schema
    │   ├── specs/
    │   │   └── INDEX.md                 ← 行為規格目錄（新功能前必查）
    │   ├── changes/                     ← 進行中 change artifacts
    │   └── archive/                     ← 已封存 change
    └── knowledge/
        ├── INDEX.md                     ← <80 行純導航（第 1 層）
        ├── changelog/
        │   └── YYYY-MM.md               ← 當月變更歷程
        ├── agent/
        │   ├── INDEX.md                 ← Agent 操作守門與 repair closure
        │   └── generated/               ← repair guard facets（rebuild 自動）
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
        ├── runtime/                     ← 本機 runtime failure ledger（只放摘要/hash）
        └── scripts/
            └── kb.mjs                   ← v3.1 CLI（純 Node ESM）
```

---

## 4 層階梯閱讀路徑

AI 啟動任務時依下列順序讀取，**不命中就停在那一層**：

    agent/INDEX.md  →  INDEX.md  →  modules/{m}/quickref.md  →  traps/topics/INDEX.md  →  traps/topics/{slug}.md  →  traps/trap-NNN.md
    (操作守門)          (<80 行)         (<150 行)                (主題目錄)                (主題集群+防呆原則)        (細節)

啟動時建議先跑只讀守門：

    node .vscode/knowledge/scripts/kb.mjs start-check --module=<Module> --file=path.ext --query="keyword"

當無法判斷主題時改用全文檢索：

    node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"

或修檔前直接查「這個檔以前踩過什麼坑」：

    node .vscode/knowledge/scripts/kb.mjs repair-preflight --tool=terminal --command="..." --intent="..."

若任何工具或命令失敗，不要原樣重試，先記錄：

    node .vscode/knowledge/scripts/kb.mjs repair-record --tool=terminal --command="..." --exit-code=1 --error="摘要"
    node .vscode/knowledge/scripts/kb.mjs repair-status

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

若要同時產生 RTK terminal 輸出壓縮提示（選配，不安裝 RTK、不強制使用）：

```powershell
.\init-kb.ps1 -EnableRtkHints
```

腳本會自動：

- 建立 `.vscode/` 結構與所有規範檔
- 若有 `-EnableRtkHints`，額外建立 `rtk-cheatsheet.md`，並把 RTK 條件式使用規則寫入 Copilot prompts
- 執行 `node kb.mjs rebuild` 初始化索引
- 執行 `node kb.mjs finish-check` 確認 taxonomy / health / repair-health 狀態
- 詢問是否重新載入 VSCode 視窗

**3. 填入專案特定資訊**

至少完成以下兩個檔案的「（請填入）」段落：

- `.vscode/copilot-instructions.md` — 技術棧、專案架構、測試規範
- `.vscode/knowledge/INDEX.md` — Quick Context、模組導航表

**4. 在 Copilot Chat 輸入 `/start-task` 開始使用**

---

## 既有知識庫升級

已經有 `.vscode/knowledge` 的專案，請使用 `update-kb.ps1`，不要用 `init-kb.ps1 -Force` 當升級流程。

預設 dry-run，只列出會調整哪些項目：

```powershell
.\update-kb.ps1 -ProjectRoot D:\www\your-project
```

確認後套用：

```powershell
.\update-kb.ps1 -ProjectRoot D:\www\your-project -Apply
```

若要替既有專案加入 RTK 選配提示，先 dry-run 檢查，再套用：

```powershell
.\update-kb.ps1 -ProjectRoot D:\www\your-project -EnableRtkHints
.\update-kb.ps1 -ProjectRoot D:\www\your-project -Apply -EnableRtkHints
```

`-EnableRtkHints` 只新增/更新 RTK 文件與 prompt 標記區塊；不安裝 RTK、不修改全域 shell hook，也不會讓 `rtk` 變成必要相依。若本機找不到 `rtk`，升級腳本只會提示 fallback，任務流程照常使用原命令。

若既有 `kb.mjs` 太舊，dry-run/apply 會產生 `scripts/kb.mjs.v3.2.candidate`，不覆蓋原檔。確認可接受模板替換後再執行：

```powershell
.\update-kb.ps1 -ProjectRoot D:\www\your-project -Apply -ForceTemplates
```

`update-kb.ps1` 只補齊 v3.1 架構和守門規則，不會覆蓋既有 `modules/quickref.md`、`traps/trap-NNN.md`、`changelog/YYYY-MM.md` 或手寫防呆原則。預設會備份被修改的檔案到 `.vscode/knowledge/backups/YYYYMMDD-HHmmss/`。

---

## opsx.bat / opsx.ps1

`init-kb.ps1` 與 `update-kb.ps1`（加 `-Apply`）在**專案根目錄**產生兩個 OpenSpec wrapper：

| 檔案 | 用途 |
|------|------|
| `opsx.bat` | Windows CMD / PowerShell 用；呼叫 `openspec` CLI 並正確保留 exit code |
| `opsx.ps1` | PowerShell 原生版；部分環境執行更穩定 |

### 為什麼放在專案根目錄？

`openspec` CLI 需要在 `.vscode/` 目錄下執行（讀取 `config.yaml`），wrapper 省去手動 `cd` 的麻煩：

    .\opsx status
    .\opsx propose --change my-feature
    .\opsx archive --change my-feature

### 為什麼建議不入版控？

1. **本機工具依賴**：`openspec` 是全域 npm 套件（`@fission-ai/openspec`），不同開發者版本可能不同或尚未安裝
2. **非協作必要**：KB + OpenSpec 是個人 AI 工作流程，不需強制所有協作者使用
3. **自動加 `.gitignore`**：`update-kb.ps1` 的 Section 7 會自動把 `opsx.bat` / `opsx.ps1` 加入 `.gitignore`

若團隊統一採用 OpenSpec 工作流程，可從 `.gitignore` 移除相關條目改為入版控。

---

## RTK 選配整合

RTK（Rust Token Killer）是 terminal / shell 輸出壓縮工具，適合把 `git`、搜尋、測試、build、lint、log、JSON 等高輸出命令整理成 AI 更容易讀取的摘要。此專案只把 RTK 當成**可選的 terminal 輸出壓縮層**：它不管理 OpenSpec、不管理 trap、不重建 facet / FTS5，也不取代 Agent Guard / repair closure。

### 是否適合目前架構？

適合，但只放在工具層：

| 面向 | 結論 |
|------|------|
| Knowledge Base | RTK 可降低 `kb.mjs` 周邊搜尋、測試、git diff 的輸出成本，但不取代 `.vscode/knowledge/` 的資料模型 |
| OpenSpec | RTK 可壓縮 `opsx` 或 git 相關輸出，但不產生 change artifacts，也不維護行為契約 |
| Agent Guard | RTK 失敗仍需走 `repair-record` / `repair-status`；不得把 raw output 或秘密寫入 runtime ledger |
| Windows | Native Windows 需用顯式 `rtk ...` 命令；WSL 才適合完整 hook / auto-rewrite |
| 風險控制 | 未安裝 RTK 時必須 fallback 原命令，不得阻擋任務完成 |

### 啟用方式

新專案初始化時啟用：

    .\init-kb.ps1 -EnableRtkHints

既有專案升級時啟用：

    .\update-kb.ps1 -ProjectRoot D:\www\your-project -EnableRtkHints
    .\update-kb.ps1 -ProjectRoot D:\www\your-project -Apply -EnableRtkHints

啟用後會產生或更新：

| 位置 | 說明 |
|------|------|
| `rtk-cheatsheet.md` | RTK 使用速查、Windows / WSL 差異、fallback 與保密規則；已存在時保留既有檔案 |
| `.vscode/copilot-instructions.md` | RTK 只作為選配 terminal 壓縮層的專案規範 |
| `.vscode/start-task.prompt.md` | 任務中高輸出 terminal 命令可優先用 RTK，但須可 fallback |
| `.vscode/start-plan.prompt.md` | 規劃階段只讀檢查時可用 RTK 壓縮搜尋 / git 輸出 |
| `.vscode/end-task.prompt.md` | `rtk gain` 僅作本機觀察，不是 finish gate |
| `.vscode/knowledge/.kb-version.json` | `update-kb.ps1 -EnableRtkHints` 會加入 `rtk-terminal-hints` feature marker |

### 安裝狀態檢查

PowerShell：

    Get-Command rtk -ErrorAction SilentlyContinue
    rtk --version

若找不到 RTK，不需要中止；直接使用原命令。

### Native Windows 使用方式

Native Windows 的 RTK filters 可用，但 auto-rewrite hook 有限制，建議明確加上 `rtk` 前綴：

    rtk git status
    rtk git diff
    rtk git log -n 10
    rtk grep "keyword" .
    rtk find "*.php" .
    rtk test npm test
    rtk err npm run build

若 RTK 輸出不足以判斷問題，改用原命令或 RTK verbose 取得完整上下文。若 RTK 命令失敗，先用 `repair-record` 記錄 sanitized failure，再決定 fallback 或改方法。

### WSL 使用方式

WSL 才適合 RTK 的完整 hook / auto-rewrite 流程。若團隊主要在 Windows PowerShell 執行，文件與 prompt 不應假設 hook 已啟用；仍以顯式 `rtk ...` 與原命令 fallback 為主。

### 隱私與 telemetry

RTK telemetry 是外部工具的 opt-in 功能。本專案不自動啟用 telemetry，不代替使用者同意，也不把 telemetry 或 `rtk gain` 當成任務完成條件。若未來要保存本機 RTK 成效，僅能保存 aggregate 摘要，例如總命令數、估計節省 token、工具類別分布；不得保存命令參數、檔名、secrets 或 raw stdout。

### 後續升版計劃

| 階段 | 內容 | 原則 |
|------|------|------|
| v3.2.1 | `-EnableRtkHints`、prompt 條件式規則、`rtk-cheatsheet.md` | 已實作；完全 opt-in |
| v3.3 | `kb.mjs rtk-check` doctor 指令 | 只讀檢查 RTK 狀態、Windows / WSL 模式、`rtk gain` 摘要 |
| v3.4 | RTK tee 與 repair closure 橋接 | 只讀取摘要；`repair-record` 仍只存 sanitized fingerprint |
| v3.5 | 本機 aggregate 成效摘要 | 不接外部 telemetry，不保存命令參數、檔名或秘密 |

---

## Copilot Chat 指令

初始化完成後，可在 VS Code Copilot Chat 中使用以下三個 `/` 指令：

### `/start-task` — 任務啟動（Agent Guard + 4 層階梯讀取）

執行流程：先讀 `agent/INDEX.md` 並執行 `start-check`，再依序讀 INDEX → modules/quickref → topics/INDEX → 命中的 topic → 必要的 trap，向使用者回報「涉及模組、命中主題、命中陷阱、操作守門摘要、待探索範圍」後接收任務。

### `/start-plan` — Plan 模式（讀取 → 計劃 → 等待確認）

執行流程：完成 Agent Guard 與 4 層階梯讀取後**只輸出計劃**（知識庫確認摘要、操作守門摘要、風險評估、執行計劃、預計異動檔案清單），等使用者回覆「**確認**」才開始執行。**嚴禁在確認前寫入任何檔案**。

### `/end-task` — 任務結束（強制歸檔）

執行流程：

1. 新增/編輯 trap fragment（**必帶 `--topics --symptoms`**）
2. 需要時更新 `topics-taxonomy.yml`
3. 需要時更新 `topics/{slug}.md` 的防呆原則段落（`<!-- AUTO_END -->` 之下）
4. 在 `changelog/YYYY-MM.md` 最上方新增一行
5. 若本任務發生工具/命令失敗，執行 `repair-status` / `repair-health`，重複失敗需升級成 operational trap 或標註 false positive
6. `node kb.mjs rebuild`
7. `node kb.mjs finish-check`（必須 0 errors）
8. 最後輸出 commit 訊息（純文字，不放 fenced code block）

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
| `node kb.mjs start-check --module=X --file=path.ext --query="keyword"` | 任務啟動必讀包，列出 Agent Guard、INDEX、quickref、topic 與 by-file 命中 |
| `node kb.mjs repair-preflight --tool=terminal --command="..." --intent="..."` | 執行前守門：阻擋 placeholder、PowerShell `&&`、危險 UTF-8 改寫與既知 operational trap |
| `node kb.mjs repair-record --tool=terminal --command="..." --exit-code=1 --error="摘要"` | 記錄 sanitized failure fingerprint；同一 fingerprint 重複會要求改方法或寫 trap |
| `node kb.mjs repair-status` | 列出 pending repeated failure |
| `node kb.mjs repair-health` | 任務收尾 repair gate，pending / invalid JSONL / secret-like 內容必須為 0 |
| `node kb.mjs health` | 健康檢查：id 唯一性、檔名 / id 一致、Markdown 連結、UTF-8 BOM、U+FFFD、settings、quickref 行數、index.jsonl 過期 |
| `node kb.mjs openspec-check [--strict]` | 驗證 OpenSpec 狀態：`specs/INDEX.md` 存在、未封存 change 狀況、spec 連結有效；預設 warning，`--strict` 升為 error |
| `node kb.mjs finish-check [--strict]` | 整合 `taxonomy lint` + `health` + `repair-health` + `openspec-check`，任務結束前必跑 |

---

## 腳本參數

初始化新專案：

```powershell
.\init-kb.ps1 [-Force] [-SkipOpenSpec] [-EnableRtkHints]
```

| 參數 | 說明 |
|------|------|
| （無參數） | 預設執行；已存在的知識庫檔案**不覆蓋**，`settings.json` 永遠不覆蓋 |
| `-Force` | 強制覆蓋初始化模板檔（`settings.json` 仍不覆蓋）；不建議當成既有知識庫升級方式 |
| `-SkipOpenSpec` | 略過 OpenSpec scaffold（不產生 `openspec/`、`opsx.bat`、`opsx.ps1`、`openspec-cheatsheet.md`）；適合純 KB 小型專案 |
| `-EnableRtkHints` | 產生 RTK 選配提示與 `rtk-cheatsheet.md`；不安裝 RTK、不修改全域 hook、未安裝時使用原命令 fallback |

升級既有知識庫：

```powershell
.\update-kb.ps1 [-ProjectRoot <path>] [-Apply] [-Backup:$false] [-ForceTemplates] [-SkipRebuild] [-SkipOpenSpec] [-EnableRtkHints] [-NoReloadPrompt]
```

| 參數 | 說明 |
|------|------|
| （無 `-Apply`） | dry-run，只列出會新增或修補的項目 |
| `-Apply` | 實際寫入檔案 |
| `-ProjectRoot` | 指定目標專案根目錄；預設目前工作目錄 |
| `-Backup:$false` | 關閉寫入前備份；預設會備份到 `.vscode/knowledge/backups/` |
| `-ForceTemplates` | 允許覆蓋 `kb.mjs` 等可執行模板；未指定時只產生 candidate |
| `-SkipRebuild` | 跳過 `rebuild` / `finish-check` |
| `-SkipOpenSpec` | 略過 OpenSpec 升級（Section 7）；保留純 v3.1 KB 行為 |
| `-EnableRtkHints` | 以 marker block 非破壞注入 RTK 選配提示，並建立 `rtk-cheatsheet.md`；RTK 不存在時只提示 fallback |
| `-NoReloadPrompt` | 不輸出 VS Code Reload Window 提示 |

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

### 為什麼需要 Agent Guard / repair closure？

靜態 health 只能檢查檔案是否一致，不能防止 Agent 反覆做同一個錯誤操作。v3.1 會把工具/命令失敗轉成 sanitized fingerprint，`repair-health` 在同一錯誤重複時擋下收尾，迫使 Agent 改方法，或把新陷阱升級成 operational trap。runtime ledger 只保存摘要與 hash，禁止保存 `.env`、token、密碼、完整 API key 或大段 stdout。

### 為什麼 RTK 是選配而不是核心相依？

RTK 解決的是「terminal 輸出太長」的問題，不解決「規格如何保存」「陷阱如何索引」「Agent 如何避免重複錯誤」。因此 RTK 放在工具層，只有使用者明確帶 `-EnableRtkHints` 時才產生提示；未安裝 RTK 時流程必須回退原命令並照常完成。這讓高輸出任務能省 token，同時不破壞 Windows / PowerShell 使用者的既有流程。

### 本機隔離，不干擾協作

知識庫存於 `.vscode/`，建議加入 `.gitignore`。每位開發者維護自己的本機 AI 知識庫，不強制所有協作者都使用相同的 AI 工作流程。

### 非破壞性設計

- 預設不覆蓋已存在的檔案（`-Force` 才會）
- `settings.json` 永遠不覆蓋，只在缺少必要設定時提示
- `topics/{slug}.md` 防呆原則段落、`changelog/YYYY-MM.md` 歷史列**只增不改**
- `update-kb.ps1` 預設 dry-run；套用時備份原檔，且不覆蓋 quickref、trap、changelog 與手寫防呆原則

---

## 系統需求

| 元件 | 最低版本 | 用途 |
|------|---------|------|
| PowerShell | 5.1 | 執行 `init-kb.ps1` |
| Node.js | 16+ | rebuild / new-trap / facets / topics / health / finish-check / repair-* / taxonomy / audit / bulk-tag |
| Node.js | 22.5+ | 額外啟用 `kb.mjs search` 全文檢索 |
| RTK | 選配 | 只有使用 `-EnableRtkHints` 時才需要；用於壓縮 terminal 輸出，缺少時 fallback 原命令 |
| VS Code + Copilot Chat | 最新 | 三個 `/` prompt 指令 |

> **無 npm 依賴**：`kb.mjs` 是純 Node ESM，使用 Node 內建模組（`fs/promises`、`path`、`url`、`sqlite`）。

---

## 注意事項

1. **首次使用必須重新載入 VS Code 視窗**：`Ctrl+Shift+P` → `Reload Window`，`/start-task` 等指令才會出現在 Copilot Chat 的 `/` 選單。
2. **編碼絕對禁止 PowerShell `Set-Content`**：CP950 會永久毀掉中文。改用 `kb.mjs new-trap` / Node `fs.writeFileSync` / VS Code 直接編輯。
3. **VS Code `files.encoding` 使用 `utf8`**：不是 `utf-8`，`health` 會檢查此設定。
4. **工具/命令失敗不要原樣重試**：先 `repair-record`，再 `repair-status`；重複失敗需新增/更新 operational trap。
5. **runtime ledger 禁止保存秘密**：不得寫入 `.env`、token、密碼、完整 API key 或大段 stdout。
6. **新增 trap 必須走 `kb.mjs new-trap`**：自動取下一個 id 避免衝突，自動校驗 topic 白名單。
7. **`traps/index.jsonl` / `by-*.json` / `agent/generated/*.json` / `topics/{slug}.md` 的 AUTO 區 / `fts.db` 全部禁止手動編輯**：rebuild 會覆寫。
8. **新主題 slug 必須先登記**：在 `topics-taxonomy.yml` 加條目後再用，否則 `taxonomy lint` 會擋。
9. **RTK 只可選配使用**：不得因未安裝 RTK 阻擋任務；不得把 RTK tee raw output、命令參數中的秘密或大段 stdout 寫入知識庫。

---

## 授權條款

見 [LICENSE](LICENSE)。
