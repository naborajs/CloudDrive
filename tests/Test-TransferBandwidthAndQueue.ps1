<#
.SYNOPSIS
    Test suite for NS Cloud Drive Transfer Stalls Resolution, User-Controlled Bandwidth,
    and Resilient Transfer Queue (TASK-005).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== NS Cloud Drive Transfer Bandwidth & Resilient Queue Test Suite ===" -ForegroundColor Cyan

. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\AdaptiveBandwidthManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')

# ==============================================================================
# 1. SETTINGS & EFFECTIVE BANDWIDTH LIMITS
# ==============================================================================
Write-Host "`n1. Testing Bandwidth Policies & Preset Mapping..." -ForegroundColor Yellow

$defaultSettings = Get-DefaultSettings
if ($defaultSettings.BandwidthPolicy -ne 'Unlimited') {
    throw "Expected default BandwidthPolicy to be 'Unlimited', got '$($defaultSettings.BandwidthPolicy)'"
}
if ($defaultSettings.BandwidthLimitPreset -ne '5 MB/s') {
    throw "Expected default BandwidthLimitPreset to be '5 MB/s', got '$($defaultSettings.BandwidthLimitPreset)'"
}
Write-Host "  [PASS] Default BandwidthPolicy ('Unlimited') and Preset ('5 MB/s') verified." -ForegroundColor Green

# Test policy mapping to rclone bwlimit rate strings
$unlimitedRate = Get-EffectiveBandwidthLimitRate @{ BandwidthPolicy = 'Unlimited' }
if ($unlimitedRate -ne 'off') { throw "Unlimited expected 'off', got '$unlimitedRate'" }

$minimalRate = Get-EffectiveBandwidthLimitRate @{ BandwidthPolicy = 'MinimalBackground' }
if ($minimalRate -ne '256k') { throw "MinimalBackground expected '256k', got '$minimalRate'" }

$presetMap = @{
    '256 KB/s' = '256k'
    '512 KB/s' = '512k'
    '1 MB/s'   = '1M'
    '2 MB/s'   = '2M'
    '5 MB/s'   = '5M'
    '10 MB/s'  = '10M'
}
foreach ($p in $presetMap.Keys) {
    $expected = $presetMap[$p]
    $actual = Get-EffectiveBandwidthLimitRate @{ BandwidthPolicy = 'Limited'; BandwidthLimitPreset = $p }
    if ($actual -ne $expected) {
        throw "Limited preset '$p' expected '$expected', got '$actual'"
    }
}
Write-Host "  [PASS] Limited bandwidth presets (256k - 10M) mapped accurately." -ForegroundColor Green

# Test custom rate format
$customMb = Get-EffectiveBandwidthLimitRate @{ BandwidthPolicy = 'Limited'; BandwidthLimitPreset = 'Custom'; CustomUploadLimitValue = 15; CustomUploadLimitUnit = 'MB/s' }
if ($customMb -ne '15M') { throw "Custom MB/s expected '15M', got '$customMb'" }

$customKb = Get-EffectiveBandwidthLimitRate @{ BandwidthPolicy = 'Custom'; CustomUploadLimitValue = 850; CustomUploadLimitUnit = 'KB/s' }
if ($customKb -ne '850k') { throw "Custom KB/s expected '850k', got '$customKb'" }
Write-Host "  [PASS] Custom bandwidth values (MB/s and KB/s) formatted correctly." -ForegroundColor Green

# ==============================================================================
# 2. VIRTUAL DRIVE MOUNT ARGUMENTS TUNING
# ==============================================================================
Write-Host "`n2. Testing Virtual Drive Mount Tuning & Concurrency Arguments..." -ForegroundColor Yellow

# Test poll and writeback intervals
$gdArgs = Build-RcloneMountArguments -RemoteName 'gdrive_primary' -DriveLetter 'G' -InitialBwLimit '2M'
$pollIdx = $gdArgs.IndexOf('--vfs-cache-poll-interval')
if ($pollIdx -lt 0 -or $gdArgs[$pollIdx + 1] -ne '2s') {
    throw "Expected --vfs-cache-poll-interval 2s, got '$($gdArgs[$pollIdx + 1])'"
}
$wbIdx = $gdArgs.IndexOf('--vfs-write-back')
if ($wbIdx -lt 0 -or $gdArgs[$wbIdx + 1] -ne '1s') {
    throw "Expected --vfs-write-back 1s, got '$($gdArgs[$wbIdx + 1])'"
}
Write-Host "  [PASS] VFS poll interval (2s) and writeback latency (1s) verified." -ForegroundColor Green

# Test provider tuning: Google Drive chunk size, upload cutoff, transfers
if ($gdArgs -notcontains '--drive-chunk-size' -or $gdArgs[$gdArgs.IndexOf('--drive-chunk-size') + 1] -ne '32M') {
    throw "Expected Google Drive --drive-chunk-size 32M"
}
if ($gdArgs -notcontains '--drive-upload-cutoff' -or $gdArgs[$gdArgs.IndexOf('--drive-upload-cutoff') + 1] -ne '32M') {
    throw "Expected Google Drive --drive-upload-cutoff 32M"
}
if ($gdArgs[$gdArgs.IndexOf('--transfers') + 1] -ne '4') {
    throw "Expected Google Drive --transfers 4"
}
if ($gdArgs[$gdArgs.IndexOf('--bwlimit') + 1] -ne '2M') {
    throw "Expected InitialBwLimit 2M to be present"
}
Write-Host "  [PASS] Google Drive streaming tuning (32M chunks, 4 transfers, 2M bwlimit) verified." -ForegroundColor Green

# Test provider tuning: TeraBox transfers (2 workers to avoid 429 locks)
$tbArgs = Build-RcloneMountArguments -RemoteName 'terabox_personal' -DriveLetter 'T'
if ($tbArgs[$tbArgs.IndexOf('--transfers') + 1] -ne '2') {
    throw "Expected TeraBox --transfers 2"
}
if ($tbArgs -contains '--bwlimit') {
    throw "Did not expect --bwlimit when InitialBwLimit is default empty"
}
Write-Host "  [PASS] TeraBox concurrency tuning (2 transfers) verified." -ForegroundColor Green

# ==============================================================================
# 3. ADAPTIVE BANDWIDTH MANAGER CONGESTION ISOLATION
# ==============================================================================
Write-Host "`n3. Testing Adaptive Bandwidth Congestion Controller..." -ForegroundColor Yellow

# When policy is Unlimited, MinimalBackground, or Limited, it should NOT throttle based on latency probes
$checkUnlimited = Invoke-AdaptiveBandwidthCheck -Settings @{ BandwidthPolicy = 'Unlimited' }
if ($checkUnlimited.AppliedRate -ne 'off' -or $checkUnlimited.IsCongested) {
    throw "Unlimited policy must not be congested or throttled"
}

$checkMinimal = Invoke-AdaptiveBandwidthCheck -Settings @{ BandwidthPolicy = 'MinimalBackground' }
if ($checkMinimal.AppliedRate -ne '256k' -or $checkMinimal.IsCongested) {
    throw "MinimalBackground policy must apply 256k without congestion flag"
}

$checkLimited = Invoke-AdaptiveBandwidthCheck -Settings @{ BandwidthPolicy = 'Limited'; BandwidthLimitPreset = '1 MB/s' }
if ($checkLimited.AppliedRate -ne '1M' -or $checkLimited.IsCongested) {
    throw "Limited policy must apply 1M without congestion flag"
}
Write-Host "  [PASS] User bandwidth policies bypass ICMP congestion throttling." -ForegroundColor Green

# ==============================================================================
# 4. RESILIENT TRANSFER QUEUE: STRESS, CONCURRENCY & RECOVERY
# ==============================================================================
Write-Host "`n4. Testing Resilient Transfer Queue Engine..." -ForegroundColor Yellow

Clear-CloudTransferQueue -All
$srcAcc = @{ Id = 'acc_gd'; ProviderId = 'gdrive'; DisplayName = 'Google Drive' }
$dstAcc = @{ Id = 'acc_tb'; ProviderId = 'terabox'; DisplayName = 'TeraBox' }

# 4.1 Enqueue >= 100 synthetic small files, mixed sizes, and 0-byte empty files
Write-Host "  -> Enqueueing 120 synthetic files (empty 0-byte, small 10KB, medium 5MB, mixed sizes)..."
$testSizes = @(0L, 512L, 10240L, 524288L, 5242880L, 10485760L)
for ($i = 1; $i -le 120; $i++) {
    $sz = $testSizes[($i % $testSizes.Count)]
    Add-CloudTransferQueueItem `
        -SourceAccount $srcAcc `
        -SourcePath "folder/file_$i.dat" `
        -DestinationAccount $dstAcc `
        -DestinationPath "backup" `
        -FileSizeBytes $sz | Out-Null
}

$queueSnapshot = Get-CloudTransferQueue
if (@($queueSnapshot).Count -ne 120) {
    throw "Expected 120 items in queue, found $(@($queueSnapshot).Count)"
}
if ($queueSnapshot[0].Status -ne 'Queued' -or $queueSnapshot[0].RetryCount -ne 0) {
    throw "Expected first item to have Status='Queued' and RetryCount=0"
}
if ($queueSnapshot[0].FileSizeBytes -ne 512L) { # 1 % 6 = 1 -> index 1 -> 512L
    throw "Expected item 1 to preserve FileSizeBytes 512"
}
Write-Host "  [PASS] Enqueued 120 synthetic mixed-size items successfully." -ForegroundColor Green

# 4.2 Test Queue Item Cancellation
$targetCancelId = [string]$queueSnapshot[5].QueueId
$cancelOk = Stop-CloudTransferQueueItem -QueueId $targetCancelId
if (-not $cancelOk) { throw "Stop-CloudTransferQueueItem failed for $targetCancelId" }

$qAfterCancel = Get-CloudTransferQueue
$cancelledItem = @($qAfterCancel | Where-Object { $_.QueueId -eq $targetCancelId })[0]
if ($cancelledItem.Status -ne 'Cancelled') {
    throw "Expected status 'Cancelled', got '$($cancelledItem.Status)'"
}
Write-Host "  [PASS] Single item cancellation verified." -ForegroundColor Green

# 4.3 Test Transient Failure Backoff and Non-Blocking Scheduling
Clear-CloudTransferQueue -All
$failItem1 = Add-CloudTransferQueueItem -SourceAccount @{ Id = 'acc_err1'; ProviderId = 'invalid_prov'; DisplayName = 'Err1' } -SourcePath 'fail1.bin' -DestinationAccount @{ Id = 'acc_err2'; ProviderId = 'invalid_prov'; DisplayName = 'Err2' } -MaxRetries 1
$failItem2 = Add-CloudTransferQueueItem -SourceAccount @{ Id = 'acc_err1'; ProviderId = 'invalid_prov'; DisplayName = 'Err1' } -SourcePath 'fail2.bin' -DestinationAccount @{ Id = 'acc_err2'; ProviderId = 'invalid_prov'; DisplayName = 'Err2' } -MaxRetries 1

# Process queue: item 1 fails immediately on Start-CloudTransfer, backs off to 'Waiting for network/provider', item 2 is scheduled next
$resProg = Process-CloudTransferQueue -MaxConcurrent 2
if ($resProg[0].Status -ne 'Waiting for network/provider' -or $resProg[0].RetryCount -ne 1) {
    throw "Expected Item 1 to enter 'Waiting for network/provider' with RetryCount 1, got $($resProg[0].Status)"
}
if ($resProg[1].Status -ne 'Waiting for network/provider' -or $resProg[1].RetryCount -ne 1) {
    throw "Expected Item 2 to advance and enter 'Waiting for network/provider' with RetryCount 1 without wedging"
}
Write-Host "  [PASS] Transient error backoff & non-blocking advancement verified." -ForegroundColor Green

# 4.4 Test MaxRetries Exceeded Permanent Failure
$script:CloudTransferQueue[0].NextRetryUtc = [DateTime]::UtcNow.AddSeconds(-5)
$script:CloudTransferQueue[1].NextRetryUtc = [DateTime]::UtcNow.AddSeconds(-5)
$resProg2 = Process-CloudTransferQueue -MaxConcurrent 2

# Both items now have RetryCount = 2 (max retries reached), status must transition to 'Failed'
if ($resProg2[0].Status -ne 'Failed' -or $resProg2[1].Status -ne 'Failed') {
    throw "Expected items to transition to 'Failed' after exceeding MaxRetries, got $($resProg2[0].Status), $($resProg2[1].Status)"
}
Write-Host "  [PASS] Permanent failure non-blocking state verified." -ForegroundColor Green

# 4.5 Test Queue Cleanup of Failed/Completed Items
Clear-CloudTransferQueue
$qRemaining = Get-CloudTransferQueue
if (@($qRemaining).Count -ne 0) {
    throw "Expected Clear-CloudTransferQueue to purge failed items"
}
Write-Host "  [PASS] Queue cleanup verified." -ForegroundColor Green

# ==============================================================================
# 5. UI ASCII COMPLIANCE & STATE HONESTY AUDIT
# ==============================================================================
Write-Host "`n5. Testing UI ASCII Compliance & State Honesty..." -ForegroundColor Yellow

$uiScriptPath = Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1'
$bytes = [System.IO.File]::ReadAllBytes($uiScriptPath)
$nonAsciiFound = 0
for ($bi = 0; $bi -lt $bytes.Length; $bi++) {
    if ($bytes[$bi] -gt 127) {
        $nonAsciiFound++
    }
}
if ($nonAsciiFound -gt 0) {
    throw "NSCloudDrive.ps1 violates strict 7-bit ASCII compliance: $nonAsciiFound multi-byte characters found!"
}
Write-Host "  [PASS] NSCloudDrive.ps1 100% 7-bit ASCII compliant (0 multi-byte characters)." -ForegroundColor Green

# Check for honest confirmation labels in UI source
$uiContent = [System.IO.File]::ReadAllText($uiScriptPath)
if ($uiContent -notmatch 'Awaiting remote confirmation\.\.\.') {
    throw "Expected 'Awaiting remote confirmation...' label in NSCloudDrive.ps1"
}
if ($uiContent -notmatch 'All bytes transmitted.*Awaiting cloud verification') {
    throw "Expected 'All bytes transmitted ... Awaiting cloud verification' note in NSCloudDrive.ps1"
}
if ($uiContent -notmatch '100% \(Awaiting confirmation\)') {
    throw "Expected '100% (Awaiting confirmation)' sub-queue label in NSCloudDrive.ps1"
}
Write-Host "  [PASS] Honest cloud confirmation lifecycle state labels verified." -ForegroundColor Green

Write-Host "`nAll Transfer Bandwidth & Resilient Queue Tests Passed Successfully (exit code 0)." -ForegroundColor Cyan
exit 0
