Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')

Write-Output 'Testing ConnectionState model...'

# 1. Test all states return valid info
$states = Get-ConnectionStates
if ($states.Count -ne 10) {
    throw "Expected 10 connection states, found $($states.Count)"
}

foreach ($state in $states) {
    $info = Get-ConnectionStateInfo $state
    if ($info.State -ne $state) {
        throw "State info mismatch for state: $state"
    }
    if ([string]::IsNullOrEmpty($info.Label)) {
        throw "Missing label for state: $state"
    }
    if ([string]::IsNullOrEmpty($info.BadgeColor)) {
        throw "Missing badge color for state: $state"
    }
}
Write-Output '  [PASS] All states return valid metadata'

# 2. Test valid transitions
$validTransitions = @(
    @('Disconnected', 'OpeningSignIn'),
    @('OpeningSignIn', 'AwaitingUserAuth'),
    @('AwaitingUserAuth', 'ValidatingAuthorization'),
    @('ValidatingAuthorization', 'CheckingAccountScope'),
    @('CheckingAccountScope', 'ListingFiles'),
    @('ListingFiles', 'Connected'),
    @('Connected', 'AuthenticationExpired'),
    @('AuthenticationExpired', 'Reconnecting'),
    @('Reconnecting', 'Connected'),
    @('Connected', 'Disconnected'),
    @('AwaitingUserAuth', 'Error')
)

foreach ($transition in $validTransitions) {
    $from = $transition[0]
    $to = $transition[1]
    if (-not (Test-ValidConnectionTransition $from $to)) {
        throw "Expected transition from $from to $to to be valid"
    }
    Assert-ValidConnectionTransition $from $to
}
Write-Output '  [PASS] Valid transitions succeed'

# 3. Test invalid transitions throw
$invalidTransitions = @(
    @('Disconnected', 'ListingFiles'),
    @('AwaitingUserAuth', 'Connected'),
    @('OpeningSignIn', 'ListingFiles')
)

foreach ($transition in $invalidTransitions) {
    $from = $transition[0]
    $to = $transition[1]
    if (Test-ValidConnectionTransition $from $to) {
        throw "Expected transition from $from to $to to be invalid"
    }
    $threw = $false
    try {
        Assert-ValidConnectionTransition $from $to
    } catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "Assert-ValidConnectionTransition did not throw on invalid transition from $from to $to"
    }
}
Write-Output '  [PASS] Invalid transitions fail closed'

# 4. Test sanitization
$sensitiveMessage = 'HTTP 401: access_token=ya29.sensitiveTokenValue&refresh_token=1//sensitiveRefresh, Cookie: ndus=sensitiveNdusValue; password: secretPassword'
$sanitized = Format-SanitizedDiagnosticMessage $sensitiveMessage

if ($sanitized -match 'ya29\.sensitiveTokenValue' -or
    $sanitized -match 'sensitiveRefresh' -or
    $sanitized -match 'sensitiveNdusValue' -or
    $sanitized -match 'secretPassword') {
    throw "Sanitization failed to redact sensitive strings: $sanitized"
}

if ($sanitized -notmatch 'access_token=\[REDACTED\]' -or
    $sanitized -notmatch 'refresh_token=\[REDACTED\]') {
    throw "Sanitization missing expected REDACTED replacement: $sanitized"
}
Write-Output '  [PASS] Secret sanitization verified'

Write-Output 'All ConnectionState tests passed.'
