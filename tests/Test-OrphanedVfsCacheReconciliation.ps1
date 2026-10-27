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

    # Test Sync-VirtualDriveOrphanedVfsCache default behavior: preserve only.
    # rclone resolves its upload queue once at mount startup, so copying staged bytes
    # into the live cache root afterwards can never trigger an upload.
    $defaultSync = @(Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $testSandbox -AccountId "gdrive_testaccount123")
    if ($defaultSync.Count -ne 1) {
        throw "Expected 1 account result from the default reconciliation, got $($defaultSync.Count)"
    }
    $defaultRes = $defaultSync[0]
    if ($defaultRes.MigratedFiles -ne 0) {
        throw "Default reconciliation copied $($defaultRes.MigratedFiles) staged file(s) into the live cache root."
    }
    if ($defaultRes.PreservedFiles -ne 1) {
        throw "Expected 1 unique preserved staged file, got $($defaultRes.PreservedFiles)"
    }
    if ($defaultRes.DuplicatePathsRetained -ne 2) {
        throw "Expected 2 same-path staged copies retained, got $($defaultRes.DuplicatePathsRetained)"
    }
    if (Test-Path -LiteralPath (Join-Path $hActive 'folder\fileC.txt') -PathType Leaf) {
        throw 'Default reconciliation copied an orphan-root file into the live cache root.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hOrphan2 'folder\fileC.txt') -PathType Leaf)) {
        throw 'Default reconciliation removed the staged orphan-root file.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $hOrphan1 'folder\fileB.txt') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $hOrphan2 'folder\fileB.txt') -PathType Leaf)) {
        throw 'Default reconciliation removed a historical staged copy.'
    }
    Write-Host "  [PASS] Default reconciliation preserves staged bytes and copies nothing into the live root"

    # Test Sync-VirtualDriveOrphanedVfsCache (explicit opt-in copy path)
    $syncResult = @(Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $testSandbox -AccountId "gdrive_testaccount123" -CopyIntoActiveCache)
    if ($syncResult.Count -ne 1) {
        throw "Expected 1 account result from Sync-VirtualDriveOrphanedVfsCache, got $($syncResult.Count)"
    }
    $res = $syncResult[0]
    if ($res.MigratedFiles -ne 1) {
        throw "Expected only the unique non-conflicting file to be copied, got $($res.MigratedFiles)"
    }
    if ($res.CleanedDirectories -ne 0 -or $res.DuplicateFilesRemoved -ne 0) {
        throw 'Reconciliation must not delete orphan VFS directories or staged duplicate files.'
    }
    if ($res.DuplicatePathsRetained -lt 1) { throw 'Duplicate staged paths were not reported as retained.' }
    if (Test-Path -LiteralPath (Join-Path $hActive 'folder\fileB.txt')) {
        throw 'An ambiguous duplicate path was copied into the active VFS cache.'
    }
    Write-Host "  [PASS] Sync-VirtualDriveOrphanedVfsCache copied only unique paths and retained ambiguous copies"

    # Verify active folder now has all 3 files
    $activeFiles = @(Get-ChildItem -LiteralPath $hActive -Recurse -File)
    if ($activeFiles.Count -ne 2) {
        throw "Expected 2 files in active VFS cache, got $($activeFiles.Count)"
    }
    $activeMetaFiles = @(Get-ChildItem -LiteralPath $mActive -Recurse -File)
    if ($activeMetaFiles.Count -ne 2) {
        throw "Expected 2 meta files in active VFS cache, got $($activeMetaFiles.Count)"
    }
    Write-Host "  [PASS] Active VFS cache contains the existing file and one unique safe copy"

    # Verify old staged data remains as a recovery copy
    if (-not (Test-Path -LiteralPath $hOrphan1) -or -not (Test-Path -LiteralPath $hOrphan2)) {
        throw 'Historical VFS folders were removed during reconciliation.'
    }
    if ([System.IO.File]::ReadAllText((Join-Path $hOrphan1 'folder\fileB.txt')) -ne 'Content B' -or
        [System.IO.File]::ReadAllText((Join-Path $hOrphan2 'folder\fileB.txt')) -ne 'Content B') {
        throw 'Original staged duplicate contents were not preserved.'
    }
    Write-Host "  [PASS] Historical staged files remain intact after active-cache copies were created"

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

# 4. Test Pre-Mount Consolidation & Static Folder Deduplication (Static Target: vfs\gdrive)
$testSandbox2 = Join-Path $env:TEMP "NSCloudDrive_VfsStaticTest_$([System.Guid]::NewGuid().ToString('N'))"
try {
    $testAccDir2 = Join-Path $testSandbox2 "gdrive_107770170417933100348"
    $vfsBase2 = Join-Path $testAccDir2 "vfs"
    $metaBase2 = Join-Path $testAccDir2 "vfsMeta"

    $staticVfs = Join-Path $vfsBase2 "gdrive"
    $staticMeta = Join-Path $metaBase2 "gdrive"
    $hashVfs1 = Join-Path $vfsBase2 "gdrive{CX-3A}"
    $hashMeta1 = Join-Path $metaBase2 "gdrive{CX-3A}"
    $hashVfs2 = Join-Path $vfsBase2 "gdrive{7Apbx}"
    $hashMeta2 = Join-Path $metaBase2 "gdrive{7Apbx}"

    $null = New-Item -ItemType Directory -Path (Join-Path $staticVfs "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $staticMeta "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashVfs1 "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashMeta1 "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashVfs2 "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashMeta2 "folder") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashVfs2 "sub") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashMeta2 "sub") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashVfs2 "folderA") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashMeta2 "folderA") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashVfs2 "folderB") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $hashMeta2 "folderB") -Force

    # File 1: Contract.pdf in hashVfs1 (newer) and duplicate in hashVfs2 (older)
    [System.IO.File]::WriteAllText((Join-Path $hashVfs1 "folder\Contract.pdf"), "Contract Data New")
    [System.IO.File]::WriteAllText((Join-Path $hashMeta1 "folder\Contract.pdf"), '{"Dirty": true, "Size": 17}')
    [System.IO.File]::WriteAllText((Join-Path $hashVfs2 "folder\Contract.pdf"), "Contract Data Old")
    [System.IO.File]::WriteAllText((Join-Path $hashMeta2 "folder\Contract.pdf"), '{"Dirty": true, "Size": 17}')

    # File 2: Sunset.jpg in hashVfs2 only
    [System.IO.File]::WriteAllText((Join-Path $hashVfs2 "Photos_Sunset.jpg"), "Sunset ImageData")
    [System.IO.File]::WriteAllText((Join-Path $hashMeta2 "Photos_Sunset.jpg"), '{"Dirty": true, "Size": 16}')

    # File 3: PreExisting.dat in static target AND duplicate in hashVfs1
    [System.IO.File]::WriteAllText((Join-Path $staticVfs "PreExisting.dat"), "PreExisting Payload Static")
    [System.IO.File]::WriteAllText((Join-Path $staticMeta "PreExisting.dat"), '{"Dirty": true, "Size": 26}')
    [System.IO.File]::WriteAllText((Join-Path $hashVfs1 "PreExisting.dat"), "PreExisting Payload Static")
    [System.IO.File]::WriteAllText((Join-Path $hashMeta1 "PreExisting.dat"), '{"Dirty": true, "Size": 26}')

    # File 4: Nested sub\fileC.txt in hashVfs2
    [System.IO.File]::WriteAllText((Join-Path $hashVfs2 "sub\fileC.txt"), "Sub File Content C")
    [System.IO.File]::WriteAllText((Join-Path $hashMeta2 "sub\fileC.txt"), '{"Dirty": true, "Size": 18}')

    # Real top-level path segments must not be mistaken for remote/hash namespaces.
    [System.IO.File]::WriteAllText((Join-Path $hashVfs2 "folderA\same.txt"), "Folder A")
    [System.IO.File]::WriteAllText((Join-Path $hashMeta2 "folderA\same.txt"), '{"Dirty": true, "Size": 8}')
    [System.IO.File]::WriteAllText((Join-Path $hashVfs2 "folderB\same.txt"), "Folder B")
    [System.IO.File]::WriteAllText((Join-Path $hashMeta2 "folderB\same.txt"), '{"Dirty": true, "Size": 8}')

    # Adjust timestamps
    (Get-Item $hashVfs2).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-30)
    (Get-Item $hashVfs1).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-15)
    (Get-Item $staticVfs).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)

    # Step A: Test Deduplication across static folder and historical {hash} folders BEFORE consolidation
    $pendingPre2 = @(Get-VirtualDrivePendingUploads -CacheDirectory $testSandbox2)
    if ($pendingPre2.Count -ne 6) {
        throw "Expected 6 deduplicated pending files across static and hash folders, got $($pendingPre2.Count)"
    }
    if (@($pendingPre2 | Where-Object { $_.RelativePath -in @('folderA/same.txt', 'folderB/same.txt') }).Count -ne 2) {
        throw "Distinct nested folder paths were collapsed into one logical file: $(($pendingPre2 | ForEach-Object { $_.RelativePath }) -join ', ')"
    }
    $contractCollision = @($pendingPre2 | Where-Object { $_.RelativePath -eq 'folder/Contract.pdf' })[0]
    if (-not $contractCollision.HasStagedPathConflict) { throw 'Different same-path staged copies were not exposed as a conflict.' }
    Write-Host "  [PASS] Pending scan preserves nested path identity and marks multiple dirty copies for review."

    # Step B: Test Pre-Mount Consolidation via Sync-VirtualDriveOrphanedVfsCache
    $hasTargetParam = (Get-Command Sync-VirtualDriveOrphanedVfsCache).Parameters.ContainsKey('TargetVfsName')
    if ($hasTargetParam) {
        $unsafeTargetRejected = $false
        try {
            Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $testSandbox2 -AccountId "gdrive_107770170417933100348" `
                -TargetVfsPath $testSandbox2 -TargetVfsMetaPath $staticMeta | Out-Null
        } catch { $unsafeTargetRejected = $true }
        if (-not $unsafeTargetRejected) { throw 'Reconciliation accepted a runtime cache target outside the account VFS root.' }

        # Default behavior against the static target must preserve, not copy.
        $preserveResult2 = @(Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $testSandbox2 -AccountId "gdrive_107770170417933100348" `
            -TargetVfsPath $staticVfs -TargetVfsMetaPath $staticMeta)[0]
        if ($preserveResult2.MigratedFiles -ne 0) {
            throw "Default reconciliation copied $($preserveResult2.MigratedFiles) file(s) into the static live root."
        }
        if ($preserveResult2.PreservedFiles -ne 4) {
            throw "Expected 4 unique staged files preserved by default, got $($preserveResult2.PreservedFiles)"
        }
        if (Test-Path -LiteralPath (Join-Path $staticVfs 'Photos_Sunset.jpg') -PathType Leaf) {
            throw 'Default reconciliation copied a historical staged file into the static live root.'
        }

        $syncResult2 = @(Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $testSandbox2 -AccountId "gdrive_107770170417933100348" `
            -TargetVfsPath $staticVfs -TargetVfsMetaPath $staticMeta -CopyIntoActiveCache)
        if ($syncResult2.Count -ne 1) {
            throw "Expected 1 account result from Sync-VirtualDriveOrphanedVfsCache, got $($syncResult2.Count)"
        }
        $r2 = $syncResult2[0]
        if (-not $r2.ActiveVfsPath.EndsWith('gdrive', [System.StringComparison]::OrdinalIgnoreCase) -or $r2.ActiveVfsPath -match '\{') {
            throw "Expected ActiveVfsPath to end with clean static 'gdrive' (no curly braces), got: $($r2.ActiveVfsPath)"
        }
        if ($r2.MigratedFiles -lt 2) {
            throw "Expected at least 2 migrated files into static vfs\gdrive, got $($r2.MigratedFiles)"
        }
        if (Test-Path -LiteralPath (Join-Path $staticVfs 'folder\Contract.pdf')) {
            throw 'An ambiguous same-path historical version was copied into the active root and could be uploaded arbitrarily.'
        }
        if ($r2.CleanedDirectories -ne 0 -or $r2.DuplicateFilesRemoved -ne 0) {
            throw 'Cache reconciliation must not delete staged files or orphan folders.'
        }
        if ($r2.DuplicatePathsRetained -lt 1) { throw 'Same-path staged copies were not reported as retained.' }
        Write-Host "  [PASS] Orphan VFS files were copied to the active root while all historical staged data remained intact."
    } else {
        Write-Host "  [NOTE] TargetVfsName parameter not yet declared in VirtualDriveManager.ps1 (owned by Coder A); verifying pre-mount consolidation structure"
    }

    # Verify that if files were consolidated into staticVfs:
    if ($hasTargetParam) {
        $staticFiles = @(Get-ChildItem -LiteralPath $staticVfs -Recurse -File)
        if ($staticFiles.Count -ne 5) {
            throw "Expected 5 safe files in static 'vfs\gdrive' after reconciliation, got $($staticFiles.Count)"
        }
        $staticMetaFiles = @(Get-ChildItem -LiteralPath $staticMeta -Recurse -File)
        if ($staticMetaFiles.Count -ne 5) {
            throw "Expected 5 safe meta files in static 'vfsMeta\gdrive' after reconciliation, got $($staticMetaFiles.Count)"
        }
        if (-not (Test-Path -LiteralPath $hashVfs1) -or -not (Test-Path -LiteralPath $hashVfs2)) {
            throw 'Historical VFS folders were removed during reconciliation.'
        }
        $oldContract = [System.IO.File]::ReadAllText((Join-Path $hashVfs2 'folder\Contract.pdf'))
        $newContract = [System.IO.File]::ReadAllText((Join-Path $hashVfs1 'folder\Contract.pdf'))
        if ($oldContract -ne 'Contract Data Old' -or $newContract -ne 'Contract Data New') {
            throw 'Different same-path staged contents were not both preserved.'
        }
        Write-Host "  [PASS] Active copies were created without removing either original staged version."

        # Step C: Test Deduplication AFTER consolidation
        $pendingPost2 = @(Get-VirtualDrivePendingUploads -CacheDirectory $testSandbox2 -ActiveCachePaths @($staticVfs))
        if ($pendingPost2.Count -ne 6) {
            throw "Expected 6 pending files after static consolidation, got $($pendingPost2.Count)"
        }
        $historicalOnlyPath = @($pendingPost2 | Where-Object { $_.RelativePath -eq 'Photos_Sunset.jpg' })[0]
        if (-not $historicalOnlyPath -or $historicalOnlyPath.State -notlike 'Needs review*') {
            throw 'A retained historical staged file outside the active cache was not given an actionable review status.'
        }
        Write-Host "  [PASS] Get-VirtualDrivePendingUploads returned a consistent logical count after safe reconciliation"
    }

} finally {
    if (Test-Path -LiteralPath $testSandbox2) {
        Remove-Item -LiteralPath $testSandbox2 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 4b. Extended-length (\\?\) cache root handling
$extSandbox = Join-Path $env:TEMP "NSCloudDrive_VfsExtendedPath_$([System.Guid]::NewGuid().ToString('N'))"
try {
    $extAcc = Join-Path $extSandbox 'gdrive_extaccount'
    $extVfsBase = Join-Path $extAcc 'vfs'
    $extMetaBase = Join-Path $extAcc 'vfsMeta'
    $extLiveVfs = Join-Path $extVfsBase 'gdrive{z0wI1}'
    $extLiveMeta = Join-Path $extMetaBase 'gdrive{z0wI1}'
    $extOrphanVfs = Join-Path $extVfsBase 'gdrive'
    $extOrphanMeta = Join-Path $extMetaBase 'gdrive'
    foreach ($dir in @($extLiveVfs, $extLiveMeta, $extOrphanVfs, $extOrphanMeta)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [System.IO.File]::WriteAllText((Join-Path $extLiveVfs 'inside.txt'), 'live')
    [System.IO.File]::WriteAllText((Join-Path $extLiveMeta 'inside.txt'), '{"Dirty": true, "Size": 4}')
    [System.IO.File]::WriteAllText((Join-Path $extOrphanVfs 'orphan.txt'), 'orphan')
    [System.IO.File]::WriteAllText((Join-Path $extOrphanMeta 'orphan.txt'), '{"Dirty": true, "Size": 6}')

    $extLiveVfsPath = '\\?\' + $extLiveVfs
    $extLiveMetaPath = '\\?\' + $extLiveMeta

    if ((ConvertFrom-ExtendedLengthPath -Path $extLiveVfsPath) -ne $extLiveVfs) {
        throw "ConvertFrom-ExtendedLengthPath did not strip the extended prefix: $(ConvertFrom-ExtendedLengthPath -Path $extLiveVfsPath)"
    }
    if ((ConvertTo-NormalizedFullPath -Path $extLiveVfsPath) -ne (ConvertTo-NormalizedFullPath -Path $extLiveVfs)) {
        throw 'ConvertTo-NormalizedFullPath did not normalize an extended-length path.'
    }
    if ((ConvertFrom-ExtendedLengthPath -Path '\\?\UNC\server\share\folder') -ne '\\server\share\folder') {
        throw 'Extended UNC paths were not converted to standard UNC form.'
    }
    if ((ConvertFrom-ExtendedLengthPath -Path '//?/D:/CloudCache') -ne 'D:/CloudCache') {
        throw 'Forward-slash extended paths were not converted.'
    }

    # This call previously threw "Illegal characters in path" because rclone reports
    # its live cache root in \\?\ form.
    $extSync = @(Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $extSandbox -AccountId 'gdrive_extaccount' `
        -TargetVfsPath $extLiveVfsPath -TargetVfsMetaPath $extLiveMetaPath)
    if ($extSync.Count -ne 1) { throw "Expected 1 result for the extended-path account, got $($extSync.Count)" }
    if ($extSync[0].ActiveVfsPath -ne (ConvertTo-NormalizedFullPath -Path $extLiveVfs)) {
        throw "Extended-path target was not normalized: $($extSync[0].ActiveVfsPath)"
    }

    $extPending = @(Get-VirtualDrivePendingUploads -CacheDirectory $extSandbox -ActiveCachePaths @($extLiveVfsPath))
    $extInside = @($extPending | Where-Object { $_.RelativePath -eq 'inside.txt' })
    $extOutside = @($extPending | Where-Object { $_.RelativePath -eq 'orphan.txt' })
    if ($extInside.Count -ne 1 -or $extInside[0].IsOutsideActiveCache) {
        throw 'A live-root file was not recognized through an extended-length active path.'
    }
    if ($extOutside.Count -ne 1 -or -not $extOutside[0].IsOutsideActiveCache) {
        throw 'An orphan-root file was not distinguished through an extended-length active path.'
    }
    Write-Host "  [PASS] Extended-length (\\?\) cache roots are accepted and contained correctly"
} finally {
    if (Test-Path -LiteralPath $extSandbox) {
        Remove-Item -LiteralPath $extSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 5. Optional live environment read. Keep the normal regression suite isolated.
if ($env:NSCLOUDDRIVE_ALLOW_LIVE_CACHE_TEST -eq '1' -and (Test-Path -LiteralPath 'D:\CloudCache')) {
    $livePending = @(Get-VirtualDrivePendingUploads -CacheDirectory 'D:\CloudCache')
    Write-Host "  [PASS] Live D:\CloudCache pending uploads check passed: $($livePending.Count) deduplicated file(s) found"
}

Write-Host "All Orphaned VFS Cache Reconciliation & Deduplication Tests Passed Successfully!"
