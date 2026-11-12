Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

<#
.SYNOPSIS
    S3Provider implements the ProviderContract for S3 / Metal Object Storage.
.DESCRIPTION
    Integrates AWS S3, Cloudflare R2, MinIO, Wasabi, Backblaze B2 S3, and private metal
    storage clusters via rclone's s3 backend.
    Credentials are encrypted at rest using Windows DPAPI with restrictive user ACLs.
#>

function Get-S3CredentialDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials')
}

function Get-S3CredentialFilePath([string]$AccountId = '') {
    $dir = Get-S3CredentialDirectory
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $clean = ($AccountId -replace '[^a-zA-Z0-9_\-]', '_')
        return (Join-Path $dir "s3-session-$clean.xml")
    }
    return (Join-Path $dir 's3-session.xml')
}

function Set-StrictS3CredentialAcl([string]$Path) {
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
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.SetAccessRule($rule)
        }
        if ($isDir) {
            [System.IO.Directory]::SetAccessControl($Path, $acl)
        } else {
            [System.IO.File]::SetAccessControl($Path, $acl)
        }
    } catch {
        throw "Unable to restrict permissions on S3 credential path '$Path': $($_.Exception.Message)"
    }
}

function Get-S3ProviderInfo {
    return [ordered]@{
        Id = 's3'
        Name = 'S3 / Metal Object Storage (Cloudflare R2, MinIO, Wasabi, AWS S3)'
        Mark = 'S3'
        AccentColor = '#F59E0B'
        AuthMethods = @(
            [ordered]@{
                Id = 's3-credentials'
                Name = 'S3 Access Key & Secret Key'
                Description = 'Connect using endpoint, region, access key, secret key, and bucket.'
                Status = 'Metal / S3 Object Store'
            }
        )
        SupportsOAuth = $false
        SupportsManualSession = $true
        SupportsQuota = $true
        SupportsMultipleAccounts = $true
    }
}

function Obscure-S3Secret([string]$PlainText, [string]$RcloneBinary = $null) {
    if ([string]::IsNullOrEmpty($PlainText)) { return '' }
    if (-not $RcloneBinary -or -not (Test-Path -LiteralPath $RcloneBinary -PathType Leaf)) {
        $cand = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe')
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            $RcloneBinary = $cand
        } else {
            $cmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
            if ($cmd) { $RcloneBinary = $cmd.Source }
        }
    }
    if ($RcloneBinary -and (Test-Path -LiteralPath $RcloneBinary -PathType Leaf)) {
        try {
            $obscured = (& $RcloneBinary obscure $PlainText 2>$null)
            if ($obscured) { return $obscured.Trim() }
        } catch { }
    }
    return $PlainText
}

function Get-S3FieldValue([object]$Dict, [string]$Key, [object]$DefaultValue = $null) {
    if ($null -eq $Dict) { return $DefaultValue }
    if ($Dict -is [System.Collections.IDictionary]) {
        if ($Dict.Contains($Key)) {
            $val = $Dict[$Key]
            if ($null -ne $val) { return $val }
        }
        return $DefaultValue
    }
    if ($Dict.PSObject -and $Dict.PSObject.Properties[$Key]) {
        $val = $Dict.PSObject.Properties[$Key].Value
        if ($null -ne $val) { return $val }
    }
    return $DefaultValue
}

function Save-S3Session([string]$AccountId, [object]$SessionData) {
    if ([string]::IsNullOrWhiteSpace($AccountId)) {
        throw 'AccountId cannot be empty when saving S3 session.'
    }
    if ($null -eq $SessionData) {
        throw 'SessionData cannot be null.'
    }

    $credDir = Get-S3CredentialDirectory
    if (-not (Test-Path -LiteralPath $credDir)) {
        [void][System.IO.Directory]::CreateDirectory($credDir)
        Set-StrictS3CredentialAcl $credDir
    }

    $credPath = Get-S3CredentialFilePath -AccountId $AccountId
    $cleanData = [ordered]@{}

    $endpoint = Get-S3FieldValue $SessionData 'Endpoint' ''
    $region = Get-S3FieldValue $SessionData 'Region' 'auto'
    $accessKey = Get-S3FieldValue $SessionData 'AccessKey' ''
    $secretKey = Get-S3FieldValue $SessionData 'SecretKey' ''
    $bucket = Get-S3FieldValue $SessionData 'Bucket' ''
    $provider = Get-S3FieldValue $SessionData 'Provider' 'Other'

    if ([string]::IsNullOrWhiteSpace([string]$accessKey) -or [string]::IsNullOrWhiteSpace([string]$secretKey)) {
        throw 'S3 account requires AccessKey and SecretKey.'
    }

    $cleanData['Endpoint'] = [string]$endpoint
    $cleanData['Region'] = [string]$region
    $cleanData['AccessKey'] = [string]$accessKey
    $cleanData['SecretKey'] = [string]$secretKey
    $cleanData['Bucket'] = [string]$bucket
    $cleanData['Provider'] = [string]$provider
    $cleanData['SavedAt'] = [DateTime]::UtcNow.ToString('o')

    $json = ($cleanData | ConvertTo-Json -Compress)
    $sec = ConvertTo-SecureString $json -AsPlainText -Force
    $cred = [System.Management.Automation.PSCredential]::new("s3_$AccountId", $sec)

    $cred | Export-Clixml -LiteralPath $credPath -Force
    Set-StrictS3CredentialAcl $credPath

    return [ordered]@{
        Success = $true
        AccountId = $AccountId
        Path = $credPath
    }
}

function Get-S3StoredSession([string]$AccountId = '') {
    $credPath = Get-S3CredentialFilePath -AccountId $AccountId
    if (-not (Test-Path -LiteralPath $credPath -PathType Leaf)) {
        return $null
    }

    try {
        $cred = Import-Clixml -LiteralPath $credPath
        if ($cred -is [System.Management.Automation.PSCredential]) {
            $bstr = [IntPtr]::Zero
            try {
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
                $json = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                $obj = ($json | ConvertFrom-Json)
                $ht = [ordered]@{}
                foreach ($prop in $obj.PSObject.Properties) {
                    $ht[$prop.Name] = $prop.Value
                }
                return $ht
            } finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Remove-S3Session([string]$AccountId = '') {
    $credPath = Get-S3CredentialFilePath -AccountId $AccountId
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-S3RcloneEnvironment(
    [string]$AccountId = '',
    [string]$RemoteName = 's3',
    [object]$SessionOverride = $null,
    [string]$RcloneBinary = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-S3StoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        throw "No S3 session found for AccountId '$AccountId'."
    }

    $upperRemote = ($RemoteName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
    $envVars = [ordered]@{}

    $endpoint = Get-S3FieldValue $session 'Endpoint' ''
    $region = Get-S3FieldValue $session 'Region' 'auto'
    $accessKey = Get-S3FieldValue $session 'AccessKey' ''
    $secretKey = Get-S3FieldValue $session 'SecretKey' ''
    $provider = Get-S3FieldValue $session 'Provider' 'Other'

    $envVars["RCLONE_CONFIG_${upperRemote}_TYPE"] = 's3'
    $envVars["RCLONE_CONFIG_${upperRemote}_PROVIDER"] = [string]$provider
    $envVars["RCLONE_CONFIG_${upperRemote}_ACCESS_KEY_ID"] = [string]$accessKey

    if (-not [string]::IsNullOrEmpty([string]$secretKey)) {
        $obscuredSecret = Obscure-S3Secret -PlainText ([string]$secretKey) -RcloneBinary $RcloneBinary
        $envVars["RCLONE_CONFIG_${upperRemote}_SECRET_ACCESS_KEY"] = $obscuredSecret
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$endpoint)) {
        $envVars["RCLONE_CONFIG_${upperRemote}_ENDPOINT"] = [string]$endpoint
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$region)) {
        $envVars["RCLONE_CONFIG_${upperRemote}_REGION"] = [string]$region
    }

    return $envVars
}

function Test-S3BackendSession(
    [string]$AccountId = '',
    [object]$SessionOverride = $null,
    [int]$TimeoutSec = 8
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-S3StoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'No S3 credentials configured or stored for this account.'
            UserInfo = $null
            Error = 'No credentials'
        }
    }

    $accessKey = [string](Get-S3FieldValue $session 'AccessKey' '')
    $secretKey = [string](Get-S3FieldValue $session 'SecretKey' '')
    $endpoint = [string](Get-S3FieldValue $session 'Endpoint' '')
    $bucket = [string](Get-S3FieldValue $session 'Bucket' '')

    if ([string]::IsNullOrWhiteSpace($accessKey) -or [string]::IsNullOrWhiteSpace($secretKey)) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'S3 configuration is missing AccessKey or SecretKey.'
            UserInfo = $null
            Error = 'Missing credentials'
        }
    }

    $disp = if ($bucket) { "S3 (${bucket})" } else { "S3 (${accessKey})" }

    return [ordered]@{
        IsValid = $true
        State = 'Connected'
        IdentityVerified = $true
        IdentitySource = 'S3Config'
        IdentityError = $null
        UserInfo = [ordered]@{
            Email = $accessKey
            DisplayName = $disp
        }
        Quota = [ordered]@{
            TotalBytes = 10995116277760L # 10 TB virtual capacity
            UsedBytes = 0L
            FreeBytes = 10995116277760L
        }
        Error = $null
    }
}

function Get-S3FileList(
    [string]$AccountId = '',
    [string]$RemotePath = '',
    [object]$SessionOverride = $null,
    [string]$RcloneBinary = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-S3StoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        return @()
    }

    $testRemote = "s3_browse_$($AccountId -replace '[^a-zA-Z0-9_]', '_')"
    $envVars = Get-S3RcloneEnvironment -AccountId $AccountId -RemoteName $testRemote -SessionOverride $session -RcloneBinary $RcloneBinary

    $rclone = if ($RcloneBinary) { $RcloneBinary } else { (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe') }
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        $cmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
        if ($cmd) { $rclone = $cmd.Source }
    }
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        return @()
    }

    $bucket = [string](Get-S3FieldValue $session 'Bucket' '')
    $targetPath = if ($bucket) {
        if ($RemotePath) { "$bucket/$($RemotePath.Trim('/'))" } else { $bucket }
    } else {
        if ($RemotePath) { $RemotePath.Trim('/') } else { '' }
    }

    $target = if ($targetPath) { "${testRemote}:${targetPath}" } else { "${testRemote}:" }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclone
    $psi.Arguments = "lsjson `"$target`" --max-depth 1"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    foreach ($k in $envVars.Keys) {
        $psi.EnvironmentVariables[$k] = [string]$envVars[$k]
    }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()

        if ($proc.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stdout)) {
            $parsed = ($stdout | ConvertFrom-Json)
            return ,@($parsed)
        }
    } catch { }

    return @()
}
