Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SettingsDirectoryOverride = $null

function Set-SettingsDirectoryOverride([string]$Path) {
    $script:SettingsDirectoryOverride = $Path
}

function Reset-SettingsDirectoryOverride {
    $script:SettingsDirectoryOverride = $null
}

function Get-NSCloudDriveSettingsDirectory {
    if ($script:SettingsDirectoryOverride) {
        return $script:SettingsDirectoryOverride
    }
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config')
}

function Get-NSCloudDriveSettingsPath {
    return (Join-Path (Get-NSCloudDriveSettingsDirectory) 'settings.json')
}

function Resolve-AppTheme([string]$ThemeName) {
    if ([string]::IsNullOrWhiteSpace($ThemeName)) { return 'PureBlack' }
    $t = $ThemeName.Trim()
    if ($t -match '(?i)^pureblack$|^dark$') { return 'PureBlack' }
    if ($t -match '(?i)^translucent$|^acrylic$|^glass$') { return 'Translucent' }
    if ($t -match '(?i)^purewhite$|^light$|^white$') { return 'PureWhite' }
    return 'PureBlack'
}

function Get-DefaultSettings {
    return [ordered]@{
        AutoStartWithWindows = $true
        AutoMountDrives = $true
        MinimizeToTrayOnClose = $true
        StartMinimized = $false
        OpenExplorerOnMount = $true
        Theme = 'Light' # Default remains Light for backward compatibility; resolves to PureWhite. Supports PureBlack, Translucent, PureWhite
        CacheDirectory = 'D:\CloudCache'
        CacheMaxGigabytes = 20
        DiagnosticLogging = 'Normal'
        HealthCheckIntervalSec = 4
        ProviderDriveLetters = [ordered]@{
            gdrive = 'G'
            terabox = 'T'
        }
        Accounts = @()
    }
}

function ConvertTo-AccountCacheMaxGigabytes([object]$Value) {
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 1024) {
        return $parsed
    }
    return 0
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

        $accountsList = @()
        if ($json.PSObject.Properties['Accounts'] -and $json.Accounts) {
            foreach ($acc in $json.Accounts) {
                if ($acc -and $acc.PSObject.Properties['Id']) {
                    $accountsList += [ordered]@{
                        Id = [string]$acc.Id
                        ProviderId = [string]$acc.ProviderId
                        DisplayName = if ($acc.PSObject.Properties['DisplayName'] -and $acc.DisplayName) { [string]$acc.DisplayName } else { [string]$acc.Id }
                        AccountEmail = if ($acc.PSObject.Properties['AccountEmail'] -and $acc.AccountEmail) { [string]$acc.AccountEmail } else { '' }
                        DriveLetter = if ($acc.PSObject.Properties['DriveLetter'] -and $acc.DriveLetter) { [string]$acc.DriveLetter } else { '' }
                        AutoMount = if ($acc.PSObject.Properties['AutoMount'] -and $null -ne $acc.AutoMount) { [bool]$acc.AutoMount } else { $true }
                        OpenExplorerOnMount = if ($acc.PSObject.Properties['OpenExplorerOnMount'] -and $null -ne $acc.OpenExplorerOnMount) { [bool]$acc.OpenExplorerOnMount } else { $true }
                        ReadOnly = if ($acc.PSObject.Properties['ReadOnly'] -and $null -ne $acc.ReadOnly) { [bool]$acc.ReadOnly } else { $false }
                        CacheDirectory = if ($acc.PSObject.Properties['CacheDirectory'] -and $acc.CacheDirectory) { [string]$acc.CacheDirectory } else { '' }
                        CacheMaxGigabytes = if ($acc.PSObject.Properties['CacheMaxGigabytes']) { ConvertTo-AccountCacheMaxGigabytes $acc.CacheMaxGigabytes } else { 0 }
                        CustomIcon = if ($acc.PSObject.Properties['CustomIcon'] -and $acc.CustomIcon) { [string]$acc.CustomIcon } else { $null }
                        Created = if ($acc.PSObject.Properties['Created'] -and $acc.Created) { [string]$acc.Created } else { [DateTime]::UtcNow.ToString('o') }
                    }
                }
            }
        }

        $settings = [ordered]@{
            AutoStartWithWindows = if ($json.PSObject.Properties['AutoStartWithWindows'] -and $null -ne $json.AutoStartWithWindows) { [bool]$json.AutoStartWithWindows } else { $defaults.AutoStartWithWindows }
            AutoMountDrives = if ($json.PSObject.Properties['AutoMountDrives'] -and $null -ne $json.AutoMountDrives) { [bool]$json.AutoMountDrives } else { $defaults.AutoMountDrives }
            MinimizeToTrayOnClose = if ($json.PSObject.Properties['MinimizeToTrayOnClose'] -and $null -ne $json.MinimizeToTrayOnClose) { [bool]$json.MinimizeToTrayOnClose } else { $defaults.MinimizeToTrayOnClose }
            StartMinimized = if ($json.PSObject.Properties['StartMinimized'] -and $null -ne $json.StartMinimized) { [bool]$json.StartMinimized } else { $defaults.StartMinimized }
            OpenExplorerOnMount = if ($json.PSObject.Properties['OpenExplorerOnMount'] -and $null -ne $json.OpenExplorerOnMount) { [bool]$json.OpenExplorerOnMount } else { $defaults.OpenExplorerOnMount }
            Theme = if ($json.PSObject.Properties['Theme'] -and -not [string]::IsNullOrEmpty($json.Theme)) { [string]$json.Theme } else { $defaults.Theme }
            CacheDirectory = if ($json.PSObject.Properties['CacheDirectory'] -and -not [string]::IsNullOrEmpty($json.CacheDirectory)) { [string]$json.CacheDirectory } else { $defaults.CacheDirectory }
            CacheMaxGigabytes = if ($json.PSObject.Properties['CacheMaxGigabytes'] -and $null -ne $json.CacheMaxGigabytes) { [int]$json.CacheMaxGigabytes } else { $defaults.CacheMaxGigabytes }
            DiagnosticLogging = if ($json.PSObject.Properties['DiagnosticLogging'] -and -not [string]::IsNullOrEmpty($json.DiagnosticLogging)) { [string]$json.DiagnosticLogging } else { $defaults.DiagnosticLogging }
            HealthCheckIntervalSec = if ($json.PSObject.Properties['HealthCheckIntervalSec'] -and $null -ne $json.HealthCheckIntervalSec) { [int]$json.HealthCheckIntervalSec } else { $defaults.HealthCheckIntervalSec }
            ProviderDriveLetters = [ordered]@{
                gdrive = if ($json.PSObject.Properties['ProviderDriveLetters'] -and $json.ProviderDriveLetters -and $json.ProviderDriveLetters.PSObject.Properties['gdrive']) { [string]$json.ProviderDriveLetters.gdrive } else { 'G' }
                terabox = if ($json.PSObject.Properties['ProviderDriveLetters'] -and $json.ProviderDriveLetters -and $json.ProviderDriveLetters.PSObject.Properties['terabox']) { [string]$json.ProviderDriveLetters.terabox } else { 'T' }
            }
            Accounts = $accountsList
        }
        return $settings
    } catch {
        throw "Unable to load saved settings from '$settingsPath'. The original file was preserved: $($_.Exception.Message)"
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
    $tempSuffix = [Guid]::NewGuid().ToString('N')
    $tempPath = "$settingsPath.$tempSuffix.tmp"
    $backupPath = "$settingsPath.$tempSuffix.bak"
    try {
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($settingsPath)) {
            [System.IO.File]::Replace($tempPath, $settingsPath, $backupPath)
        } else {
            [System.IO.File]::Move($tempPath, $settingsPath)
        }
    } finally {
        if ([System.IO.File]::Exists($tempPath)) {
            [System.IO.File]::Delete($tempPath)
        }
        if ([System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
    }
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

function Get-CloudAccounts {
    $settings = Get-NSCloudDriveSettings
    $list = @()
    if ($settings.Accounts -and $settings.Accounts.Count -gt 0) {
        foreach ($acc in $settings.Accounts) {
            $item = [ordered]@{
                Id = [string]$acc.Id
                ProviderId = [string]$acc.ProviderId
                DisplayName = [string]$acc.DisplayName
                AccountEmail = [string]$acc.AccountEmail
                DriveLetter = [string]$acc.DriveLetter
                AutoMount = if ($null -ne $acc.AutoMount) { [bool]$acc.AutoMount } else { $true }
                OpenExplorerOnMount = if ($acc.Contains('OpenExplorerOnMount') -and $null -ne $acc.OpenExplorerOnMount) { [bool]$acc.OpenExplorerOnMount } else { $true }
                ReadOnly = if ($acc.Contains('ReadOnly') -and $null -ne $acc.ReadOnly) { [bool]$acc.ReadOnly } else { $false }
                CacheDirectory = if ($acc.Contains('CacheDirectory') -and $acc.CacheDirectory) { [string]$acc.CacheDirectory } else { '' }
                CacheMaxGigabytes = if ($acc.Contains('CacheMaxGigabytes')) { ConvertTo-AccountCacheMaxGigabytes $acc.CacheMaxGigabytes } else { 0 }
                CustomIcon = if ($acc.Contains('CustomIcon') -and $acc.CustomIcon) { [string]$acc.CustomIcon } else { $null }
                Created = if ($acc.Created) { [string]$acc.Created } else { [DateTime]::UtcNow.ToString('o') }
            }
            $list += $item
        }
    }
    if ($list.Count -eq 0) {
        return @()
    }
    return ,$list
}

function Get-CloudAccount([string]$AccountId) {
    if (-not $AccountId) { return $null }
    $accounts = Get-CloudAccounts
    foreach ($a in $accounts) {
        if ($a.Id -eq $AccountId) {
            return $a
        }
    }
    return $null
}

function Test-CloudAccountPersisted([string]$AccountId) {
    if ([string]::IsNullOrWhiteSpace($AccountId)) { return $false }
    return ($null -ne (Get-CloudAccount -AccountId $AccountId))
}

function Test-CloudAccountDriveLetterAvailable([string]$DriveLetter, [string]$ExcludeAccountId = '') {
    $letter = ([string]$DriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter -notmatch '^[A-Z]$') { throw 'Choose a single valid drive letter before saving this account.' }
    foreach ($savedAccount in (Get-CloudAccounts)) {
        if (-not [string]::IsNullOrWhiteSpace($ExcludeAccountId) -and [string]$savedAccount.Id -eq $ExcludeAccountId) { continue }
        $savedLetter = ([string]$savedAccount.DriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\')
        if ($savedLetter -eq $letter) {
            throw "Drive letter $letter`: is already assigned to '$($savedAccount.DisplayName)'. Choose a different letter."
        }
    }
    return $true
}

function Add-CloudAccount([hashtable]$Account) {
    if (-not $Account -or -not $Account.ContainsKey('Id') -or -not $Account.Id) {
        throw 'Account with valid Id is required.'
    }

    $settings = Get-NSCloudDriveSettings
    if (@($settings.Accounts | Where-Object { [string]$_.Id -eq [string]$Account.Id }).Count -gt 0) {
        throw "An account with Id '$($Account.Id)' is already saved. Existing account was left unchanged."
    }
    $accounts = @($settings.Accounts)

    $cleanLetter = if ($Account.ContainsKey('DriveLetter') -and $Account.DriveLetter) {
        [string]$Account.DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    } else {
        ''
    }
    Test-CloudAccountDriveLetterAvailable -DriveLetter $cleanLetter | Out-Null

    $item = [ordered]@{
        Id = [string]$Account.Id
        ProviderId = [string]$Account.ProviderId
        DisplayName = if ($Account.ContainsKey('DisplayName') -and $Account.DisplayName) { [string]$Account.DisplayName } else { [string]$Account.Id }
        AccountEmail = if ($Account.ContainsKey('AccountEmail') -and $Account.AccountEmail) { [string]$Account.AccountEmail } else { '' }
        DriveLetter = $cleanLetter
        AutoMount = if ($Account.ContainsKey('AutoMount') -and $null -ne $Account.AutoMount) { [bool]$Account.AutoMount } else { $true }
        OpenExplorerOnMount = if ($Account.ContainsKey('OpenExplorerOnMount') -and $null -ne $Account.OpenExplorerOnMount) { [bool]$Account.OpenExplorerOnMount } else { $true }
        ReadOnly = if ($Account.ContainsKey('ReadOnly') -and $null -ne $Account.ReadOnly) { [bool]$Account.ReadOnly } else { $false }
        CacheDirectory = if ($Account.ContainsKey('CacheDirectory') -and $Account.CacheDirectory) { [string]$Account.CacheDirectory } else { '' }
        CacheMaxGigabytes = if ($Account.ContainsKey('CacheMaxGigabytes')) { ConvertTo-AccountCacheMaxGigabytes $Account.CacheMaxGigabytes } else { 0 }
        CustomIcon = if ($Account.ContainsKey('CustomIcon') -and $Account.CustomIcon) { [string]$Account.CustomIcon } else { $null }
        Created = if ($Account.ContainsKey('Created') -and $Account.Created) { [string]$Account.Created } else { [DateTime]::UtcNow.ToString('o') }
    }

    $accounts += $item
    $settings.Accounts = $accounts
    Set-NSCloudDriveSettings $settings
    return $item
}

function Update-CloudAccount([hashtable]$Account) {
    if (-not $Account -or -not $Account.ContainsKey('Id') -or -not $Account.Id) {
        throw 'Account with valid Id is required for update.'
    }
    $targetId = [string]$Account.Id
    $existing = Get-CloudAccount $targetId
    if (-not $existing) {
        throw "Account with Id '$targetId' does not exist."
    }

    $cleanLetter = if ($Account.ContainsKey('DriveLetter') -and $Account.DriveLetter) {
        [string]$Account.DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    } else {
        $existing.DriveLetter
    }
    Test-CloudAccountDriveLetterAvailable -DriveLetter $cleanLetter -ExcludeAccountId $targetId | Out-Null

    # Merge properties while preserving account Id, ProviderId, and Created
    $merged = [ordered]@{
        Id = $existing.Id
        ProviderId = $existing.ProviderId
        DisplayName = if ($Account.ContainsKey('DisplayName') -and $Account.DisplayName) { [string]$Account.DisplayName } else { $existing.DisplayName }
        AccountEmail = if ($Account.ContainsKey('AccountEmail') -and $null -ne $Account.AccountEmail) { [string]$Account.AccountEmail } else { $existing.AccountEmail }
        DriveLetter = $cleanLetter
        AutoMount = if ($Account.ContainsKey('AutoMount') -and $null -ne $Account.AutoMount) { [bool]$Account.AutoMount } else { $existing.AutoMount }
        OpenExplorerOnMount = if ($Account.ContainsKey('OpenExplorerOnMount') -and $null -ne $Account.OpenExplorerOnMount) { [bool]$Account.OpenExplorerOnMount } elseif ($existing.Contains('OpenExplorerOnMount')) { [bool]$existing.OpenExplorerOnMount } else { $true }
        ReadOnly = if ($Account.ContainsKey('ReadOnly') -and $null -ne $Account.ReadOnly) { [bool]$Account.ReadOnly } elseif ($existing.Contains('ReadOnly')) { [bool]$existing.ReadOnly } else { $false }
        CacheDirectory = if ($Account.ContainsKey('CacheDirectory') -and $Account.CacheDirectory) { [string]$Account.CacheDirectory } elseif ($existing.Contains('CacheDirectory')) { [string]$existing.CacheDirectory } else { '' }
        CacheMaxGigabytes = if ($Account.ContainsKey('CacheMaxGigabytes')) { ConvertTo-AccountCacheMaxGigabytes $Account.CacheMaxGigabytes } elseif ($existing.Contains('CacheMaxGigabytes')) { [int]$existing.CacheMaxGigabytes } else { 0 }
        CustomIcon = if ($Account.ContainsKey('CustomIcon') -and $Account.CustomIcon) { [string]$Account.CustomIcon } elseif ($existing.Contains('CustomIcon')) { $existing.CustomIcon } else { $null }
        Created = $existing.Created
    }

    $settings = Get-NSCloudDriveSettings
    $newAccounts = @()
    foreach ($a in $settings.Accounts) {
        if ($a.Id -eq $targetId) {
            $newAccounts += $merged
        } else {
            $newAccounts += $a
        }
    }
    $settings.Accounts = $newAccounts
    Set-NSCloudDriveSettings $settings
    return $merged
}

function Remove-CloudAccount([string]$AccountId) {
    if (-not $AccountId) { return $false }
    $settings = Get-NSCloudDriveSettings
    $accounts = @()
    $found = $false
    if ($settings.Accounts) {
        foreach ($a in $settings.Accounts) {
            if ($a.Id -eq $AccountId) {
                $found = $true
            } else {
                $accounts += $a
            }
        }
    }
    if ($found) {
        $settings.Accounts = $accounts
        Set-NSCloudDriveSettings $settings
    }
    return $found
}

function Remove-SeededPlaceholderAccounts {
    $settings = Get-NSCloudDriveSettings
    $cleaned = @()
    $changed = $false
    if ($settings.Accounts) {
        foreach ($a in $settings.Accounts) {
            $isPlaceholder = ($a.Id -like 'test_*' -or $a.AccountEmail -in @('personal@gmail.com', 'work@company.com', 'terabox_user'))
            if ($isPlaceholder) {
                $changed = $true
            } else {
                $cleaned += $a
            }
        }
    }
    if ($changed) {
        $settings.Accounts = $cleaned
        Set-NSCloudDriveSettings $settings
    }
    return $cleaned
}

function Get-AllocatedDriveLetters {
    $accounts = Get-CloudAccounts
    $letters = @()
    foreach ($acc in $accounts) {
        if ($acc.DriveLetter) {
            $clean = [string]$acc.DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
            if ($clean.Length -eq 1 -and $clean -match '^[A-Z]$' -and -not ($letters -contains $clean)) {
                $letters += $clean
            }
        }
    }
    if ($letters.Count -eq 0) {
        return @()
    }
    return ,$letters
}

function Get-NextAvailableDriveLetter([string]$Preferred = 'G') {
    $occupied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            [void]$occupied.Add($d.Name.Substring(0, 1).ToUpperInvariant())
        }
    } catch { }

    $allocated = Get-AllocatedDriveLetters
    foreach ($a in $allocated) {
        if (-not [string]::IsNullOrWhiteSpace($a)) {
            [void]$occupied.Add($a.Substring(0, 1).ToUpperInvariant())
        }
    }

    $cleanPref = $Preferred.Trim().TrimEnd(':').TrimEnd('\').ToUpperInvariant()
    if ($cleanPref.Length -eq 1 -and $cleanPref -match '^[A-Z]$' -and -not $occupied.Contains($cleanPref)) {
        return $cleanPref
    }

    $candidates = @('G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z','E','F')
    foreach ($cand in $candidates) {
        if (-not $occupied.Contains($cand)) {
            return $cand
        }
    }

    return 'Z'
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
