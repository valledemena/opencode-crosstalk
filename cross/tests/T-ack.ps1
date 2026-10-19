# Cross ack tests (Phase 4b): sending ACK to destination.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-ack.ps1
$ErrorActionPreference = 'Stop'
# v2.1.1 regression: mirror cross.ps1 import order (format loaded first, then
# cross-action). Before the fix, cross-action skipped importing cross-envelope
# in that order and `cross ack` failed with New-CrossAckJson not found.
Import-Module (Join-Path $PSScriptRoot '..\lib\cross-format.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-envelope.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force -DisableNameChecking

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-ack: cross-action auto-imports cross-envelope (import-order regression) =="
Assert-True ([bool](Get-Command New-CrossAckJson -ErrorAction SilentlyContinue)) 'New-CrossAckJson available after format+action import' ''
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tack_' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:AuditFile = Join-Path $dir 'audit_log.md'
    [System.IO.File]::WriteAllText($script:AuditFile, "# AUDIT`n", (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}
$script:Sent = $null
function Fake-Send { param([string]$d, [string]$t) $script:Sent = @{ dest = $d; text = $t } }

$config = Get-Content (Join-Path $PSScriptRoot '..\cross.config.json') -Raw | ConvertFrom-Json
$mySession = [string]$config.my_session_id
$myModel = [string]$config.my_model
if (-not $mySession) { $mySession = 'leader' }

Write-Host "== T-ack: ACK 4 segments (model auto-derived from config) =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'ack ok' $r.err
$pCfg = Parse-CrossEnvelope $r.ack_text
Assert-True ($pCfg.valid -and $pCfg.type -eq 'ack' -and $pCfg.token -eq 'T1' -and $pCfg.emitter -eq $mySession) 'v2 ack json (config identity)' "$($pCfg.valid)|$($pCfg.emitter)"
if ($myModel) { Assert-True ($pCfg.model -eq $myModel) 'v2 ack json config model' $pCfg.model }
Assert-True ($script:Sent.dest -eq 'ses_Y') 'send destination' $script:Sent.dest

Write-Host "== T-ack: ACK 4 segments (with model) =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -Dest 'ses_Y' -Model 'model-b' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }

$p4 = Parse-CrossEnvelope $r.ack_text
Assert-True ($p4.valid -and $p4.model -eq 'model-b' -and $p4.token -eq 'T1') 'v2 ack json with model' "$($p4.model)"

Write-Host "== T-ack: ACK 5 segments (token with suffix + model) =="
New-Fixture
$r = Send-CrossAck -Token 'T1:sub' -ForMsgId 'msg_x' -Dest 'ses_Y' -Model 'model-b' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$p = Parse-CrossEnvelope $r.ack_text
Assert-True ($p.valid -and $p.type -eq 'ack' -and $p.token -eq 'T1:sub') 'parser recovers full token with suffix' "$($p.token)"
Assert-True ($p.emitter -eq $mySession) 'parser recovers sender' $p.emitter
Assert-True ($p.model -eq 'model-b') 'parser recovers model' $p.model

Write-Host "== T-ack: empty token -> USAGE_ERROR =="
New-Fixture
$r = Send-CrossAck -Token '' -ForMsgId 'msg_x' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'empty token rejected' $r.err

Write-Host "== T-ack: default dest = my session =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.to -eq $mySession) 'dest default my_session_id' $r.to

Write-Host "== T-ack: audit recorded =="
New-Fixture
$r = Send-CrossAck -Token 'T1' -ForMsgId 'msg_x' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match 'msg=msg_x') 'audit with msg_id' $audit
Assert-True ($audit -match '\| ACK \| ENVIADO \|') 'audit type ACK / SENT' $audit

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
