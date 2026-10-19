# Transport tests: auto-detection, health, cache, errors.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-transport.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$mod = Join-Path $PSScriptRoot '..\modules\cross-transport.psm1'
Import-Module $mod -Force

$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

Write-Host "== T-transport: config =="
$cfg = Import-CrossConfig
Assert-True ($null -ne $cfg) 'Import-CrossConfig returns object' ($cfg.GetType().Name)
Assert-True ($cfg.my_role -eq 'leader') 'config.my_role=leader' $cfg.my_role
Assert-True ($cfg.protocol_version.Length -gt 0) 'config.protocol_version present'

Write-Host "== T-transport: cross.config.local.json override =="
$cfgDir = Join-Path $env:TEMP ('cross_cfg_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
$baseCfg = Join-Path $cfgDir 'cross.config.json'
$localCfg = Join-Path $cfgDir 'cross.config.local.json'
$baseSchema = '{"my_session_id":"","my_role":"leader","my_model":"","protocol_version":"1.8","port_cache_ttl_s":60,"max_retries":2,"retry_backoff_s":2,"default_ack_timeout_s":120,"default_lease_minutes":3,"max_saltos":2,"session_growing_check_ms":15000,"whiteboard_dir":"./whiteboard","log_path":"%USERPROFILE%\\.local\\share\\opencode\\log\\opencode.log","desktop_logs_dir":"%APPDATA%\\ai.opencode.desktop\\logs","port_scan_range":[30000,40000]}'
[System.IO.File]::WriteAllText($baseCfg, $baseSchema, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($localCfg, '{"my_session_id":"ses_LOCAL","my_model":"model-x"}', (New-Object System.Text.UTF8Encoding($false)))
$cfgL = Import-CrossConfig -ConfigPath $baseCfg
Assert-True ($cfgL.my_session_id -eq 'ses_LOCAL') 'local override my_session_id' $cfgL.my_session_id
Assert-True ($cfgL.my_model -eq 'model-x') 'local override my_model' $cfgL.my_model
Assert-True ($cfgL.my_role -eq 'leader') 'base preserved when not overridden' $cfgL.my_role
$noLocalDir = Join-Path $env:TEMP ('cross_cfg_nolocal_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $noLocalDir -Force | Out-Null
$baseOnly = Join-Path $noLocalDir 'cross.config.json'
[System.IO.File]::WriteAllText($baseOnly, '{"my_session_id":"ses_BASE","my_model":"","my_role":"advisor","port_cache_ttl_s":60}', (New-Object System.Text.UTF8Encoding($false)))
$cfgN = Import-CrossConfig -ConfigPath $baseOnly
Assert-True ($cfgN.my_session_id -eq 'ses_BASE') 'base used when no local file' $cfgN.my_session_id
$null = Import-CrossConfig

$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
$haveServer = (Test-Path $logDir) -and [bool](Get-ChildItem $logDir -ErrorAction SilentlyContinue) -and [bool](Get-CrossPassword)

$script:serverScenarios = 6
if (-not $haveServer) {
    Write-Host "  SKIP  $($script:serverScenarios) server-dependent scenarios: no OpenCode Desktop server logs/password in this environment (publish template)"
}

if ($haveServer) {
Write-Host "== T-transport: password =="
$pw = Get-CrossPassword
if ($pw) {
    Assert-True ($pw.value.Length -gt 0) 'password obtained' 'empty'
    Assert-True ($pw.source -in @('env','env_file')) 'password.source valid' $pw.source
} else {
    Assert-True $false 'password obtained' 'no env nor .env'
}

Write-Host "== T-transport: health raw =="
# -NoCache (not -HealthSkip): a stale well-known/cache hint must not make this
# suite order-dependent. Detection is refreshed from logs and the healthy port.
$ep = Resolve-CrossEndpoint -NoCache
Assert-True ($ep.ok) 'Resolve-CrossEndpoint ok' ($ep.err)
if ($ep.ok) {
    Assert-True ($ep.port -gt 0) 'port > 0' $ep.port
    Assert-True ($ep.password_source -in @('env','env_file','override')) 'password_source valid' $ep.password_source
    $h = Test-CrossHealthRaw -Port $ep.port -Password $ep.password
    Assert-True ($h.status -eq 200) 'health HTTP 200' $h.status
    Assert-True ($h.healthy) 'health healthy=true' $h.healthy
}

Write-Host "== T-transport: port override =="
$ep2 = Resolve-CrossEndpoint -Port 13537 -HealthSkip
Assert-True ($ep2.ok) 'port override ok' ($ep2.err)
if ($ep2.ok) {
    Assert-True ($ep2.detection_method -eq 'override') 'detection_method=override' $ep2.detection_method
}

Write-Host "== T-transport: errors =="
$epBad = Resolve-CrossEndpoint -Port 1 -Password "wrong-password-xyz"
Assert-True (-not $epBad.ok) 'port 1 + invalid password -> fail' ($epBad.err)
if (-not $epBad.ok) {
    Assert-True ($epBad.err -in @('UNHEALTHY','AUTH_FAILED')) 'err classified' $epBad.err
}

Write-Host "== T-transport: cache =="
$pwHash = Get-PasswordHash $ep.password
Write-CrossPortCache -Port $ep.port -PasswordHash $pwHash
$cached = Get-CrossPortFromCache -TtlSeconds 60 -PasswordHash $pwHash
Assert-True ($cached -eq $ep.port) 'cache written and read' $cached
$badHash = Get-PasswordHash 'wrong'
$cachedBad = Get-CrossPortFromCache -TtlSeconds 60 -PasswordHash $badHash
Assert-True ($null -eq $cachedBad) 'cache with wrong password rejected' $cachedBad

Write-Host "== T-transport: Get-CrossPortByScan (TCP scan + health) =="
$rango = @($ep.port, $ep.port + 1)
$scanned = Get-CrossPortByScan -ScanRange $rango
Assert-True ($scanned -eq $ep.port) 'scan finds the real port (only the healthy one)' $scanned
}

Write-Host "== T-transport: Get-CrossPortFromLog (main.log regex, standalone fixture) =="
$logsRoot = Join-Path $env:TEMP ('cross_tlogs_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $logsRoot '2026-08-13') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $logsRoot '2026-08-12') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $logsRoot '2026-08-12\main.log'), "something without url`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $logsRoot '2026-08-13\main.log'), "info line`nserver ready. opencode:// opbgr. url: 'http://127.0.0.1:61234'`n", (New-Object System.Text.UTF8Encoding($false)))
(Get-Item (Join-Path $logsRoot '2026-08-13')).LastWriteTime = (Get-Date)
(Get-Item (Join-Path $logsRoot '2026-08-12')).LastWriteTime = (Get-Date).AddDays(-1)
$oldEnv = [Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR')
try {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $logsRoot)
    $port = Get-CrossPortFromLog
    Assert-True ($port -eq 61234) 'regex extracts port from most recent main.log' $port
} finally {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $oldEnv)
}
$logsEmpty = Join-Path $env:TEMP ('cross_tlogs_empty_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logsEmpty -Force | Out-Null
$oldEnv2 = [Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR')
try {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $logsEmpty)
    Assert-True ($null -eq (Get-CrossPortFromLog)) 'dir without main.log -> null' (Get-CrossPortFromLog)
} finally {
    [Environment]::SetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR', $oldEnv2)
}

Write-Host "== T-transport: Get-CrossNetrcFile =="
$netrc = Get-CrossNetrcFile -Password 'test-pw-123'
try {
    Assert-True (Test-Path -LiteralPath $netrc) 'netrc file created' $netrc
    Assert-True ($netrc -match 'cross_netrc_[0-9a-f]{32}\.txt$') 'netrc unique guid name' $netrc
    $netrcContent = [System.IO.File]::ReadAllText($netrc, [System.Text.Encoding]::ASCII)
    Assert-True ($netrcContent -eq "machine 127.0.0.1`nlogin opencode`npassword test-pw-123") 'netrc content ASCII machine/login/password' $netrcContent
    $acl = [System.IO.File]::GetAccessControl($netrc)
    $netrcRules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.NTAccount]))
    Assert-True ($netrcRules.Count -ge 1) 'netrc has at least 1 ACL rule' "rules=$($netrcRules.Count)"
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $userRules = @($netrcRules | Where-Object { $_.IdentityReference.Value -eq $currentUser })
    Assert-True ($userRules.Count -ge 1) 'netrc ACL grants access to current user' "user=$currentUser userRules=$($userRules.Count)"
} finally {
    Remove-Item -LiteralPath $netrc -ErrorAction SilentlyContinue
}
if ($haveServer) {
    $netrcLeftovers = @(Get-ChildItem $env:TEMP -Filter 'cross_netrc_*.txt' -ErrorAction SilentlyContinue)
    Assert-True ($netrcLeftovers.Count -eq 0) 'no netrc leftovers after Invoke-CrossApi/HealthRaw (finally cleanup)' "leftovers=$($netrcLeftovers.Count)"
}

Write-Host "== T-transport: v2.1.1 relative config paths resolve against the config file =="
$relDir = Join-Path $env:TEMP ('cross_trel_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $relDir | Out-Null
$relCfgPath = Join-Path $relDir 'cfg.json'
$relCfg = [ordered]@{ my_session_id = 'ses_rel'; my_role = 'advisor'; whiteboard_dir = './wb'; log_path = 'logs\x.log' }
[System.IO.File]::WriteAllText($relCfgPath, ($relCfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
$oldCwd = Get-Location
try {
    Set-Location $env:TEMP   # deliberately different from the config directory
    $cfgRel = Import-CrossConfig -ConfigPath $relCfgPath
    $expectedWb = Join-Path $relDir 'wb'
    Assert-True ([System.IO.Path]::IsPathRooted([string]$cfgRel.whiteboard_dir)) 'whiteboard_dir made absolute' $cfgRel.whiteboard_dir
    Assert-True ([string]$cfgRel.whiteboard_dir -eq $expectedWb) 'whiteboard_dir resolved against config dir' $cfgRel.whiteboard_dir
    Assert-True ([string]$cfgRel.log_path -eq (Join-Path $relDir 'logs\x.log')) 'log_path resolved against config dir' $cfgRel.log_path
} finally {
    Set-Location $oldCwd
    Remove-Item -LiteralPath $relDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if (-not $haveServer) {
    Write-Host ("RESULT: {0} pass, {1} fail, {2} skipped (server-dependent)" -f $pass, $fail, $script:serverScenarios)
} else {
    Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
}
if ($fail -gt 0) { exit 1 } else { exit 0 }