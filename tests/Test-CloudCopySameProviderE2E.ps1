# Hermetic end-to-end regression for durable same-provider cloud copies.
# rclone's local backend stands in for two folders in one provider account; the
# production queue, live inventory preflight, worker process, and copy command run.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'providers\ProviderContract.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\AdaptiveBandwidthManager.ps1')
. (Join-Path $srcDir 'services\CloudDeduplicationService.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

$rclonePath = Find-RcloneBinary
if (-not $rclonePath -or -not (Test-Path -LiteralPath $rclonePath -PathType Leaf)) {
    throw 'This end-to-end test requires the configured rclone binary.'
}
$script:TestRclonePath = $rclonePath
function Find-RcloneBinary([string]$CustomPath = '') { return $script:TestRclonePath }

$originalLocation = Get-Location
$originalProcessCurrentDirectory = [Environment]::CurrentDirectory
$originalLocalAppData = $env:LOCALAPPDATA
$originalTemp = $env:TEMP
$originalTmp = $env:TMP
$originalTmpDir = $env:TMPDIR
$originalHome = $env:HOME
$originalXdgDataHome = $env:XDG_DATA_HOME
$originalXdgConfigHome = $env:XDG_CONFIG_HOME
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('NSCloudDrive_CloudCopyE2E_' + [Guid]::NewGuid().ToString('N'))
$null = [System.IO.Directory]::CreateDirectory($sandbox)
$env:LOCALAPPDATA = Join-Path $sandbox 'local-app-data'
$env:TEMP = Join-Path $sandbox 'temp'
$env:TMP = $env:TEMP
$env:TMPDIR = $env:TEMP
$env:HOME = Join-Path $sandbox 'home'
$env:XDG_DATA_HOME = Join-Path $env:HOME '.local/share'
$env:XDG_CONFIG_HOME = Join-Path $env:HOME '.config'
$null = [System.IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
$null = [System.IO.Directory]::CreateDirectory($env:TEMP)
$null = [System.IO.Directory]::CreateDirectory($env:XDG_DATA_HOME)
$null = [System.IO.Directory]::CreateDirectory($env:XDG_CONFIG_HOME)

function Get-CloudAccountTransferRemoteEnvironment {
    param([Parameter(Mandatory = $true)][object]$Account, [Parameter(Mandatory = $true)][string]$RemoteAlias)
    $safeAlias = $RemoteAlias.ToUpperInvariant() -replace '[^A-Z0-9_]', '_'
    $remoteEnvironment = @{}
    $remoteEnvironment["RCLONE_CONFIG_${safeAlias}_TYPE"] = 'local'
    return $remoteEnvironment
}

try {
    Set-Location -LiteralPath $sandbox
    [Environment]::CurrentDirectory = $sandbox
    $null = [System.IO.Directory]::CreateDirectory((Join-Path $sandbox 'source/nested'))
    $null = [System.IO.Directory]::CreateDirectory((Join-Path $sandbox 'destination/nested'))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'source/exact.txt'), [System.Text.Encoding]::UTF8.GetBytes('same'))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'destination/exact.txt'), [System.Text.Encoding]::UTF8.GetBytes('same'))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'source/replace.bin'), [System.Text.Encoding]::UTF8.GetBytes('new-size-content'))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'destination/replace.bin'), [System.Text.Encoding]::UTF8.GetBytes('x'))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'source/nested/keep.bin'), [byte[]]@(1, 2, 3))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'destination/nested/keep.bin'), [byte[]]@(1, 2, 3))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'source/nested/new.bin'), [byte[]]@(8, 9, 10, 11))

    $queuePath = Join-Path $sandbox 'queue\transfer-jobs.json'
    Set-TransferQueueFilePath -Path $queuePath
    $script:TransferQueueStateUnavailable = $false
    $script:CloudTransferQueue.Clear()
    $script:ActiveTransferJobs.Clear()

    $sameProviderAccount = @{
        Id = 'same-provider-account'
        ProviderId = 'gdrive'
        DisplayName = 'Hermetic local-backed provider account'
    }

    $scanRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $scanRunspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $scanRunspace.Open()
    $scanPowerShell = [System.Management.Automation.PowerShell]::Create()
    $scanPowerShell.Runspace = $scanRunspace
    $scanPowerShell.AddScript({
        param($moduleRoot, $sourceAccount, $destinationAccount, $runtimePath)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        . (Join-Path $moduleRoot 'services\SettingsManager.ps1')
        . (Join-Path $moduleRoot 'services\CloudTransferManager.ps1')
        $script:TestRclonePath = $runtimePath
        function Find-RcloneBinary([string]$CustomPath = '') { return $script:TestRclonePath }
        function Get-CloudAccountTransferRemoteEnvironment {
            param([object]$Account, [string]$RemoteAlias)
            $safeAlias = $RemoteAlias.ToUpperInvariant() -replace '[^A-Z0-9_]', '_'
            return @{ "RCLONE_CONFIG_${safeAlias}_TYPE" = 'local' }
        }
        Add-CloudTransferRemoteBatch `
            -SourceAccount $sourceAccount `
            -SourcePath 'source' `
            -SourceIsDirectory `
            -DestinationAccount $destinationAccount `
            -DestinationFolderPath 'destination' `
            -ConflictAction 'Skip' `
            -OnlyScan
    }).AddArgument($srcDir).AddArgument($sameProviderAccount).AddArgument($sameProviderAccount).AddArgument($rclonePath) | Out-Null
    $scanHandle = $scanPowerShell.BeginInvoke()
    try {
        if (-not $scanHandle.AsyncWaitHandle.WaitOne(30000)) { throw 'Background cloud inventory scan did not complete within 30 seconds.' }
        $scanOutput = @($scanPowerShell.EndInvoke($scanHandle))
        if ($scanPowerShell.Streams.Error.Count -gt 0) { throw ([string]$scanPowerShell.Streams.Error[0]) }
        if ($scanOutput.Count -ne 1) { throw "Background scan returned $($scanOutput.Count) plans; expected one." }
        $scanPlan = [hashtable]$scanOutput[0]
    } finally {
        $scanPowerShell.Dispose()
        $scanRunspace.Dispose()
    }
    $batch = Add-CloudTransferRemoteBatch `
        -SourceAccount $sameProviderAccount `
        -SourcePath 'source' `
        -SourceIsDirectory `
        -DestinationAccount $sameProviderAccount `
        -DestinationFolderPath 'destination' `
        -ConflictAction 'Skip' `
        -ScanPlan $scanPlan

    if ([int]$batch.TotalFiles -ne 4) { throw "Expected four source files, found $($batch.TotalFiles)." }
    if ([int]$batch.AlreadyPresentCount -ne 2) {
        $queuedPaths = (@($batch.Jobs | ForEach-Object { [string]$_['SourcePath'] }) -join ', ')
        $skippedPaths = (@($batch.SkippedPaths) -join ', ')
        throw "Expected two exact path/size skips, found $($batch.AlreadyPresentCount); skipped: $skippedPaths; queued: $queuedPaths."
    }
    if ([int]$batch.QueuedCount -ne 2) { throw "Expected two per-file queue jobs, found $($batch.QueuedCount)." }
    if (@($script:CloudTransferQueue | Where-Object { $_['OperationType'] -ne 'CloudCopy' }).Count -ne 0) {
        throw 'A same-provider transfer was mislabeled or queued as a non-cloud-copy operation.'
    }
    Write-Host '  [PASS] Same provider, different destination: exact files skipped and changed/new files queued.'

    $terminalJobs = @($script:CloudTransferQueue | Where-Object { $_['BatchId'] -eq $batch.BatchId })
    $terminalJobs[0]['Status'] = 'Failed'
    $terminalJobs[0]['VerificationStatus'] = 'Failed'
    $terminalJobs[1]['Status'] = 'Cancelled'
    $terminalJobs[1]['VerificationStatus'] = 'Cancelled'
    $terminalJobIds = @([string]$terminalJobs[0]['JobId'], [string]$terminalJobs[1]['JobId'])

    $redropBatch = Add-CloudTransferRemoteBatch `
        -SourceAccount $sameProviderAccount `
        -SourcePath 'source' `
        -SourceIsDirectory `
        -DestinationAccount $sameProviderAccount `
        -DestinationFolderPath 'destination' `
        -ConflictAction 'Skip'
    if ([int]$redropBatch.QueuedCount -ne 2 -or [int]$redropBatch.AlreadyQueuedCount -ne 0 -or
        $script:CloudTransferQueue.Count -ne 4) {
        throw 'Re-dropping should retry each terminal file exactly once.'
    }
    foreach ($retryJob in @($redropBatch.Jobs)) {
        if ([string]$retryJob['PreviousJobId'] -notin $terminalJobIds) {
            throw 'A retry created from re-dropping did not link back to a terminal prior attempt.'
        }
    }
    $queueCountAfterRetry = $script:CloudTransferQueue.Count
    $secondRedropBatch = Add-CloudTransferRemoteBatch `
        -SourceAccount $sameProviderAccount `
        -SourcePath 'source' `
        -SourceIsDirectory `
        -DestinationAccount $sameProviderAccount `
        -DestinationFolderPath 'destination' `
        -ConflictAction 'Skip'
    if ([int]$secondRedropBatch.QueuedCount -ne 0 -or [int]$secondRedropBatch.AlreadyQueuedCount -ne 2 -or
        $script:CloudTransferQueue.Count -ne $queueCountAfterRetry) {
        throw 'A second re-drop created duplicate active retries instead of reusing the in-flight jobs.'
    }
    if (@($secondRedropBatch.ExistingJobs | Where-Object { $_['Status'] -in @('Failed', 'Cancelled', 'Superseded') }).Count -gt 0) {
        throw 'Re-drop duplicate reporting pointed to an old terminal attempt instead of the active retry.'
    }
    Write-Host '  [PASS] Re-dropping retries failed/cancelled files once and suppresses duplicate in-flight retries.'

    $sameLocationBatch = Add-CloudTransferRemoteBatch `
        -SourceAccount $sameProviderAccount `
        -SourcePath 'source' `
        -SourceIsDirectory `
        -DestinationAccount $sameProviderAccount `
        -DestinationFolderPath 'source' `
        -ConflictAction 'Skip'
    if ([int]$sameLocationBatch.QueuedCount -ne 0 -or [int]$sameLocationBatch.SameLocationCount -ne 4) {
        throw 'Copying a cloud folder onto itself should be a no-op for every file.'
    }
    Write-Host '  [PASS] Same provider, same account, same path: all files were recognized as no-ops.'

    $null = Process-CloudTransferQueue -MaxConcurrent 2
    $workerBatchIds = @([string]$batch.BatchId, [string]$redropBatch.BatchId)
    $workers = @($script:CloudTransferQueue | Where-Object { $_['BatchId'] -in $workerBatchIds -and $_['Status'] -eq 'Uploading' })
    if ($workers.Count -ne 2) {
        $statusDump = @($script:CloudTransferQueue | ForEach-Object { "batch=$($_['BatchId']) status=$($_['Status']) error=$($_['LastError'])" }) -join '; '
        throw "Expected two launched transfer workers for queued files, found $($workers.Count). Queue: $statusDump"
    }
    foreach ($queueItem in $workers) {
        $activeId = [string]$queueItem['JobId']
        if (-not $script:ActiveTransferJobs.ContainsKey($activeId)) { throw "Worker record '$activeId' was not retained by the transfer manager." }
        $workerProcess = $script:ActiveTransferJobs[$activeId]['Process']
        if ($workerProcess -and -not $workerProcess.WaitForExit(30000)) {
            try { $workerProcess.Kill() } catch { }
            throw "rclone worker '$activeId' did not finish within 30 seconds."
        }
    }

    $null = Process-CloudTransferQueue -MaxConcurrent 2
    foreach ($relativePath in @('destination/replace.bin', 'destination/nested/new.bin')) {
        $path = Join-Path $sandbox $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected transferred destination file '$relativePath'." }
    }
    $replaceBytes = [System.IO.File]::ReadAllBytes((Join-Path $sandbox 'destination/replace.bin'))
    if ([System.Text.Encoding]::UTF8.GetString($replaceBytes) -ne 'new-size-content') {
        throw 'A same-path destination with a different size was not replaced with the source contents.'
    }
    $newBytes = [System.IO.File]::ReadAllBytes((Join-Path $sandbox 'destination/nested/new.bin'))
    if ([System.BitConverter]::ToString($newBytes) -ne '08-09-0A-0B') {
        throw 'The missing nested cloud file was not copied with the expected bytes.'
    }
    Write-Host '  [PASS] Queue workers transferred changed-size and missing files through rclone.'

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) {
        $originalRclonePath = $script:TestRclonePath
        $fakeRclonePath = Join-Path $sandbox 'fake-rclone'
        $fakeRclonePidPath = Join-Path $sandbox 'fake-rclone.pid'
        $fakeRcloneText = "#!/bin/sh`n" + 'echo "$$" > "' + $fakeRclonePidPath + '"' + "`nexec sleep 60`n"
        [System.IO.File]::WriteAllText($fakeRclonePath, $fakeRcloneText, [System.Text.Encoding]::ASCII)
        & chmod +x $fakeRclonePath
        $cancelSource = [System.Threading.CancellationTokenSource]::new()
        $global:CloudDirectoryListingCancellationSource = $cancelSource
        $script:TestRclonePath = $fakeRclonePath
        $listingCancelled = $false
        try {
            $cancelSource.Cancel()
            try {
                Get-CloudDirectoryContents -Account $sameProviderAccount -Path 'source' -BypassLocalMount | Out-Null
            } catch {
                $listingCancelled = $_.Exception.Message -match 'cancelled'
            }
            if (-not $listingCancelled -or -not (Test-Path -LiteralPath $fakeRclonePidPath -PathType Leaf)) {
                throw 'A cancelled cloud listing did not stop at the cancellation checkpoint.'
            }
            $fakeRclonePid = [int](Get-Content -LiteralPath $fakeRclonePidPath -Raw)
            $orphanedProcess = $false
            try {
                $remainingProcess = [System.Diagnostics.Process]::GetProcessById($fakeRclonePid)
                $orphanedProcess = -not $remainingProcess.HasExited
                $remainingProcess.Dispose()
            } catch { }
            if ($orphanedProcess) { throw "Cancelled cloud listing left rclone child process $fakeRclonePid alive." }
        } finally {
            $global:CloudDirectoryListingCancellationSource = $null
            $script:TestRclonePath = $originalRclonePath
            $cancelSource.Dispose()
        }
        Write-Host '  [PASS] Cancelling an in-flight Linux listing terminates its rclone child process.'
    }

    $sourceScopeKey = '{0}:{1}' -f "`0nscd_live_inventory_scope", 'source'
    $destinationScopeKey = '{0}:{1}' -f "`0nscd_live_inventory_scope", 'destination'
    $sourceInventory = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::Ordinal)
    $destinationInventory = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::Ordinal)
    $sourceInventory[$sourceScopeKey] = @{ Source = 'LiveProviderInventory'; RelPath = 'source' }
    $sourceInventory['source/revision.bin'] = @{ IsDirectory = $false; SizeBytes = 4L; ModTime = '2026-01-01T00:00:01.0000000Z' }
    $destinationInventory[$destinationScopeKey] = @{ Source = 'LiveProviderInventory'; RelPath = 'destination' }
    $revisionCheck = Get-RemoteCloudCopyCandidateStatus `
        -SourceInventoryMap $sourceInventory `
        -DestinationInventoryMap $destinationInventory `
        -SourcePath 'source/revision.bin' `
        -DestinationFilePath 'destination/revision.bin' `
        -ExpectedSizeBytes 4L `
        -ExpectedSourceLastWriteUtc '2026-01-01T00:00:00.0000000Z'
    if ([string]$revisionCheck.Status -ne 'SourceChanged') {
        throw 'A same-size remote source revision change was not detected before copy.'
    }
    $sourceInventory['source/revision.bin']['ModTime'] = ''
    $revisionUnavailable = Get-RemoteCloudCopyCandidateStatus `
        -SourceInventoryMap $sourceInventory `
        -DestinationInventoryMap $destinationInventory `
        -SourcePath 'source/revision.bin' `
        -DestinationFilePath 'destination/revision.bin' `
        -ExpectedSizeBytes 4L `
        -ExpectedSourceLastWriteUtc '2026-01-01T00:00:00.0000000Z'
    if ([string]$revisionUnavailable.Status -ne 'Unavailable') {
        throw 'Missing source revision metadata did not fail closed.'
    }
    Write-Host '  [PASS] Same-size source changes are caught by revision metadata before copy.'

    $repeatBatch = Add-CloudTransferRemoteBatch `
        -SourceAccount $sameProviderAccount `
        -SourcePath 'source' `
        -SourceIsDirectory `
        -DestinationAccount $sameProviderAccount `
        -DestinationFolderPath 'destination' `
        -ConflictAction 'Skip'
    if ([int]$repeatBatch.QueuedCount -ne 0 -or [int]$repeatBatch.AlreadyPresentCount -ne 4) {
        throw 'A repeated same-provider batch should skip all four exact destination files.'
    }
    Write-Host '  [PASS] Repeated transfer: all completed destination files were skipped without new jobs.'

    Write-Host 'All same-provider cloud-copy end-to-end checks passed.'
} finally {
    Set-Location -LiteralPath $originalLocation
    [Environment]::CurrentDirectory = $originalProcessCurrentDirectory
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    $env:TMPDIR = $originalTmpDir
    $env:HOME = $originalHome
    $env:XDG_DATA_HOME = $originalXdgDataHome
    $env:XDG_CONFIG_HOME = $originalXdgConfigHome
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
