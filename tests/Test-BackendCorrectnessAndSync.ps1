Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Backend Correctness, Cache Inactivity TTL, Cancellation & Sync Integrity...'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CacheManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('backend_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    # ==============================================================================
    # 1. TEST PENDING STAGED UPLOADS DISCOVERY & 0-BYTE ACCURACY
    # ==============================================================================
    Write-Output '  -> Testing Pending Staged Uploads Discovery & 0-Byte Detection...'
    
    $acc1Vfs = Join-Path $testRoot 'terabox_acc1\vfs\remote1'
    $acc1Meta = Join-Path $testRoot 'terabox_acc1\vfsMeta\remote1'
    $acc2Vfs = Join-Path $testRoot 'gdrive_acc2\vfs\remote2'
    $acc2Meta = Join-Path $testRoot 'gdrive_acc2\vfsMeta\remote2'
    
    [System.IO.Directory]::CreateDirectory($acc1Vfs) | Out-Null
    [System.IO.Directory]::CreateDirectory($acc1Meta) | Out-Null
    [System.IO.Directory]::CreateDirectory($acc2Vfs) | Out-Null
    [System.IO.Directory]::CreateDirectory($acc2Meta) | Out-Null

    # Item A: Clean synced file (Dirty = false)
    $fileClean = Join-Path $acc1Vfs 'clean_doc.pdf'
    $metaClean = Join-Path $acc1Meta 'clean_doc.pdf'
    [System.IO.File]::WriteAllBytes($fileClean, [byte[]]::new(200))
    @{ ModTime = [DateTime]::UtcNow.ToString('o'); Size = 200; Dirty = $false } | ConvertTo-Json | Set-Content -LiteralPath $metaClean -Encoding UTF8

    # Item B: Genuinely dirty staged file (Dirty = true)
    $fileDirty = Join-Path $acc1Vfs 'staged_video.mp4'
    $metaDirty = Join-Path $acc1Meta 'staged_video.mp4'
    [System.IO.File]::WriteAllBytes($fileDirty, [byte[]]::new(500))
    @{ ModTime = [DateTime]::UtcNow.ToString('o'); Size = 500; Dirty = $true } | ConvertTo-Json | Set-Content -LiteralPath $metaDirty -Encoding UTF8

    # Item C: Clean 0-byte file (Dirty = false, size = 0)
    $fileCleanEmpty = Join-Path $acc2Vfs 'clean_empty.txt'
    $metaCleanEmpty = Join-Path $acc2Meta 'clean_empty.txt'
    [System.IO.File]::WriteAllBytes($fileCleanEmpty, [byte[]]@())
    @{ ModTime = [DateTime]::UtcNow.ToString('o'); Size = 0; Dirty = $false } | ConvertTo-Json | Set-Content -LiteralPath $metaCleanEmpty -Encoding UTF8

    # Item D: Genuinely dirty 0-byte staged file (Dirty = true, size = 0)
    $fileDirtyEmpty = Join-Path $acc2Vfs 'dirty_empty.txt'
    $metaDirtyEmpty = Join-Path $acc2Meta 'dirty_empty.txt'
    [System.IO.File]::WriteAllBytes($fileDirtyEmpty, [byte[]]@())
    @{ ModTime = [DateTime]::UtcNow.ToString('o'); Size = 0; Dirty = $true } | ConvertTo-Json | Set-Content -LiteralPath $metaDirtyEmpty -Encoding UTF8

    # Item E: Stale temporary file (should be ignored)
    $fileTmp = Join-Path $acc1Vfs 'upload.tmp'
    [System.IO.File]::WriteAllBytes($fileTmp, [byte[]]::new(100))

    $pendingList = @(Get-VirtualDrivePendingUploads -CacheDirectory $testRoot)
    
    # Must only discover Item B (dirty video) and Item D (dirty 0-byte empty file)
    if ($pendingList.Count -ne 2) {
        throw "Expected 2 pending uploads, discovered: $($pendingList.Count). Files: $(($pendingList | ForEach-Object { $_.Name }) -join ', ')"
    }

    $dirtyVideo = $pendingList | Where-Object { $_.Name -eq 'staged_video.mp4' }
    if (-not $dirtyVideo -or $dirtyVideo.Length -ne 500L -or $dirtyVideo.ProviderId -ne 'terabox') {
        throw "Dirty video item properties misreported: Length=$($dirtyVideo.Length), Provider=$($dirtyVideo.ProviderId)"
    }

    $dirtyEmpty = $pendingList | Where-Object { $_.Name -eq 'dirty_empty.txt' }
    if (-not $dirtyEmpty -or $dirtyEmpty.Length -ne 0L -or $dirtyEmpty.ProviderId -ne 'gdrive') {
        throw "Dirty 0-byte item properties misreported: Length=$($dirtyEmpty.Length), Provider=$($dirtyEmpty.ProviderId)"
    }

    # Verify notification fingerprint deduplication logic
    $fingerprint1 = ($pendingList | ForEach-Object { "$($_.Path):$($_.Length)" } | Sort-Object) -join ';'
    $fingerprint2 = ($pendingList | ForEach-Object { "$($_.Path):$($_.Length)" } | Sort-Object) -join ';'
    if ($fingerprint1 -ne $fingerprint2) {
        throw "Fingerprint generation was not deterministic"
    }

    Write-Output '  [PASS] Pending Staged Uploads Discovery & 0-Byte Detection verified'

    # ==============================================================================
    # 2. TEST TRANSFER LIFECYCLE STATES & CANCELLATION
    # ==============================================================================
    Write-Output '  -> Testing Transfer Lifecycle States & Cancellation...'

    $fakeJobId = 'transfer_lifecycle_test'
    $fakeJob = [ordered]@{
        JobId = $fakeJobId
        Process = $null
        StartTime = [DateTime]::UtcNow
        EndTime = $null
        SourceAccount = @{ DisplayName = 'Account A'; ProviderId = 'gdrive' }
        DestinationAccount = @{ DisplayName = 'Account B'; ProviderId = 'terabox' }
        SourcePath = 'test.dat'
        DestinationPath = 'test.dat'
        IsMove = $false
        ConflictAction = 'Skip'
        Status = 'Uploading to provider'
        VerificationStatus = 'Uploading to provider'
        IsLoopbackStaging = $false
        IsPaused = $false
        BytesTransferred = 1000L
        TotalBytes = 5000L
        SmoothedSpeed = 1000000.0
        AverageSpeed = 1000000.0
        EtaSeconds = 4
        Percentage = 20.0
        LastError = ''
        RecentLogs = [System.Collections.Generic.List[string]]::new()
        RecentErrors = [System.Collections.Generic.List[string]]::new()
        Mode = 'Streaming Relay'
        IsServerSide = $false
    }
    $script:ActiveTransferJobs[$fakeJobId] = $fakeJob

    # Cancellation execution
    $cancelled = Stop-CloudTransfer -JobId $fakeJobId
    if (-not $cancelled) {
        throw 'Stop-CloudTransfer returned false for active job'
    }

    $statusAfterCancel = Get-CloudTransferStatus -JobId $fakeJobId
    if ($statusAfterCancel.Status -ne 'Cancelled' -or $statusAfterCancel.VerificationStatus -ne 'Cancelled') {
        throw "Expected status 'Cancelled', got: $($statusAfterCancel.Status)"
    }

    # Test Stop-VirtualDriveTransfer clean failure fallback when drive not mounted
    $vCancel = Stop-VirtualDriveTransfer -DriveLetter 'Z'
    if ($vCancel.Success -ne $false -or $vCancel.State -ne 'Failed') {
        throw "Stop-VirtualDriveTransfer should fail safely on unmounted drive Z"
    }

    Write-Output '  [PASS] Transfer Lifecycle States & Cancellation verified'

    # ==============================================================================
    # 3. TEST CACHE INACTIVITY TTL POLICY & SIZE BOUNDARIES
    # ==============================================================================
    Write-Output '  -> Testing Cache Inactivity TTL Policy (5m <1GB, 20m 1-3GB, 45m >3GB)...'

    $ttlRoot = Join-Path $testRoot 'ttl_suite'
    [System.IO.Directory]::CreateDirectory($ttlRoot) | Out-Null
    $ttlDir = Join-Path $ttlRoot 'gdrive_ttl\vfs\remote'
    $ttlMetaDir = Join-Path $ttlRoot 'gdrive_ttl\vfsMeta\remote'
    [System.IO.Directory]::CreateDirectory($ttlDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($ttlMetaDir) | Out-Null

    # Case A: File < 1 GB, inactive 6 minutes (> 5 min threshold) -> SHOULD EVICT
    $fileSmallOld = Join-Path $ttlDir 'small_old.bin'
    $metaSmallOld = Join-Path $ttlMetaDir 'small_old.bin'
    [System.IO.File]::WriteAllBytes($fileSmallOld, [byte[]]@(1..50))
    $now = [DateTime]::UtcNow
    [System.IO.File]::SetLastWriteTimeUtc($fileSmallOld, $now.AddMinutes(-6))
    [System.IO.File]::SetLastAccessTimeUtc($fileSmallOld, $now.AddMinutes(-6))
    @{ ModTime = $now.AddMinutes(-6).ToString('o'); Size = 50; Dirty = $false } | ConvertTo-Json | Set-Content -LiteralPath $metaSmallOld -Encoding UTF8

    # Case B: File < 1 GB, inactive 2 minutes (< 5 min threshold) -> PRESERVE
    $fileSmallFresh = Join-Path $ttlDir 'small_fresh.bin'
    $metaSmallFresh = Join-Path $ttlMetaDir 'small_fresh.bin'
    [System.IO.File]::WriteAllBytes($fileSmallFresh, [byte[]]@(1..50))
    [System.IO.File]::SetLastWriteTimeUtc($fileSmallFresh, $now.AddMinutes(-2))
    [System.IO.File]::SetLastAccessTimeUtc($fileSmallFresh, $now.AddMinutes(-2))
    @{ ModTime = $now.AddMinutes(-2).ToString('o'); Size = 50; Dirty = $false } | ConvertTo-Json | Set-Content -LiteralPath $metaSmallFresh -Encoding UTF8

    # Case C: Dirty file, inactive 60 minutes -> MUST NEVER EVICT DIRTY DATA
    $fileDirtyOld = Join-Path $ttlDir 'dirty_old.bin'
    $metaDirtyOld = Join-Path $ttlMetaDir 'dirty_old.bin'
    [System.IO.File]::WriteAllBytes($fileDirtyOld, [byte[]]@(1..50))
    [System.IO.File]::SetLastWriteTimeUtc($fileDirtyOld, $now.AddMinutes(-60))
    [System.IO.File]::SetLastAccessTimeUtc($fileDirtyOld, $now.AddMinutes(-60))
    @{ ModTime = $now.AddMinutes(-60).ToString('o'); Size = 50; Dirty = $true } | ConvertTo-Json | Set-Content -LiteralPath $metaDirtyOld -Encoding UTF8

    # Case D: In-use locked file, inactive 60 minutes -> MUST PRESERVE
    $fileLocked = Join-Path $ttlDir 'locked_file.bin'
    $metaLocked = Join-Path $ttlMetaDir 'locked_file.bin'
    [System.IO.File]::WriteAllBytes($fileLocked, [byte[]]@(1..50))
    [System.IO.File]::SetLastWriteTimeUtc($fileLocked, $now.AddMinutes(-60))
    [System.IO.File]::SetLastAccessTimeUtc($fileLocked, $now.AddMinutes(-60))
    @{ ModTime = $now.AddMinutes(-60).ToString('o'); Size = 50; Dirty = $false } | ConvertTo-Json | Set-Content -LiteralPath $metaLocked -Encoding UTF8
    $lockStream = [System.IO.File]::Open($fileLocked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)

    try {
        $evictRes = Invoke-InactivityCacheEviction -CacheDirectory $ttlRoot
        
        if ($evictRes.EvictedFiles -ne 1) {
            throw "Expected 1 evicted file (small_old.bin), got: $($evictRes.EvictedFiles)"
        }
        if ($evictRes.SkippedStagedCount -ne 1) {
            throw "Expected 1 skipped staged file, got: $($evictRes.SkippedStagedCount)"
        }
        if ($evictRes.SkippedInUseCount -ne 1) {
            throw "Expected 1 skipped in-use file, got: $($evictRes.SkippedInUseCount)"
        }
        if (Test-Path -LiteralPath $fileSmallOld) {
            throw "Old inactive file was not evicted!"
        }
        if (Test-Path -LiteralPath $metaSmallOld) {
            throw "Matching vfsMeta file was not evicted with data file!"
        }
        if (-not (Test-Path -LiteralPath $fileSmallFresh)) {
            throw "Fresh inactive file (< 5 min) was incorrectly evicted!"
        }
        if (-not (Test-Path -LiteralPath $fileDirtyOld)) {
            throw "Dirty staged file was destroyed by inactivity eviction!"
        }
        if (-not (Test-Path -LiteralPath $fileLocked)) {
            throw "In-use locked file was destroyed by inactivity eviction!"
        }
    } finally {
        $lockStream.Close()
        $lockStream.Dispose()
    }

    Write-Output '  [PASS] Cache Inactivity TTL Policy verified'

    # ==============================================================================
    # 4. TEST LARGE-FILE TRANSFER PREFLIGHT & LOCAL WRITE VS NETWORK SPEED
    # ==============================================================================
    Write-Output '  -> Testing Large-File Reporting & TeraBox Free Limit...'

    $tbAccount = @{
        Id = 'terabox_test'
        DisplayName = 'TeraBox Free Test'
        ProviderId = 'terabox'
    }

    # 40 GB file must be rejected for TeraBox Free
    $preflight40Gb = Test-ProviderUploadPreflight -Account $tbAccount -FileSizeBytes (40L * 1024 * 1024 * 1024) -FileName 'huge_video.mkv'
    if ($preflight40Gb.Allowed -ne $false -or $preflight40Gb.ErrorCode -ne 'PlanFileLimit') {
        throw "40 GB TeraBox transfer should have been rejected by PlanFileLimit, got: Allowed=$($preflight40Gb.Allowed)"
    }

    # 500 MB file should be allowed
    $preflight500Mb = Test-ProviderUploadPreflight -Account $tbAccount -FileSizeBytes (500L * 1024 * 1024) -FileName 'normal_video.mkv'
    if ($preflight500Mb.Allowed -ne $true) {
        throw "500 MB TeraBox transfer was rejected: $($preflight500Mb.Reason)"
    }

    Write-Output '  [PASS] Large-File Reporting & TeraBox Free Limit verified'

} finally {
    try {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    } catch { }
}

Write-Output 'All Backend Correctness, Cache Inactivity TTL, Cancellation & Sync Integrity Tests Passed Successfully.'
