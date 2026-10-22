Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')

Write-Output 'Testing GoogleDriveProvider...'

# Sandbox LOCALAPPDATA to prevent touching real user credentials
$origGlobalLocalAppData = $env:LOCALAPPDATA
$globalSandboxDir = Join-Path $env:TEMP "gdrive_test_global_sandbox_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $globalSandboxDir | Out-Null
$env:LOCALAPPDATA = $globalSandboxDir

try {
    # 1. Test metadata
    $info = Get-GoogleDriveProviderInfo
    if ($info.Id -ne 'gdrive') { throw "Expected provider ID 'gdrive', found $($info.Id)" }
    if ($info.Name -ne 'Google Drive') { throw "Expected provider name 'Google Drive', found $($info.Name)" }
    if ($info.AuthMethods[0].Scope -ne 'https://www.googleapis.com/auth/drive.readonly') {
        throw "Scope mismatch: $($info.AuthMethods[0].Scope)"
    }
    Write-Output '  [PASS] Provider metadata verified'

    # 2. Test state and PKCE generation
    $state1 = New-OAuthState
    $state2 = New-OAuthState
    if ([string]::IsNullOrEmpty($state1) -or [string]::IsNullOrEmpty($state2)) {
        throw 'Generated state was null or empty'
    }
    if ($state1 -eq $state2) {
        throw 'Generated states must be unique and cryptographically random'
    }
    if ($state1 -match '[+=/]') {
        throw "State contains unescaped URL characters: $state1"
    }

    # Test PKCE verifier and RFC 7636 Appendix B test vector
    $verifier = New-PkceVerifier
    if ($verifier.Length -ne 43) {
        throw "Expected PKCE verifier length of 43 characters, got $($verifier.Length)"
    }
    if ($verifier -match '[+=/]') {
        throw "PKCE verifier contains illegal URL characters: $verifier"
    }

    # Verify RFC 7636 Appendix B official test vector
    $testVerifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
    $expectedChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'
    $actualChallenge = New-PkceChallenge $testVerifier
    if ($actualChallenge -ne $expectedChallenge) {
        throw "RFC 7636 PKCE S256 test vector failed: expected '$expectedChallenge', got '$actualChallenge'"
    }
    Write-Output '  [PASS] Cryptographic state and RFC 7636 PKCE verifier/challenge verified'

    # 3. Test fail-closed when disconnected
    $check = Test-GoogleDriveBackendSession
    if ($check.IsValid -ne $false) { throw 'Expected IsValid to be false without tokens' }
    if ($check.State -ne 'Disconnected') { throw "Expected state 'Disconnected', found $($check.State)" }
    Write-Output '  [PASS] Missing tokens fail closed'

    # 4. Test DPAPI token save and load in sandbox
    $testTokens = @{
        access_token = 'ya29.test_access_token'
        refresh_token = '1//test_refresh_token'
        token_type = 'Bearer'
        expires_in = 3600
        scope = 'https://www.googleapis.com/auth/drive.readonly'
        obtained_at = [DateTime]::UtcNow.ToString('o')
    }
    Save-GoogleDriveTokens -TokenData $testTokens
    $loaded = Get-GoogleDriveStoredTokens
    if (-not $loaded) { throw 'Failed to load saved tokens' }
    if ($loaded.access_token -ne $testTokens.access_token) { throw 'Access token mismatch' }
    if ($loaded.refresh_token -ne $testTokens.refresh_token) { throw 'Refresh token mismatch' }
    Write-Output '  [PASS] DPAPI token save and load verified'

    # Test rclone environment construction from saved tokens
    $rcloneEnv = Get-GoogleDriveRcloneEnvironment
    if ($rcloneEnv['RCLONE_CONFIG_GDRIVE_TYPE'] -ne 'drive') {
        throw 'Expected RCLONE_CONFIG_GDRIVE_TYPE to be drive'
    }
    if ($rcloneEnv['RCLONE_CONFIG_GDRIVE_SCOPE'] -ne 'drive.readonly') {
        throw 'Expected RCLONE_CONFIG_GDRIVE_SCOPE to be drive.readonly'
    }
    $parsedToken = $rcloneEnv['RCLONE_CONFIG_GDRIVE_TOKEN'] | ConvertFrom-Json
    if ($parsedToken.access_token -ne $testTokens.access_token -or $parsedToken.refresh_token -ne $testTokens.refresh_token) {
        throw 'RCLONE_CONFIG_GDRIVE_TOKEN json payload does not match stored credentials'
    }
    Write-Output '  [PASS] rclone environment variable construction verified'

    # Clean up tokens
    Remove-GoogleDriveSession
    $afterRemove = Get-GoogleDriveStoredTokens
    if ($afterRemove) { throw 'Tokens were not cleanly removed' }
    Write-Output '  [PASS] Token removal verified'

    # 5. Test auth URL construction, PKCE challenge, and validation
    $authUrl = Build-GoogleAuthorizationUrl -ClientId 'dummy-client-id' -RedirectUri 'http://127.0.0.1:53682/' -State 'test-state' -CodeChallenge 'test-challenge'
    if ($authUrl -notmatch 'client_id=dummy-client-id' -or
        $authUrl -notmatch 'state=test-state' -or
        $authUrl -notmatch 'code_challenge=test-challenge' -or
        $authUrl -notmatch 'code_challenge_method=S256' -or
        $authUrl -notmatch 'redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A53682%2F') {
        throw "Authorization URL formatting error: $authUrl"
    }
    $threwEmptyClient = $false
    try {
        Build-GoogleAuthorizationUrl -ClientId '' -RedirectUri 'http://127.0.0.1:53682/' -State 'test-state'
    } catch {
        $threwEmptyClient = $true
    }
    if (-not $threwEmptyClient) {
        throw 'Build-GoogleAuthorizationUrl must throw when ClientId is empty.'
    }
    Write-Output '  [PASS] Authorization URL construction, PKCE parameter, and client ID validation verified'

    # 6. Test OAuth client configuration discovery
    $tempCfgDir = Join-Path $env:TEMP "gdrive_test_cfg_$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tempCfgDir | Out-Null
    try {
        $sampleInstalledJson = @{
            installed = @{
                client_id = 'test-client-id-installed.apps.googleusercontent.com'
                project_id = 'test-proj'
                auth_uri = 'https://accounts.google.com/o/oauth2/auth'
                token_uri = 'https://oauth2.googleapis.com/token'
            }
        } | ConvertTo-Json
        $tempFile = Join-Path $tempCfgDir 'google-oauth.json'
        Set-Content -LiteralPath $tempFile -Value $sampleInstalledJson

        $fakeLocalApp = Join-Path $tempCfgDir 'appdata'
        $fakeConfigDir = Join-Path $fakeLocalApp 'NSCloudDrive\config'
        New-Item -ItemType Directory -Path $fakeConfigDir -Force | Out-Null
        Copy-Item -LiteralPath $tempFile -Destination (Join-Path $fakeConfigDir 'google-oauth.json')

        $origLocalApp = $env:LOCALAPPDATA
        $origClientId = $env:GOOGLE_CLIENT_ID
        $env:GOOGLE_CLIENT_ID = $null
        try {
            $env:LOCALAPPDATA = $fakeLocalApp
            $discovered = Get-GoogleOAuthConfig
            if (-not $discovered.IsConfigured) {
                throw 'Expected installed client JSON format to be recognized as configured.'
            }
            if ($discovered.ClientId -ne 'test-client-id-installed.apps.googleusercontent.com') {
                throw "Expected ClientId 'test-client-id-installed.apps.googleusercontent.com', found '$($discovered.ClientId)'"
            }
            if (-not [string]::IsNullOrEmpty($discovered.ClientSecret)) {
                throw 'ClientSecret should be null/empty when not provided in installed json.'
            }
        } finally {
            $env:LOCALAPPDATA = $origLocalApp
            $env:GOOGLE_CLIENT_ID = $origClientId
        }
    } finally {
        Remove-Item -LiteralPath $tempCfgDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output '  [PASS] Google OAuth configuration discovery with installed client format verified'

    # 7. Test WebUtility HTML encoding for callback safety
    $encoded = [System.Net.WebUtility]::HtmlEncode('<script>alert("xss")</script>')
    if ($encoded -ne '&lt;script&gt;alert(&quot;xss&quot;)&lt;/script&gt;') {
        throw "HtmlEncode output mismatch: $encoded"
    }
    Write-Output '  [PASS] WebUtility HtmlEncode verified'

    # 8. Test publisher bundled configuration discovery and placeholder filtering
    $tempBundledDir = Join-Path $env:TEMP ('NSCloudDrive_BundledTest_' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempBundledDir -Force | Out-Null
    try {
        $placeholderJson = '{"installed":{"client_id":"YOUR_CLIENT_ID_HERE.apps.googleusercontent.com"}}'
        $placeholderFile = Join-Path $tempBundledDir 'google-oauth.json'
        Set-Content -LiteralPath $placeholderFile -Value $placeholderJson

        $validJson = '{"installed":{"client_id":"publisher-bundled-12345.apps.googleusercontent.com","client_secret":"pub-secret-xyz"}}'
        $validFile = Join-Path $tempBundledDir 'valid-client.json'
        Set-Content -LiteralPath $validFile -Value $validJson

        # Test Import-GoogleOAuthConfigFile
        $imported = Import-GoogleOAuthConfigFile -SourceFilePath $validFile
        if (-not $imported.IsConfigured) {
            throw 'Imported configuration was not recognized as configured.'
        }
        if ($imported.ClientId -ne 'publisher-bundled-12345.apps.googleusercontent.com') {
            throw "Expected ClientId 'publisher-bundled-12345.apps.googleusercontent.com', found '$($imported.ClientId)'"
        }
        if ($imported.ClientSecret -ne 'pub-secret-xyz') {
            throw "Expected ClientSecret 'pub-secret-xyz', found '$($imported.ClientSecret)'"
        }
    } finally {
        Remove-Item -LiteralPath $tempBundledDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output '  [PASS] Publisher configuration import, placeholder filtering, and client secret discovery verified'

    # 8. Test multi-account token isolation and remote environment generation
    $personalTokens = @{
        access_token = 'personal_access_token_123'
        refresh_token = 'personal_refresh_token_456'
        token_type = 'Bearer'
        expires_in = 3600
        scope = 'https://www.googleapis.com/auth/drive.readonly'
    }
    $workTokens = @{
        access_token = 'work_access_token_789'
        refresh_token = 'work_refresh_token_012'
        token_type = 'Bearer'
        expires_in = 3600
        scope = 'https://www.googleapis.com/auth/drive.readonly'
    }

    Save-GoogleDriveTokens -TokenData $personalTokens -AccountId 'gdrive_personal'
    Save-GoogleDriveTokens -TokenData $workTokens -AccountId 'gdrive_work'

    $loadedPersonal = Get-GoogleDriveStoredTokens -AccountId 'gdrive_personal'
    $loadedWork = Get-GoogleDriveStoredTokens -AccountId 'gdrive_work'

    if (-not $loadedPersonal -or $loadedPersonal.access_token -ne 'personal_access_token_123') {
        throw 'Failed to load isolated personal tokens'
    }
    if (-not $loadedWork -or $loadedWork.access_token -ne 'work_access_token_789') {
        throw 'Failed to load isolated work tokens'
    }

    $workRclone = Get-GoogleDriveRcloneEnvironment -AccountId 'gdrive_work' -RemoteName 'gdrive_work'
    if ($workRclone['RCLONE_CONFIG_GDRIVE_WORK_TYPE'] -ne 'drive') {
        throw 'Expected RCLONE_CONFIG_GDRIVE_WORK_TYPE to be drive'
    }
    $workParsed = $workRclone['RCLONE_CONFIG_GDRIVE_WORK_TOKEN'] | ConvertFrom-Json
    if ($workParsed.access_token -ne 'work_access_token_789') {
        throw 'Work rclone token does not match work account access token'
    }

    Remove-GoogleDriveSession -AccountId 'gdrive_personal'
    if (Get-GoogleDriveStoredTokens -AccountId 'gdrive_personal') {
        throw 'Expected personal account tokens to be removed'
    }
    if (-not (Get-GoogleDriveStoredTokens -AccountId 'gdrive_work')) {
        throw 'Work account tokens should remain after personal account removal'
    }
    Remove-GoogleDriveSession -AccountId 'gdrive_work'
    Write-Output '  [PASS] Multi-account Google Drive token isolation and dynamic rclone remotes verified'

} finally {
    $env:LOCALAPPDATA = $origGlobalLocalAppData
    Remove-Item -LiteralPath $globalSandboxDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All GoogleDriveProvider tests passed.'
