# Test-ProviderContracts.ps1 - provider abstraction contract tests (Phase 15)
#
# Verifies the shared provider contract definition exists and that the
# currently wired providers (Google Drive, TeraBox) satisfy its required
# function surface, while a provider WITHOUT a real implementation (Proton
# Drive) is honestly reported as not satisfied - no fake connector.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$failed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failed++; Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

$contractSource = Get-Content -LiteralPath (Join-Path $repoRoot 'src\providers\ProviderContract.ps1') -Raw
Assert-True ($contractSource -match 'IdentityVerified') 'Contract carries the verified-identity rule from the OAuth fix'
Assert-True ($contractSource -match 'SupportsMultipleAccounts') 'Contract exposes the multi-account capability flag'
Assert-True ($contractSource -match 'placeholder identity as verified') 'Contract forbids placeholder identities for unsaved accounts'

# Real providers must satisfy the contract in-process.
$files = @(
    (Join-Path $repoRoot 'src\models\ConnectionState.ps1'),
    (Join-Path $repoRoot 'src\providers\ProviderContract.ps1'),
    (Join-Path $repoRoot 'src\providers\GoogleDriveProvider.ps1'),
    (Join-Path $repoRoot 'src\providers\TeraBoxProvider.ps1'),
    (Join-Path $repoRoot 'src\providers\VpsProvider.ps1'),
    (Join-Path $repoRoot 'src\providers\ProtonDriveProvider.ps1'),
    (Join-Path $repoRoot 'src\providers\MegaProvider.ps1'),
    (Join-Path $repoRoot 'src\providers\S3Provider.ps1')
)
foreach ($file in $files) { . $file }

$gdrive = Test-ProviderContract -ProviderId 'gdrive'
Assert-True ($gdrive.Satisfied -eq $true) "Google Drive satisfies the contract (missing: $($gdrive.Missing -join ', '))"

$terabox = Test-ProviderContract -ProviderId 'terabox'
Assert-True ($terabox.Satisfied -eq $true) "TeraBox satisfies the contract (missing: $($terabox.Missing -join ', '))"

$vps = Test-ProviderContract -ProviderId 'vps'
Assert-True ($vps.Satisfied -eq $true) "VPS / Remote Server satisfies the contract (missing: $($vps.Missing -join ', '))"

$proton = Test-ProviderContract -ProviderId 'proton'
Assert-True ($proton.Satisfied -eq $true) "Proton Drive satisfies the contract (missing: $($proton.Missing -join ', '))"

$mega = Test-ProviderContract -ProviderId 'mega'
Assert-True ($mega.Satisfied -eq $true) "MEGA satisfies the contract (missing: $($mega.Missing -join ', '))"

$s3 = Test-ProviderContract -ProviderId 's3'
Assert-True ($s3.Satisfied -eq $true) "S3 / Metal satisfies the contract (missing: $($s3.Missing -join ', '))"

$unknown = Test-ProviderContract -ProviderId 'made_up_provider'
Assert-True ($unknown.Satisfied -eq $false -and $unknown.Missing[0] -match 'Unknown provider id') 'Unsupported provider ids are refused, not faked'

$summary = Get-CloudProviderContractSummary
Assert-True (@($summary).Count -eq 6) 'Contract summary covers exactly the 6 wired providers'
Assert-True (@($summary | Where-Object { -not $_.Satisfied }).Count -eq 0) 'No wired provider violates the contract'

if ($failed -gt 0) { throw "$failed provider-contract assertions failed." }
Write-Output '  [PASS] Provider contract verified.'
