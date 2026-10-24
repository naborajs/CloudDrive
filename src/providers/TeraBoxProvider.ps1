Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

function Get-TeraBoxCredentialDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials')
}

function Get-TeraBoxCredentialFilePath([string]$AccountId = '') {
    if (-not [string]::IsNullOrEmpty($AccountId) -and $AccountId -ne 'terabox') {
        $safeAccId = [regex]::Replace($AccountId, '[^a-zA-Z0-9_\-]', '_')
        return (Join-Path (Get-TeraBoxCredentialDirectory) "terabox-session-$safeAccId.xml")
    }
    return (Join-Path (Get-TeraBoxCredentialDirectory) 'terabox-session.xml')
}

$script:TeraBoxWebUrl = 'https://www.terabox.com/'
$script:TeraBoxAppId = '250528'

function Set-StrictTeraBoxCredentialAcl([string]$Path) {
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

function Get-TeraBoxProviderInfo {
    return [ordered]@{
        Id = 'terabox'
        Name = 'TeraBox'
        Mark = 'TB'
        AccentColor = '#2D60FF'
        WebsiteUrl = $script:TeraBoxWebUrl
        AuthMethods = @(
            [ordered]@{
                Id = 'web-session'
                Name = 'Browser Web Session'
                Description = 'Interactive sign-in on legitimate TeraBox website. Provides full account view when supported.'
                Status = 'Unofficial / Community'
                Limitations = 'Session does not have a documented backend refresh contract. TeraBox terms restrict non-public interfaces.'
            },
            [ordered]@{
                Id = 'open-api'
                Name = 'TeraBox Open Platform API'
                Description = 'Official OAuth 2.0 / Device-code flow with TeraBox-issued client credentials.'
                Status = 'Official API (Pending Developer Approval)'
                Limitations = 'Requires provider-issued client_id/secret. Documented scope is restricted to /From: Other Applications/<App>/.'
            }
        )
    }
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

function Get-TeraBoxStoredSession([string]$AccountId = '') {
    $credPath = Get-TeraBoxCredentialFilePath -AccountId $AccountId
    if (-not (Test-Path -LiteralPath $credPath -PathType Leaf)) {
        # Account-scoped reads must NEVER silently fall back to the shared
        # legacy session file: it belongs to the legacy TeraBox connection
        # and can hold a DIFFERENT TeraBox user's cookie. Reading it here
        # would validate, mount, and show that other user's files under
        # this account's id, drive letter, and display name. A missing
        # account-specific file is a clean "no session for this account"
        # answer; consumers report a sign-in requirement for it.
        return $null
    }

    try {
        $cred = Import-Clixml -LiteralPath $credPath
        if ($cred -is [System.Management.Automation.PSCredential]) {
            $bstr = [IntPtr]::Zero
            try {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

                $cookieVal = $secret
                $jsTokenVal = $null
                $baseUrlVal = 'https://www.terabox.com'
                $userAgentVal = $null

                if ($secret -and $secret.StartsWith('{') -and $secret.EndsWith('}')) {
                    try {
                        $meta = ConvertFrom-Json $secret -ErrorAction SilentlyContinue
                        $cookieFromJson = Get-SafeProperty $meta 'Cookie' $null
                        if ($cookieFromJson) {
                            $cookieVal = [string]$cookieFromJson
                            $jsTokenProp = Get-SafeProperty $meta 'JsToken' $null
                            if ($jsTokenProp) { $jsTokenVal = [string]$jsTokenProp }
                            $baseUrlProp = Get-SafeProperty $meta 'BaseUrl' $null
                            if ($baseUrlProp) { $baseUrlVal = [string]$baseUrlProp }
                            $uaProp = Get-SafeProperty $meta 'UserAgent' $null
                            if ($uaProp) { $userAgentVal = [string]$uaProp }
                        }
                    } catch { }
                }

                return [ordered]@{
                    Type = $cred.UserName
                    Secret = $cookieVal
                    JsToken = $jsTokenVal
                    BaseUrl = $baseUrlVal
                    UserAgent = $userAgentVal
                    RawSecret = $secret
                    StoredTime = (Get-Item -LiteralPath $credPath).LastWriteTimeUtc
                }
            } finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
                $secret = $null
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Save-TeraBoxSession(
    [string]$Type,
    [string]$Secret,
    [string]$JsToken = $null,
    [string]$BaseUrl = $null,
    [string]$UserAgent = $null,
    [string]$AccountId = ''
) {
    if ([string]::IsNullOrEmpty($Secret)) {
        throw 'Cannot store empty TeraBox session secret.'
    }

    $credDir = Get-TeraBoxCredentialDirectory
    $credPath = Get-TeraBoxCredentialFilePath -AccountId $AccountId

    if (-not (Test-Path -LiteralPath $credDir)) {
        New-Item -ItemType Directory -Path $credDir | Out-Null
        Set-StrictTeraBoxCredentialAcl -Path $credDir
    }

    $secretToStore = $Secret
    if (-not [string]::IsNullOrEmpty($JsToken) -or
        (-not [string]::IsNullOrEmpty($BaseUrl) -and $BaseUrl -ne 'https://www.terabox.com') -or
        (-not [string]::IsNullOrEmpty($UserAgent))) {
        $metaObj = [ordered]@{
            Cookie = $Secret
            JsToken = $JsToken
            BaseUrl = $(if ($BaseUrl) { $BaseUrl } else { 'https://www.terabox.com' })
            UserAgent = $UserAgent
        }
        $secretToStore = ConvertTo-Json $metaObj -Compress
    }

    $secString = ConvertTo-SecureString -String $secretToStore -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new($Type, $secString)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $credPath
        Set-StrictTeraBoxCredentialAcl -Path $credPath
    } finally {
        $secString.Dispose()
    }
}

function Remove-TeraBoxSession([string]$AccountId = '') {
    $credPath = Get-TeraBoxCredentialFilePath -AccountId $AccountId
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
    }
}

function Format-TeraBoxCookieHeader([string]$Secret) {
    if ([string]::IsNullOrWhiteSpace($Secret)) { return '' }
    $trimmed = $Secret.Trim()
    if ($trimmed.StartsWith('{') -and $trimmed.EndsWith('}')) {
        try {
            $meta = ConvertFrom-Json $trimmed -ErrorAction SilentlyContinue
            $cookieProp = Get-SafeProperty $meta 'Cookie' $null
            if ($cookieProp) {
                $trimmed = ([string]$cookieProp).Trim()
            }
        } catch { }
    }
    if ($trimmed.StartsWith('Cookie:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimmed = $trimmed.Substring(7).Trim()
    }
    if ($trimmed -match ';') {
        return $trimmed
    }
    if ($trimmed -match '^ndus=') {
        return $trimmed
    }
    return "ndus=$trimmed"
}

function Get-TeraBoxRcloneEnvironment(
    [hashtable]$SessionOverride = $null,
    [string]$AccountId = '',
    [string]$RemoteName = 'terabox'
) {
    $session = if ($SessionOverride) { $SessionOverride } else { Get-TeraBoxStoredSession -AccountId $AccountId }
    if (-not $session -or -not $session.Secret) {
        return @{}
    }

    $cookie = Format-TeraBoxCookieHeader $session.Secret
    $safeRemote = [regex]::Replace($RemoteName.ToUpperInvariant(), '[^A-Z0-9_]', '_')
    return @{
        "RCLONE_CONFIG_${safeRemote}_TYPE" = 'terabox'
        "RCLONE_CONFIG_${safeRemote}_COOKIE" = $cookie
    }
}

function Set-TeraBoxManualSession(
    [Parameter(Mandatory = $true)]
    [string]$SessionSecret,
    [string]$Type = 'web-session'
) {
    $cleanSecret = $SessionSecret.Trim()
    if ($cleanSecret.StartsWith('Cookie:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $cleanSecret = $cleanSecret.Substring(7).Trim()
    }

    $testValidation = Test-TeraBoxBackendSession -SessionOverride @{
        Type = $Type
        Secret = $cleanSecret
    }

    if (-not $testValidation.IsValid) {
        return [ordered]@{
            Success = $false
            Error = "Session validation failed: $($testValidation.Error)"
            Validation = $testValidation
        }
    }

    Save-TeraBoxSession -Type $Type -Secret $cleanSecret

    return [ordered]@{
        Success = $true
        Error = $null
        Validation = $testValidation
    }
}

function Invoke-TeraBoxHttp(
    [string]$Url,
    [hashtable]$Headers = $null,
    [int]$TimeoutSec = 15,
    [object]$Window = $null
) {
    if (-not ([System.Management.Automation.PSTypeName]'System.Net.Http.HttpClient').Type) {
        try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        if ($Headers) {
            foreach ($k in $Headers.Keys) {
                $req.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) | Out-Null
            }
        }

        $task = $client.SendAsync($req)
        if ($Window -and (Get-Command 'Wait-WpfTask' -ErrorAction SilentlyContinue)) {
            $done = Wait-WpfTask -Task $task -TimeoutMs ($TimeoutSec * 1000) -Window $Window
            if (-not $done) {
                throw "HTTP request timed out after $TimeoutSec seconds."
            }
        } else {
            # Background worker path (no WPF pump): bounded wait. An unbounded
            # Wait() here stalled a startup-restore worker indefinitely when a
            # TeraBox edge node hung the connection, keeping that provider's
            # mount from ever starting. If the task faults, Wait rethrows the
            # original exception exactly like an unbounded wait would.
            if (-not $task.Wait([Math]::Max(5, $TimeoutSec) * 1000)) {
                try { $client.CancelPendingRequests() } catch { }
                throw "HTTP request timed out after $TimeoutSec seconds."
            }
        }

        $resp = $task.Result
        $prefix = $null
        if ($resp.Headers.Contains('Url-Domain-Prefix')) {
            $prefix = ($resp.Headers.GetValues('Url-Domain-Prefix') | Select-Object -First 1)
        }

        if ([int]$resp.StatusCode -ge 300 -and [int]$resp.StatusCode -lt 400) {
            return [ordered]@{
                errno = -6
                error = 'TeraBox redirected the request (session expired or login required).'
                UrlDomainPrefix = $prefix
            }
        }

        if (-not $resp.IsSuccessStatusCode) {
            return [ordered]@{
                errno = -6
                error = "HTTP status $([int]$resp.StatusCode) ($($resp.ReasonPhrase))"
                UrlDomainPrefix = $prefix
            }
        }

        $readTask = $resp.Content.ReadAsStringAsync()
        if ($Window -and (Get-Command 'Wait-WpfTask' -ErrorAction SilentlyContinue)) {
            [void](Wait-WpfTask -Task $readTask -TimeoutMs 5000 -Window $Window)
        } else {
            # The HttpClient timeout does not cover ReadAsStringAsync once the
            # response headers have arrived, so this read must carry its own
            # bound (same startup-restore stall as the send path above).
            if (-not $readTask.Wait(5000)) {
                try { $client.CancelPendingRequests() } catch { }
                throw 'HTTP response body read timed out after 5 seconds.'
            }
        }

        $body = $readTask.Result
        $prefix = $null
        if ($resp.Headers.Contains('Url-Domain-Prefix')) {
            $prefix = ($resp.Headers.GetValues('Url-Domain-Prefix') | Select-Object -First 1)
        }

        if (-not [string]::IsNullOrWhiteSpace($body)) {
            $parsed = ConvertFrom-Json $body -ErrorAction SilentlyContinue
            if ($parsed) {
                if ($prefix) {
                    $parsed | Add-Member -NotePropertyName 'UrlDomainPrefix' -NotePropertyValue $prefix -Force -ErrorAction SilentlyContinue
                }
                return $parsed
            }
        }

        return [ordered]@{
            errno = -1
            error = 'Received non-JSON response from TeraBox.'
            UrlDomainPrefix = $prefix
        }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

$script:TeraBoxSessionCache = @{}

function Test-TeraBoxBackendSession(
    [hashtable]$SessionOverride = $null,
    [object]$Window = $null,
    [string]$AccountId = '',
    [switch]$Force = $false
) {
    $cacheKey = if (-not [string]::IsNullOrEmpty($AccountId)) { $AccountId } else { 'default' }
    if ((-not $Force) -and (-not $SessionOverride) -and $script:TeraBoxSessionCache.ContainsKey($cacheKey)) {
        $cached = $script:TeraBoxSessionCache[$cacheKey]
        if ($cached -and $cached.CheckedAt -and (([DateTime]::UtcNow - $cached.CheckedAt).TotalSeconds -lt 120)) {
            return $cached.Result
        }
    }

    $SetCacheAndReturn = {
        param($val)
        $script:TeraBoxSessionCache[$cacheKey] = [ordered]@{ CheckedAt = [DateTime]::UtcNow; Result = $val }
        return $val
    }

    $session = if ($SessionOverride) { $SessionOverride } else { Get-TeraBoxStoredSession -AccountId $AccountId }
    if (-not $session) {
        return (& $SetCacheAndReturn ([ordered]@{
            IsValid = $false
            State = 'Disconnected'
            Error = 'No local TeraBox session or credentials found. Please sign in.'
            UserInfo = $null
        }))
    }

    try {
        $activeUserAgent = if ($session.UserAgent) {
            $session.UserAgent
        } else {
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        }
        $headers = @{
            'Accept' = 'application/json, text/plain, */*'
            'User-Agent' = $activeUserAgent
        }

        $checkUrl = ''
        if ($session.Type -eq 'open-api') {
            $checkUrl = "https://www.terabox.com/openapi/uinfo?access_tokens=$([System.Uri]::EscapeDataString($session.Secret))"
        } else {
            # Web session
            $baseUrl = if ($session.BaseUrl) { $session.BaseUrl.TrimEnd('/') } else { 'https://www.terabox.com' }
            $headers['Referer'] = "$baseUrl/"
            $headers['X-Requested-With'] = 'XMLHttpRequest'
            $headers['Cookie'] = Format-TeraBoxCookieHeader $session.Secret
            $checkUrl = "$baseUrl/api/check/login?app_id=$script:TeraBoxAppId&channel=dubox&clienttype=0"
            if ($session.JsToken) {
                $checkUrl += "&jsToken=$([System.Uri]::EscapeDataString($session.JsToken))"
            }
        }

        $response = Invoke-TeraBoxHttp -Url $checkUrl -Headers $headers -TimeoutSec 15 -Window $Window

        $errno = Get-SafeProperty $response 'errno' $null
        $prefix = Get-SafeProperty $response 'UrlDomainPrefix' $null

        # If error is -6 and TeraBox indicated an account host prefix (e.g. dm.terabox.com)
        if (($null -eq $errno -or [int]$errno -eq -6) -and -not [string]::IsNullOrEmpty($prefix) -and $session.Type -ne 'open-api') {
            $switchedBaseUrl = "https://$prefix.terabox.com"
            if ($switchedBaseUrl -ne $baseUrl) {
                $headers['Referer'] = "$switchedBaseUrl/"
                $retryUrl = "$switchedBaseUrl/api/check/login?app_id=$script:TeraBoxAppId&channel=dubox&clienttype=0"
                if ($session.JsToken) {
                    $retryUrl += "&jsToken=$([System.Uri]::EscapeDataString($session.JsToken))"
                }
                $response = Invoke-TeraBoxHttp -Url $retryUrl -Headers $headers -TimeoutSec 15 -Window $Window
                $errno = Get-SafeProperty $response 'errno' $null
                if ($null -ne $errno -and [int]$errno -eq 0) {
                    $baseUrl = $switchedBaseUrl
                    try {
                        # Persist the host fix under THIS account's id. Saving
                        # without an AccountId would write this account's
                        # metadata into the legacy single-account session file
                        # and silently switch that connection's identity to
                        # this account's user.
                        Save-TeraBoxSession -Type $session.Type -Secret $session.Secret -JsToken $session.JsToken -BaseUrl $baseUrl -UserAgent $activeUserAgent -AccountId $AccountId
                    } catch { }
                }
            }
        }
        if ($null -ne $errno -and [int]$errno -eq 0) {
            $uk = Get-SafeProperty $response 'uk' $null
            $uname = Get-SafeProperty $response 'username' $null
            if (-not $uname) { $uname = Get-SafeProperty $response 'user_name' $null }
            if (-not $uname) { $uname = Get-SafeProperty $response 'uname' $null }

            $quotaTotal = [int64]0
            $quotaUsed = [int64]0
            try {
                $quotaUrl = "$baseUrl/api/quota?checkexpire=1&checkfree=1"
                $qResp = Invoke-TeraBoxHttp -Url $quotaUrl -Headers $headers -TimeoutSec 10 -Window $Window
                if ($qResp) {
                    $t = Get-SafeProperty $qResp 'total' 0
                    $u = Get-SafeProperty $qResp 'used' 0
                    if ($t) { $quotaTotal = [int64]$t }
                    if ($u) { $quotaUsed = [int64]$u }
                }
            } catch { }

            $displayName = if ($uname) {
                [string]$uname
            } elseif ($uk) {
                $ukStr = [string]$uk
                $suffix = if ($ukStr.Length -gt 4) { $ukStr.Substring($ukStr.Length - 4) } else { $ukStr }
                "TeraBox user ...$suffix"
            } else {
                'TeraBox User'
            }

            return (& $SetCacheAndReturn ([ordered]@{
                IsValid = $true
                State = 'Connected'
                Error = $null
                UserInfo = [ordered]@{
                    Type = $session.Type
                    UserName = $displayName
                    Uk = $uk
                    BaseUrl = $baseUrl
                    UserAgent = $activeUserAgent
                    QuotaTotal = $quotaTotal
                    QuotaUsed = $quotaUsed
                    QuotaTotalBytes = $quotaTotal
                    QuotaUsedBytes = $quotaUsed
                }
            }))
        } else {
            $errCode = if ($null -ne $errno) { [int]$errno } else { -1 }
            $errDetail = switch ($errCode) {
                -6 { 'TeraBox backend returned error code: -6 (Session may have expired or requires re-authentication).' }
                4000023 { 'TeraBox backend returned error code: 4000023 (Page token jsToken is missing or expired).' }
                450016 { 'TeraBox backend returned error code: 450016 (Security verification required by TeraBox).' }
                default {
                    $msg = Get-SafeProperty $response 'error' $null
                    if (-not $msg) { $msg = Get-SafeProperty $response 'errmsg' $null }
                    if ($msg) {
                        "TeraBox backend returned error code: $errCode ($msg)."
                    } else {
                        "TeraBox backend returned error code: $errCode."
                    }
                }
            }

            return (& $SetCacheAndReturn ([ordered]@{
                IsValid = $false
                State = 'AuthenticationExpired'
                Error = $errDetail
                UserInfo = $null
            }))
        }
    } catch {
        $sanitizedError = Format-SanitizedDiagnosticMessage $_.Exception.Message
        return (& $SetCacheAndReturn ([ordered]@{
            IsValid = $false
            State = 'Error'
            Error = "Backend validation request failed: $sanitizedError"
            UserInfo = $null
        }))
    }
}

function Test-TeraBoxAccountScope(
    [hashtable]$SessionOverride = $null,
    [string]$AccountId = ''
) {
    $validation = Test-TeraBoxBackendSession -SessionOverride $SessionOverride -AccountId $AccountId
    if (-not $validation.IsValid) {
        return [ordered]@{
            ScopeVerified = $false
            Scope = 'Unknown'
            Error = $validation.Error
        }
    }

    $session = if ($SessionOverride) { $SessionOverride } else { Get-TeraBoxStoredSession -AccountId $AccountId }
    if ($session.Type -eq 'open-api') {
        # Official Open Platform is documented to be app-folder only
        return [ordered]@{
            ScopeVerified = $true
            Scope = 'AppFolder'
            RootPath = '/From: Other Applications/NSCloudDrive'
            Error = $null
        }
    } else {
        # Web session has full drive root scope
        return [ordered]@{
            ScopeVerified = $true
            Scope = 'FullDrive'
            RootPath = '/'
            Error = $null
        }
    }
}

function Get-TeraBoxFileList(
    [string]$Directory = '/',
    [hashtable]$SessionOverride = $null,
    [object]$Window = $null,
    [string]$AccountId = ''
) {
    $scopeInfo = Test-TeraBoxAccountScope -SessionOverride $SessionOverride -AccountId $AccountId
    if (-not $scopeInfo.ScopeVerified) {
        return [ordered]@{
            Success = $false
            Directory = $Directory
            ItemCount = 0
            Files = @()
            Error = $scopeInfo.Error
        }
    }

    $session = if ($SessionOverride) { $SessionOverride } else { Get-TeraBoxStoredSession -AccountId $AccountId }
    try {
        $activeUserAgent = if ($session.UserAgent) {
            $session.UserAgent
        } else {
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        }
        $headers = @{
            'Accept' = 'application/json, text/plain, */*'
            'User-Agent' = $activeUserAgent
        }

        $listUrl = ''
        if ($session.Type -eq 'open-api') {
            $dirParam = [System.Uri]::EscapeDataString($Directory)
            $tokenParam = [System.Uri]::EscapeDataString($session.Secret)
            $listUrl = "https://www.terabox.com/openapi/api/list?dir=$dirParam&access_tokens=$tokenParam&page=1&num=100"
        } else {
            $baseUrl = if ($session.BaseUrl) { $session.BaseUrl.TrimEnd('/') } else { 'https://www.terabox.com' }
            $headers['Referer'] = "$baseUrl/"
            $headers['X-Requested-With'] = 'XMLHttpRequest'
            $headers['Cookie'] = Format-TeraBoxCookieHeader $session.Secret
            $dirParam = [System.Uri]::EscapeDataString($Directory)
            $listUrl = "$baseUrl/api/list?app_id=$script:TeraBoxAppId&channel=dubox&clienttype=0&dir=$dirParam&page=1&num=100"
            if ($session.JsToken) {
                $listUrl += "&jsToken=$([System.Uri]::EscapeDataString($session.JsToken))"
            }
        }

        $response = Invoke-TeraBoxHttp -Url $listUrl -Headers $headers -TimeoutSec 15 -Window $Window

        $errno = Get-SafeProperty $response 'errno' $null
        $prefix = Get-SafeProperty $response 'UrlDomainPrefix' $null

        # If errno is -6 and a regional host switch prefix is present, update baseUrl and retry once
        if (($null -eq $errno -or [int]$errno -eq -6) -and -not [string]::IsNullOrEmpty($prefix) -and $session.Type -ne 'open-api') {
            $switchedBaseUrl = "https://$prefix.terabox.com"
            if ($switchedBaseUrl -ne $baseUrl) {
                $headers['Referer'] = "$switchedBaseUrl/"
                $retryUrl = "$switchedBaseUrl/api/list?app_id=$script:TeraBoxAppId&channel=dubox&clienttype=0&dir=$dirParam&page=1&num=100"
                if ($session.JsToken) {
                    $retryUrl += "&jsToken=$([System.Uri]::EscapeDataString($session.JsToken))"
                }
                $response = Invoke-TeraBoxHttp -Url $retryUrl -Headers $headers -TimeoutSec 15 -Window $Window
                $errno = Get-SafeProperty $response 'errno' $null
            }
        }

        if ($null -ne $errno -and [int]$errno -eq 0) {
            $items = @()
            $list = Get-SafeProperty $response 'list' $null
            if ($list) {
                foreach ($item in $list) {
                    $items += [ordered]@{
                        Name = [string](Get-SafeProperty $item 'server_filename' '')
                        Path = [string](Get-SafeProperty $item 'path' '')
                        Size = [int64](Get-SafeProperty $item 'size' 0)
                        IsDirectory = ((Get-SafeProperty $item 'isdir' 0) -eq 1)
                        ModTime = [int64](Get-SafeProperty $item 'server_mtime' 0)
                    }
                }
            }
            return [ordered]@{
                Success = $true
                Directory = $Directory
                ItemCount = $items.Count
                Files = $items
                Error = $null
            }
        } else {
            $errCode = if ($null -ne $errno) { [int]$errno } else { -1 }
            return [ordered]@{
                Success = $false
                Directory = $Directory
                ItemCount = 0
                Files = @()
                Error = "TeraBox directory listing failed with code $errCode"
            }
        }
    } catch {
        return [ordered]@{
            Success = $false
            Directory = $Directory
            ItemCount = 0
            Files = @()
            Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message)
        }
    }
}
