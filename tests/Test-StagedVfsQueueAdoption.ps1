# ==============================================================================
# NS Cloud Drive - Staged VFS Upload Adoption Test Suite
# Verifies that dirty staged files left in a superseded rclone cache root are
# adopted into the durable transfer queue, uploaded from their staged location,
# counted exactly once, and never moved or deleted by adoption.
#
# Hermetic: every queue file, cache root and staged file lives in %TEMP%.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== NS Cloud Drive Staged VFS Queue Adoption Test Suite ===" -ForegroundColor Cyan

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\AdaptiveBandwidthManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

Write-Host "  [PASS] Transfer modules loaded under Set-StrictMode -Version Latest"

function New-StagedCacheFile {
    param(
        [Parameter(Mandatory = $true)][string]$VfsRoot,
        [Parameter(Mandatory = $true)][string]$MetaRoot,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $dataPath = Join-Path $VfsRoot $RelativePath
    $metaPath = Join-Path $MetaRoot $RelativePath
    foreach ($candidate in @($dataPath, $metaPath)) {
        $dir = [System.IO.Path]::GetDirectoryName($candidate)
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
    }
    [System.IO.File]::WriteAllText($dataPath, $Content)
    $meta = [ordered]@{
        ModTime     = '2026-10-26T19:53:50+05:30'
        ATime       = '2026-10-27T00:00:00+05:30'
        Size        = $Content.Length
        Rs          = @([ordered]@{ Pos = 0; Size = $Content.Length })
        Fingerprint = ''
        Dirty       = $true
    }
    [System.IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 5))
    return $dataPath
}

function Get-FlatQueue {
    $result = Get-CloudTransferQueue
    if ($result -is [array] -and $result.Count -gt 0 -and $result[0] -is [array]) {
        return @($result[0])
    }
    if ($null -ne $result) { return @($result) }
    return @()
}

$sandbox = Join-Path $env:TEMP ("NSCloudDrive_StagedAdoption_" + [Guid]::NewGuid().ToString('N'))
$accountKey = 'gdrive_testaccount123'
$accountId = 'testaccount123'
$cacheDir = Join-Path $sandbox 'cache'
$accountRoot = Join-Path $cacheDir $accountKey
$orphanRoot = Join-Path $accountRoot 'vfs\gdrive'
$orphanMeta = Join-Path $accountRoot 'vfsMeta\gdrive'
$activeRoot = Join-Path $accountRoot 'vfs\gdrive{z0wI1}'
$activeMeta = Join-Path $accountRoot 'vfsMeta\gdrive{z0wI1}'
$queueFile = Join-Path $sandbox 'state\transfer-jobs.json'
$accounts = @([pscustomobject]@{
    Id          = $accountId
    ProviderId  = 'gdrive'
    Label       = 'Staged Adoption Test Account'
    DriveLetter = 'Q'
})

try {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $queueFile -Parent))
    [void][System.IO.Directory]::CreateDirectory($activeRoot)
    [void][System.IO.Directory]::CreateDirectory($activeMeta)

    Set-TransferQueueFilePath -Path $queueFile
    $script:TransferQueueStateUnavailable = $false
    $script:CloudTransferQueue.Clear()

    # --------------------------------------------------------------------------
    # Phase A: orphan-root staged files are distinguishable from the live root
    # --------------------------------------------------------------------------
    $photoOne = New-StagedCacheFile -VfsRoot $orphanRoot -MetaRoot $orphanMeta -RelativePath 'Media\Photo One.jpg' -Content ('A' * 128)
    $photoTwo = New-StagedCacheFile -VfsRoot $orphanRoot -MetaRoot $orphanMeta -RelativePath 'Media\Photo Two.jpg' -Content ('B' * 256)
    $noteFile = New-StagedCacheFile -VfsRoot $orphanRoot -MetaRoot $orphanMeta -RelativePath 'Docs\Deep\note.txt' -Content 'nested note'
    $activeFile = New-StagedCacheFile -VfsRoot $activeRoot -MetaRoot $activeMeta -RelativePath 'Media\Active.jpg' -Content ('C' * 64)

    $pending = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot))
    if ($pending.Count -ne 4) {
        throw "Expected 4 dirty staged files (3 orphan-root + 1 live-root), got $($pending.Count)."
    }
    $byRelative = @{}
    foreach ($item in $pending) { $byRelative[[string]$item.RelativePath] = $item }

    foreach ($rel in @('Media/Photo One.jpg', 'Media/Photo Two.jpg', 'Docs/Deep/note.txt')) {
        if (-not $byRelative.ContainsKey($rel)) { throw "Staged file '$rel' was not discovered." }
        if (-not $byRelative[$rel].IsOutsideActiveCache) { throw "'$rel' was not reported as outside the live cache root." }
    }
    if ($byRelative['Media/Active.jpg'].IsOutsideActiveCache) {
        throw 'A file inside the live cache root was reported as outside it.'
    }

    $failClosed = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir)
    if (@($failClosed | Where-Object { $_.IsOutsideActiveCache }).Count -ne 0) {
        throw 'Staged files were treated as adoptable while the live cache root was unknown.'
    }
    Write-Host "  [PASS] Live-root files are excluded and adoption fails closed without a known cache root"

    # --------------------------------------------------------------------------
    # Phase B: adoption creates durable jobs for orphan-root files only
    # --------------------------------------------------------------------------
    $adoption = Import-StagedVfsFilesToTransferQueue -StagedFiles $pending -Accounts $accounts
    if ([int]$adoption.AdoptedCount -ne 3) {
        throw "Expected 3 adopted staged files, got $($adoption.AdoptedCount) (skipped $($adoption.SkippedCount), failed $($adoption.FailedCount))."
    }
    if ([int]$adoption.SkippedCount -ne 1) {
        throw "Expected the live-root file to be skipped, got SkippedCount=$($adoption.SkippedCount)."
    }

    $queueAfterAdoption = @(Get-FlatQueue)
    if ($queueAfterAdoption.Count -ne 3) {
        throw "Expected 3 durable queue jobs after adoption, got $($queueAfterAdoption.Count)."
    }
    if (@($queueAfterAdoption | Where-Object { -not [bool]$_['RecoveredFromVfsCache'] }).Count -ne 0) {
        throw 'An adopted job was not flagged as recovered from the VFS cache.'
    }
    if (@($queueAfterAdoption | Where-Object { [string]$_['ConflictAction'] -ne 'Overwrite' }).Count -ne 0) {
        throw 'Adopted jobs must overwrite the stale remote revision.'
    }
    if (@($queueAfterAdoption | Where-Object { [int]$_['MaxRetries'] -lt 5 }).Count -ne 0) {
        throw 'Adopted jobs did not receive the recovery retry budget.'
    }
    if (@($queueAfterAdoption | Where-Object { [string]$_['AccountId'] -ne $accountId -or [string]$_['ProviderId'] -ne 'gdrive' }).Count -ne 0) {
        throw 'Adopted jobs were not bound to the real destination account.'
    }

    $expectedDestinations = @('Media/Photo One.jpg', 'Media/Photo Two.jpg', 'Docs/Deep/note.txt')
    $actualDestinations = @($queueAfterAdoption | ForEach-Object { [string]$_['DestinationFilePath'] })
    foreach ($expected in $expectedDestinations) {
        if ($actualDestinations -notcontains $expected) { throw "Adopted job destination '$expected' is missing." }
    }
    foreach ($job in $queueAfterAdoption) {
        if ([string]$job['StagedSourcePath'] -ne [string]$job['SourcePath']) {
            throw 'An adopted job does not point its source at the staged cache file.'
        }
        if ([string]::IsNullOrWhiteSpace([string]$job['StagedSourceLastWriteUtc'])) {
            throw 'An adopted job has no staged revision timestamp.'
        }
    }
    Write-Host "  [PASS] Orphan-root staged files became durable, verified-upload queue jobs"

    # --------------------------------------------------------------------------
    # Phase C: staged bytes are untouched and the linkage survives persistence
    # --------------------------------------------------------------------------
    foreach ($staged in @($photoOne, $photoTwo, $noteFile, $activeFile)) {
        if (-not (Test-Path -LiteralPath $staged -PathType Leaf)) {
            throw "Adoption removed or moved a staged source file: $staged"
        }
    }
    if ([System.IO.File]::ReadAllText($photoOne) -ne ('A' * 128)) {
        throw 'Staged source content changed during adoption.'
    }
    if (-not (Test-Path -LiteralPath $queueFile -PathType Leaf)) {
        throw 'Adoption did not persist the durable transfer queue.'
    }

    $persisted = [System.IO.File]::ReadAllText($queueFile) | ConvertFrom-Json
    if (@($persisted.Jobs).Count -ne 3) {
        throw "Expected 3 persisted jobs, got $(@($persisted.Jobs).Count)."
    }
    foreach ($job in @($persisted.Jobs)) {
        if (-not $job.PSObject.Properties['RecoveredFromVfsCache'] -or -not [bool]$job.RecoveredFromVfsCache) {
            throw 'Persisted job lost its VFS recovery marker.'
        }
        if (-not $job.PSObject.Properties['StagedSourceLastWriteUtc'] -or [string]::IsNullOrWhiteSpace([string]$job.StagedSourceLastWriteUtc)) {
            throw 'Persisted job lost its staged revision timestamp.'
        }
        if (-not $job.PSObject.Properties['StagedSourcePath'] -or [string]::IsNullOrWhiteSpace([string]$job.StagedSourcePath)) {
            throw 'Persisted job lost its staged source path.'
        }
    }
    Write-Host "  [PASS] Staged sources were preserved and the recovery linkage was persisted"

    # Simulated restart: reload from disk, then re-run adoption.
    $script:CloudTransferQueue.Clear()
    $loadedCount = Load-DurableTransferQueue
    if ([int]$loadedCount -ne 3) {
        throw "Expected 3 jobs to reload after a simulated restart, got $loadedCount."
    }
    $reloaded = @(Get-FlatQueue)
    if (@($reloaded | Where-Object { -not [bool]$_['RecoveredFromVfsCache'] }).Count -ne 0) {
        throw 'Reloaded jobs lost their VFS recovery marker.'
    }
    if (@($reloaded | Where-Object { [string]::IsNullOrWhiteSpace([string]$_['StagedSourceLastWriteUtc']) }).Count -ne 0) {
        throw 'Reloaded jobs lost their staged revision timestamp.'
    }
    Write-Host "  [PASS] Staged recovery linkage survives a reload of durable state"

    # --------------------------------------------------------------------------
    # Phase D: re-running adoption is idempotent
    # --------------------------------------------------------------------------
    $rescan = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot))
    $secondPass = Import-StagedVfsFilesToTransferQueue -StagedFiles $rescan -Accounts $accounts
    if ([int]$secondPass.AdoptedCount -ne 0) {
        throw "Adoption created duplicate jobs on a second pass: $($secondPass.AdoptedCount)."
    }
    if ([int]$secondPass.AlreadyQueuedCount -ne 3) {
        throw "Expected 3 already-queued staged files on a second pass, got $($secondPass.AlreadyQueuedCount)."
    }
    if (@(Get-FlatQueue).Count -ne 3) {
        throw 'Queue length changed during an idempotent adoption pass.'
    }
    Write-Host "  [PASS] Repeated adoption passes do not duplicate durable jobs"

    # --------------------------------------------------------------------------
    # Phase E: ambiguous same-path copies are never auto-adopted
    # --------------------------------------------------------------------------
    $conflictPath = New-StagedCacheFile -VfsRoot $orphanRoot -MetaRoot $orphanMeta -RelativePath 'Media\Conflict.jpg' -Content ('D' * 32)
    $conflictItem = [pscustomobject]@{
        Path                 = $conflictPath
        Name                 = 'Conflict.jpg'
        RelativePath         = 'Media/Conflict.jpg'
        Length               = [int64]32
        LastWriteTimeUtc     = (Get-Item -LiteralPath $conflictPath).LastWriteTimeUtc
        AccountId            = $accountKey
        ProviderId           = 'gdrive'
        IsDirty              = $true
        HasMeta              = $true
        HasStagedPathConflict = $true
        IsOutsideActiveCache = $true
        State                = 'Needs review: multiple dirty staged copies share this path'
        DuplicateCopies      = 2
    }
    $conflictResult = Import-StagedVfsFilesToTransferQueue -StagedFiles @($conflictItem) -Accounts $accounts
    if ([int]$conflictResult.AdoptedCount -ne 0 -or [int]$conflictResult.SkippedCount -ne 1) {
        throw 'An ambiguous same-path staged copy was adopted instead of being left for review.'
    }
    Write-Host "  [PASS] Ambiguous same-path staged copies remain review-only"

    # Remove the synthetic conflict fixture so later accounting phases see only the
    # three adopted orphan files.
    Remove-Item -LiteralPath $conflictPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $orphanMeta 'Media\Conflict.jpg') -Force -ErrorAction SilentlyContinue

    # --------------------------------------------------------------------------
    # Phase F: confirmed revisions stop inflating pending counts
    # --------------------------------------------------------------------------
    $photoOneJob = @($script:CloudTransferQueue | Where-Object { [string]$_['DestinationFilePath'] -eq 'Media/Photo One.jpg' })[0]
    $photoOneJob['Status'] = 'Completed and remotely confirmed'

    $orphanOnly = @($rescan | Where-Object { $_.RelativePath -ne 'Media/Active.jpg' })
    $settledSummary = Get-CloudTransferPendingSummary -QueueItems @(Get-FlatQueue) -StagedFiles $orphanOnly
    if ([int]$settledSummary.StagedOnlyCount -ne 0) {
        throw "A remotely confirmed staged revision still counted as pending (StagedOnlyCount=$($settledSummary.StagedOnlyCount))."
    }
    if ([int]$settledSummary.PendingCount -ne 2) {
        throw "Expected 2 remaining pending uploads after one confirmation, got $($settledSummary.PendingCount)."
    }

    # A newer dirty revision at the same path must be counted and re-queued.
    (Get-Item -LiteralPath $photoOne).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(5)
    $newerScan = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot) |
        Where-Object { $_.RelativePath -ne 'Media/Active.jpg' })
    $newerSummary = Get-CloudTransferPendingSummary -QueueItems @(Get-FlatQueue) -StagedFiles $newerScan
    if ([int]$newerSummary.StagedOnlyCount -ne 1) {
        throw "A newer staged revision was hidden by an older confirmation (StagedOnlyCount=$($newerSummary.StagedOnlyCount))."
    }

    $newerAdoption = Import-StagedVfsFilesToTransferQueue -StagedFiles $newerScan -Accounts $accounts
    if ([int]$newerAdoption.AdoptedCount -ne 1) {
        throw "A newer staged revision was not queued after its predecessor was confirmed (adopted $($newerAdoption.AdoptedCount))."
    }
    if (@(Get-FlatQueue).Count -ne 4) {
        throw 'The newer staged revision did not add exactly one durable job.'
    }
    $completedJobs = @(Get-FlatQueue | Where-Object { [string]$_['Status'] -eq 'Completed and remotely confirmed' })
    if ($completedJobs.Count -ne 1) {
        throw 'Adopting a newer revision mutated the completed job.'
    }
    Write-Host "  [PASS] Confirmed revisions are suppressed while newer dirty revisions are queued once"

    # --------------------------------------------------------------------------
    # Phase F2: clearing the completed list must not resurrect a settled upload
    # --------------------------------------------------------------------------
    $settledPath = New-StagedCacheFile -VfsRoot $orphanRoot -MetaRoot $orphanMeta -RelativePath 'Docs\Settled.txt' -Content 'settled payload'
    $settledScan = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot) |
        Where-Object { $_.RelativePath -eq 'Docs/Settled.txt' })
    if ($settledScan.Count -ne 1) { throw 'The settlement fixture was not discovered as a staged file.' }

    $settledAdoption = Import-StagedVfsFilesToTransferQueue -StagedFiles $settledScan -Accounts $accounts
    if ([int]$settledAdoption.AdoptedCount -ne 1) {
        throw "Failed to queue the settlement fixture (adopted $($settledAdoption.AdoptedCount))."
    }
    $settledIdentity = Get-CloudTransferStagedIdentity -AccountId $accountId -ProviderId 'gdrive' -RelativePath 'Docs/Settled.txt'
    $settledJob = @($script:CloudTransferQueue | Where-Object { [string]$_['DestinationFilePath'] -eq 'Docs/Settled.txt' })[0]
    $settledJob['Status'] = 'Completed and remotely confirmed'

    $queueBeforeClear = @(Get-FlatQueue).Count
    $completedBeforeClear = @(Get-FlatQueue | Where-Object { [string]$_['Status'] -eq 'Completed and remotely confirmed' }).Count
    if ($completedBeforeClear -lt 1) { throw 'The settlement fixture was not marked completed.' }
    Clear-CloudTransferQueue -All:$false
    $queueAfterClear = @(Get-FlatQueue)
    if (@($queueAfterClear | Where-Object { [string]$_['Status'] -eq 'Completed and remotely confirmed' }).Count -ne 0) {
        throw 'Clear-CloudTransferQueue did not remove the completed job.'
    }
    if ($queueAfterClear.Count -ne ($queueBeforeClear - $completedBeforeClear)) {
        throw "Clearing completed jobs removed the wrong number of jobs ($queueBeforeClear - $completedBeforeClear -> $($queueAfterClear.Count))."
    }
    if (-not (Test-Path -LiteralPath $settledPath -PathType Leaf)) {
        throw 'Clearing completed jobs deleted the preserved staged source.'
    }
    $ledgerEntry = Get-CloudTransferSettledStagedEntry -Identity $settledIdentity
    if ($null -eq $ledgerEntry) {
        throw 'Settlement evidence was lost when the completed job was cleared.'
    }

    $settledSummary = Get-CloudTransferPendingSummary -QueueItems @(Get-FlatQueue) -StagedFiles $settledScan
    if ([int]$settledSummary.StagedOnlyCount -ne 0) {
        throw "A settled staged revision reappeared as pending after clearing completed jobs (StagedOnlyCount=$($settledSummary.StagedOnlyCount))."
    }
    $reAdopt = Import-StagedVfsFilesToTransferQueue -StagedFiles $settledScan -Accounts $accounts
    if ([int]$reAdopt.AdoptedCount -ne 0 -or [int]$reAdopt.AlreadySettledCount -ne 1) {
        throw "A settled staged revision was queued again after clearing completed jobs (adopted $($reAdopt.AdoptedCount), settled $($reAdopt.AlreadySettledCount))."
    }
    if (@(Get-FlatQueue).Count -ne $queueAfterClear.Count) {
        throw 'Re-adoption changed the queue despite the settlement record.'
    }

    # A genuinely newer revision at the same path must still upload.
    (Get-Item -LiteralPath $settledPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(10)
    $newerSettledScan = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot) |
        Where-Object { $_.RelativePath -eq 'Docs/Settled.txt' })
    $newerSettledAdoption = Import-StagedVfsFilesToTransferQueue -StagedFiles $newerSettledScan -Accounts $accounts
    if ([int]$newerSettledAdoption.AdoptedCount -ne 1) {
        throw 'A newer revision of a settled staged file was not queued.'
    }

    # The ledger must survive a restart on its own, not only while a job exists.
    $script:CloudTransferQueue.Clear()
    $script:CloudTransferSettledStaged.Clear()
    $null = Load-DurableTransferQueue
    if ($null -eq (Get-CloudTransferSettledStagedEntry -Identity $settledIdentity)) {
        throw 'The settlement ledger was not reloaded from durable state.'
    }
    $persistedQueue = [System.IO.File]::ReadAllText($queueFile) | ConvertFrom-Json
    if (-not $persistedQueue.PSObject.Properties['SettledStagedRevisions']) {
        throw 'Durable queue state does not record settled staged revisions.'
    }
    if (@($persistedQueue.SettledStagedRevisions | Where-Object { [string]$_.Identity -eq $settledIdentity }).Count -lt 1) {
        throw 'The settled staged revision is missing from durable state.'
    }
    Write-Host "  [PASS] Clearing completed jobs cannot resurrect a settled staged upload"

    # --------------------------------------------------------------------------
    # Phase G: the 197-file accounting regression (32 queued + 165 staged)
    # --------------------------------------------------------------------------
    $cacheDir2 = Join-Path $sandbox 'cache2'
    $accountRoot2 = Join-Path $cacheDir2 $accountKey
    $orphanRoot2 = Join-Path $accountRoot2 'vfs\gdrive'
    $orphanMeta2 = Join-Path $accountRoot2 'vfsMeta\gdrive'
    $activeRoot2 = Join-Path $accountRoot2 'vfs\gdrive{z0wI1}'
    $activeMeta2 = Join-Path $accountRoot2 'vfsMeta\gdrive{z0wI1}'
    $queueFile2 = Join-Path $sandbox 'state2\transfer-jobs.json'
    [void][System.IO.Directory]::CreateDirectory($activeRoot2)
    [void][System.IO.Directory]::CreateDirectory($activeMeta2)

    Set-TransferQueueFilePath -Path $queueFile2
    $script:CloudTransferQueue.Clear()
    $script:CloudTransferSettledStaged.Clear()

    $destination = @{ Id = $accountId; ProviderId = 'gdrive' }
    $localSource = @{ Id = 'local'; ProviderId = 'local' }
    for ($i = 1; $i -le 32; $i++) {
        [void](Add-CloudTransferQueueItem -SourceAccount $localSource `
            -SourcePath (Join-Path $sandbox "existing\$i.txt") `
            -DestinationAccount $destination -DestinationPath 'bulk' `
            -ConflictAction 'Overwrite' -MaxRetries 5 -FileSizeBytes 16 `
            -BatchId 'existing' -BatchName 'Existing uploads' -RelativePath "bulk/Job $i.txt" -SkipPersist)
    }
    if (@(Get-FlatQueue).Count -ne 32) { throw 'Failed to stage the 32 pre-existing queue jobs.' }

    for ($i = 1; $i -le 165; $i++) {
        $name = "Image {0:D3}.jpg" -f $i
        [void](New-StagedCacheFile -VfsRoot $orphanRoot2 -MetaRoot $orphanMeta2 -RelativePath "bulk\$name" -Content ('E' * 16))
    }
    $staged165 = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir2 -ActiveCachePaths @($activeRoot2))
    if ($staged165.Count -ne 165) {
        throw "Expected 165 staged files in the accounting fixture, got $($staged165.Count)."
    }

    $beforeAdoption = Get-CloudTransferPendingSummary -QueueItems @(Get-FlatQueue) -StagedFiles $staged165
    if ([int]$beforeAdoption.PendingCount -ne 197) {
        throw "Expected 197 honest pending transfers before adoption, got $($beforeAdoption.PendingCount)."
    }
    if ([int]$beforeAdoption.StagedOnlyCount -ne 165) {
        throw "Expected 165 staged-only transfers before adoption, got $($beforeAdoption.StagedOnlyCount)."
    }

    $bulkAdoption = Import-StagedVfsFilesToTransferQueue -StagedFiles $staged165 -Accounts $accounts
    if ([int]$bulkAdoption.AdoptedCount -ne 165) {
        throw "Expected 165 adopted files, got $($bulkAdoption.AdoptedCount) (skipped $($bulkAdoption.SkippedCount), failed $($bulkAdoption.FailedCount))."
    }
    if (@(Get-FlatQueue).Count -ne 197) {
        throw "Expected 197 durable jobs after adoption, got $(@(Get-FlatQueue).Count)."
    }

    $afterAdoption = Get-CloudTransferPendingSummary -QueueItems @(Get-FlatQueue) -StagedFiles $staged165
    if ([int]$afterAdoption.PendingCount -ne 197) {
        throw "Adoption changed the honest pending count to $($afterAdoption.PendingCount) instead of 197."
    }
    if ([int]$afterAdoption.StagedOnlyCount -ne 0) {
        throw "Adopted staged files were double-counted (StagedOnlyCount=$($afterAdoption.StagedOnlyCount))."
    }
    $bulkSecond = Import-StagedVfsFilesToTransferQueue -StagedFiles $staged165 -Accounts $accounts
    if ([int]$bulkSecond.AdoptedCount -ne 0 -or [int]$bulkSecond.AlreadyQueuedCount -ne 165) {
        throw 'Bulk adoption was not idempotent on a second pass.'
    }
    Write-Host "  [PASS] 197-transfer accounting stays exact before, after, and across repeated adoption"

    Write-Host "All Staged VFS Queue Adoption Tests Passed Successfully!"
} finally {
    foreach ($dir in @($sandbox)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
