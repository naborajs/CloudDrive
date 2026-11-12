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

Write-Output '=== Testing Proton Drive Provider ==='

# Load dependencies
. (Join-Path $repoRoot 'src\models\ConnectionState.ps1')
. (Join-Path $repoRoot 'src\providers\ProtonDriveProvider.ps1')

# Test 1: Provider Info
$info = Get-ProtonDriveProviderInfo
Assert-True ($info.Id -eq 'proton') 'Provider Id is proton'
Assert-True ($info.SupportsOAuth -eq $false) 'SupportsOAuth is false'
Assert-True ($info.SupportsManualSession -eq $true) 'SupportsManualSession is true'
Assert-True ($info.SupportsMultipleAccounts -eq $true) 'SupportsMultipleAccounts is true'
Assert-True ($info.SupportsQuota -eq $true) 'SupportsQuota is true'

# Test 2: Obscure Password
$obs = Obscure-ProtonPassword -PlainText 'ProtonPass123!'
Assert-True (-not [string]::IsNullOrEmpty($obs)) 'Obscure-ProtonPassword returns non-empty string'

# Test 3: Save and Load Session under DPAPI
$testAccountId = 'proton_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$sessionData = [ordered]@{
    Username = 'user@proton.me'
    Password = 'ProtonPass123!'
    '2FA' = '123456'
    MailboxPassword = 'MailboxSecret!'
}

try {
    Save-ProtonDriveSession -SessionData $sessionData -AccountId $testAccountId
    $credPath = Get-ProtonDriveCredentialFilePath -AccountId $testAccountId
    Assert-True (Test-Path -LiteralPath $credPath -PathType Leaf) 'Credential file created on disk'

    # Verify DPAPI read-back
    $loaded = Get-ProtonDriveStoredSession -AccountId $testAccountId
    Assert-True ($null -ne $loaded) 'Loaded session is not null'
    Assert-True ($loaded['Username'] -eq 'user@proton.me') 'Username matches original value'
    Assert-True ($loaded['Password'] -eq 'ProtonPass123!') 'Password matches original value'
    Assert-True ($loaded['2FA'] -eq '123456') '2FA matches original value'
    Assert-True ($loaded['MailboxPassword'] -eq 'MailboxSecret!') 'MailboxPassword matches original value'

    # Test 4: Rclone Environment Generation
    $envVars = Get-ProtonDriveRcloneEnvironment -AccountId $testAccountId -RemoteName 'myproton'
    Assert-True ($envVars['RCLONE_CONFIG_MYPROTON_TYPE'] -eq 'protondrive') 'Remote type is protondrive'
    Assert-True ($envVars['RCLONE_CONFIG_MYPROTON_USERNAME'] -eq 'user@proton.me') 'Remote username is user@proton.me'
    Assert-True (-not [string]::IsNullOrEmpty($envVars['RCLONE_CONFIG_MYPROTON_PASSWORD'])) 'Remote password is populated'
    Assert-True ($envVars['RCLONE_CONFIG_MYPROTON_2FA'] -eq '123456') 'Remote 2FA is populated'
    Assert-True (-not [string]::IsNullOrEmpty($envVars['RCLONE_CONFIG_MYPROTON_MAILBOX_PASSWORD'])) 'Remote mailbox password is populated'
    Assert-True ($envVars['RCLONE_CONFIG_MYPROTON_ENABLE_CACHING'] -eq 'true') 'Caching enabled'

    # Test 5: Probe on Invalid Session Fails Gracefully
    $missingProbe = Test-ProtonDriveBackendSession -AccountId 'non_existent_account'
    Assert-True ($missingProbe.IsValid -eq $false) 'Missing account returns IsValid=false'
    Assert-True ($missingProbe.State -eq 'Disconnected') 'Missing account returns State=Disconnected'

} finally {
    Remove-ProtonDriveSession -AccountId $testAccountId
    Assert-True (-not (Test-Path -LiteralPath (Get-ProtonDriveCredentialFilePath -AccountId $testAccountId))) 'Session removed from disk'
}

if ($failed -gt 0) {
    throw "$failed Proton Drive provider tests failed."
}
Write-Output '  [PASS] All Proton Drive Provider tests completed successfully.'
