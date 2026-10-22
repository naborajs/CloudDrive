Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

$script:GoogleCredentialDirectory = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials'
$script:GoogleCredentialPath = Join-Path $script:GoogleCredentialDirectory 'google-drive-tokens.xml'
$script:GoogleAuthEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth'
$script:GoogleTokenEndpoint = 'https://oauth2.googleapis.com/token'
$script:GoogleRevokeEndpoint = 'https://oauth2.googleapis.com/revoke'
$script:GoogleDriveApiEndpoint = 'https://www.googleapis.com/drive/v3'
$script:GoogleDefaultScope = 'https://www.googleapis.com/auth/drive.readonly'

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

function Get-GoogleDriveStoredTokens {
    if (-not (Test-Path -LiteralPath $script:GoogleCredentialPath -PathType Leaf)) {
        return $null
    }

    try {
        $cred = Import-Clixml -LiteralPath $script:GoogleCredentialPath
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

function Save-GoogleDriveTokens([hashtable]$TokenData) {
    if (-not $TokenData -or -not $TokenData.access_token) {
        throw 'Cannot store invalid Google Drive tokens.'
    }

    if (-not (Test-Path -LiteralPath $script:GoogleCredentialDirectory)) {
        New-Item -ItemType Directory -Path $script:GoogleCredentialDirectory | Out-Null
    }

    $json = $TokenData | ConvertTo-Json -Compress
    $secString = ConvertTo-SecureString -String $json -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('google-drive', $secString)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $script:GoogleCredentialPath
        # Restrict ACL to current user and SYSTEM
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
        Set-Acl -LiteralPath $script:GoogleCredentialPath -AclObject $acl
    } finally {
        $secString.Dispose()
    }
}

function Remove-GoogleDriveSession {
    $tokens = Get-GoogleDriveStoredTokens
    if ($tokens -and $tokens.access_token) {
        try {
            $revokeUrl = "$script:GoogleRevokeEndpoint?token=$($tokens.access_token)"
            Invoke-RestMethod -Uri $revokeUrl -Method Post -TimeoutSec 5 -ErrorAction SilentlyContinue | Out-Null
        } catch { }
    }

    if (Test-Path -LiteralPath $script:GoogleCredentialPath) {
        Remove-Item -LiteralPath $script:GoogleCredentialPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-GoogleOAuthConfig {
    $configDirectory = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config'
    $configPath = Join-Path $configDirectory 'google-oauth.json'

    $clientId = $env:GOOGLE_CLIENT_ID
    $clientSecret = $env:GOOGLE_CLIENT_SECRET

    if (-not $clientId -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        try {
            $json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($json.client_id) { $clientId = [string]$json.client_id }
            if ($json.client_secret) { $clientSecret = [string]$json.client_secret }
        } catch { }
    }

    $isConfigured = (-not [string]::IsNullOrEmpty($clientId))
    return [ordered]@{
        ClientId = $clientId
        ClientSecret = $clientSecret
        IsConfigured = $isConfigured
        ConfigPath = $configPath
    }
}

function Build-GoogleAuthorizationUrl([string]$ClientId, [string]$RedirectUri, [string]$State, [string]$Scope = $script:GoogleDefaultScope) {
    if ([string]::IsNullOrEmpty($ClientId)) {
        throw 'Cannot build authorization URL without a valid Client ID.'
    }
    $escClient = [System.Uri]::EscapeDataString($ClientId)
    $escRedirect = [System.Uri]::EscapeDataString($RedirectUri)
    $escScope = [System.Uri]::EscapeDataString($Scope)
    $escState = [System.Uri]::EscapeDataString($State)

    return "$($script:GoogleAuthEndpoint)?client_id=$escClient&redirect_uri=$escRedirect&response_type=code&scope=$escScope&state=$escState&access_type=offline&prompt=consent"
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
            $html = "<html><body style='font-family:sans-serif;text-align:center;padding:50px;'><h2>Authentication Failed</h2><p>$([System.Web.HttpUtility]::HtmlEncode($error))</p><p>You can close this tab and return to NS Cloud Drive.</p></body></html>"
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

function Exchange-GoogleAuthCode([string]$ClientId, [string]$ClientSecret, [string]$Code, [string]$RedirectUri) {
    $body = @{
        client_id = $ClientId
        client_secret = $ClientSecret
        code = $Code
        grant_type = 'authorization_code'
        redirect_uri = $RedirectUri
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

function Refresh-GoogleAccessToken([string]$ClientId, [string]$ClientSecret, [string]$RefreshToken) {
    $body = @{
        client_id = $ClientId
        client_secret = $ClientSecret
        refresh_token = $RefreshToken
        grant_type = 'refresh_token'
    }

    try {
        $response = Invoke-RestMethod -Uri $script:GoogleTokenEndpoint -Method Post -Body $body -TimeoutSec 15 -ErrorAction Stop
        if ($response -and $response.access_token) {
            $currentTokens = Get-GoogleDriveStoredTokens
            $tokenData = [ordered]@{
                access_token = $response.access_token
                refresh_token = $(if ($response.refresh_token) { $response.refresh_token } else { $RefreshToken })
                token_type = $response.token_type
                expires_in = $response.expires_in
                scope = $(if ($response.scope) { $response.scope } else { $currentTokens.scope })
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

function Test-GoogleDriveBackendSession([hashtable]$TokensOverride = $null) {
    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens }
    if (-not $tokens -or -not $tokens.access_token) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            Error = 'No Google Drive tokens found. Please connect your account.'
            UserInfo = $null
        }
    }

    try {
        $headers = @{
            'Authorization' = "Bearer $($tokens.access_token)"
            'Accept' = 'application/json'
        }

        $aboutUrl = "$script:GoogleDriveApiEndpoint/about?fields=user,storageQuota"
        $response = Invoke-RestMethod -Uri $aboutUrl -Headers $headers -Method Get -TimeoutSec 15 -ErrorAction Stop

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
                Error = 'Google Drive access token has expired. Automatic refresh will be attempted.'
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

function Get-GoogleDriveFileList([int]$PageSize = 25, [hashtable]$TokensOverride = $null) {
    $tokens = if ($TokensOverride) { $TokensOverride } else { Get-GoogleDriveStoredTokens }
    if (-not $tokens -or -not $tokens.access_token) {
        return [ordered]@{
            Success = $false
            Files = @()
            Error = 'Not connected to Google Drive.'
        }
    }

    try {
        $headers = @{
            'Authorization' = "Bearer $($tokens.access_token)"
            'Accept' = 'application/json'
        }

        $filesUrl = "$script:GoogleDriveApiEndpoint/files?pageSize=$PageSize&fields=files(id,name,mimeType,size,modifiedTime)&q=trashed=false"
        $response = Invoke-RestMethod -Uri $filesUrl -Headers $headers -Method Get -TimeoutSec 15 -ErrorAction Stop

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
