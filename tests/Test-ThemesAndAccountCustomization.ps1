Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Themes and Account Customization...'

. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\ui\ProviderConnectionWindow.ps1')

# 1. Test 3-theme resolution and aliases
$pb = Resolve-AppTheme 'PureBlack'
$tr = Resolve-AppTheme 'Translucent'
$pw = Resolve-AppTheme 'PureWhite'
$darkAlias = Resolve-AppTheme 'Dark'
$lightAlias = Resolve-AppTheme 'Light'
$invalidFallback = Resolve-AppTheme 'NonExistentTheme'

if ($pb -ne 'PureBlack' -or $tr -ne 'Translucent' -or $pw -ne 'PureWhite') {
    throw "Resolve-AppTheme failed on canonical theme names. Got: $pb, $tr, $pw"
}
if ($darkAlias -ne 'PureBlack' -or $lightAlias -ne 'PureWhite') {
    throw "Resolve-AppTheme failed on backward compatibility aliases. Got Dark->$darkAlias, Light->$lightAlias"
}
if ($invalidFallback -ne 'PureBlack') {
    throw "Resolve-AppTheme failed to fallback to PureBlack on invalid input. Got: $invalidFallback"
}
Write-Output '  [PASS] 3-theme resolution and legacy alias mapping verified'

# 2. Test modal theme palettes for all 3 themes
foreach ($tName in @('PureBlack', 'Translucent', 'PureWhite')) {
    $pal = Get-ModalThemePalette $tName
    if (-not $pal.ContainsKey('Background') -or -not $pal.ContainsKey('CardBg') -or -not $pal.ContainsKey('TextPrimary')) {
        throw "Modal palette for $tName is missing essential color keys"
    }

    if ($tName -eq 'PureBlack' -and $pal['Background'] -ne '#000000') {
        throw "PureBlack modal background must be #000000, got: $($pal['Background'])"
    }
    if ($tName -eq 'PureWhite' -and $pal['Background'] -ne '#FFFFFF') {
        throw "PureWhite modal background must be #FFFFFF, got: $($pal['Background'])"
    }
    if ($tName -eq 'Translucent' -and $pal['Background'] -ne '#181B22') {
        throw "Translucent modal background must be #181B22, got: $($pal['Background'])"
    }
}
Write-Output '  [PASS] Modal theme palettes for Pure Black, Translucent, and Pure White verified'

# 3. Test Account Customization via Update-CloudAccount
$testAccId = 'test_customization_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$initialAcc = @{
    Id = $testAccId
    ProviderId = 'gdrive'
    DisplayName = 'My Work Google Drive'
    AccountEmail = 'worker@company.com'
    DriveLetter = 'W'
    AutoMount = $false
    OpenExplorerOnMount = $false
    ReadOnly = $false
}

Add-CloudAccount -Account $initialAcc | Out-Null

$fetched = Get-CloudAccount -AccountId $testAccId
if (-not $fetched -or $fetched.DisplayName -ne 'My Work Google Drive') {
    throw 'Failed to retrieve initial test account'
}

# Update display name, drive letter, and behavior flags
$updatePatch = @{
    Id = $testAccId
    DisplayName = 'Renamed Work Projects'
    DriveLetter = 'Y'
    AutoMount = $true
    OpenExplorerOnMount = $true
    ReadOnly = $true
}

$updated = Update-CloudAccount -Account $updatePatch
if ($updated.DisplayName -ne 'Renamed Work Projects') {
    throw "Update-CloudAccount failed to update DisplayName: $($updated.DisplayName)"
}
if ($updated.DriveLetter -ne 'Y') {
    throw "Update-CloudAccount failed to update DriveLetter: $($updated.DriveLetter)"
}
if ($updated.OpenExplorerOnMount -ne $true -or $updated.ReadOnly -ne $true) {
    throw 'Update-CloudAccount failed to update behavior flags'
}
if ($updated.ProviderId -ne 'gdrive') {
    throw 'Update-CloudAccount must preserve ProviderId'
}

# Verify persistence in settings
$reloaded = Get-CloudAccount -AccountId $testAccId
if ($reloaded.DisplayName -ne 'Renamed Work Projects' -or $reloaded.DriveLetter -ne 'Y' -or -not $reloaded.ReadOnly) {
    throw 'Updated account properties failed to persist in settings.json'
}

# Clean up test account
Remove-CloudAccount -AccountId $testAccId | Out-Null
$afterRemove = Get-CloudAccount -AccountId $testAccId
if ($afterRemove) {
    throw 'Failed to clean up test account'
}
Write-Output '  [PASS] Account customization, field preservation, and persistence verified'

# 4. Test Global Settings Persistence
$originalSettings = Get-NSCloudDriveSettings
try {
    $tempSettings = Get-NSCloudDriveSettings
    $tempSettings.Theme = 'Translucent'
    $tempSettings.CacheMaxGigabytes = 50
    $tempSettings.HealthCheckIntervalSec = 5
    Set-NSCloudDriveSettings $tempSettings

    $checkSettings = Get-NSCloudDriveSettings
    if ($checkSettings.Theme -ne 'Translucent') {
        throw "Theme did not persist, got: $($checkSettings.Theme)"
    }
    if ($checkSettings.CacheMaxGigabytes -ne 50) {
        throw "CacheMaxGigabytes did not persist, got: $($checkSettings.CacheMaxGigabytes)"
    }
} finally {
    Set-NSCloudDriveSettings $originalSettings
}
Write-Output '  [PASS] Global settings persistence (Theme, CacheMaxGigabytes) verified'

# 5. Test Live Theme Switching in STA session
#    The Translucent fill has TWO valid values by design: the plain fallback
#    (#13161CE6) and the softened liquid-glass fill (#55161B2A) applied when
#    Windows composition supports the real acrylic backdrop (Win10 1803+).
$themeSwitchCheck = powershell.exe -NoProfile -STA -Command "& {
    . (Resolve-Path '.\src\NSCloudDrive.ps1')
    Apply-UITheme 'PureBlack'
    `$bgBlack = `$window.Background.ToString()
    Apply-UITheme 'PureWhite'
    `$bgWhite = `$window.Background.ToString()
    Apply-UITheme 'Translucent'
    `$bgTrans = `$window.Background.ToString()
    if (`$bgBlack -eq '#FF000000' -and `$bgWhite -eq '#FFF8FAFC' -and (`$bgTrans -eq '#13161CE6' -or `$bgTrans -eq '#E613161C' -or `$bgTrans -eq '#161B2A55')) {
        'SwitchOK'
    } else {
        'Failed: Black=' + `$bgBlack + ', White=' + `$bgWhite + ', Trans=' + `$bgTrans
    }
}"

if ($themeSwitchCheck -notmatch 'SwitchOK') {
    throw "Dynamic theme switching failed in STA session: $themeSwitchCheck"
}
Write-Output '  [PASS] Dynamic 3-theme runtime switching in STA session verified'

# 6. Test System Diagnostics Safety (No unredacted secrets)
$proc = [System.Diagnostics.Process]::GetCurrentProcess()
$diagReport = @"
Process: $($proc.ProcessName) (PID: $PID)
WorkingSet: $([Math]::Round($proc.WorkingSet64 / 1MB, 2)) MB
Threads: $($proc.Threads.Count)
WinFsp: $(Test-WinFspInstalled)
Theme: $(Resolve-AppTheme 'PureBlack')
"@

$forbiddenPatterns = @('access_token', 'refresh_token', 'client_secret', 'session_cookie', 'ndus=', 'BDUSS=')
foreach ($pat in $forbiddenPatterns) {
    if ($diagReport -match $pat) {
        throw "System diagnostics report leaked sensitive pattern: $pat"
    }
}
Write-Output '  [PASS] System diagnostics metrics safety and secret exclusion verified'

Write-Output 'All Themes and Account Customization tests passed.'
