Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'ProviderContract.ps1')

function Get-ProtonDriveCredentialDirectory {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials')
}

function Get-ProtonDriveCredentialFilePath([string]$AccountId = '') {
    $dir = Get-ProtonDriveCredentialDirectory
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        $clean = ($AccountId -replace '[^a-zA-Z0-9_\-]', '_')
        return (Join-Path $dir "proton-session-$clean.xml")
    }
    return (Join-Path $dir 'proton-session.xml')
}

function Set-StrictProtonCredentialAcl([string]$Path) {
    Set-CloudCredentialAcl -Path $Path
}

function Get-ProtonDriveFieldValue([object]$Dict, [string]$Key, [object]$DefaultValue = $null) {
    return (Get-CloudProviderFieldValue $Dict $Key $DefaultValue)
}

function Get-ProtonDriveProviderInfo {
    return [ordered]@{
        Id = 'proton'
        Name = 'Proton Drive'
        Mark = 'PD'
        AccentColor = '#6D4AFF'
        AuthMethods = @(
            [ordered]@{
                Id = 'proton-credentials'
                Name = 'Proton Account Credentials'
                Description = 'Zero-knowledge end-to-end encrypted storage via Proton SRP credentials and 2FA.'
                Status = 'Official ProtonDrive Backend'
            }
        )
        SupportsOAuth = $false
        SupportsManualSession = $true
        SupportsQuota = $true
        SupportsMultipleAccounts = $true
    }
}

function Obscure-ProtonPassword([string]$PlainText, [string]$RcloneBinary = $null) {
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

function Save-ProtonDriveSession([object]$SessionData, [string]$AccountId = '') {
    if ($null -eq $SessionData) {
        throw 'Cannot store empty Proton Drive session data.'
    }
    $username = [string](Get-ProtonDriveFieldValue $SessionData 'Username' '')
    if ([string]::IsNullOrWhiteSpace($username)) {
        $username = [string](Get-ProtonDriveFieldValue $SessionData 'User' '')
    }
    if ([string]::IsNullOrWhiteSpace($username)) {
        throw 'Proton Drive session requires a valid Username or Email.'
    }

    $password = [string](Get-ProtonDriveFieldValue $SessionData 'Password' '')
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw 'Proton Drive session requires a valid Password.'
    }

    $credDir = Get-ProtonDriveCredentialDirectory
    $credPath = Get-ProtonDriveCredentialFilePath -AccountId $AccountId

    if (-not (Test-Path -LiteralPath $credDir)) {
        New-Item -ItemType Directory -Path $credDir | Out-Null
    }
    Set-StrictProtonCredentialAcl -Path $credDir

    $json = $SessionData | ConvertTo-Json -Compress
    $secString = ConvertTo-SecureString -String $json -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('proton-drive', $secString)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $credPath
        Set-StrictProtonCredentialAcl -Path $credPath
    } finally {
        $secString.Dispose()
    }
}

function Get-ProtonDriveStoredSession([string]$AccountId = '') {
    $credPath = Get-ProtonDriveCredentialFilePath -AccountId $AccountId
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

function Remove-ProtonDriveSession([string]$AccountId = '') {
    $credPath = Get-ProtonDriveCredentialFilePath -AccountId $AccountId
    if (Test-Path -LiteralPath $credPath) {
        Remove-Item -LiteralPath $credPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ProtonDriveRcloneEnvironment(
    [string]$AccountId = '',
    [string]$RemoteName = 'proton',
    [object]$SessionOverride = $null,
    [string]$RcloneBinary = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-ProtonDriveStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        throw "No Proton Drive session found for AccountId '$AccountId'."
    }

    $upperRemote = ($RemoteName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
    $envVars = [ordered]@{}

    $username = [string](Get-ProtonDriveFieldValue $session 'Username' '')
    if ([string]::IsNullOrWhiteSpace($username)) {
        $username = [string](Get-ProtonDriveFieldValue $session 'User' '')
    }
    $password = [string](Get-ProtonDriveFieldValue $session 'Password' '')
    $twoFactor = [string](Get-ProtonDriveFieldValue $session '2FA' '')
    $mailboxPass = [string](Get-ProtonDriveFieldValue $session 'MailboxPassword' '')

    $envVars["RCLONE_CONFIG_${upperRemote}_TYPE"] = 'protondrive'
    $envVars["RCLONE_CONFIG_${upperRemote}_USERNAME"] = $username

    if (-not [string]::IsNullOrEmpty($password)) {
        $obscuredPass = Obscure-ProtonPassword -PlainText $password -RcloneBinary $RcloneBinary
        $envVars["RCLONE_CONFIG_${upperRemote}_PASSWORD"] = $obscuredPass
    }

    if (-not [string]::IsNullOrEmpty($twoFactor)) {
        $envVars["RCLONE_CONFIG_${upperRemote}_2FA"] = $twoFactor
    }

    if (-not [string]::IsNullOrEmpty($mailboxPass)) {
        $obscuredMailboxPass = Obscure-ProtonPassword -PlainText $mailboxPass -RcloneBinary $RcloneBinary
        $envVars["RCLONE_CONFIG_${upperRemote}_MAILBOX_PASSWORD"] = $obscuredMailboxPass
    }

    $envVars["RCLONE_CONFIG_${upperRemote}_ENABLE_CACHING"] = 'true'
    $envVars["RCLONE_CONFIG_${upperRemote}_ORIGINAL_FILE_SIZE"] = 'true'

    return $envVars
}

function Test-ProtonDriveBackendSession(
    [string]$AccountId = '',
    [object]$SessionOverride = $null,
    [int]$TimeoutSec = 8
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-ProtonDriveStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'No Proton Drive session configured or stored for this account.'
            UserInfo = $null
            Error = 'No credentials'
        }
    }

    $username = [string](Get-ProtonDriveFieldValue $session 'Username' '')
    if ([string]::IsNullOrWhiteSpace($username)) {
        $username = [string](Get-ProtonDriveFieldValue $session 'User' '')
    }
    $password = [string](Get-ProtonDriveFieldValue $session 'Password' '')

    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'None'
            IdentityError = 'Proton Drive session missing Username or Password.'
            UserInfo = $null
            Error = 'Missing Username or Password'
        }
    }

    $rclone = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe')
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        $cmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
        if ($cmd) { $rclone = $cmd.Source }
    }

    if (-not $rclone -or -not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'protondrive'
            IdentityError = 'rclone executable not found to probe Proton Drive.'
            UserInfo = $null
            Error = 'rclone not found'
        }
    }

    $tempRemote = "proton_test_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $envVars = Get-ProtonDriveRcloneEnvironment -SessionOverride $session -RemoteName $tempRemote -RcloneBinary $rclone

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
                IdentitySource = 'protondrive'
                IdentityError = "Proton Drive authentication timed out after $TimeoutSec`s."
                UserInfo = $null
                Error = 'Authentication timed out'
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
                IdentitySource = 'protondrive'
                IdentityError = $null
                UserInfo = [ordered]@{
                    UserName = $username
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
                IdentitySource = 'protondrive'
                IdentityError = "Proton Drive authentication failed: $cleanedErr"
                UserInfo = $null
                Error = $cleanedErr
            }
        }
    } catch {
        return [ordered]@{
            IsValid = $false
            State = 'Disconnected'
            IdentityVerified = $false
            IdentitySource = 'protondrive'
            IdentityError = "Failed to execute Proton Drive probe: $($_.Exception.Message)"
            UserInfo = $null
            Error = $_.Exception.Message
        }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Get-ProtonDriveFileList(
    [string]$AccountId = '',
    [string]$Path = '',
    [object]$SessionOverride = $null
) {
    $session = if ($null -ne $SessionOverride) { $SessionOverride } else { Get-ProtonDriveStoredSession -AccountId $AccountId }
    if ($null -eq $session) {
        throw "No Proton Drive session found for AccountId '$AccountId'."
    }

    $rclone = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe')
    if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        $cmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
        if ($cmd) { $rclone = $cmd.Source }
    }

    if (-not $rclone) {
        return @()
    }

    $tempRemote = "proton_list_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $envVars = Get-ProtonDriveRcloneEnvironment -SessionOverride $session -RemoteName $tempRemote -RcloneBinary $rclone

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
