---
id: 1
title: RTK terminal hints are optional
module: Tooling
date: "2026-05-27"
related_traps: []
---
## 決策

RTK terminal 輸出壓縮只作為 opt-in hints 導入：`init-kb.ps1` 與 `update-kb.ps1` 需使用 `-EnableRtkHints` 才產生 RTK prompt 規則與 `rtk-cheatsheet.md`。

RTK 不自動安裝、不修改全域 hook、不成為 `kb.mjs` / OpenSpec / prompt 流程的硬性相依。未安裝 RTK、RTK 輸出不足或 RTK 指令失敗時，必須回退原命令並依 Agent Guard 記錄 sanitized failure。

## 原因

RTK 解決的是 terminal 輸出過長與 token 成本問題，不負責保存 OpenSpec 行為契約、knowledge trap、facet、FTS5 或 repair closure。將 RTK 放在選配工具層，可以讓高輸出命令受益，同時避免 native Windows / PowerShell 環境因 hook 限制或未安裝 RTK 而失敗。
