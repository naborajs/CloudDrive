# Test-MultiAccountIsolation.ps1 - Validates multi-account isolation for Google Drive and TeraBox
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\TeraBoxBridgeManager.ps1')
. (Join-Path $PSScriptRoot '..\src\ui\EmbeddedBrowserWindow.ps1')

Write-Output 'Testing Multi-Account Isolation...'

# Sandbox LOCALAPPDATA to isolate test credential files
$origLocalAppData = $env:LOCALAPPDATA
$testSandbox = Join-Path $env:TEMP ("NSCloudDrive_MultiAccTest_" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testSandbox -Force)
$env:LOCALAPPDATA = $testSandbox
Set-SettingsDirectoryOverride (Join-Path $testSandbox 'settings')

try {
    # --------------------------------------------------------------------------
    # 1. Google Drive Multi-Account DPAPI and Remote Isolation
    # --------------------------------------------------------------------------
    $gdAcc1 = "gdrive_test_1"
    $gdAcc2 = "gdrive_test_2"

    $tokens1 = [ordered]@{
        access_token = "ya29.test_token_account_1"
        refresh_token = "1//test_refresh_token_account_1"
        token_type = "Bearer"
        expires_in = 3600
        scope = "https://www.googleapis.com/auth/drive"
        obtained_at = [DateTime]::UtcNow.ToString('o')
    }

    $tokens2 = [ordered]@{
        access_token = "ya29.test_token_account_2"
        refresh_token = "1//test_refresh_token_account_2"
        token_type = "Bearer"
        expires_in = 3600
        scope = "https://www.googleapis.com/auth/drive"
        obtained_at = [DateTime]::UtcNow.ToString('o')
    }

    Save-GoogleDriveTokens -TokenData $tokens1 -AccountId $gdAcc1
    Save-GoogleDriveTokens -TokenData $tokens2 -AccountId $gdAcc2

    $loaded1 = Get-GoogleDriveStoredTokens -AccountId $gdAcc1
    $loaded2 = Get-GoogleDriveStoredTokens -AccountId $gdAcc2

    if (-not $loaded1 -or $loaded1.access_token -ne "ya29.test_token_account_1") {
        throw "Account 1 token verification failed."
    }
    if (-not $loaded2 -or $loaded2.access_token -ne "ya29.test_token_account_2") {
        throw "Account 2 token verification failed."
    }

    $env1 = Get-GoogleDriveRcloneEnvironment -AccountId $gdAcc1 -RemoteName 'gdrive_user1'
    $env2 = Get-GoogleDriveRcloneEnvironment -AccountId $gdAcc2 -RemoteName 'gdrive_user2'

    if ($env1['RCLONE_CONFIG_GDRIVE_USER1_TYPE'] -ne 'drive' -or $env2['RCLONE_CONFIG_GDRIVE_USER2_TYPE'] -ne 'drive') {
        throw "Dynamic rclone remote configuration type mismatch."
    }
    if ($env1['RCLONE_CONFIG_GDRIVE_USER1_TOKEN'] -eq $env2['RCLONE_CONFIG_GDRIVE_USER2_TOKEN']) {
        throw "Dynamic rclone tokens should be distinct across Google Drive accounts."
    }

    # Removing Account 1 leaves Account 2 intact
    Remove-GoogleDriveSession -AccountId $gdAcc1
    $afterRemove1 = Get-GoogleDriveStoredTokens -AccountId $gdAcc1
    $afterRemove2 = Get-GoogleDriveStoredTokens -AccountId $gdAcc2
    if ($afterRemove1 -ne $null) { throw "Account 1 was not removed." }
    if ($afterRemove2 -eq $null -or $afterRemove2.access_token -ne "ya29.test_token_account_2") {
        throw "Account 2 was inadvertently corrupted when removing Account 1."
    }
    Write-Output '  [PASS] Google Drive multi-account credential and remote isolation verified'

    # --------------------------------------------------------------------------
    # 2. TeraBox Multi-Account DPAPI and Bridge Isolation
    # --------------------------------------------------------------------------
    $tbAcc1 = "terabox_test_1"
    $tbAcc2 = "terabox_test_2"

    Save-TeraBoxSession -Type 'web-session' -Secret 'ndus=cookie_account_1' -JsToken 'js_1' -AccountId $tbAcc1
    Save-TeraBoxSession -Type 'web-session' -Secret 'ndus=cookie_account_2' -JsToken 'js_2' -AccountId $tbAcc2

    $tbLoaded1 = Get-TeraBoxStoredSession -AccountId $tbAcc1
    $tbLoaded2 = Get-TeraBoxStoredSession -AccountId $tbAcc2

    if (-not $tbLoaded1 -or $tbLoaded1.Secret -ne 'ndus=cookie_account_1' -or $tbLoaded1.JsToken -ne 'js_1') {
        throw "TeraBox Account 1 session mismatch."
    }
    if (-not $tbLoaded2 -or $tbLoaded2.Secret -ne 'ndus=cookie_account_2' -or $tbLoaded2.JsToken -ne 'js_2') {
        throw "TeraBox Account 2 session mismatch."
    }

    $tbEnv1 = Get-TeraBoxRcloneEnvironment -AccountId $tbAcc1 -RemoteName 'terabox_acc1'
    $tbEnv2 = Get-TeraBoxRcloneEnvironment -AccountId $tbAcc2 -RemoteName 'terabox_acc2'

    if ($tbEnv1['RCLONE_CONFIG_TERABOX_ACC1_COOKIE'] -ne 'ndus=cookie_account_1' -or
        $tbEnv2['RCLONE_CONFIG_TERABOX_ACC2_COOKIE'] -ne 'ndus=cookie_account_2') {
        throw "TeraBox dynamic rclone cookie mismatch."
    }

    # Verify bridge home isolation
    $bridgeHome1 = Get-TeraBoxBridgeHomeDirectory -AccountId $tbAcc1
    $bridgeHome2 = Get-TeraBoxBridgeHomeDirectory -AccountId $tbAcc2
    if ($bridgeHome1 -eq $bridgeHome2) {
        throw "TeraBox bridge homes should be distinct per account."
    }
    if (-not $bridgeHome1.EndsWith($tbAcc1) -or -not $bridgeHome2.EndsWith($tbAcc2)) {
        throw "TeraBox bridge home paths should contain account IDs."
    }

    # Removing Account 1 leaves Account 2 intact
    Remove-TeraBoxSession -AccountId $tbAcc1
    $tbAfter1 = Get-TeraBoxStoredSession -AccountId $tbAcc1
    $tbAfter2 = Get-TeraBoxStoredSession -AccountId $tbAcc2
    if ($tbAfter1 -ne $null) { throw "TeraBox Account 1 was not removed." }
    if ($tbAfter2 -eq $null -or $tbAfter2.Secret -ne 'ndus=cookie_account_2') {
        throw "TeraBox Account 2 was inadvertently corrupted when removing Account 1."
    }
    Write-Output '  [PASS] TeraBox multi-account credential, remote, and bridge isolation verified'

    # --------------------------------------------------------------------------
    # 3. Drive Letter Conflict Detection & Stale Cleanup
    # --------------------------------------------------------------------------
    $cAvail = Test-DriveLetterAvailable 'C'
    if ($cAvail -ne $false) { throw "Drive C: should be reported as unavailable." }

    $nextFromC = Get-NextAvailableDriveLetter 'C'
    if ($nextFromC -eq 'C') { throw "Next available drive letter should not return occupied letter C." }

    # Test Clear-StaleDriveLetterMapping runs cleanly without throwing
    Clear-StaleDriveLetterMapping -DriveLetter 'Z'
    Clear-StaleDriveLetterMapping -DriveLetter ''
    Write-Output '  [PASS] Drive letter conflict detection and stale redirector cleanup verified'

    # --------------------------------------------------------------------------
    # 4. Truthful Virtual Drive State Modeling
    # --------------------------------------------------------------------------
    $statusA = Get-VirtualDriveStatus -AccountId 'acc_test_a' -ProviderId 'gdrive'
    $statusB = Get-VirtualDriveStatus -AccountId 'acc_test_b' -ProviderId 'terabox'

    if ($statusA.IsMounted -or $statusB.IsMounted) {
        throw "Unmounted drives must truthfully report IsMounted = False."
    }
    if ($statusA.ProcessRunning -or $statusB.ProcessRunning) {
        throw "Unmounted drives must truthfully report ProcessRunning = False."
    }
    Write-Output '  [PASS] Truthful virtual drive state reporting verified'

} finally {
    $env:LOCALAPPDATA = $origLocalAppData
    Reset-SettingsDirectoryOverride
    try { Remove-Item -LiteralPath $testSandbox -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Output 'All Multi-Account Isolation Tests Passed Successfully.'
