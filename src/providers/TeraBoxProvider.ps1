Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

function Get-TeraBoxCredentialDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials')
}

function Get-TeraBoxCredentialFilePath {
    return (Join-Path (Get-TeraBoxCredentialDirectory) 'terabox-session.xml')
}

$script:TeraBoxWebUrl = 'https://www.terabox.com/'
$script:TeraBoxAppId = '250528'

function Set-StrictTeraBoxCredentialAcl([string]$Path) {
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

function Get-TeraBoxStoredSession {
    $credPath = Get-TeraBoxCredentialFilePath
    if (-not (Test-Path -LiteralPath $credPath -PathType Leaf)) {
        return $null
    }

    try {
        $cred = Import-Clixml -LiteralPath $credPath
        if ($cred -is [System.Management.Automation.PSCredential]) {
            $bstr = [IntPtr]::Zero
            try {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                return [ordered]@{
                    Type = $cred.UserName
                    Secret = $secret
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

function Save-TeraBoxSession([string]$Type, [string]$Secret) {
    if ([string]::IsNullOrEmpty($Secret)) {
        throw 'Cannot store empty TeraBox session secret.'
    }

    $credDir = Get-TeraBoxCredentialDirectory
    $credPath = Get-TeraBoxCredentialFilePath

    if (-not (Test-Path -LiteralPath $credDir)) {
        New-Item -ItemType Directory -Path $credDir | Out-Null
        Set-StrictTeraBoxCredentialAcl -Path $credDir
    }

    $secString = ConvertTo-SecureString -String $Secret -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new($Type, $secString)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $credPath
        Set-StrictTeraBoxCredentialAcl -Path $credPath
    } finally {
        $secString.Dispose()
    }
}

function Remove-TeraBoxSession {
    $credPath = Get-TeraBoxCredentialFilePath
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-TeraBoxBackendSession([hashtable]$SessionOverride = $null) {
    $session = if ($SessionOverride) { $SessionOverride } else { Get-TeraBoxStoredSession }
    if (-not $session) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            Error = 'No local TeraBox session or credentials found. Please sign in.'
            UserInfo = $null
        }
    }

    try {
        $headers = @{
            'Accept' = 'application/json, text/plain, */*'
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) NSCloudDrive/1.0'
        }

        $checkUrl = ''
        if ($session.Type -eq 'open-api') {
            $checkUrl = "https://www.terabox.com/openapi/uinfo?access_tokens=$([System.Uri]::EscapeDataString($session.Secret))"
        } else {
            # Web session
            $headers['Referer'] = 'https://www.terabox.com/'
            $headers['X-Requested-With'] = 'XMLHttpRequest'
            $headers['Cookie'] = "ndus=$($session.Secret)"
            $checkUrl = "https://www.terabox.com/api/check/login?app_id=$script:TeraBoxAppId&channel=dubox&clienttype=0&web=1"
        }

        $response = Invoke-RestMethod -Uri $checkUrl -Headers $headers -Method Get -TimeoutSec 15 -ErrorAction Stop

        if ($response -and $response.errno -eq 0) {
            return [ordered]@{
                IsValid = $true
                State = 'Connected'
                Error = $null
                UserInfo = [ordered]@{
                    Type = $session.Type
                    UserName = $(if ($response.username) { $response.username } else { 'TeraBox User' })
                    Uk = $response.uk
                }
            }
        } else {
            $errno = if ($response.errno) { $response.errno } else { -1 }
            return [ordered]@{
                IsValid = $false
                State = 'AuthenticationExpired'
                Error = "TeraBox backend returned error code: $errno (Session may have expired or requires re-authentication)."
                UserInfo = $null
            }
        }
    } catch {
        $sanitizedError = Format-SanitizedDiagnosticMessage $_.Exception.Message
        return [ordered]@{
            IsValid = $false
            State = 'Error'
            Error = "Backend validation request failed: $sanitizedError"
            UserInfo = $null
        }
    }
}

function Test-TeraBoxAccountScope([hashtable]$SessionOverride = $null) {
    $validation = Test-TeraBoxBackendSession -SessionOverride $SessionOverride
    if (-not $validation.IsValid) {
        return [ordered]@{
            ScopeVerified = $false
            Scope = 'Unknown'
            Error = $validation.Error
        }
    }

    $session = if ($SessionOverride) { $SessionOverride } else { Get-TeraBoxStoredSession }
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

function Get-TeraBoxFileList([string]$Directory = '/', [hashtable]$SessionOverride = $null) {
    $scopeInfo = Test-TeraBoxAccountScope -SessionOverride $SessionOverride
    if (-not $scopeInfo.ScopeVerified) {
        return [ordered]@{
            Success = $false
            Files = @()
            Error = $scopeInfo.Error
        }
    }

    $session = if ($SessionOverride) { $SessionOverride } else { Get-TeraBoxStoredSession }
    try {
        $headers = @{
            'Accept' = 'application/json, text/plain, */*'
            'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) NSCloudDrive/1.0'
        }

        $listUrl = ''
        if ($session.Type -eq 'open-api') {
            $dirParam = [System.Uri]::EscapeDataString($Directory)
            $tokenParam = [System.Uri]::EscapeDataString($session.Secret)
            $listUrl = "https://www.terabox.com/openapi/api/list?dir=$dirParam&access_tokens=$tokenParam&page=1&num=100"
        } else {
            $headers['Referer'] = 'https://www.terabox.com/'
            $headers['X-Requested-With'] = 'XMLHttpRequest'
            $headers['Cookie'] = "ndus=$($session.Secret)"
            $dirParam = [System.Uri]::EscapeDataString($Directory)
            $listUrl = "https://www.terabox.com/api/list?app_id=$script:TeraBoxAppId&channel=dubox&clienttype=0&web=1&dir=$dirParam&page=1&num=100"
        }

        $response = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method Get -TimeoutSec 15 -ErrorAction Stop

        if ($response -and $response.errno -eq 0) {
            $items = @()
            if ($response.list) {
                foreach ($item in $response.list) {
                    $items += [ordered]@{
                        Name = $item.server_filename
                        Path = $item.path
                        Size = $item.size
                        IsDirectory = ($item.isdir -eq 1)
                        ModTime = $item.server_mtime
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
            return [ordered]@{
                Success = $false
                Files = @()
                Error = "TeraBox directory listing failed with code $($response.errno)"
            }
        }
    } catch {
        return [ordered]@{
            Success = $false
            Files = @()
            Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message)
        }
    }
}
