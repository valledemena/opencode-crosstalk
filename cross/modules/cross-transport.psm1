Set-StrictMode -Version 2.0

if (-not (Get-Command Get-CrossPlatform -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'cross-ipc.psm1') -Force -DisableNameChecking
}

$script:Config = $null
$script:PortCache = Join-Path (Get-CrossTempDir) 'cross-port.cache'
$script:EnvFile = Get-CrossEnvFile
$script:DiagLevel = ([Environment]::GetEnvironmentVariable('CROSS_DIAG')) -replace '^\s*|\s*$',''
if (-not $script:DiagLevel) { $script:DiagLevel = 'warn' }
$script:DiagLevel = $script:DiagLevel.ToLower()

function Write-CrossDiag {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('trace','debug','info','warn')][string]$Level,
        [Parameter(Mandatory=$true)][string]$Message
    )
    $order = @{ trace = 0; debug = 1; info = 2; warn = 3 }
    if ($order[$Level] -lt $order[$script:DiagLevel]) { return }
    try {
        [System.Console]::Error.WriteLine("[cross-diag] $($Level.ToUpper()) $Message")
    } catch {
        # diag is best-effort
    }
}

# F3 (v1.16): resolve curl cross-platform. Windows: curl.exe (built-in Win10+).
# Unix: curl. Cached after first resolution.
$script:CurlCmd = $null

function Get-CrossCurlCommand {
    param([switch]$NoCache)
    if (-not $NoCache -and $script:CurlCmd) { return $script:CurlCmd }
    $isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $candidates = if ($isWindowsHost) { @('curl.exe', 'curl') } else { @('curl', 'curl.exe') }
    foreach ($cand in $candidates) {
        if (Get-Command $cand -ErrorAction SilentlyContinue) {
            $script:CurlCmd = $cand
            return $cand
        }
    }
    $hint = if ($isWindowsHost) { 'curl.exe is built-in on Windows 10+. For older Windows install from https://curl.se/windows/' } else { 'install with: apt-get install curl / brew install curl' }
    throw "CURL_NOT_FOUND: no curl binary found in PATH (tried: $($candidates -join ', ')). $hint"
}

function Import-CrossConfig {
    param([string]$ConfigPath = '')
    $null = Get-CrossCurlCommand   # F3: validate and cache resolved command
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot '..\cross.config.json' }
    $configPath = [System.IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $configPath)) { throw "CONFIG_NOT_FOUND: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $localPath = [System.IO.Path]::ChangeExtension($configPath, 'local.json')
    if (Test-Path -LiteralPath $localPath) {
        $local = Get-Content -LiteralPath $localPath -Raw | ConvertFrom-Json
        foreach ($prop in $local.PSObject.Properties) {
            if ($null -ne $prop.Value -and "$($prop.Value)" -ne '') { $config.$($prop.Name) = $prop.Value }
        }
    }
    foreach ($key in @('my_session_id','my_model','my_role','whiteboard_dir','diario_dir','log_path','desktop_logs_dir')) {
        $envKey = "CROSS_MY_" + ($key.ToUpper())
        if ([Environment]::GetEnvironmentVariable($envKey)) {
            $config.$key = [Environment]::GetEnvironmentVariable($envKey)
        }
    }
    if ([Environment]::GetEnvironmentVariable('CROSS_WHITEBOARD_DIR')) { $config.whiteboard_dir = [Environment]::GetEnvironmentVariable('CROSS_WHITEBOARD_DIR') }
    if ([Environment]::GetEnvironmentVariable('CROSS_LOG_PATH')) { $config.log_path = [Environment]::GetEnvironmentVariable('CROSS_LOG_PATH') }
    # v2.1.1: relative paths resolve against the CONFIG FILE directory, never the
    # caller's cwd (previously "./whiteboard" pointed at whatever directory the
    # CLI happened to run from, orphaning the outbox and breaking send/ack).
    $configDir = Split-Path -Parent $configPath
    foreach ($key in @('whiteboard_dir', 'diario_dir', 'log_path')) {
        $prop = $config.PSObject.Properties[$key]
        if ($null -eq $prop -or -not $prop.Value) { continue }
        $val = [Environment]::ExpandEnvironmentVariables([string]$prop.Value)
        if ($val -and -not [System.IO.Path]::IsPathRooted($val)) {
            $val = [System.IO.Path]::GetFullPath((Join-Path $configDir $val))
        }
        $config.$key = $val
    }
    $script:Config = $config
    return $config
}

function Get-CrossConfig {
    if (-not $script:Config) { $null = Import-CrossConfig }
    return $script:Config
}

function Expand-Path {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return $expanded
}

function Get-CrossPassword {
    $pw = [Environment]::GetEnvironmentVariable('OPENCODE_SERVER_PASSWORD')
    if ($pw) { return @{ value = $pw; source = 'env' } }
    # Phase 1 (2026-10-28): OpenCode V2 servers rotate the password on each start
    # and persist it in ~/.config/opencode/service.json. That file is written by
    # the live server itself, so it outranks the (often stale) .env copy.
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { '' }
    if ($homeDir) {
        $svcFile = Join-Path (Join-Path (Join-Path $homeDir '.config') 'opencode') 'service.json'
        if (Test-Path -LiteralPath $svcFile) {
            try {
                $svc = Get-Content -LiteralPath $svcFile -Raw | ConvertFrom-Json
                $p = $svc.PSObject.Properties['password']
                if ($p -and $p.Value) { return @{ value = [string]$p.Value; source = 'service.json' } }
            } catch {
                Write-CrossDiag -Level debug -Message "Get-CrossPassword: service.json ilegible: $_"
            }
        } else {
            Write-CrossDiag -Level debug -Message 'Get-CrossPassword: service.json no presente (server V1?)'
        }
    }
    $envFile = Expand-Path $script:EnvFile
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in (Get-Content -LiteralPath $envFile)) {
            if ($line -match '^\s*OPENCODE_SERVER_PASSWORD\s*=\s*(.+?)\s*$') {
                return @{ value = $Matches[1]; source = 'env_file' }
            }
        }
    }
    return $null
}

function Get-PasswordHash {
    param([string]$Password)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-CrossNetrcFile {
    param([string]$Password, [string]$HostName = '127.0.0.1')
    $netrcPath = Join-Path $env:TEMP ("cross_netrc_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    $content = "machine $HostName`nlogin opencode`npassword $Password"
    [System.IO.File]::WriteAllText($netrcPath, $content, [System.Text.Encoding]::ASCII)
    if ($env:CI -or $env:GITHUB_ACTIONS) {
        # Skip icacls in CI runners to avoid I/O saturation in concurrent tests
    } elseif ($env:OS -eq 'Windows_NT') {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $null = & icacls.exe $netrcPath /inheritance:r /grant:r "$user`:(R,W)" 2>$null
    } elseif (-not $IsWindows) {
        $null = & chmod 600 $netrcPath 2>$null
    }
    return $netrcPath
}

function Test-CrossHealthRaw {
    param([int]$Port, [string]$Password)
    try {
        $url = "http://127.0.0.1:$Port/api/session"
        $tmp = Join-Path $env:TEMP ("cross_health_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
        $netrcFile = $null
        try { $netrcFile = Get-CrossNetrcFile -Password $Password } catch { Write-CrossDiag -Level debug -Message "Test-CrossHealthRaw: netrc best-effort no disponible: $_" }
        $curl = Get-CrossCurlCommand   # F3
        if ($netrcFile) { $code = & $curl -s -o $tmp -w "%{http_code}" --max-time 5 --netrc-file $netrcFile $url 2>$null }
        else { $code = & $curl -s -o $tmp -w "%{http_code}" --max-time 5 -u "opencode:$Password" $url 2>$null }
        if ($netrcFile) { Remove-Item -LiteralPath $netrcFile -ErrorAction SilentlyContinue }
        $body = if (Test-Path -LiteralPath $tmp) { Get-Content -LiteralPath $tmp -Raw } else { '' }
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($code -eq '401') { return @{ status = 401; healthy = $false } }
        if ($code -eq '200') {
            try { $json = $body | ConvertFrom-Json; $ok = ($null -ne $json) } catch { $ok = $false }
            if ($ok) { return @{ status = 200; healthy = $true; version = 'v2' } }
            return @{ status = 200; healthy = $false }
        }
        return @{ status = [int]$code; healthy = $false }
    } catch {
        return @{ status = 0; healthy = $false }
    }
}

function Get-CrossPortFromCache {
    param([int]$TtlSeconds = 60, [string]$PasswordHash = '')
    if (-not (Test-Path -LiteralPath $script:PortCache)) { return $null }
    try {
        $cache = Get-Content -LiteralPath $script:PortCache -Raw | ConvertFrom-Json
        $age = ((Get-Date).ToUniversalTime() - [System.DateTime]::Parse($cache.ts).ToUniversalTime()).TotalSeconds
        if ($age -gt $TtlSeconds) { return $null }
        if ($PasswordHash -and $cache.password_hash -ne $PasswordHash) { return $null }
        return [int]$cache.port
    } catch {
        return $null
    }
}

function Write-CrossPortCache {
    param([int]$Port, [string]$PasswordHash)
    $payload = @{ port = $Port; password_hash = $PasswordHash; ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $json = $payload | ConvertTo-Json -Compress
    try {
        [System.IO.File]::WriteAllText($script:PortCache, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # cache es best-effort
    }
}

# Cadena de descubrimiento (NEMOTRON-N5): cache -> well-known -> log -> scan,
# con health check en cada paso antes de confiar en el puerto.
function Get-CrossPortWellKnown {
    $configDir = Get-CrossConfigDir
    if (-not $configDir) { return $null }
    $file = Join-Path $configDir 'server.port'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try {
        $value = (Get-Content -LiteralPath $file -Raw).Trim()
        if ($value -match '^\d+$') {
            $port = [int]$value
            if ($port -ge 1 -and $port -le 65535) { return $port }
        }
        Write-CrossDiag -Level debug -Message "well-known '$file' vacio o corrupto -> null"
        return $null
    } catch {
        Write-CrossDiag -Level debug -Message "well-known '$file' ilegible -> null"
        return $null
    }
}

function Write-CrossPortWellKnown {
    param([int]$Port)
    if ($Port -lt 1 -or $Port -gt 65535) {
        Write-CrossDiag -Level warn -Message "Write-CrossPortWellKnown ignora puerto invalido $Port"
        return
    }
    $configDir = Get-CrossConfigDir
    if (-not $configDir) { return }
    try {
        if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $configDir 'server.port'), "$Port", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # well-known es best-effort (NEMOTRON-N1: validacion previa; el scan queda como fallback)
    }
}

# D2 (v1.17): DEPRECATED - free-text scrape of a third-party log.
# Removal planned for v1.18 (discovery is covered by well-known file + /global/health + cache).
$script:PortFromLogWarned = $false
    if (-not $script:PortFromLogWarned) {
        $script:PortFromLogWarned = $true
        # level=info: visible with CROSS_DIAG=info; silent by default so callers
        # capturing stderr under EAP=Stop are not broken (PS5.1 native stderr quirk)
        Write-CrossDiag -Level info -Message 'DEPRECATED: Get-CrossPortFromLog scrapes main.log and will be removed in v1.18'
    }

function Get-CrossPortFromLog {
    $logsDir = Expand-Path ([Environment]::GetEnvironmentVariable('CROSS_DESKTOP_LOGS_DIR'))
    if (-not $logsDir) {
        $config = Get-CrossConfig
        if ($config.desktop_logs_dir) { $logsDir = Expand-Path $config.desktop_logs_dir }
    }
    if (-not $logsDir -or -not (Test-Path -LiteralPath $logsDir)) {
        # Fallback Unix (NEMOTRON-R5): equivalentes de APPDATA y del log de
        # OpenCode en Linux/macOS. Retorna $null limpio si no hay nada
        # (BIG PICKLE-R5: sin warnings ruidosos).
        $platform = Get-CrossPlatform
        if ($platform -eq [CrossPlatform]::Unix) {
            $candidates = @(
                (Join-Path (Get-CrossConfigDir) 'desktop/logs'),
                (Join-Path $env:HOME '.local/share/opencode/log')
            )
            foreach ($c in $candidates) {
                if (-not $c -or -not (Test-Path -LiteralPath $c)) { continue }
                $latest = Get-ChildItem -LiteralPath $c -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if (-not $latest) { continue }
                $mainLog = Join-Path $latest.FullName 'main.log'
                if (-not (Test-Path -LiteralPath $mainLog)) { continue }
                try {
                    $content = Get-Content -LiteralPath $mainLog -Raw
                    # F2 (v1.16): [^\r\n]* avoids crossing lines (greedy .* could jump to a later
                    # restart URL); take the LAST match = most recent server start.
                    $ms = [regex]::Matches($content, "server ready[^\r\n]*url: 'http://127\.0\.0\.1:(\d+)'")
                    if ($ms.Count -gt 0) { return [int]$ms[$ms.Count - 1].Groups[1].Value }
                } catch { Write-CrossDiag -Level debug -Message "Get-CrossPortFromLog: fallo best-effort leyendo main.log (Unix fallback): $_" }
            }
        }
        return $null
    }
    $latest = Get-ChildItem -LiteralPath $logsDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }
    $mainLog = Join-Path $latest.FullName 'main.log'
    if (-not (Test-Path -LiteralPath $mainLog)) { return $null }
    try {
        $content = Get-Content -LiteralPath $mainLog -Raw
        # F2 (v1.16): see above.
        $ms = [regex]::Matches($content, "server ready[^\r\n]*url: 'http://127\.0\.0\.1:(\d+)'")
        if ($ms.Count -gt 0) { return [int]$ms[$ms.Count - 1].Groups[1].Value }
    } catch { Write-CrossDiag -Level debug -Message "Get-CrossPortFromLog: fallo best-effort leyendo main.log: $_" }
    return $null
}

function Get-CrossPortByScan {
    param([int[]]$ScanRange = @(30000, 40000), [int]$ScanTimeoutMs = 30000)
    $lo = $ScanRange[0]; $hi = $ScanRange[1]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $candidates = New-Object System.Collections.ArrayList
    for ($p = $lo; $p -le $hi; $p++) {
        if ($watch.Elapsed.TotalMilliseconds -gt $ScanTimeoutMs) {
            Write-CrossDiag -Level debug -Message "scan aborted at ScanTimeoutMs=$ScanTimeoutMs after $p ports"
            break
        }
        $tcp = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $task = $tcp.ConnectAsync('127.0.0.1', $p)
            if ($task.Wait(120)) {
                if ($tcp.Connected) { [void]$candidates.Add($p) }
            }
        } catch {
            # reserved port / socket error: skip this port
        } finally {
            if ($tcp) { $tcp.Close() }
        }
        if ($candidates.Count -ge 20) { break }
    }
    $pw = Get-CrossPassword
    foreach ($p in $candidates) {
        if ($pw) {
            $h = Test-CrossHealthRaw -Port $p -Password $pw.value
            if ($h.healthy) { return $p }
        } else {
            # sin password no se puede verificar health: no devolver puertos trampa,
            # dejar que Resolve-CrossEndpoint retorne SERVER_NOT_FOUND limpio
            break
        }
    }
    return $null
}

# Phase 1 (2026-10-28): OpenCode V2 desktop builds may pick a port OUTSIDE the
# configured scan range (e.g. 28894 with port_scan_range 30000-40000) and the
# log scraper is deprecated. Before brute-force scanning, probe the actual
# local TCP listeners on 127.0.0.1 that answer the health probe.
function Get-CrossPortFromListeners {
    $ports = New-Object System.Collections.ArrayList
    try {
        $conns = Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { $_.LocalAddress -eq '127.0.0.1' }
        foreach ($c in $conns) { [void]$ports.Add([int]$c.LocalPort) }
    } catch {
        # fallback: netstat parse (CIM unavailable / older environments)
        $lines = & netstat -ano -p tcp 2>$null
        foreach ($l in $lines) {
            if ($l -match '^\s*TCP\s+127\.0\.0\.1:(\d+)\s+\S+\s+LISTENING') {
                [void]$ports.Add([int]$Matches[1])
            }
        }
    }
    $ports = @($ports | Sort-Object -Unique)
    if (-not $ports) { return $null }
    $pw = Get-CrossPassword
    if (-not $pw) {
        Write-CrossDiag -Level debug -Message 'listeners: no password, cannot verify candidates'
        return $null
    }
    foreach ($p in $ports) {
        try {
            $h = Test-CrossHealthRaw -Port $p -Password $pw.value
            if ($h.healthy) {
                Write-CrossDiag -Level debug -Message "listeners: health OK on 127.0.0.1:$p"
                return $p
            }
        } catch { }
    }
    return $null
}

# D2 (v1.17): structured session state via API (GET /session/:id).
# Returns ok/status/last_activity_at/model/checkable. Mockable via SessionFn.
function Get-CrossSessionState {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [int]$Port = 0,
        [string]$Password = '',
        [scriptblock]$SessionFn
    )
    if ($SessionFn) { return @(& $SessionFn $Id) }
    $api = Invoke-CrossApi -Method 'GET' -Path "/api/session/$Id" -Port $Port -Password $Password -TimeoutSec 8
    if ($api.status -ne 200) {
        return @{ ok = $false; status_code = [int]$api.status; status = ''; last_activity_at = ''; model = ''; checkable = $false }
    }
    $s = $null
    try { $s = $api.body | ConvertFrom-Json } catch { Write-CrossDiag -Level debug -Message "Get-CrossSessionState: fallo parse JSON best-effort: $_" }
    if ($null -eq $s) { return @{ ok = $false; status_code = 200; status = ''; last_activity_at = ''; model = ''; checkable = $false } }
    function Get-Str2([object]$o, [string]$k) {
        $p = $o.PSObject.Properties[$k]
        if ($null -ne $p -and $null -ne $p.Value) { return [string]$p.Value }
        return ''
    }
    # v2.1.1: the API returns model as an OBJECT ({id,providerID,variant}) in
    # current OpenCode builds. Extract .id; accept a bare string for older ones.
    $modelStr = ''
    $modelProp = $s.PSObject.Properties['model']
    if ($null -ne $modelProp -and $null -ne $modelProp.Value) {
        $mv = $modelProp.Value
        if ($mv -is [string]) {
            $modelStr = $mv
        } else {
            $idProp = $mv.PSObject.Properties['id']
            if ($null -ne $idProp -and $idProp.Value) { $modelStr = [string]$idProp.Value }
        }
    }
    return @{
        ok = $true; status_code = 200
        status = (Get-Str2 $s 'status')
        last_activity_at = (Get-Str2 $s 'lastActivityAt')
        model = $modelStr
        checkable = $true
    }
}

# Phase 2 (2026-10-28): wait until a session goes idle (V2). Primary: POST the
# experimental wait endpoint (blocks server-side; HTTP 204 = idle). If the
# endpoint is unavailable, times out (curl status 0) or answers non-204, fall
# back to polling GET /api/session/{id}: the session is idle when
# time.idle >= time.updated, or when time.updated is older than the quiet
# threshold (V2 bumps time.updated on every turn activity).
# Mocks for tests: SleepFn(ms), WaitEndpointFn(id) -> @{status}, StateFn(id)
# -> @{ok; time_updated; time_idle}.
function Wait-CrossSessionIdle {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [int]$Port = 0,
        [string]$Password = '',
        [int]$TimeoutSec = 60,
        [int]$PollIntervalMs = 1000,
        [int]$QuietThresholdMs = 3000,
        [scriptblock]$SleepFn,
        [scriptblock]$WaitEndpointFn,
        [scriptblock]$StateFn
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $deadlineMs = [Math]::Max(1, $TimeoutSec) * 1000

    # Primary: experimental wait endpoint (server-side block; 204 = idle).
    $r = $null
    if ($WaitEndpointFn) {
        $r = & $WaitEndpointFn $Id
    } else {
        $waitSec = [Math]::Max(2, [int][Math]::Ceiling($deadlineMs / 1000.0))
        $r = Invoke-CrossApi -Method 'POST' -Path "/api/experimental/session/$Id/wait" -Port $Port -Password $Password -TimeoutSec $waitSec
    }
    if ($r -and [int]$r.status -eq 204) {
        return @{ ok = $true; idle = $true; method = 'wait-endpoint'; http_status = 204; elapsed_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
    }
    Write-CrossDiag -Level debug -Message ("Wait-CrossSessionIdle: wait endpoint HTTP {0} -> polling fallback" -f $(if ($r) { $r.status } else { 'null' }))

    # Fallback: poll session state until idle (field match or quiet threshold).
    while ($watch.Elapsed.TotalMilliseconds -lt $deadlineMs) {
        $st = $null
        if ($StateFn) {
            $st = & $StateFn $Id
        } else {
            $api = Invoke-CrossApi -Method 'GET' -Path "/api/session/$Id" -Port $Port -Password $Password -TimeoutSec 8
            if ($api.status -eq 200) {
                $s = $null
                try { $s = $api.body | ConvertFrom-Json } catch { $s = $null }
                if ($s) {
                    $tu = $null; $ti = $null
                    $pt = $s.PSObject.Properties['time']
                    if ($pt -and $pt.Value) {
                        $pu = $pt.Value.PSObject.Properties['updated']; if ($pu -and $null -ne $pu.Value) { $tu = [long]$pu.Value }
                        $pi = $pt.Value.PSObject.Properties['idle']; if ($pi -and $null -ne $pi.Value) { $ti = [long]$pi.Value }
                    }
                    $st = @{ ok = $true; time_updated = $tu; time_idle = $ti }
                } else { $st = @{ ok = $false } }
            } else { $st = @{ ok = $false; status_code = $api.status } }
        }
        if ($st -and $st.ok) {
            $tu = $st.time_updated; $ti = $st.time_idle
            if ($tu -and $ti -and $ti -ge $tu) {
                return @{ ok = $true; idle = $true; method = 'poll-idle-field'; elapsed_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
            }
            if ($tu) {
                $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                if (($nowMs - $tu) -gt $QuietThresholdMs) {
                    return @{ ok = $true; idle = $true; method = 'poll-quiet'; elapsed_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
                }
            }
        }
        if ($SleepFn) { & $SleepFn $PollIntervalMs } else { Start-Sleep -Milliseconds $PollIntervalMs }
    }
    return @{ ok = $true; idle = $false; timed_out = $true; method = 'poll-timeout'; elapsed_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
}

# Phase 1 (2026-10-28): normalize the message-list shape across API versions.
# V2 shape: {"data":[{id, time:{created(ms)}, type, text?, content?[{type,text}]}, ...], "cursor": ...}
#           (default order newest-first; user text is a flat "text" field;
#           assistant text lives in content[] with type "text").
# V1 shape: [ {info:{id, role, time:{created(ISO)}}, parts:[{type:'text',text}]}, ... ] (oldest-first)
# Returns a uniform @({id, role, time(ISO), text}) list, oldest-first.
function ConvertFrom-CrossMessageList {
    param([object]$Body)
    if ($null -eq $Body) { return @() }
    if ($Body -is [string]) { $Body = $Body | ConvertFrom-Json }  # Invoke-CrossApi returns raw JSON
    $items = @()
    $isV2 = $false
    if ($Body -is [array]) {
        $items = @($Body)
    } else {
        $d = $Body.PSObject.Properties['data']
        if ($d -and $d.Value) { $items = @($d.Value); $isV2 = $true } else { return @() }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($m in $items) {
        if ($null -eq $m) { continue }
        $id = ''; $role = ''; $time = ''
        $texts = New-Object System.Collections.ArrayList
        if ($isV2) {
            $p = $m.PSObject.Properties['id']; if ($p) { $id = [string]$p.Value }
            $p = $m.PSObject.Properties['type']; if ($p) { $role = [string]$p.Value }
            $p = $m.PSObject.Properties['time']
            if ($p -and $p.Value) {
                $pc = $p.Value.PSObject.Properties['created']
                if ($pc -and $pc.Value) {
                    $tv = "$($pc.Value)"
                    if ($tv -match '^\d+$') {
                        # V2 epoch ms -> ISO 8601 UTC (keeps --since filters meaningful)
                        $time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$tv).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    } else { $time = $tv }
                }
            }
            $p = $m.PSObject.Properties['text']; if ($p -and $p.Value) { [void]$texts.Add([string]$p.Value) }
            $p = $m.PSObject.Properties['content']
            if ($p -and $p.Value) {
                foreach ($c in @($p.Value)) {
                    if (-not $c) { continue }
                    $ct = $c.PSObject.Properties['type']
                    if (-not $ct -or [string]$ct.Value -ne 'text') { continue }
                    $cx = $c.PSObject.Properties['text']; if ($cx) { [void]$texts.Add([string]$cx.Value) }
                }
            }
        } else {
            $pInfo = $m.PSObject.Properties['info']
            if ($pInfo -and $pInfo.Value) {
                $iv = $pInfo.Value
                $p = $iv.PSObject.Properties['id']; if ($p) { $id = [string]$p.Value }
                $p = $iv.PSObject.Properties['role']; if ($p) { $role = [string]$p.Value }
                $p = $iv.PSObject.Properties['time']
                if ($p -and $p.Value) {
                    $pc = $p.Value.PSObject.Properties['created']; if ($pc) { $time = [string]$pc.Value }
                }
            }
            $p = $m.PSObject.Properties['parts']
            if ($p -and $p.Value) {
                foreach ($part in @($p.Value)) {
                    if (-not $part) { continue }
                    $pt = $part.PSObject.Properties['type']
                    if (-not $pt -or [string]$pt.Value -ne 'text') { continue }
                    $tx = $part.PSObject.Properties['text']; if ($tx) { [void]$texts.Add([string]$tx.Value) }
                }
            }
        }
        [void]$out.Add(@{ id = $id; role = $role; time = $time; text = ($texts -join "`n") })
    }
    if ($isV2) { return @($out | Sort-Object -Property { $_.time }) }  # restore oldest-first
    return @($out)
}

function Resolve-CrossEndpoint {
    param(
        [int]$Port = 0,
        [string]$Password = '',
        [switch]$NoCache,
        [switch]$HealthSkip
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $config = Get-CrossConfig
    $detectionMethod = 'cache'

    if (-not $Password) {
        $pwObj = Get-CrossPassword
        if (-not $pwObj) {
            return @{ ok = $false; code = 3; err = 'AUTH_FAILED'; detail = 'OPENCODE_SERVER_PASSWORD not defined (neither env nor .env)'; hint = 'set the env var or add it to .env' }
        }
        $Password = $pwObj.value
        $passwordSource = $pwObj.source
    } else {
        $passwordSource = 'override'
    }
    $pwHash = Get-PasswordHash $Password

    if ($Port -gt 0) {
        $detectionMethod = 'override'
        if (-not $HealthSkip) {
            $h = Test-CrossHealthRaw -Port $Port -Password $Password
            if (-not $h.healthy) {
                return @{ ok = $false; code = 3; err = 'UNHEALTHY'; detail = "port $Port responds but healthy=false or code $($h.status)"; hint = 'use --no-cache to force re-detection' }
            }
        }
        $watch.Stop()
        return @{ ok = $true; code = 0; port = $Port; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
    }

    if (-not $NoCache) {
        $cached = Get-CrossPortFromCache -TtlSeconds $config.port_cache_ttl_s -PasswordHash $pwHash
        if ($cached) {
            if ($HealthSkip) {
                $watch.Stop()
                return @{ ok = $true; code = 0; port = $cached; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
            }
            $h = Test-CrossHealthRaw -Port $cached -Password $Password
            if ($h.healthy) {
                $watch.Stop()
                return @{ ok = $true; code = 0; port = $cached; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
            }
            Write-CrossDiag -Level warn -Message "cache discarded: port $cached not healthy (status $($h.status))"
        } else {
            Write-CrossDiag -Level debug -Message 'cache: no valid entry'
        }
    }

    $wellKnown = Get-CrossPortWellKnown
    if ($wellKnown) {
        $detectionMethod = 'well-known'
        if ($HealthSkip) {
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $wellKnown; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        $h = Test-CrossHealthRaw -Port $wellKnown -Password $Password
        if ($h.healthy) {
            Write-CrossPortCache -Port $wellKnown -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $wellKnown; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        Write-CrossDiag -Level warn -Message "well-known discarded: port $wellKnown not healthy (status $($h.status))"
    } else {
        Write-CrossDiag -Level debug -Message 'well-known: no valid file'
    }

    $fromLog = Get-CrossPortFromLog
    if ($fromLog) {
        $detectionMethod = 'regex'
        if ($HealthSkip) {
            Write-CrossPortCache -Port $fromLog -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $fromLog; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        $h = Test-CrossHealthRaw -Port $fromLog -Password $Password
        if ($h.healthy) {
            Write-CrossPortCache -Port $fromLog -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $fromLog; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        Write-CrossDiag -Level warn -Message "log discarded: port $fromLog not healthy (status $($h.status))"
    } else {
        Write-CrossDiag -Level debug -Message 'log: no port detected (regex did not match or dir missing)'
    }

    # Phase 1: probe real local listeners before brute-force port scanning
    $listener = Get-CrossPortFromListeners
    if ($listener) {
        $detectionMethod = 'listeners'
        Write-CrossPortCache -Port $listener -PasswordHash $pwHash
        $watch.Stop()
        return @{ ok = $true; code = 0; port = $listener; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = $true; duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
    }

    $scanTimeoutMs = $config.port_scan_timeout_ms
    if (-not $scanTimeoutMs) { $scanTimeoutMs = 30000 }
    Write-CrossDiag -Level debug -Message "iniciando scan [$($config.port_scan_range[0])-$($config.port_scan_range[1])] ScanTimeoutMs=$scanTimeoutMs"
    $scanned = Get-CrossPortByScan -ScanRange $config.port_scan_range -ScanTimeoutMs $scanTimeoutMs
    if ($scanned) {
        $detectionMethod = 'scan'
        if ($HealthSkip) {
            Write-CrossPortCache -Port $scanned -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $scanned; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        $h = Test-CrossHealthRaw -Port $scanned -Password $Password
        if ($h.healthy) {
            Write-CrossPortCache -Port $scanned -PasswordHash $pwHash
            $watch.Stop()
            return @{ ok = $true; code = 0; port = $scanned; password = $Password; password_source = $passwordSource; detection_method = $detectionMethod; source = $detectionMethod; degraded = ($detectionMethod -eq 'regex' -or $detectionMethod -eq 'scan'); duration_ms = [math]::Round($watch.Elapsed.TotalMilliseconds) }
        }
        Write-CrossDiag -Level warn -Message "scan discarded: port $scanned not healthy (status $($h.status))"
    } else {
        Write-CrossDiag -Level warn -Message "scan: no healthy candidates (ScanTimeoutMs=$scanTimeoutMs)"
    }

    $watch.Stop()
    return @{ ok = $false; code = 3; err = 'SERVER_NOT_FOUND'; detail = 'no port responded /global/health healthy'; hint = 'check that OpenCode Desktop is open and auto-detection is enabled' }
}

function Invoke-CrossApi {
    param(
        [Parameter(Mandatory=$true)][string]$Method,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$BodyJson = '',
        [int]$Port,
        [string]$Password,
        [int]$TimeoutSec = 10
    )
    $url = "http://127.0.0.1:$Port$Path"
    $netrcFile = $null
    try { $netrcFile = Get-CrossNetrcFile -Password $Password } catch { Write-CrossDiag -Level debug -Message "Invoke-CrossApi: netrc best-effort no disponible: $_" }
    if ($netrcFile) { $args = @('-s', '--max-time', "$TimeoutSec", '--netrc-file', $netrcFile, '-X', $Method) }
    else { $args = @('-s', '--max-time', "$TimeoutSec", '-u', "opencode:$Password", '-X', $Method) }
    $tmpBody = $null
    $tmpOut = Join-Path $env:TEMP ("cross_api_" + [System.Guid]::NewGuid().ToString('N') + ".txt")
    $args += @('-o', $tmpOut, '-w', '%{http_code}')
    if ($BodyJson) {
        $tmpBody = Join-Path $env:TEMP ("cross_body_" + [System.Guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmpBody, (ConvertTo-AsciiSafe $BodyJson), (New-Object System.Text.UTF8Encoding($false)))
        $args += @('-H', 'Content-Type: application/json', '--data-binary', "@$tmpBody")
    }
    $args += $url
    $curl = Get-CrossCurlCommand   # F3
    $code = & $curl @args 2>$null
    if ($netrcFile) { Remove-Item -LiteralPath $netrcFile -ErrorAction SilentlyContinue }
    $body = if (Test-Path -LiteralPath $tmpOut) { Get-Content -LiteralPath $tmpOut -Raw } else { '' }
    Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
    if ($tmpBody) { Remove-Item -LiteralPath $tmpBody -ErrorAction SilentlyContinue }
    return @{ status = [int]$code; body = $body }
}

Export-ModuleMember -Function Import-CrossConfig, Get-CrossConfig, Get-CrossCurlCommand, Get-CrossPassword, Get-PasswordHash, Get-CrossNetrcFile, Test-CrossHealthRaw, Resolve-CrossEndpoint, Invoke-CrossApi, Get-CrossPortFromCache, Write-CrossPortCache, Get-CrossPortFromLog, Get-CrossPortByScan, Get-CrossPortWellKnown, Write-CrossPortWellKnown, Write-CrossDiag, Get-CrossSessionState, Get-CrossPortFromListeners, ConvertFrom-CrossMessageList, Wait-CrossSessionIdle
