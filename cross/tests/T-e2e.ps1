# Real E2E tests (Phase 3/D4): real transport against the OpenCode Desktop server.
# Delivery goes to the leader's session (my_session_id) as destination; the ACK/NACK is
# injected into the leader's session as a real receiver would do (7.1/7.5).
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\T-e2e.ps1
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '..\cross.ps1'

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

$config = Get-Content (Join-Path $PSScriptRoot '..\cross.config.json') -Raw | ConvertFrom-Json
$mySession = [string]$config.my_session_id
$myModel = [string]$config.my_model

if (-not $mySession) {
    Write-Host "  SKIP  T-e2e: config template has empty my_session_id (publish template); real transport needs a real session"
    Write-Host ""
    Write-Host ("RESULT: {0} pass, {1} fail" -f 0, 0)
    exit 0
}

$logDir = "$env:APPDATA\ai.opencode.desktop\logs"
if (-not (Test-Path $logDir) -or -not (Get-ChildItem $logDir -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP  T-e2e: no OpenCode Desktop server logs in this environment (publish template)"
    Write-Host ""
    Write-Host ("RESULT: {0} pass, {1} fail" -f 0, 0)
    exit 0
}
$latestLog = Get-ChildItem $logDir | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$port = ([regex]::Match((Get-Content "$($latestLog.FullName)\main.log" -Raw), "server ready.*url: 'http://127\.0\.0\.1:(\d+)'")).Groups[1].Value
$password = $env:OPENCODE_SERVER_PASSWORD
if (-not $port -or -not $password) {
    Write-Host "  SKIP  T-e2e: server credentials not detectable in this environment (publish template)"
    Write-Host ""
    Write-Host ("RESULT: {0} pass, {1} fail" -f 0, 0)
    exit 0
}

function Invoke-CrossPost {
    param([string]$Dest, [string]$Text)
    $payload = @{ parts = @(@{ type = 'text'; text = $Text }); noReply = $true } | ConvertTo-Json -Depth 3 -Compress
    $file = Join-Path $env:TEMP ("cross_e2e_body_" + [System.Guid]::NewGuid().ToString('N') + ".json")
    [System.IO.File]::WriteAllText($file, $payload, [System.Text.Encoding]::ASCII)
    $code = & curl.exe -s -o NUL -w '%{http_code}' --max-time 15 -X POST -u "opencode:$password" -H 'Content-Type: application/json' --data-binary "@$file" "http://127.0.0.1:$port/session/$Dest/prompt" 2>$null
    Remove-Item $file -ErrorAction SilentlyContinue
    return $code
}

function Invoke-SendCli {
    param([string]$MsgId, [string]$Dest, [string]$Token, [string]$Outbox, [string]$Text, [int]$TimeoutSec)
    $job = Start-Job -ArgumentList $cli, $MsgId, $Dest, $Token, $Outbox, $Text, $TimeoutSec -ScriptBlock {
        param($c, $m, $d, $t, $o, $x, $to)
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $c 'send' "--msg=$m" "--dest=$d" "--token=$t" "--outbox-file=$o" "--text=$x" "--ack-timeout=$to" 2>$null | Out-String
    }
    Start-Sleep -Seconds 6
    return $job
}

function Write-OutboxEntry {
    param([string]$MsgId, [string]$Dest, [string]$Token)
    $lease = "$Dest@" + (Get-Date).ToUniversalTime().AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $content = "# OUTBOX`n## Activo`n[2026-08-12T00:00:00Z] OUTBOX | $MsgId | dest=$Dest | run_id=E2E | token=$Token | lease=$lease | ESTADO=EN_VUELO`n"
    [System.IO.File]::WriteAllText($script:Outbox, $content, (New-Object System.Text.UTF8Encoding($false)))
}

$dir = Join-Path $env:TEMP ('cross_te2e_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$script:Outbox = Join-Path $dir 'outbox.md'
$whiteboard = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\whiteboard'))
$deliveryLog = Join-Path $whiteboard 'delivery_log.jsonl'

Write-Host "== T-e2e: happy ACK (real transport) =="
$tokH = 'E2E-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
Write-OutboxEntry 'e2e_happy' $mySession $tokH
$job = Invoke-SendCli 'e2e_happy' $mySession $tokH $script:Outbox 'TEST E2E CROSS - no response required' 45
$codeAck = Invoke-CrossPost $mySession "ACK:${tokH}:${mySession}:${myModel}"
Start-Sleep -Seconds 1
$null = Wait-Job $job -Timeout 70 -ErrorAction SilentlyContinue
$raw = Receive-Job $job
Remove-Job $job -Force
Assert-True ($codeAck -eq '204') 'ACK injected -> HTTP 204' $codeAck
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok -and $j.outbox_state -eq 'CONFIRMADO' -and $j.ack) 'E2E happy -> CONFIRMADO via real transport' $raw
Assert-True ($null -ne $j -and $j.ack_id -eq $mySession -and $j.ack_model -eq $myModel) 'E2E ack_id/ack_model correct' "$($j.ack_id)|$($j.ack_model)"

Write-Host "== T-e2e: NACK (real transport) =="
$tokN = 'E2E-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
Write-OutboxEntry 'e2e_nack' $mySession $tokN
$job = Invoke-SendCli 'e2e_nack' $mySession $tokN $script:Outbox 'TEST E2E CROSS NACK - no response required' 45
$codeNack = Invoke-CrossPost $mySession "NACK:${tokN}:${mySession}:${myModel}:CAPACITY"
Start-Sleep -Seconds 1
$null = Wait-Job $job -Timeout 70 -ErrorAction SilentlyContinue
$raw = Receive-Job $job
Remove-Job $job -Force
Assert-True ($codeNack -eq '204') 'NACK injected -> HTTP 204' $codeNack
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and -not $j.ok -and $j.outbox_state -eq 'NACKED' -and $j.reason -eq 'CAPACITY') 'E2E NACK -> NACKED with reason' $raw

Write-Host "== T-e2e: 404 non-existent destination =="
$tok4 = 'E2E-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
Write-OutboxEntry 'e2e_404' 'ses_zzz_no_existe_xyz' $tok4
$raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli 'send' "--msg=e2e_404" "--dest=ses_zzz_no_existe_xyz" "--outbox-file=$script:Outbox" '--text=x' "--ack-timeout=1" 2>$null | Out-String
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and -not $j.ok -and $j.err -eq 'DEST_NOT_FOUND' -and $j.http_status -eq 404) 'E2E 404 -> DEST_NOT_FOUND' $raw

Write-Host "== T-e2e: observability (delivery_log + audit_log) =="
$hasLog = $false
if (Test-Path -LiteralPath $deliveryLog) {
    $hasLog = @(Get-Content -LiteralPath $deliveryLog | Where-Object { $_ -match 'e2e_happy' -and $_ -match 'CONFIRMADO' }).Count -ge 1
}
Assert-True $hasLog 'delivery_log.jsonl contains e2e_happy CONFIRMADO' $deliveryLog
$audit = Join-Path $whiteboard 'audit_log.md'
$hasAudit = @(Get-Content -LiteralPath $audit | Where-Object { $_ -match 'e2e_happy' }).Count -ge 1
Assert-True $hasAudit 'audit_log.md records e2e_happy' ''

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
