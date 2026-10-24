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
Assert-True ($mainSource -match 'PrivateMemorySize64') 'Dashboard distinguishes working-set RAM from private memory'
Assert-True ($mainSource -match 'App CPU:') 'Dashboard reports app CPU when measurable'
Assert-True ($mainSource -match 'Transfer speed: Unavailable') 'Dashboard does not invent a network transfer speed'
Assert-True ($mainSource -match 'ProgressBar\]::new\(\)') 'Storage usage is drawn as a chart'
Assert-True ($mainSource -match 'ResponseMilliseconds = \[int\]\$responseTimer\.ElapsedMilliseconds') 'Provider response times are measured around real quota checks'
Assert-True ($mainSource -match 'Email = \$email[\s\S]{0,200}DriveLetter = \[string\]\$account\.DriveLetter') 'Each storage row keeps provider identity and drive assignment together'
Assert-True ($mainSource -match 'IdentityVerified') 'Google storage is accepted only with a verified identity'
Assert-True ($mainSource -match 'Used and remaining storage: Unavailable') 'Unverified or missing storage is displayed as unavailable'
Assert-True ($mainSource -match '\$total -le 0 -or \$used -lt 0') 'Missing provider quota is not presented as a fabricated zero'
Assert-True ($mainSource -match 'Start-NSBackgroundOperation.*AnalyticsStorageWorker|AnalyticsStorageWorker = Start-NSBackgroundOperation') 'Provider quota checks run off the dispatcher'
$analyticsMetrics = [regex]::Match($mainSource, '(?s)function Update-AnalyticsMetrics \{.*?function Get-AnalyticsCpuPercent').Value
Assert-True ($analyticsMetrics -and $analyticsMetrics -notmatch 'Get-DetailedCacheStatistics|Get-ChildItem.*-Recurse') 'Analytics does not recursively scan cache files'
Assert-True ($analyticsMetrics -notmatch 'Get-CimInstance Win32_Process') 'Analytics avoids expensive process-wide I/O scans'
Assert-True ($mainSource -match 'TotalProcessorTime') 'CPU percentage comes from measured process-time deltas'
Assert-True ($mainSource -match '\$script:BitmapImageCache\.ContainsKey') 'Provider icon bitmaps are decoded once and reused'
Assert-True ($mainSource -match '\$refreshAccountCards = \$accountCardsSignature -ne \$script:AccountCardsSignature') 'Unchanged account cards are not rebuilt on every UI refresh'
Assert-True ($mainSource -match 'CLOUD DRIVES') 'Saved accounts are presented together as the primary drive list'
Assert-True ($mainSource -match "New-NavButton \(\[string\]\[char\]0x2197\) 'Analytics'") 'Analytics uses a compact trend glyph instead of oversized block bars'
Assert-True ($mainSource -match 'New-AnalyticsCard ''Cloud accounts and mounts'' ''#3B82F6''' -and $mainSource -match 'New-AnalyticsCard ''Cloud storage'' ''#F59E0B''' -and $mainSource -match 'New-AnalyticsCard ''App resources \(live\)'' ''#14B8A6''') 'Analytics sections use lightweight color accents'
Assert-True ($mainSource.Contains('$analyticsDarkPalette = $p.Name -in @(''PureBlack'', ''Translucent'')') -and $mainSource.Contains('$analyticsAmber = if ($analyticsDarkPalette) { ''#FCD34D'' } else { ''#B45309'' }')) 'Analytics metric colors retain readable contrast in dark and light themes'
Assert-True ($mainSource.Contains('[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)') -and $mainSource.Contains('Active mounted drives: $($mountedDriveLetters.Count).')) 'Mounted-drive analytics counts unique drive letters across saved and legacy mounts'
Assert-True ($mainSource -notmatch 'Get-Random') 'No synthetic resource or storage values are generated'

Write-Output '  [PASS] Analytics dashboard contract verified (mocked/structural; no real provider quota call performed).'
