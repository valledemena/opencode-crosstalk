# T-ipc.ps1 - Cross-platform IPC abstraction tests (v1.10).
# Cubre Get-CrossPlatform, Get-CrossEnvFile, Get-CrossConfigDir,
# Get-CrossMutex (API minima .WaitOne()/.ReleaseMutex()), contencion
# (2 hilos concurrentes), paths mockeados y regresion del mutex delegado
# en cross-state (Get-OutboxMutex) via cross validate.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-ipc.ps1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-ipc.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-state.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'fixture-clean.psm1') -Force -DisableNameChecking
Start-CleanFixture

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-ipc: Get-CrossPlatform =="
$plat = Get-CrossPlatform
$platStr = [string]$plat
Assert-True ($platStr -eq 'Windows' -or $platStr -eq 'Unix') 'valid platform value' $platStr
Assert-True ((Get-CrossPlatform) -eq $plat) 'cached result stable' "$(Get-CrossPlatform)"

Write-Host "== T-ipc: Get-CrossConfigDir / Get-CrossEnvFile =="
$cfgDir = Get-CrossConfigDir
Assert-True ([bool]$cfgDir) 'config dir non-empty' "$cfgDir"
$envFile = Get-CrossEnvFile
Assert-True ([bool]$envFile) 'env file non-empty' "$envFile"
if ($platStr -eq 'Windows') {
    Assert-True ($envFile -like '*opencode\.env') 'env file ends with opencode\.env' $envFile
} else {
    Assert-True ($envFile -match '\.env$') 'env file ends with .env (unix)' $envFile
}

Write-Host "== T-ipc: Get-CrossMutex round-trip (WaitOne/ReleaseMutex) =="
$lockPath = Join-Path (Get-CrossTempDir) ('cross_test_lock_' + [System.Guid]::NewGuid().ToString('N') + '.md')
[System.IO.File]::WriteAllText($lockPath, 'x', (New-Object System.Text.UTF8Encoding($false)))
$m = Get-CrossMutex -Path $lockPath
Assert-True ($null -ne $m) 'mutex object returned'
$got = $m.WaitOne(5000)
Assert-True ($got) 'WaitOne acquires' "got=$got"
$m.ReleaseMutex()
$m2 = Get-CrossMutex -Path $lockPath
$got2 = $m2.WaitOne(5000)
Assert-True ($got2) 'reacquire after release works' "got2=$got2"
$m2.ReleaseMutex()

Write-Host "== T-ipc: contention (2 threads, one waits, one releases) =="
$ipcModule = Join-Path $PSScriptRoot '..\modules\cross-ipc.psm1'
if ($platStr -eq 'Windows') {
    $m3 = Get-CrossMutex -Path $lockPath
    $m3.WaitOne(5000) | Out-Null
    $job = Start-Job -ScriptBlock {
        param($P, $Mod)
        Import-Module $Mod -Force -DisableNameChecking
        $mj = Get-CrossMutex -Path $P
        $ok = $mj.WaitOne(5000)
        if ($ok) { $mj.ReleaseMutex() }
        return $ok
    } -ArgumentList $lockPath, $ipcModule
    Start-Sleep -Milliseconds 800
    Assert-True ($job.State -eq 'Running') 'second thread blocks while held' $job.State
    $m3.ReleaseMutex()
    $r = Receive-Job $job -Wait -AutoRemoveJob
    Assert-True ([bool]$r) 'second thread acquires after release' "$r"
} else {
    $m3 = Get-CrossMutex -Path $lockPath
    $m3.WaitOne(5000) | Out-Null
    $m4 = Get-CrossMutex -Path $lockPath
    $ok = $m4.WaitOne(1500)
    Assert-True ($ok) 'file lock reentrant while held (RLock, same thread)' "ok=$ok"
    $m3.ReleaseMutex()
    $ok2 = $m4.WaitOne(5000)
    Assert-True ($ok2) 'file lock acquires after release' "ok2=$ok2"
    $m4.ReleaseMutex()
}
Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue

Write-Host "== T-ipc: Get-OutboxMutex regression (cross-state delegates) =="
$dir = Join-Path (Get-CrossTempDir) ('cross_tipc_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$obPath = Join-Path $dir 'outbox.md'
[System.IO.File]::WriteAllText($obPath, "# OUTBOX`n", (New-Object System.Text.UTF8Encoding($false)))
$om = Get-OutboxMutex -Path $obPath
$got3 = $om.WaitOne(5000)
Assert-True ($got3) 'Get-OutboxMutex WaitOne works' "got3=$got3"
$om.ReleaseMutex()

Write-Host "== T-ipc: Get-OutboxMutex via cross validate (outbox consistency) =="
try {
    $cons = Test-CrossConsistency -OutboxPath $obPath -StatePath (Join-Path $dir 'idempotencia-procesados.md')
    Assert-True ($null -ne $cons) 'Test-CrossConsistency returns' "$(if ($cons) { $cons.errors.Count } else { 'null' })"
} catch {
    Assert-True $false 'Test-CrossConsistency no exception' $_.Exception.Message
}
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Stop-CleanFixture
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }