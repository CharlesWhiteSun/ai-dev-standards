#Requires -Version 5.1
<#
.SYNOPSIS
    VSCode 本機 AI 知識庫初始化腳本

.DESCRIPTION
    在 .vscode/ 目錄下建立 AI 撰寫規範與專案架構知識庫模板，
    並設定 VSCode Copilot Chat 的提示詞位置。

    建立的目錄結構：
        init-kb.ps1                    (本腳本，放在專案根目錄)
        .vscode/
        ├── settings.json          (VSCode Copilot 提示詞位置設定)
        ├── kb/
        │   ├── coding-rules.md   (AI 撰寫規範 — 通用)
        │   └── architecture.md   (專案架構摘要)
        └── prompts/
            ├── start-task.prompt.md  (/start-task 指令)
            └── end-task.prompt.md    (/end-task 指令)

    知識庫檔案儲存於 .vscode/（已在 .gitignore 中，不上傳 git）。
    腳本本身放在專案根目錄，可直接以 .\init-kb.ps1 執行。

.NOTES
    執行方式（在專案根目錄）：
        .\init-kb.ps1

    若 .vscode 目錄不存在，腳本會自動建立。
    已存在的檔案預設不覆蓋（加 -Force 強制覆蓋）。

.PARAMETER Force
    若指定，覆蓋已存在的知識庫檔案（不覆蓋 settings.json）。
#>

[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 強制 Console 輸出使用 UTF-8，避免中文亂碼
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ─────────────────────────────────────────────────────────────
# 工具函式
# ─────────────────────────────────────────────────────────────

function Write-Utf8File {
    <#
    .SYNOPSIS 以 UTF-8 NoBOM 寫入檔案（若父目錄不存在則自動建立）#>
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
        Write-Host "  [略過] 已存在: $(Resolve-Path $Path -Relative 2>$null)" -ForegroundColor Yellow
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

# 不論腳本放在根目錄或 .vscode/ 下，一律將知識庫寫入 .vscode/ 子目錄
$projectRoot = $PSScriptRoot
$vscodeDir   = Join-Path $projectRoot '.vscode'

# 取得 git tag 版本號（含 dirty 狀態編碼，格式範例：v1.2-3-gabcdef-dirty）
$gitVersion = 'v1.0'
try {
    $gitDescribe = & git describe --tags --always --dirty 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitDescribe) { $gitVersion = $gitDescribe.Trim() }
} catch {}

Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "     VSCode 本機 AI 知識庫初始化工具 $gitVersion       " -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "專案根目錄 : $projectRoot"
Write-Host "知識庫目錄 : $vscodeDir"
Write-Host ""

if ($Force) {
    Write-Host "  [模式] 強制覆蓋已存在的知識庫檔案" -ForegroundColor Magenta
}

# ─────────────────────────────────────────────────────────────
# 1. settings.json（永遠不覆蓋，避免破壞使用者自訂設定）
# ─────────────────────────────────────────────────────────────
Write-Section "建立 settings.json"

$settingsPath = Join-Path $vscodeDir 'settings.json'
if (-not (Test-Path $settingsPath)) {
    $settingsContent = @'
{
  "chat.promptFilesLocations": {
    ".vscode/prompts": true
  }
}
'@
    Write-Utf8File -Path $settingsPath -Content $settingsContent
} else {
    # 已存在：只確認必要 key 存在，不覆蓋整個檔案
    $existing = Get-Content $settingsPath -Raw -Encoding UTF8
    if ($existing -notmatch 'chat\.promptFilesLocations') {
        Write-Host "  [警告] settings.json 已存在但缺少 chat.promptFilesLocations 設定。" -ForegroundColor Yellow
        Write-Host "         請手動加入以下設定：" -ForegroundColor Yellow
        Write-Host '         "chat.promptFilesLocations": { ".vscode/prompts": true }' -ForegroundColor Gray
    } else {
        Write-Host "  [略過] settings.json 已包含所需設定" -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────────────────────
# 2. kb/coding-rules.md — 通用 AI 撰寫規範
# ─────────────────────────────────────────────────────────────
Write-Section "建立 kb/coding-rules.md"

$codingRulesContent = @'
# AI 程式碼撰寫規範

> 本檔案為 AI 程式碼協作的通用規範，適用於本專案所有對話階段。
> 由 `init-kb.ps1` 建立，儲存於本機（不上傳 git）。

---

## 一、核心設計原則

### 1.1 SOLID 設計模式（必須遵守）

| 原則 | 說明 | 違規範例（禁止） |
|------|------|-----------------|
| **S** — 單一職責 | 每個 class / function / 檔案只負責一件事 | 一個函式同時處理 HTTP 請求、資料驗證、資料庫寫入 |
| **O** — 開放封閉 | 對擴充開放，對修改封閉；透過介面新增行為 | 每次加新功能就修改既有 if-else 鏈 |
| **L** — 里氏替換 | 子型別可替換父型別，不破壞程式行為 | 覆寫方法後拋出原本不存在的例外 |
| **I** — 介面隔離 | 介面小而精，不強迫實作用不到的方法 | 一個介面同時定義 20 個方法 |
| **D** — 依賴反轉 | 依賴抽象（介面），不依賴具體實作 | Handler 直接 new 具體 DB 連線物件 |

### 1.2 低耦合、高內聚、高隔離

- **低耦合**：模組間只透過介面／合約溝通，避免直接依賴具體型別
- **高內聚**：相關邏輯集中在同一 package／module，不相關的拆分至獨立模組
- **高隔離**：外部依賴（HTTP、DB、檔案 IO、時間）必須透過可注入介面封裝

### 1.3 絕對禁止事項

- 禁止硬編碼常數、路徑、URL、連接埠、金鑰、Timeout 數值
- 禁止將不相關邏輯堆疊在同一函式或檔案中
- 禁止忽略錯誤（swallow errors）— 必須傳回或記錄
- 禁止在程式流程中留下除錯用輸出（fmt.Println、console.log、print()）
- 禁止重複邏輯（DRY 原則）— 必須提取為共用函式或介面

---

## 二、測試要求

### 2.1 必備測試規則

每次程式碼新增、修改或重構，都必須同步新增對應測試：

| 測試類型 | 目的 | 驗收標準 |
|----------|------|----------|
| **單元測試** | 驗證單一函式／方法的邏輯 | 覆蓋正常路徑 + 邊界情況 + 錯誤路徑 |
| **整合測試** | 驗證多個元件協作行為 | 模擬真實使用場景，外部依賴用 Fake |

- 修改完成後必須完整執行所有測試，確保新舊程式碼功能皆正常
- 不可因測試繁瑣而省略測試步驟

### 2.2 測試品質規範

- **命名格式**：`Test{被測函式}_{場景描述}_{預期結果}`
  → 範例：`TestLogin_WhenPasswordEmpty_ReturnError`
- **測試獨立**：每個測試案例不共享可變狀態，執行順序任意
- **依賴替換**：使用 Fake / Stub / Mock 替換外部依賴，不發真實網路請求
- **測試位置**：`<被測試檔案名>_test.<副檔名>` 放在同一目錄

---

## 三、程式碼組織

### 3.1 檔案結構

- 同一職責的程式碼集中在同一檔案；一個檔案只做一件事
- 共用工具函式、型別獨立成專屬模組
- 設定值、常數集中管理，禁止散落於業務邏輯
- 禁止把不相關的新功能堆疊進現有檔案

### 3.2 命名規範

| 對象 | 規則 | 範例 |
|------|------|------|
| 函式／方法 | 動詞開頭，描述行為 | ParseURL、validateInput、BuildReport |
| 型別／類別 | 名詞，表達抽象概念 | HTTPClient、UserRepository |
| 介面 | 名詞（Go 加 -er 後綴） | Runner、Dispatcher、Locator |
| 常數 | 全大寫或 PascalCase（依語言慣例） | MaxRetries、DEFAULT_TIMEOUT |
| 測試函式 | 描述被測函式 + 場景 + 預期結果 | TestDial_WhenTimeout_ReturnError |

---

## 四、維護性要求

### 4.1 可讀性

- 函式長度建議不超過 40 行；超過時拆分為更小的職責
- 巢狀層數建議不超過 3 層；超過時使用 early return 或提取函式
- 複雜邏輯必須有中文說明為什麼這麼做，而非描述做了什麼

### 4.2 臨時檔案清理

- 開發過程中新增的一次性驗證腳本、暫時測試檔，任務結束前必須移除
- 移除前必須確認：該檔案與主程式流程及正式測試無關
- 若不確定是否可移除，詢問使用者後再操作

---

## 五、AI 回應規範

- 所有回覆內容必須以繁體中文撰寫
- 程式碼中的識別碼以英文命名；程式碼中的註解可使用中文
- 主動提示潛在的設計缺陷，不要只做使用者問到的部分

### 5.1 Commit 訊息格式

```
{feat/fix/hotfix/refactor/chore/docs/test}({模組名}) 摘要說明（繁中）

問題:
{問題說明}

變更:
{變更說明}

測試:
{測試說明（有測試時才提供）}
```
'@

Write-Utf8File -Path (Join-Path $vscodeDir 'kb\coding-rules.md') -Content $codingRulesContent -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 3. kb/architecture.md — 初始空白模板
# ─────────────────────────────────────────────────────────────
Write-Section "建立 kb/architecture.md（初始模板）"

$archTemplatePath = Join-Path $vscodeDir 'kb\architecture.md'

$archTemplate = @'
# 專案架構知識庫

> 本檔案由 `init-kb.ps1` 初始化，儲存於本機（不上傳 git）。
> 請完善各欄位，或重新執行根目錄的 init-kb.ps1 並選擇掃描選項以自動填充基本資訊。
> 每次任務結束後，透過 `/end-task` 讓 AI 協助更新「已知雷區與決策紀錄」章節。

---

## 專案基本資訊

- **專案名稱**：（請填入）
- **技術棧**：（請填入，e.g. Go 1.24、React 18、Python 3.12）
- **模組 / 套件名稱**：（請填入）
- **主要功能描述**：（請填入）
- **儲存庫 URL**：（請填入）

---

## 目錄結構

```
（請填入，或執行根目錄的 init-kb.ps1 並選擇掃描選項以自動生成）
```

---

## 模組 / Package 職責

| 模組 / 目錄 | 職責說明 |
|-------------|----------|
| （請填入）  | （請填入） |

---

## Build / Test 指令

```bash
# 建置
（請填入）

# 執行全套測試
（請填入）

# Lint / Vet / Format
（請填入）
```

---

## 慣例與規範（專案特定）

- （請填入，e.g. 禁止 package A import package B、命名特例、依賴方向規則）

---

## 重要介面 / API 端點

- （請填入核心介面定義、REST API 端點、重要資料結構）

---

## 已知雷區與決策紀錄

| 日期 | 類型 | 說明 |
|------|------|------|
| （由 /end-task 填入） | 決策 / 雷區 | （說明） |
'@

Write-Utf8File -Path $archTemplatePath -Content $archTemplate -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 4. prompts/start-task.prompt.md
# ─────────────────────────────────────────────────────────────
Write-Section "建立 prompts/start-task.prompt.md"

$startTaskContent = @'
---
name: start-task
description: "Use when: 開始新任務、start task、載入知識庫、task start。每次對話開始時執行，讓 AI 讀取撰寫規範與專案架構知識庫"
agent: agent
tools:[vscode, execute, read, agent, edit, search, web, browser, vscode.mermaid-chat-features/renderMermaidDiagram, cweijan.vscode-database-client2/dbclient-getDatabases, cweijan.vscode-database-client2/dbclient-getTables, cweijan.vscode-database-client2/dbclient-executeQuery, ms-azuretools.vscode-containers/containerToolsConfig, ms-python.python/getPythonEnvironmentInfo, ms-python.python/getPythonExecutableCommand, ms-python.python/installPythonPackage, ms-python.python/configurePythonEnvironment, vscjava.vscode-java-debug/debugJavaApplication, vscjava.vscode-java-debug/setJavaBreakpoint, vscjava.vscode-java-debug/debugStepOperation, vscjava.vscode-java-debug/getDebugVariables, vscjava.vscode-java-debug/getDebugStackTrace, vscjava.vscode-java-debug/evaluateDebugExpression, vscjava.vscode-java-debug/getDebugThreads, vscjava.vscode-java-debug/removeJavaBreakpoints, vscjava.vscode-java-debug/stopDebugSession, vscjava.vscode-java-debug/getDebugSessionInfo, todo]
---

你是本專案的 AI 程式碼協作者。在回應任何任務需求之前，請嚴格依照以下步驟執行：

---

## 步驟 1：載入知識庫

請使用工具讀取以下兩個本機知識庫檔案的完整內容，不可省略：

1. **程式撰寫規範** → `.vscode/kb/coding-rules.md`
2. **專案架構摘要** → `.vscode/kb/architecture.md`

---

## 步驟 2：確認並摘要（以繁體中文回覆）

讀取完畢後，輸出以下結構：

### 已載入的核心規範（列出最重要的 5 條）

（從 coding-rules.md 提取最重要的規則，條列說明）

### 專案上下文快照

- **專案名稱 / 技術棧**：（從 architecture.md 提取）
- **主要模組與職責**：（從 architecture.md 提取，若未填寫請說明）
- **Build / Test 指令**：（從 architecture.md 提取，若未填寫請說明）

> 若 `architecture.md` 尚未填入任何內容，請提醒使用者：
> 「架構知識庫尚未建立，建議先在專案根目錄執行 `.\init-kb.ps1` 並選擇掃描選項，或手動填寫 `.vscode\kb\architecture.md`。」

---

## 步驟 3：準備就緒

完成上述摘要後，說：

> 「知識庫已載入完畢。本次對話我將遵守 coding-rules.md 中的所有規範，並以繁體中文回覆。請告訴我本次任務的需求。」

---

## 步驟 4：執行任務

接收使用者的任務需求並完整實作。

---

## 步驟 5：任務收尾（每次完成修改後自動執行，無需使用者提示）

**每當完成一個任務的所有程式碼修改後，立即依序執行以下收尾步驟：**

### 5-1：本次任務摘要

請以繁體中文列出：

1. **已完成的工作**
   - 修改了哪些檔案（列出路徑）
   - 新增了哪些功能、邏輯或修正了哪些 Bug

2. **執行的測試**
   - 新增了哪些測試（測試名稱與測試目的）
   - 所有測試是否通過

3. **尚未完成的事項**（若有，說明原因）

### 5-2：臨時檔案確認

請確認並回覆：

- 本次開發過程中是否產生了一次性驗證腳本或暫時測試檔案？
- 若有，逐一列出完整路徑，並詢問使用者：「是否可以移除以下暫時檔案？」
- 等待使用者確認後再執行刪除，不可自行決定

### 5-3：知識庫更新

1. 使用工具讀取 `.vscode/kb/architecture.md` 的現有完整內容
2. 根據本次任務發現的新資訊（新模組職責、架構慣例、禁止事項、重要決策），提出具體的更新段落
3. 顯示應加入「已知雷區與決策紀錄」資料表的新列（格式：`| 日期 | 類型 | 說明 |`）
4. 詢問使用者：「是否要將以上更新寫入 `.vscode/kb/architecture.md`？」
5. 使用者確認後，用工具將更新內容寫入檔案

### 5-4：Commit 訊息

根據本次變更，產生以下格式的 commit 訊息（整合在一個可直接複製的純文字區塊）：

```
{feat/fix/hotfix/refactor/chore/docs/test}({模組名}) 摘要說明（繁中）

問題:
{問題說明}

變更:
{變更說明}

測試:
{測試說明（有單元或整合測試時才提供）}
```

完成後說：「任務收尾完成。知識庫已更新，commit 訊息如上。」
'@

Write-Utf8File -Path (Join-Path $vscodeDir 'prompts\start-task.prompt.md') -Content $startTaskContent -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 5. prompts/end-task.prompt.md
# ─────────────────────────────────────────────────────────────
Write-Section "建立 prompts/end-task.prompt.md"

$endTaskContent = @'
---
name: end-task
description: "Use when: 任務完成後、end task、task end、更新知識庫、任務收尾。任務結束時執行以更新本機知識庫並完成收尾"
agent: agent
tools:[vscode, execute, read, agent, edit, search, web, browser, vscode.mermaid-chat-features/renderMermaidDiagram, cweijan.vscode-database-client2/dbclient-getDatabases, cweijan.vscode-database-client2/dbclient-getTables, cweijan.vscode-database-client2/dbclient-executeQuery, ms-azuretools.vscode-containers/containerToolsConfig, ms-python.python/getPythonEnvironmentInfo, ms-python.python/getPythonExecutableCommand, ms-python.python/installPythonPackage, ms-python.python/configurePythonEnvironment, vscjava.vscode-java-debug/debugJavaApplication, vscjava.vscode-java-debug/setJavaBreakpoint, vscjava.vscode-java-debug/debugStepOperation, vscjava.vscode-java-debug/getDebugVariables, vscjava.vscode-java-debug/getDebugStackTrace, vscjava.vscode-java-debug/evaluateDebugExpression, vscjava.vscode-java-debug/getDebugThreads, vscjava.vscode-java-debug/removeJavaBreakpoints, vscjava.vscode-java-debug/stopDebugSession, vscjava.vscode-java-debug/getDebugSessionInfo, todo]
---

任務即將收尾。請依序完成以下步驟，每步驟完成後才進入下一步：

---

## 步驟 1：本次任務摘要

請以繁體中文列出：

1. **已完成的工作**
   - 修改了哪些檔案（列出路徑）
   - 新增了哪些功能、邏輯或修正了哪些 Bug

2. **執行的測試**
   - 新增了哪些測試（測試名稱與測試目的）
   - 所有測試是否通過

3. **尚未完成的事項**（若有，說明原因）

---

## 步驟 2：臨時檔案確認

請確認並回覆：

- 本次開發過程中是否產生了一次性驗證腳本或暫時測試檔案？
- 若有，逐一列出完整路徑，並詢問使用者：「是否可以移除以下暫時檔案？」
- 等待使用者確認後再執行刪除，不可自行決定

---

## 步驟 3：知識庫更新

1. 使用工具讀取 `.vscode/kb/architecture.md` 的現有完整內容
2. 根據本次任務發現的新資訊（新模組職責、架構慣例、禁止事項、重要決策），提出具體的更新段落
3. 顯示應加入「已知雷區與決策紀錄」資料表的新列（格式：`| 日期 | 類型 | 說明 |`）
4. 詢問使用者：「是否要將以上更新寫入 `.vscode/kb/architecture.md`？」
5. 使用者確認後，用工具將更新內容寫入檔案

---

## 步驟 4：Commit 訊息

根據本次變更，產生以下格式的 commit 訊息（整合在一個可直接複製的純文字區塊）：

```
{feat/fix/hotfix/refactor/chore/docs/test}({模組名}) 摘要說明（繁中）

問題:
{問題說明}

變更:
{變更說明}

測試:
{測試說明（有單元或整合測試時才提供）}
```

---

完成後說：「任務收尾完成。知識庫已更新，commit 訊息如上。」
'@

Write-Utf8File -Path (Join-Path $vscodeDir 'prompts\end-task.prompt.md') -Content $endTaskContent -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 6. kb/kb-update-rules.md — update-kb 專用掃描與維護規則
# ─────────────────────────────────────────────────────────────
Write-Section "建立 kb/kb-update-rules.md"

$kbUpdateRulesContent = @'
# 知識庫更新規則指南

> 本檔案供 AI 執行 `/update-kb` 時遵守，規範專案掃描方式、知識庫架構與維護規則。
> 由 `init-kb.ps1` 建立，儲存於本機（不上傳 git）。

---

## 一、專案掃描規則

### 1.1 必須排除的目錄（不掃描）

| 目錄 / 模式 | 排除原因 |
|------------|---------|
| `.git/` | 版控內部資料，非專案程式碼 |
| `node_modules/` | 第三方依賴，非本專案原始碼 |
| `vendor/` | Go vendor 目錄，第三方套件 |
| `bin/`、`dist/`、`build/`、`out/` | 建置輸出，非原始碼 |
| `.vscode/` | 編輯器設定與知識庫本身，避免循環讀取 |
| `logs/`、`*.log` | 執行期日誌，非架構資訊 |
| `__pycache__/`、`*.pyc` | Python 編譯快取 |
| `.idea/`、`.DS_Store` | IDE / OS 產生的雜訊檔案 |
| `coverage/`、`*.out`、`*.test` | 測試覆蓋率輸出 |
| `tmp/`、`temp/` | 暫存目錄 |

### 1.2 掃描深度規範

- **目錄樹**：最大深度 **3 層**（避免過度展開導致輸出過長）
- **原始碼讀取**：只讀取**主要進入點**（`main.go`、`index.ts`、`app.py`、`Program.cs`、`server.go`）與**介面定義檔**；不需逐一讀取所有實作檔案
- **設定檔**：讀取第一層的 `Makefile`、`docker-compose.yml`、`Dockerfile` 即可，不深入子目錄

### 1.3 技術棧偵測對應表

| 偵測到的檔案 | 判斷技術棧 | 額外讀取目標 |
|-------------|-----------|------------|
| `go.mod` | Go | `go.sum` 的前 5 行（看主要依賴） |
| `package.json` | Node.js / TypeScript | `tsconfig.json`（若存在） |
| `pyproject.toml` 或 `requirements.txt` | Python | `pyproject.toml` 的 `[tool.poetry]` 段落 |
| `Cargo.toml` | Rust | `Cargo.toml` 的 `[dependencies]` 段落 |
| `pom.xml` | Java / Maven | `pom.xml` 的 `<dependencies>` 前 30 行 |
| `build.gradle` | Java / Kotlin / Gradle | `build.gradle` 的 `dependencies` 區塊 |
| `*.csproj` 或 `*.sln` | C# / .NET | `*.csproj` 的 `<PackageReference>` 列表 |
| `Gemfile` | Ruby | `Gemfile` 完整內容 |
| `composer.json` | PHP | `composer.json` 的 `require` 段落 |

---

## 二、知識庫架構規範

### 2.1 核心知識庫檔案（固定，`init-kb.ps1` 已建立，不可刪除）

| 檔案 | 負責內容 |
|------|---------|
| `coding-rules.md` | 通用 AI 程式撰寫規範（不因專案而異） |
| `architecture.md` | 本專案架構快照（目錄、模組、Build 指令、雷區紀錄） |
| `kb-update-rules.md` | 本檔案；知識庫掃描、架構與維護規則 |

### 2.2 何時應拆分額外 KB 檔案

**預設優先把所有資訊填入 `architecture.md`**。只有同時符合以下兩個條件時才建立額外檔案：

1. 該主題的資訊**超過 60 行**
2. 該主題**獨立性高**，與架構概覽無直接關聯

| 符合條件的情境 | 建議新增的 KB 檔案 | 負責內容 |
|--------------|-----------------|---------|
| REST / gRPC / GraphQL 端點超過 20 個 | `api-contracts.md` | 端點路由、請求/回應格式、認證方式 |
| 多個獨立微服務各自有不同技術棧 | `services-overview.md` | 各服務名稱、職責、通訊方式、端口 |
| 資料庫 Schema 複雜且需追蹤 migration 歷史 | `db-schema.md` | 資料表結構、關聯、索引、Migration 紀錄 |
| 有明確的 CI/CD 或部署流程規範 | `deployment.md` | 環境變數、部署步驟、回滾程序 |

> **原則**：只在資訊量確實超標時才拆分；拆分後須在 `architecture.md` 的對應章節加入指向新檔案的備註。

---

## 三、`architecture.md` 各章節更新規則

| 章節 | 可寫入的內容 | 更新策略 |
|------|------------|---------|
| 專案基本資訊 | 名稱、技術棧、模組路徑、功能描述 | **可覆蓋**（以最新掃描結果為準） |
| 目錄結構 | 深度 2–3 的目錄樹（排除雜訊目錄） | **可覆蓋**（以最新掃描為準） |
| 模組 / Package 職責 | 各目錄的職責說明 | **合併更新**（保留人工補充的說明，新增掃描到但尚未記錄的模組） |
| Build / Test 指令 | build、test、lint、format 指令 | **可覆蓋**（以掃描到的腳本為準） |
| 慣例與規範 | 專案特有的禁止事項、命名規則 | **只可新增，不可刪除** |
| 重要介面 / API 端點 | 核心介面定義、REST 路由 | **合併更新** |
| 已知雷區與決策紀錄 | 日期、類型、說明（表格列） | **絕對不可刪除任何既有列，只可新增** |

### 3.1 永遠保留、不可覆蓋的內容

- 「已知雷區與決策紀錄」表格中的**所有既有列**
- 「慣例與規範」中**人工填寫**的條目
- 任何章節末尾以 `> 備註：` 開頭的手動補充說明

---

## 四、AI 執行 `/update-kb` 的行為規範

1. **語言**：全程使用**繁體中文**
2. **草稿先確認**：產生更新草稿後，必須先以條列方式摘要「新增了什麼」、「修改了什麼」，等使用者明確確認後才寫入檔案
3. **不可靜默覆蓋**：任何現有內容的刪除或修改都必須明確告知使用者
4. **無法判斷時詢問**：若某模組職責無法從目錄名稱或檔案內容推斷，應詢問使用者而非自行猜測
5. **拆分前先詢問**：若判斷需要建立額外 KB 檔案，必須先向使用者說明原因並取得同意，再執行建立
'@

Write-Utf8File -Path (Join-Path $vscodeDir 'kb\kb-update-rules.md') -Content $kbUpdateRulesContent -Overwrite:$Force

# ─────────────────────────────────────────────────────────────
# 7. prompts/update-kb.prompt.md（AI 互動式知識庫更新指令）
# ─────────────────────────────────────────────────────────────
Write-Section "建立 prompts/update-kb.prompt.md"

$updateKbContent = @'
---
agent: agent
tools:[vscode, execute, read, agent, edit, search, web, browser, vscode.mermaid-chat-features/renderMermaidDiagram, cweijan.vscode-database-client2/dbclient-getDatabases, cweijan.vscode-database-client2/dbclient-getTables, cweijan.vscode-database-client2/dbclient-executeQuery, ms-azuretools.vscode-containers/containerToolsConfig, ms-python.python/getPythonEnvironmentInfo, ms-python.python/getPythonExecutableCommand, ms-python.python/installPythonPackage, ms-python.python/configurePythonEnvironment, vscjava.vscode-java-debug/debugJavaApplication, vscjava.vscode-java-debug/setJavaBreakpoint, vscjava.vscode-java-debug/debugStepOperation, vscjava.vscode-java-debug/getDebugVariables, vscjava.vscode-java-debug/getDebugStackTrace, vscjava.vscode-java-debug/evaluateDebugExpression, vscjava.vscode-java-debug/getDebugThreads, vscjava.vscode-java-debug/removeJavaBreakpoints, vscjava.vscode-java-debug/stopDebugSession, vscjava.vscode-java-debug/getDebugSessionInfo, todo]
description: 掃描專案並由 AI 互動式更新 .vscode/kb/architecture.md
---
你是一位熟悉專案架構的 AI 助理。請先完整閱讀規則指南，再依步驟執行。

## 步驟 1：載入知識庫與規則指南

使用工具讀取以下三個檔案的**完整內容**，不可省略任何一個：

1. `.vscode/kb/kb-update-rules.md` ← **掃描規則、架構規範、更新規則，執行前必讀**
2. `.vscode/kb/architecture.md` ← 現有專案架構知識庫
3. `.vscode/kb/coding-rules.md` ← 撰寫規範（用於了解專案品質要求）

> 讀取完畢後，確認你已理解 `kb-update-rules.md` 中的掃描排除規則、知識庫架構規範與各章節更新策略，再繼續執行。

## 步驟 2：掃描專案結構

依照 `kb-update-rules.md` 第一章「專案掃描規則」收集以下資訊：

1. **技術棧偵測**：依「1.3 技術棧偵測對應表」查找對應檔案
2. **目錄結構**：列出深度最多 3 層的目錄樹，排除「1.1 必須排除的目錄」清單中的所有目錄
3. **模組職責**：依目錄名稱與主要進入點檔案（`main.go`、`index.ts` 等）推斷各模組職責；無法判斷時稍後詢問使用者
4. **Build / Test 指令**：查找 `Makefile`、`build.ps1`、`package.json` 的 `scripts` 段落
5. **README 摘要**：若有 `README.md`，讀取前 20 行

## 步驟 3：評估是否需要拆分額外 KB 檔案

依照 `kb-update-rules.md` 第二章「2.2 何時應拆分額外 KB 檔案」判斷：

- 若**不需要**拆分，直接進入步驟 4
- 若**需要**拆分，先向使用者說明原因與建議新增的檔案名稱，取得同意後再繼續

## 步驟 4：產生 `architecture.md` 更新草稿

依照 `kb-update-rules.md` 第三章「各章節更新規則」整理更新後的完整內容：

- 依各章節的「更新策略」決定覆蓋或合併
- **絕對不可刪除**「已知雷區與決策紀錄」的任何既有列
- **絕對不可刪除**「慣例與規範」的任何既有條目

## 步驟 5：確認並寫入

1. 以條列方式摘要「本次新增的項目」與「本次修改的項目」
2. 詢問使用者：「是否將以上內容寫入 `.vscode/kb/architecture.md`？(y/n)」
3. 使用者確認後，將完整內容寫入 `.vscode/kb/architecture.md`

完成後說：「知識庫已更新完畢。建議下次任務開始前執行 /start-task 以載入最新知識庫。」
'@

Write-Utf8File -Path (Join-Path $vscodeDir 'prompts\update-kb.prompt.md') -Content $updateKbContent -Overwrite:$Force


# ─────────────────────────────────────────────────────────────
# 完成提示
# ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════════════" -ForegroundColor Green
Write-Host "           初始化完成！            " -ForegroundColor Green
Write-Host "══════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "後續步驟：" -ForegroundColor White
Write-Host "  1. 在 VSCode Copilot Chat 輸入 '/' 並選擇 'start-task'" -ForegroundColor Gray
Write-Host "     → AI 將讀取知識庫、詢問任務需求，並在每次完成修改後自動執行收尾流程" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  2. 輸入 '/update-kb' 讓 AI 掃描專案並互動式更新知識庫" -ForegroundColor Gray
Write-Host "     → AI 將偵測技術棧、目錄結構、Build 指令，確認後寫入 architecture.md" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  3. 若有獨立的收尾需求，可輸入 '/end-task'" -ForegroundColor Gray
Write-Host "     → AI 將摘要任務、更新知識庫、產生 Commit 訊息" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  4. 若需手動編輯知識庫，請直接修改：" -ForegroundColor Gray
Write-Host "     .vscode\kb\architecture.md" -ForegroundColor DarkGray
Write-Host "     .vscode\kb\coding-rules.md" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  注意：建議把 .vscode 目錄加入 .gitignore 中，因為不是所有人都會使用 AI agent，且專案類型不同不適合把自己的知識庫共用給其他協作者。" -ForegroundColor DarkGray
Write-Host ""


# ─────────────────────────────────────────────────────────────
# 重新啟動 VSCode（讓 /start-task 指令生效）
# ─────────────────────────────────────────────────────────────
Write-Host "────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [重要] VSCode 必須重新載入視窗，指令 /start-task 才會出現在 VSCode IDE Copilot Chat 視窗中" -ForegroundColor Yellow
Write-Host ""

$codeCmd = Get-Command 'code' -ErrorAction SilentlyContinue
if ($codeCmd) {
    $reloadPrompt = Read-Host "  是否要現在重新啟動 VSCode？(Y/n)"
    if ($reloadPrompt -eq '' -or $reloadPrompt -match '^[Yy]') {
        Write-Host ""
        Write-Host "  [重啟] 正在重新啟動 VSCode..." -ForegroundColor Cyan
        # 先用 code CLI 重開資料夾（新視窗），再關閉舊視窗
        Start-Process -FilePath "code" -ArgumentList "--reuse-window `"$projectRoot`""
        Start-Sleep -Seconds 2
        Write-Host "  [完成] VSCode 已重新載入必要項目，請在對話視窗中試著輸入 /start-task 並開始使用，祝您使用愉快" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "  請手動重新載入 VSCode：" -ForegroundColor Yellow
        Write-Host "    方法 1（推薦）: 按 Ctrl+Shift+P，輸入 'Reload Window' 並按 Enter" -ForegroundColor Gray
        Write-Host "    方法 2: 關閉 VSCode 後重新開啟此專案資料夾" -ForegroundColor Gray
    }
} else {
    Write-Host "  請手動重新載入 VSCode：" -ForegroundColor Yellow
    Write-Host "    方法 1（推薦）: 按 Ctrl+Shift+P，輸入 'Reload Window' 並按 Enter" -ForegroundColor Gray
    Write-Host "    方法 2: 關閉 VSCode 後重新開啟此專案資料夾" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  提示：如果有需要，你可以馬上在 Copilot Chat 輸入 /update-kb 主動掃描、更新專案的知識庫" -ForegroundColor Cyan
Write-Host ""

