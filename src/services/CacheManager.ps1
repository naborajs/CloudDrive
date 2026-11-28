Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'SettingsManager.ps1')
. (Join-Path $PSScriptRoot 'CacheFileSafety.ps1')

function Get-CacheDefaultDirectory {
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
        $homeDir = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
        return (Join-Path $homeDir 'CloudCache')
    }
    return 'D:\CloudCache'
}

function ConvertTo-CacheNormalizedPath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    # Do not trim whitespace from filesystem paths: Unix filenames may end in
    # spaces, and changing the path can redirect cleanup to a sibling entry.
    $clean = $Path
    if ($clean.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $clean = '\\' + $clean.Substring(8)
    } elseif ($clean.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $clean = $clean.Substring(4)
    } elseif ($clean.StartsWith('//?/UNC/', [System.StringComparison]::OrdinalIgnoreCase)) {
        $clean = '//' + $clean.Substring(8)
    } elseif ($clean.StartsWith('//?/', [System.StringComparison]::Ordinal)) {
        $clean = $clean.Substring(4)
    }
    try { return ([System.IO.Path]::GetFullPath($clean)).TrimEnd('\', '/') } catch { return $clean.TrimEnd('\', '/') }
}

function Test-CachePathWithinRoots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Roots = @(),
        [System.StringComparison]$Comparison = [System.StringComparison]::OrdinalIgnoreCase
    )

    $normalizedPath = ConvertTo-CacheNormalizedPath $Path
    if (-not $normalizedPath) { return $false }
    foreach ($root in @($Roots)) {
        $normalizedRoot = ConvertTo-CacheNormalizedPath ([string]$root)
        if (-not $normalizedRoot) { continue }
        $prefix = $normalizedRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        if ([string]::Equals($normalizedPath, $normalizedRoot, $Comparison) -or $normalizedPath.StartsWith($prefix, $Comparison)) { return $true }
    }
    return $false
}

function Test-CachePathContainsReparsePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $cursor = ConvertTo-CacheNormalizedPath $Path
    if (-not $cursor) { return $true }
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            try {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
            } catch { return $true }
        }
        $parent = [System.IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrEmpty($parent) -or [string]::Equals($parent, $cursor, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = $parent
    }
    return $false
}

function Get-CacheVfsOwnershipSnapshot {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [string[]]$ActiveCachePaths = @(),
        [switch]$ActiveCacheOwnershipKnown
    )

    $isUnix = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    $pathComparer = if ($isUnix) { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }
    $activeRoots = [System.Collections.Generic.List[string]]::new()
    $protectedRoots = [System.Collections.Generic.HashSet[string]]::new($pathComparer)
    $activeFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ownershipKnown = $false

    if ($ActiveCachePaths.Count -gt 0 -or $ActiveCacheOwnershipKnown) {
        $ownershipKnown = $true
        foreach ($activePath in @($ActiveCachePaths)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$activePath)) { $activeRoots.Add((ConvertTo-CacheNormalizedPath ([string]$activePath))) }
        }
    } elseif ((Get-Command Get-CloudAccounts -ErrorAction SilentlyContinue) -and
        (Get-Command Get-VirtualDriveVfsStats -ErrorAction SilentlyContinue) -and
        (Get-Command Get-VirtualDriveStatus -ErrorAction SilentlyContinue)) {
        $ownershipKnown = $true
        try {
            $accounts = @(Get-CloudAccounts)
            $knownProviders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($account in $accounts) {
                $accountId = [string](Get-SafeProperty $account 'Id' '')
                $providerId = [string](Get-SafeProperty $account 'ProviderId' '')
                $driveLetter = [string](Get-SafeProperty $account 'DriveLetter' '')
                if ($providerId) { [void]$knownProviders.Add($providerId) }
                $stats = Get-VirtualDriveVfsStats -DriveLetter $driveLetter -AccountId $accountId -ProviderId $providerId
                $isActive = [bool](Get-SafeProperty $stats 'IsActive' $false)
                $state = [string](Get-SafeProperty $stats 'State' 'Remote state unknown')
                $liveRoot = [string](Get-SafeProperty $stats 'DiskCachePath' '')
                if ($isActive -and $liveRoot) {
                    $activeRoots.Add((ConvertTo-CacheNormalizedPath $liveRoot))
                } elseif ($isActive) {
                    $accountBase = [string](Get-SafeProperty $account 'CacheDirectory' '')
                    if (-not $accountBase) { $accountBase = $CacheDirectory }
                    if ($accountId -and $accountBase) {
                        [void]$protectedRoots.Add((ConvertTo-CacheNormalizedPath (Join-Path $accountBase $accountId)))
                        if ($providerId) { [void]$protectedRoots.Add((ConvertTo-CacheNormalizedPath (Join-Path $accountBase "${providerId}_$accountId"))) }
                    } else { $ownershipKnown = $false }
                } elseif ($state -eq 'Remote state unknown') {
                    $status = Get-VirtualDriveStatus -DriveLetter $driveLetter -AccountId $accountId -ProviderId $providerId
                    $mounted = Get-SafeProperty $status 'IsMounted' $null
                    $processRunning = Get-SafeProperty $status 'ProcessRunning' $null
                    if ($null -eq $mounted -or $null -eq $processRunning) {
                        $ownershipKnown = $false
                    } elseif ([bool]$mounted -or [bool]$processRunning) {
                        $accountBase = [string](Get-SafeProperty $account 'CacheDirectory' '')
                        if (-not $accountBase) { $accountBase = $CacheDirectory }
                        if ($accountId -and $accountBase) {
                            [void]$protectedRoots.Add((ConvertTo-CacheNormalizedPath (Join-Path $accountBase $accountId)))
                            if ($providerId) { [void]$protectedRoots.Add((ConvertTo-CacheNormalizedPath (Join-Path $accountBase "${providerId}_$accountId"))) }
                        } else { $ownershipKnown = $false }
                    }
                }

                foreach ($entry in @(Get-SafeProperty $stats 'Transferring' @()) + @(Get-SafeProperty $stats 'QueuedItems' @())) {
                    $entryName = [string](Get-SafeProperty $entry 'Name' '')
                    $entryPath = [string](Get-SafeProperty $entry 'RelativePath' '')
                    if ($entryName) { [void]$activeFileNames.Add([System.IO.Path]::GetFileName($entryName)) }
                    if ($entryPath) { [void]$activeFileNames.Add([System.IO.Path]::GetFileName($entryPath)) }
                }
            }

            foreach ($legacyProvider in @('gdrive', 'terabox')) {
                if ($knownProviders.Contains($legacyProvider)) { continue }
                $stats = Get-VirtualDriveVfsStats -ProviderId $legacyProvider
                $isActive = [bool](Get-SafeProperty $stats 'IsActive' $false)
                $state = [string](Get-SafeProperty $stats 'State' 'Remote state unknown')
                $liveRoot = [string](Get-SafeProperty $stats 'DiskCachePath' '')
                if ($isActive -and $liveRoot) {
                    $activeRoots.Add((ConvertTo-CacheNormalizedPath $liveRoot))
                } elseif ($isActive) {
                    $ownershipKnown = $false
                } elseif ($state -eq 'Remote state unknown') {
                    $status = Get-VirtualDriveStatus -ProviderId $legacyProvider
                    $mounted = Get-SafeProperty $status 'IsMounted' $null
                    $processRunning = Get-SafeProperty $status 'ProcessRunning' $null
                    if ($null -eq $mounted -or $null -eq $processRunning -or [bool]$mounted -or [bool]$processRunning) { $ownershipKnown = $false }
                }
            }
        } catch {
            $ownershipKnown = $false
        }
    }

    return [pscustomobject]@{
        OwnershipKnown = $ownershipKnown
        ActiveRoots = @($activeRoots.ToArray())
        ProtectedCacheRoots = $protectedRoots
        ActiveFileNames = $activeFileNames
    }
}

function Get-CacheCurrentVfsOwnershipSnapshot {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [string[]]$FallbackActiveCachePaths = @(),
        [switch]$FallbackOwnershipKnown
    )

    $canRefresh = (Get-Command Get-CloudAccounts -ErrorAction SilentlyContinue) -and
        (Get-Command Get-VirtualDriveVfsStats -ErrorAction SilentlyContinue) -and
        (Get-Command Get-VirtualDriveStatus -ErrorAction SilentlyContinue)
    if ($canRefresh) {
        return Get-CacheVfsOwnershipSnapshot -CacheDirectory $CacheDirectory
    }

    # Standalone cache tooling can provide an explicit ownership snapshot when
    # provider and mount APIs are not loaded. The desktop always refreshes live.
    return Get-CacheVfsOwnershipSnapshot -CacheDirectory $CacheDirectory `
        -ActiveCachePaths $FallbackActiveCachePaths `
        -ActiveCacheOwnershipKnown:$FallbackOwnershipKnown
}

function Get-CacheVfsNamespaceInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CacheDirectory
    )

    $result = [ordered]@{
        IsVfs = $false
        IsVfsMeta = $false
        MetadataPath = ''
        AccountRoot = ''
    }
    $normalizedCache = ConvertTo-CacheNormalizedPath $CacheDirectory
    $normalizedPath = ConvertTo-CacheNormalizedPath $Path
    if (-not $normalizedCache -or -not $normalizedPath) { return [pscustomobject]$result }

    $isUnix = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    $comparison = if ($isUnix) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $prefix = $normalizedCache.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($prefix, $comparison)) { return [pscustomobject]$result }

    $relativePath = $normalizedPath.Substring($prefix.Length)
    $segments = @($relativePath -split '[\\/]' | Where-Object { $_ -ne '' })
    if ($segments.Count -lt 3) { return [pscustomobject]$result }
    $result.AccountRoot = ConvertTo-CacheNormalizedPath (Join-Path $normalizedCache ([string]$segments[0]))
    if ([string]::Equals([string]$segments[1], 'vfs', $comparison)) {
        $result.IsVfs = $true
        $metadataSegments = @($segments)
        $metadataSegments[1] = 'vfsMeta'
        $result.MetadataPath = ConvertTo-CacheNormalizedPath (Join-Path $normalizedCache ($metadataSegments -join [System.IO.Path]::DirectorySeparatorChar))
    } elseif ([string]::Equals([string]$segments[1], 'vfsMeta', $comparison)) {
        $result.IsVfsMeta = $true
    }

    return [pscustomobject]$result
}

function Test-CacheVfsMetadataClean {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$MetadataPath)

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf) -or (Test-CachePathContainsReparsePoint -Path $MetadataPath)) { return $false }
    try {
        $metadata = Get-Content -LiteralPath $MetadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return ($metadata -and $metadata.PSObject.Properties['Dirty'] -and $metadata.Dirty -is [bool] -and -not [bool]$metadata.Dirty)
    } catch { return $false }
}

# ==============================================================================
# IN-USE FILE AND PROCESS DETECTION
# ==============================================================================

function Remove-SafeCacheFileEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$CacheDirectory,
        [string[]]$ActiveCachePaths = @(),
        [switch]$ActiveCacheOwnershipKnown,
        [string[]]$ProtectedFileNames = @(),
        [int64]$ExpectedSizeBytes = -1L,
        [DateTime]$ExpectedLastWriteUtc = [DateTime]::MinValue,
        [double]$MaxAgeMinutes = -1.0
    )

    $normalizedCache = ConvertTo-CacheNormalizedPath $CacheDirectory
    $normalizedFile = ConvertTo-CacheNormalizedPath $FilePath
    $isUnix = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    $pathComparison = if ($isUnix) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $cachePrefix = $normalizedCache.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $normalizedCache -or -not $normalizedFile -or -not $normalizedFile.StartsWith($cachePrefix, $pathComparison) -or
        (Test-CachePathContainsReparsePoint -Path $normalizedFile)) {
        return @{ Success = $false; BytesRemoved = 0L; Reason = 'The cache path is invalid, outside its root, or linked.' }
    }
    if ($ProtectedFileNames -contains [System.IO.Path]::GetFileName($normalizedFile)) {
        return @{ Success = $false; BytesRemoved = 0L; Reason = 'The file is recorded as active transfer data.' }
    }

    $namespaceInfo = Get-CacheVfsNamespaceInfo -Path $normalizedFile -CacheDirectory $normalizedCache
    $isVfsEntry = [bool]$namespaceInfo.IsVfs
    $metaPath = if ($isVfsEntry) { [string]$namespaceInfo.MetadataPath } else { '' }
    $managedRoot = $normalizedCache
    if ($isVfsEntry) { $managedRoot = [string]$namespaceInfo.AccountRoot }

    $sourceStream = $null
    $metaStream = $null
    try {
        $sourceStream = Open-CacheFileExclusiveRead -Path $normalizedFile
        $sourceInfo = Get-Item -LiteralPath $normalizedFile -Force -ErrorAction Stop
        if (($sourceInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $sourceInfo.Length -ne $sourceStream.Length -or
            ($ExpectedSizeBytes -ge 0 -and $sourceInfo.Length -ne $ExpectedSizeBytes) -or
            ($ExpectedLastWriteUtc -ne [DateTime]::MinValue -and $sourceInfo.LastWriteTimeUtc.Ticks -ne $ExpectedLastWriteUtc.ToUniversalTime().Ticks)) {
            return @{ Success = $false; BytesRemoved = 0L; Reason = 'The cache file revision changed and was preserved.' }
        }

        $metadata = $null
        if ($isVfsEntry) {
            $ownership = Get-CacheCurrentVfsOwnershipSnapshot -CacheDirectory $normalizedCache -FallbackActiveCachePaths $ActiveCachePaths -FallbackOwnershipKnown:$ActiveCacheOwnershipKnown
            if (-not $ownership.OwnershipKnown -or $ownership.ProtectedCacheRoots.Contains($managedRoot) -or
                (Test-CachePathWithinRoots -Path $normalizedFile -Roots @($ownership.ActiveRoots) -Comparison $pathComparison)) {
                return @{ Success = $false; BytesRemoved = 0L; Reason = 'The VFS cache is active or its mount ownership is unknown.' }
            }
            if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf) -or (Test-CachePathContainsReparsePoint -Path $metaPath)) {
                return @{ Success = $false; BytesRemoved = 0L; Reason = 'VFS metadata is missing or linked.' }
            }
            $metaStream = Open-CacheFileExclusiveRead -Path $metaPath
            $metaReader = [System.IO.StreamReader]::new($metaStream, [System.Text.Encoding]::UTF8, $true, 1024, $true)
            try { $metadata = $metaReader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $metaReader.Dispose() }
            if (-not $metadata -or -not $metadata.PSObject.Properties['Dirty'] -or $metadata.Dirty -isnot [bool] -or [bool]$metadata.Dirty) {
                return @{ Success = $false; BytesRemoved = 0L; Reason = 'VFS metadata is dirty or ambiguous.' }
            }
        }

        if ($MaxAgeMinutes -ge 0) {
            $latestActivity = $sourceInfo.LastWriteTimeUtc
            if ($sourceInfo.LastAccessTimeUtc -gt $latestActivity -and $sourceInfo.LastAccessTimeUtc -le [DateTime]::UtcNow) { $latestActivity = $sourceInfo.LastAccessTimeUtc }
            if ($metadata) {
                foreach ($propertyName in @('ATime', 'ModTime')) {
                    $property = $metadata.PSObject.Properties[$propertyName]
                    if ($property -and $property.Value) {
                        try {
                            $metaTime = [DateTime]::Parse([string]$property.Value).ToUniversalTime()
                            $now = [DateTime]::UtcNow
                            if ($metaTime -gt $now) { $metaTime = $now }
                            if ($metaTime -gt $latestActivity) { $latestActivity = $metaTime }
                        } catch { }
                    }
                }
            }
            if (([DateTime]::UtcNow - $latestActivity).TotalMinutes -lt $MaxAgeMinutes) {
                return @{ Success = $false; BytesRemoved = 0L; Reason = 'The cache entry is no longer past its inactivity limit.' }
            }
        }

        if (Test-CachePathContainsReparsePoint -Path $normalizedFile) {
            return @{ Success = $false; BytesRemoved = 0L; Reason = 'A cache path changed during final validation.' }
        }
        if ($isVfsEntry) {
            $finalOwnership = Get-CacheCurrentVfsOwnershipSnapshot -CacheDirectory $normalizedCache -FallbackActiveCachePaths $ActiveCachePaths -FallbackOwnershipKnown:$ActiveCacheOwnershipKnown
            if (-not $finalOwnership.OwnershipKnown -or $finalOwnership.ProtectedCacheRoots.Contains($managedRoot) -or
                (Test-CachePathWithinRoots -Path $normalizedFile -Roots @($finalOwnership.ActiveRoots) -Comparison $pathComparison) -or
                $metadata.Dirty -isnot [bool] -or [bool]$metadata.Dirty) {
                return @{ Success = $false; BytesRemoved = 0L; Reason = 'VFS ownership or clean metadata changed during final validation.' }
            }
        }

        $length = [int64]$sourceInfo.Length
        $sourceSha256 = Get-CacheStreamSha256 -Stream $sourceStream
        Remove-CacheFileByExclusiveHandle -Path $normalizedFile -Stream $sourceStream -ExpectedSha256 $sourceSha256
        if ($metaStream) {
            $metadataSha256 = Get-CacheStreamSha256 -Stream $metaStream
            Remove-CacheFileByExclusiveHandle -Path $metaPath -Stream $metaStream -ExpectedSha256 $metadataSha256
        }
        return @{ Success = $true; BytesRemoved = $length; Reason = 'The locked cache revision was safely removed.' }
    } catch {
        return @{ Success = $false; BytesRemoved = 0L; Reason = 'The cache revision could not be locked or removed safely.' }
    } finally {
        if ($metaStream) { $metaStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
    }
}

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
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { Get-CacheDefaultDirectory }
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
        [string[]]$MountCacheDirectories = @(),
        [string[]]$ActiveCachePaths = @(),
        [switch]$ActiveCacheOwnershipKnown
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { Get-CacheDefaultDirectory }
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

    $isCaseSensitiveFileSystem = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    $cachePathComparison = if ($isCaseSensitiveFileSystem) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $cachePathComparer = if ($isCaseSensitiveFileSystem) { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }
    $activeVfsRoots = [System.Collections.Generic.List[string]]::new()
    $protectedCacheRoots = [System.Collections.Generic.HashSet[string]]::new($cachePathComparer)
    $vfsRetentionMinutes = 5.0
    try {
        $cacheSettings = Get-NSCloudDriveSettings
        $cachePolicy = if ($cacheSettings.PostTransferCachePolicy) { [string]$cacheSettings.PostTransferCachePolicy } else { 'RemoveAfterVerifiedUpload' }
        if ($cachePolicy -eq 'KeepCache') {
            $vfsRetentionMinutes = 45.0
        } elseif ($cachePolicy -eq 'CustomRetention') {
            $retention = 60
            if ([int]::TryParse([string]$cacheSettings.PostTransferRetentionMinutes, [ref]$retention)) {
                $vfsRetentionMinutes = [double][Math]::Max(1, [Math]::Min(43200, $retention))
            }
        }
    } catch { }

    # Query ownership by provider/account identity instead of saved drive letter.
    # RC failure is reconciled against mount process state; unresolved ownership
    # protects every VFS entry for this pass.
    $ownershipSnapshot = Get-CacheVfsOwnershipSnapshot -CacheDirectory $CacheDirectory -ActiveCachePaths $ActiveCachePaths -ActiveCacheOwnershipKnown:$ActiveCacheOwnershipKnown
    $activeOwnershipKnown = [bool]$ownershipSnapshot.OwnershipKnown
    foreach ($activeRoot in @($ownershipSnapshot.ActiveRoots)) { if ($activeRoot) { $activeVfsRoots.Add([string]$activeRoot) } }
    $protectedCacheRoots = $ownershipSnapshot.ProtectedCacheRoots
    $activeTransferFileNames = $ownershipSnapshot.ActiveFileNames

    foreach ($managedDir in $managedDirectories) {
        if (-not (Test-Path -LiteralPath $managedDir -PathType Container)) { continue }

        $vfsDir = Join-Path $managedDir 'vfs'
        $scanTarget = $managedDir

        $files = Get-ChildItem -LiteralPath $scanTarget -Recurse -File -Force -ErrorAction SilentlyContinue
        if (-not $files) { continue }

        foreach ($f in $files) {
            $namespaceInfo = Get-CacheVfsNamespaceInfo -Path $f.FullName -CacheDirectory $CacheDirectory
            $isVfsCacheFile = [bool]$namespaceInfo.IsVfs
            if ($namespaceInfo.IsVfsMeta) {
                $skippedRcloneOwned++
                continue
            }

            if ($isVfsCacheFile) {
                $normalizedFilePath = ConvertTo-CacheNormalizedPath -Path $f.FullName
                $managedRoot = ConvertTo-CacheNormalizedPath -Path $managedDir
                $protectedByUnknownMount = $protectedCacheRoots.Contains($managedRoot)
                $ownedByActiveMount = $false
                foreach ($activeRoot in $activeVfsRoots) {
                    $activePrefix = $activeRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
                    if ([string]::Equals($normalizedFilePath, $activeRoot, $cachePathComparison) -or $normalizedFilePath.StartsWith($activePrefix, $cachePathComparison)) {
                        $ownedByActiveMount = $true
                        break
                    }
                }
                # rclone owns active VFS files. Historical cache roots are eligible only
                # after their mount is gone; active file locks remain an extra guard.
                if (-not $activeOwnershipKnown -or $protectedByUnknownMount -or $ownedByActiveMount) {
                    $skippedRcloneOwned++
                    continue
                }
            }

            # Do NOT evict files actively being transferred or in-use by any process
            if ($activeTransferFileNames.Contains($f.Name) -or $activeTransferFileNames.Contains([System.IO.Path]::GetFileName($f.FullName)) -or (Test-FileInUse -FilePath $f.FullName)) {
                $skippedInUse++
                continue
            }

            $isDirty = $false
            $metaPath = ''
            $metaJson = $null
            if ($isVfsCacheFile) {
                $metaPath = [string]$namespaceInfo.MetadataPath
                if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
                    if (Test-FileInUse -FilePath $metaPath) {
                        $skippedInUse++
                        continue
                    }
                    try {
                        $metaJson = Get-Content -LiteralPath $metaPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                        if ($isVfsCacheFile) {
                            if (-not $metaJson -or -not $metaJson.PSObject.Properties['Dirty'] -or $metaJson.Dirty -ne $false) { $isDirty = $true }
                        } elseif ($metaJson -and $metaJson.PSObject.Properties['Dirty'] -and $metaJson.Dirty -eq $true) {
                            $isDirty = $true
                        }
                    } catch {
                        $isDirty = $true
                    }
                } elseif ($isVfsCacheFile) {
                    # Missing VFS metadata is ambiguous: it may be a read cache file,
                    # or an interrupted staged write whose metadata was lost. Preserve
                    # it until the transfer reconciler can classify it.
                    $isDirty = $true
                }
            }

            # Never evict dirty/staged files
            if ($isDirty) {
                $skippedStaged++
                continue
            }

            # Existing local cache files keep their size-based retention. Expired VFS
            # cache from an inactive root uses the same cleanup policy as the mount.
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
            if ($isVfsCacheFile) {
                $shouldEvict = ($inactivityMinutes -ge $vfsRetentionMinutes)
            } elseif ($fileLen -lt $ONE_GB) {
                if ($inactivityMinutes -ge 5.0) { $shouldEvict = $true }
            } elseif ($fileLen -ge $ONE_GB -and $fileLen -le $THREE_GB) {
                if ($inactivityMinutes -ge 20.0) { $shouldEvict = $true }
            } else {
                if ($inactivityMinutes -ge 45.0) { $shouldEvict = $true }
            }

            if ($shouldEvict) {
                $ttlMinutes = if ($isVfsCacheFile) { $vfsRetentionMinutes } elseif ($fileLen -lt $ONE_GB) { 5.0 } elseif ($fileLen -le $THREE_GB) { 20.0 } else { 45.0 }
                $removal = Remove-SafeCacheFileEntry `
                    -FilePath $f.FullName `
                    -CacheDirectory $CacheDirectory `
                    -ActiveCachePaths @($activeVfsRoots.ToArray()) `
                    -ActiveCacheOwnershipKnown:$activeOwnershipKnown `
                    -ProtectedFileNames @($activeTransferFileNames) `
                    -ExpectedSizeBytes $fileLen `
                    -ExpectedLastWriteUtc $f.LastWriteTimeUtc `
                    -MaxAgeMinutes $ttlMinutes
                if ($removal.Success) {
                    $evictedFiles++
                    $evictedBytes += [int64]$removal.BytesRemoved
                } elseif ($removal.Reason -match 'active|ownership|Dirty|staged') {
                    $skippedStaged++
                } elseif ($removal.Reason -match 'locked|in use|could not') {
                    $skippedInUse++
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

    $managedDirectoryPattern = '^(?:gdrive|terabox|vps|proton|mega|s3)(?:_[A-Za-z0-9_-]{1,128})?$'
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
        [string[]]$ActiveCachePaths = @(),
        [switch]$ActiveCacheOwnershipKnown,
        [int64]$TargetMaxBytes = -1L,
        [int]$MaxAgeHours = 0,
        [switch]$Force
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { Get-CacheDefaultDirectory }
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
            SkippedStagedCount = 0
            SkippedStagedBytes = 0L
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
            SkippedStagedCount = 0
            SkippedStagedBytes = 0L
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

    # A clean VFS file can still be owned by rclone. Discover live roots before
    # clearing anything; if mount ownership cannot be determined, preserve all VFS
    # entries for this pass. Non-VFS cache files remain eligible as before.
    $ownershipSnapshot = Get-CacheVfsOwnershipSnapshot -CacheDirectory $CacheDirectory -ActiveCachePaths $ActiveCachePaths -ActiveCacheOwnershipKnown:$ActiveCacheOwnershipKnown
    $activeVfsRoots = @($ownershipSnapshot.ActiveRoots)
    $protectedCacheRoots = $ownershipSnapshot.ProtectedCacheRoots
    $activeOwnershipKnown = [bool]$ownershipSnapshot.OwnershipKnown
    $activeTransferFileNames = $ownershipSnapshot.ActiveFileNames
    $isCaseSensitiveFileSystem = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    $pathComparison = if ($isCaseSensitiveFileSystem) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }

    # First pass: Categorize in-use, staged/dirty vs evictable files
    foreach ($f in $allFiles) {
        $namespaceInfo = Get-CacheVfsNamespaceInfo -Path $f.FullName -CacheDirectory $CacheDirectory
        # Skip the actual account-root vfsMeta namespace from direct deletion.
        if ($namespaceInfo.IsVfsMeta) { continue }

        if (Test-FileInUse -FilePath $f.FullName) {
            $skippedInUseCount++
            $skippedInUseBytes += [int64]$f.Length
            continue
        }

        # VFS entries are upload state, not ordinary disposable cache. A missing or
        # malformed metadata record is ambiguous and must be preserved. Active roots
        # are left to rclone so the application never removes a file behind its writer.
        $isDirty = $false
        $isVfsEntry = [bool]$namespaceInfo.IsVfs
        $metaPath = ''
        if ($isVfsEntry) {
            $normalizedFilePath = ConvertTo-CacheNormalizedPath $f.FullName
            $insideActiveRoot = $false
            foreach ($activeRoot in $activeVfsRoots) {
                if (-not $activeRoot) { continue }
                $activePrefix = $activeRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
                if ([string]::Equals($normalizedFilePath, $activeRoot, $pathComparison) -or $normalizedFilePath.StartsWith($activePrefix, $pathComparison)) {
                    $insideActiveRoot = $true
                    break
                }
            }
            $managedRoot = ConvertTo-CacheNormalizedPath $managedDirectory
            $insideProtectedAccountRoot = $protectedCacheRoots.Contains($managedRoot)
            if (-not $activeOwnershipKnown -or $insideProtectedAccountRoot -or $insideActiveRoot) {
                $skippedStagedCount++
                $skippedStagedBytes += [int64]$f.Length
                continue
            }

            $metaPath = [string]$namespaceInfo.MetadataPath
            $metaKnownClean = $false
            if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
                try {
                    $metaJson = Get-Content -LiteralPath $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($metaJson -and $metaJson.PSObject.Properties['Dirty'] -and $metaJson.Dirty -is [bool]) {
                        $isDirty = [bool]$metaJson.Dirty
                        $metaKnownClean = -not $isDirty
                    }
                } catch { }
            }
            if ($isDirty -or -not $metaKnownClean) {
                $skippedStagedCount++
                $skippedStagedBytes += [int64]$f.Length
                continue
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
                $removal = Remove-SafeCacheFileEntry `
                    -FilePath $f.FullName `
                    -CacheDirectory $CacheDirectory `
                    -ActiveCachePaths $activeVfsRoots `
                    -ActiveCacheOwnershipKnown:$activeOwnershipKnown `
                    -ProtectedFileNames @($activeTransferFileNames) `
                    -ExpectedSizeBytes ([int64]$f.Length) `
                    -ExpectedLastWriteUtc $f.LastWriteTimeUtc `
                    -MaxAgeMinutes ([double]$MaxAgeHours * 60.0)
                if ($removal.Success) {
                    $cleanedBytes += [int64]$removal.BytesRemoved
                    $cleanedFiles++
                } else {
                    $skippedInUseCount++
                    $skippedInUseBytes += [int64]$f.Length
                }
                continue
            }
        }

        # If Force clear requested, delete immediately
        if ($Force) {
            $removal = Remove-SafeCacheFileEntry `
                -FilePath $f.FullName `
                -CacheDirectory $CacheDirectory `
                -ActiveCachePaths $activeVfsRoots `
                -ActiveCacheOwnershipKnown:$activeOwnershipKnown `
                -ProtectedFileNames @($activeTransferFileNames) `
                -ExpectedSizeBytes ([int64]$f.Length) `
                -ExpectedLastWriteUtc $f.LastWriteTimeUtc
            if ($removal.Success) {
                $cleanedBytes += [int64]$removal.BytesRemoved
                $cleanedFiles++
            } else {
                $skippedStagedCount++
                $skippedStagedBytes += [int64]$f.Length
            }
            continue
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
                $removal = Remove-SafeCacheFileEntry `
                    -FilePath $item.FullName `
                    -CacheDirectory $CacheDirectory `
                    -ActiveCachePaths $activeVfsRoots `
                    -ActiveCacheOwnershipKnown:$activeOwnershipKnown `
                    -ProtectedFileNames @($activeTransferFileNames) `
                    -ExpectedSizeBytes ([int64]$item.Length) `
                    -ExpectedLastWriteUtc $item.LastWriteTimeUtc
                if ($removal.Success) {
                    $len = [int64]$removal.BytesRemoved
                    $cleanedBytes += $len
                    $cleanedFiles++
                    $currentTotal -= $len
                } else {
                    $skippedStagedCount++
                    $skippedStagedBytes += [int64]$item.Length
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
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { Get-CacheDefaultDirectory }
    }

    $recoveryTargets = @(Get-ManagedCacheDirectories -CacheDirectory $CacheDirectory -MountCacheDirectories $MountCacheDirectories)

    $recoveredFiles = 0
    $recoveredBytes = 0L
    $errors = [System.Collections.Generic.List[string]]::new()
    $staleTemporaryCutoffUtc = [DateTime]::UtcNow.AddHours(-1)

    foreach ($recoveryTarget in $recoveryTargets) {
        if (-not (Test-Path -LiteralPath $recoveryTarget -PathType Container)) { continue }
        $targetInfo = Get-Item -LiteralPath $recoveryTarget -Force -ErrorAction Stop
        $singleTarget = if ($targetInfo -is [System.Array]) { $targetInfo[0] } else { $targetInfo }
        if ([bool]($singleTarget.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))) {
            $errors.Add("Skipped cache recovery because the account cache path is a reparse point: $recoveryTarget")
            continue
        }

        $normalizedRecoveryTarget = ConvertTo-CacheNormalizedPath $recoveryTarget
        $recoveryPrefix = $normalizedRecoveryTarget.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $recoveryPathComparison = if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }

        # If the process stopped after atomically claiming a file for deletion,
        # restore that payload when its original path is still empty. This never
        # deletes the payload and skips fresh claims that may still be in progress.
        foreach ($claimDirectory in Get-ChildItem -LiteralPath $recoveryTarget -Recurse -Directory -Force -ErrorAction Stop) {
            if ($claimDirectory.Name -notmatch '^\.nscd-delete-[0-9a-f]{32}$' -or
                $claimDirectory.LastWriteTimeUtc -gt $staleTemporaryCutoffUtc -or
                (Test-CachePathContainsReparsePoint -Path $claimDirectory.FullName)) { continue }
            $claimFiles = @(Get-ChildItem -LiteralPath $claimDirectory.FullName -File -Force -ErrorAction SilentlyContinue)
            $claimSubdirectories = @(Get-ChildItem -LiteralPath $claimDirectory.FullName -Directory -Force -ErrorAction SilentlyContinue)
            if ($claimFiles.Count -ne 1 -or $claimSubdirectories.Count -ne 0 -or
                (Test-CachePathContainsReparsePoint -Path $claimFiles[0].FullName)) { continue }
            $restorePath = Join-Path $claimDirectory.Parent.FullName $claimFiles[0].Name
            if (Test-Path -LiteralPath $restorePath) { continue }
            try {
                [System.IO.File]::Move($claimFiles[0].FullName, $restorePath)
                [System.IO.Directory]::Delete($claimDirectory.FullName, $false)
                $recoveredFiles++
                $recoveredBytes += [int64]$claimFiles[0].Length
            } catch {
                $errors.Add('An interrupted cache deletion claim could not be restored safely.')
            }
        }

        foreach ($orphan in Get-ChildItem -LiteralPath $recoveryTarget -Recurse -File -Force -ErrorAction Stop) {
            # Recovery may remove only temporary files created by NS Cloud Drive
            # itself. Generic *.tmp, *.partial, editor backups, and rclone temp
            # names can be legitimate cloud files and are never swept here.
            $isOwnedTemporary = ($orphan.Name -match '^\.(?:nscd-data|nscd-meta)-[0-9a-f]{32}\.tmp$' -or
                $orphan.Name -match '^\.write_test_[0-9a-f]{8}$')
            if (-not $isOwnedTemporary -or $orphan.LastWriteTimeUtc -gt $staleTemporaryCutoffUtc) { continue }
            if (-not $orphan.FullName.StartsWith($recoveryPrefix, $recoveryPathComparison)) { continue }

            $relativePath = $orphan.FullName.Substring($recoveryPrefix.Length)
            $pathSegments = @($relativePath -split '[\\/]')
            if (@($pathSegments | Where-Object { $_ -ieq 'vfs' -or $_ -ieq 'vfsMeta' }).Count -gt 0) { continue }
            if (Test-CachePathContainsReparsePoint -Path $orphan.FullName) { continue }
            if (Test-FileInUse -FilePath $orphan.FullName) { continue }

            $orphanStream = $null
            try {
                $orphanStream = Open-CacheFileExclusiveRead -Path $orphan.FullName
                $lockedInfo = Get-Item -LiteralPath $orphan.FullName -Force -ErrorAction Stop
                if (($lockedInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    $lockedInfo.Length -ne $orphan.Length -or
                    $lockedInfo.LastWriteTimeUtc -ne $orphan.LastWriteTimeUtc -or
                    $lockedInfo.LastWriteTimeUtc -gt $staleTemporaryCutoffUtc) {
                    continue
                }
                $length = [int64]$orphanStream.Length
                $contentHash = Get-CacheStreamSha256 -Stream $orphanStream
                Remove-CacheFileByExclusiveHandle -Path $orphan.FullName -Stream $orphanStream -ExpectedSha256 $contentHash
                $orphanStream.Dispose()
                $orphanStream = $null
                $recoveredFiles++
                $recoveredBytes += $length
            } catch {
                $errors.Add('A stale app-owned cache temporary could not be removed safely.')
            } finally {
                if ($orphanStream) { $orphanStream.Dispose() }
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
        [string[]]$MountCacheDirectories = @(),
        [string[]]$ActiveCachePaths = @(),
        [switch]$ActiveCacheOwnershipKnown
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { Get-CacheDefaultDirectory }
    }

    $ownershipSnapshot = Get-CacheVfsOwnershipSnapshot -CacheDirectory $CacheDirectory -ActiveCachePaths $ActiveCachePaths -ActiveCacheOwnershipKnown:$ActiveCacheOwnershipKnown
    $isUnixFileSystem = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    $pathComparison = if ($isUnixFileSystem) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }

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
            $namespaceInfo = Get-CacheVfsNamespaceInfo -Path $f.FullName -CacheDirectory $CacheDirectory
            # Skip the account-root sidecars, not remote filenames containing that text.
            if ($namespaceInfo.IsVfsMeta) { continue }

            $len = [int64]$f.Length
            $isInUse = Test-FileInUse -FilePath $f.FullName
            $isVfsEntry = [bool]$namespaceInfo.IsVfs
            $isOwnedByActiveMount = $false
            $isKnownCleanVfsEntry = $false
            if ($isVfsEntry) {
                $isOwnedByActiveMount = Test-CachePathWithinRoots -Path $f.FullName -Roots @($ownershipSnapshot.ActiveRoots) -Comparison $pathComparison
                $managedRoot = ConvertTo-CacheNormalizedPath $mDir
                if ($ownershipSnapshot.ProtectedCacheRoots.Contains($managedRoot)) { $isOwnedByActiveMount = $true }
                if ($ownershipSnapshot.OwnershipKnown -and -not $isOwnedByActiveMount) {
                    $metaPath = [string]$namespaceInfo.MetadataPath
                    $isKnownCleanVfsEntry = Test-CacheVfsMetadataClean -MetadataPath $metaPath
                }
            }

            # Determine relative cloud path from vfs/<remote>{hash}/<relPath>
            $relPath = $f.FullName.Substring($scanTarget.Length).TrimStart('\', '/')
            $firstSeparator = $relPath.IndexOfAny(@([char]'/', [char]'\'))
            if ($firstSeparator -ge 0 -and $firstSeparator -lt ($relPath.Length - 1)) {
                $cloudPath = $relPath.Substring($firstSeparator + 1)
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
                Status = if ($isInUse) { 'Staged / In-Use' } elseif ($isVfsEntry -and -not $ownershipSnapshot.OwnershipKnown) { 'VFS ownership unknown' } elseif ($isVfsEntry -and $isOwnedByActiveMount) { 'Managed by active mount' } elseif ($isVfsEntry -and -not $isKnownCleanVfsEntry) { 'Upload state unknown or pending' } elseif ($isVfsEntry) { 'Cloud-confirmed cache' } else { 'Local cache' }
                IsInUse = $isInUse
                IsVfsEntry = $isVfsEntry
                IsEvictable = (-not $isInUse -and (-not $isVfsEntry -or ($ownershipSnapshot.OwnershipKnown -and -not $isOwnedByActiveMount -and $isKnownCleanVfsEntry)))
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
        [string]$CacheDirectory = '',
        [string[]]$ActiveCachePaths = @(),
        [switch]$ActiveCacheOwnershipKnown
    )

    if (-not $CacheDirectory) {
        $settings = Get-NSCloudDriveSettings
        $CacheDirectory = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { Get-CacheDefaultDirectory }
    }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return @{ Success = $false; Error = 'The cache file no longer exists.' } }

    $isUnixFileSystem = ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix)
    $pathComparison = if ($isUnixFileSystem) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
    $normalizedCache = ConvertTo-CacheNormalizedPath $CacheDirectory
    $normalizedFile = ConvertTo-CacheNormalizedPath $FilePath
    $cachePrefix = $normalizedCache.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $normalizedCache -or -not $normalizedFile -or -not $normalizedFile.StartsWith($cachePrefix, $pathComparison)) {
        return @{ Success = $false; Error = 'Security error: File is outside the configured cache directory.' }
    }
    if (Test-CachePathContainsReparsePoint -Path $normalizedFile) {
        return @{ Success = $false; Error = 'The cache file or one of its parent paths is a link and cannot be safely evicted.' }
    }

    $namespaceInfo = Get-CacheVfsNamespaceInfo -Path $normalizedFile -CacheDirectory $normalizedCache
    $isVfsEntry = [bool]$namespaceInfo.IsVfs
    $metaPath = ''
    if ($isVfsEntry) {
        $ownershipSnapshot = Get-CacheVfsOwnershipSnapshot -CacheDirectory $normalizedCache -ActiveCachePaths $ActiveCachePaths -ActiveCacheOwnershipKnown:$ActiveCacheOwnershipKnown
        if (-not $ownershipSnapshot.OwnershipKnown) {
            return @{ Success = $false; Error = 'Active mount ownership is unknown; the VFS file was preserved.' }
        }
        if (Test-CachePathWithinRoots -Path $normalizedFile -Roots @($ownershipSnapshot.ActiveRoots) -Comparison $pathComparison) {
            return @{ Success = $false; Error = 'The VFS file belongs to an active mount and cannot be manually evicted.' }
        }
        $accountRoot = [string]$namespaceInfo.AccountRoot
        if ($accountRoot -and $ownershipSnapshot.ProtectedCacheRoots.Contains($accountRoot)) {
            return @{ Success = $false; Error = 'This VFS cache belongs to an active mount and cannot be manually evicted.' }
        }
        $metaPath = [string]$namespaceInfo.MetadataPath
        if (-not (Test-CacheVfsMetadataClean -MetadataPath $metaPath)) {
            return @{ Success = $false; Error = 'The cloud copy is not confirmed or VFS metadata is missing or invalid; the file was preserved.' }
        }
        if (Test-FileInUse -FilePath $metaPath) {
            return @{ Success = $false; Error = 'The VFS metadata is currently in use; please retry after the transfer settles.' }
        }
    }

    if (Test-FileInUse -FilePath $normalizedFile) {
        return @{ Success = $false; Error = 'The cache file is currently open or transferring. Please wait until it is idle.' }
    }

    $fileInfo = Get-Item -LiteralPath $normalizedFile -Force -ErrorAction Stop
    $removal = Remove-SafeCacheFileEntry `
        -FilePath $normalizedFile `
        -CacheDirectory $normalizedCache `
        -ActiveCachePaths $ActiveCachePaths `
        -ActiveCacheOwnershipKnown:$ActiveCacheOwnershipKnown `
        -ExpectedSizeBytes ([int64]$fileInfo.Length) `
        -ExpectedLastWriteUtc $fileInfo.LastWriteTimeUtc
    if (-not $removal.Success) { return @{ Success = $false; Error = [string]$removal.Reason } }
    return @{ Success = $true; FilePath = $normalizedFile }
}

# ==============================================================================
# POST-TRANSFER CONFIGURABLE CACHE CLEANUP
# ==============================================================================

function Invoke-PostTransferCacheCleanup {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = '',
        [hashtable]$Settings = $null,
        [object[]]$Jobs = @()
    )

    if (-not $Settings) { $Settings = Get-NSCloudDriveSettings }
    $policy = if ($Settings.PostTransferCachePolicy) { [string]$Settings.PostTransferCachePolicy } else { 'RemoveAfterVerifiedUpload' }
    $evictedFiles = 0
    $evictedBytes = 0L
    $skippedCount = 0
    if ($Jobs.Count -eq 0 -and (Get-Command Get-CloudTransferQueue -ErrorAction SilentlyContinue)) {
        try { $Jobs = @(Get-CloudTransferQueue) } catch { $Jobs = @() }
    }
    if (-not (Get-Command Invoke-ConfirmedStagedVfsSourceCleanup -ErrorAction SilentlyContinue)) {
        return [ordered]@{
            Policy = $policy
            EvictedFiles = 0
            EvictedBytes = 0L
            SkippedCount = 0
            Reason = 'No job-scoped staged cleanup service is available; no cache files were swept.'
        }
    }

    # Deliberately do not sweep a provider VFS directory here. Only the durable queue
    # knows which staged source revision was remotely confirmed; unrelated reads,
    # other accounts, and pending uploads must remain untouched.
    foreach ($job in @($Jobs)) {
        $status = [string](Get-CloudTransferFieldValue $job 'Status')
        if ($status -ne 'Completed and remotely confirmed' -or -not [bool](Get-CloudTransferFieldValue $job 'RecoveredFromVfsCache')) { continue }
        $before = [string](Get-CloudTransferFieldValue $job 'StagedCleanupStatus')
        $cleanupResult = Invoke-ConfirmedStagedVfsSourceCleanup -Job $job
        if ($cleanupResult.Success -and [string]$cleanupResult.Status -eq 'Removed' -and $before -ne 'Removed') {
            $evictedFiles++
            $evictedBytes += [int64]$cleanupResult.BytesRemoved
        } elseif (-not $cleanupResult.Success) {
            $skippedCount++
        }
    }

    return [ordered]@{
        Policy = $policy
        EvictedFiles = $evictedFiles
        EvictedBytes = $evictedBytes
        SkippedCount = $skippedCount
        Reason = 'Cleanup was limited to exact, remotely confirmed staged queue sources.'
    }
}
