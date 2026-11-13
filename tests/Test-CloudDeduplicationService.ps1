<#
.SYNOPSIS
    Unit test suite for CloudDeduplicationService.ps1.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Testing CloudDeduplicationService..." -ForegroundColor Cyan

$serviceScript = Join-Path $PSScriptRoot '..\src\services\CloudDeduplicationService.ps1'
if (-not (Test-Path -LiteralPath $serviceScript)) {
    Write-Error "FAIL: CloudDeduplicationService.ps1 does not exist"
    exit 1
}
Write-Host "  [PASS] CloudDeduplicationService.ps1 exists" -ForegroundColor Green

. $serviceScript

$testTempDir = Join-Path $env:TEMP ("DedupTest_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testTempDir -Force | Out-Null
$testLedgerPath = Join-Path $testTempDir 'cloud-dedup-ledger.json'
Set-CloudDedupLedgerPathOverride $testLedgerPath

try {
    # 1. Format matching tests
    if (-not (Test-FileFormatMatch 'image.png' 'image.png')) {
        throw "Expected PNG to match PNG"
    }
    if (-not (Test-FileFormatMatch 'photo.jpg' 'photo.jpeg')) {
        throw "Expected JPG to match JPEG"
    }
    if (Test-FileFormatMatch 'photo.png' 'photo.jpg') {
        throw "Expected PNG to NOT match JPG"
    }
    if (Test-FileFormatMatch 'document.pdf' 'document.docx') {
        throw "Expected PDF to NOT match DOCX"
    }
    Write-Host "  [PASS] Format category and extension matching verified (PNG vs JPG, JPEG aliases)" -ForegroundColor Green

    # 2. Candidate classification with Mock Inventory
    $mockInventory = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # Remote has:
    # 1. 'photos/logo.png' (size 1024)
    # 2. 'photos/banner.jpg' (size 2048)
    # 3. 'docs/notes.txt' (size 500)
    $mockInventory['photos/logo.png'] = @{
        Name = 'logo.png'; RelPath = 'photos/logo.png'; SizeBytes = 1024L; Format = 'png'; Extension = '.png'
    }
    $mockInventory['photos/banner.jpg'] = @{
        Name = 'banner.jpg'; RelPath = 'photos/banner.jpg'; SizeBytes = 2048L; Format = 'jpeg'; Extension = '.jpg'
    }
    $mockInventory['docs/notes.txt'] = @{
        Name = 'notes.txt'; RelPath = 'docs/notes.txt'; SizeBytes = 500L; Format = 'txt'; Extension = '.txt'
    }

    # Create local test files
    $localLogo = Join-Path $testTempDir 'logo.png'
    [System.IO.File]::WriteAllBytes($localLogo, [byte[]]::new(1024))

    $localBannerPng = Join-Path $testTempDir 'banner.png'
    [System.IO.File]::WriteAllBytes($localBannerPng, [byte[]]::new(2048))

    $localNotesModified = Join-Path $testTempDir 'notes.txt'
    [System.IO.File]::WriteAllBytes($localNotesModified, [byte[]]::new(999)) # Different size!

    $localNewFile = Join-Path $testTempDir 'new_document.pdf'
    [System.IO.File]::WriteAllBytes($localNewFile, [byte[]]::new(4096))

    # Test Case A: Identical format and size -> AlreadyInCloud (Skip!)
    $resLogo = Classify-TransferCandidate -LocalFilePath $localLogo -DestinationRelativePath 'photos/logo.png' -RemoteInventoryMap $mockInventory
    if ($resLogo.Status -ne 'AlreadyInCloud' -or $resLogo.ShouldTransfer -ne $false) {
        throw "Expected logo.png to be classified as AlreadyInCloud, got $($resLogo.Status)"
    }
    Write-Host "  [PASS] Identical file (same format & size) classified as AlreadyInCloud (Skipped)" -ForegroundColor Green

    # Test Case B: Format mismatch (local PNG vs remote JPG) -> Must re-send!
    $resBanner = Classify-TransferCandidate -LocalFilePath $localBannerPng -DestinationRelativePath 'photos/banner.png' -RemoteInventoryMap $mockInventory
    if ($resBanner.Status -ne 'FormatMismatch' -or $resBanner.ShouldTransfer -ne $true) {
        throw "Expected banner.png to be FormatMismatch against banner.jpg, got $($resBanner.Status)"
    }
    Write-Host "  [PASS] Format difference (PNG vs JPG) correctly detected and marked for transfer" -ForegroundColor Green

    # Test Case C: Size mismatch (same name & format, but local edited to 999 bytes) -> Must re-send!
    $resNotes = Classify-TransferCandidate -LocalFilePath $localNotesModified -DestinationRelativePath 'docs/notes.txt' -RemoteInventoryMap $mockInventory
    if ($resNotes.Status -ne 'SizeMismatch' -or $resNotes.ShouldTransfer -ne $true) {
        throw "Expected notes.txt to be SizeMismatch, got $($resNotes.Status)"
    }
    Write-Host "  [PASS] Size mismatch (modified file) correctly detected and marked for transfer" -ForegroundColor Green

    # Test Case D: Completely new file -> Must send!
    $resNew = Classify-TransferCandidate -LocalFilePath $localNewFile -DestinationRelativePath 'docs/new_document.pdf' -RemoteInventoryMap $mockInventory
    if ($resNew.Status -ne 'New' -or $resNew.ShouldTransfer -ne $true) {
        throw "Expected new_document.pdf to be New, got $($resNew.Status)"
    }
    Write-Host "  [PASS] Completely new file correctly identified for transfer" -ForegroundColor Green

    # 3. Batch classification test
    $batchFiles = @($localLogo, $localBannerPng, $localNotesModified, $localNewFile)
    $mockAccount = @{ Id = 'gdrive_test'; ProviderId = 'gdrive' }

    # Pre-record logo.png in the durable ledger
    Record-CloudDedupVerifiedFile -AccountId 'gdrive_test' -ProviderId 'gdrive' -RemotePath 'photos/logo.png' -SizeBytes 1024L -Format 'png'

    $batchResult = Classify-TransferBatch -FilePaths $batchFiles -DestinationAccount $mockAccount -DestinationFolderPath 'photos' -SourceRootPath $testTempDir
    if ($batchResult.Summary.TotalScanned -ne 4) {
        throw "Batch total scanned expected 4, got $($batchResult.Summary.TotalScanned)"
    }
    if ($batchResult.Summary.AlreadyInCloudCount -ne 1) {
        throw "Batch already in cloud expected 1, got $($batchResult.Summary.AlreadyInCloudCount)"
    }
    if ($batchResult.Summary.FilesToTransferCount -ne 3) {
        throw "Batch to transfer expected 3, got $($batchResult.Summary.FilesToTransferCount)"
    }
    Write-Host "  [PASS] Classify-TransferBatch accurately splits batch into Skipped vs ToTransfer" -ForegroundColor Green

    # 4. Persistence across simulated device restart
    # We clear in-memory state, simulate app relaunch, and verify the ledger reloads and recognizes the files
    Record-CloudDedupVerifiedFile -AccountId 'gdrive_test' -ProviderId 'gdrive' -RemotePath 'docs/document.pdf' -SizeBytes 4096L -Format 'pdf'
    Save-CloudDedupLedger

    # Simulate restart by clearing in-memory cache
    $script:DedupLedgerCache.Clear()
    $script:DedupLedgerLoaded = $false

    # Re-query inventory from cold disk
    $reloadedInventory = Get-RemoteFileInventoryMap -DestinationAccount $mockAccount
    if (-not $reloadedInventory.ContainsKey('docs/document.pdf')) {
        throw "Durable ledger failed to restore 'docs/document.pdf' across process restart"
    }
    $restored = $reloadedInventory['docs/document.pdf']
    if ($restored.SizeBytes -ne 4096L -or $restored.Format -ne 'pdf') {
        throw "Durable ledger restored corrupted file metadata"
    }
    Write-Host "  [PASS] Durable ledger restores cloud inventory across simulated app/device restart" -ForegroundColor Green

    Write-Host "`nAll CloudDeduplicationService tests passed successfully!" -ForegroundColor Green
    exit 0
} finally {
    if (Test-Path -LiteralPath $testTempDir) {
        try { Remove-Item -LiteralPath $testTempDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
