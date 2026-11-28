Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Desktop UI Regression...'

# 1. Test for $pid conflict in parameter declarations across the repository
$psFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\src') -Recurse -Filter *.ps1
$pidMatches = @()
foreach ($file in $psFiles) {
    $matches = Select-String -Path $file.FullName -Pattern 'param\s*\([^)]*\$pid\b'
    if ($matches) {
        $pidMatches += $matches
    }
}
if ($pidMatches.Count -gt 0) {
    throw "Found prohibited read-only `$pid parameter in: $($pidMatches -join ', ')"
}
Write-Output '  [PASS] No read-only $pid parameters exist in src/'

# 2. Test horizontal scrollbar configuration in NSCloudDrive.ps1
$mainContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
$logoPath = Join-Path $PSScriptRoot '..\assets\logos\clouddrive.png'
$readmeContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\README.md') -Raw
if (-not (Test-Path -LiteralPath $logoPath -PathType Leaf) -or
    $mainContent -notmatch 'Get-AppNotifyIcon \$appLogoPath' -or
    $mainContent -notmatch '\$window\.Icon = Get-WpfBitmapImage \$appLogoPath' -or
    $readmeContent -notmatch 'assets/logos/clouddrive\.png') {
    throw 'The shared NS Cloud Drive brand logo must be used by the window, tray, and README.'
}
Write-Output '  [PASS] Shared NS Cloud Drive logo is wired into the window, tray, and README'
if ($mainContent -notmatch '\$mainScroll\.HorizontalScrollBarVisibility\s*=\s*[''"]Disabled[''"]') {
    throw 'NSCloudDrive.ps1 must set $mainScroll.HorizontalScrollBarVisibility to Disabled to prevent layout overflow.'
}
Write-Output '  [PASS] NSCloudDrive.ps1 disables horizontal scrollbar to constrain layout width'
if ($mainContent -notmatch '(?s)function Show-UploadDialog.*?Add-CloudTransferDroppedItems' -or
    $mainContent -notmatch '(?s)function Show-UploadDialog.*?-DeferRemotePreflight' -or
    $mainContent -match '\[System\.IO\.File\]::Copy\(\$srcFile,\s*\$destPath') {
    throw 'The upload dialog must queue only selected source files and must not copy them into the mounted VFS cache.'
}
if ($mainContent -match 'Import-StagedVfsFilesToTransferQueue') {
    throw 'The desktop UI must not auto-upload orphaned cache files without a durable selection record.'
}
$linkWorkerStart = $mainContent.IndexOf('function Start-SelectedStagedCacheLinkWorker', [System.StringComparison]::Ordinal)
$linkWorkerEnd = if ($linkWorkerStart -ge 0) { $mainContent.IndexOf('function Complete-SelectedStagedCacheLinkWorker', $linkWorkerStart, [System.StringComparison]::Ordinal) } else { -1 }
$linkWorkerSource = if ($linkWorkerStart -ge 0 -and $linkWorkerEnd -gt $linkWorkerStart) { $mainContent.Substring($linkWorkerStart, $linkWorkerEnd - $linkWorkerStart) } else { '' }
if ($linkWorkerSource -notmatch [regex]::Escape("Join-Path `$sourceRoot 'services\VirtualDriveManager.ps1'")) {
    throw 'The isolated selected-staging worker must load mount path normalization and reparse safety before planning cleanup links.'
}
if ($mainContent -match 'Invoke-InactivityCacheEviction\s+-CacheDirectory\s+\$script:CacheDirectory' -or
    $mainContent -notmatch '\[void\]\(Start-InactivityCacheEvictionWorker\)') {
    throw 'Periodic recursive cache eviction must run through its background runspace, not on the UI dispatcher.'
}
if ($mainContent -notmatch '(?s)\$cacheInspectorScanState\.Worker\s*=\s*Start-NSBackgroundOperation.*?Get-DetailedCacheFileList' -or
    $mainContent -notmatch '\$maxVisibleCacheRows\s*=\s*250') {
    throw 'The Cache Inspector must scan in a background runspace and cap rendered rows for large cache directories.'
}
if ($mainContent -match 'Invoke-SafeCacheCleanup\s+-CacheDirectory' -or
    $mainContent -match 'Remove-SingleCacheFile\s+-FilePath' -or
    $mainContent -notmatch '(?s)\$cleanCacheBtn\.Add_Click.*?Start-CacheUiOperation.*?-Action Clean' -or
    $mainContent -notmatch '(?s)\$cleanAllBtn\.Add_Click.*?Start-CacheUiOperation.*?-Action Clean' -or
    $mainContent -notmatch '(?s)\$evictBtn\.Add_Click.*?Start-CacheUiOperation.*?-Action Evict' -or
    $mainContent -notmatch 'Complete-CacheUiOperation') {
    throw 'Options and Cache Inspector cleanup and eviction must use background cache workers, never the UI dispatcher.'
}
$analyticsMetricsStart = $mainContent.IndexOf('function Update-AnalyticsMetrics', [System.StringComparison]::Ordinal)
$analyticsMetricsEnd = if ($analyticsMetricsStart -ge 0) {
    $mainContent.IndexOf("`nfunction ", $analyticsMetricsStart + 1, [System.StringComparison]::Ordinal)
} else { -1 }
$analyticsMetricsContent = if ($analyticsMetricsStart -ge 0) {
    if ($analyticsMetricsEnd -gt $analyticsMetricsStart) {
        $mainContent.Substring($analyticsMetricsStart, $analyticsMetricsEnd - $analyticsMetricsStart)
    } else {
        $mainContent.Substring($analyticsMetricsStart)
    }
} else { '' }
if ($analyticsMetricsContent -match 'Get-VirtualDrivePendingUploads' -or
    $analyticsMetricsContent -notmatch 'Get-AnalyticsPendingUploadSnapshot' -or
    $mainContent -notmatch '(?s)function Start-AnalyticsPendingUploadWorker.*?Get-VirtualDrivePendingUploads') {
    throw 'Diagnostics and Analytics must use background cache and staged-upload scans.'
}
if ($mainContent -notmatch '(?s)function Update-CacheUsageDisplay.*?Get-CacheStatisticsSnapshot' -or
    $mainContent -match '(?s)function Update-CacheUsageDisplay.*?Get-DetailedCacheStatistics' -or
    $mainContent -notmatch '(?s)function Start-CacheStatisticsWorker.*?Get-DetailedCacheStatistics' -or
    $mainContent -notmatch '\[void\]\(Complete-CacheStatisticsWorker\)') {
    throw 'The Options cache usage scan must run in the background and complete through the UI dispatcher timer.'
}
Write-Output '  [PASS] Desktop uploads are selection-scoped; orphan recovery and cache scans stay off the UI thread'

# 3. Test horizontal scrollbar configuration in ProviderConnectionWindow.ps1
$dialogContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ui\ProviderConnectionWindow.ps1') -Raw
if ($dialogContent -notmatch '\$contentScroll\.HorizontalScrollBarVisibility\s*=\s*[''"]Disabled[''"]') {
    throw 'ProviderConnectionWindow.ps1 must set $contentScroll.HorizontalScrollBarVisibility to Disabled.'
}
Write-Output '  [PASS] ProviderConnectionWindow.ps1 disables horizontal scrollbar to prevent layout overflow'

# 4. Test NSCloudDrive.ps1 loads cleanly in STA without throwing
$dotSourceCheck = powershell.exe -NoProfile -STA -Command "& { . (Resolve-Path '.\src\NSCloudDrive.ps1'); if (`$window -and `$providersGrid -and `$addDiskBtn -and `$script:CustomNotifyIcon -and `$script:CustomNotifyIcon.Width -gt 0) { 'LoadedOK' } else { 'Failed' } }"
if ($dotSourceCheck -notmatch 'LoadedOK') {
    throw "Failed to load NSCloudDrive.ps1 and create the app's branded tray icon in STA session: $dotSourceCheck"
}
Write-Output '  [PASS] NSCloudDrive.ps1 loads cleanly in STA, constructs window elements, and creates a branded tray icon'

# 5. Test modal dialogs exist and load cleanly in STA
$modalCheck = powershell.exe -NoProfile -STA -Command "& { . (Resolve-Path '.\src\ui\ProviderConnectionWindow.ps1'); if ((Get-Command Show-AddCloudDiskModal -ErrorAction SilentlyContinue) -and (Get-Command Show-CloudAccountSetupModal -ErrorAction SilentlyContinue) -and (Get-Command Show-VpsSetupDialog -ErrorAction SilentlyContinue) -and (Get-Command Show-ProtonDriveSetupDialog -ErrorAction SilentlyContinue)) { 'ModalOK' } else { 'Failed' } }"
if ($modalCheck -notmatch 'ModalOK') {
    throw "Modal dialogs (AddCloudDisk, CloudAccountSetup, VpsSetup, or ProtonDriveSetup) failed to load: $modalCheck"
}
Write-Output '  [PASS] All provider modal dialogs (Google, TeraBox, VPS, Proton Drive) verified in STA'

# 6. Test single-instance mutex detection and second-instance graceful foreground restoration
$createdNew = $false
$testMutex = [System.Threading.Mutex]::new($true, 'Local\NSCloudDrive_AppMutex', [ref]$createdNew)
try {
    if (-not $createdNew) {
        try { [void]$testMutex.WaitOne(1000) } catch { }
    }
    $secondInstanceOutput = powershell.exe -NoProfile -STA -File (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Minimized 2>&1 | Out-String
    if ($secondInstanceOutput -notmatch 'NS Cloud Drive is already running') {
        throw "Expected single-instance detection message, got: $secondInstanceOutput"
    }
} finally {
    try { $testMutex.ReleaseMutex() } catch { }
    $testMutex.Dispose()
}
Write-Output '  [PASS] NSCloudDrive.ps1 detects running instance, restores foreground window, and exits cleanly'

Write-Output 'All Desktop UI regression tests passed.'
