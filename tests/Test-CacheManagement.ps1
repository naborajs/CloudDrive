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

if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
    Write-Output '  -> Testing exact Linux paths with trailing-space filenames...'
    $spacePathRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('cache_space_path_' + [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($spacePathRoot)
    try {
        $plainNamePath = Join-Path $spacePathRoot 'name'
        $trailingSpacePath = Join-Path $spacePathRoot 'name '
        [System.IO.File]::WriteAllText($plainNamePath, 'same payload')
        [System.IO.File]::WriteAllText($trailingSpacePath, 'same payload')
        $spacedInfo = Get-Item -LiteralPath $trailingSpacePath -Force
        if ((ConvertTo-CacheNormalizedPath $trailingSpacePath) -cne $trailingSpacePath) {
            throw 'Linux path normalization changed the trailing space in the selected filename.'
        }
        $spaceRemoval = Remove-SingleCacheFile `
            -FilePath $trailingSpacePath `
            -CacheDirectory $spacePathRoot
        if (-not $spaceRemoval.Success -or
            (Test-Path -LiteralPath $trailingSpacePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $plainNamePath -PathType Leaf)) {
            throw 'Linux cache eviction did not target exactly the selected trailing-space filename.'
        }
        Write-Output '  [PASS] Linux cache eviction preserves exact trailing-space filenames'
    } finally {
        Remove-Item -LiteralPath $spacePathRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# VFS files are upload state. Force clear may remove only explicitly clean entries
# from inactive roots; missing/invalid metadata and active-root data are preserved.
$vfsSafetyDir = Join-Path ([System.IO.Path]::GetTempPath()) ('vfs_cleanup_safety_' + [Guid]::NewGuid().ToString('N'))
$accountVfsRoot = Join-Path (Join-Path $vfsSafetyDir 'gdrive_test') 'vfs'
$accountMetaRoot = Join-Path (Join-Path $vfsSafetyDir 'gdrive_test') 'vfsMeta'
$inactiveRoot = Join-Path $accountVfsRoot 'old'
$activeRoot = Join-Path $accountVfsRoot 'active'
$inactiveMetaRoot = Join-Path $accountMetaRoot 'old'
$activeMetaRoot = Join-Path $accountMetaRoot 'active'
foreach ($dir in @($inactiveRoot, $activeRoot, $inactiveMetaRoot, $activeMetaRoot)) {
    [void][System.IO.Directory]::CreateDirectory($dir)
}
try {
    $cleanInactive = Join-Path $inactiveRoot 'clean.txt'
    $dirtyInactive = Join-Path $inactiveRoot 'dirty.txt'
    $missingMeta = Join-Path $inactiveRoot 'missing-meta.txt'
    $invalidMeta = Join-Path $inactiveRoot 'invalid-meta.txt'
    $cleanActive = Join-Path $activeRoot 'active-clean.txt'
    foreach ($path in @($cleanInactive, $dirtyInactive, $missingMeta, $invalidMeta, $cleanActive)) {
        [System.IO.File]::WriteAllText($path, 'cache data')
    }
    [System.IO.File]::WriteAllText((Join-Path $inactiveMetaRoot 'clean.txt'), '{"Dirty":false}')
    [System.IO.File]::WriteAllText((Join-Path $inactiveMetaRoot 'dirty.txt'), '{"Dirty":true}')
    [System.IO.File]::WriteAllText((Join-Path $inactiveMetaRoot 'invalid-meta.txt'), '{bad json')
    [System.IO.File]::WriteAllText((Join-Path $activeMetaRoot 'active-clean.txt'), '{"Dirty":false}')

    $vfsCleanResult = Invoke-SafeCacheCleanup -CacheDirectory $vfsSafetyDir -Force -ActiveCachePaths @($activeRoot)
    if (Test-Path -LiteralPath $cleanInactive) { throw 'Explicitly clean data in an inactive VFS root was not removed' }
    foreach ($protected in @($dirtyInactive, $missingMeta, $invalidMeta, $cleanActive)) {
        if (-not (Test-Path -LiteralPath $protected -PathType Leaf)) { throw "Force cleanup removed protected VFS data: $protected" }
    }
    if ([int]$vfsCleanResult.SkippedStagedCount -lt 4) { throw 'Force cleanup did not report all active, dirty, or ambiguous VFS entries as protected' }
    Write-Output '  [PASS] Force cleanup preserves dirty, ambiguous, and active VFS entries'

    $nestedVfsFile = Join-Path $accountVfsRoot 'vfs\cloud-folder\vfsMeta\dirty-nested.txt'
    $nestedMetaFile = Join-Path $accountMetaRoot 'vfs\cloud-folder\vfsMeta\dirty-nested.txt'
    $legacyWrongMeta = Join-Path $accountMetaRoot 'vfsMeta\cloud-folder\vfsMeta\dirty-nested.txt'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $nestedVfsFile))
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $nestedMetaFile))
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $legacyWrongMeta))
    [System.IO.File]::WriteAllText($nestedVfsFile, 'nested remote file is still dirty')
    [System.IO.File]::WriteAllText($nestedMetaFile, '{"Dirty":true}')
    # This is the path a global regex replacement used to inspect. It falsely
    # reports the nested dirty file as clean and must never authorize deletion.
    [System.IO.File]::WriteAllText($legacyWrongMeta, '{"Dirty":false}')
    $namespaceInfo = Get-CacheVfsNamespaceInfo -Path $nestedVfsFile -CacheDirectory $vfsSafetyDir
    if (-not $namespaceInfo.IsVfs -or $namespaceInfo.MetadataPath -cne (ConvertTo-CacheNormalizedPath $nestedMetaFile)) {
        throw 'VFS metadata resolution changed a nested remote path segment named vfs or vfsMeta.'
    }
    $nestedManualEviction = Remove-SingleCacheFile `
        -FilePath $nestedVfsFile `
        -CacheDirectory $vfsSafetyDir `
        -ActiveCachePaths @($activeRoot) `
        -ActiveCacheOwnershipKnown
    if ($nestedManualEviction.Success -or -not (Test-Path -LiteralPath $nestedVfsFile -PathType Leaf)) {
        throw 'Manual eviction trusted a decoy clean sidecar instead of the nested VFS file dirty metadata.'
    }
    $nestedForceCleanup = Invoke-SafeCacheCleanup `
        -CacheDirectory $vfsSafetyDir `
        -Force `
        -ActiveCachePaths @($activeRoot) `
        -ActiveCacheOwnershipKnown
    if (-not (Test-Path -LiteralPath $nestedVfsFile -PathType Leaf) -or
        -not (Test-Path -LiteralPath $nestedMetaFile -PathType Leaf)) {
        throw 'Force cleanup removed a nested dirty VFS entry after resolving the wrong sidecar path.'
    }
    Write-Output '  [PASS] Manual eviction and force cleanup protect dirty files under nested vfs and vfsMeta names'

    $lateDirtyFile = Join-Path $inactiveRoot 'late-dirty.txt'
    $lateDirtyMeta = Join-Path $inactiveMetaRoot 'late-dirty.txt'
    [System.IO.File]::WriteAllText($lateDirtyFile, 'cache data')
    [System.IO.File]::WriteAllText($lateDirtyMeta, '{"Dirty":false}')
    $observedCleanMeta = Get-Content -LiteralPath $lateDirtyMeta -Raw | ConvertFrom-Json
    if ([bool]$observedCleanMeta.Dirty) { throw 'Late-dirty race fixture did not begin clean.' }
    $lateDirtyInfo = Get-Item -LiteralPath $lateDirtyFile
    $originalExclusiveOpen = (Get-Command Open-CacheFileExclusiveRead).ScriptBlock
    $global:TestCacheLateDirtyMetadataPath = $lateDirtyMeta
    $global:TestCacheOriginalExclusiveOpen = $originalExclusiveOpen
    try {
        Set-Item -Path Function:\Open-CacheFileExclusiveRead -Value {
            param([string]$Path)
            if ([string]::Equals($Path, [string]$global:TestCacheLateDirtyMetadataPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                [System.IO.File]::WriteAllText($Path, '{"Dirty":true}')
            }
            return & $global:TestCacheOriginalExclusiveOpen -Path $Path
        }
        $lateDirtyRemoval = Remove-SafeCacheFileEntry `
            -FilePath $lateDirtyFile `
            -CacheDirectory $vfsSafetyDir `
            -ActiveCachePaths @($activeRoot) `
            -ActiveCacheOwnershipKnown `
            -ExpectedSizeBytes ([int64]$lateDirtyInfo.Length) `
            -ExpectedLastWriteUtc $lateDirtyInfo.LastWriteTimeUtc
    } finally {
        Set-Item -Path Function:\Open-CacheFileExclusiveRead -Value $originalExclusiveOpen
        Remove-Variable -Name TestCacheLateDirtyMetadataPath -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name TestCacheOriginalExclusiveOpen -Scope Global -ErrorAction SilentlyContinue
    }
    if ($lateDirtyRemoval.Success -or -not (Test-Path -LiteralPath $lateDirtyFile) -or -not (Test-Path -LiteralPath $lateDirtyMeta)) {
        throw 'Cleanup removed a VFS entry after its metadata changed to dirty during final validation.'
    }

    $raceCacheRoot = Join-Path $vfsSafetyDir 'gdrive_race'
    $raceVfsRoot = Join-Path $raceCacheRoot 'vfs\gdrive{historical}'
    $raceMetaRoot = Join-Path $raceCacheRoot 'vfsMeta\gdrive{historical}'
    [void][System.IO.Directory]::CreateDirectory($raceVfsRoot)
    [void][System.IO.Directory]::CreateDirectory($raceMetaRoot)
    $lateActiveFile = Join-Path $raceVfsRoot 'late-active.txt'
    $lateActiveMeta = Join-Path $raceMetaRoot 'late-active.txt'
    [System.IO.File]::WriteAllText($lateActiveFile, 'cache data')
    [System.IO.File]::WriteAllText($lateActiveMeta, '{"Dirty":false}')
    $lateActiveInfo = Get-Item -LiteralPath $lateActiveFile
    $originalOwnershipSnapshot = (Get-Command Get-CacheVfsOwnershipSnapshot).ScriptBlock
    $global:TestCacheOwnershipSnapshotCalls = 0
    $global:TestCacheOwnershipInitialRoot = $activeRoot
    $global:TestCacheOwnershipLateRoot = $raceVfsRoot
    try {
        Set-Item -Path Function:\Get-CacheVfsOwnershipSnapshot -Value {
            param([string]$CacheDirectory = '', [string[]]$ActiveCachePaths = @(), [switch]$ActiveCacheOwnershipKnown)
            $global:TestCacheOwnershipSnapshotCalls++
            $activeRoots = if ($global:TestCacheOwnershipSnapshotCalls -ge 3) { @([string]$global:TestCacheOwnershipLateRoot) } else { @([string]$global:TestCacheOwnershipInitialRoot) }
            $pathComparer = if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }
            return [pscustomobject]@{
                OwnershipKnown = $true
                ActiveRoots = $activeRoots
                ProtectedCacheRoots = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
                ActiveFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            }
        }
        $lateActiveRemoval = Invoke-SafeCacheCleanup -CacheDirectory $vfsSafetyDir -Force
        $ownershipSnapshotCallCount = [int]$global:TestCacheOwnershipSnapshotCalls
    } finally {
        Set-Item -Path Function:\Get-CacheVfsOwnershipSnapshot -Value $originalOwnershipSnapshot
        Remove-Variable -Name TestCacheOwnershipSnapshotCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name TestCacheOwnershipInitialRoot -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name TestCacheOwnershipLateRoot -Scope Global -ErrorAction SilentlyContinue
    }
    if ($ownershipSnapshotCallCount -lt 3 -or [int]$lateActiveRemoval.SkippedStagedCount -lt 1 -or
        -not (Test-Path -LiteralPath $lateActiveFile) -or -not (Test-Path -LiteralPath $lateActiveMeta)) {
        throw 'Cleanup removed a VFS entry after its root became active during final validation.'
    }
    Write-Output '  [PASS] Cleanup rechecks dirty metadata and active mount ownership at deletion time'
} finally {
    Remove-Item -Recurse -Force $vfsSafetyDir -ErrorAction SilentlyContinue
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
if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
    $unixHome = if ($env:HOME) { $env:HOME } else { [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) }
    $safetySys = Test-CacheDirectorySafety -Path (Join-Path $unixHome 'DummyTestCache')
    if (-not $safetySys.IsValid) {
        throw "A writable Linux cache path was marked invalid: $($safetySys.Issues -join ', ')"
    }
} else {
    $safetySys = Test-CacheDirectorySafety -Path (Join-Path $env:SystemDrive 'DummyTestCache')
    if (-not $safetySys.IsValid) {
        throw "System drive path was marked invalid instead of returning warnings: $($safetySys.Issues -join ', ')"
    }
    $hasOsWarn = $safetySys.Warnings | Where-Object { $_ -match 'operating system drive' }
    if (-not $hasOsWarn) {
        throw "Test-CacheDirectorySafety failed to warn when cache is located on operating system drive ($($env:SystemDrive))"
    }
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
    $vfsDataDir = Join-Path $mountCacheDir 'vfs\gdrive{test}\Docs'
    $vfsMetaDir = Join-Path $mountCacheDir 'vfsMeta\gdrive{test}\Docs'
    [System.IO.Directory]::CreateDirectory($mountCacheDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($unmanagedDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($vfsDataDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($vfsMetaDir) | Out-Null
    $fPartial = Join-Path $mountCacheDir 'stream.partial'
    $fRcloneTmp = Join-Path $mountCacheDir 'chunk.rclone-tmp'
    $fLegit = Join-Path $mountCacheDir 'persisted_document.pdf'
    $fUserTemporary = Join-Path $unmanagedDir 'draft.tmp'
    $fOwnedDataTemp = Join-Path $mountCacheDir ('.nscd-data-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $fOwnedMetaTemp = Join-Path $mountCacheDir ('.nscd-meta-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $fVfsTmpName = Join-Path $vfsDataDir 'report.tmp'
    $fVfsTmpMeta = Join-Path $vfsMetaDir 'report.tmp'
    $interruptedClaimDir = Join-Path $vfsDataDir ('.nscd-delete-' + [Guid]::NewGuid().ToString('N'))
    $interruptedClaimPayload = Join-Path $interruptedClaimDir 'recovered-vfs-file.tmp'
    $restoredClaimPath = Join-Path $vfsDataDir 'recovered-vfs-file.tmp'

    [System.IO.File]::WriteAllText($fPartial, 'incomplete')
    [System.IO.File]::WriteAllText($fRcloneTmp, 'temp_buffer')
    [System.IO.File]::WriteAllText($fLegit, 'valid_document')
    [System.IO.File]::WriteAllText($fUserTemporary, 'user_data')
    [System.IO.File]::WriteAllText($fOwnedDataTemp, 'abandoned app data temp')
    [System.IO.File]::WriteAllText($fOwnedMetaTemp, 'abandoned app metadata temp')
    [System.IO.File]::WriteAllText($fVfsTmpName, 'legitimate cloud file')
    [System.IO.File]::WriteAllText($fVfsTmpMeta, '{"Dirty":true}')
    [System.IO.Directory]::CreateDirectory($interruptedClaimDir) | Out-Null
    [System.IO.File]::WriteAllText($interruptedClaimPayload, 'preserve interrupted cache claim')
    $oldTempTime = [DateTime]::UtcNow.AddHours(-2)
    [System.IO.File]::SetLastWriteTimeUtc($fOwnedDataTemp, $oldTempTime)
    [System.IO.File]::SetLastWriteTimeUtc($fOwnedMetaTemp, $oldTempTime)
    [System.IO.File]::SetLastWriteTimeUtc($interruptedClaimPayload, $oldTempTime)
    [System.IO.Directory]::SetLastWriteTimeUtc($interruptedClaimDir, $oldTempTime)

    $recRes = Invoke-StartupCacheRecovery -CacheDirectory $recDir
    if ($recRes.RecoveredFiles -ne 3) {
        throw "Startup recovery expected 2 stale app temps and 1 interrupted claim restored, got: $($recRes.RecoveredFiles)"
    }
    if (-not (Test-Path $fPartial) -or -not (Test-Path $fRcloneTmp)) {
        throw 'Startup recovery must preserve generic partial and rclone temporary names inside account cache folders.'
    }
    if ((Test-Path $fOwnedDataTemp) -or (Test-Path $fOwnedMetaTemp)) {
        throw 'Stale app-owned cache temp files were not recovered.'
    }
    if (-not (Test-Path $fLegit)) {
        throw "Legitimate file was accidentally removed by startup recovery!"
    }
    if (-not (Test-Path $fVfsTmpName) -or -not (Test-Path $fVfsTmpMeta)) {
        throw 'Startup recovery must preserve temporary-looking files and dirty metadata inside VFS trees.'
    }
    if (-not (Test-Path $restoredClaimPath) -or (Test-Path $interruptedClaimDir)) {
        throw 'Startup recovery did not safely restore a stale atomic delete claim after interruption.'
    }
    if (-not (Test-Path $fUserTemporary)) {
        throw 'Startup recovery must not remove temporary-looking files outside managed account cache directories'
    }

    $customCacheBase = Join-Path $recDir 'custom-cache-base'
    $customMountCacheDir = Join-Path $customCacheBase 'terabox_testaccount'
    [System.IO.Directory]::CreateDirectory($customMountCacheDir) | Out-Null
    $customPartial = Join-Path $customMountCacheDir ('.nscd-data-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($customPartial, 'custom_cache')
    [System.IO.File]::SetLastWriteTimeUtc($customPartial, $oldTempTime)
    $customRes = Invoke-StartupCacheRecovery -CacheDirectory $recDir -MountCacheDirectories @($customMountCacheDir)
    if ($customRes.RecoveredFiles -ne 1 -or (Test-Path -LiteralPath $customPartial)) {
        throw 'Explicit per-account cache paths should recover stale app-owned temp files in a custom cache base'
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

if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
    Write-Output '  -> Testing atomic cache deletion against a path replacement race...'
    $claimTestDir = Join-Path ([System.IO.Path]::GetTempPath()) ('cache_claim_test_' + [Guid]::NewGuid().ToString('N'))
    [System.IO.Directory]::CreateDirectory($claimTestDir) | Out-Null
    $claimTarget = Join-Path $claimTestDir 'target.bin'
    $heldOriginal = Join-Path $claimTestDir 'held-original.bin'
    $claimStream = $null
    try {
        [System.IO.File]::WriteAllText($claimTarget, 'confirmed revision')
        $claimStream = Open-CacheFileExclusiveRead -Path $claimTarget
        $expectedClaimHash = Get-CacheStreamSha256 -Stream $claimStream
        [System.IO.File]::Move($claimTarget, $heldOriginal)
        [System.IO.File]::WriteAllText($claimTarget, 'new unrelated revision')
        $expectedReplacementHash = (Get-FileHash -LiteralPath $claimTarget -Algorithm SHA256).Hash

        $replacementRejected = $false
        try {
            Remove-CacheFileByExclusiveHandle -Path $claimTarget -Stream $claimStream -ExpectedSha256 $expectedClaimHash
        } catch {
            $replacementRejected = $true
        }
        if (-not $replacementRejected -or
            -not (Test-Path -LiteralPath $claimTarget -PathType Leaf) -or
            (Get-FileHash -LiteralPath $claimTarget -Algorithm SHA256).Hash -ne $expectedReplacementHash -or
            -not (Test-Path -LiteralPath $heldOriginal -PathType Leaf) -or
            (Get-CacheStreamSha256 -Stream $claimStream) -ne $expectedClaimHash) {
            throw 'Atomic cache deletion did not preserve the replacement and held original after a path race.'
        }
        $leftoverClaims = @(Get-ChildItem -LiteralPath $claimTestDir -Directory -Force -Filter '.nscd-delete-*')
        if ($leftoverClaims.Count -gt 0) { throw 'A rejected path replacement left an unnecessary cache claim directory.' }
    } finally {
        if ($claimStream) { $claimStream.Dispose() }
        foreach ($knownPath in @($claimTarget, $heldOriginal)) {
            if ([System.IO.File]::Exists($knownPath)) { [System.IO.File]::Delete($knownPath) }
        }
        if ([System.IO.Directory]::Exists($claimTestDir)) { [System.IO.Directory]::Delete($claimTestDir, $false) }
    }
    Write-Output '  [PASS] Unix atomic claim preserved different content moved onto the verified cache path'
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
    $vfsMetaDir = Join-Path $gdriveAccDir 'vfsMeta\gdrive{mock}\Docs'
    [System.IO.Directory]::CreateDirectory($vfsMetaDir) | Out-Null

    $fileA = Join-Path $vfsDir 'sample.pdf'
    $fileB = Join-Path $vfsDir 'locked.dat'
    $fileDirty = Join-Path $vfsDir 'dirty-upload.bin'
    [System.IO.File]::WriteAllText($fileA, 'sample pdf content for cache inspection testing')
    [System.IO.File]::WriteAllText($fileB, 'locked data content')
    [System.IO.File]::WriteAllText($fileDirty, 'must remain until remote confirmation')
    [System.IO.File]::WriteAllText((Join-Path $vfsMetaDir 'sample.pdf'), '{"Dirty":false}')
    [System.IO.File]::WriteAllText((Join-Path $vfsMetaDir 'locked.dat'), '{"Dirty":false}')
    [System.IO.File]::WriteAllText((Join-Path $vfsMetaDir 'dirty-upload.bin'), '{"Dirty":true}')

    # Lock fileB
    $lockStream = [System.IO.File]::Open($fileB, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $fileList = @(Get-DetailedCacheFileList -CacheDirectory $detailDir -ActiveCacheOwnershipKnown)
        if ($fileList.Count -lt 3) {
            throw "Expected at least 3 files in detailed cache list, got: $($fileList.Count)"
        }

        $itemA = $fileList | Where-Object { $_.FileName -eq 'sample.pdf' } | Select-Object -First 1
        $itemB = $fileList | Where-Object { $_.FileName -eq 'locked.dat' } | Select-Object -First 1
        $itemDirty = $fileList | Where-Object { $_.FileName -eq 'dirty-upload.bin' } | Select-Object -First 1

        if (-not $itemA -or $itemA.IsEvictable -ne $true -or $itemA.Status -ne 'Cloud-confirmed cache') {
            throw "File A (sample.pdf) was not recognized as remotely confirmed and evictable: $($itemA | Out-String)"
        }
        if (-not $itemB -or $itemB.IsEvictable -ne $false -or $itemB.Status -notmatch 'In-Use') {
            throw "File B (locked.dat) was not recognized as locked/in-use: $($itemB | Out-String)"
        }
        if (-not $itemDirty -or $itemDirty.IsEvictable -or $itemDirty.Status -ne 'Upload state unknown or pending') {
            throw "Dirty staged file was incorrectly marked evictable: $($itemDirty | Out-String)"
        }

        # Attempt to evict locked file - must fail gracefully
        $evictLocked = Remove-SingleCacheFile -FilePath $fileB -CacheDirectory $detailDir -ActiveCacheOwnershipKnown
        if ($evictLocked.Success -eq $true) {
            throw 'Remove-SingleCacheFile should have failed for a locked in-use file'
        }
        $evictDirty = Remove-SingleCacheFile -FilePath $fileDirty -CacheDirectory $detailDir -ActiveCacheOwnershipKnown
        if ($evictDirty.Success -eq $true -or -not (Test-Path -LiteralPath $fileDirty)) {
            throw 'Remove-SingleCacheFile removed dirty staged data before remote confirmation'
        }
    } finally {
        $lockStream.Dispose()
    }

    # Now evict sample.pdf - must succeed
    $evictRes = Remove-SingleCacheFile -FilePath $fileA -CacheDirectory $detailDir -ActiveCacheOwnershipKnown
    if (-not $evictRes.Success) {
        throw "Failed to evict sample.pdf: $($evictRes.Error)"
    }
    if (Test-Path -LiteralPath $fileA) {
        throw 'sample.pdf still exists on disk after eviction'
    }
    if (Test-Path -LiteralPath (Join-Path $vfsMetaDir 'sample.pdf')) {
        throw 'The paired clean VFS metadata was not removed with sample.pdf'
    }

    Write-Output '  [PASS] Detailed cache file list and single-file eviction verified'
} finally {
    Remove-Item -Recurse -Force $detailDir -ErrorAction SilentlyContinue
}

# 8. Historical inactive VFS roots clean only old, explicitly clean files
Write-Output '  -> Testing inactive VFS cache cleanup boundaries...'
$vfsTestRoot = Join-Path $tempDir 'gdrive_vfs_test'
$oldVfsRoot = Join-Path $vfsTestRoot 'vfs\gdrive{old}'
$activeVfsRoot = Join-Path $vfsTestRoot 'vfs\gdrive{active}'
$oldMetaRoot = Join-Path $vfsTestRoot 'vfsMeta\gdrive{old}'
$activeMetaRoot = Join-Path $vfsTestRoot 'vfsMeta\gdrive{active}'
foreach ($dir in @($oldVfsRoot, $activeVfsRoot, $oldMetaRoot, $activeMetaRoot)) {
    [void][System.IO.Directory]::CreateDirectory($dir)
}
$oldCleanFile = Join-Path $oldVfsRoot 'expired.pdf'
$oldCleanMeta = Join-Path $oldMetaRoot 'expired.pdf'
$oldDirtyFile = Join-Path $oldVfsRoot 'dirty.bin'
$oldDirtyMeta = Join-Path $oldMetaRoot 'dirty.bin'
$oldUnknownFile = Join-Path $oldVfsRoot 'unknown.bin'
$activeFile = Join-Path $activeVfsRoot 'active.pdf'
$activeMeta = Join-Path $activeMetaRoot 'active.pdf'
[System.IO.File]::WriteAllText($oldCleanFile, 'verified cache')
$oldActivityStamp = [DateTime]::UtcNow.AddHours(-3).ToString('o')
[System.IO.File]::WriteAllText($oldCleanMeta, (@{ Dirty = $false; ATime = $oldActivityStamp; ModTime = $oldActivityStamp } | ConvertTo-Json -Compress))
[System.IO.File]::WriteAllText($oldDirtyFile, 'pending upload')
$oldDirtyStamp = [DateTime]::UtcNow.AddHours(-3).ToString('o')
[System.IO.File]::WriteAllText($oldDirtyMeta, (@{ Dirty = $true; ATime = $oldDirtyStamp; ModTime = $oldDirtyStamp } | ConvertTo-Json -Compress))
[System.IO.File]::WriteAllText($oldUnknownFile, 'ambiguous data')
[System.IO.File]::WriteAllText($activeFile, 'live cache')
$activeStamp = [DateTime]::UtcNow.AddHours(-3).ToString('o')
[System.IO.File]::WriteAllText($activeMeta, (@{ Dirty = $false; ATime = $activeStamp; ModTime = $activeStamp } | ConvertTo-Json -Compress))
foreach ($path in @($oldCleanFile, $oldDirtyFile, $oldUnknownFile, $activeFile)) {
    (Get-Item -LiteralPath $path).LastAccessTimeUtc = [DateTime]::UtcNow.AddHours(-3)
    (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-3)
}

$global:TestCacheManagerActiveVfsRoot = $activeVfsRoot
$global:TestCacheManagerOwnershipMode = 'Idle'
$global:TestCacheManagerAccount = [pscustomobject]@{ Id = 'gdrive_vfs_test'; ProviderId = 'gdrive'; DriveLetter = ''; CacheDirectory = $tempDir }
function Get-CloudAccounts { return @($global:TestCacheManagerAccount) }
function Get-VirtualDriveVfsStats {
    param([string]$DriveLetter = '', [string]$AccountId = '', [string]$ProviderId = '')
    if ($global:TestCacheManagerOwnershipMode -eq 'Unknown' -and $AccountId) {
        return @{ IsActive = $false; State = 'Remote state unknown'; DiskCachePath = ''; Transferring = @(); QueuedItems = @() }
    }
    if ($ProviderId -eq 'terabox') {
        return @{ IsActive = $false; State = 'Unmounted'; DiskCachePath = ''; Transferring = @(); QueuedItems = @() }
    }
    if ($global:TestCacheManagerOwnershipMode -eq 'Active') {
        return @{ IsActive = $true; State = 'Remotely confirmed'; DiskCachePath = [string]$global:TestCacheManagerActiveVfsRoot; Transferring = @(); QueuedItems = @() }
    }
    return @{ IsActive = $false; State = 'Unmounted'; DiskCachePath = ''; Transferring = @(); QueuedItems = @() }
}
function Get-VirtualDriveStatus {
    param([string]$DriveLetter = '', [string]$AccountId = '', [string]$ProviderId = '')
    if ($global:TestCacheManagerOwnershipMode -eq 'Unknown' -and $AccountId) {
        return @{ IsMounted = $true; ProcessRunning = $true; DriveLetter = 'G' }
    }
    return @{ IsMounted = $false; ProcessRunning = $false; DriveLetter = '' }
}
try {
    $inactiveCleanup = Invoke-InactivityCacheEviction -CacheDirectory $tempDir -ActiveCachePaths @($activeVfsRoot)
    if ($inactiveCleanup.EvictedFiles -ne 1 -or (Test-Path -LiteralPath $oldCleanFile)) {
        throw "Expected one explicitly clean inactive VFS entry to expire, got $($inactiveCleanup.EvictedFiles)."
    }
    if (-not (Test-Path -LiteralPath $oldDirtyFile) -or -not (Test-Path -LiteralPath $oldUnknownFile) -or -not (Test-Path -LiteralPath $activeFile)) {
        throw 'Inactive cleanup removed dirty, unknown-metadata, or active-root cache data.'
    }

    $unknownOwnershipRoot = Join-Path $tempDir 'unknown_mount_ownership'
    $unknownAccountRoot = Join-Path $unknownOwnershipRoot 'gdrive_active'
    $unknownVfsRoot = Join-Path $unknownAccountRoot 'vfs\gdrive{unknown}'
    $unknownMetaRoot = Join-Path $unknownAccountRoot 'vfsMeta\gdrive{unknown}'
    [void][System.IO.Directory]::CreateDirectory($unknownVfsRoot)
    [void][System.IO.Directory]::CreateDirectory($unknownMetaRoot)
    $unknownMountFile = Join-Path $unknownVfsRoot 'keep.txt'
    [System.IO.File]::WriteAllText($unknownMountFile, 'still owned by rclone')
    [System.IO.File]::WriteAllText((Join-Path $unknownMetaRoot 'keep.txt'), '{"Dirty":false}')
    $global:TestCacheManagerOwnershipMode = 'Unknown'
    $global:TestCacheManagerAccount = [pscustomobject]@{ Id = 'active'; ProviderId = 'gdrive'; DriveLetter = 'G'; CacheDirectory = $unknownOwnershipRoot }
    $unknownCleanup = Invoke-SafeCacheCleanup -CacheDirectory $unknownOwnershipRoot -Force
    if (-not (Test-Path -LiteralPath $unknownMountFile) -or [int]$unknownCleanup.SkippedStagedCount -lt 1) {
        throw 'Force cleanup removed VFS data while RC ownership was unknown but the mount process was live.'
    }

    $noLetterRoot = Join-Path $tempDir 'mount_without_saved_letter'
    $noLetterAccountRoot = Join-Path $noLetterRoot 'gdrive_noletter'
    $global:TestCacheManagerOwnershipMode = 'Active'
    $global:TestCacheManagerAccount = [pscustomobject]@{ Id = 'noletter'; ProviderId = 'gdrive'; DriveLetter = ''; CacheDirectory = $noLetterRoot }
    $global:TestCacheManagerActiveVfsRoot = Join-Path $noLetterAccountRoot 'vfs'
    $noLetterVfs = Join-Path $global:TestCacheManagerActiveVfsRoot 'gdrive{mounted}'
    $noLetterMeta = Join-Path $noLetterAccountRoot 'vfsMeta\gdrive{mounted}'
    [void][System.IO.Directory]::CreateDirectory($noLetterVfs)
    [void][System.IO.Directory]::CreateDirectory($noLetterMeta)
    $noLetterFile = Join-Path $noLetterVfs 'live.txt'
    [System.IO.File]::WriteAllText($noLetterFile, 'live mount data')
    [System.IO.File]::WriteAllText((Join-Path $noLetterMeta 'live.txt'), '{"Dirty":false}')
    (Get-Item -LiteralPath $noLetterFile).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-3)
    (Get-Item -LiteralPath $noLetterFile).LastAccessTimeUtc = [DateTime]::UtcNow.AddHours(-3)
    $letterlessCleanup = Invoke-InactivityCacheEviction -CacheDirectory $noLetterRoot
    if (-not (Test-Path -LiteralPath $noLetterFile) -or $letterlessCleanup.EvictedFiles -ne 0) {
        throw 'Inactive-cache eviction did not detect an active mount whose saved DriveLetter was blank.'
    }
    Write-Output '  [PASS] Inactive eviction handles blank drive letters; force clear preserves live mounts during RC outages'
} finally {
    Remove-Item Function:\Get-CloudAccounts -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-VirtualDriveVfsStats -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-VirtualDriveStatus -ErrorAction SilentlyContinue
    Remove-Variable -Name TestCacheManagerActiveVfsRoot -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name TestCacheManagerOwnershipMode -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name TestCacheManagerAccount -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $vfsTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All Cache Management tests passed.'
