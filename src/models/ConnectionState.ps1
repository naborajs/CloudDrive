Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Define connection states required by the NS Cloud Drive architecture
$script:ConnectionStates = @(
    'Disconnected',
    'OpeningSignIn',
    'AwaitingUserAuth',
    'ValidatingAuthorization',
    'CheckingAccountScope',
    'ListingFiles',
    'Connected',
    'AuthenticationExpired',
    'Reconnecting',
    'Error'
)

function Get-ConnectionStates {
    return $script:ConnectionStates
}

function Get-ConnectionStateInfo([string]$State) {
    switch ($State) {
        'Disconnected' {
            return [ordered]@{
                State = 'Disconnected'
                Label = 'Disconnected'
                Description = 'No account is connected.'
                BadgeColor = '#667085'
                BadgeBackground = '#F2F4F7'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'OpeningSignIn' {
            return [ordered]@{
                State = 'OpeningSignIn'
                Label = 'Opening sign-in'
                Description = 'Opening the provider authentication interface...'
                BadgeColor = '#B54708'
                BadgeBackground = '#FFFAEB'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'AwaitingUserAuth' {
            return [ordered]@{
                State = 'AwaitingUserAuth'
                Label = 'Awaiting authentication'
                Description = 'Please complete sign-in in the provider window.'
                BadgeColor = '#B54708'
                BadgeBackground = '#FFFAEB'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'ValidatingAuthorization' {
            return [ordered]@{
                State = 'ValidatingAuthorization'
                Label = 'Validating authorization'
                Description = 'Verifying credentials with the provider backend...'
                BadgeColor = '#026AA2'
                BadgeBackground = '#F0F9FF'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'CheckingAccountScope' {
            return [ordered]@{
                State = 'CheckingAccountScope'
                Label = 'Checking account scope'
                Description = 'Verifying granted permissions and accessible directories...'
                BadgeColor = '#026AA2'
                BadgeBackground = '#F0F9FF'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'ListingFiles' {
            return [ordered]@{
                State = 'ListingFiles'
                Label = 'Listing files'
                Description = 'Testing file access by querying root directory...'
                BadgeColor = '#026AA2'
                BadgeBackground = '#F0F9FF'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'Connected' {
            return [ordered]@{
                State = 'Connected'
                Label = 'Connected'
                Description = 'Account verified and ready to mount.'
                BadgeColor = '#027A48'
                BadgeBackground = '#ECFDF3'
                IsTerminal = $false
                IsConnected = $true
            }
        }
        'AuthenticationExpired' {
            return [ordered]@{
                State = 'AuthenticationExpired'
                Label = 'Authentication expired'
                Description = 'Session or token has expired. Re-authentication required.'
                BadgeColor = '#B54708'
                BadgeBackground = '#FFFAEB'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'Reconnecting' {
            return [ordered]@{
                State = 'Reconnecting'
                Label = 'Reconnecting'
                Description = 'Attempting to refresh session credentials...'
                BadgeColor = '#026AA2'
                BadgeBackground = '#F0F9FF'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        'Error' {
            return [ordered]@{
                State = 'Error'
                Label = 'Error'
                Description = 'Connection failed. Review diagnostics for details.'
                BadgeColor = '#B42318'
                BadgeBackground = '#FEF3F2'
                IsTerminal = $false
                IsConnected = $false
            }
        }
        default {
            throw "Unknown connection state: '$State'"
        }
    }
}

function Test-ValidConnectionTransition([string]$FromState, [string]$ToState) {
    if ($FromState -notin $script:ConnectionStates) {
        throw "Invalid source state: '$FromState'"
    }
    if ($ToState -notin $script:ConnectionStates) {
        throw "Invalid target state: '$ToState'"
    }

    # Error and Disconnected can be transitioned to from any state
    if ($ToState -in @('Error', 'Disconnected')) {
        return $true
    }

    switch ($FromState) {
        'Disconnected' {
            return $ToState -in @('OpeningSignIn', 'ValidatingAuthorization', 'Reconnecting')
        }
        'OpeningSignIn' {
            return $ToState -in @('AwaitingUserAuth', 'ValidatingAuthorization')
        }
        'AwaitingUserAuth' {
            return $ToState -eq 'ValidatingAuthorization'
        }
        'ValidatingAuthorization' {
            return $ToState -in @('CheckingAccountScope', 'ListingFiles', 'Connected')
        }
        'CheckingAccountScope' {
            return $ToState -in @('ListingFiles', 'Connected')
        }
        'ListingFiles' {
            return $ToState -eq 'Connected'
        }
        'Connected' {
            return $ToState -in @('AuthenticationExpired', 'Reconnecting', 'CheckingAccountScope', 'ListingFiles')
        }
        'AuthenticationExpired' {
            return $ToState -in @('OpeningSignIn', 'Reconnecting', 'ValidatingAuthorization')
        }
        'Reconnecting' {
            return $ToState -in @('ValidatingAuthorization', 'Connected')
        }
        'Error' {
            return $ToState -in @('OpeningSignIn', 'ValidatingAuthorization', 'Disconnected')
        }
        default {
            return $false
        }
    }
}

function Assert-ValidConnectionTransition([string]$FromState, [string]$ToState) {
    if (-not (Test-ValidConnectionTransition $FromState $ToState)) {
        throw "Illegal connection state transition from '$FromState' to '$ToState'"
    }
}

function Format-SanitizedDiagnosticMessage([string]$Message) {
    if ([string]::IsNullOrEmpty($Message)) { return '' }
    $sanitized = $Message
    # Redact sensitive parameters
    $sanitized = $sanitized -replace '(?i)(access_token[s]?\s*[=:]\s*)[^\s&";]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(refresh_token\s*[=:]\s*)[^\s&";]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(client_secret\s*[=:]\s*)[^\s&";]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(code\s*=\s*)[^\s&";]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(ndus\s*=\s*)[^\s&";]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(cookie\s*:\s*)[^\r\n]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(authorization\s*:\s*Bearer\s+)[^\r\n]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(password\s*[=:]\s*)[^\s&";]+', '$1[REDACTED]'
    return $sanitized
}
