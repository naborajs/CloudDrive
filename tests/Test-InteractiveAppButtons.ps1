# Test-InteractiveAppButtons.ps1
# Comprehensive Line-by-Line & Button-by-Button Interactive UI Verification
param(
    [switch]$Worker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Write-Output "  [FAIL] $Message"
        throw $Message
    }
    Write-Output "  [PASS] $Message"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mainScript = Join-Path $repoRoot 'src\NSCloudDrive.ps1'
$pcwScript = Join-Path $repoRoot 'src\ui\ProviderConnectionWindow.ps1'

if (-not $Worker) {
    Write-Output '=== Testing Interactive Desktop Application & Button Handlers ==='

    # 1. Verify existence of UI source scripts
    Assert-True (Test-Path -LiteralPath $mainScript) 'NSCloudDrive.ps1 exists'
    Assert-True (Test-Path -LiteralPath $pcwScript) 'ProviderConnectionWindow.ps1 exists'

    # Launch worker in dedicated STA session
    $thisScript = $MyInvocation.MyCommand.Path
    $output = powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $thisScript -Worker 2>&1 | Out-String

    if ($output -notmatch 'WINDOW_OK') {
        throw "Application interactive test failed: $output"
    }

    Write-Host $output -ForegroundColor Gray

    Assert-True ($output -match 'DISKS_VIEW_OK') 'Disks navigation button successfully exercised'
    Assert-True ($output -match 'OPTIONS_VIEW_OK') 'Options navigation button successfully exercised'
    Assert-True ($output -match 'ANALYTICS_VIEW_OK') 'Analytics navigation button successfully exercised'
    Assert-True ($output -match 'LOGS_VIEW_OK') 'Logs navigation button successfully exercised'
    Assert-True ($output -match 'HELP_VIEW_OK') 'Help navigation button successfully exercised'
    Assert-True ($output -match 'REFRESH_BTN_OK') 'Disks Refresh button successfully exercised'
    Assert-True ($output -match 'AGENT_TRANSFER_BTN_OK') 'Agent Transfer button present and verified'
    Assert-True ($output -match 'TRANSFERS_BTN_OK') 'Transfers button present and verified'
    Assert-True ($output -match 'THEME_SWITCH_OK') 'Theme radio buttons successfully exercised'
    Assert-True ($output -match 'GENERAL_CHKS_OK') 'General options checkboxes successfully exercised'
    Assert-True ($output -match 'NOTIFY_CHKS_OK') 'Notification checkboxes successfully exercised'
    Assert-True ($output -match 'LOGS_CONTROLS_OK') 'Logs view controls successfully exercised'
    Assert-True ($output -match 'MODAL_DIALOGS_OK') 'All modal dialogs (AddDisk, VPS, Proton, Agent, Transfer) verified'

    Write-Output '=== ALL INTERACTIVE BUTTON & UI TESTS PASSED SUCCESSFULLY ==='
    exit 0
}

# --- STA WORKER EXECUTION ---
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. $mainScript

if ($null -eq $window -or -not ($window -is [System.Windows.Window])) {
    throw 'WPF Window was not created.'
}
Write-Output "WINDOW_OK: $($window.Title) ($($window.Width)x$($window.Height))"

# Helper to simulate a button click
function Invoke-Click([System.Windows.Controls.Primitives.ButtonBase]$btn) {
    if ($null -eq $btn) { throw 'Button is null' }
    $clickEvent = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
    $args = [System.Windows.RoutedEventArgs]::new($clickEvent, $btn)
    $btn.RaiseEvent($args)
}

# A. Test Sidebar Navigation Buttons
Invoke-Click $navDisksItem.Button
if ($disksView.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'Disks view is not visible' }
Write-Output 'DISKS_VIEW_OK'

Invoke-Click $navOptionsItem.Button
if ($optionsView.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'Options view is not visible' }
Write-Output 'OPTIONS_VIEW_OK'

Invoke-Click $navAnalyticsItem.Button
if ($analyticsView.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'Analytics view is not visible' }
Write-Output 'ANALYTICS_VIEW_OK'

Invoke-Click $navLogsItem.Button
if ($logsView.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'Logs view is not visible' }
Write-Output 'LOGS_VIEW_OK'

Invoke-Click $navHelpItem.Button
if ($helpView.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'Help view is not visible' }
Write-Output 'HELP_VIEW_OK'

# Return to Disks view
Invoke-Click $navDisksItem.Button

# B. Test Disks View Toolbar Buttons
Invoke-Click $refreshBtn
Write-Output 'REFRESH_BTN_OK'

if ($null -eq $transfersBtn -or [string]::IsNullOrWhiteSpace($transfersBtn.Content)) { throw 'Transfers button invalid' }
Write-Output "TRANSFERS_BTN_OK: $($transfersBtn.Content)"

if ($null -eq $agentTransferBtn -or [string]::IsNullOrWhiteSpace($agentTransferBtn.Content)) { throw 'Agent transfer button invalid' }
Write-Output "AGENT_TRANSFER_BTN_OK: $($agentTransferBtn.Content)"

if ($null -eq $addDiskBtn -or [string]::IsNullOrWhiteSpace($addDiskBtn.Content)) { throw 'Add disk button invalid' }
Write-Output "ADD_DISK_BTN_OK: $($addDiskBtn.Content)"

# C. Test Options View Buttons and Toggles
Invoke-Click $navOptionsItem.Button

# Theme radio buttons
$rbThemePureWhite.IsChecked = $true
$rbThemePureBlack.IsChecked = $true
Write-Output 'THEME_SWITCH_OK'

# General checkboxes
$optStartupChk.IsChecked = (-not $optStartupChk.IsChecked)
$optStartupChk.IsChecked = (-not $optStartupChk.IsChecked)
$optTrayChk.IsChecked = (-not $optTrayChk.IsChecked)
$optTrayChk.IsChecked = (-not $optTrayChk.IsChecked)
$optStartMinChk.IsChecked = (-not $optStartMinChk.IsChecked)
$optStartMinChk.IsChecked = (-not $optStartMinChk.IsChecked)
$optExplorerChk.IsChecked = (-not $optExplorerChk.IsChecked)
$optExplorerChk.IsChecked = (-not $optExplorerChk.IsChecked)
$optAutoMountChk.IsChecked = (-not $optAutoMountChk.IsChecked)
$optAutoMountChk.IsChecked = (-not $optAutoMountChk.IsChecked)
Write-Output 'GENERAL_CHKS_OK'

# Notification checkboxes
$optNotifyMasterChk.IsChecked = (-not $optNotifyMasterChk.IsChecked)
$optNotifyMasterChk.IsChecked = (-not $optNotifyMasterChk.IsChecked)
$optNotifyStartChk.IsChecked = (-not $optNotifyStartChk.IsChecked)
$optNotifyStartChk.IsChecked = (-not $optNotifyStartChk.IsChecked)
$optNotifyCompleteChk.IsChecked = (-not $optNotifyCompleteChk.IsChecked)
$optNotifyCompleteChk.IsChecked = (-not $optNotifyCompleteChk.IsChecked)
$optNotifyGroupFolderChk.IsChecked = (-not $optNotifyGroupFolderChk.IsChecked)
$optNotifyGroupFolderChk.IsChecked = (-not $optNotifyGroupFolderChk.IsChecked)
Write-Output 'NOTIFY_CHKS_OK'

# D. Test Logs View Controls
Invoke-Click $navLogsItem.Button
Invoke-Click $logsRefreshBtn
if ($null -eq $logsSeverityCombo.SelectedItem) { throw 'Logs severity combo null' }
if ($null -eq $logsClearBtn) { throw 'Logs clear button null' }
if ($null -eq $logsOpenFolderBtn) { throw 'Logs open folder button null' }
Write-Output 'LOGS_CONTROLS_OK'

# E. Test Modal Dialog Declarations in ProviderConnectionWindow
if (-not (Get-Command 'Show-AddCloudDiskModal' -ErrorAction SilentlyContinue)) { throw 'Show-AddCloudDiskModal missing' }
if (-not (Get-Command 'Show-CloudAccountSetupModal' -ErrorAction SilentlyContinue)) { throw 'Show-CloudAccountSetupModal missing' }
if (-not (Get-Command 'Show-VpsSetupDialog' -ErrorAction SilentlyContinue)) { throw 'Show-VpsSetupDialog missing' }
if (-not (Get-Command 'Show-ProtonDriveSetupDialog' -ErrorAction SilentlyContinue)) { throw 'Show-ProtonDriveSetupDialog missing' }
if (-not (Get-Command 'Show-AgentTransferDialog' -ErrorAction SilentlyContinue)) { throw 'Show-AgentTransferDialog missing' }
if (-not (Get-Command 'Show-CloudTransferModal' -ErrorAction SilentlyContinue)) { throw 'Show-CloudTransferModal missing' }
Write-Output 'MODAL_DIALOGS_OK'

# Clean close
$window.Close()
Write-Output 'ALL_WORKER_STEPS_COMPLETED'
exit 0
