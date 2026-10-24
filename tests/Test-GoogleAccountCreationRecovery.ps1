# Test-GoogleAccountCreationRecovery.ps1 - Mocked unit tests for Google identity verification
#
# Reproduces the reported second-account failure without network, browser, or
# UI: both direct Google API identity lookups fail (mocked), the rclone identity
# fallback yields only the generic 'Google Drive User' placeholder for an
# UNSAVED account, and the session check must therefore report the identity as
# NOT verified while exposing the exact sanitized failure reason.
#
# Also proves: valid /about identities are accepted; empty-email responses are
# handled without fabrication; no placeholder account is ever persisted; and
# failure reasons never contain token material. All file/credential writes stay
# inside a sandboxed LOCALAPPDATA. This is a mocked test, not a real-provider
# authorization test.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$originalLocalAppData = $env:LOCALAPPDATA
$sandbox = Join-Path $env:TEMP ('NSCloudDrive_GAuthRecovery_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:LOCALAPPDATA = $sandbox

try {
    . (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
    . (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
    . (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')

    $Failed = 0
    function Assert-True([bool]$Condition, [string]$Message) {
        if (-not $Condition) { $script:Failed++; Write-Output "  [FAIL] $Message"; throw $Message }
        Write-Output "  [PASS] $Message"
    }

    # ---- Mocks (defined AFTER the provider so verb resolution picks these) ----
    $script:MockedApiCalls = 0
    $script:MockedApiResponse = $null    # return payload for Invoke-RestMethod
    $script:MockedApiError    = $null    # throw message for Invoke-RestMethod

    function Invoke-RestMethod {
        # Shadowed by tests; honors the script-level response/error set per scenario.
        param($Uri, $Headers = @{}, $Method = 'Get', $TimeoutSec = 15, $ErrorAction = 'Stop', $Body = $null, $ContentType = $null)
        if ($Headers -and $Headers['Authorization'] -and ($Headers['Authorization'] -notmatch '^Bearer\s')) { throw 'Mock: unexpected Authorization header shape' }
        $script:MockedApiCalls++
        if ($script:MockedApiError) { throw [System.InvalidOperationException]::new($script:MockedApiError) }
        return $script:MockedApiResponse
    }

    $script:MockedRclone = [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; StandardError = 'mock' }
    function Invoke-GoogleRcloneCommand {
        param([string]$FilePath, [string]$Arguments, $EnvironmentVariables = @{}, [int]$TimeoutSeconds = 4)
        return $script:MockedRclone
    }

    function Find-GoogleRcloneBinary { return 'C:\mock\rclone.exe' }

    function New-MockRcloneTokens {
        return ([ordered]@{
            access_token  = 'ya29.MOCKSECRET123'
            refresh_token = '1//MOCKREFRESH098'
            token_type    = 'Bearer'
            expires_in    = 3500
            scope         = 'https://www.googleapis.com/auth/drive'
            obtained_at   = [DateTime]::UtcNow.ToString('o')
        })
    }

    # ---- Scenario 1: both identity API calls fail -> falsified 'Google Drive User'
    # placeholder fallback must be reported as UNVERIFIED with the exact reason,
    # and no placeholder account may be persisted. ----
    $accId = 'gdrive_' + [guid]::NewGuid().ToString('N')
    Save-GoogleDriveTokens -TokenData (New-MockRcloneTokens) -AccountId $accId
    if (@(Get-CloudAccounts).Count -ne 0) { throw 'Test setup: saved accounts must start empty.' }

    $script:MockedApiResponse = $null
    $script:MockedApiError = "The remote server returned an error: (403) Forbidden. Token ya29.MOCKSECRET123 rejected (accessNotConfigured)."
    $s1 = Test-GoogleDriveBackendSession -TokensOverride (New-MockRcloneTokens) -AccountId $accId -Force

    Assert-True ($s1.IsValid -eq $true) 'Scenario 1: rclone-authorized token session remains valid'
    Assert-True ($s1.State -eq 'Connected') 'Scenario 1: state stays Connected (authorization itself succeeded)'
    Assert-True ($s1.IdentityVerified -eq $false) 'Scenario 1: placeholder fallback identity is NOT reported as verified'
    Assert-True ($s1.IdentitySource -ne 'drive-api') 'Scenario 1: identity source is not the Drive API'
    Assert-True (([string]$s1.IdentityError) -match '403' -and ([string]$s1.IdentityError) -match 'accessNotConfigured') 'Scenario 1: exact HTTP/API reason is surfaced'
    Assert-True (([string]$s1.IdentityError) -notmatch 'ya29\.MOCKSECRET123') 'Scenario 1: access token material is redacted from the reason'
    Assert-True (([string]$s1.IdentityError) -match 'ya29\.\[REDACTED\]') 'Scenario 1: token redaction marker is present'
    Assert-True ((Get-SafeProperty $s1.UserInfo 'EmailAddress' '') -eq '') 'Scenario 1: no email is fabricated'
    Assert-True (((Get-SafeProperty $s1.UserInfo 'DisplayName' '') -eq 'Google Drive User')) 'Scenario 1: unsaved account keeps the generic placeholder only as display text'
    Assert-True (@(Get-CloudAccounts).Count -eq 0) 'Scenario 1: failed verification persists no placeholder account'
    Assert-True ($script:MockedApiCalls -ge 2) 'Scenario 1: both direct identity lookups were attempted (files/root and /about)'
    Write-Output '  [PASS] Scenario 1 complete: unverified identity reported truthfully with sanitized exact reason'

    # ---- Scenario 2: a real /about identity is accepted and parsed safely ----
    $script:MockedApiCalls = 0
    $script:MockedApiError = $null
    $script:MockedApiResponse = [pscustomobject]@{
        user = [pscustomobject]@{ displayName = 'Work Account'; emailAddress = 'work@example.com'; permissionId = 'p1' }
        storageQuota = [pscustomobject]@{ usage = 10; limit = 100 }
    }
    $acc2 = 'gdrive_' + [guid]::NewGuid().ToString('N')
    Save-GoogleDriveTokens -TokenData (New-MockRcloneTokens) -AccountId $acc2
    $s2 = Test-GoogleDriveBackendSession -TokensOverride (New-MockRcloneTokens) -AccountId $acc2 -Force
    Assert-True ($s2.IdentityVerified -eq $true) 'Scenario 2: verified identity from Drive API is accepted'
    Assert-True ($s2.IdentitySource -eq 'drive-api') 'Scenario 2: identity source is the Drive API'
    Assert-True ((Get-SafeProperty $s2.UserInfo 'EmailAddress' '') -eq 'work@example.com') 'Scenario 2: email parsed from the real response'
    Assert-True ((Get-SafeProperty $s2.UserInfo 'DisplayName' '') -eq 'Work Account') 'Scenario 2: display name parsed from the real response'
    Assert-True ($s2.Error -eq $null) 'Scenario 2: no error on verified identity'
    Write-Output '  [PASS] Scenario 2 complete'

    # ---- Scenario 3: /about with displayName only (no email) stays verifiable ----
    $script:MockedApiCalls = 0
    $script:MockedApiResponse = [pscustomobject]@{
        user = [pscustomobject]@{ displayName = 'Provisioned User'; permissionId = 'p2' }
    }
    $acc3 = 'gdrive_' + [guid]::NewGuid().ToString('N')
    Save-GoogleDriveTokens -TokenData (New-MockRcloneTokens) -AccountId $acc3
    $s3 = Test-GoogleDriveBackendSession -TokensOverride (New-MockRcloneTokens) -AccountId $acc3 -Force
    Assert-True ($s3.IdentityVerified -eq $true) 'Scenario 3: displayName-only identity is still verifiable'
    Assert-True ((Get-SafeProperty $s3.UserInfo 'DisplayName' '') -eq 'Provisioned User') 'Scenario 3: displayName captured without email fabrication'
    Assert-True ((Get-SafeProperty $s3.UserInfo 'EmailAddress' '') -eq '') 'Scenario 3: missing email stays empty (truthful)'
    Write-Output '  [PASS] Scenario 3 complete'

    # ---- Scenario 4: the failure-reason helper contract ----
    $r0 = Get-GoogleIdentityFailureReason $null
    $r1 = Get-GoogleIdentityFailureReason ([ordered]@{ Error = 'Bad 403'; IdentityError = $null })
    $r2 = Get-GoogleIdentityFailureReason ([ordered]@{ Error = $null; IdentityError = 'Internal (500) reason=backendError token ya29.MOCKSECRET123.' })
    Assert-True ($r0 -eq '') 'Scenario 4: null verify yields empty reason'
    Assert-True ($r1 -eq 'Bad 403') 'Scenario 4: primary Error preferred'
    Assert-True ($r2 -match 'backendError' -and $r2 -notmatch 'ya29\.MOCKSECRET123') 'Scenario 4: IdentityError fallback is sanitized'
    Write-Output '  [PASS] Scenario 4 complete'

    # ---- Scenario 5 (structural): UI retry/guard/not-fabricated additions exist ----
    $uiSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ui\ProviderConnectionWindow.ps1') -Raw
    $mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
    $provSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1') -Raw
    Assert-True ($uiSource -notmatch '\$(?:verify|res)\.State') 'Scenario 5: incomplete provider results cannot throw on direct State property access'
    Assert-True ($uiSource -match 'UpdateStateFromProviderResult' -and $uiSource -match 'Get-SafeProperty \$Result ''State'' ''Error''') 'Scenario 5: missing provider state is surfaced as an explicit Error'
    Assert-True ($mainSource -match 'Get-SafeProperty \$gdCheck ''State'' ''Error''' -and $mainSource -match 'Get-SafeProperty \$tbCheck ''State'' ''Error''' -and $mainSource -notmatch '\$(?:gdCheck|tbCheck)\.State') 'Scenario 5: incomplete dashboard status cannot throw while reading provider State'
    Assert-True ($mainSource -match '\$hasActiveLegacyGoogle = \[bool\]\$gdStatus\.IsMounted -or \[bool\]\(Get-SafeProperty \$gdCheck ''IsValid'' \$false\)' -and $mainSource -match '\$hasSavedGoogleAccounts -and -not \$hasActiveLegacyGoogle') 'Scenario 5: adding a saved Google account does not hide an active legacy Google drive'
    Assert-True ($mainSource -match 'The account was saved, but its mount or dashboard refresh did not complete' -and $mainSource -match "Operation 'account-post-save'") 'Scenario 5: a post-save mount/UI error cannot be reported as account creation failure'
    Assert-True ($uiSource -match '\$verify\.IsValid -and \$userEmail -match') 'Scenario 5: a new Google account requires a valid provider-returned email'
    Assert-True ($uiSource -match 'IdentityVerified') 'Scenario 5: a new Google account requires provider-verified identity'
    Assert-True ($uiSource -match 'already saved as' -and $uiSource -match 'OrdinalIgnoreCase') 'Scenario 5: the same verified Google identity cannot be saved twice'
    Assert-True ($uiSource -match 'Retry the identity check without signing in again\?') 'Scenario 5: UI offers an identity check retry without re-authorizing'
    Assert-True ($uiSource -match 'The received authorization was discarded for security') 'Scenario 5: UI explains the discard decision'
    Assert-True ($uiSource -match '\$script:CloudAccountCreationBusy') 'Scenario 5: re-entrancy guard exists (no nested creation flows)'
    Assert-True ($uiSource -match 'Add_Closed') 'Scenario 5: provider flows run after the modal fully closes (no interactive leftover window)'
    Assert-True ($provSource -match 'Get-GoogleIdentityFailureReason') 'Scenario 5: provider exposes the sanitized failure-reason helper'
    Assert-True ($provSource -match 'IdentityVerified') 'Scenario 5: provider contract carries the verified-identity flag'
    Assert-True ($provSource -match 'TimeoutSeconds 20') 'Scenario 5: identity rclone fallback uses the raised timeout'
    Assert-True ($provSource -match 'try \{ \$proc\.Dispose\(\) \} catch \{ \}') 'Scenario 5: timed-out rclone authorize process is disposed'
    Write-Output '  [PASS] Scenario 5 complete'

    Write-Output '  [PASS] Google account-creation recovery verified (mocked provider responses).'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    # The sandbox was LOCALAPPDATA during the test, so everything the test
    # wrote (settings, DPAPI token files) lives under $sandbox only.
    try { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}
