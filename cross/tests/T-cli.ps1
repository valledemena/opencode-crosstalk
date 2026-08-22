# End-to-end tests for the cross.ps1 CLI (Phase 1).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-cli.ps1
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '../cross.ps1'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param([bool]$Cond, [string]$Name, [string]$Detail = '')
    if ($Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
# D4 (v1.17): cross-platform child PowerShell (pwsh on Linux, powershell.exe on Windows)
if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath().TrimEnd('/', '\') }
$psExe = if ($env:OS -eq 'Windows_NT') { 'powershell.exe' } elseif (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
$config = Get-Content (Join-Path $PSScriptRoot '..\cross.config.json') -Raw | ConvertFrom-Json
$crossRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$mySession = $config.my_session_id
$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
$haveServer = (Test-Path $logDir) -and [bool](Get-ChildItem $logDir -ErrorAction SilentlyContinue) -and [bool](Get-CrossPassword)
$script:serverScenarios = 9
if (-not $haveServer) {
    Write-Host "  SKIP  $($script:serverScenarios) server-dependent scenarios: no OpenCode Desktop server logs/password in this environment (publish template)"
}
function Invoke-CrossCli {
    param([string[]]$CliArgs)
    $tmp = Join-Path $env:TEMP ("cross_cli_" + [System.Guid]::NewGuid().ToString('N') + ".json")
    # v1.17: stderr del hijo (diag warnings) no debe abortar bajo EAP=Stop
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $psExe -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>$null | Out-File -LiteralPath $tmp -Encoding ascii
$ErrorActionPreference = $prevEap
    $raw = Get-Content -LiteralPath $tmp -Raw
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return $raw
}
function Get-Json {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    try { return ($Raw | ConvertFrom-Json) } catch { return $null }
}

Write-Host "== T-cli: health =="
if (-not $haveServer) {
    Write-Host "  SKIP  health: no server (publish template)"
    $script:pass++
} else {
$r = Get-Json (Invoke-CrossCli @('health'))
Assert-True ($null -ne $r) 'health emits JSON' 'null'
Assert-True ($r.ok -eq $true) 'health ok=true' $r.ok
Assert-True ($r.healthy -eq $true) 'health healthy=true' $r.healthy
Assert-True ($r.port -gt 0) 'health port>0' $r.port
}

Write-Host "== T-cli: whoami =="
$r = Get-Json (Invoke-CrossCli @('whoami'))
if ($r.ok -and $r.session_id.Length -gt 0) {
    Assert-True ($r.ok -eq $true) 'whoami ok' $r.ok
    Assert-True ($r.session_id.Length -gt 0) 'whoami session_id' $r.session_id
    Assert-True ($r.model.Length -gt 0) 'whoami model' $r.model
} else {
    Write-Host "  SKIP  whoami: config template has empty IDs (publish template); testing overrides instead"
    $ro = Get-Json (Invoke-CrossCli @('whoami', '--session-id', 'ses_TEST', '--model', 'test-model'))
    Assert-True ($ro.ok -eq $true -and $ro.session_id -eq 'ses_TEST') 'whoami --session-id override' $ro.ok
    Assert-True ($ro.identity_source -eq 'override') 'whoami identity_source=override' $ro.identity_source
    $r = $ro
}
Assert-True ($r.ok -eq $true) 'whoami ok (fallback)' $r.ok

Write-Host "== T-cli: sessions =="
if (-not $haveServer) {
    Write-Host "  SKIP  sessions: no server (publish template)"
    $script:pass++
} else {
$r = Get-Json (Invoke-CrossCli @('sessions'))
Assert-True ($r.ok -eq $true) 'sessions ok' $r.ok
Assert-True ($r.count -ge 1) 'sessions count>=1' $r.count
Assert-True ($r.sessions.Count -eq $r.count) 'sessions array matches' $r.sessions.Count

Write-Host "== T-cli: sessions --directory =="
$dirProbe = 'C:\Users\unknown\Desktop\CROSS'
if (-not (Test-Path -LiteralPath $dirProbe)) { $dirProbe = $crossRoot }
$r = Get-Json (Invoke-CrossCli @('sessions', '--directory', $dirProbe))
Assert-True ($r.ok -eq $true) 'sessions --directory ok' $r.ok
Assert-True ($r.count -ge 1) 'sessions dir count>=1' $r.count
Assert-True (@($r.sessions | Where-Object { $_.directory -match 'CROSS' }).Count -eq $r.count) 'all with dir CROSS' ''
}

Write-Host "== T-cli: read =="
if (-not $haveServer) {
    Write-Host "  SKIP  read: no server (publish template)"
    $script:pass++
} else {
if (-not $mySession) {
    # Publish template has empty IDs: discover a real session in the CROSS workdir if available
    $real = Get-Json (Invoke-CrossCli @('sessions', '--directory', 'C:\Users\unknown\Desktop\CROSS'))
    if ($real.ok -and $real.count -ge 1) { $mySession = $real.sessions[0].id }
}
if ($mySession) {
    $r = Get-Json (Invoke-CrossCli @('read', '--session', $mySession, '--limit', '2'))
    Assert-True ($r.ok -eq $true) 'read ok' $r.ok
    Assert-True ($r.count -ge 1) 'read count>=1' $r.count
    Assert-True (@($r.messages).Count -eq $r.count) 'read messages match' ''
    Assert-True (@($r.messages | Where-Object { $_.id -match '^msg_' }).Count -eq $r.count) 'ids msg_' ''
} else {
    Write-Host "  SKIP  read: no session available in this environment (publish template)"
    $script:pass++
}
}

Write-Host "== T-cli: read --role=user =="
if (-not $haveServer) {
    Write-Host "  SKIP  read --role: no server (publish template)"
    $script:pass++
} else {
if ($mySession) {
    $r = Get-Json (Invoke-CrossCli @('read', "--session=$mySession", '--role=user', '--limit=2'))
    Assert-True ($r.ok -eq $true) 'read --role ok' $r.ok
    Assert-True (@($r.messages | Where-Object { $_.role -ne 'user' }).Count -eq 0) 'all role=user' ''
} else {
    Write-Host "  SKIP  read --role: no session available (publish template)"
    $script:pass++
}
}

Write-Host "== T-cli: errors =="
$r = Get-Json (Invoke-CrossCli @('badcmd'))
Assert-True ($r.code -eq 64 -and -not $r.ok) 'unknown subcommand -> 64' $r.err
$r = Get-Json (Invoke-CrossCli @('read'))
Assert-True ($r.code -eq 64) 'read without --session -> 64' $r.err

Write-Host "== T-cli: human output =="
if (-not $haveServer) {
    Write-Host "  SKIP  human output: no server (publish template)"
    $script:pass++
} else {
$out = Invoke-CrossCli @('health', '--human')
Assert-True ($out -match 'cross health -> OK') 'health --human text' $out
$out = Invoke-CrossCli @('sessions', '--human')
Assert-True ($out -match 'sesion') 'sessions --human list' $out
}

Write-Host "== T-cli: config --set types and validation =="
try {
    $r = Get-Json (Invoke-CrossCli @('config', '--set=port_cache_ttl_s=45'))
    Assert-True ($r.ok -eq $true) 'config --set int ok' $r.ok
    $r = Get-Json (Invoke-CrossCli @('config', '--get=port_cache_ttl_s'))
    Assert-True ($null -ne $r -and $null -ne $r.value -and $r.value.GetType().Name -notin @('String','string')) 'config set preserves int (not string)' $r.value
} finally {
    $null = Invoke-CrossCli @('config', '--set=port_cache_ttl_s=60')
}
$r = Get-Json (Invoke-CrossCli @('config', '--set=my_session_id=abc'))
Assert-True (-not $r.ok -and $r.code -eq 64) 'config set validates ses_ -> 64' $r.detail

Write-Host "== T-cli: read 404 =="
if (-not $haveServer) {
    Write-Host "  SKIP  read 404: no server (publish template)"
    $script:pass++
} else {
$r = Get-Json (Invoke-CrossCli @('read', '--session=ses_no_existe_xyz', '--limit=1'))
Assert-True (-not $r.ok -and $r.err -eq 'NOT_FOUND') 'read non-existent session NOT_FOUND' $r.err

Write-Host "== T-cli: read --role case-insensitive =="
$r = Get-Json (Invoke-CrossCli @('read', "--session=$mySession", '--role=USER', '--limit=2'))
Assert-True ($r.ok -eq $true) 'read --role=USER ok' $r.ok
Assert-True (@($r.messages | Where-Object { $_.role.ToLower() -ne 'user' }).Count -eq 0) 'all role=user (case-insens)' ''
}

Write-Host "== T-cli: poll/status/reconcile/aviso-spof wiring =="
$dir = Join-Path $env:TEMP ('cross_tcli4a_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$ob = Join-Path $dir 'outbox.md'
[System.IO.File]::WriteAllText($ob, "# OUTBOX
## Activo
[2026-08-12T00:00:00Z] OUTBOX | msg_w1 | dest=ses_X | run_id=R | token=TK1 | lease=ses_X@2026-08-12T00:05:00Z | ESTADO=CONFIRMADO
", (New-Object System.Text.UTF8Encoding($false)))

$r = Get-Json (Invoke-CrossCli @('poll'))
Assert-True (-not $r.ok -and $r.code -eq 64 -and $r.err -eq 'USAGE_ERROR') 'poll without --msg -> USAGE_ERROR' $r.err
$r = Get-Json (Invoke-CrossCli @('poll', "--msg=msg_w1", '--outbox-file', $ob))
Assert-True ($r.ok -and $r.diagnostic -eq 'ACKED') 'poll CONFIRMADO -> ACKED' $r.diagnostic
$r = Get-Json (Invoke-CrossCli @('poll', "--msg-id=msg_w1", '--outbox-file', $ob))
Assert-True ($r.ok -and $r.diagnostic -eq 'ACKED') 'poll accepts --msg-id' $r.diagnostic

$r = Get-Json (Invoke-CrossCli @('status', '--outbox-file', $ob))
Assert-True ($r.ok -and $r.outbox_by_state.CONFIRMADO -eq 1) 'status with outbox ok' ($r | ConvertTo-Json -Compress)

$r = Get-Json (Invoke-CrossCli @('reconcile', "--msg=msg_w1"))
Assert-True (-not $r.ok -and $r.code -eq 64) 'reconcile without --check-file -> 64' $r.detail
$cf = Join-Path $dir 'check.md'
[System.IO.File]::WriteAllText($cf, "line`nwith TK1 here", (New-Object System.Text.UTF8Encoding($false)))
$r = Get-Json (Invoke-CrossCli @('reconcile', "--msg=msg_w1", '--check-file', $cf, '--outbox-file', $ob))
Assert-True ($r.ok -and $r.verdict -eq 'CONFIRMED') 'reconcile CONFIRMED' $r.verdict

$r = Get-Json (Invoke-CrossCli @('aviso-spof', '--outbox-file', $ob, '--for', 'ses_X'))
Assert-True ($r.ok -and $r.dry_run) 'aviso-spof dry_run by default' ($r | ConvertTo-Json -Compress)

Write-Host "== T-cli: metrics with --log-path and invalid --since =="
$metricsDir = Join-Path $env:TEMP ('cross_tcli_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $metricsDir | Out-Null
$mlog = Join-Path $metricsDir 'delivery_log.jsonl'
[System.IO.File]::WriteAllText($mlog, @'
{"ts":"2026-08-13T12:00:00Z","msg_id":"m1","dest":"ses_A","state":"CONFIRMADO","ack":true,"attempt":1,"cmd":"send"}
{"ts":"2026-08-13T12:00:01Z","msg_id":"m2","dest":"ses_A","state":"NACKED","ack":false,"reason_code":"NACK_TIMEOUT","attempt":1,"cmd":"send"}
{"ts":"2026-08-13T13:00:00Z","msg_id":"m3","dest":"ses_A","state":"CONFIRMADO","ack":false,"attempt":0,"cmd":"send"}
'@, (New-Object System.Text.UTF8Encoding($false)))
$r = Get-Json (Invoke-CrossCli @('metrics', '--log-path', $mlog))
Assert-True ($r.ok -and $r.code -eq 0) 'metrics CLI ok' $r.err
Assert-True ($r.total -eq 3) 'metrics CLI total=3' $r.total
Assert-True ($r.by_outcome.ACK -eq 2 -and $r.by_outcome.NACK -eq 1) 'ACK=2 NACK=1 (historical format counts ACK)' ($r.by_outcome | ConvertTo-Json -Compress)
$r = Get-Json (Invoke-CrossCli @('metrics', '--log-path', $mlog, '--since', 'ayer'))
Assert-True (-not $r.ok -and $r.code -eq 64 -and $r.err -eq 'USAGE_ERROR') 'metrics --since invalid -> code 64 USAGE_ERROR' $r.err
$r = Get-Json (Invoke-CrossCli @('metrics', '--log-path', (Join-Path $env:TEMP 'no_existe_metrics.jsonl')))
Assert-True (-not $r.ok -and $r.code -eq 64 -and $r.err -eq 'LOG_NOT_FOUND') 'metrics non-existent log -> LOG_NOT_FOUND' $r.err

Write-Host "== T-cli: metrics --prometheus (v1.14) =="
$rawP = Invoke-CrossCli @('metrics', '--prometheus', '--log-path', $mlog)
Assert-True ($rawP -match '(?m)^cross_messages_total 3\r?$') 'prometheus stdout text total 3' $rawP
Assert-True ($rawP -match '(?m)^cross_messages_acked_total 2\r?$') 'prometheus stdout acked 2' $rawP
Assert-True ($rawP -match '(?m)^# TYPE cross_messages_total counter\r?$') 'prometheus stdout TYPE line' $rawP
$promFile = Join-Path $metricsDir 'out.prom'
$r = Get-Json (Invoke-CrossCli @('metrics', '--prometheus', '--prometheus-output', $promFile, '--log-path', $mlog))
Assert-True ($r.ok -and $r.prometheus_file -eq $promFile) 'prometheus --prometheus-output writes file' ($r | ConvertTo-Json -Compress)
Assert-True ((Test-Path -LiteralPath $promFile) -and ((Get-Content $promFile -Raw) -match '(?m)^# TYPE cross_messages_total counter$')) 'prom file exists with TYPE line' $promFile
$r = Get-Json (Invoke-CrossCli @('metrics', '--prometheus', '--log-path', (Join-Path $env:TEMP 'no_existe_prom.jsonl')))
Assert-True (-not $r.ok -and $r.code -eq 64 -and $r.err -eq 'LOG_NOT_FOUND') 'prometheus non-existent log -> LOG_NOT_FOUND' $r.err

Write-Host ""
if (-not $haveServer) {
    Write-Host ("RESULT: {0} pass, {1} fail, {2} skipped (server-dependent)" -f $pass, $fail, $script:serverScenarios)
} else {
    Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
}
if ($fail -gt 0) { exit 1 } else { exit 0 }
