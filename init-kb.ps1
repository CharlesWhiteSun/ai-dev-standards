#Requires -Version 5.1
<#
.SYNOPSIS
  VS Code 本機 AI 知識庫初始化腳本（v3.2：Knowledge Base + OpenSpec 雙軌 — 4 層階梯 + Agent Guard + repair closure + facets + topics + FTS5）

.DESCRIPTION
    在專案 .vscode/ 目錄下建立可隨知識量擴張的結構化 AI 協作知識庫：

        .vscode/
        ├── settings.json                     ← Copilot prompt 路徑設定
        ├── copilot-instructions.md           ← 單一規範來源（SSOT）
        ├── start-task.prompt.md              ← 任務啟動：4 層階梯讀取
        ├── start-plan.prompt.md              ← Plan 模式：讀取 → 計劃 → 等待確認
        ├── end-task.prompt.md                ← 任務結束：更新 KB + commit 訊息
        └── knowledge/
            ├── INDEX.md                      ← <80 行純導航
            ├── changelog/{YYYY-MM}.md        ← 當月變更歷程
            ├── agent/                        ← Agent 操作守門與 repeated failure 閉環
            ├── modules/                      ← 各模組 quickref（使用者自填）
            ├── traps/
            │   ├── topics-taxonomy.yml       ← 主題白名單
            │   ├── topics/                   ← 主題集群（rebuild 自動產生）
            │   └── trap-NNN.md               ← 陷阱片段（new-trap 自動產生）
            └── scripts/
                └── kb.mjs                    ← v3 CLI（repair / facets / topics / FTS）

    特色：
      - 主題化（topics）：把同類踩坑歸類，避免 AI 在 N 個 trap 中盲掃
      - Facet 索引（by-module/tag/topic/file/symptom.json）：精準切片
      - Agent Operational Guard：preflight、failure fingerprint、repair-health，避免重複錯誤消耗 token
      - SQLite FTS5 全文檢索：BM25 排序 + snippet 預覽（需 Node 22.5+）
      - 編碼安全：全部 UTF-8 without BOM；CLI 內建 health 檢測 BOM/U+FFFD

.NOTES
    執行方式（在專案根目錄）：
        .\init-kb.ps1

    Node 版本要求：
      - 16+：rebuild / new-trap / facets / topics / health 全部可用
      - 22.5+：SQLite FTS5 全文檢索（kb.mjs search）才會啟用，否則優雅降級

.PARAMETER Force
    覆蓋已存在的知識庫檔案（settings.json 永遠不覆蓋）。

.PARAMETER EnableRtkHints
    產生 RTK（Rust Token Killer）選配指引；不安裝 RTK、不修改全域 hook，且未安裝 RTK 時流程不失敗。
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipOpenSpec,
    [switch]$EnableRtkHints
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─────────────────────────────────────────────────────────────
# 工具函式
# ─────────────────────────────────────────────────────────────

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content,
        [switch]$Overwrite
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ((Test-Path $Path) -and -not $Overwrite) {
        $rel = $Path.Replace($projectRoot, '').TrimStart('\','/')
        Write-Host "  [略過] 已存在: $rel" -ForegroundColor Yellow
        return
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    $rel = $Path.Replace($projectRoot, '').TrimStart('\','/')
    Write-Host "  [建立] $rel" -ForegroundColor Green
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "── $Title" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────
# 路徑設定
# ─────────────────────────────────────────────────────────────

$projectRoot = $PSScriptRoot
$vscodeDir   = Join-Path $projectRoot '.vscode'
$kbDir       = Join-Path $vscodeDir 'knowledge'
$currentMonth = Get-Date -Format 'yyyy-MM'

$gitVersion = 'v3.2'
try {
    $gitDescribe = & git describe --tags --always --dirty 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitDescribe) { $gitVersion = $gitDescribe.Trim() }
} catch {}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   VS Code 本機 AI 知識庫初始化工具 $gitVersion" -ForegroundColor Cyan
Write-Host "   (v3.2：Knowledge Base + OpenSpec 雙軌流程)" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "專案根目錄 : $projectRoot"
Write-Host "知識庫目錄 : $kbDir"
Write-Host ""

if ($Force) {
    Write-Host "  [模式] 強制覆蓋已存在的知識庫檔案" -ForegroundColor Magenta
}
if ($SkipOpenSpec) {
    Write-Host "  [模式] 跳過 OpenSpec scaffold（僅建立知識庫結構）" -ForegroundColor Magenta
}
if ($EnableRtkHints) {
    Write-Host "  [模式] 啟用 RTK 選配提示（不安裝、不強制使用）" -ForegroundColor Magenta
}

$rtkCopilotBlock = @'
---

## 五、RTK terminal 輸出壓縮（選配）

RTK（Rust Token Killer）只作為 terminal / shell 輸出壓縮層，用來降低 AI 讀取 `git`、搜尋、測試、build、lint、log 等高輸出命令的 token 成本。RTK 不管理 OpenSpec、trap、taxonomy、facets 或 FTS5，不能取代 `.vscode/openspec/` 與 `.vscode/knowledge/`。

### 使用條件

1. 先確認本機可用：`Get-Command rtk -ErrorAction SilentlyContinue` 或 `rtk --version`。
2. 若 RTK 不存在，直接使用原命令；不得讓任務因缺少 RTK 失敗。
3. Native Windows 的 auto-rewrite hook 不完整，請使用顯式命令，例如 `rtk git status`、`rtk grep "pattern" .`、`rtk test npm test`。
4. WSL 可使用 RTK hook，但仍需保留原命令 fallback。
5. VS Code / Copilot 內建的讀檔與搜尋工具不會經過 RTK；只有 shell / terminal 命令會受影響。

### 建議優先使用情境

- `rtk git status`、`rtk git diff`、`rtk git log -n 10`
- `rtk grep "keyword" .`、`rtk find "*.php" .`、`rtk ls .`
- `rtk test <測試命令>`、`rtk err <建置或 lint 命令>`
- `rtk log path/to/log`、`rtk json file.json`

### 回退與保密

- 若 RTK 輸出不足以判斷問題，改用 RTK verbose 或原命令取得完整上下文。
- 若 RTK 命令失敗，不得原樣重試；依 Agent Guard 使用 `repair-record` / `repair-status` 記錄 sanitized failure。
- 不得把 RTK tee 的完整 raw output、`.env`、token、密碼、完整 API key 或大段 stdout 寫入知識庫。
- RTK telemetry 是外部工具的 opt-in 功能；本專案不自動啟用、不代替使用者同意。
'@

$rtkPromptBlock = @'
## RTK terminal hints（選配）

若本機可執行 `rtk --version`，對高輸出 shell 命令可優先使用 RTK：`rtk git status`、`rtk git diff`、`rtk grep "keyword" .`、`rtk test <測試命令>`、`rtk err <lint/build 命令>`。RTK 只壓縮 terminal 輸出，不取代 KB / OpenSpec，也不影響 VS Code 內建讀檔或搜尋工具。

若 RTK 不存在、輸出不足或命令失敗，立即回退原命令；失敗需依 Agent Guard 執行 `repair-record` / `repair-status`，不得把 raw output 或秘密寫入知識庫。
'@

$rtkEndTaskBlock = @'
## RTK 收尾檢查（選配）

若本任務使用過 RTK，可視需要執行 `rtk gain` 查看本機節省摘要。此資訊僅作觀察，不是 finish gate；未安裝 RTK 或 RTK 指令失敗不得阻擋任務完成。不得把 RTK tee raw output、命令參數中的秘密或大段 stdout 寫入知識庫。
'@

$rtkCheatsheet = @'
# RTK 指令速查（選配）

> RTK（Rust Token Killer）是 terminal 輸出壓縮工具，可減少 AI 讀取命令輸出的 token 成本。
> 本專案只產生使用提示，不會安裝 RTK、不會修改全域 hook，也不會讓 RTK 成為必要相依。

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
'@

# ─────────────────────────────────────────────────────────────
# 1. settings.json（永遠不覆蓋）
# ─────────────────────────────────────────────────────────────
Write-Section "1. settings.json（Copilot prompt 路徑）"

$settingsPath = Join-Path $vscodeDir 'settings.json'
if (-not (Test-Path $settingsPath)) {
    $settingsContent = @'
{
  "chat.promptFiles": true,
  "chat.promptFilesLocations": {
    ".vscode": true,
    ".vscode/prompts": true
  },
  "files.encoding": "utf8",
  "files.autoGuessEncoding": false,
  "files.insertFinalNewline": true,
  "files.trimTrailingWhitespace": true
}
'@
    Write-Utf8File -Path $settingsPath -Content $settingsContent
} else {
    $existing = Get-Content $settingsPath -Raw -Encoding UTF8
    $settingsWarnings = @()
    if ($existing -notmatch 'chat\.promptFilesLocations') {
        $settingsWarnings += '缺少 chat.promptFilesLocations 設定，請手動加入 .vscode / .vscode/prompts prompt 路徑。'
    } else {
        if ($existing -notmatch '"\.vscode"\s*:\s*true') { $settingsWarnings += 'chat.promptFilesLocations 缺少 .vscode = true。' }
        if ($existing -notmatch '"\.vscode/prompts"\s*:\s*true') { $settingsWarnings += 'chat.promptFilesLocations 缺少 .vscode/prompts = true。' }
    }
    if ($existing -notmatch '"chat\.promptFiles"\s*:\s*true') {
        $settingsWarnings += '缺少 chat.promptFiles = true。'
    }
    if ($existing -match '"files\.encoding"\s*:\s*"utf-8"') {
        $settingsWarnings += 'files.encoding 請使用 utf8（不是 utf-8）。'
    } elseif ($existing -notmatch '"files\.encoding"\s*:\s*"utf8"') {
        $settingsWarnings += '建議設定 files.encoding = utf8。'
    }

    if ($settingsWarnings.Count -eq 0) {
        Write-Host "  [略過] settings.json 已包含所需設定" -ForegroundColor Yellow
    } else {
        Write-Host "  [警告] settings.json 已存在，基於安全不自動覆蓋；請手動補齊下列設定：" -ForegroundColor Yellow
        foreach ($warning in $settingsWarnings) {
            Write-Host "         - $warning" -ForegroundColor Gray
        }
    }
}

# ─────────────────────────────────────────────────────────────
# 2. .vscode/copilot-instructions.md（單一規範來源）
# ─────────────────────────────────────────────────────────────
Write-Section "2. copilot-instructions.md（單一規範來源 SSOT）"

$copilotInstructions = @'
# GitHub Copilot 專案作業規範

> 此檔案為本專案的**單一規範真實來源**（Single Source of Truth），所有 prompt 檔案引用本檔而非重複定義。

---

## 一、技術棧

| 項目 | 版本 / 說明 |
|------|------------|
| 語言 | （請填入） |
| 框架 | （請填入） |
| 資料庫 | （請填入） |
| 測試框架 | （請填入） |

---

## 二、專案架構與命名慣例

（請依專案性質填入：分層架構、命名慣例、路由前綴、主要功能模組）

---

## 三、知識庫管理協議（單一真實來源）

### 知識庫結構 v3

`.vscode/knowledge/`（建議加入 `.gitignore`）：

    .vscode/knowledge/
    ├── INDEX.md                          ← <80 行純導航（第 1 層，AI 啟動必讀）
    ├── changelog/
    │   └── YYYY-MM.md                    ← 變更歷程（按月封存，唯一來源）
    ├── agent/                            ← Agent 操作守門與 runtime repair 閉環
    │   ├── INDEX.md                      ← preflight / failure record / retry rule 入口
    │   └── generated/                    ← repair guard facets（由 rebuild 產生）
    ├── modules/                          ← 第 2 層：模組強制讀
    │   └── {module}/quickref.md          ← <150 行；其餘細節分檔
    ├── traps/
    │   ├── topics-taxonomy.yml           ← 主題分類學白名單（人工維護）
    │   ├── topics/
    │   │   ├── INDEX.md                  ← 第 3 層：主題目錄（自動產生）
    │   │   └── {slug}.md                 ← 第 4 層：主題集群（AUTO 區自動，防呆原則手動）
    │   ├── trap-NNN.md                   ← 第 5 層：陷阱細節，YAML frontmatter
    │   ├── index.jsonl                   ← 機器可讀大表（自動）
    │   ├── by-module.json                ← facet：模組 → trap id 列表
    │   ├── by-tag.json                   ← facet：tag → trap id 列表
    │   ├── by-topic.json                 ← facet：主題 → trap id 列表
    │   ├── by-file.json                  ← facet：原始碼檔 → trap id 列表（修 bug 必查）
    │   ├── by-symptom.json               ← facet：症狀短語 → trap id 列表
    │   └── fts.db                        ← SQLite FTS5 全文檢索（自動，gitignore）
    └── scripts/
        └── kb.mjs                        ← Node CLI（rebuild/new-trap/taxonomy/facets/topics/audit/search/health/...）

> 詳情見 `.vscode/knowledge/INDEX.md`。

### 任務開始前（OpenSpec + 知識庫雙軌啟動）

#### Step 0 — OpenSpec 意圖確認（新功能 / 規格變更必做）

若任務屬於**新功能**、**規格變更**或**行為契約調整**：

1. 以 `/opsx:explore` 進入探索模式，與使用者釐清需求邊界與設計假設
2. 以 `/opsx:propose` 建立 OpenSpec change，產出 `.vscode/openspec/changes/{name}/` artifacts
3. 確認 `.vscode/openspec/specs/{module}/` 中是否已有對應規格（見 `.vscode/openspec/specs/INDEX.md`）；若有，讀取後才動手實作

若任務屬於**bug 修復**或**陷阱修補**，跳過 Step 0，直接從 Step 1 開始。

#### Step 1 — 知識庫預讀（4 層階梯）

1. 讀 [agent/INDEX.md](knowledge/agent/INDEX.md)，確認 preflight / failure record / retry rule
2. 執行 `node .vscode/knowledge/scripts/kb.mjs start-check --module=<Module> --file=path.ext --query="keyword"`（若參數不明，不得執行 placeholder）
3. 讀 [INDEX.md](knowledge/INDEX.md)（< 80 行）
4. 依任務讀 `modules/{m}/quickref.md`（< 150 行）
5. 讀 [traps/topics/INDEX.md](knowledge/traps/topics/INDEX.md)（主題目錄，掌握「這類問題以前發生過幾次」）
6. 命中相關主題 → 讀 `traps/topics/{slug}.md`（含相關 trap 表 + 防呆原則）；若防呆原則含 OpenSpec 連結，讀取該 spec.md
7. 必要時讀 `traps/trap-NNN.md`（細節）

替代/補充查詢：

- 模糊查詢 / 全文檢索：`node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"`
- 「我要修這個檔，以前踩過什麼坑？」→ 直接查 `traps/by-file.json`
- 操作守門：`node .vscode/knowledge/scripts/kb.mjs repair-preflight --tool=terminal --command="..." --intent="..."`
- 失敗記錄：`node .vscode/knowledge/scripts/kb.mjs repair-record --tool=terminal --command="..." --exit-code=1 --error="摘要"`
- 重複失敗檢查：`node .vscode/knowledge/scripts/kb.mjs repair-status`、`node .vscode/knowledge/scripts/kb.mjs repair-health`
- 其他 facet：`by-{module,tag,topic,symptom}.json`

向用戶回報：涉及模組、命中主題（topic slug）、命中陷阱編號、待探索範圍。

### Agent 操作錯誤閉環

- 執行 shell、搜尋 `.vscode` / `.vscode/knowledge`、批次改檔、或重跑曾失敗命令前，先使用 `repair-preflight`。
- 任一工具/命令失敗後，不得原樣重試；先用 `repair-record` 記錄 sanitized failure，再用 `repair-status` 檢查是否重複。
- 同一 fingerprint 第 2 次失敗即視為 pending repair；必須改方法，或新增/更新 operational trap。
- runtime ledger 僅保存摘要與 hash；禁止保存 `.env`、token、密碼、完整 API key 或大段 stdout。

### 任務結束後

依以下固定順序執行，不得跳過：

1. **新增/更新 trap fragment**：
   - 新陷阱：

         node .vscode/knowledge/scripts/kb.mjs new-trap `
           --module=X --title="..." `
           --topics=slug1,slug2 `
           --symptoms="症狀A;症狀B" `
           --files=path.ext --tests=tests/...

     再編輯生成的 `traps/trap-NNN.md` 補完症狀/根因/修正/測試
   - 既有陷阱補充：直接編輯對應 `traps/trap-NNN.md`，必要時更新 `topics:` / `symptoms:`
2. **若需新主題 slug** → 編輯 `traps/topics-taxonomy.yml` 新增條目（slug / name / desc / keywords）
3. **若主題防呆原則需更新** → 編輯 `traps/topics/{slug}.md` 的 `<!-- AUTO_END -->` 以下段落（AUTO 區會被覆寫，不要動）
4. **更新模組知識**（若涉及商務規則或設計變更）：編輯 `modules/{m}/quickref.md` 或細節分檔
5. **更新當月 changelog**：在 `changelog/YYYY-MM.md` 最上方新增一行 `| 日期 | 模組 | 摘要 | 異動檔案 | 備註 |`
6. **檢查 Agent 操作錯誤閉環**：若本任務發生工具/命令失敗或重複嘗試，執行：

    node .vscode/knowledge/scripts/kb.mjs repair-status
    node .vscode/knowledge/scripts/kb.mjs repair-health

  若有 unresolved repeated failure，必須新增/更新 operational trap 或標註 false positive。
7. **OpenSpec change 收尾**（若本任務有建立 OpenSpec change）：

   a. 確認所有 tasks 均已 completed（`.\.opsx status --change {name}`）
   b. 執行 `/opsx:archive` 封存 change（archive 後必須接著執行 rebuild）

   > 若任務僅為 bug 修復（無 OpenSpec change），跳過此步驟。

8. **重建索引並體檢**：

       node .vscode/knowledge/scripts/kb.mjs rebuild
     node .vscode/knowledge/scripts/kb.mjs finish-check

  `rebuild` 會自動：重建 `index.jsonl` + facet JSON + `topics/{slug}.md` AUTO 區 + `fts.db`。
  `finish-check` 必須 0 errors 才算結束。

9. **輸出 commit 訊息**（見下方「Commit 訊息格式」），此為任務最後一步。

> Token 不足時仍需最後提供 commit 訊息；若知識庫或驗證未完成，必須明確列為未完成事項。

### Commit 訊息格式（唯一定義）

以純文字段落輸出，禁止放入 fenced code block：

    {type}({模組}) 摘要說明

    問題:
    - 逐條說明

    變更:
    - 逐條說明

    測試:（僅撰寫測試時才提供）
    - 逐條說明

type 選項：`feat` / `fix` / `hotfix` / `refactor` / `chore` / `docs`

### 檔案編碼規範（防亂碼）

- 所有知識庫檔案必須為 **UTF-8 without BOM**
- 使用 VS Code 編輯器直接儲存，或透過 Node `fs.writeFileSync(..., 'utf8')`
- **禁止** PowerShell `Set-Content` / `Get-Content | Set-Content` / `(Get-Content) -replace`（以 CP950 覆寫，中文永久損毀）
- 健康度檢查：`node .vscode/knowledge/scripts/kb.mjs health`

### Trap fragment 格式（v3）

每筆 trap 為獨立檔案 `traps/trap-NNN.md`，固定 YAML frontmatter：

    ---
    id: 1
    title: 一句話摘要（< 80 字）
    module: SomeModule
    topics: [slug-a, slug-b]                              # 必填，必須在 topics-taxonomy.yml 白名單內
    symptoms:                                              # 可選，每筆症狀短語（協助 by-symptom 索引）
      - 症狀短語 A
      - 症狀短語 B
    related: [12, 34]                                      # 相關 trap id
    date: 2026-04-22
    status: fixed          # fixed | open | archived
    severity: bug          # bug | design | perf | doc
    tags: [tag-a]
    files:
      - src/path/to/file.ext
    tests:
      - tests/path/to/test.ext
    ---

    ## 症狀
    ## 根因
    ## 修正
    ## 測試

衍生產物（`index.jsonl` / `by-*.json` / `topics/{slug}.md` AUTO 區 / `fts.db`）由 `kb.mjs rebuild` 自動生成，**禁止手動編輯**。

### 禁止行為

1. 禁止 PowerShell `Set-Content` 寫入知識庫（CP950 編碼會永久毀掉中文）
2. 禁止在回應中使用 fenced code block 提供 SQL/程式碼（VS Code Chat 視窗會隱藏）
3. 禁止手動編輯 `traps/index.jsonl`、`by-*.json`、`topics/{slug}.md` 的 AUTO 區、`fts.db`（會被 rebuild 覆寫）
4. 新增 trap 必須走 `kb.mjs new-trap`（自動取下一個 id，避免衝突；自動校驗 topics 白名單）
5. 禁止使用未登記於 `topics-taxonomy.yml` 的 topic slug
6. 禁止 `/opsx:archive` 後未執行 `kb.mjs rebuild`（topics 防呆原則中的 spec 連結無法被 FTS 索引）
7. 禁止直接修改 `.vscode/openspec/specs/` 而不更新 `specs/INDEX.md`（Requirements 數量失同步）

---

### OpenSpec 與知識庫分工

| 維度 | OpenSpec（`.vscode/openspec/`）| 知識庫（`.vscode/knowledge/`）|
|------|----------------------|-------------------------------|
| **回答問題** | WHAT（行為契約、需求規格）| WHY/HOW-NOT-TO（根因、修正歷程）|
| **觸發時機** | 新功能 / 規格變更 | 踩坑、bug 修復 |
| **入口指令** | `/opsx:propose`、`/opsx:explore` | `kb.mjs new-trap` |
| **結束動作** | `/opsx:archive` → `kb.mjs rebuild` | `kb.mjs rebuild` |

---

## 四、測試規範

（請依語言 / 框架填入：測試層次、命名慣例、執行指令）

每次修改或新增功能，必須同步撰寫對應的測試。
'@

if ($EnableRtkHints) {
  $copilotInstructions = $copilotInstructions.TrimEnd() + "`n`n" + $rtkCopilotBlock.Trim() + "`n"
}

Write-Utf8File -Path (Join-Path $vscodeDir 'copilot-instructions.md') -Content $copilotInstructions -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 3. .vscode/start-task.prompt.md
# ─────────────────────────────────────────────────────────────
Write-Section "3. start-task.prompt.md"

$startTaskPrompt = @'
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
'@

if ($EnableRtkHints) {
  $startTaskPrompt = $startTaskPrompt.TrimEnd() + "`n`n" + $rtkPromptBlock.Trim() + "`n"
}

Write-Utf8File -Path (Join-Path $vscodeDir 'start-task.prompt.md') -Content $startTaskPrompt -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 4. .vscode/start-plan.prompt.md
# ─────────────────────────────────────────────────────────────
Write-Section "4. start-plan.prompt.md"

$startPlanPrompt = @'
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

## 步驟二：輸出執行計劃（只輸出文字，不執行）

### 知識庫確認摘要

| 項目 | 內容 |
|------|------|
| 涉及模組 | （列出） |
| 命中主題 | （topic slug，附 `topics/{slug}.md` 路徑） |
| 命中陷阱 | （Trap #N，附 fragment 路徑） |
| 操作守門 | （preflight 結果、pending repair、需改用的替代讀取方式） |
| 已有規則 | （從 quickref / topic 防呆原則摘錄） |
| 需探索 | （不確定的部分） |

### 風險評估

列出潛在風險與須注意的已知陷阱。

### 執行計劃

以 `[探索]` / `[新增]` / `[修改]` / `[測試]` / `[知識庫]` 標籤列出步驟。

### 預計異動檔案清單

| 操作 | 檔案路徑 | 說明 |
|------|---------|------|

## ⏸ 等待確認

- 「**確認**」→ 依計劃執行
- 「**調整 N**」→ 修改第 N 步
- 「**取消**」→ 中止

## 我的任務描述

（請在此描述你的任務內容）
'@

if ($EnableRtkHints) {
  $startPlanPrompt = $startPlanPrompt.TrimEnd() + "`n`n" + $rtkPromptBlock.Trim() + "`n"
}

Write-Utf8File -Path (Join-Path $vscodeDir 'start-plan.prompt.md') -Content $startPlanPrompt -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 5. .vscode/end-task.prompt.md
# ─────────────────────────────────────────────────────────────
Write-Section "5. end-task.prompt.md"

$endTaskPrompt = @'
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
'@

if ($EnableRtkHints) {
  $endTaskPrompt = $endTaskPrompt.TrimEnd() + "`n`n" + $rtkEndTaskBlock.Trim() + "`n"
}

Write-Utf8File -Path (Join-Path $vscodeDir 'end-task.prompt.md') -Content $endTaskPrompt -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 6. knowledge/INDEX.md
# ─────────────────────────────────────────────────────────────
Write-Section "6. knowledge/INDEX.md（4 層導航）"

$kbIndex = @'
# 專案知識庫索引

> AI 啟動任務時依「4 層階梯」讀取；詳細規範見 `.vscode/copilot-instructions.md`。

## Quick Context（30 秒）

**技術棧**：（請填入）
**程式碼路徑**：（請填入）
**測試**：（請填入）
**Agent 操作守門**：[agent/INDEX.md](agent/INDEX.md)
**OpenSpec 行為規格**：[../openspec/specs/INDEX.md](../openspec/specs/INDEX.md)（WHAT；新功能前必查）

## 4 層階梯閱讀路徑

  agent/INDEX.md  →  INDEX.md  →  modules/{m}/quickref.md  →  traps/topics/INDEX.md  →  traps/topics/{slug}.md  →  traps/trap-NNN.md

## 模組導航（第 2 層）

| 模組 | quickref | 一句話 |
|------|----------|--------|
| （請填入） | （路徑） | （說明） |

## 已知陷阱（第 3 / 4 / 5 層）

- **第 3 層**：[traps/topics/INDEX.md](traps/topics/INDEX.md)（主題目錄，看「這類問題以前發生過幾次」）
- **第 4 層**：[traps/topics/{slug}.md](traps/topics/)（主題集群，含相關 trap 表 + 防呆原則）
- **第 5 層**：[traps/trap-NNN.md](traps/)（細節：症狀/根因/修正/測試）

主題分類學定義見 [traps/topics-taxonomy.yml](traps/topics-taxonomy.yml)（白名單，禁止繞過）。

## 多種查詢方式

| 場景 | 工具 |
|------|------|
| 模糊關鍵字 / 全文檢索 | `node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"`（SQLite FTS5） |
| 任務啟動必讀包 | `node .vscode/knowledge/scripts/kb.mjs start-check --module=<Module> --file=path.ext --query="keyword"` |
| 執行前操作守門 | `node .vscode/knowledge/scripts/kb.mjs repair-preflight --tool=terminal --command="..."` |
| 失敗記錄 / 重複檢查 | `repair-record` / `repair-status` / `repair-health` |
| 我要修這個檔，以前踩過什麼坑？ | 查 [traps/by-file.json](traps/by-file.json) |
| 某主題的所有 trap | 查 [traps/by-topic.json](traps/by-topic.json) 或讀 `topics/{slug}.md` |
| 某模組的所有 trap | 查 [traps/by-module.json](traps/by-module.json) |
| 某 tag 的所有 trap | 查 [traps/by-tag.json](traps/by-tag.json) |
| 症狀關鍵字命中 | 查 [traps/by-symptom.json](traps/by-symptom.json) |
| 機器可讀全表 | 讀 [traps/index.jsonl](traps/index.jsonl)（每行一個 JSON） |

## 變更歷程

按月封存於 [changelog/](changelog/)。任務結束時於當月檔案最上方加一行。

## 工具（CLI）

工具位於 [scripts/kb.mjs](scripts/kb.mjs)（Node 純 ESM）。

| 命令 | 用途 |
|------|------|
| `kb.mjs new-trap --module=X --title="..." --topics=slug --symptoms="A;B"` | 建新 trap fragment |
| `kb.mjs rebuild` | 重建 index.jsonl + facets + topics + fts.db |
| `kb.mjs taxonomy lint` | 校驗所有 trap 的 topics 都在白名單內 |
| `kb.mjs taxonomy stats` | 列出每個 topic 的 trap 覆蓋數 |
| `kb.mjs search "<query>"` | FTS5 全文檢索（需 Node 22.5+） |
| `kb.mjs start-check` | 任務啟動必讀包與 Agent Repair Context |
| `kb.mjs repair-preflight` | 執行 shell / 搜尋 / 改檔前的操作守門 |
| `kb.mjs repair-record` / `repair-status` / `repair-health` | runtime failure fingerprint 閉環 |
| `kb.mjs finish-check` | 任務結束總守門（taxonomy + health + repair-health + audit） |
| `kb.mjs facets` / `topics` | 只重建單項 |
| `kb.mjs audit` | 找拆分候選（多議題混在一個 trap） |
| `kb.mjs health` | 檢查 id / 編碼 / quickref 行數 / topics 對應 |

## 任務結束 Checklist

依序執行（缺一不可）：

1. 新增/編輯 trap fragment（必帶 `--topics --symptoms`），需要時補 taxonomy.yml
2. 在當月 `changelog/YYYY-MM.md` 最上方新增一行
3. 若本任務有失敗或重複嘗試，執行 `repair-status` / `repair-health`
4. `node .vscode/knowledge/scripts/kb.mjs rebuild`
5. `node .vscode/knowledge/scripts/kb.mjs finish-check`（必須 0 errors）
6. 最後輸出 commit 訊息（純文字，不放 fenced code block）
'@

Write-Utf8File -Path (Join-Path $kbDir 'INDEX.md') -Content $kbIndex -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 7. changelog/{當月}.md
# ─────────────────────────────────────────────────────────────
Write-Section "7. changelog/$currentMonth.md"

$changelogContent = @"
# 變更歷程 — $currentMonth

> 每次任務結束時，於本表**最上方**插入一行（最新者在上）。

| 日期 | 模組 | 摘要 | 異動檔案 | 備註 |
|------|------|------|---------|------|
"@

$changelogPath = Join-Path $kbDir "changelog\$currentMonth.md"
Write-Utf8File -Path $changelogPath -Content $changelogContent -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 8. agent/INDEX.md（Agent 操作守門）
# ─────────────────────────────────────────────────────────────
Write-Section "8. agent/INDEX.md（Agent 操作守門）"

$agentIndex = @'
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
'@

Write-Utf8File -Path (Join-Path $kbDir 'agent\INDEX.md') -Content $agentIndex -Overwrite:$Force
Write-Utf8File -Path (Join-Path $kbDir 'agent\generated\.gitkeep') -Content "" -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 9. modules/.gitkeep
# ─────────────────────────────────────────────────────────────
Write-Section "9. modules/（空目錄，使用者自填）"

Write-Utf8File -Path (Join-Path $kbDir 'modules\.gitkeep') -Content "" -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 10. traps/topics-taxonomy.yml（白名單）
# ─────────────────────────────────────────────────────────────
Write-Section "10. traps/topics-taxonomy.yml（白名單）"

$taxonomyContent = @'
# 主題分類學（Topics Taxonomy）— 知識庫 v3 主題白名單
#
# 規則：
#   1. 每個 trap 的 frontmatter `topics:` 欄位只能使用本檔登記的 slug
#   2. 新增前先 grep 既有 slug 確認無重複；命名一律 kebab-case
#   3. 變更後執行：node .vscode/knowledge/scripts/kb.mjs taxonomy lint
#
# 欄位說明：
#   slug      唯一短代號（kebab-case），會出現在 trap.frontmatter.topics 與檔名 topics/{slug}.md
#   name      顯示名稱（中英文皆可）
#   desc      一句話定義
#   keywords  協助 AI 自動命中本主題的關鍵字陣列

topics:
  - slug: agent-runtime-failure
    name: Agent runtime failure 閉環
    desc: AI Agent 工具/命令失敗後需記錄 fingerprint、停止原樣重試，並升級為 repair guard 或 trap
    keywords: [Agent, repair-record, repair-health, fingerprint, repeated failure]

  - slug: tool-search-visibility
    name: 工具搜尋可見性與 .vscode 讀取
    desc: `.vscode`、local knowledge 或 gitignored 路徑可能被一般搜尋忽略，需改用直接讀取、列目錄或 include ignored
    keywords: [.vscode, search, include ignored, read_file, list_dir, knowledge]

  - slug: command-preflight
    name: 命令執行前 preflight
    desc: 已知錯誤或高風險 shell 指令需先由 repair-preflight 檢查，避免 Agent 原樣重複執行
    keywords: [preflight, command, PowerShell, terminal, retry]

  - slug: prompt-agent-compat
    name: VS Code prompt agent 相容性
    desc: VS Code prompt frontmatter 的 agent 值需以本機診斷為準，例如某些環境使用 Plan 而非 lowercase plan
    keywords: [prompt, agent, Plan, plan, frontmatter]

  - slug: vscode-settings-encoding
    name: VS Code settings encoding id
    desc: VS Code settings 的 files.encoding 必須使用合法 encoding id，例如 utf8，而不是 utf-8
    keywords: [settings.json, files.encoding, utf8, utf-8, VS Code]

  - slug: powershell-encoding
    name: PowerShell UTF-8 編碼損毀
    desc: PowerShell Set-Content / Get-Content 以系統 ANSI 處理 UTF-8 檔案，導致中文 Blade/MD 檔案損毀
    keywords: [PowerShell, Set-Content, UTF-8, CP950, BOM, 編碼損毀]

  - slug: misc
    name: 雜項
    desc: 尚未分類或一次性的陷阱
    keywords: []
'@

Write-Utf8File -Path (Join-Path $kbDir 'traps\topics-taxonomy.yml') -Content $taxonomyContent -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 11. traps/topics/.gitkeep
# ─────────────────────────────────────────────────────────────
Write-Section "11. traps/topics/（rebuild 後自動填充）"

Write-Utf8File -Path (Join-Path $kbDir 'traps\topics\.gitkeep') -Content "" -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 12. scripts/kb.mjs（v3.1 CLI；FTS 採 node:sqlite）
# ─────────────────────────────────────────────────────────────
Write-Section "12. scripts/kb.mjs（v3.1 CLI）"

$kbScript = @'
#!/usr/bin/env node
// 知識庫 v3 CLI — 主題化 + facet + FTS 整合
// 純 Node ESM、無外部相依（FTS 採 Node 22.5+ 內建 node:sqlite，不可用時優雅降級）。
// Commands: rebuild | new-trap | new-decision | health | taxonomy | audit | facets | topics | search | bulk-tag | start-check | finish-check | repair-*

import { readFile, writeFile, readdir, mkdir, unlink } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const KB_ROOT = path.resolve(__dirname, '..');
const TRAPS_DIR = path.join(KB_ROOT, 'traps');
const TOPICS_DIR = path.join(TRAPS_DIR, 'topics');
const TRAPS_INDEX = path.join(TRAPS_DIR, 'index.jsonl');
const TAXONOMY = path.join(TRAPS_DIR, 'topics-taxonomy.yml');
const MODULES_DIR = path.join(KB_ROOT, 'modules');
const AGENT_DIR = path.join(KB_ROOT, 'agent');
const AGENT_GENERATED_DIR = path.join(AGENT_DIR, 'generated');
const AGENT_GUARDS = path.join(AGENT_GENERATED_DIR, 'guards.json');
const AGENT_BY_COMMAND = path.join(AGENT_GENERATED_DIR, 'by-command.json');
const AGENT_BY_TOOL = path.join(AGENT_GENERATED_DIR, 'by-tool.json');
const AGENT_BY_ERROR = path.join(AGENT_GENERATED_DIR, 'by-error.json');
const AGENT_BY_PATH = path.join(AGENT_GENERATED_DIR, 'by-path.json');
const FTS_DB = path.join(TRAPS_DIR, 'fts.db');
const PROJECT_ROOT = path.resolve(KB_ROOT, '..', '..');
const VSCODE_ROOT = path.resolve(KB_ROOT, '..');
const DEFAULT_RUNTIME_DIR = path.join(KB_ROOT, 'runtime');
const REPAIR_RETRY_LIMIT = 2;
const REPAIR_FAILURES_FILE = 'failures.jsonl';
const REPAIR_FALSE_POSITIVES_FILE = 'false-positives.json';
const AGENT_GUARD_FIELDS = ['bad_commands', 'bad_tools', 'bad_paths', 'error_patterns', 'preferred_actions', 'deny_when', 'recover_with'];

// 嘗試載入 node:sqlite（Node 22.5+），不可用時優雅降級
let DatabaseSync = null;
let sqliteUnavailableReason = '';
try {
  ({ DatabaseSync } = await import('node:sqlite'));
} catch (e) {
  sqliteUnavailableReason = e.message;
}
// 抑制 SQLite ExperimentalWarning（Node 22.5–23.x）
process.on('warning', (w) => {
  if (w.name === 'ExperimentalWarning' && /SQLite/i.test(w.message)) return;
  console.warn(w);
});

// =================================================================
//  Frontmatter parser/serializer  — 支援 block 字串列表 + CJK
// =================================================================
const FM_RE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;

function parseFrontmatter(text) {
  const m = text.match(FM_RE);
  if (!m) return { data: {}, body: text };
  const data = {};
  const lines = m[1].split(/\r?\n/);
  let i = 0;
  while (i < lines.length) {
    const raw = lines[i];
    if (!raw.trim() || raw.trim().startsWith('#')) { i++; continue; }
    const km = raw.match(/^([A-Za-z_][\w-]*):\s*(.*)$/);
    if (!km) { i++; continue; }
    const key = km[1];
    const inline = km[2];
    if (inline === '' || inline === undefined) {
      const items = [];
      i++;
      while (i < lines.length) {
        const L = lines[i];
        if (/^[A-Za-z_][\w-]*:/.test(L)) break;
        const dm = L.match(/^\s+-\s+(.*)$/);
        if (dm) { items.push(unquote(dm[1].trim())); i++; continue; }
        if (!L.trim()) { i++; continue; }
        break;
      }
      data[key] = items;
    } else if (inline.startsWith('[') && inline.endsWith(']')) {
      const inner = inline.slice(1, -1).trim();
      data[key] = inner ? splitCsv(inner).map(unquote) : [];
      i++;
    } else if (/^-?\d+$/.test(inline)) {
      data[key] = Number(inline);
      i++;
    } else {
      data[key] = unquote(inline);
      i++;
    }
  }
  return { data, body: text.slice(m[0].length) };
}

function splitCsv(s) {
  const out = []; let cur = ''; let q = null;
  for (const ch of s) {
    if (q) { if (ch === q) { q = null; } else { cur += ch; } continue; }
    if (ch === '"' || ch === "'") { q = ch; continue; }
    if (ch === ',') { out.push(cur.trim()); cur = ''; continue; }
    cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

function unquote(s) { return s.replace(/^["']|["']$/g, ''); }

function stringifyFrontmatter(data) {
  const lines = ['---'];
  for (const [k, v] of Object.entries(data)) {
    if (v === null || v === undefined) continue;
    if (Array.isArray(v)) {
      if (v.length === 0) { lines.push(`${k}: []`); continue; }
      const allShortSafe = v.every(x => typeof x === 'string' && !x.includes('\n') && x.length < 80 && !/[:#\[\]&*!|>'"%@`,]/.test(x));
      if (allShortSafe) {
        lines.push(`${k}: [${v.map(s => /[\s]/.test(s) ? JSON.stringify(s) : s).join(', ')}]`);
      } else {
        lines.push(`${k}:`);
        for (const item of v) lines.push(`  - ${needsQuote(item) ? JSON.stringify(String(item)) : String(item)}`);
      }
    } else if (typeof v === 'number') {
      lines.push(`${k}: ${v}`);
    } else {
      const s = String(v);
      lines.push(needsQuote(s) ? `${k}: ${JSON.stringify(s)}` : `${k}: ${s}`);
    }
  }
  lines.push('---', '');
  return lines.join('\n');
}

function needsQuote(s) {
  return /^[\s>!|*&%@`]/.test(s) || /[:#\[\]"']/.test(s) || s === '' || /^(true|false|null|yes|no)$/i.test(s) || /^-?\d/.test(s);
}

// =================================================================
//  File helpers
// =================================================================
async function ensureDir(d) { await mkdir(d, { recursive: true }); }
async function readUtf8(p) {
  const buf = await readFile(p);
  if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) return buf.slice(3).toString('utf8');
  return buf.toString('utf8');
}
async function writeUtf8(p, content) {
  await ensureDir(path.dirname(p));
  await writeFile(p, content, { encoding: 'utf8' });
}
async function listMd(dir) {
  if (!existsSync(dir)) return [];
  const e = await readdir(dir, { withFileTypes: true });
  return e.filter(x => x.isFile() && x.name.endsWith('.md')).map(x => path.join(dir, x.name));
}
function pad(n, w = 3) { return String(n).padStart(w, '0'); }

function sha256(text) {
  return createHash('sha256').update(String(text || '')).digest('hex');
}

function normalizeCommand(command) {
  return String(command || '')
    .replace(/(['"])(?:[A-Za-z]:)?[\\/][^'"\s]+\1/g, '$1<path>$1')
    .replace(/(?:[A-Za-z]:)?[\\/][^\s]+/g, '<path>')
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizePathValue(value) {
  if (!value) return '';
  const normalized = normalizeFile(value);
  const root = PROJECT_ROOT.replace(/[\\/]+/g, '/').toLowerCase();
  return normalized.toLowerCase().startsWith(root) ? normalized.slice(root.length).replace(/^\//, '') : normalized;
}

function redactSensitive(text) {
  return String(text || '')
    .replace(/([A-Za-z_][A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|KEY|PWD)[A-Za-z0-9_]*\s*[=:]\s*)[^\s'";]+/gi, '$1<redacted>')
    .replace(/Bearer\s+[A-Za-z0-9._~+\-/]+=*/gi, 'Bearer <redacted>')
    .replace(/sk-[A-Za-z0-9]{12,}/gi, 'sk-<redacted>')
    .replace(/[A-Za-z0-9_\-]{24,}\.[A-Za-z0-9_\-]{24,}\.[A-Za-z0-9_\-]{24,}/g, '<jwt-redacted>')
    .slice(0, 400);
}

function hasPlaceholder(value) {
  return /<[^>]+>|\{[^}]+\}|\$\{[^}]+\}|\bTODO\b|模組|檔案|關鍵字/i.test(String(value || ''));
}

function runtimeDir() {
  const env = process.env.KB_RUNTIME_DIR;
  return env ? path.resolve(env) : DEFAULT_RUNTIME_DIR;
}

async function appendJsonl(file, row) {
  await ensureDir(path.dirname(file));
  let prefix = '';
  if (existsSync(file)) {
    const old = readFileSync(file, 'utf8');
    prefix = old && !old.endsWith('\n') ? '\n' : '';
  }
  await writeFile(file, prefix + JSON.stringify(row) + '\n', { encoding: 'utf8', flag: 'a' });
}

function readJsonlIfExists(file) {
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8')
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line, index) => {
      try { return JSON.parse(line); }
      catch { return { invalid: true, line: index + 1, raw: line }; }
    });
}

function readJsonIfExists(file, fallback) {
  if (!existsSync(file)) return fallback;
  try { return JSON.parse(readFileSync(file, 'utf8')); }
  catch { return fallback; }
}

function makeFingerprint(opts) {
  const tool = String(opts.tool || 'unknown').toLowerCase();
  const cwd = normalizePathValue(opts.cwd || PROJECT_ROOT) || '.';
  const command = normalizeCommand(opts.command || '');
  const targetPath = normalizePathValue(opts.path || '');
  const exitCode = String(opts.exitCode ?? opts['exit-code'] ?? '');
  const errorSummary = redactSensitive(opts.error || opts.stderr || opts.message || '');
  const errorHash = errorSummary ? sha256(errorSummary).slice(0, 16) : '';
  const intent = String(opts.intent || '').trim();
  const source = [tool, cwd, command, targetPath, exitCode, errorHash, intent].join('|');
  return {
    id: sha256(source).slice(0, 20),
    tool,
    cwd,
    command,
    path: targetPath,
    exit_code: exitCode,
    error_hash: errorHash,
    intent,
  };
}

function groupByFingerprint(records) {
  const map = new Map();
  for (const record of records.filter(x => !x.invalid)) {
    const id = record.fingerprint?.id || record.id;
    if (!id) continue;
    if (!map.has(id)) map.set(id, []);
    map.get(id).push(record);
  }
  return map;
}

function normalizeGuardValue(value) {
  return String(value || '').trim().toLowerCase();
}

function guardMatches(value, pattern) {
  const v = normalizeGuardValue(value);
  const p = normalizeGuardValue(pattern);
  return !!p && (v === p || v.includes(p));
}

function extractListFromBody(body, heading) {
  const lines = String(body || '').split(/\r?\n/);
  const headingRe = new RegExp(`^##\\s+${heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*$`, 'i');
  const start = lines.findIndex(line => headingRe.test(line));
  if (start < 0) return [];
  const section = [];
  for (let i = start + 1; i < lines.length; i++) {
    if (/^##\s+/.test(lines[i])) break;
    section.push(lines[i]);
  }
  return section
    .map(line => line.match(/^\s*[-*]\s+(.+?)\s*$/)?.[1])
    .filter(Boolean);
}

// =================================================================
//  Taxonomy loader  — 簡單 YAML 解析
// =================================================================
function loadTaxonomy() {
  if (!existsSync(TAXONOMY)) return { topics: [], slugs: new Set() };
  const text = readFileSync(TAXONOMY, 'utf8');
  const topics = [];
  let cur = null;
  for (const raw of text.split(/\r?\n/)) {
    if (raw.startsWith('#') || !raw.trim()) continue;
    const startM = raw.match(/^\s*-\s*slug:\s*(.+?)\s*$/);
    if (startM) { if (cur) topics.push(cur); cur = { slug: startM[1].trim() }; continue; }
    if (!cur) continue;
    const kv = raw.match(/^\s+(\w+):\s*(.+?)\s*$/);
    if (!kv) continue;
    const [, k, v] = kv;
    if (k === 'keywords') {
      cur.keywords = v.startsWith('[') ? splitCsv(v.slice(1, -1)).map(unquote) : [];
    } else {
      cur[k] = unquote(v);
    }
  }
  if (cur) topics.push(cur);
  return { topics, slugs: new Set(topics.map(t => t.slug)) };
}

// =================================================================
//  Trap loader
// =================================================================
async function loadAllTraps() {
  const files = (await listMd(TRAPS_DIR)).filter(f => /trap-\d+\.md$/.test(path.basename(f)));
  const traps = [];
  for (const f of files) {
    const text = await readUtf8(f);
    const { data, body } = parseFrontmatter(text);
    traps.push({ file: path.basename(f), body, ...data });
  }
  return traps.sort((a, b) => (a.id || 0) - (b.id || 0));
}

// =================================================================
//  rebuild  — index.jsonl + facets + topics + (optional) FTS
// =================================================================
async function cmdRebuild(args) {
  const opts = parseOpts(args);
  const traps = await loadAllTraps();
  const seen = new Set();
  const errors = [];
  const lines = [];
  for (const t of traps) {
    if (typeof t.id !== 'number') { errors.push(`${t.file}: missing numeric id`); continue; }
    if (seen.has(t.id)) { errors.push(`duplicate id ${t.id} in ${t.file}`); continue; }
    seen.add(t.id);
    const expected = `trap-${pad(t.id)}.md`;
    if (t.file !== expected) errors.push(`${t.file}: filename should be ${expected}`);
    lines.push(JSON.stringify({
      id: t.id,
      title: t.title || '',
      module: t.module || '',
      topics: t.topics || [],
      symptoms: t.symptoms || [],
      related: t.related || [],
      date: t.date || '',
      status: t.status || 'fixed',
      severity: t.severity || '',
      tags: t.tags || [],
      files: t.files || [],
      file: t.file,
    }));
  }
  await writeUtf8(TRAPS_INDEX, lines.join('\n') + (lines.length ? '\n' : ''));
  console.log(`[rebuild] wrote ${lines.length} entries to traps/index.jsonl`);

  await buildFacets(traps);
  await buildAgentGuardFacets(traps);
  await buildTopicPages(traps);

  if (opts.fts !== false) {
    try { await buildFtsIndex(traps); }
    catch (e) { errors.push('fts build failed: ' + e.message); }
  }

  if (errors.length) {
    console.error('[rebuild] errors:'); for (const e of errors) console.error('  ' + e);
    process.exitCode = 1;
  }
}

// =================================================================
//  facets  — by-module / by-tag / by-topic / by-file / by-symptom
// =================================================================
async function cmdFacets() { await buildFacets(await loadAllTraps()); }

async function buildFacets(traps) {
  const active = traps.filter(t => (t.status || 'fixed') !== 'archived');
  const byModule = {}, byTag = {}, byTopic = {}, byFile = {}, bySymptom = {};
  const push = (m, k, id) => { if (!k) return; (m[k] = m[k] || []).push(id); };
  for (const t of active) {
    push(byModule, t.module, t.id);
    for (const x of t.tags || []) push(byTag, x, t.id);
    for (const x of t.topics || []) push(byTopic, x, t.id);
    for (const f of t.files || []) push(byFile, normalizeFile(f), t.id);
    for (const s of t.symptoms || []) push(bySymptom, normalizeSymptom(s), t.id);
  }
  for (const m of [byModule, byTag, byTopic, byFile, bySymptom]) {
    for (const k of Object.keys(m)) m[k] = [...new Set(m[k])].sort((a, b) => a - b);
  }
  await writeUtf8(path.join(TRAPS_DIR, 'by-module.json'), JSON.stringify(byModule, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-tag.json'), JSON.stringify(byTag, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-topic.json'), JSON.stringify(byTopic, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-file.json'), JSON.stringify(byFile, null, 2) + '\n');
  await writeUtf8(path.join(TRAPS_DIR, 'by-symptom.json'), JSON.stringify(bySymptom, null, 2) + '\n');
  console.log(`[facets] modules=${Object.keys(byModule).length} tags=${Object.keys(byTag).length} topics=${Object.keys(byTopic).length} files=${Object.keys(byFile).length} symptoms=${Object.keys(bySymptom).length}`);
}

function normalizeFile(f) {
  return String(f).trim().replace(/[\\/]+/g, '/').replace(/^\.\//, '');
}
function normalizeSymptom(s) {
  return String(s).trim().replace(/\s+/g, ' ').slice(0, 60);
}

async function buildAgentGuardFacets(traps) {
  await ensureDir(AGENT_GENERATED_DIR);
  const operational = traps.filter(t => (t.status || 'fixed') !== 'archived' && (t.tags || []).includes('operational'));
  const guards = [];
  for (const trap of operational) {
    const guard = {
      id: trap.id,
      file: trap.file,
      title: trap.title || '',
      topics: trap.topics || [],
      severity: trap.severity || '',
    };
    for (const field of AGENT_GUARD_FIELDS) {
      const value = trap[field];
      guard[field] = Array.isArray(value) ? value : [];
    }
    guard.body_commands = extractListFromBody(trap.body || '', 'Bad Commands');
    guard.body_paths = extractListFromBody(trap.body || '', 'Bad Paths');
    guard.body_errors = extractListFromBody(trap.body || '', 'Error Patterns');
    guards.push(guard);
  }

  const byCommand = {}, byTool = {}, byError = {}, byPath = {};
  const push = (map, key, id) => {
    const normalized = normalizeGuardValue(key);
    if (!normalized) return;
    (map[normalized] = map[normalized] || []).push(id);
  };

  for (const guard of guards) {
    for (const item of [...guard.bad_commands, ...guard.body_commands]) push(byCommand, item, guard.id);
    for (const item of guard.bad_tools || []) push(byTool, item, guard.id);
    for (const item of [...guard.error_patterns, ...guard.body_errors]) push(byError, item, guard.id);
    for (const item of [...guard.bad_paths, ...guard.body_paths]) push(byPath, item, guard.id);
  }

  for (const map of [byCommand, byTool, byError, byPath]) {
    for (const key of Object.keys(map)) map[key] = [...new Set(map[key])].sort((a, b) => a - b);
  }

  await writeUtf8(AGENT_GUARDS, JSON.stringify(guards, null, 2) + '\n');
  await writeUtf8(AGENT_BY_COMMAND, JSON.stringify(byCommand, null, 2) + '\n');
  await writeUtf8(AGENT_BY_TOOL, JSON.stringify(byTool, null, 2) + '\n');
  await writeUtf8(AGENT_BY_ERROR, JSON.stringify(byError, null, 2) + '\n');
  await writeUtf8(AGENT_BY_PATH, JSON.stringify(byPath, null, 2) + '\n');
  console.log(`[agent] guards=${guards.length}`);
}

// =================================================================
//  topics  — 自動產生 topics/{slug}.md + topics/INDEX.md
//  AUTO 區由 <!-- AUTO_BEGIN --> ... <!-- AUTO_END --> 包覆，僅覆寫此區
// =================================================================
async function cmdTopics() { await buildTopicPages(await loadAllTraps()); }

const AUTO_BEGIN = '<!-- AUTO_BEGIN -->';
const AUTO_END = '<!-- AUTO_END -->';

async function buildTopicPages(traps) {
  const { topics } = loadTaxonomy();
  const active = traps.filter(t => (t.status || 'fixed') !== 'archived');
  const byTopic = new Map();
  for (const t of active) for (const slug of t.topics || []) {
    if (!byTopic.has(slug)) byTopic.set(slug, []);
    byTopic.get(slug).push(t);
  }
  await ensureDir(TOPICS_DIR);
  for (const topic of topics) {
    const list = (byTopic.get(topic.slug) || []).sort((a, b) => a.id - b.id);
    const tableRows = list.length
      ? list.map(t => `| ${t.id} | ${t.title || ''} | ${(t.files || []).slice(0, 2).join(', ')} | [→](../trap-${pad(t.id)}.md) |`).join('\n')
      : '| - | _尚無相關 trap_ | - | - |';
    const auto = [
      AUTO_BEGIN,
      `**定義**：${topic.desc || ''}`,
      `**關鍵字**：${(topic.keywords || []).join(', ')}`,
      `**相關 trap 數**：${list.length}`,
      '',
      '## 相關 Trap',
      '',
      '| id | 一句話 | 主要檔案 | 連結 |',
      '|----|--------|---------|------|',
      tableRows,
      AUTO_END,
    ].join('\n');
    const file = path.join(TOPICS_DIR, `${topic.slug}.md`);
    let manualTail = '';
    if (existsSync(file)) {
      const old = await readUtf8(file);
      const m = old.match(/<!-- AUTO_END -->([\s\S]*)$/);
      if (m) manualTail = m[1].replace(/^\s*\n/, '\n');
    } else {
      manualTail = '\n\n## 防呆原則\n\n（手動編輯，CLI 不會覆寫此區）\n';
    }
    const content = `# Topic: ${topic.name || topic.slug}\n\n> 自動產生 — \`AUTO_BEGIN/AUTO_END\` 之間請勿手動編輯（會被 \`kb.mjs rebuild\` 覆寫）。\n\n${auto}\n${manualTail}`;
    await writeUtf8(file, content);
  }
  const idxRows = topics.map(t => {
    const n = (byTopic.get(t.slug) || []).length;
    return `| ${t.slug} | ${t.name || ''} | ${n} | [→](${t.slug}.md) |`;
  }).join('\n');
  const orphan = [];
  for (const t of active) for (const s of t.topics || []) {
    if (!topics.find(x => x.slug === s)) orphan.push(`#${t.id} → ${s}`);
  }
  const orphanSec = orphan.length
    ? `\n\n## 未登記的 topic slug（請補入 topics-taxonomy.yml）\n\n${[...new Set(orphan)].sort().map(x => '- ' + x).join('\n')}\n`
    : '';
  const idx = `# 主題目錄（Topics Index）\n\n> 由 \`kb.mjs rebuild\` 自動產生。AI 啟動任務時讀本檔即可掌握所有主題分布。\n\n| slug | 名稱 | 相關 trap 數 | 連結 |\n|------|------|-------------|------|\n${idxRows}\n\n## 用法\n\n- 想知道某類問題以前發生過幾次 → 看上表的「相關 trap 數」\n- 命中主題 → 讀對應 \`topics/{slug}.md\`（含相關 trap 表 + 防呆原則）\n- 模糊查詢 → \`node .vscode/knowledge/scripts/kb.mjs search "<關鍵字>"\`${orphanSec}\n`;
  await writeUtf8(path.join(TOPICS_DIR, 'INDEX.md'), idx);
  console.log(`[topics] wrote ${topics.length} topic page(s) + INDEX${orphan.length ? ` (${orphan.length} orphan slugs)` : ''}`);
}

// =================================================================
//  taxonomy lint  — frontmatter topics 必須在 taxonomy 內
// =================================================================
async function cmdTaxonomy(args) {
  const sub = args[0];
  if (sub === 'lint') {
    const { slugs, topics } = loadTaxonomy();
    const traps = await loadAllTraps();
    const errors = [];
    const unmapped = [];
    for (const t of traps) {
      const list = t.topics || [];
      if (list.length === 0 && (t.status || 'fixed') !== 'archived') unmapped.push(t.id);
      for (const s of list) if (!slugs.has(s)) errors.push(`#${t.id}: unknown topic slug "${s}"`);
    }
    console.log(`[taxonomy lint] topics=${topics.length} traps=${traps.length} unmapped=${unmapped.length} errors=${errors.length}`);
    if (unmapped.length) console.log('  unmapped trap ids: ' + unmapped.join(','));
    for (const e of errors) console.error('  ERROR ' + e);
    if (errors.length) process.exitCode = 1;
  } else if (sub === 'stats') {
    const { topics } = loadTaxonomy();
    const traps = await loadAllTraps();
    const counts = new Map();
    for (const t of traps) for (const s of t.topics || []) counts.set(s, (counts.get(s) || 0) + 1);
    console.log('slug\tcount\tname');
    for (const t of topics) console.log(`${t.slug}\t${counts.get(t.slug) || 0}\t${t.name || ''}`);
  } else {
    console.log('Usage: kb.mjs taxonomy <lint|stats>');
  }
}

// =================================================================
//  audit  — 找候選拆分
// =================================================================
async function cmdAudit() {
  const traps = await loadAllTraps();
  const splitCandidates = [];
  for (const t of traps) {
    const lines = (t.body || '').split(/\r?\n/);
    const headings = lines.filter(L => /^##?\s+(症狀|根因|修正|測試|問題)/.test(L));
    if (lines.length > 60 && headings.length >= 3) splitCandidates.push({ id: t.id, lines: lines.length, heads: headings.length });
  }
  console.log(`[audit] split candidates (lines>60 & 多段 症狀/根因): ${splitCandidates.length}`);
  for (const s of splitCandidates) console.log(`  #${s.id}  lines=${s.lines}  headings=${s.heads}`);
}

// =================================================================
//  bulk-tag  — 一次性套用 trap → topics 對照表
// =================================================================
async function cmdBulkTag(args) {
  const opts = parseOpts(args);
  let mapJson;
  if (opts.file) mapJson = await readUtf8(opts.file);
  else mapJson = await new Promise((res, rej) => {
    let s = ''; process.stdin.setEncoding('utf8');
    process.stdin.on('data', c => s += c); process.stdin.on('end', () => res(s)); process.stdin.on('error', rej);
  });
  const map = JSON.parse(mapJson);
  const { slugs } = loadTaxonomy();
  const traps = await loadAllTraps();
  let updated = 0;
  const unknown = new Set();
  for (const t of traps) {
    const key = String(t.id);
    if (!map[key]) continue;
    const newTopics = map[key];
    for (const s of newTopics) if (!slugs.has(s)) unknown.add(s);
    const file = path.join(TRAPS_DIR, t.file);
    const text = await readUtf8(file);
    const { data, body } = parseFrontmatter(text);
    data.topics = newTopics;
    if (!data.symptoms) data.symptoms = [];
    await writeUtf8(file, stringifyFrontmatter(data) + body);
    updated++;
  }
  console.log(`[bulk-tag] updated ${updated} trap(s)`);
  if (unknown.size) {
    console.error('  unknown slugs (not in taxonomy):');
    for (const s of unknown) console.error('    ' + s);
    process.exitCode = 1;
  }
}

// =================================================================
//  FTS5  — 採 Node 22.5+ 內建 node:sqlite，不可用時降級
// =================================================================
function stripMd(s) {
  s = s.replace(/```[\s\S]*?```/g, ' ');
  s = s.replace(/`[^`]+`/g, ' $& ');
  s = s.replace(/^#{1,6}\s+/gm, '');
  s = s.replace(/[*_]{1,3}([^*_]+)[*_]{1,3}/g, '$1');
  return s;
}

async function buildFtsIndex(traps) {
  if (!DatabaseSync) {
    console.log(`[fts] skipped — node:sqlite unavailable (need Node 22.5+; ${sqliteUnavailableReason})`);
    return;
  }
  if (existsSync(FTS_DB)) await unlink(FTS_DB);
  const db = new DatabaseSync(FTS_DB);
  db.exec("PRAGMA journal_mode=MEMORY");
  db.exec(`CREATE VIRTUAL TABLE traps_fts USING fts5(
    id UNINDEXED,
    title,
    module UNINDEXED,
    topics,
    symptoms,
    body,
    files UNINDEXED,
    tokenize='unicode61 remove_diacritics 2'
  )`);
  const ins = db.prepare("INSERT INTO traps_fts(id,title,module,topics,symptoms,body,files) VALUES (?,?,?,?,?,?,?)");
  let n = 0;
  for (const t of traps) {
    if ((t.status || 'fixed') === 'archived') continue;
    ins.run(
      Number(t.id) || 0,
      String(t.title || ''),
      String(t.module || ''),
      (t.topics || []).join(' '),
      (t.symptoms || []).join(' '),
      stripMd(String(t.body || '')),
      (t.files || []).join(' ')
    );
    n++;
  }
  db.exec("INSERT INTO traps_fts(traps_fts) VALUES('optimize')");
  db.close();
  console.log(`[fts] indexed ${n} trap(s) → traps/fts.db`);
}

async function cmdSearch(args) {
  const opts = parseOpts(args);
  const q = args.filter(a => !a.startsWith('--')).join(' ');
  if (!q) { console.error('Usage: kb.mjs search "<query>" [--limit=20] [--json]'); process.exit(2); }
  if (!DatabaseSync) {
    console.error(`[fts] node:sqlite unavailable — need Node 22.5+ (got ${process.version}). Reason: ${sqliteUnavailableReason}`);
    process.exit(1);
  }
  if (!existsSync(FTS_DB)) { console.error('fts.db not found — run `kb.mjs rebuild` first'); process.exit(1); }
  const limit = Math.max(1, Math.min(200, Number(opts.limit) || 20));
  const db = new DatabaseSync(FTS_DB, { readOnly: true });
  let rows;
  try {
    const stmt = db.prepare(`SELECT id, title, module, topics,
      snippet(traps_fts, 5, '«', '»', '…', 12) AS hit,
      bm25(traps_fts) AS rank
      FROM traps_fts WHERE traps_fts MATCH ? ORDER BY rank LIMIT ?`);
    rows = stmt.all(q, limit);
  } catch (e) {
    console.error('[fts] error: ' + e.message);
    process.exit(1);
  }
  db.close();
  if (opts.json) { console.log(JSON.stringify(rows, null, 2)); return; }
  if (!rows.length) { console.log('no match for: ' + q); return; }
  console.log(`[fts] query="${q}"  hits=${rows.length}`);
  for (const r of rows) {
    const id = String(r.id).padStart(3, '0');
    const rank = Number(r.rank).toFixed(3);
    console.log(`  #${id}  rank=${rank}  [${r.module}]  ${r.title}`);
    if (r.hit) console.log(`        ↳ ${String(r.hit).replace(/\s+/g, ' ')}`);
  }
}

// =================================================================
//  new-trap / new-decision
// =================================================================
async function cmdNewTrap(args) {
  const opts = parseOpts(args);
  if (!opts.title) { console.error('Usage: kb.mjs new-trap --module=X --title="..." [--topics=slug1,slug2] [--symptoms="A;B"] [--tags=a,b] [--files=...] [--tests=...] [--related=12,34]'); process.exit(2); }
  const { slugs } = loadTaxonomy();
  const topics = opts.topics ? opts.topics.split(',').map(s => s.trim()).filter(Boolean) : [];
  for (const s of topics) if (!slugs.has(s)) { console.error(`unknown topic slug: ${s}`); process.exit(2); }
  const traps = await loadAllTraps();
  const nextId = traps.reduce((m, t) => Math.max(m, t.id || 0), 0) + 1;
  const today = new Date().toISOString().slice(0, 10);
  const fm = {
    id: nextId,
    title: opts.title,
    module: opts.module || '',
    topics,
    symptoms: opts.symptoms ? opts.symptoms.split(/[;；]/).map(s => s.trim()).filter(Boolean) : [],
    related: opts.related ? opts.related.split(',').map(s => Number(s.trim())).filter(Boolean) : [],
    date: today,
    status: 'fixed',
    severity: opts.severity || 'bug',
    tags: opts.tags ? opts.tags.split(',').map(s => s.trim()).filter(Boolean) : [],
    files: opts.files ? opts.files.split(',').map(s => s.trim()).filter(Boolean) : [],
    tests: opts.tests ? opts.tests.split(',').map(s => s.trim()).filter(Boolean) : [],
  };
  const body = `## 症狀\n\n（待補）\n\n## 根因\n\n（待補）\n\n## 修正\n\n（待補）\n\n## 測試\n\n（待補）\n`;
  const out = path.join(TRAPS_DIR, `trap-${pad(nextId)}.md`);
  await writeUtf8(out, stringifyFrontmatter(fm) + body);
  console.log(`[new-trap] created trap #${nextId} at traps/${path.basename(out)}`);
  await cmdRebuild(['--no-fts']);
}

async function cmdNewDecision(args) {
  const opts = parseOpts(args);
  if (!opts.module || !opts.title) { console.error('Usage: kb.mjs new-decision --module=X --title="..."'); process.exit(2); }
  const dir = path.join(MODULES_DIR, opts.module.toLowerCase(), 'decisions');
  await ensureDir(dir);
  const existing = (await listMd(dir)).map(f => parseInt(path.basename(f).match(/decision-(\d+)/)?.[1] || '0', 10));
  const nextId = (existing.length ? Math.max(...existing) : 0) + 1;
  const today = new Date().toISOString().slice(0, 10);
  const fm = { id: nextId, title: opts.title, module: opts.module, date: today, related_traps: [] };
  const body = `## 決策\n\n（待補）\n\n## 原因\n\n（待補）\n`;
  const out = path.join(dir, `decision-${pad(nextId)}.md`);
  await writeUtf8(out, stringifyFrontmatter(fm) + body);
  console.log(`[new-decision] created at ${path.relative(KB_ROOT, out)}`);
}

// =================================================================
//  health
// =================================================================
async function cmdHealth() {
  const errors = [];
  const warnings = [];
  const traps = await loadAllTraps();
  const seen = new Set();
  const { slugs } = loadTaxonomy();
  for (const t of traps) {
    if (typeof t.id !== 'number') errors.push(`${t.file}: missing numeric id`);
    if (seen.has(t.id)) errors.push(`duplicate id ${t.id} in ${t.file}`);
    seen.add(t.id);
    if (`trap-${pad(t.id)}.md` !== t.file) errors.push(`${t.file}: filename != id`);
    if (!t.title) warnings.push(`${t.file}: empty title`);
    if (!t.module) warnings.push(`${t.file}: empty module`);
    for (const s of t.topics || []) if (!slugs.has(s)) errors.push(`${t.file}: unknown topic "${s}"`);
    if (!(t.topics || []).length && (t.status || 'fixed') !== 'archived') warnings.push(`${t.file}: empty topics (run kb.mjs taxonomy lint)`);
  }
  if (existsSync(TRAPS_INDEX)) {
    const idxLines = (await readUtf8(TRAPS_INDEX)).split(/\r?\n/).filter(Boolean);
    if (idxLines.length !== traps.length) errors.push(`traps/index.jsonl out of date: ${idxLines.length} vs ${traps.length} fragments — run rebuild`);
  } else if (traps.length) errors.push('traps/index.jsonl missing — run rebuild');
  for await (const p of walk(KB_ROOT)) {
    if (!p.endsWith('.md')) continue;
    const buf = await readFile(p);
    if (buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) errors.push(`${path.relative(KB_ROOT, p)}: UTF-8 BOM detected`);
    if (buf.toString('utf8').includes('\uFFFD')) errors.push(`${path.relative(KB_ROOT, p)}: contains U+FFFD (encoding corruption)`);
    for (const issue of checkMarkdownLinks(p, buf.toString('utf8'))) {
      errors.push(issue);
    }
  }
  if (existsSync(MODULES_DIR)) {
    for await (const p of walk(MODULES_DIR)) {
      if (path.basename(p) === 'quickref.md') {
        const lines = (await readUtf8(p)).split(/\r?\n/).length;
        if (lines > 150) warnings.push(`${path.relative(KB_ROOT, p)}: ${lines} lines > 150 (quickref should be terse)`);
      }
    }
  }
  for (const issue of collectAgentGeneratedHealthIssues()) warnings.push(issue);
  for (const issue of collectWorkspaceSettingsHealthIssues()) errors.push(issue);
  console.log(`[health] traps=${traps.length}, errors=${errors.length}, warnings=${warnings.length}`);
  for (const e of errors) console.error('  ERROR ' + e);
  for (const w of warnings) console.warn('  WARN  ' + w);
  if (errors.length) process.exitCode = 1;
}

function checkMarkdownLinks(file, text) {
  const issues = [];
  const relFile = normalizeFile(path.relative(KB_ROOT, file));
  const linkRe = /\[[^\]]+\]\(([^)]+)\)/g;
  let match;
  while ((match = linkRe.exec(text)) !== null) {
    const rawTarget = match[1].trim();
    if (!rawTarget || rawTarget.startsWith('#') || /^[a-z][a-z0-9+.-]*:/i.test(rawTarget)) continue;
    const withoutAnchor = rawTarget.split('#')[0];
    if (!withoutAnchor) continue;
    const decoded = decodeURIComponent(withoutAnchor);
    const target = path.resolve(path.dirname(file), decoded);
    if (!target.startsWith(VSCODE_ROOT) || !existsSync(target)) {
      issues.push(`${relFile}: broken markdown link ${rawTarget}`);
    }
  }
  return issues;
}

function collectAgentGeneratedHealthIssues() {
  const warnings = [];
  if (!existsSync(path.join(AGENT_DIR, 'INDEX.md'))) {
    warnings.push('agent/INDEX.md missing — Agent guard disabled');
  }
  const generated = [AGENT_GUARDS, AGENT_BY_COMMAND, AGENT_BY_TOOL, AGENT_BY_ERROR, AGENT_BY_PATH];
  const missing = generated.filter(file => !existsSync(file));
  if (missing.length) warnings.push('agent/generated facets missing — run kb.mjs rebuild');
  return warnings;
}

function collectWorkspaceSettingsHealthIssues() {
  const issues = [];
  const settingsPath = path.join(VSCODE_ROOT, 'settings.json');
  if (!existsSync(settingsPath)) return ['.vscode/settings.json missing'];
  let settings;
  try { settings = JSON.parse(readFileSync(settingsPath, 'utf8')); }
  catch (e) { return [`.vscode/settings.json invalid JSON: ${e.message}`]; }
  if (settings['chat.promptFiles'] !== true) issues.push('.vscode/settings.json missing chat.promptFiles=true');
  const locations = settings['chat.promptFilesLocations'] || {};
  if (locations['.vscode'] !== true || locations['.vscode/prompts'] !== true) {
    issues.push('.vscode/settings.json missing chat.promptFilesLocations for .vscode and .vscode/prompts');
  }
  if (settings['files.encoding'] && settings['files.encoding'] !== 'utf8') {
    issues.push('.vscode/settings.json files.encoding must be utf8');
  }
  return issues;
}

// =================================================================
//  openspec-check
// =================================================================
async function cmdOpenspecCheck(args) {
  const opts = parseOpts(args);
  const strict = 'strict' in opts;
  const warnings = [];
  const errors   = [];

  const OPENSPEC_DIR   = path.join(VSCODE_ROOT, 'openspec');
  const specsIndexPath = path.join(OPENSPEC_DIR, 'specs', 'INDEX.md');
  const changesDir     = path.join(OPENSPEC_DIR, 'changes');
  const archiveDir     = path.join(changesDir, 'archive');

  if (!existsSync(OPENSPEC_DIR)) {
    warnings.push('openspec/ not found — run init-kb.ps1 or update-kb.ps1 -Apply to scaffold OpenSpec');
  } else {
    // Check 1: specs/INDEX.md exists
    if (!existsSync(specsIndexPath)) {
      warnings.push('openspec/specs/INDEX.md missing — create and track requirement counts per module');
    }

    // Check 2: unarchived changes with tasks
    if (existsSync(changesDir)) {
      let changeDirs = [];
      try {
        changeDirs = (await readdir(changesDir, { withFileTypes: true }))
          .filter(d => d.isDirectory() && d.name !== 'archive')
          .map(d => d.name);
      } catch { /* ignore */ }
      for (const name of changeDirs) {
        const tasksPath = path.join(changesDir, name, 'tasks.md');
        if (!existsSync(tasksPath)) continue;
        const isArchived = existsSync(path.join(archiveDir, name));
        if (isArchived) continue;
        const content = await readUtf8(tasksPath);
        const incomplete = (content.match(/^\s*-\s*\[\s*\]/gm) || []).length;
        const completed  = (content.match(/^\s*-\s*\[x\]/gmi) || []).length;
        if (incomplete > 0) {
          warnings.push(`openspec/changes/${name}: ${incomplete} incomplete task(s) (${completed} done) — run '.\\opsx status --change ${name}'`);
        } else if (completed > 0) {
          warnings.push(`openspec/changes/${name}: all ${completed} task(s) done but not archived — run /opsx:archive`);
        }
      }
    }

    // Check 3: spec links in trap topics exist on disk
    if (existsSync(TOPICS_DIR)) {
      for await (const topicFile of walk(TOPICS_DIR)) {
        if (!topicFile.endsWith('.md')) continue;
        const content = await readUtf8(topicFile);
        const re = /openspec\/specs\/[^\s)#"']+/g;
        let m;
        while ((m = re.exec(content)) !== null) {
          const rel = m[0];
          const abs = path.join(VSCODE_ROOT, rel);
          if (!existsSync(abs)) {
            warnings.push(`${path.basename(topicFile)}: broken spec link '${rel}' — run /opsx:archive then kb.mjs rebuild`);
          }
        }
      }
    }
  }

  const total = warnings.length + errors.length;
  const note  = strict ? ' (strict: warnings treated as errors)' : ' (use --strict to treat warnings as errors)';
  console.log(`[openspec-check] issues=${total}${note}`);
  for (const e of errors)   console.error('  ERROR ' + e);
  for (const w of warnings) { if (strict) console.error('  ERROR ' + w); else console.warn('  WARN  ' + w); }
  if (errors.length || (strict && warnings.length)) process.exitCode = 1;
}

async function cmdFinishCheck(args) {
  await cmdTaxonomy(['lint']);
  await cmdHealth();
  const previousExitCode = process.exitCode || 0;
  await cmdRepairHealth(args);
  await cmdOpenspecCheck(args);
  if (previousExitCode || process.exitCode) process.exitCode = 1;
}

async function cmdStartCheck(args) {
  const opts = parseOpts(args);
  const moduleName = opts.module || opts.m || '';
  const file = opts.file || '';
  const query = opts.query || args.filter(a => !a.startsWith('--')).join(' ');
  console.log('[start-check] required reads');
  console.log('  - .vscode/knowledge/agent/INDEX.md');
  console.log('  - .vscode/knowledge/INDEX.md');
  if (moduleName) console.log(`  - .vscode/knowledge/modules/${String(moduleName).toLowerCase()}/quickref.md`);
  else console.log('  - module quickref: infer module first; do not run placeholder command');
  console.log('  - .vscode/knowledge/traps/topics/INDEX.md');
  if (file && existsSync(path.join(TRAPS_DIR, 'by-file.json'))) {
    const byFile = readJsonIfExists(path.join(TRAPS_DIR, 'by-file.json'), {});
    const key = normalizeFile(file);
    const hits = byFile[key] || [];
    console.log(`[start-check] by-file ${key}: ${hits.length ? hits.map(id => '#' + id).join(', ') : 'no direct trap hit'}`);
  }
  if (query) {
    if (hasPlaceholder(query)) console.log('[start-check] query has placeholder; replace with concrete keyword before search');
    else console.log(`[start-check] optional search: node .vscode/knowledge/scripts/kb.mjs search ${JSON.stringify(query)}`);
  }
  await cmdRepairStatus(['--quiet-ok']);
}

function loadGuards() {
  return readJsonIfExists(AGENT_GUARDS, []);
}

async function cmdRepairPreflight(args) {
  const opts = parseOpts(args);
  const command = String(opts.command || '').trim();
  const tool = String(opts.tool || '').trim().toLowerCase();
  const targetPath = String(opts.path || '').trim();
  const intent = String(opts.intent || '').trim();
  const decisions = [];
  if (hasPlaceholder(command) || hasPlaceholder(targetPath) || hasPlaceholder(intent)) {
    decisions.push({ level: 'deny', reason: 'placeholder detected; infer concrete values before execution' });
  }
  if (/\s&&\s/.test(command)) decisions.push({ level: 'deny', reason: 'PowerShell 5.1 does not use &&; use semicolon or separate commands' });
  if (/Get-Content\b[\s\S]*\|[\s\S]*Set-Content\b|\bSet-Content\b|\(\s*Get-Content\s*\)[\s\S]*-replace/i.test(command)) {
    decisions.push({ level: 'deny', reason: 'PowerShell text rewrite risks UTF-8 corruption; use editor/apply_patch-safe workflow' });
  }
  if ((tool === 'search' || /grep|rg|search/i.test(command)) && /(^|[\\/])\.vscode([\\/]|$)|\.vscode\/knowledge/i.test(command + ' ' + targetPath)) {
    decisions.push({ level: 'warn', reason: '.vscode may be ignored by search tools; prefer direct read/list_dir or include ignored files' });
  }

  const guards = loadGuards();
  for (const guard of guards) {
    if ((guard.bad_tools || []).some(item => guardMatches(tool, item))) decisions.push({ level: 'deny', trap: guard.id, reason: guard.title || 'bad tool guard' });
    if ([...(guard.bad_commands || []), ...(guard.body_commands || [])].some(item => guardMatches(command, item))) decisions.push({ level: 'deny', trap: guard.id, reason: guard.title || 'bad command guard' });
    if ([...(guard.bad_paths || []), ...(guard.body_paths || [])].some(item => guardMatches(targetPath, item))) decisions.push({ level: 'warn', trap: guard.id, reason: guard.title || 'bad path guard' });
  }

  const level = decisions.some(d => d.level === 'deny') ? 'deny' : decisions.some(d => d.level === 'warn') ? 'warn' : 'allow';
  console.log(`[repair-preflight] ${level}`);
  if (tool) console.log(`  tool: ${tool}`);
  if (command) console.log(`  command: ${normalizeCommand(command)}`);
  if (targetPath) console.log(`  path: ${normalizePathValue(targetPath)}`);
  if (intent) console.log(`  intent: ${intent}`);
  for (const decision of decisions) console.log(`  ${decision.level.toUpperCase()}${decision.trap ? ` #${decision.trap}` : ''}: ${decision.reason}`);
  if (level === 'deny') process.exitCode = 1;
}

async function cmdRepairRecord(args) {
  const opts = parseOpts(args);
  const fingerprint = makeFingerprint(opts);
  const file = path.join(runtimeDir(), REPAIR_FAILURES_FILE);
  const row = {
    schema: 1,
    ts: new Date().toISOString(),
    fingerprint,
    error: redactSensitive(opts.error || opts.stderr || opts.message || ''),
    resolved: false,
  };
  await appendJsonl(file, row);
  const count = (groupByFingerprint(readJsonlIfExists(file)).get(fingerprint.id) || []).length;
  console.log(`[repair-record] ${fingerprint.id} count=${count}`);
  if (count >= REPAIR_RETRY_LIMIT) {
    console.log('  pending repair: same fingerprint repeated; change method or create/update operational trap');
    process.exitCode = 1;
  }
}

async function cmdRepairStatus(args) {
  const opts = parseOpts(args);
  const file = path.join(runtimeDir(), REPAIR_FAILURES_FILE);
  const falsePositives = readJsonIfExists(path.join(runtimeDir(), REPAIR_FALSE_POSITIVES_FILE), {});
  const grouped = groupByFingerprint(readJsonlIfExists(file));
  const pending = [];
  for (const [id, records] of grouped) {
    if (records.length < REPAIR_RETRY_LIMIT) continue;
    const fp = falsePositives[id];
    if (fp && (!fp.expires || new Date(fp.expires) >= new Date())) continue;
    pending.push({ id, count: records.length, latest: records[records.length - 1] });
  }
  if (!opts['quiet-ok'] || pending.length) console.log(`[repair-status] pending=${pending.length}`);
  for (const item of pending) {
    const fp = item.latest.fingerprint || {};
    console.log(`  ${item.id} count=${item.count} tool=${fp.tool || ''} command=${fp.command || ''} intent=${fp.intent || ''}`);
  }
  if (pending.length) process.exitCode = 1;
}

async function cmdRepairHealth(args) {
  const previous = process.exitCode || 0;
  process.exitCode = 0;
  await cmdRepairStatus(args);
  const pendingExit = process.exitCode || 0;
  const file = path.join(runtimeDir(), REPAIR_FAILURES_FILE);
  const records = readJsonlIfExists(file);
  const invalid = records.filter(r => r.invalid);
  const secretLike = records.filter(r => /\.env|TOKEN|SECRET|PASSWORD|BEGIN RSA|PRIVATE KEY|Bearer\s+[A-Za-z0-9]/i.test(JSON.stringify(r))).length;
  console.log(`[repair-health] records=${records.length} invalid=${invalid.length} secret_like=${secretLike}`);
  for (const row of invalid) console.error(`  ERROR invalid jsonl line ${row.line}`);
  if (secretLike) console.error('  ERROR runtime ledger may contain sensitive data; redact or delete the entry');
  if (previous || pendingExit || invalid.length || secretLike) process.exitCode = 1;
}

async function* walk(d) {
  if (!existsSync(d)) return;
  for (const e of await readdir(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) {
      if (['backups', 'runtime'].includes(e.name)) continue;
      yield* walk(p);
    }
    else yield p;
  }
}

// =================================================================
//  arg parser
// =================================================================
function parseOpts(argv) {
  const out = {};
  for (const a of argv) {
    if (a === '--no-fts') { out.fts = false; continue; }
    const m = a.match(/^--([\w-]+)(?:=(.*))?$/);
    if (m) out[m[1]] = m[2] ?? true;
  }
  return out;
}

// =================================================================
//  main
// =================================================================
const HELP = `kb.mjs — knowledge base v3 CLI

Commands:
  rebuild [--no-fts]     重建 index.jsonl + facets + topics + (FTS db)
  new-trap               --module=X --title="..." [--topics=slug1,slug2] [--symptoms="A;B"]
                         [--tags=a,b] [--files=...] [--tests=...] [--related=12,34]
  new-decision           --module=X --title="..."
  taxonomy lint|stats    校驗 / 統計 topic 覆蓋率
  facets                 只重建 facet JSON
  topics                 只重建 topics/*.md（保留手動防呆原則段落）
  audit                  找拆分候選（行數 > 60 且多段症狀/根因）
  bulk-tag --file=X.json 一次性套用 trap → topics 對照
  search "<query>"       SQLite FTS5 全文檢索（需 Node 22.5+）
  start-check            任務啟動必讀包與 Agent Repair Context
  repair-preflight       --tool=X --command="..." [--path=...] [--intent=...]
  repair-record          --tool=X --command="..." --exit-code=N --error="..."
  repair-status          檢查 repeated failure pending repair
  repair-health          任務收尾 repair gate，pending/secret/invalid 必須為 0
  health                 健康檢查
  openspec-check         OpenSpec 驗證：specs/INDEX.md、未封存 change、斷開 spec 連結 [--strict]
  finish-check           taxonomy lint + health + repair-health + openspec-check
`;

const [, , cmd, ...rest] = process.argv;
try {
  switch (cmd) {
    case 'rebuild': await cmdRebuild(rest); break;
    case 'new-trap': await cmdNewTrap(rest); break;
    case 'new-decision': await cmdNewDecision(rest); break;
    case 'taxonomy': await cmdTaxonomy(rest); break;
    case 'facets': await cmdFacets(); break;
    case 'topics': await cmdTopics(); break;
    case 'audit': await cmdAudit(); break;
    case 'bulk-tag': await cmdBulkTag(rest); break;
    case 'search': await cmdSearch(rest); break;
    case 'start-check': await cmdStartCheck(rest); break;
    case 'repair-preflight': await cmdRepairPreflight(rest); break;
    case 'repair-record': await cmdRepairRecord(rest); break;
    case 'repair-status': await cmdRepairStatus(rest); break;
    case 'repair-health': await cmdRepairHealth(rest); break;
    case 'health': await cmdHealth(); break;
    case 'openspec-check': await cmdOpenspecCheck(rest); break;
    case 'finish-check': await cmdFinishCheck(rest); break;
    default: console.log(HELP); break;
  }
} catch (e) {
  console.error(e.stack || e.message);
  process.exit(1);
}
'@

Write-Utf8File -Path (Join-Path $kbDir 'scripts\kb.mjs') -Content $kbScript -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 13. OpenSpec scaffold + opsx wrappers + cheatsheet
# ─────────────────────────────────────────────────────────────
if (-not $SkipOpenSpec) {
    Write-Section "13. OpenSpec scaffold（.vscode/openspec/）"

    $openspecDir = Join-Path $vscodeDir 'openspec'

    # ── config.yaml ──────────────────────────────────────────
    $openspecConfig = @'
schema: project-feature

context: |
  # 專案名稱（請填入）

  ## 技術棧
  （請填入：語言、框架、資料庫、測試框架）

  ## 程式碼路徑
  （請填入：主要程式碼目錄結構）

  ## 主要模組
  （請填入：各功能模組說明）

  ## 知識庫 CLI
  - 啟動任務前：`node .vscode/knowledge/scripts/kb.mjs start-check --module=X --file=path --query="關鍵字"`
  - 新陷阱：`node .vscode/knowledge/scripts/kb.mjs new-trap --module=X --title="..." --topics=slug`
  - 重建索引：`node .vscode/knowledge/scripts/kb.mjs rebuild`

  ## 禁止事項
  - 禁止在 response 使用 fenced code block（VS Code Chat 會隱藏）
  - 禁止用 PowerShell Set-Content / Get-Content | Set-Content 寫入知識庫（CP950 損毀）
  - 禁止手動編輯 traps/index.jsonl、by-*.json、topics/{slug}.md AUTO 區

rules:
  research:
    - 必須執行 kb.mjs start-check 並記錄命中的 trap 與 topic
    - 若發現解讀歧義，必須列入「假設確認」段落，動手前須確認
  proposal:
    - 必須說明此變更的影響範圍與主要涉及檔案
    - 禁止靜默選擇解讀：有歧義情境必須在此文件中說明已確認的假設
  specs:
    - 所有 Scenario 必須使用 GIVEN / WHEN / THEN 格式
    - 核心需求使用 MUST 或 SHALL；建議性規則使用 SHOULD；選擇性使用 MAY
    - Scenario 標頭必須使用四個 # 符號（#### Scenario:）
  design:
    - 遵循最小實作原則：不加未要求的抽象層或 config 選項
  tasks:
    - 必須包含「測試驗證」群組（不可省略）
    - 必須包含「知識庫更新」群組（不可省略），包含 rebuild 和 finish-check 步驟
'@
    Write-Utf8File -Path (Join-Path $openspecDir 'config.yaml') -Content $openspecConfig -Overwrite:$Force

    # ── schemas/project-feature/schema.yaml ──────────────────
    $featureSchema = @'
name: project-feature
version: 1
description: 功能開發流程 — research → proposal → specs → design → tasks
artifacts:
  - id: research
    generates: research.md
    description: 功能背景調查：現有知識庫、陷阱查閱
    template: research.md
    instruction: |
      在動手實作之前，先閱讀現有知識庫和程式碼，完成背景調查。

      必須執行的查閱步驟：
      1. 執行 `node .vscode/knowledge/scripts/kb.mjs start-check --module=<模組> --file=<主要檔案> --query="<關鍵字>"`
      2. 讀 `.vscode/knowledge/INDEX.md` 掌握全貌
      3. 讀涉及模組的 `modules/{m}/quickref.md`
      4. 讀 `traps/topics/INDEX.md`，命中主題後讀 `traps/topics/{slug}.md`

      文件段落：
      - **知識庫查閱結果**：列出相關 trap、topic、quickref 的關鍵發現
      - **相關陷阱清單**：格式 `trap-NNN: 說明`
      - **假設確認**：列出所有可能的解讀歧義，需在 proposal 前確認

      保持精簡；目的是讓 proposal 作者有充分背景，不是寫完整技術文件。
    requires: []

  - id: proposal
    generates: proposal.md
    description: 功能提案：為何做、做什麼、影響範圍
    template: proposal.md
    instruction: |
      基於 research.md 的調查結果，撰寫功能提案。

      段落說明：
      - **為何需要此功能**：1-3 句說明動機或問題
      - **功能範圍**：條列在 scope 內和 scope 外的項目；必須明確說明邊界
      - **涉及能力（Capabilities）**：kebab-case 命名，每個對應一個 `specs/<name>/spec.md`
      - **已知風險**：列出陷阱或副作用（參考 research.md 的陷阱清單）

      禁止：不可靜默選擇解讀歧義，必須在此文件中說明已確認的假設。
    requires:
      - research

  - id: specs
    generates: "specs/**/*.md"
    description: 行為規格：WHAT — 以 GIVEN/WHEN/THEN 描述可測試行為
    template: spec.md
    instruction: |
      依據 proposal.md 的 Capabilities 段落，為每個能力建立 spec 檔案。

      **路徑規則**：
      - 新能力：`specs/<capability>/spec.md`
      - 修改能力：`specs/<capability>/spec.md`（使用現有資料夾名稱）

      **格式規則（嚴格遵守）**：
      - Delta 區段：`## ADDED Requirements`、`## MODIFIED Requirements`、`## REMOVED Requirements`
      - 每個需求：`### Requirement: <名稱>`
      - RFC 2119 關鍵字：MUST / SHALL（強制）、SHOULD（建議）、MAY（選擇）
      - Scenario 標頭：`#### Scenario: <名稱>`（**必須四個 # 符號**）
      - Scenario 格式：`- **GIVEN** ...`、`- **WHEN** ...`、`- **THEN** ...`
      - 每個 Requirement 至少一個正常路徑（happy path）scenario
    requires:
      - proposal

  - id: design
    generates: design.md
    description: 技術設計：HOW — 架構決策、資料流、修改範圍
    template: design.md
    instruction: |
      以下情況才需要 design.md（任一成立即建立）：
      - 跨多個 Service / Controller / API 的異動
      - 新增外部依賴或重大 DB Schema 異動
      - 安全性、效能或 migration 複雜度高

      段落說明：
      - **架構決策**：決策: 選了 X，因為... 考慮過 Y，但...
      - **資料流**：涉及 DB 讀寫時，說明呼叫順序
      - **涉及檔案**：`- path/to/file.ext（修改說明）`

      遵循最小實作原則：不加未要求的抽象層，不引入新的設計模式除非必要。
    requires:
      - proposal

  - id: tasks
    generates: tasks.md
    description: 實作清單：含測試驗證步驟
    template: tasks.md
    instruction: |
      依據 specs 和 design，建立可逐步勾選的實作清單。

      **格式規則（嚴格遵守）**：
      - 群組標題：`## N. <群組名稱>`
      - 每個任務：`- [ ] N.M <描述>`

      **必要群組**：
      1. 程式碼修改（依 design.md 的涉及檔案）
      2. 測試驗證（**此群組不可省略**）
      3. 知識庫更新（**此群組不可省略**）

      **知識庫更新群組範本**：
      - `- [ ] N.1 執行 kb.mjs new-trap（如有新陷阱）`
      - `- [ ] N.2 執行 node .vscode/knowledge/scripts/kb.mjs rebuild`
      - `- [ ] N.3 執行 kb.mjs finish-check，確認 0 errors`
    requires:
      - specs
      - design

apply:
  requires: [tasks]
  tracks: tasks.md
  instruction: |
    讀取 proposal.md、specs/、design.md 作為背景，逐步勾選 tasks.md 中的待辦項目。
    完成每個 task 後立即標記 [x]。遇到阻擋點或歧義時暫停並說明原因。
    完成所有 task 後提示執行 /opsx:archive。
'@
    Write-Utf8File -Path (Join-Path $openspecDir 'schemas\project-feature\schema.yaml') -Content $featureSchema -Overwrite:$Force

    # ── schemas/project-bugfix/schema.yaml ───────────────────
    $bugfixSchema = @'
name: project-bugfix
version: 1
description: Bug 修復流程（輕量）— proposal → specs → tasks
artifacts:
  - id: proposal
    generates: proposal.md
    description: 問題提案：症狀、根因、修正方向
    template: proposal.md
    instruction: |
      撰寫 bugfix 提案，說明問題、根因和修正方向。

      段落說明：
      - **症狀**：使用者或系統觀察到的異常行為
      - **根本原因**：程式碼層面的根因，說明為何現有邏輯有缺陷
      - **修正方向**：說明修正策略（不是實作細節，是方向）
      - **已知風險 / 副作用**：此修正可能影響哪些相關功能

      對應的 trap 編號（若已存在）：標注在「症狀」段末尾，格式 `（參考 trap-NNN）`。
      若尚未有 trap，在 tasks 完成後執行 kb.mjs new-trap 登錄。
    requires: []

  - id: specs
    generates: "specs/**/*.md"
    description: 修正規格：WHAT — 描述修正後正確行為
    template: spec.md
    instruction: |
      依據 proposal.md，為受影響的能力撰寫 delta spec。

      **格式規則（嚴格遵守）**：
      - Delta 區段：`## ADDED Requirements`、`## MODIFIED Requirements`、`## REMOVED Requirements`
      - 每個需求：`### Requirement: <名稱>`
      - RFC 2119 關鍵字：MUST / SHALL（強制）、SHOULD（建議）、MAY（選擇）
      - Scenario 標頭：`#### Scenario: <名稱>`（**必須四個 #**）
      - Scenario 格式：`- **GIVEN** ...`、`- **WHEN** ...`、`- **THEN** ...`

      Spec 是「修正後應有的行為契約」；不是描述現有 bug。
    requires:
      - proposal

  - id: tasks
    generates: tasks.md
    description: 實作清單：含程式碼修改、測試、知識庫更新步驟
    template: tasks.md
    instruction: |
      依據 proposal 和 specs，建立可逐步勾選的修復步驟清單。

      **格式規則（嚴格遵守）**：
      - 群組標題：`## N. <群組名稱>`
      - 每個任務：`- [ ] N.M <描述>`

      **必要群組**：
      1. 程式碼修改（每個受影響檔案至少一個 task）
      2. 測試驗證（**不可省略**）
      3. 知識庫更新（**不可省略**）

      **知識庫更新群組範本**：
      - `kb.mjs new-trap --module=<模組> --title="..." --topics=<slug> --symptoms="..."`
      - `node .vscode/knowledge/scripts/kb.mjs rebuild`
      - `kb.mjs finish-check`
    requires:
      - specs

apply:
  requires: [tasks]
  tracks: tasks.md
  instruction: |
    讀取 proposal.md 和 specs/ 作為背景，逐步勾選 tasks.md 中的待辦項目。
    完成每個 task 後立即標記 [x]。遇到阻擋點暫停並說明原因。
    全部 task 完成後，確認測試通過並執行知識庫更新，再提示 /opsx:archive。
'@
    Write-Utf8File -Path (Join-Path $openspecDir 'schemas\project-bugfix\schema.yaml') -Content $bugfixSchema -Overwrite:$Force

    # ── specs/INDEX.md ────────────────────────────────────────
    $specsIndex = @'
# OpenSpec 模組規格目錄

> **更新**：（請填入初次建立日期）
> **說明**：每份 `spec.md` 為模組的「行為契約」，AI 可僅讀本檔系列回答模組行為問題，
>          不需逐一翻 `.vscode/knowledge/traps/` 個別陷阱。

---

## 已完成規格

| 模組 | 檔案 | Requirements 數 | 主要來源 topics |
|------|------|----------------|----------------|
| （尚無規格，累積 1–2 個 change 後填入） | — | — | — |

---

## 待補規格

| 模組 | 優先度 | 主要來源 topics |
|------|--------|----------------|
| （依專案性質填入） | 中 | — |

---

## 更新規範

1. 新增 Requirement 時更新本 INDEX 的 Requirements 數欄位
2. 每個 spec.md 標頭的「更新日期」需同步
3. spec.md 內容變更後，若涉及新陷阱，需同步更新 trap 的防呆原則欄位
4. **不是** openspec change 的 spec（change 的 specs 放在 `.vscode/openspec/changes/{name}/specs/`）

---

## 與知識庫的分工

| 層級 | 存放位置 | 內容 |
|------|---------|------|
| 行為契約（What） | `.vscode/openspec/specs/{module}/spec.md` | 模組 MUST/SHALL 規則，GIVEN/WHEN/THEN 場景 |
| 陷阱紀錄（Why/How） | `.vscode/knowledge/traps/trap-NNN.md` | 具體實作細節、根因分析、修正歷史 |
| 模組索引（Where） | `.vscode/knowledge/modules/{m}/quickref.md` | 檔案路徑、API 列表、關聯模組 |
'@
    Write-Utf8File -Path (Join-Path $openspecDir 'specs\INDEX.md') -Content $specsIndex -Overwrite:$Force

    # ── changes/ 目錄 ─────────────────────────────────────────
    Write-Utf8File -Path (Join-Path $openspecDir 'changes\.gitkeep') -Content "" -Overwrite:$Force
    Write-Utf8File -Path (Join-Path $openspecDir 'changes\archive\.gitkeep') -Content "" -Overwrite:$Force

    # ─────────────────────────────────────────────────────────
    # 14. opsx wrapper scripts（專案根目錄）
    # ─────────────────────────────────────────────────────────
    Write-Section "14. opsx wrapper（根目錄 opsx.bat / opsx.ps1）"

    $opsxBat = @'
@echo off
pushd "%~dp0.vscode"
openspec %*
set _EC=%ERRORLEVEL%
popd
exit /b %_EC%
'@
    # opsx wrappers 不依 $Force 覆蓋；若已存在表示使用者已手動設置，不覆蓋
    Write-Utf8File -Path (Join-Path $projectRoot 'opsx.bat') -Content $opsxBat

    $opsxPs1 = @'
param([Parameter(ValueFromRemainingArguments=$true)]$passThrough)
Push-Location (Join-Path $PSScriptRoot ".vscode")
openspec @passThrough
$ec = $LASTEXITCODE
Pop-Location
exit $ec
'@
    Write-Utf8File -Path (Join-Path $projectRoot 'opsx.ps1') -Content $opsxPs1

    # ─────────────────────────────────────────────────────────
    # 15. openspec-cheatsheet.md（指令速查）
    # ─────────────────────────────────────────────────────────
    Write-Section "15. openspec-cheatsheet.md（指令速查）"

    $cheatsheet = @'
# OpenSpec 指令速查

> **根目錄**：`.vscode/openspec/`
> **包裝腳本**：`opsx.bat`（CMD）/ `opsx.ps1`（PowerShell）— 放在**專案根目錄**，不入版控
> **執行位置**：從**專案根目錄**執行 `opsx`，無需手動切換目錄

---

## 快速上手

在 PowerShell 中從專案根執行：

    .\opsx <子命令>

在 CMD 中：

    opsx <子命令>

---

## 常用指令

### 查看現有 Changes

    .\opsx list

### 查看 Change 完成狀態

    .\opsx status --change <change-name>
    .\opsx status --change <change-name> --json

### 建立新 Change（功能開發）

    .\opsx new change <change-name>

> 預設使用 `project-feature` schema（research → proposal → specs → design → tasks）。
> Change 目錄產生於 `.vscode/openspec/changes/<change-name>/`。

### 建立新 Change（Bug 修復）

    .\opsx new change <change-name> --schema project-bugfix

> `project-bugfix` 流程：proposal → specs → tasks（省略 research / design）。

### 取得 Artifact 撰寫指引

    .\opsx instructions <artifact-id> --change <change-name>
    .\opsx instructions <artifact-id> --change <change-name> --json

artifact-id 可為：`research` / `proposal` / `specs` / `design` / `tasks`

### Apply 指引（查看下一個要實作的 task）

    .\opsx instructions apply --change <change-name> --json

### 封存完成的 Change

    .\opsx archive <change-name>

封存後的目錄：`.vscode/openspec/changes/archive/YYYY-MM-DD-<change-name>/`

---

## 本專案 Schemas

| Schema | 流程 | 適用時機 |
|--------|------|---------|
| `project-feature` | research → proposal → specs → design → tasks | 新功能、規格變更、行為契約調整 |
| `project-bugfix` | proposal → specs → tasks | Bug 修復（輕量，省略調查和設計） |

---

## 目錄結構

    .vscode/openspec/
    ├── config.yaml               # 專案設定（預設 schema: project-feature）
    ├── schemas/
    │   ├── project-feature/      # 功能開發 schema
    │   └── project-bugfix/       # Bug 修復 schema
    ├── specs/                    # 模組行為規格（長期維護）
    │   └── INDEX.md              # 規格索引（所有模組 Requirements 數量）
    └── changes/                  # 進行中的 Changes
        └── archive/              # 封存的 Changes

---

## AI 指令（Copilot Chat Slash Commands）

| 指令 | 說明 |
|------|------|
| `/opsx:explore` | 進入探索模式，釐清需求與設計假設（不動手實作） |
| `/opsx:propose` | 建立新 change 並一次產出全部 artifacts |
| `/opsx:apply` | 實作 change 的 tasks（逐一執行） |
| `/opsx:archive` | 封存完成的 change |

> 這些是 AI Copilot 的 skill 指令，不是 CLI 命令。

---

## 完整開發流程（搭配知識庫）

    Step 0  /opsx:explore        釐清需求邊界與設計假設          ← #start-plan 觸發
    Step 1  /opsx:propose        建立 change，產出 artifacts     ← 確認計劃後手動觸發
    Step 2  kb.mjs start-check   知識庫預讀（陷阱、主題、quickref）← #start-task 觸發
    Step 3  /opsx:apply          實作 tasks                      ← #start-task 執行
    Step 4  （測試指令）          執行測試，確認 0 failures         ← #start-task 執行
    Step 5  kb.mjs new-trap      若發現新陷阱，登錄知識庫          ← #end-task 執行
    Step 6  /opsx:archive        封存 change                     ← #end-task 執行
    Step 7  kb.mjs rebuild       重建知識庫索引                   ← #end-task 執行
    Step 8  kb.mjs finish-check  體檢（errors=0）                 ← #end-task 執行

---

## Prompt 入口對照

| Prompt | 涵蓋步驟 | 用途 | 注意 |
|--------|---------|------|------|
| `#start-plan` | Step 0, Step 2 | 分析需求、讀 KB、輸出計劃表，**等待確認才繼續** | Read-only；Step 1 須確認後手動觸發 |
| `#start-task` | Step 0~4 | KB 讀取 + 實作 + 測試 | Bug 修復跳過 Step 0~1 |
| `#end-task` | Step 5~8 | KB 更新 + archive + rebuild + finish-check | archive（Step 6）在 rebuild（Step 7）之前 |

---

## 依任務類型選擇流程

### 新功能 / 規格變更

    #start-plan   → 探索需求 (Step 0) + KB 讀取 (Step 2) + 輸出計劃
    確認計劃
    /opsx:propose → 建立 change artifacts (Step 1)  ← 手動觸發
    #start-task   → KB 重讀 + /opsx:apply 實作 + 測試 (Step 2~4)
    #end-task     → KB 更新 + archive + rebuild + finish-check (Step 5~8)

### Bug 修復 / 陷阱修補

    #start-task   → KB 讀取 + 直接實作 + 測試 (Step 2~4)  ← 跳過 Step 0~1
    #end-task     → KB 更新 + rebuild + finish-check (Step 5~8)  ← 跳過 Step 6

---

## 重要注意事項

- **OpenSpec ≠ 知識庫**：OpenSpec 記錄「WHAT / 行為契約」，知識庫記錄「WHY / 根因與陷阱」
- `#start-plan` 是 Read-only，確認前不寫入；`/opsx:propose` 才是實際建立 change 的寫入動作
- 修改 `.vscode/openspec/specs/` 後必須同步更新 `specs/INDEX.md` 的 Requirements 數量
- Step 6（`/opsx:archive`）必須在 Step 7（`kb.mjs rebuild`）之前，封存後的 spec 連結才能被 FTS 索引
'@
    Write-Utf8File -Path (Join-Path $vscodeDir 'openspec-cheatsheet.md') -Content $cheatsheet -Overwrite:$Force

    Write-Host "  [提示] 建議在 .gitignore 加入：/opsx.bat 與 /opsx.ps1（wrapper 為本機工具）" -ForegroundColor Cyan
}

  if ($EnableRtkHints) {
    Write-Section "RTK 指引（選配）"
    Write-Utf8File -Path (Join-Path $projectRoot 'rtk-cheatsheet.md') -Content $rtkCheatsheet -Overwrite:$Force
  }

# ─────────────────────────────────────────────────────────────
  # 自動執行 rebuild + finish-check（若 Node 可用）
# ─────────────────────────────────────────────────────────────
  Write-Section "自動初始化索引（rebuild + finish-check）"

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $kbMjs = Join-Path $kbDir 'scripts\kb.mjs'
    Push-Location $projectRoot
    # node 可能輸出 ExperimentalWarning 到 stderr；暫時放寬 ErrorActionPreference 避免被當成終止錯誤
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & node --no-warnings $kbMjs rebuild
        if ($LASTEXITCODE -ne 0) { Write-Host "  [警告] rebuild 結束代碼 $LASTEXITCODE" -ForegroundColor Yellow }
        & node --no-warnings $kbMjs finish-check
        if ($LASTEXITCODE -ne 0) { Write-Host "  [警告] finish-check 結束代碼 $LASTEXITCODE" -ForegroundColor Yellow }
    } catch {
        Write-Host "  [警告] kb.mjs 執行失敗：$($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $prevEAP
        Pop-Location
    }
} else {
    Write-Host "  [略過] 找不到 node 執行檔；請手動執行：" -ForegroundColor Yellow
    Write-Host "         node .vscode\knowledge\scripts\kb.mjs rebuild" -ForegroundColor Gray
    Write-Host "         node .vscode\knowledge\scripts\kb.mjs finish-check" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────
# 完成提示
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "             初始化完成！                       " -ForegroundColor Green
Write-Host "════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "後續步驟：" -ForegroundColor White
Write-Host "  1. 填入 .vscode/copilot-instructions.md 的「技術棧」「專案架構」「測試規範」三節" -ForegroundColor Gray
Write-Host "  2. 填入 .vscode/knowledge/INDEX.md 的「Quick Context」與「模組導航」" -ForegroundColor Gray
Write-Host "  3. 在 Copilot Chat 輸入 '/' 並選擇 'start-task' / 'start-plan' / 'end-task'" -ForegroundColor Gray
Write-Host "  4. 累積 1–2 個 trap 後，把常見主題加入 .vscode/knowledge/traps/topics-taxonomy.yml" -ForegroundColor Gray
if (-not $SkipOpenSpec) {
    Write-Host "  5. 填入 .vscode/openspec/config.yaml 的 context 區（技術棧、程式碼路徑、模組）" -ForegroundColor Gray
    Write-Host "  6. 執行 .\opsx new change <change-name> 建立第一個 OpenSpec change" -ForegroundColor Gray
}
if ($EnableRtkHints) {
  Write-Host "  RTK. 若已安裝 rtk，可參考 rtk-cheatsheet.md；未安裝時維持原命令即可" -ForegroundColor Gray
}
Write-Host ""
Write-Host "建議在 .gitignore 加入：" -ForegroundColor White
Write-Host "    .vscode/" -ForegroundColor Gray
if (-not $SkipOpenSpec) {
    Write-Host "    /opsx.bat" -ForegroundColor Gray
    Write-Host "    /opsx.ps1" -ForegroundColor Gray
}
Write-Host "（每位協作者各自維護自己的本機 AI 知識庫，不必強制共用）" -ForegroundColor DarkGray
Write-Host ""

# ─────────────────────────────────────────────────────────────
# 重新啟動 VSCode
# ─────────────────────────────────────────────────────────────
Write-Host "────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  [重要] VSCode 必須重新載入視窗，prompt 指令才會出現在 Copilot Chat 視窗中" -ForegroundColor Yellow
Write-Host ""

$codeCmd = Get-Command 'code' -ErrorAction SilentlyContinue
if ($codeCmd) {
    $reloadPrompt = Read-Host "  是否要現在重新載入 VSCode 視窗？(Y/n)"
    if ($reloadPrompt -eq '' -or $reloadPrompt -match '^[Yy]') {
        Start-Process -FilePath "code" -ArgumentList "--reuse-window `"$projectRoot`""
        Write-Host "  [完成] VSCode 已重新載入，請在 Copilot Chat 試著輸入 /start-task" -ForegroundColor Green
    } else {
        Write-Host "  請手動：Ctrl+Shift+P → 'Reload Window'" -ForegroundColor Yellow
    }
} else {
    Write-Host "  請手動：Ctrl+Shift+P → 'Reload Window'" -ForegroundColor Yellow
}
Write-Host ""
