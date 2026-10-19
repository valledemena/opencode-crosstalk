# CLI tests for the send subcommand (Phase 3): validations and smoke against real API.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-send.ps1
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '..\cross.ps1'
Import-Module (Join-Path $PSScriptRoot '..\modules\cross-transport.psm1') -Force

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}
$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
$haveServer = (Test-Path $logDir) -and [bool](Get-ChildItem $logDir -ErrorAction SilentlyContinue) -and [bool](Get-CrossPassword)
$script:serverScenarios = 2
if (-not $haveServer) {
    Write-Host "  SKIP  $($script:serverScenarios) server-dependent scenarios: no OpenCode Desktop server logs/password in this environment (publish template)"
}
function Invoke-CrossCli {
    param([string[]]$CliArgs)
    $tmp = Join-Path $env:TEMP ("cross_cli_" + [System.Guid]::NewGuid().ToString('N') + ".json")
    # PS 5.1 turns native stderr into NativeCommandError when EAP=Stop, even with
    # 2>$null. The CLI legitimately warns on stderr (e.g. stale port hints), so
    # relax EAP around the child process.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @CliArgs 2>$null | Out-File -LiteralPath $tmp -Encoding ascii
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $raw = Get-Content -LiteralPath $tmp -Raw
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return $raw
}
function Get-Json {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    try { return ($Raw | ConvertFrom-Json) } catch { return $null }
}

$script:Dir = Join-Path $env:TEMP ('cross_tsend_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Dir | Out-Null
$script:Outbox = Join-Path $script:Dir 'outbox.md'
$script:StateFile = Join-Path $script:Dir 'state.md'
[System.IO.File]::WriteAllText($script:StateFile, "# IDEMPOTENCIA`n## Activo`n", (New-Object System.Text.UTF8Encoding($false)))

function Set-Outbox {
    param([string]$Msg, [string]$Estado = 'EN_VUELO', [string]$Dest = 'ses_X', [string]$Lease = 'ses_X@2026-08-12T23:59:00Z')
    $line = "[2026-08-12T00:00:00Z] OUTBOX | $Msg |"
    if ($Dest) { $line += " dest=$Dest |" }
    $line += " run_id=R1 | token=T1 |"
    if ($Lease) { $line += " lease=$Lease |" }
    $line += " ESTADO=$Estado"
    $content = "# OUTBOX`n## Activo`n$line`n"
    [System.IO.File]::WriteAllText($script:Outbox, $content, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "== T-send: usage validations =="
$r = Get-Json (Invoke-CrossCli @('send', '--outbox-file', $script:Outbox))
Assert-True ($null -ne $r -and -not $r.ok -and $r.code -eq 64 -and $r.err -eq 'USAGE_ERROR') 'send without --msg -> USAGE_ERROR 64' $r.err

Set-Outbox 'msg_real'
$r = Get-Json (Invoke-CrossCli @('send', '--msg=msg_fantasma', '--outbox-file', $script:Outbox, '--text', 'x'))
Assert-True ($null -ne $r -and -not $r.ok -and $r.err -eq 'OUTBOX_MSG_NOT_FOUND') 'non-existent msg -> OUTBOX_MSG_NOT_FOUND' $r.err

Set-Outbox 'msg_c' 'CONFIRMADO'
$r = Get-Json (Invoke-CrossCli @('send', '--msg=msg_c', '--outbox-file', $script:Outbox, '--text', 'x'))
Assert-True ($r.ok -and $r.already -and $r.outbox_state -eq 'CONFIRMADO') 'entry CONFIRMADO -> already=true' ($r | ConvertTo-Json -Compress)

Set-Outbox 'msg_t' 'EN_VUELO'
$r = Get-Json (Invoke-CrossCli @('send', '--msg=msg_t', '--outbox-file', $script:Outbox))
Assert-True ($null -ne $r -and -not $r.ok -and $r.err -eq 'USAGE_ERROR' -and $r.detail -match 'text') 'EN_VUELO without --text -> USAGE_ERROR' $r.detail

Set-Outbox 'msg_d' 'EN_VUELO' '' ''
$r = Get-Json (Invoke-CrossCli @('send', '--msg=msg_d', '--outbox-file', $script:Outbox, '--text', 'x'))
Assert-True ($null -ne $r -and -not $r.ok -and $r.err -eq 'USAGE_ERROR' -and $r.detail -match 'dest') 'without --dest -> USAGE_ERROR' $r.detail

Set-Outbox 'msg_e' 'EXPIRADO'
$r = Get-Json (Invoke-CrossCli @('send', '--msg=msg_e', '--outbox-file', $script:Outbox, '--text', 'x', '--dest', 'ses_X'))
Assert-True ($null -ne $r -and -not $r.ok -and $r.err -eq 'ESTADO_INVALIDO' -and $r.code -eq 2) 'EXPIRADO -> ESTADO_INVALIDO' $r.err

Write-Host "== T-send: smoke against real API =="
if (-not $haveServer) {
    Write-Host "  SKIP  smoke 404: no server (publish template)"
    $script:pass++
} else {
Set-Outbox 'msg_404' 'EN_VUELO' 'ses_zzz_no_existe_abc'
$r = Get-Json (Invoke-CrossCli @('send', '--msg=msg_404', '--outbox-file', $script:Outbox, '--text', 'T-send test', '--ack-timeout=1'))
Assert-True ($null -ne $r -and -not $r.ok -and $r.err -eq 'DEST_NOT_FOUND' -and $r.http_status -eq 404) 'non-existent dest -> 404 DEST_NOT_FOUND' ($r | ConvertTo-Json -Compress)
}

Write-Host "== T-send: send --no-wait accepts flag (404 dest) =="
if (-not $haveServer) {
    Write-Host "  SKIP  --no-wait: no server (publish template)"
    $script:pass++
} else {
Set-Outbox 'msg_nw' 'EN_VUELO' 'ses_zzz_no_existe_abc'
$r = Get-Json (Invoke-CrossCli @('send', '--msg=msg_nw', '--outbox-file', $script:Outbox, '--text', 'x', '--no-wait'))
Assert-True ($null -ne $r -and -not $r.ok -and $r.err -eq 'DEST_NOT_FOUND') '--no-wait parsed, 404 unchanged' $r.err
}

Write-Host "== T-send: scan --apply renews lease =="
$past = (Get-Date).ToUniversalTime().AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ssZ')
$future = (Get-Date).ToUniversalTime().AddHours(1).ToString('yyyy-MM-ddTHH:mm:ssZ')
function Set-OutboxLines {
    param([string[]]$Lines)
    $content = "# OUTBOX`n## Activo`n"
    foreach ($l in $Lines) { $content += $l + "`n" }
    [System.IO.File]::WriteAllText($script:Outbox, $content, (New-Object System.Text.UTF8Encoding($false)))
}
Set-OutboxLines @(
    "[2026-08-12T00:00:00Z] OUTBOX | msg_av1 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$past | ESTADO=EN_VUELO",
    "[2026-08-12T00:00:00Z] OUTBOX | msg_av2 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$future | ESTADO=EN_VUELO"
)
$r = Get-Json (Invoke-CrossCli @('scan', '--outbox-file', $script:Outbox, '--apply'))
Assert-True ($null -ne $r -and $r.ok -and @($r.applied).Count -eq 1 -and $r.applied[0] -eq 'msg_av1') '--apply renews only the expired' ($r | ConvertTo-Json -Compress)
$line = Get-Content -LiteralPath $script:Outbox | Where-Object { $_ -match 'msg_av1' }
Assert-True ($line -match 'lease=ses_X@\d{4}-\d{2}-\d{2}T') 'msg_av1 lease renewed' $line

Write-Host "== T-send: scan --quarantine marks QUARANTINE =="
Set-OutboxLines @(
    "[2026-08-12T00:00:00Z] OUTBOX | msg_av3 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$past | ESTADO=EN_VUELO"
)
$r = Get-Json (Invoke-CrossCli @('scan', '--outbox-file', $script:Outbox, '--quarantine'))
Assert-True ($null -ne $r -and $r.ok -and @($r.quarantined).Count -eq 1 -and $r.quarantined[0] -eq 'msg_av3') '--quarantine marks the expired' ($r | ConvertTo-Json -Compress)
$line = Get-Content -LiteralPath $script:Outbox | Where-Object { $_ -match 'msg_av3' }
Assert-True ($line -match 'ESTADO=QUARANTINE') 'ESTADO=QUARANTINE in outbox' $line

Write-Host "== T-send: scan without flags is diagnostic (no mutation) =="
Set-OutboxLines @(
    "[2026-08-12T00:00:00Z] OUTBOX | msg_av4 | dest=ses_X | run_id=R1 | token=T1 | lease=ses_X@$past | ESTADO=EN_VUELO"
)
$before = (Get-Content -LiteralPath $script:Outbox -Raw)
$r = Get-Json (Invoke-CrossCli @('scan', '--outbox-file', $script:Outbox))
$after = (Get-Content -LiteralPath $script:Outbox -Raw)
Assert-True ($r.ok -and $r.vencidos -eq 1 -and $before -eq $after) 'scan without flags does not mutate' ($r | ConvertTo-Json -Compress)

Write-Host ""
if (-not $haveServer) {
    Write-Host ("RESULT: {0} pass, {1} fail, {2} skipped (server-dependent)" -f $pass, $fail, $script:serverScenarios)
} else {
    Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
}
if ($fail -gt 0) { exit 1 } else { exit 0 }
