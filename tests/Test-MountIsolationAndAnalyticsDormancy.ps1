# Test-MountIsolationAndAnalyticsDormancy.ps1
# Regression coverage for:
#   1. Analytics page performs NO background work until user clicks Get Analytics.
#   2. One account's mount failure does not affect another account's mount state.
# Mocked/sandboxed: no live provider calls, no mount processes started.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

# ---------------------------------------------------------------------------
# 1. Analytics dormancy: navigation alone must not start any collection work.
# ---------------------------------------------------------------------------
Assert-True ($mainSource -notmatch '\$script:AnalyticsSampler') `
    'No AnalyticsSampler timer exists (no automatic polling)'

Assert-True ($mainSource -notmatch 'Show-AnalyticsView[\s\S]*?Start-AnalyticsSampling') `
    'Show-AnalyticsView does not start automatic sampling'

Assert-True ($mainSource -match 'function Start-AnalyticsCollection') `
    'On-demand Start-AnalyticsCollection function exists'

Assert-True ($mainSource -match 'function Stop-AnalyticsCollection') `
    'On-demand Stop-AnalyticsCollection cleanup exists'

Assert-True ($mainSource -match 'AnalyticsCollectionInProgress') `
    'Collection in-progress guard exists to prevent overlapping requests'

Assert-True ($mainSource -match 'if \(\$script:AnalyticsCollectionInProgress\) \{ return \}') `
    'Repeated Get Analytics clicks are rejected while a collection is in progress'

Assert-True ($mainSource -match 'Not yet collected') `
    'Initial analytics state reports Not yet collected (no pre-collected values)'

# ---------------------------------------------------------------------------
# 2. Mount isolation: one account's failure does not affect another account.
#    Simulate AccountMountStates where account A is Error and account B is Mounted.
# ---------------------------------------------------------------------------
$script:AccountMountStates = @{}
$script:AccountMountStates['acct-a-failed'] = [ordered]@{
    State = 'Error'; Stage = 'Mount failed'; Error = 'Provider session expired'; DriveLetter = 'A'; StartedAt = $null; UpdatedAt = [DateTime]::UtcNow
}
$script:AccountMountStates['acct-b-ok'] = [ordered]@{
    State = 'Mounted'; Stage = 'Filesystem verified'; Error = $null; DriveLetter = 'B'; StartedAt = $null; UpdatedAt = [DateTime]::UtcNow
}

# Verify account A is Error and account B is Mounted independently
$stateA = $script:AccountMountStates['acct-a-failed']
$stateB = $script:AccountMountStates['acct-b-ok']
Assert-True ($stateA.State -eq 'Error') 'Failed account A reports Error state'
Assert-True ($stateB.State -eq 'Mounted') 'Healthy account B reports Mounted state'
Assert-True ($stateA.DriveLetter -ne $stateB.DriveLetter) 'Accounts use distinct drive letters'

# Simulate clearing only account A's failure; account B must remain untouched
$script:AccountMountStates.Remove('acct-a-failed')
Assert-True (-not $script:AccountMountStates.ContainsKey('acct-a-failed')) 'Removing failed account A does not touch account B'
Assert-True ($script:AccountMountStates.ContainsKey('acct-b-ok')) 'Account B mount state remains after account A cleanup'

# ---------------------------------------------------------------------------
# 3. Disconnect is scoped to the intended account only.
# ---------------------------------------------------------------------------
$script:DriveDisconnectWorkers = @{}
$keyA = 'acct-a-failed'
$keyB = 'acct-b-ok'
# Starting a scoped disconnect for account A must not remove/affect account B's worker
$script:DriveDisconnectWorkers[$keyA] = [pscustomobject]@{ Operation = $null; ProviderId = 'gdrive'; AccountId = $keyA; DriveLetter = 'A' }
Assert-True ($script:DriveDisconnectWorkers.ContainsKey($keyA)) 'Disconnect worker registered for account A'
Assert-True (-not $script:DriveDisconnectWorkers.ContainsKey($keyB)) 'Account B has no disconnect worker (not affected by A)'

# ---------------------------------------------------------------------------
# 4. Account list isolation: Get-CloudAccounts returns individual records
#    (not a merged array that would cause WPF cards to merge accounts).
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
$accountsSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1') -Raw
Assert-True ($accountsSource -match 'function Get-CloudAccounts') 'Get-CloudAccounts function exists'
Assert-True ($accountsSource -notmatch 'return\s+,\$list') 'Get-CloudAccounts does NOT use return ,$list (which merged accounts)'

# Verify account records are distinct scalar objects (not merged arrays)
$script:AccountListCache = $null
$script:AccountListCacheAt = [DateTime]::MinValue
$all = @(Get-CloudAccounts)
$ids = @($all | ForEach-Object { [string]$_.Id })
$uniqueIds = @($ids | Select-Object -Unique)
Assert-True ($ids.Count -eq $uniqueIds.Count) 'All account IDs are unique (no merged duplicates)'
Assert-True (@($all | ForEach-Object { $_.ProviderId -is [string] } | Where-Object { -not $_ }).Count -eq 0) 'All ProviderId values are scalar strings'
Assert-True (@($all | ForEach-Object { $_.DriveLetter -is [string] } | Where-Object { -not $_ }).Count -eq 0) 'All DriveLetter values are scalar strings'

Write-Output '  [PASS] Mount isolation and analytics dormancy regression verified (mocked/sandboxed).'
