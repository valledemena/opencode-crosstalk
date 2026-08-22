# cross-ipc.psm1 - Cross-platform IPC abstraction (v1.10).
# Capa de bajo nivel con primitivas de plataforma: deteccion de SO, mutex
# (exclusividad local), rutas de configuracion del usuario y del .env de
# OpenCode. Los modulos de negocio (state, delivery, diagnostic, action)
# NO cambian; solo esta capa + helpers de rutas.
# NOTA: Get-CrossMutex NO es reentrante (igual que System.Threading.Mutex);
# el lock Unix es advisory (no POSIX flock()), valido para exclusividad
# local dentro del mismo host (BIG PICKLE-R10, NEMOTRON-R7).
Set-StrictMode -Version 2.0

enum CrossPlatform {
    Windows
    Unix
    Unknown
}

$script:Platform = $null

function Get-CrossPlatform {
    if ($null -ne $script:Platform) { return $script:Platform }
    $platform = [CrossPlatform]::Unknown
    $isCore = ($PSVersionTable.PSEdition -eq 'Core')
    if (-not $isCore) {
        # Windows PowerShell 5.1: solo existe Windows.
        if ($env:OS -eq 'Windows_NT') { $platform = [CrossPlatform]::Windows }
        else { $platform = [CrossPlatform]::Unix }
    } else {
        if ($IsWindows) {
            $platform = [CrossPlatform]::Windows
        } elseif ($IsLinux -or $IsMacOS) {
            # WSL se comporta como Unix (no tiene Mutex Global\); se detecta
            # explicitamente (NEMOTRON-R6).
            $platform = [CrossPlatform]::Unix
        }
    }
    $script:Platform = $platform
    return $platform
}

function Get-CrossConfigDir {
    $platform = Get-CrossPlatform
    switch ($platform) {
        ([CrossPlatform]::Windows) {
            $base = $env:USERPROFILE
            if (-not $base) { $base = $env:HOMEDRIVE + $env:HOMEPATH }
            return (Join-Path $base '.config\opencode')
        }
        ([CrossPlatform]::Unix) {
            # XDG_CONFIG_HOME tiene prioridad sobre ~/.config (BIG PICKLE-R9)
            $xdg = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
            if ($xdg) { return (Join-Path $xdg 'opencode') }
            $home = $env:HOME
            if (-not $home) { $home = $env:USERPROFILE }
            if (-not $home) { return '' }
            return (Join-Path (Join-Path $home '.config') 'opencode')
        }
        default {
            if ($env:USERPROFILE) { return (Join-Path $env:USERPROFILE '.config\opencode') }
            if ($env:HOME) { return (Join-Path (Join-Path $env:HOME '.config') 'opencode') }
            return ''
        }
    }
}

function Get-CrossEnvFile {
    $dir = Get-CrossConfigDir
    if (-not $dir) { return '' }
    return (Join-Path $dir '.env')
}

function Get-CrossTempDir {
    $platform = Get-CrossPlatform
    switch ($platform) {
        ([CrossPlatform]::Windows) {
            if ($env:TEMP) { return $env:TEMP }
            if ($env:TMP) { return $env:TMP }
            return (Join-Path $env:USERPROFILE 'AppData\Local\Temp')
        }
        ([CrossPlatform]::Unix) {
            if ($env:TMPDIR) { return $env:TMPDIR }
            return '/tmp'
        }
        default {
            if ($env:TEMP) { return $env:TEMP }
            if ($env:TMP) { return $env:TMP }
            return '/tmp'
        }
    }
}

# Lock por archivo para Unix: expone la misma API minima que el Mutex de
# Windows (.WaitOne(ms)/.ReleaseMutex()) para que cross-state no cambie.
class CrossFileLock {
    [string]$LockPath
    [System.IO.FileStream]$Stream = $null
    [bool]$Held = $false

    CrossFileLock([string]$Path) {
        $this.LockPath = $Path
    }

    [bool]WaitOne([int]$TimeoutMs) {
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ($null -eq $this.Stream) {
            try {
                $platform = Get-CrossPlatform
                if ($platform -eq [CrossPlatform]::Windows) {
                    $this.Stream = New-Object System.IO.FileStream($this.LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::DeleteOnClose)
                } else {
                    # Unix: NO DeleteOnClose - advisory lock via FileShare.None, explicit cleanup in ReleaseMutex
                    $this.Stream = New-Object System.IO.FileStream($this.LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 4096)
                }
                $this.Held = $true
                return $true
            } catch {
                if ((Get-Date) -ge $deadline) { return $false }
                Start-Sleep -Milliseconds 200
            }
        }
        return $true
    }

    [void]ReleaseMutex() {
        if ($null -ne $this.Stream) {
            try { $this.Stream.Dispose() } catch { }
            $this.Stream = $null
            $this.Held = $false
            try { Remove-Item -LiteralPath $this.LockPath -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Get-CrossMutex {
    param([Parameter(Mandatory=$true)][string]$Path)
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Path))).Replace('-', '').Substring(0, 24)
    $platform = Get-CrossPlatform
    switch ($platform) {
        ([CrossPlatform]::Windows) {
            return New-Object System.Threading.Mutex($false, "Global\CrossOutbox_$hash")
        }
        ([CrossPlatform]::Unix) {
            $lockPath = Join-Path (Get-CrossTempDir) "cross-outbox-$hash.lock"
            return [CrossFileLock]::new($lockPath)
        }
        default {
            throw "PLATFORM_UNSUPPORTED: $($platform)"
        }
    }
}

Export-ModuleMember -Function Get-CrossPlatform, Get-CrossConfigDir, Get-CrossEnvFile, Get-CrossTempDir, Get-CrossMutex