# Port discovery tests (v1.11): well-known server.port, diag logging, scan timeout.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-port.ps1
$ErrorActionPreference = 'Stop'
$mod = Join-Path $PSScriptRoot '..\modules\cross-transport.psm1'
$ipcMod = Join-Path $PSScriptRoot '..\modules\cross-ipc.psm1'
Import-Module $ipcMod -Force
Import-Module $mod -Force

$pass = 0; $fail = 0
# D4 (v1.17): cross-platform child PowerShell (pwsh on Linux, powershell.exe on Windows)
if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath().TrimEnd('/', '\') }
$psExe = if ($env:OS -eq 'Windows_NT') { 'powershell.exe' } elseif (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
$homeDir = if ($env:HOME) { $env:HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
function Assert-True {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

# D4 (v1.17): cross-platform child PowerShell (pwsh on Linux, powershell.exe on Windows)
if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath().TrimEnd('/', '\') }
$psExe = if ($env:OS -eq 'Windows_NT') { 'powershell.exe' } elseif (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
$homeDir = if ($env:HOME) { $env:HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }

Write-Host "== T-port: well-known round-trip (HOME aislado) =="
$realUser = $homeDir
$isoUser = Join-Path $env:TEMP ('cross_wk_user_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $isoUser -Force | Out-Null
$wkFile = Join-Path (Join-Path $isoUser '.config\opencode') 'server.port'
try {
    $env:HOME = $isoUser
    $env:USERPROFILE = $isoUser
    Assert-True ($null -eq (Get-CrossPortWellKnown)) 'well-known inexistente -> null' (Get-CrossPortWellKnown)

    $null = Write-CrossPortWellKnown -Port 12345
    Assert-True (Test-Path -LiteralPath $wkFile) 'Write-CrossPortWellKnown crea el archivo' $wkFile
    Assert-True ((Get-CrossPortWellKnown) -eq 12345) 'well-known round-trip 12345' (Get-CrossPortWellKnown)

    $null = Write-CrossPortWellKnown -Port 0
    Assert-True ((Get-CrossPortWellKnown) -eq 12345) 'puerto 0 rechazado (no pisa el archivo)' (Get-CrossPortWellKnown)
    $null = Write-CrossPortWellKnown -Port 70000
    Assert-True ((Get-CrossPortWellKnown) -eq 12345) 'puerto 70000 rechazado' (Get-CrossPortWellKnown)

    [System.IO.File]::WriteAllText($wkFile, 'abc', (New-Object System.Text.UTF8Encoding($false)))
    Assert-True ($null -eq (Get-CrossPortWellKnown)) 'contenido no numerico -> null (no throw)' (Get-CrossPortWellKnown)
    [System.IO.File]::WriteAllText($wkFile, '70000', (New-Object System.Text.UTF8Encoding($false)))
    Assert-True ($null -eq (Get-CrossPortWellKnown)) 'puerto fuera de rango -> null' (Get-CrossPortWellKnown)
    [System.IO.File]::WriteAllText($wkFile, '', (New-Object System.Text.UTF8Encoding($false)))
    Assert-True ($null -eq (Get-CrossPortWellKnown)) 'archivo vacio -> null (NEMOTRON-N2)' (Get-CrossPortWellKnown)
} finally {
    $env:HOME = $realUser
    $env:USERPROFILE = $realUser
    if (Test-Path -LiteralPath $isoUser) { Remove-Item -LiteralPath $isoUser -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "== T-port: Write-CrossDiag (stderr, niveles) =="
$diagCmd = "Import-Module '$mod' -Force; {0}"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $rDebug = & $psExe -NoProfile -ExecutionPolicy Bypass -Command ($diagCmd -f "Write-CrossDiag -Level debug -Message 'probe-debug'") 2>&1
    Assert-True (($rDebug | Out-String) -notmatch 'probe-debug') 'debug silencioso con CROSS_DIAG por defecto (warn)' ($rDebug | Out-String)
    $rWarn = & $psExe -NoProfile -ExecutionPolicy Bypass -Command ($diagCmd -f "Write-CrossDiag -Level warn -Message 'probe-warn'") 2>&1
    Assert-True (($rWarn | Out-String) -match 'probe-warn') 'warn visible en stderr (prefijo [cross-diag])' ($rWarn | Out-String)
    $env:OLD_CROSS_DIAG = [Environment]::GetEnvironmentVariable('CROSS_DIAG')
    try {
        [Environment]::SetEnvironmentVariable('CROSS_DIAG', 'trace')
        $rTrace = & $psExe -NoProfile -ExecutionPolicy Bypass -Command ($diagCmd -f "Write-CrossDiag -Level trace -Message 'probe-trace'") 2>&1
        Assert-True (($rTrace | Out-String) -match 'probe-trace') 'nivel trace visible con CROSS_DIAG=trace (NEMOTRON-N4)' ($rTrace | Out-String)
    } finally {
        if ($env:OLD_CROSS_DIAG) { [Environment]::SetEnvironmentVariable('CROSS_DIAG', $env:OLD_CROSS_DIAG) }
        else { [Environment]::SetEnvironmentVariable('CROSS_DIAG', $null) }
    }
} finally {
    $ErrorActionPreference = $prevEap
}

Write-Host "== T-port: scan con ScanTimeoutMs (regresion) =="
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$scanned = Get-CrossPortByScan -ScanRange @(20000, 60000) -ScanTimeoutMs 5
$sw.Stop()
Assert-True ($null -eq $scanned) 'scan timeout sin candidatos -> null' $scanned
Assert-True ($sw.Elapsed.TotalMilliseconds -lt 1000) 'ScanTimeoutMs aborta rapido (<1s)' ([math]::Round($sw.Elapsed.TotalMilliseconds))

$logDir = (Join-Path $env:HOME '.config\opencode\desktop\logs')
$haveServer = (Test-Path $logDir) -and [bool](Get-ChildItem $logDir -ErrorAction SilentlyContinue) -and [bool](Get-CrossPassword)
$script:serverScenarios = 4
if (-not $haveServer) {
    Write-Host "  SKIP  $($script:serverScenarios) server-dependent scenarios: no OpenCode Desktop server in this environment (publish template)"
}

if ($haveServer) {
Write-Host "== T-port: cadena completa con well-known (server real) =="
$ep = Resolve-CrossEndpoint -HealthSkip
Assert-True ($ep.ok) 'Resolve-CrossEndpoint base ok' ($ep.err)
if ($ep.ok) {
    $wkReal = Join-Path (Get-CrossConfigDir) 'server.port'
    try {
        [System.IO.File]::WriteAllText($wkReal, "$($ep.port)", (New-Object System.Text.UTF8Encoding($false)))
        $epWk = Resolve-CrossEndpoint -NoCache
        Assert-True ($epWk.ok) 'Resolve con well-known valido ok' ($epWk.err)
        if ($epWk.ok) {
            Assert-True ($epWk.detection_method -eq 'well-known') 'detection_method=well-known' $epWk.detection_method
            Assert-True ($epWk.port -eq $ep.port) 'well-known devuelve el puerto correcto' $epWk.port
        }

        [System.IO.File]::WriteAllText($wkReal, 'corrupto', (New-Object System.Text.UTF8Encoding($false)))
        $epBad = Resolve-CrossEndpoint -NoCache
        Assert-True ($epBad.ok) 'well-known corrupto -> cae a siguiente fuente (no falla)' ($epBad.err)
        if ($epBad.ok) {
            Assert-True ($epBad.detection_method -ne 'well-known') 'cadena continua (regex o scan)' $epBad.detection_method
        }
    } finally {
        if (Test-Path -LiteralPath $wkReal) { Remove-Item -LiteralPath $wkReal -Force -ErrorAction SilentlyContinue }
    }
}
}

Write-Host ""
if (-not $haveServer) {
    Write-Host ("RESULT: {0} pass, {1} fail, {2} skipped (server-dependent)" -f $pass, $fail, $script:serverScenarios)
} else {
    Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
}
if ($fail -gt 0) { exit 1 } else { exit 0 }