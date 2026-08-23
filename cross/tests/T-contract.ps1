# Contract tests (Fase 1, v1.9): envelope JSON v2 - round-trip, v1 fallback,
# body mixto, prevalencia v2, ConvertTo-CrossV1.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-contract.ps1
$ErrorActionPreference = 'Stop'
$mod = Join-Path $PSScriptRoot '..\modules\cross-envelope.psm1'
Import-Module $mod -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-delivery.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-envelope.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-contract: round-trip v2 (message) =="
$env = New-CrossEnvelope -MsgId 'msg_lead_001' -RunId 'R1' -Token 'T1' -Text 'Simple task'
$p = Parse-CrossEnvelope -Text $env
Assert-True ($p.valid -and $p.format -eq 'v2-json') 'v2 valid + format v2-json' $env
Assert-True ($p.msg_id -eq 'msg_lead_001') 'msg_id preserved' $p.msg_id
Assert-True ($p.run_id -eq 'R1') 'run_id preserved' $p.run_id
Assert-True ($p.token -eq 'T1') 'token preserved' $p.token
Assert-True ($p.type -eq 'message') 'type message' $p.type
Assert-True ($p.requires_ack -eq $true) 'requires_ack default true' $p.requires_ack
Assert-True ($p.payload_text -eq 'Simple task') 'payload.text preserved' $p.payload_text
Assert-True ($p.timestamp -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}') 'timestamp ISO8601' $p.timestamp

Write-Host "== T-contract: round-trip v2 (fields opcionales + unicode) =="
$env2 = New-CrossEnvelope -MsgId 'msg_002' -RunId 'R2' -Token 'T2' -RequiresAck $false -Lease 'ses_A@2026-08-21T15:00:00Z' -Successor 'ses_B' -Text "Unicode: jp rus ar | pipe = equals"
$p2 = Parse-CrossEnvelope -Text $env2
Assert-True ($p2.valid) 'v2 with optional fields valid' ''
Assert-True ($p2.requires_ack -eq $false) 'requires_ack=false preserved' $p2.requires_ack
Assert-True ($p2.lease -eq 'ses_A@2026-08-21T15:00:00Z') 'lease preserved' $p2.lease
Assert-True ($p2.successor -eq 'ses_B') 'successor preserved' $p2.successor
Assert-True ($p2.payload_text -eq "Unicode: jp rus ar | pipe = equals") 'payload with pipes preserved' $p2.payload_text

Write-Host "== T-contract: round-trip ACK/NACK JSON =="
$ack = New-CrossAckJson -Token 'MSG-abc123' -MsgId 'msg_lead_001' -Emitter 'ses_B' -Model 'model-b'
$pa = Parse-CrossEnvelope -Text $ack
Assert-True ($pa.valid -and $pa.type -eq 'ack') 'ack JSON valid' $ack
Assert-True ($pa.token -eq 'MSG-abc123' -and $pa.emitter -eq 'ses_B' -and $pa.model -eq 'model-b') 'ack fields' "$($pa.token)|$($pa.emitter)|$($pa.model)"
$nack = New-CrossNackJson -Token 'MSG-abc123' -MsgId 'msg_lead_001' -Emitter 'ses_B' -Model 'model-b' -Reason 'TASK_TOO_COMPLEX' -Detail 'Cannot access external APIs'
$pn = Parse-CrossEnvelope -Text $nack
Assert-True ($pn.valid -and $pn.type -eq 'nack') 'nack JSON valid' $nack
Assert-True ($pn.token -eq 'MSG-abc123' -and $pn.reason -eq 'TASK_TOO_COMPLEX' -and $pn.detail -eq 'Cannot access external APIs') 'nack fields' "$($pn.token)|$($pn.reason)|$($pn.detail)"

Write-Host "== T-contract: delivery parser is v2-only (D1 v1.17) =="
$rp = Parse-CrossEnvelope $ack
Assert-True ($rp.valid -and $rp.type -eq 'ack' -and $rp.token -eq 'MSG-abc123' -and $rp.emitter -eq 'ses_B' -and $rp.model -eq 'model-b') 'pure JSON response detected (v2)' "$($rp.valid)|$($rp.token)"

$mixed = "Analiza el informe y responde.`nENVELOPE-V2: $ack"
$rm = Parse-CrossEnvelope $mixed
Assert-True ($rm.valid -and $rm.type -eq 'ack' -and $rm.token -eq 'MSG-abc123') 'mixed body ack detected' "$($rm.valid)|$($rm.token)"

$rm2 = Parse-CrossEnvelope $env
Assert-True ($rm2.valid -and $rm2.type -eq 'message') 'type=message parses as message' "$($rm2.valid)|$($rm2.type)"
Assert-True ($rm2.type -ne 'ack' -and $rm2.type -ne 'nack') 'type=message not ack/nack' ''

# D1 regression (inverted): legacy v1 free-text formats MUST be rejected by the v2-only parser
$c1 = Parse-CrossEnvelope 'ACK:PROPUESTA-R1:ses_BBB:model-b'
Assert-True (-not $c1.valid) 'v1 ACK 4-seg rejected' ''
$c2 = Parse-CrossEnvelope 'ACK:TOKEN:ses_CCC'
Assert-True (-not $c2.valid) 'v1 ACK 3-seg rejected' ''
$c3 = Parse-CrossEnvelope 'NACK:PROPUESTA-R1:ses_BBB:model-b:CAPACITY'
Assert-True (-not $c3.valid) 'v1 NACK 5-seg rejected' ''
$c4 = Parse-CrossEnvelope 'NACK:TK:ses_A:model-b:CAPACITY:msg_123:RUN_456'
Assert-True (-not $c4.valid) 'v1 NACK enriched rejected' ''
$c5 = Parse-CrossEnvelope 'MODEL-A E2E OK. Firma: TOKEN:MSG-c9d8a9ee7451:ses_BBBB:model-a'
Assert-True (-not $c5.valid) 'v1 E1 TOKEN:MSG- rejected' ''
$c6 = Parse-CrossEnvelope 'entendido ACK-PROTOCOLO:1.8 ok'
Assert-True (-not $c6.valid) 'protocolo handshake line rejected by delivery parser (lives in cross-handshake)' ''
$c7 = Parse-CrossEnvelope 'normal response'
Assert-True (-not $c7.valid) 'normal response no match' ''

$bad = "ENVELOPE-V2: {not json} ACK:T1:ses_X:m1"
$rb = Parse-CrossEnvelope $bad
Assert-True (-not $rb.valid) 'invalid v2 does NOT fall back to v1 ACK' ''

$v1env = '{"v":1,"type":"message","msg_id":"m_1","timestamp":"2026-08-21T00:00:00Z"}'
$rv1 = Parse-CrossEnvelope -Text "ENVELOPE-V2: $v1env"
Assert-True (-not $rv1.valid) 'v=1 rejected by Parse-CrossEnvelope' "$($rv1.valid)"
$rv1b = Parse-CrossEnvelope "ENVELOPE-V2: $v1env ACK:T2:ses_Y:m2"
Assert-True (-not $rv1b.valid) 'v=1 does NOT fall back to v1 ACK' ''

$unkEnv = '{"v":2,"type":"weird","msg_id":"m_2","timestamp":"2026-08-21T00:00:00Z"}'
$ru = Parse-CrossEnvelope -Text "ENVELOPE-V2: $unkEnv"
Assert-True (-not $ru.valid) 'unknown type rejected' "$($ru.valid)"

$badBool = '{"v":2,"type":"message","msg_id":"m_3","requires_ack":"yes","timestamp":"2026-08-21T00:00:00Z"}'
$rb2 = Parse-CrossEnvelope -Text "ENVELOPE-V2: $badBool"
Assert-True (-not $rb2.valid) 'requires_ack non-bool rejected' "$($rb2.valid)"

$badTs = '{"v":2,"type":"message","msg_id":"m_4","timestamp":"ayer"}'
$rb3 = Parse-CrossEnvelope -Text "ENVELOPE-V2: $badTs"
Assert-True (-not $rb3.valid) 'timestamp non-ISO rejected' "$($rb3.valid)"

$both = "ENVELOPE-V2: $ack ACK:OTRO:ses_Z:m9"
$rb4 = Parse-CrossEnvelope $both
Assert-True ($rb4.valid -and $rb4.token -eq 'MSG-abc123' -and $rb4.emitter -eq 'ses_B') 'v2 wins over trailing v1 junk' "$($rb4.token)|$($rb4.emitter)"
Write-Host "== T-contract: ConvertTo-CrossV1 removed in v2.0 =="
Assert-True (-not (Get-Command ConvertTo-CrossV1 -ErrorAction SilentlyContinue)) '''ConvertTo-CrossV1 removed (v2.0 breaking)''' '''removed'''

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
