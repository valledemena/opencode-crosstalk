# CROSS-TALK setup helper (v2.1.1)
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-SessionId ses_X] [-Model name] [-Role leader] [-NonInteractive]
#
# Detects the OpenCode Desktop server, validates the identity, reads the model
# FROM THE API (never from guesses), writes cross/cross.config.local.json
# (git-ignored) and verifies connectivity.
#
# Identity policy: this script NEVER silently picks a session. If the session
# cannot be determined unambiguously it prints the candidates and exits with
# code 2 so the caller (human or LLM) can choose explicitly.
param(
    [string]$SessionId = '',
    [string]$Model = '',
    [string]$Role = 'leader',
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'

$root = Split-Path $MyInvocation.MyCommand.Path -Parent
$cli = Join-Path $root 'cross\cross.ps1'
$localPath = Join-Path $root 'cross\cross.config.local.json'

Write-Host "== CROSS-TALK setup =="

if (-not (Test-Path -LiteralPath $cli)) {
    Write-Host "ERROR: cross\cross.ps1 not found. Run this script from the repository root."
    exit 1
}

# --- server detection -------------------------------------------------------
$logDir = Join-Path $env:APPDATA 'ai.opencode.desktop\logs'
if (-not (Test-Path $logDir) -or -not (Get-ChildItem $logDir -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: no OpenCode Desktop logs found at $logDir."
    Write-Host "Start OpenCode Desktop with at least 2 sessions open, then re-run."
    exit 1
}

$password = $env:OPENCODE_SERVER_PASSWORD
if (-not $password) {
    $envCandidates = @(
        (Join-Path $root '.env'),
        (Join-Path $env:USERPROFILE '.config\opencode\.env')
    )
    foreach ($envFile in $envCandidates) {
        if ($password) { break }
        if (Test-Path -LiteralPath $envFile) {
            $m = [regex]::Match((Get-Content $envFile -Raw), '(?m)^\s*OPENCODE_SERVER_PASSWORD\s*=\s*(.+?)\s*$')
            if ($m.Success) { $password = $m.Groups[1].Value.Trim() }
        }
    }
}
if (-not $password) {
    Write-Host "ERROR: OPENCODE_SERVER_PASSWORD not found (env var or .env)."
    Write-Host "Set it and re-run, or add it to a .env file in the repo root."
    exit 1
}

$latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$mainLog = Join-Path $latestLog.FullName 'main.log'
$content = Get-Content $mainLog -Raw
$port = ([regex]::Match($content, "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
if (-not $port) {
    Write-Host "ERROR: could not detect the server port from the logs."
    exit 1
}
$baseUrl = "http://127.0.0.1:$port"
Write-Host "Server detected: $baseUrl"

function Invoke-CrossApiGet([string]$Path) {
    $raw = & curl.exe -s -u "opencode:$password" "$baseUrl$Path"
    if (-not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

# --- identity ---------------------------------------------------------------
$chosen = $null
if ($SessionId) {
    $chosen = Invoke-CrossApiGet "/session/$SessionId"
    if (-not $chosen -or -not $chosen.id) {
        Write-Host "ERROR: session '$SessionId' not found on $baseUrl."
        Write-Host "Run '.\cross.ps1 sessions' or open the session in the Desktop and copy its id."
        exit 2
    }
} else {
    $sessions = Invoke-CrossApiGet '/session'
    if (-not $sessions -or @($sessions).Count -eq 0) {
        Write-Host "ERROR: no sessions found. Open at least 2 sessions in the same project."
        exit 2
    }
    $candidates = @(@($sessions) | Where-Object { $_.title -match '(?i)leader|lider|muse' })
    if ($candidates.Count -eq 1) {
        $chosen = $candidates[0]
        Write-Host ""
        Write-Host "Candidate session:"
        Write-Host ("  id      : {0}" -f $chosen.id)
        Write-Host ("  title   : {0}" -f $chosen.title)
        Write-Host ("  dir     : {0}" -f $chosen.directory)
        if (-not $NonInteractive) {
            $answer = Read-Host "Use this session as YOUR identity? [Y/n]"
            if ($answer -and $answer -notmatch '^(?i)y') {
                $chosen = $null
            }
        }
    }
    if (-not $chosen) {
        Write-Host ""
        Write-Host "Could not determine YOUR session automatically (none or several candidates)."
        Write-Host "Sessions available (pass the right one with -SessionId ses_...):"
        Write-Host ""
        Write-Host ("  {0,-40} {1,-28} {2}" -f 'ID', 'TITLE', 'DIRECTORY')
        foreach ($s in @($sessions)) {
            Write-Host ("  {0,-40} {1,-28} {2}" -f $s.id, ([string]$s.title), ([string]$s.directory))
        }
        Write-Host ""
        Write-Host "Example: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -SessionId ses_xxx"
        exit 2
    }
}

# --- model (API-first) ------------------------------------------------------
if (-not $Model -and $chosen.model) {
    if ($chosen.model.id) { $Model = [string]$chosen.model.id }
    elseif ($chosen.model -is [string]) { $Model = [string]$chosen.model }
}

$existingRole = ''
if (Test-Path -LiteralPath $localPath) {
    try { $existingRole = [string]((Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json).my_role) } catch { }
}
$roleValue = if ($Role) { $Role } elseif ($existingRole) { $existingRole } else { 'leader' }
$local = [ordered]@{
    my_session_id     = [string]$chosen.id
    leader_session_id = [string]$chosen.id
    my_role           = $roleValue
    my_model          = $Model
}
$json = ($local | ConvertTo-Json)
[System.IO.File]::WriteAllText($localPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "Local config written: cross\cross.config.local.json (git-ignored)"
Write-Host ("  my_session_id = {0}" -f $local.my_session_id)
Write-Host ("  my_model      = {0}  (from API)" -f $local.my_model)

# --- verification -----------------------------------------------------------
Write-Host ""
Write-Host "== Verifying connectivity =="
$healthRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli health 2>&1 | Out-String
Write-Host $healthRaw.Trim()
$whoamiRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli whoami 2>&1 | Out-String
Write-Host $whoamiRaw.Trim()

if ($healthRaw -match '"ok":\s*true') {
    Write-Host ""
    Write-Host "Setup complete. Next steps:"
    Write-Host "  cd cross"
    Write-Host "  .\cross.ps1 sessions"
    Write-Host "  .\cross.ps1 send --msg t1 --dest ses_PEER --token T1 --text `"Hello`""
    Write-Host ""
    Write-Host "Receiving a task? ACK FIRST (v2 JSON), then do the work:"
    Write-Host "  .\cross.ps1 ack --token <token> --for-msg-id <msg_id> --to <sender_session>"
    Write-Host ""
    Write-Host "Shared clone with several agents? Give each one its own identity WITHOUT"
    Write-Host "touching the local config:"
    Write-Host "  `$env:CROSS_MY_MY_SESSION_ID='ses_YOURS'; `$env:CROSS_MY_MY_MODEL='your-model'"
    Write-Host ""
    Write-Host "NOTE: cross.config.local.json is git-ignored. Your identity stays local."
} else {
    Write-Host ""
    Write-Host "Setup finished but health check did not confirm. Check the output above."
    exit 3
}
