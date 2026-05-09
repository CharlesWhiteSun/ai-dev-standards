param([Parameter(ValueFromRemainingArguments=$true)]$passThrough)
Push-Location (Join-Path $PSScriptRoot ".vscode")
openspec @passThrough
$ec = $LASTEXITCODE
Pop-Location
exit $ec