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
        $url = "http://127.0.0.1:$Port/global/health"
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
            try { $json = $body | ConvertFrom-Json; $ok = ($json.healthy -eq $true) } catch { $ok = $false }
            if ($ok) { return @{ status = 200; healthy = $true; version = $json.version } }
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
    $api = Invoke-CrossApi -Method 'GET' -Path "/session/$Id" -Port $Port -Password $Password -TimeoutSec 8
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
    return @{
        ok = $true; status_code = 200
        status = (Get-Str2 $s 'status')
        last_activity_at = (Get-Str2 $s 'lastActivityAt')
        model = (Get-Str2 $s 'model')
        checkable = $true
    }
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

Export-ModuleMember -Function Import-CrossConfig, Get-CrossConfig, Get-CrossCurlCommand, Get-CrossPassword, Get-PasswordHash, Get-CrossNetrcFile, Test-CrossHealthRaw, Resolve-CrossEndpoint, Invoke-CrossApi, Get-CrossPortFromCache, Write-CrossPortCache, Get-CrossPortFromLog, Get-CrossPortByScan, Get-CrossPortWellKnown, Write-CrossPortWellKnown, Write-CrossDiag, Get-CrossSessionState
