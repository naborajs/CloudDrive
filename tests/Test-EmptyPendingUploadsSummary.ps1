# Unit / Regression Test: Test-EmptyPendingUploadsSummary.ps1
# Verifies that Get-VirtualDrivePendingUploads returns an empty collection (Count = 0)
# and does not produce phantom "1 files remain in transfer processing" items in Get-CloudTransferPendingSummary.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cd_empty_pending_" + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testRoot)

try {
    Write-Host "1. Testing Get-VirtualDrivePendingUploads on empty directory..." -ForegroundColor Yellow
    $pending = @(Get-VirtualDrivePendingUploads -CacheDirectory $testRoot -ActiveCachePaths @())
    if ($pending.Count -ne 0) {
        throw "Expected 0 pending uploads on empty directory, got: $($pending.Count)"
    }
    Write-Host "  [PASS] Get-VirtualDrivePendingUploads returned 0 items on empty cache." -ForegroundColor Green

    Write-Host "2. Testing Get-VirtualDrivePendingUploads on non-existent directory..." -ForegroundColor Yellow
    $nonExistent = Join-Path $testRoot 'non_existent_subdir'
    $pendingNone = @(Get-VirtualDrivePendingUploads -CacheDirectory $nonExistent -ActiveCachePaths @())
    if ($pendingNone.Count -ne 0) {
        throw "Expected 0 pending uploads on non-existent directory, got: $($pendingNone.Count)"
    }
    Write-Host "  [PASS] Get-VirtualDrivePendingUploads returned 0 items on non-existent cache." -ForegroundColor Green

    Write-Host "3. Testing Get-CloudTransferPendingSummary with empty pending array..." -ForegroundColor Yellow
    $summary = Get-CloudTransferPendingSummary -QueueItems @() -StagedFiles $pending
    if ($summary.PendingCount -ne 0) {
        throw "Expected PendingCount=0, got: $($summary.PendingCount)"
    }
    if ($summary.StagedOnlyCount -ne 0) {
        throw "Expected StagedOnlyCount=0, got: $($summary.StagedOnlyCount)"
    }
    if ($summary.TotalTrackedCount -ne 0) {
        throw "Expected TotalTrackedCount=0, got: $($summary.TotalTrackedCount)"
    }
    Write-Host "  [PASS] PendingSummary correctly reported 0 pending files for empty staged array." -ForegroundColor Green

    Write-Host "4. Testing Get-CloudTransferPendingSummary with nested empty collection..." -ForegroundColor Yellow
    $nestedEmpty = @( ,@() )
    $summaryNested = Get-CloudTransferPendingSummary -QueueItems @() -StagedFiles $nestedEmpty
    if ($summaryNested.PendingCount -ne 0) {
        throw "Expected PendingCount=0 with nested empty array, got: $($summaryNested.PendingCount)"
    }
    Write-Host "  [PASS] PendingSummary correctly skipped nested empty collections without generating phantom GUIDs." -ForegroundColor Green

    Write-Host "5. Testing Get-CloudTransferPendingSummary with malformed objects (no path/relative path)..." -ForegroundColor Yellow
    $malformed = @(
        [pscustomobject]@{ SomeOtherProperty = 'test' },
        @{ Foo = 'bar' }
    )
    $summaryMalformed = Get-CloudTransferPendingSummary -QueueItems @() -StagedFiles $malformed
    if ($summaryMalformed.PendingCount -ne 0) {
        throw "Expected PendingCount=0 with malformed items, got: $($summaryMalformed.PendingCount)"
    }
    Write-Host "  [PASS] PendingSummary safely ignored objects lacking path identity." -ForegroundColor Green

    Write-Host "6. Testing Get-CloudTransferPendingSummary with real staged item..." -ForegroundColor Yellow
    $realStaged = @(
        [pscustomobject]@{
            Path = 'C:\fake\staged\test.txt'
            RelativePath = 'test.txt'
            AccountId = 'gdrive_123'
            ProviderId = 'gdrive'
            Length = 100L
            LastWriteTimeUtc = [DateTime]::UtcNow
        }
    )
    $summaryReal = Get-CloudTransferPendingSummary -QueueItems @() -StagedFiles $realStaged
    if ($summaryReal.PendingCount -ne 1) {
        throw "Expected PendingCount=1 for real staged item, got: $($summaryReal.PendingCount)"
    }
    if ($summaryReal.StagedOnlyCount -ne 1) {
        throw "Expected StagedOnlyCount=1 for real staged item, got: $($summaryReal.StagedOnlyCount)"
    }
    Write-Host "  [PASS] Real staged items correctly counted." -ForegroundColor Green

    Write-Host "`nAll Empty Pending Uploads Summary tests passed successfully!" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        try { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
