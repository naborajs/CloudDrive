# Test-MultiAccountLifecycle.ps1 - Mocked, sandbox-safe regression suite for the
# multi-account lifecycle hardening phase. Covers the isolation defects that
# allowed one account to present another account's credentials, the saved-identity
# cross-check, restart-restore semantics for saved accounts, the ReadOnly mount
# chain, false-success prevention on missing credentials, and no-phantom removal
# cleanup. Uses letters X/Y only, overrides LOCALAPPDATA and the settings
# directory, and NEVER starts rclone, the bridge, or any mount process.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\TeraBoxBridgeManager.ps1')

Write-Output 'Testing Multi-Account Lifecycle (mocked/sandboxed; no processes are started)...'

$origLocalAppData = $env:LOCALAPPDATA
$testSandbox = Join-Path $env:TEMP ("NSCloudDrive_Lifecycle_" + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testSandbox -Force)
$env:LOCALAPPDATA = $testSandbox
Set-SettingsDirectoryOverride (Join-Path $testSandbox 'settings')

$srcRoot = Join-Path $PSScriptRoot '..\src'
$nsSourcePath = Join-Path $srcRoot 'NSCloudDrive.ps1'
$vdSourcePath = Join-Path $srcRoot 'services\VirtualDriveManager.ps1'
$gdProviderPath = Join-Path $srcRoot 'providers\GoogleDriveProvider.ps1'
$tbProviderPath = Join-Path $srcRoot 'providers\TeraBoxProvider.ps1'
$tbBridgeSourcePath = Join-Path $srcRoot 'services\TeraBoxBridgeManager.ps1'
$pcwSourcePath = Join-Path $srcRoot 'ui\ProviderConnectionWindow.ps1'
$ctmSourcePath = Join-Path $srcRoot 'services\CloudTransferManager.ps1'

try {
    # --------------------------------------------------------------------------
    # 1. Account-scoped credential reads must never fall back to the legacy
    #    shared file (the direct cross-account credential leak).
    # --------------------------------------------------------------------------
    $legacyTokens = [ordered]@{
        access_token = 'ya29.life_legacy_token'
        refresh_token = '1//life_legacy_refresh'
        token_type = 'Bearer'
        expires_in = 3600
        scope = 'https://www.googleapis.com/auth/drive'
        obtained_at = [DateTime]::UtcNow.ToString('o')
    }
    Save-GoogleDriveTokens -TokenData $legacyTokens

    $accountViewOfLegacy = Get-GoogleDriveStoredTokens -AccountId 'life_gd_a'
    if ($null -ne $accountViewOfLegacy) {
        throw "A new Google account silently read the legacy connection's tokens (fallback regression)."
    }

    Save-TeraBoxSession -Type 'web-session' -Secret 'ndus=legacy_cookie' -BaseUrl 'https://www.terabox.com'

    $tbAccountViewOfLegacy = Get-TeraBoxStoredSession -AccountId 'life_tb_a'
    if ($null -ne $tbAccountViewOfLegacy) {
        throw "A new TeraBox account silently read the legacy connection's session (fallback regression)."
    }

    # A real account-scoped write is still readable per account, and the legacy
    # shared files remain untouched by account-scoped operations.
    $ownTokens = [ordered]@{
        access_token = 'ya29.life_account_token'
        refresh_token = '1//life_account_refresh'
        token_type = 'Bearer'
        expires_in = 3600
        scope = 'https://www.googleapis.com/auth/drive'
        obtained_at = [DateTime]::UtcNow.ToString('o')
    }
    Save-GoogleDriveTokens -TokenData $ownTokens -AccountId 'life_gd_a'
    $ownLoaded = Get-GoogleDriveStoredTokens -AccountId 'life_gd_a'
    if ($null -eq $ownLoaded -or $ownLoaded.access_token -ne 'ya29.life_account_token') {
        throw 'Account-scoped Google token store lost its own data.'
    }
    $legacyStill = Get-GoogleDriveStoredTokens
    if ($null -eq $legacyStill -or $legacyStill.access_token -ne 'ya29.life_legacy_token') {
        throw 'Legacy token store was disturbed by account-scoped operations.'
    }
    Write-Output '  [PASS] Account-scoped reads never inherit the legacy connection credentials'

    # --------------------------------------------------------------------------
    # 2. Saved-identity cross-check (Google): a verified Google identity that
    #    does not belong to the saved account fails the session check. HTTP
    #    calls are intercepted with a stub; no network access occurs. The stub
    #    lives only in this script scope and is removed in the finally block.
    # --------------------------------------------------------------------------
    function Invoke-RestMethod {
        param(
            [string]$Uri,
            $Headers,
            $Method = 'Get',
            $Body,
            $TimeoutSec,
            $ErrorAction,
            $ContentType,
            $UseBasicParsing
        )
        if ($Uri -like '*files/root*') {
            return [pscustomobject]@{
                id = 'fake_root_id'
                name = 'My Drive (stubbed)'
                owners = @([pscustomobject]@{ displayName = 'Cross Stub'; emailAddress = 'cross@demo.com' })
            }
        }
        if ($Uri -like '*about*') {
            return [pscustomobject]@{
                user = [pscustomobject]@{ displayName = 'Cross Stub'; emailAddress = 'cross@demo.com' }
                storageQuota = [pscustomobject]@{ limit = '1000000000'; usage = '125000' }
            }
        }
        return [pscustomobject]@{}
    }

    try {
        Add-CloudAccount ([ordered]@{
            Id = 'life_gd_x'; ProviderId = 'gdrive'; DisplayName = 'Alpha Work Drive'
            AccountEmail = 'alpha@example.com'; DriveLetter = 'X'
        }) | Out-Null
        Add-CloudAccount ([ordered]@{
            Id = 'life_gd_y'; ProviderId = 'gdrive'; DisplayName = 'Beta Personal Drive'
            AccountEmail = 'cross@demo.com'; DriveLetter = 'Y'
        }) | Out-Null

        $stubTokens = [ordered]@{
            access_token = 'ya29.life_cross_token'
            refresh_token = '1//life_cross_refresh'
            token_type = 'Bearer'
            expires_in = 3600
            scope = 'https://www.googleapis.com/auth/drive'
            obtained_at = [DateTime]::UtcNow.ToString('o')
        }

        # Account X: the authenticated Google identity belongs to a different
        # user than the saved record -> must fail with a sign-in requirement.
        $mismatch = Test-GoogleDriveBackendSession -TokensOverride $stubTokens -AccountId 'life_gd_x' -Force
        if ($null -eq $mismatch -or $mismatch.IsValid -ne $false -or $mismatch.State -ne 'AuthRequired') {
            throw "A Google identity that contradicts the saved account still validated (State: $($mismatch.State))."
        }
        if ($mismatch.IdentityError -notmatch 'belong') {
            throw 'The identity mismatch did not produce an actionable identity error.'
        }

        # Account Y: the authenticated identity IS the saved account -> valid.
        $match = Test-GoogleDriveBackendSession -TokensOverride $stubTokens -AccountId 'life_gd_y' -Force
        if ($null -eq $match -or $match.IsValid -ne $true -or $match.State -ne 'Connected') {
            throw ("A saved account whose identity matches Google's answer was wrongly rejected (State: $(if ($match) { $match.State } else { 'null' })).")
        }
        if ([bool]$match.IdentityVerified -ne $true) {
            throw 'A matching live identity must be reported as verified.'
        }
        Write-Output '  [PASS] Google identity cross-check rejects foreign identities and accepts matching ones'
    } finally {
        # Drop the stub so no later section can accidentally use it.
        Remove-Item function:Invoke-RestMethod -ErrorAction SilentlyContinue
    }

    # --------------------------------------------------------------------------
    # 3. Restart-restore semantics: two saved accounts (one per provider type is
    #    not required; same provider is harder) with distinct letters, custom
    #    names, persistent settings store, conflict refusals, and removal.
    # --------------------------------------------------------------------------
    Update-CloudAccount ([ordered]@{
        Id = 'life_gd_y'
        DisplayName = 'Beta Renamed'
        CacheDirectory = 'C:\NSCD-Lifecycle-Cache-B'
        CacheMaxGigabytes = 7
    }) | Out-Null
    $persisted = Get-CloudAccount -AccountId 'life_gd_y'
    if ($null -eq $persisted -or $persisted.DisplayName -ne 'Beta Renamed' -or
        $persisted.CacheDirectory -ne 'C:\NSCD-Lifecycle-Cache-B' -or
        $persisted.CacheMaxGigabytes -ne 7) {
        throw 'Renaming an account or saving its per-drive cache settings did not persist.'
    }
    $allAccounts = Get-CloudAccounts
    if ($allAccounts.Count -ne 2) {
        throw ("Expected exactly 2 saved accounts after restore simulation, found $($allAccounts.Count).")
    }
    $letters = @($allAccounts | ForEach-Object { [string]$_.DriveLetter })
    if ($letters -notcontains 'X' -or $letters -notcontains 'Y') {
        throw ("Saved accounts did not restore with their distinct letters X and Y, got: $($letters -join ',').")
    }
    $emailX = @($allAccounts | Where-Object { $_.Id -eq 'life_gd_x' })[0]
    if ($null -eq $emailX -or [string]$emailX.AccountEmail -ne 'alpha@example.com' -or [string]$emailX.DisplayName -ne 'Alpha Work Drive') {
        throw 'The saved identity and custom display name were not restored per account.'
    }

    # A third account may not take an occupied letter.
    $conflictThrown = $false
    try {
        Add-CloudAccount ([ordered]@{
            Id = 'life_gd_z'; ProviderId = 'gdrive'; DisplayName = 'Gamma'
            AccountEmail = 'gamma@example.com'; DriveLetter = 'X'
        }) | Out-Null
    } catch {
        $conflictThrown = $true
    }
    if (-not $conflictThrown) {
        throw 'Adding a second account onto an occupied drive letter did not fail.'
    }

    # A saved account may not move onto another account's letter, but keeping
    # its own letter is always allowed.
    $moveConflict = $false
    try {
        Update-CloudAccount ([ordered]@{ Id = 'life_gd_y'; DriveLetter = 'X' }) | Out-Null
    } catch {
        $moveConflict = $true
    }
    if (-not $moveConflict) {
        throw 'An account was allowed to steal another account''s drive letter.'
    }
    Update-CloudAccount ([ordered]@{ Id = 'life_gd_y'; DriveLetter = 'Y' }) | Out-Null

    # Removing account X frees its letter and leaves account Y intact.
    Remove-CloudAccount -AccountId 'life_gd_x' | Out-Null
    $afterRemove = Get-CloudAccounts
    if ($afterRemove.Count -ne 1 -or $afterRemove[0].Id -ne 'life_gd_y') {
        throw 'Removing one account affected another saved account.'
    }
    Add-CloudAccount ([ordered]@{
        Id = 'life_gd_d'; ProviderId = 'gdrive'; DisplayName = 'Delta New'
        AccountEmail = 'delta@example.com'; DriveLetter = 'X'
    }) | Out-Null
    $freedLetterCheck = Get-CloudAccount -AccountId 'life_gd_d'
    if ($null -eq $freedLetterCheck -or [string]$freedLetterCheck.DriveLetter -ne 'X') {
        throw 'A freed drive letter was not reusable by a new account.'
    }
    Write-Output '  [PASS] Restart-restore, letter conflicts, rename, and removal semantics verified'

    # --------------------------------------------------------------------------
    # 4. ReadOnly mount chain and false-success prevention (structural + local
    #    builder checks; nothing is launched).
    # --------------------------------------------------------------------------
    $builderArgs = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'X' -ReadOnly
    if ($builderArgs -notcontains '--read-only') {
        throw 'Build-RcloneMountArguments ignores the ReadOnly switch.'
    }
    $builderArgsRw = Build-RcloneMountArguments -RemoteName 'terabox' -DriveLetter 'Y'
    if ($builderArgsRw -contains '--read-only') {
        throw 'Build-RcloneMountArguments added --read-only to a read-write mount.'
    }
    $builderArgsWithAccountCache = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'Y' -CacheMaxGigabytes 7
    $cacheLimitIndex = $builderArgsWithAccountCache.IndexOf('--vfs-cache-max-size')
    if ($cacheLimitIndex -lt 0 -or $builderArgsWithAccountCache[$cacheLimitIndex + 1] -ne '7G') {
        throw 'Build-RcloneMountArguments did not apply the selected account''s VFS cache limit.'
    }

    $nsReadOnlySites = (Select-String -Path $nsSourcePath -Pattern ([regex]::Escape('-ReadOnly:$([bool]$account.ReadOnly)')))
    if (@($nsReadOnlySites).Count -ne 4) {
        throw ("Expected the per-account ReadOnly flag at exactly 4 mount call sites, found $($nsReadOnlySites.Count).")
    }
    $workerSetup = [regex]::Match((Get-Content -LiteralPath $nsSourcePath -Raw), '(?ms)\$workerAccounts = if .*?^\s*\$nextAllowed =').Value
    if (-not $workerSetup -or ([regex]::Matches($workerSetup, 'ReadOnly\s*=')).Count -ne 4) {
        throw 'Every saved, legacy Google, and legacy TeraBox reconnect worker record must define its ReadOnly mode.'
    }

    $nsMapping = Select-String -Path $nsSourcePath -SimpleMatch -Pattern 'No Google Drive tokens|No valid TeraBox session'
    if (-not $nsMapping) {
        throw 'Startup restore no longer maps missing per-account credentials to the sign-in-required state.'
    }

    $vdIsolatedConfig = Select-String -Path $vdSourcePath -Pattern 'account-mount-isolated\.conf'
    if (-not $vdIsolatedConfig) {
        throw 'Account mounts no longer use an isolated rclone config file.'
    }

    $tbErrnoSave = Select-String -Path $tbProviderPath -Pattern ([regex]::Escape('UserAgent $activeUserAgent -AccountId $AccountId'))
    if (-not $tbErrnoSave) {
        throw 'The TeraBox errno -6 host-prefix fix no longer saves the session under its own account id.'
    }
    Write-Output '  [PASS] ReadOnly mount chain, isolated account config, and AuthRequired mapping verified'

    # --------------------------------------------------------------------------
    # 5. No-phantom account creation/cancellation cleanup (structural checks on
    #    the creation flow source).
    # --------------------------------------------------------------------------
    $cancelGd = Select-String -Path $pcwSourcePath -Pattern ([regex]::Escape('Remove-GoogleDriveSession -AccountId $accId'))
    $cancelTb = Select-String -Path $pcwSourcePath -Pattern ([regex]::Escape('Remove-TeraBoxSession -AccountId $accId'))
    if (-not $cancelGd -or -not $cancelTb) {
        throw 'Refused or cancelled account creation no longer cleans up the provider session.'
    }
    $nsRemovalCleanup = Select-String -Path $nsSourcePath -Pattern ([regex]::Escape('Get-TeraBoxBridgeHomeDirectory -AccountId $request.AccountId'))
    if (-not $nsRemovalCleanup) {
        throw 'Card removal no longer cleans up the per-account bridge home directory.'
    }
    if (-not (Select-String -Path $nsSourcePath -SimpleMatch -Pattern 'Join-Path $request.CacheDirectory $request.AccountId')) {
        throw 'Account removal no longer cleans the cache under that account''s configured cache base.'
    }
    Write-Output '  [PASS] Cancelled creation and card-removal cleanup hooks verified'

    # --------------------------------------------------------------------------
    # 6. Disconnect must be backgrounded, scoped to the selected identity, and
    #    reflected in the UI only after process and drive removal are verified.
    # --------------------------------------------------------------------------
    $nsSource = Get-Content -LiteralPath $nsSourcePath -Raw
    $disconnectRegion = [regex]::Match($nsSource, '(?ms)function Start-ScopedDriveDisconnect\(.*?function Start-ProviderStatusRefreshWorker').Value
    if (-not $disconnectRegion -or
        $disconnectRegion -notmatch 'Start-NSBackgroundOperation' -or
        $disconnectRegion -notmatch 'Stop-VirtualDriveMount -ProviderId \$providerId -AccountId \$accountId -DriveLetter \$driveLetter' -or
        $disconnectRegion -notmatch '\$status\.ProcessRunning -or \$status\.IsMounted' -or
        $disconnectRegion -notmatch 'Get-SafeProperty \$result ''Verified'' \$false') {
        throw 'Selected-account disconnect is not asynchronous and verified before completion.'
    }
    if ($nsSource -notmatch 'Get-CloudAccount -AccountId \(\[string\]\$sender\.Tag\)' -or
        $nsSource -notmatch '(?s)\$mountOptionsChanged = .*?\$previous\.CacheDirectory .*?\$savedAcc\.CacheMaxGigabytes' -or
        $nsSource -notmatch '(?s)\$script:ManualMountRequests\.Contains\(\$key\).*?\$selectedAccount\.OpenExplorerOnMount') {
        throw 'Drive actions and saved mount options are not bound to the selected account.'
    }
    $completionStart = $nsSource.IndexOf('function Complete-AvailableStartupWorkers {')
    $reconnectStart = $nsSource.IndexOf('if ($script:ReconnectWorker -and', $completionStart)
    $legacyCompletionStart = $nsSource.IndexOf('Complete-AvailableLegacyMountWorkers', $reconnectStart)
    if ($completionStart -lt 0 -or $reconnectStart -lt 0 -or $legacyCompletionStart -le $reconnectStart) {
        throw 'Could not locate startup and reconnect completion paths for Explorer launch checks.'
    }
    $startupCompletion = $nsSource.Substring($completionStart, $reconnectStart - $completionStart)
    $reconnectCompletion = $nsSource.Substring($reconnectStart, $legacyCompletionStart - $reconnectStart)
    if ($startupCompletion -match 'Start-ExplorerWindow' -or
        $reconnectCompletion -notmatch '\$script:ManualMountRequests\.Contains\(\$key\)' -or
        $nsSource -notmatch '\$script:ManualMountRequests\.Add\(\[string\]\$selectedAccount\.Id\)') {
        throw 'Automatic mount restoration must not open Explorer; only a successful user-requested account mount may honor the preference.'
    }
    if ($nsSource -notmatch 'CacheDirectory \$accountCacheDirectory -CacheMaxGigabytes \$accountCacheMaxGigabytes') {
        throw 'Startup and reconnect mount workers do not use the selected account''s effective cache settings.'
    }
    $settingsModalSource = Get-Content -LiteralPath $pcwSourcePath -Raw
    if ($settingsModalSource -notmatch 'CacheDirectory = \$cacheDirectory' -or
        $settingsModalSource -notmatch 'CacheMaxGigabytes = \$cacheMaxGigabytes' -or
        $settingsModalSource -notmatch 'VerticalScrollBarVisibility = ''Auto''') {
        throw 'Drive settings must persist cache values and keep all options reachable in the scrollable modal.'
    }
    Write-Output '  [PASS] Selected-account disconnect is asynchronous, scoped, and verified before UI completion'
    Write-Output '  [PASS] Per-account cache settings save and trigger remount when changed'

    # --------------------------------------------------------------------------
    # 7. Startup-restore worker scope and legacy parity. The legacy single-
    #    provider fallback inside the worker must resolve the rclone path
    #    without the UI helper (which is absent in the worker runspace and
    #    previously killed every TeraBox restore attempt with a
    # CommandNotFoundException), and preserve existing mounts when a root
    # probe times out rather than triggering a duplicate mount.
    # --------------------------------------------------------------------------
    $nsAll = Get-Content -LiteralPath $nsSourcePath -Raw
    $autoMountStart = $nsAll.IndexOf('function Invoke-StartupAutoMount {')
    $loadedAfter = $nsAll.IndexOf('$window.Add_Loaded({')
    if ($autoMountStart -lt 0 -or $loadedAfter -lt 0 -or $loadedAfter -le $autoMountStart) {
        throw 'Could not locate the Invoke-StartupAutoMount region in NSCloudDrive.ps1.'
    }
    $autoMountRegion = $nsAll.Substring($autoMountStart, $loadedAfter - $autoMountStart)
    if ($autoMountRegion -notmatch 'function Get-VerifiedRclonePath') {
        throw 'The startup auto-mount worker no longer defines a worker-local Get-VerifiedRclonePath resolver.'
    }
    if ($autoMountRegion -notmatch "\`$results\.Add\(\[pscustomobject\]@\{ AccountId = 'gdrive'; State = 'ExistingProcess'") {
        throw 'The legacy Google fallback no longer records a verified existing mount as ExistingProcess.'
    }
    if ($autoMountRegion -notmatch ([regex]::Escape("A mount process exists, but its assigned drive is not present."))) {
        throw 'The legacy fallback no longer refuses success when a mount process lacks its drive letter.'
    }
    if ($autoMountRegion -notmatch 'Test-VirtualDriveFilesystem -DriveRoot \$googleStatus\.DriveRoot') {
        throw 'The legacy Google fallback no longer runs its bounded filesystem health probe on an existing mount.'
    }
    $managerSource = Get-Content -LiteralPath $vdSourcePath -Raw
    if ($managerSource -notmatch 'function Test-MountProcessOwnership' -or
        $managerSource -notmatch 'rclone-'' \+ \[regex\]::Escape\(\$MountKey\)' -or
        $managerSource -match '\[string\]::IsNullOrEmpty\(\$AccountId\) -and \$script:MountProcess') {
        throw 'Live mount processes are not bound to their account/provider log namespace.'
    }
    $ownedH = Test-MountProcessOwnership -CommandLine 'rclone mount gdrive: H: --log-file "C:\NSCloudDrive\logs\rclone-gdrive_alpha.log"' -DriveLetter 'H' -MountKey 'gdrive_alpha'
    $wrongGoogleIdentity = Test-MountProcessOwnership -CommandLine 'rclone mount gdrive: H: --log-file "C:\NSCloudDrive\logs\rclone-gdrive_beta.log"' -DriveLetter 'H' -MountKey 'gdrive_alpha'
    $wrongLetter = Test-MountProcessOwnership -CommandLine 'rclone mount gdrive: G: --log-file "C:\NSCloudDrive\logs\rclone-gdrive_alpha.log"' -DriveLetter 'H' -MountKey 'gdrive_alpha'
    $legacyG = Test-MountProcessOwnership -CommandLine 'rclone mount gdrive: G: --log-file "C:\NSCloudDrive\logs\rclone-gdrive.log"' -DriveLetter 'G' -MountKey 'gdrive'
    $legacyT = Test-MountProcessOwnership -CommandLine 'rclone mount terabox: T: --log-file "C:\NSCloudDrive\logs\rclone-terabox.log"' -DriveLetter 'T' -MountKey 'terabox'
    if (-not $ownedH -or $wrongGoogleIdentity -or $wrongLetter -or -not $legacyG -or -not $legacyT) {
        throw 'Google account, legacy Google, and TeraBox process ownership checks are not isolated.'
    }
    $bridgeCapture = Select-String -Path $tbBridgeSourcePath -Pattern ([regex]::Escape('[void](Stop-TeraBoxBridge -Port $Port -AccountId $AccountId -BridgePassword $existingPw)'))
    if (-not $bridgeCapture) {
        throw 'Start-TeraBoxBridge again leaks the Stop-TeraBoxBridge sentinel into its result pipeline.'
    }
    $ctmDict = Select-String -Path $ctmSourcePath -SimpleMatch -Pattern "`$bridgeStatus['Success']"
    if (-not $ctmDict) {
        throw 'CloudTransferManager again reads ordered-dictionary keys as properties instead of with indexing.'
    }
    Write-Output '  [PASS] Startup-restore worker scope, legacy parity, and bridge status shape verified'

} finally {
    # Leave the process scope intact for the harness; the stub above was
    # already removed in its own finally. Restore process-level state.
    $env:LOCALAPPDATA = $origLocalAppData
    Reset-SettingsDirectoryOverride
    try { Remove-Item -LiteralPath $testSandbox -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Output 'All Multi-Account Lifecycle Tests Passed Successfully.'
