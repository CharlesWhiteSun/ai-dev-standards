# VSCode 本機 AI 知識庫初始化工具

透過一鍵腳本，在任何專案中建立結構化的 AI 協作知識庫，讓 GitHub Copilot Chat 在每次對話中都能遵守統一的撰寫規範、理解專案架構，並自動執行任務收尾流程。

---

## 目錄

- [功能概覽](#功能概覽)
- [建立的目錄結構](#建立的目錄結構)
- [快速開始](#快速開始)
- [指令說明](#指令說明)
- [知識庫檔案說明](#知識庫檔案說明)
- [腳本參數](#腳本參數)
- [設計理念](#設計理念)
- [注意事項](#注意事項)
- [授權條款](#授權條款)

---

## 功能概覽

| 功能 | 說明 |
|------|------|
| **一鍵初始化** | 執行單一腳本，完整建立 AI 協作所需的知識庫與提示詞 |
| **撰寫規範** | 內建通用 AI 程式撰寫規範（SOLID、測試要求、命名慣例等） |
| **架構知識庫** | 提供可填寫的專案架構模板，供 AI 快速掌握上下文 |
| **互動式 KB 更新** | `/update-kb` 指令讓 AI 掃描專案並互動式更新知識庫 |
| **任務收尾自動化** | 每次任務完成後自動摘要、更新 KB、產生 Commit 訊息 |
| **本機隔離** | 所有知識庫檔案存於 `.vscode/`，不上傳 git，避免影響協作者 |

---

## 建立的目錄結構

```
專案根目錄/
├── init-kb.ps1                         ← 本腳本
└── .vscode/
    ├── settings.json                   ← VSCode Copilot 提示詞路徑設定
    ├── kb/
    │   ├── coding-rules.md             ← AI 程式撰寫規範（通用）
    │   ├── architecture.md             ← 專案架構知識庫（可填寫 / 自動更新）
    │   └── kb-update-rules.md          ← /update-kb 掃描與維護規則
    └── prompts/
        ├── start-task.prompt.md        ← /start-task 指令
        ├── end-task.prompt.md          ← /end-task 指令
        └── update-kb.prompt.md         ← /update-kb 指令
```

> `.vscode/` 建議加入 `.gitignore`，每位協作者各自維護自己的本機知識庫。

---

## 快速開始

### 前置需求

- Windows PowerShell 5.1 或更新版本
- Visual Studio Code（含 GitHub Copilot Chat 擴充功能）

### 步驟

**1. 將腳本複製到專案根目錄**

```
專案根目錄/
└── init-kb.ps1
```

**2. 在專案根目錄執行腳本**

```powershell
.\init-kb.ps1
```

**3. 重新載入 VSCode 視窗**

按 `Ctrl+Shift+P`，輸入 `Reload Window` 並按 Enter，讓提示詞指令生效。

**4. 在 Copilot Chat 輸入 `/start-task` 開始使用**

---

## 指令說明

初始化完成後，可在 VSCode Copilot Chat 中使用以下三個 `/` 指令：

### `/start-task` — 任務開始

**使用時機**：每次開始新任務或新對話時執行。

**執行流程**：
1. 讀取 `coding-rules.md`（撰寫規範）與 `architecture.md`（專案架構）
2. 以繁體中文摘要最重要的 5 條規範與專案上下文快照
3. 確認知識庫載入完畢後，接收任務需求
4. 任務完成後，**自動執行收尾流程**（無需額外輸入指令）：
   - 本次任務摘要（修改檔案、測試結果）
   - 確認並清除臨時檔案
   - 提出 `architecture.md` 更新建議
   - 產生標準格式 Commit 訊息

---

### `/end-task` — 任務收尾

**使用時機**：需要單獨執行收尾流程時（獨立於 `/start-task` 之外）。

**執行流程**：
1. 列出本次已完成工作與測試結果
2. 確認是否有臨時檔案需要清理（等待使用者確認才刪除）
3. 讀取 `architecture.md`，提出更新草稿並確認後寫入
4. 產生標準格式 Commit 訊息

---

### `/update-kb` — 互動式知識庫更新

**使用時機**：首次建立知識庫後、專案結構有重大異動後，或需要重新整理 `architecture.md` 時。

**執行流程**：
1. 讀取 `kb-update-rules.md`、`architecture.md`、`coding-rules.md`
2. 依規則掃描專案：偵測技術棧、目錄結構（最深 3 層）、Build / Test 指令
3. 評估是否需要拆分額外 KB 檔案（超過 60 行且獨立性高時）
4. 產生 `architecture.md` 更新草稿並摘要變更
5. **使用者確認後**才寫入，絕不靜默覆蓋既有內容

---

## 知識庫檔案說明

### `kb/coding-rules.md` — AI 程式撰寫規範

內建以下通用規範，適用於所有專案：

| 章節 | 內容摘要 |
|------|---------|
| **核心設計原則** | SOLID 五大原則對照表、低耦合高內聚要求、絕對禁止事項 |
| **測試要求** | 單元測試 + 整合測試規則、命名格式、測試獨立性 |
| **程式碼組織** | 檔案結構規範、命名慣例對照表 |
| **維護性要求** | 函式長度、巢狀層數、臨時檔案清理規則 |
| **AI 回應規範** | 語言（繁體中文）、Commit 訊息格式 |

### `kb/architecture.md` — 專案架構知識庫

初始為模板格式，可手動填寫或透過 `/update-kb` 自動更新，包含：

- 專案基本資訊（名稱、技術棧、模組路徑）
- 目錄結構
- 模組 / Package 職責對應表
- Build / Test 指令
- 慣例與規範（專案特定）
- 重要介面 / API 端點
- 已知雷區與決策紀錄（累積式，絕不刪除）

### `kb/kb-update-rules.md` — KB 更新規則指南

規範 `/update-kb` 的行為，包含：

- 掃描時必須排除的目錄清單（`.git/`、`node_modules/`、`vendor/` 等）
- 技術棧偵測對應表（Go、Node.js、Python、Rust、Java、C#、Ruby、PHP）
- 各 KB 章節的更新策略（覆蓋 / 合併 / 只新增不刪除）
- 何時應拆分額外 KB 檔案的判斷條件

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

### 本機隔離，不干擾協作

知識庫存於 `.vscode/`，建議加入 `.gitignore`。每位開發者維護自己的本機 AI 知識庫，不強制所有協作者都使用相同的 AI 工作流程。

### 非破壞性設計

- 預設不覆蓋已存在的檔案
- `settings.json` 永遠不覆蓋，只在缺少必要設定時提示手動補充
- `/update-kb` 的「已知雷區與決策紀錄」欄位只增不減

### 收尾流程內建於任務中

使用 `/start-task` 開始任務後，AI 在完成每次修改時會**自動**執行收尾（摘要 → 清理 → 更新 KB → Commit 訊息），無需記得額外執行 `/end-task`。

---

## 注意事項

1. **首次使用**：執行腳本後必須重新載入 VSCode 視窗，`/start-task` 等指令才會出現在 Copilot Chat 的 `/` 選單中。

2. **`architecture.md` 初始為空白模板**：建議在使用 `/start-task` 前，先執行 `/update-kb` 讓 AI 自動填充基本資訊，或手動填寫 `.vscode/kb/architecture.md`。

3. **`.gitignore` 設定**：若要避免知識庫上傳至版控，請確認 `.gitignore` 中已包含 `.vscode/`。

4. **執行原則問題**：若遇到 PowerShell 執行原則限制，可使用以下指令暫時允許執行：
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\init-kb.ps1
   ```

---

## 授權條款

本專案採用 [Apache License 2.0](LICENSE) 授權。

```
Copyright 2026 CharlesWhiteSun

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

### 授權重點說明

| 項目 | 說明 |
|------|------|
| **允許** | 個人使用、商業使用、修改、散布、專利授權、私人使用 |
| **要求** | 保留原始著作權聲明與授權條款；若有修改，須於修改檔案中標明 |
| **禁止** | 使用本專案貢獻者的商標或品牌名稱進行背書或宣傳 |
| **無擔保** | 本軟體依「現狀」提供，作者不負任何明示或默示的擔保責任 |
