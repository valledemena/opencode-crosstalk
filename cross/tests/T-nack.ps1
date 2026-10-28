# Cross nack tests (Phase 4b): sending NACK with closed reason and traceability.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-nack.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-action.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-envelope.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fixture-clean.psm1') -Force -DisableNameChecking
Start-CleanFixture

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
function New-Fixture {
    $dir = Join-Path $env:TEMP ('cross_tnack_' + [System.Guid]::NewGuid().ToString('N'))
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

Write-Host "== T-nack: NACK 5 segments (model auto-derived from config, no ids) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'nack ok' $r.err
$pA = Parse-CrossEnvelope $r.nack_text
Assert-True ($pA.valid -and $pA.type -eq 'nack' -and $pA.token -eq 'T1' -and $pA.reason -eq 'CAPACITY' -and $pA.emitter -eq $mySession) 'v2 nack json (config identity)' "$($pA.valid)|$($pA.reason)|$($pA.emitter)"
if ($myModel) { Assert-True ($pA.model -eq $myModel) 'v2 nack json config model' $pA.model }

Write-Host "== T-nack: NACK 5 segments (with model) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$pB = Parse-CrossEnvelope $r.nack_text
Assert-True ($pB.valid -and $pB.type -eq 'nack' -and $pB.reason -eq 'CAPACITY') 'parser recovers reason' "$($pB.reason)"
Assert-True ($pB.emitter -eq $mySession -and $pB.model -eq 'model-b') 'parser recovers sender/model' "$($pB.emitter)|$($pB.model)"

Write-Host "== T-nack: msg_id without run_id does NOT enrich frame (5 segments) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'TOOL_MISSING' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$pC = Parse-CrossEnvelope $r.nack_text
Assert-True ($pC.reason -eq 'TOOL_MISSING') 'reason present (v2 has no segment ambiguity)' $pC.reason

Write-Host "== T-nack: nack_msg_id/nack_run_id propagation (7 segments, enriched) =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_orig' -ForRunId 'run_orig' -Reason 'PROVIDER_DOWN' -Model 'model-b' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$pD = Parse-CrossEnvelope $r.nack_text
Assert-True ($pD.msg_id -eq 'msg_orig' -and $pD.run_id -eq 'run_orig') 'v2 embeds msg_id/run_id' "$($pD.msg_id)|$($pD.run_id)"
Assert-True ($pD.reason -eq 'PROVIDER_DOWN') 'reason propagated' $pD.reason

Write-Host "== T-nack: BUG Y - enriched WITHOUT --model auto-derives from config (7 segments) =="
if (-not $myModel) {
    Write-Host "  SKIP  enriched without --model: config template has empty my_model (publish template)"
} else {
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -ForRunId 'R1' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True ($r.ok) 'enriched nack ok' $r.err
$pE = Parse-CrossEnvelope $r.nack_text
Assert-True ($pE.reason -eq 'CAPACITY' -and $pE.msg_id -eq 'msg_x' -and $pE.run_id -eq 'R1' -and $pE.model -eq $myModel) 'v2 unambiguous (reason/model/ids correct)' "$($pE.reason)|$($pE.model)|$($pE.msg_id)|$($pE.run_id)"
}

Write-Host "== T-nack: closed reasons =="
foreach ($razon in @('CAPACITY', 'TOOL_MISSING', 'AMBIGUOUS_TASK', 'PROVIDER_DOWN', 'OTHER')) {
    New-Fixture
    $r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason $razon -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
    Assert-True ($r.ok -and $r.reason -eq $razon) "valid reason $razon" $r.err
}

Write-Host "== T-nack: non-closed reason -> NACK_REASON_INVALID =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'PORQUE_NO' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'NACK_REASON_INVALID') 'free reason rejected' $r.err

Write-Host "== T-nack: empty token -> USAGE_ERROR =="
New-Fixture
$r = Send-CrossNack -Token '' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
Assert-True (-not $r.ok -and $r.err -eq 'USAGE_ERROR') 'empty token rejected' $r.err

Write-Host "== T-nack: audit recorded with reason =="
New-Fixture
$r = Send-CrossNack -Token 'T1' -ForMsgId 'msg_x' -Reason 'CAPACITY' -Dest 'ses_Y' -Note 'context exhausted' -AuditPath $script:AuditFile -SendFn { param($d,$t) Fake-Send $d $t }
$audit = Get-Content -LiteralPath $script:AuditFile -Raw
Assert-True ($audit -match '\| NACK \| ENVIADO \|') 'audit type NACK / SENT' $audit
Assert-True ($audit -match 'nack reason=CAPACITY') 'audit with reason' $audit
Assert-True ($audit -match 'msg=msg_x') 'audit with msg_id' $audit

Write-Host ""
Stop-CleanFixture

Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
