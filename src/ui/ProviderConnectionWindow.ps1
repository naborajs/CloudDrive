Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot '..\providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot '..\services\CloudTransferManager.ps1')
. (Join-Path $PSScriptRoot '..\services\CacheManager.ps1')
. (Join-Path $PSScriptRoot 'EmbeddedBrowserWindow.ps1')

# Prevents nested account-creation flows. During authorization this module
# pumps WPF dispatcher frames, so a second Add Cloud Disk click can otherwise
# start a second full flow inside the first one; that nest is what turns a
# simple failure dialog into a broken window stack.
$script:CloudAccountCreationBusy = $false

function New-UIElement-Label([string]$Text, [int]$Size = 13, [string]$Color = '#172033', [bool]$Bold = $false) {
    $block = [System.Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $block.TextWrapping = 'Wrap'
    return $block
}

function New-LogoImageControl([string]$FileName, [int]$Width = 36, [int]$Height = 36) {
    $img = [System.Windows.Controls.Image]::new()
    $img.Width = $Width
    $img.Height = $Height
    $img.Stretch = [System.Windows.Media.Stretch]::Uniform
    $candidates = @(
        (Join-Path $PSScriptRoot "..\..\assets\logos\$FileName"),
        (Join-Path $PSScriptRoot "..\assets\logos\$FileName"),
        (Join-Path (Get-Location).Path "assets\logos\$FileName")
    )
    foreach ($cand in $candidates) {
        if (Test-Path -LiteralPath $cand -PathType Leaf) {
            try {
                $bi = [System.Windows.Media.Imaging.BitmapImage]::new()
                $bi.BeginInit()
                $bi.UriSource = [System.Uri]::new((Resolve-Path $cand).Path, [System.UriKind]::Absolute)
                $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $bi.EndInit()
                $img.Source = $bi
                break
            } catch { }
        }
    }
    return $img
}

function Show-GoogleClientConfigModal([System.Windows.Window]$Owner = $null) {
    $cfgWin = [System.Windows.Window]::new()
    $cfgWin.Title = 'Google Drive OAuth Setup'
    $cfgWin.Width = 500
    $cfgWin.Height = 260
    $cfgWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $cfgWin.Owner = $Owner }
    $cfgWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
    $cfgWin.ResizeMode = 'NoResize'

    $stack = [System.Windows.Controls.StackPanel]::new()
    $stack.Margin = [System.Windows.Thickness]::new(24)
    $cfgWin.Content = $stack

    $title = New-UIElement-Label 'Google Drive OAuth Client ID' 16 '#0F172A' $true
    $stack.Children.Add($title) | Out-Null

    $desc = New-UIElement-Label 'Enter your Google Cloud OAuth Client ID (or import a client_secret.json file):' 12 '#64748B'
    $desc.Margin = [System.Windows.Thickness]::new(0, 6, 0, 12)
    $stack.Children.Add($desc) | Out-Null

    $txtClientId = [System.Windows.Controls.TextBox]::new()
    $txtClientId.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $txtClientId.FontSize = 12
    $txtClientId.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $existing = Get-GoogleOAuthConfig
    if ($existing.ClientId -and -not $existing.ClientId.Contains('YOUR_GOOGLE_CLIENT_ID')) {
        $txtClientId.Text = $existing.ClientId
    }
    $stack.Children.Add($txtClientId) | Out-Null

    $btnRow = [System.Windows.Controls.DockPanel]::new()
    $stack.Children.Add($btnRow) | Out-Null

    $browseBtn = [System.Windows.Controls.Button]::new()
    $browseBtn.Content = 'Import JSON...'
    $browseBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    [System.Windows.Controls.DockPanel]::SetDock($browseBtn, 'Left')
    $browseBtn.Add_Click({
        $ofd = [Microsoft.Win32.OpenFileDialog]::new()
        $ofd.Filter = 'JSON Credentials (*.json)|*.json|All Files (*.*)|*.*'
        $ofd.Title = 'Select Google OAuth client_secret.json'
        if ($ofd.ShowDialog($cfgWin) -eq $true) {
            try {
                $imported = Import-GoogleOAuthConfigFile -SourceFilePath $ofd.FileName
                if ($imported.ClientId) {
                    $txtClientId.Text = $imported.ClientId
                }
            } catch {
                [System.Windows.MessageBox]::Show("Could not import: $($_.Exception.Message)", 'Import Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        }
    })
    $btnRow.Children.Add($browseBtn) | Out-Null

    $rightBtns = [System.Windows.Controls.StackPanel]::new()
    $rightBtns.Orientation = 'Horizontal'
    [System.Windows.Controls.DockPanel]::SetDock($rightBtns, 'Right')
    $btnRow.Children.Add($rightBtns) | Out-Null

    $saveBtn = [System.Windows.Controls.Button]::new()
    $saveBtn.Content = 'Save & Continue'
    $saveBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
    $saveBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
    $saveBtn.Foreground = [System.Windows.Media.Brushes]::White
    $saveBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $saveBtn.BorderThickness = [System.Windows.Thickness]::new(0)

    $cancelBtn = [System.Windows.Controls.Button]::new()
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $cancelBtn.Add_Click({ $cfgWin.Close() })

    $script:CfgSuccess = $false
    $saveBtn.Add_Click({
        $val = $txtClientId.Text.Trim()
        if (-not [string]::IsNullOrEmpty($val)) {
            $configDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config'
            if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
            $cfgFile = Join-Path $configDir 'google-oauth.json'
            $json = [ordered]@{
                installed = [ordered]@{
                    client_id = $val
                    auth_uri = 'https://accounts.google.com/o/oauth2/v2/auth'
                    token_uri = 'https://oauth2.googleapis.com/token'
                }
            } | ConvertTo-Json -Depth 4
            Set-Content -LiteralPath $cfgFile -Value $json -Force -Encoding UTF8
            $script:CfgSuccess = $true
            $cfgWin.Close()
        }
    })

    $rightBtns.Children.Add($saveBtn) | Out-Null
    $rightBtns.Children.Add($cancelBtn) | Out-Null

    [void]$cfgWin.ShowDialog()
    return [ordered]@{ Success = $script:CfgSuccess }
}

function Show-SettingsModal([System.Windows.Window]$Owner = $null, [scriptblock]$OnSettingsChanged = $null) {
    $settings = Get-NSCloudDriveSettings

    $setWin = [System.Windows.Window]::new()
    $setWin.Title = 'Options - NS Cloud Drive'
    $setWin.Width = 520
    $setWin.Height = 520
    $setWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $setWin.Owner = $Owner }
    $setWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#18191C')
    $setWin.ResizeMode = 'NoResize'
    $setWin.FontFamily = 'Segoe UI'

    $dock = [System.Windows.Controls.DockPanel]::new()
    $dock.Margin = [System.Windows.Thickness]::new(20)
    $setWin.Content = $dock

    $hdr = New-UIElement-Label '⚙ Options & Preferences' 18 '#F2F3F5' $true
    [System.Windows.Controls.DockPanel]::SetDock($hdr, 'Top')
    $hdr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $dock.Children.Add($hdr) | Out-Null

    $closeBtn = [System.Windows.Controls.Button]::new()
    $closeBtn.Content = 'Done'
    $closeBtn.Padding = [System.Windows.Thickness]::new(20, 8, 20, 8)
    $closeBtn.HorizontalAlignment = 'Right'
    $closeBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
    $closeBtn.Foreground = [System.Windows.Media.Brushes]::White
    $closeBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
    $closeBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    [System.Windows.Controls.DockPanel]::SetDock($closeBtn, 'Bottom')
    $closeBtn.Add_Click({ $setWin.Close() })
    $dock.Children.Add($closeBtn) | Out-Null

    $stack = [System.Windows.Controls.StackPanel]::new()
    $dock.Children.Add($stack) | Out-Null

    # Startup & Background Group
    $bgCard = [System.Windows.Controls.Border]::new()
    $bgCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
    $bgCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
    $bgCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $bgCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $bgCard.Padding = [System.Windows.Thickness]::new(14)
    $bgCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $bgStack = [System.Windows.Controls.StackPanel]::new()
    $bgCard.Child = $bgStack

    $bgStack.Children.Add((New-UIElement-Label 'General Options' 14 '#F2F3F5' $true)) | Out-Null

    $chkStartup = [System.Windows.Controls.CheckBox]::new()
    $chkStartup.Content = 'Run NS Cloud Drive at login'
    $chkStartup.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
    $chkStartup.IsChecked = (Test-WindowsStartupEnabled)
    $chkStartup.Margin = [System.Windows.Thickness]::new(0, 10, 0, 8)
    $chkStartup.Add_Click({
        $checked = ($chkStartup.IsChecked -eq $true)
        Set-WindowsStartupEnabled -Enable $checked
        $settings.AutoStartWithWindows = $checked
        Set-NSCloudDriveSettings $settings
        if ($OnSettingsChanged) { & $OnSettingsChanged }
    })
    $bgStack.Children.Add($chkStartup) | Out-Null

    $chkAutoMount = [System.Windows.Controls.CheckBox]::new()
    $chkAutoMount.Content = 'Automatically mount connected drives on startup'
    $chkAutoMount.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
    $chkAutoMount.IsChecked = $settings.AutoMountDrives
    $chkAutoMount.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $chkAutoMount.Add_Click({
        $settings.AutoMountDrives = ($chkAutoMount.IsChecked -eq $true)
        Set-NSCloudDriveSettings $settings
        if ($OnSettingsChanged) { & $OnSettingsChanged }
    })
    $bgStack.Children.Add($chkAutoMount) | Out-Null

    $chkTray = [System.Windows.Controls.CheckBox]::new()
    $chkTray.Content = 'Minimize to tray area'
    $chkTray.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
    $chkTray.IsChecked = $settings.MinimizeToTrayOnClose
    $chkTray.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $chkTray.Add_Click({
        $settings.MinimizeToTrayOnClose = ($chkTray.IsChecked -eq $true)
        Set-NSCloudDriveSettings $settings
        if ($OnSettingsChanged) { & $OnSettingsChanged }
    })
    $bgStack.Children.Add($chkTray) | Out-Null

    $chkStartMin = [System.Windows.Controls.CheckBox]::new()
    $chkStartMin.Content = 'Start Minimized'
    $chkStartMin.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
    $chkStartMin.IsChecked = $settings.StartMinimized
    $chkStartMin.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $chkStartMin.Add_Click({
        $settings.StartMinimized = ($chkStartMin.IsChecked -eq $true)
        Set-NSCloudDriveSettings $settings
        if ($OnSettingsChanged) { & $OnSettingsChanged }
    })
    $bgStack.Children.Add($chkStartMin) | Out-Null

    $chkOpenExp = [System.Windows.Controls.CheckBox]::new()
    $chkOpenExp.Content = 'Open File Explorer when a drive has connected'
    $chkOpenExp.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
    $chkOpenExp.IsChecked = $settings.OpenExplorerOnMount
    $chkOpenExp.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $chkOpenExp.Add_Click({
        $settings.OpenExplorerOnMount = ($chkOpenExp.IsChecked -eq $true)
        Set-NSCloudDriveSettings $settings
        if ($OnSettingsChanged) { & $OnSettingsChanged }
    })
    $bgStack.Children.Add($chkOpenExp) | Out-Null
    $stack.Children.Add($bgCard) | Out-Null

    # Cache Group
    $cacheCard = [System.Windows.Controls.Border]::new()
    $cacheCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
    $cacheCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
    $cacheCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $cacheCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $cacheCard.Padding = [System.Windows.Thickness]::new(14)
    $cacheStack = [System.Windows.Controls.StackPanel]::new()
    $cacheCard.Child = $cacheStack

    $cacheStack.Children.Add((New-UIElement-Label 'Local Disk Cache' 14 '#F2F3F5' $true)) | Out-Null

    $cacheDir = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
    $cStats = Get-CacheUsageStatistics -CacheDirectory $cacheDir
    $cacheInfo = New-UIElement-Label "Directory: $cacheDir`nUsage: $($cStats.UsedFormatted) / $($cStats.TargetMaxFormatted) soft limit ($($cStats.VolumeFreeFormatted) free on volume)" 12 '#949BA4'
    $cacheInfo.Margin = [System.Windows.Thickness]::new(0, 6, 0, 10)
    $cacheStack.Children.Add($cacheInfo) | Out-Null

    $cacheBtns = [System.Windows.Controls.StackPanel]::new()
    $cacheBtns.Orientation = 'Horizontal'

    $openCacheBtn = [System.Windows.Controls.Button]::new()
    $openCacheBtn.Content = 'Open Cache Folder'
    $openCacheBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $openCacheBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
    $openCacheBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $openCacheBtn.Foreground = [System.Windows.Media.Brushes]::White
    $openCacheBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $openCacheBtn.Add_Click({
        if (-not (Test-Path -LiteralPath $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }
        [System.Diagnostics.Process]::Start('explorer.exe', $cacheDir) | Out-Null
    })
    $cacheBtns.Children.Add($openCacheBtn) | Out-Null

    $cleanCacheBtn = [System.Windows.Controls.Button]::new()
    $cleanCacheBtn.Content = 'Clean Cache'
    $cleanCacheBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $cleanCacheBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
    $cleanCacheBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $cleanCacheBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
    $cleanCacheBtn.Add_Click({
        try {
            if (Test-Path -LiteralPath $cacheDir) {
                Get-ChildItem -Path $cacheDir -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            [System.Windows.MessageBox]::Show('Cache cleaned successfully.', 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        } catch { }
    })
    $cacheBtns.Children.Add($cleanCacheBtn) | Out-Null

    $cacheStack.Children.Add($cacheBtns) | Out-Null
    $stack.Children.Add($cacheCard) | Out-Null

    [void]$setWin.ShowDialog()
}

function Get-ModalThemePalette([string]$ThemeName = '') {
    $t = if (-not [string]::IsNullOrEmpty($ThemeName)) {
        Resolve-AppTheme $ThemeName
    } else {
        try { Resolve-AppTheme (Get-NSCloudDriveSettings).Theme } catch { 'PureBlack' }
    }

    if ($t -eq 'PureWhite') {
        return @{
            Background = '#FFFFFF'
            Border = '#E5E7EB'
            CardBg = '#F9FAFB'
            CardBorder = '#E5E7EB'
            TextPrimary = '#111827'
            TextMuted = '#6B7280'
            InputBg = '#FFFFFF'
            InputBorder = '#D1D5DB'
            InputText = '#111827'
            CancelBg = '#F3F4F6'
            CancelBorder = '#E5E7EB'
            CancelText = '#374151'
        }
    } elseif ($t -eq 'Translucent') {
        return @{
            Background = '#181B22'
            Border = '#2D3342'
            CardBg = '#222734'
            CardBorder = '#363E50'
            TextPrimary = '#FFFFFF'
            TextMuted = '#94A3B8'
            InputBg = '#1C202B'
            InputBorder = '#363E50'
            InputText = '#FFFFFF'
            CancelBg = '#2B3142'
            CancelBorder = '#363E50'
            CancelText = '#DBDEE1'
        }
    } else {
        return @{
            Background = '#000000'
            Border = '#222222'
            CardBg = '#121212'
            CardBorder = '#262626'
            TextPrimary = '#FFFFFF'
            TextMuted = '#A0A0A0'
            InputBg = '#161616'
            InputBorder = '#2E2E2E'
            InputText = '#FFFFFF'
            CancelBg = '#1E1E1E'
            CancelBorder = '#2E2E2E'
            CancelText = '#D4D4D4'
        }
    }
}

function Show-AddCloudDiskModal([System.Windows.Window]$Owner = $null, [scriptblock]$OnProviderSelected = $null, [string]$Theme = '') {
    $p = Get-ModalThemePalette $Theme
    $addWin = [System.Windows.Window]::new()
    $addWin.Title = 'Add Cloud Disk'
    $addWin.Width = 520
    $addWin.Height = 360
    $addWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $addWin.Owner = $Owner }
    $addWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Background)
    $addWin.ResizeMode = 'NoResize'
    $addWin.FontFamily = 'Segoe UI'

    $dock = [System.Windows.Controls.DockPanel]::new()
    $dock.Margin = [System.Windows.Thickness]::new(20)
    $addWin.Content = $dock

    # Header
    $headerStack = [System.Windows.Controls.StackPanel]::new()
    [System.Windows.Controls.DockPanel]::SetDock($headerStack, 'Top')
    $headerStack.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $title = New-UIElement-Label 'Add Cloud Disk' 18 $p.TextPrimary $true
    $headerStack.Children.Add($title) | Out-Null
    $subtitle = New-UIElement-Label 'Select a supported cloud storage provider to mount as a Windows drive.' 12 $p.TextMuted
    $subtitle.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $headerStack.Children.Add($subtitle) | Out-Null
    $dock.Children.Add($headerStack) | Out-Null

    # Bottom button (Cancel)
    $cancelBtn = [System.Windows.Controls.Button]::new()
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $cancelBtn.HorizontalAlignment = 'Right'
    $cancelBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBg)
    $cancelBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBorder)
    $cancelBtn.BorderThickness = [System.Windows.Thickness]::new(1)
    $cancelBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelText)
    [System.Windows.Controls.DockPanel]::SetDock($cancelBtn, 'Bottom')
    $cancelBtn.Add_Click({ $addWin.Close() })
    $dock.Children.Add($cancelBtn) | Out-Null

    # Provider Options List
    $listStack = [System.Windows.Controls.StackPanel]::new()
    $dock.Children.Add($listStack) | Out-Null

    $script:SelectedProvider = $null

    # Provider 1: Google Drive
    $gdBorder = [System.Windows.Controls.Border]::new()
    $gdBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
    $gdBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    $gdBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $gdBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $gdBorder.Padding = [System.Windows.Thickness]::new(14)
    $gdBorder.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $gdBorder.Cursor = [System.Windows.Input.Cursors]::Hand

    $gdDock = [System.Windows.Controls.DockPanel]::new()
    $gdBorder.Child = $gdDock

    $gdBtn = [System.Windows.Controls.Button]::new()
    $gdBtn.Content = 'Select'
    $gdBtn.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $gdBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
    $gdBtn.Foreground = [System.Windows.Media.Brushes]::White
    $gdBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
    $gdBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    [System.Windows.Controls.DockPanel]::SetDock($gdBtn, 'Right')
    $gdDock.Children.Add($gdBtn) | Out-Null

    $gdLeft = [System.Windows.Controls.StackPanel]::new()
    $gdLeft.Orientation = 'Horizontal'
    $gdDock.Children.Add($gdLeft) | Out-Null

    $gdLogoImg = New-LogoImageControl 'googledrive.png' 38 38
    $gdLogoImg.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $gdLeft.Children.Add($gdLogoImg) | Out-Null

    $gdText = [System.Windows.Controls.StackPanel]::new()
    $gdText.Children.Add((New-UIElement-Label 'Google Drive' 15 $p.TextPrimary $true)) | Out-Null
    $gdText.Children.Add((New-UIElement-Label 'Personal & Workspace cloud storage via Google OAuth 2.0' 12 $p.TextMuted)) | Out-Null
    $gdLeft.Children.Add($gdText) | Out-Null

    $SelectGD = {
        if ($script:CloudAccountCreationBusy) { return }
        $script:SelectedProvider = 'gdrive'
        # Defer the provider flow to the Closed event so the modal is fully
        # torn down before the long-running authorization starts, and so any
        # failure inside the flow is reported as a dialog instead of bubbling
        # through the WPF event pipeline.
        $addWin.Add_Closed({
            if ($OnProviderSelected) {
                try {
                    & $OnProviderSelected 'gdrive' | Out-Null
                } catch {
                    try {
                        $crashReason = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
                        [System.Windows.MessageBox]::Show("Account creation failed unexpectedly: $crashReason", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                    } catch { }
                }
            }
        })
        $addWin.Close()
    }
    $gdBtn.Add_Click($SelectGD)
    $gdBorder.Add_MouseLeftButtonDown($SelectGD)
    $listStack.Children.Add($gdBorder) | Out-Null

    # Provider 2: TeraBox
    $tbBorder = [System.Windows.Controls.Border]::new()
    $tbBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
    $tbBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    $tbBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $tbBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $tbBorder.Padding = [System.Windows.Thickness]::new(14)
    $tbBorder.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $tbBorder.Cursor = [System.Windows.Input.Cursors]::Hand

    $tbDock = [System.Windows.Controls.DockPanel]::new()
    $tbBorder.Child = $tbDock

    $tbBtn = [System.Windows.Controls.Button]::new()
    $tbBtn.Content = 'Select'
    $tbBtn.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $tbBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
    $tbBtn.Foreground = [System.Windows.Media.Brushes]::White
    $tbBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
    $tbBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    [System.Windows.Controls.DockPanel]::SetDock($tbBtn, 'Right')
    $tbDock.Children.Add($tbBtn) | Out-Null

    $tbLeft = [System.Windows.Controls.StackPanel]::new()
    $tbLeft.Orientation = 'Horizontal'
    $tbDock.Children.Add($tbLeft) | Out-Null

    $tbLogoImg = New-LogoImageControl 'terabox.png' 38 38
    $tbLogoImg.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $tbLeft.Children.Add($tbLogoImg) | Out-Null

    $tbText = [System.Windows.Controls.StackPanel]::new()
    $tbText.Children.Add((New-UIElement-Label 'TeraBox' 15 $p.TextPrimary $true)) | Out-Null
    $tbText.Children.Add((New-UIElement-Label '1024 GB free cloud storage via WebDAV loopback bridge' 12 $p.TextMuted)) | Out-Null
    $tbLeft.Children.Add($tbText) | Out-Null

    $SelectTB = {
        if ($script:CloudAccountCreationBusy) { return }
        $script:SelectedProvider = 'terabox'
        # Same Closed-event deferral as the Google Drive card above.
        $addWin.Add_Closed({
            if ($OnProviderSelected) {
                try {
                    & $OnProviderSelected 'terabox' | Out-Null
                } catch {
                    try {
                        $crashReason = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
                        [System.Windows.MessageBox]::Show("Account creation failed unexpectedly: $crashReason", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                    } catch { }
                }
            }
        })
        $addWin.Close()
    }
    $tbBtn.Add_Click($SelectTB)
    $tbBorder.Add_MouseLeftButtonDown($SelectTB)
    $listStack.Children.Add($tbBorder) | Out-Null

    [void]$addWin.ShowDialog()
    return [ordered]@{ SelectedProvider = $script:SelectedProvider }
}

function Show-CloudAccountSetupModal(
    [System.Windows.Window]$Owner = $null,
    [string]$ProviderId = 'gdrive',
    [hashtable]$InitialAccount = $null,
    [string]$Theme = ''
) {
    $p = Get-ModalThemePalette $Theme
    $setupWin = [System.Windows.Window]::new()
    $isEdit = ($InitialAccount -and $InitialAccount.ContainsKey('Id') -and (Test-CloudAccountPersisted -AccountId ([string]$InitialAccount.Id)))
    $provName = if ($ProviderId -eq 'terabox') { 'TeraBox' } else { 'Google Drive' }
    $setupWin.Title = if ($isEdit) { "Configure $provName Account" } else { "Add $provName Disk" }
    $setupWin.Width = 470
    $setupWin.Height = 440
    $setupWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $setupWin.Owner = $Owner }
    $setupWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Background)
    $setupWin.ResizeMode = 'NoResize'
    $setupWin.FontFamily = 'Segoe UI'

    $stack = [System.Windows.Controls.StackPanel]::new()
    $stack.Margin = [System.Windows.Thickness]::new(24)
    $setupWin.Content = $stack

    # Header
    $title = New-UIElement-Label $(if ($isEdit) { "Configure $provName Disk" } else { "Add $provName Disk" }) 16 $p.TextPrimary $true
    $stack.Children.Add($title) | Out-Null

    $sub = New-UIElement-Label 'Configure account display name, drive letter, and mounting options.' 12 $p.TextMuted
    $sub.Margin = [System.Windows.Thickness]::new(0, 4, 0, 16)
    $stack.Children.Add($sub) | Out-Null

    # Account Name field
    $lbl1 = New-UIElement-Label 'Disk / Account Name' 12 $p.TextPrimary $true
    $stack.Children.Add($lbl1) | Out-Null

    $txtName = [System.Windows.Controls.TextBox]::new()
    $txtName.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $txtName.Margin = [System.Windows.Thickness]::new(0, 4, 0, 14)
    $txtName.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBg)
    $txtName.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)
    $txtName.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputText)
    $defaultName = if ($InitialAccount -and $InitialAccount.ContainsKey('DisplayName')) {
        [string]$InitialAccount.DisplayName
    } elseif ($ProviderId -eq 'terabox') {
        'TeraBox'
    } else {
        'Google Drive'
    }
    $txtName.Text = $defaultName
    $stack.Children.Add($txtName) | Out-Null

    # Drive Letter field
    $lbl2 = New-UIElement-Label 'Windows Drive Letter' 12 $p.TextPrimary $true
    $stack.Children.Add($lbl2) | Out-Null

    $cmbLetter = [System.Windows.Controls.ComboBox]::new()
    $cmbLetter.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $cmbLetter.Margin = [System.Windows.Thickness]::new(0, 4, 0, 14)

    # Populate drive letter choices
    $prefDefault = if ($ProviderId -eq 'terabox') { 'T' } else { 'G' }
    $currentLetter = if ($InitialAccount -and $InitialAccount.ContainsKey('DriveLetter') -and $InitialAccount.DriveLetter) {
        [string]$InitialAccount.DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    } else {
        (Get-NextAvailableDriveLetter $prefDefault)
    }

    $allLetters = @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')
    $allocated = Get-AllocatedDriveLetters
    $sysDrives = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            $sysDrives += $d.Name.Substring(0, 1).ToUpperInvariant()
        }
    } catch { }

    $selectedIdx = 0
    $idx = 0
    foreach ($let in $allLetters) {
        $isCurrent = ($let -eq $currentLetter)
        $isOccupied = ($sysDrives -contains $let) -or ($allocated -contains $let)
        if ($isCurrent -or -not $isOccupied) {
            $item = [System.Windows.Controls.ComboBoxItem]::new()
            $item.Content = "$let`: Drive"
            $item.Tag = $let
            [void]$cmbLetter.Items.Add($item)
            if ($isCurrent) { $selectedIdx = $idx }
            $idx++
        }
    }
    if ($cmbLetter.Items.Count -gt 0) {
        $cmbLetter.SelectedIndex = $selectedIdx
    }
    $stack.Children.Add($cmbLetter) | Out-Null

    # CheckBoxes
    $chkAutoMount = [System.Windows.Controls.CheckBox]::new()
    $chkAutoMount.Content = 'Automatically mount this drive on startup'
    $chkAutoMount.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $chkAutoMount.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $chkAutoMount.IsChecked = if ($InitialAccount -and $InitialAccount.ContainsKey('AutoMount') -and $null -ne $InitialAccount.AutoMount) {
        [bool]$InitialAccount.AutoMount
    } else {
        $true
    }
    $stack.Children.Add($chkAutoMount) | Out-Null

    $chkOpenExplorer = [System.Windows.Controls.CheckBox]::new()
    $chkOpenExplorer.Content = 'Open Windows File Explorer automatically after mounting'
    $chkOpenExplorer.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $chkOpenExplorer.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $chkOpenExplorer.IsChecked = if ($InitialAccount -and $InitialAccount.ContainsKey('OpenExplorerOnMount') -and $null -ne $InitialAccount.OpenExplorerOnMount) {
        [bool]$InitialAccount.OpenExplorerOnMount
    } else {
        $true
    }
    $stack.Children.Add($chkOpenExplorer) | Out-Null

    $chkReadOnly = [System.Windows.Controls.CheckBox]::new()
    $chkReadOnly.Content = 'Mount as read-only disk (protect cloud files against modifications)'
    $chkReadOnly.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextMuted)
    $chkReadOnly.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
    $chkReadOnly.IsChecked = if ($InitialAccount -and $InitialAccount.ContainsKey('ReadOnly') -and $null -ne $InitialAccount.ReadOnly) {
        [bool]$InitialAccount.ReadOnly
    } else {
        $false
    }
    $stack.Children.Add($chkReadOnly) | Out-Null

    # Buttons
    $btnDock = [System.Windows.Controls.DockPanel]::new()
    $stack.Children.Add($btnDock) | Out-Null

    $btnStack = [System.Windows.Controls.StackPanel]::new()
    $btnStack.Orientation = 'Horizontal'
    [System.Windows.Controls.DockPanel]::SetDock($btnStack, 'Right')
    $btnDock.Children.Add($btnStack) | Out-Null

    $saveBtn = [System.Windows.Controls.Button]::new()
    $saveBtn.Content = if ($isEdit) { 'Save Changes' } else { 'Add Disk' }
    $saveBtn.Padding = [System.Windows.Thickness]::new(16, 7, 16, 7)
    $accent = if ($ProviderId -eq 'terabox') { '#2563EB' } else { '#0F9D58' }
    $saveBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accent)
    $saveBtn.Foreground = [System.Windows.Media.Brushes]::White
    $saveBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
    $saveBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $saveBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $btnStack.Children.Add($saveBtn) | Out-Null

    $cancelBtn = [System.Windows.Controls.Button]::new()
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(12, 7, 12, 7)
    $cancelBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBg)
    $cancelBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBorder)
    $cancelBtn.BorderThickness = [System.Windows.Thickness]::new(1)
    $cancelBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelText)
    $cancelBtn.Add_Click({ $setupWin.Close() })
    $btnStack.Children.Add($cancelBtn) | Out-Null

    $script:SavedAccountResult = $null

    $saveBtn.Add_Click({
        $name = $txtName.Text.Trim()
        if ([string]::IsNullOrEmpty($name)) {
            $name = if ($ProviderId -eq 'terabox') { 'TeraBox' } else { 'Google Drive' }
        }

        $letter = $prefDefault
        if ($cmbLetter.SelectedItem -and $cmbLetter.SelectedItem.Tag) {
            $letter = [string]$cmbLetter.SelectedItem.Tag
        }

        $accId = if ($InitialAccount -and $InitialAccount.ContainsKey('Id') -and $InitialAccount.Id) {
            [string]$InitialAccount.Id
        } else {
            "${ProviderId}_" + [Guid]::NewGuid().ToString('N')
        }

        $accObj = [ordered]@{
            Id = $accId
            ProviderId = $ProviderId
            DisplayName = $name
            AccountEmail = if ($InitialAccount -and $InitialAccount.ContainsKey('AccountEmail')) { [string]$InitialAccount.AccountEmail } else { '' }
            DriveLetter = $letter
            AutoMount = [bool]$chkAutoMount.IsChecked
            OpenExplorerOnMount = [bool]$chkOpenExplorer.IsChecked
            ReadOnly = [bool]$chkReadOnly.IsChecked
            CustomIcon = if ($InitialAccount -and $InitialAccount.ContainsKey('CustomIcon')) { [string]$InitialAccount.CustomIcon } else { $null }
            Created = if ($isEdit -and $InitialAccount.ContainsKey('Created')) { [string]$InitialAccount.Created } else { [DateTime]::UtcNow.ToString('o') }
        }

        try {
            if ($isEdit) {
                $saved = Update-CloudAccount $accObj
            } else {
                $saved = Add-CloudAccount $accObj
            }
            if (-not $saved) { throw 'The account save operation returned no saved record.' }
            $script:SavedAccountResult = $saved
            $setupWin.Close()
        } catch {
            [System.Windows.MessageBox]::Show("Could not save this cloud account. $($_.Exception.Message)", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        }
    })

    [void]$setupWin.ShowDialog()
    return $script:SavedAccountResult
}

function Connect-NewCloudAccount([System.Windows.Window]$Owner = $null, [string]$ProviderId = 'gdrive') {
    if ($script:CloudAccountCreationBusy) {
        [System.Windows.MessageBox]::Show('An account is already being created. Finish or cancel the current flow before starting another.', 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return $null
    }
    $script:CloudAccountCreationBusy = $true
    try {
        return (New-CloudAccountRecord -Owner $Owner -ProviderId $ProviderId)
    } catch {
        # A failed creation attempt must never bubble into the WPF event
        # pipeline (unhandled exception) and must never escalate into an
        # application crash. The exception text is sanitized and actionable.
        $reason = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
        [System.Windows.MessageBox]::Show("Account creation failed unexpectedly: $reason`n`nThe application remains usable. No account data was modified. You can retry.", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return $null
    } finally {
        $script:CloudAccountCreationBusy = $false
    }
}

function New-CloudAccountRecord([System.Windows.Window]$Owner = $null, [string]$ProviderId = 'gdrive') {
    if ($ProviderId -eq 'gdrive') {
        $accId = "gdrive_" + [Guid]::NewGuid().ToString('N')
        $authRes = Invoke-GoogleDriveAuthorization -AccountId $accId
        if (-not $authRes.Success) {
            [System.Windows.MessageBox]::Show("Google Drive sign-in: $($authRes.Error)", 'Google Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return $null
        }

        # Identity verification with an explicit retry path. The fresh
        # authorization result is safely stored for the new account id under
        # DPAPI, so verification can be retried without signing in again.
        # The final 'Google Drive User' placeholder from the rclone fallback
        # is never treated as a verified identity for an unsaved account.
        $identityOk = $false
        $userEmail = ''
        $userName = ''
        $reason = ''
        $retryAttempt = 0
        while ($true) {
            $verify = Test-GoogleDriveBackendSession -TokensOverride $authRes.Tokens -AccountId $accId
            $userEmail = if ($verify.IsValid -and $verify.UserInfo) { [string](Get-SafeProperty $verify.UserInfo 'EmailAddress' '') } else { '' }
            $userName = if ($verify.IsValid -and $verify.UserInfo) { [string](Get-SafeProperty $verify.UserInfo 'DisplayName' '') } else { '' }
            $reason = Get-GoogleIdentityFailureReason $verify
            if (-not $reason) { $reason = 'Google did not return a verifiable account identity.' }

            $identityOk = $false
            if ($verify.IsValid) {
                $flagVerified = [bool](Get-SafeProperty $verify 'IdentityVerified' $false)
                if ($flagVerified) {
                    $identityOk = $true
                } elseif ( ($userEmail -match '@') -or ($userName -and $userName -ne 'Google Drive User') ) {
                    # Identity text that is neither empty nor the generic
                    # placeholder came from Google APIs or persisted metadata
                    # that was itself verified when the account was saved.
                    $identityOk = $true
                }
            }

            if ($identityOk) { break }

            $prompt = "Google authorization succeeded, but the account identity could not be verified. No account will be added.`n`nReason: $reason`n`nThe authorization was received. Retry the identity check without signing in again?"
            $choice = [System.Windows.MessageBox]::Show($prompt, 'Google Drive', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            if ($choice -eq [System.Windows.MessageBoxResult]::Yes -and $retryAttempt -lt 2) {
                $retryAttempt++
                continue
            }
            break
        }

        if (-not $identityOk) {
            # Discard the failed attempt cleanly: the fresh tokens are revoked
            # and removed so no half-authorized residue stays on disk, and the
            # user gets the exact failure reason to act on.
            Remove-GoogleDriveSession -AccountId $accId
            [System.Windows.MessageBox]::Show("Google authorization succeeded, but the account identity could not be verified. No account was added.`n`nReason: $reason`n`nThe received authorization was discarded for security. No saved accounts were changed. You can retry via Add Cloud Disk.", 'Google Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return $null
        }

        if ($userEmail) {
            $existing = Get-CloudAccounts
            foreach ($account in $existing) {
                if ($account.ProviderId -eq 'gdrive' -and $account.AccountEmail -and [string]::Equals([string]$account.AccountEmail, $userEmail, [StringComparison]::OrdinalIgnoreCase)) {
                    Remove-GoogleDriveSession -AccountId $accId
                    [System.Windows.MessageBox]::Show("This Google account is already saved as '$($account.DisplayName)' on $($account.DriveLetter):. The existing account was left unchanged.", 'Google Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
                    return $null
                }
            }
        }

        $nextLetter = Get-NextAvailableDriveLetter 'G'
        $initData = @{
            Id = $accId
            ProviderId = 'gdrive'
            DisplayName = if ($userName) { "Google Drive ($userName)" } else { "Google Drive" }
            AccountEmail = $userEmail
            DriveLetter = $nextLetter
            AutoMount = $true
        }

        $saved = Show-CloudAccountSetupModal -Owner $Owner -ProviderId 'gdrive' -InitialAccount $initData
        if (-not $saved) { Remove-GoogleDriveSession -AccountId $accId }
        return $saved

    } elseif ($ProviderId -eq 'terabox') {
        $accId = "terabox_" + [Guid]::NewGuid().ToString('N')
        $loginRes = Show-TeraBoxEmbeddedLoginWindow -Owner $Owner -AccountId $accId
        if (-not $loginRes.Success) {
            if (-not $loginRes.Cancelled) {
                [System.Windows.MessageBox]::Show("TeraBox sign-in failed: $($loginRes.Error)", 'TeraBox', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
            return $null
        }

        $nextLetter = Get-NextAvailableDriveLetter 'T'
        $initData = @{
            Id = $accId
            ProviderId = 'terabox'
            DisplayName = if ($loginRes.UserName) { "TeraBox ($($loginRes.UserName))" } else { "TeraBox" }
            AccountEmail = if ($loginRes.UserName) { $loginRes.UserName } else { '' }
            DriveLetter = $nextLetter
            AutoMount = $true
        }

        $saved = Show-CloudAccountSetupModal -Owner $Owner -ProviderId 'terabox' -InitialAccount $initData
        if (-not $saved) { Remove-TeraBoxSession -AccountId $accId }
        return $saved
    }

    return $null
}

function Show-DiagnosticsModal([System.Windows.Window]$Owner = $null) {
    $settings = Get-NSCloudDriveSettings
    $cacheDir = if ($settings.CacheDirectory) { $settings.CacheDirectory } else { 'D:\CloudCache' }
    $rclonePath = Find-RcloneBinary
    $winfspAvailable = Test-WinFspInstalled
    $gDriveLetter = Get-PreferredDriveLetter 'gdrive'
    $tLetter = Get-PreferredDriveLetter 'terabox'

    $items = [System.Collections.Generic.List[string]]::new()
    $items.Add("==================================================")
    $items.Add("NS CLOUD DRIVE - SYSTEM DIAGNOSTICS")
    $items.Add("Time: $([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))")
    $items.Add("==================================================")
    $items.Add("")
    $items.Add("[Filesystem Engine]")
    $items.Add("WinFsp Service: " + $(if ($winfspAvailable) { "Running (Installed)" } else { "NOT DETECTED" }))
    $items.Add("Rclone Executable: " + $(if ($rclonePath) { $rclonePath } else { "Not found" }))
    $items.Add("")
    $items.Add("[Virtual Drive Letters]")
    $items.Add("Google Drive preferred letter: $gDriveLetter`: " + $(if (Test-DriveLetterAvailable $gDriveLetter) { "Available" } else { "Occupied / In Use" }))
    $items.Add("TeraBox preferred letter: $tLetter`: " + $(if (Test-DriveLetterAvailable $tLetter) { "Available" } else { "Occupied / In Use" }))
    $items.Add("")
    $items.Add("[Local Cache Storage]")
    $items.Add("Path: $cacheDir")
    $cStats = Get-CacheUsageStatistics -CacheDirectory $cacheDir
    $items.Add("Usage: $($cStats.UsedFormatted) / $($cStats.TargetMaxFormatted) soft limit")
    $items.Add("Volume Free: $($cStats.VolumeFreeFormatted)")
    $items.Add("")
    $items.Add("[Authentication State]")
    $tbCheck = Test-TeraBoxBackendSession
    $tbUName = if ($tbCheck.UserInfo) { [string](Get-SafeProperty $tbCheck.UserInfo 'UserName' 'TeraBox User') } else { 'TeraBox User' }
    $tbErr = [string](Get-SafeProperty $tbCheck 'Error' 'Not connected')
    $items.Add("TeraBox Session: " + $(if ($tbCheck.IsValid) { "Connected ($tbUName)" } else { "Disconnected ($tbErr)" }))
    $gdCheck = Test-GoogleDriveBackendSession
    $gdDispName = if ($gdCheck.UserInfo) { [string](Get-SafeProperty $gdCheck.UserInfo 'DisplayName' (Get-SafeProperty $gdCheck.UserInfo 'EmailAddress' 'Google Drive User')) } else { 'Google Drive User' }
    $gdErr = [string](Get-SafeProperty $gdCheck 'Error' 'Not connected')
    $items.Add("Google Drive Session: " + $(if ($gdCheck.IsValid) { "Connected ($gdDispName)" } else { "Disconnected ($gdErr)" }))

    Show-DiagnosticsDialog -Title 'System Diagnostics' -DiagnosticsContent ($items -join "`n") -Owner $Owner
}

function Show-GoogleSetupInstructionsDialog([System.Windows.Window]$Owner = $null) {
    $instructions = @"
GOOGLE DRIVE OAUTH 2.0 SETUP GUIDE FOR NS CLOUD DRIVE

To connect Google Drive using official, secure OAuth 2.0 with PKCE (RFC 8252):

1. Create a Google Cloud Project:
   • Open Google Cloud Console: https://console.cloud.google.com/
   • Create a new project (e.g., 'NS Cloud Drive').

2. Enable Google Drive API:
   • Navigate to 'APIs & Services' > 'Library'.
   • Search for 'Google Drive API' and click 'Enable'.

3. Configure OAuth Consent Screen:
   • Navigate to 'APIs & Services' > 'OAuth consent screen'.
   • User Type: Select 'External' (for standard personal Google accounts).
   • App name: 'NS Cloud Drive' (enter your email under User support and Developer contact).
   • Scopes: Add '.../auth/drive.readonly'.
   • Test Users: Add your Google account email under 'Test users'.
   • Click Save and Continue.

4. Create OAuth 2.0 Desktop Credentials:
   • Navigate to 'APIs & Services' > 'Credentials' > '+ CREATE CREDENTIALS' > 'OAuth client ID'.
   • Application type: Select 'Desktop app'.
   • Name: 'NS Cloud Drive Desktop Client'.
   • Click 'CREATE'.

5. Configure NS Cloud Drive:
   • Click 'DOWNLOAD JSON' in Google Cloud Console.
   • Click 'Import JSON...' in NS Cloud Drive, or drop the downloaded client_secret_*.json into:
     $env:LOCALAPPDATA\NSCloudDrive\config\google-oauth.json
"@
    Show-DiagnosticsDialog -Title 'Google Drive Setup' -DiagnosticsContent $instructions -Owner $Owner
}

function Show-TeraBoxArchitectureDetailsDialog([System.Windows.Window]$Owner = $null) {
    $content = @"
TERABOX AUTHENTICATION ARCHITECTURE REPORT

1. Embedded Sign-In Flow:
   • NS Cloud Drive provides a private Microsoft Edge WebView2 browser profile.
   • When you sign in to TeraBox with your account, NS Cloud Drive verifies the
     authenticated session against the backend and secures it using Windows DPAPI.
   • Temporary browsing data is cleaned after session capture.

2. Access Scope:
   • Web session authentication provides access to your personal drive root ('/').
   • Official Open Platform API is limited to app-specific folders.
"@
    Show-DiagnosticsDialog -Title 'TeraBox Architecture' -DiagnosticsContent $content -Owner $Owner
}

function Show-DiagnosticsDialog([string]$Title, [string]$DiagnosticsContent, [System.Windows.Window]$Owner = $null) {
    $diagWindow = [System.Windows.Window]::new()
    $diagWindow.Title = "$Title - Diagnostics"
    $diagWindow.Width = 620
    $diagWindow.Height = 440
    $diagWindow.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $diagWindow.Owner = $Owner }
    $diagWindow.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')

    $dock = [System.Windows.Controls.DockPanel]::new()
    $dock.Margin = [System.Windows.Thickness]::new(18)
    $diagWindow.Content = $dock

    $hdr = New-UIElement-Label "$Title - Diagnostics Record (Sanitized)" 16 '#172033' $true
    [System.Windows.Controls.DockPanel]::SetDock($hdr, 'Top')
    $hdr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $dock.Children.Add($hdr) | Out-Null

    $closeBtn = [System.Windows.Controls.Button]::new()
    $closeBtn.Content = 'Close'
    $closeBtn.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $closeBtn.HorizontalAlignment = 'Right'
    [System.Windows.Controls.DockPanel]::SetDock($closeBtn, 'Bottom')
    $closeBtn.Add_Click({ $diagWindow.Close() })
    $dock.Children.Add($closeBtn) | Out-Null

    $tb = [System.Windows.Controls.TextBox]::new()
    $tb.IsReadOnly = $true
    $tb.VerticalScrollBarVisibility = 'Auto'
    $tb.HorizontalScrollBarVisibility = 'Auto'
    $tb.FontFamily = 'Consolas'
    $tb.FontSize = 12
    $tb.Text = Format-SanitizedDiagnosticMessage $DiagnosticsContent
    $tb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $dock.Children.Add($tb) | Out-Null

    [void]$diagWindow.ShowDialog()
}

function Show-ProviderConnectionWindow(
    [string]$ProviderId,
    [System.Windows.Window]$Owner = $null,
    [scriptblock]$OnStateChanged = $null
) {
    $providerInfo = $null
    if ($ProviderId -eq 'terabox') {
        $providerInfo = Get-TeraBoxProviderInfo
    } elseif ($ProviderId -eq 'gdrive') {
        $providerInfo = Get-GoogleDriveProviderInfo
    } else {
        throw "Unsupported provider ID: $ProviderId"
    }

    $win = [System.Windows.Window]::new()
    $win.Title = "Manage $($providerInfo.Name) - NS Cloud Drive"
    $win.Width = 600
    $win.Height = 460
    $win.MinWidth = 520
    $win.MinHeight = 400
    $win.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $win.Owner = $Owner }
    $win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
    $win.FontFamily = 'Segoe UI'

    $root = [System.Windows.Controls.DockPanel]::new()
    $root.Margin = [System.Windows.Thickness]::new(20)
    $win.Content = $root

    # Header
    $headerStack = [System.Windows.Controls.StackPanel]::new()
    [System.Windows.Controls.DockPanel]::SetDock($headerStack, 'Top')
    $headerStack.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)

    $brandPanel = [System.Windows.Controls.StackPanel]::new()
    $brandPanel.Orientation = 'Horizontal'

    $markBorder = [System.Windows.Controls.Border]::new()
    $markBorder.Width = 36; $markBorder.Height = 36; $markBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $markBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($providerInfo.AccentColor)
    $markText = New-UIElement-Label $providerInfo.Mark 14 '#FFFFFF' $true
    $markText.HorizontalAlignment = 'Center'; $markText.VerticalAlignment = 'Center'
    $markBorder.Child = $markText
    $markBorder.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $brandPanel.Children.Add($markBorder) | Out-Null

    $titleBox = [System.Windows.Controls.StackPanel]::new()
    $titleBox.Children.Add((New-UIElement-Label "$($providerInfo.Name) Connection" 18 '#0F172A' $true)) | Out-Null
    $titleBox.Children.Add((New-UIElement-Label "View status, validate authorization, and manage virtual drive mount." 12 '#64748B')) | Out-Null
    $brandPanel.Children.Add($titleBox) | Out-Null
    $headerStack.Children.Add($brandPanel) | Out-Null
    $root.Children.Add($headerStack) | Out-Null

    # Status Card
    $statusCard = [System.Windows.Controls.Border]::new()
    $statusCard.Background = [System.Windows.Media.Brushes]::White
    $statusCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
    $statusCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $statusCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $statusCard.Padding = [System.Windows.Thickness]::new(14)
    $statusCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)

    $statusStack = [System.Windows.Controls.StackPanel]::new()
    $statusCard.Child = $statusStack

    $statusRow = [System.Windows.Controls.DockPanel]::new()
    $statusTitle = New-UIElement-Label 'Connection status:' 13 '#334155' $true
    [System.Windows.Controls.DockPanel]::SetDock($statusTitle, 'Left')
    $statusRow.Children.Add($statusTitle) | Out-Null

    $statusBadge = [System.Windows.Controls.Border]::new()
    $statusBadge.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $statusBadge.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
    $statusBadge.HorizontalAlignment = 'Right'
    $badgeText = New-UIElement-Label 'Disconnected' 12 '#667085' $true
    $statusBadge.Child = $badgeText
    $statusBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F1F5F9')
    $statusRow.Children.Add($statusBadge) | Out-Null
    $statusStack.Children.Add($statusRow) | Out-Null

    $statusDesc = New-UIElement-Label 'Checking status...' 12 '#64748B'
    $statusDesc.Margin = [System.Windows.Thickness]::new(0, 6, 0, 4)
    $statusStack.Children.Add($statusDesc) | Out-Null

    # Scrollable Content (Constrained width to satisfy test requirements)
    $contentScroll = [System.Windows.Controls.ScrollViewer]::new()
    $contentScroll.VerticalScrollBarVisibility = 'Auto'
    $contentScroll.HorizontalScrollBarVisibility = 'Disabled'
    $root.Children.Add($contentScroll) | Out-Null

    $contentStack = [System.Windows.Controls.StackPanel]::new()
    $contentScroll.Content = $contentStack

    $contentStack.Children.Add($statusCard) | Out-Null

    $actionCard = [System.Windows.Controls.Border]::new()
    $actionCard.Background = [System.Windows.Media.Brushes]::White
    $actionCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
    $actionCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $actionCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $actionCard.Padding = [System.Windows.Thickness]::new(14)
    $actionCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $actionStack = [System.Windows.Controls.StackPanel]::new()
    $actionCard.Child = $actionStack
    $contentStack.Children.Add($actionCard) | Out-Null

    $UpdateState = {
        param([string]$NewState, [string]$CustomMessage = $null)
        $info = Get-ConnectionStateInfo $NewState
        $badgeText.Text = $info.Label
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($info.BadgeColor)
        $statusBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($info.BadgeBackground)

        if ($CustomMessage) {
            $statusDesc.Text = $CustomMessage
        } else {
            $statusDesc.Text = $info.Description
        }

        if ($OnStateChanged) {
            & $OnStateChanged $ProviderId $NewState
        }
    }

    if ($ProviderId -eq 'terabox') {
        $openBrowserBtn = [System.Windows.Controls.Button]::new()
        $openBrowserBtn.Content = 'Sign In with Embedded Browser'
        $openBrowserBtn.Padding = [System.Windows.Thickness]::new(16, 10, 16, 10)
        $openBrowserBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
        $openBrowserBtn.Foreground = [System.Windows.Media.Brushes]::White
        $openBrowserBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
        $openBrowserBtn.BorderThickness = [System.Windows.Thickness]::new(0)
        $openBrowserBtn.HorizontalAlignment = 'Left'
        $openBrowserBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        $openBrowserBtn.Add_Click({
            & $UpdateState 'OpeningSignIn' 'Launching embedded sign-in browser...'
            $loginRes = Show-TeraBoxEmbeddedLoginWindow -Owner $win -OnLoginSucceeded {
                param($res)
                & $UpdateState 'Connected' "Connected as $($res.UserName) ($($res.ItemCount) files in root)."
            } -OnStateChanged {
                param($st, $msg)
                & $UpdateState $st $msg
            }
            if ($loginRes.Success) {
                & $UpdateState 'Connected' "Connected as $($loginRes.UserName) ($($loginRes.ItemCount) files in root)."
            }
        })
        $actionStack.Children.Add($openBrowserBtn) | Out-Null
    } elseif ($ProviderId -eq 'gdrive') {
        $signInBtn = [System.Windows.Controls.Button]::new()
        $signInBtn.Content = 'Sign In with Google'
        $signInBtn.Padding = [System.Windows.Thickness]::new(16, 10, 16, 10)
        $signInBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
        $signInBtn.Foreground = [System.Windows.Media.Brushes]::White
        $signInBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
        $signInBtn.BorderThickness = [System.Windows.Thickness]::new(0)
        $signInBtn.HorizontalAlignment = 'Left'
        $signInBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        $signInBtn.Add_Click({
            & $UpdateState 'OpeningSignIn' 'Starting Google authorization in browser...'
            try {
                $authRes = Invoke-GoogleDriveAuthorization -TimeoutSeconds 120 -CancelCheck { -not $win.IsVisible }
                if ($authRes.Success) {
                    Save-GoogleDriveTokens -TokenData $authRes.Tokens
                    $verify = Test-GoogleDriveBackendSession -TokensOverride $authRes.Tokens
                    if ($verify.IsValid) {
                        $uDisp = if ($verify.UserInfo) { [string](Get-SafeProperty $verify.UserInfo 'DisplayName' (Get-SafeProperty $verify.UserInfo 'EmailAddress' 'Google Drive User')) } else { 'Google Drive User' }
                        & $UpdateState 'Connected' "Connected as $uDisp"
                    } else {
                        & $UpdateState $verify.State $verify.Error
                    }
                } else {
                    & $UpdateState 'Disconnected' $authRes.Error
                }
            } catch {
                & $UpdateState 'Error' (Format-SanitizedDiagnosticMessage $_.Exception.Message)
            }
        })
        $actionStack.Children.Add($signInBtn) | Out-Null

        $advBtn = [System.Windows.Controls.Button]::new()
        $advBtn.Content = 'Advanced: Custom Client ID'
        $advBtn.Padding = [System.Windows.Thickness]::new(8, 4, 8, 4)
        $advBtn.Background = [System.Windows.Media.Brushes]::Transparent
        $advBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#64748B')
        $advBtn.BorderThickness = [System.Windows.Thickness]::new(0)
        $advBtn.FontSize = 11
        $advBtn.HorizontalAlignment = 'Left'
        $advBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        $advBtn.Add_Click({
            [void](Show-GoogleClientConfigModal -Owner $win)
        })
        $actionStack.Children.Add($advBtn) | Out-Null
    }

    # Action row: Test & Disconnect
    $btnRow = [System.Windows.Controls.WrapPanel]::new()
    $actionStack.Children.Add($btnRow) | Out-Null

    $testBtn = [System.Windows.Controls.Button]::new()
    $testBtn.Content = 'Test Connection'
    $testBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $testBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
    $testBtn.Add_Click({
        if ($ProviderId -eq 'terabox') {
            $res = Test-TeraBoxBackendSession
            if ($res.IsValid) {
                $uName = if ($res.UserInfo) { [string](Get-SafeProperty $res.UserInfo 'UserName' 'TeraBox User') } else { 'TeraBox User' }
                & $UpdateState 'Connected' "Verified connection for $uName"
            } else {
                & $UpdateState $res.State $res.Error
            }
        } else {
            $res = Test-GoogleDriveBackendSession
            if ($res.IsValid) {
                $uDisp = if ($res.UserInfo) { [string](Get-SafeProperty $res.UserInfo 'DisplayName' (Get-SafeProperty $res.UserInfo 'EmailAddress' 'Google Drive User')) } else { 'Google Drive User' }
                & $UpdateState 'Connected' "Verified connection for $uDisp"
            } else {
                & $UpdateState $res.State $res.Error
            }
        }
    })
    $btnRow.Children.Add($testBtn) | Out-Null

    $disconnectBtn = [System.Windows.Controls.Button]::new()
    $disconnectBtn.Content = 'Disconnect Account'
    $disconnectBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $disconnectBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
    $disconnectBtn.Add_Click({
        if ($ProviderId -eq 'terabox') {
            Remove-TeraBoxSession
        } else {
            Remove-GoogleDriveSession
        }
        & $UpdateState 'Disconnected' 'Account disconnected.'
    })
    $btnRow.Children.Add($disconnectBtn) | Out-Null

    # Initial check
    if ($ProviderId -eq 'terabox') {
        $c = Test-TeraBoxBackendSession
        if ($c.IsValid) {
            $uName = if ($c.UserInfo) { [string](Get-SafeProperty $c.UserInfo 'UserName' 'TeraBox User') } else { 'TeraBox User' }
            & $UpdateState 'Connected' "Connected as $uName"
        } else {
            & $UpdateState 'Disconnected' 'No account connected.'
        }
    } else {
        $c = Test-GoogleDriveBackendSession
        if ($c.IsValid) {
            $uDisp = if ($c.UserInfo) { [string](Get-SafeProperty $c.UserInfo 'DisplayName' (Get-SafeProperty $c.UserInfo 'EmailAddress' 'Google Drive User')) } else { 'Google Drive User' }
            & $UpdateState 'Connected' "Connected as $uDisp"
        } else {
            & $UpdateState 'Disconnected' 'No account connected.'
        }
    }

    [void]$win.ShowDialog()
}

# ==============================================================================
# CLOUD-TO-CLOUD TRANSFER MODAL
# ==============================================================================

function Get-AvailableTransferAccounts {
    $list = @()
    try {
        $accs = Get-CloudAccounts
        if ($accs) {
            foreach ($a in $accs) {
                if ($a.Id -notlike 'test_*' -and $a.AccountEmail -notin @('personal@gmail.com', 'work@company.com', 'terabox_user')) {
                    $list += $a
                }
            }
        }
    } catch { }

    $hasGd = $list | Where-Object { $_.ProviderId -eq 'gdrive' }
    if (-not $hasGd) {
        $gdCheck = Test-GoogleDriveBackendSession
        if ($gdCheck.IsValid) {
            $list += @{
                Id = 'gdrive_primary'
                ProviderId = 'gdrive'
                DisplayName = 'Google Drive'
                DriveLetter = (Get-PreferredDriveLetter 'gdrive')
                AccountEmail = if ($gdCheck.UserInfo) { Get-SafeProperty $gdCheck.UserInfo 'EmailAddress' '' } else { '' }
            }
        }
    }

    $hasTb = $list | Where-Object { $_.ProviderId -eq 'terabox' }
    if (-not $hasTb) {
        $tbCheck = Test-TeraBoxBackendSession
        if ($tbCheck.IsValid) {
            $list += @{
                Id = 'terabox_primary'
                ProviderId = 'terabox'
                DisplayName = 'TeraBox'
                DriveLetter = (Get-PreferredDriveLetter 'terabox')
                AccountEmail = if ($tbCheck.UserInfo) { Get-SafeProperty $tbCheck.UserInfo 'UserName' '' } else { '' }
            }
        }
    }

    return $list
}

function Show-CloudTransferModal(
    [System.Windows.Window]$Owner = $null,
    [string]$Theme = '',
    [hashtable]$InitialSourceAccount = $null,
    [hashtable]$InitialDestinationAccount = $null
) {
    $p = Get-ModalThemePalette $Theme

    $win = [System.Windows.Window]::new()
    $win.Title = 'NS Cloud Drive - Cloud-to-Cloud Transfer'
    $win.Width = 840
    $win.Height = 660
    $win.MinWidth = 760
    $win.MinHeight = 540
    $win.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $win.Owner = $Owner }
    $win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Background)
    $win.FontFamily = 'Segoe UI'

    $rootDock = [System.Windows.Controls.DockPanel]::new()
    $rootDock.Margin = [System.Windows.Thickness]::new(20)
    $win.Content = $rootDock

    # Header
    $hdrStack = [System.Windows.Controls.StackPanel]::new()
    $hdrStack.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    [System.Windows.Controls.DockPanel]::SetDock($hdrStack, 'Top')
    $rootDock.Children.Add($hdrStack) | Out-Null

    $hTitle = New-UIElement-Label 'Cloud-to-Cloud Transfer' 20 $p.TextPrimary $true
    $hSub = New-UIElement-Label 'Direct streaming relay between cloud providers. Files stream in bounded memory chunks without caching full files on your OS drive.' 11 $p.TextMuted
    $hdrStack.Children.Add($hTitle) | Out-Null
    $hdrStack.Children.Add($hSub) | Out-Null

    # Bottom Button Bar
    $btnBar = [System.Windows.Controls.DockPanel]::new()
    $btnBar.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($btnBar, 'Bottom')
    $rootDock.Children.Add($btnBar) | Out-Null

    $leftActions = [System.Windows.Controls.StackPanel]::new()
    $leftActions.Orientation = 'Horizontal'
    [System.Windows.Controls.DockPanel]::SetDock($leftActions, 'Left')
    $btnBar.Children.Add($leftActions) | Out-Null

    $pauseBtn = [System.Windows.Controls.Button]::new()
    $pauseBtn.Content = 'Pause'
    $pauseBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
    $pauseBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $pauseBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBg)
    $pauseBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBorder)
    $pauseBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelText)
    $pauseBtn.IsEnabled = $false
    $pauseBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $leftActions.Children.Add($pauseBtn) | Out-Null

    $cancelBtn = [System.Windows.Controls.Button]::new()
    $cancelBtn.Content = 'Cancel Transfer'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
    $cancelBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DC2626')
    $cancelBtn.Foreground = [System.Windows.Media.Brushes]::White
    $cancelBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $cancelBtn.IsEnabled = $false
    $cancelBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $leftActions.Children.Add($cancelBtn) | Out-Null

    $rightActions = [System.Windows.Controls.StackPanel]::new()
    $rightActions.Orientation = 'Horizontal'
    $rightActions.HorizontalAlignment = 'Right'
    $btnBar.Children.Add($rightActions) | Out-Null

    $closeBtn = [System.Windows.Controls.Button]::new()
    $closeBtn.Content = 'Close'
    $closeBtn.Padding = [System.Windows.Thickness]::new(16, 6, 16, 6)
    $closeBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $closeBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBg)
    $closeBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBorder)
    $closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelText)
    $closeBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $closeBtn.Add_Click({ $win.Close() })
    $rightActions.Children.Add($closeBtn) | Out-Null

    $startBtn = [System.Windows.Controls.Button]::new()
    $startBtn.Content = 'Start Transfer'
    $startBtn.Padding = [System.Windows.Thickness]::new(20, 6, 20, 6)
    $startBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#22C55E')
    $startBtn.Foreground = [System.Windows.Media.Brushes]::White
    $startBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
    $startBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $startBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $rightActions.Children.Add($startBtn) | Out-Null

    # Bottom-docked Transfer Progress & Statistics Panel
    $statsCard = [System.Windows.Controls.Border]::new()
    $statsCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
    $statsCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    $statsCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $statsCard.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $statsCard.Padding = [System.Windows.Thickness]::new(14, 10, 14, 10)
    $statsCard.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($statsCard, 'Bottom')
    $rootDock.Children.Add($statsCard) | Out-Null

    $statsStack = [System.Windows.Controls.StackPanel]::new()
    $statsCard.Child = $statsStack

    $stTopRow = [System.Windows.Controls.DockPanel]::new()
    $statsStack.Children.Add($stTopRow) | Out-Null

    $stTitle = New-UIElement-Label 'Live Transfer Metrics' 12 $p.TextPrimary $true
    [System.Windows.Controls.DockPanel]::SetDock($stTitle, 'Left')
    $stTopRow.Children.Add($stTitle) | Out-Null

    $statusBadge = New-UIElement-Label 'Ready to transfer' 11 $p.TextMuted $true
    $statusBadge.HorizontalAlignment = 'Right'
    $stTopRow.Children.Add($statusBadge) | Out-Null

    $progressBar = [System.Windows.Controls.ProgressBar]::new()
    $progressBar.Height = 8
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Value = 0
    $progressBar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#22C55E')
    $progressBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)
    $progressBar.BorderThickness = [System.Windows.Thickness]::new(0)
    $progressBar.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    $statsStack.Children.Add($progressBar) | Out-Null

    $metricsRow = [System.Windows.Controls.DockPanel]::new()
    $statsStack.Children.Add($metricsRow) | Out-Null

    $bytesText = New-UIElement-Label '0 B transferred' 11 $p.TextMuted
    [System.Windows.Controls.DockPanel]::SetDock($bytesText, 'Left')
    $metricsRow.Children.Add($bytesText) | Out-Null

    $speedEtaText = New-UIElement-Label 'Speed: 0 B/s • ETA: --' 11 $p.TextPrimary $true
    $speedEtaText.HorizontalAlignment = 'Right'
    $metricsRow.Children.Add($speedEtaText) | Out-Null

    $logMsgText = New-UIElement-Label '' 10 '#F87171'
    $logMsgText.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    $logMsgText.Visibility = 'Collapsed'
    $statsStack.Children.Add($logMsgText) | Out-Null

    # Center Grid: 2 Columns (Source on Left, Destination on Right)
    $centerGrid = [System.Windows.Controls.Grid]::new()
    $cCol0 = [System.Windows.Controls.ColumnDefinition]::new(); $cCol0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $cColSep = [System.Windows.Controls.ColumnDefinition]::new(); $cColSep.Width = [System.Windows.GridLength]::new(14)
    $cCol1 = [System.Windows.Controls.ColumnDefinition]::new(); $cCol1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $centerGrid.ColumnDefinitions.Add($cCol0)
    $centerGrid.ColumnDefinitions.Add($cColSep)
    $centerGrid.ColumnDefinitions.Add($cCol1)
    $rootDock.Children.Add($centerGrid) | Out-Null

    # --- SOURCE COLUMN ---
    $srcBorder = [System.Windows.Controls.Border]::new()
    $srcBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
    $srcBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    $srcBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $srcBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $srcBorder.Padding = [System.Windows.Thickness]::new(12)
    [System.Windows.Controls.Grid]::SetColumn($srcBorder, 0)
    $centerGrid.Children.Add($srcBorder) | Out-Null

    $srcStack = [System.Windows.Controls.DockPanel]::new()
    $srcBorder.Child = $srcStack

    $srcTop = [System.Windows.Controls.StackPanel]::new()
    [System.Windows.Controls.DockPanel]::SetDock($srcTop, 'Top')
    $srcStack.Children.Add($srcTop) | Out-Null

    $srcTitle = New-UIElement-Label 'SOURCE' 11 '#3B82F6' $true
    $srcTop.Children.Add($srcTitle) | Out-Null

    $srcCombo = [System.Windows.Controls.ComboBox]::new()
    $srcCombo.Height = 28
    $srcCombo.Margin = [System.Windows.Thickness]::new(0, 4, 0, 8)
    $srcTop.Children.Add($srcCombo) | Out-Null

    $srcNavRow = [System.Windows.Controls.DockPanel]::new()
    $srcNavRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $srcTop.Children.Add($srcNavRow) | Out-Null

    $srcUpBtn = [System.Windows.Controls.Button]::new()
    $srcUpBtn.Content = [string][char]0x2191 + ' Up'
    $srcUpBtn.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
    $srcUpBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBg)
    $srcUpBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBorder)
    $srcUpBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $srcUpBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    [System.Windows.Controls.DockPanel]::SetDock($srcUpBtn, 'Right')
    $srcNavRow.Children.Add($srcUpBtn) | Out-Null

    $srcPathLbl = New-UIElement-Label 'Folder: /' 11 $p.TextMuted
    $srcPathLbl.VerticalAlignment = 'Center'
    $srcNavRow.Children.Add($srcPathLbl) | Out-Null

    $srcSelectedLbl = New-UIElement-Label 'Select a file or folder below' 11 $p.TextPrimary $true
    $srcSelectedLbl.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($srcSelectedLbl, 'Bottom')
    $srcStack.Children.Add($srcSelectedLbl) | Out-Null

    $srcList = [System.Windows.Controls.ListBox]::new()
    $srcList.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBg)
    $srcList.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)
    $srcList.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $srcStack.Children.Add($srcList) | Out-Null

    # --- DESTINATION COLUMN ---
    $dstBorder = [System.Windows.Controls.Border]::new()
    $dstBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
    $dstBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    $dstBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $dstBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $dstBorder.Padding = [System.Windows.Thickness]::new(12)
    [System.Windows.Controls.Grid]::SetColumn($dstBorder, 2)
    $centerGrid.Children.Add($dstBorder) | Out-Null

    $dstStack = [System.Windows.Controls.DockPanel]::new()
    $dstBorder.Child = $dstStack

    $dstTop = [System.Windows.Controls.StackPanel]::new()
    [System.Windows.Controls.DockPanel]::SetDock($dstTop, 'Top')
    $dstStack.Children.Add($dstTop) | Out-Null

    $dstTitle = New-UIElement-Label 'DESTINATION' 11 '#22C55E' $true
    $dstTop.Children.Add($dstTitle) | Out-Null

    $dstCombo = [System.Windows.Controls.ComboBox]::new()
    $dstCombo.Height = 28
    $dstCombo.Margin = [System.Windows.Thickness]::new(0, 4, 0, 8)
    $dstTop.Children.Add($dstCombo) | Out-Null

    $dstNavRow = [System.Windows.Controls.DockPanel]::new()
    $dstNavRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $dstTop.Children.Add($dstNavRow) | Out-Null

    $dstUpBtn = [System.Windows.Controls.Button]::new()
    $dstUpBtn.Content = [string][char]0x2191 + ' Up'
    $dstUpBtn.Padding = [System.Windows.Thickness]::new(8, 2, 8, 2)
    $dstUpBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBg)
    $dstUpBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CancelBorder)
    $dstUpBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $dstUpBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    [System.Windows.Controls.DockPanel]::SetDock($dstUpBtn, 'Right')
    $dstNavRow.Children.Add($dstUpBtn) | Out-Null

    $dstPathLbl = New-UIElement-Label 'Target Folder: /' 11 $p.TextMuted
    $dstPathLbl.VerticalAlignment = 'Center'
    $dstNavRow.Children.Add($dstPathLbl) | Out-Null

    $dstSelectedLbl = New-UIElement-Label 'Files will be saved into /' 11 $p.TextPrimary $true
    $dstSelectedLbl.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($dstSelectedLbl, 'Bottom')
    $dstStack.Children.Add($dstSelectedLbl) | Out-Null

    $dstList = [System.Windows.Controls.ListBox]::new()
    $dstList.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBg)
    $dstList.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)
    $dstList.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $dstStack.Children.Add($dstList) | Out-Null

    # State variables
    $script:SrcCurrentPath = ''
    $script:DstCurrentPath = ''
    $script:SelectedSourceItem = $null
    $script:ActiveTransferJobId = $null

    $availableAccounts = Get-AvailableTransferAccounts
    if (-not $availableAccounts -or $availableAccounts.Count -eq 0) {
        $srcSelectedLbl.Text = 'No active cloud accounts available. Connect Google Drive or TeraBox first.'
        $srcSelectedLbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
        $startBtn.IsEnabled = $false
    } else {
        foreach ($acc in $availableAccounts) {
            $tagText = "$($acc.DisplayName) ($($acc.ProviderId))"
            [void]$srcCombo.Items.Add($tagText)
            [void]$dstCombo.Items.Add($tagText)
        }

        # Default source: Google Drive, destination: TeraBox (or vice versa)
        $srcCombo.SelectedIndex = 0
        if ($availableAccounts.Count -gt 1) {
            $srcCombo.SelectedIndex = 0
            $dstCombo.SelectedIndex = 1
        } else {
            $dstCombo.SelectedIndex = 0
        }
    }

    # Helper: Refresh Source File List
    $refreshSource = {
        $srcList.Items.Clear()
        if ($srcCombo.SelectedIndex -lt 0 -or $srcCombo.SelectedIndex -ge $availableAccounts.Count) { return }
        $acc = $availableAccounts[$srcCombo.SelectedIndex]
        $srcPathLbl.Text = "Folder: /" + $script:SrcCurrentPath

        try {
            $items = Get-CloudDirectoryContents -Account $acc -Path $script:SrcCurrentPath
            if ($items) {
                foreach ($item in $items) {
                    $prefix = if ($item.IsDir) { "[Folder] " } else { "[File] " }
                    $szStr = if ($item.IsDir) { "" } else { " (" + (Format-TransferSpeed $item.Size).Replace('/s','') + ")" }
                    $txt = "$prefix$($item.Name)$szStr"
                    $lItem = [System.Windows.Controls.ListBoxItem]::new()
                    $lItem.Content = $txt
                    $lItem.Tag = $item
                    $lItem.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
                    $srcList.Items.Add($lItem) | Out-Null
                }
            }
        } catch {
            $errItem = [System.Windows.Controls.ListBoxItem]::new()
            $errItem.Content = "Could not list directory: $($_.Exception.Message)"
            $errItem.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
            $srcList.Items.Add($errItem) | Out-Null
        }
    }

    # Helper: Refresh Destination Folder List
    $refreshDest = {
        $dstList.Items.Clear()
        if ($dstCombo.SelectedIndex -lt 0 -or $dstCombo.SelectedIndex -ge $availableAccounts.Count) { return }
        $acc = $availableAccounts[$dstCombo.SelectedIndex]
        $dstPathLbl.Text = "Target Folder: /" + $script:DstCurrentPath
        $dstSelectedLbl.Text = "Files will be saved into /" + $script:DstCurrentPath

        try {
            $items = Get-CloudDirectoryContents -Account $acc -Path $script:DstCurrentPath
            if ($items) {
                foreach ($item in $items) {
                    if ($item.IsDir) {
                        $lItem = [System.Windows.Controls.ListBoxItem]::new()
                        $lItem.Content = "[Folder] " + $item.Name
                        $lItem.Tag = $item
                        $lItem.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
                        $dstList.Items.Add($lItem) | Out-Null
                    }
                }
            }
        } catch { }
    }

    $srcCombo.Add_SelectionChanged({
        $script:SrcCurrentPath = ''
        $script:SelectedSourceItem = $null
        & $refreshSource
    })

    $dstCombo.Add_SelectionChanged({
        $script:DstCurrentPath = ''
        & $refreshDest
    })

    $srcUpBtn.Add_Click({
        if ($script:SrcCurrentPath) {
            $parts = $script:SrcCurrentPath.Split('/')
            if ($parts.Length -gt 1) {
                $script:SrcCurrentPath = ($parts[0..($parts.Length - 2)] -join '/')
            } else {
                $script:SrcCurrentPath = ''
            }
            $script:SelectedSourceItem = $null
            & $refreshSource
        }
    })

    $dstUpBtn.Add_Click({
        if ($script:DstCurrentPath) {
            $parts = $script:DstCurrentPath.Split('/')
            if ($parts.Length -gt 1) {
                $script:DstCurrentPath = ($parts[0..($parts.Length - 2)] -join '/')
            } else {
                $script:DstCurrentPath = ''
            }
            & $refreshDest
        }
    })

    # Source selection handling
    $srcList.Add_SelectionChanged({
        if ($srcList.SelectedItem) {
            $item = $srcList.SelectedItem.Tag
            if ($item) {
                $script:SelectedSourceItem = $item
                if ($item.IsDir) {
                    $srcSelectedLbl.Text = "Selected Folder: $($item.Name) (double-click to enter)"
                } else {
                    $srcSelectedLbl.Text = "Selected File: $($item.Name) (" + (Format-TransferSpeed $item.Size).Replace('/s','') + ")"
                }
            }
        }
    })

    # Double click folder to drill down
    $srcList.Add_MouseDoubleClick({
        if ($srcList.SelectedItem) {
            $item = $srcList.SelectedItem.Tag
            if ($item -and $item.IsDir) {
                $script:SrcCurrentPath = if ($script:SrcCurrentPath) { "$($script:SrcCurrentPath)/$($item.Name)" } else { $item.Name }
                $script:SelectedSourceItem = $null
                & $refreshSource
            }
        }
    })

    $dstList.Add_MouseDoubleClick({
        if ($dstList.SelectedItem) {
            $item = $dstList.SelectedItem.Tag
            if ($item -and $item.IsDir) {
                $script:DstCurrentPath = if ($script:DstCurrentPath) { "$($script:DstCurrentPath)/$($item.Name)" } else { $item.Name }
                & $refreshDest
            }
        }
    })

    # Live Transfer Polling Timer
    $pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $pollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $pollTimer.Add_Tick({
        if ($script:ActiveTransferJobId) {
            $st = Get-CloudTransferStatus -JobId $script:ActiveTransferJobId
            if ($st) {
                if ($st.Percentage -ge 0) {
                    $progressBar.IsIndeterminate = $false
                    $progressBar.Value = $st.Percentage
                } else {
                    $progressBar.IsIndeterminate = $true
                }

                $bytesFmt = (Format-TransferSpeed $st.BytesTransferred).Replace('/s', '')
                $totFmt = if ($st.TotalBytes -gt 0) { (Format-TransferSpeed $st.TotalBytes).Replace('/s', '') } else { 'Unknown size' }
                $bytesText.Text = "$bytesFmt of $totFmt transferred ($($st.Percentage)%)"
                $speedEtaText.Text = "Speed: $($st.SpeedFormatted) • ETA: $($st.EtaFormatted)"

                if ($st.Status -eq 'Running') {
                    $statusBadge.Text = ([string][char]0x25CF + ' Streaming Relay...')
                    $statusBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3B82F6')
                    $pauseBtn.Content = 'Pause'
                    $pauseBtn.IsEnabled = $true
                    $cancelBtn.IsEnabled = $true
                    $startBtn.IsEnabled = $false
                } elseif ($st.Status -eq 'Paused') {
                    $statusBadge.Text = ([string][char]0x25CF + ' Paused')
                    $statusBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FBBF24')
                    $pauseBtn.Content = 'Resume'
                    $pauseBtn.IsEnabled = $true
                } elseif ($st.Status -eq 'Completed') {
                    $statusBadge.Text = ([string][char]0x25CF + ' Completed Successfully')
                    $statusBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#22C55E')
                    $progressBar.IsIndeterminate = $false
                    $progressBar.Value = 100
                    $pauseBtn.IsEnabled = $false
                    $cancelBtn.IsEnabled = $false
                    $startBtn.IsEnabled = $true
                    $script:ActiveTransferJobId = $null
                    $pollTimer.Stop()
                    & $refreshDest
                } elseif ($st.Status -eq 'Failed') {
                    $statusBadge.Text = ([string][char]0x25CF + ' Failed')
                    $statusBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EF4444')
                    $logMsgText.Text = "Error: $($st.LastError)"
                    $logMsgText.Visibility = 'Visible'
                    $pauseBtn.IsEnabled = $false
                    $cancelBtn.IsEnabled = $false
                    $startBtn.IsEnabled = $true
                    $script:ActiveTransferJobId = $null
                    $pollTimer.Stop()
                } elseif ($st.Status -eq 'Cancelled') {
                    $statusBadge.Text = ([string][char]0x25CF + ' Cancelled')
                    $statusBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextMuted)
                    $pauseBtn.IsEnabled = $false
                    $cancelBtn.IsEnabled = $false
                    $startBtn.IsEnabled = $true
                    $script:ActiveTransferJobId = $null
                    $pollTimer.Stop()
                }
            }
        }
    })

    # Action: Start Transfer
    $startBtn.Add_Click({
        if ($srcCombo.SelectedIndex -lt 0 -or $dstCombo.SelectedIndex -lt 0) {
            [System.Windows.MessageBox]::Show('Please select source and destination accounts.', 'Transfer Notice', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        $srcAcc = $availableAccounts[$srcCombo.SelectedIndex]
        $dstAcc = $availableAccounts[$dstCombo.SelectedIndex]

        if ($srcAcc.Id -eq $dstAcc.Id -and $script:SrcCurrentPath -eq $script:DstCurrentPath) {
            [System.Windows.MessageBox]::Show('Source and destination cannot be identical in the same directory.', 'Transfer Notice', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        # Path to transfer: specific selected item or current folder
        $srcTarget = if ($script:SelectedSourceItem) {
            if ($script:SrcCurrentPath) { "$($script:SrcCurrentPath)/$($script:SelectedSourceItem.Name)" } else { $script:SelectedSourceItem.Name }
        } else {
            $script:SrcCurrentPath
        }

        $logMsgText.Visibility = 'Collapsed'
        $statusBadge.Text = 'Initializing streaming transfer...'
        $statusBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3B82F6')

        try {
            $job = Start-CloudTransfer -SourceAccount $srcAcc -SourcePath $srcTarget -DestinationAccount $dstAcc -DestinationPath $script:DstCurrentPath -ConflictAction 'Skip'
            $script:ActiveTransferJobId = $job.JobId
            $pollTimer.Start()
            $startBtn.IsEnabled = $false
            $pauseBtn.IsEnabled = $true
            $cancelBtn.IsEnabled = $true
        } catch {
            $statusBadge.Text = ([string][char]0x25CF + ' Start Failed')
            $statusBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EF4444')
            $logMsgText.Text = "Error starting transfer: $($_.Exception.Message)"
            $logMsgText.Visibility = 'Visible'
        }
    })

    $pauseBtn.Add_Click({
        if ($script:ActiveTransferJobId) {
            if ($pauseBtn.Content -eq 'Pause') {
                Suspend-CloudTransfer -JobId $script:ActiveTransferJobId | Out-Null
            } else {
                Resume-CloudTransfer -JobId $script:ActiveTransferJobId | Out-Null
            }
        }
    })

    $cancelBtn.Add_Click({
        if ($script:ActiveTransferJobId) {
            Stop-CloudTransfer -JobId $script:ActiveTransferJobId | Out-Null
        }
    })

    $win.Add_Closing({
        param($sender, $eventArgs)
        if ($script:ActiveTransferJobId) {
            $c = [System.Windows.MessageBox]::Show('A cloud transfer is currently running. Do you want to cancel the transfer and exit?', 'Cancel Transfer', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($c -eq [System.Windows.MessageBoxResult]::Yes) {
                Stop-CloudTransfer -JobId $script:ActiveTransferJobId | Out-Null
                $pollTimer.Stop()
            } else {
                $eventArgs.Cancel = $true
            }
        }
    })

    # Initial population of file lists
    & $refreshSource
    & $refreshDest

    [void]$win.ShowDialog()
}
