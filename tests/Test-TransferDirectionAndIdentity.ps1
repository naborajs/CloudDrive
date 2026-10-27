# ==============================================================================
# NS Cloud Drive - Transfer Direction and Identity Regression Suite
# Verifies that transfer direction, operation type, and job identity are always
# resolved from explicit account providers, never inferred from drive letters,
# file names, extensions, UI labels, or working directories. Unresolvable state
# fails closed to "Needs reconciliation" rather than guessing.
#
# Hermetic: every queue file, cache root and staged file lives in %TEMP%.
# No real-account transfers are performed.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== NS Cloud Drive Transfer Direction and Identity Regression Suite ===" -ForegroundColor Cyan

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
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

$sandbox = Join-Path $env:TEMP ("NSCloudDrive_DirectionIdentity_" + [Guid]::NewGuid().ToString('N'))
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
