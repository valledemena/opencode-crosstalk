#!/usr/bin/env pwsh
# cross.ps1 - Cross-Talk protocol CLI (spec v0.2, Phase 1: transport)
# Subcommands: health, whoami, sessions, read, config
# Global flags: --json (default), --human, --quiet, --no-cache, --health-skip, --port, --password, --config

[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Command,
    [Parameter(Position=1, ValueFromRemainingArguments=$true)][string[]]$Argv
)

$ErrorActionPreference = 'Stop'
$MyRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModulePaths = @(
    (Join-Path $MyRoot 'lib\cross-format.psm1'),
    (Join-Path $MyRoot 'modules\cross-transport.psm1'),
    (Join-Path $MyRoot 'modules\cross-state.psm1'),
    (Join-Path $MyRoot 'modules\cross-delivery.psm1'),
    (Join-Path $MyRoot 'modules\cross-diagnostic.psm1'),
    (Join-Path $MyRoot 'modules\cross-action.psm1')
)
foreach ($mp in $ModulePaths) {
    if (-not (Test-Path -LiteralPath $mp)) {
        [Console]::Error.WriteLine((ConvertTo-Json @{ ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); ok = $false; code = 70; err = 'INTERNAL_ERROR'; detail = "module not found: $mp" } -Compress))
        exit 70
    }
    Import-Module $mp -Force -DisableNameChecking
}

$OutputMode = 'json'
$NoCache = $false
$HealthSkip = $false
$ConfigPath = ''
$PortArg = 0
$PasswordArg = ''
$Help = $false

$Command = $Command.Trim().ToLower()
$argsList = @($Argv)

$flags = [ordered]@{}
$positionals = New-Object System.Collections.ArrayList
$KnownFlags = @('json','human','quiet','no-cache','health-skip','port','password','config','help','directory','session','session-id','since','role','limit','get','set','list','msg','model','owner','force','state-file','outbox-file','text','dest','delivery','token','run-id','lease','sucesor','attempt','ack-timeout','max-attempts','no-wait','timeout','apply','quarantine','retry-auto','for','interval','check-file','expected-token','msg-id','agent','reason','note','for-msg-id','for-run-id','task','task-id','from','retries','flag','summary','check-log','minutes','to','log-path','by-agent','until','dry-run-sweep','prometheus','prometheus-output')

for ($i = 0; $i -lt $argsList.Count; $i++) {
    $arg = $argsList[$i]
    switch -Regex ($arg) {
        '^--json$' { $OutputMode = 'json'; break }
        '^--human$' { $OutputMode = 'human'; break }
        '^--quiet$' { $OutputMode = 'quiet'; break }
        '^--no-cache$' { $NoCache = $true; break }
        '^--health-skip$' { $HealthSkip = $true; break }
        '^--port=(.*)$' { $PortArg = [int]$Matches[1]; break }
        '^--port$' { $i++; $PortArg = [int]$argsList[$i]; break }
        '^--password=(.*)$' { $PasswordArg = $Matches[1]; break }
        '^--password$' { $i++; $PasswordArg = $argsList[$i]; break }
        '^--config=(.*)$' { $ConfigPath = $Matches[1]; break }
        '^--config$' { $i++; $ConfigPath = $argsList[$i]; break }
        '^--help$' { $Help = $true; break }
        '^-h$' { $Help = $true; break }
        '^--(delivery|directory|session|session-id|since|role|limit|get|set|msg|model|owner|state-file|outbox-file|text|dest|token|run-id|lease|sucesor|attempt|ack-timeout|timeout|max-attempts|for|interval|check-file|expected-token|msg-id|agent|reason|note|for-msg-id|for-run-id|task|task-id|from|retries|flag|summary|minutes|to|log-path|by-agent|until|prometheus-output)$' {
            $name = $Matches[1]
            if (($i + 1) -lt $argsList.Count) { $i++; $flags[$name] = $argsList[$i] }
            else { $flags[$name] = $true }
            break
        }
        '^--(delivery|directory|session|session-id|since|role|limit|get|set|msg|model|owner|state-file|outbox-file|text|dest|token|run-id|lease|sucesor|attempt|ack-timeout|timeout|max-attempts|for|interval|check-file|expected-token|msg-id|agent|reason|note|for-msg-id|for-run-id|task|task-id|from|retries|flag|summary|minutes|to|log-path|by-agent|until|prometheus-output)=(.+)$' {
            $name = $Matches[1]
            $flags[$name] = $Matches[2]
            break
        }
        '^--?[a-zA-Z\-]+=(.+)$' {
            $name = $Matches[0].Substring(2).Split('=')[0]
            $value = $Matches[0].Substring(2).Split('=')[1]
            if ($name -notin $KnownFlags) { [Console]::Error.WriteLine("WARN: unknown flag --$name") }
            $flags[$name] = $value
            break
        }
        '^--?[a-zA-Z\-]+$' {
            $name = $arg.TrimStart('-')
            if ($name -notin $KnownFlags) { [Console]::Error.WriteLine("WARN: unknown flag --$name") }
            $flags[$name] = $true
            break
        }
        default { [void]$positionals.Add($arg) }
    }
}

function Show-Usage {
    Write-Host @'
cross.ps1 - Cross-Talk protocol CLI (v0.2, Phase 2)

Usage:
  cross health    [--no-cache] [--health-skip]
  cross whoami
  cross sessions  [--directory <path>]
  cross read      --session ses_X [--limit 20] [--since ISO8601] [--role user|assistant]
  cross config    [--get <key>] [--set <key>=<value>] [--list]
  cross claim     --msg msg_X [--owner ses_Y] [--model M]
  cross release   --msg msg_X [--owner ses_Y] [--model M] [--force]
  cross done      --msg msg_X [--owner ses_Y] [--model M]
  cross validate  [--state-file PATH] [--outbox-file PATH]
  cross send      --msg msg_X --dest ses_Y --text "..." [--token T] [--run-id R]
                  [--ack-timeout S | --timeout S] [--max-attempts N] [--attempt N]
                  [--delivery steer|queue] [--no-wait] [--dry-run-sweep] [--outbox-file PATH]
  cross scan      [--outbox-file PATH] [--apply] [--quarantine]
                  [--retry-auto [--max-attempts N]]
  cross poll      --msg msg_X [--timeout S] [--interval MS] [--outbox-file PATH]
  cross status    [--msg msg_X] [--run-id R] [--agent ses_Y] [--outbox-file PATH]
                  [--state-file PATH]
  cross reconcile --msg msg_X --check-file PATH [--expected-token T] [--outbox-file PATH]
  cross aviso-spof [--apply] [--for ses_X] [--outbox-file PATH]
  cross ack --token T --for-msg-id X [--to ses_SENDER] [--model M]
  cross nack --token T --for-msg-id X --reason REASON [--note "..."] [--for-run-id R] [--to ses_SENDER] [--model M]
  cross resume --to ses_X --task-id TX [--from "checkpoint"] [--text "..."]
  cross restart-task --msg-id X [--to ses_Y] [--text "..."] [--max-attempts N] [--outbox-file PATH]
  cross nudge --to ses_X --task "..." [--token T]
  cross escalate --msg-id X --to ses_Y --reason "..." [--run-id R] [--apply]
  cross dlq --msg-id X [--to ses_Y] [--retries N] [--flag F] [--summary "..."] [--outbox-file PATH]
  cross quarantine --msg-id X --reason "..." [--check-log] [--outbox-file PATH]
  cross diagnose --msg X [--outbox-file PATH] [--sleep-threshold-sec N]
  cross metrics [--since ISO8601] [--until ISO8601] [--by-agent ses_Y] [--log-path PATH]
                [--json | --human]

Global flags:
  --json (default) | --human | --quiet
  --no-cache        force port re-detection
  --health-skip     skip /global/health check (tests)
  --port NNNNN      skip port detection
  --password PW     explicit password (prefer env)
  --config <path>   override cross.config.json path

claim/release/done operate on idempotencia-procesados.md (append-only).
validate runs consistency lint (outbox vs idempotencia, lease UTC).
send delivers a message via prompt and waits for a v2 JSON ACK/NACK (retries, lease).
  A --msg id with no outbox entry is auto-created (EN_VUELO) when --dest and --text are given;
  --token defaults to the msg id so the receiver can ACK with a stable token.
  --no-wait sends without waiting for ACK (fire-and-forget, outbox remains IN_FLIGHT).
  --ack-timeout 0 equals no ACK (requires_ack=false, outbox CONFIRMED); use --no-wait for the opposite.
  --delivery queue (default): a busy destination takes the message when idle (never derails
  a turn in progress). --delivery steer: a busy destination sees it at its next step
  boundary (may arrive mid-turn). Idle destinations start a turn either way (OpenAPI V2).
  NOTE: send ALWAYS runs an automatic sweep first (Invoke-CrossAutoSweep) that marks
  other expired outbox entries as EXPIRADO (reported as swept_expired/swept_count).
  Use --dry-run-sweep to preview what would be swept without mutating anything.
scan lists IN_FLIGHT outbox entries and marks expired ones by lease.
  --apply renews the lease for expired entries (A/B); --quarantine moves them to QUARANTINE.
  --retry-auto classifies each expired entry via diagnose and applies the appropriate action
    (PROVIDER_DOWN -> renew lease; AGENT_SLEEPING/NO_DATA -> restart-task;
    CONFIG_ERROR -> quarantine --check-log; NO_ERROR -> notify leader).
    Dry-run by default; combine with --apply to execute. Not blind automation:
    restart-task already validates MAX_RETRIES_EXCEEDED and reports it as 'failed'.
  Write failures (OUTBOX_LOCKED) are reported in the 'failed' field.
poll diagnoses an outbox msg (ACKED/NACKED/WORKING/QUIET/TERMINAL).
  --timeout S is the total loop deadline; --interval MS is the polling step.
status summarizes outbox + idempotencia + escalated + dlq at a glance.
reconcile checks whether a deliverable reached its destination by searching for its token in the check-file.
aviso-spof detects expired IN_FLIGHT entries; --apply emits AVISO-SPOF (dry-run by default).
ack emits a v2 JSON ACK to the sender's session (--to defaults to your own id).
  The port/password are auto-resolved when no --port is given (v2.1.1 fix).
nack emits a v2 JSON NACK with a closed reason (CAPACITY|TOOL_MISSING|AMBIGUOUS_TASK|PROVIDER_DOWN|OTHER).
whoami reports model from config/--model, or auto-detects it from the OpenCode API (model_source).
Paths in the config (whiteboard_dir, diario_dir, log_path) resolve against the config file, not the cwd.
resume sends a continuation instruction (does NOT create msg_id, does NOT increment attempt).
restart-task resends the task with the SAME msg_id (attempt+1; OUTBOX_MSG_NOT_FOUND/MAX_RETRIES_EXCEEDED).
nudge sends a firm prompt that ignores previous 'Continue' messages.
escalate writes URGENT to escalated.md (12.6); --apply sends wake-on-write to the destination.
dlq writes to dlq-messages.md (12.7) with a closed flag and marks outbox STATUS=DLQ.
quarantine writes DLQ with flag=HUMAN_REVIEW and marks outbox QUARANTINE; --check-log diagnoses via opencode.log (case 524).
diagnose reads opencode.log looking for the msg destination and classifies (PROVIDER_DOWN/AGENT_SLEEPING/CONFIG_ERROR).
metrics summarizes delivery_log.jsonl (ACK/NACK/TIMEOUT, latency P50/P95, retries,
  lease renewals, top NACK by reason). Filters --since/--until/--by-agent.
'@
}

if ($Help -or -not $Command) {
    Show-Usage
    exit 0
}

try {
    $config = Import-CrossConfig -ConfigPath $ConfigPath
} catch {
    $err = @{ ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); ok = $false; code = 64; err = 'CONFIG_ERROR'; detail = $_.Exception.Message }
    [Console]::WriteLine((ConvertTo-Json $err -Compress))
    exit 64
}

function Out-Result {
    param($Result, [string]$Cmd, [System.Diagnostics.Stopwatch]$Watch)
    if ($Watch) {
        $Watch.Stop()
        $Result['duration_ms'] = [math]::Round($Watch.Elapsed.TotalMilliseconds)
    }
    Write-OutResult -Result $Result -Mode $OutputMode -Cmd $Cmd
    if (-not $Result.ok) { exit $Result.code }
}

switch ($Command) {
    'health' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $ep = Resolve-CrossEndpoint -Port $PortArg -Password $PasswordArg -NoCache:$NoCache -HealthSkip:$HealthSkip
        if (-not $ep.ok) {
            $r = New-Result -Ok $false -Code $ep.code -Data @{ err = $ep.err; detail = $ep.detail; hint = $ep.hint } -Cmd 'health'
            Out-Result $r 'health' -Watch $watch
        }
        $h = Test-CrossHealthRaw -Port $ep.port -Password $ep.password
        $r = New-Result -Ok $true -Code 0 -Data @{ healthy = $true; version = $h.version; port = $ep.port; password_source = $ep.password_source; detection_method = $ep.detection_method } -Cmd 'health'
        Out-Result $r 'health' -Watch $watch
    }
    'whoami' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $sid = $config.my_session_id
        $model = $config.my_model
        $role = $config.my_role
        $source = 'config'
        $overrideSid = [string]$flags['session-id']
        $overrideModel = [string]$flags['model']
        $overrideRole = [string]$flags['role']
        if ($overrideSid) { $sid = $overrideSid; $source = 'override' }
        if ($overrideModel) { $model = $overrideModel; $source = 'override' }
        if ($overrideRole) { $role = $overrideRole; $source = 'override' }
        if (-not $sid) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'NO_IDENTITY'; detail = 'neither config nor env defines my_session_id. Edit cross.config.json (my_session_id/leader_session_id/my_model) or pass --session-id/--model/--role overrides.' } -Cmd 'whoami'
            Out-Result $r 'whoami' -Watch $watch
        }
        # v2.1.1: model is API-derivable. If neither config nor --model defines it,
        # ask the server (GET /session/:id -> model.id). No manual guessing.
        $modelSource = if ($overrideModel) { 'override' } elseif ($model) { 'config' } else { '' }
        if (-not $model) {
            $ep = Resolve-CrossEndpoint -Port $PortArg -Password $PasswordArg -NoCache:$NoCache -HealthSkip:$HealthSkip
            if ($ep.ok) {
                $st = Get-CrossSessionState -Id $sid -Port $ep.port -Password $ep.password
                if ($st.ok -and $st.model) { $model = $st.model; $modelSource = 'api' }
            }
        }
        $shared = $false
        if ($source -eq 'config' -and [string]$config.my_session_id -eq [string]$config.leader_session_id) {
            $shared = $true
        }
        $r = New-Result -Ok $true -Code 0 -Data @{ session_id = $sid; model = $model; model_source = $modelSource; role = $role; identity_source = $source; shared_config = $shared; protocol_version = $config.protocol_version } -Cmd 'whoami'
        Out-Result $r 'whoami' -Watch $watch
    }
    'sessions' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $ep = Resolve-CrossEndpoint -Port $PortArg -Password $PasswordArg -NoCache:$NoCache -HealthSkip:$HealthSkip
        if (-not $ep.ok) {
            $r = New-Result -Ok $false -Code $ep.code -Data @{ err = $ep.err; detail = $ep.detail; hint = $ep.hint } -Cmd 'sessions'
            Out-Result $r 'sessions' -Watch $watch
        }
        $api = Invoke-CrossApi -Method 'GET' -Path '/api/session' -Port $ep.port -Password $ep.password
        if ($api.status -ge 400) {
            $errName = if ($api.status -ge 500) { 'HTTP_5XX' } elseif ($api.status -eq 401) { 'AUTH_FAILED' } elseif ($api.status -eq 404) { 'NOT_FOUND' } else { 'HTTP_4XX' }
            $r = New-Result -Ok $false -Code 3 -Data @{ err = $errName; detail = "GET /session -> HTTP $($api.status)"; http_status = $api.status } -Cmd 'sessions'
            Out-Result $r 'sessions' -Watch $watch
        }
        $dirFilter = ''
        if ($flags['directory']) { $dirFilter = [string]$flags['directory'] }
        $parsed = $api.body | ConvertFrom-Json
        $all = if ($parsed.data) { $parsed.data } elseif ($parsed -is [array]) { $parsed } else { @($parsed) }
        $list = @()
        foreach ($s in $all) {
            $dir = if ($s.location -and $s.location.directory) { $s.location.directory } else { $s.directory }
            if ($dirFilter -and $dir -and -not ($dir -eq $dirFilter)) { continue }
            $list += @{ id = $s.id; title = $s.title; model = if ($s.model.id) { $s.model.id } else { '' }; directory = $dir }
        }
        $r = New-Result -Ok $true -Code 0 -Data @{ count = $list.Count; sessions = $list } -Cmd 'sessions'
        Out-Result $r 'sessions' -Watch $watch
    }
    'read' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $session = [string]$flags['session']
        if (-not $session) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --session ses_X' } -Cmd 'read'
            Out-Result $r 'read' -Watch $watch
        }
        $ep = Resolve-CrossEndpoint -Port $PortArg -Password $PasswordArg -NoCache:$NoCache -HealthSkip:$HealthSkip
        if (-not $ep.ok) {
            $r = New-Result -Ok $false -Code $ep.code -Data @{ err = $ep.err; detail = $ep.detail; hint = $ep.hint } -Cmd 'read'
            Out-Result $r 'read' -Watch $watch
        }
        $api = Invoke-CrossApi -Method 'GET' -Path "/api/session/$session/message" -Port $ep.port -Password $ep.password
        if ($api.status -ge 400) {
            $errName = if ($api.status -ge 500) { 'HTTP_5XX' } elseif ($api.status -eq 401) { 'AUTH_FAILED' } elseif ($api.status -eq 404) { 'NOT_FOUND' } else { 'HTTP_4XX' }
            $code = if ($api.status -eq 404) { 64 } else { 3 }
            $r = New-Result -Ok $false -Code $code -Data @{ err = $errName; detail = "GET message -> HTTP $($api.status)"; http_status = $api.status } -Cmd 'read'
            Out-Result $r 'read' -Watch $watch
        }
        $all = $api.body
        $limit = 20; if ($flags['limit']) { $limit = [int]$flags['limit'] }
        $since = ''; if ($flags['since']) { $since = [string]$flags['since'] }
        $roleFilter = ''; if ($flags['role']) { $roleFilter = [string]$flags['role'] }
        # V2 shape {"data":[...]} (type/text/content) / V1 array (info/parts),
        # normalized to id/role/time(ISO)/text, oldest-first.
        $msgs = @()
        foreach ($m in (ConvertFrom-CrossMessageList -Body $all)) {
            if ($roleFilter -and $m.role -and ($m.role.ToLower() -ne $roleFilter.ToLower())) { continue }
            if ($since -and $m.time -and $m.time -lt $since) { continue }
            $msgs += @{ id = $m.id; role = $m.role; time = $m.time; text = $m.text }
        }
        if ($msgs.Count -gt $limit) { $msgs = @($msgs | Select-Object -Last $limit) }
        $r = New-Result -Ok $true -Code 0 -Data @{ session = $session; count = $msgs.Count; messages = @($msgs) } -Cmd 'read'
        Out-Result $r 'read' -Watch $watch
    }
    'config' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($flags.Contains('get')) {
            $key = [string]$flags['get']
            $value = $config.$key
            if ($null -eq $value) {
                $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = "key does not exist: $key" } -Cmd 'config'
                Out-Result $r 'config' -Watch $watch
                return
            }
            $r = New-Result -Ok $true -Code 0 -Data @{ key = $key; value = $value } -Cmd 'config'
            Out-Result $r 'config' -Watch $watch
            return
        }
        if ($flags.Contains('set')) {
            $kv = [string]$flags['set']
            if ($kv -notmatch '^(.+?)=(.+)$') {
                $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'format: --set key=value' } -Cmd 'config'
                Out-Result $r 'config' -Watch $watch
                return
            }
            $key = $Matches[1]; $value = $Matches[2]
            $configPath = if ($ConfigPath) { [System.IO.Path]::GetFullPath($ConfigPath) } else { Join-Path $MyRoot 'cross.config.json' }
            $current = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $obj = [ordered]@{}
            foreach ($p in $current.PSObject.Properties) { $obj[$p.Name] = $p.Value }
            $currentValue = $null
            if ($obj.Contains($key)) { $currentValue = $obj[$key] }
            if ($currentValue -is [int] -or $currentValue -is [long]) {
                $parsed = 0
                if ([long]::TryParse($value, [ref]$parsed)) { $value = [int]$parsed }
                else {
                    $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = "non-numeric value for int key: $key=$value" } -Cmd 'config'
                    Out-Result $r 'config' -Watch $watch; return
                }
            }
            elseif ($currentValue -is [bool]) {
                if ($value -in @('true','1','yes')) { $value = $true }
                elseif ($value -in @('false','0','no')) { $value = $false }
                else {
                    $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = "non-boolean value for ${key}: $value" } -Cmd 'config'
                    Out-Result $r 'config' -Watch $watch; return
                }
            }
            elseif ($currentValue -is [array]) {
                $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = "cannot set array via CLI: $key" } -Cmd 'config'
                Out-Result $r 'config' -Watch $watch; return
            }
            $validators = @{
                my_session_id = { param($v) $v -match '^ses_' }
                default_ack_timeout_s = { param($v) $v -is [int] -and $v -ge 30 -and $v -le 600 }
                default_lease_minutes = { param($v) $v -is [int] -and $v -ge 1 -and $v -le 30 }
                max_retries = { param($v) $v -is [int] -and $v -ge 0 -and $v -le 5 }
                max_saltos = { param($v) $v -is [int] -and $v -ge 0 -and $v -le 5 }
                protocol_version = { param($v) $v -eq '1.6.1' }
            }
            if ($validators.ContainsKey($key)) {
                $valid = & $validators[$key] $value
                if (-not $valid) {
                    if ($key -eq 'protocol_version') {
                        [Console]::Error.WriteLine("WARN: protocol_version=$value (recommended 1.6.1)")
                    } else {
                        $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = "invalid value for ${key}: $value" } -Cmd 'config'
                        Out-Result $r 'config' -Watch $watch; return
                    }
                }
            }
            $obj[$key] = $value
            $json = [pscustomobject]$obj | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($configPath, (ConvertTo-AsciiSafe $json), (New-Object System.Text.UTF8Encoding($false)))
            $r = New-Result -Ok $true -Code 0 -Data @{ key = $key; value = $value; written = $true } -Cmd 'config'
            Out-Result $r 'config' -Watch $watch
            return
        }
        $r = New-Result -Ok $true -Code 0 -Data @{ config = $config } -Cmd 'config'
        Out-Result $r 'config' -Watch $watch
    }
    'claim' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $msg = [string]$flags['msg']
        if (-not $msg) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --msg msg_id' } -Cmd 'claim'
            Out-Result $r 'claim' -Watch $watch
        }
        $owner = if ($flags['owner']) { [string]$flags['owner'] } else { [string]$config.my_session_id }
        $model = if ($flags['model']) { [string]$flags['model'] } else { [string]$config.my_model }
        $stateFile = [string]$flags['state-file']
        $res = New-CrossClaim -MsgId $msg -Modelo $model -Owner $owner -Path $stateFile
        if (-not $res.ok) {
            $r = New-Result -Ok $false -Code 2 -Data @{ err = $res.err; detail = $res.detail; msg_id = $msg; owner = $owner } -Cmd 'claim'
            Out-Result $r 'claim' -Watch $watch
        }
        $r = New-Result -Ok $true -Code 0 -Data @{ msg_id = $msg; owner = $owner; state = "CLAIMED_BY=$owner"; already = $res.already } -Cmd 'claim'
        Out-Result $r 'claim' -Watch $watch
    }
    'release' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $msg = [string]$flags['msg']
        if (-not $msg) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --msg msg_id' } -Cmd 'release'
            Out-Result $r 'release' -Watch $watch
        }
        $owner = if ($flags['owner']) { [string]$flags['owner'] } else { [string]$config.my_session_id }
        $model = if ($flags['model']) { [string]$flags['model'] } else { [string]$config.my_model }
        $force = [bool]$flags['force']
        $stateFile = [string]$flags['state-file']
        $res = New-CrossRelease -MsgId $msg -Modelo $model -Owner $owner -Force:$force -Path $stateFile
        if (-not $res.ok) {
            $r = New-Result -Ok $false -Code 2 -Data @{ err = $res.err; detail = $res.detail; msg_id = $msg; owner = $owner } -Cmd 'release'
            Out-Result $r 'release' -Watch $watch
        }
        $r = New-Result -Ok $true -Code 0 -Data @{ msg_id = $msg; owner = $owner; state = "SUPERSEDED_BY=$owner"; already = $res.already } -Cmd 'release'
        Out-Result $r 'release' -Watch $watch
    }
    'done' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $msg = [string]$flags['msg']
        if (-not $msg) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --msg msg_id' } -Cmd 'done'
            Out-Result $r 'done' -Watch $watch
        }
        $owner = if ($flags['owner']) { [string]$flags['owner'] } else { [string]$config.my_session_id }
        $model = if ($flags['model']) { [string]$flags['model'] } else { [string]$config.my_model }
        $stateFile = [string]$flags['state-file']
        $res = New-CrossDone -MsgId $msg -Modelo $model -Owner $owner -Path $stateFile
        if (-not $res.ok) {
            $r = New-Result -Ok $false -Code 2 -Data @{ err = $res.err; detail = $res.detail; msg_id = $msg; owner = $owner } -Cmd 'done'
            Out-Result $r 'done' -Watch $watch
        }
        $r = New-Result -Ok $true -Code 0 -Data @{ msg_id = $msg; owner = $owner; state = 'PROCESADO'; already = $res.already } -Cmd 'done'
        Out-Result $r 'done' -Watch $watch
    }
    'validate' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $stateFile = [string]$flags['state-file']
        $outboxFile = [string]$flags['outbox-file']
        $v = Test-CrossConsistency -StatePath $stateFile -OutboxPath $outboxFile
        $r = New-Result -Ok $v.ok -Code $(if ($v.ok) { 0 } else { 2 }) -Data @{ warnings = $v.warnings; errors = $v.errors; warning_count = $v.warnings.Count; error_count = $v.errors.Count } -Cmd 'validate'
        Out-Result $r 'validate' -Watch $watch
    }
    'doctor' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $d = Get-CrossDoctorReport -ConfigPath $ConfigPath
        $r = New-Result -Ok $d.ok -Code $(if ($d.ok) { 0 } else { 2 }) -Data @{ checks = $d.checks; summary = $d.summary; error_count = $d.error_count; warn_count = $d.warn_count } -Cmd 'doctor'
        Out-Result $r 'doctor' -Watch $watch
    }
    'send' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $msg = [string]$flags['msg']
        $text = if ($flags['text']) { [string]$flags['text'] } else { '' }
        $autoCreated = $false
        if (-not $msg) {
            if (-not $text) {
                $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --msg msg_id or --text' } -Cmd 'send'
                Out-Result $r 'send' -Watch $watch
                return
            }
            # Fast Send: Auto-generate ID and add to outbox if --msg is missing but --text is present
            $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
            $rand = -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
            $msg = "msg_cli_$ts-$rand"
            
            $dest = if ($flags['dest']) { [string]$flags['dest'] } else { '' }
            if (-not $dest) {
                $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --dest for fast send' } -Cmd 'send'
                Out-Result $r 'send' -Watch $watch
                return
            }
            
            $token = if ($flags['token']) { [string]$flags['token'] } else { '' }
            $runId = if ($flags['run-id']) { [string]$flags['run-id'] } else { '' }
            $lease = if ($flags['lease']) { [string]$flags['lease'] } else { '' }
            $sucesor = if ($flags['sucesor']) { [string]$flags['sucesor'] } else { '' }
            
            $outboxFile = [string]$flags['outbox-file']
            $addRes = Add-OutboxEntry -MsgId $msg -Dest $dest -RunId $runId -Token $token -Lease $lease -Sucesor $sucesor -Path $outboxFile
            if (-not $addRes.ok) {
                $r = New-Result -Ok $false -Code 2 -Data @{ err = $addRes.err; detail = $addRes.detail } -Cmd 'send'
                Out-Result $r 'send' -Watch $watch
                return
            }
        } else {
            $outboxFile = [string]$flags['outbox-file']
            $entry = Get-OutboxEntry -MsgId $msg -Path $outboxFile
            # v2.1.1: an explicit --msg with --dest/--text auto-creates its outbox
            # entry (EN_VUELO). Before, a typo/new id made send fail with
            # OUTBOX_MSG_NOT_FOUND even though delivery was perfectly possible.
            if (-not $entry -and $flags['dest'] -and $text) {
                $newToken = if ($flags['token']) { [string]$flags['token'] } else { $msg }
                $addRes = Add-OutboxEntry -MsgId $msg -Dest ([string]$flags['dest']) `
                    -RunId ([string]$flags['run-id']) -Token $newToken `
                    -Lease ([string]$flags['lease']) -Sucesor ([string]$flags['sucesor']) -Path $outboxFile
                if (-not $addRes.ok) {
                    $r = New-Result -Ok $false -Code 2 -Data @{ err = $addRes.err; detail = $addRes.detail } -Cmd 'send'
                    Out-Result $r 'send' -Watch $watch
                    return
                }
                $autoCreated = $true
                $entry = Get-OutboxEntry -MsgId $msg -Path $outboxFile
            }
            if (-not $entry) {
                $r = New-Result -Ok $false -Code 64 -Data @{ err = 'OUTBOX_MSG_NOT_FOUND'; detail = "no outbox entry found for $msg (pass --dest and --text to auto-create it)" } -Cmd 'send'
                Out-Result $r 'send' -Watch $watch
                return
            }
            if ($entry.estado -eq 'CONFIRMADO') {
                $r = New-Result -Ok $true -Code 0 -Data @{ msg_id = $msg; outbox_state = 'CONFIRMADO'; already = $true; detail = 'already delivered' } -Cmd 'send'
                Out-Result $r 'send' -Watch $watch
                return
            }
            if ($entry.estado -ne 'EN_VUELO') {
                $r = New-Result -Ok $false -Code 2 -Data @{ err = 'ESTADO_INVALIDO'; detail = "outbox=$($entry.estado) (expected EN_VUELO)"; msg_id = $msg; outbox_state = $entry.estado } -Cmd 'send'
                Out-Result $r 'send' -Watch $watch
                return
            }
            $dest = if ($flags['dest']) { [string]$flags['dest'] } else { [string]$entry.dest }
            $token = if ($flags['token']) { [string]$flags['token'] } else { [string]$entry.token }
            $runId = if ($flags['run-id']) { [string]$flags['run-id'] } else { [string]$entry.run_id }
            $lease = if ($flags['lease']) { [string]$flags['lease'] } else { [string]$entry.lease }
            $sucesor = if ($flags['sucesor']) { [string]$flags['sucesor'] } else { [string]$entry.sucesor }
        }

        if (-not $dest) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --dest ses_Y' } -Cmd 'send'
            Out-Result $r 'send' -Watch $watch
            return
        }
        if (-not $text) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --text (message body)' } -Cmd 'send'
            Out-Result $r 'send' -Watch $watch
            return
        }
        $reqAck = $true
        $outboxFile = [string]$flags['outbox-file']
        $entry = Get-OutboxEntry -MsgId $msg -Path $outboxFile
        if ($entry -and $entry.requiere_ack -and $entry.requiere_ack.ToLower() -eq 'false') { $reqAck = $false }
        if ($flags['ack-timeout'] -and [int]$flags['ack-timeout'] -eq 0) { $reqAck = $false }
        if ($flags['timeout'] -and [int]$flags['timeout'] -eq 0) { $reqAck = $false }
        $ackTimeout = 0
        if ($flags['ack-timeout']) { $ackTimeout = [int]$flags['ack-timeout'] }
        elseif ($flags['timeout']) { $ackTimeout = [int]$flags['timeout'] }
        else { $ackTimeout = [int]$config.default_ack_timeout_s }
        $maxAttempts = if ($flags['max-attempts']) { [int]$flags['max-attempts'] } else { [int]$config.max_retries }
        $attempt = if ($flags['attempt']) { [int]$flags['attempt'] } else { if ($entry) { [int]$entry.attempt } else { 0 } }
        $backoffSec = if ($config.retry_backoff_s) { [int]$config.retry_backoff_s } else { 2 }
        $delivery = if ($flags['delivery']) { [string]$flags['delivery'] } else { '' }
        $sweep = Invoke-CrossAutoSweep -Path $outboxFile -ExcludeMsgId $msg -LeaseMinutes $config.default_lease_minutes -DryRun:([bool]$flags['dry-run-sweep'])
        $res = New-CrossDelivery -MsgId $msg -Dest $dest -Text $text -RunId $runId -Token $token -Lease $lease -Sucesor $sucesor -Delivery $delivery -RequiereAck:$reqAck -OutboxPath $outboxFile -AckTimeoutSec $ackTimeout -MaxAttempts $maxAttempts -InitialAttempt $attempt -BackoffSec $backoffSec -NoWait:([bool]$flags['no-wait']) -Port $PortArg -Password $PasswordArg -NoCache:$NoCache -HealthSkip:$HealthSkip
        $warnings = @()
        if ($res.ack -and $res.ack_id -and $dest -and ([string]$res.ack_id -ne [string]$dest)) {
            $warnings += 'ACK_EMITTER_MISMATCH: ACK emitter differs from destination. Shared cross.config.local.json? Set CROSS_MY_MY_SESSION_ID/CROSS_MY_MY_MODEL on the receiver.'
        }
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 2 }) -Data @{
            msg_id = $msg; dest = $dest; outbox_state = $res.state; attempt = $res.attempt
            auto_created = $autoCreated; warnings = $warnings
            err = $res.err; detail = $res.detail; ack = $res.ack; ack_id = $res.ack_id; ack_model = $res.ack_model
            reason = $res.reason; reason_code = $res.reason_code; http_status = $res.http_status; session_growing = $res.session_growing
            ack_latency_ms = $res.ack_latency_ms; no_wait = $res.no_wait
            swept_expired = $sweep.swept; swept_count = $sweep.swept.Count
        } -Cmd 'send'
        $logData = @{
            state = $res.state; ok = $res.ok; err = $res.err; reason_code = $res.reason_code
            attempt = $res.attempt; http_status = $res.http_status; ack = $res.ack
            ack_id = $res.ack_id; ack_model = $res.ack_model; reason = $res.reason
            ack_latency_ms = $res.ack_latency_ms; session_growing = $res.session_growing
        }
        [void](Write-CrossDeliveryLog -MsgId $msg -Dest $dest -Token $token -Result $logData -Detail $($r.detail))
        Out-Result $r 'send' -Watch $watch
    }
    'scan' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $outboxFile = [string]$flags['outbox-file']
        $pending = @(Find-CrossOutboxPending -Path $outboxFile)
        $vencidos = @($pending | Where-Object { $_.vencido })
        if ($flags['retry-auto']) {
            $maxAttempts = if ($flags['max-attempts']) { [int]$flags['max-attempts'] } else { 0 }
            $applyRetry = [bool]$flags['apply']
            $plan = New-Object System.Collections.ArrayList
            foreach ($e in $vencidos) {
                $diag = Get-CrossDiagnose -Msg ([string]$e.msg_id) -OutboxPath $outboxFile
                $classification = if ($diag.ok) { [string]$diag.classification } else { 'NO_DATA' }
                $action = 'NO_ACTION'
                if ($classification -eq 'PROVIDER_DOWN') { $action = 'RENEW_LEASE' }
                elseif ($classification -eq 'AGENT_SLEEPING' -or $classification -eq 'NO_DATA') { $action = 'RESTART_TASK' }
                elseif ($classification -eq 'CONFIG_ERROR') { $action = 'QUARANTINE' }
                elseif ($classification -eq 'NO_ERROR') { $action = 'NOTIFY_LEADER' }
                $executed = $false
                $err = ''
                if ($applyRetry) {
                    if ($action -eq 'RENEW_LEASE') {
                        $ar = Renew-CrossLease -MsgId $e.msg_id -Path $outboxFile -Minutes $config.default_lease_minutes
                        if ($ar.ok) { $executed = $true } else { $err = $ar.err }
                    } elseif ($action -eq 'RESTART_TASK') {
                        $rr = Restart-CrossTask -MsgId $e.msg_id -OutboxPath $outboxFile -MaxAttempts $maxAttempts -Port $PortArg -Password $PasswordArg
                        if ($rr.ok) { $executed = $true }
                        elseif ($rr.err -eq 'MAX_RETRIES_EXCEEDED') { $err = "MAX_RETRIES_EXCEEDED (attempt=$($rr.attempt)); requires manual QUARANTINE, do not retry in loop" }
                        else { $err = $rr.err }
                    } elseif ($action -eq 'QUARANTINE') {
                        $qr = Set-CrossQuarantine -MsgId $e.msg_id -Reason "scan --retry-auto: CONFIG_ERROR" -OutboxPath $outboxFile -CheckLog
                        if ($qr.ok) { $executed = $true } else { $err = $qr.err }
                    } elseif ($action -eq 'NOTIFY_LEADER') {
                        $nl = Write-CrossEscalated -MsgId $e.msg_id -To ([string]$config.leader_session_id) -Reason "scan --retry-auto: no errors in window, check ACK/escalation" -RunId ([string]$e.run_id)
                        if ($nl.ok) { $executed = $true } else { $err = $nl.err }
                    }
                }
                [void]$plan.Add([ordered]@{
                    msg_id = $e.msg_id; dest = $e.dest; classification = $classification; action = $action
                    dry_run = (-not $applyRetry); executed = $executed; err = $err
                })
            }
            $r = New-Result -Ok $true -Code 0 -Data @{
                count = $pending.Count; vencidos = $vencidos.Count; retry_auto = $true
                dry_run = (-not $applyRetry); plan = @($plan)
            } -Cmd 'scan'
            Out-Result $r 'scan' -Watch $watch
            break
        }
        $applied = New-Object System.Collections.ArrayList
        $quarantined = New-Object System.Collections.ArrayList
        $failed = New-Object System.Collections.ArrayList
        if ($flags['quarantine']) {
            foreach ($e in $vencidos) {
                $qr = Set-OutboxEstado -MsgId $e.msg_id -Estado 'QUARANTINE' -Path $outboxFile
                if ($qr.ok) { [void]$quarantined.Add($e.msg_id) }
                else { [void]$failed.Add([ordered]@{ msg_id = $e.msg_id; op = 'quarantine'; err = $qr.err }) }
            }
        } elseif ($flags['apply']) {
            foreach ($e in $vencidos) {
                $ar = Renew-CrossLease -MsgId $e.msg_id -Path $outboxFile -Minutes $config.default_lease_minutes
                if ($ar.ok) { [void]$applied.Add($e.msg_id) }
                else { [void]$failed.Add([ordered]@{ msg_id = $e.msg_id; op = 'apply'; err = $ar.err }) }
            }
        }
        $r = New-Result -Ok $true -Code 0 -Data @{
            count = $pending.Count; vencidos = $vencidos.Count; applied = @($applied); quarantined = @($quarantined); failed = @($failed); pending = @($pending)
        } -Cmd 'scan'
        Out-Result $r 'scan' -Watch $watch
    }
    'poll' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $msgId = if ($flags['msg-id']) { [string]$flags['msg-id'] } else { [string]$flags['msg'] }
        if (-not $msgId) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --msg msg_id' } -Cmd 'poll'
            Out-Result $r 'poll' -Watch $watch
        }
        $timeoutSec = if ($flags['timeout']) { [int]$flags['timeout'] } else { [int]$config.default_ack_timeout_s }
        $intervalMs = if ($flags['interval']) { [int]$flags['interval'] } else { 3000 }
        $waitMs = if ($config.session_growing_check_ms) { [int]$config.session_growing_check_ms } else { 15000 }
        $res = Get-CrossPoll -MsgId $msgId -OutboxPath ([string]$flags['outbox-file']) -TimeoutSec $timeoutSec -IntervalMs $intervalMs -WaitMs $waitMs -Port $PortArg -Password $PasswordArg
        if (-not $res.ok) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = $res.err; detail = $res.detail; diagnostic = $res.diagnostic; action = $res.action } -Cmd 'poll'
            Out-Result $r 'poll' -Watch $watch
        }
        $r = New-Result -Ok $true -Code 0 -Data @{
            msg_id = $res.msg_id; dest = $res.dest; outbox_state = $res.outbox_state
            diagnostic = $res.diagnostic; action = $res.action; confidence = $res.confidence
            session_status = $res.session_status; session_growing = $res.session_growing
            nack_reason = $res.nack_reason; lease_expired = $res.lease_expired
        } -Cmd 'poll'
        Out-Result $r 'poll' -Watch $watch
    }
    'status' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $waitMs = if ($config.session_growing_check_ms) { [int]$config.session_growing_check_ms } else { 15000 }
        $res = Get-CrossStatus -MsgId ([string]$flags['msg-id']) -RunId ([string]$flags['run-id']) -Agent ([string]$flags['agent']) -OutboxPath ([string]$flags['outbox-file']) -StatePath ([string]$flags['state-file']) -Port $PortArg -Password $PasswordArg -WaitMs $waitMs
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            outbox_by_state = $res.outbox_by_state; outbox_by_agent = $res.outbox_by_agent
            expired_unmanaged = $res.expired_unmanaged; idempotencia_by_state = $res.idempotencia_by_state
            claimed_orphaned = $res.claimed_orphaned; escalated_pending = $res.escalated_pending
            aviso_spof = $res.aviso_spof; dlq_unread = $res.dlq_unread; dlq_by_flag = $res.dlq_by_flag
            lifecycle = $res.lifecycle
        } -Cmd 'status'
        Out-Result $r 'status' -Watch $watch
    }
    'reconcile' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $msgId = if ($flags['msg-id']) { [string]$flags['msg-id'] } else { [string]$flags['msg'] }
        $checkFile = [string]$flags['check-file']
        if (-not $msgId -or -not $checkFile) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = 'missing --msg msg_id and --check-file PATH' } -Cmd 'reconcile'
            Out-Result $r 'reconcile' -Watch $watch
        }
        $res = Get-CrossReconcile -MsgId $msgId -CheckFile $checkFile -ExpectedToken ([string]$flags['expected-token']) -OutboxPath ([string]$flags['outbox-file'])
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            msg_id = $res.msg_id; check_file = $res.check_file; expected_token = $res.expected_token
            verdict = $res.verdict; recommendation = $res.recommendation; file = $res.file
        } -Cmd 'reconcile'
        Out-Result $r 'reconcile' -Watch $watch
    }
    'aviso-spof' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $waitMs = if ($config.session_growing_check_ms) { [int]$config.session_growing_check_ms } else { 15000 }
        $res = Get-CrossAvisoSpof -OutboxPath ([string]$flags['outbox-file']) -MySessionId ([string]$flags['for']) -Apply:([bool]$flags['apply']) -Port $PortArg -Password $PasswordArg -WaitMs $waitMs
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            vencidos = $res.vencidos; dry_run = $res.dry_run; results = $res.results
            written = $res.written; notified = $res.notified
        } -Cmd 'aviso-spof'
        Out-Result $r 'aviso-spof' -Watch $watch
    }
    'ack' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Send-CrossAck -Token ([string]$flags['token']) -ForMsgId ([string]$flags['for-msg-id']) -Dest ([string]$flags['to']) -Model ([string]$flags['model']) -Port $PortArg -Password $PasswordArg
        $warnings = @()
        if ($res.ok -and $res.ack_text -and $res.to) {
            try {
                $pe = Parse-CrossEnvelope ([string]$res.ack_text)
                if ($pe.valid -and $pe.emitter -and ([string]$pe.emitter -eq [string]$res.to)) {
                    $warnings += 'SELF_ACK: the envelope emitter equals the destination. You are probably sharing cross.config.local.json; set CROSS_MY_MY_SESSION_ID/CROSS_MY_MY_MODEL.'
                }
            } catch { }
        }
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            ack_text = $res.ack_text; segments = $res.segments; to = $res.to; sent = $res.sent; warnings = $warnings
            err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'ack'
        Out-Result $r 'ack' -Watch $watch
    }
    'nack' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Send-CrossNack -Token ([string]$flags['token']) -ForMsgId ([string]$flags['for-msg-id']) -Reason ([string]$flags['reason']) -Note ([string]$flags['note']) -ForRunId ([string]$flags['for-run-id']) -Dest ([string]$flags['to']) -Model ([string]$flags['model']) -Port $PortArg -Password $PasswordArg
        $warnings = @()
        if ($res.ok -and $res.nack_text -and $res.to) {
            try {
                $pn = Parse-CrossEnvelope ([string]$res.nack_text)
                if ($pn.valid -and $pn.emitter -and ([string]$pn.emitter -eq [string]$res.to)) {
                    $warnings += 'SELF_ACK: the envelope emitter equals the destination. You are probably sharing cross.config.local.json; set CROSS_MY_MY_SESSION_ID/CROSS_MY_MY_MODEL.'
                }
            } catch { }
        }
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            nack_text = $res.nack_text; segments = $res.segments; to = $res.to; reason = $res.reason
            sent = $res.sent; warnings = $warnings; err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'nack'
        Out-Result $r 'nack' -Watch $watch
    }
    'resume' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Send-CrossResume -To ([string]$flags['to']) -TaskId ([string]$flags['task-id']) -From ([string]$flags['from']) -Text ([string]$flags['text']) -Port $PortArg -Password $PasswordArg
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            to = $res.to; task_id = $res.task_id; from = $res.from; prompt = $res.prompt
            new_msg_id = $res.new_msg_id; sent = $res.sent; err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'resume'
        Out-Result $r 'resume' -Watch $watch
    }
    'restart-task' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Restart-CrossTask -MsgId ([string]$flags['msg-id']) -To ([string]$flags['to']) -Text ([string]$flags['text']) -MaxAttempts $([int]$flags['max-attempts']) -OutboxPath ([string]$flags['outbox-file']) -Port $PortArg -Password $PasswordArg
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            msg_id = $res.msg_id; dest = $res.dest; attempt = $res.attempt; same_msg_id = $res.same_msg_id
            sent = $res.sent; err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'restart-task'
        Out-Result $r 'restart-task' -Watch $watch
    }
    'nudge' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Send-CrossNudge -To ([string]$flags['to']) -Task ([string]$flags['task']) -Token ([string]$flags['token']) -Port $PortArg -Password $PasswordArg
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            to = $res.to; task = $res.task; prompt = $res.prompt; sent = $res.sent
            err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'nudge'
        Out-Result $r 'nudge' -Watch $watch
    }
    'escalate' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Write-CrossEscalated -MsgId ([string]$flags['msg-id']) -To ([string]$flags['to']) -Reason ([string]$flags['reason']) -RunId ([string]$flags['run-id']) -Apply:([bool]$flags['apply']) -Port $PortArg -Password $PasswordArg
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            msg_id = $res.msg_id; para = $res.para; line = $res.line; written = $res.written
            notified = $res.notified; err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'escalate'
        Out-Result $r 'escalate' -Watch $watch
    }
    'dlq' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Write-CrossDlq -MsgId ([string]$flags['msg-id']) -To ([string]$flags['to']) -Retries ([string]$flags['retries']) -Flag ([string]$flags['flag']) -Summary ([string]$flags['summary']) -OutboxPath ([string]$flags['outbox-file'])
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            msg_id = $res.msg_id; line = $res.line; written = $res.written; outbox_marked = $res.outbox_marked
            err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'dlq'
        Out-Result $r 'dlq' -Watch $watch
    }
    'quarantine' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Set-CrossQuarantine -MsgId ([string]$flags['msg-id']) -Reason ([string]$flags['reason']) -OutboxPath ([string]$flags['outbox-file']) -CheckLog:([bool]$flags['check-log'])
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            msg_id = $res.msg_id; quarantine = $res.quarantine; dlq_written = $res.dlq_written
            log_diagnostic = $res.log_diagnostic; err = $res.err; detail = $res.detail; audit_ok = $res.audit_ok
        } -Cmd 'quarantine'
        Out-Result $r 'quarantine' -Watch $watch
    }
    'diagnose' {
        # D2 (v1.17): structured API-first diagnosis (no third-party log scraping)
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $sleepSec = if ($flags['sleep-threshold-sec']) { [int]$flags['sleep-threshold-sec'] } else { 300 }
        $res = Get-CrossDiagnose -Msg ([string]$flags['msg']) -OutboxPath ([string]$flags['outbox-file']) -SleepThresholdSec $sleepSec
        $r = New-Result -Ok $res.ok -Code $(if ($res.ok) { 0 } else { 64 }) -Data @{
            msg = $res.msg; dest = $res.dest; classification = $res.classification
            action = $res.action; source = $res.source; session_status = $res.session_status
            idle_seconds = $res.idle_seconds; detail = $res.detail; err = $res.err
        } -Cmd 'diagnose'
        Out-Result $r 'diagnose' -Watch $watch
    }
    'metrics' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($flags['prometheus']) {
            $res = Export-CrossMetrics -Since ([string]$flags['since']) -Until ([string]$flags['until']) -ByAgent ([string]$flags['by-agent']) -LogPath ([string]$flags['log-path']) -OutputPath ([string]$flags['prometheus-output']) -OutboxPath ([string]$flags['outbox-file'])
            if (-not $res.ok) {
                $r = New-Result -Ok $false -Code 64 -Data @{ err = $res.err; detail = $res.detail } -Cmd 'metrics'
                Out-Result $r 'metrics' -Watch $watch
            }
            if ($res.output) {
                $r = New-Result -Ok $true -Code 0 -Data @{ prometheus_file = $res.output; lines = $res.lines; source = $res.source; log_path = $res.log_path } -Cmd 'metrics'
                Out-Result $r 'metrics' -Watch $watch
            }
            [Console]::Write($res.text)
            exit 0
        }
        $res = Get-CrossMetrics -Since ([string]$flags['since']) -Until ([string]$flags['until']) -ByAgent ([string]$flags['by-agent']) -LogPath ([string]$flags['log-path'])
        if (-not $res.ok) {
            $r = New-Result -Ok $false -Code 64 -Data @{ err = $res.err; detail = $res.detail } -Cmd 'metrics'
            Out-Result $r 'metrics' -Watch $watch
        }
        $r = New-Result -Ok $true -Code 0 -Data @{
            source = $res.source; log_path = $res.log_path; total = $res.total
            by_outcome = $res.by_outcome; rates = $res.rates
            latency_p50_ms = $res.latency_p50_ms; latency_p95_ms = $res.latency_p95_ms
            attempts = $res.attempts; lease_renewals = $res.lease_renewals
            top_nack = $res.top_nack; quarantine = $res.quarantine; dlq = $res.dlq
            by_agent = $res.by_agent
        } -Cmd 'metrics'
        Out-Result $r 'metrics' -Watch $watch
    }
    default {
        $r = New-Result -Ok $false -Code 64 -Data @{ err = 'USAGE_ERROR'; detail = "unknown subcommand: $Command" } -Cmd $Command
        Out-Result $r $Command
    }
}
