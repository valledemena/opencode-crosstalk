# T-wait-idle.ps1 - Wait-CrossSessionIdle tests (Fase 2). No server required (mocks).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-wait-idle.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'modules\cross-transport.psm1') -Force -DisableNameChecking

$pass = 0; $fail = 0
function Assert-True { param([bool]$Cond, [string]$Name, [string]$Detail='')
  if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
  else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-wait-idle: wait endpoint returns 204 =="
$waitMock = [scriptblock]{ param($id) return @{ status = 204 } }
$res = Wait-CrossSessionIdle -Id 'ses_X' -SleepFn ([scriptblock]{ }) -WaitEndpointFn $waitMock -TimeoutSec 5 -PollIntervalMs 500
Assert-True ($res.idle -eq $true) 'idle=true when 204' $res.method
Assert-True ($res.method -eq 'wait-endpoint') 'method=wait-endpoint' $res.method

Write-Host "== T-wait-idle: wait endpoint non-204 falls back to poll =="
$waitMock404 = [scriptblock]{ param($id) return @{ status = 404 } }
$pollMock = [scriptblock]{ param($id) return @{ ok = $true; time_updated = [DateTimeOffset]::UtcNow.AddMilliseconds(-5000).ToUnixTimeMilliseconds(); time_idle = [DateTimeOffset]::UtcNow.AddMilliseconds(-1000).ToUnixTimeMilliseconds() } }
$resPoll = Wait-CrossSessionIdle -Id 'ses_X' -SleepFn ([scriptblock]{ }) -WaitEndpointFn $waitMock404 -StateFn $pollMock -TimeoutSec 5 -PollIntervalMs 200 -QuietThresholdMs 3000
Assert-True ($resPoll.idle -eq $true) 'poll finds idle via time.idle>=updated' $resPoll.method

Write-Host "== T-wait-idle: poll quiet threshold =="
$quietMock = [scriptblock]{ param($id) return @{ ok = $true; time_updated = [DateTimeOffset]::UtcNow.AddMilliseconds(-10000).ToUnixTimeMilliseconds(); time_idle = $null } }
$resQuiet = Wait-CrossSessionIdle -Id 'ses_X' -SleepFn ([scriptblock]{ }) -WaitEndpointFn $waitMock404 -StateFn $quietMock -TimeoutSec 5 -PollIntervalMs 200 -QuietThresholdMs 3000
Assert-True ($resQuiet.idle -eq $true) 'poll finds idle via quiet threshold' $resQuiet.method
Assert-True ($resQuiet.method -match 'poll-') 'poll method label' $resQuiet.method

Write-Host "== T-wait-idle: timeout when never idle =="
$neverIdleMock = [scriptblock]{ param($id) return @{ ok = $true; time_updated = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); time_idle = 0 } }
$resTimeout = Wait-CrossSessionIdle -Id 'ses_X' -SleepFn ([scriptblock]{ }) -WaitEndpointFn $waitMock404 -StateFn $neverIdleMock -TimeoutSec 1 -PollIntervalMs 500 -QuietThresholdMs 3000
Assert-True ($resTimeout.idle -eq $false) 'timeout: idle=false' $resTimeout.timed_out
Assert-True ($resTimeout.timed_out -eq $true) 'timeout: timed_out=true' $resTimeout.method

Write-Host "== T-wait-idle: no endpoint (curl 0) -> poll fallback =="
$waitMockNull = [scriptblock]{ param($id) return @{ status = 0 } }
$resNull = Wait-CrossSessionIdle -Id 'ses_X' -SleepFn ([scriptblock]{ }) -WaitEndpointFn $waitMockNull -StateFn $pollMock -TimeoutSec 3 -PollIntervalMs 500 -QuietThresholdMs 3000
# Should fall back and find idle from mock
Assert-True ($resNull.ok -eq $true) 'fallback poll succeeds' $resNull.idle

Write-Host "== RESULT: $pass pass, $fail fail =="
if ($fail -gt 0) { exit 1 } else { exit 0 }
