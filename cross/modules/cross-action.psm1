# cross-action.psm1 - Phase 4b (estados terminales/reactivacion): ack, nack, resume,
# restart-task, nudge, escalate, dlq, quarantine, diagnose.
# Explicit writes: outbox (STATUS/attempt), escalated.md, dlq-messages.md, audit_log.md.
# audit_log.md is multi-writer (sender + receiver + leader): use Write-AuditEntry (retry).
# Uso (via cross.ps1): cross ack|nack|resume|restart-task|nudge|escalate|dlq|quarantine|diagnose
Set-StrictMode -Version 2.0

if (-not (Get-Command ConvertTo-AsciiSafe -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\lib\cross-format.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command New-CrossAckJson -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-envelope.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Get-CrossConfig -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-transport.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Resolve-CrossEndpoint -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-transport.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Read-OutboxLog -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-state.psm1') -Force -DisableNameChecking
}

function Get-CrossActionPaths {
    $cfg = Get-CrossConfig
    $dir = if ($cfg.whiteboard_dir) { [Environment]::ExpandEnvironmentVariables([string]$cfg.whiteboard_dir) } else { Split-Path -Parent (Get-OutboxPath) }
    return @{
        outbox       = Join-Path $dir 'outbox.md'
        audit        = Join-Path $dir 'audit_log.md'
        escalated    = Join-Path $dir 'escalated.md'
        dlq          = Join-Path $dir 'dlq-messages.md'
        log          = if ($cfg.log_path) { [Environment]::ExpandEnvironmentVariables([string]$cfg.log_path) } else { '' }
    }
}

function Get-CrossMyId {
    $cfg = Get-CrossConfig
    return $(if ($cfg.my_session_id) { [string]$cfg.my_session_id } else { 'leader' })
}

function Get-CrossMyModel {
    $cfg = Get-CrossConfig
    return $(if ($cfg.my_model) { [string]$cfg.my_model } else { '' })
}

function Send-CrossAck {
    param(
        [AllowEmptyString()][string]$Token,
        [AllowEmptyString()][string]$ForMsgId,
        [string]$Dest = '',
        [string]$Model = '',
        [string]$AuditPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SendFn,
        [string]$Secret = ''
    )
    if (-not $Token) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --token' } }
    if (-not $ForMsgId) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --for-msg-id' } }
    $myId = Get-CrossMyId
    if (-not $Dest) { $Dest = $myId }
    if (-not $Model) { $Model = Get-CrossMyModel }
    # D1 (v1.17): ACK como envelope v2 JSON (el receptor lo parsea con Parse-CrossEnvelope)
    $ackText = New-CrossAckJson -Token $Token -MsgId $ForMsgId -Emitter $myId -Model $Model -Secret $Secret
    $sent = $false
    if ($SendFn) {
        [void](& $SendFn $Dest $ackText)
        $sent = $true
    } else {
        if (-not $Port) {
            $ep = Resolve-CrossEndpoint -Port $Port -Password $Password
            if ($ep.ok) {
                $Port = [int]$ep.port
                if (-not $Password) { $Password = [string]$ep.password }
            }
        }
        if (-not $Port) {
            return @{ ok = $false; err = 'SEND_FAILED'; detail = 'endpoint unresolved (no port)'; ack_text = $ackText }
        }
        # V2 body (steer: control message, must be seen even mid-turn)
        $payload = @{ text = $ackText; delivery = 'steer' } | ConvertTo-Json -Depth 4
        $api = Invoke-CrossApi -Method 'POST' -Path "/api/session/$Dest/prompt" -BodyJson $payload -Port $Port -Password $Password
        if ($api.status -lt 200 -or $api.status -ge 300) {
            return @{ ok = $false; err = 'SEND_FAILED'; detail = "prompt -> HTTP $($api.status)"; http_status = $api.status; ack_text = $ackText }
        }
        $sent = $true
    }
    $audit = Write-AuditEntry -MsgId $ForMsgId -Dest $Dest -Token $Token -Tipo 'ACK' -Estado 'ENVIADO' -Nota 'ack emitted by leader' -AuditPath $AuditPath
    return @{ ok = $true; ack_text = $ackText; to = $Dest; sent = $sent; audit_ok = $audit.ok }
}

function Send-CrossNack {
    param(
        [AllowEmptyString()][string]$Token,
        [AllowEmptyString()][string]$ForMsgId,
        [AllowEmptyString()][string]$Reason,
        [string]$Note = '',
        [string]$ForRunId = '',
        [string]$Dest = '',
        [string]$Model = '',
        [string]$AuditPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SendFn,
        [string]$Secret = ''
    )
    if (-not $Token) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --token' } }
    if (-not $ForMsgId) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --for-msg-id' } }
    $validReasons = @('CAPACITY', 'TOOL_MISSING', 'AMBIGUOUS_TASK', 'PROVIDER_DOWN', 'OTHER')
    if ($Reason -notin $validReasons) {
        return @{ ok = $false; err = 'NACK_REASON_INVALID'; detail = "reason not closed: $Reason (validas: $($validReasons -join ', '))" }
    }
    $myId = Get-CrossMyId
    if (-not $Dest) { $Dest = $myId }
    if (-not $Model) { $Model = Get-CrossMyModel }
    # D1 (v1.17): NACK como envelope v2 JSON (msg_id/run_id embebidos, sin limite de segmentos)
    $nackText = New-CrossNackJson -Token $Token -MsgId $ForMsgId -Emitter $myId -Model $Model -Reason $Reason -RunId $ForRunId -Secret $Secret
    $sent = $false
    if ($SendFn) {
        [void](& $SendFn $Dest $nackText)
        $sent = $true
    } else {
        if (-not $Port) {
            $ep = Resolve-CrossEndpoint -Port $Port -Password $Password
            if ($ep.ok) {
                $Port = [int]$ep.port
                if (-not $Password) { $Password = [string]$ep.password }
            }
        }
        if (-not $Port) {
            return @{ ok = $false; err = 'SEND_FAILED'; detail = 'endpoint unresolved (no port)'; nack_text = $nackText }
        }
        # V2 body (steer: control message, must be seen even mid-turn)
        $payload = @{ text = $nackText; delivery = 'steer' } | ConvertTo-Json -Depth 4
        $api = Invoke-CrossApi -Method 'POST' -Path "/api/session/$Dest/prompt" -BodyJson $payload -Port $Port -Password $Password
        if ($api.status -lt 200 -or $api.status -ge 300) {
            return @{ ok = $false; err = 'SEND_FAILED'; detail = "prompt -> HTTP $($api.status)"; http_status = $api.status; nack_text = $nackText }
        }
        $sent = $true
    }
    $nota = "nack reason=$Reason"
    if ($Note) { $nota += "; nota=$Note" }
    if ($ForRunId) { $nota += "; run=$ForRunId" }
    $audit = Write-AuditEntry -MsgId $ForMsgId -Dest $Dest -Token $Token -Tipo 'NACK' -Estado 'ENVIADO' -Nota $nota -AuditPath $AuditPath
    return @{ ok = $true; nack_text = $nackText; to = $Dest; reason = $Reason; sent = $sent; audit_ok = $audit.ok }
}

function Send-CrossResume {
    param(
        [AllowEmptyString()][string]$To,
        [AllowEmptyString()][string]$TaskId,
        [string]$From = '',
        [string]$Text = '',
        [string]$AuditPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SendFn
    )
    if (-not $To) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --to ses_X' } }
    if (-not $TaskId) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --task-id' } }
    if (-not $Text) {
        $base = if ($From) { "Continue from `"$From`"." } else { 'Continue your work.' }
        $Text = "$base Complete task $TaskId and deliver the final signed report."
    }
    $sent = $false
    if ($SendFn) {
        [void](& $SendFn $To $Text)
        $sent = $true
    } elseif ($Port) {
        $payload = @{ text = $Text; delivery = 'queue' } | ConvertTo-Json -Depth 4
        $api = Invoke-CrossApi -Method 'POST' -Path "/api/session/$To/prompt" -BodyJson $payload -Port $Port -Password $Password
        if ($api.status -lt 200 -or $api.status -ge 300) {
            return @{ ok = $false; err = 'SEND_FAILED'; detail = "prompt -> HTTP $($api.status)"; http_status = $api.status }
        }
        $sent = $true
    }
    $nota = 'resume (NO new msg_id, NO attempt increment)'
    if ($From) { $nota += "; from $From" }
    $audit = Write-AuditEntry -MsgId $TaskId -Dest $To -Tipo 'RESUME' -Estado 'ENVIADO' -Nota $nota -AuditPath $AuditPath
    return @{ ok = $true; to = $To; task_id = $TaskId; from = $From; prompt = $Text; new_msg_id = $false; sent = $sent; audit_ok = $audit.ok }
}

function Restart-CrossTask {
    param(
        [AllowEmptyString()][string]$MsgId,
        [string]$To = '',
        [string]$Text = '',
        [int]$MaxAttempts = 0,
        [string]$OutboxPath = '',
        [string]$AuditPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SendFn
    )
    if (-not $MsgId) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --msg-id' } }
    if (-not $OutboxPath) { $OutboxPath = (Get-CrossActionPaths).outbox }
    $entry = @(Read-OutboxLog -Path $OutboxPath | Where-Object { $_.msg_id -eq $MsgId }) | Select-Object -First 1
    if (-not $entry) { return @{ ok = $false; err = 'OUTBOX_MSG_NOT_FOUND'; detail = $MsgId } }
    $maxAttempts = $MaxAttempts
    if ($maxAttempts -le 0) {
        $cfg = Get-CrossConfig
        if ($cfg.max_retries) { $maxAttempts = [int]$cfg.max_retries }
    }
    if ($maxAttempts -le 0) { $maxAttempts = 2 }
    if ([int]$entry.attempt -ge $maxAttempts) {
        return @{ ok = $false; err = 'MAX_RETRIES_EXCEEDED'; detail = "attempt=$($entry.attempt) >= max=$maxAttempts"; msg_id = $MsgId; attempt = [int]$entry.attempt }
    }
    $newAttempt = [int]$entry.attempt + 1
    $dest = if ($To) { $To } else { [string]$entry.dest }
    if (-not $Text) { $Text = "Retry de la tarea (mismo msg_id $MsgId, intento $newAttempt). Completa y entrega el informe firmado." }
    $ar = Set-OutboxAttempt -MsgId $MsgId -Attempt $newAttempt -Path $OutboxPath
    if (-not $ar.ok) { return $ar }
    $er = Set-OutboxEstado -MsgId $MsgId -Estado 'EN_VUELO' -Path $OutboxPath
    if (-not $er.ok) { return $er }
    $sent = $false
    if ($SendFn) {
        [void](& $SendFn $dest $Text)
        $sent = $true
    } elseif ($Port) {
        $payload = @{ text = $Text; delivery = 'queue' } | ConvertTo-Json -Depth 4
        $api = Invoke-CrossApi -Method 'POST' -Path "/api/session/$dest/prompt" -BodyJson $payload -Port $Port -Password $Password
        if ($api.status -lt 200 -or $api.status -ge 300) {
            return @{ ok = $false; err = 'SEND_FAILED'; detail = "prompt -> HTTP $($api.status)"; http_status = $api.status }
        }
        $sent = $true
    }
    $audit = Write-AuditEntry -MsgId $MsgId -Dest $dest -Token ([string]$entry.token) -Tipo 'RESTART' -Estado 'EN_VUELO' -Nota "mismo msg_id, attempt=$newAttempt" -AuditPath $AuditPath
    return @{ ok = $true; msg_id = $MsgId; dest = $dest; attempt = $newAttempt; same_msg_id = $true; sent = $sent; audit_ok = $audit.ok }
}

function Send-CrossNudge {
    param(
        [AllowEmptyString()][string]$To,
        [AllowEmptyString()][string]$Task,
        [string]$Token = '',
        [string]$AuditPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SendFn
    )
    if (-not $To) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --to ses_X' } }
    if (-not $Task) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --task' } }
    $text = "NUDGE. Ignore previous 'Continue' messages or guidance. Complete the task NOW: $Task"
    if ($Token) { $text += " (token: $Token)" }
    $sent = $false
    if ($SendFn) {
        [void](& $SendFn $To $text)
        $sent = $true
    } elseif ($Port) {
        # V2 body (steer: control message, must be seen even mid-turn)
        $payload = @{ text = $text; delivery = 'steer' } | ConvertTo-Json -Depth 4
        $api = Invoke-CrossApi -Method 'POST' -Path "/api/session/$To/prompt" -BodyJson $payload -Port $Port -Password $Password
        if ($api.status -lt 200 -or $api.status -ge 300) {
            return @{ ok = $false; err = 'SEND_FAILED'; detail = "prompt -> HTTP $($api.status)"; http_status = $api.status }
        }
        $sent = $true
    }
    $audit = Write-AuditEntry -MsgId $Task -Dest $To -Token $Token -Tipo 'NUDGE' -Estado 'ENVIADO' -Nota 'nudge firme' -AuditPath $AuditPath
    return @{ ok = $true; to = $To; task = $Task; prompt = $text; sent = $sent; audit_ok = $audit.ok }
}

function Write-CrossEscalated {
    param(
        [AllowEmptyString()][string]$MsgId,
        [AllowEmptyString()][string]$To,
        [AllowEmptyString()][string]$Reason,
        [string]$RunId = '',
        [string]$Expira = '',
        [string]$EscalatedPath = '',
        [string]$AuditPath = '',
        [switch]$Apply,
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SendFn
    )
    if (-not $MsgId) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --msg-id' } }
    if (-not $To) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --to ses_Y' } }
    if (-not $Reason) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --reason' } }
    if (-not $EscalatedPath) { $EscalatedPath = (Get-CrossActionPaths).escalated }
    $myId = Get-CrossMyId
    $cfg = Get-CrossConfig
    $leaseMin = if ($cfg.default_lease_minutes) { [int]$cfg.default_lease_minutes } else { 3 }
    if (-not $Expira) { $Expira = (Get-Date).ToUniversalTime().AddMinutes($leaseMin).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $line = "URGENTE | para=$To | msg_id=$MsgId | run_id=$RunId | de=$myId | expira=$Expira | '$Reason'"
    $res = Add-CrossLogLine -Path $EscalatedPath -Line $line
    if (-not $res.ok) { return @{ ok = $false; err = $res.err; detail = $res.detail } }
    $notified = $false
    if ($Apply) {
        $wake = "URGENTE | para=$To | $MsgId | wake-on-write: revisa escalated.md | '$Reason'"
        if ($SendFn) {
            [void](& $SendFn $To $wake)
            $notified = $true
        } elseif ($Port) {
            # V2 body (steer: wake-up control message)
            $payload = @{ text = $wake; delivery = 'steer' } | ConvertTo-Json -Depth 4
            [void](Invoke-CrossApi -Method 'POST' -Path "/api/session/$To/prompt" -BodyJson $payload -Port $Port -Password $Password)
            $notified = $true
        }
    }
    $audit = Write-AuditEntry -MsgId $MsgId -Dest $To -Tipo 'ESCALADA' -Estado 'ESCRITO' -Nota "URGENTE en escalated.md; para=$To; aplicada=$Apply" -AuditPath $AuditPath
    return @{ ok = $true; msg_id = $MsgId; para = $To; line = $line; written = $res.ok; notified = $notified; audit_ok = $audit.ok }
}

function Write-CrossDlq {
    param(
        [AllowEmptyString()][string]$MsgId,
        [string]$To = '',
        [string]$Retries = '',
        [string]$Flag = '',
        [string]$Summary = '',
        [string]$OutboxPath = '',
        [string]$DlqPath = '',
        [string]$AuditPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SendFn
    )
    if (-not $MsgId) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --msg-id' } }
    $validFlags = @('HUMAN_REVIEW', 'NACK_ORIGINATED', 'QUARANTINE', 'PROVIDER_DOWN', 'TOTAL_TIMEOUT')
    if (-not $Flag) { $Flag = 'HUMAN_REVIEW' }
    if ($Flag -notin $validFlags) {
        return @{ ok = $false; err = 'DLQ_FLAG_INVALID'; detail = "flag not closed: $Flag (valid: $($validFlags -join ', '))" }
    }
    if (-not $OutboxPath) { $OutboxPath = (Get-CrossActionPaths).outbox }
    if (-not $DlqPath) { $DlqPath = (Get-CrossActionPaths).dlq }
    $myId = Get-CrossMyId
    $entry = @(Read-OutboxLog -Path $OutboxPath | Where-Object { $_.msg_id -eq $MsgId }) | Select-Object -First 1
    if (-not $To) { $To = if ($entry) { [string]$entry.dest } else { '' } }
    if (-not $Retries) { $Retries = if ($entry) { [string][Math]::Max(0, [int]$entry.attempt - 1) } else { '0' } }
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = "[$ts] DLQ | $MsgId | to=$To | from=$myId | retries=$Retries | ESTADO=UNREAD | flag=$Flag"
    if ($Summary) { $line += " | '$Summary'" }
    $res = Add-CrossLogLine -Path $DlqPath -Line $line
    if (-not $res.ok) { return @{ ok = $false; err = $res.err; detail = $res.detail } }
    $outboxMarked = $false
    if ($entry) {
        $mr = Set-OutboxEstado -MsgId $MsgId -Estado 'DLQ' -Path $OutboxPath
        if ($mr.ok) { $outboxMarked = $true }
    }
    $audit = Write-AuditEntry -MsgId $MsgId -Dest $To -Tipo 'DLQ' -Estado 'ESCRITO' -Nota "flag=$Flag; retries=$Retries" -AuditPath $AuditPath
    return @{ ok = $true; msg_id = $MsgId; line = $line; written = $res.ok; outbox_marked = $outboxMarked; audit_ok = $audit.ok }
}

function Set-CrossQuarantine {
    param(
        [AllowEmptyString()][string]$MsgId,
        [AllowEmptyString()][string]$Reason,
        [string]$OutboxPath = '',
        [string]$DlqPath = '',
        [string]$LogPath = '',
        [string]$AuditPath = '',
        [int]$Minutes = 10,
        [switch]$CheckLog,
        [scriptblock]$HealthFn = $null,
        [scriptblock]$SessionFn = $null
    )
    if (-not $MsgId) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --msg-id' } }
    if (-not $Reason) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --reason' } }
    if (-not $OutboxPath) { $OutboxPath = (Get-CrossActionPaths).outbox }
    if (-not $DlqPath) { $DlqPath = (Get-CrossActionPaths).dlq }
    $entry = @(Read-OutboxLog -Path $OutboxPath | Where-Object { $_.msg_id -eq $MsgId }) | Select-Object -First 1
    if (-not $entry) { return @{ ok = $false; err = 'OUTBOX_MSG_NOT_FOUND'; detail = $MsgId } }
    $diag = $null
    if ($CheckLog) {
        # D2 (v1.17): structured diagnosis; LogPath/Minutes legacy params are ignored
        $diag = Get-CrossDiagnose -Msg $MsgId -OutboxPath $OutboxPath -HealthFn $HealthFn -SessionFn $SessionFn
    }
    $summary = $Reason
    if ($diag -and $diag.ok -and $diag.classification) { $summary += "; log=$($diag.classification)" }
    $dlq = Write-CrossDlq -MsgId $MsgId -To ([string]$entry.dest) -Retries ([string][Math]::Max(0, [int]$entry.attempt - 1)) -Flag 'HUMAN_REVIEW' -Summary $summary -OutboxPath $OutboxPath -DlqPath $DlqPath -AuditPath $AuditPath
    $qr = Set-OutboxEstado -MsgId $MsgId -Estado 'QUARANTINE' -Path $OutboxPath
    $audit = Write-AuditEntry -MsgId $MsgId -Dest ([string]$entry.dest) -Tipo 'QUARANTINE' -Estado 'ESCRITO' -Nota "flag=HUMAN_REVIEW; dlq escrito" -AuditPath $AuditPath
    return @{
        ok = $true; msg_id = $MsgId; quarantine = $qr.ok; dlq_written = $dlq.ok
        log_diagnostic = $diag; audit_ok = $audit.ok
    }
}

function Get-CrossDiagnose {
    <#
    D2 (v1.17): structured failure diagnosis (HY3 design, API-first hybrid).
    Contract:
      1. CONFIG_ERROR   <- local validation (session-id format, token presence)
      2. PROVIDER_DOWN  <- /global/health unhealthy (Test-CrossHealthRaw)
      3. AGENT_SLEEPING <- Get-CrossSessionState: status in {idle,asleep} OR
                           now - lastActivityAt > SleepThresholdSec
      4. fallback NO_ERROR when no structured signal is available.
    NEVER scrapes third-party application logs. Fully mockable:
    -HealthFn / -SessionFn scriptblocks for CI without a live server.
    #>
    param(
        [AllowEmptyString()][string]$Msg,
        [string]$OutboxPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [int]$SleepThresholdSec = 300,
        [scriptblock]$HealthFn,
        [scriptblock]$SessionFn
    )
    if (-not $Msg) { return @{ ok = $false; err = 'USAGE_ERROR'; detail = 'missing --msg'; classification = 'NO_DATA'; source = 'none' } }
    if (-not $OutboxPath) { $OutboxPath = (Get-CrossActionPaths).outbox }
    $entry = @(Read-OutboxLog -Path $OutboxPath | Where-Object { $_.msg_id -eq $Msg }) | Select-Object -First 1
    $dest = ''
    $token = ''
    if ($entry) {
        $dest = [string]$entry.dest
        if ($entry.token) { $token = [string]$entry.token }
    }

    # 1) CONFIG_ERROR <- local validation, no network
    if ($dest -and $dest -notmatch '^ses_[0-9A-Za-z]+$') {
        return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'CONFIG_ERROR'
                  action = 'invalid destination session-id format: fix config or outbox entry'
                  source = 'local-validation' }
    }
    if (-not $token) {
        return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'CONFIG_ERROR'
                  action = 'outbox entry has no token: re-send with a fresh token'
                  source = 'local-validation' }
    }
    $pw = if ($Password) { $Password } else { $p = Get-CrossPassword; if ($p) { $p.value } else { '' } }
    # D2 fix: when HealthFn is mocked (CI), credential absence must not shadow the
    # scenario under test - only enforce password in real (non-mocked) runs.
    if (-not $pw -and -not $HealthFn) {
        return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'CONFIG_ERROR'
                  action = 'OPENCODE_SERVER_PASSWORD not defined (env or .env)'
                  source = 'local-validation' }
    }

    # 2) PROVIDER_DOWN <- /global/health
    $healthy = $null
    if ($HealthFn) { $healthy = & $HealthFn } else {
        $ep = Resolve-CrossEndpoint -Port $Port -Password $pw
        if (-not $ep.ok) {
            return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'PROVIDER_DOWN'
                      action = 'server unreachable/health failed: wait and retry delivery'
                      source = 'api-health'; detail = $ep.err }
        }
        $h = Test-CrossHealthRaw -Port $ep.port -Password $pw
        $healthy = $h.healthy
    }
    if ($healthy -eq $false) {
        return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'PROVIDER_DOWN'
                  action = 'provider/server unhealthy: renew lease and wait (12.10)'
                  source = 'api-health' }
    }

    # 3) AGENT_SLEEPING <- structured session state of the destination
    $state = $null
    if ($SessionFn) { $state = @(& $SessionFn $dest) } elseif ($dest) {
        $ep = Resolve-CrossEndpoint -Port $Port -Password $pw
        if ($ep.ok) { $state = Get-CrossSessionState -Id $dest -Port $ep.port -Password $pw }
    }
    if ($state -and $state.ok) {
        $st = [string]$state.status
        if ($st -in @('idle', 'asleep')) {
            return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'AGENT_SLEEPING'
                      action = 'destination idle/asleep: nudge (12.10) then escalate if persistent'
                      source = 'api-session-state'; session_status = $st }
        }
        if ($state.last_activity_at) {
            try {
                $la = [System.DateTime]::Parse($state.last_activity_at, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                $idleFor = ((Get-Date).ToUniversalTime() - $la).TotalSeconds
                if ($idleFor -gt $SleepThresholdSec) {
                    return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'AGENT_SLEEPING'
                              action = "no activity for $([int]$idleFor)s (> ${SleepThresholdSec}s): nudge (12.10)"
                              source = 'api-session-state'; idle_seconds = [int]$idleFor }
                }
            } catch { } # unparseable timestamp -> keep falling through to NO_ERROR
        }
    }

    # 4) fallback: explicit NO_ERROR (no blind classification)
    return @{ ok = $true; msg = $Msg; dest = $dest; classification = 'NO_ERROR'
              action = 'no structured failure signal: verify ACK via audit/reconcile (12.10)'
              source = $(if ($state -and $state.checkable) { 'api-session-state' } else { 'none' }) }
}
Export-ModuleMember -Function Send-CrossAck, Send-CrossNack, Send-CrossResume, Restart-CrossTask, Send-CrossNudge, Write-CrossEscalated, Write-CrossDlq, Set-CrossQuarantine, Get-CrossDiagnose, Get-CrossActionPaths, Get-CrossMyId
