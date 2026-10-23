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
    $accounts = Get-CloudAccounts
    if ($accounts.Count -ne 2 -or (Get-CloudAccount $firstId).DisplayName -ne 'Personal' -or (Get-CloudAccount $secondId).DisplayName -ne 'Work') {
        throw 'Saving a second account changed or lost the first account.'
    }

    $uiSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ui\ProviderConnectionWindow.ps1') -Raw
    if ($uiSource -notmatch 'Test-CloudAccountPersisted' -or $uiSource -notmatch 'Add-CloudAccount \$accObj' -or $uiSource -notmatch 'Update-CloudAccount \$accObj') {
        throw 'Account dialog is not wired to distinguish unsaved drafts from persisted accounts.'
    }
    if ($uiSource -notmatch 'Could not save this cloud account') { throw 'Save failures must remain visible in the account dialog.' }

    $mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
    $addHandler = [regex]::Match($mainSource, '(?s)\$addDiskBtn\.Add_Click\(\{.*?\r?\n\}\)\r?\n\$leftToolbar\.Children\.Add\(\$addDiskBtn\)')
    if (-not $addHandler.Success -or $addHandler.Value -notmatch 'Invoke-AutoReconnectWatchdog -AccountId' -or $addHandler.Value -match 'Start-VirtualDriveMount') {
        throw 'A newly saved account must enter the background mount worker instead of blocking the WPF Add handler.'
    }
    if ($mainSource -notmatch 'Test-GoogleDriveBackendSession -AccountId \$account\.Id -Force' -or $mainSource -notmatch 'Test-TeraBoxBackendSession -AccountId \$account\.Id -Force') {
        throw 'Account-scoped mount workers must validate each provider session independently.'
    }
    if ($mainSource -notmatch 'PendingManualMountAccountIds' -or $mainSource -notmatch 'Queued behind another mount') {
        throw 'Concurrent restore and manual mount requests must be queued per account.'
    }

    Write-Output '  [PASS] New drafts use Add; saved accounts use Edit; duplicate IDs are rejected; the second account preserves the first; mount validation runs asynchronously with per-account queueing.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    Reset-SettingsDirectoryOverride
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

