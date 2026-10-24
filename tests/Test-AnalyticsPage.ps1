# Test-AnalyticsPage.ps1 - On-demand, verified Analytics dashboard contract.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

Assert-True ($mainSource -match 'function Show-AnalyticsView') 'Analytics view is reachable'
Assert-True ($mainSource -match '\$navAnalyticsItem\.Button\.Add_Click\(\{ Show-AnalyticsView \}\)') 'Analytics navigation is wired'
Assert-True ($mainSource -match '\$script:AnalyticsSampler\.Interval = \[TimeSpan\]::FromSeconds\(5\)') 'Lightweight resource samples are five seconds apart'
Assert-True ($mainSource -match '(?ms)if \(\$script:CurrentView -ne ''Analytics''\) \{\s+\$script:AnalyticsSampler\.Stop\(\)') 'Sampler stops when the page is no longer active'

foreach ($fn in @('Show-DisksView', 'Show-OptionsView', 'Show-HelpView', 'Show-LogsView')) {
    $pattern = 'function ' + $fn + ' \{[\s\S]?[\s\S]*?\$script:AnalyticsSampler\.Stop\(\)[\s\S]?[\s\S]*?Stop-AnalyticsStorageWorker'
    Assert-True ($mainSource -match $pattern) "$fn stops analytics sampling and quota work"
}

Assert-True ($mainSource -match '\$analyticsAccounts = New-AnalyticsRow') 'Dashboard reports total cloud accounts'
Assert-True ($mainSource -match '\$analyticsMounts = New-AnalyticsRow') 'Dashboard reports active mounted drives'
Assert-True ($mainSource -match 'App RAM:') 'Dashboard reports app RAM when measurable'
Assert-True ($mainSource -match 'App CPU:') 'Dashboard reports app CPU when measurable'
Assert-True ($mainSource -match 'ProgressBar\]::new\(\)') 'Storage usage is drawn as a chart'
Assert-True ($mainSource -match 'IdentityVerified') 'Google storage is accepted only with a verified identity'
Assert-True ($mainSource -match 'Used and remaining storage: Unavailable') 'Unverified or missing storage is displayed as unavailable'
Assert-True ($mainSource -match '\$total -le 0 -or \$used -lt 0') 'Missing provider quota is not presented as a fabricated zero'
Assert-True ($mainSource -match 'Start-NSBackgroundOperation.*AnalyticsStorageWorker|AnalyticsStorageWorker = Start-NSBackgroundOperation') 'Provider quota checks run off the dispatcher'
$analyticsMetrics = [regex]::Match($mainSource, '(?s)function Update-AnalyticsMetrics \{.*?function Get-AnalyticsCpuPercent').Value
Assert-True ($analyticsMetrics -and $analyticsMetrics -notmatch 'Get-DetailedCacheStatistics|Get-ChildItem.*-Recurse') 'Analytics does not recursively scan cache files'
Assert-True ($analyticsMetrics -notmatch 'Get-CimInstance Win32_Process') 'Analytics avoids expensive process-wide I/O scans'
Assert-True ($mainSource -match 'TotalProcessorTime') 'CPU percentage comes from measured process-time deltas'
Assert-True ($mainSource -notmatch 'Get-Random') 'No synthetic resource or storage values are generated'

Write-Output '  [PASS] Analytics dashboard contract verified (mocked/structural; no real provider quota call performed).'
