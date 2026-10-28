# Cross dlq tests (Phase 4b): DLQ with closed flag + outbox ESTADO=DLQ.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-dlq.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force
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
    $dir = Join-Path $env:TEMP ('cross_tdlq_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    $script:DlqFile = Join-Path $dir 'dlq-messages.md'
    $script:OutboxFile = Join-Path $dir 'outbox.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($script:DlqFile, "# DLQ`n", (New-Object System.Text.UTF8Encoding($false)))
    $content = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_d | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EXPIRADO | attempt=3
"
    [System.IO.File]::WriteAllText($script:OutboxFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}

Write-Host "== T-dlq: canonical line with closed flag =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -To 'ses_X' -Retries '3' -Flag 'HUMAN_REVIEW' -Summary 'agent not responding' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.ok) 'dlq ok' $r.err
Assert-True ($r.written) 'written' $r.written
Assert-True ($r.line -match '^\[.*\] DLQ \| msg_d \| to=ses_X \| from=leader \| retries=3 \| ESTADO=UNREAD \| flag=HUMAN_REVIEW') 'canonical format' $r.line
Assert-True ($r.line -match "'agent not responding'") 'summary in quotes' $r.line

Write-Host "== T-dlq: persisted in dlq-messages.md =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -To 'ses_X' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
$content = Get-Content -LiteralPath $script:DlqFile -Raw
Assert-True ($content -match 'DLQ \| msg_d \| to=ses_X') 'DLQ in file' $content

Write-Host "== T-dlq: round-trip writer -> parser (BUG II) =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -To 'ses_X' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
$dlqEntries = @(Read-DlqLog -Path $script:DlqFile)
Assert-True ($dlqEntries.Count -eq 1) 'DLQ entry parsed (round-trip)' $dlqEntries.Count
Assert-True ($dlqEntries[0].unread -eq $true) 'DLQ entry unread=true (round-trip)' $dlqEntries[0].unread
Assert-True ($dlqEntries[0].to -eq 'ses_X' -and $dlqEntries[0].from -eq 'leader' -and $dlqEntries[0].retries -eq '3') 'to/from/retries parsed (round-trip)' "$($dlqEntries[0].to)|$($dlqEntries[0].from)|$($dlqEntries[0].retries)"

Write-Host "== T-dlq: marks outbox ESTADO=DLQ =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.outbox_marked) 'outbox marked' $r.outbox_marked
$entry = @(Read-OutboxLog -Path $script:OutboxFile | Where-Object { $_.msg_id -eq 'msg_d' }) | Select-Object -First 1
Assert-True ($entry.estado -eq 'DLQ') 'ESTADO=DLQ persisted' $entry.estado

Write-Host "== T-dlq: default dest from outbox =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.line -match 'to=ses_X') 'dest taken from outbox' $r.line

Write-Host "== T-dlq: non-closed flag -> DLQ_FLAG_INVALID =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'FLAG_LIBRE' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'DLQ_FLAG_INVALID') 'free flag rejected' $r.err

Write-Host "== T-dlq: valid closed flags =="
foreach ($f in @('HUMAN_REVIEW', 'NACK_ORIGINATED', 'QUARANTINE', 'PROVIDER_DOWN')) {
    New-Fixture
    $r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag $f -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
    Assert-True ($r.ok -and $r.line -match "flag=$f") "valid flag $f" $r.err
}

Write-Host "== T-dlq: no msg_id -> USAGE_ERROR =="
New-Fixture
$r = Write-CrossDlq -MsgId '' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'no --msg-id -> USAGE_ERROR' $r.err

Write-Host "== T-dlq: retries auto-derived from attempt (BUG Z) =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.line -match 'retries=2') 'attempt=3 -> retries=2 (max(0,attempt-1))' $r.line
New-Fixture
$content2 = "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_d | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@2026-08-12T01:00:00Z | ESTADO=EXPIRADO | attempt=1
"
[System.IO.File]::WriteAllText($script:OutboxFile, $content2, (New-Object System.Text.UTF8Encoding($false)))
$r = Write-CrossDlq -MsgId 'msg_d' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
Assert-True ($r.line -match 'retries=0') 'attempt=1 -> retries=0' $r.line

Write-Host "== T-dlq: audit DLQ =="
New-Fixture
$r = Write-CrossDlq -MsgId 'msg_d' -Retries '3' -Flag 'HUMAN_REVIEW' -OutboxPath $script:OutboxFile -DlqPath $script:DlqFile -AuditPath $script:AuditFile
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| DLQ \| ESCRITO \|') 'audit type DLQ / WRITTEN' $audit

Write-Host ""
Stop-CleanFixture
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
