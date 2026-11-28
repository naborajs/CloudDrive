Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing background cache UI operations...'
. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CacheManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\BackgroundOperationManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CacheUiOperationManager.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('nscd_cache_ui_' + [Guid]::NewGuid().ToString('N'))
$cacheDirectory = Join-Path $testRoot 'cache'
$managedCacheDirectory = Join-Path $cacheDirectory 'gdrive_test'
$evictPath = Join-Path $cacheDirectory 'single-eviction.tmp'
$cleanPath = Join-Path $managedCacheDirectory 'bulk-clean.tmp'
[void][System.IO.Directory]::CreateDirectory($managedCacheDirectory)

try {
    [System.IO.File]::WriteAllBytes($evictPath, [byte[]]@(1, 2, 3, 4))
    $evictWorker = Start-CacheUiOperation -SourceRoot (Join-Path $PSScriptRoot '..\src') `
        -CacheDirectory $cacheDirectory -Action Evict -FilePath $evictPath
    if (-not $evictWorker.Handle.AsyncWaitHandle.WaitOne(30000)) {
        Stop-NSBackgroundOperation $evictWorker
        throw 'Single-file cache eviction did not finish within 30 seconds.'
    }
    $evictResult = Complete-CacheUiOperation -Worker $evictWorker
    if (-not [bool]$evictResult.Success -or [System.IO.File]::Exists($evictPath)) {
        throw 'The background single-file eviction did not safely remove the selected test file.'
    }
    Write-Output '  [PASS] Selected-file eviction runs in a background operation and removes only the selected file'

    [System.IO.File]::WriteAllBytes($cleanPath, [byte[]]@(5, 6, 7, 8))
    $cleanWorker = Start-CacheUiOperation -SourceRoot (Join-Path $PSScriptRoot '..\src') `
        -CacheDirectory $cacheDirectory -Action Clean -ActiveCacheOwnershipKnown -ActiveCachePaths @()
    if (-not $cleanWorker.Handle.AsyncWaitHandle.WaitOne(30000)) {
        Stop-NSBackgroundOperation $cleanWorker
        throw 'Bulk cache cleanup did not finish within 30 seconds.'
    }
    $cleanResult = Complete-CacheUiOperation -Worker $cleanWorker
    if (-not [bool]$cleanResult.Success -or [int]$cleanResult.CleanedFiles -ne 1 -or
        [System.IO.File]::Exists($cleanPath)) {
        throw 'The background bulk-clean operation did not safely remove the eligible test file.'
    }
    Write-Output '  [PASS] Bulk cache cleanup runs in a background operation and reports a safe result'
} finally {
    foreach ($knownPath in @($evictPath, $cleanPath)) {
        if ([System.IO.File]::Exists($knownPath)) { [System.IO.File]::Delete($knownPath) }
    }
    if ([System.IO.Directory]::Exists($managedCacheDirectory)) { [System.IO.Directory]::Delete($managedCacheDirectory, $false) }
    if ([System.IO.Directory]::Exists($cacheDirectory)) { [System.IO.Directory]::Delete($cacheDirectory, $false) }
    if ([System.IO.Directory]::Exists($testRoot)) { [System.IO.Directory]::Delete($testRoot, $false) }
}

Write-Output 'All background cache UI operation tests passed.'
