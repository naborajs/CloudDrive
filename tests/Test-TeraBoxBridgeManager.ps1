# Test-TeraBoxBridgeManager.ps1 - Validates CPX WebDAV bridge manager
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\services\TeraBoxBridgeManager.ps1')

Write-Output 'Testing TeraBoxBridgeManager...'

# 1. Test binary discovery
$cpx = Find-CpxBinary
if (-not $cpx) {
    throw 'Find-CpxBinary failed to locate cpx.exe.'
}
if (-not (Test-Path -LiteralPath $cpx)) {
    throw "cpx.exe does not exist at path: $cpx"
}
Write-Output "  [PASS] CPX binary located: $cpx"

# 2. Test bridge home initialization
$testHome = Join-Path $env:TEMP 'NSCloudDrive_Bridge_Test'
if (Test-Path -LiteralPath $testHome) { Remove-Item -Recurse -Force -LiteralPath $testHome }

$initDir = Initialize-TeraBoxBridgeHome -HomeDirectory $testHome
if (-not (Test-Path -LiteralPath (Join-Path $testHome 'settings.json'))) {
    throw 'settings.json was not created in bridge home'
}
$settingsContent = Get-Content -Raw -LiteralPath (Join-Path $testHome 'settings.json')
if (-not $settingsContent.Contains('"Transport":  "web"')) {
    throw 'settings.json does not specify web transport'
}
Write-Output '  [PASS] Bridge home directory and settings.json initialization verified'

# 3. Test DPAPI secret protection with CloudPlayX entropy
$mockSession = @{
    Secret = 'ndus=mock_unit_test_session_cookie'
    BaseUrl = 'https://www.terabox.com'
    UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    JsToken = 'mock_jstoken_123'
}

$pw = Set-TeraBoxBridgeSecrets -Session $mockSession -HomeDirectory $testHome
if ([string]::IsNullOrWhiteSpace($pw) -or -not $pw.StartsWith('cpx_')) {
    throw "Unexpected bridge password generated: $pw"
}

$bridgeKeyFile = Join-Path $testHome 'terabox.bridge.key'
$sessionKeyFile = Join-Path $testHome 'terabox.websession.key'
if (-not (Test-Path -LiteralPath $bridgeKeyFile)) { throw 'terabox.bridge.key was not created' }
if (-not (Test-Path -LiteralPath $sessionKeyFile)) { throw 'terabox.websession.key was not created' }

# Decrypt and verify
$entropy = [System.Text.Encoding]::UTF8.GetBytes('CloudPlayX.v1.secret')
$decSecretBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    [System.IO.File]::ReadAllBytes($bridgeKeyFile),
    $entropy,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
)
$decSecret = [System.Text.Encoding]::UTF8.GetString($decSecretBytes)
if ($decSecret -ne $pw) {
    throw "Decrypted bridge password mismatch ($decSecret vs $pw)"
}

$decWsBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    [System.IO.File]::ReadAllBytes($sessionKeyFile),
    $entropy,
    [System.Security.Cryptography.DataProtectionScope]::CurrentUser
)
$decWsJson = [System.Text.Encoding]::UTF8.GetString($decWsBytes)
if (-not $decWsJson.Contains('mock_unit_test_session_cookie') -or -not $decWsJson.Contains('mock_jstoken_123')) {
    throw 'Decrypted web session JSON missing expected fields'
}
Write-Output '  [PASS] DPAPI secret generation and CloudPlayX entropy interoperability verified'

# 4. Test rclone environment variable construction
$rcloneBinary = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe'
$envVars = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword $pw -Port 19191 -RcloneBinary $rcloneBinary
if ($envVars['RCLONE_CONFIG_TERABOX_TYPE'] -ne 'webdav') {
    throw 'Expected RCLONE_CONFIG_TERABOX_TYPE to be webdav'
}
if ($envVars['RCLONE_CONFIG_TERABOX_URL'] -ne 'http://127.0.0.1:19191/') {
    throw 'Expected RCLONE_CONFIG_TERABOX_URL to point to 127.0.0.1:19191/'
}
if ($envVars['RCLONE_CONFIG_TERABOX_USER'] -ne 'cpx') {
    throw 'Expected RCLONE_CONFIG_TERABOX_USER to be cpx'
}
if (Test-Path -LiteralPath $rcloneBinary) {
    if (-not $envVars.Contains('RCLONE_CONFIG_TERABOX_PASS') -or [string]::IsNullOrEmpty($envVars['RCLONE_CONFIG_TERABOX_PASS'])) {
        throw 'Expected RCLONE_CONFIG_TERABOX_PASS to be populated when rclone binary exists'
    }
}
Write-Output '  [PASS] TeraBox WebDAV rclone environment variables verified'

# 5. Clean up temporary test home
try { Remove-Item -Recurse -Force -LiteralPath $testHome } catch { }

Write-Output 'All TeraBoxBridgeManager tests passed.'
