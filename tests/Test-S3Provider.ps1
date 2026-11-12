# Test-S3Provider.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Write-Output "  [FAIL] $Message"
        throw $Message
    }
    Write-Output "  [PASS] $Message"
}

Write-Output 'Testing S3Provider...'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$s3Script = Join-Path $repoRoot 'src\providers\S3Provider.ps1'

Assert-True (Test-Path -LiteralPath $s3Script) 'S3Provider.ps1 exists'

. $s3Script

# 1. Capability Info
$info = Get-S3ProviderInfo
Assert-True ($info.Id -eq 's3') 'Provider Id is s3'
Assert-True ($info.SupportsManualSession -eq $true) 'Supports manual session'
Assert-True ($info.SupportsMultipleAccounts -eq $true) 'Supports multiple accounts'

# 2. Session Save and Read-back
$testAccId = 'test_s3_unit_' + [Guid]::NewGuid().ToString('N')
$testData = [ordered]@{
    Endpoint = 'https://accountid.r2.cloudflarestorage.com'
    Region = 'auto'
    AccessKey = 'AKIAIOSFODNN7EXAMPLE'
    SecretKey = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
    Bucket = 'agent-models'
    Provider = 'Cloudflare'
}

try {
    $saveRes = Save-S3Session -AccountId $testAccId -SessionData $testData
    Assert-True ($saveRes.Success -eq $true) 'Save-S3Session returned success'
    Assert-True (Test-Path -LiteralPath $saveRes.Path) 'Credential XML file exists'

    $readBack = Get-S3StoredSession -AccountId $testAccId
    Assert-True ($null -ne $readBack) 'Get-S3StoredSession retrieved saved session'
    Assert-True ($readBack['AccessKey'] -eq 'AKIAIOSFODNN7EXAMPLE') 'AccessKey preserved'
    Assert-True ($readBack['Endpoint'] -eq 'https://accountid.r2.cloudflarestorage.com') 'Endpoint preserved'
    Assert-True ($readBack['Bucket'] -eq 'agent-models') 'Bucket preserved'

    # 3. Test Backend Session validation
    $check = Test-S3BackendSession -AccountId $testAccId
    Assert-True ($check.IsValid -eq $true) 'Test-S3BackendSession validates stored credentials'
    Assert-True ($check.State -eq 'Connected') 'Session state is Connected'

    # 4. Rclone Environment Generation
    $envVars = Get-S3RcloneEnvironment -AccountId $testAccId -RemoteName 'my_s3'
    Assert-True ($envVars['RCLONE_CONFIG_MY_S3_TYPE'] -eq 's3') 'Rclone remote type is s3'
    Assert-True ($envVars['RCLONE_CONFIG_MY_S3_ACCESS_KEY_ID'] -eq 'AKIAIOSFODNN7EXAMPLE') 'Rclone access key set'
    Assert-True ($envVars['RCLONE_CONFIG_MY_S3_ENDPOINT'] -eq 'https://accountid.r2.cloudflarestorage.com') 'Rclone endpoint set'
    Assert-True ($null -ne $envVars['RCLONE_CONFIG_MY_S3_SECRET_ACCESS_KEY']) 'Rclone secret key set'

    # 5. Session Removal
    Remove-S3Session -AccountId $testAccId
    $readAfter = Get-S3StoredSession -AccountId $testAccId
    Assert-True ($null -eq $readAfter) 'Remove-S3Session cleans up session file'
    Assert-True (-not (Test-Path -LiteralPath $saveRes.Path)) 'Credential file removed from disk'

    Write-Output 'S3Provider tests passed successfully.'
} finally {
    Remove-S3Session -AccountId $testAccId
}
