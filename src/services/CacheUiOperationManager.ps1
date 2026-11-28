Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Start-CacheUiOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$CacheDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('Clean', 'Evict')][string]$Action,
        [string]$FilePath = '',
        [string[]]$ActiveCachePaths = @(),
        [switch]$ActiveCacheOwnershipKnown
    )

    if (-not (Get-Command Start-NSBackgroundOperation -ErrorAction SilentlyContinue)) {
        throw 'Background cache operations are unavailable.'
    }
    if ($Action -eq 'Evict' -and -not $FilePath) {
        throw 'An eviction path is required.'
    }

    return Start-NSBackgroundOperation `
        -ArgumentList @($SourceRoot, $CacheDirectory, $Action, $FilePath, [string[]]$ActiveCachePaths, [bool]$ActiveCacheOwnershipKnown) `
        -ScriptBlock {
            param([string]$root, [string]$cacheDirectory, [string]$operation, [string]$path, [string[]]$activeCachePaths, [bool]$activeCacheOwnershipKnown)
            $ErrorActionPreference = 'Stop'
            try {
                . (Join-Path $root 'services\SettingsManager.ps1')
                . (Join-Path $root 'services\VirtualDriveManager.ps1')
                . (Join-Path $root 'services\CacheManager.ps1')
                if ($operation -eq 'Clean') {
                    $result = Invoke-SafeCacheCleanup -CacheDirectory $cacheDirectory -Force `
                        -ActiveCachePaths $activeCachePaths -ActiveCacheOwnershipKnown:$activeCacheOwnershipKnown
                    return [pscustomobject]@{
                        Action = 'Clean'
                        Success = $true
                        CleanedBytes = [int64]$result.CleanedBytes
                        CleanedFiles = [int]$result.CleanedFiles
                        SkippedInUseCount = [int]$result.SkippedInUseCount
                        SkippedStagedCount = [int]$result.SkippedStagedCount
                        Error = ''
                    }
                }

                $result = Remove-SingleCacheFile -FilePath $path -CacheDirectory $cacheDirectory
                $removeSuccess = [bool]$result['Success']
                $removedBytes = 0L
                if ($result.ContainsKey('BytesRemoved')) { $removedBytes = [int64]$result['BytesRemoved'] }
                return [pscustomobject]@{
                    Action = 'Evict'
                    Success = $removeSuccess
                    CleanedBytes = $removedBytes
                    CleanedFiles = [int]$removeSuccess
                    SkippedInUseCount = 0
                    SkippedStagedCount = 0
                    Error = if ($removeSuccess) { '' } else { 'The cache file could not be removed safely.' }
                }
            } catch {
                return [pscustomobject]@{
                    Action = $operation
                    Success = $false
                    CleanedBytes = 0L
                    CleanedFiles = 0
                    SkippedInUseCount = 0
                    SkippedStagedCount = 0
                    Error = 'The cache operation could not be completed safely.'
                }
            }
        }
}

function Complete-CacheUiOperation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Worker)

    if (-not (Test-NSBackgroundOperationCompleted $Worker)) {
        throw 'The background cache operation has not completed.'
    }
    try {
        $completed = Complete-NSBackgroundOperation $Worker
        if ($completed.HadErrors -or $completed.Output.Count -eq 0) {
            return [pscustomobject]@{
                Action = ''
                Success = $false
                CleanedBytes = 0L
                CleanedFiles = 0
                SkippedInUseCount = 0
                SkippedStagedCount = 0
                Error = 'The cache operation could not be completed safely.'
            }
        }
        return $completed.Output[-1]
    } catch {
        return [pscustomobject]@{
            Action = ''
            Success = $false
            CleanedBytes = 0L
            CleanedFiles = 0
            SkippedInUseCount = 0
            SkippedStagedCount = 0
            Error = 'The cache operation could not be completed safely.'
        }
    }
}
