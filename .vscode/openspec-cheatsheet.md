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