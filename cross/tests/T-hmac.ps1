# T-hmac.ps1 - HMAC signature tests (Fase 2). No server required.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-hmac.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'modules\cross-envelope.psm1') -Force -DisableNameChecking

$pass = 0; $fail = 0
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail='')
  if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-hmac: secret resolution =="
$sec = Get-CrossHmacSecret -Secret 'test-secret-123'
Assert-True ($sec -eq 'test-secret-123') 'Get-CrossHmacSecret param' $sec

Write-Host "== T-hmac: signature canonical form =="
$sig1 = Get-CrossHmacSignature -Type 'message' -MsgId 'msg_1' -Token 'T1' -Timestamp '2026-01-01T00:00:00Z' -PayloadText 'hello' -Secret 'test-secret-123'
Assert-True ([string]::IsNullOrEmpty($sig1) -eq $false) 'signature non-empty' $sig1
$sig2 = Get-CrossHmacSignature -Type 'message' -MsgId 'msg_1' -Token 'T1' -Timestamp '2026-01-01T00:00:00Z' -PayloadText 'hello' -Secret 'test-secret-123'
Assert-True ($sig1 -eq $sig2) 'signature deterministic' "sig1=$sig1 sig2=$sig2"
$sig3 = Get-CrossHmacSignature -Type 'ack' -MsgId 'msg_1' -Token 'T1' -Timestamp '2026-01-01T00:00:00Z' -PayloadText '' -Secret 'test-secret-123'
Assert-True ($sig1 -ne $sig3) 'ack sig differs from message' ($sig3.Substring(0,[Math]::Min(8,$sig3.Length)))

Write-Host "== T-hmac: envelope with Secret =="
$json = New-CrossEnvelope -MsgId 'msg_hmac_01' -Token 'HMAC-T1' -Text 'test payload' -Secret 'test-secret-123'
$obj = $json | ConvertFrom-Json
Assert-True ($obj.sig -ne $null -and [string]$obj.sig -ne '') 'envelope has sig field' ([string]$obj.sig)

Write-Host "== T-hmac: parse exposes sig =="
$pe = Parse-CrossEnvelope -Text ("ENVELOPE-V2: $json")
Assert-True ($pe.valid -eq $true) 'parse valid' $pe.format
Assert-True ([string]::IsNullOrEmpty($pe.sig) -eq $false) 'parse exposes sig' $pe.sig

Write-Host "== T-hmac: verify valid =="
$check = Test-CrossEnvelopeSignature -Envelope $obj -Secret 'test-secret-123'
Assert-True ($check.valid -eq $true) 'verify valid with same secret' $check.reason

Write-Host "== T-hmac: verify invalid secret =="
$checkBad = Test-CrossEnvelopeSignature -Envelope $obj -Secret 'wrong-secret'
Assert-True ($checkBad.valid -eq $false) 'verify invalid with wrong secret' $checkBad.reason

Write-Host "== T-hmac: verify missing sig =="
$jsonNoSig = New-CrossEnvelope -MsgId 'msg_no_sig' -Token 'T' -Text 'x'
$objNoSig = $jsonNoSig | ConvertFrom-Json
$checkMissing = Test-CrossEnvelopeSignature -Envelope $objNoSig -Secret 'test-secret-123'
Assert-True ($checkMissing.valid -eq $false) 'verify fails when sig missing' $checkMissing.reason

Write-Host "== T-hmac: ack/nack with Secret =="
$ackJson = New-CrossAckJson -Token 'ACK-T' -MsgId 'msg_x' -Secret 'test-secret-123'
$nackJson = New-CrossNackJson -Token 'NACK-T' -MsgId 'msg_x' -Reason 'CAPACITY' -Secret 'test-secret-123'
$ackObj = $ackJson | ConvertFrom-Json; $nackObj = $nackJson | ConvertFrom-Json
Assert-True ([string]::IsNullOrEmpty([string]$ackObj.sig) -eq $false) 'ack has sig' ([string]$ackObj.sig)
Assert-True ([string]::IsNullOrEmpty([string]$nackObj.sig) -eq $false) 'nack has sig' ([string]$nackObj.sig)

Write-Host "== RESULT: $pass pass, $fail fail =="
if ($fail -gt 0) { exit 1 } else { exit 0 }
