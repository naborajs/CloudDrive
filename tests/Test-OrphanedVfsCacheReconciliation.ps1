# ------------------------------------------------------------------------------
# Test-OrphanedVfsCacheReconciliation.ps1
# Unit & integration tests for VFS cache deduplication and reconciliation
# ------------------------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Starting Orphaned VFS Cache Reconciliation & Deduplication Tests..."

# 1. Load module under Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')

Write-Host "  [PASS] VirtualDriveManager.ps1 loaded cleanly under Set-StrictMode -Version Latest"

# 2. Test Get-VirtualDriveVfsStats property structure
$emptyStats = Get-VirtualDriveVfsStats -DriveLetter ''
if (-not $emptyStats.Contains('DiskCachePath') -or -not $emptyStats.Contains('DiskCacheMetaPath')) {
    throw "Get-VirtualDriveVfsStats does not return DiskCachePath or DiskCacheMetaPath in fallback hashtable"
}
Write-Host "  [PASS] Get-VirtualDriveVfsStats fallback structure includes DiskCachePath and DiskCacheMetaPath"

# 3. Test Deduplication in Sandbox Environment
$testSandbox = Join-Path $env:TEMP "NSCloudDrive_VfsTest_$([System.Guid]::NewGuid().ToString('N'))"
try {
    $testAccDir = Join-Path $testSandbox "gdrive_testaccount123"
    $vfsBase = Join-Path $testAccDir "vfs"
    $metaBase = Join-Path $testAccDir "vfsMeta"

    $hActive = Join-Path $vfsBase "gdrive{active01}"
    $hOrphan1 = Join-Path $vfsBase "gdrive{orphan01}"
    $hOrphan2 = Join-Path $vfsBase "gdrive{orphan02}"

    $mActive = Join-Path $metaBase "gdrive{active01}"
    $mOrphan1 = Join-Path $metaBase "gdrive{orphan01}"
    $mOrphan2 = Join-Path $metaBase "gdrive{orphan02}"

    $null = New-Item -ItemType Directory -Path (Join-Path $hActive "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hOrphan1 "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hOrphan2 "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $mActive "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $mOrphan1 "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $mOrphan2 "folder") -Force

    # Staged dirty files:
    # fileA.txt in active
    [System.IO.File]::WriteAllText((Join-Path $hActive "folder\fileA.txt"), "Content A")
    [System.IO.File]::WriteAllText((Join-Path $mActive "folder\fileA.txt"), '{"Dirty": true, "Size": 9}')

    # fileB.txt in orphan1
    [System.IO.File]::WriteAllText((Join-Path $hOrphan1 "folder\fileB.txt"), "Content B")
    [System.IO.File]::WriteAllText((Join-Path $mOrphan1 "folder\fileB.txt"), '{"Dirty": true, "Size": 9}')

    # fileB.txt duplicate in orphan2 (same size)
    [System.IO.File]::WriteAllText((Join-Path $hOrphan2 "folder\fileB.txt"), "Content B")
    [System.IO.File]::WriteAllText((Join-Path $mOrphan2 "folder\fileB.txt"), '{"Dirty": true, "Size": 9}')

    # fileC.txt in orphan2 only
    [System.IO.File]::WriteAllText((Join-Path $hOrphan2 "folder\fileC.txt"), "Content C")
    [System.IO.File]::WriteAllText((Join-Path $mOrphan2 "folder\fileC.txt"), '{"Dirty": true, "Size": 9}')

    # Set write times so active is newest
    (Get-Item $hOrphan1).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-30)
    (Get-Item $hOrphan2).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-20)
    (Get-Item $hActive).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)

    # Test Deduplication BEFORE reconciliation
    $pendingPre = @(Get-VirtualDrivePendingUploads -CacheDirectory $testSandbox)
    if ($pendingPre.Count -ne 3) {
        throw "Expected 3 deduplicated pending files across 3 hash folders, got $($pendingPre.Count)"
    }
    Write-Host "  [PASS] Get-VirtualDrivePendingUploads deduplication verified (3 unique files returned instead of 4 raw files)"

    # Test Sync-VirtualDriveOrphanedVfsCache
    $syncResult = @(Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $testSandbox -AccountId "gdrive_testaccount123")
    if ($syncResult.Count -ne 1) {
        throw "Expected 1 account result from Sync-VirtualDriveOrphanedVfsCache, got $($syncResult.Count)"
    }
    $res = $syncResult[0]
    if ($res.MigratedFiles -lt 2) {
        throw "Expected at least 2 migrated files, got $($res.MigratedFiles)"
    }
    if ($res.CleanedDirectories -ne 2) {
        throw "Expected 2 cleaned orphan directories, got $($res.CleanedDirectories)"
    }
    Write-Host "  [PASS] Sync-VirtualDriveOrphanedVfsCache migrated files and cleaned 2 orphan directories"

    # Verify active folder now has all 3 files
    $activeFiles = @(Get-ChildItem -LiteralPath $hActive -Recurse -File)
    if ($activeFiles.Count -ne 3) {
        throw "Expected 3 files in active VFS cache, got $($activeFiles.Count)"
    }
    $activeMetaFiles = @(Get-ChildItem -LiteralPath $mActive -Recurse -File)
    if ($activeMetaFiles.Count -ne 3) {
        throw "Expected 3 meta files in active VFS cache, got $($activeMetaFiles.Count)"
    }
    Write-Host "  [PASS] Active VFS cache verified containing 3 files and 3 meta files"

    # Verify orphan folders were removed
    if (Test-Path -LiteralPath $hOrphan1) { throw "hOrphan1 should have been removed" }
    if (Test-Path -LiteralPath $hOrphan2) { throw "hOrphan2 should have been removed" }
    Write-Host "  [PASS] Orphan VFS folders were completely removed"

    # Test Deduplication AFTER reconciliation
    $pendingPost = @(Get-VirtualDrivePendingUploads -CacheDirectory $testSandbox)
    if ($pendingPost.Count -ne 3) {
        throw "Expected 3 pending files after reconciliation, got $($pendingPost.Count)"
    }
    Write-Host "  [PASS] Get-VirtualDrivePendingUploads returned consistent 3 files after reconciliation"

} finally {
    if (Test-Path -LiteralPath $testSandbox) {
        Remove-Item -LiteralPath $testSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 4. Live Environment Verification on D:\CloudCache if present
if (Test-Path -LiteralPath 'D:\CloudCache') {
    $livePending = @(Get-VirtualDrivePendingUploads -CacheDirectory 'D:\CloudCache')
    Write-Host "  [PASS] Live D:\CloudCache pending uploads check passed: $($livePending.Count) deduplicated file(s) found"
}

Write-Host "All Orphaned VFS Cache Reconciliation & Deduplication Tests Passed Successfully!"
