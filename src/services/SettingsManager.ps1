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
        EnableNotifications = $true
        NotifyOnUploadStart = $true
        NotifyOnUploadComplete = $true
        NotifyOnBackgroundSync = $true
        GroupFolderUploads = $true
        NotifyOnlyFullFolder = $true
        MinNotificationFileSizeBytes = 5242880 # 5 MB default threshold
        NotificationSnoozeUntilUtc = ''
        Accounts = @()

        # Bandwidth & Network Management
        BandwidthPolicy = 'Unlimited' # 'Unlimited', 'Limited', 'MinimalBackground', 'Adaptive', 'Custom'
        BandwidthLimitPreset = '5 MB/s' # '256 KB/s', '512 KB/s', '1 MB/s', '2 MB/s', '5 MB/s', '10 MB/s', 'Custom'
        CustomUploadLimitValue = 5
        CustomUploadLimitUnit = 'MB/s' # 'MB/s', 'KB/s'
        AdaptiveSensitivity = 'Balanced' # 'Conservative', 'Balanced', 'Aggressive'
        DetectGamingTraffic = $false
        ContinueUploadingWhileMinimized = $true
        RespectLimitsInTray = $true
        KeepTransfersAliveInTray = $true

        # Post-Transfer Cache Cleanup
        PostTransferCachePolicy = 'KeepCache' # 'KeepCache', 'RemoveAfterVerifiedUpload', 'CustomRetention'
        PostTransferRetentionMinutes = 60

        # UI Presentation Order
        CardDisplayOrder = @()
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
            EnableNotifications = if ($json.PSObject.Properties['EnableNotifications'] -and $null -ne $json.EnableNotifications) { [bool]$json.EnableNotifications } else { $defaults.EnableNotifications }
            NotifyOnUploadStart = if ($json.PSObject.Properties['NotifyOnUploadStart'] -and $null -ne $json.NotifyOnUploadStart) { [bool]$json.NotifyOnUploadStart } else { $defaults.NotifyOnUploadStart }
            NotifyOnUploadComplete = if ($json.PSObject.Properties['NotifyOnUploadComplete'] -and $null -ne $json.NotifyOnUploadComplete) { [bool]$json.NotifyOnUploadComplete } else { $defaults.NotifyOnUploadComplete }
            NotifyOnBackgroundSync = if ($json.PSObject.Properties['NotifyOnBackgroundSync'] -and $null -ne $json.NotifyOnBackgroundSync) { [bool]$json.NotifyOnBackgroundSync } else { $defaults.NotifyOnBackgroundSync }
            GroupFolderUploads = if ($json.PSObject.Properties['GroupFolderUploads'] -and $null -ne $json.GroupFolderUploads) { [bool]$json.GroupFolderUploads } else { $defaults.GroupFolderUploads }
            NotifyOnlyFullFolder = if ($json.PSObject.Properties['NotifyOnlyFullFolder'] -and $null -ne $json.NotifyOnlyFullFolder) { [bool]$json.NotifyOnlyFullFolder } else { $defaults.NotifyOnlyFullFolder }
            MinNotificationFileSizeBytes = if ($json.PSObject.Properties['MinNotificationFileSizeBytes'] -and $null -ne $json.MinNotificationFileSizeBytes) { [int64]$json.MinNotificationFileSizeBytes } else { $defaults.MinNotificationFileSizeBytes }
            NotificationSnoozeUntilUtc = if ($json.PSObject.Properties['NotificationSnoozeUntilUtc'] -and -not [string]::IsNullOrEmpty($json.NotificationSnoozeUntilUtc)) { [string]$json.NotificationSnoozeUntilUtc } else { $defaults.NotificationSnoozeUntilUtc }
            Accounts = $accountsList

            # Bandwidth & Network Management
            BandwidthPolicy = if ($json.PSObject.Properties['BandwidthPolicy'] -and -not [string]::IsNullOrEmpty($json.BandwidthPolicy)) { [string]$json.BandwidthPolicy } else { $defaults.BandwidthPolicy }
            BandwidthLimitPreset = if ($json.PSObject.Properties['BandwidthLimitPreset'] -and -not [string]::IsNullOrEmpty($json.BandwidthLimitPreset)) { [string]$json.BandwidthLimitPreset } else { $defaults.BandwidthLimitPreset }
            CustomUploadLimitValue = if ($json.PSObject.Properties['CustomUploadLimitValue'] -and $null -ne $json.CustomUploadLimitValue) { [int]$json.CustomUploadLimitValue } else { $defaults.CustomUploadLimitValue }
            CustomUploadLimitUnit = if ($json.PSObject.Properties['CustomUploadLimitUnit'] -and -not [string]::IsNullOrEmpty($json.CustomUploadLimitUnit)) { [string]$json.CustomUploadLimitUnit } else { $defaults.CustomUploadLimitUnit }
            AdaptiveSensitivity = if ($json.PSObject.Properties['AdaptiveSensitivity'] -and -not [string]::IsNullOrEmpty($json.AdaptiveSensitivity)) { [string]$json.AdaptiveSensitivity } else { $defaults.AdaptiveSensitivity }
            DetectGamingTraffic = if ($json.PSObject.Properties['DetectGamingTraffic'] -and $null -ne $json.DetectGamingTraffic) { [bool]$json.DetectGamingTraffic } else { $defaults.DetectGamingTraffic }
            ContinueUploadingWhileMinimized = if ($json.PSObject.Properties['ContinueUploadingWhileMinimized'] -and $null -ne $json.ContinueUploadingWhileMinimized) { [bool]$json.ContinueUploadingWhileMinimized } else { $defaults.ContinueUploadingWhileMinimized }
            RespectLimitsInTray = if ($json.PSObject.Properties['RespectLimitsInTray'] -and $null -ne $json.RespectLimitsInTray) { [bool]$json.RespectLimitsInTray } else { $defaults.RespectLimitsInTray }
            KeepTransfersAliveInTray = if ($json.PSObject.Properties['KeepTransfersAliveInTray'] -and $null -ne $json.KeepTransfersAliveInTray) { [bool]$json.KeepTransfersAliveInTray } else { $defaults.KeepTransfersAliveInTray }

            # Post-Transfer Cache Cleanup
            PostTransferCachePolicy = if ($json.PSObject.Properties['PostTransferCachePolicy'] -and -not [string]::IsNullOrEmpty($json.PostTransferCachePolicy)) { [string]$json.PostTransferCachePolicy } else { $defaults.PostTransferCachePolicy }
            PostTransferRetentionMinutes = if ($json.PSObject.Properties['PostTransferRetentionMinutes'] -and $null -ne $json.PostTransferRetentionMinutes) { [int]$json.PostTransferRetentionMinutes } else { $defaults.PostTransferRetentionMinutes }

            # UI Presentation Order
            CardDisplayOrder = if ($json.PSObject.Properties['CardDisplayOrder'] -and $json.CardDisplayOrder) { @($json.CardDisplayOrder | ForEach-Object { [string]$_ }) } else { @() }
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
    # Short-circuit cache: settings.json is read from disk on every call, so
    # cache the normalized account list for a short TTL to avoid repeated
    # file reads during UI refresh ticks. Invalidated by Clear-AccountListCache
    # after any account mutation.
    $now = [DateTime]::UtcNow
    if ($script:AccountListCache -and
        ($now - $script:AccountListCacheAt).TotalSeconds -lt $script:AccountListCacheTtlSec) {
        return $script:AccountListCache
    }

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
        $script:AccountListCache = @()
        $script:AccountListCacheAt = $now
        return
    }
    $script:AccountListCache = $list
    $script:AccountListCacheAt = $now
    return $list
}

# Cached account list to avoid re-reading settings.json from disk on every
# timer tick. Invalidated after account mutations and refreshed on a short
# TTL so UI-visible changes appear within a few seconds. Lives in script
# scope so both SettingsManager and NSCloudDrive (which dot-sources this
# file) share the same cache.
$script:AccountListCache = $null
$script:AccountListCacheAt = [DateTime]::MinValue
$script:AccountListCacheTtlSec = 5

function Get-CachedCloudAccounts {
    $now = [DateTime]::UtcNow
    if ($script:AccountListCache -and
        ($now - $script:AccountListCacheAt).TotalSeconds -lt $script:AccountListCacheTtlSec) {
        return $script:AccountListCache
    }
    try {
        $script:AccountListCache = @(Get-CloudAccounts)
    } catch {
        $script:AccountListCache = @()
    }
    $script:AccountListCacheAt = $now
    return $script:AccountListCache
}

function Clear-AccountListCache {
    $script:AccountListCache = $null
    $script:AccountListCacheAt = [DateTime]::MinValue
}

function Get-CloudAccount([string]$AccountId) {
    if (-not $AccountId) { return $null }
    $accounts = @(Get-CloudAccounts)
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
    foreach ($savedAccount in @(Get-CloudAccounts)) {
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
    Clear-AccountListCache
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
    Clear-AccountListCache
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
        Clear-AccountListCache
    }
    return $found
}

function Remove-SeededPlaceholderAccounts {
    $settings = Get-NSCloudDriveSettings
    $cleaned = @()
    $changed = $false
    if ($settings.Accounts) {
        foreach ($a in $settings.Accounts) {
            $isPlaceholder = ($a.Id -like 'test_*')
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
        Clear-AccountListCache
    }
    return $cleaned
}

function Get-AllocatedDriveLetters {
    $accounts = @(Get-CloudAccounts)
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

function Set-WindowsStartupEnabled([bool]$Enable, [string]$ScriptPath = '', [string]$ExecutablePath = '') {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath $runKey)) {
        New-Item -Path $runKey -Force | Out-Null
    }

    if ($Enable) {
        $settings = Get-NSCloudDriveSettings
        $minParam = if ($settings -and $settings.StartMinimized) { ' -Minimized' } else { '' }

        if (-not [string]::IsNullOrEmpty($ScriptPath)) {
            $targetScript = [System.IO.Path]::GetFullPath($ScriptPath)
            $psExe = if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) {
                Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            } else {
                'powershell.exe'
            }
            $commandValue = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$targetScript`"$minParam"
        } else {
            $rootExe = if (-not [string]::IsNullOrEmpty($ExecutablePath)) {
                $ExecutablePath
            } else {
                Join-Path $PSScriptRoot '..\..\NSCloudDrive.exe'
            }
            if (Test-Path -LiteralPath $rootExe -PathType Leaf) {
                $fullExe = [System.IO.Path]::GetFullPath($rootExe)
                $commandValue = "`"$fullExe`"$minParam"
            } else {
                $targetScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\NSCloudDrive.ps1'))
                $psExe = if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')) {
                    Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                } else {
                    'powershell.exe'
                }
                $commandValue = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$targetScript`"$minParam"
            }
        }
        Set-ItemProperty -LiteralPath $runKey -Name 'NSCloudDrive' -Value $commandValue -Type String
    } else {
        Remove-ItemProperty -LiteralPath $runKey -Name 'NSCloudDrive' -ErrorAction SilentlyContinue
    }
}


function Test-NotificationsSnoozed([hashtable]$Settings = $null) {
    if (-not $Settings) { $Settings = Get-NSCloudDriveSettings }
    if (-not $Settings -or -not $Settings.EnableNotifications) { return $true }
    if ($Settings.NotificationSnoozeUntilUtc) {
        $parsed = [DateTime]::MinValue
        if ([DateTime]::TryParse($Settings.NotificationSnoozeUntilUtc, [ref]$parsed)) {
            if ([DateTime]::UtcNow -lt $parsed.ToUniversalTime()) {
                return $true
            }
        }
    }
    return $false
}

function Set-NotificationSnooze([int]$Minutes, [hashtable]$Settings = $null) {
    if (-not $Settings) { $Settings = Get-NSCloudDriveSettings }
    if ($Minutes -le 0) {
        $Settings.NotificationSnoozeUntilUtc = ''
    } else {
        $Settings.NotificationSnoozeUntilUtc = [DateTime]::UtcNow.AddMinutes($Minutes).ToString('o')
    }
    Set-NSCloudDriveSettings $Settings
    return $Settings
}

function Get-EffectiveBandwidthLimitRate([hashtable]$Settings = $null) {
    if (-not $Settings) { $Settings = Get-NSCloudDriveSettings }
    $policy = if ($Settings.BandwidthPolicy) { [string]$Settings.BandwidthPolicy } else { 'Unlimited' }

    if ($policy -eq 'Unlimited') {
        return 'off'
    }
    if ($policy -eq 'MinimalBackground') {
        return '256k'
    }

    $formatCustom = {
        $val = if ($Settings.CustomUploadLimitValue) { [int]$Settings.CustomUploadLimitValue } else { 5 }
        if ($val -le 0) { $val = 1 }
        $unit = if ($Settings.CustomUploadLimitUnit) { [string]$Settings.CustomUploadLimitUnit } else { 'MB/s' }
        if ($unit -eq 'KB/s' -or $unit -eq 'k') {
            return "${val}k"
        }
        return "${val}M"
    }

    if ($policy -eq 'Limited') {
        $preset = if ($Settings.Contains('BandwidthLimitPreset') -and $Settings.BandwidthLimitPreset) { [string]$Settings.BandwidthLimitPreset } else { '5 MB/s' }
        switch ($preset) {
            '256 KB/s' { return '256k' }
            '512 KB/s' { return '512k' }
            '1 MB/s'   { return '1M' }
            '2 MB/s'   { return '2M' }
            '5 MB/s'   { return '5M' }
            '10 MB/s'  { return '10M' }
            'Custom'   { return (& $formatCustom) }
            default    {
                if ($preset -match '^(\d+)\s*KB/s$') { return "$($Matches[1])k" }
                if ($preset -match '^(\d+)\s*MB/s$') { return "$($Matches[1])M" }
                return '5M'
            }
        }
    }
    if ($policy -eq 'Custom') {
        return (& $formatCustom)
    }
    # Adaptive mode default initial rate
    return 'off'
}
