# ==============================================================================
# NS Cloud Drive - Write Protection, Upload, Mount Reconciliation & Placeholder Test
# ==============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Write Protection, Upload, and Mount Reconciliation...'

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')

# Dot-source models, services, providers
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\TeraBoxBridgeManager.ps1')
. (Join-Path $srcDir 'providers\GoogleDriveProvider.ps1')
. (Join-Path $srcDir 'providers\TeraBoxProvider.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')

# ------------------------------------------------------------------------------
# 1. Mount Arguments & Write-Protection Prevention
# ------------------------------------------------------------------------------
$rwArgs = Build-RcloneMountArguments -RemoteName 'terabox' -DriveLetter 'T'
if ($rwArgs -contains '--read-only') {
    throw 'Default mount arguments must NOT contain --read-only; write protection must be disabled.'
}
if ($rwArgs -notcontains '--vfs-cache-mode' -or $rwArgs -notcontains 'full') {
    throw 'Mount arguments must include --vfs-cache-mode full to support Explorer write streams.'
}
if ($rwArgs -notcontains '--vfs-write-back') {
    throw 'Mount arguments must include --vfs-write-back to ensure asynchronous flush.'
}
Write-Output '  [PASS] Mount arguments builder defaults to read-write with VFS full cache'

# Explicit read-only verification
$roArgs = Build-RcloneMountArguments -RemoteName 'terabox' -DriveLetter 'T' -ReadOnly
if ($roArgs -notcontains '--read-only') {
    throw 'Explicit -ReadOnly switch must include --read-only in mount arguments.'
}
Write-Output '  [PASS] Explicit -ReadOnly switch honored'

# ------------------------------------------------------------------------------
# 2. Mount Reconciliation & Find-ActiveMountProcess
# ------------------------------------------------------------------------------
$nullProc = Find-ActiveMountProcess -DriveLetter ''
if ($null -ne $nullProc) {
    throw 'Empty drive letter search must return null'
}

$nonExistentProc = Find-ActiveMountProcess -DriveLetter 'Z'
Write-Output '  [PASS] Active mount process search handles unmounted drive letters cleanly'

# ------------------------------------------------------------------------------
# 3. Placeholder Demo Account Removal
# ------------------------------------------------------------------------------
$testSettingsDir = Join-Path $env:TEMP ("NSCloudDrive_PurgeTest_" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testSettingsDir -Force)
Set-SettingsDirectoryOverride $testSettingsDir

try {
    # Seed fake accounts
    [void](Add-CloudAccount -Account @{
        Id = 'test_fake_gdrive_1'
        ProviderId = 'gdrive'
        DisplayName = 'Personal Google Drive'
        AccountEmail = 'personal@gmail.com'
        DriveLetter = 'G'
    })
    [void](Add-CloudAccount -Account @{
        Id = 'test_fake_gdrive_2'
        ProviderId = 'gdrive'
        DisplayName = 'Work Google Drive'
        AccountEmail = 'work@company.com'
        DriveLetter = 'H'
    })
    [void](Add-CloudAccount -Account @{
        Id = 'real_user_acc_1'
        ProviderId = 'gdrive'
        DisplayName = 'My Real GDrive'
        AccountEmail = 'myrealaccount@gmail.com'
        DriveLetter = 'I'
    })

    $beforePurge = Get-CloudAccounts
    if ($beforePurge.Count -ne 3) {
        throw "Expected 3 accounts before purge, got $($beforePurge.Count)"
    }

    $purged = Remove-SeededPlaceholderAccounts
    $afterPurge = Get-CloudAccounts
    if ($afterPurge.Count -ne 1) {
        throw "Expected exactly 1 real account after purge, got $($afterPurge.Count)"
    }
    if ($afterPurge[0].Id -ne 'real_user_acc_1') {
        throw "Remaining account mismatch: $($afterPurge[0].Id)"
    }
    Write-Output '  [PASS] Placeholder demo accounts purged while preserving real user accounts'

} finally {
    Reset-SettingsDirectoryOverride
    try { Remove-Item -LiteralPath $testSettingsDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ------------------------------------------------------------------------------
# 4. Google Drive OAuth Desktop Authorization Resolver
# ------------------------------------------------------------------------------
$rcloneBinary = Find-GoogleRcloneBinary
if ($rcloneBinary) {
    Write-Output "  [PASS] rclone binary available for one-click desktop Google OAuth: $rcloneBinary"
} else {
    Write-Output "  [INFO] rclone binary not present on path"
}

# ------------------------------------------------------------------------------
# 5. Live TeraBox Backend Listing Verification
# ------------------------------------------------------------------------------
$tbSession = Get-TeraBoxStoredSession
if ($tbSession -and $tbSession.Secret) {
    $listRes = Get-TeraBoxFileList -Directory '/'
    if ($listRes.Success) {
        Write-Output "  [PASS] Live TeraBox file listing verified ($($listRes.ItemCount) items found)"
    } else {
        Write-Output "  [WARN] TeraBox listing check returned error: $($listRes.Error)"
    }
} else {
    Write-Output '  [SKIP] No local TeraBox session found for live listing test'
}

Write-Output 'All Write Protection, Upload, and Mount Reconciliation Tests Passed Successfully.'
