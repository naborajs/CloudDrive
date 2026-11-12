Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $script:failed++
        Write-Output "  [FAIL] $Message"
        throw $Message
    }
    Write-Output "  [PASS] $Message"
}

Write-Output '=== Testing VPS / Remote Server (SSH & SFTP) Provider ==='

# Load dependencies
. (Join-Path $repoRoot 'src\models\ConnectionState.ps1')
. (Join-Path $repoRoot 'src\providers\VpsProvider.ps1')

# Test 1: Provider Info
$info = Get-VpsProviderInfo
Assert-True ($info.Id -eq 'vps') 'Provider Id is vps'
Assert-True ($info.SupportsOAuth -eq $false) 'SupportsOAuth is false'
Assert-True ($info.SupportsManualSession -eq $true) 'SupportsManualSession is true'
Assert-True ($info.SupportsMultipleAccounts -eq $true) 'SupportsMultipleAccounts is true'
Assert-True ($info.SupportsQuota -eq $true) 'SupportsQuota is true'

# Test 2: Obscure Password
$obs = Obscure-VpsPassword -PlainText 'SuperSecret123!'
Assert-True (-not [string]::IsNullOrEmpty($obs)) 'Obscure-VpsPassword returns non-empty string'

# Test 3: Save and Load Session under DPAPI
$testAccountId = 'vps_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$sessionData = [ordered]@{
    Host = '127.0.0.1'
    Port = 2222
    User = 'agentuser'
    Password = 'SuperSecret123!'
    RemotePath = '/home/agentuser'
}

try {
    Save-VpsSession -SessionData $sessionData -AccountId $testAccountId
    $credPath = Get-VpsCredentialFilePath -AccountId $testAccountId
    Assert-True (Test-Path -LiteralPath $credPath -PathType Leaf) 'Credential file created on disk'

    # Verify DPAPI read-back
    $loaded = Get-VpsStoredSession -AccountId $testAccountId
    Assert-True ($null -ne $loaded) 'Loaded session is not null'
    Assert-True ($loaded['Host'] -eq '127.0.0.1') 'Host matches original value'
    Assert-True ($loaded['Port'] -eq 2222) 'Port matches original value'
    Assert-True ($loaded['User'] -eq 'agentuser') 'User matches original value'
    Assert-True ($loaded['Password'] -eq 'SuperSecret123!') 'Password matches original value'

    # Test 4: Rclone Environment Generation
    $envVars = Get-VpsRcloneEnvironment -AccountId $testAccountId -RemoteName 'myvps'
    Assert-True ($envVars['RCLONE_CONFIG_MYVPS_TYPE'] -eq 'sftp') 'Remote type is sftp'
    Assert-True ($envVars['RCLONE_CONFIG_MYVPS_HOST'] -eq '127.0.0.1') 'Remote host is 127.0.0.1'
    Assert-True ($envVars['RCLONE_CONFIG_MYVPS_PORT'] -eq '2222') 'Remote port is 2222'
    Assert-True ($envVars['RCLONE_CONFIG_MYVPS_USER'] -eq 'agentuser') 'Remote user is agentuser'
    Assert-True (-not [string]::IsNullOrEmpty($envVars['RCLONE_CONFIG_MYVPS_PASS'])) 'Remote pass is populated'
    Assert-True ($envVars['RCLONE_CONFIG_MYVPS_PATH_OVERRIDE'] -eq '/home/agentuser') 'Remote path override set'

    # Test 5: Key File Support in Environment Generation
    $keySession = [ordered]@{
        Host = 'vps.example.com'
        Port = 22
        User = 'root'
        KeyFile = 'C:\Users\test\.ssh\id_rsa'
        KeyPassphrase = 'KeyPass'
    }
    $keyEnv = Get-VpsRcloneEnvironment -SessionOverride $keySession -RemoteName 'keyvps'
    Assert-True ($keyEnv['RCLONE_CONFIG_KEYVPS_TYPE'] -eq 'sftp') 'Key remote type is sftp'
    Assert-True ($keyEnv['RCLONE_CONFIG_KEYVPS_KEY_FILE'] -eq 'C:\Users\test\.ssh\id_rsa') 'Key file path passed'

    # Test 6: Connectivity Probe on Unreachable Port (Fails Safe, No Crash)
    $testResult = Test-VpsBackendSession -AccountId $testAccountId -TimeoutSec 1
    Assert-True ($testResult.IsValid -eq $false) 'Unreachable port returns IsValid=false'
    Assert-True ($testResult.State -eq 'Disconnected') 'State is Disconnected'

} finally {
    Remove-VpsSession -AccountId $testAccountId
    Assert-True (-not (Test-Path -LiteralPath (Get-VpsCredentialFilePath -AccountId $testAccountId))) 'Session removed from disk'
}

if ($failed -gt 0) {
    throw "$failed VPS provider tests failed."
}
Write-Output '  [PASS] All VPS Provider tests completed successfully.'
