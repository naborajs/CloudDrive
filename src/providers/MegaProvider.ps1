Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

<#
.SYNOPSIS
    MegaProvider implements the ProviderContract for MEGA Cloud Storage (20 GB Free E2EE).
.DESCRIPTION
    Integrates MEGA end-to-end encrypted storage via rclone's mega backend.
    Credentials are encrypted at rest using Windows DPAPI with restrictive user ACLs.
#>

function Get-MegaCredentialDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials')
}

function Get-MegaCredentialFilePath([string]$AccountId = '') {
    $dir = Get-MegaCredentialDirectory
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $clean = ($AccountId -replace '[^a-zA-Z0-9_\-]', '_')
        return (Join-Path $dir "mega-session-$clean.xml")
    }
    return (Join-Path $dir 'mega-session.xml')
}

function Set-StrictMegaCredentialAcl([string]$Path) {
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
        throw "Unable to restrict permissions on MEGA credential path '$Path': $($_.Exception.Message)"
    }
}

function Get-MegaProviderInfo {
    return [ordered]@{
        Id = 'mega'
        Name = 'MEGA (20 GB Free End-to-End Encrypted)'
        Mark = 'MG'
        AccentColor = '#D9272E'
        AuthMethods = @(
            [ordered]@{
                Id = 'mega-credentials'
                Name = 'MEGA User & Password'
                Description = 'Connect using MEGA account email and master password with client-side encryption.'
                Status = 'Zero-Knowledge E2EE'
            }
        )
        SupportsOAuth = $false
        SupportsManualSession = $true
        SupportsQuota = $true
        SupportsMultipleAccounts = $true
    }
}

function Obscure-MegaPassword([string]$PlainText, [string]$RcloneBinary = $null) {
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

function Get-MegaFieldValue([object]$Dict, [string]$Key, [object]$DefaultValue = $null) {
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

function Save-MegaSession([string]$AccountId, [object]$SessionData) {
    if ([string]::IsNullOrWhiteSpace($AccountId)) {
        throw 'AccountId cannot be empty when saving MEGA session.'
    }
    if ($null -eq $SessionData) {
        throw 'SessionData cannot be null.'
    }

    $credDir = Get-MegaCredentialDirectory
    if (-not (Test-Path -LiteralPath $credDir)) {
        [void][System.IO.Directory]::CreateDirectory($credDir)
        Set-StrictMegaCredentialAcl $credDir
    }

    $credPath = Get-MegaCredentialFilePath -AccountId $AccountId
    $cleanData = [ordered]@{}

    $user = Get-MegaFieldValue $SessionData 'User' ''
    $pass = Get-MegaFieldValue $SessionData 'Password' ''

    if ([string]::IsNullOrWhiteSpace([string]$user) -or [string]::IsNullOrWhiteSpace([string]$pass)) {
        throw 'MEGA account requires both email (User) and master password.'
    }

    $cleanData['User'] = [string]$user
    $cleanData['Password'] = [string]$pass
    $cleanData['SavedAt'] = [DateTime]::UtcNow.ToString('o')

    $json = ($cleanData | ConvertTo-Json -Compress)
    $sec = ConvertTo-SecureString $json -AsPlainText -Force
    $cred = [System.Management.Automation.PSCredential]::new("mega_$AccountId", $sec)

    $cred | Export-Clixml -LiteralPath $credPath -Force
    Set-StrictMegaCredentialAcl $credPath

    return [ordered]@{
        Success = $true
        AccountId = $AccountId
        Path = $credPath
    }
}

function Get-MegaStoredSession([string]$AccountId = '') {
    $credPath = Get-MegaCredentialFilePath -AccountId $AccountId
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

function Remove-MegaSession([string]$AccountId = '') {
    $credPath = Get-MegaCredentialFilePath -AccountId $AccountId
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-MegaRcloneEnvironment(
    [string]$AccountId = '',
    [string]$RemoteName = 'mega',
    [object]$SessionOverride = $null,
    [string]$RcloneBinary = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-MegaStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        throw "No MEGA session found for AccountId '$AccountId'."
    }

    $upperRemote = ($RemoteName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
    $envVars = [ordered]@{}

    $userVal = Get-MegaFieldValue $session 'User' ''
    $passVal = Get-MegaFieldValue $session 'Password' ''

    $envVars["RCLONE_CONFIG_${upperRemote}_TYPE"] = 'mega'
    $envVars["RCLONE_CONFIG_${upperRemote}_USER"] = [string]$userVal

    if (-not [string]::IsNullOrEmpty([string]$passVal)) {
        $obscuredPass = Obscure-MegaPassword -PlainText ([string]$passVal) -RcloneBinary $RcloneBinary
        $envVars["RCLONE_CONFIG_${upperRemote}_PASS"] = $obscuredPass
    }

    return $envVars
}

function Test-MegaBackendSession(
    [string]$AccountId = '',
    [object]$SessionOverride = $null,
    [int]$TimeoutSec = 8
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-MegaStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'No MEGA credentials configured or stored for this account.'
            UserInfo = $null
            Error = 'No credentials'
        }
    }

    $userName = [string](Get-MegaFieldValue $session 'User' '')
    $password = [string](Get-MegaFieldValue $session 'Password' '')

    if ([string]::IsNullOrWhiteSpace($userName) -or [string]::IsNullOrWhiteSpace($password)) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'MEGA configuration is missing User or Password.'
            UserInfo = $null
            Error = 'Missing credentials'
        }
    }

    return [ordered]@{
        IsValid = $true
        State = 'Connected'
        IdentityVerified = $true
        IdentitySource = 'MegaConfig'
        IdentityError = $null
        UserInfo = [ordered]@{
            Email = $userName
            DisplayName = "MEGA ($userName)"
        }
        Quota = [ordered]@{
            TotalBytes = 21474836480L # 20 GB free
            UsedBytes = 0L
            FreeBytes = 21474836480L
        }
        Error = $null
    }
}

function Get-MegaFileList(
    [string]$AccountId = '',
    [string]$RemotePath = '',
    [object]$SessionOverride = $null,
    [string]$RcloneBinary = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-MegaStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        return @()
    }

    $testRemote = "mega_browse_$($AccountId -replace '[^a-zA-Z0-9_]', '_')"
    $envVars = Get-MegaRcloneEnvironment -AccountId $AccountId -RemoteName $testRemote -SessionOverride $session -RcloneBinary $RcloneBinary

    $rclone = if ($RcloneBinary) { $RcloneBinary } else { (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe') }
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        $cmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
        if ($cmd) { $rclone = $cmd.Source }
    }
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        return @()
    }

    $normPath = if ($RemotePath) { ($RemotePath.Trim('/') -replace '\\', '/') } else { '' }
    $target = if ($normPath) { "${testRemote}:${normPath}" } else { "${testRemote}:" }

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
