[CmdletBinding()]
param(
    [switch]$Store
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$credentialDirectory = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\credentials'
$credentialPath = Join-Path $credentialDirectory 'rclone-config.xml'
$userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')

function New-PrivateAcl([bool]$Directory) {
    if ($Directory) {
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
    } else {
        $acl = [System.Security.AccessControl.FileSecurity]::new()
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
    }

    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($userSid, $systemSid)) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    return $acl
}

if ($Store) {
    if (Test-Path -LiteralPath $credentialPath) {
        throw 'A stored unlock credential already exists. Remove it locally before storing a replacement.'
    }
    if (-not (Test-Path -LiteralPath $credentialDirectory)) {
        New-Item -ItemType Directory -Path $credentialDirectory | Out-Null
    }

    Set-Acl -LiteralPath $credentialDirectory -AclObject (New-PrivateAcl $true)
    $securePassword = Read-Host 'Enter the rclone config-encryption password (it is not echoed)' -AsSecureString
    if ($securePassword.Length -eq 0) {
        throw 'The config-encryption password cannot be empty.'
    }

    $credential = [System.Management.Automation.PSCredential]::new('rclone-config', $securePassword)
    try {
        Export-Clixml -InputObject $credential -LiteralPath $credentialPath
        Set-Acl -LiteralPath $credentialPath -AclObject (New-PrivateAcl $false)
    } catch {
        Remove-Item -LiteralPath $credentialPath -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        $securePassword.Dispose()
    }

    Write-Output 'Stored a current-user protected rclone config unlock credential.'
    exit 0
}

if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
    throw 'No local unlock credential is stored. Run this script with -Store in the signed-in Windows account.'
}

$credential = Import-Clixml -LiteralPath $credentialPath
if ($credential -isnot [System.Management.Automation.PSCredential]) {
    throw 'The stored unlock file is not a valid PowerShell credential.'
}

$bstr = [IntPtr]::Zero
try {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Console]::Out.WriteLine($plainPassword)
} finally {
    if ($bstr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $plainPassword = $null
}
