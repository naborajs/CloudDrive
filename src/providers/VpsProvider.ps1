Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

function Get-VpsCredentialDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials')
}

function Get-VpsCredentialFilePath([string]$AccountId = '') {
    $dir = Get-VpsCredentialDirectory
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $clean = ($AccountId -replace '[^a-zA-Z0-9_\-]', '_')
        return (Join-Path $dir "vps-session-$clean.xml")
    }
    return (Join-Path $dir 'vps-session.xml')
}

function Set-StrictVpsCredentialAcl([string]$Path) {
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
        throw "Unable to restrict permissions on VPS credential path '$Path': $($_.Exception.Message)"
    }
}

function Get-VpsProviderInfo {
    return [ordered]@{
        Id = 'vps'
        Name = 'VPS / Remote Server (SSH & SFTP)'
        Mark = 'VP'
        AccentColor = '#6366F1'
        AuthMethods = @(
            [ordered]@{
                Id = 'ssh-password'
                Name = 'SSH Password Authentication'
                Description = 'Connect using SSH host, port, username, and password.'
                Status = 'Standard SSH/SFTP'
            },
            [ordered]@{
                Id = 'ssh-key'
                Name = 'SSH Private Key Authentication'
                Description = 'Connect using PEM/OpenSSH private key file or inline key.'
                Status = 'Public Key Cryptography'
            }
        )
        SupportsOAuth = $false
        SupportsManualSession = $true
        SupportsQuota = $true
        SupportsMultipleAccounts = $true
    }
}

function Obscure-VpsPassword([string]$PlainText, [string]$RcloneBinary = $null) {
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

function Get-VpsFieldValue([object]$Dict, [string]$Key, [object]$DefaultValue = $null) {
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

function Save-VpsSession([object]$SessionData, [string]$AccountId = '') {
    if ($null -eq $SessionData) {
        throw 'Cannot store empty VPS session data.'
    }
    $hostVal = Get-VpsFieldValue $SessionData 'Host' ''
    if ([string]::IsNullOrWhiteSpace([string]$hostVal)) {
        throw 'VPS session requires a valid Host address.'
    }
    $userVal = Get-VpsFieldValue $SessionData 'User' ''
    if ([string]::IsNullOrWhiteSpace([string]$userVal)) {
        throw 'VPS session requires a valid User.'
    }

    $credDir = Get-VpsCredentialDirectory
    $credPath = Get-VpsCredentialFilePath -AccountId $AccountId

    if (-not (Test-Path -LiteralPath $credDir)) {
        New-Item -ItemType Directory -Path $credDir | Out-Null
    }
    Set-StrictVpsCredentialAcl -Path $credDir

    $json = $SessionData | ConvertTo-Json -Compress
    $secString = ConvertTo-SecureString -String $json -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('vps-sftp', $secString)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $credPath
        Set-StrictVpsCredentialAcl -Path $credPath
    } finally {
        $secString.Dispose()
    }
}

function Get-VpsStoredSession([string]$AccountId = '') {
    $credPath = Get-VpsCredentialFilePath -AccountId $AccountId
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

function Remove-VpsSession([string]$AccountId = '') {
    $credPath = Get-VpsCredentialFilePath -AccountId $AccountId
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-VpsRcloneEnvironment(
    [string]$AccountId = '',
    [string]$RemoteName = 'vps',
    [object]$SessionOverride = $null,
    [string]$RcloneBinary = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-VpsStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        throw "No VPS session found for AccountId '$AccountId'."
    }

    $upperRemote = ($RemoteName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
    $envVars = [ordered]@{}

    $hostVal = Get-VpsFieldValue $session 'Host' ''
    $userVal = Get-VpsFieldValue $session 'User' ''
    $portVal = Get-VpsFieldValue $session 'Port' 22
    $passVal = Get-VpsFieldValue $session 'Password' ''
    $keyFileVal = Get-VpsFieldValue $session 'KeyFile' ''
    $keyPemVal = Get-VpsFieldValue $session 'KeyPem' ''
    $keyPassVal = Get-VpsFieldValue $session 'KeyPassphrase' ''
    $remotePathVal = Get-VpsFieldValue $session 'RemotePath' ''

    $envVars["RCLONE_CONFIG_${upperRemote}_TYPE"] = 'sftp'
    $envVars["RCLONE_CONFIG_${upperRemote}_HOST"] = [string]$hostVal
    
    $port = 22
    $parsedPort = 0
    if ([int]::TryParse([string]$portVal, [ref]$parsedPort) -and $parsedPort -gt 0) {
        $port = $parsedPort
    }
    $envVars["RCLONE_CONFIG_${upperRemote}_PORT"] = [string]$port
    $envVars["RCLONE_CONFIG_${upperRemote}_USER"] = [string]$userVal

    if (-not [string]::IsNullOrEmpty([string]$passVal)) {
        $obscuredPass = Obscure-VpsPassword -PlainText ([string]$passVal) -RcloneBinary $RcloneBinary
        $envVars["RCLONE_CONFIG_${upperRemote}_PASS"] = $obscuredPass
    }

    if (-not [string]::IsNullOrEmpty([string]$keyFileVal)) {
        $envVars["RCLONE_CONFIG_${upperRemote}_KEY_FILE"] = [string]$keyFileVal
    }

    if (-not [string]::IsNullOrEmpty([string]$keyPemVal)) {
        $envVars["RCLONE_CONFIG_${upperRemote}_KEY_PEM"] = [string]$keyPemVal
    }

    if (-not [string]::IsNullOrEmpty([string]$keyPassVal)) {
        $obscuredKeyPass = Obscure-VpsPassword -PlainText ([string]$keyPassVal) -RcloneBinary $RcloneBinary
        $envVars["RCLONE_CONFIG_${upperRemote}_KEY_FILE_PASS"] = $obscuredKeyPass
    }

    if (-not [string]::IsNullOrEmpty([string]$remotePathVal)) {
        $envVars["RCLONE_CONFIG_${upperRemote}_PATH_OVERRIDE"] = [string]$remotePathVal
    }

    # Disable interactive password prompt in child processes
    $envVars["RCLONE_CONFIG_${upperRemote}_ASK_PASSWORD"] = 'false'
    $envVars["RCLONE_CONFIG_${upperRemote}_PIN_HOST_KEY"] = 'true'

    return $envVars
}

function Test-VpsBackendSession(
    [string]$AccountId = '',
    [object]$SessionOverride = $null,
    [int]$TimeoutSec = 8
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-VpsStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'No VPS session configured or stored for this account.'
            UserInfo = $null
            Error = 'No credentials'
        }
    }

    $hostName = [string](Get-VpsFieldValue $session 'Host' '')
    $userName = [string](Get-VpsFieldValue $session 'User' '')
    $port = [int](Get-VpsFieldValue $session 'Port' 22)
    $remotePath = [string](Get-VpsFieldValue $session 'RemotePath' '/')

    if ([string]::IsNullOrWhiteSpace($hostName) -or [string]::IsNullOrWhiteSpace($userName)) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'VPS configuration is missing Host or User.'
            UserInfo = $null
            Error = 'Missing Host or User'
        }
    }

    # Locate rclone to execute remote connectivity probe
    $rclone = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe')
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        $cmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
        if ($cmd) { $rclone = $cmd.Source }
    }

    if (-not $rclone -or -not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        # Fallback if rclone is not present: TCP socket ping to SSH port
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $connectTask = $tcp.ConnectAsync($hostName, $port)
            $completed = $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSec))
            if ($completed -and $tcp.Connected) {
                $tcp.Close()
                return [ordered]@{
                    IsValid = $true
                    State = 'Connected'
                    IdentityVerified = $true
                    IdentitySource = 'SSH-TCP'
                    IdentityError = $null
                    UserInfo = [ordered]@{
                        UserName = "$userName@$hostName"
                        Host = $hostName
                        Port = $port
                        RemotePath = $remotePath
                        TotalSpace = 0L
                        UsedSpace = 0L
                        FreeSpace = 0L
                    }
                    Error = $null
                }
            } else {
                $tcp.Close()
                return [ordered]@{
                    IsValid = $false
                    State = 'Disconnected'
                    IdentityVerified = $false
                    IdentitySource = 'SSH-TCP'
                    IdentityError = "Connection to $hostName`:$port timed out after $TimeoutSec seconds."
                    UserInfo = $null
                    Error = "Connection timed out"
                }
            }
        } catch {
            return [ordered]@{
                IsValid = $false
                State = 'Disconnected'
                IdentityVerified = $false
                IdentitySource = 'SSH-TCP'
                IdentityError = "SSH port $hostName`:$port unreachable: $($_.Exception.Message)"
                UserInfo = $null
                Error = $_.Exception.Message
            }
        }
    }

    # Rclone probe via ephemeral test remote
    $tempRemote = "vps_test_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $envVars = Get-VpsRcloneEnvironment -SessionOverride $session -RemoteName $tempRemote -RcloneBinary $rclone

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclone
    $psi.Arguments = "about ${tempRemote}: --json --timeout ${TimeoutSec}s --contimeout ${TimeoutSec}s"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($k in $envVars.Keys) {
        $psi.EnvironmentVariables[[string]$k] = [string]$envVars[$k]
    }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            return [ordered]@{
                IsValid = $false
                State = 'Disconnected'
                IdentityVerified = $false
                IdentitySource = 'rclone-sftp'
                IdentityError = "SSH connection to $hostName`:$port timed out after $TimeoutSec`s."
                UserInfo = $null
                Error = 'Connection timed out'
            }
        }

        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result

        if ($proc.ExitCode -eq 0) {
            $totalSpace = 0L
            $usedSpace = 0L
            $freeSpace = 0L
            if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                try {
                    $json = $stdout | ConvertFrom-Json
                    if ($json.PSObject.Properties['total']) { $totalSpace = [long]$json.total }
                    if ($json.PSObject.Properties['used']) { $usedSpace = [long]$json.used }
                    if ($json.PSObject.Properties['free']) { $freeSpace = [long]$json.free }
                } catch { }
            }

            return [ordered]@{
                IsValid = $true
                State = 'Connected'
                IdentityVerified = $true
                IdentitySource = 'rclone-sftp'
                IdentityError = $null
                UserInfo = [ordered]@{
                    UserName = "$userName@$hostName"
                    Host = $hostName
                    Port = $port
                    RemotePath = $remotePath
                    TotalSpace = $totalSpace
                    UsedSpace = $usedSpace
                    FreeSpace = $freeSpace
                }
                Error = $null
            }
        } else {
            $cleanedErr = if ($stderr) { ($stderr -replace '(?i)(pass|password)=.+', '$1=***').Trim() } else { "Process exited with code $($proc.ExitCode)" }
            return [ordered]@{
                IsValid = $false
                State = 'Disconnected'
                IdentityVerified = $false
                IdentitySource = 'rclone-sftp'
                IdentityError = "SSH/SFTP authentication failed on $hostName`:$port - $cleanedErr"
                UserInfo = $null
                Error = $cleanedErr
            }
        }
    } catch {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'rclone-sftp'
            IdentityError = "Failed to execute SSH probe: $($_.Exception.Message)"
            UserInfo = $null
            Error = $_.Exception.Message
        }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Get-VpsFileList(
    [string]$AccountId = '',
    [string]$Path = '',
    [object]$SessionOverride = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-VpsStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        throw "No VPS session found for AccountId '$AccountId'."
    }

    $rclone = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe')
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        $cmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
        if ($cmd) { $rclone = $cmd.Source }
    }

    if (-not $rclone) {
        return @()
    }

    $tempRemote = "vps_list_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $envVars = Get-VpsRcloneEnvironment -SessionOverride $session -RemoteName $tempRemote -RcloneBinary $rclone

    $targetPath = if ([string]::IsNullOrWhiteSpace($Path)) { "${tempRemote}:" } else { "${tempRemote}:$Path" }
    
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclone
    $psi.Arguments = "lsjson `"$targetPath`" --max-depth 1"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($k in $envVars.Keys) {
        $psi.EnvironmentVariables[[string]$k] = [string]$envVars[$k]
    }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit(15000) | Out-Null
        if ($proc.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stdout)) {
            return @($stdout | ConvertFrom-Json)
        }
    } catch { }
    finally {
        if ($proc) { $proc.Dispose() }
    }

    return @()
}
