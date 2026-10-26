Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

function Get-GoogleCredentialDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials')
}

function Get-GoogleCredentialFilePath([string]$AccountId = '') {
    $dir = Get-GoogleCredentialDirectory
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $clean = ($AccountId -replace '[^a-zA-Z0-9_\-]', '_')
        return (Join-Path $dir "google-drive-tokens-$clean.xml")
    }
    return (Join-Path $dir 'google-drive-tokens.xml')
}

$script:GoogleAuthEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth'
$script:GoogleTokenEndpoint = 'https://oauth2.googleapis.com/token'
$script:GoogleRevokeEndpoint = 'https://oauth2.googleapis.com/revoke'
$script:GoogleDriveApiEndpoint = 'https://www.googleapis.com/drive/v3'
$script:GoogleDefaultScope = 'https://www.googleapis.com/auth/drive.readonly'

function Set-StrictCredentialAcl([string]$Path) {
    try {
        $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $isDir = (Test-Path -LiteralPath $Path -PathType Container)
        $acl = if ($isDir) {
            [System.IO.Directory]::GetAccessControl($Path)
        } else {
            [System.IO.File]::GetAccessControl($Path)
        }
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($acl.Access)) {
            [void]$acl.RemoveAccessRuleSpecific($existingRule)
        }
        foreach ($sid in @($userSid, $systemSid)) {
            $rule = if ($isDir) {
                [System.Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
            } else {
                [System.Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
            }
            [void]$acl.SetAccessRule($rule)
        }
        if ($isDir) {
            [System.IO.Directory]::SetAccessControl($Path, $acl)
        } else {
            [System.IO.File]::SetAccessControl($Path, $acl)
        }
    } catch {
        throw "Unable to restrict permissions on the Google credential path '$Path': $($_.Exception.Message)"
    }
}

function Get-GoogleDriveProviderInfo {
    return [ordered]@{
        Id = 'gdrive'
        Name = 'Google Drive'
        Mark = 'GD'
        AccentColor = '#0F9D58'
        AuthMethods = @(
            [ordered]@{
                Id = 'oauth-loopback'
                Name = 'Sign in with Google (OAuth 2.0)'
                Description = 'Standard RFC 8252 loopback authorization in system browser.'
                Status = 'Official Google OAuth 2.0'
                Scope = $script:GoogleDefaultScope
                ScopeExplanation = 'Read-only access to files and metadata for the virtual drive.'
            }
        )
    }
}

function New-OAuthState {
    $bytes = New-Object byte[] 24
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
}

function New-PkceVerifier {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-PkceChallenge([string]$Verifier) {
    if ([string]::IsNullOrEmpty($Verifier)) {
        throw 'Cannot generate PKCE challenge from an empty verifier.'
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Verifier))
    return [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-GoogleDriveStoredTokens([string]$AccountId = '') {
    $credPath = Get-GoogleCredentialFilePath -AccountId $AccountId
    if (-not (Test-Path -LiteralPath $credPath -PathType Leaf)) {
        # Account-scoped reads must NEVER silently fall back to the shared
        # legacy token file: that file belongs to the legacy single-account
        # connection and may hold a DIFFERENT Google user's tokens. Falling
        # back here would validate, refresh, and even mount that other user's
        # Drive under this account's id and drive letter. A missing
        # account-specific file is a clean "no tokens for this account"
        # answer; consumers report a sign-in requirement for it.
        return $null
    }

    try {
        $cred = Import-Clixml -LiteralPath $credPath
        if ($cred -is [System.Management.Automation.PSCredential]) {
            $bstr = [IntPtr]::Zero
            try {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                $json = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                return ($json | ConvertFrom-Json)
            } finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
                $json = $null
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Save-GoogleDriveTokens($TokenData, [string]$AccountId = '') {
    $tokenHt = if ($TokenData -is [hashtable]) {
        $TokenData
    } elseif ($TokenData -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($k in $TokenData.Keys) { $ht[[string]$k] = $TokenData[$k] }
        $ht
    } elseif ($null -ne $TokenData -and $TokenData.PSObject.Properties['access_token']) {
        $ht = @{}
        foreach ($p in $TokenData.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        $ht
    } else {
        $null
    }

    if (-not $tokenHt -or -not $tokenHt.ContainsKey('access_token') -or [string]::IsNullOrWhiteSpace($tokenHt['access_token'])) {
        throw 'Cannot store invalid Google Drive tokens.'
    }

    $credDir = Get-GoogleCredentialDirectory
    $credPath = Get-GoogleCredentialFilePath -AccountId $AccountId

    if (-not (Test-Path -LiteralPath $credDir)) {
        New-Item -ItemType Directory -Path $credDir | Out-Null
    }
    Set-StrictCredentialAcl -Path $credDir

    $json = $tokenHt | ConvertTo-Json -Compress
    $secString = ConvertTo-SecureString -String $json -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('google-drive', $secString)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $credPath
        Set-StrictCredentialAcl -Path $credPath
    } finally {
        $secString.Dispose()
    }
}

function Save-GoogleDriveStoredTokens {
    param(
        $Tokens = $null,
        $TokenData = $null,
        [string]$AccountId = ''
    )
    $payload = if ($null -ne $TokenData) { $TokenData } else { $Tokens }
    Save-GoogleDriveTokens -TokenData $payload -AccountId $AccountId
}

function Sync-GoogleDriveTokensFromRcloneConfig(
    [string]$AccountId = '',
    [string]$RemoteName = 'gdrive',
    [string]$ConfigPath = '',
    [switch]$Force
) {
    $existing = Get-GoogleDriveStoredTokens -AccountId $AccountId
    $existingExpUtc = [DateTime]::MinValue
    if ($existing) {
        if ($existing.PSObject.Properties['expiry'] -and -not [string]::IsNullOrWhiteSpace($existing.expiry)) {
            try { $existingExpUtc = [DateTime]::Parse($existing.expiry).ToUniversalTime() } catch { }
        }
        if ($existingExpUtc -eq [DateTime]::MinValue -and $existing.PSObject.Properties['obtained_at'] -and $existing.obtained_at -and $existing.PSObject.Properties['expires_in'] -and $existing.expires_in) {
            try {
                $obtainedUtc = [DateTime]::Parse($existing.obtained_at).ToUniversalTime()
                $existingExpUtc = $obtainedUtc.AddSeconds([int]$existing.expires_in)
            } catch { }
        }
    }

    # If the currently stored token is still valid for > 60s and not forced, check if sync is even necessary
    $storedIsValid = ($existingExpUtc -gt [DateTime]::UtcNow.AddSeconds(60))

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $candidates.Add($ConfigPath)
    }
    if ($env:RCLONE_CONFIG -and -not [string]::IsNullOrWhiteSpace($env:RCLONE_CONFIG)) {
        $candidates.Add($env:RCLONE_CONFIG)
    }
    $isolatedConf = Join-Path (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config') 'account-mount-isolated.conf'
    if (Test-Path -LiteralPath $isolatedConf -PathType Leaf) {
        $candidates.Add($isolatedConf)
    }
    $globalConf = Join-Path $env:APPDATA 'rclone\rclone.conf'
    if (Test-Path -LiteralPath $globalConf -PathType Leaf) {
        $candidates.Add($globalConf)
    }

    $targetSections = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $targetSections.Add($AccountId)
        if (-not $AccountId.StartsWith('gdrive_')) {
            $targetSections.Add("gdrive_$AccountId")
        }
        if (-not [string]::IsNullOrWhiteSpace($RemoteName) -and $RemoteName -eq $AccountId) {
            $targetSections.Add($RemoteName)
        }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($RemoteName)) {
            $targetSections.Add($RemoteName)
        }
        $targetSections.Add('gdrive')
    }

    $bestToken = $null
    $bestExpiryUtc = [DateTime]::MinValue

    foreach ($confFile in $candidates) {
        if (-not (Test-Path -LiteralPath $confFile -PathType Leaf)) { continue }
        try {
            $lines = Get-Content -LiteralPath $confFile -ErrorAction Stop
            $currentSection = ''
            foreach ($line in $lines) {
                if ($line -match '^\s*\[([^\]]+)\]\s*$') {
                    $currentSection = $Matches[1].Trim()
                    continue
                }
                if ($currentSection -and ($targetSections.Contains($currentSection))) {
                    if ($line -match '^\s*token\s*=\s*(.+)$') {
                        $rawTokenJson = $Matches[1].Trim()
                        try {
                            $parsed = $rawTokenJson | ConvertFrom-Json
                            if ($parsed -and $parsed.PSObject.Properties['access_token'] -and $parsed.access_token -and
                                $parsed.PSObject.Properties['expiry'] -and $parsed.expiry) {
                                $tokenExpUtc = [DateTime]::Parse($parsed.expiry).ToUniversalTime()
                                if ($tokenExpUtc -gt $bestExpiryUtc) {
                                    $bestExpiryUtc = $tokenExpUtc
                                    $bestToken = $parsed
                                }
                            }
                        } catch { }
                    }
                }
            }
        } catch { }
    }

    # Only sync if the rclone.conf token is valid AND either stored is expired or rclone token is strictly newer
    $shouldSync = $false
    if ($bestToken -and $bestExpiryUtc -gt [DateTime]::UtcNow.AddSeconds(30)) {
        if (-not $storedIsValid -or $Force -or ($bestExpiryUtc -gt $existingExpUtc.AddSeconds(60))) {
            $shouldSync = $true
        }
    }

    if ($shouldSync) {
        $remainingSec = [Math]::Max(0, [int]($bestExpiryUtc - [DateTime]::UtcNow).TotalSeconds)
        $refreshToken = if ($bestToken.PSObject.Properties['refresh_token'] -and -not [string]::IsNullOrEmpty($bestToken.refresh_token)) {
            [string]$bestToken.refresh_token
        } elseif ($existing -and $existing.PSObject.Properties['refresh_token'] -and -not [string]::IsNullOrEmpty($existing.refresh_token)) {
            [string]$existing.refresh_token
        } else {
            $null
        }
        $tokenType = if ($bestToken.PSObject.Properties['token_type'] -and -not [string]::IsNullOrEmpty($bestToken.token_type)) {
            [string]$bestToken.token_type
        } elseif ($existing -and $existing.PSObject.Properties['token_type'] -and -not [string]::IsNullOrEmpty($existing.token_type)) {
            [string]$existing.token_type
        } else {
            'Bearer'
        }

        $tokenData = @{
            access_token  = [string]$bestToken.access_token
            token_type    = $tokenType
            refresh_token = $refreshToken
            expiry        = $bestExpiryUtc.ToString('o')
            obtained_at   = [DateTime]::UtcNow.ToString('o')
            expires_in    = $remainingSec
        }
        Save-GoogleDriveTokens -TokenData $tokenData -AccountId $AccountId
        return (Get-GoogleDriveStoredTokens -AccountId $AccountId)
    }

    if ($storedIsValid) {
        return $existing
    }

    return $null
}

function Remove-GoogleDriveSession([string]$AccountId = '') {
    $tokens = Get-GoogleDriveStoredTokens -AccountId $AccountId
    $tokenToRevoke = if ($tokens -and $tokens.refresh_token) { $tokens.refresh_token } elseif ($tokens -and $tokens.access_token) { $tokens.access_token } else { $null }
    if ($tokenToRevoke) {
        try {
            $body = @{ token = $tokenToRevoke }
            $headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
            Invoke-RestMethod -Uri $script:GoogleRevokeEndpoint -Method Post -Body $body -Headers $headers -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        } catch { }
    }

    $credPath = Get-GoogleCredentialFilePath -AccountId $AccountId
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-GoogleOAuthConfig {
    $userConfigDirectory = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config'
    $appConfigDirectory = Join-Path $PSScriptRoot '..\config'

    $clientId = $env:GOOGLE_CLIENT_ID
    $clientSecret = $env:GOOGLE_CLIENT_SECRET
    $foundPath = $null
    $configSource = 'None'

    if ($clientId) {
        $configSource = 'EnvironmentVariable'
        $foundPath = 'env:GOOGLE_CLIENT_ID'
    } else {
        # 1. Check publisher bundled configuration in repo/application directory
        $bundledCandidates = @(
            (Join-Path $appConfigDirectory 'google-oauth.json'),
            (Join-Path $appConfigDirectory 'client_secret.json'),
            (Join-Path $PSScriptRoot '..\google-client.json'),
            (Join-Path $PSScriptRoot '..\google-oauth.json')
        )
        if (Test-Path -LiteralPath $appConfigDirectory -PathType Container) {
            $appGlob = Get-ChildItem -Path $appConfigDirectory -Filter 'client_secret_*.json' -File -ErrorAction SilentlyContinue
            if ($appGlob) { $bundledCandidates += ($appGlob | Select-Object -ExpandProperty FullName) }
        }

        # 2. Check user LocalAppData configuration
        $userCandidates = @(
            (Join-Path $userConfigDirectory 'google-oauth.json'),
            (Join-Path $userConfigDirectory 'client_secret.json'),
            (Join-Path $userConfigDirectory 'credentials.json')
        )
        if (Test-Path -LiteralPath $userConfigDirectory -PathType Container) {
            $userGlob = Get-ChildItem -Path $userConfigDirectory -Filter 'client_secret_*.json' -File -ErrorAction SilentlyContinue
            if ($userGlob) { $userCandidates += ($userGlob | Select-Object -ExpandProperty FullName) }
        }

        # 3. Check user Downloads and Desktop directories for downloaded Google Cloud client files
        $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        $downloadsCandidates = @()
        $dlDir = Join-Path $userHome 'Downloads'
        $dtDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
        foreach ($dir in @($dlDir, $dtDir)) {
            if (Test-Path -LiteralPath $dir -PathType Container) {
                $matches = Get-ChildItem -Path $dir -Filter 'client_secret*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
                if ($matches) { $downloadsCandidates += ($matches | Select-Object -ExpandProperty FullName) }
            }
        }

        $allCandidates = @()
        foreach ($c in $bundledCandidates) { $allCandidates += [ordered]@{ Path = $c; Source = 'BundledPublisher' } }
        foreach ($c in $userCandidates) { $allCandidates += [ordered]@{ Path = $c; Source = 'UserConfig' } }
        foreach ($c in $downloadsCandidates) { $allCandidates += [ordered]@{ Path = $c; Source = 'UserDownloaded' } }

        foreach ($item in $allCandidates) {
            $file = $item.Path
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                try {
                    $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                    $parsedId = $null
                    $parsedSecret = $null
                    if ($json.PSObject.Properties['installed'] -and $json.installed) {
                        if ($json.installed.PSObject.Properties['client_id'] -and $json.installed.client_id) {
                            $parsedId = [string]$json.installed.client_id
                        }
                        if ($json.installed.PSObject.Properties['client_secret'] -and $json.installed.client_secret) {
                            $parsedSecret = [string]$json.installed.client_secret
                        }
                    } elseif ($json.PSObject.Properties['web'] -and $json.web) {
                        if ($json.web.PSObject.Properties['client_id'] -and $json.web.client_id) {
                            $parsedId = [string]$json.web.client_id
                        }
                        if ($json.web.PSObject.Properties['client_secret'] -and $json.web.client_secret) {
                            $parsedSecret = [string]$json.web.client_secret
                        }
                    } elseif ($json.PSObject.Properties['client_id'] -and $json.client_id) {
                        $parsedId = [string]$json.client_id
                        if ($json.PSObject.Properties['client_secret'] -and $json.client_secret) {
                            $parsedSecret = [string]$json.client_secret
                        }
                    }

                    if ($parsedId -and $parsedId -notmatch 'YOUR_CLIENT_ID_HERE|YOUR_GOOGLE_CLIENT_ID') {
                        $clientId = $parsedId
                        $clientSecret = $parsedSecret
                        $foundPath = $file
                        $configSource = $item.Source
                        break
                    }
                } catch { }
            }
        }
    }

    $isConfigured = (-not [string]::IsNullOrEmpty($clientId))
    $defaultUserConfig = Join-Path $userConfigDirectory 'google-oauth.json'
    return [ordered]@{
        ClientId = $clientId
        ClientSecret = $clientSecret
        IsConfigured = $isConfigured
        ConfigSource = $configSource
        ConfigPath = if ($foundPath) { $foundPath } else { $defaultUserConfig }
        ConfigDirectory = $userConfigDirectory
        AppConfigDirectory = $appConfigDirectory
    }
}

function Import-GoogleOAuthConfigFile([string]$SourceFilePath) {
    if (-not (Test-Path -LiteralPath $SourceFilePath -PathType Leaf)) {
        throw "Source configuration file does not exist: $SourceFilePath"
    }
    $userConfigDirectory = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config'
    if (-not (Test-Path -LiteralPath $userConfigDirectory)) {
        New-Item -ItemType Directory -Path $userConfigDirectory -Force | Out-Null
    }
    $dest = Join-Path $userConfigDirectory 'google-oauth.json'
    Copy-Item -LiteralPath $SourceFilePath -Destination $dest -Force
    return Get-GoogleOAuthConfig
}

function Build-GoogleAuthorizationUrl(
    [string]$ClientId,
    [string]$RedirectUri,
    [string]$State,
    [string]$CodeChallenge = $null,
    [string]$Scope = $script:GoogleDefaultScope,
    [string]$Prompt = 'select_account consent'
) {
    if ([string]::IsNullOrEmpty($ClientId)) {
        throw 'Cannot build authorization URL without a valid Client ID.'
    }
    $escClient = [System.Uri]::EscapeDataString($ClientId)
    $escRedirect = [System.Uri]::EscapeDataString($RedirectUri)
    $escScope = [System.Uri]::EscapeDataString($Scope)
    $escState = [System.Uri]::EscapeDataString($State)
    $escPrompt = [System.Uri]::EscapeDataString($Prompt)

    $url = "$($script:GoogleAuthEndpoint)?client_id=$escClient&redirect_uri=$escRedirect&response_type=code&scope=$escScope&state=$escState&access_type=offline&prompt=$escPrompt"
    if (-not [string]::IsNullOrEmpty($CodeChallenge)) {
        $escChallenge = [System.Uri]::EscapeDataString($CodeChallenge)
        $url += "&code_challenge=$escChallenge&code_challenge_method=S256"
    }
    return $url
}

function Start-OAuthLoopbackListener([int]$Port = 53682, [int]$TimeoutSeconds = 120, [string]$ExpectedState) {
    $listener = [System.Net.HttpListener]::new()
    $prefix = "http://127.0.0.1:$Port/"
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    } catch {
        # If default port is occupied, try dynamic port
        $listener.Close()
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $tcpListener.Start()
        $Port = ($tcpListener.LocalEndpoint).Port
        $tcpListener.Stop()

        $listener = [System.Net.HttpListener]::new()
        $prefix = "http://127.0.0.1:$Port/"
        $listener.Prefixes.Add($prefix)
        $listener.Start()
    }

    return [ordered]@{
        Listener = $listener
        Port = $Port
        RedirectUri = $prefix
        ExpectedState = $ExpectedState
        TimeoutSeconds = $TimeoutSeconds
    }
}

function Wait-OAuthLoopbackResponse([hashtable]$ListenerContext, [scriptblock]$CancelCheck = $null) {
    $listener = $ListenerContext.Listener
    $expectedState = $ListenerContext.ExpectedState
    $timeoutSec = $ListenerContext.TimeoutSeconds

    try {
        $asyncResult = $listener.BeginGetContext($null, $null)
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false

        while (-not $asyncResult.IsCompleted) {
            if ($CancelCheck -and (& $CancelCheck)) {
                return [ordered]@{
                    Success = $false
                    Error = 'Authentication cancelled by user.'
                    Code = $null
                }
            }
            if ($stopwatch.Elapsed.TotalSeconds -ge $timeoutSec) {
                $timedOut = $true
                break
            }
            # Allow WPF UI dispatcher events to process so the window remains responsive
            if ([System.Windows.Threading.Dispatcher]::CurrentDispatcher) {
                $frame = [System.Windows.Threading.DispatcherFrame]::new()
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Background,
                    [Action]{ $frame.Continue = $false }
                ) | Out-Null
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
            }
            [System.Threading.Thread]::Sleep(50)
        }

        if ($timedOut) {
            return [ordered]@{
                Success = $false
                Error = "Authentication timed out after $timeoutSec seconds. Please try again."
                Code = $null
            }
        }

        $context = $listener.EndGetContext($asyncResult)
        $request = $context.Request
        $response = $context.Response

        $qs = $request.QueryString
        $code = $qs['code']
        $state = $qs['state']
        $error = $qs['error']

        # Render a branded local callback page without external resources.
        $brand = '<div class="brand"><svg viewBox="0 0 48 48" role="img" aria-label="NS Cloud Drive"><path d="M13 34h22a8 8 0 0 0 1-16 13 13 0 0 0-25-2 9 9 0 0 0 2 18Z" fill="none" stroke="#22c55e" stroke-width="4" stroke-linecap="round"/><path d="m18 25 6 6 10-11" fill="none" stroke="#22c55e" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/></svg><span>NS Cloud Drive</span></div>'
        $pageStart = "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>NS Cloud Drive</title><style>body{margin:0;background:#0b1020;color:#e5e7eb;font:16px Segoe UI,Arial,sans-serif;display:grid;min-height:100vh;place-items:center}.card{max-width:440px;margin:24px;padding:32px;border:1px solid #334155;border-radius:18px;background:#111827;text-align:center;box-shadow:0 18px 60px #0008}.brand{display:flex;align-items:center;justify-content:center;gap:10px;margin-bottom:24px;font-weight:600}.brand svg{width:42px;height:42px}.brand span{font-size:18px}h1{font-size:22px;margin:0 0 12px;color:#4ade80}p{line-height:1.6;color:#cbd5e1;margin:8px 0}</style></head><body><main class='card'>$brand"
        $html = ''
        if ($error) {
            $html = "$pageStart<h1>Authorization failed</h1><p>$([System.Net.WebUtility]::HtmlEncode($error))</p><p>You can close this tab and return to NS Cloud Drive.</p></main></body></html>"
        } elseif (-not $state -or $state -ne $expectedState) {
            $error = 'State parameter mismatch (possible CSRF or invalid request).'
            $html = "$pageStart<h1>Security validation failed</h1><p>State parameter did not match. Please restart sign-in from NS Cloud Drive.</p></main></body></html>"
        } elseif (-not $code) {
            $error = 'No authorization code received from Google.'
            $html = "$pageStart<h1>Authorization response incomplete</h1><p>No authorization code was received. Please restart sign-in from NS Cloud Drive.</p></main></body></html>"
        } else {
            $html = "$pageStart<h1>Authorization received</h1><p>Google returned a valid authorization response. Return to NS Cloud Drive to finish account verification.</p></main></body></html>"
        }

        $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
        $response.ContentLength64 = $buffer.Length
        $response.ContentType = 'text/html; charset=utf-8'
        $response.OutputStream.Write($buffer, 0, $buffer.Length)
        $response.OutputStream.Close()

        if ($error) {
            return [ordered]@{
                Success = $false
                Error = $error
                Code = $null
            }
        }

        return [ordered]@{
            Success = $true
            Error = $null
            Code = $code
        }
    } catch {
        return [ordered]@{
            Success = $false
            Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message)
            Code = $null
        }
    } finally {
        try {
            $listener.Stop()
            $listener.Close()
        } catch { }
    }
}

function Exchange-GoogleAuthCode(
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$Code,
    [string]$RedirectUri,
    [string]$CodeVerifier = $null,
    [string]$AccountId = ''
) {
    $body = @{
        client_id = $ClientId
        code = $Code
        grant_type = 'authorization_code'
        redirect_uri = $RedirectUri
    }
    if (-not [string]::IsNullOrEmpty($ClientSecret)) {
        $body['client_secret'] = $ClientSecret
    }
    if (-not [string]::IsNullOrEmpty($CodeVerifier)) {
        $body['code_verifier'] = $CodeVerifier
    }

    try {
        $tokenResponse = Invoke-RestMethod -Uri $script:GoogleTokenEndpoint -Method Post -Body $body -TimeoutSec 15 -ErrorAction Stop
        if ($tokenResponse -and $tokenResponse.access_token) {
            $tokenData = [ordered]@{
                access_token = $tokenResponse.access_token
                refresh_token = $tokenResponse.refresh_token
                token_type = $tokenResponse.token_type
                expires_in = $tokenResponse.expires_in
                scope = $tokenResponse.scope
                obtained_at = [DateTime]::UtcNow.ToString('o')
            }
            Save-GoogleDriveTokens -TokenData $tokenData -AccountId $AccountId
            return [ordered]@{
                Success = $true
                Tokens = $tokenData
                Error = $null
            }
        }
        return [ordered]@{
            Success = $false
            Tokens = $null
            Error = 'No access token in token exchange response.'
        }
    } catch {
        return [ordered]@{
            Success = $false
            Tokens = $null
            Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message)
        }
    }
}

function Find-GoogleRcloneBinary {
    if (Get-Command 'Find-RcloneBinary' -ErrorAction SilentlyContinue) {
        $found = Find-RcloneBinary
        if ($found) { return $found }
    }
    $localTool = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe'
    if (Test-Path -LiteralPath $localTool) { return $localTool }
    $onPath = Get-Command 'rclone.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

function Invoke-GoogleRcloneAuthorize([string]$AccountId = '', [int]$TimeoutSeconds = 120) {
    $rclone = Find-GoogleRcloneBinary
    if (-not $rclone) {
        return [ordered]@{
            Success = $false
            Error = 'rclone.exe was not found to execute Google Drive authorization.'
            Tokens = $null
        }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclone
    $psi.Arguments = 'authorize "drive"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            try { $proc.Kill() } catch { }
            try { $proc.Dispose() } catch { }
            return [ordered]@{
                Success = $false
                Error = "Google Drive authorization timed out after $TimeoutSeconds seconds."
                Tokens = $null
            }
        }
        [System.Threading.Thread]::Sleep(250)
    }

    $outText = $stdoutTask.Result
    $errText = $stderrTask.Result

    # Extract JSON between "Paste the following into your remote machine --->" and "<---End paste" or find {"access_token"
    $match = [regex]::Match($outText, '\{[\s\S]*"access_token"[\s\S]*\}')
    if (-not $match.Success) {
        $match = [regex]::Match($errText, '\{[\s\S]*"access_token"[\s\S]*\}')
    }

    if ($match.Success) {
        try {
            $tokenObj = $match.Value | ConvertFrom-Json
            $tokenData = [ordered]@{
                access_token = [string]$tokenObj.access_token
                refresh_token = if ($tokenObj.PSObject.Properties['refresh_token'] -and $tokenObj.refresh_token) { [string]$tokenObj.refresh_token } else { $null }
                token_type = if ($tokenObj.PSObject.Properties['token_type'] -and $tokenObj.token_type) { [string]$tokenObj.token_type } else { 'Bearer' }
                expires_in = if ($tokenObj.PSObject.Properties['expiry'] -and $tokenObj.expiry) {
                    try {
                        [int]([DateTime]::Parse($tokenObj.expiry).ToUniversalTime() - [DateTime]::UtcNow).TotalSeconds
                    } catch { 3600 }
                } else { 3600 }
                scope = 'https://www.googleapis.com/auth/drive'
                obtained_at = [DateTime]::UtcNow.ToString('o')
            }

            Save-GoogleDriveTokens -TokenData $tokenData -AccountId $AccountId
            return [ordered]@{
                Success = $true
                Tokens = $tokenData
                Error = $null
            }
        } catch {
            return [ordered]@{
                Success = $false
                Tokens = $null
                Error = "Failed to parse token payload: $($_.Exception.Message)"
            }
        }
    }

    return [ordered]@{
        Success = $false
        Tokens = $null
        Error = "Google Drive authorization cancelled or failed to produce tokens: $errText"
    }
}

function Start-GoogleOAuthFlow(
    [string]$ClientId,
    [string]$ClientSecret = $null,
    [string]$AccountId = '',
    [int]$TimeoutSeconds = 120,
    [scriptblock]$CancelCheck = $null
) {
    $state = New-OAuthState
    $verifier = New-PkceVerifier
    $challenge = New-PkceChallenge -Verifier $verifier
    $listenerCtx = Start-OAuthLoopbackListener -ExpectedState $state -TimeoutSeconds $TimeoutSeconds
    $authUrl = Build-GoogleAuthorizationUrl -ClientId $ClientId -RedirectUri $listenerCtx.RedirectUri -State $state -CodeChallenge $challenge -Scope 'https://www.googleapis.com/auth/drive'

    [System.Diagnostics.Process]::Start($authUrl) | Out-Null
    $loopbackRes = Wait-OAuthLoopbackResponse -ListenerContext $listenerCtx -CancelCheck $CancelCheck

    if (-not $loopbackRes.Success) {
        return [ordered]@{
            Success = $false
            Tokens = $null
            Error = $loopbackRes.Error
        }
    }

    $tokenRes = Exchange-GoogleAuthCode -ClientId $ClientId -ClientSecret $ClientSecret -Code $loopbackRes.Code -RedirectUri $listenerCtx.RedirectUri -CodeVerifier $verifier -AccountId $AccountId
    return $tokenRes
}

function Invoke-GoogleDriveAuthorization(
    [string]$AccountId = '',
    [int]$TimeoutSeconds = 120,
    [scriptblock]$CancelCheck = $null
) {
    $oauthConfig = Get-GoogleOAuthConfig
    if ($oauthConfig.IsConfigured -and $oauthConfig.ClientId) {
        return (Start-GoogleOAuthFlow -ClientId $oauthConfig.ClientId -ClientSecret $oauthConfig.ClientSecret -AccountId $AccountId -TimeoutSeconds $TimeoutSeconds -CancelCheck $CancelCheck)
    }

    $rclonePath = Find-GoogleRcloneBinary
    if ($rclonePath) {
        return (Invoke-GoogleRcloneAuthorize -AccountId $AccountId -TimeoutSeconds $TimeoutSeconds)
    }

    return [ordered]@{
        Success = $false
        Tokens = $null
        Error = "Google Drive authorization requires a configured OAuth Client ID or rclone binary. Set GOOGLE_CLIENT_ID or configure client_secret.json in %LOCALAPPDATA%\NSCloudDrive\config."
    }
}

function Refresh-GoogleAccessToken([string]$ClientId, [string]$ClientSecret, [string]$RefreshToken, [string]$AccountId = '') {
    $body = @{
        client_id = $ClientId
        refresh_token = $RefreshToken
        grant_type = 'refresh_token'
    }
    if (-not [string]::IsNullOrEmpty($ClientSecret)) {
        $body['client_secret'] = $ClientSecret
    }

    try {
        $response = Invoke-RestMethod -Uri $script:GoogleTokenEndpoint -Method Post -Body $body -TimeoutSec 15 -ErrorAction Stop
        if ($response -and $response.access_token) {
            $currentTokens = Get-GoogleDriveStoredTokens -AccountId $AccountId
            $tokenData = [ordered]@{
                access_token = $response.access_token
                refresh_token = $(if ($response.refresh_token) { $response.refresh_token } else { $RefreshToken })
                token_type = $response.token_type
                expires_in = $response.expires_in
                scope = $(if ($response.scope) { $response.scope } else { $currentTokens.scope })
                obtained_at = [DateTime]::UtcNow.ToString('o')
            }
            Save-GoogleDriveTokens -TokenData $tokenData -AccountId $AccountId
            return [ordered]@{
                Success = $true
                Tokens = $tokenData
                Error = $null
            }
        }
        return [ordered]@{
            Success = $false
            Tokens = $null
            Error = 'Refresh token response contained no access token.'
        }
    } catch {
        return [ordered]@{
            Success = $false
            Tokens = $null
            Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message)
        }
    }
}

function Get-GoogleApiErrorDetails($Exception) {
    $code = $null
    $message = $null
    $reason = $null
    $status = $null
    $actionableError = $null

    try {
        $webEx = $null
        if ($Exception -is [System.Net.WebException]) {
            $webEx = $Exception
        } elseif ($Exception.PSObject.Properties['Exception'] -and ($Exception.Exception -is [System.Net.WebException])) {
            $webEx = $Exception.Exception
        } elseif ($Exception.PSObject.Properties['InnerException'] -and ($Exception.InnerException -is [System.Net.WebException])) {
            $webEx = $Exception.InnerException
        }

        if ($webEx -and $webEx.Response) {
            $respStream = $webEx.Response.GetResponseStream()
            if ($respStream) {
                $reader = [System.IO.StreamReader]::new($respStream)
                $rawBody = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($rawBody)) {
                    $json = $rawBody | ConvertFrom-Json
                    if ($json -and $json.PSObject.Properties['error']) {
                        $err = $json.error
                        $code = if ($err.PSObject.Properties['code']) { [int]$err.code } else { $null }
                        $message = if ($err.PSObject.Properties['message']) { [string]$err.message } else { $null }
                        $status = if ($err.PSObject.Properties['status']) { [string]$err.status } else { $null }
                        if ($err.PSObject.Properties['errors'] -and $err.errors.Count -gt 0) {
                            $first = $err.errors[0]
                            if ($first.PSObject.Properties['reason']) {
                                $reason = [string]$first.reason
                            }
                        }
                    }
                }
            }
        }
    } catch { }

    if ($reason -match 'rateLimitExceeded|userRateLimitExceeded') {
        $actionableError = "Google Drive API rate limit reached on shared rclone client ID (project 202264815644). Limit resets automatically in a few seconds."
    } elseif ($reason -match 'accessNotConfigured') {
        $actionableError = "Google Drive API is disabled or not configured in your Google Cloud Project. Please enable it in Google Cloud Console (APIs & Services > Library > Google Drive API)."
    } elseif ($reason -match 'insufficientPermissions|insufficientFilePermissions') {
        $actionableError = "Insufficient Google Drive permissions. Reconnect your account and grant drive access permissions on the consent screen."
    } elseif ($reason -match 'appNotVerified|access_denied') {
        $actionableError = "Google blocked access because this OAuth client is unverified. Add your Google account as a Test User in the Google Cloud Console OAuth consent screen."
    } elseif ($message) {
        $actionableError = (Format-SanitizedDiagnosticMessage $message)
    } elseif ($Exception) {
        $exMsg = if ($Exception -is [string]) {
            $Exception
        } elseif ($Exception.PSObject.Properties['Exception'] -and $Exception.Exception -and $Exception.Exception.PSObject.Properties['Message']) {
            [string]$Exception.Exception.Message
        } elseif ($Exception.PSObject.Properties['Message']) {
            [string]$Exception.Message
        } else {
            [string]$Exception
        }
        $actionableError = (Format-SanitizedDiagnosticMessage $exMsg)
    } else {
        $actionableError = 'Unknown Google Drive API error.'
    }

    return [ordered]@{
        Code = $code
        Message = $message
        Reason = $reason
        Status = $status
        ActionableError = $actionableError
    }
}

function Invoke-GoogleDriveApiWithRetry(
    [scriptblock]$ApiAction,
    [hashtable]$TokensOverride = $null,
    [string]$AccountId = '',
    [int]$MaxRateLimitRetries = 3
) {
    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens -AccountId $AccountId }
    if (-not $tokens -or -not $tokens.access_token) {
        throw 'No Google Drive tokens available.'
    }

    $retries = 0
    $delaySeconds = 1.5

    while ($true) {
        try {
            return (& $ApiAction $tokens.access_token)
        } catch {
            $errDetails = Get-GoogleApiErrorDetails $_
            $sanitized = Format-SanitizedDiagnosticMessage $_.Exception.Message
            $isAuthError = ($sanitized -match '401' -or $sanitized -match 'Invalid Credentials' -or $errDetails.Code -eq 401)
            $isRateLimit = ($errDetails.Reason -match 'rateLimitExceeded|userRateLimitExceeded' -or $sanitized -match 'rateLimitExceeded' -or $sanitized -match '429')

            if ($isAuthError -and (-not $TokensOverride) -and $tokens.refresh_token) {
                # Attempt automatic token refresh
                $oauthConfig = Get-GoogleOAuthConfig
                if ($oauthConfig -and $oauthConfig.ClientId) {
                    $refreshResult = Refresh-GoogleAccessToken -ClientId $oauthConfig.ClientId -ClientSecret $oauthConfig.ClientSecret -RefreshToken $tokens.refresh_token -AccountId $AccountId
                    if ($refreshResult.Success -and $refreshResult.Tokens -and $refreshResult.Tokens.access_token) {
                        # Retry once with newly refreshed access token
                        return (& $ApiAction $refreshResult.Tokens.access_token)
                    }
                }
            }

            if ($isRateLimit -and ($retries -lt $MaxRateLimitRetries)) {
                $retries++
                [System.Threading.Thread]::Sleep([int]($delaySeconds * 1000))
                $delaySeconds = $delaySeconds * 2
                continue
            }

            throw
        }
    }
}

function Invoke-GoogleRcloneCommand(
    [string]$FilePath,
    [string]$Arguments,
    [hashtable]$EnvironmentVariables = @{},
    [int]$TimeoutSeconds = 10
) {
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        throw 'Google Drive helper executable path is missing.'
    }
    if ($TimeoutSeconds -lt 1) { $TimeoutSeconds = 1 }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($key in $EnvironmentVariables.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$EnvironmentVariables[$key]
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) {
            throw 'Google Drive helper process failed to start.'
        }

        # Drain both redirected streams asynchronously before waiting on the child.
        # Synchronous ReadToEnd() here can wait forever and makes a later WaitForExit
        # timeout ineffective when rclone stalls or fills either pipe.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { }
            [void]$proc.WaitForExit(2000)
            throw "Google Drive helper timed out after $TimeoutSeconds seconds."
        }

        # Ensure asynchronous stream readers have observed EOF after process exit.
        [void]$proc.WaitForExit()
        return [ordered]@{
            ExitCode = [int]$proc.ExitCode
            StandardOutput = $stdoutTask.GetAwaiter().GetResult()
            StandardError = $stderrTask.GetAwaiter().GetResult()
        }
    } finally {
        $proc.Dispose()
    }
}

$script:GoogleDriveSessionCache = @{}

function Test-GoogleDriveBackendSession([hashtable]$TokensOverride = $null, [string]$AccountId = '', [switch]$Force = $false) {
    $cacheKey = if (-not [string]::IsNullOrEmpty($AccountId)) { $AccountId } else { 'default' }
    if ((-not $Force) -and (-not $TokensOverride) -and $script:GoogleDriveSessionCache.ContainsKey($cacheKey)) {
        $cached = $script:GoogleDriveSessionCache[$cacheKey]
        if ($cached -and $cached.CheckedAt -and (([DateTime]::UtcNow - $cached.CheckedAt).TotalSeconds -lt 120)) {
            return $cached.Result
        }
    }

    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens -AccountId $AccountId }
    if (-not $tokens -or -not $tokens.access_token) {
        $res = [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            Error = 'No Google Drive tokens found. Please connect your account.'
            IdentityVerified = $false
            IdentitySource = ''
            IdentityError = $null
            UserInfo = $null
        }
        $script:GoogleDriveSessionCache[$cacheKey] = [ordered]@{ CheckedAt = [DateTime]::UtcNow; Result = $res }
        return $res
    }

    # Step 1: Validate token and retrieve user identity via root file metadata
    $userDisplayName = $null
    $userEmail = $null
    $quotaUsed = [int64]0
    $quotaTotal = [int64]0
    $hasQuotaInfo = $false
    # Sanitized, secret-free diagnostics for the identity lookup. Populated
    # from real API failures so the UI can show the exact reason (HTTP status,
    # Google error reason, safe response details) instead of a vague
    # "identity could not be verified" rejection. Never contains tokens.
    $identityDiagnostics = [System.Collections.Generic.List[string]]::new()
    $identitySource = ''

    # Fast-path: check if access token is expired based on obtained_at and expires_in
    $isTokenExpired = $false
    if ($tokens.obtained_at -and $tokens.expires_in) {
        try {
            $obtained = [DateTime]::Parse($tokens.obtained_at).ToUniversalTime()
            $expSec = [double]$tokens.expires_in
            if (([DateTime]::UtcNow - $obtained).TotalSeconds -ge ($expSec - 60)) {
                $isTokenExpired = $true
            }
        } catch { }
    }

    $hasCustomClient = $false
    try {
        $oCfg = Get-GoogleOAuthConfig
        if ($oCfg -and $oCfg.ClientId) { $hasCustomClient = $true }
    } catch { }

    # Only attempt direct files/root HTTP query if token is not expired or custom client is configured
    if (-not $isTokenExpired -or $hasCustomClient) {
        try {
            $rootResp = Invoke-GoogleDriveApiWithRetry -TokensOverride $TokensOverride -AccountId $AccountId -ApiAction {
                param([string]$accessToken)
                $headers = @{
                    'Authorization' = "Bearer $accessToken"
                    'Accept' = 'application/json'
                }
                $rootUrl = "$script:GoogleDriveApiEndpoint/files/root?fields=id,name,owners"
                return (Invoke-RestMethod -Uri $rootUrl -Headers $headers -Method Get -TimeoutSec 10 -ErrorAction Stop)
            }

            if ($rootResp -and $rootResp.PSObject.Properties['owners'] -and $rootResp.owners.Count -gt 0) {
                $userDisplayName = [string]$rootResp.owners[0].displayName
                $userEmail = [string]$rootResp.owners[0].emailAddress
                if ($userDisplayName -or $userEmail) { $identitySource = 'drive-api' }
            }
        } catch {
            try {
                $apiDiag = Get-GoogleApiErrorDetails $_
                if ($apiDiag -and $apiDiag.ActionableError) { $identityDiagnostics.Add([string]$apiDiag.ActionableError) }
                elseif ($_) { $identityDiagnostics.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
            } catch { }
        }
    }

    if (-not $userDisplayName -and -not $userEmail -and (-not $isTokenExpired -or $hasCustomClient)) {
        try {
            $aboutResp = Invoke-GoogleDriveApiWithRetry -TokensOverride $TokensOverride -AccountId $AccountId -ApiAction {
                param([string]$accessToken)
                $headers = @{ 'Authorization' = "Bearer $accessToken"; 'Accept' = 'application/json' }
                $aboutUrl = "$script:GoogleDriveApiEndpoint/about?fields=user(displayName,emailAddress,permissionId),storageQuota"
                return (Invoke-RestMethod -Uri $aboutUrl -Headers $headers -Method Get -TimeoutSec 10 -ErrorAction Stop)
            }
            if ($aboutResp -and $aboutResp.user) {
                $userDisplayName = [string]$aboutResp.user.displayName
                $userEmail = [string]$aboutResp.user.emailAddress
                if ($aboutResp.storageQuota) {
                    if ($aboutResp.storageQuota.limit) { $quotaTotal = [int64]$aboutResp.storageQuota.limit }
                    $hasQuotaInfo = $true
                    if ($aboutResp.storageQuota.usage) { $quotaUsed = [int64]$aboutResp.storageQuota.usage }
                }
                if ($userDisplayName -or $userEmail) { $identitySource = 'drive-api' }
            }
        } catch {
            try {
                $apiDiag = Get-GoogleApiErrorDetails $_
                if ($apiDiag -and $apiDiag.ActionableError) { $identityDiagnostics.Add([string]$apiDiag.ActionableError) }
                elseif ($_) { $identityDiagnostics.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
            } catch { }
        }
    }

    $SetCacheAndReturn = {
        param($val)
        $script:GoogleDriveSessionCache[$cacheKey] = [ordered]@{ CheckedAt = [DateTime]::UtcNow; Result = $val }
        return $val
    }

    if (-not $userDisplayName -and -not $userEmail) {
        # Check if rclone can validate the session and refresh if expired on shared rclone credentials
        $rclone = Find-GoogleRcloneBinary
        if ($rclone -and $tokens.refresh_token) {
            try {
                $remoteName = if (-not [string]::IsNullOrEmpty($AccountId)) { $AccountId } else { 'gdrive' }
                $safeRemote = [regex]::Replace($remoteName, '[^a-zA-Z0-9_\-]', '_')
                $envVars = Get-GoogleDriveRcloneEnvironment -AccountId $AccountId -RemoteName $safeRemote
                # Identity lookups may need a token refresh under the shared rclone
                # client, which can take 30-35 seconds under rate limits. A 4-second
                # cutoff made this check look failed even when the session was fine.
                $result = Invoke-GoogleRcloneCommand -FilePath $rclone -Arguments "about --json ${safeRemote}:" -EnvironmentVariables $envVars -TimeoutSeconds 20
                if ($result.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($result.StandardOutput))) {
                    $aboutObj = $result.StandardOutput | ConvertFrom-Json
                    $quotaTotal = if ($aboutObj.total) { [int64]$aboutObj.total } else { 0L }
                    $quotaUsed = if ($aboutObj.used) { [int64]$aboutObj.used } else { 0L }

                    # Retrieve account metadata from the saved account record
                    # when available; only a brand-new (unsaved) account keeps
                    # the generic placeholder - which creation-time callers
                    # then refuse to treat as a verified identity.
                    $acc = if (-not [string]::IsNullOrEmpty($AccountId) -and (Get-Command 'Get-CloudAccount' -ErrorAction SilentlyContinue)) {
                        Get-CloudAccount -AccountId $AccountId
                    } else { $null }
                    $fallbackName = if ($acc -and $acc.DisplayName) { [string]$acc.DisplayName } else { 'Google Drive User' }
                    $fallbackEmail = if ($acc -and $acc.AccountEmail) { [string]$acc.AccountEmail } elseif ($acc -and $acc.Username -and $acc.Username -match '@') { [string]$acc.Username } else { '' }

                    return (& $SetCacheAndReturn ([ordered]@{
                        IsValid = $true
                        State = 'Connected'
                        Error = $null
                        # This identity came from stored metadata, not from a live
                        # Google API response. For a brand-new (unsaved) account it
                        # is only the generic placeholder, so callers that need a
                        # verified identity (account creation) must not accept it.
                        IdentityVerified = $false
                        IdentitySource = 'rclone-metadata'
                        IdentityError = $(if ($identityDiagnostics.Count -gt 0) { [string]::Join(' ', $identityDiagnostics) } else { $null })
                        UserInfo = [ordered]@{
                            DisplayName = $fallbackName
                            EmailAddress = $fallbackEmail
                            QuotaUsed = $quotaUsed
                            QuotaTotal = $quotaTotal
                        }
                    }))
                }
            } catch { }
        }

        # If we have a refresh token and rclone binary, session is valid via rclone token auto-renewal
        if ($tokens.refresh_token -and $rclone) {
            $acc = if (-not [string]::IsNullOrEmpty($AccountId) -and (Get-Command 'Get-CloudAccount' -ErrorAction SilentlyContinue)) {
                Get-CloudAccount -AccountId $AccountId
            } else { $null }
            $fallbackName = if ($acc -and $acc.DisplayName) { [string]$acc.DisplayName } else { 'Google Drive User' }
            $fallbackEmail = if ($acc -and $acc.AccountEmail) { [string]$acc.AccountEmail } else { '' }

            return (& $SetCacheAndReturn ([ordered]@{
                IsValid = $true
                State = 'Connected'
                Error = $null
                # Token-only validation: no live identity was returned by Google.
                IdentityVerified = $false
                IdentitySource = 'stored-token'
                IdentityError = $(if ($identityDiagnostics.Count -gt 0) { [string]::Join(' ', $identityDiagnostics) } else { $null })
                UserInfo = [ordered]@{
                    DisplayName = $fallbackName
                    EmailAddress = $fallbackEmail
                    QuotaUsed = 0L
                    QuotaTotal = 0L
                }
            }))
        }

        return (& $SetCacheAndReturn ([ordered]@{
            IsValid = $false
            State = 'AuthenticationExpired'
            Error = 'Google Drive access token has expired or was revoked. Please reconnect your account.'
            IdentityVerified = $false
            IdentitySource = ''
            IdentityError = $(if ($identityDiagnostics.Count -gt 0) { [string]::Join(' ', $identityDiagnostics) } else { $null })
            UserInfo = $null
        }))
    }

    # Step 2: Retrieve storage quota (via /about or rclone fallback)
    if (-not $hasQuotaInfo) {
    $quotaUsed = [int64]0
    $quotaTotal = [int64]0

    try {
        $aboutResp = Invoke-GoogleDriveApiWithRetry -TokensOverride $TokensOverride -AccountId $AccountId -MaxRateLimitRetries 1 -ApiAction {
            param([string]$accessToken)
            $headers = @{
                'Authorization' = "Bearer $accessToken"
                'Accept' = 'application/json'
            }
            $aboutUrl = "$script:GoogleDriveApiEndpoint/about?fields=storageQuota"
            return (Invoke-RestMethod -Uri $aboutUrl -Headers $headers -Method Get -TimeoutSec 10 -ErrorAction Stop)
        }
        if ($aboutResp -and $aboutResp.PSObject.Properties['storageQuota'] -and $aboutResp.storageQuota) {
            if ($aboutResp.storageQuota.PSObject.Properties['usage']) {
                $quotaUsed = [int64]$aboutResp.storageQuota.usage
            }
            if ($aboutResp.storageQuota.PSObject.Properties['limit']) {
                $quotaTotal = [int64]$aboutResp.storageQuota.limit
            }
        }
    } catch {
        # If /about is rate limited on shared client ID, fall back to rclone about --json if rclone is available
        try {
            $rclone = Find-GoogleRcloneBinary
            if ($rclone) {
                $remoteName = if (-not [string]::IsNullOrEmpty($AccountId)) { $AccountId } else { 'gdrive' }
                $safeRemote = [regex]::Replace($remoteName, '[^a-zA-Z0-9_\-]', '_')
                $envVars = Get-GoogleDriveRcloneEnvironment -AccountId $AccountId -RemoteName $safeRemote
                $result = Invoke-GoogleRcloneCommand -FilePath $rclone -Arguments "about --json ${safeRemote}:" -EnvironmentVariables $envVars -TimeoutSeconds 4
                if ($result.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($result.StandardOutput))) {
                    $json = $result.StandardOutput | ConvertFrom-Json
                    if ($json.PSObject.Properties['used']) { $quotaUsed = [int64]$json.used }
                    if ($json.PSObject.Properties['total']) { $quotaTotal = [int64]$json.total }
                }
            }
        } catch { }
    }

    }

    # Account-scoped connection identity cross-check: when this check is bound
    # to a saved account, the identity Google just verified must BELONG to
    # that account. A mismatch means the credential store produced a
    # different account's tokens (e.g. the saved file was replaced or an old
    # connection's material leaked in); reporting a sign-in requirement here
    # is what prevents mounting another user's Drive under this account's
    # letter. Compared only when BOTH values look like actual email
    # addresses, so display-label edits can never trigger a false positive.
    if (-not [string]::IsNullOrEmpty($AccountId) -and $userEmail -match '@') {
        try {
            $savedAccount = if (Get-Command 'Get-CloudAccount' -ErrorAction SilentlyContinue) { Get-CloudAccount -AccountId $AccountId } else { $null }
            $savedEmail = if ($savedAccount -and $savedAccount.AccountEmail) { [string]$savedAccount.AccountEmail } else { '' }
            if ($savedEmail -match '@' -and -not [string]::Equals($savedEmail, $userEmail, [System.StringComparison]::OrdinalIgnoreCase)) {
                return (& $SetCacheAndReturn ([ordered]@{
                    IsValid = $false
                    State = 'AuthRequired'
                    Error = "The authorized Google account ($userEmail) does not match this saved account ($savedEmail). Disconnect and reconnect this account's sign-in from its card."
                    IdentityVerified = $false
                    IdentitySource = $(if ($identitySource) { $identitySource } else { 'drive-api' })
                    IdentityError = 'The signing-in Google identity does not belong to this saved account.'
                    UserInfo = [ordered]@{
                        DisplayName = $userDisplayName
                        EmailAddress = $userEmail
                        QuotaUsed = $quotaUsed
                        QuotaTotal = $quotaTotal
                    }
                }))
            }
        } catch { }
    }

    return (& $SetCacheAndReturn ([ordered]@{
        IsValid = $true
        State = 'Connected'
        Error = $null
        IdentityVerified = $true
        IdentitySource = $(if ($identitySource) { $identitySource } else { 'drive-api' })
        IdentityError = $null
        UserInfo = [ordered]@{
            DisplayName = if ($userDisplayName) { $userDisplayName } else { 'Google Drive User' }
            EmailAddress = if ($userEmail) { $userEmail } else { '' }
            QuotaUsed = $quotaUsed
            QuotaTotal = $quotaTotal
        }
    }))
}

# Summarizes the best available sanitized reason for a failed Google identity
# lookup so the UI can show the exact failure (HTTP status, Google error
# reason, safe response details) instead of a generic rejection. Returns ''
# when nothing was captured. Never contains tokens or authorization codes.
function Get-GoogleIdentityFailureReason($Verify) {
    if ($null -eq $Verify) { return '' }
    try {
        $primary = Get-SafeProperty $Verify 'Error' ''
        if ($primary) { return (Format-SanitizedDiagnosticMessage ([string]$primary)) }
        $secondary = Get-SafeProperty $Verify 'IdentityError' ''
        if ($secondary) { return (Format-SanitizedDiagnosticMessage ([string]$secondary)) }
    } catch { }
    return ''
}

function Get-GoogleDriveFileList([int]$PageSize = 25, [hashtable]$TokensOverride = $null, [string]$AccountId = '') {
    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens -AccountId $AccountId }
    if (-not $tokens -or -not $tokens.access_token) {
        return [ordered]@{
            Success = $false
            ItemCount = 0
            Files = @()
            Error = 'Not connected to Google Drive.'
        }
    }

    try {
        $response = Invoke-GoogleDriveApiWithRetry -TokensOverride $TokensOverride -AccountId $AccountId -ApiAction {
            param([string]$accessToken)
            $headers = @{
                'Authorization' = "Bearer $accessToken"
                'Accept' = 'application/json'
            }
            $filesUrl = "$script:GoogleDriveApiEndpoint/files?pageSize=$PageSize&fields=files(id,name,mimeType,size,modifiedTime)&q=trashed=false"
            return (Invoke-RestMethod -Uri $filesUrl -Headers $headers -Method Get -TimeoutSec 15 -ErrorAction Stop)
        }

        $items = @()
        if ($response -and $response.PSObject.Properties['files'] -and $response.files) {
            foreach ($f in $response.files) {
                $isFolder = ($f.PSObject.Properties['mimeType'] -and $f.mimeType -eq 'application/vnd.google-apps.folder')
                $items += [pscustomobject]@{
                    Id = if ($f.PSObject.Properties['id']) { $f.id } else { '' }
                    Name = if ($f.PSObject.Properties['name']) { $f.name } else { '' }
                    IsDirectory = $isFolder
                    Size = $(if ($f.PSObject.Properties['size'] -and $f.size) { [int64]$f.size } else { 0 })
                    ModTime = if ($f.PSObject.Properties['modifiedTime']) { $f.modifiedTime } else { $null }
                }
            }
        }

        return [ordered]@{
            Success = $true
            ItemCount = $items.Count
            Files = $items
            Error = $null
        }
    } catch {
        # Fallback to rclone lsjson if direct REST API is expired on shared client credentials
        $rclone = Find-GoogleRcloneBinary
        if ($rclone -and $tokens.refresh_token) {
            try {
                $remoteName = if (-not [string]::IsNullOrEmpty($AccountId)) { $AccountId } else { 'gdrive' }
                $envVars = Get-GoogleDriveRcloneEnvironment -AccountId $AccountId -RemoteName $remoteName
                $result = Invoke-GoogleRcloneCommand -FilePath $rclone -Arguments "lsjson --max-depth 1 ${remoteName}:" -EnvironmentVariables $envVars -TimeoutSeconds 10
                if ($result.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($result.StandardOutput))) {
                    $rawItems = $result.StandardOutput | ConvertFrom-Json
                    $items = @()
                    foreach ($it in $rawItems) {
                        $items += [pscustomobject]@{
                            Id = if ($it.ID) { $it.ID } else { '' }
                            Name = if ($it.Name) { $it.Name } else { '' }
                            IsDirectory = ($it.IsDir -eq $true)
                            Size = $(if ($it.Size -and $it.Size -gt 0) { [int64]$it.Size } else { 0L })
                            ModTime = if ($it.ModTime) { $it.ModTime } else { $null }
                        }
                        if ($items.Count -ge $PageSize) { break }
                    }
                    return [ordered]@{
                        Success = $true
                        ItemCount = $items.Count
                        Files = $items
                        Error = $null
                    }
                }
            } catch { }
        }

        $errDetails = Get-GoogleApiErrorDetails $_
        return [ordered]@{
            Success = $false
            ItemCount = 0
            Files = @()
            Error = "Failed to list Google Drive files: $($errDetails.ActionableError)"
        }
    }
}

function Get-GoogleDriveRcloneEnvironment(
    [string]$AccountId = '',
    [string]$RemoteName = 'gdrive',
    [string]$Scope = 'drive'
) {
    # 1. Proactive sync from rclone config first!
    $synced = Sync-GoogleDriveTokensFromRcloneConfig -AccountId $AccountId -RemoteName $RemoteName
    $tokens = if ($synced) { $synced } else { Get-GoogleDriveStoredTokens -AccountId $AccountId }
    $oauthConfig = Get-GoogleOAuthConfig
    if (-not $tokens -or -not $tokens.access_token) {
        throw 'No Google Drive tokens available to configure rclone environment.'
    }

    # --- Token validity evaluation ---
    $hasObtainedAt = ($tokens.PSObject.Properties['obtained_at'] -and $tokens.obtained_at)
    $hasExpiresIn  = ($tokens.PSObject.Properties['expires_in']  -and $tokens.expires_in)
    $hasRefresh    = ($tokens.PSObject.Properties['refresh_token'] -and -not [string]::IsNullOrEmpty($tokens.refresh_token))

    $tokenIsExpiredOrSoon = $false
    if ($tokens.PSObject.Properties['expiry'] -and -not [string]::IsNullOrWhiteSpace($tokens.expiry)) {
        try {
            $expUtc = [DateTime]::Parse($tokens.expiry).ToUniversalTime()
            if ([DateTime]::UtcNow.AddSeconds(60) -ge $expUtc) {
                $tokenIsExpiredOrSoon = $true
            }
        } catch {
            $tokenIsExpiredOrSoon = $true
        }
    } elseif ($hasObtainedAt -and $hasExpiresIn) {
        try {
            $obtainedCheck = [DateTime]::Parse($tokens.obtained_at).ToUniversalTime()
            $expSecCheck   = [int]$tokens.expires_in
            if (([DateTime]::UtcNow - $obtainedCheck).TotalSeconds -ge ($expSecCheck - 60)) {
                $tokenIsExpiredOrSoon = $true
            }
        } catch {
            $tokenIsExpiredOrSoon = $true
        }
    } else {
        $tokenIsExpiredOrSoon = $true
    }

    if ($tokenIsExpiredOrSoon -and $hasRefresh) {
        if ($oauthConfig.ClientId) {
            try {
                $refreshResult = Refresh-GoogleAccessToken `
                    -ClientId     $oauthConfig.ClientId `
                    -ClientSecret $oauthConfig.ClientSecret `
                    -RefreshToken $tokens.refresh_token `
                    -AccountId    $AccountId
                if ($refreshResult.Success -and $refreshResult.Tokens -and $refreshResult.Tokens.access_token) {
                    $tokens = $refreshResult.Tokens
                    $tokenIsExpiredOrSoon = $false
                }
            } catch { }
        } else {
            # Shared rclone client ID: perform single bounded pre-refresh using rclone about
            $rclone = Find-GoogleRcloneBinary
            if ($rclone -and $tokens.refresh_token -and $tokens.refresh_token.StartsWith('1//')) {
                try {
                    $preRefreshRemote = if (-not [string]::IsNullOrEmpty($RemoteName)) { $RemoteName } else { 'gdrive' }
                    $safeRemote = [regex]::Replace($preRefreshRemote, '[^a-zA-Z0-9_\-]', '_')
                    $tempUpper = $safeRemote.ToUpperInvariant()
                    $tempTokenObj = [ordered]@{
                        access_token  = $tokens.access_token
                        token_type    = if ($tokens.PSObject.Properties['token_type'] -and $tokens.token_type) { $tokens.token_type } else { 'Bearer' }
                        refresh_token = $tokens.refresh_token
                        expiry        = '2000-01-01T00:00:00Z'
                    }
                    $tempEnv = @{
                        "RCLONE_CONFIG_${tempUpper}_TYPE"  = 'drive'
                        "RCLONE_CONFIG_${tempUpper}_SCOPE" = $Scope
                        "RCLONE_CONFIG_${tempUpper}_TOKEN" = ($tempTokenObj | ConvertTo-Json -Compress)
                    }
                    $aboutResult = Invoke-GoogleRcloneCommand -FilePath $rclone -Arguments "about --json ${safeRemote}:" -EnvironmentVariables $tempEnv -TimeoutSeconds 35
                    $refreshedSync = Sync-GoogleDriveTokensFromRcloneConfig -AccountId $AccountId -RemoteName $RemoteName
                    if ($refreshedSync) {
                        $tokens = $refreshedSync
                        $tokenIsExpiredOrSoon = $false
                    }
                } catch { }
            }
        }
    }

    # --- Build accurate expiry timestamp ---
    # Use real future expiry timestamp so rclone does not force an on-mount refresh
    $expiryStr = '2000-01-01T00:00:00Z'
    if ($tokens.PSObject.Properties['expiry'] -and -not [string]::IsNullOrWhiteSpace($tokens.expiry)) {
        try {
            $parsedExp = [DateTime]::Parse($tokens.expiry).ToUniversalTime()
            if ($parsedExp -gt [DateTime]::UtcNow) {
                $expiryStr = $parsedExp.ToString('o')
            }
        } catch { }
    }
    if ($expiryStr -eq '2000-01-01T00:00:00Z') {
        $hasObtainedAt2 = ($tokens.PSObject.Properties['obtained_at'] -and $tokens.obtained_at)
        $hasExpiresIn2  = ($tokens.PSObject.Properties['expires_in']  -and $tokens.expires_in)
        if ($hasObtainedAt2 -and $hasExpiresIn2) {
            try {
                $obtainedUtc = [DateTime]::Parse($tokens.obtained_at).ToUniversalTime()
                $expSec      = [int]$tokens.expires_in
                $expUtc      = $obtainedUtc.AddSeconds($expSec)
                if ($expUtc -gt [DateTime]::UtcNow) {
                    $expiryStr = $expUtc.ToString('o')
                }
            } catch { }
        }
    }

    $tokenObj = [ordered]@{
        access_token  = $tokens.access_token
        token_type    = if ($tokens.PSObject.Properties['token_type'] -and $tokens.token_type) { $tokens.token_type } else { 'Bearer' }
        refresh_token = if ($tokens.PSObject.Properties['refresh_token']) { $tokens.refresh_token } else { $null }
        expiry        = $expiryStr
    }
    $tokenJson = $tokenObj | ConvertTo-Json -Compress

    $upperRemote = $RemoteName.ToUpperInvariant()

    $envMap = @{
        "RCLONE_CONFIG_${upperRemote}_TYPE"  = 'drive'
        "RCLONE_CONFIG_${upperRemote}_SCOPE" = $Scope
        "RCLONE_CONFIG_${upperRemote}_TOKEN" = $tokenJson
    }

    if ($oauthConfig.ClientId) {
        $envMap["RCLONE_CONFIG_${upperRemote}_CLIENT_ID"]     = $oauthConfig.ClientId
    }
    if ($oauthConfig.ClientSecret) {
        $envMap["RCLONE_CONFIG_${upperRemote}_CLIENT_SECRET"] = $oauthConfig.ClientSecret
    }

    return $envMap
}

function Invoke-GoogleDriveMountWithRetry(
    [Parameter(Mandatory = $true)]
    [string]$RemoteName,
    [string]$AccountId = '',
    [string]$DriveLetter = '',
    [string]$VolumeLabel = '',
    [string]$CacheDirectory = '',
    [int]$CacheMaxGigabytes = 20,
    [switch]$ReadOnly = $false,
    [hashtable]$Progress = $null,
    [int]$MaxAttempts = 3
) {
    $cleanLetter = if ($DriveLetter) { $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\') } else { 'G' }
    $volName = if ($VolumeLabel) { $VolumeLabel } else { 'Google Drive' }

    if ($Progress) {
        $Progress.Stage = "Initializing ${cleanLetter}: mount"
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($Progress) {
                $Progress.Stage = 'Refreshing Google Drive token'
            }
            $environment = Get-GoogleDriveRcloneEnvironment -AccountId $AccountId -RemoteName $RemoteName

            if ($Progress) {
                $Progress.Stage = "Starting ${cleanLetter}: mount"
            }

            Start-VirtualDriveMount -RemoteName $RemoteName -ProviderId 'gdrive' -AccountId $AccountId `
                -DriveLetter $cleanLetter -VolumeLabel $volName `
                -CacheDirectory $CacheDirectory -CacheMaxGigabytes $CacheMaxGigabytes `
                -EnvironmentVariables $environment -ReadOnly:$ReadOnly -Progress $Progress | Out-Null

            if ($Progress) {
                $Progress.Stage = "Mounted (${cleanLetter}:)"
                $Progress.Error = $null
            }
            return [ordered]@{
                Success     = $true
                State       = 'Mounted'
                Error       = $null
                DriveLetter = $cleanLetter
            }
        } catch {
            $errMessage = $_.Exception.Message
            $lastError = $errMessage

            # Classify errors: Non-retryable auth errors
            if ($errMessage -match '(?i)(invalid_grant|token revoked|unauthorized|bad client credentials|unauthorized_client|No Google Drive tokens)') {
                $authErr = 'Google Drive authorization expired or revoked. Please reconnect your account.'
                if ($Progress) {
                    $Progress.Stage = 'Sign-in required'
                    $Progress.Error = $authErr
                }
                return [ordered]@{
                    Success     = $false
                    State       = 'AuthRequired'
                    Error       = $authErr
                    DriveLetter = $cleanLetter
                }
            }

            # Retryable errors: HTTP 429, 500, 503, network timeouts, RATE_LIMIT_EXCEEDED, premature exit
            if ($attempt -lt $MaxAttempts) {
                if ($Progress) {
                    $Progress.Stage = "Waiting before retry (Attempt $($attempt + 1) of $MaxAttempts)"
                }
                try {
                    Stop-VirtualDriveMount -ProviderId 'gdrive' -AccountId $AccountId -DriveLetter $cleanLetter | Out-Null
                } catch { }

                # Backoff: 4s * 2^(attempt - 1) + jitter (between 100ms and 900ms)
                $jitter = (Get-Random -Minimum 100 -Maximum 900) / 1000.0
                $delaySec = [Math]::Round((4 * [Math]::Pow(2, $attempt - 1)) + $jitter, 1)
                [System.Threading.Thread]::Sleep([int]($delaySec * 1000))
            }
        }
    }

    # Retry budget exhausted
    try {
        Stop-VirtualDriveMount -ProviderId 'gdrive' -AccountId $AccountId -DriveLetter $cleanLetter | Out-Null
    } catch { }

    $exhaustedErr = 'Google Drive could not connect after several attempts. Please reconnect your account and try again.'
    if ($Progress) {
        $Progress.Stage = 'Connection failed'
        $Progress.Error = $exhaustedErr
    }
    return [ordered]@{
        Success     = $false
        State       = 'Error'
        Error       = $exhaustedErr
        DriveLetter = $cleanLetter
    }
}
