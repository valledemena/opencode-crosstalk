# cross-diagnostic.psm1 - Fase 4a (diagnostico): poll, status, reconcile, aviso-spof.
# Observacion pura salvo las mutaciones explicitas (B1: poll marca NACKED; aviso-spof con --apply).
# Uso (via cross.ps1): cross poll|status|reconcile|aviso-spof
Set-StrictMode -Version 2.0

if (-not (Get-Command ConvertTo-AsciiSafe -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\lib\cross-format.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Get-CrossConfig -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-transport.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Read-OutboxLog -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-state.psm1') -Force -DisableNameChecking
}
if (-not (Get-Command Test-SessionGrowing -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-delivery.psm1') -Force -DisableNameChecking
}

function Get-DiagPaths {
    $cfg = Get-CrossConfig
    $dir = if ($cfg.whiteboard_dir) { [Environment]::ExpandEnvironmentVariables([string]$cfg.whiteboard_dir) } else { Split-Path -Parent (Get-OutboxPath) }
    return @{
        outbox       = Join-Path $dir 'outbox.md'
        idempotencia = Join-Path $dir 'idempotencia-procesados.md'
        audit        = Join-Path $dir 'audit_log.md'
        escalated    = Join-Path $dir 'escalated.md'
        dlq          = Join-Path $dir 'dlq-messages.md'
    }
}

function Get-SessionState {
    param(
        [Parameter(Mandatory=$true)][string]$SessionId,
        [int]$Port = 0,
        [string]$Password = '',
        [int]$WaitMs = 15000,
        [scriptblock]$SessionFn,
        [scriptblock]$SleepFn
    )
    if ($SessionFn) { return @(& $SessionFn $SessionId) }
    $status = ''
    $checkable = $false
    $growing = $false
    if ($Port) {
        $api = Invoke-CrossApi -Method 'GET' -Path "/api/session/$SessionId" -Port $Port -Password $Password -TimeoutSec 8
        if ($api.status -eq 200) {
            $s = $api.body | ConvertFrom-Json
            if ($null -ne $s -and $s.status) { $status = [string]$s.status }
            $checkable = $true
        }
        if ($status -eq 'idle' -or $status -eq 'asleep') {
            # D2 (v1.17): structured AGENT_SLEEPING signal from GET /session/:id
            return @{ session_id = $SessionId; status = $status; growing = $false; checkable = $true; wait_ms = $WaitMs; sleeping = $true }
        }
        if ($status -eq 'busy' -or -not $status) {
            $g = Test-SessionGrowing -SessionId $SessionId -Port $Port -Password $Password -WaitMs $WaitMs -SleepFn $SleepFn
            $growing = [bool]$g.growing
        }
    }
    return @{ session_id = $SessionId; status = $status; growing = $growing; checkable = $checkable; wait_ms = $WaitMs }
}

function Read-EscalatedLog {
    param([string]$Path = '')
    if (-not $Path) { $Path = (Get-DiagPaths).escalated }
    $items = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return @($items) }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -notmatch '^URGENTE\s*\||^AVISO-SPOF') { continue }
        $recibido = ($t -match '\bRECIBIDO\s*$')
        $fields = @($t -split '\|') | ForEach-Object { $_.Trim() }
        $para = ''; $msgId = ''; $runId = ''; $de = ''; $expira = ''; $resumen = ''
        foreach ($f in $fields) {
            if ($f -match '^para=(.+)$') { $para = $Matches[1] }
            elseif ($f -match '^run_id=(.+)$') { $runId = $Matches[1] }
            elseif ($f -match '^de=(.+)$') { $de = $Matches[1] }
            elseif ($f -match '^expira=(.+)$') { $expira = $Matches[1] }
            elseif ($f -match '^msg_id=(.+)$') { $msgId = $Matches[1] }
            elseif (-not $msgId -and $f -match '^msg_[^\s|]+$') { $msgId = $f }
            elseif ($f -match "^(?:'|\"")(.+?)(?:'|\"")(?:\s*RECIBIDO)?$") { $resumen = $Matches[1] }
        }
        [void]$items.Add([ordered]@{
            raw = $t; kind = $(if ($t -match '^AVISO-SPOF') { 'AVISO-SPOF' } else { 'URGENTE' })
            para = $para; msg_id = $msgId; run_id = $runId; de = $de; expira = $expira; resumen = $resumen; recibido = $recibido
        })
    }
    return @($items)
}

function Read-DlqLog {
    param([string]$Path = '')
    if (-not $Path) { $Path = (Get-DiagPaths).dlq }
    $items = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return @($items) }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $t = $line.Trim()
        if (-not $t -or $t -notmatch '^\[.*\]\s*DLQ') { continue }
        $fields = @($t -split '\|') | ForEach-Object { $_.Trim() }
        if ($fields.Count -lt 5) { continue }
        $msgId = $fields[1]
        $to = ''; $from = ''; $retries = ''; $estado = ''; $flag = ''; $resumen = ''
        foreach ($f in $fields) {
            if ($f -match '^to=(.+)$') { $to = $Matches[1] }
            elseif ($f -match '^from=(.+)$') { $from = $Matches[1] }
            elseif ($f -match '^retries=(\d+)') { $retries = $Matches[1] }
            elseif ($f -match '^ESTADO=(.+)$') { $estado = $Matches[1] }
            elseif ($f -match '^flag=(.+)$') { $flag = $Matches[1] }
            elseif ($f -match "^(?:'|\"")(.+?)(?:'|\"")$") { $resumen = $Matches[1] }
        }
        [void]$items.Add([ordered]@{
            raw = $t; msg_id = $msgId; to = $to; from = $from; retries = $retries
            estado = $estado; flag = $flag; resumen = $resumen; unread = ($estado -eq 'UNREAD')
        })
    }
    return @($items)
}

function Find-AuditOutcome {
    param([Parameter(Mandatory=$true)][string]$MsgId, [string]$AuditPath = '')
    if (-not $AuditPath) { $AuditPath = (Get-DiagPaths).audit }
    $ack = $null; $nack = $null
    if (-not (Test-Path -LiteralPath $AuditPath)) { return @{ ack = $null; nack = $null } }
    $pat = 'msg=' + [regex]::Escape($MsgId) + '(\s|;|\||$)'
    foreach ($line in (Get-Content -LiteralPath $AuditPath)) {
        if ($line -notmatch $pat) { continue }
        $fields = @($line -split '\|')
        if ($fields.Count -lt 7) { continue }
        $estado = $fields[6].Trim()
        if ($estado -eq 'NACKED') {
            $rc = ''; $nota = if ($fields.Count -gt 7) { $fields[7].Trim() } else { '' }
            if ($nota -match 'rc=(\S+)') { $rc = $Matches[1] }
            $nack = @{ estado = 'NACKED'; reason = $rc }
        } elseif ($estado -eq 'CONFIRMADO') {
            $ack = @{ estado = 'CONFIRMADO' }
        }
    }
    return @{ ack = $ack; nack = $nack }
}

function Get-PollDiagnostic {
    param(
        [string]$OutboxEstado,
        [bool]$NackDetected = $false,
        [bool]$AckDetected = $false,
        [bool]$LeaseVencido = $false,
        $SessionState = $null
    )
    if ($OutboxEstado -eq 'CONFIRMADO' -or $AckDetected) {
        return @{ diagnostic = 'ACKED'; action = 'ninguna (entregado y confirmado)'; confidence = 'alta' }
    }
    if ($OutboxEstado -eq 'NACKED' -or $NackDetected) {
        return @{ diagnostic = 'NACKED'; action = 'gestionar segun razon (12.7/12.10)'; confidence = 'alta' }
    }
    if ($OutboxEstado -in @('EXPIRADO', 'TRANSFERIDO', 'QUARANTINE')) {
        return @{ diagnostic = 'TERMINAL'; action = 'gestionar estado terminal (12.10/12.11)'; confidence = 'alta' }
    }
    if ($LeaseVencido) {
        return @{ diagnostic = 'EXPIRED'; action = 'ejecutar scan (12.10) para RETRY/RESUME/RECONCILE'; confidence = 'alta' }
    }
    if ($null -eq $SessionState -or -not $SessionState.checkable) {
        return @{ diagnostic = 'UNKNOWN'; action = 'could not verify destination session'; confidence = 'low' }
    }
    $st = $SessionState.status
    $grow = [bool]$SessionState.growing
    if ($st -eq 'error') {
        return @{ diagnostic = 'PROVIDER_DOWN'; action = 'provider failure, healthy agent: renew lease and wait (12.10)'; confidence = 'alta' }
    }
    if ($st -eq 'busy') {
        if ($grow) { return @{ diagnostic = 'WORKING'; action = 'wait (renew lease if applicable, 12.4a)'; confidence = 'alta' } }
        return @{ diagnostic = 'ACKED_QUIETA'; action = 'investigate: agent busy with no growth, possible stall'; confidence = 'media' }
    }
    if ($st -eq 'idle') {
        if ($grow) { return @{ diagnostic = 'WORKING'; action = 'wait'; confidence = 'media' } }
        return @{ diagnostic = 'QUIETA_SIN_ACK'; action = 'circuit breaker 12.9: verificar ACK en audit; si no, escalar (12.10)'; confidence = 'media' }
    }
    if ($grow) { return @{ diagnostic = 'CRECE_SIN_ACK'; action = 'wait: the session is growing, renew lease (12.4a)'; confidence = 'media' } }
    return @{ diagnostic = 'QUIETA_SIN_ACK'; action = 'circuit breaker 12.9: escalar (12.10/12.11)'; confidence = 'media' }
}

function Get-CrossPoll {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [string]$OutboxPath = '',
        [string]$AuditPath = '',
        [int]$TimeoutSec = 0,
        [int]$IntervalMs = 3000,
        [int]$WaitMs = 15000,
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SessionFn,
        [scriptblock]$SleepFn
    )
    if (-not $OutboxPath) { $OutboxPath = (Get-DiagPaths).outbox }
    if (-not $AuditPath) { $AuditPath = (Get-DiagPaths).audit }
    $entry = @(Read-OutboxLog -Path $OutboxPath | Where-Object { $_.msg_id -eq $MsgId }) | Select-Object -First 1
    if (-not $entry) {
        return @{ ok = $false; err = 'OUTBOX_MSG_NOT_FOUND'; detail = $MsgId; diagnostic = 'NOT_FOUND'; action = 'verificar msg_id' }
    }
    $deadline = $null
    if ($TimeoutSec -gt 0) { $deadline = (Get-Date).AddSeconds($TimeoutSec) }
    $last = $null
    do {
        $entry = @(Read-OutboxLog -Path $OutboxPath | Where-Object { $_.msg_id -eq $MsgId }) | Select-Object -First 1
        if (-not $entry) {
            $last = @{ ok = $false; diagnostic = 'NOT_FOUND'; action = 'msg_id desaparecio del outbox' }
            break
        }
        $audit = Find-AuditOutcome -MsgId $MsgId -AuditPath $AuditPath
        $leaseVencido = $false
        if ($entry.lease -match '@(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)') {
            try {
                $leaseVencido = ([System.DateTime]::Parse($Matches[1]).ToUniversalTime() -lt (Get-Date).ToUniversalTime())
            } catch { $leaseVencido = $true }
        }
        $sess = $null
        if ($entry.estado -eq 'EN_VUELO') {
            $sess = Get-SessionState -SessionId $entry.dest -Port $Port -Password $Password -WaitMs $WaitMs -SessionFn $SessionFn -SleepFn $SleepFn
        }
        $diag = Get-PollDiagnostic -OutboxEstado $entry.estado -NackDetected:($null -ne $audit.nack) -AckDetected:($null -ne $audit.ack) -LeaseVencido:$leaseVencido -SessionState $sess
        $last = @{
            ok = $true
            msg_id = $MsgId
            dest = $entry.dest
            outbox_state = $entry.estado
            diagnostic = $diag.diagnostic
            action = $diag.action
            confidence = $diag.confidence
            session_status = $(if ($sess) { $sess.status } else { '' })
            session_growing = $(if ($sess) { $sess.growing } else { $null })
            nack_reason = $(if ($audit.nack) { $audit.nack.reason } else { '' })
            lease_expired = $leaseVencido
        }
        if (-not $deadline) { break }
        if ($diag.diagnostic -in @('ACKED', 'NACKED', 'TERMINAL')) { break }
        if ($SleepFn) { & $SleepFn $IntervalMs } else { Start-Sleep -Milliseconds $IntervalMs }
    } while ((Get-Date) -lt $deadline)
    return $last
}

function Get-CrossStatus {
    param(
        [string]$MsgId = '',
        [string]$RunId = '',
        [string]$Agent = '',
        [string]$OutboxPath = '',
        [string]$StatePath = '',
        [string]$EscalatedPath = '',
        [string]$DlqPath = '',
        [string]$AuditPath = '',
        [int]$Port = 0,
        [string]$Password = '',
        [int]$WaitMs = 15000,
        [scriptblock]$SessionFn,
        [scriptblock]$SleepFn
    )
    if (-not $OutboxPath) { $OutboxPath = (Get-DiagPaths).outbox }
    if (-not $StatePath) { $StatePath = (Get-DiagPaths).idempotencia }
    if (-not $EscalatedPath) { $EscalatedPath = (Get-DiagPaths).escalated }
    if (-not $DlqPath) { $DlqPath = (Get-DiagPaths).dlq }
    if (-not $AuditPath) { $AuditPath = (Get-DiagPaths).audit }

    $entries = @(Read-OutboxLog -Path $OutboxPath)
    if ($MsgId) { $entries = @($entries | Where-Object { $_.msg_id -eq $MsgId }) }
    if ($RunId) { $entries = @($entries | Where-Object { $_.run_id -eq $RunId }) }
    if ($Agent) { $entries = @($entries | Where-Object { $_.dest -eq $Agent }) }

    $byState = @{}
    foreach ($e in $entries) {
        $k = $e.estado; if (-not $k) { $k = 'SIN_ESTADO' }
        $byState[$k] = [int]$byState[$k] + 1
    }

    $byAgent = @{}
    foreach ($e in $entries) {
        if (-not $e.dest) { continue }
        if (-not $byAgent.ContainsKey($e.dest)) {
            $byAgent[$e.dest] = [ordered]@{ agent = $e.dest; en_vuelo = 0; confirmado = 0; expirado = 0; nacked = 0; terminal = 0; total = 0; last_seen = '' }
        }
        $a = $byAgent[$e.dest]
        switch ($e.estado) {
            'EN_VUELO' { $a.en_vuelo++; if ($e.lease -match '@(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)') { $a.last_seen = $Matches[1] } }
            'CONFIRMADO' { $a.confirmado++ }
            'EXPIRADO' { $a.expirado++ }
            'NACKED' { $a.nacked++ }
            default { $a.terminal++ }
        }
        $a.total++
    }
    $agents = New-Object System.Collections.ArrayList
    foreach ($k in $byAgent.Keys) {
        $a = $byAgent[$k]
        $st = $null
        if ($SessionFn -or $Port) { $st = Get-SessionState -SessionId $k -Port $Port -Password $Password -WaitMs $WaitMs -SessionFn $SessionFn -SleepFn $SleepFn }
        [void]$agents.Add([ordered]@{
            agent = $a.agent; en_vuelo = $a.en_vuelo; confirmado = $a.confirmado; expirado = $a.expirado
            nacked = $a.nacked; terminal = $a.terminal; total = $a.total; last_seen = $a.last_seen
            state = $(if ($st) { if ($st.status) { $st.status } elseif ($st.growing) { 'growing' } else { 'quiet' } } else { 'unknown' })
        })
    }

    $expiredUnmanaged = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        if ($e.estado -ne 'EN_VUELO' -or -not $e.lease) { continue }
        $vencido = $false
        if ($e.lease -match '@(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)') {
            try { $vencido = ([System.DateTime]::Parse($Matches[1]).ToUniversalTime() -lt (Get-Date).ToUniversalTime()) } catch { $vencido = $true }
        }
        if ($vencido) {
            [void]$expiredUnmanaged.Add([ordered]@{ msg_id = $e.msg_id; dest = $e.dest; lease = $e.lease; attempt = $e.attempt })
        }
    }

    $idem = @(Read-IdempotenciaLog -Path $StatePath)
    if ($MsgId) { $idem = @($idem | Where-Object { $_.msg_id -eq $MsgId }) }
    $idemByState = @{}
    $lastPerMsg = @{}
    foreach ($rec in $idem) {
        $lastPerMsg[$rec.msg_id] = $rec
        $k = if ($rec.state -match '^CLAIMED_BY=') { 'CLAIMED' } else { $rec.state }
        $idemByState[$k] = [int]$idemByState[$k] + 1
    }
    $claimedOrphaned = New-Object System.Collections.ArrayList
    $claimers = @{}
    foreach ($k in $lastPerMsg.Keys) {
        $rec = $lastPerMsg[$k]
        if ($rec.state -match '^CLAIMED_BY=(.+)$') {
            $owner = $Matches[1]
            if (-not $claimers.ContainsKey($owner)) { $claimers[$owner] = New-Object System.Collections.ArrayList }
            [void]$claimers[$owner].Add($rec.msg_id)
        }
    }
    foreach ($o in $claimers.Keys) {
        $st = $null
        if ($SessionFn -or $Port) { $st = Get-SessionState -SessionId $o -Port $Port -Password $Password -WaitMs $WaitMs -SessionFn $SessionFn -SleepFn $SleepFn }
        $quiet = $null
        if ($st) { $quiet = -not $st.growing }
        foreach ($mid in $claimers[$o]) {
            [void]$claimedOrphaned.Add([ordered]@{
                msg_id = $mid; owner = $o; claimer_quiet = $quiet; claimer_checked = ($null -ne $quiet)
                claimer_status = $(if ($st) { $st.status } else { 'unreachable' })
            })
        }
    }

    $escalated = @(Read-EscalatedLog -Path $EscalatedPath)
    $escalatedPending = @($escalated | Where-Object { -not $_.recibido -and $_.kind -eq 'URGENTE' })
    $avisoSpof = @($escalated | Where-Object { $_.kind -eq 'AVISO-SPOF' })

    $dlq = @(Read-DlqLog -Path $DlqPath)
    $dlqUnread = @($dlq | Where-Object { $_.unread })
    $dlqByFlag = @{}
    $validFlags = @('HUMAN_REVIEW', 'NACK_ORIGINATED', 'QUARANTINE', 'PROVIDER_DOWN')
    foreach ($d in $dlq) {
        $f = $d.flag
        if (-not $f -or $f -notin $validFlags) { $f = 'UNKNOWN' }
        $dlqByFlag[$f] = [int]$dlqByFlag[$f] + 1
    }

    $lifecycle = $null
    if ($MsgId) {
        $auditLines = New-Object System.Collections.ArrayList
        $audit = $AuditPath
        if (Test-Path -LiteralPath $audit) {
            $pat = 'msg=' + [regex]::Escape($MsgId) + '(\s|;|\||$)'
            foreach ($line in (Get-Content -LiteralPath $audit)) {
                if ($line -match $pat) { [void]$auditLines.Add($line.Trim()) }
            }
        }
        $lifecycle = [ordered]@{
            msg_id = $MsgId
            outbox = @($entries)
            idempotencia = @($idem)
            audit = @($auditLines)
        }
    }

    return @{
        ok = $true
        outbox_by_state = $byState
        outbox_by_agent = @($agents)
        expired_unmanaged = @($expiredUnmanaged)
        idempotencia_by_state = $idemByState
        claimed_orphaned = @($claimedOrphaned)
        escalated_pending = @($escalatedPending)
        aviso_spof = @($avisoSpof)
        dlq_unread = @($dlqUnread)
        dlq_by_flag = $dlqByFlag
        lifecycle = $lifecycle
    }
}

function Get-CrossReconcile {
    param(
        [Parameter(Mandatory=$true)][string]$MsgId,
        [Parameter(Mandatory=$true)][string]$CheckFile,
        [string]$ExpectedToken = '',
        [string]$OutboxPath = ''
    )
    if (-not $OutboxPath) { $OutboxPath = (Get-DiagPaths).outbox }
    $entry = @(Read-OutboxLog -Path $OutboxPath | Where-Object { $_.msg_id -eq $MsgId }) | Select-Object -First 1
    if (-not $ExpectedToken -and $entry) { $ExpectedToken = [string]$entry.token }
    $meta = @{ exists = $false; size = 0; mtime = ''; lines = 0; line_found = 0; token = $ExpectedToken }
    if (Test-Path -LiteralPath $CheckFile) {
        $fi = Get-Item -LiteralPath $CheckFile
        $meta.exists = $true
        $meta.size = $fi.Length
        $meta.mtime = $fi.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $all = @(Get-Content -LiteralPath $CheckFile)
        $meta.lines = $all.Count
        if ($ExpectedToken) {
            for ($i = 0; $i -lt $all.Count; $i++) {
                if ($all[$i] -match [regex]::Escape($ExpectedToken)) { $meta.line_found = $i + 1; break }
            }
        }
    }
    $verdict = 'NOT_FOUND'; $recommendation = 'retry'
    if ($meta.line_found -gt 0) { $verdict = 'CONFIRMED'; $recommendation = 'mark_confirmed' }
    elseif ($meta.exists -and $meta.lines -eq 0) { $verdict = 'AMBIGUOUS'; $recommendation = 'retry' }
    elseif ($meta.exists -and $meta.lines -gt 0) { $verdict = 'AMBIGUOUS'; $recommendation = 'investigate' }
    return @{
        ok = $true
        msg_id = $MsgId
        check_file = $CheckFile
        expected_token = $ExpectedToken
        verdict = $verdict
        recommendation = $recommendation
        file = $meta
    }
}

function Write-AppendDiagLine {
    param([string]$Path, [string]$Line)
    # E2 (v1.18): delega a Add-CrossLogLine (elimina duplicación, hereda mutex+retries)
    return Add-CrossLogLine -Path $Path -Line $Line
}

function Get-CrossAvisoSpof {
    param(
        [string]$OutboxPath = '',
        [string]$EscalatedPath = '',
        [string]$MySessionId = '',
        [switch]$Apply,
        [int]$Port = 0,
        [string]$Password = '',
        [int]$WaitMs = 15000,
        [scriptblock]$SessionFn,
        [scriptblock]$NotifyFn,
        [scriptblock]$SleepFn
    )
    if (-not $OutboxPath) { $OutboxPath = (Get-DiagPaths).outbox }
    if (-not $EscalatedPath) { $EscalatedPath = (Get-DiagPaths).escalated }
    $cfg = Get-CrossConfig
    if (-not $MySessionId) { $MySessionId = [string]$cfg.my_session_id }
    $targetSession = if ($cfg.leader_session_id) { [string]$cfg.leader_session_id } else { $MySessionId }
    $vencidos = @(Find-CrossOutboxPending -Path $OutboxPath | Where-Object { $_.vencido })
    $results = New-Object System.Collections.ArrayList
    $written = New-Object System.Collections.ArrayList
    $notified = New-Object System.Collections.ArrayList
    foreach ($e in $vencidos) {
        if ($e.dest -eq $MySessionId) {
            $st = Get-SessionState -SessionId $MySessionId -Port $Port -Password $Password -WaitMs $WaitMs -SessionFn $SessionFn -SleepFn $SleepFn
            $mineQuiet = (-not [bool]$st.growing)
            if ($mineQuiet) {
                [void]$results.Add([ordered]@{ msg_id = $e.msg_id; dest = $e.dest; action = 'aviso-spof'; detail = 'EN_VUELO vencido y mi sesion quieta' })
                if ($Apply) {
                    $line = "AVISO-SPOF | msg_id=$($e.msg_id) | para=$($e.dest) | de=$MySessionId | expira=$((Get-Date).ToUniversalTime().AddMinutes(3).ToString('yyyy-MM-ddTHH:mm:ssZ')) | 'EN_VUELO vencido, sesion quieta'"
                    Write-AppendDiagLine -Path $EscalatedPath -Line $line
                    [void]$written.Add($e.msg_id)
                }
            } else {
                [void]$results.Add([ordered]@{ msg_id = $e.msg_id; dest = $e.dest; action = 'growing'; detail = 'lease expido pero mi sesion crece: esperar' })
            }
        } else {
            [void]$results.Add([ordered]@{ msg_id = $e.msg_id; dest = $e.dest; action = 'notify-leader'; detail = 'fallen message for another session: notify leader' })
            if ($Apply) {
                if ($NotifyFn) {
                    [void](& $NotifyFn $e.dest $e.msg_id)
                } elseif ($Port) {
                    $body = "AVISO-SPOF | there is a fallen message for $($e.dest) | msg_id=$($e.msg_id) | from=$MySessionId"
                    $payload = @{ parts = @(@{ type = 'text'; text = $body }) } | ConvertTo-Json -Depth 4
                    [void](Invoke-CrossApi -Method 'POST' -Path "/api/session/$targetSession/prompt" -BodyJson $payload -Port $Port -Password $Password)
                }
                [void]$notified.Add($e.msg_id)
            }
        }
    }
    return @{
        ok = $true
        vencidos = $vencidos.Count
        dry_run = (-not $Apply)
        results = @($results)
        written = @($written)
        notified = @($notified)
    }
}

function Get-CrossMetrics {
    param(
        [string]$Since = '',
        [string]$Until = '',
        [string]$ByAgent = '',
        [string]$LogPath = ''
    )
    $cfg = Get-CrossConfig
    $dir = if ($cfg.whiteboard_dir) { [Environment]::ExpandEnvironmentVariables([string]$cfg.whiteboard_dir) } else { Split-Path -Parent (Get-OutboxPath) }
    if (-not $LogPath) { $LogPath = Join-Path $dir 'delivery_log.jsonl' }
    if (-not (Test-Path -LiteralPath $LogPath)) {
        return @{ ok = $false; err = 'LOG_NOT_FOUND'; detail = $LogPath }
    }
    $sinceDt = $null
    $untilDt = $null
    if ($Since) {
        try { $sinceDt = [System.DateTime]::Parse($Since).ToUniversalTime() }
        catch { return @{ ok = $false; err = 'USAGE_ERROR'; detail = "--since formato invalido: '$Since' (usar ISO8601, p. ej. 2026-08-13T00:00:00Z)" } }
    }
    if ($Until) {
        try { $untilDt = [System.DateTime]::Parse($Until).ToUniversalTime() }
        catch { return @{ ok = $false; err = 'USAGE_ERROR'; detail = "--until formato invalido: '$Until' (usar ISO8601, p. ej. 2026-08-13T00:00:00Z)" } }
    }

    $latencies = New-Object System.Collections.ArrayList
    $outcome = @{ ACK = 0; NACK = 0; TIMEOUT = 0; ERROR = 0; NO_ACK = 0; OTHER = 0 }
    $attempts = @{}
    $leaseRenewals = 0
    $total = 0
    $nackReasons = @{}
    $byAgentCounts = @{}
    $quarantine = 0
    $dlq = 0

    foreach ($raw in (Get-Content -LiteralPath $LogPath)) {
        if (-not $raw.Trim()) { continue }
        $j = $null
        try { $j = $raw | ConvertFrom-Json } catch { continue }
        if (-not $j) { continue }
        $ts = $null
        if ($j.ts) {
            try { $ts = [System.DateTime]::Parse([string]$j.ts).ToUniversalTime() } catch { }
        }
        if ($ts) {
            if ($sinceDt -and $ts -lt $sinceDt) { continue }
            if ($untilDt -and $ts -gt $untilDt) { continue }
        }
        $dest = if ($j.PSObject.Properties['dest']) { [string]$j.dest } else { '' }
        if ($ByAgent -and $dest -ne $ByAgent) { continue }
        $total++
        $agentKey = if ($dest) { $dest } else { '(sin dest)' }
        if ($byAgentCounts.ContainsKey($agentKey)) { $byAgentCounts[$agentKey]++ } else { $byAgentCounts[$agentKey] = 1 }

        $st = if ($j.state) { [string]$j.state } else { '' }
        $nackFlag = $false
        if ($j.PSObject.Properties['nack']) { $nackFlag = [bool]$j.nack }
        $reasonCode = if ($j.PSObject.Properties['reason_code']) { [string]$j.reason_code } else { '' }
        $err = if ($j.PSObject.Properties['err']) { [string]$j.err } else { '' }
        # F4/F6 (2026-08-13): clasificar por estado, no por el flag ack, para no
        # contar como OTHER las lineas historicas CONFIRMADO con ack=false
        # (formato experimental de tests viejos) ni las fire-and-forget.
        if ($st -eq 'CONFIRMADO') { $outcome.ACK++ }
        elseif ($nackFlag -or ($reasonCode -match '^NACK')) {
            $outcome.NACK++
            $reason = if ($j.PSObject.Properties['reason']) { [string]$j.reason } else { $reasonCode }
            if ($nackReasons.ContainsKey($reason)) { $nackReasons[$reason]++ } else { $nackReasons[$reason] = 1 }
        }
        elseif ($st -eq 'EXPIRADO' -and $err -eq 'ACK_TIMEOUT') { $outcome.TIMEOUT++ }
        elseif ($err) { $outcome.ERROR++ }
        elseif ($st -eq 'PENDING' -or $st -eq 'EN_VUELO') { $outcome.NO_ACK++ }
        else { $outcome.OTHER++ }

        $ackLatency = if ($j.PSObject.Properties['ack_latency_ms'] -and $null -ne $j.ack_latency_ms -and $j.ack_latency_ms -gt 0) { [int]$j.ack_latency_ms } else { 0 }
        if ($ackLatency -gt 0) { [void]$latencies.Add($ackLatency) }
        $attemptVal = if ($j.PSObject.Properties['attempt'] -and $null -ne $j.attempt) { [int]$j.attempt } else { -1 }
        if ($attemptVal -ge 0) {
            if ($attempts.ContainsKey("$attemptVal")) { $attempts["$attemptVal"]++ } else { $attempts["$attemptVal"] = 1 }
        }
        if ($j.PSObject.Properties['session_growing'] -and $j.session_growing) { $leaseRenewals++ }
        $cmd = if ($j.PSObject.Properties['cmd']) { [string]$j.cmd } else { '' }
        if ($cmd -eq 'quarantine') { $quarantine++ }
        if ($cmd -eq 'dlq') { $dlq++ }
    }

    $p50 = $null; $p95 = $null
    if ($latencies.Count -gt 0) {
        $sorted = @($latencies | Sort-Object)
        $p50 = $sorted[[math]::Floor($sorted.Count * 0.50)]
        $p95 = $sorted[[math]::Floor($sorted.Count * 0.95)]
    }
    $rates = @{
        ack = if ($total -gt 0) { [math]::Round(100.0 * $outcome.ACK / $total, 1) } else { 0 }
        nack = if ($total -gt 0) { [math]::Round(100.0 * $outcome.NACK / $total, 1) } else { 0 }
        timeout = if ($total -gt 0) { [math]::Round(100.0 * $outcome.TIMEOUT / $total, 1) } else { 0 }
        error = if ($total -gt 0) { [math]::Round(100.0 * $outcome.ERROR / $total, 1) } else { 0 }
    }
    $topNackLimit = 10
    $topNack = @()
    foreach ($k in @($nackReasons.Keys | Sort-Object { -$nackReasons[$_] })) {
        $topNack += [ordered]@{ reason = $k; count = $nackReasons[$k] }
        if ($topNack.Count -ge $topNackLimit) { break }
    }
    return @{
        ok = $true; source = 'delivery_log.jsonl'; log_path = $LogPath; total = $total
        by_outcome = $outcome; rates = $rates
        latency_p50_ms = $p50; latency_p95_ms = $p95
        attempts = $attempts; lease_renewals = $leaseRenewals
        top_nack = @($topNack); quarantine = $quarantine; dlq = $dlq
        by_agent = $byAgentCounts
    }
}

function Export-CrossMetrics {
    param(
        [string]$Since = '',
        [string]$Until = '',
        [string]$ByAgent = '',
        [string]$LogPath = '',
        [string]$OutputPath = '',
        [string]$OutboxPath = ''
    )
    if ($LogPath -and -not (Test-Path -LiteralPath $LogPath)) {
        return @{ ok = $false; err = 'LOG_NOT_FOUND'; detail = $LogPath }
    }
    $m = Get-CrossMetrics -Since $Since -Until $Until -ByAgent $ByAgent -LogPath $LogPath
    if (-not $m.ok) { return @{ ok = $false; err = $m.err; detail = $m.detail } }
    $pending = 0
    $status = Get-CrossStatus -OutboxPath $OutboxPath
    if ($status.ok -and $null -ne $status.outbox_by_state -and $status.outbox_by_state.ContainsKey('EN_VUELO')) { $pending = [int]$status.outbox_by_state['EN_VUELO'] }
    $oc = $m.by_outcome
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('# HELP cross_messages_total Total messages tracked in delivery_log.jsonl (envios via cross send; la actividad de asesores/reactivaciones esta en audit_log, no aqui)')
    [void]$lines.Add('# TYPE cross_messages_total counter')
    [void]$lines.Add("cross_messages_total $($m.total)")
    [void]$lines.Add('# HELP cross_messages_acked_total Messages confirmed (ACK received)')
    [void]$lines.Add('# TYPE cross_messages_acked_total counter')
    [void]$lines.Add("cross_messages_acked_total $($oc.ACK)")
    [void]$lines.Add('# HELP cross_messages_nacked_total Messages rejected (NACK received)')
    [void]$lines.Add('# TYPE cross_messages_nacked_total counter')
    [void]$lines.Add("cross_messages_nacked_total $($oc.NACK)")
    [void]$lines.Add('# HELP cross_messages_timeout_total Messages expired by ACK timeout')
    [void]$lines.Add('# TYPE cross_messages_timeout_total counter')
    [void]$lines.Add("cross_messages_timeout_total $($oc.TIMEOUT)")
    [void]$lines.Add('# HELP cross_messages_error_total Messages failed with error')
    [void]$lines.Add('# TYPE cross_messages_error_total counter')
    [void]$lines.Add("cross_messages_error_total $($oc.ERROR)")
    [void]$lines.Add('# HELP cross_messages_noack_total Messages delivered without waiting for ACK (no-wait / PENDING)')
    [void]$lines.Add('# TYPE cross_messages_noack_total counter')
    [void]$lines.Add("cross_messages_noack_total $($oc.NO_ACK)")
    [void]$lines.Add('# HELP cross_delivery_latency_ms Delivery latency in milliseconds (summary; solo quantiles P50/P95, el repositorio no calcula P99)')
    [void]$lines.Add('# TYPE cross_delivery_latency_ms summary')
    if ($null -ne $m.latency_p50_ms) { [void]$lines.Add('cross_delivery_latency_ms{quantile="0.5"} ' + $m.latency_p50_ms) }
    if ($null -ne $m.latency_p95_ms) { [void]$lines.Add('cross_delivery_latency_ms{quantile="0.95"} ' + $m.latency_p95_ms) }
    [void]$lines.Add('# HELP cross_outbox_pending Pending messages in outbox (state EN_VUELO)')
    [void]$lines.Add('# TYPE cross_outbox_pending gauge')
    [void]$lines.Add("cross_outbox_pending $pending")
    [void]$lines.Add('# HELP cross_messages_dlq Messages moved to dead letter queue')
    [void]$lines.Add('# TYPE cross_messages_dlq gauge')
    [void]$lines.Add("cross_messages_dlq $($m.dlq)")
    [void]$lines.Add('# HELP cross_messages_quarantine Messages quarantined for human review')
    [void]$lines.Add('# TYPE cross_messages_quarantine gauge')
    [void]$lines.Add("cross_messages_quarantine $($m.quarantine)")
    $text = ($lines -join "`n") + "`n"
    if ($OutputPath) {
        [System.IO.File]::WriteAllText($OutputPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        return @{ ok = $true; output = $OutputPath; lines = $lines.Count; source = $m.source; log_path = $m.log_path }
    }
    return @{ ok = $true; text = $text; lines = $lines.Count; source = $m.source; log_path = $m.log_path }
}

function Get-CrossDoctorReport {
    param([string]$ConfigPath = '')
    $checks = New-Object System.Collections.ArrayList

    # 1. config
    try {
        $cfg = if ($ConfigPath) { Import-CrossConfig -ConfigPath $ConfigPath } else { Get-CrossConfig }
        $idOk = [bool]($cfg.my_session_id) -and [bool]($cfg.my_role)
        $detail = "my_session_id='$($cfg.my_session_id)' role=$($cfg.my_role)"
        [void]$checks.Add([ordered]@{ name = 'config'; status = $(if ($idOk) { 'ok' } else { 'warn' }); detail = $detail })
    } catch {
        [void]$checks.Add([ordered]@{ name = 'config'; status = 'fail'; detail = "config no valido: $_" })
    }


    # 2. paths
    try {
        $paths = Get-DiagPaths
        $pathIssues = @()
        foreach ($entry in $paths.GetEnumerator()) {
            $expanded = [Environment]::ExpandEnvironmentVariables([string]$entry.Value)
            if (-not $expanded) { $pathIssues += "$($entry.Key): ruta vacia"; continue }
            $full = [System.IO.Path]::GetFullPath($expanded)
            $dir = Split-Path -Parent $full
            if (-not (Test-Path -LiteralPath $dir)) { $pathIssues += "$($entry.Key): dir no existe ($dir)" }
        }
        if ($pathIssues.Count -eq 0) { [void]$checks.Add([ordered]@{ name = 'paths'; status = 'ok'; detail = 'whiteboard dirs resolubles' }) }
        else { [void]$checks.Add([ordered]@{ name = 'paths'; status = 'warn'; detail = ($pathIssues -join '; ') }) }
    } catch {
        [void]$checks.Add([ordered]@{ name = 'paths'; status = 'warn'; detail = "paths no verificables: $_" })
    }

    # 3. integrity (checksum v1.7 + malformadas + consistencia)
    try {
        $stateEx = Read-IdempotenciaLogEx
        $outboxEntries = @(Read-OutboxLog)
        $malformed = @($outboxEntries | Where-Object { $_.malformed })
        $cons = Test-CrossConsistency
        $issues = @()
        if ($stateEx.corrupt_count -gt 0) { $issues += "$($stateEx.corrupt_count) linea(s) idempotencia con checksum corrupto" }
        if ($malformed.Count -gt 0) { $issues += "$($malformed.Count) linea(s) outbox malformada(s)" }
        foreach ($e in $cons.errors) { $issues += "consistencia: $e" }
        if ($issues.Count -eq 0) { [void]$checks.Add([ordered]@{ name = 'integrity'; status = 'ok'; detail = "idempotencia=$($stateEx.records.Count) regs, outbox=$($outboxEntries.Count) entries" }) }
        else { [void]$checks.Add([ordered]@{ name = 'integrity'; status = 'warn'; detail = ($issues -join '; ') }) }
    } catch {
        [void]$checks.Add([ordered]@{ name = 'integrity'; status = 'warn'; detail = "integridad no verificable: $_" })
    }

    # 4. password
    $pw = Get-CrossPassword
    if ($pw) { [void]$checks.Add([ordered]@{ name = 'password'; status = 'ok'; detail = "OPENCODE_SERVER_PASSWORD via $($pw.source)" }) }
    else { [void]$checks.Add([ordered]@{ name = 'password'; status = 'warn'; detail = 'OPENCODE_SERVER_PASSWORD no definida (env ni .env)' }) }

    # 5. server (N3/N5: CI sin server = warn esperado, no error)
    $isCi = [bool]$env:CI -or [bool]$env:GITHUB_ACTIONS
    $ep = Resolve-CrossEndpoint -HealthSkip
    if ($ep.ok) {
        $h = Test-CrossHealthRaw -Port $ep.port -Password $ep.password
        if ($h.healthy) { [void]$checks.Add([ordered]@{ name = 'server'; status = 'ok'; detail = "healthy puerto=$($ep.port) via=$($ep.detection_method) version=$($h.version)" }) }
        else { [void]$checks.Add([ordered]@{ name = 'server'; status = 'warn'; detail = "puerto $($ep.port) responde pero no healthy (status $($h.status))" }) }
    } else {
        $ciDetail = if ($isCi) { 'server_unavailable_expected_ci' } else { 'server_unavailable' }
        [void]$checks.Add([ordered]@{ name = 'server'; status = 'warn'; detail = "${ciDetail}: $($ep.err) ($($ep.hint))"; expected_ci = $isCi })
    }

    # 6. consistencia
    try {
        $cons = Test-CrossConsistency
        if ($cons.ok -and $cons.warnings.Count -eq 0) { [void]$checks.Add([ordered]@{ name = 'consistencia'; status = 'ok'; detail = 'sin warnings ni errores' }) }
        elseif ($cons.ok) { [void]$checks.Add([ordered]@{ name = 'consistencia'; status = 'warn'; detail = "$($cons.warnings.Count) warning(s): $($cons.warnings -join '; ')" }) }
        else { [void]$checks.Add([ordered]@{ name = 'consistencia'; status = 'fail'; detail = "$($cons.errors.Count) error(es): $($cons.errors -join '; ')" }) }
    } catch {
        [void]$checks.Add([ordered]@{ name = 'consistencia'; status = 'warn'; detail = "no verificable: $_" })
    }

    $okCount = @($checks | Where-Object { $_.status -eq 'ok' }).Count
    $warnCount = @($checks | Where-Object { $_.status -eq 'warn' }).Count
    $failCount = @($checks | Where-Object { $_.status -eq 'fail' }).Count
    return @{
        ok       = ($failCount -eq 0)
        checks   = @($checks)
        summary  = @{ ok = $okCount; warn = $warnCount; fail = $failCount }
        error_count = $failCount
        warn_count  = $warnCount
    }
}

Export-ModuleMember -Function Get-CrossPoll, Get-CrossStatus, Get-CrossReconcile, Get-CrossAvisoSpof, Get-SessionState, Read-EscalatedLog, Read-DlqLog, Find-AuditOutcome, Get-CrossMetrics, Export-CrossMetrics, Get-PollDiagnostic, Get-CrossDoctorReport
