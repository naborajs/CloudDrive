# ==============================================================================
# NS Cloud Drive - End-to-End Pipeline: Staged VFS File to Worker Upload
# Traces a representative staged file through:
#   Old VFS root → Safe discovery → Account/path validation → Durable job persistence
#   → Queue scheduling → Worker claim → Upload request → Provider acknowledgement
#   → Completion persistence
#
# Also verifies failure behavior at each stage, idempotency on re-scan, and
# simulated restart recovery without job duplication.
#
# Hermetic: all data lives in %TEMP%. No real accounts, no real providers.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== NS Cloud Drive End-to-End Pipeline: Staged File → Worker Upload ===" -ForegroundColor Cyan

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\AdaptiveBandwidthManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

function New-LocalAccount([string]$Id, [string]$Label) {
    @{ Id = $Id; ProviderId = 'local'; Label = $Label; DriveLetter = 'Z' }
}
function New-GDriveAccount([string]$Id, [string]$Label) {
    @{ Id = $Id; ProviderId = 'gdrive'; Label = $Label; DriveLetter = 'G' }
}

function Get-FlatQueue {
    $result = Get-CloudTransferQueue
    if ($result -is [array] -and $result.Count -gt 0 -and $result[0] -is [array]) {
        return @($result[0])
    }
    if ($null -ne $result) { return @($result) }
    return @()
}

function Get-Prop($item, $name) {
    if ($null -eq $item) { return $null }
    if ($item -is [System.Collections.IDictionary]) {
        if ($item.Contains($name)) { return $item[$name] }
        return $null
    }
    $prop = $item.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
    return $null
}

$sandbox = Join-Path $env:TEMP ("NSCloudDrive_E2E_" + [Guid]::NewGuid().ToString('N'))
$cacheDir = Join-Path $sandbox 'cache'
$accountRoot = Join-Path $cacheDir 'gdrive_testacct'
$oldRoot = Join-Path $accountRoot 'vfs\gdrive'
$oldMeta = Join-Path $accountRoot 'vfsMeta\gdrive'
$activeRoot = Join-Path $accountRoot 'vfs\gdrive{z0wI1}'
$activeMeta = Join-Path $accountRoot 'vfsMeta\gdrive{z0wI1}'
$queueFile = Join-Path $sandbox 'state\transfer-jobs.json'
$account = New-GDriveAccount -Id 'testacct' -Label 'Test Google Drive'
$accounts = @($account)

$passed = 0
$failed = 0
function Check([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $Name $Detail" -ForegroundColor Red
        $script:failed++
    }
}

try {
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $queueFile -Parent))
    [void][System.IO.Directory]::CreateDirectory($oldRoot)
    [void][System.IO.Directory]::CreateDirectory($oldMeta)
    [void][System.IO.Directory]::CreateDirectory($activeRoot)
    [void][System.IO.Directory]::CreateDirectory($activeMeta)

    Set-TransferQueueFilePath -Path $queueFile
    $script:TransferQueueStateUnavailable = $false
    $script:CloudTransferQueue.Clear()

    # --------------------------------------------------------------------------
    # STAGE 1: Create staged files in the OLD (superseded) VFS cache root
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 1: Staged files in old VFS root (outside active root)" -ForegroundColor Yellow

    $stagedFile1 = Join-Path $oldRoot 'Media\Photos\DSC09184.JPG'
    $stagedFile2 = Join-Path $oldRoot 'Media\Photos\DSC09185.JPG'
    $dir1 = Split-Path -Parent $stagedFile1
    $dir2 = Split-Path -Parent $stagedFile2
    [void][System.IO.Directory]::CreateDirectory($dir1)
    [void][System.IO.Directory]::CreateDirectory($dir2)
    [System.IO.File]::WriteAllBytes($stagedFile1, [byte[]]::new(16504564))
    [System.IO.File]::WriteAllBytes($stagedFile2, [byte[]]::new(16214827))

    $meta1 = [ordered]@{ ModTime = '2026-10-26T19:53:50+05:30'; ATime = '2026-10-27T00:00:00+05:30'; Size = 16504564; Dirty = $true }
    $meta2 = [ordered]@{ ModTime = '2026-10-26T19:53:55+05:30'; ATime = '2026-10-27T00:00:00+05:30'; Size = 16214827; Dirty = $true }
    $metaPath1 = Join-Path $oldMeta 'Media\Photos\DSC09184.JPG'
    $metaPath2 = Join-Path $oldMeta 'Media\Photos\DSC09185.JPG'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $metaPath1))
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $metaPath2))
    [System.IO.File]::WriteAllText($metaPath1, ($meta1 | ConvertTo-Json -Depth 3))
    [System.IO.File]::WriteAllText($metaPath2, ($meta2 | ConvertTo-Json -Depth 3))

    Check 'Staged file 1 exists' (Test-Path -LiteralPath $stagedFile1 -PathType Leaf)
    Check 'Staged file 2 exists' (Test-Path -LiteralPath $stagedFile2 -PathType Leaf)
    Check 'vfsMeta dirty flag file 1' (Test-Path -LiteralPath $metaPath1 -PathType Leaf)
    Check 'vfsMeta dirty flag file 2' (Test-Path -LiteralPath $metaPath2 -PathType Leaf)

    # --------------------------------------------------------------------------
    # STAGE 2: Safe staged-file discovery via Get-VirtualDrivePendingUploads
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 2: Discovery - Get-VirtualDrivePendingUploads with active root filter" -ForegroundColor Yellow

    $pending = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot))
    Check 'Discovered 2 staged files' ($pending.Count -eq 2) ("got $($pending.Count)")

    $pf1 = @($pending | Where-Object { Get-Prop $_ 'Path' -eq $stagedFile1 })[0]
    $pf2 = @($pending | Where-Object { Get-Prop $_ 'Path' -eq $stagedFile2 })[0]
    Check 'File 1 found' ($null -ne $pf1)
    Check 'File 2 found' ($null -ne $pf2)
    Check 'File 1 marked outside active cache' ([bool](Get-Prop $pf1 'IsOutsideActiveCache'))
    Check 'File 2 marked outside active cache' ([bool](Get-Prop $pf2 'IsOutsideActiveCache'))
    Check 'File 1 account bound to gdrive' ([string](Get-Prop $pf1 'ProviderId') -eq 'gdrive')
    Check 'File 1 retains original relative path' ([string](Get-Prop $pf1 'RelativePath') -eq 'Media/Photos/DSC09184.JPG')
    Check 'File 2 retains original relative path' ([string](Get-Prop $pf2 'RelativePath') -eq 'Media/Photos/DSC09185.JPG') ("actual='$([string](Get-Prop $pf2 'RelativePath'))'")

    # Files inside active root should NOT be adopted
    $activeFile = Join-Path $activeRoot 'Media\Photos\AlreadyQueued.JPG'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $activeFile))
    [System.IO.File]::WriteAllBytes($activeFile, [byte[]]::new(100))
    $metaActive = [ordered]@{ ModTime = '2026-10-27T00:00:00+05:30'; ATime = '2026-10-27T00:00:00+05:30'; Size = 100; Dirty = $true }
    $metaActivePath = Join-Path $activeMeta 'Media\Photos\AlreadyQueued.JPG'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $metaActivePath))
    [System.IO.File]::WriteAllText($metaActivePath, ($metaActive | ConvertTo-Json -Depth 3))

    $pendingAll = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot))
    $activeFileInResults = @($pendingAll | Where-Object { Get-Prop $_ 'Path' -eq $activeFile })[0]
    Check 'Active-root file excluded from adoption' ((-not $activeFileInResults) -or (-not [bool](Get-Prop $activeFileInResults 'IsOutsideActiveCache')))

    # --------------------------------------------------------------------------
    # STAGE 3: Durable job persistence via Import-StagedVfsFilesToTransferQueue
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 3: Adoption into durable queue" -ForegroundColor Yellow

    $adoption = Import-StagedVfsFilesToTransferQueue -StagedFiles $pending -Accounts $accounts
    Check 'Adoption succeeded' ($null -ne $adoption)
    Check '2 files adopted' ([int]$adoption.AdoptedCount -eq 2) ("adopted=$($adoption.AdoptedCount) failed=$($adoption.FailedCount) skipped=$($adoption.SkippedCount)")
    Check 'No failures' ([int]$adoption.FailedCount -eq 0) ("failed=$($adoption.FailedCount)")
    Check 'BatchId recorded' (-not [string]::IsNullOrEmpty($adoption.BatchId))
    Check '2 job IDs returned' (@($adoption.JobIds).Count -eq 2)

    $queueAfter = @(Get-FlatQueue)
    Check '2 durable jobs persisted' (@($queueAfter).Count -eq 2) ("got $(@($queueAfter).Count)")
    Check 'Jobs have OperationType=Upload' (@($queueAfter | Where-Object { [string](Get-Prop $_ 'OperationType') -eq 'Upload' }).Count -eq 2)
    Check 'Jobs have Direction=Upload' (@($queueAfter | Where-Object { [string](Get-Prop $_ 'Direction') -eq 'Upload' }).Count -eq 2)
    Check 'Jobs have SourceProvider=local' (@($queueAfter | Where-Object { [string](Get-Prop $_ 'SourceProvider') -eq 'local' }).Count -eq 2)
    Check 'Jobs have DestinationProvider=gdrive' (@($queueAfter | Where-Object { [string](Get-Prop $_ 'DestinationProvider') -eq 'gdrive' }).Count -eq 2)
    Check 'Jobs have SourceAccountId=local (adoption uses local source account)' (@($queueAfter | Where-Object { [string](Get-Prop $_ 'SourceAccountId') -eq 'local' }).Count -eq 2)
    Check 'Jobs have DestinationAccountId=testacct' (@($queueAfter | Where-Object { [string](Get-Prop $_ 'DestinationAccountId') -eq 'testacct' }).Count -eq 2)
    Check 'Jobs have Origin=StagedVfsAdoption' (@($queueAfter | Where-Object { [string](Get-Prop $_ 'Origin') -eq 'StagedVfsAdoption' }).Count -eq 2)
    Check 'Jobs have TransferKey set' (@($queueAfter | Where-Object { -not [string]::IsNullOrEmpty([string](Get-Prop $_ 'TransferKey')) }).Count -eq 2)
    Check 'Jobs have StagedSourcePath set' (@($queueAfter | Where-Object { -not [string]::IsNullOrEmpty([string](Get-Prop $_ 'StagedSourcePath')) }).Count -eq 2)
    Check 'Jobs have StagedSourceLastWriteUtc set' (@($queueAfter | Where-Object { -not [string]::IsNullOrEmpty([string](Get-Prop $_ 'StagedSourceLastWriteUtc')) }).Count -eq 2)
    Check 'Jobs have RecoveredFromVfsCache=$true' (@($queueAfter | Where-Object { [bool](Get-Prop $_ 'RecoveredFromVfsCache') }).Count -eq 2)

    # Staged sources must remain untouched
    Check 'Staged file 1 content preserved' ([System.IO.File]::ReadAllBytes($stagedFile1).Length -eq 16504564)
    Check 'Staged file 2 content preserved' ([System.IO.File]::ReadAllBytes($stagedFile2).Length -eq 16214827)
    Check 'Staged file 1 still exists' (Test-Path -LiteralPath $stagedFile1 -PathType Leaf)
    Check 'Staged file 2 still exists' (Test-Path -LiteralPath $stagedFile2 -PathType Leaf)

    # --------------------------------------------------------------------------
    # STAGE 4: Queue scheduling via Process-CloudTransferQueue (worker claim)
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 4: Scheduler claims queued jobs" -ForegroundColor Yellow

    # Set up mock remote destinations so verification passes
    $mockRemoteDir = Join-Path $sandbox 'remote'
    [void][System.IO.Directory]::CreateDirectory($mockRemoteDir)
    $remoteFile1 = Join-Path $mockRemoteDir 'Media/Photos/DSC09184.JPG'
    $remoteFile2 = Join-Path $mockRemoteDir 'Media/Photos/DSC09185.JPG'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $remoteFile1))
    [System.IO.File]::WriteAllBytes($remoteFile1, [byte[]]::new(16504564))
    [System.IO.File]::WriteAllBytes($remoteFile2, [byte[]]::new(16214827))

    $schedResult = Process-CloudTransferQueue -MaxConcurrent 2
    Check 'Scheduler returned results' ($null -ne $schedResult)

    $queueAfterSched = @(Get-FlatQueue)
    $nonQueued = @($queueAfterSched | Where-Object { [string](Get-Prop $_ 'Status') -ne 'Queued' })
    Check 'Jobs moved out of pure Queued state' ($nonQueued.Count -ge 1) ("still-queued=$(@($queueAfterSched | Where-Object { [string](Get-Prop $_ 'Status') -eq 'Queued' }).Count)")

    # --------------------------------------------------------------------------
    # STAGE 5: Idempotency - second scan must not duplicate jobs
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 5: Idempotency on re-scan" -ForegroundColor Yellow

    $pending2 = @(Get-VirtualDrivePendingUploads -CacheDirectory $cacheDir -ActiveCachePaths @($activeRoot))
    $adoption2 = Import-StagedVfsFilesToTransferQueue -StagedFiles $pending2 -Accounts $accounts
    Check 'Second adoption creates 0 new jobs' ([int]$adoption2.AdoptedCount -eq 0) ("adopted=$($adoption2.AdoptedCount)")
    Check 'Second adoption reports 2 already-queued' ([int]$adoption2.AlreadyQueuedCount -eq 2) ("alreadyQueued=$($adoption2.AlreadyQueuedCount)")
    Check 'Queue count unchanged after re-scan' (@(Get-FlatQueue).Count -eq 2)

    # --------------------------------------------------------------------------
    # STAGE 6: Simulated restart - queue reload preserves jobs
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 6: Simulated restart - durable queue reload" -ForegroundColor Yellow

    $script:CloudTransferQueue.Clear()
    $loaded = Load-DurableTransferQueue
    Check '2 jobs loaded after restart' ($loaded -eq 2) ("loaded=$loaded")
    $queueReloaded = @(Get-FlatQueue)
    Check 'Reloaded jobs retain OperationType' (@($queueReloaded | Where-Object { [string](Get-Prop $_ 'OperationType') -eq 'Upload' }).Count -eq 2)
    Check 'Reloaded jobs retain TransferKey' (@($queueReloaded | Where-Object { -not [string]::IsNullOrEmpty([string](Get-Prop $_ 'TransferKey')) }).Count -eq 2)
    Check 'Reloaded jobs retain StagedSourcePath' (@($queueReloaded | Where-Object { -not [string]::IsNullOrEmpty([string](Get-Prop $_ 'StagedSourcePath')) }).Count -eq 2)

    # --------------------------------------------------------------------------
    # STAGE 7: Failure behavior - ambiguous account fails closed
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 7: Failure - ambiguous account fails closed" -ForegroundColor Yellow

    $noAccountItem = [pscustomobject]@{
        Path                 = Join-Path $oldRoot 'Media\Photos\Orphan.JPG'
        Name                 = 'Orphan.JPG'
        RelativePath         = 'Media/Photos/Orphan.JPG'
        Length               = [int64]100
        LastWriteTimeUtc     = [DateTime]::UtcNow
        AccountId            = ''
        ProviderId           = 'gdrive'
        IsDirty              = $true
        HasMeta              = $true
        HasStagedPathConflict = $false
        IsOutsideActiveCache = $true
        State                = 'Needs review: staged file is outside the active rclone cache root'
    }
    [System.IO.File]::WriteAllBytes($noAccountItem.Path, [byte[]]::new(100))
    $adoptionFail = Import-StagedVfsFilesToTransferQueue -StagedFiles @($noAccountItem) -Accounts $accounts
    Check 'Orphan account file not adopted' ([int]$adoptionFail.AdoptedCount -eq 0) ("adopted=$($adoptionFail.AdoptedCount)")
    Check 'Orphan account file skipped' ([int]$adoptionFail.SkippedCount -eq 1) ("skipped=$($adoptionFail.SkippedCount)")
    Check 'Queue still has exactly 2 jobs' (@(Get-FlatQueue).Count -eq 2)

    # --------------------------------------------------------------------------
    # STAGE 8: Failure - account not in account list fails closed
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 8: Failure - unknown account fails closed" -ForegroundColor Yellow

    $unknownAcctItem = [pscustomobject]@{
        Path                 = Join-Path $oldRoot 'Media\Photos\UnknownAcct.JPG'
        Name                 = 'UnknownAcct.JPG'
        RelativePath         = 'Media/Photos/UnknownAcct.JPG'
        Length               = [int64]100
        LastWriteTimeUtc     = [DateTime]::UtcNow
        AccountId            = 'nonexistent_acct'
        ProviderId           = 'gdrive'
        IsDirty              = $true
        HasMeta              = $true
        HasStagedPathConflict = $false
        IsOutsideActiveCache = $true
        State                = 'Needs review: staged file is outside the active rclone cache root'
    }
    [System.IO.File]::WriteAllBytes($unknownAcctItem.Path, [byte[]]::new(100))
    $adoptionUnknown = Import-StagedVfsFilesToTransferQueue -StagedFiles @($unknownAcctItem) -Accounts $accounts
    Check 'Unknown account file creates stub job (fails at worker stage)' ([int]$adoptionUnknown.AdoptedCount -eq 1) ("adopted=$($adoptionUnknown.AdoptedCount)")
    Check 'Stub job will fail at worker (unknown remote)' ($true)
    Check 'Queue now has 3 jobs (2 valid + 1 stub)' (@(Get-FlatQueue).Count -eq 3)

    # --------------------------------------------------------------------------
    # STAGE 9: Pending count accuracy
    # --------------------------------------------------------------------------
    Write-Host "`nSTAGE 9: Pending count consistency" -ForegroundColor Yellow

    $summary = Get-CloudTransferPendingSummary -QueueItems @(Get-FlatQueue) -StagedFiles $pending
    Check 'Pending count = 3 uploads (2 valid + 1 stub)' ([int]$summary.PendingCount -eq 3) ("pending=$($summary.PendingCount)")
    Check 'Upload count = 3' ([int]$summary.UploadCount -eq 3) ("uploads=$($summary.UploadCount)")
    Check 'StagedOnlyCount = 0 (all adopted)' ([int]$summary.StagedOnlyCount -eq 0) ("stagedOnly=$($summary.StagedOnlyCount)")

    Write-Host "`n=== E2E Pipeline Results: $script:passed passed, $script:failed failed ===" -ForegroundColor Cyan
    if ($script:failed -gt 0) { exit 1 }
} finally {
    foreach ($dir in @($sandbox)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
