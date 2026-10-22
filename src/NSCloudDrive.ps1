param(
    [switch]$Minimized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot 'providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot 'services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot 'services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot 'ui\EmbeddedBrowserWindow.ps1')
. (Join-Path $PSScriptRoot 'ui\ProviderConnectionWindow.ps1')

$script:Settings = Get-NSCloudDriveSettings
$script:CacheDirectory = if ($script:Settings.CacheDirectory) { $script:Settings.CacheDirectory } else { 'D:\CloudCache' }
$script:GDriveLetter = Get-PreferredDriveLetter 'gdrive'
$script:TeraBoxLetter = Get-PreferredDriveLetter 'terabox'
$script:IsExiting = $false
$script:AppMutex = $null
$script:RestoreEvent = $null
$script:LastFullUpdate = [DateTime]::UtcNow
$script:IsConnecting = $false

# Enforce single instance when launched as standalone application
if ($MyInvocation.InvocationName -ne '.') {
    $isNewInstance = $false
    try {
        $script:AppMutex = [System.Threading.Mutex]::new($true, 'Local\NSCloudDrive_AppMutex', [ref]$isNewInstance)
    } catch [System.Threading.AbandonedMutexException] {
        $isNewInstance = $true
    } catch {
        $isNewInstance = $true
    }

    if (-not $isNewInstance) {
        Write-Host 'NS Cloud Drive is already running. Restoring window to foreground...'
        try {
            $existingEvent = [System.Threading.EventWaitHandle]::OpenExisting('Local\NSCloudDrive_RestoreWindow_Event')
            $existingEvent.Set() | Out-Null
            $existingEvent.Dispose()
        } catch { }

        try {
            $wshell = New-Object -ComObject WScript.Shell
            $wshell.AppActivate('NS Cloud Drive') | Out-Null
        } catch { }

        exit 0
    }

    try {
        $script:RestoreEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, 'Local\NSCloudDrive_RestoreWindow_Event')
    } catch { }
}

function New-Label([string]$Text, [int]$Size = 13, [string]$Color = '#1E293B', [bool]$Bold = $false) {
    $label = [System.Windows.Controls.TextBlock]::new()
    $label.Text = $Text
    $label.FontSize = $Size
    $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $label.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $label.TextWrapping = 'Wrap'
    return $label
}

function Get-VerifiedRclonePath {
    $r = Find-RcloneBinary
    if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) {
        return $r
    }
    return $null
}

# --- Main Window Construction ---
$window = [System.Windows.Window]::new()
$window.Title = 'NS Cloud Drive'
$window.Width = 760
$window.Height = 560
$window.MinWidth = 680
$window.MinHeight = 480
$window.WindowStartupLocation = 'CenterScreen'
$window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
$window.FontFamily = 'Segoe UI'

$outer = [System.Windows.Controls.DockPanel]::new()
$outer.LastChildFill = $true
$outer.Margin = [System.Windows.Thickness]::new(24)
$window.Content = $outer

# --- Header Bar ---
$headerDock = [System.Windows.Controls.DockPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($headerDock, 'Top')
$headerDock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 18)
$outer.Children.Add($headerDock) | Out-Null

# Right side: Header actions (Settings, Diagnostics)
$headerActions = [System.Windows.Controls.StackPanel]::new()
$headerActions.Orientation = 'Horizontal'
[System.Windows.Controls.DockPanel]::SetDock($headerActions, 'Right')
$headerDock.Children.Add($headerActions) | Out-Null

$settingsBtn = [System.Windows.Controls.Button]::new()
$settingsBtn.Content = '⚙ Settings'
$settingsBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$settingsBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$settingsBtn.Background = [System.Windows.Media.Brushes]::White
$settingsBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
$settingsBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$settingsBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
$settingsBtn.Add_Click({
    Show-SettingsModal -Owner $window -OnSettingsChanged {
        $script:Settings = Get-NSCloudDriveSettings
        $script:CacheDirectory = if ($script:Settings.CacheDirectory) { $script:Settings.CacheDirectory } else { 'D:\CloudCache' }
        Update-AllUIState
    }
})
$headerActions.Children.Add($settingsBtn) | Out-Null

$diagBtn = [System.Windows.Controls.Button]::new()
$diagBtn.Content = 'Diagnostics'
$diagBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$diagBtn.Background = [System.Windows.Media.Brushes]::White
$diagBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
$diagBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$diagBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
$diagBtn.Add_Click({
    Show-DiagnosticsModal -Owner $window
})
$headerActions.Children.Add($diagBtn) | Out-Null

# Left side: Brand Logo & Title
$brand = [System.Windows.Controls.StackPanel]::new()
$brand.Orientation = 'Horizontal'
$headerDock.Children.Add($brand) | Out-Null

$mark = [System.Windows.Controls.Border]::new()
$mark.Width = 38; $mark.Height = 38; $mark.CornerRadius = [System.Windows.CornerRadius]::new(9)
$mark.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
$markText = New-Label 'NS' 15 '#FFFFFF' $true
$markText.HorizontalAlignment = 'Center'; $markText.VerticalAlignment = 'Center'
$mark.Child = $markText
$mark.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
$brand.Children.Add($mark) | Out-Null

$brandTitle = [System.Windows.Controls.StackPanel]::new()
$brandTitle.Children.Add((New-Label 'NS Cloud Drive' 18 '#0F172A' $true)) | Out-Null
$brandTitle.Children.Add((New-Label 'Cloud storage drives mounted directly in Windows File Explorer.' 12 '#64748B')) | Out-Null
$brand.Children.Add($brandTitle) | Out-Null

# --- Main Scroll Container (Constrained width to satisfy test requirements) ---
$mainScroll = [System.Windows.Controls.ScrollViewER]::new()
$mainScroll.VerticalScrollBarVisibility = 'Auto'
$mainScroll.HorizontalScrollBarVisibility = 'Disabled'
$outer.Children.Add($mainScroll) | Out-Null

$content = [System.Windows.Controls.StackPanel]::new()
$mainScroll.Content = $content

# --- Providers Container (Grid required by regression test suite) ---
$providersGrid = [System.Windows.Controls.Grid]::new()
$providersGrid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
$rowGd = [System.Windows.Controls.RowDefinition]::new()
$rowGd.Height = [System.Windows.GridLength]::Auto
$rowTb = [System.Windows.Controls.RowDefinition]::new()
$rowTb.Height = [System.Windows.GridLength]::Auto
$providersGrid.RowDefinitions.Add($rowGd)
$providersGrid.RowDefinitions.Add($rowTb)
$content.Children.Add($providersGrid) | Out-Null

$driveLetters = @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')

# ==============================================================================
# 1. GOOGLE DRIVE CARD (Air Live Drive Style)
# ==============================================================================
$gdCard = [System.Windows.Controls.Border]::new()
$gdCard.Background = [System.Windows.Media.Brushes]::White
$gdCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
$gdCard.BorderThickness = [System.Windows.Thickness]::new(1)
$gdCard.CornerRadius = [System.Windows.CornerRadius]::new(10)
$gdCard.Padding = [System.Windows.Thickness]::new(18)
$gdCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
[System.Windows.Controls.Grid]::SetRow($gdCard, 0)
$providersGrid.Children.Add($gdCard) | Out-Null

$gdStack = [System.Windows.Controls.StackPanel]::new()
$gdCard.Child = $gdStack

# GD Header Row: Badge, Title, Letter combo, Status Pill
$gdHeaderDock = [System.Windows.Controls.DockPanel]::new()
$gdStack.Children.Add($gdHeaderDock) | Out-Null

# Right side: Status Pill
$gdStatusPill = [System.Windows.Controls.Border]::new()
$gdStatusPill.CornerRadius = [System.Windows.CornerRadius]::new(6)
$gdStatusPill.Padding = [System.Windows.Thickness]::new(10, 3, 10, 3)
$gdStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F1F5F9')
[System.Windows.Controls.DockPanel]::SetDock($gdStatusPill, 'Right')
$gdStatusPillText = New-Label '● Disconnected' 12 '#64748B' $true
$gdStatusPill.Child = $gdStatusPillText
$gdHeaderDock.Children.Add($gdStatusPill) | Out-Null

# Left side: Icon, Name, Drive letter selector
$gdTitleStack = [System.Windows.Controls.StackPanel]::new()
$gdTitleStack.Orientation = 'Horizontal'
$gdHeaderDock.Children.Add($gdTitleStack) | Out-Null

$gdIconBadge = [System.Windows.Controls.Border]::new()
$gdIconBadge.Width = 28; $gdIconBadge.Height = 28; $gdIconBadge.CornerRadius = [System.Windows.CornerRadius]::new(6)
$gdIconBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
$gdIconText = New-Label 'GD' 12 '#FFFFFF' $true
$gdIconText.HorizontalAlignment = 'Center'; $gdIconText.VerticalAlignment = 'Center'
$gdIconBadge.Child = $gdIconText
$gdIconBadge.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
$gdTitleStack.Children.Add($gdIconBadge) | Out-Null

$gdNameLabel = New-Label 'Google Drive' 16 '#0F172A' $true
$gdNameLabel.VerticalAlignment = 'Center'
$gdTitleStack.Children.Add($gdNameLabel) | Out-Null

$gdDriveLabel = New-Label 'Drive:' 12 '#64748B'
$gdDriveLabel.VerticalAlignment = 'Center'
$gdDriveLabel.Margin = [System.Windows.Thickness]::new(16, 0, 4, 0)
$gdTitleStack.Children.Add($gdDriveLabel) | Out-Null

$gdLetterCombo = [System.Windows.Controls.ComboBox]::new()
$gdLetterCombo.Width = 56; $gdLetterCombo.Height = 26
foreach ($l in $driveLetters) { [void]$gdLetterCombo.Items.Add("$($l):") }
$gdLetterCombo.SelectedItem = "$($script:GDriveLetter):"
$gdLetterCombo.Add_SelectionChanged({
    if ($gdLetterCombo.SelectedItem) {
        $sel = $gdLetterCombo.SelectedItem.ToString().TrimEnd(':')
        Set-PreferredDriveLetter -ProviderId 'gdrive' -DriveLetter $sel
        $script:GDriveLetter = $sel
    }
})
$gdTitleStack.Children.Add($gdLetterCombo) | Out-Null

# GD Middle Row: Details & Storage Usage
$gdDetailStack = [System.Windows.Controls.StackPanel]::new()
$gdDetailStack.Margin = [System.Windows.Thickness]::new(0, 12, 0, 12)
$gdStack.Children.Add($gdDetailStack) | Out-Null

$gdAccountText = New-Label 'Not connected. Click Connect to sign in and mount virtual drive.' 13 '#475569'
$gdDetailStack.Children.Add($gdAccountText) | Out-Null

$gdStorageBar = [System.Windows.Controls.ProgressBar]::new()
$gdStorageBar.Height = 6
$gdStorageBar.Minimum = 0
$gdStorageBar.Maximum = 100
$gdStorageBar.Value = 0
$gdStorageBar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
$gdStorageBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
$gdStorageBar.BorderThickness = [System.Windows.Thickness]::new(0)
$gdStorageBar.Margin = [System.Windows.Thickness]::new(0, 6, 0, 4)
$gdStorageBar.Visibility = 'Collapsed'
$gdDetailStack.Children.Add($gdStorageBar) | Out-Null

$gdQuotaText = New-Label '' 12 '#64748B'
$gdQuotaText.Visibility = 'Collapsed'
$gdDetailStack.Children.Add($gdQuotaText) | Out-Null

$gdErrorText = New-Label '' 12 '#DC2626'
$gdErrorText.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
$gdErrorText.Visibility = 'Collapsed'
$gdDetailStack.Children.Add($gdErrorText) | Out-Null

# GD Bottom Row: Direct Action Buttons
$gdActionsDock = [System.Windows.Controls.DockPanel]::new()
$gdStack.Children.Add($gdActionsDock) | Out-Null

$gdConnectBtn = [System.Windows.Controls.Button]::new()
$gdConnectBtn.Content = 'Connect'
$gdConnectBtn.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
$gdConnectBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
$gdConnectBtn.Foreground = [System.Windows.Media.Brushes]::White
$gdConnectBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$gdConnectBtn.BorderThickness = [System.Windows.Thickness]::new(0)
[System.Windows.Controls.DockPanel]::SetDock($gdConnectBtn, 'Left')
$gdActionsDock.Children.Add($gdConnectBtn) | Out-Null

$gdConnectedActions = [System.Windows.Controls.StackPanel]::new()
$gdConnectedActions.Orientation = 'Horizontal'
$gdConnectedActions.Visibility = 'Collapsed'
[System.Windows.Controls.DockPanel]::SetDock($gdConnectedActions, 'Left')
$gdActionsDock.Children.Add($gdConnectedActions) | Out-Null

$gdExplorerBtn = [System.Windows.Controls.Button]::new()
$gdExplorerBtn.Content = 'Open in Explorer'
$gdExplorerBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
$gdExplorerBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
$gdExplorerBtn.Foreground = [System.Windows.Media.Brushes]::White
$gdExplorerBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$gdExplorerBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$gdExplorerBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$gdConnectedActions.Children.Add($gdExplorerBtn) | Out-Null

$gdDisconnectBtn = [System.Windows.Controls.Button]::new()
$gdDisconnectBtn.Content = 'Disconnect'
$gdDisconnectBtn.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
$gdDisconnectBtn.Background = [System.Windows.Media.Brushes]::White
$gdDisconnectBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
$gdDisconnectBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$gdDisconnectBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#475569')
$gdConnectedActions.Children.Add($gdDisconnectBtn) | Out-Null

# ==============================================================================
# 2. TERABOX CARD (Air Live Drive Style)
# ==============================================================================
$tbCard = [System.Windows.Controls.Border]::new()
$tbCard.Background = [System.Windows.Media.Brushes]::White
$tbCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
$tbCard.BorderThickness = [System.Windows.Thickness]::new(1)
$tbCard.CornerRadius = [System.Windows.CornerRadius]::new(10)
$tbCard.Padding = [System.Windows.Thickness]::new(18)
$tbCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
[System.Windows.Controls.Grid]::SetRow($tbCard, 1)
$providersGrid.Children.Add($tbCard) | Out-Null

$tbStack = [System.Windows.Controls.StackPanel]::new()
$tbCard.Child = $tbStack

# TB Header Row: Badge, Title, Letter combo, Status Pill
$tbHeaderDock = [System.Windows.Controls.DockPanel]::new()
$tbStack.Children.Add($tbHeaderDock) | Out-Null

# Right side: Status Pill
$tbStatusPill = [System.Windows.Controls.Border]::new()
$tbStatusPill.CornerRadius = [System.Windows.CornerRadius]::new(6)
$tbStatusPill.Padding = [System.Windows.Thickness]::new(10, 3, 10, 3)
$tbStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F1F5F9')
[System.Windows.Controls.DockPanel]::SetDock($tbStatusPill, 'Right')
$tbStatusPillText = New-Label '● Disconnected' 12 '#64748B' $true
$tbStatusPill.Child = $tbStatusPillText
$tbHeaderDock.Children.Add($tbStatusPill) | Out-Null

# Left side: Icon, Name, Drive letter selector
$tbTitleStack = [System.Windows.Controls.StackPanel]::new()
$tbTitleStack.Orientation = 'Horizontal'
$tbHeaderDock.Children.Add($tbTitleStack) | Out-Null

$tbIconBadge = [System.Windows.Controls.Border]::new()
$tbIconBadge.Width = 28; $tbIconBadge.Height = 28; $tbIconBadge.CornerRadius = [System.Windows.CornerRadius]::new(6)
$tbIconBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
$tbIconText = New-Label 'TB' 12 '#FFFFFF' $true
$tbIconText.HorizontalAlignment = 'Center'; $tbIconText.VerticalAlignment = 'Center'
$tbIconBadge.Child = $tbIconText
$tbIconBadge.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
$tbTitleStack.Children.Add($tbIconBadge) | Out-Null

$tbNameLabel = New-Label 'TeraBox' 16 '#0F172A' $true
$tbNameLabel.VerticalAlignment = 'Center'
$tbTitleStack.Children.Add($tbNameLabel) | Out-Null

$tbDriveLabel = New-Label 'Drive:' 12 '#64748B'
$tbDriveLabel.VerticalAlignment = 'Center'
$tbDriveLabel.Margin = [System.Windows.Thickness]::new(16, 0, 4, 0)
$tbTitleStack.Children.Add($tbDriveLabel) | Out-Null

$tbLetterCombo = [System.Windows.Controls.ComboBox]::new()
$tbLetterCombo.Width = 56; $tbLetterCombo.Height = 26
foreach ($l in $driveLetters) { [void]$tbLetterCombo.Items.Add("$($l):") }
$tbLetterCombo.SelectedItem = "$($script:TeraBoxLetter):"
$tbLetterCombo.Add_SelectionChanged({
    if ($tbLetterCombo.SelectedItem) {
        $sel = $tbLetterCombo.SelectedItem.ToString().TrimEnd(':')
        Set-PreferredDriveLetter -ProviderId 'terabox' -DriveLetter $sel
        $script:TeraBoxLetter = $sel
    }
})
$tbTitleStack.Children.Add($tbLetterCombo) | Out-Null

# TB Middle Row: Details & Storage Usage
$tbDetailStack = [System.Windows.Controls.StackPanel]::new()
$tbDetailStack.Margin = [System.Windows.Thickness]::new(0, 12, 0, 12)
$tbStack.Children.Add($tbDetailStack) | Out-Null

$tbAccountText = New-Label 'Not connected. Click Connect to sign in and mount virtual drive.' 13 '#475569'
$tbDetailStack.Children.Add($tbAccountText) | Out-Null

$tbQuotaText = New-Label '' 12 '#64748B'
$tbQuotaText.Visibility = 'Collapsed'
$tbDetailStack.Children.Add($tbQuotaText) | Out-Null

$tbErrorText = New-Label '' 12 '#DC2626'
$tbErrorText.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
$tbErrorText.Visibility = 'Collapsed'
$tbDetailStack.Children.Add($tbErrorText) | Out-Null

# TB Bottom Row: Direct Action Buttons
$tbActionsDock = [System.Windows.Controls.DockPanel]::new()
$tbStack.Children.Add($tbActionsDock) | Out-Null

$tbConnectBtn = [System.Windows.Controls.Button]::new()
$tbConnectBtn.Content = 'Connect'
$tbConnectBtn.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
$tbConnectBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
$tbConnectBtn.Foreground = [System.Windows.Media.Brushes]::White
$tbConnectBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$tbConnectBtn.BorderThickness = [System.Windows.Thickness]::new(0)
[System.Windows.Controls.DockPanel]::SetDock($tbConnectBtn, 'Left')
$tbActionsDock.Children.Add($tbConnectBtn) | Out-Null

$tbConnectedActions = [System.Windows.Controls.StackPanel]::new()
$tbConnectedActions.Orientation = 'Horizontal'
$tbConnectedActions.Visibility = 'Collapsed'
[System.Windows.Controls.DockPanel]::SetDock($tbConnectedActions, 'Left')
$tbActionsDock.Children.Add($tbConnectedActions) | Out-Null

$tbExplorerBtn = [System.Windows.Controls.Button]::new()
$tbExplorerBtn.Content = 'Open in Explorer'
$tbExplorerBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
$tbExplorerBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
$tbExplorerBtn.Foreground = [System.Windows.Media.Brushes]::White
$tbExplorerBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$tbExplorerBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$tbExplorerBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$tbConnectedActions.Children.Add($tbExplorerBtn) | Out-Null

$tbDisconnectBtn = [System.Windows.Controls.Button]::new()
$tbDisconnectBtn.Content = 'Disconnect'
$tbDisconnectBtn.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
$tbDisconnectBtn.Background = [System.Windows.Media.Brushes]::White
$tbDisconnectBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
$tbDisconnectBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$tbDisconnectBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#475569')
$tbConnectedActions.Children.Add($tbDisconnectBtn) | Out-Null

# --- UI State Synchronizer ---
function Update-AllUIState {
    if ($script:IsConnecting) { return }

    # 1. Google Drive State
    $gdCheck = Test-GoogleDriveBackendSession
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'

    if ($gdCheck.IsValid) {
        $userDisplay = if ($gdCheck.UserInfo.DisplayName) { $gdCheck.UserInfo.DisplayName } else { $gdCheck.UserInfo.EmailAddress }
        $mountInfo = if ($gdStatus.IsMounted) { "Mounted at $($gdStatus.DriveLetter):\" } else { "Authentication valid (Not mounted)" }
        $gdAccountText.Text = "Account: $userDisplay   •   $mountInfo"

        if ($gdCheck.UserInfo.QuotaTotal -gt 0) {
            $usedGb = [Math]::Round($gdCheck.UserInfo.QuotaUsed / 1GB, 2)
            $totalGb = [Math]::Round($gdCheck.UserInfo.QuotaTotal / 1GB, 2)
            $freeGb = [Math]::Round(($gdCheck.UserInfo.QuotaTotal - $gdCheck.UserInfo.QuotaUsed) / 1GB, 2)
            $pct = [Math]::Round(($gdCheck.UserInfo.QuotaUsed / $gdCheck.UserInfo.QuotaTotal) * 100, 1)

            $gdStorageBar.Value = [Math]::Min(100, [Math]::Max(0, $pct))
            $gdStorageBar.Visibility = 'Visible'
            $gdQuotaText.Text = "$usedGb GB of $totalGb GB used ($freeGb GB free, $pct%)"
            $gdQuotaText.Visibility = 'Visible'
        } else {
            $gdStorageBar.Visibility = 'Collapsed'
            $gdQuotaText.Visibility = 'Collapsed'
        }

        if ($gdStatus.IsMounted) {
            $gdStatusPillText.Text = "● Connected ($($gdStatus.DriveLetter):)"
            $gdStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#16A34A')
            $gdStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DCFCE7')
        } else {
            $gdStatusPillText.Text = "● Authorized"
            $gdStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
            $gdStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EFF6FF')
        }

        $gdConnectBtn.Visibility = 'Collapsed'
        $gdConnectedActions.Visibility = 'Visible'
        $gdLetterCombo.IsEnabled = (-not $gdStatus.IsMounted)
    } else {
        $gdAccountText.Text = 'Not connected. Click Connect to sign in and mount virtual drive.'
        $gdStorageBar.Visibility = 'Collapsed'
        $gdQuotaText.Visibility = 'Collapsed'

        $gdStatusPillText.Text = '● Disconnected'
        $gdStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#64748B')
        $gdStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F1F5F9')

        $gdConnectBtn.Visibility = 'Visible'
        $gdConnectedActions.Visibility = 'Collapsed'
        $gdLetterCombo.IsEnabled = $true
    }

    # 2. TeraBox State
    $tbCheck = Test-TeraBoxBackendSession
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'

    if ($tbCheck.IsValid) {
        $mountInfo = if ($tbStatus.IsMounted) { "Mounted at $($tbStatus.DriveLetter):\" } else { "Authentication valid (Not mounted)" }
        $tbAccountText.Text = "Account: $($tbCheck.UserInfo.UserName)   •   $mountInfo"

        $tbQuotaText.Text = 'Full drive access verified via secure web session.'
        $tbQuotaText.Visibility = 'Visible'

        if ($tbStatus.IsMounted) {
            $tbStatusPillText.Text = "● Connected ($($tbStatus.DriveLetter):)"
            $tbStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#16A34A')
            $tbStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#DCFCE7')
        } else {
            $tbStatusPillText.Text = "● Authorized"
            $tbStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
            $tbStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EFF6FF')
        }

        $tbConnectBtn.Visibility = 'Collapsed'
        $tbConnectedActions.Visibility = 'Visible'
        $tbLetterCombo.IsEnabled = (-not $tbStatus.IsMounted)
    } else {
        $tbAccountText.Text = 'Not connected. Click Connect to sign in and mount virtual drive.'
        $tbQuotaText.Visibility = 'Collapsed'

        $tbStatusPillText.Text = '● Disconnected'
        $tbStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#64748B')
        $tbStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F1F5F9')

        $tbConnectBtn.Visibility = 'Visible'
        $tbConnectedActions.Visibility = 'Collapsed'
        $tbLetterCombo.IsEnabled = $true
    }
}

# --- Action Event Handlers ---

# GOOGLE DRIVE: Connect Action
$gdConnectBtn.Add_Click({
    $script:IsConnecting = $true
    $gdStatusPillText.Text = '● Connecting...'
    $gdStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
    $gdStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#ECFDF5')
    $gdErrorText.Visibility = 'Collapsed'
    $gdConnectBtn.IsEnabled = $false

    try {
        $oauthCfg = Get-GoogleOAuthConfig
        if (-not $oauthCfg.IsConfigured) {
            $cfgRes = Show-GoogleClientConfigModal -Owner $window
            if (-not $cfgRes.Success) {
                $gdErrorText.Text = 'Google OAuth Client ID is required to connect.'
                $gdErrorText.Visibility = 'Visible'
                return
            }
            $oauthCfg = Get-GoogleOAuthConfig
        }

        $state = New-OAuthState
        $verifier = New-PkceVerifier
        $challenge = New-PkceChallenge $verifier

        $listenerCtx = Start-OAuthLoopbackListener -ExpectedState $state
        $authUrl = Build-GoogleAuthorizationUrl -ClientId $oauthCfg.ClientId -RedirectUri $listenerCtx.RedirectUri -State $state -CodeChallenge $challenge
        $gdAccountText.Text = 'Awaiting Google sign-in approval in browser...'
        [System.Diagnostics.Process]::Start($authUrl) | Out-Null

        $waitResult = Wait-OAuthLoopbackResponse -ListenerContext $listenerCtx -CancelCheck { -not $window.IsVisible }
        if ($waitResult.Success) {
            $gdAccountText.Text = 'Validating authorization code...'
            $tokenResult = Exchange-GoogleAuthCode -ClientId $oauthCfg.ClientId -ClientSecret $oauthCfg.ClientSecret -Code $waitResult.Code -RedirectUri $listenerCtx.RedirectUri -CodeVerifier $verifier
            if ($tokenResult.Success) {
                $gdAccountText.Text = 'Verifying Google Drive account access...'
                $verify = Test-GoogleDriveBackendSession -TokensOverride $tokenResult.Tokens
                if ($verify.IsValid) {
                    Save-GoogleDriveTokens -TokenData $tokenResult.Tokens

                    # Direct Auto-Mount
                    if (Test-WinFspInstalled) {
                        $gdAccountText.Text = "Mounting virtual drive ($($script:GDriveLetter):)..."
                        try {
                            $envVars = Get-GoogleDriveRcloneEnvironment
                            Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -VolumeLabel 'Google Drive' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars | Out-Null
                        } catch {
                            $gdErrorText.Text = "Connected, but could not mount $($script:GDriveLetter): $($_.Exception.Message)"
                            $gdErrorText.Visibility = 'Visible'
                        }
                    }
                } else {
                    $gdErrorText.Text = "Validation failed: $($verify.Error)"
                    $gdErrorText.Visibility = 'Visible'
                }
            } else {
                $gdErrorText.Text = "Authorization failed: $($tokenResult.Error)"
                $gdErrorText.Visibility = 'Visible'
            }
        } else {
            $gdErrorText.Text = "Authorization cancelled: $($waitResult.Error)"
            $gdErrorText.Visibility = 'Visible'
        }
    } catch {
        $gdErrorText.Text = "Error: $($_.Exception.Message)"
        $gdErrorText.Visibility = 'Visible'
    } finally {
        $script:IsConnecting = $false
        $gdConnectBtn.IsEnabled = $true
        Update-AllUIState
    }
})

# GOOGLE DRIVE: Explorer Action
$gdExplorerBtn.Add_Click({
    $status = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($status.IsMounted) {
        [System.Diagnostics.Process]::Start('explorer.exe', $status.DriveRoot) | Out-Null
    } else {
        # Mount first if not mounted
        try {
            $envVars = Get-GoogleDriveRcloneEnvironment
            $res = Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -VolumeLabel 'Google Drive' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars
            if ($res.Success) {
                [System.Diagnostics.Process]::Start('explorer.exe', $res.DriveRoot) | Out-Null
            }
        } catch {
            $gdErrorText.Text = "Mount failed: $($_.Exception.Message)"
            $gdErrorText.Visibility = 'Visible'
        }
        Update-AllUIState
    }
})

# GOOGLE DRIVE: Disconnect Action
$gdDisconnectBtn.Add_Click({
    Stop-VirtualDriveMount -ProviderId 'gdrive' | Out-Null
    Remove-GoogleDriveSession
    $gdErrorText.Visibility = 'Collapsed'
    Update-AllUIState
})

# TERABOX: Connect Action
$tbConnectBtn.Add_Click({
    $script:IsConnecting = $true
    $tbStatusPillText.Text = '● Connecting...'
    $tbStatusPillText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
    $tbStatusPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EFF6FF')
    $tbErrorText.Visibility = 'Collapsed'
    $tbConnectBtn.IsEnabled = $false

    try {
        $loginRes = Show-TeraBoxEmbeddedLoginWindow -Owner $window -OnLoginSucceeded {
            param($res)
            # Verified login completed in embedded browser
        }

        if ($loginRes.Success) {
            $tbAccountText.Text = "Mounting virtual drive ($($script:TeraBoxLetter):)..."
            $verifiedRclone = Get-VerifiedRclonePath
            if ($verifiedRclone -and (Test-WinFspInstalled)) {
                try {
                    $tbEnvVars = Get-TeraBoxRcloneEnvironment
                    Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -VolumeLabel 'TeraBox' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars | Out-Null
                } catch {
                    $tbErrorText.Text = "Connected, but could not mount $($script:TeraBoxLetter): $($_.Exception.Message)"
                    $tbErrorText.Visibility = 'Visible'
                }
            }
        } elseif (-not $loginRes.Cancelled) {
            $tbErrorText.Text = if ($loginRes.Error) { $loginRes.Error } else { 'Sign-in was not completed.' }
            $tbErrorText.Visibility = 'Visible'
        }
    } catch {
        $tbErrorText.Text = "Sign-in error: $($_.Exception.Message)"
        $tbErrorText.Visibility = 'Visible'
    } finally {
        $script:IsConnecting = $false
        $tbConnectBtn.IsEnabled = $true
        Update-AllUIState
    }
})

# TERABOX: Explorer Action
$tbExplorerBtn.Add_Click({
    $status = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($status.IsMounted) {
        [System.Diagnostics.Process]::Start('explorer.exe', $status.DriveRoot) | Out-Null
    } else {
        # Mount first if not mounted
        try {
            $tbEnvVars = Get-TeraBoxRcloneEnvironment
            $res = Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -VolumeLabel 'TeraBox' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars
            if ($res.Success) {
                [System.Diagnostics.Process]::Start('explorer.exe', $res.DriveRoot) | Out-Null
            }
        } catch {
            $tbErrorText.Text = "Mount failed: $($_.Exception.Message)"
            $tbErrorText.Visibility = 'Visible'
        }
        Update-AllUIState
    }
})

# TERABOX: Disconnect Action
$tbDisconnectBtn.Add_Click({
    Stop-VirtualDriveMount -ProviderId 'terabox' | Out-Null
    Remove-TeraBoxSession
    $tbErrorText.Visibility = 'Collapsed'
    Update-AllUIState
})

# --- System Tray Integration ---
$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Text = 'NS Cloud Drive'
$notifyIcon.Visible = $true

$trayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
$menuOpen = $trayMenu.Items.Add('Open NS Cloud Drive')
$menuOpen.Font = [System.Drawing.Font]::new($trayMenu.Font, [System.Drawing.FontStyle]::Bold)
$menuOpen.Add_Click({
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate() | Out-Null
    Update-AllUIState
})

$trayMenu.Items.Add('-') | Out-Null

$menuOpenGD = $trayMenu.Items.Add("Open Google Drive ($($script:GDriveLetter):\)")
$menuOpenGD.Add_Click({
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) {
        [System.Diagnostics.Process]::Start('explorer.exe', $gdStatus.DriveRoot) | Out-Null
    }
})

$menuOpenTB = $trayMenu.Items.Add("Open TeraBox ($($script:TeraBoxLetter):\)")
$menuOpenTB.Add_Click({
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) {
        [System.Diagnostics.Process]::Start('explorer.exe', $tbStatus.DriveRoot) | Out-Null
    }
})

$trayMenu.Items.Add('-') | Out-Null

$menuExit = $trayMenu.Items.Add('Exit NS Cloud Drive')
$menuExit.Add_Click({
    $script:IsExiting = $true
    Stop-VirtualDriveMount | Out-Null
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($script:RestoreEvent) {
        try { $script:RestoreEvent.Dispose() } catch { }
        $script:RestoreEvent = $null
    }
    if ($script:AppMutex) {
        try { $script:AppMutex.ReleaseMutex() } catch { }
        $script:AppMutex.Dispose()
        $script:AppMutex = $null
    }
    $window.Close()
})

$notifyIcon.ContextMenuStrip = $trayMenu
$notifyIcon.Add_DoubleClick({
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate() | Out-Null
    try {
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.AppActivate('NS Cloud Drive') | Out-Null
    } catch { }
    Update-AllUIState
})

$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:IsExiting) {
        if ($script:Settings.MinimizeToTrayOnClose) {
            $eventArgs.Cancel = $true
            $window.Hide()
            $notifyIcon.ShowBalloonTip(2000, 'NS Cloud Drive', 'Running in background. Double-click tray icon to open.', [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $script:IsExiting = $true
            Stop-VirtualDriveMount | Out-Null
            $notifyIcon.Visible = $false
            $notifyIcon.Dispose()
            if ($script:RestoreEvent) {
                try { $script:RestoreEvent.Dispose() } catch { }
                $script:RestoreEvent = $null
            }
            if ($script:AppMutex) {
                try { $script:AppMutex.ReleaseMutex() } catch { }
                $script:AppMutex.Dispose()
                $script:AppMutex = $null
            }
        }
    }
})

$window.Add_Activated({
    Update-AllUIState
})

$window.Add_Loaded({
    if (-not $Minimized) {
        $window.Activate() | Out-Null
        try {
            $wshell = New-Object -ComObject WScript.Shell
            $wshell.AppActivate('NS Cloud Drive') | Out-Null
        } catch { }
    }
})

# --- Background Refresh Timer ---
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if ($script:RestoreEvent) {
        try {
            if ($script:RestoreEvent.WaitOne(0)) {
                $window.Show()
                $window.WindowState = [System.Windows.WindowState]::Normal
                $window.Activate() | Out-Null
                try {
                    $wshell = New-Object -ComObject WScript.Shell
                    $wshell.AppActivate('NS Cloud Drive') | Out-Null
                } catch { }
                Update-AllUIState
                return
            }
        } catch { }
    }

    if ($window.IsVisible) {
        if (([DateTime]::UtcNow - $script:LastFullUpdate).TotalSeconds -ge 4) {
            Update-AllUIState
            $script:LastFullUpdate = [DateTime]::UtcNow
        }
    } else {
        if (([DateTime]::UtcNow - $script:LastFullUpdate).TotalSeconds -ge 30) {
            Update-AllUIState
            $script:LastFullUpdate = [DateTime]::UtcNow
        }
    }
})
$timer.Start()

# Initial UI population
Update-AllUIState

# --- Auto-Mount on Startup ---
if ($script:Settings.AutoMountDrives) {
    try {
        $gdCheck = Test-GoogleDriveBackendSession
        if ($gdCheck.IsValid) {
            $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
            if (-not $gdStatus.IsMounted) {
                $envVars = Get-GoogleDriveRcloneEnvironment
                Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -VolumeLabel 'Google Drive' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars | Out-Null
            }
        }

        $tbCheck = Test-TeraBoxBackendSession
        if ($tbCheck.IsValid -and (Get-VerifiedRclonePath)) {
            $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
            if (-not $tbStatus.IsMounted) {
                $tbEnvVars = Get-TeraBoxRcloneEnvironment
                Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -VolumeLabel 'TeraBox' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars | Out-Null
            }
        }
        Update-AllUIState
    } catch { }
}

if ($Minimized) {
    $window.Visibility = [System.Windows.Visibility]::Hidden
}

if ($MyInvocation.InvocationName -ne '.') {
    $app = [System.Windows.Application]::new()
    if ($Minimized) {
        $window.Hide()
        $app.Run()
    } else {
        $window.Show()
        $window.Activate() | Out-Null
        try {
            $wshell = New-Object -ComObject WScript.Shell
            $wshell.AppActivate('NS Cloud Drive') | Out-Null
        } catch { }
        [void]$app.Run($window)
    }
}
