# ==============================================================================
# NS Cloud Drive - Test Post-Restart Drop Deduplication (100 Files Interruption Scenario)
# Validates:
# 1. 100-file batch where 85 files complete and PC power-off / restart occurs.
# 2. On restart, user drags and drops all 100 files again into the drive.
# 3. Exactly 85 files are identified by name, size, and location and SKIPPED (0 bytes).
# 4. Only the remaining 15 files are queued for transfer.
# 5. Format differences (PNG vs JPG) and size modifications are detected and re-sent.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Testing Post-Restart Drop Deduplication & Restart Recovery ===" -ForegroundColor Cyan

$testDir = Join-Path $env:TEMP "NSCloudDrive_PostRestartDrop_Test_$([Guid]::NewGuid().ToString('N'))"
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
    # Step 2: Initial Session - 85 Files are Transferred & Remotely Confirmed
    # --------------------------------------------------------------------------
    Write-Host "  -> Simulating initial transfer of first 85 files before power interruption..." -ForegroundColor Yellow
    $first85Paths = $all100FilePaths.GetRange(0, 85)

    foreach ($fp in $first85Paths) {
        $fi = [System.IO.FileInfo]::new($fp)
        $rel = $fi.Name
        Record-CloudDedupVerifiedFile `
            -AccountId ([string]$testAccount.Id) `
            -ProviderId ([string]$testAccount.ProviderId) `
            -RemotePath $rel `
            -SizeBytes ([int64]$fi.Length) `
            -Format (Get-FileFormatCategory $fi.Extension) `
            -RemoteHash "hash_$($fi.Name)" `
            -SkipPersist
    }
    Save-CloudDedupLedger

    if (-not (Test-Path -LiteralPath $testLedgerPath)) {
        throw "cloud-dedup-ledger.json was not written to disk!"
    }

    $ledgerContent = Get-Content -LiteralPath $testLedgerPath -Raw | ConvertFrom-Json
    if ($ledgerContent.Count -ne 85) {
        throw "Expected 85 verified entries in ledger, found $($ledgerContent.Count)"
    }
    Write-Host "  [PASS] 85 files durably confirmed and recorded in cloud-dedup-ledger.json." -ForegroundColor Green

    # --------------------------------------------------------------------------
    # Step 3: Simulate Sudden PC Shutdown / Power-off & Machine Restart
    # --------------------------------------------------------------------------
    Write-Host "  -> Simulating machine power-off / restart (clearing volatile memory)..." -ForegroundColor Yellow
    
    # Clear in-memory transfer queues and deduplication cache
    Clear-CloudTransferQueue
    Set-CloudDedupLedgerPathOverride $testLedgerPath
    Set-TransferQueueFilePath $testQueuePath

    # Verify memory is clean but disk ledger persists
    $reloadedLedger = Load-CloudDedupLedger
    if ($reloadedLedger.Keys.Count -ne 85) {
        throw "Reloaded ledger should contain 85 items after restart, found $($reloadedLedger.Keys.Count)"
    }
    Write-Host "  [PASS] Durable ledger loaded 85 confirmed items across simulated restart." -ForegroundColor Green

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

    # CRITICAL USER ASSERTION: Exactly 85 files skipped, remaining 15 queued
    if ($dropResult.SkippedCount -ne 85) {
        throw "CRITICAL FAILURE: Expected exactly 85 files to be skipped, but skipped count was $($dropResult.SkippedCount)!"
    }
    Write-Host "  [PASS] Exactly 85 files identified by name, size, and location and SKIPPED (0 bytes re-transferred)." -ForegroundColor Green

    if ($dropResult.QueuedCount -ne 15) {
        throw "CRITICAL FAILURE: Expected exactly 15 remaining files to be queued, but queued count was $($dropResult.QueuedCount)!"
    }
    Write-Host "  [PASS] Exactly 15 remaining unsent files queued for transfer." -ForegroundColor Green

    # Verify the 15 queued files correspond to documents 086 to 100
    foreach ($qJob in $dropResult.QueuedJobs) {
        $qName = [string]$qJob['FileName']
        $match = [System.Text.RegularExpressions.Regex]::Match($qName, 'document_(\d+)')
        if ($match.Success) {
            $num = [int]$match.Groups[1].Value
            if ($num -lt 86 -or $num -gt 100) {
                throw "Unexpected file queued: $qName (should be between 86 and 100)"
            }
        }
    }
    Write-Host "  [PASS] All queued jobs correctly correspond to the unsent files (document_086 through document_100)." -ForegroundColor Green

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
