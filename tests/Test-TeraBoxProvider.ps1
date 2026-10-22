Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\providers\TeraBoxProvider.ps1')

Write-Output 'Testing TeraBoxProvider...'

# Sandbox LOCALAPPDATA to protect user's real credential store
$origGlobalLocalAppData = $env:LOCALAPPDATA
$globalSandboxDir = Join-Path $env:TEMP "terabox_test_sandbox_$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $globalSandboxDir | Out-Null
$env:LOCALAPPDATA = $globalSandboxDir

try {
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

    # 3. Test DPAPI session save and load in sandbox
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

    # 5. Test rclone environment variable construction
    $emptyEnv = Get-TeraBoxRcloneEnvironment
    if ($emptyEnv.Count -ne 0) { throw 'Expected empty environment when disconnected' }

    $testEnv = Get-TeraBoxRcloneEnvironment -SessionOverride @{ Type = 'web-session'; Secret = 'my_ndus_token' }
    if ($testEnv['RCLONE_CONFIG_TERABOX_TYPE'] -ne 'terabox') { throw 'Expected RCLONE_CONFIG_TERABOX_TYPE to be terabox' }
    if ($testEnv['RCLONE_CONFIG_TERABOX_COOKIE'] -ne 'ndus=my_ndus_token') { throw 'Expected RCLONE_CONFIG_TERABOX_COOKIE to be ndus=my_ndus_token' }

    # Preserves already formatted ndus= prefix
    $prefixedEnv = Get-TeraBoxRcloneEnvironment -SessionOverride @{ Type = 'web-session'; Secret = 'ndus=prefixed_token' }
    if ($prefixedEnv['RCLONE_CONFIG_TERABOX_COOKIE'] -ne 'ndus=prefixed_token') { throw 'Expected already prefixed cookie to be preserved' }

    # Formats multi-cookie headers and strips Cookie: prefix properly
    $multiEnv = Get-TeraBoxRcloneEnvironment -SessionOverride @{ Type = 'web-session'; Secret = 'Cookie: browserid=123; ndus=abc; csrfToken=xyz' }
    if ($multiEnv['RCLONE_CONFIG_TERABOX_COOKIE'] -ne 'browserid=123; ndus=abc; csrfToken=xyz') { throw 'Expected multi-cookie header to be preserved without ndus= wrapper' }

    if ((Format-TeraBoxCookieHeader 'raw_value') -ne 'ndus=raw_value') { throw 'Expected raw_value to be prefixed with ndus=' }
    if ((Format-TeraBoxCookieHeader 'ndus=already') -ne 'ndus=already') { throw 'Expected ndus=already to be preserved' }
    if ((Format-TeraBoxCookieHeader 'a=1; b=2') -ne 'a=1; b=2') { throw 'Expected multi-cookie string to be preserved' }
    Write-Output '  [PASS] TeraBox rclone environment variable construction verified'

    # 6. Test manual session setter fails closed on invalid credentials
    $manualRes = Set-TeraBoxManualSession -SessionSecret 'invalid_test_secret_123'
    if ($manualRes.Success -ne $false) { throw 'Expected invalid manual session to fail closed' }
    Write-Output '  [PASS] Manual session validation fails closed on invalid credentials'
} finally {
    $env:LOCALAPPDATA = $origGlobalLocalAppData
    Remove-Item -LiteralPath $globalSandboxDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'All TeraBoxProvider tests passed.'
