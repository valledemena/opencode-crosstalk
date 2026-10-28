# send_message.ps1 - Message-sending wrapper (Phase 5).
# Replaces whiteboard\send_message.ps1 (direct HTTP) by delegating to the
# `cross send` CLI, which manages outbox.md, audit_log.md, delivery_log.jsonl
# and retries.
# Legacy signature preserved: -Destino -Texto [-NoReply]. With -LegacyMode the
# old direct HTTP path is used (no outbox/audit/retries).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File send_message.ps1 -Destino ses_X -Texto "..." [-NoReply] [-LegacyMode]

param(
  [Parameter(Mandatory=$true)][string]$Destino,
  [Parameter(Mandatory=$true)][string]$Texto,
  [string]$Puerto,
  [string]$Password,
  [switch]$NoReply,
  [switch]$LegacyMode
)

$ErrorActionPreference = 'Stop'
$MyRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cli = Join-Path $MyRoot 'cross.ps1'

if ($LegacyMode) {
    $logDir = "$env:APPDATA\ai.opencode.desktop\logs"
    $latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $Puerto = ([regex]::Match((Get-Content "$($latestLog.FullName)\main.log" -Raw), "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
    if (-not $Puerto) { throw 'Could not auto-detect server port' }
    $Password = $env:OPENCODE_SERVER_PASSWORD
    if (-not $Password) { throw 'OPENCODE_SERVER_PASSWORD is not defined in the environment' }
    # V2 contract: prompt = {"text": ...} (wakes the agent); -NoReply uses the
    # synthetic endpoint (notice without wake-up). V1 'message'+noReply is gone.
    $payload = @{ text = $Texto }
    $json = $payload | ConvertTo-Json -Depth 4
    $file = Join-Path $env:TEMP "send_$(Get-Random).json"
    [System.IO.File]::WriteAllText($file, $json, [System.Text.Encoding]::ASCII)
    $endpoint = if ($NoReply) { 'synthetic' } else { 'prompt' }
    curl.exe -s -X POST -u "opencode:$Password" -H 'Content-Type: application/json' --data-binary "@$file" "http://127.0.0.1:$Puerto/api/session/$Destino/$endpoint"
    Remove-Item $file -ErrorAction SilentlyContinue
    exit 0
}

if (-not (Test-Path -LiteralPath $Cli)) { throw "cross.ps1 not found: $Cli" }
Import-Module (Join-Path $MyRoot 'modules\cross-transport.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $MyRoot 'modules\cross-state.psm1') -Force -DisableNameChecking
$config = Get-CrossConfig

$emisor = [string]$config.my_session_id
if (-not $emisor) { $emisor = 'leader' }
$msgId = "msg_${emisor}_$(Get-Date -Format 'yyyyMMdd-HHmmss')-" + (Get-Random -Maximum 16777215).ToString('X6')
$token = 'MSG-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12)
$runId = 'RUN-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$leaseMin = if ($config.default_lease_minutes) { [int]$config.default_lease_minutes } else { 3 }
$lease = "$Destino@" + (Get-Date).ToUniversalTime().AddMinutes($leaseMin).ToString('yyyy-MM-ddTHH:mm:ssZ')
$whiteboard = [Environment]::ExpandEnvironmentVariables([string]$config.whiteboard_dir)
$outbox = Join-Path $whiteboard 'outbox.md'
$ar = Add-OutboxEntry -MsgId $msgId -Dest $Destino -RunId $runId -Token $token -Lease $lease -Path $outbox
if (-not $ar.ok) { throw "$($ar.err): $($ar.detail)" }

$cliArgs = @('send', "--msg=$msgId", "--dest=$Destino", "--text=$Texto")
if ($NoReply) { $cliArgs += '--no-wait' }
if ($Puerto) { $cliArgs += "--port=$Puerto" }
if ($Password) { $cliArgs += "--password=$Password" }
[Console]::Error.WriteLine("NOTE: send_message.ps1 delegated to cross send (msg_id=$msgId). Outbox/audit/retries active.")
# v1.17: PS5.1 quirk - native stderr under EAP=Stop throws even when redirected.
# Diag warnings (deprecation) must not abort the send; restore EAP afterwards.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Cli @cliArgs 2>$null | Out-String
$ErrorActionPreference = $prevEap
[Console]::WriteLine($raw.Trim())
exit $LASTEXITCODE
