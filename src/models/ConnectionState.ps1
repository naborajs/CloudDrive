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

    # Redact JSON-formatted string values: "key": "value"
    $sanitized = $sanitized -replace '(?i)("?(?:access_token[s]?|refresh_token|client_secret|token|code|ndus|BDUSS|password)"?\s*:\s*")([^"\\]|\\.)*(")', '$1[REDACTED]$3'

    # Redact key=value or key: value parameters (both unquoted and quoted)
    $sanitized = $sanitized -replace '(?i)(\b(?:access_token[s]?|refresh_token|client_secret|token|code|ndus|BDUSS|password)\s*[=:]\s*["'']?)[^\s&"'';]+(["'']?)', '$1[REDACTED]$2'

    # Redact raw Google OAuth access and refresh token formats anywhere in text
    $sanitized = $sanitized -replace '\bya29\.[a-zA-Z0-9_\.\-]+', 'ya29.[REDACTED]'
    $sanitized = $sanitized -replace '\b1//[a-zA-Z0-9_\.\-]+', '1//[REDACTED]'

    # Redact sensitive HTTP headers
    $sanitized = $sanitized -replace '(?i)(cookie\s*:\s*)[^\r\n]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(set-cookie\s*:\s*)[^\r\n]+', '$1[REDACTED]'
    $sanitized = $sanitized -replace '(?i)(authorization\s*:\s*(?:Bearer|Basic)\s+)[^\r\n]+', '$1[REDACTED]'

    return $sanitized
}

# ==============================================================================
# SHARED APPLICATION LOG (bounded JSONL store; safe to call from any runspace)
# ==============================================================================
# Both the UI runspaces and the background mount workers dot-source this file,
# so the shared log lives here. Every message passes through
# Format-SanitizedDiagnosticMessage BEFORE the file is touched: authorization
# codes, tokens, passwords, session cookies, and similar secrets are redacted
# on disk, not just on screen. The store is bounded (2 MB rotate, at most two
# files) so a long session cannot grow logs without limit.
$script:ApplicationLogRotateBytes = 2MB
$script:ApplicationLogCheckState = @{ Setting = $null; ReadAt = [DateTime]::MinValue }

function Get-ApplicationLogSettingEnabled {
    # 'Normal' is the default; 'Off' disables log writes. The setting file is
    # small, so reads are rate-limited (5 s) instead of cached forever so that
    # a settings edit is honored quickly without per-write file parsing.
    try {
        if (([DateTime]::UtcNow - $script:ApplicationLogCheckState.ReadAt).TotalSeconds -lt 5 -and $null -ne $script:ApplicationLogCheckState.Setting) {
            return $script:ApplicationLogCheckState.Setting
        }
        $settingsPath = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\settings.json'
        $enabled = $true
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            $raw = [System.IO.File]::ReadAllText($settingsPath)
            $matchOn = [regex]::Match($raw, '"DiagnosticLogging"\s*:\s*"([^"]*)"')
            if ($matchOn.Success -and $matchOn.Groups[1].Value -eq 'Off') { $enabled = $false }
        }
        $script:ApplicationLogCheckState.Setting = $enabled
        $script:ApplicationLogCheckState.ReadAt = [DateTime]::UtcNow
        return $enabled
    } catch {
        return $true   # fail open for logging capability; never in a hot loop
    }
}

function Get-ApplicationLogFilePath {
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs') 'application.jsonl')
}

function Write-NSCloudLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Severity = 'Info',
        [string]$Provider = '',
        [string]$AccountId = '',
        [string]$AccountLabel = '',
        [string]$Operation = '',
        [int]$DurationMilliseconds = -1,
        [string]$Message = '',
        $Recovered = $null                        # $true / $false / $null (unknown)
    )

    try {
        if (-not (Get-ApplicationLogSettingEnabled)) { return }

        $logDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs'
        if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $logPath = Get-ApplicationLogFilePath

        # Bounded storage: rotate once, keeping only the predecessor file.
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            try {
                $info = [System.IO.FileInfo]::new($logPath)
                if ($info.Length -gt $script:ApplicationLogRotateBytes) {
                    Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }

        $entry = [ordered]@{
            timestampUtc   = [DateTime]::UtcNow.ToString('o')
            severity       = $Severity
            provider       = $Provider
            accountId      = $AccountId
            accountLabel   = $AccountLabel
            operation      = $Operation
            durationMs     = if ($DurationMilliseconds -ge 0) { [int]$DurationMilliseconds } else { [int]-1 }
            message        = (Format-SanitizedDiagnosticMessage $Message)
            recovered      = if ($null -eq $Recovered) { $null } else { [bool]$Recovered }
        }
        [System.IO.File]::AppendAllText($logPath, (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine), [System.Text.Encoding]::UTF8)
    } catch { }
}

function Read-ApplicationLogEntries([int]$MaxEntries = 200, [int]$SkipEntries = 0, [int]$MaxBytes = 2MB) {
    if ($MaxEntries -lt 1 -or $MaxEntries -gt 800) { throw 'Log page size must be between 1 and 800 entries.' }
    if ($SkipEntries -lt 0) { throw 'Log page offset cannot be negative.' }
    if ($MaxBytes -lt 1) { throw 'Log read byte limit must be positive.' }
    $MaxBytes = [Math]::Min($MaxBytes, 2MB)

    # Scan backward from the end so the read stays bounded even if a damaged
    # or externally enlarged log exceeds the normal rotation limit.
    $newestFirst = [System.Collections.Generic.List[object]]::new()
    $lineBytes = [System.Collections.Generic.List[byte]]::new()
    $logPath = Get-ApplicationLogFilePath
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return $newestFirst }

    $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $position = [int64]$stream.Length
        $scanStart = [Math]::Max([int64]0, ($position - [int64]$MaxBytes))
        $validEntriesSeen = 0
        $buffer = [byte[]]::new(4096)

        while ($position -gt $scanStart -and $newestFirst.Count -lt $MaxEntries) {
            $chunkStart = [Math]::Max($scanStart, ($position - $buffer.Length))
            $stream.Position = $chunkStart
            $bytesToRead = [int]($position - $chunkStart)
            $bytesRead = $stream.Read($buffer, 0, $bytesToRead)
            if ($bytesRead -le 0) { break }

            for ($index = $bytesRead - 1; $index -ge 0; $index--) {
                if ($buffer[$index] -eq 10) {
                    if ($lineBytes.Count -eq 0) { continue }
                    $orderedLineBytes = [byte[]]::new($lineBytes.Count)
                    for ($byteIndex = 0; $byteIndex -lt $lineBytes.Count; $byteIndex++) {
                        $orderedLineBytes[$byteIndex] = $lineBytes[$lineBytes.Count - $byteIndex - 1]
                    }
                    $lineBytes.Clear()
                    $line = [System.Text.Encoding]::UTF8.GetString($orderedLineBytes)
                    $line = $line.TrimStart([char]0xFEFF)
                    try {
                        $entry = $line | ConvertFrom-Json -ErrorAction Stop
                        if ($validEntriesSeen -lt $SkipEntries) {
                            $validEntriesSeen++
                            continue
                        }
                        $newestFirst.Add($entry)
                    } catch { }
                    if ($newestFirst.Count -ge $MaxEntries) { break }
                } elseif ($buffer[$index] -ne 13) {
                    $lineBytes.Add($buffer[$index])
                }
            }
            $position = $chunkStart
        }

        if ($position -eq 0 -and $lineBytes.Count -gt 0 -and $newestFirst.Count -lt $MaxEntries) {
            $orderedLineBytes = [byte[]]::new($lineBytes.Count)
            for ($byteIndex = 0; $byteIndex -lt $lineBytes.Count; $byteIndex++) {
                $orderedLineBytes[$byteIndex] = $lineBytes[$lineBytes.Count - $byteIndex - 1]
            }
            $line = [System.Text.Encoding]::UTF8.GetString($orderedLineBytes)
            $line = $line.TrimStart([char]0xFEFF)
            try {
                $entry = $line | ConvertFrom-Json -ErrorAction Stop
                if ($validEntriesSeen -ge $SkipEntries) { $newestFirst.Add($entry) }
            } catch { }
        }
    } finally {
        $stream.Dispose()
    }

    $oldestFirst = [System.Collections.Generic.List[object]]::new()
    for ($entryIndex = $newestFirst.Count - 1; $entryIndex -ge 0; $entryIndex--) {
        $oldestFirst.Add($newestFirst[$entryIndex])
    }
    return $oldestFirst
}

function Get-SafeProperty([object]$Object, [string]$PropertyName, $DefaultValue = $null) {
    if ($null -eq $Object) { return $DefaultValue }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($PropertyName)) { return $Object[$PropertyName] }
        return $DefaultValue
    }
    if ($Object.PSObject -and $Object.PSObject.Properties[$PropertyName]) {
        return $Object.PSObject.Properties[$PropertyName].Value
    }
    return $DefaultValue
}
