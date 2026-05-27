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
    kb.mjs.v3.2.candidate file is created instead of overwriting kb.mjs.

.PARAMETER SkipRebuild
    Skip kb.mjs rebuild and finish-check.

.PARAMETER SkipOpenSpec
    Skip OpenSpec scaffold, opsx wrapper, and prompt injection steps.

.PARAMETER EnableRtkHints
    Add optional RTK terminal-output optimization hints. This never installs
    RTK, never changes global hooks, and must not make RTK a hard dependency.

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
    [switch]$EnableRtkHints,
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

function Insert-LineAfterNeedleIfMissing {
    param([string]$Path, [string]$MissingNeedle, [string]$Needle, [string]$InsertLine, [string]$Reason)
    if (-not (Test-Path $Path)) { return }
    $text = Read-Utf8File $Path
    if ($text.Contains($MissingNeedle)) {
        Write-Host "  [SKIP]  $Reason already present" -ForegroundColor DarkYellow
        return
    }
    $idx = $text.IndexOf($Needle)
    if ($idx -lt 0) { return }
    $lineEnd = $text.IndexOf("`n", $idx)
    if ($lineEnd -lt 0) {
        $newText = $text.TrimEnd() + "`n" + $InsertLine + "`n"
    } else {
        $newText = $text.Insert($lineEnd + 1, $InsertLine + "`n")
    }
    Save-TextFile -Path $Path -Content $newText -Reason $Reason
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
    # Markers not found - append
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
    Ensure-Directory -Path (Join-Path $schemasDir 'project-feature') -Reason 'Create openspec/schemas/project-feature'
    Ensure-Directory -Path (Join-Path $schemasDir 'project-bugfix') -Reason 'Create openspec/schemas/project-bugfix'

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
        - For code changes, list the TDD entry, verifiable scope, and out-of-scope items
        - If tests break, feature drift appears, specs conflict, or old test expectations must change, list it as a user-confirmation item
    design:
        - Apply SOLID pragmatically; justify new abstractions, dependencies, or cross-module changes
    tasks:
        - Code changes must have a TDD test step first; document alternate verification if TDD is not feasible
        - Stop and ask the user before accepting changed behavior or rewriting existing test expectations
        - Each task must have a verification step
'@
    $openspecConfigPath = Join-Path $openspecDir 'config.yaml'
    Ensure-File -Path $openspecConfigPath -Content $openspecConfig -Reason 'Create openspec/config.yaml'
    Insert-LineAfterNeedleIfMissing -Path $openspecConfigPath -MissingNeedle 'If tests break, feature drift appears' -Needle '- For code changes, list the TDD entry, verifiable scope, and out-of-scope items' -InsertLine '        - If tests break, feature drift appears, specs conflict, or old test expectations must change, list it as a user-confirmation item' -Reason 'Inject conflict guard into openspec/config.yaml proposal rules'
    Insert-LineAfterNeedleIfMissing -Path $openspecConfigPath -MissingNeedle 'Stop and ask the user before accepting changed behavior' -Needle '- Code changes must have a TDD test step first; document alternate verification if TDD is not feasible' -InsertLine '        - Stop and ask the user before accepting changed behavior or rewriting existing test expectations' -Reason 'Inject conflict guard into openspec/config.yaml task rules'
    Append-BlockIfMissing -Path $openspecConfigPath -Needle $CnConflict -Block '# Conflict confirmation guard v3.2.3
# If tests break, feature drift appears, specs conflict, or old test expectations must change,
# stop expanding edits and ask the user before accepting changed behavior.' -Reason 'Add conflict confirmation comments to openspec/config.yaml'

    $featureSchemaTemplate = Extract-HereStringFromInit -VariableName 'featureSchema'
    $featureSchemaPath = Join-Path $schemasDir 'project-feature\schema.yaml'
    if ($featureSchemaTemplate) {
        Ensure-File -Path $featureSchemaPath -Content $featureSchemaTemplate -Reason 'Create openspec/schemas/project-feature/schema.yaml'
    }
    Insert-LineAfterNeedleIfMissing -Path $featureSchemaPath -MissingNeedle '**Conflict confirmation**' -Needle '- **TDD entry**' -InsertLine '      - **Conflict confirmation**: list tests, behavior contracts, or business rules that require user confirmation if affected' -Reason 'Inject conflict confirmation into project-feature proposal schema'
    Append-BlockIfMissing -Path $featureSchemaPath -Needle $CnConflict -Block '# Conflict confirmation guard v3.2.3
# If tests break, feature drift appears, specs conflict, or old test expectations must change,
# stop expanding edits and ask the user before accepting changed behavior.' -Reason 'Add conflict confirmation comments to project-feature schema'

    $bugfixSchemaTemplate = Extract-HereStringFromInit -VariableName 'bugfixSchema'
    $bugfixSchemaPath = Join-Path $schemasDir 'project-bugfix\schema.yaml'
    if ($bugfixSchemaTemplate) {
        Ensure-File -Path $bugfixSchemaPath -Content $bugfixSchemaTemplate -Reason 'Create openspec/schemas/project-bugfix/schema.yaml'
    }
    Insert-LineAfterNeedleIfMissing -Path $bugfixSchemaPath -MissingNeedle '**Conflict confirmation**' -Needle '- **TDD entry**' -InsertLine '      - **Conflict confirmation**: list tests, behavior contracts, or business rules that require user confirmation if affected' -Reason 'Inject conflict confirmation into project-bugfix proposal schema'
    Append-BlockIfMissing -Path $bugfixSchemaPath -Needle $CnConflict -Block '# Conflict confirmation guard v3.2.3
# If tests break, feature drift appears, specs conflict, or old test expectations must change,
# stop expanding edits and ask the user before accepting changed behavior.' -Reason 'Add conflict confirmation comments to project-bugfix schema'
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

# ---------------------------------------------------------------------------
# Ensure-RtkCheatsheet
# Creates rtk-cheatsheet.md in project root if optional RTK hints are enabled.
# ---------------------------------------------------------------------------
function Ensure-RtkCheatsheet {
    $cheatsheetPath = Join-Path $ProjectRootFull 'rtk-cheatsheet.md'
    $content = @'
# RTK Command Quick Reference (Optional)

> RTK (Rust Token Killer) compresses terminal output before it reaches the AI context.
> This project only adds usage hints. It does not install RTK, modify global hooks,
> or make RTK a required dependency.

## When to use RTK

Good candidates:

- `git status`, `git diff`, `git log`
- `rg`, `grep`, `find`, `ls`
- test, lint, build, and type-check commands
- long logs, large JSON, docker / kubectl output

Do not use RTK as a replacement for:

- `.vscode/knowledge/` traps, facets, FTS5, or repair closure
- `.vscode/openspec/` behaviour specs and change artifacts
- VS Code / Copilot built-in read or search tools

## Check availability

PowerShell:

    Get-Command rtk -ErrorAction SilentlyContinue
    rtk --version

If RTK is not found, use the original command. Missing RTK must never block the task.

## Native Windows

Native Windows supports explicit RTK commands, but auto-rewrite hooks are limited:

    rtk git status
    rtk git diff
    rtk git log -n 10
    rtk grep "keyword" .
    rtk find "*.php" .
    rtk test npm test
    rtk err npm run build

If compact output is not enough, rerun the original command or use RTK verbose mode.

## WSL

WSL can use RTK's full hook / auto-rewrite workflow. Keep fallback commands available,
especially when the project is normally maintained from native Windows PowerShell.

## Agent Guard integration

1. Prefer explicit RTK commands for high-output terminal commands when RTK is available.
2. If an RTK command fails, do not retry unchanged; record a sanitized failure with `repair-record`.
3. If RTK hides necessary detail, fall back to the original command.
4. Never write RTK tee raw output, `.env`, tokens, passwords, full API keys, or large stdout into the knowledge base.

## Privacy and telemetry

RTK telemetry is an external opt-in feature. This project does not enable telemetry,
does not grant consent on behalf of the user, and does not treat telemetry as a finish gate.
'@
    Ensure-File -Path $cheatsheetPath -Content $content -Reason 'Create rtk-cheatsheet.md'
}

$ProjectRootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
$VscodeDir = Join-Path $ProjectRootFull '.vscode'
$KbDir = Join-Path $VscodeDir 'knowledge'
$ScriptDir = Join-Path $KbDir 'scripts'
$TaxonomyPath = Join-Path $KbDir 'traps\topics-taxonomy.yml'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$BackupDir = Join-Path $KbDir "backups\$Stamp"
$script:BackedUp = @{}
$CnConflict = -join ([char[]](0x885D,0x7A81))

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
if ($EnableRtkHints) {
    $rtkCommand = Get-Command rtk -ErrorAction SilentlyContinue
    $rtkState = if ($rtkCommand) { 'available' } else { 'not found; hints only, fallback required' }
    Write-Host "  [mode]  -EnableRtkHints: RTK optional guidance enabled ($rtkState)" -ForegroundColor Magenta
}
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

## Test and Spec Conflict Closure

When a change makes existing tests fail, requires changing old test expectations, causes feature drift, or conflicts with OpenSpec / quickref / user requirements, stop expanding edits and ask the user first. Record the test command, failed tests, affected behavior, suspected cause, related files, and possible paths forward. Do not accept new behavior or rewrite test expectations without user confirmation.

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
$agentConflictBlock = @'

## Test and Spec Conflict Closure

- If existing tests fail, fixing A breaks B/C, test expectations must change, feature drift appears, or specs conflict, stop expanding edits and do not accept new behavior silently.
- Collect the test command, failed tests, affected behavior, suspected cause, related files, and possible paths forward before asking the user.
- Continue only after the user chooses whether to preserve old behavior, accept a new spec, split the task, or add regression coverage first.
'@
Append-BlockIfMissing -Path $agentIndexPath -Needle $CnConflict -Block $agentConflictBlock -Reason 'Add test/spec conflict closure to agent/INDEX.md'
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

$engineeringGuardBlock = @'
## Engineering Guard: TDD / SOLID / Verifiable Scope

- Code behavior changes must prefer TDD: find or add a test first, make it fail, implement the smallest passing change, then refactor under test coverage.
- If TDD is not feasible, record the exception and alternate verification before implementation.
- Apply SOLID pragmatically: keep single responsibility, avoid needless abstractions, preserve public contracts, and justify new dependencies or cross-module changes.
- Keep scope controlled: only touch planned source, test, docs, and knowledge files. If scope expands, stop and confirm.
- Every behavior change must map to a test, OpenSpec requirement, or explicit manual verification.
'@
Append-Or-Replace-MarkedBlock `
    -Path (Join-Path $VscodeDir 'copilot-instructions.md') `
    -StartMarker '<!-- ENGINEERING GUARD v3.3 START -->' `
    -EndMarker   '<!-- ENGINEERING GUARD v3.3 END -->' `
    -NewBlock    $engineeringGuardBlock `
    -Reason      'Inject TDD/SOLID/scope guard into copilot-instructions'

$engineeringStartTaskBlock = @'
## Engineering Guard: TDD / SOLID / Verifiable Scope

Before code changes, confirm:
1. Add or identify the TDD test first. Bug fixes reproduce failure; features define verifiable behavior. If TDD is not feasible, explain the exception and alternate verification.
2. Make the smallest change needed to pass, then refactor under test coverage.
3. Keep SOLID boundaries: single responsibility, no needless abstractions, no public contract breakage, justified new dependencies.
4. Touch only files, tests, docs, and knowledge needed for this task. If scope expands, stop and confirm.
'@
Append-Or-Replace-MarkedBlock `
    -Path (Join-Path $VscodeDir 'start-task.prompt.md') `
    -StartMarker '<!-- ENGINEERING GUARD v3.3 START -->' `
    -EndMarker   '<!-- ENGINEERING GUARD v3.3 END -->' `
    -NewBlock    $engineeringStartTaskBlock `
    -Reason      'Inject TDD/SOLID/scope guard into start-task'

$engineeringStartPlanBlock = @'
## TDD / SOLID / Scope Planning Guard

For code changes, the plan must include:
1. TDD entry: which test changes first and what behavior should fail first; if TDD is not feasible, explain exception and alternate verification.
2. SOLID check: how the change preserves single responsibility, avoids needless abstractions, and protects public contracts.
3. Controlled scope: planned files, validation commands, and explicit out-of-scope items.

If unplanned files, cross-module design, or behavior contract changes are needed, list them as confirmation items before implementation.
'@
Append-Or-Replace-MarkedBlock `
    -Path (Join-Path $VscodeDir 'start-plan.prompt.md') `
    -StartMarker '<!-- ENGINEERING GUARD v3.3 START -->' `
    -EndMarker   '<!-- ENGINEERING GUARD v3.3 END -->' `
    -NewBlock    $engineeringStartPlanBlock `
    -Reason      'Inject TDD/SOLID/scope guard into start-plan'

$engineeringEndTaskBlock = @'
## Engineering Constraint Review

Before the final commit message, confirm:
- TDD: list added/updated passing tests; if TDD was not used, record exception and alternate verification.
- SOLID: no needless abstractions, no public contract breakage, no unrelated refactors.
- Scope: every behavior change maps to a test, OpenSpec requirement, or explicit manual verification.
'@
Append-Or-Replace-MarkedBlock `
    -Path (Join-Path $VscodeDir 'end-task.prompt.md') `
    -StartMarker '<!-- ENGINEERING GUARD v3.3 START -->' `
    -EndMarker   '<!-- ENGINEERING GUARD v3.3 END -->' `
    -NewBlock    $engineeringEndTaskBlock `
    -Reason      'Inject TDD/SOLID/scope review into end-task'

$conflictGuardBlock = @'
## Conflict Detection and User Confirmation Guard

- If tests break, fixing A breaks B/C, feature drift appears, unit-test drift appears, specs conflict, existing test expectations must change, or scope expands to unplanned modules, stop expanding edits immediately.
- The agent may only gather minimal evidence: test command, failed tests, affected behavior, suspected cause, related files, and possible paths forward.
- Before user confirmation, do not rewrite test expectations, snapshots, fixtures, mocks, acceptance criteria, or public contracts. Do not treat a spec conflict as an ordinary bug.
- Only obvious in-plan syntax, test setup, or missing mock fixes may be corrected immediately, and only when no behavior contract changes.
'@
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'copilot-instructions.md') -Needle $CnConflict -Block $conflictGuardBlock -Reason 'Inject conflict confirmation guard into copilot-instructions'

$conflictStartTaskBlock = @'
## Conflict Confirmation Guard

During implementation, if existing tests fail, fixing A breaks B/C, test expectations must change, feature drift appears, or specs conflict, stop expanding edits immediately. Report failed tests/commands, affected behavior, suspected cause, known evidence, and options; continue only after user confirmation.
'@
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'start-task.prompt.md') -Needle $CnConflict -Block $conflictStartTaskBlock -Reason 'Inject conflict confirmation guard into start-task'

$conflictStartPlanBlock = @'
## Conflict Confirmation Planning Guard

For code changes, the plan must list conflict stop lines: which existing tests, behavior contracts, OpenSpec requirements, business rules, or cross-module dependencies require user confirmation if affected. If old test expectations, snapshots, fixtures, mocks, or acceptance criteria might need changes, list them as confirmation items.
'@
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'start-plan.prompt.md') -Needle $CnConflict -Block $conflictStartPlanBlock -Reason 'Inject conflict confirmation planning guard into start-plan'

$conflictEndTaskBlock = @'
## Conflict Confirmation Review

At closure, state whether tests broke, feature drift appeared, specs conflicted, or test expectations needed changes. If yes, list the evidence reported to the user, the user decision, and follow-up spec/test/knowledge updates. If no, explicitly state that no unplanned behavior changes were found.
'@
Append-BlockIfMissing -Path (Join-Path $VscodeDir 'end-task.prompt.md') -Needle $CnConflict -Block $conflictEndTaskBlock -Reason 'Inject conflict confirmation review into end-task'

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

$engineeringIndexBlock = @'

## Engineering Guard

- Code behavior changes should prefer TDD; record exception and alternate verification when needed.
- Apply SOLID pragmatically; avoid needless abstractions and unrelated refactors.
- Scope must be controlled; every behavior change maps to a test, OpenSpec requirement, or manual verification.
'@
Append-Or-Replace-MarkedBlock `
    -Path (Join-Path $KbDir 'INDEX.md') `
    -StartMarker '<!-- ENGINEERING GUARD v3.3 START -->' `
    -EndMarker   '<!-- ENGINEERING GUARD v3.3 END -->' `
    -NewBlock    $engineeringIndexBlock `
    -Reason      'Inject TDD/SOLID/scope guard into knowledge INDEX'

$conflictIndexBlock = @'

## Conflict Confirmation Guard

- If tests break, feature drift appears, or specs conflict, stop and ask the user before changing expectations or accepting new behavior.
- Report failed tests/commands, affected behavior, suspected cause, related files, and possible paths forward.
'@
Append-BlockIfMissing -Path (Join-Path $KbDir 'INDEX.md') -Needle $CnConflict -Block $conflictIndexBlock -Reason 'Inject conflict confirmation guard into knowledge INDEX'

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
$versionFeatures = @('"agent-guard"', '"repair-closure"', '"finish-check"', '"openspec-dual-track"', '"tdd-solid-scope-guard"', '"conflict-confirmation-guard"')
if ($EnableRtkHints) { $versionFeatures += '"rtk-terminal-hints"' }
$versionJson = @"
{
  "schema": "local-ai-knowledge-base",
    "version": "3.2.3",
  "updated_at": "$(Get-Date -Format o)",
    "features": [$($versionFeatures -join ', ')]
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

Write-Section '8. RTK terminal hints (optional)'
if (-not $EnableRtkHints) {
    Write-Host '  [SKIP]  -EnableRtkHints not specified; RTK remains disabled' -ForegroundColor DarkYellow
} else {
    Ensure-RtkCheatsheet

    $rtkCopilotBlock = @'
## RTK terminal output optimization (optional)

RTK (Rust Token Killer) is only a terminal / shell output compression layer for high-output commands such as git, search, tests, build, lint, and logs. It does not replace `.vscode/openspec/` or `.vscode/knowledge/`.

Rules:
1. Check availability with `Get-Command rtk -ErrorAction SilentlyContinue` or `rtk --version` before use.
2. If RTK is missing, use the original command. Missing RTK must never fail the task.
3. Native Windows uses explicit commands such as `rtk git status`, `rtk grep "pattern" .`, `rtk test <command>`, and `rtk err <command>`; do not assume auto-rewrite hooks are active.
4. WSL can use RTK hooks, but original-command fallback still applies.
5. VS Code / Copilot built-in read and search tools bypass RTK; RTK only affects terminal commands.
6. If RTK output is insufficient, use RTK verbose mode or rerun the original command.
7. If an RTK command fails, follow Agent Guard: `repair-record`, then `repair-status`.
8. Never write RTK tee raw output, `.env`, tokens, passwords, full API keys, or large stdout into the knowledge base.
'@
    Append-Or-Replace-MarkedBlock `
        -Path (Join-Path $VscodeDir 'copilot-instructions.md') `
        -StartMarker '<!-- RTK HINTS v3.3 START -->' `
        -EndMarker   '<!-- RTK HINTS v3.3 END -->' `
        -NewBlock    $rtkCopilotBlock `
        -Reason      'Inject optional RTK guidance into copilot-instructions'

    $rtkPromptBlock = @'
## RTK terminal hints (optional)

If `rtk --version` succeeds, prefer explicit RTK commands for high-output terminal work: `rtk git status`, `rtk git diff`, `rtk grep "keyword" .`, `rtk test <test command>`, or `rtk err <lint/build command>`. RTK only compresses terminal output; it does not replace KB / OpenSpec reads.

If RTK is missing, hides necessary details, or fails, fall back to the original command. Record RTK failures through Agent Guard when relevant, and never store raw RTK tee output or secrets in the knowledge base.
'@
    Append-Or-Replace-MarkedBlock `
        -Path (Join-Path $VscodeDir 'start-task.prompt.md') `
        -StartMarker '<!-- RTK HINTS v3.3 START -->' `
        -EndMarker   '<!-- RTK HINTS v3.3 END -->' `
        -NewBlock    $rtkPromptBlock `
        -Reason      'Inject optional RTK guidance into start-task'

    Append-Or-Replace-MarkedBlock `
        -Path (Join-Path $VscodeDir 'start-plan.prompt.md') `
        -StartMarker '<!-- RTK HINTS v3.3 START -->' `
        -EndMarker   '<!-- RTK HINTS v3.3 END -->' `
        -NewBlock    $rtkPromptBlock `
        -Reason      'Inject optional RTK guidance into start-plan'

    $rtkEndTaskBlock = @'
## RTK finish note (optional)

If RTK was used during this task, `rtk gain` may be checked for a local savings summary. This is informational only and is not a finish gate. Missing RTK or failed RTK analytics must not block completion. Do not store RTK tee raw output, command secrets, or large stdout in the knowledge base.
'@
    Append-Or-Replace-MarkedBlock `
        -Path (Join-Path $VscodeDir 'end-task.prompt.md') `
        -StartMarker '<!-- RTK HINTS v3.3 START -->' `
        -EndMarker   '<!-- RTK HINTS v3.3 END -->' `
        -NewBlock    $rtkEndTaskBlock `
        -Reason      'Inject optional RTK guidance into end-task'
}

Write-Section '9. rebuild / finish-check'
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
