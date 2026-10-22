Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\providers\TeraBoxProvider.ps1')

Write-Output 'Testing TeraBoxProvider...'

# 1. Test metadata
$info = Get-TeraBoxProviderInfo
if ($info.Id -ne 'terabox') { throw "Expected provider ID 'terabox', found $($info.Id)" }
if ($info.Name -ne 'TeraBox') { throw "Expected provider name 'TeraBox', found $($info.Name)" }
if ($info.AuthMethods.Count -ne 2) { throw "Expected 2 auth methods, found $($info.AuthMethods.Count)" }
Write-Output '  [PASS] Provider metadata verified'

# 2. Test fail-closed when disconnected
$check = Test-TeraBoxBackendSession
if ($check.IsValid -ne $false) { throw 'Expected IsValid to be false without session' }
if ($check.State -ne 'Disconnected') { throw "Expected state 'Disconnected', found $($check.State)" }
Write-Output '  [PASS] Missing session fails closed'

# 3. Test DPAPI session save and load
$testSecret = 'synthetic_test_secret_value'
Save-TeraBoxSession -Type 'web-session' -Secret $testSecret
$loaded = Get-TeraBoxStoredSession
if (-not $loaded) { throw 'Failed to load saved session' }
if ($loaded.Type -ne 'web-session') { throw "Session type mismatch: $($loaded.Type)" }
if ($loaded.Secret -ne $testSecret) { throw 'Secret value mismatch' }
Write-Output '  [PASS] DPAPI session save and load verified'

# Clean up session
Remove-TeraBoxSession
$afterRemove = Get-TeraBoxStoredSession
if ($afterRemove) { throw 'Session was not cleanly removed' }
Write-Output '  [PASS] Session removal verified'

# 4. Test account scope evaluation
$webScope = Test-TeraBoxAccountScope -SessionOverride @{ Type = 'web-session'; Secret = 'dummy' }
# Note: because 'dummy' fails validation against real network, scope is unknown
if ($webScope.ScopeVerified) {
    # If network unexpectedly succeeded with dummy
    throw 'Dummy secret unexpectedly passed network validation'
} else {
    Write-Output '  [PASS] Unverified session correctly rejected for scope'
}

Write-Output 'All TeraBoxProvider tests passed.'
