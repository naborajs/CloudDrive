# Test-MegaProvider.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Write-Output "  [FAIL] $Message"
        throw $Message
    }
    Write-Output "  [PASS] $Message"
}

Write-Output 'Testing MegaProvider...'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$megaScript = Join-Path $repoRoot 'src\providers\MegaProvider.ps1'

Assert-True (Test-Path -LiteralPath $megaScript) 'MegaProvider.ps1 exists'

. $megaScript

# 1. Capability Info
$info = Get-MegaProviderInfo
Assert-True ($info.Id -eq 'mega') 'Provider Id is mega'
Assert-True ($info.SupportsManualSession -eq $true) 'Supports manual session'
Assert-True ($info.SupportsMultipleAccounts -eq $true) 'Supports multiple accounts'

# 2. Session Save and Read-back
$testAccId = 'test_mega_unit_' + [Guid]::NewGuid().ToString('N')
$testData = [ordered]@{
    User = 'testuser@example.com'
    Password = 'SuperSecretMegaPassword123'
}

try {
    $saveRes = Save-MegaSession -AccountId $testAccId -SessionData $testData
    Assert-True ($saveRes.Success -eq $true) 'Save-MegaSession returned success'
    Assert-True (Test-Path -LiteralPath $saveRes.Path) 'Credential XML file exists'

    $readBack = Get-MegaStoredSession -AccountId $testAccId
    Assert-True ($null -ne $readBack) 'Get-MegaStoredSession retrieved saved session'
    Assert-True ($readBack['User'] -eq 'testuser@example.com') 'User email preserved'
    Assert-True ($readBack['Password'] -eq 'SuperSecretMegaPassword123') 'Password preserved'

    # 3. Test Backend Session validation
    $check = Test-MegaBackendSession -AccountId $testAccId
    Assert-True ($check.IsValid -eq $true) 'Test-MegaBackendSession validates stored credentials'
    Assert-True ($check.State -eq 'Connected') 'Session state is Connected'

    # 4. Rclone Environment Generation
    $envVars = Get-MegaRcloneEnvironment -AccountId $testAccId -RemoteName 'my_mega'
    Assert-True ($envVars['RCLONE_CONFIG_MY_MEGA_TYPE'] -eq 'mega') 'Rclone remote type is mega'
    Assert-True ($envVars['RCLONE_CONFIG_MY_MEGA_USER'] -eq 'testuser@example.com') 'Rclone user env set'
    Assert-True ($null -ne $envVars['RCLONE_CONFIG_MY_MEGA_PASS']) 'Rclone pass env set'

    # 5. Session Removal
    Remove-MegaSession -AccountId $testAccId
    $readAfter = Get-MegaStoredSession -AccountId $testAccId
    Assert-True ($null -eq $readAfter) 'Remove-MegaSession cleans up session file'
    Assert-True (-not (Test-Path -LiteralPath $saveRes.Path)) 'Credential file removed from disk'

    Write-Output 'MegaProvider tests passed successfully.'
} finally {
    Remove-MegaSession -AccountId $testAccId
}
