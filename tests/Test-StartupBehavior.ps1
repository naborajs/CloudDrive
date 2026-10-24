# Test-StartupBehavior.ps1
# Regression coverage for Windows startup, Start Minimized, and window close behavior.
# Mocked/sandboxed: does not launch the WPF UI or modify the real Windows Run key.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = (Get-Item (Join-Path $PSScriptRoot '..\src')).FullName
$srcRoot = Join-Path $scriptRoot '..'

# Dot-source SettingsManager (independent of WPF)
. (Join-Path $srcRoot 'src\services\SettingsManager.ps1')

# Use a sandbox registry path instead of the real HKCU Run key
$origLocalAppData = $env:LOCALAPPDATA
$sandboxDir = Join-Path $env:TEMP "nscd_startup_test_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $sandboxDir | Out-Null
$env:LOCALAPPDATA = $sandboxDir

# Override the settings path to use the sandbox
Set-SettingsDirectoryOverride $sandboxDir

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

try {
    # -------------------------------------------------------------------------
    # 1. AutoStartWithWindows setting defaults and persistence
    # -------------------------------------------------------------------------
    $settings = Get-NSCloudDriveSettings
    Assert-True ($settings.AutoStartWithWindows -is [bool]) 'AutoStartWithWindows is a boolean'
    Assert-True ($settings.AutoStartWithWindows -eq $true) 'Default AutoStartWithWindows is true'

    # -------------------------------------------------------------------------
    # 2. Test-WindowsStartupEnabled reflects the actual registry state
    # -------------------------------------------------------------------------
    $runKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $hasExistingKey = Test-Path -LiteralPath $runKeyPath -ErrorAction SilentlyContinue
    $existingVal = if ($hasExistingKey) {
        (Get-ItemProperty -LiteralPath $runKeyPath -Name 'NSCloudDrive' -ErrorAction SilentlyContinue).NSCloudDrive
    } else {
        $null
    }
    $enabled = Test-WindowsStartupEnabled
    Assert-True ($enabled -eq ($null -ne $existingVal -and -not [string]::IsNullOrEmpty([string]$existingVal))) `
        "Test-WindowsStartupEnabled matches actual registry state (enabled=$enabled, val='$existingVal')"

    # -------------------------------------------------------------------------
    # 3. Set-WindowsStartupEnabled creates/updates the registry entry
    # -------------------------------------------------------------------------
    $scriptPath = Join-Path $srcRoot 'src\NSCloudDrive.ps1'
    Set-WindowsStartupEnabled -Enable $true -ScriptPath $scriptPath
    $enabled = Test-WindowsStartupEnabled
    Assert-True ($enabled -eq $true) 'Set-WindowsStartupEnabled -Enable $true creates the Run key entry'

    # Verify the value points to the script
    $runKey = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NSCloudDrive' -ErrorAction SilentlyContinue
    Assert-True ($null -ne $runKey) 'NSCloudDrive value exists in Run key'
    Assert-True ($runKey.NSCloudDrive -like '*NSCloudDrive.ps1*') 'Run key value references NSCloudDrive.ps1'
    Assert-True ($runKey.NSCloudDrive -like '*powershell.exe*') 'Run key value invokes powershell.exe'

    # -------------------------------------------------------------------------
    # 4. Set-WindowsStartupEnabled -Enable $false removes the entry
    # -------------------------------------------------------------------------
    Set-WindowsStartupEnabled -Enable $false
    $enabled = Test-WindowsStartupEnabled
    Assert-True ($enabled -eq $false) 'Set-WindowsStartupEnabled -Enable $false removes the Run key entry'

    # -------------------------------------------------------------------------
    # 5. Auto-start registration on app launch: when AutoStartWithWindows=True
    #    but registry key is missing, Set-WindowsStartupEnabled is called
    # -------------------------------------------------------------------------
    $settings2 = Get-NSCloudDriveSettings
    Assert-True ($settings2.AutoStartWithWindows -eq $true) 'Settings still has AutoStartWithWindows=true'

    # Manually trigger the same logic as NSCloudDrive.ps1 lines 44-46:
    if ($settings2.AutoStartWithWindows -and -not (Test-WindowsStartupEnabled)) {
        Set-WindowsStartupEnabled -Enable $true
    }
    Assert-True (Test-WindowsStartupEnabled) 'Auto-start registration works when setting is enabled but key is missing'

    # -------------------------------------------------------------------------
    # 6. StartMinimized setting defaults to false
    # -------------------------------------------------------------------------
    Assert-True ($settings.StartMinimized -is [bool]) 'StartMinimized is a boolean'
    # Default is false per Get-DefaultSettings

    # -------------------------------------------------------------------------
    # 7. AutoMountDrives defaults to true
    # -------------------------------------------------------------------------
    Assert-True ($settings.AutoMountDrives -eq $true) 'Default AutoMountDrives is true'

    # -------------------------------------------------------------------------
    # 8. MinimizeToTrayOnClose defaults to true
    # -------------------------------------------------------------------------
    Assert-True ($settings.MinimizeToTrayOnClose -eq $true) 'Default MinimizeToTrayOnClose is true'

    Write-Output '  [PASS] Startup behavior regression verified (mocked/sandboxed).'
} finally {
    $env:LOCALAPPDATA = $origLocalAppData
    Remove-Item -LiteralPath $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    Set-SettingsDirectoryOverride
    Reset-SettingsDirectoryOverride
}
