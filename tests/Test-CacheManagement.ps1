Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Cache Management and In-Use File Protection...'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CacheManager.ps1')

# 1. Test In-Use File Detection
Write-Output '  -> Testing in-use file detection...'
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cache_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
[System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
$managedCacheDirectory = Join-Path $tempDir 'gdrive_test'
$unmanagedCacheDirectory = Join-Path $tempDir 'Documents'
[System.IO.Directory]::CreateDirectory($managedCacheDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($unmanagedCacheDirectory) | Out-Null

$fileLocked = Join-Path $managedCacheDirectory 'active_download.vfs'
$fileNormal = Join-Path $managedCacheDirectory 'idle_file.vfs'
$unmanagedFile = Join-Path $unmanagedCacheDirectory 'important.tmp'
$testBytes = [byte[]]@(1..100)

[System.IO.File]::WriteAllBytes($fileLocked, $testBytes)
[System.IO.File]::WriteAllBytes($fileNormal, $testBytes)
[System.IO.File]::WriteAllBytes($unmanagedFile, $testBytes)

# Open exclusive lock on $fileLocked
$lockStream = [System.IO.File]::Open($fileLocked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $isLocked = Test-FileInUse -FilePath $fileLocked
    $isNormalLocked = Test-FileInUse -FilePath $fileNormal

    if ($isLocked -ne $true) {
        throw "Test-FileInUse failed to detect active locked file: $fileLocked"
    }
    if ($isNormalLocked -ne $false) {
        throw "Test-FileInUse falsely reported unlocked file as in-use: $fileNormal"
    }
    Write-Output '  [PASS] In-use file lock detection verified'

    # 2. Test Detailed Cache Statistics
    Write-Output '  -> Testing detailed cache statistics calculation...'
    $stats = Get-DetailedCacheStatistics -CacheDirectory $managedCacheDirectory
    if ($stats.TotalFileCount -ne 2 -or $stats.TotalSizeBytes -ne 200L) {
        throw "Get-DetailedCacheStatistics failed total size/count check: TotalFiles=$($stats.TotalFileCount), TotalSize=$($stats.TotalSizeBytes)"
    }
    if ($stats.InUseCount -ne 1 -or $stats.InUseBytes -ne 100L) {
        throw "Get-DetailedCacheStatistics failed in-use check: InUseCount=$($stats.InUseCount), InUseBytes=$($stats.InUseBytes)"
    }
    if ($stats.EvictableBytes -ne 100L) {
        throw "Get-DetailedCacheStatistics failed evictable check: EvictableBytes=$($stats.EvictableBytes)"
    }
    if ($stats.DriveFreeBytes -le 0L) {
        throw "Get-DetailedCacheStatistics failed to report drive free bytes: $($stats.DriveFreeBytes)"
    }
    Write-Output '  [PASS] Detailed cache statistics and in-use breakdown verified'

    # 3. Test Safe Cache Cleanup with In-Use Protection
    Write-Output '  -> Testing safe cache cleanup with in-use protection...'
    $cleanRes = Invoke-SafeCacheCleanup -CacheDirectory $tempDir -Force
    if ($cleanRes.CleanedFiles -ne 1 -or $cleanRes.SkippedInUseCount -ne 1) {
        throw "Invoke-SafeCacheCleanup failed: CleanedFiles=$($cleanRes.CleanedFiles), SkippedInUse=$($cleanRes.SkippedInUseCount)"
    }
    if (-not (Test-Path -LiteralPath $fileLocked)) {
        throw "In-use file was deleted during cache cleanup!"
    }
    if (Test-Path -LiteralPath $fileNormal) {
        throw "Evictable file was not removed during force cleanup!"
    }
    if (-not (Test-Path -LiteralPath $unmanagedFile)) {
        throw 'Force cleanup removed a temporary-looking file outside a managed account cache directory'
    }
    if ($cleanRes.Errors.Count -ne 0) {
        throw "Cache cleanup reported errors: $($cleanRes.Errors -join '; ')"
    }
    Write-Output '  [PASS] Safe cache cleanup preserved in-use files and cleaned evictable files'
} finally {
    $lockStream.Dispose()
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}

# 4. Test LRU (Least Recently Used) Eviction under Target Quota
Write-Output '  -> Testing LRU eviction under quota threshold...'
$lruDir = Join-Path ([System.IO.Path]::GetTempPath()) ('lru_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
[System.IO.Directory]::CreateDirectory($lruDir) | Out-Null
$lruCacheDirectory = Join-Path $lruDir 'gdrive_lru'
[System.IO.Directory]::CreateDirectory($lruCacheDirectory) | Out-Null

try {
    $fOld = Join-Path $lruCacheDirectory 'file_old.dat'
    $fNew = Join-Path $lruCacheDirectory 'file_new.dat'

    $kbPayload = [byte[]]::new(10240) # 10 KB each
    [System.IO.File]::WriteAllBytes($fOld, $kbPayload)
    [System.IO.File]::WriteAllBytes($fNew, $kbPayload)

    # Set older timestamp on fOld
    (Get-Item $fOld).LastAccessTimeUtc = [DateTime]::UtcNow.AddDays(-5)
    (Get-Item $fNew).LastAccessTimeUtc = [DateTime]::UtcNow

    # Enforce 15 KB quota on 20 KB total -> Should evict oldest file (fOld) and keep fNew
    $lruRes = Invoke-SafeCacheCleanup -CacheDirectory $lruDir -TargetMaxBytes 15360L
    if ($lruRes.CleanedFiles -ne 1) {
        throw "LRU eviction expected 1 file cleaned, got: $($lruRes.CleanedFiles)"
    }
    if (Test-Path -LiteralPath $fOld) {
        throw "Oldest accessed file was not evicted first!"
    }
    if (-not (Test-Path -LiteralPath $fNew)) {
        throw "Recently accessed file was evicted prematurely!"
    }
    Write-Output '  [PASS] LRU cache eviction order verified'
} finally {
    Remove-Item -Recurse -Force $lruDir -ErrorAction SilentlyContinue
}

# 5. Test Cache Directory Safety and OS Drive Warning
Write-Output '  -> Testing cache directory safety and OS drive detection...'
$safetySys = Test-CacheDirectorySafety -Path (Join-Path $env:SystemDrive 'DummyTestCache')
if (-not $safetySys.IsValid) {
    throw "System drive path was marked invalid instead of returning warnings: $($safetySys.Issues -join ', ')"
}
$hasOsWarn = $safetySys.Warnings | Where-Object { $_ -match 'operating system drive' }
if (-not $hasOsWarn) {
    throw "Test-CacheDirectorySafety failed to warn when cache is located on operating system drive ($($env:SystemDrive))"
}

$safetyInvalid = Test-CacheDirectorySafety -Path 'Z:\NonExistentDrive99\Cache'
if ($safetyInvalid.IsValid -ne $false) {
    throw "Test-CacheDirectorySafety failed to reject non-existent drive"
}
Write-Output '  [PASS] Cache directory validation and OS drive warning verified'

# 6. Test Startup Recovery of Orphaned Partial Chunks
Write-Output '  -> Testing startup recovery of orphaned temporary files...'
$recDir = Join-Path ([System.IO.Path]::GetTempPath()) ('recovery_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
[System.IO.Directory]::CreateDirectory($recDir) | Out-Null

try {
    $mountCacheDir = Join-Path $recDir 'gdrive_testaccount'
    $unmanagedDir = Join-Path $recDir 'Documents'
    [System.IO.Directory]::CreateDirectory($mountCacheDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($unmanagedDir) | Out-Null
    $fPartial = Join-Path $mountCacheDir 'stream.partial'
    $fRcloneTmp = Join-Path $mountCacheDir 'chunk.rclone-tmp'
    $fLegit = Join-Path $mountCacheDir 'persisted_document.pdf'
    $fUserTemporary = Join-Path $unmanagedDir 'draft.tmp'

    [System.IO.File]::WriteAllText($fPartial, 'incomplete')
    [System.IO.File]::WriteAllText($fRcloneTmp, 'temp_buffer')
    [System.IO.File]::WriteAllText($fLegit, 'valid_document')
    [System.IO.File]::WriteAllText($fUserTemporary, 'user_data')

    $recRes = Invoke-StartupCacheRecovery -CacheDirectory $recDir
    if ($recRes.RecoveredFiles -ne 2) {
        throw "Startup recovery expected 2 recovered files, got: $($recRes.RecoveredFiles)"
    }
    if ((Test-Path $fPartial) -or (Test-Path $fRcloneTmp)) {
        throw "Orphaned partial chunks were not removed!"
    }
    if (-not (Test-Path $fLegit)) {
        throw "Legitimate file was accidentally removed by startup recovery!"
    }
    if (-not (Test-Path $fUserTemporary)) {
        throw 'Startup recovery must not remove temporary-looking files outside managed account cache directories'
    }

    $customCacheBase = Join-Path $recDir 'custom-cache-base'
    $customMountCacheDir = Join-Path $customCacheBase 'terabox_testaccount'
    [System.IO.Directory]::CreateDirectory($customMountCacheDir) | Out-Null
    $customPartial = Join-Path $customMountCacheDir 'custom.partial'
    [System.IO.File]::WriteAllText($customPartial, 'custom_cache')
    $customRes = Invoke-StartupCacheRecovery -CacheDirectory $recDir -MountCacheDirectories @($customMountCacheDir)
    if ($customRes.RecoveredFiles -ne 1 -or (Test-Path -LiteralPath $customPartial)) {
        throw 'Explicit per-account cache paths should recover temporary files in a custom cache base'
    }

    $invalidNamespaceRejected = $false
    try {
        Invoke-StartupCacheRecovery -CacheDirectory $recDir -MountCacheDirectories @($unmanagedDir) | Out-Null
    } catch {
        $invalidNamespaceRejected = $true
    }
    if (-not $invalidNamespaceRejected -or -not (Test-Path -LiteralPath $fUserTemporary)) {
        throw 'Recovery must reject directories outside the known provider/account cache namespace'
    }
    Write-Output '  [PASS] Startup recovery is isolated to valid provider/account cache directories'
} finally {
    Remove-Item -Recurse -Force $recDir -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------
# Test 7: Detailed Cache File List & Single-File Eviction
# ------------------------------------------------------------------------------
Write-Output '  -> Testing detailed cache file list and single-file eviction...'
$detailDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cache_detail_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
try {
    $gdriveAccDir = Join-Path $detailDir 'gdrive_mockacc'
    $vfsDir = Join-Path $gdriveAccDir 'vfs\gdrive{mock}\Docs'
    [System.IO.Directory]::CreateDirectory($vfsDir) | Out-Null

    $fileA = Join-Path $vfsDir 'sample.pdf'
    $fileB = Join-Path $vfsDir 'locked.dat'
    [System.IO.File]::WriteAllText($fileA, 'sample pdf content for cache inspection testing')
    [System.IO.File]::WriteAllText($fileB, 'locked data content')

    # Lock fileB
    $lockStream = [System.IO.File]::Open($fileB, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $fileList = @(Get-DetailedCacheFileList -CacheDirectory $detailDir)
        if ($fileList.Count -lt 2) {
            throw "Expected at least 2 files in detailed cache list, got: $($fileList.Count)"
        }

        $itemA = $fileList | Where-Object { $_.FileName -eq 'sample.pdf' } | Select-Object -First 1
        $itemB = $fileList | Where-Object { $_.FileName -eq 'locked.dat' } | Select-Object -First 1

        if (-not $itemA -or $itemA.IsEvictable -ne $true -or $itemA.Status -ne 'Cached (Synced)') {
            throw "File A (sample.pdf) was not recognized as evictable/synced: $($itemA | Out-String)"
        }
        if (-not $itemB -or $itemB.IsEvictable -ne $false -or $itemB.Status -notmatch 'In-Use') {
            throw "File B (locked.dat) was not recognized as locked/in-use: $($itemB | Out-String)"
        }

        # Attempt to evict locked file - must fail gracefully
        $evictLocked = Remove-SingleCacheFile -FilePath $fileB -CacheDirectory $detailDir
        if ($evictLocked.Success -eq $true) {
            throw 'Remove-SingleCacheFile should have failed for a locked in-use file'
        }
    } finally {
        $lockStream.Dispose()
    }

    # Now evict sample.pdf - must succeed
    $evictRes = Remove-SingleCacheFile -FilePath $fileA -CacheDirectory $detailDir
    if (-not $evictRes.Success) {
        throw "Failed to evict sample.pdf: $($evictRes.Error)"
    }
    if (Test-Path -LiteralPath $fileA) {
        throw 'sample.pdf still exists on disk after eviction'
    }

    Write-Output '  [PASS] Detailed cache file list and single-file eviction verified'
} finally {
    Remove-Item -Recurse -Force $detailDir -ErrorAction SilentlyContinue
}

Write-Output 'All Cache Management tests passed.'
