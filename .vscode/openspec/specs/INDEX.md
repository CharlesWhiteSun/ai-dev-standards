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