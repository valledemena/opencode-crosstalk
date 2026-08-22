# T-whoami.ps1 - Tests for the whoami subcommand (fix F3: real identity via config/override).
# Verifies that whoami reports the correct identity: shared config (shared_config),
# explicit overrides (--session-id/--model/--role) and NO_IDENTITY error without config.
$ErrorActionPreference = 'Stop'
$cli = Join-Path $PSScriptRoot '../cross.ps1'

$pass = 0; $fail = 0
function Assert-True {
    param($Cond, [string]$Name, [string]$Detail = '')
    if ([bool]$Cond) { $script:pass++; Write-Host ("  PASS  {0}" -f $Name) }
    else { $script:fail++; Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) }
}

# D4 (v1.17): cross-platform child PowerShell (pwsh on Linux, powershell.exe on Windows)
if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath().TrimEnd('/', '\') }
$psExe = if ($env:OS -eq 'Windows_NT') { 'powershell.exe' } elseif (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell.exe' }
function Invoke-CrossCli {
    param([string[]]$Args2)
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $cli @Args2 2>$null | Out-String
}

function Get-TmpConfig {
    param([string]$Dir, [string]$Sid, [string]$Lider, [string]$Model, [string]$Role)
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath('UserProfile') }
    $tmpDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $cfg = [ordered]@{
        my_session_id = $Sid
        leader_session_id = $Lider
        my_model = $Model
        my_role = $Role
        whiteboard_dir = (Join-Path $Dir 'whiteboard')
        diario_dir = (Join-Path $Dir 'diario')
        log_path = (Join-Path $env:TEMP 'opencode\opencode.log')
        desktop_logs_dir = (Join-Path $homeDir '.config/opencode/logs')
        default_ack_timeout_s = 120
        default_lease_minutes = 3
        max_retries = 2
        protocol_version = '1.6.1'
    }
    $p = Join-Path $Dir 'config.json'
    [System.IO.File]::WriteAllText($p, ($cfg | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    return $p
}

$tmp = Join-Path $env:TEMP ('cross_twhoami_' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

Write-Host "== T-whoami: shared config (my_session_id == leader) =="
$cfgShared = Get-TmpConfig $tmp 'ses_leader_abc' 'ses_leader_abc' 'leader-model' 'leader'
$raw = Invoke-CrossCli @('whoami', "--config=$cfgShared")
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok) 'whoami with config -> ok' $raw
Assert-True ($null -ne $j -and $j.session_id -eq 'ses_leader_abc') 'session_id from config' "$($j.session_id)"
Assert-True ($null -ne $j -and $j.model -eq 'leader-model') 'model from config' "$($j.model)"
Assert-True ($null -ne $j -and $j.role -eq 'leader') 'role from config' "$($j.role)"
Assert-True ($null -ne $j -and $j.identity_source -eq 'config') 'identity_source=config' "$($j.identity_source)"
Assert-True ($null -ne $j -and $j.shared_config) 'shared_config=true when my_session_id==leader' ''

Write-Host "== T-whoami: full override (advisor identity) =="
$raw = Invoke-CrossCli @('whoami', "--config=$cfgShared", '--session-id=ses_advisor_xyz', '--model=model-a', '--role=advisor')
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok) 'whoami with override -> ok' $raw
Assert-True ($null -ne $j -and $j.session_id -eq 'ses_advisor_xyz') 'override session_id' "$($j.session_id)"
Assert-True ($null -ne $j -and $j.model -eq 'model-a') 'override model' "$($j.model)"
Assert-True ($null -ne $j -and $j.role -eq 'advisor') 'override role' "$($j.role)"
Assert-True ($null -ne $j -and $j.identity_source -eq 'override') 'identity_source=override' "$($j.identity_source)"
Assert-True ($null -ne $j -and -not $j.shared_config) 'override -> shared_config=false' ''

Write-Host "== T-whoami: partial override (only session-id inherits model/role) =="
$raw = Invoke-CrossCli @('whoami', "--config=$cfgShared", '--session-id=ses_advisor_xyz')
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok -and $j.session_id -eq 'ses_advisor_xyz' -and $j.identity_source -eq 'override') 'partial override -> session_id from override' "$($j.session_id)|$($j.identity_source)"
Assert-True ($null -ne $j -and $j.model -eq 'leader-model' -and $j.role -eq 'leader') 'partial override -> inherits model/role from config' "$($j.model)|$($j.role)"

Write-Host "== T-whoami: own config (my_session_id != leader) is not shared =="
$cfgPropia = Get-TmpConfig $tmp 'ses_advisor_xyz' 'ses_leader_abc' 'model-b' 'advisor'
$raw = Invoke-CrossCli @('whoami', "--config=$cfgPropia")
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and $j.ok -and $j.session_id -eq 'ses_advisor_xyz' -and $j.identity_source -eq 'config') 'whoami own config -> ok' $raw
Assert-True ($null -ne $j -and -not $j.shared_config) 'own config -> shared_config=false' ''

Write-Host "== T-whoami: NO_IDENTITY without config =="
$cfgVacia = Get-TmpConfig $tmp '' '' '' ''
$raw = Invoke-CrossCli @('whoami', "--config=$cfgVacia")
$j = $null
try { $j = ($raw | ConvertFrom-Json) } catch { }
Assert-True ($null -ne $j -and -not $j.ok -and $j.err -eq 'NO_IDENTITY') 'no identity -> NO_IDENTITY' $raw

Write-Host ""
Write-Host ("RESULT: {0} pass, {1} fail" -f $pass, $fail)
if ($fail -gt 0) { exit 1 } else { exit 0 }
