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
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($userSid, $systemSid)) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch { }
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
        if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
            $defaultPath = Get-GoogleCredentialFilePath
            if (Test-Path -LiteralPath $defaultPath -PathType Leaf) {
                $credPath = $defaultPath
            } else {
                return $null
            }
        } else {
            return $null
        }
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

function Save-GoogleDriveTokens([hashtable]$TokenData, [string]$AccountId = '') {
    if (-not $TokenData -or -not $TokenData.access_token) {
        throw 'Cannot store invalid Google Drive tokens.'
    }

    $credDir = Get-GoogleCredentialDirectory
    $credPath = Get-GoogleCredentialFilePath -AccountId $AccountId

    if (-not (Test-Path -LiteralPath $credDir)) {
        New-Item -ItemType Directory -Path $credDir | Out-Null
        Set-StrictCredentialAcl -Path $credDir
    }

    $json = $TokenData | ConvertTo-Json -Compress
    $secString = ConvertTo-SecureString -String $json -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('google-drive', $secString)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $credPath
        Set-StrictCredentialAcl -Path $credPath
    } finally {
        $secString.Dispose()
    }
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

        # Render response page in user browser
        $html = ''
        if ($error) {
            $html = "<html><body style='font-family:sans-serif;text-align:center;padding:50px;'><h2>Authentication Failed</h2><p>$([System.Net.WebUtility]::HtmlEncode($error))</p><p>You can close this tab and return to NS Cloud Drive.</p></body></html>"
        } elseif (-not $state -or $state -ne $expectedState) {
            $error = 'State parameter mismatch (possible CSRF or invalid request).'
            $html = "<html><body style='font-family:sans-serif;text-align:center;padding:50px;'><h2>Security Validation Failed</h2><p>State parameter did not match. Please restart sign-in from NS Cloud Drive.</p></body></html>"
        } elseif (-not $code) {
            $error = 'No authorization code received from Google.'
            $html = "<html><body style='font-family:sans-serif;text-align:center;padding:50px;'><h2>Authorization Code Missing</h2><p>Please restart sign-in from NS Cloud Drive.</p></body></html>"
        } else {
            $html = "<html><body style='font-family:sans-serif;text-align:center;padding:50px;'><h2 style='color:#0F9D58;'>Google Drive Connected</h2><p>Authentication was successful! You may close this tab and return to NS Cloud Drive.</p></body></html>"
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
    [string]$CodeVerifier = $null
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
            Save-GoogleDriveTokens -TokenData $tokenData
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

function Invoke-GoogleDriveApiWithRetry([scriptblock]$ApiAction, [hashtable]$TokensOverride = $null, [string]$AccountId = '') {
    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens -AccountId $AccountId }
    if (-not $tokens -or -not $tokens.access_token) {
        throw 'No Google Drive tokens available.'
    }

    try {
        return (& $ApiAction $tokens.access_token)
    } catch {
        $sanitized = Format-SanitizedDiagnosticMessage $_.Exception.Message
        $isAuthError = ($sanitized -match '401' -or $sanitized -match 'Invalid Credentials')

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
        throw
    }
}

function Test-GoogleDriveBackendSession([hashtable]$TokensOverride = $null, [string]$AccountId = '') {
    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens -AccountId $AccountId }
    if (-not $tokens -or -not $tokens.access_token) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            Error = 'No Google Drive tokens found. Please connect your account.'
            UserInfo = $null
        }
    }

    try {
        $response = Invoke-GoogleDriveApiWithRetry -TokensOverride $TokensOverride -AccountId $AccountId -ApiAction {
            param([string]$accessToken)
            $headers = @{
                'Authorization' = "Bearer $accessToken"
                'Accept' = 'application/json'
            }
            $aboutUrl = "$script:GoogleDriveApiEndpoint/about?fields=user,storageQuota"
            return (Invoke-RestMethod -Uri $aboutUrl -Headers $headers -Method Get -TimeoutSec 15 -ErrorAction Stop)
        }

        return [ordered]@{
            IsValid = $true
            State = 'Connected'
            Error = $null
            UserInfo = [ordered]@{
                DisplayName = $response.user.displayName
                EmailAddress = $response.user.emailAddress
                QuotaUsed = [int64]$response.storageQuota.usage
                QuotaTotal = [int64]$response.storageQuota.limit
            }
        }
    } catch {
        $sanitized = Format-SanitizedDiagnosticMessage $_.Exception.Message
        if ($sanitized -match '401' -or $sanitized -match 'Invalid Credentials') {
            return [ordered]@{
                IsValid = $false
                State = 'AuthenticationExpired'
                Error = 'Google Drive access token has expired or was revoked. Please reconnect your account.'
                UserInfo = $null
            }
        }
        return [ordered]@{
            IsValid = $false
            State = 'Error'
            Error = "Google Drive API verification failed: $sanitized"
            UserInfo = $null
        }
    }
}

function Get-GoogleDriveFileList([int]$PageSize = 25, [hashtable]$TokensOverride = $null, [string]$AccountId = '') {
    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens -AccountId $AccountId }
    if (-not $tokens -or -not $tokens.access_token) {
        return [ordered]@{
            Success = $false
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
        if ($response.files) {
            foreach ($f in $response.files) {
                $isFolder = ($f.mimeType -eq 'application/vnd.google-apps.folder')
                $items += [ordered]@{
                    Id = $f.id
                    Name = $f.name
                    IsDirectory = $isFolder
                    Size = $(if ($f.size) { [int64]$f.size } else { 0 })
                    ModTime = $f.modifiedTime
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
        return [ordered]@{
            Success = $false
            Files = @()
            Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message)
        }
    }
}

function Get-GoogleDriveRcloneEnvironment([string]$AccountId = '', [string]$RemoteName = 'gdrive') {
    $tokens = Get-GoogleDriveStoredTokens -AccountId $AccountId
    $oauthConfig = Get-GoogleOAuthConfig
    if (-not $tokens -or -not $tokens.access_token) {
        throw 'No Google Drive tokens available to configure rclone environment.'
    }

    $hasObtainedAt = ($tokens.PSObject.Properties['obtained_at'] -and $tokens.obtained_at)
    $hasExpiresIn = ($tokens.PSObject.Properties['expires_in'] -and $tokens.expires_in)

    $tokenObj = [ordered]@{
        access_token = $tokens.access_token
        token_type = if ($tokens.PSObject.Properties['token_type'] -and $tokens.token_type) { $tokens.token_type } else { 'Bearer' }
        refresh_token = if ($tokens.PSObject.Properties['refresh_token']) { $tokens.refresh_token } else { $null }
        expiry = if ($hasObtainedAt -and $hasExpiresIn) {
            try {
                ([DateTime]::Parse($tokens.obtained_at).AddSeconds($tokens.expires_in)).ToString('o')
            } catch {
                [DateTime]::UtcNow.AddHours(1).ToString('o')
            }
        } else {
            [DateTime]::UtcNow.AddHours(1).ToString('o')
        }
    }
    $tokenJson = $tokenObj | ConvertTo-Json -Compress

    $upperRemote = $RemoteName.ToUpperInvariant()

    $envMap = @{
        "RCLONE_CONFIG_${upperRemote}_TYPE" = 'drive'
        "RCLONE_CONFIG_${upperRemote}_SCOPE" = 'drive.readonly'
        "RCLONE_CONFIG_${upperRemote}_TOKEN" = $tokenJson
    }

    if ($oauthConfig.ClientId) {
        $envMap["RCLONE_CONFIG_${upperRemote}_CLIENT_ID"] = $oauthConfig.ClientId
    }
    if ($oauthConfig.ClientSecret) {
        $envMap["RCLONE_CONFIG_${upperRemote}_CLIENT_SECRET"] = $oauthConfig.ClientSecret
    }

    return $envMap
}
