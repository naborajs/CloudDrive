Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'SettingsManager.ps1')

# ==============================================================================
# IN-USE FILE AND PROCESS DETECTION
# ==============================================================================

function Test-FileInUse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Dispose()
        return $false
    } catch {
        return $true
    }
}

# ==============================================================================
# DETAILED CACHE USAGE STATISTICS
# ==============================================================================

function Get-DetailedCacheStatistics {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = ''
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
    }

    $totalBytes = 0L
    $fileCount = 0
    $inUseBytes = 0L
    $inUseCount = 0

    $resolvedDir = $CacheDirectory
    if (Test-Path -LiteralPath $CacheDirectory) {
        try {
            $resolvedDir = (Resolve-Path -LiteralPath $CacheDirectory).Path
            $files = Get-ChildItem -LiteralPath $resolvedDir -Recurse -File -Force -ErrorAction SilentlyContinue
            if ($files) {
                foreach ($f in $files) {
                    $len = [int64]$f.Length
                    $totalBytes += $len
                    $fileCount++

                    if (Test-FileInUse -FilePath $f.FullName) {
                        $inUseBytes += $len
                        $inUseCount++
                    }
                }
            }
        } catch { }
    }

    $evictableBytes = [Math]::Max(0L, ($totalBytes - $inUseBytes))

    # Drive space and OS drive detection
    $driveFreeBytes = 0L
    $driveTotalBytes = 0L
    $isSystemDrive = $false
    $driveLetter = ''

    try {
        $root = [System.IO.Path]::GetPathRoot($resolvedDir)
        if ($root) {
            $driveLetter = $root.Substring(0, 1).ToUpperInvariant()
            $dInfo = [System.IO.DriveInfo]::new($driveLetter)
            if ($dInfo.IsReady) {
                $driveFreeBytes = [int64]$dInfo.AvailableFreeSpace
                $driveTotalBytes = [int64]$dInfo.TotalSize
            }
            $sysDriveRoot = [System.IO.Path]::GetPathRoot($env:SystemDrive)
            if ($sysDriveRoot -and $root.StartsWith($sysDriveRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $isSystemDrive = $true
            }
        }
    } catch { }

    return [ordered]@{
        CacheDirectory = $resolvedDir
        TotalSizeBytes = $totalBytes
        TotalFileCount = $fileCount
        InUseBytes = $inUseBytes
        InUseCount = $inUseCount
        EvictableBytes = $evictableBytes
        DriveLetter = $driveLetter
        DriveFreeBytes = $driveFreeBytes
        DriveTotalBytes = $driveTotalBytes
        IsSystemDrive = $isSystemDrive
    }
}

# ==============================================================================
# INACTIVITY-BASED SAFE READ/PREVIEW CACHE EVICTION
# ==============================================================================

function Invoke-InactivityCacheEviction {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [string[]]$MountCacheDirectories = @()
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
    }

    $managedDirectories = @(Get-ManagedCacheDirectories -CacheDirectory $CacheDirectory -MountCacheDirectories $MountCacheDirectories)
    if ($managedDirectories.Count -eq 0) {
        return [ordered]@{
            EvictedBytes = 0L
            EvictedFiles = 0
            SkippedInUseCount = 0
            SkippedStagedCount = 0
            Errors = @()
        }
    }

    # Strict binary thresholds:
    # 1 GB = 1073741824 bytes
    # 3 GB = 3221225472 bytes
    $ONE_GB = 1073741824L
    $THREE_GB = 3221225472L

    $nowUtc = [DateTime]::UtcNow
    $evictedBytes = 0L
    $evictedFiles = 0
    $skippedInUse = 0
    $skippedStaged = 0
    $skippedRcloneOwned = 0
    $errors = [System.Collections.Generic.List[string]]::new()

    # Query active rclone transfers across accounts to prevent evicting files being actively read, streamed, or uploaded
    $activeTransferFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ((Get-Command Get-CloudAccounts -ErrorAction SilentlyContinue) -and (Get-Command Get-VirtualDriveVfsStats -ErrorAction SilentlyContinue)) {
        try {
            $accounts = @(Get-CloudAccounts)
            foreach ($acc in $accounts) {
                $accLetter = [string](Get-SafeProperty $acc 'DriveLetter' '')
                if (-not $accLetter) { continue }
                $vfs = Get-VirtualDriveVfsStats -DriveLetter $accLetter
                $vfsTransferring = @(Get-SafeProperty $vfs 'Transferring' @())
                foreach ($tr in $vfsTransferring) {
                    $trName = [string](Get-SafeProperty $tr 'Name' '')
                    if ($trName) { $activeTransferFileNames.Add([System.IO.Path]::GetFileName($trName)) | Out-Null }
                    $rel = [string](Get-SafeProperty $tr 'RelativePath' '')
                    if ($rel) { $activeTransferFileNames.Add([System.IO.Path]::GetFileName($rel)) | Out-Null }
                }
                $vfsQueued = @(Get-SafeProperty $vfs 'QueuedItems' @())
                foreach ($qi in $vfsQueued) {
                    $qName = [string](Get-SafeProperty $qi 'Name' '')
                    if ($qName) { $activeTransferFileNames.Add([System.IO.Path]::GetFileName($qName)) | Out-Null }
                    $qRel = [string](Get-SafeProperty $qi 'RelativePath' '')
                    if ($qRel) { $activeTransferFileNames.Add([System.IO.Path]::GetFileName($qRel)) | Out-Null }
                }
            }
        } catch { }
    }

    foreach ($managedDir in $managedDirectories) {
        if (-not (Test-Path -LiteralPath $managedDir -PathType Container)) { continue }

        $vfsDir = Join-Path $managedDir 'vfs'
        $scanTarget = $managedDir

        $files = Get-ChildItem -LiteralPath $scanTarget -Recurse -File -Force -ErrorAction SilentlyContinue
        if (-not $files) { continue }

        foreach ($f in $files) {
            # rclone owns everything under its VFS read cache and its metadata. Its own
            # --vfs-cache-max-age/--vfs-cache-max-size are authoritative; deleting files
            # behind a running mount causes 'detected external removal of cache file'
            # and an immediate re-download, which looks like a repeated transfer.
            if ($f.FullName -match '[\\/]vfs[\\/]' -or $f.FullName -match '[\\/]vfsMeta[\\/]') {
                $skippedRcloneOwned++
                continue
            }

            # Do NOT evict files actively being transferred or in-use by any process
            if ($activeTransferFileNames.Contains($f.Name) -or $activeTransferFileNames.Contains([System.IO.Path]::GetFileName($f.FullName)) -or (Test-FileInUse -FilePath $f.FullName)) {
                $skippedInUse++
                continue
            }

            $isDirty = $false
            $metaPath = ''
            $metaJson = $null
            if ($f.FullName -match '([\\/])vfs([\\/])') {
                $metaPath = $f.FullName -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
                if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
                    if (Test-FileInUse -FilePath $metaPath) {
                        $skippedInUse++
                        continue
                    }
                    try {
                        $metaJson = Get-Content -LiteralPath $metaPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                        if ($metaJson -and $metaJson.PSObject.Properties['Dirty'] -and $metaJson.Dirty -eq $true) {
                            $isDirty = $true
                        }
                    } catch {
                        $isDirty = $true
                    }
                }
            }

            # Never evict dirty/staged files
            if ($isDirty) {
                $skippedStaged++
                continue
            }

            # Size-dependent inactivity calculation
            $fileLen = [int64]$f.Length
            $latestActivity = $f.LastWriteTimeUtc
            if ($f.LastAccessTimeUtc -gt $latestActivity -and $f.LastAccessTimeUtc -le $nowUtc) {
                $latestActivity = $f.LastAccessTimeUtc
            }

            if ($metaJson) {
                if ($metaJson.PSObject.Properties['ATime'] -and $metaJson.ATime) {
                    try {
                        $metaATime = [DateTime]::Parse([string]$metaJson.ATime).ToUniversalTime()
                        if ($metaATime -gt $latestActivity) {
                            $latestActivity = if ($metaATime -gt $nowUtc) { $nowUtc } else { $metaATime }
                        }
                    } catch { }
                }
                if ($metaJson.PSObject.Properties['ModTime'] -and $metaJson.ModTime) {
                    try {
                        $metaModTime = [DateTime]::Parse([string]$metaJson.ModTime).ToUniversalTime()
                        if ($metaModTime -gt $latestActivity) {
                            $latestActivity = if ($metaModTime -gt $nowUtc) { $nowUtc } else { $metaModTime }
                        }
                    } catch { }
                }
            }

            $lastActivity = $latestActivity
            $inactivityMinutes = ($nowUtc - $lastActivity).TotalMinutes

            # Inactivity windows:
            # - Smaller than 1 GB (< 1073741824 bytes): 5 minutes
            # - 1 GB through 3 GB inclusive (1073741824 to 3221225472 bytes): 20 minutes
            # - Larger than 3 GB (> 3221225472 bytes): 45 minutes
            $shouldEvict = $false
            if ($fileLen -lt $ONE_GB) {
                if ($inactivityMinutes -ge 5.0) { $shouldEvict = $true }
            } elseif ($fileLen -ge $ONE_GB -and $fileLen -le $THREE_GB) {
                if ($inactivityMinutes -ge 20.0) { $shouldEvict = $true }
            } else {
                if ($inactivityMinutes -ge 45.0) { $shouldEvict = $true }
            }

            if ($shouldEvict) {
                try {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    if ($metaPath -and (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
                        Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
                    }
                    $evictedFiles++
                    $evictedBytes += $fileLen
                } catch {
                    $errors.Add("Failed to evict inactive cache file '$($f.FullName)': $($_.Exception.Message)")
                }
            }
        }
    }

    return [ordered]@{
        EvictedBytes = $evictedBytes
        EvictedFiles = $evictedFiles
        SkippedInUseCount = $skippedInUse
        SkippedStagedCount = $skippedStaged
        SkippedRcloneOwnedCount = $skippedRcloneOwned
        Errors = @($errors.ToArray())
    }
}

# ==============================================================================
# CACHE DIRECTORY VALIDATION & OS PROTECTION
# ==============================================================================

function Test-CacheDirectorySafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $issues = @()
    $warnings = @()

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ IsValid = $false; Issues = @('Cache directory path cannot be empty.'); Warnings = @() }
    }

    # Volume validation
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root) {
            $issues += "Invalid path structure: $Path"
        } else {
            $dInfo = [System.IO.DriveInfo]::new($root.Substring(0, 1))
            if (-not $dInfo.IsReady) {
                $issues += "Target drive '$root' is not ready or accessible."
            } else {
                if ($dInfo.DriveType -ne [System.IO.DriveType]::Fixed) {
                    $warnings += "Target drive is of type '$($dInfo.DriveType)'. Fixed internal NTFS drives are recommended."
                }
                if ($dInfo.AvailableFreeSpace -lt 5GB) {
                    $warnings += "Target drive has less than 5 GB available free space ($([Math]::Round($dInfo.AvailableFreeSpace / 1GB, 1)) GB)."
                }
                $sysRoot = [System.IO.Path]::GetPathRoot($env:SystemDrive)
                if ($sysRoot -and $root.StartsWith($sysRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    $warnings += "Cache is located on the operating system drive ($root). Placing cloud cache on secondary storage is recommended to protect OS disk space."
                }
            }
        }
    } catch {
        $issues += "Could not inspect drive volume for '$Path': $($_.Exception.Message)"
    }

    # Write permission test
    if ($issues.Count -eq 0) {
        try {
            if (-not (Test-Path -LiteralPath $Path)) {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
            }
            $testFile = Join-Path $Path (".write_test_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            [System.IO.File]::WriteAllText($testFile, "test")
            [System.IO.File]::Delete($testFile)
        } catch {
            $issues += "Target path is not writable: $($_.Exception.Message)"
        }
    }

    return @{
        IsValid = ($issues.Count -eq 0)
        Issues = $issues
        Warnings = $warnings
    }
}

# ==============================================================================
# SAFE CACHE CLEANUP & LRU SIZE ENFORCEMENT
# ==============================================================================

function Get-ManagedCacheDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheDirectory,
        [string[]]$MountCacheDirectories = @()
    )

    $managedDirectoryPattern = '^(?:gdrive|terabox)(?:_[A-Za-z0-9_-]{1,128})?$'
    $targets = [System.Collections.Generic.List[string]]::new()
    if ($MountCacheDirectories.Count -gt 0) {
        foreach ($directory in $MountCacheDirectories) {
            if ([string]::IsNullOrWhiteSpace($directory)) { continue }
            $mountKey = [System.IO.Path]::GetFileName($directory.TrimEnd('\', '/'))
            if ($mountKey -notmatch $managedDirectoryPattern) {
                throw 'Refusing cache operation for a directory outside an account cache namespace.'
            }
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
            $targetInfo = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
            $singleTarget = if ($targetInfo -is [System.Array]) { $targetInfo[0] } else { $targetInfo }
            if ([bool]($singleTarget.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))) {
                throw "Refusing cache operation on a reparse-point account cache path: $directory"
            }
            $targets.Add($singleTarget.FullName)
        }
    } elseif (Test-Path -LiteralPath $CacheDirectory -PathType Container) {
        foreach ($directory in Get-ChildItem -LiteralPath $CacheDirectory -Directory -Force -ErrorAction Stop) {
            if ($directory.Name -notmatch $managedDirectoryPattern) { continue }
            $singleDir = if ($directory -is [System.Array]) { $directory[0] } else { $directory }
            if ([bool]($singleDir.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))) {
                throw "Refusing cache operation on a reparse-point account cache path: $($singleDir.FullName)"
            }
            $targets.Add($singleDir.FullName)
        }
    }

    return $targets.ToArray()
}

function Invoke-SafeCacheCleanup {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [string[]]$MountCacheDirectories = @(),
        [int64]$TargetMaxBytes = -1L,
        [int]$MaxAgeHours = 0,
        [switch]$Force
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
        if ($TargetMaxBytes -lt 0L) {
            $TargetMaxBytes = [int64]($settings.CacheMaxGigabytes) * 1GB
        }
    }

    $managedDirectories = @(Get-ManagedCacheDirectories -CacheDirectory $CacheDirectory -MountCacheDirectories $MountCacheDirectories)
    if ($managedDirectories.Count -eq 0) {
        return [ordered]@{
            CleanedBytes = 0L
            CleanedFiles = 0
            SkippedInUseCount = 0
            SkippedInUseBytes = 0L
            RemainingBytes = 0L
            UnmountRequired = $false
            Errors = @()
        }
    }

    $allFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    foreach ($managedDirectory in $managedDirectories) {
        Get-ChildItem -LiteralPath $managedDirectory -Recurse -File -Force -ErrorAction Stop |
            ForEach-Object { $allFiles.Add($_) }
    }

    if ($allFiles.Count -eq 0) {
        return [ordered]@{
            CleanedBytes = 0L
            CleanedFiles = 0
            SkippedInUseCount = 0
            SkippedInUseBytes = 0L
            RemainingBytes = 0L
            UnmountRequired = $false
            Errors = @()
        }
    }

    $cleanedBytes = 0L
    $cleanedFiles = 0
    $skippedInUseCount = 0
    $skippedInUseBytes = 0L
    $skippedStagedCount = 0
    $skippedStagedBytes = 0L
    $errors = [System.Collections.Generic.List[string]]::new()
    $totalBytes = 0L
    foreach ($file in $allFiles) { $totalBytes += [int64]$file.Length }

    $evictableCandidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $nowUtc = [DateTime]::UtcNow

    # First pass: Categorize in-use, staged/dirty vs evictable files
    foreach ($f in $allFiles) {
        # Skip vfsMeta files from direct deletion
        if ($f.FullName -match '[\\/]vfsMeta[\\/]') { continue }

        if (Test-FileInUse -FilePath $f.FullName) {
            $skippedInUseCount++
            $skippedInUseBytes += [int64]$f.Length
            continue
        }

        # Check if file is dirty/staged for cloud upload
        $isDirty = $false
        $metaPath = ''
        if ($f.FullName -match '([\\/])vfs([\\/])') {
            $metaPath = $f.FullName -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
            if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
                try {
                    $metaJson = Get-Content -LiteralPath $metaPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                    if ($metaJson -and $metaJson.PSObject.Properties['Dirty'] -and $metaJson.Dirty -eq $true) {
                        $isDirty = $true
                    }
                } catch {
                    $isDirty = $true
                }
            }
        }

        if ($isDirty) {
            # Staged files must NEVER be evicted by cleanup
            $skippedStagedCount++
            $skippedStagedBytes += [int64]$f.Length
            continue
        }

        # If MaxAgeHours specified and file is older, clean immediately
        if ($MaxAgeHours -gt 0) {
            $lastAccess = if ($f.LastAccessTimeUtc -gt [DateTime]::MinValue) { $f.LastAccessTimeUtc } else { $f.LastWriteTimeUtc }
            if (($nowUtc - $lastAccess).TotalHours -ge $MaxAgeHours) {
                try {
                    $len = [int64]$f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    if ($metaPath -and (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
                        Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
                    }
                    $cleanedBytes += $len
                    $cleanedFiles++
                    continue
                } catch {
                    $errors.Add("Could not remove cache file '$($f.FullName)': $($_.Exception.Message)")
                }
            }
        }

        # If Force clear requested, delete immediately
        if ($Force) {
            try {
                $len = [int64]$f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                if ($metaPath -and (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
                }
                $cleanedBytes += $len
                $cleanedFiles++
                continue
            } catch {
                $errors.Add("Could not remove cache file '$($f.FullName)': $($_.Exception.Message)")
            }
        }

        $evictableCandidates.Add($f)
    }

    # Second pass: If size limit is configured and current size still exceeds target, evict LRU (oldest accessed first)
    if (-not $Force -and $TargetMaxBytes -gt 0L) {
        $currentTotal = $skippedInUseBytes + $skippedStagedBytes
        foreach ($c in $evictableCandidates) { $currentTotal += [int64]$c.Length }

        if ($currentTotal -gt $TargetMaxBytes) {
            $sorted = $evictableCandidates | Sort-Object -Property @{ Expression = { if ($_.LastAccessTimeUtc -gt [DateTime]::MinValue) { $_.LastAccessTimeUtc } else { $_.LastWriteTimeUtc } } }

            foreach ($item in $sorted) {
                if ($currentTotal -le $TargetMaxBytes) {
                    break
                }
                try {
                    $len = [int64]$item.Length
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                    $itemMeta = if ($item.FullName -match '([\\/])vfs([\\/])') { $item.FullName -replace '([\\/])vfs([\\/])', '$1vfsMeta$2' } else { '' }
                    if ($itemMeta -and (Test-Path -LiteralPath $itemMeta -PathType Leaf)) {
                        Remove-Item -LiteralPath $itemMeta -Force -ErrorAction SilentlyContinue
                    }
                    $cleanedBytes += $len
                    $cleanedFiles++
                    $currentTotal -= $len
                } catch {
                    $errors.Add("Could not remove cache file '$($item.FullName)': $($_.Exception.Message)")
                }
            }
        }
    }

    # Clean up empty subdirectories
    foreach ($managedDirectory in $managedDirectories) {
        Get-ChildItem -LiteralPath $managedDirectory -Recurse -Directory -Force -ErrorAction Stop |
            Sort-Object -Property { $_.FullName.Length } -Descending |
            ForEach-Object {
                $directory = $_
                if (@(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop).Count -eq 0) {
                    try {
                        Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
                    } catch {
                        $errors.Add("Could not remove empty cache directory '$($directory.FullName)': $($_.Exception.Message)")
                    }
                }
            }
    }

    $remaining = [Math]::Max(0L, $totalBytes - $cleanedBytes)

    return [ordered]@{
        CleanedBytes = $cleanedBytes
        CleanedFiles = $cleanedFiles
        SkippedInUseCount = $skippedInUseCount
        SkippedInUseBytes = $skippedInUseBytes
        SkippedStagedCount = $skippedStagedCount
        SkippedStagedBytes = $skippedStagedBytes
        RemainingBytes = $remaining
        UnmountRequired = ($skippedInUseCount -gt 0)
        Errors = @($errors.ToArray())
    }
}

# ==============================================================================
# STARTUP RECOVERY (ORPHANED CHUNKS & PARTIAL TRANSFERS)
# ==============================================================================

function Invoke-StartupCacheRecovery {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [string[]]$MountCacheDirectories = @()
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
    }

    $recoveryTargets = @(Get-ManagedCacheDirectories -CacheDirectory $CacheDirectory -MountCacheDirectories $MountCacheDirectories)

    $recoveredFiles = 0
    $recoveredBytes = 0L
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($recoveryTarget in $recoveryTargets) {
        if (-not (Test-Path -LiteralPath $recoveryTarget -PathType Container)) { continue }
        $targetInfo = Get-Item -LiteralPath $recoveryTarget -Force -ErrorAction Stop
        $singleTarget = if ($targetInfo -is [System.Array]) { $targetInfo[0] } else { $targetInfo }
        if ([bool]($singleTarget.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))) {
            $errors.Add("Skipped cache recovery because the account cache path is a reparse point: $recoveryTarget")
            continue
        }

        Get-ChildItem -LiteralPath $recoveryTarget -Recurse -File -Force -ErrorAction Stop |
            Where-Object {
                $_.Name -like '*.partial' -or
                $_.Name -like '*.tmp' -or
                $_.Name -like '*.rclone-tmp' -or
                $_.Name -like '*~' -or
                $_.Name -like '.write_test_*'
            } |
            ForEach-Object {
                $orphan = $_
                if (Test-FileInUse -FilePath $orphan.FullName) { return }
                try {
                    $length = [int64]$orphan.Length
                    Remove-Item -LiteralPath $orphan.FullName -Force -ErrorAction Stop
                    $recoveredFiles++
                    $recoveredBytes += $length
                } catch {
                    $errors.Add("Could not remove cache temporary file '$($orphan.FullName)': $($_.Exception.Message)")
                }
            }
    }

    return [ordered]@{
        RecoveredFiles = $recoveredFiles
        RecoveredBytes = $recoveredBytes
        Errors = @($errors.ToArray())
    }
}

# ==============================================================================
# DETAILED CACHE FILE LIST & SINGLE-FILE EVICTION
# ==============================================================================

function Get-DetailedCacheFileList {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [string[]]$MountCacheDirectories = @()
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
    }

    $accountMap = @{}
    try {
        $accounts = @(Get-CloudAccounts)
        foreach ($acc in $accounts) {
            if ($acc.Id) {
                $label = if ($acc.DisplayName) { [string]$acc.DisplayName } else { [string]$acc.Id }
                $drive = if ($acc.DriveLetter) { "$($acc.DriveLetter):" } else { '' }
                $accountMap[[string]$acc.Id] = if ($drive) { "$label ($drive)" } else { $label }
            }
        }
    } catch { }

    $managedDirs = @()
    try {
        $managedDirs = @(Get-ManagedCacheDirectories -CacheDirectory $CacheDirectory -MountCacheDirectories $MountCacheDirectories)
    } catch {
        if (Test-Path -LiteralPath $CacheDirectory) {
            $managedDirs = @(Get-ChildItem -LiteralPath $CacheDirectory -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    }

    $fileList = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($mDir in $managedDirs) {
        if (-not (Test-Path -LiteralPath $mDir -PathType Container)) { continue }
        $dirName = [System.IO.Path]::GetFileName($mDir.TrimEnd('\', '/'))
        $accountLabel = if ($accountMap.ContainsKey($dirName)) { $accountMap[$dirName] } else { $dirName }

        # Scan files inside vfs directory (actual cached data chunks / files)
        $vfsDir = Join-Path $mDir 'vfs'
        $scanTarget = if (Test-Path -LiteralPath $vfsDir -PathType Container) { $vfsDir } else { $mDir }

        $files = Get-ChildItem -LiteralPath $scanTarget -Recurse -File -Force -ErrorAction SilentlyContinue
        if (-not $files) { continue }

        foreach ($f in $files) {
            # Skip vfsMeta files
            if ($f.FullName -match '[\\/]vfsMeta[\\/]') { continue }

            $len = [int64]$f.Length
            $isInUse = Test-FileInUse -FilePath $f.FullName

            # Determine relative cloud path from vfs/<remote>{hash}/<relPath>
            $relPath = $f.FullName.Substring($scanTarget.Length).TrimStart('\', '/')
            if ($relPath -match '^[^\\]+\\(.+)$') {
                $cloudPath = $Matches[1]
            } else {
                $cloudPath = $relPath
            }

            $sizeFormatted = if ($len -ge 1GB) {
                "$([Math]::Round($len / 1GB, 2)) GB"
            } elseif ($len -ge 1MB) {
                "$([Math]::Round($len / 1MB, 2)) MB"
            } elseif ($len -ge 1KB) {
                "$([Math]::Round($len / 1KB, 1)) KB"
            } else {
                "$len B"
            }

            $fileList.Add([PSCustomObject]@{
                Account = $accountLabel
                AccountId = $dirName
                FileName = $f.Name
                RelativePath = $cloudPath
                FullPath = $f.FullName
                Directory = $f.DirectoryName
                SizeBytes = $len
                SizeFormatted = $sizeFormatted
                Status = if ($isInUse) { 'Staged / In-Use' } else { 'Cached (Synced)' }
                IsInUse = $isInUse
                IsEvictable = (-not $isInUse)
                LastModified = $f.LastWriteTime
                LastAccessed = if ($f.LastAccessTime -gt [DateTime]::MinValue) { $f.LastAccessTime } else { $f.LastWriteTime }
            })
        }
    }

    return $fileList.ToArray()
}

function Remove-SingleCacheFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string]$CacheDirectory = ''
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return @{ Success = $false; Error = "File does not exist: $FilePath" }
    }

    if (Test-FileInUse -FilePath $FilePath) {
        return @{ Success = $false; Error = "File is currently open or transferring to the cloud. Please wait until transfer completes." }
    }

    try {
        if (-not $CacheDirectory) {
            $settings = Get-NSCloudDriveSettings
            $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
        }
        if (Test-Path -LiteralPath $CacheDirectory) {
            $resolvedCache = (Resolve-Path -LiteralPath $CacheDirectory).Path
            $resolvedFile = (Resolve-Path -LiteralPath $FilePath).Path
            if (-not $resolvedFile.StartsWith($resolvedCache, [System.StringComparison]::OrdinalIgnoreCase)) {
                return @{ Success = $false; Error = "Security error: File is outside the configured cache directory." }
            }
        }

        Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop

        # Remove matching vfsMeta file if present
        if ($FilePath -match '[\\/]vfs[\\/]') {
            $metaPath = $FilePath -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
            if (Test-Path -LiteralPath $metaPath) {
                Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
            }
        }

        return @{ Success = $true; FilePath = $FilePath }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# ==============================================================================
# POST-TRANSFER CONFIGURABLE CACHE CLEANUP
# ==============================================================================

function Invoke-PostTransferCacheCleanup {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [hashtable]$Settings = $null
    )

    if (-not $Settings) { $Settings = Get-NSCloudDriveSettings }
    $policy = if ($Settings.PostTransferCachePolicy) { [string]$Settings.PostTransferCachePolicy } else { 'KeepCache' }

    if ($policy -eq 'KeepCache') {
        return [ordered]@{
            Policy = 'KeepCache'
            EvictedFiles = 0
            EvictedBytes = 0L
            SkippedCount = 0
            Reason = 'Policy is KeepCache (following standard inactivity TTL)'
        }
    }

    if (-not $CacheDirectory) {
        $CacheDirectory = if ($Settings.CacheDirectory) { [string]$Settings.CacheDirectory } else { 'D:\CloudCache' }
    }

    $managedDirs = @()
    try {
        $managedDirs = @(Get-ManagedCacheDirectories -CacheDirectory $CacheDirectory)
    } catch {
        return [ordered]@{
            Policy = $policy
            EvictedFiles = 0
            EvictedBytes = 0L
            SkippedCount = 0
            Reason = "Managed directories check failed: $($_.Exception.Message)"
        }
    }

    $nowUtc = [DateTime]::UtcNow
    $evictedFiles = 0
    $evictedBytes = 0L
    $skippedCount = 0
    $retentionMin = if ($Settings.PostTransferRetentionMinutes) { [int]$Settings.PostTransferRetentionMinutes } else { 60 }

    foreach ($mDir in $managedDirs) {
        $vfsDir = Join-Path $mDir 'vfs'
        if (-not (Test-Path -LiteralPath $vfsDir -PathType Container)) { continue }

        $files = @(Get-ChildItem -LiteralPath $vfsDir -Recurse -File -Force -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            if ($f.Name -match '(?i)\.(tmp|lock|part|rclone)$') { continue }

            # 1. Check vfsMeta: MUST be verified uploaded (Dirty: false)
            $metaPath = $f.FullName -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
            if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
                $skippedCount++
                continue
            }

            $isDirty = $true
            try {
                $metaJson = Get-Content -LiteralPath $metaPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($metaJson -and $metaJson.PSObject.Properties['Dirty'] -and $metaJson.Dirty -eq $false) {
                    $isDirty = $false
                }
            } catch {
                $isDirty = $true
            }

            if ($isDirty) {
                # Staged upload or pending write: MUST NEVER be evicted.
                $skippedCount++
                continue
            }

            # 2. Check locks: MUST NOT be in-use by any active process or reader
            if (Test-FileInUse -FilePath $f.FullName) {
                $skippedCount++
                continue
            }

            # 3. Check retention condition
            $shouldEvict = $false
            if ($policy -eq 'RemoveAfterVerifiedUpload') {
                $shouldEvict = $true
            } elseif ($policy -eq 'CustomRetention') {
                $lastWrite = if ($f.LastWriteTimeUtc -gt [DateTime]::MinValue) { $f.LastWriteTimeUtc } else { $f.CreationTimeUtc }
                if (($nowUtc - $lastWrite).TotalMinutes -ge $retentionMin) {
                    $shouldEvict = $true
                } else {
                    $skippedCount++
                }
            }

            if ($shouldEvict) {
                try {
                    $fLen = [int64]$f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
                        Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
                    }
                    $evictedFiles++
                    $evictedBytes += $fLen
                } catch {
                    $skippedCount++
                }
            }
        }
    }

    return [ordered]@{
        Policy = $policy
        EvictedFiles = $evictedFiles
        EvictedBytes = $evictedBytes
        SkippedCount = $skippedCount
        Reason = "Post-transfer cleanup completed under policy $policy"
    }
}
