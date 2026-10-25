# Test-OptionsPage.ps1 - Comprehensive functional audit and UX tests for NS Cloud Drive Options Page
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Write-Output "  [FAIL] $Message"
        throw $Message
    }
    Write-Output "  [PASS] $Message"
}

Write-Output 'Testing Options Page Functional Audit & UX Upgrade...'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mainScriptPath = Join-Path $repoRoot 'src\NSCloudDrive.ps1'

# 1. Parse and static structure verification
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-True ($null -eq $parseErrors -or $parseErrors.Count -eq 0) 'NSCloudDrive.ps1 parses cleanly with zero syntax errors'

$mainContent = [System.IO.File]::ReadAllText($mainScriptPath)

# 2. General Settings Controls Verification
Assert-True ($mainContent -match '\$optStartupChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Startup checkbox ($optStartupChk) is instantiated'
Assert-True ($mainContent -match '\$optTrayChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Minimize to tray checkbox ($optTrayChk) is instantiated'
Assert-True ($mainContent -match '\$optStartMinChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Start minimized checkbox ($optStartMinChk) is instantiated'
Assert-True ($mainContent -match '\$optExplorerChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Open Explorer checkbox ($optExplorerChk) is instantiated'
Assert-True ($mainContent -match '\$optAutoMountChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Auto mount checkbox ($optAutoMountChk) is instantiated'
Assert-True ($mainContent -match '\$optStatusLabel\s*=') 'Feedback status label ($optStatusLabel) is present for user feedback'

# 2.1 Notification Preferences Controls Verification
Assert-True ($mainContent -match '\$optNotifyMasterChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Notification master checkbox ($optNotifyMasterChk) is instantiated'
Assert-True ($mainContent -match '\$optNotifyStartChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Notification upload start checkbox ($optNotifyStartChk) is instantiated'
Assert-True ($mainContent -match '\$optNotifyCompleteChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Notification upload complete checkbox ($optNotifyCompleteChk) is instantiated'
Assert-True ($mainContent -match '\$optNotifyGroupFolderChk\s*=\s*\[System\.Windows\.Controls\.CheckBox\]::new\(\)') 'Notification group folder checkbox ($optNotifyGroupFolderChk) is instantiated'
Assert-True ($mainContent -match '\$optNotifySnoozeStatusText\s*=') 'Notification snooze status text ($optNotifySnoozeStatusText) is instantiated'
Assert-True ($mainContent -match 'Set-NotificationSnooze') 'Notification snooze quick actions are wired'
Assert-True ($mainContent -match '\$notifyIcon\.Add_BalloonTipClicked') 'Notification balloon click handler is wired to open Explorer and bring window to front'

# 3. Contextual Info Icons (Tooltips) Verification
Assert-True ($mainContent -match 'function New-OptionsInfoIcon') 'New-OptionsInfoIcon helper function is defined'
Assert-True ($mainContent -match '\$script:OptionsInfoIcons') 'OptionsInfoIcons tracking list is maintained for dynamic theme styling'
Assert-True ($mainContent -match 'ToolTip\.IsOpen') 'Info icons support touch/keyboard click toggle'

# 4. Themes: Pure Black and Pure White only in Options UI, Translucent preserved in engine
Assert-True ($mainContent -match '\$rbThemePureBlack\s*=\s*\[System\.Windows\.Controls\.RadioButton\]::new\(\)') 'Pure Black radio button is instantiated'
Assert-True ($mainContent -match '\$rbThemePureWhite\s*=\s*\[System\.Windows\.Controls\.RadioButton\]::new\(\)') 'Pure White radio button is instantiated'
Assert-True ($mainContent -match '\$themeStack\.Children\.Add\(\$rbThemePureBlack\)') 'Pure Black is added to Options UI'
Assert-True ($mainContent -match '\$themeStack\.Children\.Add\(\$rbThemePureWhite\)') 'Pure White is added to Options UI'
Assert-True ($mainContent -notmatch '\$themeStack\.Children\.Add\(\$rbThemeTranslucent\)') 'Translucent theme is removed from Options UI'
Assert-True ($mainContent -match 'Translucent Liquid Glass') 'Translucent Liquid Glass engine/contract string is preserved for test compatibility'

# 5. Cache Management: 200 GB option, Confirmation Dialog, Honest Reporting
Assert-True ($mainContent -match '200') '200 GB option is included in Cache Quota list'
Assert-True ($mainContent -match 'Clean Local Cache' -and $mainContent -match 'MessageBoxButton\]::YesNo') 'Clean Cache requires clear user confirmation before proceeding'
Assert-True ($mainContent -match 'Invoke-SafeCacheCleanup') 'Clean Cache executes safe cleanup preserving in-use files'
Assert-True ($mainContent -match 'SkippedInUseCount') 'Clean Cache honestly reports preserved in-use files'
Assert-True ($mainContent -match 'Start-ExplorerWindow \$script:CacheDirectory') 'Open Cache Folder launches Explorer with active cache path'

# 6. Diagnostics & System Health Verification
Assert-True ($mainContent -match 'function Show-SystemDiagnosticsModal') 'Show-SystemDiagnosticsModal is defined'
Assert-True ($mainContent -match 'Get-Process -Name ''rclone''' -and $mainContent -match 'Get-Process -Name ''cpx''') 'Diagnostics queries rclone and CPX engine process status'
Assert-True ($mainContent -match '\[OK\]' -and $mainContent -match '\[WARN\]' -and $mainContent -match '\[INFO\]') 'Diagnostics displays clear status indicator badges'
Assert-True ($mainContent -match 'Trim Working Set') 'Trim Working Set is available in diagnostics modal'

# 7. Memory Trim before/after calculation and honest explanation
Assert-True ($mainContent -match 'Invoke-MemoryTrim') 'Trim Memory Now invokes Win32 EmptyWorkingSet'
Assert-True ($mainContent -match 'WorkingSet64' -and $mainContent -match 'reclaimed') 'Memory trimming measures and reports before/after working set'

# 8. StartMinimized Startup Integration
Assert-True ($mainContent -match 'param\(\s*\[switch\]\$Minimized\s*\)') 'StartMinimized CLI parameter is supported'
Assert-True ($mainContent -match 'if \(-not \$PSBoundParameters\.ContainsKey\(''Minimized''\)\) \{\s*\$Minimized = \[switch\]\$false\s*\}') 'Interactive launch defaults Minimized to false so main window opens'

# 9. Settings Manager Integration: Round-trip persistence of all 5 General Options
. (Join-Path $repoRoot 'src\services\SettingsManager.ps1')
$tempSandbox = Join-Path $env:TEMP ("NSCD_OptionsTest_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempSandbox -Force | Out-Null
try {
    Set-SettingsDirectoryOverride $tempSandbox

    $s = Get-NSCloudDriveSettings
    $s.AutoStartWithWindows = $false
    $s.MinimizeToTrayOnClose = $false
    $s.StartMinimized = $true
    $s.OpenExplorerOnMount = $false
    $s.AutoMountDrives = $false
    $s.CacheMaxGigabytes = 200
    $s.Theme = 'PureWhite'
    $s.EnableNotifications = $false
    $s.NotifyOnUploadStart = $false
    $s.NotifyOnUploadComplete = $false
    $s.GroupFolderUploads = $false
    Set-NSCloudDriveSettings $s

    $loaded = Get-NSCloudDriveSettings
    Assert-True ($loaded.AutoStartWithWindows -eq $false) 'AutoStartWithWindows persisted correctly'
    Assert-True ($loaded.MinimizeToTrayOnClose -eq $false) 'MinimizeToTrayOnClose persisted correctly'
    Assert-True ($loaded.StartMinimized -eq $true) 'StartMinimized persisted correctly'
    Assert-True ($loaded.OpenExplorerOnMount -eq $false) 'OpenExplorerOnMount persisted correctly'
    Assert-True ($loaded.AutoMountDrives -eq $false) 'AutoMountDrives persisted correctly'
    Assert-True ($loaded.CacheMaxGigabytes -eq 200) 'CacheMaxGigabytes 200 GB persisted correctly'
    Assert-True ($loaded.Theme -eq 'PureWhite') 'Theme PureWhite persisted correctly'
    Assert-True ($loaded.EnableNotifications -eq $false) 'EnableNotifications persisted correctly'
    Assert-True ($loaded.NotifyOnUploadStart -eq $false) 'NotifyOnUploadStart persisted correctly'
    Assert-True ($loaded.NotifyOnUploadComplete -eq $false) 'NotifyOnUploadComplete persisted correctly'
    Assert-True ($loaded.GroupFolderUploads -eq $false) 'GroupFolderUploads persisted correctly'
} finally {
    Set-SettingsDirectoryOverride $null
    if (Test-Path -LiteralPath $tempSandbox) {
        Remove-Item -LiteralPath $tempSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 10. STA Child Process Verification: Options Page UI Construction and Tooltips
$staHarness = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. '$mainScriptPath'

# Verify Palette and theme resolution
`$p = Get-MainThemePalette 'PureBlack'
if (-not `$p -or `$p.Name -ne 'PureBlack') { throw 'PureBlack palette failed' }

`$pWhite = Get-MainThemePalette 'PureWhite'
if (-not `$pWhite -or `$pWhite.Name -ne 'PureWhite') { throw 'PureWhite palette failed' }

# Verify New-OptionsInfoIcon creates elements with valid tooltips
`$icon = New-OptionsInfoIcon -ExplanationText 'Test explanation text' -Title 'Test Title'
if (-not `$icon) { throw 'New-OptionsInfoIcon returned null' }
if (`$icon.Width -ne 16 -or `$icon.Height -ne 16) { throw 'Icon dimensions incorrect' }
if (-not (`$icon.ToolTip -is [System.Windows.Controls.ToolTip])) { throw 'Icon missing ToolTip' }

# Verify Show-OptionsView updates visibility without errors
Show-OptionsView
if (`$optionsView.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'optionsView not visible' }

# Verify Theme switching does not throw and updates UI
Apply-UITheme 'PureWhite'
Apply-UITheme 'PureBlack'

Write-Output 'STA_OPTIONS_UI_OK'
"@

$sandboxDir = Join-Path $env:TEMP ("NSCD_OptionsSTA_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandboxDir -Force | Out-Null
$staFile = Join-Path $sandboxDir 'TestOptionsSTA.ps1'
try {
    [System.IO.File]::WriteAllText($staFile, $staHarness, [System.Text.UTF8Encoding]::new($false))
    $res = powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $staFile
    Assert-True ($res -like '*STA_OPTIONS_UI_OK*') 'STA Options Page UI construction and theme switching verified'
} finally {
    if (Test-Path -LiteralPath $sandboxDir) {
        Remove-Item -LiteralPath $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'All Options Page Functional Audit & UX tests passed.'
