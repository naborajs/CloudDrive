Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NSCloudDriveSettingsDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config')
}

function Get-NSCloudDriveSettingsPath {
    return (Join-Path (Get-NSCloudDriveSettingsDirectory) 'settings.json')
}

function Get-DefaultSettings {
    return [ordered]@{
        AutoStartWithWindows = $true
        AutoMountDrives = $true
        MinimizeToTrayOnClose = $true
        StartMinimized = $false
        OpenExplorerOnMount = $true
        Theme = 'Light'
        CacheDirectory = 'D:\CloudCache'
        ProviderDriveLetters = [ordered]@{
            gdrive = 'G'
            terabox = 'T'
        }
    }
}

function Get-NSCloudDriveSettings {
    $settingsPath = Get-NSCloudDriveSettingsPath
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return (Get-DefaultSettings)
    }

    try {
        $raw = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json
        $defaults = Get-DefaultSettings

        $settings = [ordered]@{
            AutoStartWithWindows = if ($json.PSObject.Properties['AutoStartWithWindows'] -and $null -ne $json.AutoStartWithWindows) { [bool]$json.AutoStartWithWindows } else { $defaults.AutoStartWithWindows }
            AutoMountDrives = if ($json.PSObject.Properties['AutoMountDrives'] -and $null -ne $json.AutoMountDrives) { [bool]$json.AutoMountDrives } else { $defaults.AutoMountDrives }
            MinimizeToTrayOnClose = if ($json.PSObject.Properties['MinimizeToTrayOnClose'] -and $null -ne $json.MinimizeToTrayOnClose) { [bool]$json.MinimizeToTrayOnClose } else { $defaults.MinimizeToTrayOnClose }
            StartMinimized = if ($json.PSObject.Properties['StartMinimized'] -and $null -ne $json.StartMinimized) { [bool]$json.StartMinimized } else { $defaults.StartMinimized }
            OpenExplorerOnMount = if ($json.PSObject.Properties['OpenExplorerOnMount'] -and $null -ne $json.OpenExplorerOnMount) { [bool]$json.OpenExplorerOnMount } else { $defaults.OpenExplorerOnMount }
            Theme = if ($json.PSObject.Properties['Theme'] -and -not [string]::IsNullOrEmpty($json.Theme)) { [string]$json.Theme } else { $defaults.Theme }
            CacheDirectory = if ($json.PSObject.Properties['CacheDirectory'] -and -not [string]::IsNullOrEmpty($json.CacheDirectory)) { [string]$json.CacheDirectory } else { $defaults.CacheDirectory }
            ProviderDriveLetters = [ordered]@{
                gdrive = if ($json.PSObject.Properties['ProviderDriveLetters'] -and $json.ProviderDriveLetters -and $json.ProviderDriveLetters.PSObject.Properties['gdrive']) { [string]$json.ProviderDriveLetters.gdrive } else { 'G' }
                terabox = if ($json.PSObject.Properties['ProviderDriveLetters'] -and $json.ProviderDriveLetters -and $json.ProviderDriveLetters.PSObject.Properties['terabox']) { [string]$json.ProviderDriveLetters.terabox } else { 'T' }
            }
        }
        return $settings
    } catch {
        return (Get-DefaultSettings)
    }
}

function Set-NSCloudDriveSettings([hashtable]$Settings) {
    if (-not $Settings) { throw 'Settings hashtable cannot be null.' }

    $settingsDir = Get-NSCloudDriveSettingsDirectory
    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }

    $settingsPath = Get-NSCloudDriveSettingsPath
    $json = $Settings | ConvertTo-Json -Depth 4
    Set-Content -LiteralPath $settingsPath -Value $json -Encoding UTF8 -Force
}

function Get-PreferredDriveLetter([string]$ProviderId) {
    $settings = Get-NSCloudDriveSettings
    if ($settings.ProviderDriveLetters -and $settings.ProviderDriveLetters[$ProviderId]) {
        return [string]$settings.ProviderDriveLetters[$ProviderId]
    }
    if ($ProviderId -eq 'gdrive') { return 'G' }
    if ($ProviderId -eq 'terabox') { return 'T' }
    return 'V'
}

function Set-PreferredDriveLetter([string]$ProviderId, [string]$Letter) {
    $cleanLetter = $Letter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($cleanLetter.Length -ne 1 -or $cleanLetter -notmatch '^[A-Z]$') {
        throw "Invalid drive letter: $Letter"
    }

    $settings = Get-NSCloudDriveSettings
    if (-not $settings.ProviderDriveLetters) {
        $settings.ProviderDriveLetters = [ordered]@{}
    }
    $settings.ProviderDriveLetters[$ProviderId] = $cleanLetter
    Set-NSCloudDriveSettings $settings
}

function Test-WindowsStartupEnabled {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path -LiteralPath $runKey) {
        $props = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
        if ($props -and $props.PSObject.Properties.Name -contains 'NSCloudDrive') {
            $val = $props.NSCloudDrive
            return (-not [string]::IsNullOrEmpty([string]$val))
        }
    }
    return $false
}

function Set-WindowsStartupEnabled([bool]$Enable, [string]$ScriptPath = '') {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runKey)) {
        New-Item -Path $runKey -Force | Out-Null
    }

    if ($Enable) {
        $targetScript = if (-not [string]::IsNullOrEmpty($ScriptPath)) {
            $ScriptPath
        } else {
            (Join-Path $PSScriptRoot '..\NSCloudDrive.ps1')
        }
        $targetScript = [System.IO.Path]::GetFullPath($targetScript)
        $commandValue = "`"powershell.exe`" -NoProfile -WindowStyle Hidden -STA -File `"$targetScript`" -Minimized"
        Set-ItemProperty -LiteralPath $runKey -Name 'NSCloudDrive' -Value $commandValue -Type String
    } else {
        Remove-ItemProperty -LiteralPath $runKey -Name 'NSCloudDrive' -ErrorAction SilentlyContinue
    }
}
