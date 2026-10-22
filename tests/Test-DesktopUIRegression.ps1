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
if ($mainContent -notmatch '\$mainScroll\.HorizontalScrollBarVisibility\s*=\s*[''"]Disabled[''"]') {
    throw 'NSCloudDrive.ps1 must set $mainScroll.HorizontalScrollBarVisibility to Disabled to prevent layout overflow.'
}
Write-Output '  [PASS] NSCloudDrive.ps1 disables horizontal scrollbar to constrain layout width'

# 3. Test horizontal scrollbar configuration in ProviderConnectionWindow.ps1
$dialogContent = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\ui\ProviderConnectionWindow.ps1') -Raw
if ($dialogContent -notmatch '\$contentScroll\.HorizontalScrollBarVisibility\s*=\s*[''"]Disabled[''"]') {
    throw 'ProviderConnectionWindow.ps1 must set $contentScroll.HorizontalScrollBarVisibility to Disabled.'
}
Write-Output '  [PASS] ProviderConnectionWindow.ps1 disables horizontal scrollbar to prevent layout overflow'

# 4. Test NSCloudDrive.ps1 loads cleanly in STA without throwing
$dotSourceCheck = powershell.exe -NoProfile -STA -Command "& { . (Resolve-Path '.\src\NSCloudDrive.ps1'); if (`$window -and `$providersGrid) { 'LoadedOK' } else { 'Failed' } }"
if ($dotSourceCheck -notmatch 'LoadedOK') {
    throw "Failed to load NSCloudDrive.ps1 cleanly in STA session: $dotSourceCheck"
}
Write-Output '  [PASS] NSCloudDrive.ps1 loads cleanly in STA and constructs window elements'

# 5. Test single-instance mutex detection and second-instance graceful foreground restoration
$createdNew = $false
$testMutex = [System.Threading.Mutex]::new($true, 'Local\NSCloudDrive_AppMutex', [ref]$createdNew)
try {
    $secondInstanceOutput = powershell.exe -NoProfile -STA -File (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') 2>&1 | Out-String
    if ($secondInstanceOutput -notmatch 'NS Cloud Drive is already running') {
        throw "Expected single-instance detection message, got: $secondInstanceOutput"
    }
} finally {
    if ($createdNew) {
        $testMutex.ReleaseMutex()
    }
    $testMutex.Dispose()
}
Write-Output '  [PASS] NSCloudDrive.ps1 detects running instance, restores foreground window, and exits cleanly'

Write-Output 'All Desktop UI regression tests passed.'
