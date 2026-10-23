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
        $acl = if ($isDir) { [System.Security.AccessControl.DirectorySecurity]::new() } else { [System.Security.AccessControl.FileSecurity]::new() }
        $acl.SetAccessRuleProtection($true, $false)
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
            UserInfo = $null
        }
        $script:GoogleDriveSessionCache[$cacheKey] = [ordered]@{ CheckedAt = [DateTime]::UtcNow; Result = $res }
        return $res
    }

    # Step 1: Validate token and retrieve user identity via root file metadata
    $userDisplayName = $null
    $userEmail = $null

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
            }
        } catch { }
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
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $rclone
                $psi.Arguments = "about --json ${safeRemote}:"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                foreach ($k in $envVars.Keys) {
                    $psi.EnvironmentVariables[$k] = [string]$envVars[$k]
                }
                $proc = [System.Diagnostics.Process]::Start($psi)
                $outJson = $proc.StandardOutput.ReadToEnd()
                [void]$proc.WaitForExit(4000)
                if ($proc.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($outJson))) {
                    $aboutObj = $outJson | ConvertFrom-Json
                    $quotaTotal = if ($aboutObj.total) { [int64]$aboutObj.total } else { 0L }
                    $quotaUsed = if ($aboutObj.used) { [int64]$aboutObj.used } else { 0L }

                    # Retrieve account metadata from settings if available, else generic fallback
                    $acc = if (-not [string]::IsNullOrEmpty($AccountId) -and (Get-Command 'Find-CloudAccountById' -ErrorAction SilentlyContinue)) {
                        Find-CloudAccountById -Id $AccountId
                    } else { $null }
                    $fallbackName = if ($acc -and $acc.DisplayName) { [string]$acc.DisplayName } else { 'Google Drive User' }
                    $fallbackEmail = if ($acc -and $acc.AccountEmail) { [string]$acc.AccountEmail } elseif ($acc -and $acc.Username -and $acc.Username -match '@') { [string]$acc.Username } else { '' }

                    return (& $SetCacheAndReturn ([ordered]@{
                        IsValid = $true
                        State = 'Connected'
                        Error = $null
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
            $acc = if (-not [string]::IsNullOrEmpty($AccountId) -and (Get-Command 'Find-CloudAccountById' -ErrorAction SilentlyContinue)) {
                Find-CloudAccountById -Id $AccountId
            } else { $null }
            $fallbackName = if ($acc -and $acc.DisplayName) { [string]$acc.DisplayName } else { 'Google Drive User' }
            $fallbackEmail = if ($acc -and $acc.AccountEmail) { [string]$acc.AccountEmail } else { '' }

            return (& $SetCacheAndReturn ([ordered]@{
                IsValid = $true
                State = 'Connected'
                Error = $null
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
            UserInfo = $null
        }))
    }

    # Step 2: Retrieve storage quota (via /about or rclone fallback)
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
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $rclone
                $psi.Arguments = "about --json ${safeRemote}:"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.CreateNoWindow = $true
                foreach ($k in $envVars.Keys) {
                    $psi.EnvironmentVariables[$k] = [string]$envVars[$k]
                }
                $p = [System.Diagnostics.Process]::Start($psi)
                $out = $p.StandardOutput.ReadToEnd()
                [void]$p.WaitForExit(4000)
                if ($p.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($out))) {
                    $json = $out | ConvertFrom-Json
                    if ($json.PSObject.Properties['used']) { $quotaUsed = [int64]$json.used }
                    if ($json.PSObject.Properties['total']) { $quotaTotal = [int64]$json.total }
                }
            }
        } catch { }
    }

    return (& $SetCacheAndReturn ([ordered]@{
        IsValid = $true
        State = 'Connected'
        Error = $null
        UserInfo = [ordered]@{
            DisplayName = if ($userDisplayName) { $userDisplayName } else { 'Google Drive User' }
            EmailAddress = if ($userEmail) { $userEmail } else { '' }
            QuotaUsed = $quotaUsed
            QuotaTotal = $quotaTotal
        }
    }))
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
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = $rclone
                $psi.Arguments = "lsjson --max-depth 1 ${remoteName}:"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.CreateNoWindow = $true
                foreach ($k in $envVars.Keys) {
                    $psi.EnvironmentVariables[$k] = [string]$envVars[$k]
                }
                $proc = [System.Diagnostics.Process]::Start($psi)
                $outJson = $proc.StandardOutput.ReadToEnd()
                [void]$proc.WaitForExit(10000)
                if ($proc.ExitCode -eq 0 -and (-not [string]::IsNullOrWhiteSpace($outJson))) {
                    $rawItems = $outJson | ConvertFrom-Json
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
    $tokens = Get-GoogleDriveStoredTokens -AccountId $AccountId
    $oauthConfig = Get-GoogleOAuthConfig
    if (-not $tokens -or -not $tokens.access_token) {
        throw 'No Google Drive tokens available to configure rclone environment.'
    }

    # --- Proactive token refresh ---
    # If the stored access token is expired (or will expire within 120 seconds) and we have a
    # refresh_token plus a custom OAuth client configured, refresh it NOW rather than letting
    # rclone attempt the refresh under rate-limit conditions.  This eliminates the 30-35 second
    # startup delay caused by exponential-backoff retries against Google's shared client quota.
    $hasObtainedAt = ($tokens.PSObject.Properties['obtained_at'] -and $tokens.obtained_at)
    $hasExpiresIn  = ($tokens.PSObject.Properties['expires_in']  -and $tokens.expires_in)
    $hasRefresh    = ($tokens.PSObject.Properties['refresh_token'] -and -not [string]::IsNullOrEmpty($tokens.refresh_token))

    $tokenIsExpiredOrSoon = $false
    if ($hasObtainedAt -and $hasExpiresIn) {
        try {
            $obtainedCheck = [DateTime]::Parse($tokens.obtained_at).ToUniversalTime()
            $expSecCheck   = [int]$tokens.expires_in
            if (([DateTime]::UtcNow - $obtainedCheck).TotalSeconds -ge ($expSecCheck - 120)) {
                $tokenIsExpiredOrSoon = $true
            }
        } catch { }
    } else {
        # No timing metadata — assume expired to be safe
        $tokenIsExpiredOrSoon = $true
    }

    if ($tokenIsExpiredOrSoon -and $hasRefresh -and $oauthConfig.ClientId) {
        try {
            $refreshResult = Refresh-GoogleAccessToken `
                -ClientId     $oauthConfig.ClientId `
                -ClientSecret $oauthConfig.ClientSecret `
                -RefreshToken $tokens.refresh_token `
                -AccountId    $AccountId
            if ($refreshResult.Success -and $refreshResult.Tokens -and $refreshResult.Tokens.access_token) {
                $tokens = $refreshResult.Tokens
            }
        } catch { }
    }

    # --- Build accurate expiry timestamp ---
    # Use the real expires_in value — do NOT cap it to 3600.  Google issues tokens with
    # expires_in=3599 (just under one hour); capping at 3600 previously caused rclone to treat
    # a still-valid token as expired and retry the refresh under shared-client rate limits.
    $expiryStr = '2000-01-01T00:00:00Z'
    $hasObtainedAt2 = ($tokens.PSObject.Properties['obtained_at'] -and $tokens.obtained_at)
    $hasExpiresIn2  = ($tokens.PSObject.Properties['expires_in']  -and $tokens.expires_in)
    if ($hasObtainedAt2 -and $hasExpiresIn2) {
        try {
            $obtainedUtc = [DateTime]::Parse($tokens.obtained_at).ToUniversalTime()
            $expSec      = [int]$tokens.expires_in            # real value — no arbitrary cap
            $expUtc      = $obtainedUtc.AddSeconds($expSec)
            if ($expUtc -gt [DateTime]::UtcNow) {
                $expiryStr = $expUtc.ToString('o')
            }
        } catch { }
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
