# Test-AnalyticsPage.ps1 - Analytics page contract and no-fabricated-metrics checks
#
# Mocked/structural verification: the Analytics page must sample only while it
# is visible, keep a bounded history, compute CPU from real processor-time
# deltas, distinguish process RAM from cache disk usage, and report metrics
# that have no measurement channel as Unavailable rather than inventing values.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

# 1. Page exists in navigation and is reachable.
Assert-True ($mainSource -match 'function Show-AnalyticsView') 'Show-AnalyticsView exists'
Assert-True ($mainSource -match '\$navAnalyticsItem = New-NavButton') 'Analytics navigation item exists'
Assert-True ($mainSource -match '\$navAnalyticsItem\.Button\.Add_Click\(\{ Show-AnalyticsView \}\)') 'Analytics nav click wired'
Assert-True ($mainSource -notmatch '\[char\]0x1F') 'Nav glyphs stay single-char BMP safe (no astral-plane cast crash)'

# 2. Sampler lives only on the page.
Assert-True ($mainSource -match '\$script:AnalyticsSampler\.Interval = \[TimeSpan\]::FromSeconds\(5\)') 'Sampler interval is 5 seconds'
Assert-True ($mainSource -match '(?ms)if \(\$script:CurrentView -ne ''Analytics''\) \{\s+\$script:AnalyticsSampler\.Stop\(\)') 'Sampler self-stops when leaving the Analytics page'
foreach ($fn in @('Show-DisksView', 'Show-OptionsView', 'Show-HelpView')) {
    $pattern = 'function ' + $fn + ' \{[\s\S]?[\s\S]*?\$script:AnalyticsSampler\.Stop\(\)'
    Assert-True ($mainSource -match $pattern) "$fn stops the sampler when navigating away"
}

# 3. Visibility kept consistent across all four views.
foreach ($view in @('analyticsView', 'optionsView', 'helpView', 'disksView')) {
    $collapsedCount = ([regex]::Matches($mainSource, ('\${0}\.Visibility = \[System\.Windows\.Visibility\]::Collapsed' -f $view))).Count
    Assert-True ($collapsedCount -ge 3) "$view is collapsed by at least the three sibling view functions (found $collapsedCount)"
}

# 4. CPU percentages derive from real processor-time deltas, not random values.
Assert-True ($mainSource -match 'TotalProcessorTime') 'CPU metric reads TotalProcessorTime'
Assert-True ($mainSource -match 'AnalyticsCpuBaseline') 'CPU metric keeps a first-seen baseline for deltas'
Assert-True ($mainSource -notmatch 'Get-Random') 'CPU metric does not fabricate values'

# 5. Bounded history.
Assert-True ($mainSource -match '\$script:AnalyticsHistory\.Count -gt 120') 'History is bounded to 120 samples'
Assert-True ($mainSource -match 'RemoveAt\(0\)') 'Old samples are dropped, not accumulated'

# 6. RAM vs cache disk distinction and honest unavailables.
Assert-True ($mainSource -match 'App memory:') 'App memory reported separately'
Assert-True ($mainSource -match 'Cached files on disk:') 'Cache disk usage reported separately'
Assert-True ($mainSource -match 'Currently in use / locked by mounts:') 'Locked/in-use cache entries are distinguished from total cache'
Assert-True ($mainSource -match 'Transfer speeds, bytes transferred, operation durations, and provider latency: Unavailable\.') 'Unmeasurable transfer/latency metrics are Unavailable, not invented'
Assert-True ($mainSource -match 'do not expose a transfer-statistics endpoint') 'Truthful explanation of why transfer stats are unavailable'
Assert-True ($mainSource -match 'measuring\.\.\.') 'First sample states measurement is pending instead of showing a fake number'

# 7. Per-account health uses the app's own cached truth, not new probing.
Assert-True ($mainSource -match 'Get-CachedUiDriveStatus -ProviderId \(\[string\]\$acc\.ProviderId\)') 'Per-account health reads the same cached status the UI displays'

Write-Output '  [PASS] Analytics page contract verified (mocked/structural).'
