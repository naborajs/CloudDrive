Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing confirmed staged-cache cleanup in an isolated runspace...'

$originalLocalAppData = $env:LOCALAPPDATA
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('nscd_staged_cleanup_worker_' + [Guid]::NewGuid().ToString('N'))
$env:LOCALAPPDATA = $testRoot
$cacheDirectory = Join-Path $testRoot 'cache'
$accountId = 'worker_cleanup_test'
$accountRoot = Join-Path $cacheDirectory $accountId
$relativeDirectory = 'selected'
$relativePath = "$relativeDirectory\already-sent.txt"
$sourcePath = Join-Path (Join-Path (Join-Path $accountRoot 'vfs') $relativeDirectory) 'already-sent.txt'
$metadataPath = Join-Path (Join-Path (Join-Path $accountRoot 'vfsMeta') $relativeDirectory) 'already-sent.txt'
$queuePath = Join-Path $testRoot 'transfer-queue.json'
$settingsDirectory = Join-Path $testRoot 'NSCloudDrive\config'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$sourceRoot = Join-Path $PSScriptRoot '..\src'
$worker = $null

try {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $sourcePath))
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $metadataPath))
    [void][System.IO.Directory]::CreateDirectory($settingsDirectory)
    [System.IO.File]::WriteAllText($sourcePath, 'remote-confirmed temporary staged payload')
    [System.IO.File]::WriteAllText($metadataPath, '{"Dirty":false}')
    $fileInfo = Get-Item -LiteralPath $sourcePath
    $account = [ordered]@{
        Id = $accountId
        ProviderId = 'gdrive'
        DisplayName = 'Cleanup Worker Test'
        DriveLetter = 'Z'
        CacheDirectory = $cacheDirectory
    }
    [ordered]@{
        CacheDirectory = $cacheDirectory
        CacheMaxGigabytes = 1
        Accounts = @($account)
        DiagnosticLogging = 'Off'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

    . (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
    . (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
    . (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
    . (Join-Path $PSScriptRoot '..\src\services\BackgroundOperationManager.ps1')
    . (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')
    . (Join-Path $PSScriptRoot '..\src\services\StagedCacheCleanupWorker.ps1')
    Set-TransferQueueFilePath -Path $queuePath
    $script:CloudTransferQueue = [System.Collections.Generic.List[object]]::new()
    $script:TransferQueueStateUnavailable = $false

    Set-Item -Path Function:\Test-RemoteCloudFileDeduplication -Value {
        return @{ IsPresent = $true; Status = 'AlreadyInCloud'; Reason = 'Exact destination path and size were confirmed.' }
    }
    $candidate = [pscustomobject]@{
        Path = $sourcePath
        RelativePath = $relativePath
        AccountId = $accountId
        ProviderId = 'gdrive'
        Length = [int64]$fileInfo.Length
        LastWriteTimeUtc = $fileInfo.LastWriteTimeUtc
        IsOutsideActiveCache = $true
        HasStagedPathConflict = $false
        State = 'Needs review: outside the active rclone cache root'
    }
    $import = Import-StagedVfsFilesToTransferQueue -StagedFiles @($candidate) -Accounts @($account) -BatchName 'Confirmed staged cleanup test'
    if ([int]$import.AlreadySettledCount -ne 1 -or [int]$import.AdoptedCount -ne 0 -or
        -not [System.IO.File]::Exists($sourcePath) -or -not [System.IO.File]::Exists($metadataPath)) {
        throw 'An exact already-present cloud match was not checkpointed while preserving the staged files until worker cleanup.'
    }
    $jobs = @($script:CloudTransferQueue)
    if ($jobs.Count -ne 1 -or [string]$jobs[0]['Origin'] -ne 'ConfirmedStagedCleanup' -or
        [string]$jobs[0]['Status'] -ne 'Completed and remotely confirmed') {
        throw 'The already-present cloud match did not create a terminal cleanup-only queue record.'
    }
    Write-Output '  [PASS] Exact already-in-cloud staged files create a durable cleanup-only checkpoint'

    if (-not (Start-StagedCacheCleanupWorker -SourceRoot $sourceRoot)) {
        throw 'The staged-cache cleanup worker did not start.'
    }
    $worker = $script:StagedCacheCleanupWorker
    if (-not $worker.Handle.AsyncWaitHandle.WaitOne(30000)) {
        Stop-NSBackgroundOperation $worker
        throw 'The isolated staged-cache cleanup worker did not finish within 30 seconds.'
    }
    if (-not (Complete-StagedCacheCleanupWorker)) {
        throw 'The isolated staged-cache cleanup worker did not complete successfully.'
    }
    if ([System.IO.File]::Exists($sourcePath) -or [System.IO.File]::Exists($metadataPath) -or
        [string]$jobs[0]['StagedCleanupStatus'] -ne 'Removed') {
        throw "The confirmed staged cache files were not removed automatically; status='$($jobs[0]['StagedCleanupStatus'])'."
    }
    Write-Output '  [PASS] Worker loads mount/path safety dependencies and automatically removes confirmed staged data and metadata'
} finally {
    Remove-Item -Path Function:\Test-RemoteCloudFileDeduplication -ErrorAction SilentlyContinue
    if ($worker -and -not (Test-NSBackgroundOperationCompleted $worker)) {
        Stop-NSBackgroundOperation $worker
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'All staged-cache cleanup worker tests passed.'
