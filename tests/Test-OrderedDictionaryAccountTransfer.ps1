# ==============================================================================
# NS Cloud Drive - OrderedDictionary Account Transfer Regression Suite
# Verifies that System.Collections.Specialized.OrderedDictionary accounts do not
# throw MethodNotFound (due to missing .ContainsKey) across CloudTransferManager
# operations, enabling durable queue ingestion and worker processing.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== NS Cloud Drive OrderedDictionary Account Transfer Regression Suite ===" -ForegroundColor Cyan

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'providers\TeraBoxProvider.ps1')
. (Join-Path $srcDir 'providers\GoogleDriveProvider.ps1')
. (Join-Path $srcDir 'services\TeraBoxBridgeManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

Write-Host "  [PASS] Modules loaded successfully under Set-StrictMode -Version Latest"

# Isolate queue file and working directories in %TEMP%
$tempRoot = Join-Path $env:TEMP ("NSCloudDrive_OrderedDictTest_" + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempRoot)
$tempQueueFile = Join-Path $tempRoot "test-transfer-jobs.json"
Set-TransferQueueFilePath -Path $tempQueueFile

# Reset in-memory queue
$script:CloudTransferQueue.Clear()
$script:ActiveTransferJobs.Clear()

try {
    # --------------------------------------------------------------------------
    # 1. Setup OrderedDictionary Account Instances
    # --------------------------------------------------------------------------
    $localAccount = [ordered]@{
        Id          = 'test_local_ordered_acc'
        ProviderId  = 'local'
        DisplayName = 'Local Ordered Test'
        DriveLetter = 'C'
    }

    $gdriveAccount = [ordered]@{
        Id          = 'test_gdrive_ordered_acc'
        ProviderId  = 'gdrive'
        DisplayName = 'Google Drive Ordered Test'
        DriveLetter = 'Z'
    }

    $teraBoxAccount = [ordered]@{
        Id          = 'test_tb_ordered_acc'
        ProviderId  = 'terabox'
        DisplayName = 'TeraBox Ordered Test'
        DriveLetter = 'Y'
    }

    # Verify types are strictly System.Collections.Specialized.OrderedDictionary
    if ($gdriveAccount -isnot [System.Collections.Specialized.OrderedDictionary]) {
        throw "gdriveAccount is not System.Collections.Specialized.OrderedDictionary"
    }
    if ($teraBoxAccount -isnot [System.Collections.Specialized.OrderedDictionary]) {
        throw "teraBoxAccount is not System.Collections.Specialized.OrderedDictionary"
    }
    Write-Host "  [PASS] Test accounts verified as [System.Collections.Specialized.OrderedDictionary]"

    # --------------------------------------------------------------------------
    # 2. Verify Resolve-CloudTransferOperation with OrderedDictionary
    # --------------------------------------------------------------------------
    $dummyFile = Join-Path $tempRoot 'dummy_source.bin'
    [System.IO.File]::WriteAllBytes($dummyFile, [byte[]]@(1, 2, 3, 4, 5))

    $opUpload = Resolve-CloudTransferOperation `
        -SourceAccount $localAccount `
        -SourcePath $dummyFile `
        -DestinationAccount $gdriveAccount `
        -DestinationPath 'uploads'

    if (-not $opUpload.IsValid -or $opUpload.OperationType -ne 'Upload' -or $opUpload.Direction -ne 'Upload') {
        throw "Resolve-CloudTransferOperation failed for Local -> GDrive OrderedDictionary: $($opUpload.Reason)"
    }

    $opDownload = Resolve-CloudTransferOperation `
        -SourceAccount $gdriveAccount `
        -SourcePath 'remote_folder/remote.txt' `
        -DestinationAccount $localAccount `
        -DestinationPath (Join-Path $tempRoot 'downloaded.txt')

    if (-not $opDownload.IsValid -or $opDownload.OperationType -ne 'Download' -or $opDownload.Direction -ne 'Download') {
        throw "Resolve-CloudTransferOperation failed for GDrive -> Local OrderedDictionary: $($opDownload.Reason)"
    }

    $opCloudCopy = Resolve-CloudTransferOperation `
        -SourceAccount $gdriveAccount `
        -SourcePath 'remote_folder/remote.txt' `
        -DestinationAccount $teraBoxAccount `
        -DestinationPath 'cloud_dest'

    if (-not $opCloudCopy.IsValid -or $opCloudCopy.OperationType -ne 'CloudCopy') {
        throw "Resolve-CloudTransferOperation failed for GDrive -> TeraBox OrderedDictionary: $($opCloudCopy.Reason)"
    }
    Write-Host "  [PASS] Resolve-CloudTransferOperation successfully resolved Upload, Download, and CloudCopy"

    # --------------------------------------------------------------------------
    # 3. Verify Test-ProviderUploadPreflight with OrderedDictionary
    # --------------------------------------------------------------------------
    $preflightGDrive = Test-ProviderUploadPreflight -Account $gdriveAccount -FileSizeBytes 1048576 -FileName 'sample.dat'
    if ($null -eq $preflightGDrive -or -not $preflightGDrive.Allowed) {
        throw "Test-ProviderUploadPreflight failed for GDrive OrderedDictionary"
    }

    $preflightTB = Test-ProviderUploadPreflight -Account $teraBoxAccount -FileSizeBytes 1048576 -FileName 'sample.dat'
    if ($null -eq $preflightTB -or -not $preflightTB.Allowed) {
        throw "Test-ProviderUploadPreflight failed for TeraBox OrderedDictionary"
    }

    # Verify oversized file limit on TeraBox free tier without throwing MethodNotFound
    $preflightOversized = Test-ProviderUploadPreflight -Account $teraBoxAccount -FileSizeBytes 5000000000L -FileName 'large.iso'
    if ($null -eq $preflightOversized -or $preflightOversized.Allowed) {
        throw "Test-ProviderUploadPreflight should have rejected oversized file on TeraBox"
    }
    Write-Host "  [PASS] Test-ProviderUploadPreflight verified for GDrive and TeraBox OrderedDictionary"

    # --------------------------------------------------------------------------
    # 4. Verify Get-CloudAccountTransferRemoteEnvironment with OrderedDictionary
    # --------------------------------------------------------------------------
    # Local account remote environment
    $localEnv = Get-CloudAccountTransferRemoteEnvironment -Account $localAccount -RemoteAlias 'local_remote'
    if ($null -eq $localEnv -or $localEnv.Count -ne 0) {
        throw "Get-CloudAccountTransferRemoteEnvironment failed for Local OrderedDictionary"
    }

    # GDrive account remote environment: Must not throw MethodNotFound / ContainsKey error
    try {
        $null = Get-CloudAccountTransferRemoteEnvironment -Account $gdriveAccount -RemoteAlias 'gd_remote'
        Write-Host "  [PASS] Get-CloudAccountTransferRemoteEnvironment (gdrive) generated environment"
    } catch {
        if ($_.Exception.Message -match 'ContainsKey' -or $_.Exception.Message -match 'does not contain a method named') {
            throw "Get-CloudAccountTransferRemoteEnvironment threw MethodNotFound on GDrive: $($_.Exception.Message)"
        }
        Write-Host "  [PASS] Get-CloudAccountTransferRemoteEnvironment (gdrive) safely handled tokens ($($_.Exception.Message))"
    }

    # TeraBox account remote environment: Must not throw MethodNotFound / ContainsKey error
    try {
        $null = Get-CloudAccountTransferRemoteEnvironment -Account $teraBoxAccount -RemoteAlias 'tb_remote'
        Write-Host "  [PASS] Get-CloudAccountTransferRemoteEnvironment (terabox) generated environment"
    } catch {
        if ($_.Exception.Message -match 'ContainsKey' -or $_.Exception.Message -match 'does not contain a method named') {
            throw "Get-CloudAccountTransferRemoteEnvironment threw MethodNotFound on TeraBox: $($_.Exception.Message)"
        }
        Write-Host "  [PASS] Get-CloudAccountTransferRemoteEnvironment (terabox) safely handled bridge ($($_.Exception.Message))"
    }

    # --------------------------------------------------------------------------
    # 5. Verify Add-CloudTransferQueueItem with OrderedDictionary
    # --------------------------------------------------------------------------
    $jobGDrive = Add-CloudTransferQueueItem `
        -SourceAccount $localAccount `
        -SourcePath $dummyFile `
        -DestinationAccount $gdriveAccount `
        -DestinationPath 'uploads' `
        -SkipPersist

    if ($null -eq $jobGDrive -or -not $jobGDrive.JobId -or $jobGDrive.OperationType -ne 'Upload') {
        throw "Add-CloudTransferQueueItem failed to enqueue GDrive upload"
    }

    $jobTB = Add-CloudTransferQueueItem `
        -SourceAccount $localAccount `
        -SourcePath $dummyFile `
        -DestinationAccount $teraBoxAccount `
        -DestinationPath 'backups' `
        -SkipPersist

    if ($null -eq $jobTB -or -not $jobTB.JobId -or $jobTB.OperationType -ne 'Upload') {
        throw "Add-CloudTransferQueueItem failed to enqueue TeraBox upload"
    }
    Write-Host "  [PASS] Add-CloudTransferQueueItem succeeded with OrderedDictionary accounts"

    # --------------------------------------------------------------------------
    # 6. Verify Add-CloudTransferFolderBatch with OrderedDictionary
    # --------------------------------------------------------------------------
    $folderToIngest = Join-Path $tempRoot 'batch_folder'
    [void][System.IO.Directory]::CreateDirectory($folderToIngest)
    [System.IO.File]::WriteAllText((Join-Path $folderToIngest 'fileA.txt'), 'content A')
    [System.IO.File]::WriteAllText((Join-Path $folderToIngest 'fileB.txt'), 'content B')

    $batchJobs = Add-CloudTransferFolderBatch `
        -SourceAccount $localAccount `
        -SourceFolderPath $folderToIngest `
        -DestinationAccount $gdriveAccount `
        -DestinationFolderPath 'target_remote_dir'

    if ($null -eq $batchJobs -or $batchJobs.Count -lt 2) {
        throw "Add-CloudTransferFolderBatch failed to enqueue items with OrderedDictionary"
    }
    Write-Host "  [PASS] Add-CloudTransferFolderBatch succeeded with OrderedDictionary ($($batchJobs.Count) items enqueued)"

    # --------------------------------------------------------------------------
    # 7. Verify Resolve-TransferAccountSnapshot with OrderedDictionary
    # --------------------------------------------------------------------------
    $snapshotResolved = Resolve-TransferAccountSnapshot -Snapshot $gdriveAccount
    if ($null -eq $snapshotResolved -or $snapshotResolved['Id'] -ne 'test_gdrive_ordered_acc') {
        throw "Resolve-TransferAccountSnapshot failed on OrderedDictionary"
    }
    Write-Host "  [PASS] Resolve-TransferAccountSnapshot succeeded with OrderedDictionary"

    # --------------------------------------------------------------------------
    # 8. Verify Get-CloudTransferStatus with missing DisplayName & OrderedDictionary
    # --------------------------------------------------------------------------
    $noDisplayAccount = [ordered]@{
        Id         = 'acc_no_display_test'
        ProviderId = 'local'
    }

    $mockJobRecord = [ordered]@{
        JobId               = 'active_test_job_1'
        Process             = $null
        StartTime           = [DateTime]::UtcNow
        EndTime             = $null
        SourceAccount       = $noDisplayAccount
        DestinationAccount  = $teraBoxAccount
        SourcePath          = 'C:\source\file.dat'
        DestinationPath     = 'dest\file.dat'
        IsMove              = $false
        ConflictAction      = 'Skip'
        Status              = 'Uploading'
        VerificationStatus  = 'Uploading'
        IsLoopbackStaging    = $true
        IsPaused            = $false
        BytesTransferred    = 500L
        TotalBytes          = 1000L
        SmoothedSpeed       = 250.0
        AverageSpeed        = 250.0
        EtaSeconds          = 2
        Percentage          = 50.0
        LastError           = ''
        RemoteHash          = ''
        VerificationType    = ''
        RecentLogs          = [System.Collections.Generic.List[string]]::new()
        RecentErrors        = [System.Collections.Generic.List[string]]::new()
        Mode                = 'Streaming Relay'
        IsServerSide        = $false
    }
    $script:ActiveTransferJobs['active_test_job_1'] = $mockJobRecord

    $statusReport = Get-CloudTransferStatus -JobId 'active_test_job_1'
    if ($null -eq $statusReport) {
        throw "Get-CloudTransferStatus returned null for active job"
    }
    # Verify fallback from missing DisplayName to Id
    if ($statusReport.SourceAccount -ne 'acc_no_display_test') {
        throw "Get-CloudTransferStatus failed DisplayName fallback: expected 'acc_no_display_test', got '$($statusReport.SourceAccount)'"
    }
    if ($statusReport.DestinationAccount -ne 'TeraBox Ordered Test') {
        throw "Get-CloudTransferStatus failed DisplayName check: expected 'TeraBox Ordered Test', got '$($statusReport.DestinationAccount)'"
    }
    Write-Host "  [PASS] Get-CloudTransferStatus safely handled missing DisplayName and OrderedDictionary"

    Write-Host "`nAll OrderedDictionary Account Transfer Tests Passed Successfully!" -ForegroundColor Green
    exit 0
} finally {
    Set-TransferQueueFilePath -Path ''
    $script:CloudTransferQueue.Clear()
    $script:ActiveTransferJobs.Clear()

    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}
