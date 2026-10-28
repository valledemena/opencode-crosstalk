# Cross escalate tests (Phase 4b): URGENTE in escalated.md + wake-on-write.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-escalate.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-diagnostic.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fixture-clean.psm1') -Force -DisableNameChecking
Start-CleanFixture

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tescalate_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:EscalatedFile = Join-Path $dir 'escalated.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:EscalatedFile, "# ESCALADAS`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

Write-Host "== T-escalate: canonical URGENTE line =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'no ACK after retries' -RunId 'R1' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True ($r.ok) 'escalate ok' $r.err
Assert-True ($r.written) 'written' $r.written
Assert-True ($r.line -match '^URGENTE \| para=ses_Y \| msg_id=msg_x \| run_id=R1') 'canonical URGENTE format' $r.line
$mySession = [string]((Get-Content (Join-Path $PSScriptRoot '..\cross.config.json') -Raw | ConvertFrom-Json).my_session_id)
if (-not $mySession) { $mySession = 'leader' }
Assert-True ($r.line -match "de=$mySession") 'de= my session' $r.line
Assert-True ($r.line -match 'expira=\d{4}-\d{2}-\d{2}T') 'expira UTC' $r.line
Assert-True ($r.line -match "'no ACK after retries'") 'reason in quotes' $r.line
Assert-True ($r.notified -eq $false) 'without --apply does not notify' $r.notified

Write-Host "== T-escalate: persisted in escalated.md =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'reason' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
$content = Get-Content -LiteralPath $script:EscalatedFile -Raw
Assert-True ($content -match 'URGENTE \| para=ses_Y') 'URGENTE in file' $content

Write-Host "== T-escalate: --apply sends wake-on-write =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'reason' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile -Apply -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.notified -eq $true) 'wake-on-write sent' $r.notified
Assert-True ($script:Sent.dest -eq 'ses_Y') 'wake to destination' $script:Sent.dest
Assert-True ($script:Sent.text -match 'wake-on-write') 'wake-on-write text' $script:Sent.text

Write-Host "== T-escalate: validations =="
New-Fixture
$r = Write-CrossEscalated -MsgId '' -To 'ses_Y' -Reason 'r' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --msg-id -> USAGE_ERROR' $r.err
$r = Write-CrossEscalated -MsgId 'msg_x' -To '' -Reason 'r' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --to -> USAGE_ERROR' $r.err
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason '' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --reason -> USAGE_ERROR' $r.err

Write-Host "== T-escalate: Read-EscalatedLog parses explicit msg_id (BUG BB) =="
New-Fixture
[void](Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'reason' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile)
$parsed = @(Read-EscalatedLog -Path $script:EscalatedFile)
Assert-True ($parsed.Count -eq 1) 'escalation read' $parsed.Count
Assert-True ($parsed[0].msg_id -eq 'msg_x') 'msg_id parsed' $parsed[0].msg_id
Assert-True ($parsed[0].para -eq 'ses_Y' -and $parsed[0].kind -eq 'URGENTE') 'para/kind' "$($parsed[0].para)|$($parsed[0].kind)"

Write-Host "== T-escalate: audit ESCALADA =="
New-Fixture
$r = Write-CrossEscalated -MsgId 'msg_x' -To 'ses_Y' -Reason 'r' -EscalatedPath $script:EscalatedFile -AuditPath $script:AuditFile
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| ESCALADA \| ESCRITO \|') 'audit type ESCALADA / WRITTEN' $audit

Write-Host ""
Stop-CleanFixture
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
