<#
.SYNOPSIS
    Non-destructive upgrade for an existing VS Code local AI knowledge base.

.DESCRIPTION
    This script upgrades projects that already have .vscode/knowledge.
    Default mode is dry-run. Use -Apply to write changes.

    The script is intentionally ASCII-only so Windows PowerShell 5.1 can
    execute it even when the file has no UTF-8 BOM.

.PARAMETER ProjectRoot
    Target project root. Defaults to the current directory.

.PARAMETER Apply
    Write changes. Without this switch the script only prints planned work.

.PARAMETER Backup
    Back up changed files before writing. Defaults to true.

.PARAMETER ForceTemplates
    Replace executable templates such as kb.mjs. Without this switch, a
    kb.mjs.v3.1.candidate file is created instead of overwriting kb.mjs.

.PARAMETER SkipRebuild
    Skip kb.mjs rebuild and finish-check.

.PARAMETER SkipOpenSpec
    Skip OpenSpec scaffold, opsx wrapper, and prompt injection steps.

.PARAMETER NoReloadPrompt
    Suppress the VS Code reload reminder.
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$Apply,
    [bool]$Backup = $true,
    [switch]$ForceTemplates,
    [switch]$SkipRebuild,
    [switch]$SkipOpenSpec,
    [switch]$NoReloadPrompt
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host '------------------------------------------------' -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host '------------------------------------------------' -ForegroundColor DarkGray
}

function Write-Plan {
    param([string]$Message)
    if ($Apply) {
        Write-Host "  [APPLY] $Message" -ForegroundColor Green
    } else {
        Write-Host "  [PLAN]  $Message" -ForegroundColor Yellow
    }
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function Read-Utf8File {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Utf8NoBomEncoding))
}

function Get-RelativePathCompat {
    param([string]$BasePath, [string]$TargetPath)
    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFull += [System.IO.Path]::DirectorySeparatorChar
    }
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    $baseUri = [System.Uri]::new($baseFull)
    $targetUri = [System.Uri]::new($targetFull)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Copy-Backup {
    param([string]$Path)
    if (-not $Backup -or -not (Test-Path $Path)) { return }
    if ($script:BackedUp.ContainsKey($Path)) { return }
    $relative = Get-RelativePathCompat -BasePath $ProjectRootFull -TargetPath $Path
    $target = Join-Path $BackupDir $relative
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path $targetDir)) { [System.IO.Directory]::CreateDirectory($targetDir) | Out-Null }
    [System.IO.File]::Copy($Path, $target, $true)
    $script:BackedUp[$Path] = $true
}

function Save-TextFile {
    param([string]$Path, [string]$Content, [string]$Reason)
    Write-Plan $Reason
    if (-not $Apply) { return }
    Copy-Backup $Path
    Write-Utf8File -Path $Path -Content $Content
}

function Ensure-Directory {
    param([string]$Path, [string]$Reason)
    Write-Plan $Reason
    if ($Apply -and -not (Test-Path $Path)) { [System.IO.Directory]::CreateDirectory($Path) | Out-Null }
}

function Ensure-File {
    param([string]$Path, [string]$Content, [string]$Reason, [switch]$Overwrite)
    if ((Test-Path $Path) -and -not $Overwrite) {
        Write-Host "  [SKIP]  $Reason already exists" -ForegroundColor DarkYellow
        return
    }
    Save-TextFile -Path $Path -Content $Content -Reason $Reason
}

function Append-BlockIfMissing {
    param([string]$Path, [string]$Needle, [string]$Block, [string]$Reason)
    if (-not (Test-Path $Path)) {
        Ensure-File -Path $Path -Content ($Block.TrimStart() + "`n") -Reason $Reason
        return
    }
    $text = Read-Utf8File $Path
    if ($text.Contains($Needle)) {
        Write-Host "  [SKIP]  $Reason already present" -ForegroundColor DarkYellow
        return
    }
    Save-TextFile -Path $Path -Content ($text.TrimEnd() + "`n`n" + $Block.Trim() + "`n") -Reason $Reason
}

function Replace-TextIfMatch {
    param([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Reason)
    if (-not (Test-Path $Path)) { return }
    $text = Read-Utf8File $Path
    if ($text -notmatch $Pattern) { return }
    $newText = [regex]::Replace($text, $Pattern, $Replacement)
    if ($newText -ne $text) { Save-TextFile -Path $Path -Content $newText -Reason $Reason }
}

function Add-JsonPropertyBlock {
    param([string]$Content, [string]$Block)
    $trimmed = $Content.TrimEnd()
    $idx = $trimmed.LastIndexOf('}')
    if ($idx -lt 0) { return $Content }
    $before = $trimmed.Substring(0, $idx).TrimEnd()
    $after = $trimmed.Substring($idx)
    $comma = ''
    if ($before -notmatch '\{\s*$' -and $before -notmatch ',\s*$') { $comma = ',' }
    return $before + $comma + "`n" + $Block.TrimEnd() + "`n" + $after + "`n"
}

function Ensure-PromptLocation {
    param([string]$Content, [string]$Location)
    if ($Content -match ('"' + [regex]::Escape($Location) + '"\s*:\s*true')) { return $Content }
    $pattern = '(?s)("chat\.promptFilesLocations"\s*:\s*\{)(.*?)(\})'
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) { return $Content }
    $body = $match.Groups[2].Value.TrimEnd()
    if ($body.Trim().Length -gt 0 -and $body -notmatch ',\s*$') { $body += ',' }
    $body += "`n    `"$Location`": true`n  "
    return $Content.Substring(0, $match.Groups[2].Index) + $body + $Content.Substring($match.Groups[3].Index)
}

function Repair-SettingsJson {
    param([string]$Path)
    $defaultSettings = @'
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
    if (-not (Test-Path $Path)) {
        Save-TextFile -Path $Path -Content $defaultSettings -Reason 'Create .vscode/settings.json'
        return
    }
    $text = Read-Utf8File $Path
    $next = $text
    if ($next -match '"files\.encoding"\s*:\s*"utf-8"') {
        $next = [regex]::Replace($next, '"files\.encoding"\s*:\s*"utf-8"', '"files.encoding": "utf8"')
    }
    if ($next -notmatch '"chat\.promptFiles"\s*:\s*true') {
        $next = Add-JsonPropertyBlock -Content $next -Block '  "chat.promptFiles": true'
    }
    if ($next -notmatch '"chat\.promptFilesLocations"') {
        $next = Add-JsonPropertyBlock -Content $next -Block @'
  "chat.promptFilesLocations": {
    ".vscode": true,
    ".vscode/prompts": true
  }
'@
    } else {
        $next = Ensure-PromptLocation -Content $next -Location '.vscode'
        $next = Ensure-PromptLocation -Content $next -Location '.vscode/prompts'
    }
    if ($next -notmatch '"files\.encoding"\s*:\s*"utf8"') {
        $next = Add-JsonPropertyBlock -Content $next -Block '  "files.encoding": "utf8"'
    }
    if ($next -eq $text) {
        Write-Host '  [SKIP]  settings.json already has v3.1 settings' -ForegroundColor DarkYellow
    } else {
        Save-TextFile -Path $Path -Content $next -Reason 'Patch settings.json prompt paths and utf8 encoding'
    }
}

function Extract-HereStringFromInit {
    param([string]$VariableName)
    $initPath = Join-Path $PSScriptRoot 'init-kb.ps1'
    if (-not (Test-Path $initPath)) { return $null }
    $text = Read-Utf8File $initPath
    $pattern = '(?s)\$' + [regex]::Escape($VariableName) + '\s*=\s*@''\r?\n(.*?)\r?\n''@'
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value + "`n"
}

function Ensure-TaxonomyTopic {
    param([string]$Slug, [string]$Name, [string]$Desc, [string]$Keywords)
    if (-not (Test-Path $TaxonomyPath)) { return }
    $text = Read-Utf8File $TaxonomyPath
    $slugPattern = 'slug:\s*' + [regex]::Escape($Slug) + '\b'
    if ($text -match $slugPattern) {
        Write-Host "  [SKIP]  taxonomy topic $Slug already exists" -ForegroundColor DarkYellow
        return
    }
    $block = @"

  - slug: $Slug
    name: $Name
    desc: $Desc
    keywords: [$Keywords]
"@
    Save-TextFile -Path $TaxonomyPath -Content ($text.TrimEnd() + $block + "`n") -Reason "Add taxonomy topic $Slug"
}

# ---------------------------------------------------------------------------
# Append-Or-Replace-MarkedBlock
# Replaces content between START/END markers in a file, or appends if absent.
# All OpenSpec injections use <!-- OPENSPEC v3.2 START --> / END markers so
# future upgrades can replace only the marked block, not the whole file.
# ---------------------------------------------------------------------------
function Append-Or-Replace-MarkedBlock {
    param([string]$Path, [string]$StartMarker, [string]$EndMarker, [string]$NewBlock, [string]$Reason)
    $replacement = $StartMarker + "`n" + $NewBlock.Trim() + "`n" + $EndMarker
    if (-not (Test-Path $Path)) {
        Ensure-File -Path $Path -Content ($replacement + "`n") -Reason $Reason
        return
    }
    $text = Read-Utf8File $Path
    $startIdx = $text.IndexOf($StartMarker)
    if ($startIdx -ge 0) {
        $endIdx = $text.IndexOf($EndMarker, $startIdx)
        if ($endIdx -ge 0) {
            $before  = $text.Substring(0, $startIdx)
            $after   = $text.Substring($endIdx + $EndMarker.Length)
            $newText = $before + $replacement + $after
            if ($newText -ne $text) {
                Save-TextFile -Path $Path -Content $newText -Reason "$Reason (replace existing block)"
            } else {
                Write-Host "  [SKIP]  $Reason block unchanged" -ForegroundColor DarkYellow
            }
            return
        }
    }
    # Markers not found — append
    $appended = $text.TrimEnd() + "`n`n" + $replacement + "`n"
    Save-TextFile -Path $Path -Content $appended -Reason "$Reason (append new block)"
}

# ---------------------------------------------------------------------------
# Ensure-OpenSpecScaffold
# Creates .vscode/openspec/ directory structure if not present.
# Existing files are never overwritten.
# ---------------------------------------------------------------------------
function Ensure-OpenSpecScaffold {
    $openspecDir = Join-Path $VscodeDir 'openspec'
    $changesDir  = Join-Path $openspecDir 'changes'
    $archiveDir  = Join-Path $changesDir  'archive'
    $schemasDir  = Join-Path $openspecDir 'schemas'
    $specsDir    = Join-Path $openspecDir 'specs'

    Ensure-Directory -Path $changesDir -Reason 'Create openspec/changes'
    Ensure-Directory -Path $archiveDir -Reason 'Create openspec/changes/archive'
    Ensure-Directory -Path $schemasDir -Reason 'Create openspec/schemas'
    Ensure-Directory -Path $specsDir   -Reason 'Create openspec/specs'

    Ensure-File -Path (Join-Path $changesDir '.gitkeep')         -Content '' -Reason 'Create openspec/changes/.gitkeep'
    Ensure-File -Path (Join-Path $archiveDir '.gitkeep')         -Content '' -Reason 'Create openspec/changes/archive/.gitkeep'

    $specsIndex = @'
OpenSpec Requirements Index

> Update requirement counts per module after each change is archived.

| Module | Requirements | Last Updated | Notes |
|--------|-------------|--------------|-------|
'@
    Ensure-File -Path (Join-Path $specsDir 'INDEX.md') -Content $specsIndex -Reason 'Create openspec/specs/INDEX.md'

    $openspecConfig = @'
schema: project-feature

context: |
  # Project name (fill in)

  ## Tech stack
  (fill in: language, framework, database, test framework)

  ## Code paths
  (fill in: main code directory structure)

  ## KB CLI
  - node .vscode/knowledge/scripts/kb.mjs start-check --module=X --file=path --query="keyword"
  - node .vscode/knowledge/scripts/kb.mjs new-trap --module=X --title="..." --topics=slug
  - node .vscode/knowledge/scripts/kb.mjs rebuild

  ## Forbidden
  - Do not use fenced code blocks in responses (VS Code Chat hides them)
  - Do not use PowerShell Set-Content to write knowledge files (CP950 corruption)
  - Do not manually edit traps/index.jsonl, by-*.json, or topics AUTO sections

rules:
  research:
    - Run kb.mjs start-check and record matching traps and topics
    - List ambiguities in an Assumptions block; confirm before implementing
  proposal:
    - Produce tasks with explicit verification steps
  tasks:
    - Each task must have a verification step
'@
    Ensure-File -Path (Join-Path $openspecDir 'config.yaml') -Content $openspecConfig -Reason 'Create openspec/config.yaml'
}

# ---------------------------------------------------------------------------
# Ensure-OpsxWrappers
# Creates opsx.bat / opsx.ps1 in project root if not present.
# ---------------------------------------------------------------------------
function Ensure-OpsxWrappers {
    $opsxBat = @'
@echo off
pushd "%~dp0.vscode"
openspec %*
set _EC=%ERRORLEVEL%
popd
exit /b %_EC%
'@
    $opsxPs1 = @'
param([Parameter(ValueFromRemainingArguments=$true)]$passThrough)
Push-Location (Join-Path $PSScriptRoot ".vscode")
openspec @passThrough
$ec = $LASTEXITCODE
Pop-Location
exit $ec
'@
    Ensure-File -Path (Join-Path $ProjectRootFull 'opsx.bat') -Content $opsxBat -Reason 'Create opsx.bat wrapper'
    Ensure-File -Path (Join-Path $ProjectRootFull 'opsx.ps1') -Content $opsxPs1 -Reason 'Create opsx.ps1 wrapper'
}

# ---------------------------------------------------------------------------
# Ensure-GitignoreEntries
# Appends .vscode/, /opsx.bat, /opsx.ps1 to .gitignore if not already present.
# ---------------------------------------------------------------------------
function Ensure-GitignoreEntries {
    $gitignorePath = Join-Path $ProjectRootFull '.gitignore'
    $entries = @(
        @{ Needle = '.vscode/';  Line = '.vscode/' },
        @{ Needle = '/opsx.bat'; Line = '/opsx.bat' },
        @{ Needle = '/opsx.ps1'; Line = '/opsx.ps1' }
    )
    foreach ($e in $entries) {
        Append-BlockIfMissing -Path $gitignorePath -Needle $e.Needle -Block $e.Line -Reason "Add $($e.Line) to .gitignore"
    }
}

# ---------------------------------------------------------------------------
# Ensure-OpenSpecCheatsheet
# Creates openspec-cheatsheet.md in project root if not present.
# ---------------------------------------------------------------------------
function Ensure-OpenSpecCheatsheet {
    $cheatsheetPath = Join-Path $ProjectRootFull 'openspec-cheatsheet.md'
    $content = @'
# OpenSpec Quick Reference

> Root: `.vscode/openspec/`
> Wrappers: `opsx.bat` (CMD) / `opsx.ps1` (PowerShell) -- project root, not versioned

## Common commands

    .\opsx list                         # list all changes
    .\opsx new change <name>            # create new change
    .\opsx status --change <name>       # check task completion
    .\opsx archive --change <name>      # archive completed change

## VS Code prompt flow

    #start-plan   -> OpenSpec pre-read + KB read + plan output
    /opsx:propose -> create change artifacts  (after user confirms plan)
    #start-task   -> KB read + implement tasks
    #end-task     -> KB update + /opsx:archive + rebuild + finish-check

## Dual-track responsibility

| OpenSpec (.vscode/openspec/)     | Knowledge Base (.vscode/knowledge/)      |
|----------------------------------|------------------------------------------|
| WHAT: behaviour contracts, specs | WHY/HOW-NOT-TO: root causes, traps       |
| New features / spec changes      | Bug fixes, trap records                  |
| /opsx:propose, /opsx:explore     | kb.mjs new-trap                          |
| /opsx:archive -> rebuild         | rebuild                                  |

## Key files

- `.vscode/openspec/config.yaml`     -- project context and rules (fill in)
- `.vscode/openspec/specs/INDEX.md`  -- requirement counts per module
- `.vscode/openspec/changes/<name>/` -- change artifacts (working)
- `.vscode/openspec/changes/archive/<name>/` -- archived changes
'@
    Ensure-File -Path $cheatsheetPath -Content $content -Reason 'Create openspec-cheatsheet.md'
}

$ProjectRootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
$VscodeDir = Join-Path $ProjectRootFull '.vscode'
$KbDir = Join-Path $VscodeDir 'knowledge'
$ScriptDir = Join-Path $KbDir 'scripts'
$TaxonomyPath = Join-Path $KbDir 'traps\topics-taxonomy.yml'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = Join-Path $KbDir "backups\$Stamp"
$script:BackedUp = @{}

Write-Host ''
Write-Host '========================================================' -ForegroundColor Cyan
Write-Host '   VS Code local AI knowledge base v3.2 updater' -ForegroundColor Cyan
Write-Host '   (v3.2: Knowledge Base + OpenSpec dual-track)' -ForegroundColor Cyan
Write-Host '========================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "Project root : $ProjectRootFull"
Write-Host "Knowledge dir: $KbDir"
Write-Host "Mode         : $(if ($Apply) { 'Apply' } else { 'Dry-run' })"
if ($SkipOpenSpec) { Write-Host '  [mode]  -SkipOpenSpec: skipping OpenSpec scaffold and prompt injection' -ForegroundColor Magenta }
Write-Host ''

if (-not (Test-Path $ProjectRootFull)) { throw "ProjectRoot does not exist: $ProjectRootFull" }
if (-not (Test-Path $KbDir)) {
    Write-Host 'Cannot find .vscode/knowledge. Run init-kb.ps1 first.' -ForegroundColor Red
    exit 1
}

Write-Section '1. Directories and settings.json'
Ensure-Directory -Path (Join-Path $KbDir 'agent') -Reason 'Create knowledge/agent'
Ensure-Directory -Path (Join-Path $KbDir 'agent\generated') -Reason 'Create knowledge/agent/generated'
Ensure-Directory -Path (Join-Path $KbDir 'runtime') -Reason 'Create knowledge/runtime'
Repair-SettingsJson -Path (Join-Path $VscodeDir 'settings.json')

Write-Section '2. Agent Guard document'
$agentIndex = @'
# Agent Guard

> Goal: turn failed tool calls, bad shell commands, wrong search paths, and repeated attempts into recorded, blockable, and regressable knowledge.

## Task Start

1. Read this file before `start-check`.
2. Before shell commands, `.vscode` search, bulk edits, or retrying a failed command, run `repair-preflight`.
3. If preflight returns `deny`, do not run the original command. Use the suggested alternative.

## Failure Closure

1. Do not retry the same failed tool call or command unchanged.
2. Run `repair-record` with a sanitized failure summary.
3. Run `repair-status` to check repeated fingerprints.
4. The second failure with the same fingerprint becomes pending repair. Change method or create/update an operational trap.

## Finish Rules

- `repair-health` must have 0 errors before task completion.
- Repeated failures must become operational traps, or documented false positives with expiry.
- Runtime ledgers store summaries and hashes only. Never store `.env`, tokens, passwords, full API keys, or large stdout.
'@
$agentIndexPath = Join-Path $KbDir 'agent\INDEX.md'
if ($ForceTemplates) {
    Ensure-File -Path $agentIndexPath -Content $agentIndex -Reason 'Replace agent/INDEX.md template' -Overwrite
} else {
    Append-BlockIfMissing -Path $agentIndexPath -Needle 'repair-preflight' -Block $agentIndex -Reason 'Add agent repair closure to agent/INDEX.md'
}
Ensure-File -Path (Join-Path $KbDir 'agent\generated\.gitkeep') -Content '' -Reason 'Create agent/generated/.gitkeep'

Write-Section '3. Prompts and SSOT'
$guardBlock = @'

## Agent Guard v3.1

- Start by reading `knowledge/agent/INDEX.md`, then run `start-check`.
- Do not execute commands containing placeholders such as `<module>`, `<file>`, or `<keyword>`.
- After a tool or command failure, do not retry unchanged. Run `repair-record`, then `repair-status`.
- Finish with `finish-check`; output the commit message last.
'@
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'copilot-instructions.md') -Needle 'repair-record' -Block $guardBlock -Reason 'Add Agent Guard to copilot-instructions'
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'start-task.prompt.md') -Needle 'repair-record' -Block $guardBlock -Reason 'Add Agent Guard to start-task'
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'start-plan.prompt.md') -Needle 'repair-preflight' -Block $guardBlock -Reason 'Add Agent Guard to start-plan'
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'end-task.prompt.md') -Needle 'finish-check' -Block $guardBlock -Reason 'Add finish-check and commit-last rule to end-task'
Replace-TextIfMatch -Path (Join-Path $VscodeDir 'end-task.prompt.md') -Pattern 'kb\.mjs\s+health' -Replacement 'kb.mjs finish-check' -Reason 'Replace end-task health with finish-check'

Write-Section '4. Knowledge INDEX and taxonomy'
$indexBlock = @'

## Agent Guard / Repair Closure

- Guard entry: [agent/INDEX.md](agent/INDEX.md)
- Task start: `node .vscode/knowledge/scripts/kb.mjs start-check --module=<Module> --file=path.ext --query="keyword"`
- Preflight: `repair-preflight`
- Failure closure: `repair-record` / `repair-status` / `repair-health`
- Finish: run `rebuild`, then `finish-check`; output the commit message last.
'@
Append-BlockIfMissing -Path (Join-Path $KbDir 'INDEX.md') -Needle 'repair-preflight' -Block $indexBlock -Reason 'Add Agent Guard entry to knowledge INDEX'
Replace-TextIfMatch -Path (Join-Path $KbDir 'INDEX.md') -Pattern 'kb\.mjs\s+health' -Replacement 'kb.mjs finish-check' -Reason 'Replace knowledge INDEX health with finish-check'

Ensure-TaxonomyTopic -Slug 'agent-runtime-failure' -Name 'Agent runtime failure closure' -Desc 'Tool or command failures must be recorded as fingerprints and must not be retried unchanged.' -Keywords 'Agent, repair-record, repair-health, fingerprint, repeated failure'
Ensure-TaxonomyTopic -Slug 'tool-search-visibility' -Name 'Tool search visibility and .vscode reads' -Desc 'Search tools may ignore .vscode or gitignored local knowledge paths; use direct reads or include ignored files.' -Keywords '.vscode, search, include ignored, read_file, list_dir, knowledge'
Ensure-TaxonomyTopic -Slug 'command-preflight' -Name 'Command preflight' -Desc 'Known bad or high-risk shell commands must pass repair-preflight before execution.' -Keywords 'preflight, command, PowerShell, terminal, retry'
Ensure-TaxonomyTopic -Slug 'prompt-agent-compat' -Name 'VS Code prompt agent compatibility' -Desc 'Prompt frontmatter agent values must follow local VS Code diagnostics.' -Keywords 'prompt, agent, Plan, plan, frontmatter'
Ensure-TaxonomyTopic -Slug 'vscode-settings-encoding' -Name 'VS Code settings encoding id' -Desc 'VS Code files.encoding must use a valid id such as utf8, not utf-8.' -Keywords 'settings.json, files.encoding, utf8, utf-8, VS Code'
Ensure-TaxonomyTopic -Slug 'powershell-encoding' -Name 'PowerShell UTF-8 corruption' -Desc 'PowerShell text rewrite commands can corrupt UTF-8 knowledge files.' -Keywords 'PowerShell, Set-Content, UTF-8, CP950, BOM, encoding'

Write-Section '5. kb.mjs executable template'
$kbMjsPath = Join-Path $ScriptDir 'kb.mjs'
$templateKbMjs = Extract-HereStringFromInit -VariableName 'kbScript'
if (-not $templateKbMjs) {
    Write-Host '  [WARN]  Could not read kb.mjs template from init-kb.ps1; skipped CLI upgrade.' -ForegroundColor Yellow
} elseif (-not (Test-Path $kbMjsPath)) {
    Save-TextFile -Path $kbMjsPath -Content $templateKbMjs -Reason 'Create scripts/kb.mjs v3.1'
} else {
    $currentKb = Read-Utf8File $kbMjsPath
    if ($currentKb -match 'async function cmdFinishCheck' -and $currentKb -match 'cmdRepairPreflight') {
        Write-Host '  [SKIP]  kb.mjs already has repair-* and finish-check' -ForegroundColor DarkYellow
    } elseif ($ForceTemplates) {
        Save-TextFile -Path $kbMjsPath -Content $templateKbMjs -Reason 'Replace scripts/kb.mjs with v3.1 template'
    } else {
        $candidate = Join-Path $ScriptDir 'kb.mjs.v3.2.candidate'
        Save-TextFile -Path $candidate -Content $templateKbMjs -Reason 'Create scripts/kb.mjs.v3.2.candidate without replacing kb.mjs'
        Write-Host '  [INFO]  Re-run with -Apply -ForceTemplates to replace kb.mjs after review.' -ForegroundColor Gray
    }
}

Write-Section '6. Version marker'
$versionJson = @"
{
  "schema": "local-ai-knowledge-base",
  "version": "3.2",
  "updated_at": "$(Get-Date -Format o)",
  "features": ["agent-guard", "repair-closure", "finish-check", "openspec-dual-track"]
}
"@
Save-TextFile -Path (Join-Path $KbDir '.kb-version.json') -Content $versionJson -Reason 'Write .kb-version.json'

Write-Section '7. OpenSpec dual-track upgrade'
if ($SkipOpenSpec) {
    Write-Host '  [SKIP]  -SkipOpenSpec specified; skipping all OpenSpec steps' -ForegroundColor DarkYellow
} else {
    # 7a. Scaffold
    Ensure-OpenSpecScaffold

    # 7b. opsx wrappers
    Ensure-OpsxWrappers

    # 7c. .gitignore entries
    Ensure-GitignoreEntries

    # 7d. Cheatsheet
    Ensure-OpenSpecCheatsheet

    # 7e. Inject OpenSpec block into copilot-instructions.md
    $copilotInstructionsPath = Join-Path $VscodeDir 'copilot-instructions.md'
    $openspecCopilotBlock = @'
### Task startup: OpenSpec + KB dual-track (Step 0)

If the task involves new features, spec changes, or behaviour contract adjustments:
1. Use `/opsx:explore` to clarify requirement boundaries with the user
2. Use `/opsx:propose` to create an OpenSpec change (`.vscode/openspec/changes/{name}/` artifacts)
3. Check `.vscode/openspec/specs/INDEX.md` for existing specs; if found, read before implementing

If the task is a bug fix or trap patch, skip Step 0 and go directly to the KB read (Step 1).

### Task end: OpenSpec archive closure

If this task created an OpenSpec change:
a. Confirm all tasks completed: `.\opsx status --change {name}`
b. Run `/opsx:archive`; immediately follow with `kb.mjs rebuild`
   (so spec links in topic guard rules are FTS-indexed)
If bug fix only (no OpenSpec change), skip.

### OpenSpec vs KB responsibility

| Dimension | OpenSpec (`.vscode/openspec/`) | KB (`.vscode/knowledge/`) |
|-----------|-------------------------------|---------------------------|
| Answers | WHAT: behaviour contracts | WHY/HOW-NOT-TO: root causes, traps |
| Trigger | New features / spec changes | Bug fixes, trap records |
| Entry | `/opsx:propose`, `/opsx:explore` | `kb.mjs new-trap` |
| End action | `/opsx:archive` then rebuild | rebuild |

Forbidden:
- Do not run `kb.mjs rebuild` without first running `/opsx:archive` when a change exists
- Do not modify `.vscode/openspec/specs/` without updating `specs/INDEX.md`
'@
    Append-Or-Replace-MarkedBlock `
        -Path $copilotInstructionsPath `
        -StartMarker '<!-- OPENSPEC v3.2 START -->' `
        -EndMarker   '<!-- OPENSPEC v3.2 END -->' `
        -NewBlock    $openspecCopilotBlock `
        -Reason      'Inject OpenSpec dual-track block into copilot-instructions'

    # 7f. Inject OpenSpec pre-read block into start-task.prompt.md
    $startTaskPath = Join-Path $VscodeDir 'start-task.prompt.md'
    $openspecStartTaskBlock = @'
## OpenSpec pre-read (new features / spec changes only)

If the task involves new features, spec changes, or behaviour contract adjustments:
1. Check [openspec/specs/INDEX.md](openspec/specs/INDEX.md) for existing specs; read before KB read
2. Use `/opsx:explore` to clarify requirement boundaries
3. Use `/opsx:propose` to create an OpenSpec change

> Bug fix / trap patch: skip this block and go directly to the startup steps.
'@
    Append-Or-Replace-MarkedBlock `
        -Path $startTaskPath `
        -StartMarker '<!-- OPENSPEC v3.2 START -->' `
        -EndMarker   '<!-- OPENSPEC v3.2 END -->' `
        -NewBlock    $openspecStartTaskBlock `
        -Reason      'Inject OpenSpec pre-read block into start-task'

    # 7g. Inject OpenSpec pre-read block into start-plan.prompt.md
    $startPlanPath = Join-Path $VscodeDir 'start-plan.prompt.md'
    $openspecStartPlanBlock = @'
## OpenSpec pre-read (new features / spec changes only)

If the task involves new features, spec changes, or behaviour contract adjustments:
1. Check [openspec/specs/INDEX.md](openspec/specs/INDEX.md) for existing specs; read before outputting plan
2. Use `/opsx:explore` to clarify requirement boundaries
3. Use `/opsx:propose` to create an OpenSpec change (trigger AFTER user confirms the plan)

> Bug fix / trap patch: skip this block and go directly to Step 1.
'@
    Append-Or-Replace-MarkedBlock `
        -Path $startPlanPath `
        -StartMarker '<!-- OPENSPEC v3.2 START -->' `
        -EndMarker   '<!-- OPENSPEC v3.2 END -->' `
        -NewBlock    $openspecStartPlanBlock `
        -Reason      'Inject OpenSpec pre-read block into start-plan'

    # 7h. Inject OpenSpec archive step into end-task.prompt.md
    $endTaskPath = Join-Path $VscodeDir 'end-task.prompt.md'
    $openspecEndTaskBlock = @'
## OpenSpec archive closure (new features / spec changes only)

If this task created an OpenSpec change:
a. Confirm all tasks completed: `.\opsx status --change <change-name>`
b. Run `/opsx:archive` to archive the change
c. Immediately run `kb.mjs rebuild` so spec links are FTS-indexed

> Pure bug fix (no OpenSpec change): skip this block.
'@
    Append-Or-Replace-MarkedBlock `
        -Path $endTaskPath `
        -StartMarker '<!-- OPENSPEC v3.2 START -->' `
        -EndMarker   '<!-- OPENSPEC v3.2 END -->' `
        -NewBlock    $openspecEndTaskBlock `
        -Reason      'Inject OpenSpec archive step into end-task'
}

Write-Section '8. rebuild / finish-check'
if ($SkipRebuild) {
    Write-Host '  [SKIP]  -SkipRebuild specified' -ForegroundColor DarkYellow
} elseif (-not $Apply) {
    Write-Host '  [PLAN]  Run kb.mjs rebuild and finish-check after apply' -ForegroundColor Yellow
} else {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Host '  [WARN]  node not found; run rebuild and finish-check manually.' -ForegroundColor Yellow
    } else {
        Push-Location $ProjectRootFull
        try {
            & node --no-warnings .vscode\knowledge\scripts\kb.mjs rebuild
            if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN]  rebuild exit code $LASTEXITCODE" -ForegroundColor Yellow }
            & node --no-warnings .vscode\knowledge\scripts\kb.mjs finish-check
            if ($LASTEXITCODE -ne 0) { Write-Host "  [WARN]  finish-check exit code $LASTEXITCODE" -ForegroundColor Yellow }
        } finally {
            Pop-Location
        }
    }
}

if ($Apply -and $Backup -and $script:BackedUp.Count -gt 0) {
    Write-Host ''
    Write-Host "Backup dir: $BackupDir" -ForegroundColor Gray
}

if (-not $NoReloadPrompt) {
    Write-Host ''
    Write-Host 'VS Code prompt/settings changes require Reload Window.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
