# ==============================================================================
# NS Cloud Drive - Transfer Recovery, Folder Batching & Progression Test Suite
# Tests Add-CloudTransferFolderBatch, Invoke-StartupTransferQueueRecovery,
# Process-CloudTransferQueue liveness, and Test-RemoteCloudFileVerification.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== NS Cloud Drive Transfer Recovery & Progression Test Suite ===" -ForegroundColor Cyan

# Dot-source required dependencies
$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\AdaptiveBandwidthManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

# Create isolated scratch sandbox
$sandboxDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ns_transfer_recov_test_" + [Guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($sandboxDir)
$isolatedQueuePath = Join-Path $sandboxDir 'test-durable-queue.json'

# Redirect durable queue to isolated temporary path
Set-TransferQueueFilePath -Path $isolatedQueuePath

try {
    # ==========================================================================
    # 1. TEST ADD-CLOUDTRANSFERFOLDERBATCH
    # ==========================================================================
    Write-Host "`n1. Testing Add-CloudTransferFolderBatch Folder Ingestion..." -ForegroundColor Yellow

    $srcFolder = Join-Path $sandboxDir 'SourceFolder'
    $subA = Join-Path $srcFolder 'nestedA'
    $subB = Join-Path $srcFolder 'nestedB'
    $deepB = Join-Path $subB 'deepSub'
    $emptySub = Join-Path $srcFolder 'nestedC_empty'

    $null = [System.IO.Directory]::CreateDirectory($srcFolder)
    $null = [System.IO.Directory]::CreateDirectory($subA)
    $null = [System.IO.Directory]::CreateDirectory($subB)
    $null = [System.IO.Directory]::CreateDirectory($deepB)
    $null = [System.IO.Directory]::CreateDirectory($emptySub)

    # File 1: Root level file (128 bytes)
    $fRoot = Join-Path $srcFolder 'root_file.txt'
    [System.IO.File]::WriteAllBytes($fRoot, [byte[]]::new(128))

    # File 2: Nested file in subA (2048 bytes)
    $fSubA1 = Join-Path $subA 'doc1.bin'
    [System.IO.File]::WriteAllBytes($fSubA1, [byte[]]::new(2048))

    # File 3: 0-byte empty file in subA
    $fSubA2 = Join-Path $subA 'empty_file.dat'
    [System.IO.File]::WriteAllBytes($fSubA2, [byte[]]::new(0))

    # File 4: Duplicate basename in subB (doc1.bin with different size: 4096 bytes)
    $fSubB1 = Join-Path $subB 'doc1.bin'
    [System.IO.File]::WriteAllBytes($fSubB1, [byte[]]::new(4096))

    # File 5: Deeply nested file in subB\deepSub (512 bytes)
    $fDeep = Join-Path $deepB 'deep_telemetry.log'
    [System.IO.File]::WriteAllBytes($fDeep, [byte[]]::new(512))

    Clear-CloudTransferQueue -All

    $srcAccount = @{
        Id = 'acc_test_src'
        ProviderId = 'local'
        DisplayName = 'Local Source'
    }
    $dstAccount = @{
        Id = 'acc_test_dst'
        ProviderId = 'gdrive'
        DisplayName = 'Google Drive Backup'
    }

    Write-Host "  -> Ingesting folder with nested subdirectories, 0-byte file, and duplicate basenames..."
    $batchResult = Add-CloudTransferFolderBatch `
        -SourceAccount $srcAccount `
        -SourceFolderPath $srcFolder `
        -DestinationAccount $dstAccount `
        -DestinationFolderPath 'CloudBackups/ProjectAlpha'

    # Verify batch summary metrics
    if ($batchResult.TotalFiles -ne 5) {
        throw "Expected TotalFiles to be 5, got: $($batchResult.TotalFiles)"
    }
    $expectedBatchBytes = 128L + 2048L + 0L + 4096L + 512L
    if ($batchResult.TotalBytes -ne $expectedBatchBytes) {
        throw "Expected TotalBytes to be $expectedBatchBytes, got: $($batchResult.TotalBytes)"
    }
    if ($batchResult.Jobs.Length -ne 5) {
        throw "Expected Jobs array length to be 5, got: $($batchResult.Jobs.Length)"
    }
    Write-Host "  [PASS] Add-CloudTransferFolderBatch returned 5 files and $expectedBatchBytes total bytes." -ForegroundColor Green

    # Verify queue state & relative path hierarchy preservation
    $currentQueue = Get-CloudTransferQueue
    if (@($currentQueue).Count -ne 5) {
        throw "Expected 5 items in CloudTransferQueue, found: $(@($currentQueue).Count)"
    }

    # Verify root file
    $rootJob = @($currentQueue | Where-Object { $_['FileName'] -eq 'root_file.txt' })[0]
    if ($rootJob['RelativePath'] -ne 'root_file.txt') {
        throw "Root file relative path mismatch: expected 'root_file.txt', got '$($rootJob['RelativePath'])'"
    }
    if ($rootJob['DestinationDirectory'] -ne 'CloudBackups/ProjectAlpha') {
        throw "Root file destination directory mismatch: expected 'CloudBackups/ProjectAlpha', got '$($rootJob['DestinationDirectory'])'"
    }
    if ($rootJob['DestinationFilePath'] -ne 'CloudBackups/ProjectAlpha/root_file.txt') {
        throw "Root file destination file path mismatch: expected 'CloudBackups/ProjectAlpha/root_file.txt', got '$($rootJob['DestinationFilePath'])'"
    }
    if ($rootJob['FileSizeBytes'] -ne 128L) {
        throw "Root file size mismatch: expected 128, got $($rootJob['FileSizeBytes'])"
    }

    # Verify nestedA/doc1.bin vs nestedB/doc1.bin duplicate basename handling
    $doc1Jobs = @($currentQueue | Where-Object { $_['FileName'] -eq 'doc1.bin' })
    if ($doc1Jobs.Count -ne 2) {
        throw "Expected 2 jobs with FileName 'doc1.bin', found: $($doc1Jobs.Count)"
    }
    if ($doc1Jobs[0]['JobId'] -eq $doc1Jobs[1]['JobId']) {
        throw "Duplicate basenames must have unique JobIds: $($doc1Jobs[0]['JobId']) vs $($doc1Jobs[1]['JobId'])"
    }
    if ($doc1Jobs[0]['RelativePath'] -eq $doc1Jobs[1]['RelativePath']) {
        throw "Duplicate basenames must have distinct RelativePaths!"
    }
    if ($doc1Jobs[0]['DestinationFilePath'] -eq $doc1Jobs[1]['DestinationFilePath']) {
        throw "Duplicate basenames must have distinct DestinationFilePaths!"
    }

    $subAJob = @($doc1Jobs | Where-Object { $_['RelativePath'] -eq 'nestedA/doc1.bin' })[0]
    if ($subAJob['DestinationDirectory'] -ne 'CloudBackups/ProjectAlpha/nestedA') {
        throw "subA doc1.bin destination directory mismatch: expected 'CloudBackups/ProjectAlpha/nestedA', got '$($subAJob['DestinationDirectory'])'"
    }
    if ($subAJob['FileSizeBytes'] -ne 2048L) {
        throw "subA doc1.bin size mismatch: expected 2048, got $($subAJob['FileSizeBytes'])"
    }

    $subBJob = @($doc1Jobs | Where-Object { $_['RelativePath'] -eq 'nestedB/doc1.bin' })[0]
    if ($subBJob['DestinationDirectory'] -ne 'CloudBackups/ProjectAlpha/nestedB') {
        throw "subB doc1.bin destination directory mismatch: expected 'CloudBackups/ProjectAlpha/nestedB', got '$($subBJob['DestinationDirectory'])'"
    }
    if ($subBJob['FileSizeBytes'] -ne 4096L) {
        throw "subB doc1.bin size mismatch: expected 4096, got $($subBJob['FileSizeBytes'])"
    }
    Write-Host "  [PASS] Duplicate basenames across subdirectories maintain distinct relative paths, destination paths, and JobIds." -ForegroundColor Green

    # Verify 0-byte empty file handling
    $emptyJob = @($currentQueue | Where-Object { $_['FileName'] -eq 'empty_file.dat' })[0]
    if ($emptyJob['FileSizeBytes'] -ne 0L) {
        throw "Empty file FileSizeBytes expected 0, got $($emptyJob['FileSizeBytes'])"
    }
    if ($emptyJob['RelativePath'] -ne 'nestedA/empty_file.dat') {
        throw "Empty file relative path expected 'nestedA/empty_file.dat', got '$($emptyJob['RelativePath'])'"
    }
    Write-Host "  [PASS] 0-byte file preserved in batch queue with FileSizeBytes=0L." -ForegroundColor Green

    # Verify deeply nested file
    $deepJob = @($currentQueue | Where-Object { $_['FileName'] -eq 'deep_telemetry.log' })[0]
    if ($deepJob['RelativePath'] -ne 'nestedB/deepSub/deep_telemetry.log') {
        throw "Deep file relative path mismatch: expected 'nestedB/deepSub/deep_telemetry.log', got '$($deepJob['RelativePath'])'"
    }
    if ($deepJob['DestinationDirectory'] -ne 'CloudBackups/ProjectAlpha/nestedB/deepSub') {
        throw "Deep file destination directory mismatch: expected 'CloudBackups/ProjectAlpha/nestedB/deepSub', got '$($deepJob['DestinationDirectory'])'"
    }
    Write-Host "  [PASS] Deeply nested subdirectory path hierarchy preserved." -ForegroundColor Green

    # Verify empty folder handling
    Write-Host "  -> Testing Add-CloudTransferFolderBatch on completely empty folder..."
    $emptyRootFolder = Join-Path $sandboxDir 'CompletelyEmptyFolder'
    $null = [System.IO.Directory]::CreateDirectory($emptyRootFolder)
    $emptyBatchRes = Add-CloudTransferFolderBatch `
        -SourceAccount $srcAccount `
        -SourceFolderPath $emptyRootFolder `
        -DestinationAccount $dstAccount `
        -DestinationFolderPath 'CloudBackups/Empty'

    if ($emptyBatchRes.TotalFiles -ne 0 -or $emptyBatchRes.TotalBytes -ne 0L -or $emptyBatchRes.Jobs.Length -ne 0) {
        throw "Empty folder batch should have 0 files and 0 bytes, got: Files=$($emptyBatchRes.TotalFiles), Bytes=$($emptyBatchRes.TotalBytes)"
    }
    Write-Host "  [PASS] Empty folder safely handled with 0 jobs enqueued." -ForegroundColor Green

    # Verify non-existent folder throws Stop error
    Write-Host "  -> Testing Add-CloudTransferFolderBatch on non-existent folder..."
    $threw = $false
    try {
        Add-CloudTransferFolderBatch `
            -SourceAccount $srcAccount `
            -SourceFolderPath (Join-Path $sandboxDir 'NonExistentDir123') `
            -DestinationAccount $dstAccount
    } catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "Expected Add-CloudTransferFolderBatch to throw when folder does not exist!"
    }
    Write-Host "  [PASS] Non-existent source folder safely rejected." -ForegroundColor Green

    # ==========================================================================
    # 2. TEST INVOKE-STARTUPTRANSFERQUEUERECOVERY
    # ==========================================================================
    Write-Host "`n2. Testing Invoke-StartupTransferQueueRecovery Crash Recovery..." -ForegroundColor Yellow

    # Prepare mock remote destination directory (using local provider to verify reconciliation)
    $mockRemoteDir = Join-Path $sandboxDir 'MockRemoteStorage'
    $null = [System.IO.Directory]::CreateDirectory($mockRemoteDir)

    # Remote file 1 exists with 1024 bytes (Upload was finished on remote before crash)
    $remoteFile1 = Join-Path $mockRemoteDir 'finished_before_crash.bin'
    [System.IO.File]::WriteAllBytes($remoteFile1, [byte[]]::new(1024))

    # Remote file 3 exists with 0 bytes (0-byte file completed remotely)
    $remoteFile3 = Join-Path $mockRemoteDir 'zero_byte_remote.txt'
    [System.IO.File]::WriteAllBytes($remoteFile3, [byte[]]::new(0))

    # Remote file 4 exists with 512 bytes (Pending remote confirmation completed remotely)
    $remoteFile4 = Join-Path $mockRemoteDir 'pending_confirmed_remote.dat'
    [System.IO.File]::WriteAllBytes($remoteFile4, [byte[]]::new(512))

    # Note: Remote file 2 ('missing_interrupted.bin') does NOT exist remotely!
    $remoteFile2 = Join-Path $mockRemoteDir 'missing_interrupted.bin'

    # Note: Remote file 5 ('waiting_missing.bin') does NOT exist remotely!
    $remoteFile5 = Join-Path $mockRemoteDir 'waiting_missing.bin'

    Clear-CloudTransferQueue -All

    $mockLocalDst = @{
        Id = 'acc_mock_dst'
        ProviderId = 'local'
        DisplayName = 'Mock Destination Storage'
    }

    # Job 1: In 'Uploading' state, remote file exists with correct size
    $job1 = [hashtable]::Synchronized(@{
        JobId = 'job_recov_1'
        QueueId = 'queue_recov_1'
        SourceAccount = $srcAccount
        DestinationAccount = $mockLocalDst
        SourcePath = 'C:\fake\finished_before_crash.bin'
        DestinationFilePath = $remoteFile1
        FileName = 'finished_before_crash.bin'
        FileSizeBytes = 1024L
        BytesTransferred = 512L
        Status = 'Uploading'
        RetryCount = 1
        MaxRetries = 3
        NextRetryUtc = [DateTime]::UtcNow.AddSeconds(10)
        WorkerPid = 54321
        WorkerLeaseUtc = [DateTime]::UtcNow.AddMinutes(-2)
        Percentage = 50.0
    })

    # Job 2: In 'Uploading' state, remote file DOES NOT EXIST (crash interrupted upload)
    $job2 = [hashtable]::Synchronized(@{
        JobId = 'job_recov_2'
        QueueId = 'queue_recov_2'
        SourceAccount = $srcAccount
        DestinationAccount = $mockLocalDst
        SourcePath = 'C:\fake\missing_interrupted.bin'
        DestinationFilePath = $remoteFile2
        FileName = 'missing_interrupted.bin'
        FileSizeBytes = 2048L
        BytesTransferred = 1024L
        Status = 'Uploading'
        RetryCount = 2
        MaxRetries = 3
        NextRetryUtc = [DateTime]::UtcNow.AddSeconds(20)
        WorkerPid = 54322
        WorkerLeaseUtc = [DateTime]::UtcNow.AddMinutes(-3)
        Percentage = 50.0
    })

    # Job 3: In 'Uploading' state, 0-byte file, remote file exists with 0 bytes
    $job3 = [hashtable]::Synchronized(@{
        JobId = 'job_recov_3'
        QueueId = 'queue_recov_3'
        SourceAccount = $srcAccount
        DestinationAccount = $mockLocalDst
        SourcePath = 'C:\fake\zero_byte_remote.txt'
        DestinationFilePath = $remoteFile3
        FileName = 'zero_byte_remote.txt'
        FileSizeBytes = 0L
        BytesTransferred = 0L
        Status = 'Uploading'
        RetryCount = 1
        MaxRetries = 3
        NextRetryUtc = [DateTime]::UtcNow.AddSeconds(5)
        WorkerPid = 54323
        WorkerLeaseUtc = [DateTime]::UtcNow.AddMinutes(-1)
        Percentage = 0.0
    })

    # Job 4: In 'Upload pending remote confirmation' state, remote file exists with correct size
    $job4 = [hashtable]::Synchronized(@{
        JobId = 'job_recov_4'
        QueueId = 'queue_recov_4'
        SourceAccount = $srcAccount
        DestinationAccount = $mockLocalDst
        SourcePath = 'C:\fake\pending_confirmed_remote.dat'
        DestinationFilePath = $remoteFile4
        FileName = 'pending_confirmed_remote.dat'
        FileSizeBytes = 512L
        BytesTransferred = 512L
        Status = 'Upload pending remote confirmation'
        RetryCount = 0
        MaxRetries = 3
        NextRetryUtc = [DateTime]::MinValue
        WorkerPid = 0
        WorkerLeaseUtc = $null
        Percentage = 100.0
    })

    # Job 5: In 'Waiting for network/provider' state, remote file does NOT exist
    $job5 = [hashtable]::Synchronized(@{
        JobId = 'job_recov_5'
        QueueId = 'queue_recov_5'
        SourceAccount = $srcAccount
        DestinationAccount = $mockLocalDst
        SourcePath = 'C:\fake\waiting_missing.bin'
        DestinationFilePath = $remoteFile5
        FileName = 'waiting_missing.bin'
        FileSizeBytes = 4096L
        BytesTransferred = 0L
        Status = 'Waiting for network/provider'
        RetryCount = 2
        MaxRetries = 3
        NextRetryUtc = [DateTime]::UtcNow.AddMinutes(10)
        WorkerPid = 0
        WorkerLeaseUtc = $null
        Percentage = 0.0
    })

    # Job 6: Already 'Completed and remotely confirmed' (should NOT be modified)
    $job6 = [hashtable]::Synchronized(@{
        JobId = 'job_recov_6'
        QueueId = 'queue_recov_6'
        SourceAccount = $srcAccount
        DestinationAccount = $mockLocalDst
        SourcePath = 'C:\fake\already_completed.bin'
        DestinationFilePath = 'already_completed.bin'
        FileName = 'already_completed.bin'
        FileSizeBytes = 100L
        BytesTransferred = 100L
        Status = 'Completed and remotely confirmed'
        RetryCount = 0
        MaxRetries = 3
        NextRetryUtc = [DateTime]::MinValue
        WorkerPid = 0
        WorkerLeaseUtc = $null
        Percentage = 100.0
        CompletedUtc = [DateTime]::UtcNow.AddHours(-1)
    })

    foreach ($j in @($job1, $job2, $job3, $job4, $job5, $job6)) {
        [void]$script:CloudTransferQueue.Add($j)
    }

    # Persist the crash state to disk
    Save-DurableTransferQueue | Out-Null

    # Clear in-memory queue to simulate clean process restart after crash
    $script:CloudTransferQueue.Clear()
    if ($script:CloudTransferQueue.Count -ne 0) {
        throw "Failed to clear in-memory queue for startup recovery test."
    }

    Write-Host "  -> Invoking Invoke-StartupTransferQueueRecovery on persisted crash state..."
    $recovResult = Invoke-StartupTransferQueueRecovery

    if ($recovResult.RecoveredCount -ne 5) {
        throw "Expected RecoveredCount=5, got: $($recovResult.RecoveredCount)"
    }
    if ($recovResult.ConfirmedCount -ne 3) {
        throw "Expected ConfirmedCount=3 (Job1, Job3, Job4), got: $($recovResult.ConfirmedCount)"
    }
    if ($recovResult.ResetCount -ne 2) {
        throw "Expected ResetCount=2 (Job2, Job5), got: $($recovResult.ResetCount)"
    }
    Write-Host "  [PASS] Startup recovery counts verified (5 recovered, 3 confirmed, 2 reset)." -ForegroundColor Green

    # Inspect the recovered in-memory queue items
    $qItems = Get-CloudTransferQueue

    # Job 1 verification: existed on destination -> must be Completed and remotely confirmed
    $recovJob1 = @($qItems | Where-Object { $_['QueueId'] -eq 'queue_recov_1' })[0]
    if ($recovJob1['Status'] -ne 'Completed and remotely confirmed') {
        throw "Job 1 status mismatch: expected 'Completed and remotely confirmed', got '$($recovJob1['Status'])'"
    }
    if ($recovJob1['Percentage'] -ne 100.0) {
        throw "Job 1 percentage mismatch: expected 100.0, got $($recovJob1['Percentage'])"
    }
    if ($recovJob1['BytesTransferred'] -ne 1024L) {
        throw "Job 1 BytesTransferred mismatch: expected 1024, got $($recovJob1['BytesTransferred'])"
    }
    if ($recovJob1['WorkerPid'] -ne 0 -or $null -ne $recovJob1['WorkerLeaseUtc']) {
        throw "Job 1 worker state was not cleaned up!"
    }
    if ($null -eq $recovJob1['CompletedUtc']) {
        throw "Job 1 CompletedUtc was not set!"
    }
    Write-Host "  [PASS] Job 1 (remotely existing) safely reconciled to 'Completed and remotely confirmed'." -ForegroundColor Green

    # Job 2 verification: did NOT exist on destination -> must safely reset to Queued with RetryCount=0, NextRetryUtc=MinValue
    $recovJob2 = @($qItems | Where-Object { $_['QueueId'] -eq 'queue_recov_2' })[0]
    if ($recovJob2['Status'] -ne 'Queued') {
        throw "Job 2 status mismatch: expected 'Queued', got '$($recovJob2['Status'])'"
    }
    if ($recovJob2['RetryCount'] -ne 0) {
        throw "Job 2 RetryCount mismatch: expected 0, got $($recovJob2['RetryCount'])"
    }
    if ($recovJob2['NextRetryUtc'] -ne [DateTime]::MinValue) {
        throw "Job 2 NextRetryUtc mismatch: expected [DateTime]::MinValue, got $($recovJob2['NextRetryUtc'])"
    }
    if ($recovJob2['WorkerPid'] -ne 0 -or $null -ne $recovJob2['WorkerLeaseUtc']) {
        throw "Job 2 worker state was not cleaned up!"
    }
    if ($recovJob2['JobId'] -ne '') {
        throw "Job 2 JobId expected to be reset to empty string, got '$($recovJob2['JobId'])'"
    }
    Write-Host "  [PASS] Job 2 (unverified interrupted upload) safely reset to 'Queued' with RetryCount=0 and NextRetryUtc=MinValue." -ForegroundColor Green

    # Job 3 verification: 0-byte file exists remotely -> Completed and remotely confirmed
    $recovJob3 = @($qItems | Where-Object { $_['QueueId'] -eq 'queue_recov_3' })[0]
    if ($recovJob3['Status'] -ne 'Completed and remotely confirmed') {
        throw "Job 3 (0-byte file) status mismatch: expected 'Completed and remotely confirmed', got '$($recovJob3['Status'])'"
    }
    if ($recovJob3['Percentage'] -ne 100.0) {
        throw "Job 3 percentage mismatch: expected 100.0, got $($recovJob3['Percentage'])"
    }
    Write-Host "  [PASS] Job 3 (0-byte remotely confirmed file) verified successfully." -ForegroundColor Green

    # Job 4 verification: Upload pending remote confirmation existed remotely -> Completed
    $recovJob4 = @($qItems | Where-Object { $_['QueueId'] -eq 'queue_recov_4' })[0]
    if ($recovJob4['Status'] -ne 'Completed and remotely confirmed') {
        throw "Job 4 status mismatch: expected 'Completed and remotely confirmed', got '$($recovJob4['Status'])'"
    }
    Write-Host "  [PASS] Job 4 (pending confirmation file) reconciled to 'Completed and remotely confirmed'." -ForegroundColor Green

    # Job 5 verification: Waiting for network/provider did NOT exist remotely -> reset to Queued
    $recovJob5 = @($qItems | Where-Object { $_['QueueId'] -eq 'queue_recov_5' })[0]
    if ($recovJob5['Status'] -ne 'Queued') {
        throw "Job 5 status mismatch: expected 'Queued', got '$($recovJob5['Status'])'"
    }
    if ($recovJob5['RetryCount'] -ne 0) {
        throw "Job 5 RetryCount mismatch: expected 0, got $($recovJob5['RetryCount'])"
    }
    if ($recovJob5['NextRetryUtc'] -ne [DateTime]::MinValue) {
        throw "Job 5 NextRetryUtc mismatch: expected [DateTime]::MinValue, got $($recovJob5['NextRetryUtc'])"
    }
    Write-Host "  [PASS] Job 5 (waiting missing file) reset to 'Queued' with RetryCount=0 and NextRetryUtc=MinValue." -ForegroundColor Green

    # Job 6 verification: untouched completed job
    $recovJob6 = @($qItems | Where-Object { $_['QueueId'] -eq 'queue_recov_6' })[0]
    if ($recovJob6['Status'] -ne 'Completed and remotely confirmed') {
        throw "Job 6 status was altered unexpectedly: $($recovJob6['Status'])"
    }
    Write-Host "  [PASS] Job 6 (pre-existing completed file) untouched." -ForegroundColor Green

    # Verify that the durable queue file on disk now reflects the post-recovery state
    $script:CloudTransferQueue.Clear()
    $reloadedCount = Load-DurableTransferQueue
    if ($reloadedCount -ne 6) {
        throw "Expected 6 items reloaded from durable disk queue, got: $reloadedCount"
    }
    $reloadedQ = Get-CloudTransferQueue
    $reloadedJob2 = @($reloadedQ | Where-Object { $_['QueueId'] -eq 'queue_recov_2' })[0]
    if ($reloadedJob2['Status'] -ne 'Queued' -or $reloadedJob2['RetryCount'] -ne 0) {
        throw "Durable file did not preserve reset state for Job 2!"
    }
    Write-Host "  [PASS] Durable queue file on disk accurately reflects post-recovery state." -ForegroundColor Green

    # ==========================================================================
    # 3. TEST QUEUE LIVENESS & CONTINUOUS ADVANCEMENT WITHOUT WEDGING
    # ==========================================================================
    Write-Host "`n3. Testing Queue Liveness & Continuous Scheduling Advancement..." -ForegroundColor Yellow

    Clear-CloudTransferQueue -All

    # Add 4 queued items designed to test scheduler progression:
    # Items with non-existent source will trigger immediate Start-CloudTransfer failure,
    # entering 'Waiting for network/provider' with future NextRetryUtc.
    # The scheduler must NOT stop or wedge on item 1; it must advance continuously
    # through all eligible items up to MaxConcurrent.
    $livenessAccount = @{
        Id = 'acc_liveness_test'
        ProviderId = 'mock_liveness'
        DisplayName = 'Liveness Test Provider'
    }

    $liveJob1 = Add-CloudTransferQueueItem `
        -SourceAccount $livenessAccount `
        -SourcePath (Join-Path $sandboxDir 'live_file_1.dat') `
        -DestinationAccount $livenessAccount `
        -DestinationPath 'live_dst' `
        -FileSizeBytes 1024L `
        -MaxRetries 3

    $liveJob2 = Add-CloudTransferQueueItem `
        -SourceAccount $livenessAccount `
        -SourcePath (Join-Path $sandboxDir 'live_file_2.dat') `
        -DestinationAccount $livenessAccount `
        -DestinationPath 'live_dst' `
        -FileSizeBytes 2048L `
        -MaxRetries 3

    $liveJob3 = Add-CloudTransferQueueItem `
        -SourceAccount $livenessAccount `
        -SourcePath (Join-Path $sandboxDir 'live_file_3.dat') `
        -DestinationAccount $livenessAccount `
        -DestinationPath 'live_dst' `
        -FileSizeBytes 4096L `
        -MaxRetries 3

    $liveJob4 = Add-CloudTransferQueueItem `
        -SourceAccount $livenessAccount `
        -SourcePath (Join-Path $sandboxDir 'live_file_4.dat') `
        -DestinationAccount $livenessAccount `
        -DestinationPath 'live_dst' `
        -FileSizeBytes 8192L `
        -MaxRetries 3

    $initQ = Get-CloudTransferQueue
    if (@($initQ).Count -ne 4) {
        throw "Expected 4 initial items in liveness queue, got: $(@($initQ).Count)"
    }

    # Process queue with MaxConcurrent = 4
    Write-Host "  -> Running Process-CloudTransferQueue Round 1 (sequential progression through transient errors)..."
    $round1Res = Process-CloudTransferQueue -MaxConcurrent 4

    # In Round 1, the scheduler must continuously advance through all 4 items without wedging:
    # Each item encounters a transient error, enters 'Waiting for network/provider' with RetryCount=1,
    # and sets NextRetryUtc into the future.
    $round1Job1 = @($round1Res | Where-Object { $_['QueueId'] -eq $liveJob1['QueueId'] })[0]
    $round1Job2 = @($round1Res | Where-Object { $_['QueueId'] -eq $liveJob2['QueueId'] })[0]
    $round1Job3 = @($round1Res | Where-Object { $_['QueueId'] -eq $liveJob3['QueueId'] })[0]
    $round1Job4 = @($round1Res | Where-Object { $_['QueueId'] -eq $liveJob4['QueueId'] })[0]

    foreach ($j in @($round1Job1, $round1Job2, $round1Job3, $round1Job4)) {
        if ($j['Status'] -ne 'Waiting for network/provider' -or $j['RetryCount'] -ne 1) {
            throw "Item $($j['QueueId']) expected 'Waiting for network/provider' with RetryCount=1, got '$($j['Status'])' (Retry: $($j['RetryCount']))"
        }
        if ($j['NextRetryUtc'] -le [DateTime]::UtcNow) {
            throw "Item $($j['QueueId']) expected future NextRetryUtc backoff timestamp!"
        }
    }
    Write-Host "  [PASS] Queue scheduler traversed all 4 items sequentially without wedging on transient failures." -ForegroundColor Green

    # Run Round 2: Immediate re-invocation while NextRetryUtc is in the future.
    # No items are eligible; scheduler must not busy-retry before backoff expiration.
    Write-Host "  -> Running Process-CloudTransferQueue Round 2 (verifying backoff respect)..."
    $round2Res = Process-CloudTransferQueue -MaxConcurrent 4
    foreach ($j in @($round2Res)) {
        if ($j['Status'] -ne 'Waiting for network/provider' -or $j['RetryCount'] -ne 1) {
            throw "Item $($j['QueueId']) should not be re-attempted before backoff expiration!"
        }
    }
    Write-Host "  [PASS] Backoff cooldown respected: no busy retries during cooldown period." -ForegroundColor Green

    # Run Round 3: Expire backoff cooldown and set MaxRetries=1 to test permanent failure transition
    Write-Host "  -> Running Process-CloudTransferQueue Round 3 (retry timer expiration and MaxRetries exhaustion)..."
    foreach ($item in @($script:CloudTransferQueue)) {
        $item['MaxRetries'] = 1
        $item['NextRetryUtc'] = [DateTime]::UtcNow.AddSeconds(-5)
    }

    $round3Res = Process-CloudTransferQueue -MaxConcurrent 4
    foreach ($j in @($round3Res)) {
        if ($j['Status'] -ne 'Failed') {
            throw "Item $($j['QueueId']) expected 'Failed' status after exceeding MaxRetries, got '$($j['Status'])'"
        }
    }
    Write-Host "  [PASS] All items transitioned cleanly to 'Failed' after reaching MaxRetries without scheduler stall." -ForegroundColor Green

    # ==========================================================================
    # 4. TEST PROVIDER CONCURRENCY BOUNDING UNDER MIXED QUEUE
    # ==========================================================================
    Write-Host "`n4. Testing Provider Concurrency Bounding (TeraBox max 2, Google Drive max 4)..." -ForegroundColor Yellow

    Clear-CloudTransferQueue -All

    $tbAccount = @{ Id = 'acc_tb_bound'; ProviderId = 'terabox'; DisplayName = 'TeraBox Concurrency' }
    $gdAccount = @{ Id = 'acc_gd_bound'; ProviderId = 'gdrive'; DisplayName = 'Google Drive Concurrency' }

    # Simulate 2 active TeraBox jobs already 'Uploading' (saturated TeraBox budget)
    $actTb1 = Add-CloudTransferQueueItem -SourceAccount $srcAccount -SourcePath 'tb1.bin' -DestinationAccount $tbAccount
    $actTb2 = Add-CloudTransferQueueItem -SourceAccount $srcAccount -SourcePath 'tb2.bin' -DestinationAccount $tbAccount

    $script:CloudTransferQueue[0]['Status'] = 'Uploading'
    $script:CloudTransferQueue[0]['WorkerPid'] = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $script:CloudTransferQueue[0]['WorkerLeaseUtc'] = [DateTime]::UtcNow
    $script:CloudTransferQueue[1]['Status'] = 'Uploading'
    $script:CloudTransferQueue[1]['WorkerPid'] = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $script:CloudTransferQueue[1]['WorkerLeaseUtc'] = [DateTime]::UtcNow

    # Enqueue a 3rd TeraBox item (which MUST be skipped due to max 2 limit)
    # and a Google Drive item (which MUST be selected despite the 3rd TeraBox item preceding it)
    $tbItem3 = Add-CloudTransferQueueItem -SourceAccount $srcAccount -SourcePath 'tb3.bin' -DestinationAccount $tbAccount
    $gdItem1 = Add-CloudTransferQueueItem -SourceAccount $srcAccount -SourcePath 'gd1.bin' -DestinationAccount $gdAccount

    # Process queue with MaxConcurrent = 4
    # The scheduler should skip tb3 and schedule gd1!
    $boundRes = Process-CloudTransferQueue -MaxConcurrent 4

    $tb3After = @($boundRes | Where-Object { $_['QueueId'] -eq $tbItem3['QueueId'] })[0]
    $gd1After = @($boundRes | Where-Object { $_['QueueId'] -eq $gdItem1['QueueId'] })[0]

    if ($tb3After['Status'] -ne 'Queued') {
        throw "TeraBox Item 3 should have been bounded and remained 'Queued', got: $($tb3After['Status'])"
    }
    if ($gd1After['Status'] -eq 'Queued') {
        throw "Google Drive Item 1 should have been scheduled past the saturated TeraBox queue, but remained 'Queued'!"
    }
    Write-Host "  [PASS] TeraBox concurrency bound respected: saturated TeraBox items did not block Google Drive progression." -ForegroundColor Green

    # ==========================================================================
    # 5. TEST TEST-REMOTECLOUDFILEVERIFICATION EDGE CASES
    # ==========================================================================
    Write-Host "`n5. Testing Test-RemoteCloudFileVerification Edge Cases..." -ForegroundColor Yellow

    $vfTestDir = Join-Path $sandboxDir 'VerificationTest'
    $null = [System.IO.Directory]::CreateDirectory($vfTestDir)

    # 5.1 Zero-byte file verification
    $vfZeroFile = Join-Path $vfTestDir 'zero_test.bin'
    [System.IO.File]::WriteAllBytes($vfZeroFile, [byte[]]::new(0))
    $vfZeroRes = Test-RemoteCloudFileVerification -Account @{ ProviderId = 'local' } -RemotePath $vfZeroFile -ExpectedSizeBytes 0L
    if (-not $vfZeroRes.Verified -or $vfZeroRes.Status -ne 'Remotely confirmed') {
        throw "Zero-byte verification failed: $($vfZeroRes.Reason)"
    }
    Write-Host "  [PASS] 0-byte file confirmed remotely with matching ExpectedSizeBytes=0L." -ForegroundColor Green

    # 5.2 Size mismatch detection
    $vfMismatchFile = Join-Path $vfTestDir 'size_mismatch.bin'
    [System.IO.File]::WriteAllBytes($vfMismatchFile, [byte[]]::new(100))
    $vfMismatchRes = Test-RemoteCloudFileVerification -Account @{ ProviderId = 'local' } -RemotePath $vfMismatchFile -ExpectedSizeBytes 200L
    if ($vfMismatchRes.Verified -or $vfMismatchRes.Status -ne 'Failed') {
        throw "Expected size mismatch verification to fail, got: Verified=$($vfMismatchRes.Verified), Status=$($vfMismatchRes.Status)"
    }
    if ($vfMismatchRes.Reason -notmatch 'size mismatch') {
        throw "Expected reason to state size mismatch, got: $($vfMismatchRes.Reason)"
    }
    Write-Host "  [PASS] File size mismatch safely detected and failed with descriptive reason." -ForegroundColor Green

    # 5.3 Non-existent file detection
    $vfMissingPath = Join-Path $vfTestDir 'definitely_missing_file.xyz'
    $vfMissingRes = Test-RemoteCloudFileVerification -Account @{ ProviderId = 'local' } -RemotePath $vfMissingPath -ExpectedSizeBytes 100L
    if ($vfMissingRes.Verified -or $vfMissingRes.Status -ne 'Failed') {
        throw "Expected non-existent file verification to fail!"
    }
    if ($vfMissingRes.Reason -notmatch 'File not found') {
        throw "Expected reason to state file not found, got: $($vfMissingRes.Reason)"
    }
    Write-Host "  [PASS] Non-existent remote file safely rejected with 'File not found'." -ForegroundColor Green

    Write-Host "`nAll Transfer Recovery & Progression Tests Passed Successfully (exit code 0)." -ForegroundColor Cyan
} finally {
    # Reset custom queue path to avoid polluting subsequent tests or production state
    Set-TransferQueueFilePath -Path ''
    $script:CloudTransferQueue.Clear()

    # Clean up isolated sandbox
    if (Test-Path -LiteralPath $sandboxDir) {
        try {
            [System.IO.Directory]::Delete($sandboxDir, $true)
        } catch { }
    }
}

exit 0
