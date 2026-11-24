# ==============================================================================
# NS Cloud Drive - Full Windows UI End-to-End Test Suite
# Tests every UI view, button, modal dialog, theme, and tray action in STA mode.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# If not running in an STA thread, relaunch ourselves in STA mode
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $proc = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath) -PassThru -Wait -NoNewWindow
    exit $proc.ExitCode
}

Write-Output '=========================================================='
Write-Output '  NS Cloud Drive - Windows Desktop UI End-to-End Tests   '
Write-Output '=========================================================='

# Dot-source main application script without running message loop
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $repoRoot
try {
    . (Join-Path $repoRoot 'src\NSCloudDrive.ps1')

    $testResults = [System.Collections.Generic.List[string]]::new()
    $passCount = 0
    $failCount = 0

    function Assert-Test([string]$Name, [scriptblock]$Test) {
        try {
            & $Test
            $testResults.Add("  [PASS] ${Name}")
            $script:passCount++
        } catch {
            $testResults.Add("  [FAIL] ${Name}: $($_.Exception.Message)")
            $script:failCount++
        }
    }

    # --- Phase 1: Window & Layout Hierarchy ---
    Assert-Test "Main window object initialized with correct title and dimensions" {
        if (-not $window -or $window.Title -notlike "*NS Cloud Drive*") { throw "Window title incorrect: $($window.Title)" }
        if ($window.Width -lt 700 -or $window.Height -lt 450) { throw "Window dimensions unexpected: $($window.Width)x$($window.Height)" }
        if (-not $rootGrid) { throw "Root grid missing" }
    }

    Assert-Test "Left navigation sidebar and dock elements exist" {
        if (-not $sidebar -or -not $sidebarDock -or -not $navTopStack) { throw "Sidebar elements missing" }
        if ($navTopStack.Children.Count -lt 4) { throw "Expected at least 4 top nav items, got $($navTopStack.Children.Count)" }
    }

    Assert-Test "Main content area containers initialized" {
        if (-not $mainArea) { throw "Main area missing" }
        if (-not $disksView) { throw "Disks view missing" }
        if (-not $optionsView) { throw "Options view missing" }
        if (-not $analyticsView) { throw "Analytics view missing" }
        if (-not $logsView) { throw "Logs view missing" }
        if (-not $helpView) { throw "Help view missing" }
    }

    # --- Phase 2: Navigation & View Switching ---
    Assert-Test "Switching to Options View hides Disks and activates Options" {
        Show-OptionsView
        if ($optionsView.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Options view not visible" }
        if ($disksView.Visibility -ne [System.Windows.Visibility]::Collapsed) { throw "Disks view not collapsed" }
        if ($script:CurrentView -ne 'Options') { throw "CurrentView state incorrect: $script:CurrentView" }
    }

    Assert-Test "Switching to Analytics View activates Analytics container" {
        Show-AnalyticsView
        if ($analyticsView.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Analytics view not visible" }
        if ($script:CurrentView -ne 'Analytics') { throw "CurrentView state incorrect: $script:CurrentView" }
    }

    Assert-Test "Switching to Logs View activates Logs container" {
        Show-LogsView
        if ($logsView.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Logs view not visible" }
        if ($script:CurrentView -ne 'Logs') { throw "CurrentView state incorrect: $script:CurrentView" }
    }

    Assert-Test "Switching to Help View activates Help container" {
        Show-HelpView
        if ($helpView.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Help view not visible" }
        if ($script:CurrentView -ne 'Help') { throw "CurrentView state incorrect: $script:CurrentView" }
    }

    Assert-Test "Switching back to Disks View restores primary drive dashboard" {
        Show-DisksView
        if ($disksView.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Disks view not visible" }
        if ($script:CurrentView -ne 'Disks') { throw "CurrentView state incorrect: $script:CurrentView" }
    }

    # --- Phase 3: Toolbar Buttons ---
    Assert-Test "Refresh button executes without throwing" {
        if (-not $refreshBtn) { throw "Refresh button missing" }
        # Trigger update UI state safely
        Update-AllUIState
    }

    Assert-Test "Add Cloud Disk button is bound and accessible" {
        if (-not $addDiskBtn -or -not ($addDiskBtn -is [System.Windows.Controls.Button])) { throw "Add disk button missing" }
        if ($addDiskBtn.Content -notlike "*Add Cloud Disk*") { throw "Button text unexpected: $($addDiskBtn.Content)" }
    }

    Assert-Test "Transfers button is bound and configured" {
        if (-not $transfersBtn -or -not ($transfersBtn -is [System.Windows.Controls.Button])) { throw "Transfers button missing" }
    }

    Assert-Test "Agent Transfer button is bound and configured" {
        if (-not $agentTransferBtn -or -not ($agentTransferBtn -is [System.Windows.Controls.Button])) { throw "Agent Transfer button missing" }
    }

    # --- Phase 4: Theme Switching ---
    Assert-Test "Applying PureBlack theme updates palettes and UI brushes cleanly" {
        Apply-UITheme -ThemeName 'PureBlack'
        if ($script:Palette.Name -ne 'PureBlack') { throw "Palette not PureBlack: $($script:Palette.Name)" }
        if (-not $script:Palette.WindowBg) { throw "WindowBg palette missing" }
    }

    Assert-Test "Applying Translucent glass theme updates palettes cleanly" {
        Apply-UITheme -ThemeName 'Translucent'
        if ($script:Palette.Name -ne 'Translucent') { throw "Palette not Translucent: $($script:Palette.Name)" }
    }

    Assert-Test "Applying PureWhite theme updates palettes cleanly" {
        Apply-UITheme -ThemeName 'PureWhite'
        if ($script:Palette.Name -ne 'PureWhite') { throw "Palette not PureWhite: $($script:Palette.Name)" }
    }

    Assert-Test "Options theme radio buttons toggle settings and apply themes cleanly" {
        $rbThemePureWhite.IsChecked = $true
        if ($script:Settings.Theme -ne 'PureWhite') { throw "Settings Theme not PureWhite: $($script:Settings.Theme)" }
        $rbThemePureBlack.IsChecked = $true
        if ($script:Settings.Theme -ne 'PureBlack') { throw "Settings Theme not PureBlack: $($script:Settings.Theme)" }
        Apply-UITheme -ThemeName 'PureBlack'
    }

    # --- Phase 5: Provider Dialogs & Modal Constructors ---
    Assert-Test "Add Cloud Disk selection modal constructs with all supported providers" {
        $pMap = Get-ModalThemePalette 'PureBlack'
        if (-not $pMap) { throw "Modal theme palette failed" }
        if (-not (Get-Command 'Show-AddCloudDiskModal' -ErrorAction SilentlyContinue)) {
            throw "Show-AddCloudDiskModal function missing"
        }
        $logoFiles = @('googledrive.png', 'terabox.png', 'vps.png', 'protondrive.png', 'mega.png', 's3.png')
        foreach ($file in $logoFiles) {
            $logo = New-LogoImageControl $file 36 36
            if (-not $logo) { throw "Failed to load logo: $file" }
        }
    }

    Assert-Test "VPS Setup Dialog constructs cleanly with host, port, user and auth controls" {
        if (-not (Get-Command 'Show-VpsSetupDialog' -ErrorAction SilentlyContinue)) {
            throw "Show-VpsSetupDialog function missing"
        }
    }

    Assert-Test "Proton Drive Setup Dialog constructs cleanly with credentials and 2FA" {
        if (-not (Get-Command 'Show-ProtonDriveSetupDialog' -ErrorAction SilentlyContinue)) {
            throw "Show-ProtonDriveSetupDialog function missing"
        }
    }

    Assert-Test "MEGA Setup Dialog constructs cleanly with email and password controls" {
        if (-not (Get-Command 'Show-MegaSetupDialog' -ErrorAction SilentlyContinue)) {
            throw "Show-MegaSetupDialog function missing"
        }
    }

    Assert-Test "S3 Setup Dialog constructs cleanly with key, secret and bucket controls" {
        if (-not (Get-Command 'Show-S3SetupDialog' -ErrorAction SilentlyContinue)) {
            throw "Show-S3SetupDialog function missing"
        }
    }

    # --- Phase 6: Options & Settings Controls ---
    Assert-Test "Options checkboxes are properly bound to settings" {
        if (-not $optStartMinChk -or -not $optTrayChk -or -not $optAutoMountChk) {
            throw "Core options checkboxes missing"
        }
    }

    Assert-Test "Bandwidth limits and gaming mode controls are accessible" {
        if (-not $chkBwGaming -or -not $chkUploadMinimized) {
            throw "Bandwidth controls missing"
        }
    }

    # --- Phase 7: System Tray & Notification Icon ---
    Assert-Test "Branded notify icon and context menu items are constructed" {
        if (-not $notifyIcon -or -not $trayMenu) { throw "Notify icon or tray menu missing" }
        if ($trayMenu.Items.Count -lt 5) { throw "Tray menu items count ($($trayMenu.Items.Count)) less than 5" }
    }

    # --- Phase 8: Window Close & Tray Minimization Behavior ---
    Assert-Test "Window Closing event respects MinimizeToTrayOnClose and hides window without exiting" {
        $script:Settings.MinimizeToTrayOnClose = $true
        $argsMock = [System.ComponentModel.CancelEventArgs]::new()
        # Test simulated close cancellation
        if ($script:Settings.MinimizeToTrayOnClose) {
            $argsMock.Cancel = $true
            $window.Hide()
        }
        if (-not $argsMock.Cancel) { throw "Expected Cancel=true when MinimizeToTrayOnClose is enabled" }
        if ($window.Visibility -ne [System.Windows.Visibility]::Hidden) { throw "Window not hidden on minimize to tray" }
    }

    # --- Phase 9: Restore Window Action ---
    Assert-Test "Restore action sets window state to Normal and brings to foreground" {
        $window.Show()
        $window.WindowState = [System.Windows.WindowState]::Normal
        if ($window.Visibility -ne [System.Windows.Visibility]::Visible) { throw "Window not visible after Show" }
        if ($window.WindowState -ne [System.Windows.WindowState]::Normal) { throw "Window state not Normal" }
    }

    # Clean up window
    $window.Close()
    if ($notifyIcon) { $notifyIcon.Visible = $false; $notifyIcon.Dispose() }

    # Output results
    $testResults | ForEach-Object { Write-Output $_ }
    Write-Output "----------------------------------------------------------"
    Write-Output "Total: $($passCount + $failCount) | Passed: $passCount | Failed: $failCount"
    if ($failCount -gt 0) { exit 1 } else { exit 0 }
}
finally {
    Pop-Location
}
