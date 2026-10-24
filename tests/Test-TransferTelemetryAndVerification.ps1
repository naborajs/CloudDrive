# ==============================================================================
# NS Cloud Drive - Transfer Telemetry, Pre-flight Limits & Remote Verification Test
# ==============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Transfer Telemetry, Pre-flight Limits & Remote Verification...'

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')

# Dot-source models, services, providers
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\TeraBoxBridgeManager.ps1')
. (Join-Path $srcDir 'providers\GoogleDriveProvider.ps1')
. (Join-Path $srcDir 'providers\TeraBoxProvider.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

# ------------------------------------------------------------------------------
# 1. Pre-flight Check: TeraBox Free vs Premium Plan File Size Limits
# ------------------------------------------------------------------------------
Write-Output '  -> Testing TeraBox plan file size pre-flight validation...'

$tbAccount = @{
    Id = 'test_tb_preflight'
    ProviderId = 'terabox'
    DisplayName = 'Test TeraBox Account'
}

# 40 GB file must be rejected on Free plan (limit is 4.0 GB)
$fortyGb = 40L * 1024L * 1024L * 1024L
$preflight40Gb = Test-ProviderUploadPreflight -Account $tbAccount -FileSizeBytes $fortyGb -FileName 'HugeFile.iso'
if ($preflight40Gb.Allowed) {
    throw 'Pre-flight check failed: 40 GB file was allowed on TeraBox Free account!'
}
if ($preflight40Gb.ErrorCode -ne 'PlanFileLimit') {
    throw "Expected ErrorCode 'PlanFileLimit', got '$($preflight40Gb.ErrorCode)'"
}
if ($preflight40Gb.Reason -notmatch '4\.0 GB per file') {
    throw "Expected error message explaining 4.0 GB per file limit, got: $($preflight40Gb.Reason)"
}
Write-Output '  [PASS] 40 GB upload rejected by pre-flight check with PlanFileLimit and clear explanation'

# 500 MB file must be allowed on TeraBox Free plan
$fiveHundredMb = 500L * 1024L * 1024L
$preflight500Mb = Test-ProviderUploadPreflight -Account $tbAccount -FileSizeBytes $fiveHundredMb -FileName 'NormalDoc.zip'
if (-not $preflight500Mb.Allowed) {
    throw "Pre-flight check failed: 500 MB file was rejected unexpectedly: $($preflight500Mb.Reason)"
}
Write-Output '  [PASS] Standard file size (500 MB) permitted on TeraBox Free account'

# ------------------------------------------------------------------------------
# 2. Pre-flight Check: Google Drive 5 TB Limit
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Google Drive 5 TB file size limit...'

$gdAccount = @{
    Id = 'test_gd_preflight'
    ProviderId = 'gdrive'
    DisplayName = 'Test Google Drive'
}

# 10 GB file must be allowed on Google Drive
$tenGb = 10L * 1024L * 1024L * 1024L
$preflightGd10Gb = Test-ProviderUploadPreflight -Account $gdAccount -FileSizeBytes $tenGb -FileName 'ProjectVideo.mp4'
if (-not $preflightGd10Gb.Allowed) {
    throw "Pre-flight check failed: 10 GB file was rejected on Google Drive: $($preflightGd10Gb.Reason)"
}
Write-Output '  [PASS] 10 GB file allowed on Google Drive'

# 6 TB file must be rejected on Google Drive (limit is 5 TB)
$sixTb = 6L * 1024L * 1024L * 1024L * 1024L
$preflightGd6Tb = Test-ProviderUploadPreflight -Account $gdAccount -FileSizeBytes $sixTb -FileName 'MassiveArchive.tar'
if ($preflightGd6Tb.Allowed) {
    throw 'Pre-flight check failed: 6 TB file was allowed on Google Drive!'
}
if ($preflightGd6Tb.Reason -notmatch '5 TB') {
    throw "Expected 5 TB limit error for Google Drive, got: $($preflightGd6Tb.Reason)"
}
Write-Output '  [PASS] 6 TB file rejected by pre-flight check on Google Drive'

# ------------------------------------------------------------------------------
# 3. Throughput Formatting and Network Unit Differentiation
# ------------------------------------------------------------------------------
Write-Output '  -> Testing throughput unit distinction (MB/s vs Mbps) and loopback staging labels...'

# 10 MB/s should display ~10.0 MB/s and ~83.9 Mbps (or 80-84 Mbps depending on decimal base)
$speedBytes = 10L * 1024L * 1024L
$tpStr = Format-TransferThroughput -BytesPerSec $speedBytes -IsLoopbackStaging $false
if ($tpStr -notmatch 'MB/s' -or $tpStr -notmatch 'Mbps') {
    throw "Format-TransferThroughput must output both MB/s and Mbps, got: '$tpStr'"
}
Write-Output "  [PASS] Throughput unit distinction verified: $tpStr"

# Loopback staging to local CPX bridge must NOT masquerade as direct cloud upload
$stagingStr = Format-TransferThroughput -BytesPerSec $speedBytes -IsLoopbackStaging $true
if ($stagingStr -notmatch 'Staging to local bridge' -or $stagingStr -notmatch 'Cloud upload pending') {
    throw "Loopback throughput must explicitly indicate local bridge staging, got: '$stagingStr'"
}
Write-Output "  [PASS] Loopback staging honestly reported: $stagingStr"

# ------------------------------------------------------------------------------
# 4. Deterministic Virtual Drive RC Ports & Mount Arguments
# ------------------------------------------------------------------------------
Write-Output '  -> Testing deterministic RC ports and mount argument builder...'

$portT = Get-VirtualDriveRcPort -DriveLetter 'T'
$portG = Get-VirtualDriveRcPort -DriveLetter 'G'
$portH = Get-VirtualDriveRcPort -DriveLetter 'H'
$portI = Get-VirtualDriveRcPort -DriveLetter 'I'

if ($portT -eq $portG -or $portG -eq $portH -or $portH -eq $portI) {
    throw "RC ports must be unique per drive letter: T=$portT, G=$portG, H=$portH, I=$portI"
}
if ($portT -lt 5580 -or $portT -gt 5610) {
    throw "RC port out of expected range: $portT"
}
Write-Output "  [PASS] Deterministic RC port mapping verified: T=$portT, G=$portG, H=$portH, I=$portI"

# Verify Build-RcloneMountArguments with RcPort
$argsWithRc = Build-RcloneMountArguments -RemoteName 'terabox' -DriveLetter 'T' -RcPort $portT
if ($argsWithRc[0] -ne 'mount' -or $argsWithRc[1] -ne 'terabox:' -or $argsWithRc[2] -ne 'T:\') {
    throw 'Build-RcloneMountArguments corrupted leading positional mount arguments!'
}
if ($argsWithRc -notcontains '--rc' -or $argsWithRc -notcontains '--rc-no-auth') {
    throw 'Build-RcloneMountArguments missing --rc flags'
}
$expectedAddr = "127.0.0.1:$portT"
if ($argsWithRc -notcontains $expectedAddr) {
    throw "Build-RcloneMountArguments missing expected RC address: $expectedAddr"
}
Write-Output '  [PASS] Mount argument builder correctly appends isolated RC configuration'

# ------------------------------------------------------------------------------
# 5. Remote Directory Listing Bypass & Verification Logic
# ------------------------------------------------------------------------------
Write-Output '  -> Testing remote verification logic and local cache bypass...'

# Test-RemoteCloudFileVerification with missing file
$verifyMissing = Test-RemoteCloudFileVerification -Account @{ ProviderId = 'terabox'; Id = 'fake_acc' } -RemotePath 'DoesNotExist.bin' -ExpectedSizeBytes 1000
if ($verifyMissing.Verified) {
    throw 'Missing file should not be verified!'
}
if ($verifyMissing.Status -ne 'Failed' -and $verifyMissing.Status -ne 'Remote state unknown') {
    throw "Expected status 'Failed' or 'Remote state unknown', got '$($verifyMissing.Status)'"
}
Write-Output '  [PASS] Remote verification fails safely on non-existent files'

# ------------------------------------------------------------------------------
# 6. Live TeraBox Bridge Status Endpoint Verification (if CPX daemon is alive)
# ------------------------------------------------------------------------------
Write-Output '  -> Testing live CPX bridge status querying...'

$liveAccounts = @(Get-CloudAccounts | Where-Object { $_.ProviderId -eq 'terabox' })
if ($liveAccounts.Count -gt 0) {
    $firstTb = $liveAccounts[0]
    $bStatus = Get-TeraBoxBridgeStatus -AccountId $firstTb.Id
    if ($bStatus.Success) {
        Write-Output "  [PASS] Live CPX bridge status queried successfully (User: $($bStatus.User), Plan: $($bStatus.Plan), MaxFileLimit: $([Math]::Round($bStatus.MaxFileSizeBytes / 1GB, 1)) GB)"
        if ($bStatus.Plan -eq 'Free' -and $bStatus.MaxFileSizeBytes -ne 4000000000L) {
            throw "Free plan must have 4,000,000,000 byte limit, got $($bStatus.MaxFileSizeBytes)"
        }
    } else {
        Write-Output "  [INFO] CPX bridge not currently active for $($firstTb.Id): $($bStatus.Error)"
    }
} else {
    Write-Output '  [INFO] No saved TeraBox accounts to query live bridge status'
}

# ------------------------------------------------------------------------------
# 7. Virtual Drive VFS Stats Helper
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Get-VirtualDriveVfsStats default/fallback behavior...'

$vfsDefault = Get-VirtualDriveVfsStats -DriveLetter 'Z'
if ($vfsDefault.IsActive) {
    throw 'Unmounted drive Z should report IsActive = $false'
}
if ($vfsDefault.State -ne 'Remote state unknown') {
    throw "Expected state 'Remote state unknown', got '$($vfsDefault.State)'"
}
Write-Output '  [PASS] Virtual drive VFS stats returns clean inactive state for unmounted drives'

Write-Output "`nAll Transfer Telemetry, Pre-flight Limits & Remote Verification Tests Passed Successfully."
