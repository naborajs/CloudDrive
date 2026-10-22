Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')

Write-Output 'Testing SettingsManager...'

# Sandbox LOCALAPPDATA to isolate settings testing
$origGlobalLocalAppData = $env:LOCALAPPDATA
$globalSandboxDir = Join-Path $env:TEMP "settings_test_sandbox_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $globalSandboxDir | Out-Null
$env:LOCALAPPDATA = $globalSandboxDir

try {
    # 1. Test defaults when no settings.json exists
    $settings = Get-NSCloudDriveSettings
    if (-not $settings.AutoStartWithWindows) { throw 'Expected AutoStartWithWindows to default to true' }
    if (-not $settings.AutoMountDrives) { throw 'Expected AutoMountDrives to default to true' }
    if (-not $settings.MinimizeToTrayOnClose) { throw 'Expected MinimizeToTrayOnClose to default to true' }
    if ($settings.StartMinimized -ne $false) { throw 'Expected StartMinimized to default to false' }
    if ($settings.OpenExplorerOnMount -ne $true) { throw 'Expected OpenExplorerOnMount to default to true' }
    if ($settings.Theme -ne 'Light') { throw "Expected Theme to default to Light, got $($settings.Theme)" }
    if ($settings.CacheDirectory -ne 'D:\CloudCache') { throw "Expected CacheDirectory to default to D:\CloudCache, got $($settings.CacheDirectory)" }
    if ($settings.ProviderDriveLetters.gdrive -ne 'G') { throw "Expected gdrive to default to G, got $($settings.ProviderDriveLetters.gdrive)" }
    if ($settings.ProviderDriveLetters.terabox -ne 'T') { throw "Expected terabox to default to T, got $($settings.ProviderDriveLetters.terabox)" }
    Write-Output '  [PASS] Default settings verified'

    # 2. Test saving and reloading custom settings
    $custom = [ordered]@{
        AutoStartWithWindows = $false
        AutoMountDrives = $false
        MinimizeToTrayOnClose = $false
        StartMinimized = $true
        OpenExplorerOnMount = $false
        Theme = 'Dark'
        CacheDirectory = 'D:\CloudCache\Custom'
        ProviderDriveLetters = [ordered]@{
            gdrive = 'S'
            terabox = 'X'
        }
    }
    Set-NSCloudDriveSettings $custom

    $reloaded = Get-NSCloudDriveSettings
    if ($reloaded.AutoStartWithWindows -ne $false) { throw 'Expected AutoStartWithWindows to be false' }
    if ($reloaded.AutoMountDrives -ne $false) { throw 'Expected AutoMountDrives to be false' }
    if ($reloaded.StartMinimized -ne $true) { throw 'Expected StartMinimized to be true' }
    if ($reloaded.OpenExplorerOnMount -ne $false) { throw 'Expected OpenExplorerOnMount to be false' }
    if ($reloaded.Theme -ne 'Dark') { throw 'Expected Theme to be Dark' }
    if ($reloaded.CacheDirectory -ne 'D:\CloudCache\Custom') { throw 'Expected CacheDirectory to match custom value' }
    if ($reloaded.ProviderDriveLetters.gdrive -ne 'S') { throw 'Expected gdrive to be S' }
    if ($reloaded.ProviderDriveLetters.terabox -ne 'X') { throw 'Expected terabox to be X' }
    Write-Output '  [PASS] Custom settings persistence verified'

    # 3. Test Get-PreferredDriveLetter and Set-PreferredDriveLetter
    $gdriveLetter = Get-PreferredDriveLetter 'gdrive'
    if ($gdriveLetter -ne 'S') { throw "Expected S, got $gdriveLetter" }

    Set-PreferredDriveLetter 'gdrive' 'Z:'
    $updatedLetter = Get-PreferredDriveLetter 'gdrive'
    if ($updatedLetter -ne 'Z') { throw "Expected Z, got $updatedLetter" }

    # Test invalid letter throws
    $threwInvalid = $false
    try {
        Set-PreferredDriveLetter 'gdrive' 'ZZ'
    } catch {
        $threwInvalid = $true
    }
    if (-not $threwInvalid) { throw 'Expected invalid drive letter to throw' }
    Write-Output '  [PASS] Preferred drive letter get/set and validation verified'

    # 4. Test Windows Startup registry configuration (enable and clean up)
    $wasEnabled = Test-WindowsStartupEnabled
    try {
        Set-WindowsStartupEnabled -Enable $true -ScriptPath 'C:\Test\NSCloudDrive.ps1'
        if (-not (Test-WindowsStartupEnabled)) {
            throw 'Expected Test-WindowsStartupEnabled to return true after enabling'
        }
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $val = (Get-ItemProperty -LiteralPath $runKey -Name 'NSCloudDrive').NSCloudDrive
        if ($val -notmatch 'NSCloudDrive\.ps1' -or $val -notmatch '-Minimized') {
            throw "Startup command string malformed: $val"
        }

        Set-WindowsStartupEnabled -Enable $false
        if (Test-WindowsStartupEnabled) {
            throw 'Expected Test-WindowsStartupEnabled to return false after disabling'
        }
        Write-Output '  [PASS] Windows Startup registration and cleanup verified'
    } finally {
        # Restore original state if previously enabled
        if ($wasEnabled) {
            Set-WindowsStartupEnabled -Enable $true
        } else {
            Set-WindowsStartupEnabled -Enable $false
        }
    }

} finally {
    $env:LOCALAPPDATA = $origGlobalLocalAppData
    Remove-Item -LiteralPath $globalSandboxDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All SettingsManager tests passed.'
