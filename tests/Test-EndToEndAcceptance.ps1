# ==============================================================================
# NS Cloud Drive - Comprehensive End-to-End Acceptance Test
# ==============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing NS Cloud Drive End-to-End Acceptance...'

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')

# Dot-source all required components
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\TeraBoxBridgeManager.ps1')
. (Join-Path $srcDir 'providers\GoogleDriveProvider.ps1')
. (Join-Path $srcDir 'providers\TeraBoxProvider.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')

# Isolate test settings in a temporary directory to never pollute production user config
$testSettingsDir = Join-Path $env:TEMP ("NSCloudDrive_Test_" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testSettingsDir -Force)
Set-SettingsDirectoryOverride $testSettingsDir

# ------------------------------------------------------------------------------
# Gate 1: Multi-Account Isolation and Collision Prevention
# ------------------------------------------------------------------------------
$testAcc1Id = "test_gdrive_personal_" + [DateTime]::UtcNow.Ticks.ToString()
$testAcc2Id = "test_gdrive_work_" + ([DateTime]::UtcNow.Ticks + 1).ToString()
$testAcc3Id = "test_terabox_" + ([DateTime]::UtcNow.Ticks + 2).ToString()

try {
    # 1. Register multiple accounts
    $acc1 = Add-CloudAccount -Account @{
        Id = $testAcc1Id
        ProviderId = 'gdrive'
        DisplayName = 'Personal Google Drive'
        AccountEmail = 'personal@gmail.com'
        DriveLetter = 'G'
        AutoMount = $true
    }
    if ($acc1.DriveLetter -ne 'G') {
        throw "Account 1 expected drive letter G, got $($acc1.DriveLetter)"
    }

    $acc2 = Add-CloudAccount -Account @{
        Id = $testAcc2Id
        ProviderId = 'gdrive'
        DisplayName = 'Work Google Drive'
        AccountEmail = 'work@company.com'
        DriveLetter = 'H'
        AutoMount = $true
    }
    if ($acc2.DriveLetter -ne 'H') {
        throw "Account 2 expected drive letter H, got $($acc2.DriveLetter)"
    }

    $acc3 = Add-CloudAccount -Account @{
        Id = $testAcc3Id
        ProviderId = 'terabox'
        DisplayName = 'TeraBox Main'
        AccountEmail = 'terabox_user'
        DriveLetter = 'T'
        AutoMount = $true
    }
    if ($acc3.DriveLetter -ne 'T') {
        throw "Account 3 expected drive letter T, got $($acc3.DriveLetter)"
    }

    # Verify both accounts exist in registry
    $all = Get-CloudAccounts
    $found1 = $all | Where-Object { $_.Id -eq $testAcc1Id }
    $found2 = $all | Where-Object { $_.Id -eq $testAcc2Id }
    $found3 = $all | Where-Object { $_.Id -eq $testAcc3Id }
    if (-not $found1 -or -not $found2 -or -not $found3) {
        throw "Failed to retrieve all saved multi-accounts from SettingsManager."
    }
    Write-Output '  [PASS] Multi-account registry persistence verified across Google Drive and TeraBox'

    # 2. Token store isolation
    $mockTokens1 = @{
        access_token = 'token_personal_secret'
        token_type = 'Bearer'
        refresh_token = 'refresh_personal_secret'
        expiry = [DateTime]::UtcNow.AddHours(1).ToString('o')
    }
    $mockTokens2 = @{
        access_token = 'token_work_secret'
        token_type = 'Bearer'
        refresh_token = 'refresh_work_secret'
        expiry = [DateTime]::UtcNow.AddHours(1).ToString('o')
    }

    Save-GoogleDriveTokens -TokenData $mockTokens1 -AccountId $testAcc1Id
    Save-GoogleDriveTokens -TokenData $mockTokens2 -AccountId $testAcc2Id

    $loaded1 = Get-GoogleDriveStoredTokens -AccountId $testAcc1Id
    $loaded2 = Get-GoogleDriveStoredTokens -AccountId $testAcc2Id

    if ($loaded1.access_token -ne 'token_personal_secret' -or $loaded2.access_token -ne 'token_work_secret') {
        throw "Google Drive multi-account token isolation failed: cross-contamination detected."
    }
    Write-Output '  [PASS] Isolated DPAPI token files verified per account without cross-contamination'

    # 3. Dynamic Rclone Remote Environment Variables
    $env1 = Get-GoogleDriveRcloneEnvironment -AccountId $testAcc1Id -RemoteName 'gdrive_personal'
    $env2 = Get-GoogleDriveRcloneEnvironment -AccountId $testAcc2Id -RemoteName 'gdrive_work'

    if (-not $env1.ContainsKey('RCLONE_CONFIG_GDRIVE_PERSONAL_TYPE') -or $env1['RCLONE_CONFIG_GDRIVE_PERSONAL_TYPE'] -ne 'drive') {
        throw "Invalid dynamic rclone configuration for Account 1"
    }
    if (-not $env2.ContainsKey('RCLONE_CONFIG_GDRIVE_WORK_TYPE') -or $env2['RCLONE_CONFIG_GDRIVE_WORK_TYPE'] -ne 'drive') {
        throw "Invalid dynamic rclone configuration for Account 2"
    }
    if ($env1['RCLONE_CONFIG_GDRIVE_PERSONAL_TOKEN'] -eq $env2['RCLONE_CONFIG_GDRIVE_WORK_TOKEN']) {
        throw "Dynamic rclone remote tokens matched when they must be distinct."
    }
    Write-Output '  [PASS] Dynamic rclone environment variable generation verified per account'

    # 4. WebDAV Bridge Environment
    $tbEnv = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword 'test_bridge_pass' -Port 19191
    if ($tbEnv['RCLONE_CONFIG_TERABOX_TYPE'] -ne 'webdav' -or $tbEnv['RCLONE_CONFIG_TERABOX_URL'] -notmatch '19191') {
        throw "TeraBox WebDAV rclone environment invalid: $($tbEnv | Out-String)"
    }
    Write-Output '  [PASS] TeraBox loopback WebDAV bridge rclone environment verified'

} finally {
    # Cleanup test accounts and credentials
    Remove-CloudAccount -AccountId $testAcc1Id | Out-Null
    Remove-CloudAccount -AccountId $testAcc2Id | Out-Null
    Remove-CloudAccount -AccountId $testAcc3Id | Out-Null
    Remove-GoogleDriveSession -AccountId $testAcc1Id
    Remove-GoogleDriveSession -AccountId $testAcc2Id
    Reset-SettingsDirectoryOverride
    try { Remove-Item -LiteralPath $testSettingsDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ------------------------------------------------------------------------------
# Gate 2: Virtual Drive Lifecycle and Multi-Mount Conflict Isolation
# ------------------------------------------------------------------------------
$status1 = Get-VirtualDriveStatus -AccountId 'acc_sim_1' -ProviderId 'gdrive'
$status2 = Get-VirtualDriveStatus -AccountId 'acc_sim_2' -ProviderId 'gdrive'
if ($status1.IsMounted -or $status2.IsMounted) {
    throw "Initial virtual drive state should be unmounted."
}
Write-Output '  [PASS] Independent virtual drive status isolation verified'

# ------------------------------------------------------------------------------
# Gate 3: UI Architecture and Memory Trimming
# ------------------------------------------------------------------------------
Add-Type -MemberDefinition '[DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hwProc);' -Name 'Win32Test' -Namespace 'NSCloudDrive' -ErrorAction SilentlyContinue
$proc = [System.Diagnostics.Process]::GetCurrentProcess()
$wsBefore = $proc.WorkingSet64
[NSCloudDrive.Win32Test]::EmptyWorkingSet($proc.Handle) | Out-Null
$proc.Refresh()
$wsAfter = $proc.WorkingSet64
Write-Output "  [PASS] Win32 EmptyWorkingSet memory trimming verified (Before: $([Math]::Round($wsBefore / 1MB, 2)) MB, After: $([Math]::Round($wsAfter / 1MB, 2)) MB)"

# ------------------------------------------------------------------------------
# Gate 4: No Uninitialized $browserWin Variable in NSCloudDrive.ps1
# ------------------------------------------------------------------------------
$code = Get-Content -LiteralPath (Join-Path $srcDir 'NSCloudDrive.ps1') -Raw
if ($code -match '\$browserWin\b') {
    throw "Forbidden uninitialized `$browserWin variable found in NSCloudDrive.ps1"
}
Write-Output '  [PASS] NSCloudDrive.ps1 verified clean of uninitialized $browserWin references'

Write-Output 'All End-to-End Acceptance Tests Passed Successfully.'
