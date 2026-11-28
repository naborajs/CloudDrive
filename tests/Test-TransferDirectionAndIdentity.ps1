# ==============================================================================
# NS Cloud Drive - Transfer Direction and Identity Regression Suite
# Verifies that transfer direction, operation type, and job identity are always
# resolved from explicit account providers, never inferred from drive letters,
# file names, extensions, UI labels, or working directories. Unresolvable state
# fails closed to "Needs reconciliation" rather than guessing.
#
# Hermetic: every queue file, cache root and staged file lives under the OS temp directory.
# No real-account transfers are performed.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== NS Cloud Drive Transfer Direction and Identity Regression Suite ===" -ForegroundColor Cyan

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\BackgroundOperationManager.ps1')
. (Join-Path $srcDir 'services\AdaptiveBandwidthManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

Write-Host "  [PASS] Transfer modules loaded under Set-StrictMode -Version Latest"

function New-LocalAccount([string]$Id, [string]$Label) {
    @{
        Id          = $Id
        ProviderId  = 'local'
        Label       = $Label
        DriveLetter = 'Z'
    }
}

function New-GDriveAccount([string]$Id, [string]$Label) {
    @{
        Id          = $Id
        ProviderId  = 'gdrive'
        Label       = $Label
        DriveLetter = 'G'
    }
}

function New-TeraBoxAccount([string]$Id, [string]$Label) {
    @{
        Id          = $Id
        ProviderId  = 'terabox'
        Label       = $Label
        DriveLetter = 'T'
    }
}

function Get-FlatQueue {
    $result = Get-CloudTransferQueue
    if ($result -is [array] -and $result.Count -gt 0 -and $result[0] -is [array]) {
        return @($result[0])
    }
    if ($null -ne $result) { return @($result) }
    return @()
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("NSCloudDrive_DirectionIdentity_" + [Guid]::NewGuid().ToString('N'))
$queueFile = Join-Path $sandbox 'state\transfer-jobs.json'
$local   = New-LocalAccount -Id 'local_disk_001' -Label 'Local Disk Cache'
$gdrive  = New-GDriveAccount -Id 'gdrive_acct_alpha' -Label 'Google Drive Alpha'
$terabox = New-TeraBoxAccount -Id 'terabox_acct_beta' -Label 'TeraBox Beta'

try {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $queueFile -Parent))
    Set-TransferQueueFilePath -Path $queueFile
    $script:TransferQueueStateUnavailable = $false
    $script:CloudTransferQueue.Clear()

    # --------------------------------------------------------------------------
    # Case 1: Upload direction - local source, cloud destination
    # --------------------------------------------------------------------------
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $local `
        -SourcePath 'C:\Users\Naboraj_sarkar\Videos\video.mp4' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Videos'
    if (-not $op.IsValid) { throw "Case 1 failed: upload should be valid, reason=$($op.Reason)" }
    if ($op.OperationType -ne 'Upload' -or $op.Direction -ne 'Upload') {
        throw "Case 1 failed: expected Upload/Upload, got $($op.OperationType)/$($op.Direction)"
    }
    if ($op.SourceProvider -ne 'local' -or $op.DestinationProvider -ne 'gdrive') {
        throw "Case 1 failed: providers not persisted: $($op.SourceProvider)/$($op.DestinationProvider)"
    }
    Write-Host "  [PASS] Case 1: local -> cloud resolves Upload/Upload"

    # --------------------------------------------------------------------------
    # Case 2: Download direction - cloud source, local destination
    # --------------------------------------------------------------------------
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $gdrive `
        -SourcePath 'Videos/video.mp4' `
        -DestinationAccount $local `
        -DestinationPath 'C:\Users\Naboraj_sarkar\Downloads'
    if (-not $op.IsValid) { throw "Case 2 failed: download should be valid, reason=$($op.Reason)" }
    if ($op.OperationType -ne 'Download' -or $op.Direction -ne 'Download') {
        throw "Case 2 failed: expected Download/Download, got $($op.OperationType)/$($op.Direction)"
    }
    Write-Host "  [PASS] Case 2: cloud -> local resolves Download/Download"

    # --------------------------------------------------------------------------
    # Case 3: Cloud-to-cloud direction - gdrive source, terabox destination
    # --------------------------------------------------------------------------
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $gdrive `
        -SourcePath 'Videos/video.mp4' `
        -DestinationAccount $terabox `
        -DestinationPath 'Videos'
    if (-not $op.IsValid) { throw "Case 3 failed: cloud copy should be valid, reason=$($op.Reason)" }
    if ($op.OperationType -ne 'CloudCopy' -or $op.Direction -ne 'CloudToCloud') {
        throw "Case 3 failed: expected CloudCopy/CloudToCloud, got $($op.OperationType)/$($op.Direction)"
    }
    Write-Host "  [PASS] Case 3: gdrive -> terabox resolves CloudCopy/CloudToCloud"

    # --------------------------------------------------------------------------
    # Case 4: Both local - no cloud operation to perform
    # --------------------------------------------------------------------------
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $local `
        -SourcePath 'C:\Source\file.txt' `
        -DestinationAccount $local `
        -DestinationPath 'C:\Dest'
    if ($op.IsValid) { throw 'Case 4 failed: local-to-local should not be valid.' }
    if ($op.Reason -notmatch '(?i)both local') { throw "Case 4 failed: unexpected reason: $($op.Reason)" }
    Write-Host "  [PASS] Case 4: local-to-local is rejected as no cloud operation"

    # --------------------------------------------------------------------------
    # Case 5: Unknown (empty) source provider - fail closed
    # --------------------------------------------------------------------------
    $unknownSrc = @{ Id = 'unk'; ProviderId = '' }
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $unknownSrc `
        -SourcePath 'C:\Source\file.txt' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Videos'
    if ($op.IsValid) { throw 'Case 5 failed: empty source provider should not be valid.' }
    if ($op.Reason -notmatch '(?i)source account provider is unknown') { throw "Case 5 failed: unexpected reason: $($op.Reason)" }
    Write-Host "  [PASS] Case 5: empty source provider fails closed"

    # --------------------------------------------------------------------------
    # Case 6: Unknown (empty) destination provider - fail closed
    # --------------------------------------------------------------------------
    $unknownDst = @{ Id = 'unk'; ProviderId = '' }
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $gdrive `
        -SourcePath 'Videos/file.txt' `
        -DestinationAccount $unknownDst `
        -DestinationPath 'Videos'
    if ($op.IsValid) { throw 'Case 6 failed: empty destination provider should not be valid.' }
    if ($op.Reason -notmatch '(?i)destination account provider is unknown') { throw "Case 6 failed: unexpected reason: $($op.Reason)" }
    Write-Host "  [PASS] Case 6: empty destination provider fails closed"

    # --------------------------------------------------------------------------
    # Case 7: Missing source path - fail closed
    # --------------------------------------------------------------------------
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $local `
        -SourcePath '' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Videos'
    if ($op.IsValid) { throw 'Case 7 failed: missing source path should not be valid.' }
    if ($op.Reason -notmatch '(?i)source path is missing') { throw "Case 7 failed: unexpected reason: $($op.Reason)" }
    Write-Host "  [PASS] Case 7: missing source path fails closed"

    # --------------------------------------------------------------------------
    # Case 8: Missing download destination path - fail closed
    # --------------------------------------------------------------------------
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $gdrive `
        -SourcePath 'Videos/file.txt' `
        -DestinationAccount $local `
        -DestinationPath ''
    if ($op.IsValid) { throw 'Case 8 failed: missing download destination should not be valid.' }
    if ($op.Reason -notmatch '(?i)download destination path is missing') { throw "Case 8 failed: unexpected reason: $($op.Reason)" }
    Write-Host "  [PASS] Case 8: missing download destination path fails closed"

    # --------------------------------------------------------------------------
    # Case 9: Declared operation type mismatch with endpoints - fail closed
    # --------------------------------------------------------------------------
    $op = Resolve-CloudTransferOperation `
        -SourceAccount $local `
        -SourcePath 'C:\Source\file.txt' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Videos' `
        -DeclaredOperationType 'Download'
    if ($op.IsValid) { throw 'Case 9 failed: declared Download vs resolved Upload should not be valid.' }
    if ($op.Reason -notmatch '(?i)does not match its endpoints') { throw "Case 9 failed: unexpected reason: $($op.Reason)" }
    Write-Host "  [PASS] Case 9: declared-vs-resolved operation mismatch fails closed"

    # --------------------------------------------------------------------------
    # Case 10: Dedup - same TransferKey suppresses duplicate jobs
    # --------------------------------------------------------------------------
    $job1 = Add-CloudTransferQueueItem `
        -SourceAccount $local `
        -SourcePath 'C:\Uploads\photo.jpg' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Photos' `
        -ConflictAction 'Overwrite' `
        -FileSizeBytes 1024 `
        -OperationType 'Upload' `
        -Origin 'UserRequest'
    if ($null -eq $job1) { throw 'Case 10 failed: first upload job should be created.' }
    $job2 = Add-CloudTransferQueueItem `
        -SourceAccount $local `
        -SourcePath 'C:\Uploads\photo.jpg' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Photos' `
        -ConflictAction 'Overwrite' `
        -FileSizeBytes 1024 `
        -OperationType 'Upload' `
        -Origin 'UserRequest'
    if (-not $null -eq $job2) { throw 'Case 10 failed: duplicate logical transfer was not suppressed.' }
    if (@(Get-FlatQueue).Count -ne 1) { throw 'Case 10 failed: queue should still contain exactly 1 job.' }
    Write-Host "  [PASS] Case 10: duplicate logical transfer suppressed by TransferKey"

    # --------------------------------------------------------------------------
    # Case 11: Terminal jobs not revived implicitly (need -AllowNewAttempt)
    # --------------------------------------------------------------------------
    $job1['Status'] = 'Completed and remotely confirmed'
    $null = Save-DurableTransferQueue | Out-Null
    $script:CloudTransferQueue.Clear()
    $loaded = Load-DurableTransferQueue
    if ($loaded -ne 1) { throw "Case 11 failed: expected 1 job after reload, got $loaded." }
    $job3 = Add-CloudTransferQueueItem `
        -SourceAccount $local `
        -SourcePath 'C:\Uploads\photo.jpg' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Photos' `
        -ConflictAction 'Overwrite' `
        -FileSizeBytes 1024 `
        -OperationType 'Upload' `
        -Origin 'UserRequest'
    if (-not $null -eq $job3) { throw 'Case 11 failed: terminal job was revived implicitly.' }
    $job4 = Add-CloudTransferQueueItem `
        -SourceAccount $local `
        -SourcePath 'C:\Uploads\photo.jpg' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Photos' `
        -ConflictAction 'Overwrite' `
        -FileSizeBytes 1024 `
        -OperationType 'Upload' `
        -Origin 'UserRequest' `
        -AllowNewAttempt
    if ($null -eq $job4) { throw 'Case 11 failed: explicit -AllowNewAttempt should create a new attempt.' }
    Write-Host "  [PASS] Case 11: terminal jobs stay terminal without -AllowNewAttempt"

    # --------------------------------------------------------------------------
    # Case 12: Legacy record migrates operation/direction from endpoints on load
    # --------------------------------------------------------------------------
    $legacyJson = @{
        Version = '1.0'
        Jobs = @(
            @{
                JobId = 'legacy_upload_001'
                QueueId = 'legacy_upload_001'
                BatchId = ''
                BatchName = 'Legacy'
                TransferKey = ''
                OperationType = ''
                Direction = ''
                SourceProvider = ''
                DestinationProvider = ''
                SourceAccountId = 'local_disk_001'
                DestinationAccountId = 'gdrive_acct_alpha'
                Origin = 'Legacy'
                PreviousJobId = ''
                ReconciliationStatus = 'None'
                StatusBeforeReconciliation = ''
                StagedSourcePath = ''
                StagedSourceLastWriteUtc = ''
                RecoveredFromVfsCache = $false
                RecoveryBatchId = ''
                AccountId = 'gdrive_acct_alpha'
                ProviderId = 'gdrive'
                SourceAccount = @{ Id = 'local_disk_001'; ProviderId = 'local' }
                DestinationAccount = @{ Id = 'gdrive_acct_alpha'; ProviderId = 'gdrive' }
                SourcePath = 'C:\Legacy\file.txt'
                DestinationPath = 'Legacy'
                DestinationFilePath = 'Legacy/file.txt'
                DestinationDirectory = 'Legacy'
                RelativePath = 'file.txt'
                ConflictAction = 'Skip'
                IsMove = $false
                SourceLastWriteUtc = ''
                Status = 'Queued'
                RetryCount = 0
                VerificationRetryCount = 0
                MaxRetries = 3
                NextRetryUtc = ''
                EnqueuedUtc = [DateTime]::UtcNow.ToString('o')
                StartedUtc = $null
                CompletedUtc = $null
                LastProgressUtc = $null
                WorkerPid = 0
                WorkerLeaseUtc = $null
                LastError = ''
                FileName = 'file.txt'
                FileSizeBytes = 100
                BytesTransferred = 0
                Percentage = 0
                SmoothedSpeed = 0
                EtaSeconds = $null
                BandwidthLimit = ''
                RemoteHash = ''
                VerificationType = ''
            }
        )
    }
    [System.IO.File]::WriteAllText($queueFile, ($legacyJson | ConvertTo-Json -Depth 10))
    $script:CloudTransferQueue.Clear()
    $loaded = Load-DurableTransferQueue
    if ($loaded -ne 1) { throw "Case 12 failed: expected 1 legacy job loaded, got $loaded." }
    $migrated = @(Get-FlatQueue)[0]
    if ([string]$migrated['OperationType'] -ne 'Upload') {
        throw "Case 12 failed: legacy upload did not migrate OperationType, got '$([string]$migrated['OperationType'])'."
    }
    if ([string]$migrated['Direction'] -ne 'Upload') {
        throw "Case 12 failed: legacy upload did not migrate Direction, got '$([string]$migrated['Direction'])'."
    }
    if ([string]$migrated['SourceProvider'] -ne 'local') {
        throw "Case 12 failed: SourceProvider was not migrated."
    }
    if ([string]$migrated['DestinationProvider'] -ne 'gdrive') {
        throw "Case 12 failed: DestinationProvider was not migrated."
    }
    Write-Host "  [PASS] Case 12: legacy record migrates operation/direction from persisted endpoints"

    # --------------------------------------------------------------------------
    # Case 13: Legacy record with missing endpoint fails closed to Needs reconciliation
    # --------------------------------------------------------------------------
    $legacyJson2 = @{
        Version = '1.0'
        Jobs = @(
            @{
                JobId = 'legacy_broken_001'
                QueueId = 'legacy_broken_001'
                BatchId = ''
                BatchName = 'Legacy'
                TransferKey = ''
                OperationType = ''
                Direction = ''
                SourceProvider = ''
                DestinationProvider = ''
                SourceAccountId = ''
                DestinationAccountId = 'gdrive_acct_alpha'
                Origin = 'Legacy'
                PreviousJobId = ''
                ReconciliationStatus = 'None'
                StatusBeforeReconciliation = ''
                StagedSourcePath = ''
                StagedSourceLastWriteUtc = ''
                RecoveredFromVfsCache = $false
                RecoveryBatchId = ''
                AccountId = 'gdrive_acct_alpha'
                ProviderId = 'gdrive'
                SourceAccount = $null
                DestinationAccount = @{ Id = 'gdrive_acct_alpha'; ProviderId = 'gdrive' }
                SourcePath = 'C:\Legacy\file.txt'
                DestinationPath = 'Legacy'
                DestinationFilePath = 'Legacy/file.txt'
                DestinationDirectory = 'Legacy'
                RelativePath = 'file.txt'
                ConflictAction = 'Skip'
                IsMove = $false
                SourceLastWriteUtc = ''
                Status = 'Queued'
                RetryCount = 0
                VerificationRetryCount = 0
                MaxRetries = 3
                NextRetryUtc = ''
                EnqueuedUtc = [DateTime]::UtcNow.ToString('o')
                StartedUtc = $null
                CompletedUtc = $null
                LastProgressUtc = $null
                WorkerPid = 0
                WorkerLeaseUtc = $null
                LastError = ''
                FileName = 'file.txt'
                FileSizeBytes = 100
                BytesTransferred = 0
                Percentage = 0
                SmoothedSpeed = 0
                EtaSeconds = $null
                BandwidthLimit = ''
                RemoteHash = ''
                VerificationType = ''
            }
        )
    }
    [System.IO.File]::WriteAllText($queueFile, ($legacyJson2 | ConvertTo-Json -Depth 10))
    $script:CloudTransferQueue.Clear()
    $loaded = Load-DurableTransferQueue
    if ($loaded -ne 1) { throw "Case 13 failed: expected 1 legacy job loaded, got $loaded." }
    $broken = @(Get-FlatQueue)[0]
    if ([string]$broken['Status'] -ne 'Needs reconciliation: operation unresolved') {
        throw "Case 13 failed: legacy record with missing source should fail closed, got '$([string]$broken['Status'])'."
    }
    if ([string]$broken['ReconciliationStatus'] -ne 'Required') {
        throw "Case 13 failed: ReconciliationStatus should be Required, got '$([string]$broken['ReconciliationStatus'])'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$broken['LastError'])) {
        throw 'Case 13 failed: unresolved job should record a reason.'
    }
    Write-Host "  [PASS] Case 13: legacy record with missing endpoint fails closed to Needs reconciliation"

    # --------------------------------------------------------------------------
    # Case 14: Get-CloudTransferJobOperation resolves direction without path inference
    # --------------------------------------------------------------------------
    $jobWithOp = @{
        JobId = 'op_direct_001'
        QueueId = 'op_direct_001'
        OperationType = 'Download'
        Direction = 'Download'
        SourceProvider = 'gdrive'
        DestinationProvider = 'local'
        SourceAccountId = 'gdrive_acct_alpha'
        DestinationAccountId = 'local_disk_001'
        SourcePath = 'Videos/video.mp4'
        DestinationFilePath = 'C:\Downloads\video.mp4'
        DestinationDirectory = 'C:\Downloads'
        SourceAccount = @{ Id = 'gdrive_acct_alpha'; ProviderId = 'gdrive' }
        DestinationAccount = @{ Id = 'local_disk_001'; ProviderId = 'local' }
    }
    $resolved = Get-CloudTransferJobOperation -Job $jobWithOp
    if (-not $resolved.IsValid) { throw "Case 14 failed: job operation should be valid, reason=$($resolved.Reason)" }
    if ($resolved.OperationType -ne 'Download' -or $resolved.Direction -ne 'Download') {
        throw "Case 14 failed: expected Download/Download from persisted fields, got $($resolved.OperationType)/$($resolved.Direction)"
    }
    # Declared operation must match endpoints; a mismatch invalidates even if fields exist.
    $jobMismatch = $jobWithOp.Clone()
    $jobMismatch.OperationType = 'Upload'
    $resolvedMismatch = Get-CloudTransferJobOperation -Job $jobMismatch
    if ($resolvedMismatch.IsValid) { throw 'Case 14 failed: declared Upload vs persisted Download should not be valid.' }
    Write-Host "  [PASS] Case 14: job operation resolved from persisted fields, mismatch invalidates"

    # --------------------------------------------------------------------------
    # Case 15: Same provider and account still allows a distinct destination path
    # --------------------------------------------------------------------------
    $script:CloudTransferQueue.Clear()
    $sameProviderJob = Add-CloudTransferQueueItem `
        -SourceAccount $gdrive `
        -SourcePath 'Source/clip.mp4' `
        -DestinationAccount $gdrive `
        -DestinationPath 'Archive' `
        -ConflictAction 'Skip' `
        -FileSizeBytes 128 `
        -OperationType 'CloudCopy'
    if ($null -eq $sameProviderJob -or [string]$sameProviderJob['OperationType'] -ne 'CloudCopy') {
        throw 'Case 15 failed: same-provider copy to a distinct path should be queued as CloudCopy.'
    }
    Write-Host "  [PASS] Case 15: same-provider/different-path cloud copy remains allowed"

    # --------------------------------------------------------------------------
    # Case 16: Exact same provider/account/path is a no-op and is never queued
    # --------------------------------------------------------------------------
    $script:CloudTransferQueue.Clear()
    $sameLocationRejected = $false
    try {
        Add-CloudTransferQueueItem `
            -SourceAccount $gdrive `
            -SourcePath 'Source/clip.mp4' `
            -DestinationAccount $gdrive `
            -DestinationPath 'Source' `
            -ConflictAction 'Skip' `
            -FileSizeBytes 128 `
            -OperationType 'CloudCopy' | Out-Null
    } catch {
        $sameLocationRejected = $_.Exception.Message -match '(?i)same cloud object'
    }
    if (-not $sameLocationRejected -or @($script:CloudTransferQueue).Count -ne 0) {
        throw 'Case 16 failed: exact same-location cloud copy should be rejected without creating a queue item.'
    }
    Write-Host "  [PASS] Case 16: exact same-location copy is a no-op and never queued"

    # --------------------------------------------------------------------------
    # Case 17: UI scheduling must not perform provider inventory synchronously
    # --------------------------------------------------------------------------
    $script:CloudTransferQueue.Clear()
    $asyncSourcePath = Join-Path $sandbox 'async-preflight-source.txt'
    [System.IO.File]::WriteAllText($asyncSourcePath, 'async source')
    $script:AsyncInventoryCalled = $false
    $script:AsyncTransferStarted = $false
    function Get-RemoteFileInventoryMap {
        [CmdletBinding()]
        param([object]$DestinationAccount, [string[]]$DestinationFolderPaths = @(), [switch]$BypassLedger)
        $script:AsyncInventoryCalled = $true
        throw 'UI dispatcher attempted synchronous provider inventory.'
    }
    function Start-CloudTransfer {
        [CmdletBinding()]
        param([object]$SourceAccount, [string]$SourcePath, [object]$DestinationAccount, [string]$DestinationPath = '', [string]$ConflictAction = 'Skip', [switch]$IsMove, [string]$OperationType = '', [int64]$FileSizeBytes = 0L, [string]$BandwidthLimit = '')
        $script:AsyncTransferStarted = $true
        throw 'Transfer launcher should not run before inventory completes.'
    }
    Add-CloudTransferQueueItem `
        -SourceAccount $local `
        -SourcePath $asyncSourcePath `
        -DestinationAccount $gdrive `
        -DestinationPath 'AsyncChecks' `
        -ConflictAction 'Skip' `
        -FileSizeBytes 12 `
        -OperationType 'Upload' | Out-Null
    $null = Process-CloudTransferQueue -RequireCachedRemoteChecks
    $asyncJob = @(Get-FlatQueue)[0]
    if ($script:AsyncInventoryCalled -or $script:AsyncTransferStarted -or [string]$asyncJob['Status'] -ne 'Queued') {
        throw 'UI-safe queue processing performed provider inventory or transfer launch without cached remote results.'
    }
    Write-Host '  [PASS] UI-safe queue processing defers provider inventory and leaves the job durable'

    # --------------------------------------------------------------------------
    # Case 18: Explicit UI selections are queued exactly and defer cloud scans
    # --------------------------------------------------------------------------
    $script:CloudTransferQueue.Clear()
    $selectedDir = Join-Path $sandbox 'selected-files'
    [void][System.IO.Directory]::CreateDirectory($selectedDir)
    $selectedPath = Join-Path $selectedDir 'chosen.txt'
    $notSelectedPath = Join-Path $selectedDir 'not-chosen.txt'
    [System.IO.File]::WriteAllText($selectedPath, 'selected payload')
    [System.IO.File]::WriteAllText($notSelectedPath, 'not selected payload')
    $script:AsyncInventoryCalled = $false
    $selectedDrop = Add-CloudTransferDroppedItems `
        -DestinationAccount $gdrive `
        -DroppedPaths @($selectedPath) `
        -ConflictAction 'Skip' `
        -DeferRemotePreflight
    $selectedJobs = @(Get-FlatQueue)
    if ($script:AsyncInventoryCalled -or [int]$selectedDrop.NewlyQueuedCount -ne 1 -or $selectedJobs.Count -ne 1) {
        throw 'Case 18 failed: UI selection did not create exactly one durable job without a synchronous cloud listing.'
    }
    if ([string]$selectedJobs[0]['SourcePath'] -ne $selectedPath -or -not (Test-Path -LiteralPath $notSelectedPath -PathType Leaf) -or
        [string]$selectedJobs[0]['DeduplicationStatus'] -ne 'PreflightPending') {
        throw 'Case 18 failed: selection escaped its explicit path set or deferred preflight metadata was missing.'
    }
    Write-Host '  [PASS] Case 18: only explicitly selected files enter the durable queue; cloud matching is deferred'

    # The user re-selects a matching file from an older VFS staging cache. Preserve
    # its exact cache link until the queue confirms the destination, then remove only
    # that staged cache revision while leaving the original source untouched.
    $script:CloudTransferQueue.Clear()
    $legacyCacheRoot = Join-Path $sandbox 'legacy-cloud-cache'
    $legacyAccountRoot = Join-Path $legacyCacheRoot $gdrive.Id
    $legacyVfsRoot = Join-Path $legacyAccountRoot 'vfs'
    $legacyMetaRoot = Join-Path $legacyAccountRoot 'vfsMeta'
    $legacyStagedPath = Join-Path (Join-Path $legacyVfsRoot 'gdrive{legacy-hash}') 'chosen.txt'
    $legacyStagedMetaPath = Join-Path (Join-Path $legacyMetaRoot 'gdrive{legacy-hash}') 'chosen.txt'
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($legacyStagedPath))
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($legacyStagedMetaPath))
    [System.IO.File]::WriteAllText($legacyStagedPath, 'selected payload')
    [System.IO.File]::WriteAllText($legacyStagedMetaPath, '{"Dirty": true}')
    $legacyStagedInfo = Get-Item -LiteralPath $legacyStagedPath
    $legacyCandidate = [pscustomobject]@{
        Path = $legacyStagedPath
        RelativePath = 'chosen.txt'
        AccountId = $gdrive.Id
        ProviderId = 'gdrive'
        Length = [int64]$legacyStagedInfo.Length
        LastWriteTimeUtc = $legacyStagedInfo.LastWriteTimeUtc
        IsOutsideActiveCache = $true
        HasStagedPathConflict = $false
        State = 'Needs review: staged file is outside the active rclone cache root'
    }
    $gdriveWithCache = @{
        Id = $gdrive.Id
        ProviderId = 'gdrive'
        Label = $gdrive.Label
        DriveLetter = 'G'
        CacheDirectory = $legacyCacheRoot
    }
    $linkedDrop = Add-CloudTransferDroppedItems `
        -DestinationAccount $gdriveWithCache `
        -DroppedPaths @($selectedPath) `
        -ConflictAction 'Skip' `
        -DeferRemotePreflight
    $linkedJob = @($script:CloudTransferQueue)[0]
    $linkPlans = @(Get-CloudTransferStagedCacheLinkPlans -Jobs @($linkedJob) -Candidates @($legacyCandidate))
    if ($linkPlans.Count -ne 1 -or [string]$linkPlans[0].CandidatePath -ne $legacyStagedPath) {
        throw 'Case 19 failed: background matching did not verify the exact selected cache candidate.'
    }
    $linkWorkerArgs = [object[]]::new(3)
    $linkWorkerArgs[0] = [string]$srcDir
    $linkWorkerArgs[1] = [object[]]@($linkedJob)
    $linkWorkerArgs[2] = [object[]]@($legacyCandidate)
    $linkWorker = Start-NSBackgroundOperation -ArgumentList $linkWorkerArgs -ScriptBlock {
        param([string]$sourceRoot, [object[]]$jobs, [object[]]$candidates)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $sourceRoot 'services\VirtualDriveManager.ps1')
        . (Join-Path $sourceRoot 'services\CloudTransferManager.ps1')
        return [pscustomobject]@{ Plans = @(Get-CloudTransferStagedCacheLinkPlans -Jobs $jobs -Candidates $candidates) }
    }
    if (-not $linkWorker.Handle.AsyncWaitHandle.WaitOne(30000)) {
        Stop-NSBackgroundOperation $linkWorker
        throw 'Case 19 failed: isolated staged-cache link worker timed out.'
    }
    $linkWorkerResult = Complete-NSBackgroundOperation -Operation $linkWorker
    $linkWorkerOutput = @($linkWorkerResult.Output)
    $isolatedLinkPlans = @()
    if ($linkWorkerOutput.Count -gt 0) { $isolatedLinkPlans = @($linkWorkerOutput[-1].Plans) }
    if ($linkWorkerResult.HadErrors -or $isolatedLinkPlans.Count -ne 1 -or
        [string]$isolatedLinkPlans[0].CandidatePath -ne $legacyStagedPath) {
        throw 'Case 19 failed: isolated worker did not load the mount path-safety dependency before planning the exact staged link.'
    }
    Write-Host '  [PASS] Case 19: isolated staging-link runspace loads path normalization and reparse safety'
    if (-not (Set-CloudTransferStagedCacheCleanupLink `
        -Job $linkedJob `
        -Candidates @($legacyCandidate) `
        -DestinationAccountId $gdriveWithCache.Id `
        -DestinationProviderId $gdriveWithCache.ProviderId `
        -DestinationRelativePath ([string]$linkedJob['DestinationFilePath']) `
        -ExpectedSizeBytes ([int64]$linkedJob['FileSizeBytes']) `
        -ExpectedSha256 ([string]$linkPlans[0].ExpectedSha256)) -or
        -not [bool]$linkedJob['RecoveredFromVfsCache'] -or
        [string]$linkedJob['StagedSourcePath'] -ne $legacyStagedPath -or
        [string]$linkedJob['StagedSourceSha256'] -ne [string]$linkPlans[0].ExpectedSha256) {
        throw 'Case 19 failed: the SHA-256 verified staged cleanup link was not attached to the explicit selection.'
    }
    $linkedJob['Status'] = 'Completed and remotely confirmed'
    $originalVfsStats = (Get-Command Get-VirtualDriveVfsStats).ScriptBlock
    $originalDriveStatus = (Get-Command Get-VirtualDriveStatus).ScriptBlock
    try {
        Set-Item -Path Function:\Get-VirtualDriveVfsStats -Value { param([string]$DriveLetter, [string]$AccountId, [string]$ProviderId) return @{ IsActive = $false; State = 'Unmounted'; DiskCachePath = '' } }
        Set-Item -Path Function:\Get-VirtualDriveStatus -Value { param([string]$DriveLetter, [string]$AccountId, [string]$ProviderId) return @{ IsMounted = $false; ProcessRunning = $false } }
        $replacementJob = $linkedJob.Clone()
        $expectedStagedWrite = (Get-Item -LiteralPath $legacyStagedPath).LastWriteTimeUtc
        [System.IO.File]::WriteAllText($legacyStagedPath, ('X' * [int]$legacyStagedInfo.Length))
        [System.IO.File]::SetLastWriteTimeUtc($legacyStagedPath, $expectedStagedWrite)
        $replacementCleanup = Invoke-ConfirmedStagedVfsSourceCleanup -Job $replacementJob
        if (-not $replacementCleanup.Success -or [string]$replacementJob['StagedCleanupStatus'] -ne 'Preserved: staged revision changed' -or
            -not (Test-Path -LiteralPath $legacyStagedPath -PathType Leaf) -or -not (Test-Path -LiteralPath $legacyStagedMetaPath -PathType Leaf)) {
            throw 'Case 19 failed: a same-size replacement with a restored timestamp was not preserved.'
        }
        [System.IO.File]::WriteAllText($legacyStagedPath, 'selected payload')
        [System.IO.File]::SetLastWriteTimeUtc($legacyStagedPath, $expectedStagedWrite)
        $linkedCleanup = Invoke-ConfirmedStagedVfsSourceCleanup -Job $linkedJob
    } finally {
        Set-Item -Path Function:\Get-VirtualDriveVfsStats -Value $originalVfsStats
        Set-Item -Path Function:\Get-VirtualDriveStatus -Value $originalDriveStatus
    }
    if (-not $linkedCleanup.Success -or [string]$linkedCleanup.Status -ne 'Removed' -or
        (Test-Path -LiteralPath $legacyStagedPath) -or (Test-Path -LiteralPath $legacyStagedMetaPath) -or
        -not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
        throw 'Case 19 failed: confirmed cache staging was not removed exactly or the original local selection was touched.'
    }
    Write-Host '  [PASS] Case 19: remote confirmation removes the linked temporary cache source and preserves the original file'

    $metadataRacePath = Join-Path (Split-Path -Parent $legacyStagedPath) 'metadata-race.txt'
    $metadataRaceMetaPath = $metadataRacePath -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
    [System.IO.File]::WriteAllText($metadataRacePath, 'confirmed staged payload')
    [System.IO.File]::WriteAllText($metadataRaceMetaPath, '{"Dirty": false}')
    $metadataRaceInfo = Get-Item -LiteralPath $metadataRacePath
    $metadataRaceJob = @{
        Status = 'Completed and remotely confirmed'
        RecoveredFromVfsCache = $true
        StagedSourcePath = $metadataRacePath
        StagedSourceLastWriteUtc = $metadataRaceInfo.LastWriteTimeUtc.ToUniversalTime().ToString('o')
        StagedSourceSha256 = (Get-FileHash -LiteralPath $metadataRacePath -Algorithm SHA256).Hash
        StagedMetadataSha256 = (Get-FileHash -LiteralPath $metadataRaceMetaPath -Algorithm SHA256).Hash
        StagedCleanupStatus = 'Pending'
        FileSizeBytes = [int64]$metadataRaceInfo.Length
        AccountId = $gdriveWithCache.Id
        ProviderId = 'gdrive'
        DestinationAccount = $gdriveWithCache
    }
    $originalVfsStats = (Get-Command Get-VirtualDriveVfsStats).ScriptBlock
    $originalDriveStatus = (Get-Command Get-VirtualDriveStatus).ScriptBlock
    [System.IO.File]::WriteAllText($metadataRaceMetaPath, '{"Dirty": true, "Revision": "new"}')
    try {
        Set-Item -Path Function:\Get-VirtualDriveVfsStats -Value { param([string]$DriveLetter, [string]$AccountId, [string]$ProviderId) return @{ IsActive = $false; State = 'Unmounted'; DiskCachePath = '' } }
        Set-Item -Path Function:\Get-VirtualDriveStatus -Value { param([string]$DriveLetter, [string]$AccountId, [string]$ProviderId) return @{ IsMounted = $false; ProcessRunning = $false } }
        $metadataRaceResult = Invoke-ConfirmedStagedVfsSourceCleanup -Job $metadataRaceJob
        if ($metadataRaceResult.Success -or
            -not (Test-Path -LiteralPath $metadataRacePath) -or
            -not (Test-Path -LiteralPath $metadataRaceMetaPath)) {
            throw 'Case 20 failed: changed metadata was deleted or its paired staged data was removed.'
        }
        $metadataRetry = Invoke-ConfirmedStagedVfsSourceCleanup -Job $metadataRaceJob
        if ($metadataRetry.Success -or -not (Test-Path -LiteralPath $metadataRacePath) -or
            -not (Test-Path -LiteralPath $metadataRaceMetaPath)) {
            throw 'Case 20 failed: a later cleanup retry deleted a metadata revision that no longer matched its checkpoint.'
        }
    } finally {
        Set-Item -Path Function:\Get-VirtualDriveVfsStats -Value $originalVfsStats
        Set-Item -Path Function:\Get-VirtualDriveStatus -Value $originalDriveStatus
    }
    Write-Host '  [PASS] Case 20: a metadata revision changed after checkpointing is preserved across cleanup retries'

    $metadataCheckpointPath = Join-Path (Split-Path -Parent $legacyStagedPath) 'metadata-checkpoint.txt'
    $metadataCheckpointMetaPath = $metadataCheckpointPath -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
    [System.IO.File]::WriteAllText($metadataCheckpointPath, 'durable metadata checkpoint payload')
    [System.IO.File]::WriteAllText($metadataCheckpointMetaPath, '{"Dirty": false}')
    $metadataCheckpointInfo = Get-Item -LiteralPath $metadataCheckpointPath
    $metadataCheckpointJob = Add-CloudTransferQueueItem `
        -SourceAccount $local `
        -SourcePath $metadataCheckpointPath `
        -DestinationAccount $gdriveWithCache `
        -DestinationPath 'checkpoint' `
        -ConflictAction 'Overwrite' `
        -FileSizeBytes ([int64]$metadataCheckpointInfo.Length) `
        -RelativePath 'metadata-checkpoint.txt' `
        -SourceLastWriteUtc $metadataCheckpointInfo.LastWriteTimeUtc.ToUniversalTime().ToString('o') `
        -OperationType 'Upload' `
        -Origin 'StagedVfsAdoption' `
        -SkipPersist
    if ($null -eq $metadataCheckpointJob) { throw 'Case 21 failed: test cleanup checkpoint could not be queued.' }
    $metadataCheckpointJob['Status'] = 'Completed and remotely confirmed'
    $metadataCheckpointJob['StagedCleanupStatus'] = 'Pending'
    $metadataCheckpointJob['StagedSourcePath'] = $metadataCheckpointPath
    $metadataCheckpointJob['StagedSourceLastWriteUtc'] = $metadataCheckpointInfo.LastWriteTimeUtc.ToUniversalTime().ToString('o')
    $metadataCheckpointJob['StagedSourceSha256'] = (Get-FileHash -LiteralPath $metadataCheckpointPath -Algorithm SHA256).Hash
    $metadataCheckpointJob['RecoveredFromVfsCache'] = $true
    $expectedCheckpointMetadataSha256 = (Get-FileHash -LiteralPath $metadataCheckpointMetaPath -Algorithm SHA256).Hash
    $originalCheckpointRemove = (Get-Command Remove-CacheFileByExclusiveHandle).ScriptBlock
    $global:TestCheckpointQueueFile = $queueFile
    $global:TestCheckpointQueueId = [string]$metadataCheckpointJob['QueueId']
    $global:TestCheckpointMetadataSha256 = $expectedCheckpointMetadataSha256
    $global:TestCheckpointPersistedBeforeUnlink = $false
    try {
        Set-Item -Path Function:\Remove-CacheFileByExclusiveHandle -Value {
            param([string]$Path, [System.IO.FileStream]$Stream, [string]$ExpectedSha256 = '')
            $storedState = [System.IO.File]::ReadAllText($global:TestCheckpointQueueFile) | ConvertFrom-Json
            $storedJob = @($storedState.Jobs | Where-Object { [string]$_.QueueId -eq $global:TestCheckpointQueueId })
            if ($storedJob.Count -eq 1 -and [string]$storedJob[0].StagedMetadataSha256 -eq $global:TestCheckpointMetadataSha256) {
                $global:TestCheckpointPersistedBeforeUnlink = $true
            }
            throw 'Injected interruption after metadata checkpoint and before unlink.'
        }
        $interruptedCleanup = Invoke-ConfirmedStagedVfsSourceCleanup -Job $metadataCheckpointJob
        $checkpointPersistedBeforeUnlink = [bool]$global:TestCheckpointPersistedBeforeUnlink
    } finally {
        Set-Item -Path Function:\Remove-CacheFileByExclusiveHandle -Value $originalCheckpointRemove
        Remove-Variable -Name TestCheckpointQueueFile, TestCheckpointQueueId, TestCheckpointMetadataSha256, TestCheckpointPersistedBeforeUnlink -Scope Global -ErrorAction SilentlyContinue
    }
    if ($interruptedCleanup.Success -or -not $checkpointPersistedBeforeUnlink -or
        -not (Test-Path -LiteralPath $metadataCheckpointPath) -or -not (Test-Path -LiteralPath $metadataCheckpointMetaPath)) {
        throw 'Case 21 failed: metadata was not durably checkpointed before the injected pre-unlink interruption.'
    }
    $null = Load-DurableTransferQueue
    $metadataCheckpointQueueId = [string]$metadataCheckpointJob['QueueId']
    $reloadedCheckpointJobs = @($script:CloudTransferQueue | Where-Object { [string](Get-CloudTransferFieldValue $_ 'QueueId') -eq $metadataCheckpointQueueId } | Select-Object -First 1)
    if ($reloadedCheckpointJobs.Count -ne 1) { throw 'Case 21 failed: the durable checkpoint job could not be reloaded.' }
    $metadataCheckpointJob = $reloadedCheckpointJobs[0]
    Remove-Item -LiteralPath $metadataCheckpointMetaPath -Force
    $missingMetadataRetry = Invoke-ConfirmedStagedVfsSourceCleanup -Job $metadataCheckpointJob
    if ($missingMetadataRetry.Success -or
        [string]$metadataCheckpointJob['StagedCleanupStatus'] -ne 'Pending: staged metadata is missing' -or
        -not (Test-Path -LiteralPath $metadataCheckpointPath -PathType Leaf)) {
        throw 'Case 22 failed: a restarted cleanup retry deleted data after its checkpointed metadata sidecar disappeared.'
    }
    [System.IO.File]::WriteAllText($metadataCheckpointMetaPath, '{"Dirty": false}')
    if ((Get-FileHash -LiteralPath $metadataCheckpointMetaPath -Algorithm SHA256).Hash -ne $expectedCheckpointMetadataSha256) {
        throw 'Case 22 failed: the exact checkpointed metadata revision could not be restored for the subsequent cleanup check.'
    }
    Write-Host '  [PASS] Case 22: a restarted cleanup preserves staged data when checkpointed metadata is missing'
    $metadataCheckpointCleanup = Invoke-ConfirmedStagedVfsSourceCleanup -Job $metadataCheckpointJob
    $persistedCheckpointState = [System.IO.File]::ReadAllText($queueFile) | ConvertFrom-Json
    $persistedCheckpointJob = @($persistedCheckpointState.Jobs | Where-Object { [string]$_.QueueId -eq [string]$metadataCheckpointJob['QueueId'] })
    if (-not $metadataCheckpointCleanup.Success -or $persistedCheckpointJob.Count -ne 1 -or
        [string]$persistedCheckpointJob[0].StagedMetadataSha256 -ne $expectedCheckpointMetadataSha256 -or
        (Test-Path -LiteralPath $metadataCheckpointPath) -or (Test-Path -LiteralPath $metadataCheckpointMetaPath)) {
        throw 'Case 21 failed: the paired metadata fingerprint was not durably checkpointed before exact cleanup.'
    }
    [void]$script:CloudTransferQueue.Remove($metadataCheckpointJob)
    Save-DurableTransferQueue | Out-Null
    Write-Host '  [PASS] Case 21: metadata fingerprint is durably saved before confirmed cache cleanup'

    $legacyMetadataOnlyPath = Join-Path (Split-Path -Parent $metadataCheckpointPath) 'legacy-metadata-only.txt'
    $legacyMetadataOnlyMetaPath = $legacyMetadataOnlyPath -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
    [System.IO.File]::WriteAllText($legacyMetadataOnlyPath, 'legacy payload already uploaded')
    [System.IO.File]::WriteAllText($legacyMetadataOnlyMetaPath, '{"Dirty": false, "Revision": "unlinked"}')
    $legacyMetadataOnlyInfo = Get-Item -LiteralPath $legacyMetadataOnlyPath
    $legacyMetadataOnlyHash = (Get-FileHash -LiteralPath $legacyMetadataOnlyMetaPath -Algorithm SHA256).Hash
    $legacySourceHash = (Get-FileHash -LiteralPath $legacyMetadataOnlyPath -Algorithm SHA256).Hash
    Remove-Item -LiteralPath $legacyMetadataOnlyPath -Force
    $legacyMetadataOnlyJob = $metadataCheckpointJob.Clone()
    $legacyMetadataOnlyJob['StagedSourcePath'] = $legacyMetadataOnlyPath
    $legacyMetadataOnlyJob['StagedSourceLastWriteUtc'] = $legacyMetadataOnlyInfo.LastWriteTimeUtc.ToUniversalTime().ToString('o')
    $legacyMetadataOnlyJob['StagedSourceSha256'] = $legacySourceHash
    $legacyMetadataOnlyJob['StagedMetadataSha256'] = ''
    $legacyMetadataOnlyJob['StagedCleanupStatus'] = 'Pending'
    $originalVfsStats = (Get-Command Get-VirtualDriveVfsStats).ScriptBlock
    $originalDriveStatus = (Get-Command Get-VirtualDriveStatus).ScriptBlock
    try {
        Set-Item -Path Function:\Get-VirtualDriveVfsStats -Value { param([string]$DriveLetter, [string]$AccountId, [string]$ProviderId) return @{ IsActive = $false; State = 'Unmounted'; DiskCachePath = '' } }
        Set-Item -Path Function:\Get-VirtualDriveStatus -Value { param([string]$DriveLetter, [string]$AccountId, [string]$ProviderId) return @{ IsMounted = $false; ProcessRunning = $false } }
        $legacyMetadataOnlyResult = Invoke-ConfirmedStagedVfsSourceCleanup -Job $legacyMetadataOnlyJob
    } finally {
        Set-Item -Path Function:\Get-VirtualDriveVfsStats -Value $originalVfsStats
        Set-Item -Path Function:\Get-VirtualDriveStatus -Value $originalDriveStatus
    }
    if (-not $legacyMetadataOnlyResult.Success -or
        [string]$legacyMetadataOnlyResult.Status -ne 'Preserved: unverified staged metadata' -or
        [string]$legacyMetadataOnlyJob['StagedMetadataSha256'] -ne '' -or
        (Test-Path -LiteralPath $legacyMetadataOnlyPath) -or
        -not (Test-Path -LiteralPath $legacyMetadataOnlyMetaPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $legacyMetadataOnlyMetaPath -Algorithm SHA256).Hash -ne $legacyMetadataOnlyHash) {
        throw 'Case 23 failed: a legacy confirmed job deleted or adopted a sidecar after its staged payload was already absent.'
    }
    Write-Host '  [PASS] Case 23: a missing legacy payload cannot authorize deletion or fingerprinting of an unlinked sidecar'

    $summary = Get-CloudTransferPendingSummary -QueueItems @(Get-FlatQueue)
    Write-Host "  [INFO] Pending summary: $($summary.PendingCount) pending, $($summary.UploadCount) uploads, $($summary.DownloadCount) downloads, $($summary.CloudCopyCount) cloud copies"

    Write-Host "All Transfer Direction and Identity Tests Passed Successfully!" -ForegroundColor Green
} finally {
    foreach ($dir in @($sandbox)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
