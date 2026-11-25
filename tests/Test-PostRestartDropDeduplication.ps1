# ==============================================================================
# NS Cloud Drive - Test Post-Restart Drop Deduplication (100 Files Interruption Scenario)
# Validates:
# 1. 100-file batch where 75 files complete and PC power-off / restart occurs.
# 2. On restart, user drags and drops all 100 files again into the drive.
# 3. Startup recovery confirms those 75 and safely retries the interrupted 25.
# 4. Re-dropping all files skips the 75 remote matches and retains the 25 existing jobs.
# 5. Format differences (PNG vs JPG) and size modifications are detected and re-sent.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Testing Post-Restart Drop Deduplication & Restart Recovery ===" -ForegroundColor Cyan

$testDir = Join-Path ([System.IO.Path]::GetTempPath()) "NSCloudDrive_PostRestartDrop_Test_$([Guid]::NewGuid().ToString('N'))"
$sourceDir = Join-Path $testDir "SourceDropFiles"
$cacheDir = Join-Path $testDir "Cache"
$fakeDriveRoot = Join-Path $testDir "FakeVirtualDrive"

New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $fakeDriveRoot -Force | Out-Null

$testLedgerPath = Join-Path $cacheDir "cloud-dedup-ledger.json"
$testQueuePath = Join-Path $cacheDir "cloud-transfer-queue.json"

# Import Required Services
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\ProviderContract.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudDeduplicationService.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')

$emptyProviderListing = ConvertFrom-CloudDirectoryListingJson -Json '[]' -Path 'empty-folder'
if ($emptyProviderListing -isnot [System.Array] -or $emptyProviderListing.Count -ne 0) {
    throw 'A valid empty provider listing must remain an empty array.'
}
$singleProviderListing = ConvertFrom-CloudDirectoryListingJson -Json '[{"Name":"single.txt","IsDir":false,"Size":1}]' -Path 'single-item-folder'
if ($singleProviderListing -isnot [System.Array] -or $singleProviderListing.Count -ne 1 -or $singleProviderListing[0].Name -ne 'single.txt') {
    throw 'A valid one-item provider listing must remain a single-element array.'
}
$malformedListingRejected = $false
try { $null = ConvertFrom-CloudDirectoryListingJson -Json '{invalid' -Path 'broken-folder' } catch { $malformedListingRejected = $true }
if (-not $malformedListingRejected) {
    throw 'Malformed provider JSON must be rejected instead of becoming an empty inventory.'
}
$nonArrayListingRejected = $false
try { $null = ConvertFrom-CloudDirectoryListingJson -Json '{"Name":"unexpected"}' -Path 'broken-folder' } catch { $nonArrayListingRejected = $true }
if (-not $nonArrayListingRejected) {
    throw 'A non-array provider response must be rejected instead of becoming an empty inventory.'
}
$missingSizeListingRejected = $false
try { $null = ConvertFrom-CloudDirectoryListingJson -Json '[{"Name":"zero-byte.txt","IsDir":false}]' -Path 'broken-folder' } catch { $missingSizeListingRejected = $true }
if (-not $missingSizeListingRejected) {
    throw 'A file without a validated byte size must not be treated as a zero-byte remote match.'
}
Write-Host '  [PASS] Empty and single-item listings retain their array shape; malformed responses fail closed.' -ForegroundColor Green

$script:MockRemoteUnavailable = $false
$script:MockRemoteError = ''
$script:MockListingCalls = 0
$script:MockMissingRemoteSizeName = ''
function Get-CloudDirectoryContents {
    param([object]$Account, [string]$Path = '', [switch]$BypassLocalMount)
    $script:MockListingCalls++
    if ($script:MockRemoteUnavailable) { throw 'Simulated provider unavailable' }
    if ($script:MockRemoteError) { throw $script:MockRemoteError }
    $remoteFolder = if ($Path) { Join-Path $fakeDriveRoot ($Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)) } else { $fakeDriveRoot }
    if (-not (Test-Path -LiteralPath $remoteFolder -PathType Container)) { return @() }
    $entries = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($remoteDirectory in @(Get-ChildItem -LiteralPath $remoteFolder -Directory -ErrorAction SilentlyContinue)) {
        $entries.Add(@{
            Name = $remoteDirectory.Name
            Path = $remoteDirectory.Name
            IsDir = $true
            Size = 0L
            ModTime = $remoteDirectory.LastWriteTimeUtc.ToString('o')
            Hash = ''
        })
    }
    foreach ($remoteFile in @(Get-ChildItem -LiteralPath $remoteFolder -File -ErrorAction SilentlyContinue)) {
        $entry = @{
            Name = $remoteFile.Name
            # rclone lsjson reports Path relative to the folder being listed.
            Path = $remoteFile.Name
            IsDir = $false
            ModTime = $remoteFile.LastWriteTimeUtc.ToString('o')
            Hash = ''
        }
        if ($remoteFile.Name -ne $script:MockMissingRemoteSizeName) { $entry['Size'] = [int64]$remoteFile.Length }
        $entries.Add($entry)
    }
    return $entries.ToArray()
}

function Get-TestTransferQueueItems {
    $result = Get-CloudTransferQueue
    if ($result -is [array] -and $result.Count -gt 0 -and $result[0] -is [array]) {
        return @($result[0])
    }
    return @($result)
}

Set-CloudDedupLedgerPathOverride $testLedgerPath
Set-TransferQueueFilePath $testQueuePath

$testAccount = [ordered]@{
    Id         = 'acc_gdrive_postrestart_test'
    ProviderId = 'gdrive'
    Email      = 'tester@example.com'
}

try {
    # --------------------------------------------------------------------------
    # Step 1: Generate 100 Test Files
    # --------------------------------------------------------------------------
    Write-Host "  -> Generating 100 test files with varied formats and sizes..." -ForegroundColor Yellow
    $all100FilePaths = [System.Collections.Generic.List[string]]::new()
    
    for ($i = 1; $i -le 100; $i++) {
        $ext = switch ($i % 5) {
            0 { '.png' }
            1 { '.jpg' }
            2 { '.pdf' }
            3 { '.txt' }
            4 { '.csv' }
        }
        $fName = "document_$($i.ToString('D3'))$ext"
        $fPath = Join-Path $sourceDir $fName
        # Distinct content & size for each file
        $content = "Payload data for file #$i - " + ('X' * ($i * 15))
        [System.IO.File]::WriteAllText($fPath, $content, [System.Text.Encoding]::UTF8)
        $all100FilePaths.Add($fPath)
    }

    if ($all100FilePaths.Count -ne 100) {
        throw "Failed to create 100 test files. Count was: $($all100FilePaths.Count)"
    }
    Write-Host "  [PASS] Successfully generated 100 unique files." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 2: Initial Session - Queue 100 files, then simulate 75 remote completions
    # --------------------------------------------------------------------------
    Write-Host "  -> Persisting all 100 jobs, then confirming the first 75 remotely..." -ForegroundColor Yellow
    $initialDrop = Add-CloudTransferDroppedItems `
        -DestinationAccount $testAccount `
        -DroppedPaths @($all100FilePaths.ToArray()) `
        -ConflictAction 'Skip' `
        -BatchName 'Initial_100_File_Transfer'
    if ($initialDrop.QueuedCount -ne 100) {
        throw "Expected 100 jobs to be queued initially, got $($initialDrop.QueuedCount)."
    }

    $first75Paths = $all100FilePaths.GetRange(0, 75)
    foreach ($fp in $first75Paths) {
        $fi = [System.IO.FileInfo]::new($fp)
        $rel = $fi.Name
        Copy-Item -LiteralPath $fp -Destination (Join-Path $fakeDriveRoot $rel) -Force
        Record-CloudDedupVerifiedFile `
            -AccountId ([string]$testAccount.Id) `
            -ProviderId ([string]$testAccount.ProviderId) `
            -RemotePath $rel `
            -SizeBytes ([int64]$fi.Length) `
            -Format (Get-FileFormatCategory $fi.Extension) `
            -RemoteHash "hash_$($fi.Name)" `
            -SkipPersist
        $completedJob = @($script:CloudTransferQueue | Where-Object { $_['DestinationFilePath'] -eq $rel })[0]
        $completedJob['Status'] = 'Completed and remotely confirmed'
        $completedJob['BytesTransferred'] = [int64]$fi.Length
        $completedJob['Percentage'] = 100.0
        $completedJob['CompletedUtc'] = [DateTime]::UtcNow
        $completedJob['VerificationType'] = 'TestRemoteProvider'
    }
    foreach ($interruptedPath in $all100FilePaths.GetRange(75, 25)) {
        $interruptedName = [System.IO.Path]::GetFileName($interruptedPath)
        $interruptedJob = @($script:CloudTransferQueue | Where-Object { $_['DestinationFilePath'] -eq $interruptedName })[0]
        $interruptedJob['Status'] = 'Uploading'
        $interruptedJob['BytesTransferred'] = [int64]($interruptedJob['FileSizeBytes'] / 2)
        $interruptedJob['Percentage'] = 50.0
        $interruptedJob['WorkerPid'] = 54321
        $interruptedJob['WorkerLeaseUtc'] = [DateTime]::UtcNow.AddMinutes(-3)
    }
    Save-CloudDedupLedger
    Save-DurableTransferQueue | Out-Null

    if (-not (Test-Path -LiteralPath $testLedgerPath)) {
        throw "cloud-dedup-ledger.json was not written to disk!"
    }

    $ledgerContent = Get-Content -LiteralPath $testLedgerPath -Raw | ConvertFrom-Json
    if ($ledgerContent.Count -ne 75) {
        throw "Expected 75 verified entries in ledger, found $($ledgerContent.Count)"
    }
    $initialQueuePayload = Get-Content -LiteralPath $testQueuePath -Raw | ConvertFrom-Json
    if (@($initialQueuePayload.Jobs).Count -ne 100) {
        throw "Expected 100 durable transfer jobs before restart, found $(@($initialQueuePayload.Jobs).Count)."
    }
    Write-Host "  [PASS] 75 remote files and all 100 transfer jobs were durably persisted before restart." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 3: Simulate Sudden PC Shutdown / Power-off & Machine Restart
    # --------------------------------------------------------------------------
    Write-Host "  -> Simulating machine power-off / restart (clearing volatile memory)..." -ForegroundColor Yellow
    
    # Clear in-memory transfer queues and deduplication cache
    $script:CloudTransferQueue.Clear()
    Set-CloudDedupLedgerPathOverride $testLedgerPath
    Set-TransferQueueFilePath $testQueuePath

    $loadedJobs = Load-DurableTransferQueue
    if ($loadedJobs -ne 100) { throw "Expected 100 jobs to reload after restart, got $loadedJobs." }

    # Verify memory is clean but disk ledger persists
    $reloadedLedger = Load-CloudDedupLedger
    if ($reloadedLedger.Keys.Count -ne 75) {
        throw "Reloaded ledger should contain 75 items after restart, found $($reloadedLedger.Keys.Count)"
    }
    Write-Host "  [PASS] Durable queue and ledger loaded across simulated restart." -ForegroundColor Green

    $script:MockListingCalls = 0
    $recovery = Invoke-StartupTransferQueueRecovery
    if ($recovery.RecoveredCount -ne 25 -or $recovery.ConfirmedCount -ne 0 -or $recovery.ResetCount -ne 25) {
        throw "Expected 25 interrupted jobs to recover and wait for retry; got recovered=$($recovery.RecoveredCount), confirmed=$($recovery.ConfirmedCount), reset=$($recovery.ResetCount)."
    }
    $afterRecovery = @(Get-TestTransferQueueItems)
    $confirmedAfterRecovery = @($afterRecovery | Where-Object { $_['Status'] -eq 'Completed and remotely confirmed' }).Count
    $waitingAfterRecovery = @($afterRecovery | Where-Object { $_['Status'] -eq 'Waiting for network/provider' }).Count
    if ($confirmedAfterRecovery -ne 75 -or $waitingAfterRecovery -ne 25) {
        throw "Restart recovery state mismatch: confirmed=$confirmedAfterRecovery, waiting=$waitingAfterRecovery."
    }
    if ($script:MockListingCalls -ne 1) {
        throw "Startup recovery should scan the shared destination folder once for all 25 interrupted files; provider listings=$($script:MockListingCalls)."
    }
    Write-Host "  [PASS] Restart recovery confirmed 75 cloud files and preserved exactly 25 interrupted jobs." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 4: User Drags & Drops ALL 100 Files Again into the Drive
    # --------------------------------------------------------------------------
    Write-Host "  -> Simulating user dragging all 100 files again into the drive..." -ForegroundColor Yellow
    
    $dropResult = Add-CloudTransferDroppedItems `
        -DestinationAccount $testAccount `
        -DroppedPaths @($all100FilePaths.ToArray()) `
        -ConflictAction 'Skip' `
        -BatchName 'Recovery_Drop_All100'

    Write-Host "     Drop Result Summary: Total=$($dropResult.TotalDropped), Skipped=$($dropResult.SkippedCount), Queued=$($dropResult.QueuedCount)"

    if ($dropResult.TotalDropped -ne 100) {
        throw "Expected 100 total dropped files, got $($dropResult.TotalDropped)"
    }

    # CRITICAL USER ASSERTION: Exactly 75 files skipped, remaining 25 stay queued
    if ($dropResult.SkippedCount -ne 75) {
        throw "CRITICAL FAILURE: Expected exactly 75 files to be skipped, but skipped count was $($dropResult.SkippedCount)!"
    }
    Write-Host "  [PASS] Exactly 75 files identified by name, size, and location and SKIPPED (0 bytes re-transferred)." -ForegroundColor Green

    if ($dropResult.QueuedCount -ne 25 -or $dropResult.NewlyQueuedCount -ne 0 -or $dropResult.AlreadyTrackedCount -ne 25) {
        throw "CRITICAL FAILURE: Expected 25 remaining jobs already in queue and no duplicates; got queued=$($dropResult.QueuedCount), new=$($dropResult.NewlyQueuedCount), tracked=$($dropResult.AlreadyTrackedCount)."
    }
    Write-Host "  [PASS] Exactly 25 unsent files remain queued; the re-drop created no duplicate jobs." -ForegroundColor Green

    # Verify the 25 queued files correspond to documents 076 to 100
    $pendingJobs = @(Get-TestTransferQueueItems | Where-Object { $_['Status'] -eq 'Waiting for network/provider' })
    if ($pendingJobs.Count -ne 25) { throw "Expected 25 waiting jobs after restart; found $($pendingJobs.Count)." }
    foreach ($qJob in $pendingJobs) {
        $qName = [string]$qJob['FileName']
        $match = [System.Text.RegularExpressions.Regex]::Match($qName, 'document_(\d+)')
        if ($match.Success) {
            $num = [int]$match.Groups[1].Value
            if ($num -lt 76 -or $num -gt 100) {
                throw "Unexpected file queued: $qName (should be between 86 and 100)"
            }
        }
    }
    Write-Host "  [PASS] All retained jobs correctly correspond to the unsent files (document_076 through document_100)." -ForegroundColor Green

    # An unavailable provider is not evidence that the destination path is absent.
    $script:MockRemoteUnavailable = $true
    $offlineCheck = Test-RemoteCloudFileDeduplication `
        -AccountId ([string]$testAccount.Id) `
        -ProviderId ([string]$testAccount.ProviderId) `
        -RemotePath 'provider-offline.txt' `
        -LocalSizeBytes 12L `
        -LocalFilePath $all100FilePaths[0] `
        -Account $testAccount `
        -RequireLiveCheck
    $script:MockRemoteUnavailable = $false
    if ($offlineCheck.Status -ne 'Unavailable' -or $offlineCheck.IsPresent) {
        throw "Provider outage must not be classified as absent or already uploaded; got $($offlineCheck.Status)."
    }
    Write-Host "  [PASS] Provider unavailability remains distinct from confirmed remote absence." -ForegroundColor Green

    $script:MockRemoteError = 'HTTP 404 Not Found'
    $missingParentCheck = Test-RemoteCloudFileDeduplication `
        -AccountId ([string]$testAccount.Id) `
        -ProviderId ([string]$testAccount.ProviderId) `
        -RemotePath 'missing-parent/provider-file.txt' `
        -LocalSizeBytes 12L `
        -LocalFilePath $all100FilePaths[0] `
        -Account $testAccount `
        -RequireLiveCheck
    $script:MockRemoteError = ''
    if ($missingParentCheck.Status -ne 'New' -or $missingParentCheck.IsPresent) {
        throw "A confirmed HTTP 404 for a missing destination path should allow upload; got $($missingParentCheck.Status)."
    }

    $script:MockRemoteUnavailable = $true
    $script:MockListingCalls = 0
    $unavailableInventory = Get-RemoteFileInventoryMap -DestinationAccount $testAccount -DestinationFolderPaths @('offline-parent') -BypassLedger
    $callsAfterUnavailableScan = $script:MockListingCalls
    $unavailableCandidate = Classify-TransferCandidate `
        -LocalFilePath $all100FilePaths[0] `
        -DestinationRelativePath 'offline-parent/provider-file.txt' `
        -RemoteInventoryMap $unavailableInventory `
        -DestinationAccount $testAccount
    $script:MockRemoteUnavailable = $false
    if ($unavailableCandidate.Status -ne 'Unavailable' -or $script:MockListingCalls -ne $callsAfterUnavailableScan -or $callsAfterUnavailableScan -ne 1) {
        throw "An unavailable folder scan should defer classification without per-file provider retries; status=$($unavailableCandidate.Status), requests=$($script:MockListingCalls)."
    }
    Write-Host "  [PASS] Missing-folder 404 is an uploadable absence; provider outages are cached per folder and fail closed." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 4b: Verify recursive live inventory for nested folder drops
    # --------------------------------------------------------------------------
    Write-Host "  -> Verifying bounded provider listings cover only targeted nested folders..." -ForegroundColor Yellow
    $nestedLocalDir = Join-Path $sourceDir 'subfolder'
    $nestedRemoteDir = Join-Path $fakeDriveRoot 'subfolder'
    New-Item -ItemType Directory -Path $nestedLocalDir -Force | Out-Null
    New-Item -ItemType Directory -Path $nestedRemoteDir -Force | Out-Null
    $nestedLocalPath = Join-Path $nestedLocalDir 'nested-present.txt'
    $nestedRemotePath = Join-Path $nestedRemoteDir 'nested-present.txt'
    [System.IO.File]::WriteAllText($nestedLocalPath, 'same nested payload', [System.Text.Encoding]::UTF8)
    Copy-Item -LiteralPath $nestedLocalPath -Destination $nestedRemotePath -Force

    $script:MockListingCalls = 0
    $nestedInventory = Get-RemoteFileInventoryMap -DestinationAccount $testAccount -DestinationFolderPaths @('', 'subfolder') -BypassLedger
    if ($script:MockListingCalls -ne 2 -or -not $nestedInventory.ContainsKey('subfolder/nested-present.txt')) {
        throw "Expected one root and one nested folder listing, with a complete nested path; calls=$($script:MockListingCalls), nestedPresent=$($nestedInventory.ContainsKey('subfolder/nested-present.txt'))."
    }
    $nestedMatch = Classify-TransferCandidate `
        -LocalFilePath $nestedLocalPath `
        -DestinationRelativePath 'subfolder/nested-present.txt' `
        -RemoteInventoryMap $nestedInventory `
        -DestinationAccount $testAccount
    if ($nestedMatch.Status -ne 'AlreadyInCloud' -or $nestedMatch.ShouldTransfer) {
        throw "Nested remote file was not deduplicated from the recursive scan: $($nestedMatch.Status)."
    }

    $nestedMissingPath = Join-Path $nestedLocalDir 'nested-missing.txt'
    [System.IO.File]::WriteAllText($nestedMissingPath, 'new nested payload', [System.Text.Encoding]::UTF8)
    $callsBeforeMissing = $script:MockListingCalls
    $nestedMissing = Classify-TransferCandidate `
        -LocalFilePath $nestedMissingPath `
        -DestinationRelativePath 'subfolder/nested-missing.txt' `
        -RemoteInventoryMap $nestedInventory `
        -DestinationAccount $testAccount
    if ($nestedMissing.Status -ne 'New' -or -not $nestedMissing.ShouldTransfer -or $script:MockListingCalls -ne $callsBeforeMissing) {
        throw "A missing nested file should be classified from the completed scan without a per-file provider request."
    }

    $nestedDirect = Test-RemoteCloudFileDeduplication `
        -AccountId ([string]$testAccount.Id) `
        -ProviderId ([string]$testAccount.ProviderId) `
        -RemotePath 'subfolder/nested-present.txt' `
        -LocalSizeBytes ([int64]([System.IO.FileInfo]::new($nestedLocalPath).Length)) `
        -LocalFilePath $nestedLocalPath `
        -Account $testAccount `
        -RequireLiveCheck
    if ($nestedDirect.Status -ne 'AlreadyInCloud' -or -not $nestedDirect.IsPresent) {
        throw "Direct provider listing did not normalize the nested relative path: $($nestedDirect.Status)."
    }

    $directoryCollisionPath = Join-Path $sourceDir 'empty-collision.txt'
    [System.IO.File]::WriteAllBytes($directoryCollisionPath, [byte[]]::new(0))
    New-Item -ItemType Directory -Path (Join-Path $fakeDriveRoot 'empty-collision.txt') -Force | Out-Null
    $directoryCollision = Test-RemoteCloudFileDeduplication `
        -AccountId ([string]$testAccount.Id) `
        -ProviderId ([string]$testAccount.ProviderId) `
        -RemotePath 'empty-collision.txt' `
        -LocalSizeBytes 0L `
        -LocalFilePath $directoryCollisionPath `
        -Account $testAccount `
        -RequireLiveCheck
    if ($directoryCollision.IsPresent -or $directoryCollision.Status -ne 'PathMismatch') {
        throw "A same-name cloud directory must not confirm a zero-byte local file; got $($directoryCollision.Status)."
    }

    $unknownSizePath = Join-Path $fakeDriveRoot 'unknown-size.txt'
    [System.IO.File]::WriteAllBytes($unknownSizePath, [byte[]]::new(0))
    $unknownSizeLocalPath = Join-Path $sourceDir 'unknown-size.txt'
    [System.IO.File]::WriteAllBytes($unknownSizeLocalPath, [byte[]]::new(0))
    $script:MockMissingRemoteSizeName = 'unknown-size.txt'
    $unknownRemoteSize = Test-RemoteCloudFileDeduplication `
        -AccountId ([string]$testAccount.Id) `
        -ProviderId ([string]$testAccount.ProviderId) `
        -RemotePath 'unknown-size.txt' `
        -LocalSizeBytes 0L `
        -LocalFilePath $unknownSizeLocalPath `
        -Account $testAccount `
        -RequireLiveCheck
    $script:MockMissingRemoteSizeName = ''
    if ($unknownRemoteSize.IsPresent -or $unknownRemoteSize.Status -ne 'Unavailable') {
        throw "An unknown remote size must not be treated as a zero-byte match; got $($unknownRemoteSize.Status)."
    }
    Write-Host "  [PASS] Target-folder inventory deduplicated nested files; directories and unknown sizes did not masquerade as zero-byte files." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 5: Test Format Mismatch (PNG vs JPG) Re-transfer
    # --------------------------------------------------------------------------
    Write-Host "  -> Testing format difference detection (photo.png vs photo.jpg)..." -ForegroundColor Yellow
    
    # Record a JPG as confirmed in cloud
    Record-CloudDedupVerifiedFile `
        -AccountId ([string]$testAccount.Id) `
        -ProviderId ([string]$testAccount.ProviderId) `
        -RemotePath 'gallery/photo.jpg' `
        -SizeBytes 5000L `
        -Format 'jpeg'

    # Create local file with same base name but PNG format
    $pngPath = Join-Path $sourceDir 'photo.png'
    [System.IO.File]::WriteAllBytes($pngPath, [byte[]]::new(5000))

    $invMap = Get-RemoteFileInventoryMap -DestinationAccount $testAccount
    $fmtCheck = Classify-TransferCandidate `
        -LocalFilePath $pngPath `
        -DestinationRelativePath 'gallery/photo.png' `
        -RemoteInventoryMap $invMap

    if ($fmtCheck.Status -ne 'New' -and $fmtCheck.Status -ne 'FormatMismatch') {
        throw "Format difference must trigger transfer! Status was: $($fmtCheck.Status)"
    }
    if ($fmtCheck.ShouldTransfer -ne $true) {
        throw "Format difference must set ShouldTransfer = `$true"
    }
    Write-Host "  [PASS] Format difference correctly requires transfer (ShouldTransfer = `$true)." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 6: Test Size Mismatch (Modified File) Re-transfer
    # --------------------------------------------------------------------------
    Write-Host "  -> Testing size modification detection (modified file must be re-sent)..." -ForegroundColor Yellow
    
    # Take an existing confirmed file from the 85 (e.g. document_001.jpg) and modify its size
    $doc1Path = $all100FilePaths[0]
    $origSize = (Get-Item -LiteralPath $doc1Path).Length
    
    # Append 500 bytes to change size
    [System.IO.File]::AppendAllText($doc1Path, ('Z' * 500), [System.Text.Encoding]::UTF8)
    $newSize = (Get-Item -LiteralPath $doc1Path).Length

    $modCheck = Classify-TransferCandidate `
        -LocalFilePath $doc1Path `
        -DestinationRelativePath ([System.IO.Path]::GetFileName($doc1Path)) `
        -RemoteInventoryMap $invMap

    if ($modCheck.Status -ne 'SizeMismatch') {
        throw "Modified file size must be classified as SizeMismatch! Got: $($modCheck.Status)"
    }
    if ($modCheck.ShouldTransfer -ne $true) {
        throw "Size mismatch must set ShouldTransfer = `$true"
    }
    Write-Host "  [PASS] Size mismatch correctly detected ($origSize bytes -> $newSize bytes) and marked for re-transfer." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 7: Test-CloudDedupVerifiedFile Helper Validation
    # --------------------------------------------------------------------------
    Write-Host "  -> Testing Test-CloudDedupVerifiedFile fast-lookup helper..." -ForegroundColor Yellow
    $isDoc2Verified = Test-CloudDedupVerifiedFile `
        -AccountId ([string]$testAccount.Id) `
        -RemotePath ([System.IO.Path]::GetFileName($all100FilePaths[1])) `
        -SizeBytes ([int64](Get-Item -LiteralPath $all100FilePaths[1]).Length)

    if (-not $isDoc2Verified) {
        throw "Test-CloudDedupVerifiedFile should return `$true for verified document_002"
    }

    $isBogusVerified = Test-CloudDedupVerifiedFile `
        -AccountId ([string]$testAccount.Id) `
        -RemotePath 'non_existent_file.pdf' `
        -SizeBytes 1234L

    if ($isBogusVerified) {
        throw "Test-CloudDedupVerifiedFile should return `$false for non-existent file"
    }
    Write-Host "  [PASS] Test-CloudDedupVerifiedFile fast-path lookup validated." -ForegroundColor Green

    Write-Host "`nAll Post-Restart Drop Deduplication tests passed successfully!" -ForegroundColor Green
    exit 0
} finally {
    Set-CloudDedupLedgerPathOverride $null
    Set-TransferQueueFilePath ''
    if (Test-Path -LiteralPath $testDir) {
        try { Remove-Item -LiteralPath $testDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
