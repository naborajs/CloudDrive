Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')

Write-Output 'Testing GoogleDriveProvider...'

# 1. Test metadata
$info = Get-GoogleDriveProviderInfo
if ($info.Id -ne 'gdrive') { throw "Expected provider ID 'gdrive', found $($info.Id)" }
if ($info.Name -ne 'Google Drive') { throw "Expected provider name 'Google Drive', found $($info.Name)" }
if ($info.AuthMethods[0].Scope -ne 'https://www.googleapis.com/auth/drive.readonly') {
    throw "Scope mismatch: $($info.AuthMethods[0].Scope)"
}
Write-Output '  [PASS] Provider metadata verified'

# 2. Test state generation
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
Write-Output '  [PASS] Cryptographic state generation verified'

# 3. Test fail-closed when disconnected
$check = Test-GoogleDriveBackendSession
if ($check.IsValid -ne $false) { throw 'Expected IsValid to be false without tokens' }
if ($check.State -ne 'Disconnected') { throw "Expected state 'Disconnected', found $($check.State)" }
Write-Output '  [PASS] Missing tokens fail closed'

# 4. Test DPAPI token save and load
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

# Clean up tokens
Remove-GoogleDriveSession
$afterRemove = Get-GoogleDriveStoredTokens
if ($afterRemove) { throw 'Tokens were not cleanly removed' }
Write-Output '  [PASS] Token removal verified'

# 5. Test auth URL construction
$authUrl = Build-GoogleAuthorizationUrl -ClientId 'dummy-client-id' -RedirectUri 'http://127.0.0.1:53682/' -State 'test-state'
if ($authUrl -notmatch 'client_id=dummy-client-id' -or
    $authUrl -notmatch 'state=test-state' -or
    $authUrl -notmatch 'redirect_uri=http%3A%2F%2F127\.0\.0\.1%3A53682%2F') {
    throw "Authorization URL formatting error: $authUrl"
}
Write-Output '  [PASS] Authorization URL construction verified'

Write-Output 'All GoogleDriveProvider tests passed.'
