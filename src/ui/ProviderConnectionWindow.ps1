Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot '..\providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot 'EmbeddedBrowserWindow.ps1')

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

function Show-AddCloudDiskModal([System.Windows.Window]$Owner = $null, [scriptblock]$OnProviderSelected = $null) {
    $addWin = [System.Windows.Window]::new()
    $addWin.Title = 'Add Cloud Disk'
    $addWin.Width = 520
    $addWin.Height = 360
    $addWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $addWin.Owner = $Owner }
    $addWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#18191C')
    $addWin.ResizeMode = 'NoResize'
    $addWin.FontFamily = 'Segoe UI'

    $dock = [System.Windows.Controls.DockPanel]::new()
    $dock.Margin = [System.Windows.Thickness]::new(20)
    $addWin.Content = $dock

    # Header
    $headerStack = [System.Windows.Controls.StackPanel]::new()
    [System.Windows.Controls.DockPanel]::SetDock($headerStack, 'Top')
    $headerStack.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $title = New-UIElement-Label 'Add Cloud Disk' 18 '#F2F3F5' $true
    $headerStack.Children.Add($title) | Out-Null
    $subtitle = New-UIElement-Label 'Select a supported cloud storage provider to mount as a Windows drive.' 12 '#949BA4'
    $subtitle.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $headerStack.Children.Add($subtitle) | Out-Null
    $dock.Children.Add($headerStack) | Out-Null

    # Bottom button (Cancel)
    $cancelBtn = [System.Windows.Controls.Button]::new()
    $cancelBtn.Content = 'Cancel'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $cancelBtn.HorizontalAlignment = 'Right'
    $cancelBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
    $cancelBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
    $cancelBtn.BorderThickness = [System.Windows.Thickness]::new(1)
    $cancelBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
    [System.Windows.Controls.DockPanel]::SetDock($cancelBtn, 'Bottom')
    $cancelBtn.Add_Click({ $addWin.Close() })
    $dock.Children.Add($cancelBtn) | Out-Null

    # Provider Options List
    $listStack = [System.Windows.Controls.StackPanel]::new()
    $dock.Children.Add($listStack) | Out-Null

    $script:SelectedProvider = $null

    # Provider 1: Google Drive
    $gdBorder = [System.Windows.Controls.Border]::new()
    $gdBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
    $gdBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
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
    $gdText.Children.Add((New-UIElement-Label 'Google Drive' 15 '#F2F3F5' $true)) | Out-Null
    $gdText.Children.Add((New-UIElement-Label 'Personal & Workspace cloud storage via Google OAuth 2.0' 12 '#949BA4')) | Out-Null
    $gdLeft.Children.Add($gdText) | Out-Null

    $SelectGD = {
        $script:SelectedProvider = 'gdrive'
        $addWin.Close()
        if ($OnProviderSelected) { & $OnProviderSelected 'gdrive' }
    }
    $gdBtn.Add_Click($SelectGD)
    $gdBorder.Add_MouseLeftButtonDown($SelectGD)
    $listStack.Children.Add($gdBorder) | Out-Null

    # Provider 2: TeraBox
    $tbBorder = [System.Windows.Controls.Border]::new()
    $tbBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
    $tbBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
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
    $tbText.Children.Add((New-UIElement-Label 'TeraBox' 15 '#F2F3F5' $true)) | Out-Null
    $tbText.Children.Add((New-UIElement-Label '1 TB cloud storage with high-speed media streaming' 12 '#949BA4')) | Out-Null
    $tbLeft.Children.Add($tbText) | Out-Null

    $SelectTB = {
        $script:SelectedProvider = 'terabox'
        $addWin.Close()
        if ($OnProviderSelected) { & $OnProviderSelected 'terabox' }
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
    [hashtable]$InitialAccount = $null
) {
    $setupWin = [System.Windows.Window]::new()
    $isEdit = ($InitialAccount -and $InitialAccount.ContainsKey('Id') -and $InitialAccount.Id)
    $provName = if ($ProviderId -eq 'terabox') { 'TeraBox' } else { 'Google Drive' }
    $setupWin.Title = if ($isEdit) { "Configure $provName Account" } else { "Add $provName Disk" }
    $setupWin.Width = 460
    $setupWin.Height = 360
    $setupWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $setupWin.Owner = $Owner }
    $setupWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#18191C')
    $setupWin.ResizeMode = 'NoResize'
    $setupWin.FontFamily = 'Segoe UI'

    $stack = [System.Windows.Controls.StackPanel]::new()
    $stack.Margin = [System.Windows.Thickness]::new(24)
    $setupWin.Content = $stack

    # Header
    $title = New-UIElement-Label $(if ($isEdit) { "Configure $provName Disk" } else { "Add $provName Disk" }) 16 '#F2F3F5' $true
    $stack.Children.Add($title) | Out-Null

    $sub = New-UIElement-Label 'Configure the display name and Windows virtual drive letter.' 12 '#949BA4'
    $sub.Margin = [System.Windows.Thickness]::new(0, 4, 0, 16)
    $stack.Children.Add($sub) | Out-Null

    # Account Name field
    $lbl1 = New-UIElement-Label 'Disk / Account Name' 12 '#DBDEE1' $true
    $stack.Children.Add($lbl1) | Out-Null

    $txtName = [System.Windows.Controls.TextBox]::new()
    $txtName.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $txtName.Margin = [System.Windows.Thickness]::new(0, 4, 0, 14)
    $txtName.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
    $txtName.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
    $txtName.Foreground = [System.Windows.Media.Brushes]::White
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
    $lbl2 = New-UIElement-Label 'Windows Drive Letter' 12 '#DBDEE1' $true
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

    # Auto-mount CheckBox
    $chkAutoMount = [System.Windows.Controls.CheckBox]::new()
    $chkAutoMount.Content = 'Automatically mount this drive on startup'
    $chkAutoMount.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
    $chkAutoMount.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
    $chkAutoMount.IsChecked = if ($InitialAccount -and $InitialAccount.ContainsKey('AutoMount') -and $null -ne $InitialAccount.AutoMount) {
        [bool]$InitialAccount.AutoMount
    } else {
        $true
    }
    $stack.Children.Add($chkAutoMount) | Out-Null

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
    $cancelBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
    $cancelBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
    $cancelBtn.BorderThickness = [System.Windows.Thickness]::new(1)
    $cancelBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DBDEE1')
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
            "${ProviderId}_" + [DateTime]::UtcNow.Ticks.ToString()
        }

        $accObj = [ordered]@{
            Id = $accId
            ProviderId = $ProviderId
            DisplayName = $name
            AccountEmail = if ($InitialAccount -and $InitialAccount.ContainsKey('AccountEmail')) { [string]$InitialAccount.AccountEmail } else { '' }
            DriveLetter = $letter
            AutoMount = [bool]$chkAutoMount.IsChecked
            Created = [DateTime]::UtcNow.ToString('o')
        }

        Add-CloudAccount $accObj | Out-Null
        $script:SavedAccountResult = $accObj
        $setupWin.Close()
    })

    [void]$setupWin.ShowDialog()
    return $script:SavedAccountResult
}

function Connect-NewCloudAccount([System.Windows.Window]$Owner = $null, [string]$ProviderId = 'gdrive') {
    if ($ProviderId -eq 'gdrive') {
        $accId = "gdrive_" + [DateTime]::UtcNow.Ticks.ToString()
        $authRes = Invoke-GoogleDriveAuthorization -AccountId $accId
        if (-not $authRes.Success) {
            [System.Windows.MessageBox]::Show("Google Drive sign-in: $($authRes.Error)", 'Google Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return $null
        }

        $verify = Test-GoogleDriveBackendSession -TokensOverride $authRes.Tokens -AccountId $accId
        $userEmail = if ($verify.IsValid -and $verify.UserInfo) { [string](Get-SafeProperty $verify.UserInfo 'EmailAddress' '') } else { '' }
        $userName = if ($verify.IsValid -and $verify.UserInfo) { [string](Get-SafeProperty $verify.UserInfo 'DisplayName' $userEmail) } else { $userEmail }

        $nextLetter = Get-NextAvailableDriveLetter 'G'
        $initData = @{
            Id = $accId
            ProviderId = 'gdrive'
            DisplayName = if ($userName) { "Google Drive ($userName)" } else { "Google Drive" }
            AccountEmail = $userEmail
            DriveLetter = $nextLetter
            AutoMount = $true
        }

        return (Show-CloudAccountSetupModal -Owner $Owner -ProviderId 'gdrive' -InitialAccount $initData)

    } elseif ($ProviderId -eq 'terabox') {
        $accId = "terabox_" + [DateTime]::UtcNow.Ticks.ToString()
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
            AccountEmail = if ($loginRes.UserName) { $loginRes.UserName } else { 'TeraBox User' }
            DriveLetter = $nextLetter
            AutoMount = $true
        }

        return (Show-CloudAccountSetupModal -Owner $Owner -ProviderId 'terabox' -InitialAccount $initData)
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
