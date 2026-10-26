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
Assert-True ($mainSource -match 'function Start-AnalyticsCollection') 'On-demand collection function exists'
Assert-True ($mainSource -match 'function Stop-AnalyticsCollection') 'On-demand collection cleanup exists'
Assert-True ($mainSource -match 'analyticsGetAnalyticsBtn') 'Get Analytics button exists'
Assert-True ($mainSource -match 'analyticsRefreshAnalyticsBtn') 'Refresh Analytics button exists'

# Analytics must NOT auto-start on navigation - no sampler timer, no automatic collection
Assert-True ($mainSource -notmatch '\$script:AnalyticsSampler') 'No AnalyticsSampler timer (no automatic polling)'
Assert-True ($mainSource -notmatch 'Start-AnalyticsSampling') 'No automatic sampling start'
Assert-True ($mainSource -notmatch 'Show-AnalyticsView[\s\S]*?Start-AnalyticsSampling') 'Show-AnalyticsView does not start automatic collection'

# Navigation away from Analytics stops collection work
foreach ($fn in @('Show-DisksView', 'Show-OptionsView', 'Show-HelpView', 'Show-LogsView')) {
    $pattern = 'function ' + $fn + ' \{[\s\S]*?Stop-AnalyticsCollection'
    Assert-True ($mainSource -match $pattern) "$fn stops analytics collection on navigation away"
}

# In-progress guard prevents overlapping requests
Assert-True ($mainSource -match '\$script:AnalyticsCollectionInProgress') 'Collection in-progress guard exists'
Assert-True ($mainSource -match 'if \(\$script:AnalyticsCollectionInProgress\) \{ return \}') 'Overlapping collection requests are rejected'

# Collection status elements exist
Assert-True ($mainSource -match '\$analyticsCollectionStatus') 'Collection status display exists'
Assert-True ($mainSource -match '\$analyticsCollectionErrors') 'Collection errors display exists'

# Dashboard content
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
Assert-True ($mainSource -match 'Storage: Not yet collected') 'Storage shows not-yet-collected state initially'
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

# Collection is time-stamped and duration-tracked
Assert-True ($mainSource -match '\$script:AnalyticsLastCollectionTime') 'Collection timestamp is recorded'
Assert-True ($mainSource -match '\$script:AnalyticsLastCollectionDurationMs') 'Collection duration is recorded'
Assert-True ($mainSource -match 'Stopwatch') 'Stopwatch is used to measure collection duration'

# Focused Lifecycle & Safety Verifications
Assert-True ($mainSource -match '\$analyticsCancelBtn') 'Cancel collection action exists'
Assert-True ($mainSource -match '\$analyticsSummaryGrid') '4-column key metrics summary grid exists'
Assert-True ($mainSource -match 'New-AnalyticsStatCard ''Drive Mounts''') 'Drive Mounts stat card is defined'
Assert-True ($mainSource -match 'New-AnalyticsStatCard ''Active Transfers''') 'Active Transfers stat card is defined'
Assert-True ($mainSource -match 'New-AnalyticsStatCard ''SSD Local Cache''') 'SSD Local Cache stat card is defined'
Assert-True ($mainSource -match 'New-AnalyticsStatCard ''Network Latency''') 'Network Latency stat card is defined'
Assert-True ($mainSource -match 'New-AnalyticsCard ''Network & latency diagnostics'' ''#06B6D4''') 'Network & latency diagnostics card is defined'
Assert-True ($mainSource -match 'New-AnalyticsCard ''Local SSD cache & staging diagnostics'' ''#10B981''') 'Local SSD cache & staging diagnostics card is defined'

# Theme and Liquid Glass styling integration
$applyThemeBlock = [regex]::Match($mainSource, '(?s)function Apply-UITheme\b.*?function Update-NavActiveState').Value
Assert-True ($applyThemeBlock -match '\$analyticsLandingCard') 'Apply-UITheme includes analyticsLandingCard'
Assert-True ($applyThemeBlock -match '\$analyticsActionBar') 'Apply-UITheme includes analyticsActionBar'
Assert-True ($applyThemeBlock -match '\$analyticsRefreshAnalyticsBtn') 'Apply-UITheme includes analyticsRefreshAnalyticsBtn'
$glassCardList = [regex]::Match($applyThemeBlock, '(?s)foreach\s*\(\$glassCard in @\((.*?)\)\)').Value
Assert-True ($glassCardList -match '\$analyticsLandingCard') 'Liquid glass card composition includes analyticsLandingCard'

# CPU measurement bounding
Assert-True ($mainSource -match '\[Math\]::Max\(0\.0,\s*\[Math\]::Min\(100\.0,') 'CPU percent calculation is safely bounded between 0.0 and 100.0'

# Verify absolutely NO automatic collection in timers, startup, or tray
$timerBlock = [regex]::Match($mainSource, '(?s)\$timer\.Add_Tick\(\{.*?\}\)\s*\r?\n').Value
Assert-True ($timerBlock -and $timerBlock -notmatch 'Start-AnalyticsCollection|Update-AnalyticsMetrics') 'Main timer tick does not run analytics'

$startupBlock = [regex]::Match($mainSource, '(?s)function Invoke-StartupAutoMount \{.*?\}').Value
Assert-True ($startupBlock -and $startupBlock -notmatch 'Start-AnalyticsCollection|Update-AnalyticsMetrics') 'Startup auto-mount does not run analytics'

# Verify NO cache cleanup or cloud writes occur inside analytics collection
$analyticsCollectionFn = [regex]::Match($mainSource, '(?s)function Start-AnalyticsCollection \{.*?function Stop-AnalyticsCollection').Value
Assert-True ($analyticsCollectionFn -notmatch 'Invoke-SafeCacheCleanup|Remove-Item|Clear-Content|rclone (delete|rmdir|sync)') 'Analytics does not perform cache cleanup or cloud writes'

Write-Output '  [PASS] Analytics dashboard contract verified (on-demand, no automatic polling; mocked/structural; no real provider quota call performed).'
