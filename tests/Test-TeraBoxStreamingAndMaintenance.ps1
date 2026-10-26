Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing TeraBox Streaming Optimization, Keep-Alive Heartbeat, and Log Maintenance...'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')

# ------------------------------------------------------------------------------
# 1. Verify TeraBox & Cloud Streaming Mount Arguments
# ------------------------------------------------------------------------------
Write-Output '  -> Testing TeraBox and Google Drive streaming mount arguments...'

$tbArgs = Build-RcloneMountArguments -RemoteName 'terabox' -DriveLetter 'T' -ConfigPath ''

if ($tbArgs[0] -ne 'mount' -or $tbArgs[1] -ne 'terabox:' -or $tbArgs[2] -ne 'T:\') {
    throw "TeraBox mount positional arguments corrupted: $($tbArgs[0..2] -join ' ')"
}

# WinFsp ThreadCount=64 must be present on TeraBox to prevent Windows Photos / Explorer crashes
if ($tbArgs -notcontains '--fuse-flag' -or $tbArgs -notcontains '--ThreadCount=64') {
    throw 'TeraBox mount arguments missing WinFsp --ThreadCount=64 flag!'
}

# High-speed streaming read arguments must be present
$expectedStreamingArgs = @(
    '--vfs-read-chunk-size',
    '--vfs-read-chunk-size-limit',
    '--vfs-read-ahead',
    '--buffer-size'
)

foreach ($arg in $expectedStreamingArgs) {
    if ($tbArgs -notcontains $arg) {
        throw "TeraBox mount arguments missing streaming argument: $arg"
    }
}

$chunkSizeIdx = [array]::IndexOf($tbArgs, '--vfs-read-chunk-size')
if ($chunkSizeIdx -lt 0 -or $tbArgs[$chunkSizeIdx + 1] -ne '4M') {
    throw "Expected --vfs-read-chunk-size 4M, got: $($tbArgs[$chunkSizeIdx + 1])"
}

$chunkLimitIdx = [array]::IndexOf($tbArgs, '--vfs-read-chunk-size-limit')
if ($chunkLimitIdx -lt 0 -or $tbArgs[$chunkLimitIdx + 1] -ne '32M') {
    throw "Expected --vfs-read-chunk-size-limit 32M, got: $($tbArgs[$chunkLimitIdx + 1])"
}

$readAheadIdx = [array]::IndexOf($tbArgs, '--vfs-read-ahead')
if ($readAheadIdx -lt 0 -or $tbArgs[$readAheadIdx + 1] -ne '16M') {
    throw "Expected --vfs-read-ahead 16M, got: $($tbArgs[$readAheadIdx + 1])"
}

$bufferSizeIdx = [array]::IndexOf($tbArgs, '--buffer-size')
if ($bufferSizeIdx -lt 0 -or $tbArgs[$bufferSizeIdx + 1] -ne '16M') {
    throw "Expected --buffer-size 16M, got: $($tbArgs[$bufferSizeIdx + 1])"
}

# Verify Google Drive also has ThreadCount=64 and streaming read arguments
$gdArgs = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'G' -ConfigPath ''
if ($gdArgs -notcontains '--fuse-flag' -or $gdArgs -notcontains '--ThreadCount=64') {
    throw 'Google Drive mount arguments missing WinFsp --ThreadCount=64 flag!'
}
foreach ($arg in $expectedStreamingArgs) {
    if ($gdArgs -notcontains $arg) {
        throw "Google Drive mount arguments missing streaming argument: $arg"
    }
}

Write-Output '  [PASS] High-speed streaming arguments and WinFsp ThreadCount=64 verified for all mounts'

# ------------------------------------------------------------------------------
# 2. Connection Keep-Alive Heartbeat
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Invoke-VirtualDriveKeepAlive and VirtualDriveKeepAliveHelper...'

# Test with no active mounts
$origActive = $script:ActiveMountProcesses
$origMapping = $script:ProviderDriveMapping
try {
    $script:ActiveMountProcesses = @{}
    $script:ProviderDriveMapping = @{}
    $emptyResult = @(Invoke-VirtualDriveKeepAlive)
    if ($emptyResult.Count -ne 0) {
        throw "Expected 0 results for empty active mount processes, got $($emptyResult.Count)"
    }

    # Test with mock active mount process
    $mockProc = [System.Diagnostics.Process]::GetCurrentProcess()
    $script:ActiveMountProcesses['mock_terabox'] = $mockProc
    $script:ProviderDriveMapping['mock_terabox'] = 'T'

    $kaResults = @(Invoke-VirtualDriveKeepAlive -Synchronous)
    if ($kaResults.Count -ne 1) {
        throw "Expected 1 keep-alive result for mock mount, got $($kaResults.Count)"
    }
    if ($kaResults[0].MountKey -ne 'mock_terabox') {
        throw "Unexpected mount key: $($kaResults[0].MountKey)"
    }
    if ($kaResults[0].KeepAliveMethod -ne 'RC') {
        throw "Expected KeepAliveMethod 'RC', got: $($kaResults[0].KeepAliveMethod)"
    }
    if ($kaResults[0].RcPort -ne (Get-VirtualDriveRcPort 'T')) {
        throw "Unexpected RC port: $($kaResults[0].RcPort)"
    }

    # Test async keep-alive dispatch
    $asyncResults = @(Invoke-VirtualDriveKeepAlive)
    if ($asyncResults.Count -ne 1) {
        throw "Expected 1 keep-alive result for async mock mount, got $($asyncResults.Count)"
    }
    if (-not $asyncResults[0].Success) {
        throw "Async keep-alive dispatch reported failure!"
    }
} finally {
    $script:ActiveMountProcesses = $origActive
    $script:ProviderDriveMapping = $origMapping
}

# Test VirtualDriveKeepAliveHelper methods directly
if (([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveKeepAliveHelper').Type) {
    # Port 59999 is almost certainly closed/unbound; PingRc must fail gracefully within 2000ms
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $pingResult = [NSCloudDrive.VirtualDriveKeepAliveHelper]::PingRc(59999, 1000)
    $sw.Stop()
    if ($pingResult) {
        throw 'PingRc unexpectedly succeeded on unbound port 59999'
    }
    if ($sw.ElapsedMilliseconds -gt 3500) {
        throw "PingRc timeout exceeded expected bound: $($sw.ElapsedMilliseconds) ms"
    }

    # PingDriveRoot on non-existent drive root
    $statResult = [NSCloudDrive.VirtualDriveKeepAliveHelper]::PingDriveRoot('Z:\NonExistentDriveRoot999\')
    if ($statResult) {
        throw 'PingDriveRoot unexpectedly succeeded on non-existent path'
    }

    # PingDriveRoot on valid system directory
    $sysDir = [System.IO.Path]::GetPathRoot($env:WINDIR)
    $validStat = [NSCloudDrive.VirtualDriveKeepAliveHelper]::PingDriveRoot($sysDir)
    if (-not $validStat) {
        throw "PingDriveRoot failed on system drive root: $sysDir"
    }
} else {
    throw 'NSCloudDrive.VirtualDriveKeepAliveHelper C# class not found!'
}

Write-Output '  [PASS] Virtual drive keep-alive heartbeat and C# background worker verified'

# ------------------------------------------------------------------------------
# 3. Automated Log Maintenance & Pruning
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Invoke-LogMaintenance in isolated sandbox...'

$origLocalAppData = $env:LOCALAPPDATA
$sandboxDir = Join-Path $env:TEMP "nsclouddrive_log_sandbox_$([Guid]::NewGuid().ToString('N'))"
$sandboxLogDir = Join-Path $sandboxDir 'NSCloudDrive\logs'

try {
    New-Item -ItemType Directory -Path $sandboxLogDir -Force | Out-Null
    $env:LOCALAPPDATA = $sandboxDir

    # Create test files in sandbox:
    # 1. Stale temporary/lock/bak files
    $staleTmp = Join-Path $sandboxLogDir 'crash_dump.tmp'
    $staleBak = Join-Path $sandboxLogDir 'settings.bak'
    $staleOld = Join-Path $sandboxLogDir 'previous.old'
    $staleLock = Join-Path $sandboxLogDir 'session.lock'
    [System.IO.File]::WriteAllText($staleTmp, 'temporary data')
    [System.IO.File]::WriteAllText($staleBak, 'backup data')
    [System.IO.File]::WriteAllText($staleOld, 'old data')
    [System.IO.File]::WriteAllText($staleLock, 'lock info')

    # 2. Expired log file (> 7 days old)
    $expiredLog = Join-Path $sandboxLogDir 'rclone-legacy.log'
    [System.IO.File]::WriteAllText($expiredLog, 'ancient log entries')
    [System.IO.File]::SetLastWriteTimeUtc($expiredLog, [DateTime]::UtcNow.AddDays(-14))

    # 3. Active fresh log file (< 7 days old)
    $freshLog = Join-Path $sandboxLogDir 'rclone-active.log'
    [System.IO.File]::WriteAllText($freshLog, 'active log entries')
    [System.IO.File]::SetLastWriteTimeUtc($freshLog, [DateTime]::UtcNow.AddHours(-2))

    # 4. Oversized rclone log file (> 5 MB) and existing predecessor
    $oversizedLog = Join-Path $sandboxLogDir 'rclone-terabox.log'
    $oldPredLog = Join-Path $sandboxLogDir 'rclone-terabox.1.log'
    [System.IO.File]::WriteAllText($oldPredLog, 'old predecessor')
    
    # Write 6 MB file
    $chunk = [byte[]]::new(1024 * 1024)
    for ($i = 0; $i -lt $chunk.Length; $i++) { $chunk[$i] = 65 }
    $fs = [System.IO.File]::Create($oversizedLog)
    try {
        for ($i = 0; $i -lt 6; $i++) {
            $fs.Write($chunk, 0, $chunk.Length)
        }
    } finally {
        $fs.Dispose()
    }

    # Reset rate-limiting timer to ensure maintenance runs
    $script:LastLogMaintenanceTime = [DateTime]::MinValue

    # Run maintenance with Force
    $maintStats = Invoke-LogMaintenance -RetentionDays 7 -MaxLogSizeBytes 5242880L -Force

    if ($null -eq $maintStats) {
        throw 'Invoke-LogMaintenance returned null on forced run!'
    }

    if ($maintStats.DeletedStale -ne 4) {
        throw "Expected 4 stale files deleted, got: $($maintStats.DeletedStale)"
    }
    if ($maintStats.DeletedExpired -lt 1) {
        throw "Expected at least 1 expired log deleted, got: $($maintStats.DeletedExpired)"
    }
    if ($maintStats.RotatedLogs -ne 1) {
        throw "Expected 1 oversized log rotated, got: $($maintStats.RotatedLogs)"
    }

    # Verify stale files deleted
    if (Test-Path -LiteralPath $staleTmp) { throw 'staleTmp was not deleted' }
    if (Test-Path -LiteralPath $staleBak) { throw 'staleBak was not deleted' }
    if (Test-Path -LiteralPath $staleOld) { throw 'staleOld was not deleted' }
    if (Test-Path -LiteralPath $staleLock) { throw 'staleLock was not deleted' }

    # Verify expired log deleted and fresh log preserved
    if (Test-Path -LiteralPath $expiredLog) { throw 'expiredLog was not deleted' }
    if (-not (Test-Path -LiteralPath $freshLog)) { throw 'freshLog was unexpectedly deleted!' }

    # Verify oversized log was rotated to .1.log
    if (Test-Path -LiteralPath $oversizedLog) { throw 'oversizedLog was not moved during rotation!' }
    if (-not (Test-Path -LiteralPath $oldPredLog)) { throw 'Rotated predecessor rclone-terabox.1.log not found!' }
    $rotatedInfo = [System.IO.FileInfo]::new($oldPredLog)
    if ($rotatedInfo.Length -lt 5242880L) {
        throw "Rotated file size mismatch: $($rotatedInfo.Length)"
    }

    # 4. Verify Rate-Limiting
    # Immediate subsequent call without Force must return $null and skip work
    $rateLimitedResult = Invoke-LogMaintenance -RetentionDays 7 -MaxLogSizeBytes 5242880L
    if ($null -ne $rateLimitedResult) {
        throw 'Invoke-LogMaintenance did not respect 30-minute rate limit!'
    }

    # 5. Verify Write-NSCloudLog integration (zero pipeline pollution)
    $pipelineItems = @(Write-NSCloudLog -Severity 'Info' -Message 'Test maintenance integration')
    if ($pipelineItems.Count -ne 0) {
        throw "Write-NSCloudLog leaked $($pipelineItems.Count) items to the pipeline!"
    }

} finally {
    $env:LOCALAPPDATA = $origLocalAppData
    if (Test-Path -LiteralPath $sandboxDir) {
        Remove-Item -LiteralPath $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output '  [PASS] Automated log pruning, rotation, rate-limiting, and pipeline purity verified'

Write-Output 'All TeraBox Streaming, Keep-Alive, and Maintenance tests passed successfully.'
