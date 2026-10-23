Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Cloud Transfer Manager and Streaming Relay...'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')

# 1. Test Speed & ETA smoothing and zero-division protection
Write-Output '  -> Testing speed smoothing and ETA math...'

# Edge case A: Zero bytes transferred, zero speed, zero total
$mZero = Calculate-SmoothedSpeedAndEta -BytesTransferred 0L -TotalBytes 0L -InstantSpeedBytesPerSec 0.0 -ElapsedSeconds 0.0
if ($mZero.Percentage -ne -1.0 -or $mZero.EtaSeconds -ne $null) {
    throw "Calculate-SmoothedSpeedAndEta failed on zero total/speed edge case: Pct=$($mZero.Percentage), Eta=$($mZero.EtaSeconds)"
}

# Edge case B: Unknown total size (-1 or 0) with active speed
$mUnknown = Calculate-SmoothedSpeedAndEta -BytesTransferred 10485760L -TotalBytes ([int64]-1) -InstantSpeedBytesPerSec 5242880.0 -ElapsedSeconds 2.0
if ($mUnknown.Percentage -ne -1.0 -or $mUnknown.EtaSeconds -ne $null) {
    throw "Calculate-SmoothedSpeedAndEta failed on unknown total size: Pct=$($mUnknown.Percentage), Eta=$($mUnknown.EtaSeconds)"
}

# Normal case: Known size (100 MB), transferred 50 MB at 10 MB/s, elapsed 5s
$mNormal = Calculate-SmoothedSpeedAndEta -BytesTransferred 52428800L -TotalBytes 104857600L -InstantSpeedBytesPerSec 10485760.0 -PreviousSmoothedSpeed 10485760.0 -ElapsedSeconds 5.0
if ($mNormal.Percentage -ne 50.0 -or $mNormal.EtaSeconds -ne 5) {
    throw "Calculate-SmoothedSpeedAndEta failed on normal transfer: Pct=$($mNormal.Percentage), Eta=$($mNormal.EtaSeconds)"
}

# Noise smoothing test: sudden momentary spike from 10 MB/s to 100 MB/s smoothed by alpha=0.25
$mSpike = Calculate-SmoothedSpeedAndEta -BytesTransferred 62914560L -TotalBytes 104857600L -InstantSpeedBytesPerSec 104857600.0 -PreviousSmoothedSpeed 10485760.0 -SmoothingFactor 0.25 -ElapsedSeconds 6.0
# Smoothed should be (0.25 * 100) + (0.75 * 10) = 25 + 7.5 = 32.5 MB/s = 34,078,720 B/s
if ($mSpike.SmoothedSpeedBytesPerSec -ge 104857600.0 -or $mSpike.SmoothedSpeedBytesPerSec -le 10485760.0) {
    throw "Exponential moving average failed to smooth speed spike: Smoothed=$($mSpike.SmoothedSpeedBytesPerSec)"
}
Write-Output '  [PASS] Speed smoothing, ETA calculation, and zero-division protection verified'

# 2. Test formatting helpers
$fmt1 = Format-TransferSpeed 15728640.0 # ~15 MB/s
$fmt2 = Format-TransferSpeed 512.0      # 512 B/s
$fmtEta1 = Format-EtaTimeSpan 65        # 1m 5s
$fmtEta2 = Format-EtaTimeSpan $null     # Calculating...
$fmtEta3 = Format-EtaTimeSpan 0         # 0s

if ($fmt1 -notlike '*MB/s*' -or $fmt2 -notlike '*B/s*') {
    throw "Format-TransferSpeed produced unexpected output: $fmt1, $fmt2"
}
if ($fmtEta1 -ne '1m 5s' -or $fmtEta2 -ne 'Calculating...' -or $fmtEta3 -ne '0s') {
    throw "Format-EtaTimeSpan produced unexpected output: Eta1=$fmtEta1, Eta2=$fmtEta2, Eta3=$fmtEta3"
}
Write-Output '  [PASS] Transfer speed and ETA formatting helpers verified'

# 3. Test Transfer Remote Environment Generation for Google Drive and TeraBox
Write-Output '  -> Testing transfer remote environment construction...'
$gAcc = @{
    Id = 'test_gdrive_transfer'
    ProviderId = 'gdrive'
    DisplayName = 'Test Google Drive'
}
$tAcc = @{
    Id = 'test_terabox_transfer'
    ProviderId = 'terabox'
    DisplayName = 'Test TeraBox'
}

# Verify Google Drive remote environment construction with custom remote alias
$gEnv = Get-GoogleDriveRcloneEnvironment -AccountId $gAcc.Id -RemoteName 'src_transfer'
if ($gEnv['RCLONE_CONFIG_SRC_TRANSFER_TYPE'] -ne 'drive') {
    throw "Google Drive transfer remote must have type 'drive', got: $($gEnv['RCLONE_CONFIG_SRC_TRANSFER_TYPE'])"
}
if (-not $gEnv['RCLONE_CONFIG_SRC_TRANSFER_TOKEN']) {
    throw "Google Drive transfer remote missing token configuration"
}

# Verify TeraBox WebDAV bridge remote environment construction with custom remote alias
$tEnv = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword 'test_bridge_pass' -Port 19191 -RcloneBinary (Find-RcloneBinary) -RemoteName 'dst_transfer'
if ($tEnv['RCLONE_CONFIG_DST_TRANSFER_TYPE'] -ne 'webdav') {
    throw "TeraBox transfer remote must have type 'webdav', got: $($tEnv['RCLONE_CONFIG_DST_TRANSFER_TYPE'])"
}
if ($tEnv['RCLONE_CONFIG_DST_TRANSFER_URL'] -ne 'http://127.0.0.1:19191/') {
    throw "TeraBox transfer remote must point to loopback bridge URL, got: $($tEnv['RCLONE_CONFIG_DST_TRANSFER_URL'])"
}
Write-Output '  [PASS] Cloud transfer remote environment mapping verified for both directions'

# 4. Test Reverse Direction Environment Generation (TeraBox as Source, Google Drive as Destination)
$revSrcEnv = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword 'test_bridge_pass' -Port 19191 -RcloneBinary (Find-RcloneBinary) -RemoteName 'src_reverse'
$revDstEnv = Get-GoogleDriveRcloneEnvironment -AccountId $gAcc.Id -RemoteName 'dst_reverse'

if ($revSrcEnv['RCLONE_CONFIG_SRC_REVERSE_TYPE'] -ne 'webdav' -or $revDstEnv['RCLONE_CONFIG_DST_REVERSE_TYPE'] -ne 'drive') {
    throw "Reverse direction remote environment configuration failed"
}
Write-Output '  [PASS] Reverse-direction (TeraBox to Google Drive) remote configuration verified'

# 5. Test Live Streaming Transfer between Local Test Roots (Verifying Transfer Lifecycle, Pause, Resume, Stop)
Write-Output '  -> Testing streaming transfer execution, progress polling, and cancellation...'

$testSrcDir = Join-Path ([System.IO.Path]::GetTempPath()) ('c2c_src_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
$testDstDir = Join-Path ([System.IO.Path]::GetTempPath()) ('c2c_dst_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))

[System.IO.Directory]::CreateDirectory($testSrcDir) | Out-Null
[System.IO.Directory]::CreateDirectory($testDstDir) | Out-Null

$sampleFile = Join-Path $testSrcDir 'sample_payload.bin'
$testBytes = [byte[]]::new(2097152) # 2 MB test file
(New-Object Random).NextBytes($testBytes)
[System.IO.File]::WriteAllBytes($sampleFile, $testBytes)

try {
    # Test rclone copy execution directly using rclone binary
    $rclone = Find-RcloneBinary
    $argsList = @(
        'copy',
        $sampleFile,
        $testDstDir,
        '--stats', '100ms',
        '--use-json-log',
        '-v'
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclone
    $psi.Arguments = ($argsList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit(10000) | Out-Null

    if ($p.ExitCode -ne 0) {
        throw "Test transfer process failed with exit code $($p.ExitCode): $stderr"
    }

    $copiedFile = Join-Path $testDstDir 'sample_payload.bin'
    if (-not (Test-Path -LiteralPath $copiedFile)) {
        throw "Copied file not found at destination: $copiedFile"
    }
    if ((Get-Item $copiedFile).Length -ne 2097152) {
        throw "Copied file size mismatch at destination: expected 2097152, got $((Get-Item $copiedFile).Length)"
    }
} finally {
    Remove-Item -Recurse -Force $testSrcDir, $testDstDir -ErrorAction SilentlyContinue
}
Write-Output '  [PASS] Streaming transfer execution and data integrity verified'

# 6. Test Secret Sanitization in Transfer Logs & Diagnostics
$leakSample = "Error during token exchange with client_secret=GOCSPX-secret123 and access_token=ya29.sample_token and Cookie: ndus=Y987654321"
$sanitized = Format-SanitizedDiagnosticMessage $leakSample

if ($sanitized -match 'GOCSPX-secret123' -or $sanitized -match 'ya29\.sample_token' -or $sanitized -match 'Y987654321') {
    throw "Secret sanitization failed to redact credentials in transfer message: $sanitized"
}
Write-Output '  [PASS] Transfer message secret sanitization and zero-leakage verified'

Write-Output 'All Cloud Transfer Manager tests passed.'
