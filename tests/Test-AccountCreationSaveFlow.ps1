Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')

$originalLocalAppData = $env:LOCALAPPDATA
$sandbox = Join-Path $env:TEMP ('NSCloudDrive_AccountSave_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:LOCALAPPDATA = $sandbox
Set-SettingsDirectoryOverride (Join-Path $sandbox 'settings')
try {
    $firstId = 'gdrive_' + [guid]::NewGuid().ToString('N')
    $first = @{
        Id = $firstId; ProviderId = 'gdrive'; DisplayName = 'Personal'; AccountEmail = 'person@example.invalid'
        DriveLetter = 'G'; AutoMount = $true; OpenExplorerOnMount = $true; ReadOnly = $false
    }
    if (Test-CloudAccountPersisted $firstId) { throw 'A newly authorized draft must take the Add path before save.' }
    $saved = Add-CloudAccount $first
    if (-not (Test-CloudAccountPersisted $firstId) -or $saved.Id -ne $firstId) { throw 'New account was not persisted.' }

    $duplicate = @{} + $first
    $duplicate.DisplayName = 'Replacement must not overwrite'
    $duplicateFailed = $false
    try { Add-CloudAccount $duplicate | Out-Null } catch { $duplicateFailed = $true }
    if (-not $duplicateFailed) { throw 'Duplicate account ID should be rejected.' }
    $unchanged = Get-CloudAccount $firstId
    if ($unchanged.DisplayName -ne 'Personal' -or $unchanged.AccountEmail -ne 'person@example.invalid') {
        throw 'Rejecting a duplicate changed the existing account.'
    }

    $secondId = 'gdrive_' + [guid]::NewGuid().ToString('N')
    $second = @{} + $first
    $second.Id = $secondId; $second.DisplayName = 'Work'; $second.AccountEmail = 'work@example.invalid'; $second.DriveLetter = 'H'
    Add-CloudAccount $second | Out-Null
    $accounts = @(Get-CloudAccounts)
    if ($accounts.Count -ne 2 -or (Get-CloudAccount $firstId).DisplayName -ne 'Personal' -or (Get-CloudAccount $secondId).DisplayName -ne 'Work') {
        throw 'Saving a second account changed or lost the first account.'
    }
    if ($accounts[0].AccountEmail -ne 'person@example.invalid' -or $accounts[1].AccountEmail -ne 'work@example.invalid') {
        throw 'Enumerating saved accounts must preserve each account identity as a separate record.'
    }

    $firstUpdate = @{ Id = $firstId; DisplayName = 'Personal renamed' }
    Update-CloudAccount $firstUpdate | Out-Null
    $accounts = @(Get-CloudAccounts)
    if ($accounts.Count -ne 2 -or (Get-CloudAccount $firstId).DisplayName -ne 'Personal renamed' -or
        (Get-CloudAccount $secondId).DisplayName -ne 'Work' -or
        (Get-CloudAccount $secondId).AccountEmail -ne 'work@example.invalid') {
        throw 'Renaming one account must not merge or modify the other account.'
    }

    $duplicateLetterRejected = $false
    try {
        Add-CloudAccount @{ Id = 'gdrive_letter_collision'; ProviderId = 'gdrive'; DisplayName = 'Collision'; AccountEmail = 'collision@example.invalid'; DriveLetter = 'g:'; AutoMount = $true } | Out-Null
    } catch { $duplicateLetterRejected = $_.Exception.Message -match 'already assigned' }
    if (-not $duplicateLetterRejected) { throw 'Two saved accounts must not be assigned the same drive letter.' }

    $letterChangeRejected = $false
    try {
        $secondPatch = @{ Id = $secondId; DisplayName = 'Work'; DriveLetter = 'G'; AutoMount = $true }
        Update-CloudAccount $secondPatch | Out-Null
    } catch { $letterChangeRejected = $_.Exception.Message -match 'already assigned' }
    if (-not $letterChangeRejected -or (Get-CloudAccount $secondId).DriveLetter -ne 'H') {
        throw 'A conflicting edit must be rejected without changing the saved account letter.'
    }

    $sampleAddressId = 'gdrive_' + [guid]::NewGuid().ToString('N')
    Add-CloudAccount @{
        Id = $sampleAddressId; ProviderId = 'gdrive'; DisplayName = 'Personal address'
        AccountEmail = 'personal@gmail.com'; DriveLetter = 'Z'; AutoMount = $false
    } | Out-Null
    [void](Remove-SeededPlaceholderAccounts)
    if (-not (Get-CloudAccount $sampleAddressId)) {
        throw 'A real account must not be removed because its Gmail address matches a test example.'
    }

    $uiSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ui\ProviderConnectionWindow.ps1') -Raw
    if ($uiSource -notmatch 'Test-CloudAccountPersisted' -or $uiSource -notmatch 'Add-CloudAccount \$accObj' -or $uiSource -notmatch 'Update-CloudAccount \$accObj') {
        throw 'Account dialog is not wired to distinguish unsaved drafts from persisted accounts.'
    }
    if ($uiSource -notmatch 'Could not save this cloud account') { throw 'Save failures must remain visible in the account dialog.' }

    $mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
    $settingsSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1') -Raw
    if ($settingsSource -match 'return\s+,\$list' -or $mainSource -notmatch '\$allAccounts\s*=\s*@\(Get-CloudAccounts\)') {
        throw 'Account enumeration must yield individual records so WPF collection wrapping cannot merge cards.'
    }
    if ($mainSource -notmatch "'gdrive'\s*\{[^}]*googledrive\.png" -or
        $mainSource -notmatch "'terabox'\s*\{[^}]*terabox\.png" -or
        $mainSource -notmatch 'default\s*\{\s*\$null\s*\}') {
        throw 'Provider card icons must map by the individual provider ID and never fall back to TeraBox.'
    }
    if ($mainSource -notmatch '\$emailAddr\s*=' -or $mainSource -notmatch '\$gdUserInfo\s*=\s*\$null') {
        throw 'An unlinked Google recovery mount must not display a provider-session identity.'
    }
    $addHandler = [regex]::Match($mainSource, '(?s)\$addDiskBtn\.Add_Click\(\{.*?\r?\n\}\)\r?\n\$leftToolbar\.Children\.Add\(\$addDiskBtn\)')
    if (-not $addHandler.Success -or $addHandler.Value -notmatch 'Invoke-AutoReconnectWatchdog -AccountId' -or $addHandler.Value -match 'Start-VirtualDriveMount') {
        throw 'A newly saved account must enter the background mount worker instead of blocking the WPF Add handler.'
    }
    $googleCardHandler = [regex]::Match($mainSource, '(?s)\$gdActionBtn\.Add_Click\(\{.*?\r?\n\}\)')
    $teraBoxCardHandler = [regex]::Match($mainSource, '(?s)\$tbActionBtn\.Add_Click\(\{.*?\r?\n\}\)')
    if (-not $googleCardHandler.Success -or $googleCardHandler.Value -notmatch 'Connect-NewCloudAccount -Owner \$window -ProviderId ''gdrive''' -or $googleCardHandler.Value -match 'Start-LegacyMountWorker|Save-GoogleDriveTokens') {
        throw 'Google connection controls must create account-scoped records rather than provider-only connections.'
    }
    if (-not $teraBoxCardHandler.Success -or $teraBoxCardHandler.Value -notmatch 'Connect-NewCloudAccount -Owner \$window -ProviderId ''terabox''' -or $teraBoxCardHandler.Value -match 'Start-LegacyMountWorker|Save-TeraBoxSession') {
        throw 'TeraBox connection controls must create account-scoped records rather than provider-only connections.'
    }
    if ($mainSource -match 'AccountEmail -notin @\(' -or $mainSource -notmatch 'CLOUD DRIVES') {
        throw 'The main drive list must not hide saved accounts by matching hard-coded email examples.'
    }
    if ($mainSource -notmatch 'Test-GoogleDriveBackendSession -AccountId \$account\.Id -Force' -or $mainSource -notmatch 'Test-TeraBoxBackendSession -AccountId \$account\.Id -Force') {
        throw 'Account-scoped mount workers must validate each provider session independently.'
    }
    if ($mainSource -notmatch 'PendingManualMountAccountIds' -or $mainSource -notmatch 'Queued behind another mount') {
        throw 'Concurrent restore and manual mount requests must be queued per account.'
    }

    Write-Output '  [PASS] New drafts use Add; saved accounts use Edit; duplicate IDs and drive letters are rejected; account records stay independent; mount validation is queued off the UI thread.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    Reset-SettingsDirectoryOverride
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
