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

function Invoke-SafeCacheCleanup {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
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

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        return [ordered]@{
            CleanedBytes = 0L
            CleanedFiles = 0
            SkippedInUseCount = 0
            SkippedInUseBytes = 0L
            RemainingBytes = 0L
            UnmountRequired = $false
        }
    }

    $allFiles = @()
    try {
        $allFiles = Get-ChildItem -LiteralPath $CacheDirectory -Recurse -File -Force -ErrorAction SilentlyContinue
    } catch { }

    if (-not $allFiles -or $allFiles.Count -eq 0) {
        return [ordered]@{
            CleanedBytes = 0L
            CleanedFiles = 0
            SkippedInUseCount = 0
            SkippedInUseBytes = 0L
            RemainingBytes = 0L
            UnmountRequired = $false
        }
    }

    $cleanedBytes = 0L
    $cleanedFiles = 0
    $skippedInUseCount = 0
    $skippedInUseBytes = 0L

    $evictableCandidates = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $nowUtc = [DateTime]::UtcNow

    # First pass: Categorize in-use vs evictable files
    foreach ($f in $allFiles) {
        if (Test-FileInUse -FilePath $f.FullName) {
            $skippedInUseCount++
            $skippedInUseBytes += [int64]$f.Length
            continue
        }

        # If MaxAgeHours specified and file is older, clean immediately
        if ($MaxAgeHours -gt 0) {
            $lastAccess = if ($f.LastAccessTimeUtc -gt [DateTime]::MinValue) { $f.LastAccessTimeUtc } else { $f.LastWriteTimeUtc }
            if (($nowUtc - $lastAccess).TotalHours -ge $MaxAgeHours) {
                try {
                    $len = [int64]$f.Length
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                    $cleanedBytes += $len
                    $cleanedFiles++
                    continue
                } catch { }
            }
        }

        # If Force clear requested, delete immediately
        if ($Force) {
            try {
                $len = [int64]$f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $cleanedBytes += $len
                $cleanedFiles++
                continue
            } catch { }
        }

        $evictableCandidates.Add($f)
    }

    # Second pass: If size limit is configured and current size still exceeds target, evict LRU (oldest accessed first)
    if (-not $Force -and $TargetMaxBytes -gt 0L) {
        $currentTotal = $skippedInUseBytes
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
                    $cleanedBytes += $len
                    $cleanedFiles++
                    $currentTotal -= $len
                } catch { }
            }
        }
    }

    # Clean up empty subdirectories
    try {
        Get-ChildItem -LiteralPath $CacheDirectory -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object -Property { $_.FullName.Length } -Descending |
            Where-Object { (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

    # Compute remaining bytes
    $remaining = (Get-DetailedCacheStatistics -CacheDirectory $CacheDirectory).TotalSizeBytes

    return [ordered]@{
        CleanedBytes = $cleanedBytes
        CleanedFiles = $cleanedFiles
        SkippedInUseCount = $skippedInUseCount
        SkippedInUseBytes = $skippedInUseBytes
        RemainingBytes = $remaining
        UnmountRequired = ($skippedInUseCount -gt 0)
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

    $managedDirectoryPattern = '^(?:gdrive|terabox)(?:_[A-Za-z0-9_-]{1,128})?$'
    $recoveryTargets = [System.Collections.Generic.List[string]]::new()
    if ($MountCacheDirectories.Count -gt 0) {
        foreach ($directory in $MountCacheDirectories) {
            if ([string]::IsNullOrWhiteSpace($directory)) { continue }
            $mountKey = [System.IO.Path]::GetFileName($directory.TrimEnd('\', '/'))
            if ($mountKey -notmatch $managedDirectoryPattern) {
                throw "Refusing cache recovery for a directory outside an account cache namespace."
            }
            $recoveryTargets.Add($directory)
        }
    } elseif (Test-Path -LiteralPath $CacheDirectory -PathType Container) {
        foreach ($directory in Get-ChildItem -LiteralPath $CacheDirectory -Directory -Force -ErrorAction Stop) {
            if ($directory.Name -match $managedDirectoryPattern) {
                $recoveryTargets.Add($directory.FullName)
            }
        }
    }

    $recoveredFiles = 0
    $recoveredBytes = 0L
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($recoveryTarget in $recoveryTargets) {
        if (-not (Test-Path -LiteralPath $recoveryTarget -PathType Container)) { continue }
        $targetInfo = Get-Item -LiteralPath $recoveryTarget -Force -ErrorAction Stop
        if (($targetInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
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
