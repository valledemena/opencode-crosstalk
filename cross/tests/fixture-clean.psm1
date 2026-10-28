# Fixture cleaner for pre-existing test contamination (Fase 2 fix).
# The real cross.config.local.json (with session/model identity) pollutes
# fixtures that expect a blank/default identity. This module temporarily
# moves it aside and restores it after the test.
$script:BackupPath = $null
$script:BackupConfigPath = $null
function Start-CleanFixture {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $local = Join-Path $repoRoot 'cross\cross.config.local.json'
    $cfg = Join-Path $repoRoot 'cross\cross.config.json'
    if (Test-Path -LiteralPath $local) {
        $script:BackupPath = $local + '.test-backup'
        Move-Item -LiteralPath $local -Destination $script:BackupPath -Force
    }
    if (Test-Path -LiteralPath $cfg) {
        $script:BackupConfigPath = $cfg + '.test-backup'
        Move-Item -LiteralPath $cfg -Destination $script:BackupConfigPath -Force
        $blank = '{"my_session_id":"","my_role":"leader","my_model":"","protocol_version":"1.8","port_cache_ttl_s":60,"max_retries":2,"retry_backoff_s":2,"default_ack_timeout_s":120,"default_lease_minutes":3,"max_saltos":2,"session_growing_check_ms":15000,"whiteboard_dir":"./whiteboard","log_path":"%USERPROFILE%\\.local\\share\\opencode\\log\\opencode.log","desktop_logs_dir":"%APPDATA%\\ai.opencode.desktop\\logs","port_scan_range":[30000,40000]}'
        [System.IO.File]::WriteAllText($cfg, $blank, (New-Object System.Text.UTF8Encoding($false)))
    }
}
function Stop-CleanFixture {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $local = Join-Path $repoRoot 'cross\cross.config.local.json'
    $cfg = Join-Path $repoRoot 'cross\cross.config.json'
    if ($script:BackupPath -and (Test-Path -LiteralPath $script:BackupPath)) {
        if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force }
        Move-Item -LiteralPath $script:BackupPath -Destination $local -Force
        $script:BackupPath = $null
    }
    if ($script:BackupConfigPath -and (Test-Path -LiteralPath $script:BackupConfigPath)) {
        if (Test-Path -LiteralPath $cfg) { Remove-Item -LiteralPath $cfg -Force }
        Move-Item -LiteralPath $script:BackupConfigPath -Destination $cfg -Force
        $script:BackupConfigPath = $null
    }
}
function Get-LocalConfigPath {
    return Join-Path (Split-Path $PSScriptRoot -Parent) 'cross\cross.config.local.json'
}
