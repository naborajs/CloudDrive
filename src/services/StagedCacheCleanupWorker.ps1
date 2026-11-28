Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StagedCacheCleanupWorker = $null

function Start-StagedCacheCleanupWorker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    if ($script:StagedCacheCleanupWorker -or
        -not (Get-Command Start-NSBackgroundOperation -ErrorAction SilentlyContinue)) { return $false }

    $settledStatuses = @('Removed', 'Already missing', 'NotRequired', 'Preserved: staged revision changed', 'Preserved: unverified staged metadata')
    $jobs = [System.Collections.Generic.List[object]]::new()
    $removedQueueItems = $false
    $nowUtc = [DateTime]::UtcNow
    foreach ($job in @($script:CloudTransferQueue)) {
        $cleanupStatus = [string](Get-CloudTransferFieldValue $job 'StagedCleanupStatus')
        if ([bool](Get-CloudTransferFieldValue $job 'ClearWhenStagedCleanupCompletes') -and $cleanupStatus -in $settledStatuses) {
            [void]$script:CloudTransferQueue.Remove($job)
            $removedQueueItems = $true
            continue
        }
        if ([string](Get-CloudTransferFieldValue $job 'Status') -ne 'Completed and remotely confirmed' -or
            -not [bool](Get-CloudTransferFieldValue $job 'RecoveredFromVfsCache') -or
            $cleanupStatus -in $settledStatuses) { continue }

        $retryRaw = Get-CloudTransferFieldValue $job 'StagedCleanupRetryAfterUtc' ''
        $retryUtc = [DateTime]::MinValue
        if ($retryRaw -is [DateTime]) { $retryUtc = ([DateTime]$retryRaw).ToUniversalTime() }
        elseif ($retryRaw -and [DateTime]::TryParse([string]$retryRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$retryUtc)) {
            if ($retryUtc.Kind -ne [DateTimeKind]::Utc) { $retryUtc = $retryUtc.ToUniversalTime() }
        }
        if ($retryUtc -le $nowUtc) { $jobs.Add($job) }
    }
    if ($removedQueueItems) { Save-DurableTransferQueue | Out-Null }
    if ($jobs.Count -eq 0) { return $false }

    try {
        $queuePath = Get-TransferQueueFilePath
        $sharedQueue = $script:CloudTransferQueue
        $script:StagedCacheCleanupWorker = Start-NSBackgroundOperation `
            -ArgumentList @($SourceRoot, $queuePath, $sharedQueue, [object[]]$jobs.ToArray()) `
            -ScriptBlock {
                param([string]$sourceRoot, [string]$queueFile, [object]$queue, [object[]]$cleanupJobs)
                $ErrorActionPreference = 'Stop'
                try {
                    # This operation uses its own runspace. Load the mount module so
                    # cleanup can resolve paths and verify live VFS ownership there.
                    . (Join-Path $sourceRoot 'services\VirtualDriveManager.ps1')
                    . (Join-Path $sourceRoot 'services\CloudTransferManager.ps1')
                    Set-TransferQueueFilePath -Path $queueFile
                    $script:CloudTransferQueue = $queue
                    $script:TransferQueueStateUnavailable = $false
                    foreach ($job in $cleanupJobs) {
                        try {
                            $result = Invoke-ConfirmedStagedVfsSourceCleanup -Job $job
                            if ($result.Success) {
                                $job['StagedCleanupRetryAfterUtc'] = ''
                            } else {
                                $job['StagedCleanupRetryAfterUtc'] = [DateTime]::UtcNow.AddMinutes(1)
                            }
                        } catch {
                            $job['StagedCleanupRetryAfterUtc'] = [DateTime]::UtcNow.AddMinutes(1)
                        }
                    }
                    Save-DurableTransferQueue | Out-Null
                    return [pscustomobject]@{ Success = $true }
                } catch {
                    return [pscustomobject]@{ Success = $false }
                }
            }
        return $true
    } catch {
        $script:StagedCacheCleanupWorker = $null
        return $false
    }
}

function Complete-StagedCacheCleanupWorker {
    if (-not $script:StagedCacheCleanupWorker -or
        -not (Test-NSBackgroundOperationCompleted $script:StagedCacheCleanupWorker)) { return $false }

    $worker = $script:StagedCacheCleanupWorker
    $script:StagedCacheCleanupWorker = $null
    try {
        $completed = Complete-NSBackgroundOperation $worker
        if ($completed.HadErrors -or $completed.Output.Count -eq 0 -or
            -not [bool](Get-SafeProperty $completed.Output[-1] 'Success' $false)) {
            try { Write-NSCloudLog -Severity 'Warning' -Operation 'staged-cache-cleanup' -Message 'Confirmed cache cleanup was deferred; it will retry in the background.' } catch { }
            return $false
        }

        $settledStatuses = @('Removed', 'Already missing', 'NotRequired', 'Preserved: staged revision changed', 'Preserved: unverified staged metadata')
        $removedQueueItems = $false
        foreach ($job in @($script:CloudTransferQueue)) {
            if (-not [bool](Get-CloudTransferFieldValue $job 'ClearWhenStagedCleanupCompletes') -or
                [string](Get-CloudTransferFieldValue $job 'StagedCleanupStatus') -notin $settledStatuses) { continue }
            [void]$script:CloudTransferQueue.Remove($job)
            $removedQueueItems = $true
        }
        if ($removedQueueItems) { Save-DurableTransferQueue | Out-Null }
        return $true
    } catch {
        try { Write-NSCloudLog -Severity 'Warning' -Operation 'staged-cache-cleanup' -Message 'Confirmed cache cleanup was deferred; it will retry in the background.' } catch { }
        return $false
    }
}
