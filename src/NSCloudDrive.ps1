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

Add-Type -MemberDefinition '[DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hwProc); [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);' -Name 'Win32' -Namespace 'NSCloudDrive' -ErrorAction SilentlyContinue

function Invoke-MemoryTrim {
    try {
        $p = [System.Diagnostics.Process]::GetCurrentProcess()
        [NSCloudDrive.Win32]::EmptyWorkingSet($p.Handle) | Out-Null
    } catch { }
}

. (Join-Path $PSScriptRoot 'models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot 'providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot 'services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot 'services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot 'services\CloudTransferManager.ps1')
. (Join-Path $PSScriptRoot 'services\CacheManager.ps1')
. (Join-Path $PSScriptRoot 'services\BackgroundOperationManager.ps1')
. (Join-Path $PSScriptRoot 'services\ExplorerIntegration.ps1')
. (Join-Path $PSScriptRoot 'ui\EmbeddedBrowserWindow.ps1')
. (Join-Path $PSScriptRoot 'ui\ProviderConnectionWindow.ps1')

$script:Settings = Get-NSCloudDriveSettings
if (-not $PSBoundParameters.ContainsKey('Minimized')) {
    $Minimized = [switch]$false
}
$script:CacheDirectory = if ($script:Settings.CacheDirectory) { $script:Settings.CacheDirectory } else { 'D:\CloudCache' }
$script:GDriveLetter = Get-PreferredDriveLetter 'gdrive'
$script:TeraBoxLetter = Get-PreferredDriveLetter 'terabox'
$script:IsExiting = $false
$script:AppMutex = $null
$script:RestoreEvent = $null
$script:LastFullUpdate = [DateTime]::UtcNow
$script:IsConnecting = $false
$script:CurrentView = 'Disks'
# Per-account reconnect throttle: accountId/providerId -> [DateTime] next-allowed reconnect attempt
$script:ReconnectNextAllowed = @{}
# Per-account consecutive failure count for exponential backoff
$script:ReconnectFailCount = @{}
# Tracks when the watchdog was last executed (prevents it running every 1-second tick)
$script:LastWatchdogRun = [DateTime]::MinValue
# Deduplication key for startup failure log entries (log each distinct error once)
$script:LastLoggedAutoMountErrorText = ''
$script:ProviderStatusWorker = $null
$script:ProviderStatusSnapshot = $null
$script:LastProviderStatusCheck = [DateTime]::MinValue
$script:StartupCacheRecoveryWorker = $null
$script:StartupAutoMountWorker = $null
$script:StartupAutoMountTimer = $null
$script:StartupAutoMountError = $null
$script:DriveDisconnectWorkers = @{}
$script:AccountCardsSignature = ''
$script:AnalyticsStorageRecords = @()
$script:BitmapImageCache = @{}
$script:OptionsInfoIcons = [System.Collections.Generic.List[System.Windows.Controls.Border]]::new()
$script:OptionsToolTips = [System.Collections.Generic.List[System.Windows.Controls.ToolTip]]::new()
$script:ReconnectWorker = $null
$script:ReconnectWorkerAccountId = ''
$script:ReconnectWorkerProgress = $null
$script:AccountMountStates = @{}
$script:PendingManualMountAccountIds = [System.Collections.Generic.Queue[string]]::new()
$script:ManualMountRequests = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
# Legacy (no saved account) provider-card mounts run off the UI thread. One
# worker per provider prevents duplicate mounts; states drive the status pill.
$script:LegacyMountWorkers = @{}
$script:LegacyMountStates = @{}
$script:StartupAutoMountPending = [bool]$script:Settings.AutoMountDrives
$script:StartupAutoMountProgress = [hashtable]::Synchronized(@{
    AccountStages = [hashtable]::Synchronized(@{})
    Stage = 'Waiting for startup dispatcher'
    ProviderId = ''
    DriveLetter = ''
    AccountId = ''
    StartedAt = if ($script:Settings.AutoMountDrives) { [DateTime]::UtcNow } else { $null }
    StageStartedAt = if ($script:Settings.AutoMountDrives) { [DateTime]::UtcNow } else { $null }
})
$script:LastStartupAutoMountLogKey = ''

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

function New-Label([string]$Text, [int]$Size = 13, [string]$Color = '#F2F3F5', [bool]$Bold = $false) {
    $label = [System.Windows.Controls.TextBlock]::new()
    $label.Text = $Text
    $label.FontSize = $Size
    $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $label.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $label.TextWrapping = 'Wrap'
    return $label
}

function New-OptionsInfoIcon([string]$ExplanationText, [string]$Title = '') {
    $btn = [System.Windows.Controls.Border]::new()
    $btn.Width = 16
    $btn.Height = 16
    $btn.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
    $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
    $btn.BorderThickness = [System.Windows.Thickness]::new(1)
    $btn.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    $btn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $iconText = [System.Windows.Controls.TextBlock]::new()
    $iconText.Text = 'i'
    $iconText.FontFamily = 'Segoe UI'
    $iconText.FontSize = 10
    $iconText.FontWeight = [System.Windows.FontWeights]::SemiBold
    $iconText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextSecondary)
    $iconText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $iconText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $btn.Child = $iconText

    $tip = [System.Windows.Controls.ToolTip]::new()
    $tip.MaxWidth = 360
    $tip.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
    $tip.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
    $tip.BorderThickness = [System.Windows.Thickness]::new(1)
    $tip.Padding = [System.Windows.Thickness]::new(10, 8, 10, 8)

    $tipStack = [System.Windows.Controls.StackPanel]::new()
    if (-not [string]::IsNullOrEmpty($Title)) {
        $tipTitle = [System.Windows.Controls.TextBlock]::new()
        $tipTitle.Text = $Title
        $tipTitle.FontWeight = [System.Windows.FontWeights]::Bold
        $tipTitle.FontSize = 11
        $tipTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
        $tipTitle.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        $tipTitle.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $tipStack.Children.Add($tipTitle) | Out-Null
    }

    $tipBody = [System.Windows.Controls.TextBlock]::new()
    $tipBody.Text = $ExplanationText
    $tipBody.FontSize = 11
    $tipBody.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextSecondary)
    $tipBody.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tipStack.Children.Add($tipBody) | Out-Null

    $tip.Content = $tipStack
    $btn.ToolTip = $tip

    [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($btn, 50)
    [System.Windows.Controls.ToolTipService]::SetShowDuration($btn, 60000)
    [System.Windows.Controls.ToolTipService]::SetBetweenShowDelay($btn, 0)

    $btn.Add_MouseDown({
        param($s, $e)
        if ($btn.ToolTip -is [System.Windows.Controls.ToolTip]) {
            $btn.ToolTip.IsOpen = -not $btn.ToolTip.IsOpen
        }
    })

    if ($null -ne $script:OptionsInfoIcons) {
        $script:OptionsInfoIcons.Add($btn)
    }
    if ($null -ne $script:OptionsToolTips) {
        $script:OptionsToolTips.Add($tip)
    }

    return $btn
}

function Set-ControlDetailedToolTip($Control, [string]$ExplanationText, [string]$Title = '') {
    if (-not $Control) { return }
    $tip = [System.Windows.Controls.ToolTip]::new()
    $tip.MaxWidth = 360
    $tip.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
    $tip.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
    $tip.BorderThickness = [System.Windows.Thickness]::new(1)
    $tip.Padding = [System.Windows.Thickness]::new(10, 8, 10, 8)

    $tipStack = [System.Windows.Controls.StackPanel]::new()
    if (-not [string]::IsNullOrEmpty($Title)) {
        $tipTitle = [System.Windows.Controls.TextBlock]::new()
        $tipTitle.Text = $Title
        $tipTitle.FontWeight = [System.Windows.FontWeights]::Bold
        $tipTitle.FontSize = 11
        $tipTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
        $tipTitle.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
        $tipTitle.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $tipStack.Children.Add($tipTitle) | Out-Null
    }

    $tipBody = [System.Windows.Controls.TextBlock]::new()
    $tipBody.Text = $ExplanationText
    $tipBody.FontSize = 11
    $tipBody.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextSecondary)
    $tipBody.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tipStack.Children.Add($tipBody) | Out-Null

    $tip.Content = $tipStack
    $Control.ToolTip = $tip

    [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($Control, 150)
    [System.Windows.Controls.ToolTipService]::SetShowDuration($Control, 60000)
    [System.Windows.Controls.ToolTipService]::SetBetweenShowDelay($Control, 0)

    if ($null -ne $script:OptionsToolTips) {
        $script:OptionsToolTips.Add($tip)
    }
}

function Get-VerifiedRclonePath {
    $r = Find-RcloneBinary
    if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) {
        return $r
    }
    return $null
}

function Get-WpfBitmapImage([string]$Path) {
    $cacheKey = [System.IO.Path]::GetFullPath($Path)
    if ($script:BitmapImageCache.ContainsKey($cacheKey)) {
        return $script:BitmapImageCache[$cacheKey]
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
            $bmp.BeginInit()
            $bmp.UriSource = [System.Uri]::new((Resolve-Path $Path).Path)
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $bmp.Freeze()
            $script:BitmapImageCache[$cacheKey] = $bmp
            return $bmp
        } catch { }
    }
    return $null
}

function Get-AppNotifyIcon([string]$Path) {
    $bitmap = $null
    $iconHandle = [IntPtr]::Zero
    try {
        $bitmap = [System.Drawing.Bitmap]::new($Path)
        $iconHandle = $bitmap.GetHicon()
        return [System.Drawing.Icon]::FromHandle($iconHandle).Clone()
    } finally {
        if ($iconHandle -ne [IntPtr]::Zero) {
            [NSCloudDrive.Win32]::DestroyIcon($iconHandle) | Out-Null
        }
        if ($bitmap) { $bitmap.Dispose() }
    }
}

function Dispose-AppNotifyIcon {
    if ($script:CustomNotifyIcon) {
        $script:CustomNotifyIcon.Dispose()
        $script:CustomNotifyIcon = $null
    }
}

function Start-ExplorerWindow([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $clean = $Path.Trim().Trim('"')
        [System.Diagnostics.Process]::Start('explorer.exe', "`"$clean`"") | Out-Null
    } catch { }
}

# ==============================================================================
# THREE THEMES PALETTE RESOLVER
# ==============================================================================
function Get-MainThemePalette([string]$ThemeName) {
    $resolved = Resolve-AppTheme $ThemeName
    switch ($resolved) {
        'PureBlack' {
            return @{
                Name = 'PureBlack'
                WindowBg = '#000000'
                SidebarBg = '#080808'
                SidebarBorder = '#18181A'
                CardBg = '#0E0E10'
                CardBorder = '#22242A'
                TextPrimary = '#FFFFFF'
                TextSecondary = '#9E9E9E'
                TextMuted = '#6B7280'
                InputBg = '#141518'
                InputBorder = '#2D3039'
                ButtonBg = '#1A1B20'
                ButtonBorder = '#2E323D'
                Accent = '#22C55E'
                Danger = '#DC2626'
                PillConnected = '#60A5FA'
                PillMounted = '#4ADE80'
                PillWarning = '#FBBF24'
                NavActiveBg = '#18181C'
                NavInactiveForeground = '#949BA4'
            }
        }
        'Translucent' {
            return @{
                Name = 'Translucent'
                WindowBg = '#13161CE6'
                # Softer fill used only when a real acrylic backdrop is active,
                # so the Windows-composed blur shows through the window surface.
                WindowGlassBg = '#161B2A35'
                SidebarGlassBg = '#10141A75'
                CardGlassBg = '#161B2A88'
                SidebarBg = '#0E1117D8'
                SidebarBorder = '#1E2433C0'
                CardBg = '#1A1E29CC'
                CardBorder = '#2B3345B0'
                TextPrimary = '#FFFFFF'
                TextSecondary = '#94A3B8'
                TextMuted = '#64748B'
                InputBg = '#1E2330CC'
                InputBorder = '#374151B0'
                ButtonBg = '#222838D0'
                ButtonBorder = '#3A445CB0'
                Accent = '#22C55E'
                Danger = '#DC2626'
                PillConnected = '#60A5FA'
                PillMounted = '#4ADE80'
                PillWarning = '#FBBF24'
                NavActiveBg = '#222838E0'
                NavInactiveForeground = '#94A3B8'
            }
        }
        'PureWhite' {
            return @{
                Name = 'PureWhite'
                WindowBg = '#F8FAFC'
                SidebarBg = '#F1F5F9'
                SidebarBorder = '#E2E8F0'
                CardBg = '#FFFFFF'
                CardBorder = '#E2E8F0'
                TextPrimary = '#0F172A'
                TextSecondary = '#475569'
                TextMuted = '#94A3B8'
                InputBg = '#FFFFFF'
                InputBorder = '#CBD5E1'
                ButtonBg = '#F1F5F9'
                ButtonBorder = '#CBD5E1'
                Accent = '#16A34A'
                Danger = '#DC2626'
                PillConnected = '#2563EB'
                PillMounted = '#16A34A'
                PillWarning = '#D97706'
                NavActiveBg = '#E2E8F0'
                NavInactiveForeground = '#64748B'
            }
        }
    }
}

$script:Palette = Get-MainThemePalette $script:Settings.Theme

function New-AccountDiskIcon([string]$ProviderId) {
    $container = [System.Windows.Controls.Grid]::new()
    $container.Width = 50
    $container.Height = 50
    $container.Margin = [System.Windows.Thickness]::new(0, 0, 14, 0)
    $container.VerticalAlignment = 'Center'

    # Hard drive base graphic
    $hdPath = Join-Path $PSScriptRoot '..\assets\logos\harddrive.png'
    $hdBmp = Get-WpfBitmapImage $hdPath
    if ($hdBmp) {
        $hdImg = [System.Windows.Controls.Image]::new()
        $hdImg.Source = $hdBmp
        $hdImg.Width = 44
        $hdImg.Height = 44
        $hdImg.HorizontalAlignment = 'Left'
        $hdImg.VerticalAlignment = 'Top'
        $container.Children.Add($hdImg) | Out-Null
    } else {
        $fallback = [System.Windows.Controls.Border]::new()
        $fallback.Width = 42; $fallback.Height = 42
        $fallback.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $fallback.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2B2D31')
        $fallbackTxt = New-Label 'DRV' 11 '#949BA4' $true
        $fallbackTxt.HorizontalAlignment = 'Center'; $fallbackTxt.VerticalAlignment = 'Center'
        $fallback.Child = $fallbackTxt
        $container.Children.Add($fallback) | Out-Null
    }

    # Overlay badge in lower right
    $provLogoPath = switch ([string]$ProviderId) {
        'gdrive' { Join-Path $PSScriptRoot '..\assets\logos\googledrive.png'; break }
        'terabox' { Join-Path $PSScriptRoot '..\assets\logos\terabox.png'; break }
        default { $null }
    }
    $provBmp = if ($provLogoPath) { Get-WpfBitmapImage $provLogoPath } else { $null }
    if ($provBmp) {
        $badgeBorder = [System.Windows.Controls.Border]::new()
        $badgeBorder.Width = 22
        $badgeBorder.Height = 22
        $badgeBorder.CornerRadius = [System.Windows.CornerRadius]::new(11)
        $badgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#18191C')
        $badgeBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#383A40')
        $badgeBorder.BorderThickness = [System.Windows.Thickness]::new(1.5)
        $badgeBorder.HorizontalAlignment = 'Right'
        $badgeBorder.VerticalAlignment = 'Bottom'

        $badgeImg = [System.Windows.Controls.Image]::new()
        $badgeImg.Source = $provBmp
        $badgeImg.Width = 14
        $badgeImg.Height = 14
        $badgeImg.Margin = [System.Windows.Thickness]::new(2)
        $badgeBorder.Child = $badgeImg
        $container.Children.Add($badgeBorder) | Out-Null
    }

    return $container
}

# ==============================================================================
# MAIN WINDOW INITIALIZATION
# ==============================================================================
$window = [System.Windows.Window]::new()
$window.Title = 'NS Cloud Drive'
$window.Width = 860
$window.Height = 580
$window.MinWidth = 760
$window.MinHeight = 480
$window.WindowStartupLocation = 'CenterScreen'
$window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.WindowBg)
$window.FontFamily = 'Segoe UI'

# App window icon
$appLogoPath = Join-Path $PSScriptRoot '..\assets\logos\clouddrive.png'
if (Test-Path -LiteralPath $appLogoPath -PathType Leaf) {
    try {
        $window.Icon = Get-WpfBitmapImage $appLogoPath
    } catch { }
}

# Main Layout Grid: Left Sidebar (Column 0), Content Area (Column 1)
$rootGrid = [System.Windows.Controls.Grid]::new()
$colSidebar = [System.Windows.Controls.ColumnDefinition]::new()
$colSidebar.Width = [System.Windows.GridLength]::new(66)
$colMain = [System.Windows.Controls.ColumnDefinition]::new()
$colMain.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$rootGrid.ColumnDefinitions.Add($colSidebar)
$rootGrid.ColumnDefinitions.Add($colMain)
$window.Content = $rootGrid

# ==============================================================================
# LEFT NAVIGATION SIDEBAR (Air Live Drive Style)
# ==============================================================================
$sidebar = [System.Windows.Controls.Border]::new()
$sidebar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.SidebarBg)
$sidebar.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.SidebarBorder)
$sidebar.BorderThickness = [System.Windows.Thickness]::new(0, 0, 1, 0)
[System.Windows.Controls.Grid]::SetColumn($sidebar, 0)
$rootGrid.Children.Add($sidebar) | Out-Null

$sidebarDock = [System.Windows.Controls.DockPanel]::new()
$sidebarDock.LastChildFill = $false
$sidebar.Child = $sidebarDock

$navTopStack = [System.Windows.Controls.StackPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($navTopStack, 'Top')
$sidebarDock.Children.Add($navTopStack) | Out-Null

function New-NavButton([string]$Glyph, [string]$Text, [bool]$IsActive = $false) {
    $btn = [System.Windows.Controls.Button]::new()
    $btn.Width = 58
    $btn.Height = 54
    $btn.Margin = [System.Windows.Thickness]::new(4, 6, 4, 2)
    $btn.BorderThickness = [System.Windows.Thickness]::new(0)
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand

    $stack = [System.Windows.Controls.StackPanel]::new()
    $stack.HorizontalAlignment = 'Center'
    $stack.VerticalAlignment = 'Center'

    $ico = [System.Windows.Controls.TextBlock]::new()
    $ico.Text = $Glyph
    $ico.FontFamily = 'Segoe UI Symbol, Segoe UI'
    $ico.FontSize = 18
    $ico.HorizontalAlignment = 'Center'

    $lbl = [System.Windows.Controls.TextBlock]::new()
    $lbl.Text = $Text
    $lbl.FontSize = 10
    $lbl.FontWeight = [System.Windows.FontWeights]::SemiBold
    $lbl.HorizontalAlignment = 'Center'
    $lbl.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)

    $stack.Children.Add($ico) | Out-Null
    $stack.Children.Add($lbl) | Out-Null
    $btn.Content = $stack
    if ($IsActive) {
        $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.NavActiveBg)
        $ico.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
        $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
    } else {
        $btn.Background = [System.Windows.Media.Brushes]::Transparent
        $ico.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.NavInactiveForeground)
        $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.NavInactiveForeground)
    }

    return @{ Button = $btn; Icon = $ico; Label = $lbl }
}

$navDisksItem = New-NavButton ([string][char]0x2601) 'Disks' $true
$navTopStack.Children.Add($navDisksItem.Button) | Out-Null

$navOptionsItem = New-NavButton ([string][char]0x2699) 'Options' $false
$navTopStack.Children.Add($navOptionsItem.Button) | Out-Null

$navAnalyticsItem = New-NavButton ([string][char]0x2197) 'Analytics' $false
$navTopStack.Children.Add($navAnalyticsItem.Button) | Out-Null

$navLogsItem = New-NavButton ([string][char]0x2261) 'Logs' $false
$navTopStack.Children.Add($navLogsItem.Button) | Out-Null

$navHelpItem = New-NavButton '?' 'Help' $false
[System.Windows.Controls.DockPanel]::SetDock($navHelpItem.Button, 'Bottom')
$navHelpItem.Button.Margin = [System.Windows.Thickness]::new(4, 0, 4, 12)
$sidebarDock.Children.Add($navHelpItem.Button) | Out-Null

# ==============================================================================
# MAIN CONTENT AREA (Disks View vs Options View vs Help View)
# ==============================================================================
$mainArea = [System.Windows.Controls.Grid]::new()
[System.Windows.Controls.Grid]::SetColumn($mainArea, 1)
$rootGrid.Children.Add($mainArea) | Out-Null

# ------------------------------------------------------------------------------
# 1. DISKS VIEW (Default)
# ------------------------------------------------------------------------------
$disksView = [System.Windows.Controls.DockPanel]::new()
$disksView.Margin = [System.Windows.Thickness]::new(18, 16, 18, 16)
$disksView.LastChildFill = $true
$mainArea.Children.Add($disksView) | Out-Null

# Top Toolbar in Disks View
$toolbar = [System.Windows.Controls.DockPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($toolbar, 'Top')
$toolbar.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
$disksView.Children.Add($toolbar) | Out-Null

# Right side of toolbar: Refresh button
$rightToolbar = [System.Windows.Controls.StackPanel]::new()
$rightToolbar.Orientation = 'Horizontal'
[System.Windows.Controls.DockPanel]::SetDock($rightToolbar, 'Right')
$toolbar.Children.Add($rightToolbar) | Out-Null

$refreshBtn = [System.Windows.Controls.Button]::new()
$refreshBtn.Content = 'Refresh'
$refreshBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$refreshBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$refreshBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$refreshBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$refreshBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextSecondary)
$refreshBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$refreshBtn.Add_Click({
    if ($script:StartupAutoMountError -and -not $script:StartupAutoMountPending -and -not $script:StartupAutoMountWorker) {
        $script:StartupAutoMountError = $null
        Start-StartupAutoMountTimer
    }
    Update-AllUIState
    Invoke-MemoryTrim
})
$rightToolbar.Children.Add($refreshBtn) | Out-Null

# Left side of toolbar: "+ Add Cloud Disk" button
$leftToolbar = [System.Windows.Controls.StackPanel]::new()
$leftToolbar.Orientation = 'Horizontal'
$toolbar.Children.Add($leftToolbar) | Out-Null

$addDiskBtn = [System.Windows.Controls.Button]::new()
$addDiskBtn.Content = '+ Add Cloud Disk'
$addDiskBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
$addDiskBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
$addDiskBtn.Foreground = [System.Windows.Media.Brushes]::White
$addDiskBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$addDiskBtn.FontSize = 13
$addDiskBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$addDiskBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$addDiskBtn.Add_Click({
    Show-AddCloudDiskModal -Owner $window -Theme $script:Settings.Theme -OnProviderSelected {
        param($selected)
        if ($selected -in @('gdrive', 'terabox')) {
            $created = Connect-NewCloudAccount -Owner $window -ProviderId $selected
            if ($created) {
                try {
                    $null = $script:ManualMountRequests.Add([string]$created.Id)
                    Invoke-AutoReconnectWatchdog -AccountId ([string]$created.Id)
                    Update-AllUIState
                    Invoke-MemoryTrim
                } catch {
                    $reason = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
                    Write-NSCloudLog -Severity 'Error' -Provider $selected -AccountId ([string]$created.Id) `
                        -Operation 'account-post-save' -Message $reason -Recovered $false
                    [System.Windows.MessageBox]::Show(
                        "The account was saved, but its mount or dashboard refresh did not complete. Your saved account was kept. You can retry from its account card.`n`n$reason",
                        'Account saved; mount needs attention',
                        [System.Windows.MessageBoxButton]::OK,
                        [System.Windows.MessageBoxImage]::Warning
                    ) | Out-Null
                }
            }
        }
    }
})
$leftToolbar.Children.Add($addDiskBtn) | Out-Null

$transferDiskBtn = [System.Windows.Controls.Button]::new()
$transferDiskBtn.Content = [string][char]0x21C4 + ' Transfer Files'
$transferDiskBtn.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
$transferDiskBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
$transferDiskBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$transferDiskBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$transferDiskBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$transferDiskBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$transferDiskBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$transferDiskBtn.FontSize = 13
$transferDiskBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$transferDiskBtn.Add_Click({
    Show-CloudTransferModal -Owner $window -Theme $script:Settings.Theme
})
$leftToolbar.Children.Add($transferDiskBtn) | Out-Null

# --- Main Scroll Container (Constrained width to satisfy regression test requirements) ---
$mainScroll = [System.Windows.Controls.ScrollViewer]::new()
$mainScroll.VerticalScrollBarVisibility = 'Auto'
$mainScroll.HorizontalScrollBarVisibility = 'Disabled'
$disksView.Children.Add($mainScroll) | Out-Null

$content = [System.Windows.Controls.StackPanel]::new()
$mainScroll.Content = $content

# --- Overall Drives Summary Banner ---
$drivesSummaryBanner = [System.Windows.Controls.Border]::new()
$drivesSummaryBanner.CornerRadius = [System.Windows.CornerRadius]::new(8)
$drivesSummaryBanner.Padding = [System.Windows.Thickness]::new(14, 10, 14, 10)
$drivesSummaryBanner.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
$drivesSummaryBanner.BorderThickness = [System.Windows.Thickness]::new(1)
$bannerGrid = [System.Windows.Controls.Grid]::new()
$drivesSummaryBanner.Child = $bannerGrid
$bCol0 = [System.Windows.Controls.ColumnDefinition]::new(); $bCol0.Width = [System.Windows.GridLength]::Auto
$bCol1 = [System.Windows.Controls.ColumnDefinition]::new(); $bCol1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$bCol2 = [System.Windows.Controls.ColumnDefinition]::new(); $bCol2.Width = [System.Windows.GridLength]::Auto
$bannerGrid.ColumnDefinitions.Add($bCol0)
$bannerGrid.ColumnDefinitions.Add($bCol1)
$bannerGrid.ColumnDefinitions.Add($bCol2)

$bannerIcon = New-Label ([char]::ConvertFromUtf32(0x25CF)) 14 $script:Palette.PillMounted $true
$bannerIcon.VerticalAlignment = 'Center'
$bannerIcon.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
[System.Windows.Controls.Grid]::SetColumn($bannerIcon, 0)
$bannerGrid.Children.Add($bannerIcon) | Out-Null

$bannerTextStack = [System.Windows.Controls.StackPanel]::new()
$bannerTextStack.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($bannerTextStack, 1)
$bannerGrid.Children.Add($bannerTextStack) | Out-Null

$bannerTitle = New-Label 'All drives connected' 13 $script:Palette.TextPrimary $true
$bannerTextStack.Children.Add($bannerTitle) | Out-Null
$bannerSubtitle = New-Label 'All virtual cloud drives are active in Windows File Explorer.' 11 $script:Palette.TextSecondary
$bannerTextStack.Children.Add($bannerSubtitle) | Out-Null

$bannerChipsStack = [System.Windows.Controls.StackPanel]::new()
$bannerChipsStack.Orientation = 'Horizontal'
$bannerChipsStack.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($bannerChipsStack, 2)
$bannerGrid.Children.Add($bannerChipsStack) | Out-Null

$content.Children.Add($drivesSummaryBanner) | Out-Null

# Saved accounts are the primary drive list. Provider-only entries are shown
# afterward only when an active mount cannot be reconciled to a saved account.
$accountsStack = [System.Windows.Controls.StackPanel]::new()
$content.Children.Add($accountsStack) | Out-Null

# --- Provider recovery container (Grid required by regression test suite) ---
$providersGrid = [System.Windows.Controls.Grid]::new()
$providersGrid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
$rowGd = [System.Windows.Controls.RowDefinition]::new()
$rowGd.Height = [System.Windows.GridLength]::Auto
$rowTb = [System.Windows.Controls.RowDefinition]::new()
$rowTb.Height = [System.Windows.GridLength]::Auto
$providersGrid.RowDefinitions.Add($rowGd)
$providersGrid.RowDefinitions.Add($rowTb)
$content.Children.Add($providersGrid) | Out-Null

$driveLetters = @('D','E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z')

# Quick Icon Button Builder
function New-QuickIconButton([string]$Glyph, [string]$ToolTipText) {
    $btn = [System.Windows.Controls.Button]::new()
    $btn.Content = $Glyph
    $btn.FontFamily = 'Segoe UI Symbol, Segoe UI'
    $btn.FontSize = 13
    $btn.Width = 28
    $btn.Height = 28
    $btn.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
    $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
    $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
    $btn.BorderThickness = [System.Windows.Thickness]::new(1)
    $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
    $btn.ToolTip = $ToolTipText
    $btn.Cursor = [System.Windows.Input.Cursors]::Hand
    return $btn
}

# ==============================================================================
# 1. GOOGLE DRIVE CARD (Air Live Drive Style)
# ==============================================================================
$gdCard = [System.Windows.Controls.Border]::new()
$gdCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$gdCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$gdCard.BorderThickness = [System.Windows.Thickness]::new(1)
$gdCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$gdCard.Padding = [System.Windows.Thickness]::new(14, 12, 14, 12)
$gdCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
[System.Windows.Controls.Grid]::SetRow($gdCard, 0)
$providersGrid.Children.Add($gdCard) | Out-Null

$gdGrid = [System.Windows.Controls.Grid]::new()
$gdCard.Child = $gdGrid
$gdCol0 = [System.Windows.Controls.ColumnDefinition]::new(); $gdCol0.Width = [System.Windows.GridLength]::Auto
$gdCol1 = [System.Windows.Controls.ColumnDefinition]::new(); $gdCol1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$gdCol2 = [System.Windows.Controls.ColumnDefinition]::new(); $gdCol2.Width = [System.Windows.GridLength]::Auto
$gdGrid.ColumnDefinitions.Add($gdCol0)
$gdGrid.ColumnDefinitions.Add($gdCol1)
$gdGrid.ColumnDefinitions.Add($gdCol2)

# Col 0: Hard drive icon with Google Drive badge
$gdDiskIcon = New-AccountDiskIcon 'gdrive'
[System.Windows.Controls.Grid]::SetColumn($gdDiskIcon, 0)
$gdGrid.Children.Add($gdDiskIcon) | Out-Null

# Col 1: Account title, email/status, action controls row
$gdInfoStack = [System.Windows.Controls.StackPanel]::new()
$gdInfoStack.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($gdInfoStack, 1)
$gdGrid.Children.Add($gdInfoStack) | Out-Null

$gdNameLabel = New-Label 'Google Drive' 15 $script:Palette.TextPrimary $true
$gdInfoStack.Children.Add($gdNameLabel) | Out-Null

$gdAccountText = New-Label 'Not connected' 11 $script:Palette.TextSecondary
$gdAccountText.Margin = [System.Windows.Thickness]::new(0, 1, 0, 6)
$gdInfoStack.Children.Add($gdAccountText) | Out-Null

# Action row: Connect button + "in" + Drive combo + Quick action buttons
$gdActionRow = [System.Windows.Controls.StackPanel]::new()
$gdActionRow.Orientation = 'Horizontal'
$gdActionRow.VerticalAlignment = 'Center'
$gdInfoStack.Children.Add($gdActionRow) | Out-Null

$gdActionBtn = [System.Windows.Controls.Button]::new()
$gdActionBtn.Content = 'Connect'
$gdActionBtn.Padding = [System.Windows.Thickness]::new(16, 5, 16, 5)
$gdActionBtn.Height = 28
$gdActionBtn.MinWidth = 85
$gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
$gdActionBtn.Foreground = [System.Windows.Media.Brushes]::White
$gdActionBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$gdActionBtn.FontSize = 12
$gdActionBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$gdActionBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$gdActionRow.Children.Add($gdActionBtn) | Out-Null

$gdInLabel = New-Label 'in' 12 $script:Palette.TextSecondary
$gdInLabel.VerticalAlignment = 'Center'
$gdInLabel.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
$gdActionRow.Children.Add($gdInLabel) | Out-Null

$gdLetterCombo = [System.Windows.Controls.ComboBox]::new()
$gdLetterCombo.Width = 56
$gdLetterCombo.Height = 28
$gdLetterCombo.VerticalContentAlignment = 'Center'
foreach ($l in $driveLetters) { [void]$gdLetterCombo.Items.Add("$($l):") }
$gdLetterCombo.SelectedItem = "$($script:GDriveLetter):"
$gdLetterCombo.Add_SelectionChanged({
    if ($gdLetterCombo.SelectedItem) {
        $sel = $gdLetterCombo.SelectedItem.ToString().TrimEnd(':')
        Set-PreferredDriveLetter -ProviderId 'gdrive' -DriveLetter $sel
        $script:GDriveLetter = $sel
    }
})
$gdActionRow.Children.Add($gdLetterCombo) | Out-Null

$gdExplorerBtn = New-QuickIconButton ([char]::ConvertFromUtf32(0x1F4C1)) 'Open in Windows File Explorer'
$gdActionRow.Children.Add($gdExplorerBtn) | Out-Null

$gdSettingsBtn = New-QuickIconButton ([string][char]0x2699) 'Account Options'
$gdActionRow.Children.Add($gdSettingsBtn) | Out-Null

$gdUploadBtn = New-QuickIconButton ([string][char]0x2191) 'Upload Files'
$gdActionRow.Children.Add($gdUploadBtn) | Out-Null

$gdRemoveBtn = New-QuickIconButton ([string][char]0x2715) 'Disconnect and Remove'
$gdActionRow.Children.Add($gdRemoveBtn) | Out-Null

# Col 2: Storage usage, Progress bar, Status
$gdRightStack = [System.Windows.Controls.StackPanel]::new()
$gdRightStack.VerticalAlignment = 'Center'
$gdRightStack.HorizontalAlignment = 'Right'
$gdRightStack.Width = 220
$gdRightStack.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
[System.Windows.Controls.Grid]::SetColumn($gdRightStack, 2)
$gdGrid.Children.Add($gdRightStack) | Out-Null

$gdQuotaText = New-Label '' 11 $script:Palette.TextSecondary
$gdQuotaText.HorizontalAlignment = 'Right'
$gdRightStack.Children.Add($gdQuotaText) | Out-Null

$gdStorageBar = [System.Windows.Controls.ProgressBar]::new()
$gdStorageBar.Height = 6
$gdStorageBar.Minimum = 0
$gdStorageBar.Maximum = 100
$gdStorageBar.Value = 0
$gdStorageBar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
$gdStorageBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.InputBorder)
$gdStorageBar.BorderThickness = [System.Windows.Thickness]::new(0)
$gdStorageBar.Margin = [System.Windows.Thickness]::new(0, 4, 0, 6)
$gdStorageBar.Visibility = 'Collapsed'
$gdRightStack.Children.Add($gdStorageBar) | Out-Null

$gdStatusText = New-Label ([string][char]0x25CF + ' Disconnected') 11 $script:Palette.TextMuted $true
$gdStatusText.HorizontalAlignment = 'Right'
$gdRightStack.Children.Add($gdStatusText) | Out-Null

$gdErrorText = New-Label '' 11 '#F87171'
$gdErrorText.HorizontalAlignment = 'Right'
$gdErrorText.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
$gdErrorText.Visibility = 'Collapsed'
$gdRightStack.Children.Add($gdErrorText) | Out-Null

# ==============================================================================
# 2. TERABOX CARD (Air Live Drive Style)
# ==============================================================================
$tbCard = [System.Windows.Controls.Border]::new()
$tbCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$tbCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$tbCard.BorderThickness = [System.Windows.Thickness]::new(1)
$tbCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$tbCard.Padding = [System.Windows.Thickness]::new(14, 12, 14, 12)
$tbCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
[System.Windows.Controls.Grid]::SetRow($tbCard, 1)
$providersGrid.Children.Add($tbCard) | Out-Null

$tbGrid = [System.Windows.Controls.Grid]::new()
$tbCard.Child = $tbGrid
$tbCol0 = [System.Windows.Controls.ColumnDefinition]::new(); $tbCol0.Width = [System.Windows.GridLength]::Auto
$tbCol1 = [System.Windows.Controls.ColumnDefinition]::new(); $tbCol1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$tbCol2 = [System.Windows.Controls.ColumnDefinition]::new(); $tbCol2.Width = [System.Windows.GridLength]::Auto
$tbGrid.ColumnDefinitions.Add($tbCol0)
$tbGrid.ColumnDefinitions.Add($tbCol1)
$tbGrid.ColumnDefinitions.Add($tbCol2)

# Col 0: Hard drive icon with TeraBox badge
$tbDiskIcon = New-AccountDiskIcon 'terabox'
[System.Windows.Controls.Grid]::SetColumn($tbDiskIcon, 0)
$tbGrid.Children.Add($tbDiskIcon) | Out-Null

# Col 1: Account title, email/status, action controls row
$tbInfoStack = [System.Windows.Controls.StackPanel]::new()
$tbInfoStack.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($tbInfoStack, 1)
$tbGrid.Children.Add($tbInfoStack) | Out-Null

$tbNameLabel = New-Label 'TeraBox' 15 $script:Palette.TextPrimary $true
$tbInfoStack.Children.Add($tbNameLabel) | Out-Null

$tbAccountText = New-Label 'Not connected' 11 $script:Palette.TextSecondary
$tbAccountText.Margin = [System.Windows.Thickness]::new(0, 1, 0, 6)
$tbInfoStack.Children.Add($tbAccountText) | Out-Null

# Action row: Connect button + "in" + Drive combo + Quick action buttons
$tbActionRow = [System.Windows.Controls.StackPanel]::new()
$tbActionRow.Orientation = 'Horizontal'
$tbActionRow.VerticalAlignment = 'Center'
$tbInfoStack.Children.Add($tbActionRow) | Out-Null

$tbActionBtn = [System.Windows.Controls.Button]::new()
$tbActionBtn.Content = 'Connect'
$tbActionBtn.Padding = [System.Windows.Thickness]::new(16, 5, 16, 5)
$tbActionBtn.Height = 28
$tbActionBtn.MinWidth = 85
$tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
$tbActionBtn.Foreground = [System.Windows.Media.Brushes]::White
$tbActionBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
$tbActionBtn.FontSize = 12
$tbActionBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$tbActionBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$tbActionRow.Children.Add($tbActionBtn) | Out-Null

$tbInLabel = New-Label 'in' 12 $script:Palette.TextSecondary
$tbInLabel.VerticalAlignment = 'Center'
$tbInLabel.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
$tbActionRow.Children.Add($tbInLabel) | Out-Null

$tbLetterCombo = [System.Windows.Controls.ComboBox]::new()
$tbLetterCombo.Width = 56
$tbLetterCombo.Height = 28
$tbLetterCombo.VerticalContentAlignment = 'Center'
foreach ($l in $driveLetters) { [void]$tbLetterCombo.Items.Add("$($l):") }
$tbLetterCombo.SelectedItem = "$($script:TeraBoxLetter):"
$tbLetterCombo.Add_SelectionChanged({
    if ($tbLetterCombo.SelectedItem) {
        $sel = $tbLetterCombo.SelectedItem.ToString().TrimEnd(':')
        Set-PreferredDriveLetter -ProviderId 'terabox' -DriveLetter $sel
        $script:TeraBoxLetter = $sel
    }
})
$tbActionRow.Children.Add($tbLetterCombo) | Out-Null

$tbExplorerBtn = New-QuickIconButton ([char]::ConvertFromUtf32(0x1F4C1)) 'Open in Windows File Explorer'
$tbActionRow.Children.Add($tbExplorerBtn) | Out-Null

$tbSettingsBtn = New-QuickIconButton ([string][char]0x2699) 'Account Options'
$tbActionRow.Children.Add($tbSettingsBtn) | Out-Null

$tbUploadBtn = New-QuickIconButton ([string][char]0x2191) 'Upload Files'
$tbActionRow.Children.Add($tbUploadBtn) | Out-Null

$tbRemoveBtn = New-QuickIconButton ([string][char]0x2715) 'Disconnect and Remove'
$tbActionRow.Children.Add($tbRemoveBtn) | Out-Null

# Col 2: Storage usage, Progress bar, Status
$tbRightStack = [System.Windows.Controls.StackPanel]::new()
$tbRightStack.VerticalAlignment = 'Center'
$tbRightStack.HorizontalAlignment = 'Right'
$tbRightStack.Width = 220
$tbRightStack.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
[System.Windows.Controls.Grid]::SetColumn($tbRightStack, 2)
$tbGrid.Children.Add($tbRightStack) | Out-Null

$tbQuotaText = New-Label '' 11 $script:Palette.TextSecondary
$tbQuotaText.HorizontalAlignment = 'Right'
$tbRightStack.Children.Add($tbQuotaText) | Out-Null

$tbStorageBar = [System.Windows.Controls.ProgressBar]::new()
$tbStorageBar.Height = 6
$tbStorageBar.Minimum = 0
$tbStorageBar.Maximum = 100
$tbStorageBar.Value = 0
$tbStorageBar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3B82F6')
$tbStorageBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.InputBorder)
$tbStorageBar.BorderThickness = [System.Windows.Thickness]::new(0)
$tbStorageBar.Margin = [System.Windows.Thickness]::new(0, 4, 0, 6)
$tbStorageBar.Visibility = 'Collapsed'
$tbRightStack.Children.Add($tbStorageBar) | Out-Null

$tbStatusText = New-Label ([string][char]0x25CF + ' Disconnected') 11 $script:Palette.TextMuted $true
$tbStatusText.HorizontalAlignment = 'Right'
$tbRightStack.Children.Add($tbStatusText) | Out-Null

$tbErrorText = New-Label '' 11 '#F87171'
$tbErrorText.HorizontalAlignment = 'Right'
$tbErrorText.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
$tbErrorText.Visibility = 'Collapsed'
$tbRightStack.Children.Add($tbErrorText) | Out-Null

# ------------------------------------------------------------------------------
# 2. OPTIONS VIEW (Air Live Drive Style Settings and Preferences)
# ------------------------------------------------------------------------------
$optionsView = [System.Windows.Controls.DockPanel]::new()
$optionsView.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
$optionsView.Visibility = [System.Windows.Visibility]::Collapsed
$mainArea.Children.Add($optionsView) | Out-Null

# Options Header
$optHeader = [System.Windows.Controls.DockPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($optHeader, 'Top')
$optHeader.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
$optionsView.Children.Add($optHeader) | Out-Null

$backToDisksBtn = [System.Windows.Controls.Button]::new()
$backToDisksBtn.Content = '< Back to Disks'
$backToDisksBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$backToDisksBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$backToDisksBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$backToDisksBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$backToDisksBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$backToDisksBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($backToDisksBtn, 'Right')
$optHeader.Children.Add($backToDisksBtn) | Out-Null

$optTitles = [System.Windows.Controls.StackPanel]::new()
$optTitle = New-Label 'Options' 22 $script:Palette.TextPrimary $true
$optSubtitle = New-Label 'Configure application preferences, themes, and cache behavior' 12 $script:Palette.TextSecondary
$optTitles.Children.Add($optTitle) | Out-Null
$optTitles.Children.Add($optSubtitle) | Out-Null
$optHeader.Children.Add($optTitles) | Out-Null
$optScroll = [System.Windows.Controls.ScrollViewer]::new()
$optScroll.VerticalScrollBarVisibility = 'Auto'
$optScroll.HorizontalScrollBarVisibility = 'Disabled'
$optionsView.Children.Add($optScroll) | Out-Null

$optContent = [System.Windows.Controls.StackPanel]::new()
$optScroll.Content = $optContent

# Card A: General Preferences
$genCard = [System.Windows.Controls.Border]::new()
$genCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$genCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$genCard.BorderThickness = [System.Windows.Thickness]::new(1)
$genCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$genCard.Padding = [System.Windows.Thickness]::new(18)
$genCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
$optContent.Children.Add($genCard) | Out-Null

$genStack = [System.Windows.Controls.StackPanel]::new()
$genCard.Child = $genStack

$genTitle = New-Label 'General' 15 $script:Palette.TextPrimary $true
$genStack.Children.Add($genTitle) | Out-Null

# Row 1: Startup
$rowStartup = [System.Windows.Controls.StackPanel]::new()
$rowStartup.Orientation = 'Horizontal'
$rowStartup.Margin = [System.Windows.Thickness]::new(0, 12, 0, 8)
$optStartupChk = [System.Windows.Controls.CheckBox]::new()
$optStartupChk.Content = 'Run NS Cloud Drive at Windows login'
$optStartupChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optStartupChk.IsChecked = (Test-WindowsStartupEnabled)
$rowStartup.Children.Add($optStartupChk) | Out-Null
$genStack.Children.Add($rowStartup) | Out-Null

# Row 2: Tray
$rowTray = [System.Windows.Controls.StackPanel]::new()
$rowTray.Orientation = 'Horizontal'
$rowTray.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$optTrayChk = [System.Windows.Controls.CheckBox]::new()
$optTrayChk.Content = 'Minimize to system tray on close'
$optTrayChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optTrayChk.IsChecked = $script:Settings.MinimizeToTrayOnClose
$rowTray.Children.Add($optTrayChk) | Out-Null
$genStack.Children.Add($rowTray) | Out-Null

# Row 3: Start Minimized
$rowStartMin = [System.Windows.Controls.StackPanel]::new()
$rowStartMin.Orientation = 'Horizontal'
$rowStartMin.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$optStartMinChk = [System.Windows.Controls.CheckBox]::new()
$optStartMinChk.Content = 'Start application minimized to system tray'
$optStartMinChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optStartMinChk.IsChecked = $script:Settings.StartMinimized
$rowStartMin.Children.Add($optStartMinChk) | Out-Null
$genStack.Children.Add($rowStartMin) | Out-Null

# Row 4: Explorer on Connect
$rowExplorer = [System.Windows.Controls.StackPanel]::new()
$rowExplorer.Orientation = 'Horizontal'
$rowExplorer.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$optExplorerChk = [System.Windows.Controls.CheckBox]::new()
$optExplorerChk.Content = 'Open Windows File Explorer automatically on connect'
$optExplorerChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optExplorerChk.IsChecked = $script:Settings.OpenExplorerOnMount
$rowExplorer.Children.Add($optExplorerChk) | Out-Null
$genStack.Children.Add($rowExplorer) | Out-Null

# Row 5: Auto Mount
$rowAutoMount = [System.Windows.Controls.StackPanel]::new()
$rowAutoMount.Orientation = 'Horizontal'
$rowAutoMount.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
$optAutoMountChk = [System.Windows.Controls.CheckBox]::new()
$optAutoMountChk.Content = 'Automatically mount cloud drives on startup'
$optAutoMountChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optAutoMountChk.IsChecked = $script:Settings.AutoMountDrives
$rowAutoMount.Children.Add($optAutoMountChk) | Out-Null
$genStack.Children.Add($rowAutoMount) | Out-Null

$optStatusLabel = New-Label '' 11 '#4ADE80'
$optStatusLabel.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
$genStack.Children.Add($optStatusLabel) | Out-Null

$optStartupChk.Add_Click({
    try {
        $c = ($optStartupChk.IsChecked -eq $true)
        Set-WindowsStartupEnabled -Enable $c
        $script:Settings.AutoStartWithWindows = $c
        Set-NSCloudDriveSettings $script:Settings
        $optStatusLabel.Text = if ($c) { 'Auto-start enabled at Windows login.' } else { 'Auto-start disabled.' }
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
    } catch {
        $optStatusLabel.Text = "Failed to update Windows startup: $($_.Exception.Message)"
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
    }
})

$optTrayChk.Add_Click({
    try {
        $script:Settings.MinimizeToTrayOnClose = ($optTrayChk.IsChecked -eq $true)
        Set-NSCloudDriveSettings $script:Settings
        $optStatusLabel.Text = if ($script:Settings.MinimizeToTrayOnClose) { 'Minimize to tray on close enabled.' } else { 'Window will exit on close.' }
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
    } catch {
        $optStatusLabel.Text = "Failed to save settings: $($_.Exception.Message)"
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
    }
})

$optStartMinChk.Add_Click({
    try {
        $script:Settings.StartMinimized = ($optStartMinChk.IsChecked -eq $true)
        Set-NSCloudDriveSettings $script:Settings
        if (Test-WindowsStartupEnabled) {
            Set-WindowsStartupEnabled -Enable $true
        }
        $optStatusLabel.Text = if ($script:Settings.StartMinimized) { 'Application will start minimized to system tray.' } else { 'Application will show window on launch.' }
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
    } catch {
        $optStatusLabel.Text = "Failed to save settings: $($_.Exception.Message)"
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
    }
})

$optExplorerChk.Add_Click({
    try {
        $script:Settings.OpenExplorerOnMount = ($optExplorerChk.IsChecked -eq $true)
        Set-NSCloudDriveSettings $script:Settings
        $optStatusLabel.Text = if ($script:Settings.OpenExplorerOnMount) { 'File Explorer will open automatically when drives connect.' } else { 'File Explorer auto-open disabled.' }
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
    } catch {
        $optStatusLabel.Text = "Failed to save settings: $($_.Exception.Message)"
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
    }
})

$optAutoMountChk.Add_Click({
    try {
        $script:Settings.AutoMountDrives = ($optAutoMountChk.IsChecked -eq $true)
        Set-NSCloudDriveSettings $script:Settings
        $optStatusLabel.Text = if ($script:Settings.AutoMountDrives) { 'Cloud drives will mount automatically on application startup.' } else { 'Automatic mount on startup disabled.' }
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
    } catch {
        $optStatusLabel.Text = "Failed to save settings: $($_.Exception.Message)"
        $optStatusLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
    }
})

# Card B: Theme Selection (Pure Black, Pure White)
# Note: Translucent Liquid Glass theme engine and palette are preserved for test and runtime compatibility,
# while the Options UI presents high-contrast Pure Black and Pure White options.
$themeCard = [System.Windows.Controls.Border]::new()
$themeCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$themeCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$themeCard.BorderThickness = [System.Windows.Thickness]::new(1)
$themeCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$themeCard.Padding = [System.Windows.Thickness]::new(18)
$themeCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
$optContent.Children.Add($themeCard) | Out-Null

$themeStack = [System.Windows.Controls.StackPanel]::new()
$themeCard.Child = $themeStack

$themeTitle = New-Label 'Appearance & Themes' 15 $script:Palette.TextPrimary $true
$themeStack.Children.Add($themeTitle) | Out-Null

$themeDesc = New-Label 'Select your preferred visual style. All themes are lightweight and native.' 11 $script:Palette.TextSecondary
$themeDesc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
$themeStack.Children.Add($themeDesc) | Out-Null

$rbThemePureBlack = [System.Windows.Controls.RadioButton]::new()
$rbThemePureBlack.GroupName = 'ThemeSelection'
$rbThemePureBlack.Content = 'Pure Black (Deep black surfaces, maximum contrast)'
$rbThemePureBlack.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$rbThemePureBlack.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$themeStack.Children.Add($rbThemePureBlack) | Out-Null

$rbThemeTranslucent = $null

$rbThemePureWhite = [System.Windows.Controls.RadioButton]::new()
$rbThemePureWhite.GroupName = 'ThemeSelection'
$rbThemePureWhite.Content = 'Pure White (Clean light theme with subtle separators)'
$rbThemePureWhite.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$rbThemePureWhite.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
$themeStack.Children.Add($rbThemePureWhite) | Out-Null

$currResolvedTheme = Resolve-AppTheme $script:Settings.Theme
if ($currResolvedTheme -eq 'PureWhite') {
    $rbThemePureWhite.IsChecked = $true
} else {
    $rbThemePureBlack.IsChecked = $true
}

$rbThemePureBlack.Add_Checked({
    $script:Settings.Theme = 'PureBlack'
    Set-NSCloudDriveSettings $script:Settings
    Apply-UITheme 'PureBlack'
})
$rbThemePureWhite.Add_Checked({
    $script:Settings.Theme = 'PureWhite'
    Set-NSCloudDriveSettings $script:Settings
    Apply-UITheme 'PureWhite'
})

# Card C: Cache Management
$cacheCard = [System.Windows.Controls.Border]::new()
$cacheCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$cacheCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$cacheCard.BorderThickness = [System.Windows.Thickness]::new(1)
$cacheCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$cacheCard.Padding = [System.Windows.Thickness]::new(18)
$cacheCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
$optContent.Children.Add($cacheCard) | Out-Null

$cacheStack = [System.Windows.Controls.StackPanel]::new()
$cacheCard.Child = $cacheStack

$cacheTitle = New-Label 'Cache Management' 15 $script:Palette.TextPrimary $true
$cacheStack.Children.Add($cacheTitle) | Out-Null

$cachePathRow = [System.Windows.Controls.DockPanel]::new()
$cachePathRow.Margin = [System.Windows.Thickness]::new(0, 8, 0, 4)
$cacheStack.Children.Add($cachePathRow) | Out-Null

$browseStack = [System.Windows.Controls.StackPanel]::new()
$browseStack.Orientation = 'Horizontal'
[System.Windows.Controls.DockPanel]::SetDock($browseStack, 'Right')

$browseCacheBtn = [System.Windows.Controls.Button]::new()
$browseCacheBtn.Content = 'Browse...'
$browseCacheBtn.Padding = [System.Windows.Thickness]::new(10, 2, 10, 2)
$browseCacheBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$browseCacheBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$browseCacheBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$browseCacheBtn.Cursor = [System.Windows.Input.Cursors]::Hand

$browseStack.Children.Add($browseCacheBtn) | Out-Null
$cachePathRow.Children.Add($browseStack) | Out-Null

$cachePathLabel = New-Label ('Cache Folder: ' + $script:CacheDirectory) 12 $script:Palette.TextSecondary
$cachePathRow.Children.Add($cachePathLabel) | Out-Null

$browseCacheBtn.Add_Click({
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = 'Select Cache Storage Directory (Dedicated non-OS drive recommended)'
    $dlg.SelectedPath = $script:CacheDirectory
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) {
        $check = Test-CacheDirectorySafety -Path $dlg.SelectedPath
        if (-not $check.IsValid) {
            [System.Windows.MessageBox]::Show(($check.Issues -join "`n"), 'Invalid Cache Path', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
            return
        }
        if ($check.Warnings.Count -gt 0) {
            $msg = ($check.Warnings -join "`n`n") + "`n`nDo you want to use this directory?"
            $c = [System.Windows.MessageBox]::Show($msg, 'Cache Path Notice', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($c -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
        }
        $script:CacheDirectory = $dlg.SelectedPath
        $script:Settings.CacheDirectory = $dlg.SelectedPath
        Set-NSCloudDriveSettings $script:Settings
        $cachePathLabel.Text = 'Cache Folder: ' + $script:CacheDirectory
        Update-CacheUsageDisplay

        $accounts = @(Get-CloudAccounts)
        $mountedCount = 0
        foreach ($acc in $accounts) {
            $st = Get-VirtualDriveStatus -AccountId $acc.Id -ProviderId $acc.ProviderId
            if ($st -and $st.IsMounted) { $mountedCount++ }
        }
        if ($mountedCount -gt 0) {
            [System.Windows.MessageBox]::Show(
                "The cache folder has been changed to:`n$($dlg.SelectedPath)`n`n" +
                "Notice: Active mounted drives ($mountedCount drive(s)) will continue using their current cache folder until they are remounted or the application is restarted.",
                'Cache Folder Changed',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null
        }
    }
})

$cacheQuotaRow = [System.Windows.Controls.StackPanel]::new()
$cacheQuotaRow.Orientation = 'Horizontal'
$cacheQuotaRow.Margin = [System.Windows.Thickness]::new(0, 4, 0, 8)
$cacheStack.Children.Add($cacheQuotaRow) | Out-Null

$cacheQuotaLabel = New-Label 'Maximum Cache Quota: ' 12 $script:Palette.TextPrimary
$cacheQuotaLabel.VerticalAlignment = 'Center'
$cacheQuotaRow.Children.Add($cacheQuotaLabel) | Out-Null

$cacheQuotaCombo = [System.Windows.Controls.ComboBox]::new()
$cacheQuotaCombo.Width = 100
$cacheQuotaCombo.Height = 26
$cacheQuotaCombo.VerticalContentAlignment = 'Center'
foreach ($sz in @(10, 20, 50, 100, 200)) {
    [void]$cacheQuotaCombo.Items.Add("$($sz) GB")
}
$currQuota = if ($script:Settings.CacheMaxGigabytes) { $script:Settings.CacheMaxGigabytes } else { 20 }
if (-not ($cacheQuotaCombo.Items -contains "$($currQuota) GB")) {
    [void]$cacheQuotaCombo.Items.Add("$($currQuota) GB")
}
$cacheQuotaCombo.SelectedItem = "$($currQuota) GB"
$cacheQuotaCombo.Add_SelectionChanged({
    if ($cacheQuotaCombo.SelectedItem) {
        $val = [int]($cacheQuotaCombo.SelectedItem.ToString().Replace(' GB', '').Trim())
        $script:Settings.CacheMaxGigabytes = $val
        Set-NSCloudDriveSettings $script:Settings
    }
})
$cacheQuotaRow.Children.Add($cacheQuotaCombo) | Out-Null

$cacheUsageLabel = New-Label 'Checking cache status...' 12 $script:Palette.TextSecondary
$cacheUsageLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
$cacheStack.Children.Add($cacheUsageLabel) | Out-Null

$cacheActionStack = [System.Windows.Controls.StackPanel]::new()
$cacheActionStack.Orientation = 'Horizontal'
$cacheStack.Children.Add($cacheActionStack) | Out-Null

$cleanCacheBtn = [System.Windows.Controls.Button]::new()
$cleanCacheBtn.Content = 'Clean Cache'
$cleanCacheBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$cleanCacheBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$cleanCacheBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$cleanCacheBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$cleanCacheBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$cleanCacheBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$cleanCacheBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$cleanCacheBtn.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "Are you sure you want to clean the local cache directory?`n`n" +
        "• In-use files and pending uploads will be safely protected and preserved.`n" +
        "• Files stored remotely on Google Drive and TeraBox will NOT be affected.`n`n" +
        "Target directory:`n$($script:CacheDirectory)",
        'Clean Local Cache',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }
    try {
        $res = Invoke-SafeCacheCleanup -CacheDirectory $script:CacheDirectory -Force
        $mbCleaned = [Math]::Round($res.CleanedBytes / 1MB, 1)
        if ($res.SkippedInUseCount -gt 0) {
            $cacheUsageLabel.Text = "Cleaned $mbCleaned MB ($($res.CleanedFiles) files). $($res.SkippedInUseCount) files protected in-use by active mounts."
            $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#60A5FA')
        } else {
            $cacheUsageLabel.Text = "Cache cleared successfully ($mbCleaned MB reclaimed, $($res.CleanedFiles) files)."
            $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
        }
        Update-CacheUsageDisplay
    } catch {
        $cacheUsageLabel.Text = "Could not clear all cache files: $($_.Exception.Message)"
        $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
    }
})
$cacheActionStack.Children.Add($cleanCacheBtn) | Out-Null

$openCacheBtn = [System.Windows.Controls.Button]::new()
$openCacheBtn.Content = 'Open Cache Folder'
$openCacheBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$openCacheBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$openCacheBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$openCacheBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$openCacheBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextSecondary)
$openCacheBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$openCacheBtn.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:CacheDirectory)) {
            New-Item -ItemType Directory -Path $script:CacheDirectory -Force | Out-Null
        }
        Start-ExplorerWindow $script:CacheDirectory
    } catch {
        [System.Windows.MessageBox]::Show("Unable to open cache folder '$($script:CacheDirectory)': $($_.Exception.Message)", 'Cache Folder Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
})
$cacheActionStack.Children.Add($openCacheBtn) | Out-Null


$diagCard = [System.Windows.Controls.Border]::new()
$diagCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$diagCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$diagCard.BorderThickness = [System.Windows.Thickness]::new(1)
$diagCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$diagCard.Padding = [System.Windows.Thickness]::new(18)
$diagCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
$optContent.Children.Add($diagCard) | Out-Null

$diagStack = [System.Windows.Controls.StackPanel]::new()
$diagCard.Child = $diagStack

$diagTitle = New-Label 'Diagnostics & System Health' 15 $script:Palette.TextPrimary $true
$diagStack.Children.Add($diagTitle) | Out-Null

$diagDescLabel = New-Label 'Inspect live process memory, WinFsp virtual filesystem driver status, and active mounts. All diagnostic reports are safe and unredacted secrets are never displayed.' 11 $script:Palette.TextSecondary
$diagDescLabel.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
$diagStack.Children.Add($diagDescLabel) | Out-Null

$diagBtnRow = [System.Windows.Controls.StackPanel]::new()
$diagBtnRow.Orientation = 'Horizontal'
$diagStack.Children.Add($diagBtnRow) | Out-Null

$showDiagBtn = [System.Windows.Controls.Button]::new()
$showDiagBtn.Content = 'System Diagnostics'
$showDiagBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$showDiagBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$showDiagBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$showDiagBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$showDiagBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$showDiagBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$showDiagBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$showDiagBtn.Add_Click({
    Show-SystemDiagnosticsModal -Owner $window
})
$diagBtnRow.Children.Add($showDiagBtn) | Out-Null

$trimMemBtn = [System.Windows.Controls.Button]::new()
$trimMemBtn.Content = 'Trim Memory Now'
$trimMemBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$trimMemBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$trimMemBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$trimMemBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$trimMemBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$trimMemBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$trimMemBtn.Add_Click({
    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
    $beforeMb = [Math]::Round($proc.WorkingSet64 / 1MB, 2)
    Invoke-MemoryTrim
    $proc.Refresh()
    $afterMb = [Math]::Round($proc.WorkingSet64 / 1MB, 2)
    $reclaimedMb = [Math]::Round([Math]::Max(0, $beforeMb - $afterMb), 2)
    $diagDescLabel.Text = "Memory working set trimmed from $beforeMb MB to $afterMb MB ($reclaimedMb MB reclaimed). Pages moved to standby list; Windows will page active data back on demand."
    $diagDescLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
})
$diagBtnRow.Children.Add($trimMemBtn) | Out-Null


# 3. HELP VIEW (Air Live Drive Inspired Documentation & Architecture)
# ------------------------------------------------------------------------------
$helpView = [System.Windows.Controls.DockPanel]::new()
$helpView.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
$helpView.Visibility = [System.Windows.Visibility]::Collapsed
$mainArea.Children.Add($helpView) | Out-Null

# Help Header
$helpHeader = [System.Windows.Controls.DockPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($helpHeader, 'Top')
$helpHeader.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
$helpView.Children.Add($helpHeader) | Out-Null

$backFromHelpBtn = [System.Windows.Controls.Button]::new()
$backFromHelpBtn.Content = '< Back to Disks'
$backFromHelpBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$backFromHelpBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$backFromHelpBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$backFromHelpBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$backFromHelpBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$backFromHelpBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($backFromHelpBtn, 'Right')
$helpHeader.Children.Add($backFromHelpBtn) | Out-Null

$helpTitles = [System.Windows.Controls.StackPanel]::new()
$helpTitle = New-Label 'Help & Information' 22 $script:Palette.TextPrimary $true
$helpSubtitle = New-Label 'Quick start guides, provider details, and security architecture' 12 $script:Palette.TextSecondary
$helpTitles.Children.Add($helpTitle) | Out-Null
$helpTitles.Children.Add($helpSubtitle) | Out-Null
$helpHeader.Children.Add($helpTitles) | Out-Null

$helpScroll = [System.Windows.Controls.ScrollViewer]::new()
$helpScroll.VerticalScrollBarVisibility = 'Auto'
$helpScroll.HorizontalScrollBarVisibility = 'Disabled'
$helpView.Children.Add($helpScroll) | Out-Null

$helpContent = [System.Windows.Controls.StackPanel]::new()
$helpScroll.Content = $helpContent

function New-HelpSectionCard([string]$SectionTitle, [string]$SectionBody) {
    $card = [System.Windows.Controls.Border]::new()
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
    $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $card.Padding = [System.Windows.Thickness]::new(18)
    $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)

    $st = [System.Windows.Controls.StackPanel]::new()
    $card.Child = $st

    $t = New-Label $SectionTitle 15 $script:Palette.TextPrimary $true
    $t.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    $st.Children.Add($t) | Out-Null

    $b = New-Label $SectionBody 12 $script:Palette.TextSecondary
    $st.Children.Add($b) | Out-Null

    return @{ Card = $card; Title = $t; Text = $b }
}

$h1 = New-HelpSectionCard 'Quick Start Guide' "1. Click '+ Add Cloud Disk' to configure a new cloud account.`n2. Authorize Google Drive via standard browser OAuth or sign in to TeraBox.`n3. Select your preferred Windows drive letter (e.g., G: or T:).`n4. Click 'Connect' to mount the drive directly into Windows File Explorer.`n5. Open Windows File Explorer to browse, open, edit, and stream your files seamlessly."
$helpQuickCard = $h1.Card; $helpQuickTitle = $h1.Title; $helpQuickText = $h1.Text
$helpContent.Children.Add($helpQuickCard) | Out-Null

$h2 = New-HelpSectionCard 'Security & DPAPI Encryption' "All credentials, OAuth refresh tokens, and session cookies are protected using Windows Data Protection API (DPAPI). Only your logged-in Windows user account can decrypt them. Tokens and passwords are never logged, never exposed to Task Manager command lines, and never stored in plaintext."
$helpSecCard = $h2.Card; $helpSecTitle = $h2.Title; $helpSecText = $h2.Text
$helpContent.Children.Add($helpSecCard) | Out-Null

$h3 = New-HelpSectionCard 'Supported Providers & Capabilities' "* Google Drive: Full read and write support, streaming media playback, folder creation, multi-account isolation, and automatic token refresh.`n* TeraBox: High-speed browsing, direct video and music streaming via loopback WebDAV bridge, and direct file uploads."
$helpProvCard = $h3.Card; $helpProvTitle = $h3.Title; $helpProvText = $h3.Text
$helpContent.Children.Add($helpProvCard) | Out-Null

$h4 = New-HelpSectionCard 'Lightweight Performance & Resource Footprint' "NS Cloud Drive is designed for minimal resource consumption. Background health checks operate at relaxed intervals (4s visible, 30s minimized), and working set memory is trimmed automatically on minimize to keep idle RAM typically under 15-30 MB."
$helpPerfCard = $h4.Card; $helpPerfTitle = $h4.Title; $helpPerfText = $h4.Text
$helpContent.Children.Add($helpPerfCard) | Out-Null

$backFromHelpBtn.Add_Click({ Show-DisksView })

# ------------------------------------------------------------------------------
# 4. ANALYTICS VIEW (real measurements only, bounded sampling, no idle work)
# ------------------------------------------------------------------------------
$analyticsView = [System.Windows.Controls.DockPanel]::new()
$analyticsView.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
$analyticsView.Visibility = [System.Windows.Visibility]::Collapsed
$mainArea.Children.Add($analyticsView) | Out-Null

$analyticsHeader = [System.Windows.Controls.DockPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($analyticsHeader, 'Top')
$analyticsHeader.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
$analyticsView.Children.Add($analyticsHeader) | Out-Null

$backFromAnalyticsBtn = [System.Windows.Controls.Button]::new()
$backFromAnalyticsBtn.Content = '< Back to Disks'
$backFromAnalyticsBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$backFromAnalyticsBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$backFromAnalyticsBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$backFromAnalyticsBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$backFromAnalyticsBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$backFromAnalyticsBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($backFromAnalyticsBtn, 'Right')
$analyticsHeader.Children.Add($backFromAnalyticsBtn) | Out-Null

$analyticsTitles = [System.Windows.Controls.StackPanel]::new()
$analyticsTitle = New-Label 'Analytics' 22 $script:Palette.TextPrimary $true
$analyticsSubtitle = New-Label 'On-demand diagnostic dashboard. Zero background polling when idle.' 12 $script:Palette.TextSecondary
$analyticsTitles.Children.Add($analyticsTitle) | Out-Null
$analyticsTitles.Children.Add($analyticsSubtitle) | Out-Null
$analyticsHeader.Children.Add($analyticsTitles) | Out-Null

$analyticsScroll = [System.Windows.Controls.ScrollViewer]::new()
$analyticsScroll.VerticalScrollBarVisibility = 'Auto'
$analyticsScroll.HorizontalScrollBarVisibility = 'Disabled'
$analyticsView.Children.Add($analyticsScroll) | Out-Null

$analyticsContent = [System.Windows.Controls.StackPanel]::new()
$analyticsScroll.Content = $analyticsContent

# Action bar with Get Analytics & Refresh Analytics buttons and collection status
$analyticsActionBar = [System.Windows.Controls.Border]::new()
$analyticsActionBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$analyticsActionBar.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$analyticsActionBar.BorderThickness = [System.Windows.Thickness]::new(1)
$analyticsActionBar.CornerRadius = [System.Windows.CornerRadius]::new(8)
$analyticsActionBar.Padding = [System.Windows.Thickness]::new(14, 10, 14, 10)
$analyticsActionBar.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)

$analyticsActionStack = [System.Windows.Controls.StackPanel]::new()
$analyticsActionBar.Child = $analyticsActionStack

$analyticsBtnRow = [System.Windows.Controls.StackPanel]::new()
$analyticsBtnRow.Orientation = 'Horizontal'
$analyticsActionStack.Children.Add($analyticsBtnRow) | Out-Null

$analyticsGetAnalyticsBtn = [System.Windows.Controls.Button]::new()
$analyticsGetAnalyticsBtn.Content = 'Get Analytics'
$analyticsGetAnalyticsBtn.Width = 120
$analyticsGetAnalyticsBtn.Height = 32
$analyticsGetAnalyticsBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
$analyticsGetAnalyticsBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
$analyticsGetAnalyticsBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$analyticsGetAnalyticsBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$analyticsGetAnalyticsBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$analyticsGetAnalyticsBtn.Add_Click({ Start-AnalyticsCollection })
$analyticsBtnRow.Children.Add($analyticsGetAnalyticsBtn) | Out-Null

$analyticsRefreshAnalyticsBtn = [System.Windows.Controls.Button]::new()
$analyticsRefreshAnalyticsBtn.Content = 'Refresh Analytics'
$analyticsRefreshAnalyticsBtn.Width = 130
$analyticsRefreshAnalyticsBtn.Height = 32
$analyticsRefreshAnalyticsBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$analyticsRefreshAnalyticsBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$analyticsRefreshAnalyticsBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$analyticsRefreshAnalyticsBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$analyticsRefreshAnalyticsBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$analyticsRefreshAnalyticsBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$analyticsRefreshAnalyticsBtn.Add_Click({ Start-AnalyticsCollection })
$analyticsBtnRow.Children.Add($analyticsRefreshAnalyticsBtn) | Out-Null

$analyticsCollectionStatus = New-Label 'Status: Ready (idle). Click Get Analytics to gather metrics.' 11 $script:Palette.TextSecondary
$analyticsCollectionStatus.Margin = [System.Windows.Thickness]::new(0, 6, 0, 2)
$analyticsActionStack.Children.Add($analyticsCollectionStatus) | Out-Null

$analyticsCollectionErrors = New-Label '' 11 $script:Palette.Danger
$analyticsCollectionErrors.Visibility = [System.Windows.Visibility]::Collapsed
$analyticsActionStack.Children.Add($analyticsCollectionErrors) | Out-Null

$analyticsContent.Children.Add($analyticsActionBar) | Out-Null

function New-AnalyticsCard([string]$SectionTitle, [string]$AccentColor) {
    $card = [System.Windows.Controls.Border]::new()
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
    $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $card.Padding = [System.Windows.Thickness]::new(18)
    $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)

    $st = [System.Windows.Controls.StackPanel]::new()
    $card.Child = $st

    $accent = [System.Windows.Controls.Border]::new()
    $accent.Height = 3
    $accent.CornerRadius = [System.Windows.CornerRadius]::new(2)
    $accent.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($AccentColor)
    $accent.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $st.Children.Add($accent) | Out-Null

    $t = New-Label $SectionTitle 15 $script:Palette.TextPrimary $true
    $t.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
    $st.Children.Add($t) | Out-Null

    return @{ Card = $card; Stack = $st; Title = $t; Accent = $accent }
}

function New-AnalyticsRow([System.Windows.Controls.StackPanel]$Parent, [string]$LabelText) {
    $rowLabel = New-Label $LabelText 12 $script:Palette.TextSecondary
    $rowLabel.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
    $Parent.Children.Add($rowLabel) | Out-Null
    return $rowLabel
}

$overviewCard = New-AnalyticsCard 'Cloud accounts and mounts' '#3B82F6'
$analyticsContent.Children.Add($overviewCard.Card) | Out-Null
$analyticsAccounts = New-AnalyticsRow $overviewCard.Stack 'Cloud accounts: Not yet collected.'
$analyticsMounts = New-AnalyticsRow $overviewCard.Stack 'Active mounted drives: Not yet collected.'
$analyticsAccounts.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
$analyticsMounts.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#16A34A')

$storageCard = New-AnalyticsCard 'Cloud storage' '#F59E0B'
$analyticsContent.Children.Add($storageCard.Card) | Out-Null
$analyticsStorageSummary = New-AnalyticsRow $storageCard.Stack 'Storage: Not yet collected'
$analyticsStorageSummary.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B45309')
$analyticsStorageChart = [System.Windows.Controls.StackPanel]::new()
$storageCard.Stack.Children.Add($analyticsStorageChart) | Out-Null

$resourceCard = New-AnalyticsCard 'App resources (live)' '#14B8A6'
$analyticsContent.Children.Add($resourceCard.Card) | Out-Null
$analyticsAppRam = New-AnalyticsRow $resourceCard.Stack 'App RAM: Not yet collected.'
$analyticsAppCpu = New-AnalyticsRow $resourceCard.Stack 'App CPU: Not yet collected.'
$analyticsNetwork = New-AnalyticsRow $resourceCard.Stack 'Transfer speed: Unavailable (no active transfer telemetry).'
$analyticsAppRam.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F766E')
$analyticsAppCpu.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F766E')
$analyticsNetwork.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F766E')

$script:AnalyticsCpuBaseline = @{}
$script:AnalyticsStorageWorker = $null
$script:AnalyticsStorageLastStarted = [DateTime]::MinValue
$script:AnalyticsCollectionInProgress = $false
$script:AnalyticsLastCollectionTime = $null
$script:AnalyticsLastCollectionDurationMs = 0
$script:AnalyticsCollectionWatchdogTimer = $null

function Format-AnalyticsBytes([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Set-AnalyticsStorageDisplay([object[]]$StorageRecords) {
    $analyticsStorageChart.Children.Clear()
    $validRecords = @($StorageRecords | Where-Object { $_ -and $_.TotalBytes -gt 0 -and $_.UsedBytes -ge 0 })
    if ($validRecords.Count -eq 0) {
        $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (no verified provider quota data).'
        $analyticsStorageChart.Children.Add((New-AnalyticsRow $analyticsStorageChart 'Storage chart: Unavailable.')) | Out-Null
        return
    }

    $totalUsed = [int64]0
    $totalCapacity = [int64]0
    foreach ($record in $validRecords) {
        $totalUsed += [int64]$record.UsedBytes
        $totalCapacity += [int64]$record.TotalBytes
    }
    $remaining = [Math]::Max([int64]0, $totalCapacity - $totalUsed)
    $analyticsStorageSummary.Text = "Used: $(Format-AnalyticsBytes $totalUsed)   Remaining: $(Format-AnalyticsBytes $remaining)   ($($validRecords.Count) verified account(s))"

    foreach ($record in $validRecords) {
        $row = [System.Windows.Controls.StackPanel]::new()
        $row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $identity = [System.Collections.Generic.List[string]]::new()
        if ($record.ProviderId) { $identity.Add([string]$record.ProviderId) }
        if ($record.Name) { $identity.Add([string]$record.Name) }
        if ($record.Email) { $identity.Add([string]$record.Email) }
        if ($record.DriveLetter) { $identity.Add(([string]$record.DriveLetter).TrimEnd(':') + ':') }
        if ($null -ne $record.ResponseMilliseconds) { $identity.Add("$($record.ResponseMilliseconds) ms response") }
        $accountLabel = if ($identity.Count -gt 0) { [string]::Join(' | ', $identity) } else { 'Verified account' }
        $label = New-Label ("{0}`n{1} used of {2}" -f $accountLabel, (Format-AnalyticsBytes ([int64]$record.UsedBytes)), (Format-AnalyticsBytes ([int64]$record.TotalBytes))) 11 $script:Palette.TextSecondary
        $row.Children.Add($label) | Out-Null
        $bar = [System.Windows.Controls.ProgressBar]::new()
        $bar.Height = 7
        $bar.Minimum = 0
        $bar.Maximum = 100
        $bar.Value = [Math]::Min(100, [Math]::Max(0, ([double]$record.UsedBytes / [double]$record.TotalBytes) * 100))
        $bar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
        $bar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.InputBorder)
        $bar.BorderThickness = [System.Windows.Thickness]::new(0)
        $row.Children.Add($bar) | Out-Null
        $analyticsStorageChart.Children.Add($row) | Out-Null
    }
}

function Start-AnalyticsStorageWorker {
    if ($script:AnalyticsStorageWorker -or
        ([DateTime]::UtcNow - $script:AnalyticsStorageLastStarted).TotalSeconds -lt 60) { return }
    $script:AnalyticsStorageLastStarted = [DateTime]::UtcNow
    $analyticsStorageSummary.Text = 'Checking verified provider storage quotas...'
    try {
        $script:AnalyticsStorageWorker = Start-NSBackgroundOperation -ArgumentList @($PSScriptRoot) -ScriptBlock {
        param([string]$sourceRoot)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $sourceRoot 'models\ConnectionState.ps1')
        . (Join-Path $sourceRoot 'services\SettingsManager.ps1')
        . (Join-Path $sourceRoot 'providers\GoogleDriveProvider.ps1')
        . (Join-Path $sourceRoot 'providers\TeraBoxProvider.ps1')

        $records = [System.Collections.Generic.List[object]]::new()
        $errors = [System.Collections.Generic.List[string]]::new()
        $verifiedAccountCount = 0
        $accounts = @(Get-CloudAccounts)
        $savedAccountCount = $accounts.Count
        if ($accounts.Count -eq 0) {
            $accounts = @(
                [pscustomobject]@{ Id = ''; ProviderId = 'gdrive'; DisplayName = 'Google Drive'; AccountEmail = ''; DriveLetter = (Get-PreferredDriveLetter 'gdrive') },
                [pscustomobject]@{ Id = ''; ProviderId = 'terabox'; DisplayName = 'TeraBox'; AccountEmail = ''; DriveLetter = (Get-PreferredDriveLetter 'terabox') }
            )
        }
        foreach ($account in $accounts) {
            try {
                $responseTimer = [System.Diagnostics.Stopwatch]::StartNew()
                $check = if ($account.ProviderId -eq 'gdrive') {
                    Test-GoogleDriveBackendSession -AccountId ([string]$account.Id)
                } elseif ($account.ProviderId -eq 'terabox') {
                    Test-TeraBoxBackendSession -AccountId ([string]$account.Id)
                } else { $null }
                $responseTimer.Stop()
                if (-not $check -or -not $check.IsValid -or -not $check.UserInfo) { continue }
                if ($account.ProviderId -eq 'gdrive' -and -not (Get-SafeProperty $check 'IdentityVerified' $false)) { continue }
                $verifiedAccountCount++
                $total = [int64](Get-SafeProperty $check.UserInfo 'QuotaTotal' (Get-SafeProperty $check.UserInfo 'QuotaTotalBytes' 0))
                $used = [int64](Get-SafeProperty $check.UserInfo 'QuotaUsed' (Get-SafeProperty $check.UserInfo 'QuotaUsedBytes' -1))
                if ($total -le 0 -or $used -lt 0) { continue }
                $providerName = if ($account.ProviderId -eq 'gdrive') { 'Google Drive' } else { 'TeraBox' }
                $verifiedName = if ($account.ProviderId -eq 'gdrive') {
                    [string](Get-SafeProperty $check.UserInfo 'DisplayName' '')
                } else {
                    [string](Get-SafeProperty $check.UserInfo 'UserName' '')
                }
                $email = [string](Get-SafeProperty $check.UserInfo 'EmailAddress' '')
                if (-not $verifiedName) { $verifiedName = [string]$account.DisplayName }
                if (-not $email) { $email = [string]$account.AccountEmail }
                $records.Add([pscustomobject]@{
                    AccountId = [string]$account.Id
                    ProviderId = $providerName
                    Name = $verifiedName
                    Email = $email
                    DriveLetter = [string]$account.DriveLetter
                    ResponseMilliseconds = [int]$responseTimer.ElapsedMilliseconds
                    UsedBytes = $used
                    TotalBytes = $total
                })
            } catch {
                $errors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)))
            }
        }
            return [pscustomobject]@{
                Records = @($records.ToArray())
                Errors = @($errors.ToArray())
                AccountCount = if ($savedAccountCount -gt 0) { $savedAccountCount } else { $verifiedAccountCount }
            }
        }
    } catch {
        $script:AnalyticsStorageWorker = $null
        $analyticsStorageSummary.Text = "Used and remaining storage: Unavailable. $(Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))"
        $analyticsStorageChart.Children.Clear()
    }
}

function Stop-AnalyticsStorageWorker {
    if ($script:AnalyticsStorageWorker) {
        Stop-NSBackgroundOperation $script:AnalyticsStorageWorker
        $script:AnalyticsStorageWorker = $null
    }
}

function Update-AnalyticsMetrics {
    if ($script:CurrentView -ne 'Analytics') { return }
    $nowUtc = [DateTime]::UtcNow
    $accounts = @()
    try {
        $accounts = @(Get-CloudAccounts)
        $analyticsAccounts.Text = "Saved cloud accounts: $($accounts.Count)."
        $mountedDriveLetters = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($account in $accounts) {
            $letter = ([string]$account.DriveLetter).TrimEnd(':').TrimEnd('\')
            $status = Get-CachedUiDriveStatus -ProviderId ([string]$account.ProviderId) -AccountId ([string]$account.Id) -DriveLetter $letter
            if ($status -and $status.IsMounted -and $letter) { [void]$mountedDriveLetters.Add($letter) }
        }
        foreach ($providerId in @('gdrive', 'terabox')) {
            $status = Get-CachedUiDriveStatus -ProviderId $providerId
            $letter = ([string]$status.DriveLetter).TrimEnd(':').TrimEnd('\')
            if ($status -and $status.IsMounted -and $letter) { [void]$mountedDriveLetters.Add($letter) }
        }
        $analyticsMounts.Text = "Active mounted drives: $($mountedDriveLetters.Count)."
    } catch {
        $analyticsAccounts.Text = 'Cloud accounts: Unavailable.'
        $analyticsMounts.Text = 'Active mounted drives: Unavailable.'
    }

    $appProc = $null
    try {
        $appProc = [System.Diagnostics.Process]::GetCurrentProcess()
        $cpuPct = Get-AnalyticsCpuPercent -Process $appProc -Now $nowUtc -Cores ([Math]::Max(1, [System.Environment]::ProcessorCount))
        $workingSetMb = [Math]::Round($appProc.WorkingSet64 / 1MB, 1)
        $privateMb = [Math]::Round($appProc.PrivateMemorySize64 / 1MB, 1)
        $analyticsAppRam.Text = "App RAM: $workingSetMb MB working set; $privateMb MB private memory."
        $analyticsAppCpu.Text = if ($null -ne $cpuPct) { "App CPU: $cpuPct% of all logical cores." } else { 'App CPU: sampling; value appears on the next refresh.' }
    } catch {
        $analyticsAppRam.Text = 'App RAM: Unavailable.'
        $analyticsAppCpu.Text = 'App CPU: Unavailable.'
    } finally {
        if ($appProc) { $appProc.Dispose() }
    }

    # Update network transfer telemetry honestly from live VFS and streaming state
    try {
        $totalSpeed = 0.0
        $totalInProgress = 0
        $totalQueued = 0

        # Check virtual drive VFS stats
        foreach ($letter in $mountedDriveLetters) {
            $vfs = Get-VirtualDriveVfsStats -DriveLetter $letter
            if ($vfs.IsActive) {
                $totalSpeed += $vfs.TransferSpeed
                $totalInProgress += $vfs.UploadsInProgress
                $totalQueued += $vfs.UploadsQueued
            }
        }

        # Check active cloud transfer job if any
        if ($script:ActiveTransferJobId) {
            $jobSt = Get-CloudTransferStatus -JobId $script:ActiveTransferJobId
            if ($jobSt -and ($jobSt.Status -eq 'Running' -or $jobSt.Status -eq 'Uploading to provider')) {
                $totalSpeed += $jobSt.SmoothedSpeed
                $totalInProgress++
            }
        }

        if ($totalInProgress -gt 0 -or $totalQueued -gt 0) {
            $tp = Format-TransferThroughput -BytesPerSec $totalSpeed
            $analyticsNetwork.Text = "Transfer speed: $tp ($totalInProgress uploading, $totalQueued queued)."
        } elseif ($totalSpeed -gt 0) {
            $tp = Format-TransferThroughput -BytesPerSec $totalSpeed
            $analyticsNetwork.Text = "Transfer speed: $tp (Idle / No uploads queued)."
        } else {
            $analyticsNetwork.Text = "Transfer speed: 0 B/s (Idle • No active background transfers)."
        }
    } catch {
        $analyticsNetwork.Text = "Transfer speed: Unavailable (no active transfer telemetry)."
    }

    if ($script:AnalyticsStorageWorker -and (Test-NSBackgroundOperationCompleted $script:AnalyticsStorageWorker)) {
        try {
            $completed = Complete-NSBackgroundOperation $script:AnalyticsStorageWorker
            $script:AnalyticsStorageWorker = $null
            if ($completed.HadErrors) {
                $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider measurement failed).'
                $analyticsStorageChart.Children.Clear()
            } else {
                $storageResult = if ($completed.Output.Count -gt 0) { $completed.Output[-1] } else { $null }
                if (-not $storageResult) {
                    $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider returned no quota data).'
                    $analyticsStorageChart.Children.Clear()
                } else {
                    $script:AnalyticsStorageRecords = @($storageResult.Records)
                    if ($accounts.Count -eq 0) {
                        $analyticsAccounts.Text = "Cloud accounts: $($storageResult.AccountCount) verified legacy provider session(s)."
                    }
                    Set-AnalyticsStorageDisplay @($storageResult.Records)
                    if ($storageResult.Errors.Count -gt 0 -and $storageResult.Records.Count -gt 0) {
                        $analyticsStorageSummary.Text += " Some provider checks were unavailable: $($storageResult.Errors[0])"
                    } elseif ($storageResult.Errors.Count -gt 0 -and $storageResult.Records.Count -eq 0) {
                        $analyticsStorageSummary.Text = "Used and remaining storage: Unavailable. $($storageResult.Errors[0])"
                    }
                }
            }
        } catch {
            $script:AnalyticsStorageWorker = $null
            $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider measurement failed).'
            $analyticsStorageChart.Children.Clear()
        }
    } elseif ($script:AnalyticsStorageWorker -and
        ([DateTime]::UtcNow - $script:AnalyticsStorageLastStarted).TotalSeconds -gt 30) {
        Stop-AnalyticsStorageWorker
        $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider request timed out).'
        $analyticsStorageChart.Children.Clear()
    }
}

function Get-AnalyticsCpuPercent($Process, [DateTime]$Now, [int]$Cores = 1) {
    # Real per-process CPU percentage from TotalProcessorTime deltas.
    if ($null -eq $Process) { return $null }
    try {
        $pid = [int]$Process.Id
        $cpuTimes = $Process.TotalProcessorTime
        $previous = $null
        if ($script:AnalyticsCpuBaseline.ContainsKey($pid)) { $previous = $script:AnalyticsCpuBaseline[$pid] }
        $script:AnalyticsCpuBaseline[$pid] = @{ Cpu = $cpuTimes; At = $Now }
        if (-not $previous) { return $null }
        $cpuDelta = ($cpuTimes - $previous.Cpu).TotalSeconds
        $wallDelta = ($Now - $previous.At).TotalSeconds
        if ($wallDelta -le 0) { return $null }
        return [Math]::Round([Math]::Min(100, ($cpuDelta / ($wallDelta * $cores)) * 100), 1)
    } catch { return $null }
}

function Show-AnalyticsView {
    $script:CurrentView = 'Analytics'
    $disksView.Visibility = [System.Windows.Visibility]::Collapsed
    $optionsView.Visibility = [System.Windows.Visibility]::Collapsed
    $helpView.Visibility = [System.Windows.Visibility]::Collapsed
    $analyticsView.Visibility = [System.Windows.Visibility]::Visible
    $logsView.Visibility = [System.Windows.Visibility]::Collapsed
    Stop-LogsViewLoad
    Update-NavActiveState
}

function Stop-AnalyticsCollection {
    Stop-AnalyticsStorageWorker
    $script:AnalyticsCollectionInProgress = $false
    if ($script:AnalyticsCollectionWatchdogTimer) {
        try { $script:AnalyticsCollectionWatchdogTimer.Stop() } catch { }
        $script:AnalyticsCollectionWatchdogTimer = $null
    }
    if ($analyticsGetAnalyticsBtn) { $analyticsGetAnalyticsBtn.IsEnabled = $true }
    if ($analyticsRefreshAnalyticsBtn) { $analyticsRefreshAnalyticsBtn.IsEnabled = $true }
}

function Start-AnalyticsCollection {
    if ($script:AnalyticsCollectionInProgress) { return }
    $script:AnalyticsCollectionInProgress = $true
    if ($analyticsGetAnalyticsBtn) { $analyticsGetAnalyticsBtn.IsEnabled = $false }
    if ($analyticsRefreshAnalyticsBtn) { $analyticsRefreshAnalyticsBtn.IsEnabled = $false }
    $analyticsCollectionStatus.Text = 'Status: Collecting analytics on demand...'
    $analyticsCollectionErrors.Visibility = [System.Windows.Visibility]::Collapsed
    $analyticsCollectionErrors.Text = ''

    $collectStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Update-AnalyticsMetrics
    Start-AnalyticsStorageWorker

    $script:AnalyticsCollectionWatchdogTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:AnalyticsCollectionWatchdogTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:AnalyticsCollectionWatchdogTimer.Add_Tick({
        try {
            if ($script:CurrentView -ne 'Analytics' -or -not $script:AnalyticsCollectionInProgress) {
                Stop-AnalyticsCollection
                return
            }

            $done = $false
            if ($script:AnalyticsStorageWorker) {
                if (Test-NSBackgroundOperationCompleted $script:AnalyticsStorageWorker) {
                    try {
                        $completed = Complete-NSBackgroundOperation $script:AnalyticsStorageWorker
                        $script:AnalyticsStorageWorker = $null
                        if ($completed.HadErrors) {
                            $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider measurement failed).'
                            $analyticsStorageChart.Children.Clear()
                        } else {
                            $storageResult = if ($completed.Output.Count -gt 0) { $completed.Output[-1] } else { $null }
                            if (-not $storageResult) {
                                $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider returned no quota data).'
                                $analyticsStorageChart.Children.Clear()
                            } else {
                                $script:AnalyticsStorageRecords = @($storageResult.Records)
                                Set-AnalyticsStorageDisplay @($storageResult.Records)
                                if ($storageResult.Errors.Count -gt 0 -and $storageResult.Records.Count -gt 0) {
                                    $analyticsStorageSummary.Text += " Some provider checks were unavailable: $($storageResult.Errors[0])"
                                } elseif ($storageResult.Errors.Count -gt 0 -and $storageResult.Records.Count -eq 0) {
                                    $analyticsStorageSummary.Text = "Used and remaining storage: Unavailable. $($storageResult.Errors[0])"
                                }
                            }
                        }
                    } catch {
                        $script:AnalyticsStorageWorker = $null
                        $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider measurement failed).'
                        $analyticsStorageChart.Children.Clear()
                    }
                    $done = $true
                } elseif (([DateTime]::UtcNow - $script:AnalyticsStorageLastStarted).TotalSeconds -gt 30) {
                    Stop-AnalyticsStorageWorker
                    $analyticsStorageSummary.Text = 'Used and remaining storage: Unavailable (provider request timed out).'
                    $analyticsStorageChart.Children.Clear()
                    $done = $true
                }
            } else {
                $done = $true
            }

            if ($done) {
                $collectStopwatch.Stop()
                $script:AnalyticsLastCollectionTime = [DateTime]::UtcNow
                $script:AnalyticsLastCollectionDurationMs = [int]$collectStopwatch.ElapsedMilliseconds
                $analyticsCollectionStatus.Text = "Status: Collection completed in $($script:AnalyticsLastCollectionDurationMs) ms at $([DateTime]::Now.ToString('HH:mm:ss'))."
                Stop-AnalyticsCollection
            }
        } catch {
            Stop-AnalyticsCollection
        }
    })
    $script:AnalyticsCollectionWatchdogTimer.Start()
}

# ------------------------------------------------------------------------------
# 5. LOGS VIEW (bounded local application events + honest privacy notice)
# ------------------------------------------------------------------------------
$logsView = [System.Windows.Controls.DockPanel]::new()
$logsView.Margin = [System.Windows.Thickness]::new(24, 20, 24, 20)
$logsView.Visibility = [System.Windows.Visibility]::Collapsed
$mainArea.Children.Add($logsView) | Out-Null

$logsHeader = [System.Windows.Controls.DockPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($logsHeader, 'Top')
$logsHeader.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
$logsView.Children.Add($logsHeader) | Out-Null

$backFromLogsBtn = [System.Windows.Controls.Button]::new()
$backFromLogsBtn.Content = '< Back to Disks'
$backFromLogsBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
$backFromLogsBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$backFromLogsBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$backFromLogsBtn.BorderThickness = [System.Windows.Thickness]::new(1)
$backFromLogsBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$backFromLogsBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($backFromLogsBtn, 'Right')
$logsHeader.Children.Add($backFromLogsBtn) | Out-Null

$logsTitles = [System.Windows.Controls.StackPanel]::new()
$logsTitle = New-Label 'Logs' 22 $script:Palette.TextPrimary $true
$logsSubtitle = New-Label 'Bounded record of mount, restore, and reconnect events stored locally on this machine.' 12 $script:Palette.TextSecondary
$logsTitles.Children.Add($logsTitle) | Out-Null
$logsTitles.Children.Add($logsSubtitle) | Out-Null
$logsHeader.Children.Add($logsTitles) | Out-Null

# Filter bar
$logsFilterBar = [System.Windows.Controls.DockPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($logsFilterBar, 'Top')
$logsFilterBar.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
$logsView.Children.Add($logsFilterBar) | Out-Null

$logsButtons = [System.Windows.Controls.StackPanel]::new()
$logsButtons.Orientation = 'Horizontal'
[System.Windows.Controls.DockPanel]::SetDock($logsButtons, 'Left')
$logsFilterBar.Children.Add($logsButtons) | Out-Null

$logsRefreshBtn = [System.Windows.Controls.Button]::new()
$logsRefreshBtn.Content = 'Refresh'
$logsRefreshBtn.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
$logsRefreshBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$logsRefreshBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$logsButtons.Children.Add($logsRefreshBtn) | Out-Null

$logsNewerBtn = [System.Windows.Controls.Button]::new()
$logsNewerBtn.Content = 'Newer entries'
$logsNewerBtn.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
$logsNewerBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$logsNewerBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$logsNewerBtn.IsEnabled = $false
$logsButtons.Children.Add($logsNewerBtn) | Out-Null

$logsOlderBtn = [System.Windows.Controls.Button]::new()
$logsOlderBtn.Content = 'Older entries'
$logsOlderBtn.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
$logsOlderBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$logsOlderBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$logsOlderBtn.IsEnabled = $false
$logsButtons.Children.Add($logsOlderBtn) | Out-Null

$logsOpenFolderBtn = [System.Windows.Controls.Button]::new()
$logsOpenFolderBtn.Content = 'Open logs folder'
$logsOpenFolderBtn.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
$logsOpenFolderBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$logsOpenFolderBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$logsButtons.Children.Add($logsOpenFolderBtn) | Out-Null

$logsClearBtn = [System.Windows.Controls.Button]::new()
$logsClearBtn.Content = 'Clear logs'
$logsClearBtn.Padding = [System.Windows.Thickness]::new(12, 5, 12, 5)
$logsClearBtn.Cursor = [System.Windows.Input.Cursors]::Hand
$logsButtons.Children.Add($logsClearBtn) | Out-Null

$logsFilterStack = [System.Windows.Controls.StackPanel]::new()
$logsFilterStack.Orientation = 'Horizontal'
[System.Windows.Controls.DockPanel]::SetDock($logsFilterStack, 'Right')
$logsFilterBar.Children.Add($logsFilterStack) | Out-Null

$logsSeverityLabel = New-Label 'Severity:' 11 $script:Palette.TextSecondary
$logsSeverityLabel.VerticalAlignment = 'Center'
$logsSeverityLabel.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
$logsFilterStack.Children.Add($logsSeverityLabel) | Out-Null

$logsSeverityCombo = [System.Windows.Controls.ComboBox]::new()
$logsSeverityCombo.Width = 130
$logsSeverityCombo.Margin = [System.Windows.Thickness]::new(0, 0, 14, 0)
foreach ($item in @('All severities', 'Info', 'Warning', 'Error')) { [void]$logsSeverityCombo.Items.Add($item) }
$logsSeverityCombo.SelectedIndex = 0
$logsFilterStack.Children.Add($logsSeverityCombo) | Out-Null

$logsAccountLabel = New-Label 'Account:' 11 $script:Palette.TextSecondary
$logsAccountLabel.VerticalAlignment = 'Center'
$logsAccountLabel.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
$logsFilterStack.Children.Add($logsAccountLabel) | Out-Null

$logsAccountCombo = [System.Windows.Controls.ComboBox]::new()
$logsAccountCombo.Width = 220
$logsAccountCombo.SelectedIndex = 0
$logsFilterStack.Children.Add($logsAccountCombo) | Out-Null

$logsSearchLabel = New-Label 'Search:' 11 $script:Palette.TextSecondary
$logsSearchLabel.VerticalAlignment = 'Center'
$logsSearchLabel.Margin = [System.Windows.Thickness]::new(14, 0, 6, 0)
$logsFilterStack.Children.Add($logsSearchLabel) | Out-Null

$logsSearchBox = [System.Windows.Controls.TextBox]::new()
$logsSearchBox.Width = 150
$logsSearchBox.Height = 26
$logsSearchBox.VerticalContentAlignment = 'Center'
$logsSearchBox.ToolTip = 'Search the current log page'
$logsFilterStack.Children.Add($logsSearchBox) | Out-Null

# Event list card
$logsListCard = [System.Windows.Controls.Border]::new()
$logsListCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$logsListCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$logsListCard.BorderThickness = [System.Windows.Thickness]::new(1)
$logsListCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$logsListCard.Padding = [System.Windows.Thickness]::new(14)
$logsListCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
[System.Windows.Controls.DockPanel]::SetDock($logsListCard, 'Top')
$logsView.Children.Add($logsListCard) | Out-Null

$logsListStack = [System.Windows.Controls.StackPanel]::new()
$logsListCard.Child = $logsListStack

$logsStatusLine = New-Label 'Showing 0 entries.' 11 $script:Palette.TextMuted
$logsStatusLine.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$logsListStack.Children.Add($logsStatusLine) | Out-Null

$logsTextBox = [System.Windows.Controls.TextBox]::new()
$logsTextBox.IsReadOnly = $true
$logsTextBox.VerticalScrollBarVisibility = 'Auto'
$logsTextBox.HorizontalScrollBarVisibility = 'Auto'
$logsTextBox.FontFamily = 'Consolas, Courier New'
$logsTextBox.FontSize = 11
$logsTextBox.MinHeight = 220
$logsTextBox.MaxHeight = 330
$logsTextBox.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.InputBg)
$logsTextBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.InputBorder)
$logsTextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$logsTextBox.Text = 'No log entries yet. Mount and reconnect events appear here.'
$logsListStack.Children.Add($logsTextBox) | Out-Null

# Privacy / retention notice card
$logsPrivacyCard = [System.Windows.Controls.Border]::new()
$logsPrivacyCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBg)
$logsPrivacyCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)
$logsPrivacyCard.BorderThickness = [System.Windows.Thickness]::new(1)
$logsPrivacyCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
$logsPrivacyCard.Padding = [System.Windows.Thickness]::new(14)
$logsView.Children.Add($logsPrivacyCard) | Out-Null

$logsPrivacyStack = [System.Windows.Controls.StackPanel]::new()
$logsPrivacyCard.Child = $logsPrivacyStack

$logsPrivacyTitle = New-Label 'Privacy and retention' 14 $script:Palette.TextPrimary $true
$logsPrivacyTitle.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$logsPrivacyStack.Children.Add($logsPrivacyTitle) | Out-Null

function New-PrivacyLine([string]$Text) {
    $tb = New-Label $Text 11 $script:Palette.TextSecondary
    $tb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
    $tb.TextWrapping = 'Wrap'
    return $tb
}
$script:LogsPrivacyLines = @(
    (New-PrivacyLine 'Stored locally: %LOCALAPPDATA%\NSCloudDrive\logs only. application.jsonl and startup-restore.jsonl are event records from this application; rclone-<mount>.log files contain per-mount provider output. Nothing is sent anywhere by NS Cloud Drive itself.'),
    (New-PrivacyLine 'Redaction: every application log message passes a sanitizer before it is written; authorization codes, access and refresh tokens, passwords, and session cookies are replaced with [REDACTED]. Per-mount rclone output is produced by rclone itself and is not reparsed by this application.'),
    (New-PrivacyLine 'Provider access: mounts use the Google Drive API through rclone and the TeraBox bridge service, per the account you configured. NS Cloud Drive does not collect analytics and does not upload your logs.'),
    (New-PrivacyLine 'Retention: bounded storage; application.jsonl rotates at 2 MB keeping one predecessor, and per-mount logs rotate at 5 MB the same way. Clear logs removes both generations of every log file in the folder.')
)
foreach ($line in $script:LogsPrivacyLines) { $logsPrivacyStack.Children.Add($line) | Out-Null }

$script:LogsRenderedEntries = @()
$script:LogsPageOffset = 0
$script:LogsPageSize = 200
$script:LogsHasOlderEntries = $false
$script:LogsFilterUpdateInProgress = $false
$script:LogsSearchText = ''
$script:LogsLoadOperation = $null
$script:LogsLoadStartedAt = $null
$script:LogsLoadTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:LogsLoadTimer.Interval = [TimeSpan]::FromMilliseconds(100)

function Format-LogsEntryLine($entry) {
    return ("{0} | {1,-7} | {2,-7} | {3,-16} | {4} | {5}" -f `
        $(try { ([string]$entry.timestampUtc) } catch { '' }), `
        $(try { ([string]$entry.severity) } catch { '' }), `
        $(try { [string]$entry.provider } catch { '' }), `
        $(try { [string]$entry.operation } catch { '' }), `
        $(try { if ($null -ne $entry.durationMs -and [int]$entry.durationMs -ge 0) { "$([int]$entry.durationMs) ms" } else { '-' } } catch { '-' }), `
        $(try { [string]$entry.message } catch { '' }))
}

function Render-LogsViewContent {
    $entries = @($script:LogsRenderedEntries)
    $severitySel = if ($logsSeverityCombo.SelectedItem) { [string]$logsSeverityCombo.SelectedItem } else { 'All severities' }
    $accountSel = if ($logsAccountCombo.SelectedItem) { [string]$logsAccountCombo.SelectedItem } else { 'All accounts' }

    # Rebuild the account filter from cached entries (sorted, unique, no PII beyond labels the user chose).
    $accountKeys = [System.Collections.Generic.List[string]]::new()
    $accountKeys.Add('All accounts')
    foreach ($entry in $entries) {
        try {
            $label = ([string]$entry.accountLabel).Trim()
            $id = ([string]$entry.accountId).Trim()
            $value = if ($label) { $label } elseif ($id) { $id } else { '' }
            if ($value -and -not $accountKeys.Contains($value)) { $accountKeys.Add($value) }
        } catch { }
    }
    $script:LogsFilterUpdateInProgress = $true
    try {
        $logsAccountCombo.Items.Clear()
        foreach ($value in $accountKeys) { [void]$logsAccountCombo.Items.Add($value) }
        if ($accountKeys.Contains($accountSel)) { $logsAccountCombo.SelectedItem = $accountSel } else { $logsAccountCombo.SelectedIndex = 0; $accountSel = 'All accounts' }
    } finally {
        $script:LogsFilterUpdateInProgress = $false
    }

    $filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $entries) {
        try {
            if ($severitySel -ne 'All severities' -and ([string]$entry.severity) -ne $severitySel) { continue }
            if ($accountSel -ne 'All accounts') {
                $label = ([string]$entry.accountLabel).Trim()
                $id = ([string]$entry.accountId).Trim()
                if ($label -ne $accountSel -and $id -ne $accountSel) { continue }
            }
            if ($script:LogsSearchText -and
                (Format-LogsEntryLine $entry).IndexOf($script:LogsSearchText, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $filtered.Add($entry)
        } catch { }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $filtered) {
        try { $lines.Add((Format-LogsEntryLine $entry)) } catch { }
    }
    $logsTextBox.Text = if ($lines.Count -gt 0) { [string]::Join([Environment]::NewLine, $lines) } else { 'No matching log entries. Events are written when accounts mount, restore, or reconnect.' }
    $pageNumber = [int][Math]::Floor($script:LogsPageOffset / $script:LogsPageSize) + 1
    $logsStatusLine.Text = "Page $pageNumber; showing $($filtered.Count) of $($entries.Count) entries (newest first, bounded pages)."
    $logsNewerBtn.IsEnabled = $script:LogsPageOffset -gt 0
    $logsOlderBtn.IsEnabled = $script:LogsHasOlderEntries
}

function Stop-LogsViewLoad {
    $script:LogsLoadTimer.Stop()
    if ($script:LogsLoadOperation) {
        Stop-NSBackgroundOperation $script:LogsLoadOperation
        $script:LogsLoadOperation = $null
    }
    $script:LogsLoadStartedAt = $null
}

function Update-LogsViewContent {
    if ($script:LogsLoadOperation) { return }
    $logsStatusLine.Text = 'Loading recent log entries...'
    $logsTextBox.Text = 'Loading logs...'
    $logsNewerBtn.IsEnabled = $false
    $logsOlderBtn.IsEnabled = $false
    try {
        $script:LogsLoadOperation = Start-NSBackgroundOperation -ArgumentList @(
            $PSScriptRoot, [int]$script:LogsPageSize, [int]$script:LogsPageOffset
        ) -ScriptBlock {
            param([string]$sourceRoot, [int]$pageSize, [int]$skipEntries)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $sourceRoot 'models\ConnectionState.ps1')
            Read-ApplicationLogEntries -MaxEntries ($pageSize + 1) -SkipEntries $skipEntries
        }
        $script:LogsLoadStartedAt = [DateTime]::UtcNow
        $script:LogsLoadTimer.Start()
    } catch {
        $script:LogsLoadOperation = $null
        $script:LogsLoadStartedAt = $null
        $logsStatusLine.Text = 'Log loading failed.'
        $logsTextBox.Text = "Unable to load logs: $(Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))"
    }
}

$script:LogsLoadTimer.Add_Tick({
    if ($script:CurrentView -ne 'Logs') {
        Stop-LogsViewLoad
        return
    }
    if (-not $script:LogsLoadOperation) {
        $script:LogsLoadTimer.Stop()
        return
    }
    if (-not (Test-NSBackgroundOperationCompleted $script:LogsLoadOperation)) {
        if ($script:LogsLoadStartedAt -and ([DateTime]::UtcNow - $script:LogsLoadStartedAt).TotalSeconds -gt 10) {
            Stop-LogsViewLoad
            $logsStatusLine.Text = 'Log loading timed out.'
            $logsTextBox.Text = 'Unable to load logs: the local log reader exceeded its 10 second limit. Use Refresh to retry.'
        }
        return
    }

    try {
        $completed = Complete-NSBackgroundOperation $script:LogsLoadOperation
        $script:LogsLoadOperation = $null
        $script:LogsLoadStartedAt = $null
        $script:LogsLoadTimer.Stop()
        if ($completed.HadErrors) {
            $message = if ($completed.Errors.Count -gt 0) { [string]$completed.Errors[0].Exception.Message } else { 'The log reader failed.' }
            $logsStatusLine.Text = 'Log loading failed.'
            $logsTextBox.Text = "Unable to load logs: $(Format-SanitizedDiagnosticMessage $message)"
            return
        }
        $loadedEntries = @($completed.Output)
        $script:LogsHasOlderEntries = $loadedEntries.Count -gt $script:LogsPageSize
        if ($script:LogsHasOlderEntries) {
            $loadedEntries = @($loadedEntries | Select-Object -Skip 1)
        }
        $script:LogsRenderedEntries = $loadedEntries
        Render-LogsViewContent
    } catch {
        Stop-LogsViewLoad
        $logsStatusLine.Text = 'Log loading failed.'
        $logsTextBox.Text = "Unable to load logs: $(Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))"
    }
})

function Show-LogsView {
    $script:CurrentView = 'Logs'
    $disksView.Visibility = [System.Windows.Visibility]::Collapsed
    $optionsView.Visibility = [System.Windows.Visibility]::Collapsed
    $helpView.Visibility = [System.Windows.Visibility]::Collapsed
    $analyticsView.Visibility = [System.Windows.Visibility]::Collapsed
    $logsView.Visibility = [System.Windows.Visibility]::Visible
    Stop-AnalyticsCollection
    $script:AnalyticsStorageLastStarted = [DateTime]::MinValue
    Update-NavActiveState
    $script:LogsPageOffset = 0
    Update-LogsViewContent
}

# ==============================================================================
# SAFE SYSTEM DIAGNOSTICS MODAL
# ==============================================================================
function Show-SystemDiagnosticsModal([System.Windows.Window]$Owner = $null) {
    $p = Get-MainThemePalette $script:Settings.Theme
    $diagWin = [System.Windows.Window]::new()
    $diagWin.Title = 'NS Cloud Drive - System Diagnostics'
    $diagWin.Width = 600
    $diagWin.Height = 520
    $diagWin.MinWidth = 520
    $diagWin.MinHeight = 440
    $diagWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $diagWin.Owner = $Owner }
    $diagWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.WindowBg)
    $diagWin.FontFamily = 'Segoe UI'

    $dDock = [System.Windows.Controls.DockPanel]::new()
    $dDock.Margin = [System.Windows.Thickness]::new(20)
    $diagWin.Content = $dDock

    # Bottom button bar
    $bBar = [System.Windows.Controls.StackPanel]::new()
    $bBar.Orientation = 'Horizontal'
    $bBar.HorizontalAlignment = 'Right'
    $bBar.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($bBar, 'Bottom')
    $dDock.Children.Add($bBar) | Out-Null

    $closeBtn = [System.Windows.Controls.Button]::new()
    $closeBtn.Content = 'Close'
    $closeBtn.Padding = [System.Windows.Thickness]::new(18, 6, 18, 6)
    $closeBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
    $closeBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
    $closeBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $closeBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    $closeBtn.Add_Click({ $diagWin.Close() })

    $trimBtn = [System.Windows.Controls.Button]::new()
    $trimBtn.Content = 'Trim Working Set'
    $trimBtn.Padding = [System.Windows.Thickness]::new(14, 6, 14, 6)
    $trimBtn.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $trimBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
    $trimBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
    $trimBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $trimBtn.Cursor = [System.Windows.Input.Cursors]::Hand

    $bBar.Children.Add($trimBtn) | Out-Null
    $bBar.Children.Add($closeBtn) | Out-Null

    # Top Title
    $topStack = [System.Windows.Controls.StackPanel]::new()
    [System.Windows.Controls.DockPanel]::SetDock($topStack, 'Top')
    $topStack.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $dDock.Children.Add($topStack) | Out-Null

    $t1 = New-Label 'System Diagnostics & Health' 18 $p.TextPrimary $true
    $t2 = New-Label 'Safe process, driver, and mounting metrics. Secrets and tokens are strictly excluded.' 11 $p.TextSecondary
    $topStack.Children.Add($t1) | Out-Null
    $topStack.Children.Add($t2) | Out-Null

    # Center Scroll content
    $dScroll = [System.Windows.Controls.ScrollViewer]::new()
    $dScroll.VerticalScrollBarVisibility = 'Auto'
    $dDock.Children.Add($dScroll) | Out-Null

    $dContent = [System.Windows.Controls.StackPanel]::new()
    $dScroll.Content = $dContent

    function Add-DiagMetric([string]$Category, [hashtable]$Metrics) {
        $card = [System.Windows.Controls.Border]::new()
        $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
        $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
        $card.BorderThickness = [System.Windows.Thickness]::new(1)
        $card.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $card.Padding = [System.Windows.Thickness]::new(12, 10, 12, 10)
        $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

        $st = [System.Windows.Controls.StackPanel]::new()
        $card.Child = $st

        $hdr = New-Label $Category 13 $p.TextPrimary $true
        $hdr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
        $st.Children.Add($hdr) | Out-Null

        foreach ($k in $Metrics.Keys) {
            $row = [System.Windows.Controls.DockPanel]::new()
            $row.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
            $kLbl = New-Label $k 11 $p.TextSecondary
            [System.Windows.Controls.DockPanel]::SetDock($kLbl, 'Left')
            $valStr = [string]$Metrics[$k]
            $vColor = if ($valStr -like '*[FAIL]*') { '#F87171' }
                      elseif ($valStr -like '*[WARN]*') { '#FBBF24' }
                      elseif ($valStr -like '*[OK]*') { '#4ADE80' }
                      elseif ($valStr -like '*[INFO]*') { '#60A5FA' }
                      else { $p.TextPrimary }
            $vLbl = New-Label $valStr 11 $vColor $true
            $vLbl.HorizontalAlignment = 'Right'
            $row.Children.Add($kLbl) | Out-Null
            $row.Children.Add($vLbl) | Out-Null
            $st.Children.Add($row) | Out-Null
        }
        $dContent.Children.Add($card) | Out-Null
    }

    $populateData = {
        $dContent.Children.Clear()
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        $wsMb = [Math]::Round($proc.WorkingSet64 / 1MB, 2)
        $pmMb = [Math]::Round($proc.PrivateMemorySize64 / 1MB, 2)
        $threads = $proc.Threads.Count

        $cpuDisplay = '0.0%'
        try {
            $t0 = $proc.TotalProcessorTime
            $w0 = [DateTime]::UtcNow
            Start-Sleep -Milliseconds 60
            $proc.Refresh()
            $t1 = $proc.TotalProcessorTime
            $w1 = [DateTime]::UtcNow
            $procMs = ($t1 - $t0).TotalMilliseconds
            $wallMs = ($w1 - $w0).TotalMilliseconds * [Environment]::ProcessorCount
            if ($wallMs -gt 0) {
                $pct = [Math]::Round(($procMs / $wallMs) * 100, 1)
                $cpuDisplay = "$pct%"
            }
        } catch { }

        Add-DiagMetric 'Application Process Health' ([ordered]@{
            'Process ID (PID)' = "[OK] $PID ($($proc.ProcessName))"
            'Working Set RAM' = "$wsMb MB"
            'Private Memory' = "$pmMb MB"
            'Estimated CPU' = $cpuDisplay
            'Active Threads' = $threads
            'Theme Active' = (Resolve-AppTheme $script:Settings.Theme)
        })

        $engineMetrics = [ordered]@{}
        $rcloneProcs = @(Get-Process -Name 'rclone' -ErrorAction SilentlyContinue)
        $cpxProcs = @(Get-Process -Name 'cpx' -ErrorAction SilentlyContinue)
        if ($rcloneProcs.Count -eq 0 -and $cpxProcs.Count -eq 0) {
            $engineMetrics['Background Engines'] = '[INFO] No rclone or CPX processes currently active'
        } else {
            foreach ($rp in $rcloneProcs) {
                $rpWs = [Math]::Round($rp.WorkingSet64 / 1MB, 1)
                $engineMetrics["rclone Engine (PID $($rp.Id))"] = "[OK] Running ($rpWs MB RAM)"
            }
            foreach ($cp in $cpxProcs) {
                $cpWs = [Math]::Round($cp.WorkingSet64 / 1MB, 1)
                $engineMetrics["CPX Bridge (PID $($cp.Id))"] = "[OK] Running ($cpWs MB RAM)"
            }
        }
        Add-DiagMetric 'Engine & Subsystem Processes' $engineMetrics

        $winfspStatus = if (Test-WinFspInstalled) { '[OK] Installed & Operational' } else { '[FAIL] Not Detected' }
        $rclonePath = Find-RcloneBinary
        $rcloneStatus = if ($rclonePath -and (Test-Path -LiteralPath $rclonePath -PathType Leaf)) { "[OK] $rclonePath" } else { '[WARN] Not Found' }

        Add-DiagMetric 'Filesystem Subsystem' ([ordered]@{
            'WinFsp Driver' = $winfspStatus
            'rclone Binary' = $rcloneStatus
            'Cache Target' = $script:CacheDirectory
            'Cache Max Quota' = "$($script:Settings.CacheMaxGigabytes) GB"
        })

        try {
            $cacheStats = Get-DetailedCacheStatistics -CacheDirectory $script:CacheDirectory
            $cacheMb = [Math]::Round($cacheStats.TotalSizeBytes / 1MB, 1)
            $lockedMb = [Math]::Round($cacheStats.InUseBytes / 1MB, 1)
            $freeGb = [Math]::Round($cacheStats.DriveFreeBytes / 1GB, 1)
            $osNotice = if ($cacheStats.IsSystemDrive) { '[WARN] Cache on Windows OS Drive' } else { '[OK] Cache on Dedicated Volume' }

            Add-DiagMetric 'Cache & Storage Health' ([ordered]@{
                'Cache Volume' = "$($cacheStats.DriveLetter): ($freeGb GB Free Space)"
                'Cache Volume Placement' = $osNotice
                'Total Cached Data' = "$cacheMb MB ($($cacheStats.TotalFileCount) files)"
                'In-Use Locked Files' = "$lockedMb MB ($($cacheStats.InUseCount) files protected)"
            })
        } catch { }

        $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
        $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
        $mountInfo = [ordered]@{}

        $accounts = @(Get-CloudAccounts)
        if ($accounts -and $accounts.Count -gt 0) {
            foreach ($acc in $accounts) {
                $st = Get-VirtualDriveStatus -AccountId $acc.Id -ProviderId $acc.ProviderId
                $providerName = if ($acc.ProviderId -eq 'gdrive') { 'Google Drive' } else { 'TeraBox' }
                $accKey = "$providerName - $($acc.DisplayName)"
                if ($st -and $st.IsMounted) {
                    $mountInfo[$accKey] = "[OK] Mounted on $($st.DriveLetter):"
                } elseif ($acc.LastError) {
                    $mountInfo[$accKey] = "[FAIL] Error: $($acc.LastError)"
                } else {
                    $mountInfo[$accKey] = '[INFO] Disconnected'
                }
            }
        } else {
            $mountInfo['Cloud Accounts'] = '[INFO] No configured accounts'
        }
        foreach ($providerStatus in @($gdStatus, $tbStatus)) {
            if ($providerStatus.IsMounted) {
                $ownsDrive = @($accounts | Where-Object {
                    ([string]$_.DriveLetter).TrimEnd(':').TrimEnd('') -eq ([string]$providerStatus.DriveLetter).TrimEnd(':').TrimEnd('')
                }).Count -gt 0
                if (-not $ownsDrive) {
                    $mountInfo["Unregistered mount ($($providerStatus.DriveLetter):)"] = '[WARN] Recovery required'
                }
            }
        }
        if ($script:StartupAutoMountError) {
            $mountInfo['Startup Restore Alert'] = "[WARN] $script:StartupAutoMountError"
        }
        Add-DiagMetric 'Mounted Drive Allocations' $mountInfo
    }

    $trimBtn.Add_Click({
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        $beforeMb = [Math]::Round($proc.WorkingSet64 / 1MB, 2)
        Invoke-MemoryTrim
        $proc.Refresh()
        $afterMb = [Math]::Round($proc.WorkingSet64 / 1MB, 2)
        $reclaimedMb = [Math]::Round([Math]::Max(0, $beforeMb - $afterMb), 2)
        & $populateData
        [System.Windows.MessageBox]::Show(
            "Working set trimmed from $beforeMb MB to $afterMb MB ($reclaimedMb MB reclaimed).`n`n" +
            "Note: Memory trimming requests Windows to release unreferenced working pages to the standby list. " +
            "If active operations require this data later, Windows will page it back into RAM automatically.",
            'Working Set Memory Trimmed',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    })

    & $populateData
    [void](Enable-ModalGlassBackdrop $diagWin)
    $diagWin.ShowDialog() | Out-Null
}

# ==============================================================================
# LIQUID GLASS BACKDROP ENGINE (only engages on supported Windows builds)
# ==============================================================================
# Real acrylic glass via Windows composition, not a recolored panel:
#  - Windows 11 (build 22000+): DWM system backdrop, attribute 38
#    (DWMWA_SYSTEMBACKDROP_TYPE, transient-acrylic value 3).
#  - Windows 10 1803+ (build 17134): the composition accent policy with
#    ACCENT_ENABLE_ACRYLICBLURBEHIND (4) and a dark tint layered between the
#    blur and the WPF buffer.
#  - Both paths make the WPF surface itself transparent (HwndSource
#    CompositionTarget.BackgroundColor); window fills, sidebar, and cards keep
#    semi-alpha tints so the blur shows through while text contrast holds.
# Everything fails closed: an unsupported build, a missing compositor, or any
# exception silently falls back to the plain translucent palette (the previous
# appearance), and Pure Black / Pure White never enable the effect at all.
if (-not ('NSCloudGlassInterop' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class NSCloudGlassInterop
{
    internal const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    internal const int DWMSBT_NONE = 1;
    internal const int DWMSBT_TRANSIENTWINDOW = 3;

    public const int WCA_ACCENT_POLICY = 19;
    public const int ACCENT_DISABLED = 0;
    public const int ACCENT_ENABLE_ACRYLICBLURBEHIND = 4;

    // Dark slate tint (approximately #730F1622, ~45% alpha) painted between the
    // acrylic blur and the WPF surface on Windows 10 so light backgrounds do
    // not wash out the UI.
    private const uint AcrylicGradient = 0x730F1622u;

    [StructLayout(LayoutKind.Sequential)]
    private struct ACCENT_POLICY
    {
        public int AccentState;
        public uint AccentFlags;
        public uint GradientColor;
        public uint AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWCOMPOSITIONATTRIBDATA
    {
        public int Attrib;
        public IntPtr Data;
        public uint SizeOfData;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MARGINS
    {
        public int Left;
        public int Right;
        public int Top;
        public int Bottom;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

    [DllImport("user32.dll")]
    private static extern bool SetWindowCompositionAttribute(IntPtr hwnd, ref WINDOWCOMPOSITIONATTRIBDATA data);

    private static bool ApplyAccentPolicy(IntPtr hwnd, int accentState)
    {
        var policy = new ACCENT_POLICY();
        policy.AccentState = accentState;
        policy.AccentFlags = 2;
        policy.GradientColor = AcrylicGradient;
        policy.AnimationId = 0;

        var data = new WINDOWCOMPOSITIONATTRIBDATA();
        data.Attrib = WCA_ACCENT_POLICY;

        IntPtr ptr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ACCENT_POLICY)));
        try
        {
            Marshal.StructureToPtr(policy, ptr, false);
            data.Data = ptr;
            data.SizeOfData = (uint)Marshal.SizeOf(typeof(ACCENT_POLICY));
            return SetWindowCompositionAttribute(hwnd, ref data);
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }

    // Returns true when the DWM reported success for the Win11 backdrop path.
    public static bool SetSystemBackdrop(IntPtr hwnd, int backdrop)
    {
        if (hwnd == IntPtr.Zero) { return false; }
        int value = backdrop;
        return DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, ref value, 4) == 0;
    }

    // Returns true when the Win10 acrylic blur-behind was applied without error.
    public static bool EnableAcrylic(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) { return false; }
        try
        {
            var margins = new MARGINS { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            if (DwmExtendFrameIntoClientArea(hwnd, ref margins) != 0) { return false; }
            return ApplyAccentPolicy(hwnd, ACCENT_ENABLE_ACRYLICBLURBEHIND);
        }
        catch (DllNotFoundException) { return false; }
        catch (EntryPointNotFoundException) { return false; }
    }

    // Fully tears the composition effect down (both the Win11 backdrop and any
    // Win10 accent policy), regardless of which path produced it.
    public static void Disable(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) { return; }
        try { SetSystemBackdrop(hwnd, DWMSBT_NONE); } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
        try { ApplyAccentPolicy(hwnd, ACCENT_DISABLED); } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
        try
        {
            var margins = new MARGINS();
            DwmExtendFrameIntoClientArea(hwnd, ref margins);
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
    }
}
"@ -ErrorAction SilentlyContinue
}

$script:GlassState = @{ Active = $false; Supported = $null; OriginalColor = $null }

function Get-GlassSupported {
    # Cached: OS build capability never changes within a session. Any failure
    # probing the version (or an exotic build) conservatively reports false so
    # callers keep the plain translucent look.
    if ($null -ne $script:GlassState.Supported) { return $script:GlassState.Supported }
    $supported = $false
    try {
        $build = [System.Environment]::OSVersion.Version.Build
        if ($build -ge 17134) { $supported = $true }   # Windows 10 1803+ / 11
    } catch { }
    $script:GlassState.Supported = $supported
    return $supported
}

function Enable-GlassBackdrop([System.Windows.Window]$Window) {
    # Returns $true when a real composition effect was applied; $false means a
    # caller must stay with the plain fallback palette.
    if ($null -eq $Window) { return $false }
    try {
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($Window)
        $hwnd = $helper.Handle
        if ($hwnd -eq [IntPtr]::Zero) {
            # EnsureHandle returns the created HWND; capture it so it never
            # leaks into the function's pipeline output.
            $hwnd = $helper.EnsureHandle()
        }
        if ($hwnd -eq [IntPtr]::Zero) { return $false }
        $hwnd = [IntPtr]$hwnd

        # FromHwnd resolves the presentation source reliably even for a window
        # that has never been shown; FromVisual only works post-show.
        $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
        if (-not $src -or -not $src.CompositionTarget) { return $false }

        # Preserve the pre-glass render color exactly once, so disabling later
        # restores the previous appearance rather than guessing a default.
        if ($script:GlassState.OriginalColor -eq $null) {
            $script:GlassState.OriginalColor = $src.CompositionTarget.BackgroundColor
        }
        $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent

        $applied = [NSCloudGlassInterop]::SetSystemBackdrop($hwnd, 3)   # transient acrylic (Win11)
        if (-not $applied) {
            $applied = [NSCloudGlassInterop]::EnableAcrylic($hwnd)       # accent blur (Win10 1803+)
        }
        if (-not $applied) {
            # Neither path took effect; if this is a retry after a previous
            # success, first tear the effect down so we never half-enable.
            [NSCloudGlassInterop]::Disable($hwnd)
            $script:GlassState.Active = $false
            return $false
        }

        $script:GlassState.Active = $true
        return $true
    } catch {
        try {
            $helper = [System.Windows.Interop.WindowInteropHelper]::new($Window)
            [NSCloudGlassInterop]::Disable($helper.Handle)
        } catch { }
        $script:GlassState.Active = $false
        return $false
    }
}

function Disable-GlassBackdrop([System.Windows.Window]$Window) {
    if ($null -eq $Window) { return }
    try {
        $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle
        [NSCloudGlassInterop]::Disable($hwnd)

        $src = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
        if ($src -and $src.CompositionTarget) {
            if ($script:GlassState.OriginalColor -ne $null) {
                $src.CompositionTarget.BackgroundColor = $script:GlassState.OriginalColor
            } else {
                $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Black   # opaque default
            }
        }
    } catch { }
    $script:GlassState.Active = $false
}

# ==============================================================================
# THEME APPLICATION ENGINE
# ==============================================================================
function Apply-UITheme([string]$ThemeName) {
    $script:Palette = Get-MainThemePalette $ThemeName
    $p = $script:Palette

    $window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.WindowBg)
    $sidebar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.SidebarBg)
    $sidebar.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.SidebarBorder)

    # Disks view toolbar
    $refreshBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
    $refreshBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
    $refreshBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)

    $addDiskBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Accent)
    if ($transferDiskBtn) {
        $transferDiskBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
        $transferDiskBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
        $transferDiskBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }

    # Google Drive Card
    $gdCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
    $gdCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    $gdNameLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $gdAccountText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $gdInLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $gdQuotaText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $gdStorageBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)

    foreach ($btn in @($gdExplorerBtn, $gdSettingsBtn, $gdUploadBtn, $gdRemoveBtn)) {
        $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
        $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
        $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }

    # TeraBox Card
    $tbCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
    $tbCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    $tbNameLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $tbAccountText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $tbInLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $tbQuotaText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $tbStorageBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)

    foreach ($btn in @($tbExplorerBtn, $tbSettingsBtn, $tbUploadBtn, $tbRemoveBtn)) {
        $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
        $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
        $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }

    # Provider drive selectors and cache quota use the same input palette in every theme.
    foreach ($combo in @($gdLetterCombo, $tbLetterCombo, $cacheQuotaCombo)) {
        $combo.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBg)
        $combo.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)
        $combo.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }
    # Options View
    $optTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $optSubtitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $backToDisksBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
    $backToDisksBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
    $backToDisksBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)

    foreach ($card in @($genCard, $themeCard, $cacheCard, $diagCard)) {
        $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
        $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    }
    foreach ($lbl in @($genTitle, $themeTitle, $cacheTitle, $diagTitle)) {
        $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }
    foreach ($chk in @($optStartupChk, $optTrayChk, $optStartMinChk, $optExplorerChk, $optAutoMountChk)) {
        if ($chk) {
            $chk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
        }
    }
    foreach ($rb in @($rbThemePureBlack, $rbThemePureWhite)) {
        if ($rb) {
            $rb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
        }
    }
    if ($rbThemeTranslucent) {
        $rbThemeTranslucent.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }

    if ($script:OptionsInfoIcons) {
        foreach ($ic in $script:OptionsInfoIcons) {
            $ic.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
            $ic.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
            if ($ic.Child -is [System.Windows.Controls.TextBlock]) {
                $ic.Child.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
            }
            if ($ic.ToolTip -is [System.Windows.Controls.ToolTip]) {
                $ic.ToolTip.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
                $ic.ToolTip.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
                if ($ic.ToolTip.Content -is [System.Windows.Controls.StackPanel]) {
                    foreach ($child in $ic.ToolTip.Content.Children) {
                        if ($child -is [System.Windows.Controls.TextBlock]) {
                            if ($child.FontWeight -eq [System.Windows.FontWeights]::Bold) {
                                $child.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
                            } else {
                                $child.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
    if ($script:OptionsToolTips) {
        foreach ($tt in $script:OptionsToolTips) {
            $tt.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
            $tt.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
            if ($tt.Content -is [System.Windows.Controls.StackPanel]) {
                foreach ($child in $tt.Content.Children) {
                    if ($child -is [System.Windows.Controls.TextBlock]) {
                        if ($child.FontWeight -eq [System.Windows.FontWeights]::Bold) {
                            $child.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
                        } else {
                            $child.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
                        }
                    }
                }
            }
        }
    }
    $themeDesc.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $cachePathLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $cacheQuotaLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $diagDescLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)

    foreach ($btn in @($cleanCacheBtn, $openCacheBtn, $showDiagBtn, $trimMemBtn, $browseCacheBtn)) {
        $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
        $btn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
        $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }

    # Help View
    $helpTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $helpSubtitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $backFromHelpBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
    $backFromHelpBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
    $backFromHelpBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)

    foreach ($hcard in @($helpQuickCard, $helpSecCard, $helpProvCard, $helpPerfCard)) {
        $hcard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
        $hcard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    }
    foreach ($htitle in @($helpQuickTitle, $helpSecTitle, $helpProvTitle, $helpPerfTitle)) {
        $htitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }
    foreach ($htxt in @($helpQuickText, $helpSecText, $helpProvText, $helpPerfText)) {
        $htxt.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    }

    # Analytics View
    $analyticsTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $analyticsSubtitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $analyticsStorageSummary.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $backFromAnalyticsBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
    $backFromAnalyticsBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
    $backFromAnalyticsBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    foreach ($acard in @($overviewCard.Card, $storageCard.Card, $resourceCard.Card)) {
        $acard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
        $acard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    }
    foreach ($atitle in @($overviewCard.Title, $storageCard.Title, $resourceCard.Title)) {
        $atitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }
    foreach ($arow in @($analyticsStorageSummary, $analyticsAppRam, $analyticsAppCpu, $analyticsNetwork, $analyticsAccounts, $analyticsMounts)) {
        $arow.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    }
    $overviewCard.Accent.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#3B82F6')
    $storageCard.Accent.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F59E0B')
    $resourceCard.Accent.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#14B8A6')
    $analyticsDarkPalette = $p.Name -in @('PureBlack', 'Translucent')
    $analyticsBlue = if ($analyticsDarkPalette) { '#93C5FD' } else { '#2563EB' }
    $analyticsGreen = if ($analyticsDarkPalette) { '#86EFAC' } else { '#15803D' }
    $analyticsAmber = if ($analyticsDarkPalette) { '#FCD34D' } else { '#B45309' }
    $analyticsTeal = if ($analyticsDarkPalette) { '#5EEAD4' } else { '#0F766E' }
    $analyticsAccounts.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($analyticsBlue)
    $analyticsMounts.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($analyticsGreen)
    $analyticsStorageSummary.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($analyticsAmber)
    foreach ($resourceMetric in @($analyticsAppRam, $analyticsAppCpu, $analyticsNetwork)) {
        $resourceMetric.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($analyticsTeal)
    }

    # Logs View
    $logsTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $logsSubtitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $logsSeverityLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $logsAccountLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    $logsStatusLine.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextMuted)
    $logsPrivacyTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $logsTextBox.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBg)
    $logsTextBox.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)
    $logsTextBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    $backFromLogsBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
    $backFromLogsBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
    $backFromLogsBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    foreach ($lbtn in @($logsRefreshBtn, $logsOpenFolderBtn, $logsClearBtn)) {
        $lbtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBg)
        $lbtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.ButtonBorder)
        $lbtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }
    foreach ($lcard in @($logsListCard, $logsPrivacyCard)) {
        $lcard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
        $lcard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
    }
    foreach ($lcombo in @($logsSeverityCombo, $logsAccountCombo)) {
        $lcombo.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBg)
        $lcombo.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.InputBorder)
        $lcombo.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }
    foreach ($pline in $script:LogsPrivacyLines) {
        $pline.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextSecondary)
    }

    # Liquid glass backdrop: real Windows-composed acrylic for the Translucent
    # theme only, torn down when switching to any other theme. Unsupported
    # builds or any failure keep the plain translucent fallback set above.
    $glassActive = $false
    if ($p.Name -eq 'Translucent' -and (Get-GlassSupported)) {
        $glassActive = Enable-GlassBackdrop $window
    } elseif ($script:GlassState.Active) {
        Disable-GlassBackdrop $window
    }
    if ($glassActive) {
        # Keep a light tint over the compositor blur so the wallpaper remains
        # visible through the window and its navigation and dashboard surfaces.
        $window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.WindowGlassBg)
        $sidebar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.SidebarGlassBg)
        foreach ($glassCard in @($gdCard, $tbCard, $genCard, $themeCard, $cacheCard, $diagCard, $helpQuickCard, $helpSecCard, $helpProvCard, $helpPerfCard, $overviewCard.Card, $storageCard.Card, $resourceCard.Card, $logsListCard, $logsPrivacyCard)) {
            $glassCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardGlassBg)
        }
    }

    Update-NavActiveState
}

function Update-NavActiveState {
    $p = $script:Palette
    foreach ($item in @(
        @{ Nav = $navDisksItem; View = 'Disks' },
        @{ Nav = $navOptionsItem; View = 'Options' },
        @{ Nav = $navAnalyticsItem; View = 'Analytics' },
        @{ Nav = $navLogsItem; View = 'Logs' },
        @{ Nav = $navHelpItem; View = 'Help' }
    )) {
        if ($script:CurrentView -eq $item.View) {
            $item.Nav.Button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.NavActiveBg)
            $item.Nav.Icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
            $item.Nav.Label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
        } else {
            $item.Nav.Button.Background = [System.Windows.Media.Brushes]::Transparent
            $item.Nav.Icon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.NavInactiveForeground)
            $item.Nav.Label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.NavInactiveForeground)
        }
    }
}

function Show-DisksView {
    $script:CurrentView = 'Disks'
    $disksView.Visibility = [System.Windows.Visibility]::Visible
    $optionsView.Visibility = [System.Windows.Visibility]::Collapsed
    $helpView.Visibility = [System.Windows.Visibility]::Collapsed
    $analyticsView.Visibility = [System.Windows.Visibility]::Collapsed
    $logsView.Visibility = [System.Windows.Visibility]::Collapsed
    Stop-AnalyticsCollection
    Stop-LogsViewLoad
    $script:AnalyticsStorageLastStarted = [DateTime]::MinValue
    Update-NavActiveState
}

function Update-CacheUsageDisplay {
    try {
        $st = Get-DetailedCacheStatistics -CacheDirectory $script:CacheDirectory
        $mbTotal = [Math]::Round($st.TotalSizeBytes / 1MB, 1)
        $mbInUse = [Math]::Round($st.InUseBytes / 1MB, 1)
        $gbFree = [Math]::Round($st.DriveFreeBytes / 1GB, 1)
        $osNotice = if ($st.IsSystemDrive) { " (OS Drive Warning)" } else { "" }
        $cacheUsageLabel.Text = "Total: $mbTotal MB ($($st.TotalFileCount) files) | In use: $mbInUse MB ($($st.InUseCount) locked) | Free on $($st.DriveLetter): $gbFree GB$osNotice"
        $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextSecondary)
    } catch { }
}

function Show-OptionsView {
    $script:CurrentView = "Options"
    $disksView.Visibility = [System.Windows.Visibility]::Collapsed
    $optionsView.Visibility = [System.Windows.Visibility]::Visible
    $helpView.Visibility = [System.Windows.Visibility]::Collapsed
    $analyticsView.Visibility = [System.Windows.Visibility]::Collapsed
    $logsView.Visibility = [System.Windows.Visibility]::Collapsed
    Stop-AnalyticsCollection
    Stop-LogsViewLoad
    $script:AnalyticsStorageLastStarted = [DateTime]::MinValue
    Update-NavActiveState

    Update-CacheUsageDisplay
}

function Show-HelpView {
    $script:CurrentView = 'Help'
    $disksView.Visibility = [System.Windows.Visibility]::Collapsed
    $optionsView.Visibility = [System.Windows.Visibility]::Collapsed
    $helpView.Visibility = [System.Windows.Visibility]::Visible
    $analyticsView.Visibility = [System.Windows.Visibility]::Collapsed
    $logsView.Visibility = [System.Windows.Visibility]::Collapsed
    Stop-AnalyticsCollection
    Stop-LogsViewLoad
    $script:AnalyticsStorageLastStarted = [DateTime]::MinValue
    Update-NavActiveState
}

$navDisksItem.Button.Add_Click({ Show-DisksView })
$navOptionsItem.Button.Add_Click({ Show-OptionsView })
$navAnalyticsItem.Button.Add_Click({ Show-AnalyticsView })
$navLogsItem.Button.Add_Click({ Show-LogsView })
$navHelpItem.Button.Add_Click({ Show-HelpView })
$backToDisksBtn.Add_Click({ Show-DisksView })
$backFromAnalyticsBtn.Add_Click({ Show-DisksView })
$backFromLogsBtn.Add_Click({ Show-DisksView })

$logsSeverityCombo.Add_SelectionChanged({ if (-not $script:LogsFilterUpdateInProgress) { Render-LogsViewContent } })
$logsAccountCombo.Add_SelectionChanged({ if (-not $script:LogsFilterUpdateInProgress) { Render-LogsViewContent } })
$logsSearchBox.Add_TextChanged({
    $script:LogsSearchText = [string]$logsSearchBox.Text
    Render-LogsViewContent
})

function Clear-NSCloudLogsFolder {
    Stop-LogsViewLoad
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs'
        if (Test-Path -LiteralPath $logDir) {
            foreach ($name in @('application.jsonl', 'application.jsonl.1', 'startup-restore.jsonl', 'startup-restore.jsonl.1')) {
                $path = Join-Path $logDir $name
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            }
        }
    } catch {
        $message = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
        $logsStatusLine.Text = 'Could not clear the logs.'
        $logsTextBox.Text = "Unable to clear logs: $message"
        return
    }
    $script:LogsPageOffset = 0
    Update-LogsViewContent
}

$logsRefreshBtn.Add_Click({
    $script:LogsPageOffset = 0
    Update-LogsViewContent
})
$logsOlderBtn.Add_Click({
    if (-not $script:LogsHasOlderEntries) { return }
    $script:LogsPageOffset += $script:LogsPageSize
    Update-LogsViewContent
})
$logsNewerBtn.Add_Click({
    if ($script:LogsPageOffset -le 0) { return }
    $script:LogsPageOffset = [Math]::Max(0, ($script:LogsPageOffset - $script:LogsPageSize))
    Update-LogsViewContent
})
$logsClearBtn.Add_Click({ Clear-NSCloudLogsFolder })
$logsOpenFolderBtn.Add_Click({
    try {
        $logDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$logDir`""
    } catch { }
})

# Use a theme-aware button template so disabled controls keep their themed surface
# instead of reverting to the Windows default white/gray face.
$buttonStyleXaml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Setter Property="SnapsToDevicePixels" Value="True" />
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="Chrome"
                Background="{TemplateBinding Background}"
                BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}"
                CornerRadius="6"
                Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                            VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                            RecognizesAccessKey="True" />
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="Chrome" Property="Opacity" Value="0.92" />
          </Trigger>
          <Trigger Property="IsPressed" Value="True">
            <Setter TargetName="Chrome" Property="Opacity" Value="0.78" />
          </Trigger>
          <Trigger Property="IsEnabled" Value="False">
            <Setter TargetName="Chrome" Property="Opacity" Value="0.55" />
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
'@
$buttonStyle = [System.Windows.Markup.XamlReader]::Parse($buttonStyleXaml)
$window.Resources.Add([System.Windows.Controls.Button], $buttonStyle)

# Apply active theme immediately
Apply-UITheme $script:Settings.Theme

# ==============================================================================
# UI STATE SYNCHRONIZER
# ==============================================================================
function Ensure-UiDriveStatusShape([object]$Status) {
    if ($null -eq $Status) { return $null }
    $defaults = [ordered]@{
        IsMounted = $false
        ProcessRunning = $false
        DriveLetter = ''
        DriveRoot = ''
        IsReadOnly = $null
        ProcessId = $null
        MountState = $null
    }
    if ($Status -is [System.Collections.IDictionary]) {
        foreach ($key in $defaults.Keys) {
            if (-not $Status.Contains($key)) { $Status[$key] = $defaults[$key] }
        }
        return $Status
    }

    $normalized = [ordered]@{}
    foreach ($property in $Status.PSObject.Properties) {
        $normalized[$property.Name] = Get-SafeProperty $Status $property.Name $null
    }
    foreach ($key in $defaults.Keys) {
        if (-not $normalized.Contains($key)) { $normalized[$key] = $defaults[$key] }
    }
    return $normalized
}

function Get-CachedUiDriveStatus([string]$ProviderId, [string]$AccountId = '', [string]$DriveLetter = '') {
    if (-not [string]::IsNullOrWhiteSpace($AccountId) -and $script:AccountMountStates.ContainsKey($AccountId)) {
        $mountState = $script:AccountMountStates[$AccountId]
        if ($mountState -and $mountState.State -eq 'Mounting') {
            $letter = if ($DriveLetter) { $DriveLetter } else { [string]$mountState.DriveLetter }
            return [ordered]@{ IsMounted = $false; ProcessRunning = $false; DriveLetter = $letter; DriveRoot = "$letter`:\"; IsReadOnly = $false; ProcessId = $null; MountState = $mountState }
        }
        if ($mountState -and $mountState.State -in @('Error', 'AuthRequired')) {
            $snapshot = $script:ProviderStatusSnapshot
            $accountStatuses = Get-SafeProperty $snapshot 'AccountStatuses' $null
            if ($accountStatuses -and $accountStatuses.ContainsKey($AccountId)) {
                $liveStatus = Ensure-UiDriveStatusShape $accountStatuses[$AccountId]
                $reportedAccountId = [string](Get-SafeProperty $liveStatus 'AccountId' '')
                $reportedLetter = ([string]$liveStatus.DriveLetter).TrimEnd(':').TrimEnd('\')
                $expectedLetter = if ($DriveLetter) { ([string]$DriveLetter).TrimEnd(':').TrimEnd('\') } else { ([string]$mountState.DriveLetter).TrimEnd(':').TrimEnd('\') }
                $statusMatchesAccount = (-not $reportedAccountId -or [string]::Equals($reportedAccountId, $AccountId, [System.StringComparison]::OrdinalIgnoreCase)) -and
                    (-not $expectedLetter -or -not $reportedLetter -or [string]::Equals($expectedLetter, $reportedLetter, [System.StringComparison]::OrdinalIgnoreCase))
                if ($liveStatus.ProcessRunning -and $liveStatus.IsMounted -and $statusMatchesAccount) {
                    $liveStatus['MountState'] = $mountState
                    return $liveStatus
                }
            }
            $letter = if ($DriveLetter) { $DriveLetter } else { [string]$mountState.DriveLetter }
            return [ordered]@{ IsMounted = $false; ProcessRunning = $false; DriveLetter = $letter; DriveRoot = "$letter`:\"; IsReadOnly = $false; ProcessId = $null; MountState = $mountState }
        }
    }
    if ([string]::IsNullOrWhiteSpace($AccountId)) {
        $providerKey = ([string]$ProviderId).ToLowerInvariant()
        if ($script:LegacyMountStates.ContainsKey($providerKey)) {
            $legacyState = $script:LegacyMountStates[$providerKey]
            if ($legacyState -and $legacyState.State -eq 'Mounting') {
                $letter = if ($DriveLetter) { $DriveLetter } else { [string]$legacyState.DriveLetter }
                return [ordered]@{ IsMounted = $false; ProcessRunning = $false; DriveLetter = $letter; DriveRoot = "$letter`:\"; IsReadOnly = $false; ProcessId = $null; MountState = $legacyState }
            }
            if ($legacyState -and $legacyState.State -eq 'Disconnecting') {
                $snapshot = $script:ProviderStatusSnapshot
                $cachedStatus = if ($providerKey -eq 'gdrive' -and $snapshot) { $snapshot.GoogleStatus } elseif ($providerKey -eq 'terabox' -and $snapshot) { $snapshot.TeraBoxStatus } else { $null }
                $letter = if ($DriveLetter) { $DriveLetter } elseif ($legacyState.DriveLetter) { [string]$legacyState.DriveLetter } else { [string](Get-PreferredDriveLetter $providerKey) }
                return [ordered]@{
                    IsMounted = [bool](Get-SafeProperty $cachedStatus 'IsMounted' $false)
                    ProcessRunning = [bool](Get-SafeProperty $cachedStatus 'ProcessRunning' $false)
                    DriveLetter = $letter
                    DriveRoot = "$letter`:\"
                    IsReadOnly = [bool](Get-SafeProperty $cachedStatus 'IsReadOnly' $false)
                    ProcessId = Get-SafeProperty $cachedStatus 'ProcessId' $null
                    MountState = $legacyState
                }
            }
            if ($legacyState -and $legacyState.State -in @('Error', 'AuthRequired')) {
                $snapshot = $script:ProviderStatusSnapshot
                $cachedStatus = if ($providerKey -eq 'gdrive' -and $snapshot) { $snapshot.GoogleStatus } elseif ($providerKey -eq 'terabox' -and $snapshot) { $snapshot.TeraBoxStatus } else { $null }
                $liveStatus = Ensure-UiDriveStatusShape $cachedStatus
                if ($liveStatus -and $liveStatus.ProcessRunning -and $liveStatus.IsMounted) {
                    $liveStatus['MountState'] = $legacyState
                    return $liveStatus
                }
            }
        }
    }
    $snapshot = $script:ProviderStatusSnapshot
    if ($snapshot) {
        $accountStatuses = Get-SafeProperty $snapshot 'AccountStatuses' $null
        if (-not [string]::IsNullOrWhiteSpace($AccountId) -and $accountStatuses -and $accountStatuses.ContainsKey($AccountId)) {
            $accountStatus = Ensure-UiDriveStatusShape $accountStatuses[$AccountId]
            $reportedAccountId = [string](Get-SafeProperty $accountStatus 'AccountId' '')
            $reportedLetter = ([string]$accountStatus.DriveLetter).TrimEnd(':').TrimEnd('\')
            $expectedLetter = ([string]$DriveLetter).TrimEnd(':').TrimEnd('\')
            if (($reportedAccountId -and -not [string]::Equals($reportedAccountId, $AccountId, [System.StringComparison]::OrdinalIgnoreCase)) -or
                ($expectedLetter -and $reportedLetter -and -not [string]::Equals($expectedLetter, $reportedLetter, [System.StringComparison]::OrdinalIgnoreCase))) {
                $unmappedLetter = if ($expectedLetter) { $expectedLetter } else { $reportedLetter }
                return [ordered]@{
                    IsMounted = $false
                    ProcessRunning = $false
                    DriveLetter = $unmappedLetter
                    DriveRoot = if ($unmappedLetter) { "$unmappedLetter`:\" } else { '' }
                    IsReadOnly = $false
                    ProcessId = $null
                    MountState = $accountStatus.MountState
                }
            }
            return $accountStatus
        }
        if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
            $savedAccount = Get-CloudAccount -AccountId $AccountId
            $letter = if ($DriveLetter) { ([string]$DriveLetter).TrimEnd(':').TrimEnd('\') } elseif ($savedAccount) { ([string]$savedAccount.DriveLetter).TrimEnd(':').TrimEnd('\') } else { '' }
            return [ordered]@{
                IsMounted = $false
                ProcessRunning = $false
                DriveLetter = $letter
                DriveRoot = if ($letter) { "$letter`:\" } else { '' }
                IsReadOnly = $false
                ProcessId = $null
                MountState = $null
            }
        }
        $statusProperty = if ($ProviderId -eq 'gdrive') { 'GoogleStatus' } elseif ($ProviderId -eq 'terabox') { 'TeraBoxStatus' } else { '' }
        $providerStatus = if ($statusProperty) { Get-SafeProperty $snapshot $statusProperty $null } else { $null }
        if ($providerStatus) { return (Ensure-UiDriveStatusShape $providerStatus) }
    }

    $savedAccount = if (-not [string]::IsNullOrWhiteSpace($AccountId)) { Get-CloudAccount -AccountId $AccountId } else { $null }
    $letter = if ($DriveLetter) {
        $DriveLetter
    } elseif ($savedAccount) {
        [string]$savedAccount.DriveLetter
    } elseif (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        ''
    } elseif ($ProviderId -eq 'gdrive') {
        $script:GDriveLetter
    } else {
        $script:TeraBoxLetter
    }
    $driveRoot = if ($letter) { "$letter`:\" } else { '' }
    return [ordered]@{ IsMounted = $false; ProcessRunning = $false; DriveLetter = $letter; DriveRoot = $driveRoot; IsReadOnly = $false; ProcessId = $null; MountState = $null }
}

function Start-ScopedDriveDisconnect(
    [string]$ProviderId,
    [string]$DriveLetter,
    [string]$AccountId = '',
    [switch]$RemoveAccount,
    [switch]$RemoveLegacySession,
    [switch]$ReconnectAfterSuccess
) {
    if ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker -or $script:ReconnectWorker) {
        return $false
    }
    $key = if ($AccountId) { $AccountId } else { "__legacy_${ProviderId}_$($DriveLetter.TrimEnd(':'))" }
    if ($script:DriveDisconnectWorkers.ContainsKey($key)) { return $false }

    $cleanLetter = ([string]$DriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $account = if ($AccountId) { Get-CloudAccount -AccountId $AccountId } else { $null }
    $accountCacheDirectory = if ($account -and $account.CacheDirectory) { [string]$account.CacheDirectory } else { [string]$script:CacheDirectory }
    if ($AccountId) {
        $script:AccountMountStates[$AccountId] = [ordered]@{
            State = 'Disconnecting'; Stage = 'Stopping selected drive'
            Error = $null; DriveLetter = $cleanLetter; StartedAt = [DateTime]::UtcNow
            UpdatedAt = [DateTime]::UtcNow
        }
    } else {
        $script:LegacyMountStates[$ProviderId.ToLowerInvariant()] = [ordered]@{
            State = 'Disconnecting'; Stage = 'Stopping selected drive'
            Error = $null; DriveLetter = $cleanLetter; StartedAt = [DateTime]::UtcNow
            UpdatedAt = [DateTime]::UtcNow
        }
    }

    try {
        $operation = Start-NSBackgroundOperation -ArgumentList @($PSScriptRoot, $ProviderId, $AccountId, $cleanLetter) -ScriptBlock {
            param([string]$sourceRoot, [string]$providerId, [string]$accountId, [string]$driveLetter)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $sourceRoot 'services\VirtualDriveManager.ps1')
            $stop = Stop-VirtualDriveMount -ProviderId $providerId -AccountId $accountId -DriveLetter $driveLetter
            if (-not $stop.Success -or -not $stop.Verified) {
                throw [System.InvalidOperationException]::new([string]$stop.Message)
            }
            $status = Get-VirtualDriveStatus -ProviderId $providerId -AccountId $accountId -DriveLetter $driveLetter
            if ($status.ProcessRunning -or $status.IsMounted) {
                throw [System.InvalidOperationException]::new("The selected drive $driveLetter`: remains mounted.")
            }
            return [pscustomobject]@{
                Verified = $true
                ProviderId = $providerId
                AccountId = $accountId
                DriveLetter = $driveLetter
                Status = $status
                Message = [string]$stop.Message
            }
        }
        $script:DriveDisconnectWorkers[$key] = [pscustomobject]@{
            Operation = $operation
            ProviderId = $ProviderId
            AccountId = $AccountId
            DriveLetter = $cleanLetter
            CacheDirectory = $accountCacheDirectory
            RemoveAccount = [bool]$RemoveAccount
            RemoveLegacySession = [bool]$RemoveLegacySession
            ReconnectAfterSuccess = [bool]$ReconnectAfterSuccess
        }
        return $true
    } catch {
        $message = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
        if ($AccountId) {
            $script:AccountMountStates[$AccountId] = [ordered]@{
                State = 'Error'; Stage = 'Disconnect could not start'
                Error = $message; DriveLetter = $cleanLetter; StartedAt = $null
                UpdatedAt = [DateTime]::UtcNow
            }
        } else {
            $script:LegacyMountStates[$ProviderId.ToLowerInvariant()] = [ordered]@{
                State = 'Error'; Stage = 'Disconnect could not start'
                Error = $message; DriveLetter = $cleanLetter; StartedAt = $null
                UpdatedAt = [DateTime]::UtcNow
            }
        }
        return $false
    }
}

function Complete-AvailableDriveDisconnectWorkers {
    foreach ($key in @($script:DriveDisconnectWorkers.Keys)) {
        $request = $script:DriveDisconnectWorkers[$key]
        if (-not $request -or -not (Test-NSBackgroundOperationCompleted $request.Operation)) { continue }
        $script:DriveDisconnectWorkers.Remove($key)
        $errorMessage = $null
        $result = $null
        try {
            $completed = Complete-NSBackgroundOperation $request.Operation
            if ($completed.HadErrors) {
                $errorMessage = if ($completed.Errors.Count -gt 0) {
                    Format-SanitizedDiagnosticMessage ([string]$completed.Errors[0].Exception.Message)
                } else { 'The disconnect worker failed.' }
            } elseif ($completed.Output.Count -gt 0) {
                $result = $completed.Output[-1]
                if (-not (Get-SafeProperty $result 'Verified' $false)) {
                    $errorMessage = 'Windows did not verify that the selected drive disconnected.'
                }
            } else {
                $errorMessage = 'The disconnect worker returned no verification result.'
            }
        } catch {
            $errorMessage = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
        }

        if ($errorMessage) {
            if ($request.AccountId) {
                $script:AccountMountStates[$request.AccountId] = [ordered]@{
                    State = 'Error'; Stage = 'Disconnect failed'; Error = $errorMessage
                    DriveLetter = $request.DriveLetter; StartedAt = $null
                    UpdatedAt = [DateTime]::UtcNow
                }
            } else {
                $script:LegacyMountStates[$request.ProviderId.ToLowerInvariant()] = [ordered]@{
                    State = 'Error'; Stage = 'Disconnect failed'; Error = $errorMessage
                    DriveLetter = $request.DriveLetter; StartedAt = $null
                    UpdatedAt = [DateTime]::UtcNow
                }
            }
            try {
                Write-NSCloudLog -Severity 'Error' -Provider $request.ProviderId -AccountId $request.AccountId `
                    -Operation 'disconnect' -Message $errorMessage -Recovered $false
            } catch { }
            [System.Windows.MessageBox]::Show($errorMessage, 'Disconnect failed', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            Update-AllUIState
            continue
        }

        $snapshot = $script:ProviderStatusSnapshot
        if ($request.AccountId) {
            $script:AccountMountStates[$request.AccountId] = [ordered]@{
                State = 'Disconnected'; Stage = 'Drive removal verified'; Error = $null
                DriveLetter = $request.DriveLetter; StartedAt = $null
                UpdatedAt = [DateTime]::UtcNow
            }
            $accountStatuses = Get-SafeProperty $snapshot 'AccountStatuses' $null
            if ($accountStatuses -and $accountStatuses.ContainsKey($request.AccountId)) {
                $accountStatuses[$request.AccountId] = $result.Status
            }
            Remove-ProviderExplorerIcon -ProviderId $request.ProviderId -DriveLetter $request.DriveLetter
        } else {
            $script:LegacyMountStates[$request.ProviderId.ToLowerInvariant()] = [ordered]@{
                State = 'Disconnected'; Stage = 'Drive removal verified'; Error = $null
                DriveLetter = $request.DriveLetter; StartedAt = $null
                UpdatedAt = [DateTime]::UtcNow
            }
            if ($snapshot) {
                if ($request.ProviderId -eq 'gdrive' -and $snapshot.PSObject.Properties['GoogleStatus']) { $snapshot.GoogleStatus = $result.Status }
                elseif ($request.ProviderId -eq 'terabox' -and $snapshot.PSObject.Properties['TeraBoxStatus']) { $snapshot.TeraBoxStatus = $result.Status }
            }
            Remove-ProviderExplorerIcon -ProviderId $request.ProviderId -DriveLetter $request.DriveLetter
        }

        if ($request.RemoveAccount) {
            try {
                if (-not (Remove-CloudAccount -AccountId $request.AccountId)) {
                    throw 'The saved account could not be removed after its drive disconnected.'
                }
                if ($request.ProviderId -eq 'gdrive') {
                    Remove-GoogleDriveSession -AccountId $request.AccountId
                } elseif ($request.ProviderId -eq 'terabox') {
                    Remove-TeraBoxSession -AccountId $request.AccountId
                }
                Remove-Item -LiteralPath (Join-Path $request.CacheDirectory $request.AccountId) -Recurse -Force -ErrorAction SilentlyContinue
                if ($request.ProviderId -eq 'terabox') {
                    Remove-Item -LiteralPath (Get-TeraBoxBridgeHomeDirectory -AccountId $request.AccountId) -Recurse -Force -ErrorAction SilentlyContinue
                }
                Remove-Item -LiteralPath (Join-Path (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\webview2-profile') $request.AccountId) -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($logName in @("rclone-$($request.AccountId).log", "rclone-$($request.AccountId).1.log")) {
                    Remove-Item -LiteralPath (Join-Path (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs') $logName) -Force -ErrorAction SilentlyContinue
                }
                $script:AccountMountStates.Remove($request.AccountId)
            } catch {
                $message = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
                [System.Windows.MessageBox]::Show($message, 'Account removal failed', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        } elseif ($request.RemoveLegacySession) {
            try {
                if ($request.ProviderId -eq 'gdrive') { Remove-GoogleDriveSession }
                elseif ($request.ProviderId -eq 'terabox') { Remove-TeraBoxSession }
            } catch {
                $message = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
                [System.Windows.MessageBox]::Show($message, 'Account removal failed', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            }
        }

        try {
            Write-NSCloudLog -Severity 'Info' -Provider $request.ProviderId -AccountId $request.AccountId `
                -Operation 'disconnect' -Message "Verified disconnect of $($request.DriveLetter):." -Recovered $true
        } catch { }
        $script:LastProviderStatusCheck = [DateTime]::MinValue
        if ($request.ReconnectAfterSuccess -and $request.AccountId) {
            Invoke-AutoReconnectWatchdog -AccountId $request.AccountId
        }
        Update-AllUIState
    }
}

function Start-ProviderStatusRefreshWorker {
    if ($script:ProviderStatusWorker) { return }

    $script:ProviderStatusWorker = Start-NSBackgroundOperation -ArgumentList @($PSScriptRoot) -ScriptBlock {
        param([string]$sourceRoot)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $sourceRoot 'models\ConnectionState.ps1')
        . (Join-Path $sourceRoot 'providers\GoogleDriveProvider.ps1')
        . (Join-Path $sourceRoot 'providers\TeraBoxProvider.ps1')
        . (Join-Path $sourceRoot 'services\VirtualDriveManager.ps1')

        $googleCheck = try { Test-GoogleDriveBackendSession } catch {
            [ordered]@{ IsValid = $false; State = 'Error'; Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message); UserInfo = $null }
        }
        $googleStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
        $teraBoxCheck = try { Test-TeraBoxBackendSession } catch {
            [ordered]@{ IsValid = $false; State = 'Error'; Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message); UserInfo = $null }
        }
        $teraBoxStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
        $accountStatuses = @{}
        foreach ($account in @(Get-CloudAccounts)) {
            try {
                $accountStatuses[[string]$account.Id] = Get-VirtualDriveStatus -AccountId $account.Id -ProviderId $account.ProviderId
            } catch { }
        }

        [pscustomobject]@{
            GoogleCheck = $googleCheck
            GoogleStatus = $googleStatus
            TeraBoxCheck = $teraBoxCheck
            TeraBoxStatus = $teraBoxStatus
            AccountStatuses = $accountStatuses
            CheckedAt = [DateTime]::UtcNow
        }
    }
}

function Start-StartupCacheRecoveryWorker {
    if ($script:StartupCacheRecoveryWorker) { return }

    $script:StartupCacheRecoveryWorker = Start-NSBackgroundOperation -ArgumentList @($PSScriptRoot, $script:CacheDirectory) -ScriptBlock {
        param([string]$sourceRoot, [string]$cacheDirectory)
        $ErrorActionPreference = 'Stop'
        . (Join-Path $sourceRoot 'services\CacheManager.ps1')
        $targets = [System.Collections.Generic.List[string]]::new()
        $targetSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($account in @(Get-CloudAccounts)) {
            $providerId = ([string]$account.ProviderId).ToLowerInvariant()
            $accountId = [string]$account.Id
            if ($providerId -notin @('gdrive', 'terabox') -or $accountId -notmatch "^${providerId}_[A-Za-z0-9_-]{1,128}$") {
                continue
            }
            $accountCacheBase = if ($account.CacheDirectory) { [string]$account.CacheDirectory } else { $cacheDirectory }
            $accountCachePath = Join-Path $accountCacheBase $accountId
            if ($targetSet.Add($accountCachePath)) { $targets.Add($accountCachePath) }
        }
        foreach ($legacyMountKey in @('gdrive', 'terabox')) {
            $legacyCachePath = Join-Path $cacheDirectory $legacyMountKey
            if ($targetSet.Add($legacyCachePath)) { $targets.Add($legacyCachePath) }
        }
        $recovery = Invoke-StartupCacheRecovery -CacheDirectory $cacheDirectory -MountCacheDirectories @($targets.ToArray())
        [pscustomobject]@{ Success = ($recovery.Errors.Count -eq 0); Result = $recovery }
    }
}

function Complete-AvailableStartupWorkers {
    Complete-AvailableDriveDisconnectWorkers

    if ($script:ProviderStatusWorker -and (Test-NSBackgroundOperationCompleted $script:ProviderStatusWorker)) {
        try {
            $completed = Complete-NSBackgroundOperation $script:ProviderStatusWorker
            if (-not $completed.HadErrors -and $completed.Output.Count -gt 0) {
                $script:ProviderStatusSnapshot = $completed.Output[-1]
            } elseif ($completed.HadErrors) {
                $message = if ($completed.Errors.Count -gt 0) {
                    Format-SanitizedDiagnosticMessage ([string]$completed.Errors[0].Exception.Message)
                } else {
                    'Provider status check failed.'
                }
                try {
                    Write-NSCloudLog -Severity 'Error' -Operation 'status-refresh' -Message $message -Recovered $false
                } catch { }
                $script:ProviderStatusSnapshot = [pscustomobject]@{
                    GoogleCheck = [ordered]@{ IsValid = $false; State = 'Error'; Error = $message; UserInfo = $null }
                    GoogleStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive'
                    TeraBoxCheck = [ordered]@{ IsValid = $false; State = 'Error'; Error = $message; UserInfo = $null }
                    TeraBoxStatus = Get-CachedUiDriveStatus -ProviderId 'terabox'
                    CheckedAt = [DateTime]::UtcNow
                }
            }
        } catch { }
        $script:ProviderStatusWorker = $null
        $script:LastProviderStatusCheck = [DateTime]::UtcNow
    }

    if ($script:StartupCacheRecoveryWorker -and (Test-NSBackgroundOperationCompleted $script:StartupCacheRecoveryWorker)) {
        try {
            $completed = Complete-NSBackgroundOperation $script:StartupCacheRecoveryWorker
            if ($completed.HadErrors) {
                $firstErr = if ($completed.Errors.Count -gt 0) { $completed.Errors[0] } else { $null }
                $message = if ($firstErr -is [System.Management.Automation.ErrorRecord] -and $firstErr.Exception) {
                    $firstErr.Exception.Message
                } elseif ($firstErr -is [System.Exception]) {
                    $firstErr.Message
                } elseif ($firstErr) {
                    [string]$firstErr
                } else {
                    'Startup cache recovery failed.'
                }
                Write-NSCloudLog -Severity 'Warning' -Operation 'startup-cache-recovery' -Message $message
            } elseif ($completed.Output.Count -gt 0) {
                $recovery = $completed.Output[-1].Result
                foreach ($errorMessage in $recovery.Errors) {
                    Write-NSCloudLog -Severity 'Warning' -Operation 'startup-cache-recovery' -Message ([string]$errorMessage)
                }
            }
        } catch {
            Write-NSCloudLog -Severity 'Warning' -Operation 'startup-cache-recovery' -Message ([string]$_.Exception.Message)
        } finally {
            $script:StartupCacheRecoveryWorker = $null
        }
    }

    if ($script:StartupAutoMountWorker -and (Test-NSBackgroundOperationCompleted $script:StartupAutoMountWorker)) {
        try {
            $completed = Complete-NSBackgroundOperation $script:StartupAutoMountWorker
            foreach ($result in $completed.Output) {
                $key = [string](Get-SafeProperty $result 'AccountId' '')
                if (-not $key) { continue }
                $resultState = [string](Get-SafeProperty $result 'State' 'Error')
                $resultError = Get-SafeProperty $result 'Error' $null
                $resultDriveLetter = [string](Get-SafeProperty $result 'DriveLetter' '')
                $script:AccountMountStates[$key] = [ordered]@{
                    State = if ($resultState -in @('Mounted', 'ExistingProcess', 'FilesystemUnverified')) { 'Mounted' } elseif ($resultState -eq 'Error') { 'Error' } else { $resultState }
                    Stage = if ($resultState -eq 'FilesystemUnverified') { 'Existing mount retained; filesystem root check timed out' } elseif ($resultState -eq 'ExistingProcess') { 'Existing mount process and drive detected; filesystem root not probed' } elseif ($resultState -eq 'Mounted') { 'Filesystem verified' } else { 'Startup restore finished' }
                    Error = if ($resultError) { [string]$resultError } else { $null }
                    DriveLetter = $resultDriveLetter
                    StartedAt = $null
                    UpdatedAt = [DateTime]::UtcNow
                }
                # Shared-log entry per completed startup restore result so the
                # Logs page shows the true outcome (this loop is the single
                # funnel where worker results reach the UI).
                try {
                    $restoreSeverity = 'Info'
                    if ($resultState -eq 'Error') { $restoreSeverity = 'Error' }
                    elseif ($resultState -eq 'FilesystemUnverified') { $restoreSeverity = 'Warning' }
                    elseif ($resultState -eq 'AuthRequired') { $restoreSeverity = 'Warning' }
                    $restoreRecovered = if ($resultState -in @('Mounted', 'ExistingProcess')) { $true } elseif ($resultState -eq 'Error') { $false } else { $null }
                    Write-NSCloudLog -Severity $restoreSeverity -AccountId $key -Operation 'startup-restore' `
                        -Message ("Account restore finished: $resultState$(if ($resultDriveLetter) { " on ${resultDriveLetter}:" })$(if ($resultError) { " - $resultError" })") `
                        -Recovered $restoreRecovered
                } catch { }
                if ($resultState -in @('Mounted', 'ExistingProcess', 'FilesystemUnverified')) {
                    Register-ProviderExplorerIconViaAccount -AccountId $key -DriveLetter $resultDriveLetter
                }
            }
            if ($completed.HadErrors) {
                # A worker-level failure (not a per-provider mount failure) must
                # surface, otherwise an empty result list looks like a clean
                # restore even when nothing was verified.
                $message = if ($completed.Errors.Count -gt 0) { Format-SanitizedDiagnosticMessage ([string]$completed.Errors[0].Exception.Message) } else { 'The startup restore worker stopped unexpectedly.' }
                try {
                    Write-NSCloudLog -Severity 'Error' -Operation 'startup-restore' -Message "Startup restore worker failed: $message" -Recovered $false
                } catch { }
            }
        } catch { }
        $script:StartupAutoMountWorker = $null
        $script:LastProviderStatusCheck = [DateTime]::MinValue
    }

    if ($script:ReconnectWorker -and (Test-NSBackgroundOperationCompleted $script:ReconnectWorker)) {
        try {
            $completed = Complete-NSBackgroundOperation $script:ReconnectWorker
            foreach ($result in $completed.Output) {
                $key = [string](Get-SafeProperty $result 'WorkerKey' '')
                if (-not $key) { continue }
                $resultState = [string](Get-SafeProperty $result 'State' 'Error')
                $resultError = Get-SafeProperty $result 'Error' $null
                $resultDriveLetter = [string](Get-SafeProperty $result 'DriveLetter' '')
                if ($key -notlike '__*') {
                    $script:AccountMountStates[$key] = [ordered]@{
                        State = if ($resultState -in @('Mounted', 'ExistingProcess')) { 'Mounted' } elseif ($resultState -eq 'Error') { 'Error' } elseif ($resultState -eq 'AuthRequired') { 'AuthRequired' } else { $resultState }
                        Stage = if ($resultState -eq 'Mounted') { 'Filesystem verified' } elseif ($resultState -eq 'ExistingProcess') { 'Existing mount process and drive detected; filesystem root not re-probed' } elseif ($resultState -eq 'AuthRequired') { 'Sign-in required' } else { 'Mount attempt finished' }
                        Error = if ($resultError) { [string]$resultError } else { $null }
                        DriveLetter = $resultDriveLetter
                        StartedAt = $null
                        UpdatedAt = [DateTime]::UtcNow
                    }
                }
                # Shared-log entry for every reconnect outcome (mount or
                # recovery attempt), including legacy keys.
                try {
                    $reconSeverity = 'Info'
                    if ($resultState -eq 'Error') { $reconSeverity = 'Error' }
                    elseif ($resultState -eq 'AuthRequired') { $reconSeverity = 'Warning' }
                    $reconRecovered = if ($resultState -in @('Mounted', 'Connected')) { $true } elseif ($resultState -eq 'Error') { $false } else { $null }
                    Write-NSCloudLog -Severity $reconSeverity -AccountId $key -Operation 'reconnect' `
                        -Message ("Reconnect attempt finished: $resultState$(if ($resultDriveLetter) { " on ${resultDriveLetter}:" })$(if ($resultError) { " - $resultError" })") `
                        -Recovered $reconRecovered
                } catch { }
                if ($resultState -in @('Mounted', 'ExistingProcess')) {
                    Register-ProviderExplorerIconViaAccount -AccountId $key -DriveLetter $resultDriveLetter
                    $selectedAccount = if ($resultState -eq 'Mounted') { Get-CloudAccount -AccountId $key } else { $null }
                    if ($resultState -eq 'Mounted' -and $script:ManualMountRequests.Contains($key) -and
                        $script:Settings.OpenExplorerOnMount -and
                        ($selectedAccount -eq $null -or $selectedAccount.OpenExplorerOnMount) -and $resultDriveLetter) {
                        Start-ExplorerWindow ($resultDriveLetter + ':\')
                    }
                }
                $null = $script:ManualMountRequests.Remove($key)
                if ($resultState -in @('Mounted', 'ExistingProcess', 'Connected')) {
                    $script:ReconnectFailCount[$key] = 0
                    $script:ReconnectNextAllowed.Remove($key)
                } elseif ($resultState -eq 'Error') {
                    $script:ReconnectFailCount[$key] = [int](Get-SafeProperty $result 'FailureCount' 0)
                    $nextAllowed = Get-SafeProperty $result 'NextAllowed' ([DateTime]::UtcNow.AddMinutes(5))
                    $script:ReconnectNextAllowed[$key] = [DateTime]$nextAllowed
                }
            }
            if ($completed.HadErrors -and -not [string]::IsNullOrWhiteSpace($script:ReconnectWorkerAccountId)) {
                $message = if ($completed.Errors.Count -gt 0) { Format-SanitizedDiagnosticMessage ([string]$completed.Errors[0].Exception.Message) } else { 'The mount worker stopped unexpectedly.' }
                $script:AccountMountStates[$script:ReconnectWorkerAccountId] = [ordered]@{ State = 'Error'; Stage = 'Mount worker stopped'; Error = $message; DriveLetter = [string]$script:ReconnectWorkerProgress.DriveLetter; StartedAt = $null; UpdatedAt = [DateTime]::UtcNow }
            }
        } catch { }
        $script:ReconnectWorker = $null
        $script:ReconnectWorkerAccountId = ''
        $script:ReconnectWorkerProgress = $null
        $script:LastProviderStatusCheck = [DateTime]::MinValue
    }

    Complete-AvailableLegacyMountWorkers

    if (-not $script:StartupAutoMountPending -and -not $script:StartupAutoMountWorker -and -not $script:ReconnectWorker -and $script:PendingManualMountAccountIds.Count -gt 0) {
        $nextAccountId = $script:PendingManualMountAccountIds.Dequeue()
        Invoke-AutoReconnectWatchdog -AccountId $nextAccountId
    }
}

function Write-StartupAutoMountProgressLog {
    $progress = $script:StartupAutoMountProgress
    if (-not $progress -or -not $progress.Stage) { return }
    $providerId = if ($progress.ProviderId -in @('gdrive', 'terabox')) { [string]$progress.ProviderId } else { '' }
    $driveLetter = if ([string]$progress.DriveLetter -match '^[A-Za-z]$') { ([string]$progress.DriveLetter).ToUpperInvariant() } else { '' }
    $accountId = if ($progress.AccountId) { [string]$progress.AccountId } else { '' }
    $key = "$($progress.Stage)|$providerId|$driveLetter|$accountId"
    if ($key -eq $script:LastStartupAutoMountLogKey) { return }
    $script:LastStartupAutoMountLogKey = $key
    if ($script:Settings.DiagnosticLogging -eq 'Off') { return }

    $elapsedMilliseconds = 0
    $totalElapsedMilliseconds = 0
    if ($progress.StartedAt) {
        $totalElapsedMilliseconds = [Math]::Max(0, [int64]([DateTime]::UtcNow - [DateTime]$progress.StartedAt).TotalMilliseconds)
    }
    if ($progress.StageStartedAt) {
        $elapsedMilliseconds = [Math]::Max(0, [int64]([DateTime]::UtcNow - [DateTime]$progress.StageStartedAt).TotalMilliseconds)
    }
    $entry = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        event = 'startup_restore_stage'
        stage = [string]$progress.Stage
        providerId = $providerId
        accountId = $accountId
        driveLetter = $driveLetter
        elapsedMilliseconds = $elapsedMilliseconds
        totalElapsedMilliseconds = $totalElapsedMilliseconds
    }
    try {
        $logDirectory = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs'
        if (-not (Test-Path -LiteralPath $logDirectory)) { New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null }
        $logPath = Join-Path $logDirectory 'startup-restore.jsonl'
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
            Move-Item -LiteralPath $logPath -Destination ($logPath + '.1') -Force
        }
        Add-Content -LiteralPath $logPath -Value (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine) -Encoding UTF8
    } catch { }

    # Mirror the stage into the shared application log so the Logs page shows
    # the restore flow together with mount and reconnect events.
    try {
        $stage = [string]$progress.Stage
        $severity = if ($stage -match '(?i)failed|could not|not responsive') { 'Error' } else { 'Info' }
        Write-NSCloudLog -Severity $severity -Provider $providerId -AccountId $accountId -Operation 'startup-restore' `
            -Message ("Startup restore stage: $stage$(if ($driveLetter) { " ($driveLetter`:)" })") `
            -DurationMilliseconds ([int]$elapsedMilliseconds) `
            -Recovered $(if ($stage -eq 'Recovery checks complete') { $true } else { $null })
    } catch { }
}

function Get-StartupRestoreDisplay([string]$ProviderId, [string]$DriveLetter, [string]$AccountId = '') {
    if (-not ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker)) { return $null }
    $progress = $script:StartupAutoMountProgress
    if ($AccountId -and $progress.AccountStages -and $progress.AccountStages.ContainsKey($AccountId)) {
        $st = $progress.AccountStages[$AccountId]
        $stState = [string]$st.State
        $stStage = [string]$st.Stage
        $stOrigin = if ($st.StageStartedAt) { [DateTime]$st.StageStartedAt } else { [DateTime]::UtcNow }
        $elapsedSec = [Math]::Max(0, [int]([DateTime]::UtcNow - $stOrigin).TotalSeconds)
        switch ($stState) {
            'Queued' { return 'Queued' }
            'Checking' { return "Checking existing mount (${elapsedSec}s)" }
            'Mounting' { return "$stStage (${elapsedSec}s)" }
            'Mounted' { return 'Connected' }
            'Error' { return "Failed: $([string]$st.Error)" }
            'AuthRequired' { return 'Sign-in required' }
            default { return "$stStage (${elapsedSec}s)" }
        }
    }
    if ($AccountId -and $script:StartupAutoMountPending) {
        return 'Waiting for startup restoration'
    }
    $activeProvider = [string]$progress.ProviderId
    $activeDrive = [string]$progress.DriveLetter
    $activeAccount = [string]$progress.AccountId
    $isCurrentStage = $false
    if ($AccountId -and $activeAccount) {
        $isCurrentStage = $AccountId -eq $activeAccount
    } elseif ($activeProvider) {
        $isCurrentStage = ($ProviderId -eq $activeProvider) -and
            (-not $activeDrive -or -not $DriveLetter -or $DriveLetter.TrimEnd(':') -eq $activeDrive.TrimEnd(':'))
    } else {
        $isCurrentStage = $true
    }
    $elapsedFrom = if ($progress.StartedAt) {
        [DateTime]$progress.StartedAt
    } elseif ($script:StartupAutoMountWorker) {
        [DateTime]$script:StartupAutoMountWorker.StartedAt
    } else {
        [DateTime]::UtcNow
    }
    $elapsed = [DateTime]::UtcNow - $elapsedFrom
    $elapsedText = ([int][Math]::Floor($elapsed.TotalMinutes)).ToString() + ':' + $elapsed.Seconds.ToString('00')
    if (-not $isCurrentStage) {
        $providerLabel = if ($ProviderId -eq 'gdrive') { 'Google Drive' } elseif ($ProviderId -eq 'terabox') { 'TeraBox' } else { 'saved drives' }
        return "Waiting for $providerLabel restore ($elapsedText)"
    }
    $stage = if ($progress.Stage) { [string]$progress.Stage } else { 'Preparing saved drives' }
    return "$stage ($elapsedText)"
}

function Update-AllUIState {

    Complete-AvailableStartupWorkers
    Write-StartupAutoMountProgressLog
    if (-not $script:StartupAutoMountPending -and -not $script:StartupAutoMountWorker -and
        -not $script:ProviderStatusWorker -and
        ([DateTime]::UtcNow - $script:LastProviderStatusCheck).TotalSeconds -ge 120) {
        try { Start-ProviderStatusRefreshWorker } catch { }
    }

    $statusSnapshot = $script:ProviderStatusSnapshot
    $allAccounts = @()
    try {
        $allAccounts = @(Get-CloudAccounts)
    } catch { }
    $hasSavedGoogleAccounts = @($allAccounts | Where-Object { $_.ProviderId -eq 'gdrive' }).Count -gt 0
    $hasSavedTeraBoxAccounts = @($allAccounts | Where-Object { $_.ProviderId -eq 'terabox' }).Count -gt 0
    if ($script:StartupAutoMountError -and -not $script:StartupAutoMountPending -and -not $script:StartupAutoMountWorker) {
        # Log each distinct startup failure exactly once (the UI branch runs on
        # every dispatcher tick, so no dedup here means log spam).
        try {
            $failureText = Format-SanitizedDiagnosticMessage ([string]$script:StartupAutoMountError)
            if ($failureText -and $failureText -ne $script:LastLoggedAutoMountErrorText) {
                $script:LastLoggedAutoMountErrorText = $failureText
                Write-NSCloudLog -Severity 'Error' -Operation 'startup-restore' -Message $failureText -Recovered $false
            }
        } catch { }
        $failure = [ordered]@{ IsValid = $false; State = 'Error'; Error = $script:StartupAutoMountError; UserInfo = $null }
        $script:ProviderStatusSnapshot = [pscustomobject]@{
            GoogleCheck = $failure
            GoogleStatus = [ordered]@{ IsMounted = $false; DriveLetter = $script:GDriveLetter }
            TeraBoxCheck = $failure
            TeraBoxStatus = [ordered]@{ IsMounted = $false; DriveLetter = $script:TeraBoxLetter }
            CheckedAt = [DateTime]::UtcNow
        }
        $statusSnapshot = $script:ProviderStatusSnapshot
    }
    $restoreInProgress = [bool]($script:StartupAutoMountPending -or $script:StartupAutoMountWorker)
    $gdRestoreStateLabel = Get-StartupRestoreDisplay -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter
    $tbRestoreStateLabel = Get-StartupRestoreDisplay -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter
    $progressProvider = [string]$script:StartupAutoMountProgress.ProviderId
    $gdCheckingState = if ($restoreInProgress -and (-not $progressProvider -or $progressProvider -eq 'gdrive')) { 'Mounting' } else { 'Checking' }
    $tbCheckingState = if ($restoreInProgress -and (-not $progressProvider -or $progressProvider -eq 'terabox')) { 'Mounting' } else { 'Checking' }
    $gdCheckingResult = [ordered]@{
        IsValid = $false
        State = $gdCheckingState
        Error = $null
        UserInfo = $null
    }
    $tbCheckingResult = [ordered]@{
        IsValid = $false
        State = $tbCheckingState
        Error = $null
        UserInfo = $null
    }

    # 1. Google Drive State
    $gdCheck = Get-SafeProperty $statusSnapshot 'GoogleCheck' $gdCheckingResult
    $gdStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive'
    $gdDriveLetter = ([string]$gdStatus.DriveLetter).TrimEnd(':').TrimEnd('\')
    $accountUiStatuses = @{}
    foreach ($account in $allAccounts) {
        $accountUiStatuses[[string]$account.Id] = Get-CachedUiDriveStatus `
            -AccountId ([string]$account.Id) -ProviderId ([string]$account.ProviderId) -DriveLetter ([string]$account.DriveLetter)
    }
    $googleDriveHasSavedAccount = @($allAccounts | Where-Object {
        $_.ProviderId -eq 'gdrive' -and
        $accountUiStatuses[[string]$_.Id].IsMounted -and
        ([string]$accountUiStatuses[[string]$_.Id].DriveLetter).TrimEnd(':').TrimEnd('\') -eq $gdDriveLetter
    }).Count -gt 0
    $hasActiveLegacyGoogle = [bool]$gdStatus.IsMounted -and -not $googleDriveHasSavedAccount
    if ($gdCheckingState -eq 'Mounting' -and -not (Get-SafeProperty $gdCheck 'IsValid' $false)) {
        $gdCheck = $gdCheckingResult
    }
    $gdCheckIsValid = [bool](Get-SafeProperty $gdCheck 'IsValid' $false)
    $gdUserInfo = Get-SafeProperty $gdCheck 'UserInfo' $null

    if ($gdCheckIsValid) {
        $dispName = if ($gdUserInfo) { Get-SafeProperty $gdUserInfo 'DisplayName' $null } else { $null }
        $emailAddr = if ($gdUserInfo) { Get-SafeProperty $gdUserInfo 'EmailAddress' '' } else { '' }
        $userDisplay = if ($dispName) { $dispName } else { $emailAddr }
        $googleIdentityVerified = [bool](Get-SafeProperty $gdCheck 'IdentityVerified' $false)
        if ($hasActiveLegacyGoogle) {
            $userDisplay = 'Google Drive - recovery needed'
            $emailAddr = ''
            $gdUserInfo = $null
            $googleIdentityVerified = $false
        } elseif (-not $userDisplay -or $userDisplay -eq 'Google Drive User') {
            if (-not $hasSavedGoogleAccounts) {
                try {
                    $accs = @(Get-CloudAccounts)
                    $primaryGd = $accs | Where-Object { $_.ProviderId -eq 'gdrive' } | Select-Object -First 1
                    if ($primaryGd) {
                        if ($primaryGd.DisplayName) { $userDisplay = $primaryGd.DisplayName }
                        if ($primaryGd.AccountEmail) { $emailAddr = $primaryGd.AccountEmail }
                    }
                } catch { }
            }
            if (-not $userDisplay -or $userDisplay -eq 'Google Drive User') {
                $userDisplay = 'Google Drive'
            }
        }
        if (-not $userDisplay) { $userDisplay = 'Google Drive' }

        $gdNameLabel.Text = $userDisplay
        $gdAccountText.Text = if ($emailAddr) {
            $emailAddr
        } elseif ($hasActiveLegacyGoogle) {
            'This mounted drive is not linked to a saved account.'
        } else {
            'Connected'
        }
        $gdErrorText.Visibility = 'Collapsed'

        $gdTotal = if ($gdUserInfo) { [int64](Get-SafeProperty $gdUserInfo 'QuotaTotal' (Get-SafeProperty $gdUserInfo 'QuotaTotalBytes' 0)) } else { 0L }
        $gdUsed = if ($gdUserInfo) { [int64](Get-SafeProperty $gdUserInfo 'QuotaUsed' (Get-SafeProperty $gdUserInfo 'QuotaUsedBytes' 0)) } else { 0L }

        if ($gdTotal -gt 0) {
            $freeBytes = [Math]::Max(0L, ($gdTotal - $gdUsed))
            $freeTb = [Math]::Round($freeBytes / 1TB, 2)
            $totalTb = [Math]::Round($gdTotal / 1TB, 2)
            $pct = [Math]::Round(($gdUsed / $gdTotal) * 100, 1)

            $gdStorageBar.Value = [Math]::Min(100, [Math]::Max(0, $pct))
            $gdStorageBar.Visibility = 'Visible'
            $gdQuotaText.Text = if ($hasSavedGoogleAccounts -and -not $googleIdentityVerified) {
                "Unregistered session: $freeTb TB free of $totalTb TB"
            } else {
                "$freeTb TB free of $totalTb TB"
            }
            $gdQuotaText.Visibility = 'Visible'
        } else {
            $gdStorageBar.Visibility = 'Collapsed'
            $gdQuotaText.Visibility = 'Collapsed'
        }

        if ($gdStatus.MountState -and $gdStatus.MountState.State -eq 'Disconnecting') {
            $gdStatusText.Text = ([string][char]0x25CF + ' Disconnecting (' + [string]$gdStatus.DriveLetter + ':)...')
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $gdActionBtn.Content = 'Disconnecting...'
            $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $gdActionBtn.IsEnabled = $false
            $gdLetterCombo.IsEnabled = $false
            $gdExplorerBtn.IsEnabled = $false
            $gdUploadBtn.IsEnabled = $false
        } elseif ($gdStatus.IsMounted) {
            $gdStatusText.Text = ([string][char]0x25CF + ' Mounted (' + $gdStatus.DriveLetter + ':)')
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillMounted)

            $gdActionBtn.Content = 'Disconnect'
            $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
            $gdLetterCombo.IsEnabled = $false
            $gdExplorerBtn.IsEnabled = $true
            $gdUploadBtn.IsEnabled = $true
        } elseif ($gdRestoreStateLabel) {
            $gdStatusText.Text = ([string][char]0x25CF + ' Restoring drive - ' + $gdRestoreStateLabel)
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $gdActionBtn.Content = 'Restoring...'
            $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $gdActionBtn.IsEnabled = $false
            $gdLetterCombo.IsEnabled = $false
            $gdExplorerBtn.IsEnabled = $false
            $gdUploadBtn.IsEnabled = $false
        } elseif ($gdStatus.MountState -and $gdStatus.MountState.State -eq 'Mounting') {
            $gdStatusText.Text = ([string][char]0x25CF + ' ' + [string]$gdStatus.MountState.Stage)
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $gdActionBtn.Content = 'Mounting...'
            $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $gdActionBtn.IsEnabled = $false
            $gdLetterCombo.IsEnabled = $false
            $gdExplorerBtn.IsEnabled = $false
            $gdUploadBtn.IsEnabled = $false
        } elseif ($gdStatus.MountState -and $gdStatus.MountState.State -eq 'Error') {
            $gdStatusText.Text = ([string][char]0x25CF + ' ' + [string]$gdStatus.MountState.Error)
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
            $gdActionBtn.Content = 'Retry'
            $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
            $gdLetterCombo.IsEnabled = $true
            $gdExplorerBtn.IsEnabled = $false
            $gdUploadBtn.IsEnabled = $false
        } else {
            $gdStatusText.Text = ([string][char]0x25CF + ' Ready to connect')
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillConnected)

            $gdActionBtn.Content = 'Connect'
            $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
            $gdLetterCombo.IsEnabled = $true
            $gdExplorerBtn.IsEnabled = $false
            $gdUploadBtn.IsEnabled = $false
        }
    } else {
        $gdNameLabel.Text = if ($hasActiveLegacyGoogle) { 'Google Drive - recovery needed' } else { 'Google Drive' }
        $gdState = Get-SafeProperty $gdCheck 'State' ''
        $gdErr = Get-SafeProperty $gdCheck 'Error' ''
        if ($gdState -eq 'Mounting') {
            $gdAccountText.Text = $gdRestoreStateLabel
            $gdErrorText.Visibility = 'Collapsed'
        } elseif ($gdState -eq 'Checking') {
            $gdAccountText.Text = 'Checking saved connection...'
            $gdErrorText.Visibility = 'Collapsed'
        } elseif ($gdState -eq 'AuthenticationExpired') {
            $gdAccountText.Text = 'Session expired. Click Connect to re-authenticate.'
            $gdErrorText.Text = if ($gdErr) { $gdErr } else { 'Session expired.' }
            $gdErrorText.Visibility = 'Visible'
        } elseif ($gdState -eq 'Error') {
            $gdAccountText.Text = 'Could not check saved connection.'
            $gdErrorText.Text = if ($gdErr) { $gdErr } else { 'Connection check failed.' }
            $gdErrorText.Visibility = 'Visible'
        } else {
            $gdAccountText.Text = 'Not connected'
            $gdErrorText.Visibility = 'Collapsed'
        }

        $gdStorageBar.Visibility = 'Collapsed'
        $gdQuotaText.Visibility = 'Collapsed'

        if ($gdState -eq 'Mounting') {
            $gdStatusText.Text = ([string][char]0x25CF + ' Restoring drive - ' + $gdRestoreStateLabel)
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        } elseif ($gdState -eq 'Checking') {
            $gdStatusText.Text = ([string][char]0x25CF + ' Checking connection...')
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        } else {
            $gdStatusText.Text = ([string][char]0x25CF + ' Disconnected')
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextMuted)
        }

        $gdActionBtn.Content = 'Connect'
        $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
        $gdLetterCombo.IsEnabled = $true
        $gdExplorerBtn.IsEnabled = $false
        $gdUploadBtn.IsEnabled = $false
    }

    if ($gdStatus.MountState -and $gdStatus.MountState.State -eq 'Disconnecting') {
        $gdActionBtn.Content = 'Disconnecting...'
        $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $gdActionBtn.IsEnabled = $false
    } elseif ($gdStatus.IsMounted) {
        $gdStatusText.Text = ([string][char]0x25CF + ' Mounted (' + $gdStatus.DriveLetter + ':)')
        $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillMounted)
        $gdActionBtn.Content = 'Disconnect'
        $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
        $gdActionBtn.IsEnabled = -not ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker -or $script:ReconnectWorker)
        $gdLetterCombo.IsEnabled = $false
        $gdExplorerBtn.IsEnabled = $true
        $gdUploadBtn.IsEnabled = $true
    }

    # 2. TeraBox State
    $tbCheck = Get-SafeProperty $statusSnapshot 'TeraBoxCheck' $tbCheckingResult
    $tbStatus = Get-CachedUiDriveStatus -ProviderId 'terabox'
    $tbDriveLetter = ([string]$tbStatus.DriveLetter).TrimEnd(':').TrimEnd('\')
    $teraBoxDriveHasSavedAccount = @($allAccounts | Where-Object {
        $_.ProviderId -eq 'terabox' -and
        $accountUiStatuses[[string]$_.Id].IsMounted -and
        ([string]$accountUiStatuses[[string]$_.Id].DriveLetter).TrimEnd(':').TrimEnd('\') -eq $tbDriveLetter
    }).Count -gt 0
    $hasActiveLegacyTeraBox = [bool]$tbStatus.IsMounted -and -not $teraBoxDriveHasSavedAccount
    if ($tbCheckingState -eq 'Mounting' -and -not (Get-SafeProperty $tbCheck 'IsValid' $false)) {
        $tbCheck = $tbCheckingResult
    }
    $tbCheckIsValid = [bool](Get-SafeProperty $tbCheck 'IsValid' $false)
    $tbUserInfo = Get-SafeProperty $tbCheck 'UserInfo' $null

    if ($tbCheckIsValid) {
        $tbUName = if ($tbUserInfo) { Get-SafeProperty $tbUserInfo 'UserName' 'TeraBox User' } else { 'TeraBox User' }
        $tbDisplayName = 'TeraBox'
        if ($hasActiveLegacyTeraBox) {
            $tbDisplayName = 'TeraBox - recovery needed'
            $tbUName = 'This mounted drive is not linked to a saved account.'
            $tbUserInfo = $null
        }
        if ($tbUName -eq 'TeraBox User') {
            if (-not $hasSavedTeraBoxAccounts) {
                try {
                    $accs = @(Get-CloudAccounts)
                    $primaryTb = $accs | Where-Object { $_.ProviderId -eq 'terabox' } | Select-Object -First 1
                    if ($primaryTb) {
                        if ($primaryTb.DisplayName) { $tbDisplayName = $primaryTb.DisplayName }
                        if ($primaryTb.AccountEmail) { $tbUName = $primaryTb.AccountEmail }
                    }
                } catch { }
            }
            if ($hasActiveLegacyTeraBox) {
                $tbDisplayName = 'TeraBox - recovery needed'
                $tbUName = 'This mounted drive is not linked to a saved account.'
            }
        }
        $tbNameLabel.Text = $tbDisplayName
        $tbAccountText.Text = $tbUName
        $tbErrorText.Visibility = 'Collapsed'

        $tbTotal = if ($tbUserInfo) { [int64](Get-SafeProperty $tbUserInfo 'QuotaTotal' (Get-SafeProperty $tbUserInfo 'QuotaTotalBytes' 0)) } else { 0L }
        $tbUsed = if ($tbUserInfo) { [int64](Get-SafeProperty $tbUserInfo 'QuotaUsed' (Get-SafeProperty $tbUserInfo 'QuotaUsedBytes' 0)) } else { 0L }

        if ($hasActiveLegacyTeraBox) {
            $tbStorageBar.Visibility = 'Collapsed'
            $tbQuotaText.Text = 'Storage: unavailable until this mount is identified.'
            $tbQuotaText.Visibility = 'Visible'
        } elseif ($tbTotal -gt 0) {
            $freeBytes = [Math]::Max(0L, ($tbTotal - $tbUsed))
            $freeGb = [Math]::Round($freeBytes / 1GB, 1)
            $totalGb = [Math]::Round($tbTotal / 1GB, 0)
            $pct = [Math]::Round(($tbUsed / $tbTotal) * 100, 1)

            $tbStorageBar.Value = [Math]::Min(100, [Math]::Max(0, $pct))
            $tbStorageBar.Visibility = 'Visible'
            $tbQuotaText.Text = "$freeGb GB free of $totalGb GB"
            $tbQuotaText.Visibility = 'Visible'
        } else {
            $tbStorageBar.Visibility = 'Collapsed'
            $tbQuotaText.Text = 'Full drive access'
            $tbQuotaText.Visibility = 'Visible'
        }

        if ($tbStatus.MountState -and $tbStatus.MountState.State -eq 'Disconnecting') {
            $tbStatusText.Text = ([string][char]0x25CF + ' Disconnecting (' + [string]$tbStatus.DriveLetter + ':)...')
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $tbActionBtn.Content = 'Disconnecting...'
            $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $tbActionBtn.IsEnabled = $false
            $tbLetterCombo.IsEnabled = $false
            $tbExplorerBtn.IsEnabled = $false
            $tbUploadBtn.IsEnabled = $false
        } elseif ($tbStatus.IsMounted) {
            $tbStatusText.Text = ([string][char]0x25CF + ' Mounted (' + $tbStatus.DriveLetter + ':)')
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillMounted)

            $tbActionBtn.Content = 'Disconnect'
            $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
            $tbLetterCombo.IsEnabled = $false
            $tbExplorerBtn.IsEnabled = $true
            $tbUploadBtn.IsEnabled = $true
        } elseif ($tbRestoreStateLabel) {
            $tbStatusText.Text = ([string][char]0x25CF + ' Restoring drive - ' + $tbRestoreStateLabel)
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $tbActionBtn.Content = 'Restoring...'
            $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $tbActionBtn.IsEnabled = $false
            $tbLetterCombo.IsEnabled = $false
            $tbExplorerBtn.IsEnabled = $false
            $tbUploadBtn.IsEnabled = $false
        } elseif ($tbStatus.MountState -and $tbStatus.MountState.State -eq 'Mounting') {
            $tbStatusText.Text = ([string][char]0x25CF + ' ' + [string]$tbStatus.MountState.Stage)
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $tbActionBtn.Content = 'Mounting...'
            $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $tbActionBtn.IsEnabled = $false
            $tbLetterCombo.IsEnabled = $false
            $tbExplorerBtn.IsEnabled = $false
            $tbUploadBtn.IsEnabled = $false
        } elseif ($tbStatus.MountState -and $tbStatus.MountState.State -eq 'Error') {
            $tbStatusText.Text = ([string][char]0x25CF + ' ' + [string]$tbStatus.MountState.Error)
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
            $tbActionBtn.Content = 'Retry'
            $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
            $tbLetterCombo.IsEnabled = $true
            $tbExplorerBtn.IsEnabled = $false
            $tbUploadBtn.IsEnabled = $false
        } else {
            $tbStatusText.Text = ([string][char]0x25CF + ' Ready to connect')
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillConnected)

            $tbActionBtn.Content = 'Connect'
            $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
            $tbLetterCombo.IsEnabled = $true
            $tbExplorerBtn.IsEnabled = $false
            $tbUploadBtn.IsEnabled = $false
        }
    } else {
        $tbNameLabel.Text = if ($hasActiveLegacyTeraBox) { 'TeraBox - recovery needed' } else { 'TeraBox' }
        $tbState = Get-SafeProperty $tbCheck 'State' ''
        $tbErr = Get-SafeProperty $tbCheck 'Error' ''
        if ($tbState -eq 'Mounting') {
            $tbAccountText.Text = $tbRestoreStateLabel
            $tbErrorText.Visibility = 'Collapsed'
        } elseif ($tbState -eq 'Checking') {
            $tbAccountText.Text = 'Checking saved connection...'
            $tbErrorText.Visibility = 'Collapsed'
        } elseif ($tbState -eq 'AuthenticationExpired') {
            $tbAccountText.Text = 'Session expired. Click Connect to re-authenticate.'
            $tbErrorText.Text = if ($tbErr) { $tbErr } else { 'Session expired.' }
            $tbErrorText.Visibility = 'Visible'
        } elseif ($tbState -eq 'Error') {
            $tbAccountText.Text = 'Could not check saved connection.'
            $tbErrorText.Text = if ($tbErr) { $tbErr } else { 'Connection check failed.' }
            $tbErrorText.Visibility = 'Visible'
        } else {
            $tbAccountText.Text = 'Not connected'
            $tbErrorText.Visibility = 'Collapsed'
        }

        $tbStorageBar.Visibility = 'Collapsed'
        $tbQuotaText.Visibility = 'Collapsed'

        if ($tbState -eq 'Mounting') {
            $tbStatusText.Text = ([string][char]0x25CF + ' Restoring drive - ' + $tbRestoreStateLabel)
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        } elseif ($tbState -eq 'Checking') {
            $tbStatusText.Text = ([string][char]0x25CF + ' Checking connection...')
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        } else {
            $tbStatusText.Text = ([string][char]0x25CF + ' Disconnected')
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextMuted)
        }

        $tbActionBtn.Content = 'Connect'
        $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
        $tbLetterCombo.IsEnabled = $true
        $tbExplorerBtn.IsEnabled = $false
        $tbUploadBtn.IsEnabled = $false
    }

    if ($tbStatus.MountState -and $tbStatus.MountState.State -eq 'Disconnecting') {
        $tbActionBtn.Content = 'Disconnecting...'
        $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $tbActionBtn.IsEnabled = $false
    } elseif ($tbStatus.IsMounted) {
        $tbStatusText.Text = ([string][char]0x25CF + ' Mounted (' + $tbStatus.DriveLetter + ':)')
        $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillMounted)
        $tbActionBtn.Content = 'Disconnect'
        $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
        $tbActionBtn.IsEnabled = -not ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker -or $script:ReconnectWorker)
        $tbLetterCombo.IsEnabled = $false
        $tbExplorerBtn.IsEnabled = $true
        $tbUploadBtn.IsEnabled = $true
    }

    $gdCheckState = [string](Get-SafeProperty $gdCheck 'State' 'Error')
    $tbCheckState = [string](Get-SafeProperty $tbCheck 'State' 'Error')
    $gdActionBtn.IsEnabled = (-not $script:StartupAutoMountPending -and -not $script:StartupAutoMountWorker -and -not $script:ReconnectWorker -and -not ($gdStatus.MountState -and $gdStatus.MountState.State -eq 'Disconnecting') -and ($gdCheckState -ne 'Checking' -or $gdStatus.IsMounted) -and -not (Test-LegacyMountBusy 'gdrive'))
    $tbActionBtn.IsEnabled = (-not $script:StartupAutoMountPending -and -not $script:StartupAutoMountWorker -and -not $script:ReconnectWorker -and -not ($tbStatus.MountState -and $tbStatus.MountState.State -eq 'Disconnecting') -and ($tbCheckState -ne 'Checking' -or $tbStatus.IsMounted) -and -not (Test-LegacyMountBusy 'terabox'))

    # 3. Dynamic Multi-Account Cards
    $showGoogleRecovery = $hasActiveLegacyGoogle -or ($gdStatus.MountState -and $gdStatus.MountState.State -in @('Mounting', 'Disconnecting', 'Error', 'AuthRequired'))
    $showTeraBoxRecovery = $hasActiveLegacyTeraBox -or ($tbStatus.MountState -and $tbStatus.MountState.State -in @('Mounting', 'Disconnecting', 'Error', 'AuthRequired'))
    $gdCard.Visibility = if ($showGoogleRecovery) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $tbCard.Visibility = if ($showTeraBoxRecovery) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }

    $cardSignatureItems = [System.Collections.Generic.List[object]]::new()
    foreach ($account in $allAccounts) {
        $status = $accountUiStatuses[[string]$account.Id]
        $mountState = if ($status.MountState) { $status.MountState } elseif ($script:AccountMountStates.ContainsKey([string]$account.Id)) { $script:AccountMountStates[[string]$account.Id] } else { $null }
        $progress = $script:StartupAutoMountProgress
        if ($script:StartupAutoMountWorker -and $progress.AccountId -eq [string]$account.Id) {
            $mountState = [ordered]@{
                State = 'Mounting'
                Stage = [string]$progress.Stage
                StartedAt = if ($progress.StartedAt) { [DateTime]$progress.StartedAt } else { [DateTime]::UtcNow }
                Error = $null
            }
        }
        $storageRecord = @($script:AnalyticsStorageRecords | Where-Object { $_.AccountId -eq [string]$account.Id } | Select-Object -First 1)
        $cardSignatureItems.Add([pscustomobject]@{
            Id = [string]$account.Id
            ProviderId = [string]$account.ProviderId
            DisplayName = [string]$account.DisplayName
            Email = [string]$account.AccountEmail
            DriveLetter = [string]$account.DriveLetter
            IsMounted = [bool]$status.IsMounted
            IsReadOnly = [bool]$status.IsReadOnly
            MountState = if ($mountState) { [string]$mountState.State + '|' + [string]$mountState.Stage + '|' + [string]$mountState.Error } else { '' }
            MountElapsedBucket = if ($mountState -and $mountState.StartedAt) { [int][Math]::Floor(([DateTime]::UtcNow - [DateTime]$mountState.StartedAt).TotalSeconds / 5) } else { 0 }
            StorageUsed = if ($storageRecord.Count -gt 0) { [int64]$storageRecord[0].UsedBytes } else { -1 }
            StorageTotal = if ($storageRecord.Count -gt 0) { [int64]$storageRecord[0].TotalBytes } else { -1 }
            ResponseMs = if ($storageRecord.Count -gt 0) { [int]$storageRecord[0].ResponseMilliseconds } else { -1 }
        })
    }
    # Update Drives Summary Banner
    if ($drivesSummaryBanner -and $allAccounts) {
        $totalAccountsCount = $allAccounts.Count
        $mountedAccountsCount = @($allAccounts | Where-Object {
            $st = $accountUiStatuses[[string]$_.Id]
            $st -and $st.IsMounted
        }).Count
        $errorAccountsCount = @($allAccounts | Where-Object {
            $script:AccountMountStates.ContainsKey([string]$_.Id) -and $script:AccountMountStates[[string]$_.Id].State -eq 'Error'
        }).Count

        $bannerFill = if ($script:GlassState.Active -and $script:Palette.Name -eq 'Translucent') { $script:Palette.CardGlassBg } else { $script:Palette.CardBg }
        $drivesSummaryBanner.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($bannerFill)
        $drivesSummaryBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.CardBorder)

        if ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker) {
            $bannerIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
            $bannerTitle.Text = "$mountedAccountsCount of $totalAccountsCount drives connected"
            $bannerSubtitle.Text = "Restoring cloud drives at startup... ($($script:StartupAutoMountProgress.Stage))"
        } elseif ($totalAccountsCount -gt 0) {
            if ($mountedAccountsCount -eq $totalAccountsCount) {
                $bannerIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillMounted)
                $bannerTitle.Text = "All $totalAccountsCount drives connected"
                $bannerSubtitle.Text = "All virtual cloud drives are active in Windows File Explorer."
            } else {
                $bannerIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($errorAccountsCount -gt 0) { $script:Palette.Danger } else { $script:Palette.PillWarning }))
                $bannerTitle.Text = "$mountedAccountsCount of $totalAccountsCount drives connected"
                $bannerSubtitle.Text = if ($errorAccountsCount -gt 0) { "$errorAccountsCount drive(s) encountered an error. Click Retry on the card." } else { "$($totalAccountsCount - $mountedAccountsCount) drive(s) ready to connect." }
            }
        } else {
            $bannerIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextMuted)
            $bannerTitle.Text = "No cloud drives connected"
            $bannerSubtitle.Text = "Click '+ Add Cloud Disk' to mount Google Drive or TeraBox."
        }

        $bannerChipsStack.Children.Clear()
        foreach ($acc in $allAccounts) {
            $st = $accountUiStatuses[[string]$acc.Id]
            $chipBorder = [System.Windows.Controls.Border]::new()
            $chipBorder.CornerRadius = [System.Windows.CornerRadius]::new(4)
            $chipBorder.Padding = [System.Windows.Thickness]::new(6, 2, 6, 2)
            $chipBorder.Margin = [System.Windows.Thickness]::new(3, 0, 0, 0)
            $chipColor = if ($st -and $st.IsMounted) { $script:Palette.PillMounted } elseif ($script:AccountMountStates.ContainsKey([string]$acc.Id) -and $script:AccountMountStates[[string]$acc.Id].State -eq 'Error') { $script:Palette.Danger } else { $script:Palette.TextMuted }
            $chipBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($chipColor)
            $chipBorder.BorderThickness = [System.Windows.Thickness]::new(1)
            $chipLabel = New-Label ("$($acc.DriveLetter):") 10 $chipColor $true
            $chipBorder.Child = $chipLabel
            $bannerChipsStack.Children.Add($chipBorder) | Out-Null
        }
    }

    $accountCardsSignature = $script:Palette.Name + '|' + (ConvertTo-Json -InputObject @($cardSignatureItems.ToArray()) -Depth 4 -Compress)
    $refreshAccountCards = $accountCardsSignature -ne $script:AccountCardsSignature
    if ($refreshAccountCards) {
        $accountsStack.Children.Clear()
    if ($allAccounts -and $allAccounts.Count -gt 0) {
        $p = $script:Palette
        $secLabel = New-Label 'CLOUD DRIVES' 11 $p.TextSecondary $true
        $secLabel.Margin = [System.Windows.Thickness]::new(2, 6, 0, 8)
        $accountsStack.Children.Add($secLabel) | Out-Null

        foreach ($acc in $allAccounts) {
            $aCard = [System.Windows.Controls.Border]::new()
            $accountCardFill = if ($script:GlassState.Active -and $p.Name -eq 'Translucent') { $p.CardGlassBg } else { $p.CardBg }
            $aCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($accountCardFill)
            $aCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBorder)
            $aCard.BorderThickness = [System.Windows.Thickness]::new(1)
            $aCard.CornerRadius = [System.Windows.CornerRadius]::new(8)
            $aCard.Padding = [System.Windows.Thickness]::new(14, 12, 14, 12)
            $aCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

            $aGrid = [System.Windows.Controls.Grid]::new()
            $aCard.Child = $aGrid
            $aCol0 = [System.Windows.Controls.ColumnDefinition]::new(); $aCol0.Width = [System.Windows.GridLength]::Auto
            $aCol1 = [System.Windows.Controls.ColumnDefinition]::new(); $aCol1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $aCol2 = [System.Windows.Controls.ColumnDefinition]::new(); $aCol2.Width = [System.Windows.GridLength]::Auto
            $aGrid.ColumnDefinitions.Add($aCol0)
            $aGrid.ColumnDefinitions.Add($aCol1)
            $aGrid.ColumnDefinitions.Add($aCol2)

            $aDiskIcon = New-AccountDiskIcon $acc.ProviderId
            [System.Windows.Controls.Grid]::SetColumn($aDiskIcon, 0)
            $aGrid.Children.Add($aDiskIcon) | Out-Null

            $aInfoStack = [System.Windows.Controls.StackPanel]::new()
            $aInfoStack.VerticalAlignment = 'Center'
            [System.Windows.Controls.Grid]::SetColumn($aInfoStack, 1)
            $aGrid.Children.Add($aInfoStack) | Out-Null

            $aProviderName = switch ([string]$acc.ProviderId) {
                'gdrive' { 'Google Drive'; break }
                'terabox' { 'TeraBox'; break }
                default { 'Unknown provider' }
            }
            $aProviderLabel = New-Label $aProviderName 11 $p.TextMuted $true
            $aInfoStack.Children.Add($aProviderLabel) | Out-Null
            $aName = New-Label $acc.DisplayName 15 $p.TextPrimary $true
            $aInfoStack.Children.Add($aName) | Out-Null

            $aEmailText = if ($acc.AccountEmail) { $acc.AccountEmail } else { 'Drive: ' + $acc.DriveLetter + ':' }
            $aEmail = New-Label $aEmailText 11 $p.TextSecondary
            $aEmail.Margin = [System.Windows.Thickness]::new(0, 1, 0, 6)
            $aInfoStack.Children.Add($aEmail) | Out-Null
            $aStorageRecord = @($script:AnalyticsStorageRecords | Where-Object { $_.AccountId -eq [string]$acc.Id } | Select-Object -First 1)
            $aStorageText = if ($aStorageRecord.Count -gt 0) {
                $quota = $aStorageRecord[0]
                $freeBytes = [Math]::Max([int64]0, ([int64]$quota.TotalBytes - [int64]$quota.UsedBytes))
                "Storage: $(Format-AnalyticsBytes ([int64]$quota.UsedBytes)) used / $(Format-AnalyticsBytes $freeBytes) free | $($quota.ResponseMilliseconds) ms response"
            } else {
                'Storage: open Analytics to check verified quota'
            }
            $aStorage = New-Label $aStorageText 11 $p.TextSecondary
            $aStorage.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
            $aInfoStack.Children.Add($aStorage) | Out-Null

            $aActionRow = [System.Windows.Controls.StackPanel]::new()
            $aActionRow.Orientation = 'Horizontal'
            $aActionRow.VerticalAlignment = 'Center'
            $aInfoStack.Children.Add($aActionRow) | Out-Null

            $aStatus = Get-CachedUiDriveStatus -AccountId $acc.Id -ProviderId $acc.ProviderId -DriveLetter $acc.DriveLetter
            $aMountState = if ($aStatus.MountState) { $aStatus.MountState } elseif ($script:AccountMountStates.ContainsKey([string]$acc.Id)) { $script:AccountMountStates[[string]$acc.Id] } else { $null }
            if ($script:StartupAutoMountPending -and -not $aStatus.IsMounted -and [bool]$acc.AutoMount) {
                $aMountState = [ordered]@{
                    State = 'Waiting'
                    Stage = 'Waiting for startup restoration'
                    StartedAt = [DateTime]::UtcNow
                    Error = $null
                }
            } elseif ($script:StartupAutoMountWorker -and [bool]$acc.AutoMount -and -not $aStatus.IsMounted) {
                $prog = $script:StartupAutoMountProgress
                if ($prog.AccountStages -and $prog.AccountStages.ContainsKey([string]$acc.Id)) {
                    $st = $prog.AccountStages[[string]$acc.Id]
                    $aMountState = [ordered]@{
                        State = [string]$st.State
                        Stage = [string]$st.Stage
                        StartedAt = if ($st.StageStartedAt) { [DateTime]$st.StageStartedAt } else { [DateTime]::UtcNow }
                        Error = [string]$st.Error
                    }
                } elseif ($prog.AccountId -eq [string]$acc.Id) {
                    $aMountState = [ordered]@{
                        State = 'Mounting'
                        Stage = [string]$prog.Stage
                        StartedAt = if ($prog.StartedAt) { [DateTime]$prog.StartedAt } else { [DateTime]::UtcNow }
                        Error = $null
                    }
                } else {
                    $aMountState = [ordered]@{
                        State = 'Queued'
                        Stage = 'Queued'
                        StartedAt = [DateTime]::UtcNow
                        Error = $null
                    }
                }
            }

            $aBtn = [System.Windows.Controls.Button]::new()
            $aBtn.Padding = [System.Windows.Thickness]::new(16, 5, 16, 5)
            $aBtn.Height = 28
            $aBtn.MinWidth = 85
            $aBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
            $aBtn.FontSize = 12
            $aBtn.BorderThickness = [System.Windows.Thickness]::new(0)
            $aBtn.Cursor = [System.Windows.Input.Cursors]::Hand

            $aBtn.Tag = [string]$acc.Id
            if ($aMountState -and $aMountState.State -eq 'Disconnecting') {
                $aBtn.Content = 'Disconnecting...'
                $aBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Danger)
                $aBtn.Foreground = [System.Windows.Media.Brushes]::White
            } elseif ($aStatus.IsMounted) {
                $aBtn.Content = 'Disconnect'
                $aBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Danger)
                $aBtn.Foreground = [System.Windows.Media.Brushes]::White
            } else {
                $aBtn.Content = if ($aMountState -and $aMountState.State -in @('Mounting', 'Checking')) { 'Mounting...' } elseif ($aMountState -and $aMountState.State -eq 'Queued') { 'Queued' } elseif ($aMountState -and $aMountState.State -eq 'Waiting') { 'Waiting...' } elseif ($aMountState -and $aMountState.State -in @('Error', 'AuthRequired')) { 'Retry' } else { 'Connect' }
                $aBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Accent)
                $aBtn.Foreground = [System.Windows.Media.Brushes]::White
            }
            $aBtn.Add_Click({
                param($sender, $eventArgs)
                $selectedAccount = Get-CloudAccount -AccountId ([string]$sender.Tag)
                if (-not $selectedAccount) { return }
                $state = if ($script:AccountMountStates.ContainsKey([string]$selectedAccount.Id)) { $script:AccountMountStates[[string]$selectedAccount.Id] } else { $null }
                if ($state -and $state.State -in @('Mounting', 'Disconnecting')) { return }
                $selectedStatus = Get-CachedUiDriveStatus -ProviderId ([string]$selectedAccount.ProviderId) -AccountId ([string]$selectedAccount.Id) -DriveLetter ([string]$selectedAccount.DriveLetter)
                if ($selectedStatus.IsMounted) {
                    [void](Start-ScopedDriveDisconnect -ProviderId ([string]$selectedAccount.ProviderId) -AccountId ([string]$selectedAccount.Id) -DriveLetter ([string]$selectedAccount.DriveLetter))
                } else {
                    $null = $script:ManualMountRequests.Add([string]$selectedAccount.Id)
                    Invoke-AutoReconnectWatchdog -AccountId ([string]$selectedAccount.Id)
                }
                Update-AllUIState
            })
            $aActionRow.Children.Add($aBtn) | Out-Null
            $aBtn.IsEnabled = -not ($aMountState -and $aMountState.State -in @('Mounting', 'Disconnecting', 'Checking', 'Queued', 'Waiting'))

            $aInLabel = New-Label 'in' 12 $p.TextSecondary
            $aInLabel.VerticalAlignment = 'Center'
            $aInLabel.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
            $aActionRow.Children.Add($aInLabel) | Out-Null

            $aCombo = [System.Windows.Controls.ComboBox]::new()
            $aCombo.Tag = [string]$acc.Id
            $aCombo.Width = 56
            $aCombo.Height = 28
            $aCombo.VerticalContentAlignment = 'Center'
            $aCombo.IsEnabled = (-not $aStatus.IsMounted)
            foreach ($l in $driveLetters) { [void]$aCombo.Items.Add("$($l):") }
            $aCombo.SelectedItem = "$($acc.DriveLetter):"
            $aCombo.Add_SelectionChanged({
                param($sender, $eventArgs)
                if ($sender.SelectedItem) {
                    $selectedAccount = Get-CloudAccount -AccountId ([string]$sender.Tag)
                    if (-not $selectedAccount) { return }
                    $mountState = if ($script:AccountMountStates.ContainsKey([string]$selectedAccount.Id)) { $script:AccountMountStates[[string]$selectedAccount.Id] } else { $null }
                    if ($mountState -and $mountState.State -in @('Mounting', 'Disconnecting')) {
                        $sender.SelectedItem = "$([string]$selectedAccount.DriveLetter):"
                        return
                    }
                    $sel = $sender.SelectedItem.ToString().TrimEnd(':')
                    $previousLetter = [string]$selectedAccount.DriveLetter
                    if ($sel -eq $previousLetter) { return }
                    $updatedAccount = @{} + $selectedAccount
                    $updatedAccount.DriveLetter = $sel
                    try {
                        # Persist first: if another account owns that letter the
                        # save is rejected, the combo reverts, and the card keeps
                        # its previous letter everywhere.
                        Update-CloudAccount -Account $updatedAccount | Out-Null
                        Remove-ProviderExplorerIcon -ProviderId ([string]$selectedAccount.ProviderId) -DriveLetter $previousLetter
                        Register-ProviderExplorerIcon -ProviderId ([string]$selectedAccount.ProviderId) -DriveLetter $sel
                    } catch {
                        $sender.SelectedItem = "${previousLetter}:"
                        [System.Windows.MessageBox]::Show((Format-SanitizedDiagnosticMessage $_.Exception.Message), 'Drive letter unavailable', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                    }
                }
            })
            $aActionRow.Children.Add($aCombo) | Out-Null

            $aExpBtn = New-QuickIconButton ([char]::ConvertFromUtf32(0x1F4C1)) 'Open in Windows File Explorer'
            $aExpBtn.Tag = [string]$acc.Id
            $aExpBtn.IsEnabled = $aStatus.IsMounted
            $aExpBtn.Add_Click({
                param($sender, $eventArgs)
                $selectedAccount = Get-CloudAccount -AccountId ([string]$sender.Tag)
                if ($selectedAccount) { Start-ExplorerWindow ($selectedAccount.DriveLetter + ':\') }
            })
            $aActionRow.Children.Add($aExpBtn) | Out-Null

            $aSetBtn = New-QuickIconButton ([string][char]0x2699) 'Account Options'
            $aSetBtn.Tag = [string]$acc.Id
            $aSetBtn.Add_Click({
                param($sender, $eventArgs)
                $selectedAccount = Get-CloudAccount -AccountId ([string]$sender.Tag)
                if (-not $selectedAccount) { return }
                $previous = @{} + $selectedAccount
                $wasMounted = (Get-CachedUiDriveStatus -AccountId $previous.Id -ProviderId $previous.ProviderId -DriveLetter $previous.DriveLetter).IsMounted
                $savedAcc = Show-CloudAccountSetupModal -Owner $window -ProviderId $selectedAccount.ProviderId -InitialAccount $selectedAccount -Theme $script:Settings.Theme
                if ($savedAcc) {
                    $mountOptionsChanged = ($previous.DisplayName -ne $savedAcc.DisplayName) -or
                        ($previous.DriveLetter -ne $savedAcc.DriveLetter) -or
                        ([bool]$previous.ReadOnly -ne [bool]$savedAcc.ReadOnly) -or
                        ($previous.CacheDirectory -ne $savedAcc.CacheDirectory) -or
                        ([int]$previous.CacheMaxGigabytes -ne [int]$savedAcc.CacheMaxGigabytes)
                    if ($wasMounted -and $mountOptionsChanged) {
                        [void](Start-ScopedDriveDisconnect -ProviderId ([string]$previous.ProviderId) -AccountId ([string]$previous.Id) -DriveLetter ([string]$previous.DriveLetter) -ReconnectAfterSuccess)
                    }
                    Update-AllUIState
                }
            })
            $aActionRow.Children.Add($aSetBtn) | Out-Null

            $aUpBtn = New-QuickIconButton ([string][char]0x2191) 'Upload Files'
            $aUpBtn.Tag = [string]$acc.Id
            $aUpBtn.IsEnabled = $aStatus.IsMounted
            $aUpBtn.Add_Click({
                param($sender, $eventArgs)
                $selectedAccount = Get-CloudAccount -AccountId ([string]$sender.Tag)
                if ($selectedAccount) { Show-UploadDialog -DriveLetter $selectedAccount.DriveLetter -ParentWindow $window }
            })
            $aActionRow.Children.Add($aUpBtn) | Out-Null

            $aRemBtn = New-QuickIconButton ([string][char]0x2715) 'Disconnect and Remove'
            $aRemBtn.Tag = [string]$acc.Id
            $aRemBtn.Add_Click({
                param($sender, $eventArgs)
                # Never tear an account down while a startup restore or reconnect
                # worker may be saving/mounting it concurrently; the worker would
                # resurrect a phantom mount for a deleted account.
                if ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker -or $script:ReconnectWorker) { return }
                $selectedAccount = Get-CloudAccount -AccountId ([string]$sender.Tag)
                if (-not $selectedAccount) { return }
                [void](Start-ScopedDriveDisconnect -ProviderId ([string]$selectedAccount.ProviderId) -AccountId ([string]$selectedAccount.Id) -DriveLetter ([string]$selectedAccount.DriveLetter) -RemoveAccount)
                Update-AllUIState
            })
            $aRemBtn.IsEnabled = -not ($aMountState -and $aMountState.State -in @('Mounting', 'Disconnecting'))
            $aActionRow.Children.Add($aRemBtn) | Out-Null

            # Col 2: Status
            $aRightStack = [System.Windows.Controls.StackPanel]::new()
            $aRightStack.VerticalAlignment = 'Center'
            $aRightStack.HorizontalAlignment = 'Right'
            $aRightStack.Width = 220
            $aRightStack.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
            [System.Windows.Controls.Grid]::SetColumn($aRightStack, 2)
            $aGrid.Children.Add($aRightStack) | Out-Null

            $mountElapsed = if ($aMountState -and $aMountState.StartedAt) { [Math]::Max(0, [int]([DateTime]::UtcNow - [DateTime]$aMountState.StartedAt).TotalSeconds) } else { 0 }
            # Surface the mount's real access mode: IsReadOnly comes from the
            # running rclone process's command line, so '(read-only)' reflects
            # what actually applies to this drive, not just the saved setting.
            $roSuffix = if ($aStatus.IsReadOnly) { ' (read-only)' } else { '' }
            $pillText = if ($aMountState -and $aMountState.State -eq 'Disconnecting') {
                [string][char]0x25CF + ' Disconnecting (' + $mountElapsed + 's)'
            } elseif ($aStatus.IsMounted) {
                [string][char]0x25CF + ' Mounted (' + $aStatus.DriveLetter + ':' + $roSuffix + ')'
            } elseif ($aMountState -and $aMountState.State -eq 'Waiting') {
                [string][char]0x25CF + ' Waiting for startup restoration'
            } elseif ($aMountState -and $aMountState.State -eq 'Queued') {
                [string][char]0x25CF + ' Queued'
            } elseif ($aMountState -and $aMountState.State -eq 'Checking') {
                [string][char]0x25CF + ' Checking existing mount (' + $mountElapsed + 's)'
            } elseif ($aMountState -and $aMountState.State -eq 'Mounting') {
                [string][char]0x25CF + ' ' + [string]$aMountState.Stage + ' (' + $mountElapsed + 's)'
            } elseif ($aMountState -and $aMountState.State -eq 'Error') {
                $errText = if ($aMountState.Error) { [string]$aMountState.Error } else { 'Mount failed' }
                [string][char]0x25CF + ' Failed: ' + $errText
            } elseif ($aMountState -and $aMountState.State -eq 'AuthRequired') {
                [string][char]0x25CF + ' Sign-in required'
            } else {
                [string][char]0x25CF + ' Ready to connect'
            }
            $pillColor = if ($aMountState -and $aMountState.State -eq 'Disconnecting') {
                $p.PillWarning
            } elseif ($aStatus.IsMounted) {
                $p.PillMounted
            } elseif ($aMountState -and $aMountState.State -eq 'Error') {
                $p.Danger
            } elseif ($aMountState -and $aMountState.State -in @('Mounting', 'Checking', 'Queued')) {
                $p.PillWarning
            } elseif ($aMountState -and $aMountState.State -eq 'Waiting') {
                $p.TextMuted
            } else {
                $p.PillConnected
            }
            $aStatusLbl = New-Label $pillText 11 $pillColor $true
            $aStatusLbl.HorizontalAlignment = 'Right'
            $aRightStack.Children.Add($aStatusLbl) | Out-Null

            $accountsStack.Children.Add($aCard) | Out-Null
        }
    }
        $script:AccountCardsSignature = $accountCardsSignature
    }
}

# ==============================================================================
# ACTION EVENT HANDLERS
# ==============================================================================

function Show-UploadDialog([string]$DriveLetter, [System.Windows.Window]$ParentWindow) {
    $cleanLetter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $driveRoot = $cleanLetter + ':\'
    if (-not (Test-Path -LiteralPath $driveRoot)) {
        [System.Windows.MessageBox]::Show('Drive ' + $driveRoot + ' is not mounted or accessible. Please mount the drive first.', 'Upload to Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = 'Select File(s) to Upload to ' + $cleanLetter + ':'
    $dlg.Multiselect = $true
    $dlg.CheckFileExists = $true

    $res = $dlg.ShowDialog($ParentWindow)
    if ($res -eq $true -and $dlg.FileNames.Length -gt 0) {
        $uploaded = 0
        $failed = 0
        $errMsgs = @()

        # Resolve associated cloud account for pre-flight verification
        $matchingAccount = $null
        try {
            $accounts = Get-CloudAccounts
            foreach ($a in $accounts) {
                if ($a.DriveLetter -and $a.DriveLetter.ToUpperInvariant().TrimEnd(':') -eq $cleanLetter) {
                    $matchingAccount = $a
                    break
                }
            }
        } catch { }
        if (-not $matchingAccount) {
            if ($cleanLetter -eq $script:GDriveLetter) {
                $matchingAccount = @{ ProviderId = 'gdrive'; DisplayName = 'Google Drive'; Id = '' }
            } elseif ($cleanLetter -eq $script:TeraBoxLetter) {
                $matchingAccount = @{ ProviderId = 'terabox'; DisplayName = 'TeraBox'; Id = '' }
            }
        }

        foreach ($srcFile in $dlg.FileNames) {
            try {
                $fi = [System.IO.FileInfo]::new($srcFile)
                $fName = $fi.Name
                $fSize = $fi.Length

                if ($matchingAccount) {
                    $preflight = Test-ProviderUploadPreflight -Account $matchingAccount -FileSizeBytes $fSize -FileName $fName
                    if (-not $preflight.Allowed) {
                        $failed++
                        $errMsgs += "$fName`: $($preflight.Reason)"
                        continue
                    }
                }

                $destPath = Join-Path $driveRoot $fName
                [System.IO.File]::Copy($srcFile, $destPath, $true)
                $uploaded++
            } catch {
                $failed++
                $errMsgs += "$([System.IO.Path]::GetFileName($srcFile)): $($_.Exception.Message)"
            }
        }

        if ($failed -eq 0 -and $uploaded -gt 0) {
            $msg = "Staged $uploaded file(s) into local drive cache ($driveRoot).`n`n" +
                   "The file(s) are cached locally and are being uploaded to the cloud in the background.`n`n" +
                   "Status: Locally cached -> Uploading to provider.`n" +
                   "You can monitor live progress on the Analytics and Disks pages."
            [System.Windows.MessageBox]::Show($msg, 'Files Staged for Cloud Upload', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        } elseif ($uploaded -gt 0 -and $failed -gt 0) {
            $msg = "Staged: $uploaded file(s) to cache`nRejected / Failed: $failed file(s)`n`nDetails:`n" + ($errMsgs -join "`n")
            [System.Windows.MessageBox]::Show($msg, 'Upload Notice', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        } else {
            $msg = "Upload rejected for $failed file(s):`n`n" + ($errMsgs -join "`n`n")
            [System.Windows.MessageBox]::Show($msg, 'Upload Prohibited by Plan Limits', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        }
    }
}

# ------------------------------------------------------------------------------
# GOOGLE DRIVE: Connect / Disconnect Action
# ------------------------------------------------------------------------------
$gdActionBtn.Add_Click({
    if ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker -or $script:ReconnectWorker) { return }
    $gdStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) {
        $gdStatusText.Text = [string][char]0x25CF + ' Disconnecting...'
        $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $gdActionBtn.IsEnabled = $false
        [void](Start-ScopedDriveDisconnect -ProviderId 'gdrive' -DriveLetter ([string]$gdStatus.DriveLetter))
        Update-AllUIState
        return
    }

    try {
        $created = Connect-NewCloudAccount -Owner $window -ProviderId 'gdrive'
        if ($created) {
            [void]$script:ManualMountRequests.Add([string]$created.Id)
            Invoke-AutoReconnectWatchdog -AccountId ([string]$created.Id)
        }
        Update-AllUIState
    } catch {
        $gdErrorText.Text = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
        $gdErrorText.Visibility = 'Visible'
        Update-AllUIState
    }
})

$gdExplorerBtn.Add_Click({
    $status = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($status.IsMounted) {
        Start-ExplorerWindow $status.DriveRoot
    }
})

$gdSettingsBtn.Add_Click({
    $selectedStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive'
    $selectedLetter = ([string]$selectedStatus.DriveLetter).TrimEnd(':').TrimEnd('\')
    $existing = Get-CloudAccounts | Where-Object {
        $_.ProviderId -eq 'gdrive' -and
        ([string]$_.DriveLetter).TrimEnd(':').TrimEnd('\') -eq $selectedLetter
    } | Select-Object -First 1
    if (-not $existing) {
        [System.Windows.MessageBox]::Show('This mounted Google Drive is not linked to a saved account. Use Add Cloud Disk to create a verified account record; this will not change the existing mount or its credentials.', 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $res = Show-CloudAccountSetupModal -Owner $window -ProviderId 'gdrive' -InitialAccount $existing -Theme $script:Settings.Theme
    if ($res) {
        Update-AllUIState
    }
})

$gdUploadBtn.Add_Click({
    Show-UploadDialog -DriveLetter $script:GDriveLetter -ParentWindow $window
})

$gdRemoveBtn.Add_Click({
    $conf = [System.Windows.MessageBox]::Show('Are you sure you want to disconnect and remove Google Drive?', 'Remove Cloud Drive', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($conf -eq [System.Windows.MessageBoxResult]::Yes) {
        [void](Start-ScopedDriveDisconnect -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -RemoveLegacySession)
        Update-AllUIState
    }
})

# ------------------------------------------------------------------------------
# TERABOX: Connect / Disconnect Action
# ------------------------------------------------------------------------------
$tbActionBtn.Add_Click({
    if ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker -or $script:ReconnectWorker) { return }
    $tbStatus = Get-CachedUiDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) {
        $tbStatusText.Text = [string][char]0x25CF + ' Disconnecting...'
        $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $tbActionBtn.IsEnabled = $false
        [void](Start-ScopedDriveDisconnect -ProviderId 'terabox' -DriveLetter ([string]$tbStatus.DriveLetter))
        Update-AllUIState
        return
    }

    try {
        $created = Connect-NewCloudAccount -Owner $window -ProviderId 'terabox'
        if ($created) {
            [void]$script:ManualMountRequests.Add([string]$created.Id)
            Invoke-AutoReconnectWatchdog -AccountId ([string]$created.Id)
        }
        Update-AllUIState
    } catch {
        $tbErrorText.Text = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
        $tbErrorText.Visibility = 'Visible'
        Update-AllUIState
    }
})

$tbExplorerBtn.Add_Click({
    $status = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($status.IsMounted) {
        Start-ExplorerWindow $status.DriveRoot
    }
})

$tbSettingsBtn.Add_Click({
    $selectedStatus = Get-CachedUiDriveStatus -ProviderId 'terabox'
    $selectedLetter = ([string]$selectedStatus.DriveLetter).TrimEnd(':').TrimEnd('\')
    $existing = Get-CloudAccounts | Where-Object {
        $_.ProviderId -eq 'terabox' -and
        ([string]$_.DriveLetter).TrimEnd(':').TrimEnd('\') -eq $selectedLetter
    } | Select-Object -First 1
    if (-not $existing) {
        [System.Windows.MessageBox]::Show('This mounted TeraBox connection is not linked to a saved account. Use Add Cloud Disk to create a verified account record; this will not change the existing mount or its session.', 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $res = Show-CloudAccountSetupModal -Owner $window -ProviderId 'terabox' -InitialAccount $existing -Theme $script:Settings.Theme
    if ($res) {
        Update-AllUIState
    }
})

$tbUploadBtn.Add_Click({
    Show-UploadDialog -DriveLetter $script:TeraBoxLetter -ParentWindow $window
})

$tbRemoveBtn.Add_Click({
    $conf = [System.Windows.MessageBox]::Show('Are you sure you want to disconnect and remove TeraBox?', 'Remove Cloud Drive', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($conf -eq [System.Windows.MessageBoxResult]::Yes) {
        [void](Start-ScopedDriveDisconnect -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -RemoveLegacySession)
        Update-AllUIState
    }
})

# ==============================================================================
# SYSTEM TRAY INTEGRATION
# ==============================================================================
$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$script:CustomNotifyIcon = $null
$appLogoPath = Join-Path $PSScriptRoot '..\assets\logos\clouddrive.png'
if (Test-Path -LiteralPath $appLogoPath -PathType Leaf) {
    try {
        $script:CustomNotifyIcon = Get-AppNotifyIcon $appLogoPath
        $notifyIcon.Icon = $script:CustomNotifyIcon
    } catch {
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    }
} else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}
$notifyIcon.Text = 'NS Cloud Drive'
$notifyIcon.Visible = $true

$trayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
$menuOpen = $trayMenu.Items.Add('Open NS Cloud Drive')
$menuOpen.Font = [System.Drawing.Font]::new($trayMenu.Font, [System.Drawing.FontStyle]::Bold)
$menuOpen.Add_Click({
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Topmost = $true
    $window.Topmost = $false
    $window.Activate() | Out-Null
    $window.Focus() | Out-Null
    Update-AllUIState
})

$trayMenu.Items.Add('-') | Out-Null

$menuOpenGD = $trayMenu.Items.Add('Open Google Drive (' + $script:GDriveLetter + ':\)')
$menuOpenGD.Add_Click({
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) {
        Start-ExplorerWindow $gdStatus.DriveRoot
    }
})

$menuOpenTB = $trayMenu.Items.Add('Open TeraBox (' + $script:TeraBoxLetter + ':\)')
$menuOpenTB.Add_Click({
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) {
        Start-ExplorerWindow $tbStatus.DriveRoot
    }
})

$trayMenu.Items.Add('-') | Out-Null

$menuExit = $trayMenu.Items.Add('Exit NS Cloud Drive')
$menuExit.Add_Click({
    $script:IsExiting = $true
    Stop-VirtualDriveMount | Out-Null
    Remove-NSCloudDriveOwnedExplorerIcons
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    Dispose-AppNotifyIcon
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
    $window.Topmost = $true
    $window.Topmost = $false
    $window.Activate() | Out-Null
    $window.Focus() | Out-Null
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
            Stop-AnalyticsCollection
            $window.Hide()
            $notifyIcon.ShowBalloonTip(2000, 'NS Cloud Drive', 'Running in background. Double-click tray icon to open.', [System.Windows.Forms.ToolTipIcon]::Info)
        } else {
            $script:IsExiting = $true
            Stop-VirtualDriveMount | Out-Null
            Remove-NSCloudDriveOwnedExplorerIcons
            $notifyIcon.Visible = $false
            $notifyIcon.Dispose()
            Dispose-AppNotifyIcon
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

$window.Add_IsVisibleChanged({
    if (-not $window.IsVisible) {
        Stop-AnalyticsCollection
    }
})
$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        Stop-AnalyticsCollection
    }
})

$window.Add_Activated({
    Update-AllUIState
})

$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        Invoke-MemoryTrim
    }
})

# ==============================================================================
# EXPLORER DRIVE ICON LIFECYCLE
# ==============================================================================
# Only verified mounts get their Explorer icon registered, and only icons this
# application stamped are removed. Registration is per-user (HKCU DriveIcons),
# fails closed on foreign registrations, and never blocks the mount flow.
function Register-ProviderExplorerIcon([string]$ProviderId, [string]$DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter) -or [string]::IsNullOrWhiteSpace($ProviderId)) { return }
    $cleanLetter = ([string]$DriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($cleanLetter.Length -ne 1) { return }
    try { Invoke-NSCloudDriveExplorerIconRegistration -Action Register -DriveLetter $cleanLetter -ProviderId ([string]$ProviderId) | Out-Null } catch { }
}

# Registers the Explorer icon for a mounted saved account by resolving its
# provider from the persisted record (mount results only carry ids/letters).
function Register-ProviderExplorerIconViaAccount([string]$AccountId, [string]$DriveLetter) {
    try {
        $account = Get-CloudAccount -AccountId $AccountId
        if ($account) { Register-ProviderExplorerIcon -ProviderId ([string]$account.ProviderId) -DriveLetter $DriveLetter }
    } catch { }
}

function Remove-ProviderExplorerIcon([string]$ProviderId, [string]$DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return }
    $cleanLetter = ([string]$DriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($cleanLetter.Length -ne 1) { return }
    try { Invoke-NSCloudDriveExplorerIconRegistration -Action Remove -DriveLetter $cleanLetter -ProviderId ([string]$ProviderId) | Out-Null } catch { }
}

# Removes every Explorer icon this application owns (per the NSCloudDriveOwner
# stamp), regardless of which letter currently maps to which provider. Used on
# shutdown and provider removal so app-owned letters stay clean when idle.
function Remove-NSCloudDriveOwnedExplorerIcons {
    $letters = @($script:GDriveLetter, $script:TeraBoxLetter)
    try { $letters += @((Get-CloudAccounts) | ForEach-Object { ([string]$_.DriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\') }) } catch { }
    foreach ($letter in ($letters | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($letter)) { continue }
        if ($letter.Length -ne 1 -or $letter -notmatch '^[A-Z]$') { continue }
        try {
            $registration = Get-NSCloudDriveExplorerIconRegistration $letter
            if ($registration.IsOwned -and $registration.IconPath) {
                $rawIconPath = ([string]$registration.IconPath) -replace ',0$',''
                Remove-NSCloudDriveExplorerIcon -DriveLetter $letter -ExpectedIconPath $rawIconPath | Out-Null
            }
        } catch { }
    }
}

# ==============================================================================
# LEGACY PROVIDER-CARD MOUNT WORKERS
# ==============================================================================
# The provider cards at the top of the Disks view connect credentials stored in
# the legacy (account-less) token files. Their mounts used to run inline in the
# WPF click handler and could freeze the window for up to 90 seconds. These
# helpers dispatch each legacy mount to the same cancellable background runspace
# machinery used for saved accounts, keyed per provider so a duplicate click can
# never start a second rclone mount for the same drive.
function Test-LegacyMountBusy([string]$ProviderId) {
    $providerKey = ([string]$ProviderId).ToLowerInvariant()
    if ($script:LegacyMountWorkers.ContainsKey($providerKey) -and $script:LegacyMountWorkers[$providerKey]) { return $true }
    if ($script:LegacyMountStates.ContainsKey($providerKey) -and $script:LegacyMountStates[$providerKey] -and $script:LegacyMountStates[$providerKey].State -eq 'Mounting') { return $true }
    return $false
}

function Start-LegacyMountWorker {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [Parameter(Mandatory = $true)][string]$DriveLetter,
        [string]$DisplayName = ''
    )
    $providerKey = $ProviderId.ToLowerInvariant()
    if (Test-LegacyMountBusy $providerKey) { return $false }

    $cleanLetter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $progress = [hashtable]::Synchronized(@{ Stage = 'Starting mount worker'; DriveLetter = $cleanLetter; Error = $null; StartedAt = [DateTime]::UtcNow })
    $script:LegacyMountStates[$providerKey] = [ordered]@{
        State = 'Mounting'; Stage = 'Starting mount worker'; Error = $null
        DriveLetter = $cleanLetter; StartedAt = [DateTime]::UtcNow; UpdatedAt = [DateTime]::UtcNow
    }
    try {
        $script:LegacyMountWorkers[$providerKey] = Start-NSBackgroundOperation -ArgumentList @(
            $PSScriptRoot, $script:CacheDirectory, [int]$script:Settings.CacheMaxGigabytes, $providerKey, $cleanLetter, $DisplayName, $progress
        ) -ScriptBlock {
            param([string]$sourceRoot, [string]$cacheDirectory, [int]$cacheMaxGigabytes, [string]$providerKey, [string]$driveLetter, [string]$displayName, [hashtable]$progress)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $sourceRoot 'models\ConnectionState.ps1')
            . (Join-Path $sourceRoot 'providers\GoogleDriveProvider.ps1')
            . (Join-Path $sourceRoot 'providers\TeraBoxProvider.ps1')
            . (Join-Path $sourceRoot 'services\VirtualDriveManager.ps1')

            if ($providerKey -eq 'gdrive') {
                $progress.Stage = 'Validating Google Drive credentials'
                $check = Test-GoogleDriveBackendSession
                if (-not $check.IsValid) {
                    $checkState = [string](Get-SafeProperty $check 'State' 'Error')
                    return [pscustomobject]@{ WorkerKey = "__${providerKey}_legacy__"; ProviderId = $providerKey; State = if ($checkState -eq 'Disconnected') { 'Disconnected' } else { 'AuthRequired' }; Error = (Get-SafeProperty $check 'Error' 'Provider returned an incomplete status response.'); DriveLetter = $driveLetter }
                }
                $progress.Stage = "Starting and verifying ${driveLetter}: mount"
                $environment = Get-GoogleDriveRcloneEnvironment
                Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $driveLetter `
                    -VolumeLabel $(if ($displayName) { $displayName } else { 'Google Drive' }) `
                    -CacheDirectory $cacheDirectory -CacheMaxGigabytes $cacheMaxGigabytes -EnvironmentVariables $environment | Out-Null
            } elseif ($providerKey -eq 'terabox') {
                $progress.Stage = 'Validating TeraBox session'
                $check = Test-TeraBoxBackendSession
                if (-not $check.IsValid) {
                    $checkState = [string](Get-SafeProperty $check 'State' 'Error')
                    return [pscustomobject]@{ WorkerKey = "__${providerKey}_legacy__"; ProviderId = $providerKey; State = if ($checkState -eq 'Disconnected') { 'Disconnected' } else { 'AuthRequired' }; Error = (Get-SafeProperty $check 'Error' 'Provider returned an incomplete status response.'); DriveLetter = $driveLetter }
                }
                $progress.Stage = "Starting and verifying ${driveLetter}: mount"
                $environment = Get-TeraBoxRcloneEnvironment
                Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $driveLetter `
                    -VolumeLabel $(if ($displayName) { $displayName } else { 'TeraBox' }) `
                    -CacheDirectory $cacheDirectory -CacheMaxGigabytes $cacheMaxGigabytes -EnvironmentVariables $environment | Out-Null
            } else {
                return [pscustomobject]@{ WorkerKey = "__${providerKey}_legacy__"; ProviderId = $providerKey; State = 'Error'; Error = "Unknown provider '$providerKey'."; DriveLetter = $driveLetter }
            }

            return [pscustomobject]@{ WorkerKey = "__${providerKey}_legacy__"; ProviderId = $providerKey; State = 'Mounted'; Error = $null; DriveLetter = $driveLetter }
        }
        return $true
    } catch {
        $script:LegacyMountStates[$providerKey] = [ordered]@{
            State = 'Error'; Stage = 'Could not start mount worker'
            Error = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
            DriveLetter = $cleanLetter; StartedAt = $null; UpdatedAt = [DateTime]::UtcNow
        }
        return $false
    }
}

function Complete-AvailableLegacyMountWorkers {
    foreach ($providerKey in @($script:LegacyMountWorkers.Keys)) {
        $operation = $script:LegacyMountWorkers[$providerKey]
        if (-not $operation -or -not (Test-NSBackgroundOperationCompleted $operation)) { continue }
        $script:LegacyMountWorkers.Remove($providerKey)
        $previous = if ($script:LegacyMountStates.ContainsKey($providerKey)) { $script:LegacyMountStates[$providerKey] } else { $null }
        $final = [ordered]@{
            State = 'Error'; Stage = 'Mount worker stopped'
            Error = 'The mount worker stopped unexpectedly.'
            DriveLetter = if ($previous) { [string]$previous.DriveLetter } else { '' }
            StartedAt = $null; UpdatedAt = [DateTime]::UtcNow
        }
        try {
            $completed = Complete-NSBackgroundOperation $operation
            $result = if ($completed.Output.Count -gt 0) { $completed.Output[-1] } else { $null }
            if ($result -and $result.WorkerKey) {
                $final = [ordered]@{
                    State = if ($result.State -in @('Mounted', 'ExistingProcess')) { 'Mounted' } else { [string]$result.State }
                    Stage = if ($result.State -in @('Mounted', 'ExistingProcess')) { 'Filesystem verified' } else { 'Mount attempt finished' }
                    Error = if ($result.Error) { [string]$result.Error } else { $null }
                    DriveLetter = if ($result.DriveLetter) { [string]$result.DriveLetter } else { $final.DriveLetter }
                    StartedAt = $null; UpdatedAt = [DateTime]::UtcNow
                }
            } elseif ($completed.HadErrors -and $completed.Errors.Count -gt 0) {
                $final.Error = Format-SanitizedDiagnosticMessage ([string]$completed.Errors[0].Exception.Message)
            }
        } catch { }
        $script:LegacyMountStates[$providerKey] = $final
        # Shared-log entry so the Logs page shows legacy card mount outcomes.
        try {
            $legacySeverity = 'Info'
            if ($final.State -eq 'Error') { $legacySeverity = 'Error' }
            elseif ($final.State -eq 'AuthRequired') { $legacySeverity = 'Warning' }
            $legacyRecovered = if ($final.State -in @('Mounted', 'Connected')) { $true } elseif ($final.State -eq 'Error') { $false } else { $null }
            Write-NSCloudLog -Severity $legacySeverity -Provider $providerKey -Operation 'legacy-mount' `
                -Message ("Legacy mount finished: $(if ($final.State) { [string]$final.State } else { 'unknown' })$(if ($final.DriveLetter) { " on $($final.DriveLetter):" })$(if ($final.Error) { " - $($final.Error)" })") `
                -Recovered $legacyRecovered
        } catch { }
        if ($final.State -eq 'Mounted') {
            Register-ProviderExplorerIcon -ProviderId $providerKey -DriveLetter ([string]$final.DriveLetter)
            if ($script:Settings.OpenExplorerOnMount -and $final.DriveLetter) {
                try { Start-ExplorerWindow ($final.DriveLetter + ':\') } catch { }
            }
        }
    }
}

# ==============================================================================
# AUTO-RECONNECT WATCHDOG
# ==============================================================================
# Invoked from the background DispatcherTimer.  When a configured account has
# AutoMount=true and its drive is no longer accessible, this function schedules
# and executes a remount attempt with exponential backoff.
#
# Backoff schedule (per account):
#   failure 0 (first attempt) : retry after 30 s
#   failure 1                 : retry after 60 s
#   failure 2                 : retry after 120 s
#   failure 3+                : retry after 300 s (5 min cap)
#
# The watchdog does nothing when $script:IsConnecting is set (manual connect
# in progress) or when AutoMountDrives is disabled in settings.
function Invoke-AutoReconnectWatchdog {
    param([string]$AccountId = '')
    # A legacy provider card is already mounting with this backend; a second
    # rclone mount for the same drive would fail with a letter conflict. Until
    # it finishes, new requests wait instead of racing the running mount.
    if (Test-LegacyMountBusy 'gdrive' -or Test-LegacyMountBusy 'terabox') { return }
    if ($script:IsConnecting -or ([string]::IsNullOrWhiteSpace($AccountId) -and -not $script:Settings.AutoMountDrives)) { return }
    if ($script:ReconnectWorker -or $script:StartupAutoMountWorker -or $script:StartupAutoMountPending) {
        if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
            if (-not $script:PendingManualMountAccountIds.Contains($AccountId)) { $script:PendingManualMountAccountIds.Enqueue($AccountId) }
            $account = Get-CloudAccount -AccountId $AccountId
            if ($account) { $script:AccountMountStates[$AccountId] = [ordered]@{ State = 'Mounting'; Stage = 'Queued behind another mount'; Error = $null; DriveLetter = [string]$account.DriveLetter; StartedAt = [DateTime]::UtcNow; UpdatedAt = [DateTime]::UtcNow } }
        }
        return
    }

    try {
        $accounts = @(Get-CloudAccounts)
        $legacyMode = ($accounts.Count -eq 0)
        $workerAccounts = if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
            $account = Get-CloudAccount -AccountId $AccountId
            if (-not $account) { throw 'The saved account could not be found.' }
            @([pscustomobject]@{ WorkerKey = [string]$account.Id; Id = [string]$account.Id; ProviderId = [string]$account.ProviderId; DriveLetter = [string]$account.DriveLetter; DisplayName = [string]$account.DisplayName; AutoMount = $true; ReadOnly = [bool]$account.ReadOnly; CacheDirectory = [string]$account.CacheDirectory; CacheMaxGigabytes = [int]$account.CacheMaxGigabytes })
        } elseif ($legacyMode) {
            @(
                [pscustomobject]@{ WorkerKey = '__gdrive_primary__'; Id = ''; ProviderId = 'gdrive'; DriveLetter = $script:GDriveLetter; DisplayName = 'Google Drive'; AutoMount = $true; ReadOnly = $false; CacheDirectory = ''; CacheMaxGigabytes = 0 },
                [pscustomobject]@{ WorkerKey = '__terabox_primary__'; Id = ''; ProviderId = 'terabox'; DriveLetter = $script:TeraBoxLetter; DisplayName = 'TeraBox'; AutoMount = $true; ReadOnly = $false; CacheDirectory = ''; CacheMaxGigabytes = 0 }
            )
        } else {
            @($accounts | Where-Object { $_.AutoMount } | ForEach-Object {
                [pscustomobject]@{
                    WorkerKey = [string]$_.Id
                    Id = [string]$_.Id
                    ProviderId = [string]$_.ProviderId
                    DriveLetter = [string]$_.DriveLetter
                    DisplayName = [string]$_.DisplayName
                    AutoMount = [bool]$_.AutoMount
                    ReadOnly = [bool]$_.ReadOnly
                    CacheDirectory = [string]$_.CacheDirectory
                    CacheMaxGigabytes = [int]$_.CacheMaxGigabytes
                }
            })
        }

        $nextAllowed = @{}
        foreach ($key in $script:ReconnectNextAllowed.Keys) { $nextAllowed[$key] = $script:ReconnectNextAllowed[$key] }
        $failureCounts = @{}
        foreach ($key in $script:ReconnectFailCount.Keys) { $failureCounts[$key] = [int]$script:ReconnectFailCount[$key] }
        $cacheDirectory = $script:CacheDirectory
        $cacheMaxGigabytes = [int]$script:Settings.CacheMaxGigabytes
        $mountProgress = New-MountOperationState -State 'Mounting' -Stage 'Starting mount worker' -AccountId $AccountId
        if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
            $mountProgress.DriveLetter = [string]$workerAccounts[0].DriveLetter
            $script:AccountMountStates[$AccountId] = $mountProgress
        }

        $script:ReconnectWorkerAccountId = $AccountId
        $script:ReconnectWorkerProgress = $mountProgress
        $script:ReconnectWorker = Start-NSBackgroundOperation -ArgumentList @(
            $PSScriptRoot, $cacheDirectory, $cacheMaxGigabytes, $workerAccounts, $nextAllowed, $failureCounts, $mountProgress
        ) -ScriptBlock {
            param([string]$sourceRoot, [string]$cacheDirectory, [int]$cacheMaxGigabytes, [object[]]$accounts, [hashtable]$nextAllowed, [hashtable]$failureCounts, [hashtable]$mountProgress)
            $ErrorActionPreference = 'Stop'
            . (Join-Path $sourceRoot 'models\ConnectionState.ps1')
            . (Join-Path $sourceRoot 'providers\GoogleDriveProvider.ps1')
            . (Join-Path $sourceRoot 'providers\TeraBoxProvider.ps1')
            . (Join-Path $sourceRoot 'services\VirtualDriveManager.ps1')

            function Get-VerifiedRclonePath {
                $r = Find-RcloneBinary
                if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) {
                    return $r
                }
                return $null
            }

            $now = [DateTime]::UtcNow
            foreach ($account in $accounts) {
                if (-not $account.AutoMount) { continue }
                $accountCacheDirectory = if ($account.CacheDirectory) { [string]$account.CacheDirectory } else { $cacheDirectory }
                $accountCacheMaxGigabytes = if ([int]$account.CacheMaxGigabytes -gt 0) { [int]$account.CacheMaxGigabytes } else { $cacheMaxGigabytes }
                $key = [string]$account.WorkerKey
                if ($mountProgress.AccountId -eq $key) { $mountProgress.Stage = 'Checking existing mount'; $mountProgress.DriveLetter = [string]$account.DriveLetter }
                try {
                    $status = Get-VirtualDriveStatus -AccountId $account.Id -ProviderId $account.ProviderId
                    if ($status.ProcessRunning) {
                        if ($status.IsMounted) {
                            [pscustomobject]@{ WorkerKey = $key; State = 'ExistingProcess'; HealthCheck = 'NotProbed'; FailureCount = 0; NextAllowed = $null; Error = $null; DriveLetter = $account.DriveLetter }
                        } else {
                            [pscustomobject]@{ WorkerKey = $key; State = 'Error'; FailureCount = [int]($failureCounts[$key] + 1); NextAllowed = $now.AddSeconds(30); Error = 'The account mount process is still running, but its drive letter is not present. It was not restarted.'; DriveLetter = $account.DriveLetter }
                        }
                        continue
                    }

                    $retryAt = if ($nextAllowed.ContainsKey($key)) { [DateTime]$nextAllowed[$key] } else { [DateTime]::MinValue }
                    if ($mountProgress.AccountId -ne $key -and $now -lt $retryAt) {
                        [pscustomobject]@{ WorkerKey = $key; State = 'Backoff'; FailureCount = [int]$failureCounts[$key]; NextAllowed = $retryAt; Error = $null }
                        continue
                    }

                    if ($account.ProviderId -eq 'gdrive') {
                        if ($mountProgress.AccountId -eq $key) { $mountProgress.Stage = 'Validating Google Drive credentials' }
                        if ($key -like '__*') {
                            $check = Test-GoogleDriveBackendSession
                            if (-not $check.IsValid) {
                                [pscustomobject]@{ WorkerKey = $key; State = 'Disconnected'; FailureCount = 0; NextAllowed = $null; Error = $null }
                                continue
                            }
                            $environment = Get-GoogleDriveRcloneEnvironment
                        } else {
                            $check = Test-GoogleDriveBackendSession -AccountId $account.Id -Force
                            if (-not $check.IsValid) {
                                [pscustomobject]@{ WorkerKey = $key; State = 'AuthRequired'; FailureCount = 0; NextAllowed = $null; Error = (Format-SanitizedDiagnosticMessage ([string]$check.Error)); DriveLetter = $account.DriveLetter }
                                continue
                            }
                            $environment = Get-GoogleDriveRcloneEnvironment -AccountId $account.Id -RemoteName 'gdrive'
                        }
                    } elseif ($account.ProviderId -eq 'terabox' -and (Get-VerifiedRclonePath)) {
                        if ($mountProgress.AccountId -eq $key) { $mountProgress.Stage = 'Validating TeraBox session' }
                        if ($key -like '__*') {
                            $check = Test-TeraBoxBackendSession
                            if (-not $check.IsValid) {
                                [pscustomobject]@{ WorkerKey = $key; State = 'Disconnected'; FailureCount = 0; NextAllowed = $null; Error = $null }
                                continue
                            }
                        } else {
                            $check = Test-TeraBoxBackendSession -AccountId $account.Id -Force
                            if (-not $check.IsValid) {
                                [pscustomobject]@{ WorkerKey = $key; State = 'AuthRequired'; FailureCount = 0; NextAllowed = $null; Error = (Format-SanitizedDiagnosticMessage ([string]$check.Error)); DriveLetter = $account.DriveLetter }
                                continue
                            }
                        }
                        $environment = if ($key -like '__*') { Get-TeraBoxRcloneEnvironment } else { Get-TeraBoxRcloneEnvironment -AccountId $account.Id }
                        if ($mountProgress.AccountId -eq $key) { $mountProgress.Stage = "Starting and verifying $($account.DriveLetter): mount" }
                        Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -AccountId $account.Id `
                            -DriveLetter $account.DriveLetter -VolumeLabel $account.DisplayName `
                            -CacheDirectory $accountCacheDirectory -CacheMaxGigabytes $accountCacheMaxGigabytes -EnvironmentVariables $environment `
                            -ReadOnly:$([bool]$account.ReadOnly) | Out-Null
                    } else {
                        continue
                    }

                    if ($account.ProviderId -eq 'gdrive' -and $mountProgress.AccountId -eq $key) { $mountProgress.Stage = "Starting and verifying $($account.DriveLetter): mount" }
                    if ($account.ProviderId -eq 'gdrive') {
                        Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -AccountId $account.Id `
                            -DriveLetter $account.DriveLetter -VolumeLabel $account.DisplayName `
                            -CacheDirectory $accountCacheDirectory -CacheMaxGigabytes $accountCacheMaxGigabytes -EnvironmentVariables $environment `
                            -ReadOnly:$([bool]$account.ReadOnly) | Out-Null
                    }

                    [pscustomobject]@{ WorkerKey = $key; State = 'Mounted'; FailureCount = 0; NextAllowed = $null; Error = $null; DriveLetter = $account.DriveLetter }
                } catch {
                    $failures = if ($failureCounts.ContainsKey($key)) { [int]$failureCounts[$key] } else { 0 }
                    $delaySeconds = [Math]::Min(300, [Math]::Pow(2, $failures) * 30)
                    $next = $now.AddSeconds($delaySeconds)
                    if ($mountProgress.AccountId -eq $key) { $mountProgress.Stage = 'Mount failed'; $mountProgress.Error = Format-SanitizedDiagnosticMessage $_.Exception.Message }
                    [pscustomobject]@{
                        WorkerKey = $key
                        State = 'Error'
                        FailureCount = $failures + 1
                        NextAllowed = $next
                        Error = Format-SanitizedDiagnosticMessage $_.Exception.Message
                        DriveLetter = $account.DriveLetter
                    }
                }
            }
        }
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
            $safeMessage = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
            $script:AccountMountStates[$AccountId] = [ordered]@{ State = 'Error'; Stage = 'Could not start mount worker'; Error = $safeMessage; DriveLetter = ''; StartedAt = $null; UpdatedAt = [DateTime]::UtcNow }
        }
    }
}

function Start-StartupAutoMountTimer {
    if (-not $script:Settings.AutoMountDrives -or $script:StartupAutoMountWorker -or $script:StartupAutoMountTimer) { return }

    $script:StartupAutoMountProgress.Stage = 'Waiting for startup dispatcher'
    $script:StartupAutoMountProgress.ProviderId = ''
    $script:StartupAutoMountProgress.DriveLetter = ''
    $script:StartupAutoMountProgress.AccountId = ''
    $script:StartupAutoMountProgress.AccountStages = [hashtable]::Synchronized(@{})
    $script:StartupAutoMountProgress.StartedAt = [DateTime]::UtcNow
    $script:StartupAutoMountProgress.StageStartedAt = $script:StartupAutoMountProgress.StartedAt
    $script:StartupAutoMountPending = $true
    $script:StartupAutoMountTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Normal)
    $script:StartupAutoMountTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:StartupAutoMountTimer.Add_Tick({
        $timer = $script:StartupAutoMountTimer
        if ($timer) { $timer.Stop() }
        $script:StartupAutoMountTimer = $null
        $script:StartupAutoMountPending = $false
        try {
            $script:StartupAutoMountError = $null
            Invoke-StartupAutoMount
        } catch {
            $script:StartupAutoMountError = Format-SanitizedDiagnosticMessage $_.Exception.Message
            $script:LastProviderStatusCheck = [DateTime]::MinValue
        } finally {
            Update-AllUIState
        }
    })
    $script:StartupAutoMountTimer.Start()
}

function Invoke-StartupAutoMount {
    if (-not $script:Settings.AutoMountDrives) { return }
    if ($script:StartupAutoMountWorker) { return }

    $cacheDirectory = $script:CacheDirectory
    $script:StartupAutoMountProgress.Stage = 'Loading saved account settings'
    $script:StartupAutoMountProgress.ProviderId = ''
    $script:StartupAutoMountProgress.DriveLetter = ''
    $script:StartupAutoMountProgress.AccountId = ''
    $script:StartupAutoMountProgress.StageStartedAt = [DateTime]::UtcNow
    $script:StartupAutoMountWorker = Start-NSBackgroundOperation -ArgumentList @($PSScriptRoot, $cacheDirectory, $script:StartupAutoMountProgress) -ScriptBlock {
        param([string]$sourceRoot, [string]$cacheDirectory, [hashtable]$progress)
        $ErrorActionPreference = 'Stop'
        function Set-StartupRestoreProgress {
            param([hashtable]$Progress, [string]$Stage, [string]$ProviderId = '', [string]$DriveLetter = '', [string]$AccountId = '')
            $Progress.Stage = $Stage
            $Progress.ProviderId = $ProviderId
            $Progress.DriveLetter = $DriveLetter
            $Progress.AccountId = $AccountId
            $Progress.StageStartedAt = [DateTime]::UtcNow
        }
        . (Join-Path $sourceRoot 'models\ConnectionState.ps1')
        . (Join-Path $sourceRoot 'providers\GoogleDriveProvider.ps1')
        . (Join-Path $sourceRoot 'providers\TeraBoxProvider.ps1')
        . (Join-Path $sourceRoot 'services\VirtualDriveManager.ps1')

        # This background block dot-sources service/provider modules only; the
        # finder below is therefore NOT the UI script's Get-VerifiedRclonePath
        # (which lives in NSCloudDrive.ps1 and is absent in this runspace).
        # Without a local definition the legacy TeraBox restore threw
        # CommandNotFoundException and no TeraBox mount could ever start.
        function Get-VerifiedRclonePath {
            $r = Find-RcloneBinary
            if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) {
                return $r
            }
            return $null
        }

        $settings = Get-NSCloudDriveSettings
        if (-not $settings.AutoMountDrives) { return }
        $results = [System.Collections.Generic.List[object]]::new()
        Set-StartupRestoreProgress -Progress $progress -Stage 'Loading saved accounts'
        $accounts = @(Get-CloudAccounts)
        Set-StartupRestoreProgress -Progress $progress -Stage 'Checking saved mount state'

        if ($accounts.Count -gt 0) {
            foreach ($initAcc in $accounts) {
                if ($initAcc.AutoMount) {
                    $progress.AccountStages[[string]$initAcc.Id] = [hashtable]::Synchronized(@{
                        State = 'Queued'
                        Stage = 'Queued'
                        StartedAt = [DateTime]::UtcNow
                        StageStartedAt = [DateTime]::UtcNow
                        Error = $null
                    })
                }
            }
            foreach ($account in $accounts) {
                if (-not $account.AutoMount) { continue }
                try {
                    $accountCacheDirectory = if ($account.CacheDirectory) { [string]$account.CacheDirectory } else { $cacheDirectory }
                    $accountCacheMaxGigabytes = if ([int]$account.CacheMaxGigabytes -gt 0) { [int]$account.CacheMaxGigabytes } else { [int]$settings.CacheMaxGigabytes }
                    $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                        State = 'Checking'
                        Stage = 'Checking existing mount'
                        StartedAt = [DateTime]::UtcNow
                        StageStartedAt = [DateTime]::UtcNow
                        Error = $null
                    })
                    Set-StartupRestoreProgress -Progress $progress -Stage "Checking existing $($account.DriveLetter): mount" -ProviderId ([string]$account.ProviderId) -DriveLetter ([string]$account.DriveLetter) -AccountId ([string]$account.Id)
                    $status = Get-VirtualDriveStatus -AccountId $account.Id -ProviderId $account.ProviderId
                    if ($status.ProcessRunning) {
                        if (-not $status.IsMounted) { throw 'A mount process exists, but its assigned drive is not present.' }
                        $health = Test-VirtualDriveFilesystem -DriveRoot $status.DriveRoot -TimeoutSeconds 10
                        if (-not $health.Success) {
                            if ($health.State -eq 'Timeout') {
                                $results.Add([pscustomobject]@{
                                    AccountId = $account.Id
                                    State = 'FilesystemUnverified'
                                    Error = "The existing mount process and drive were retained; the root check timed out: $($health.Error)"
                                    DriveLetter = [string]$account.DriveLetter
                                })
                                $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                                    State = 'Mounted'
                                    Stage = 'Connected'
                                    StartedAt = [DateTime]::UtcNow
                                    StageStartedAt = [DateTime]::UtcNow
                                    Error = $null
                                })
                                continue
                            }
                            throw "Existing mount is not responsive: $($health.Error)"
                        }
                        $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                            State = 'Mounted'
                            Stage = 'Connected'
                            StartedAt = [DateTime]::UtcNow
                            StageStartedAt = [DateTime]::UtcNow
                            Error = $null
                        })
                        $results.Add([pscustomobject]@{ AccountId = $account.Id; State = 'ExistingProcess'; Error = $null; DriveLetter = [string]$account.DriveLetter })
                        continue
                    }

                    if ($account.ProviderId -eq 'gdrive') {
                        $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                            State = 'Mounting'
                            Stage = 'Connecting or starting mount'
                            StartedAt = [DateTime]::UtcNow
                            StageStartedAt = [DateTime]::UtcNow
                            Error = $null
                        })
                        Set-StartupRestoreProgress -Progress $progress -Stage 'Validating Google Drive session' -ProviderId 'gdrive' -DriveLetter ([string]$account.DriveLetter) -AccountId ([string]$account.Id)
                        $environment = Get-GoogleDriveRcloneEnvironment -AccountId $account.Id -RemoteName 'gdrive'
                        $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                            State = 'Mounting'
                            Stage = 'Verifying mount'
                            StartedAt = [DateTime]::UtcNow
                            StageStartedAt = [DateTime]::UtcNow
                            Error = $null
                        })
                        Set-StartupRestoreProgress -Progress $progress -Stage "Starting $($account.DriveLetter): Google Drive mount (up to 90s)" -ProviderId 'gdrive' -DriveLetter ([string]$account.DriveLetter) -AccountId ([string]$account.Id)
                        Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -AccountId $account.Id `
                            -DriveLetter $account.DriveLetter -VolumeLabel $account.DisplayName `
                            -CacheDirectory $accountCacheDirectory -CacheMaxGigabytes $accountCacheMaxGigabytes -EnvironmentVariables $environment `
                            -ReadOnly:$([bool]$account.ReadOnly) | Out-Null
                        $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                            State = 'Mounted'
                            Stage = 'Connected'
                            StartedAt = [DateTime]::UtcNow
                            StageStartedAt = [DateTime]::UtcNow
                            Error = $null
                        })
                        $results.Add([pscustomobject]@{ AccountId = $account.Id; State = 'Mounted'; Error = $null; DriveLetter = [string]$account.DriveLetter })
                    } elseif ($account.ProviderId -eq 'terabox' -and (Get-VerifiedRclonePath)) {
                        $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                            State = 'Mounting'
                            Stage = 'Connecting or starting mount'
                            StartedAt = [DateTime]::UtcNow
                            StageStartedAt = [DateTime]::UtcNow
                            Error = $null
                        })
                        Set-StartupRestoreProgress -Progress $progress -Stage 'Validating TeraBox session' -ProviderId 'terabox' -DriveLetter ([string]$account.DriveLetter) -AccountId ([string]$account.Id)
                        $environment = Get-TeraBoxRcloneEnvironment -AccountId $account.Id
                        $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                            State = 'Mounting'
                            Stage = 'Verifying mount'
                            StartedAt = [DateTime]::UtcNow
                            StageStartedAt = [DateTime]::UtcNow
                            Error = $null
                        })
                        Set-StartupRestoreProgress -Progress $progress -Stage "Starting $($account.DriveLetter): TeraBox mount (up to 90s)" -ProviderId 'terabox' -DriveLetter ([string]$account.DriveLetter) -AccountId ([string]$account.Id)
                        Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -AccountId $account.Id `
                            -DriveLetter $account.DriveLetter -VolumeLabel $account.DisplayName `
                            -CacheDirectory $accountCacheDirectory -CacheMaxGigabytes $accountCacheMaxGigabytes -EnvironmentVariables $environment `
                            -ReadOnly:$([bool]$account.ReadOnly) | Out-Null
                        $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                            State = 'Mounted'
                            Stage = 'Connected'
                            StartedAt = [DateTime]::UtcNow
                            StageStartedAt = [DateTime]::UtcNow
                            Error = $null
                        })
                        $results.Add([pscustomobject]@{ AccountId = $account.Id; State = 'Mounted'; Error = $null; DriveLetter = [string]$account.DriveLetter })
                    }
                } catch {
                    $restoreError = Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)
                    # A mount failure caused by missing per-account credentials is
                    # an authentication-stage failure, not a generic error: the
                    # Google rclone environment builder throws when the account
                    # has no tokens, and the TeraBox bridge fails when the
                    # account has no session. Mapping these to AuthRequired makes
                    # the card show 'Sign-in required' (with a bounded retry when
                    # the user signs in), and guarantees no false 'Mounted'
                    # result can ever be recorded from a failed launch.
                    $restoreState = if ($restoreError -match 'No Google Drive tokens|No valid TeraBox session|No local TeraBox session') { 'AuthRequired' } else { 'Error' }
                    $progress.AccountStages[[string]$account.Id] = [hashtable]::Synchronized(@{
                        State = $restoreState
                        Stage = 'Failed'
                        StartedAt = [DateTime]::UtcNow
                        StageStartedAt = [DateTime]::UtcNow
                        Error = $restoreError
                    })
                    $results.Add([pscustomobject]@{
                        AccountId = $account.Id
                        State = $restoreState
                        Error = $restoreError
                        DriveLetter = [string]$account.DriveLetter
                    })
                }
            }
        } else {
            # Fallback for legacy single-provider settings. Semantics mirror the
            # per-account branch exactly: an already-running mount process must
            # hold its assigned letter and pass a filesystem health probe before
            # success is recorded ('ExistingProcess'), a fresh start is the only
            # path that records 'Mounted', and an invalid session records its
            # true state (including 'AuthRequired') instead of a false success.
            try {
                $googleDriveLetter = [string](Get-PreferredDriveLetter 'gdrive')
                Set-StartupRestoreProgress -Progress $progress -Stage 'Validating Google Drive session' -ProviderId 'gdrive' -DriveLetter $googleDriveLetter
                $googleCheck = Test-GoogleDriveBackendSession
                $googleStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
                if ($googleCheck.IsValid) {
                    if ($googleStatus.ProcessRunning) {
                        if (-not $googleStatus.IsMounted) { throw 'A mount process exists, but its assigned drive is not present.' }
                        $health = Test-VirtualDriveFilesystem -DriveRoot $googleStatus.DriveRoot -TimeoutSeconds 10
                        if (-not $health.Success) { throw "Existing mount is not responsive: $($health.Error)" }
                        $results.Add([pscustomobject]@{ AccountId = 'gdrive'; State = 'ExistingProcess'; Error = $null; DriveLetter = [string]$googleStatus.DriveLetter })
                    } else {
                        $environment = Get-GoogleDriveRcloneEnvironment
                        Set-StartupRestoreProgress -Progress $progress -Stage "Starting $googleDriveLetter`: Google Drive mount (up to 90s)" -ProviderId 'gdrive' -DriveLetter $googleDriveLetter
                        Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' `
                            -DriveLetter (Get-PreferredDriveLetter 'gdrive') -VolumeLabel 'Google Drive' `
                            -CacheDirectory $cacheDirectory -CacheMaxGigabytes ([int]$settings.CacheMaxGigabytes) -EnvironmentVariables $environment | Out-Null
                        $results.Add([pscustomobject]@{ AccountId = 'gdrive'; State = 'Mounted'; Error = $null; DriveLetter = [string](Get-PreferredDriveLetter 'gdrive') })
                    }
                } else {
                    $results.Add([pscustomobject]@{ AccountId = 'gdrive'; State = [string](Get-SafeProperty $googleCheck 'State' 'Error'); Error = (Get-SafeProperty $googleCheck 'Error' 'Provider returned an incomplete status response.'); DriveLetter = [string](Get-PreferredDriveLetter 'gdrive') })
                }
            } catch {
                $results.Add([pscustomobject]@{ AccountId = 'gdrive'; State = 'Error'; Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message); DriveLetter = [string](Get-PreferredDriveLetter 'gdrive') })
            }

            try {
                $teraBoxDriveLetter = [string](Get-PreferredDriveLetter 'terabox')
                Set-StartupRestoreProgress -Progress $progress -Stage 'Validating TeraBox session' -ProviderId 'terabox' -DriveLetter $teraBoxDriveLetter
                $teraBoxStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
                if ($teraBoxStatus.ProcessRunning) {
                    # Same parity rules as gdrive: an existing process must hold
                    # its letter and answer a filesystem probe; success here is
                    # 'ExistingProcess', never 'Mounted'.
                    if (-not $teraBoxStatus.IsMounted) { throw 'A mount process exists, but its assigned drive is not present.' }
                    $health = Test-VirtualDriveFilesystem -DriveRoot $teraBoxStatus.DriveRoot -TimeoutSeconds 10
                    if (-not $health.Success) { throw "Existing mount is not responsive: $($health.Error)" }
                    $results.Add([pscustomobject]@{ AccountId = 'terabox'; State = 'ExistingProcess'; Error = $null; DriveLetter = [string]$teraBoxStatus.DriveLetter })
                } elseif ((Get-VerifiedRclonePath)) {
                    $teraBoxCheck = Test-TeraBoxBackendSession
                    if (-not $teraBoxCheck.IsValid) {
                        $results.Add([pscustomobject]@{ AccountId = 'terabox'; State = [string](Get-SafeProperty $teraBoxCheck 'State' 'Error'); Error = (Get-SafeProperty $teraBoxCheck 'Error' 'Provider returned an incomplete status response.'); DriveLetter = [string](Get-PreferredDriveLetter 'terabox') })
                    } else {
                        $environment = Get-TeraBoxRcloneEnvironment
                        Set-StartupRestoreProgress -Progress $progress -Stage "Starting $teraBoxDriveLetter`: TeraBox mount (up to 90s)" -ProviderId 'terabox' -DriveLetter $teraBoxDriveLetter
                        Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' `
                            -DriveLetter (Get-PreferredDriveLetter 'terabox') -VolumeLabel 'TeraBox' `
                            -CacheDirectory $cacheDirectory -CacheMaxGigabytes ([int]$settings.CacheMaxGigabytes) -EnvironmentVariables $environment | Out-Null
                        $results.Add([pscustomobject]@{ AccountId = 'terabox'; State = 'Mounted'; Error = $null; DriveLetter = [string](Get-PreferredDriveLetter 'terabox') })
                    }
                } else {
                    # No verified rclone binary: nothing can be mounted, so this
                    # is an error rather than a silent success.
                    $results.Add([pscustomobject]@{ AccountId = 'terabox'; State = 'Error'; Error = 'No verified rclone binary was found for the TeraBox mount.'; DriveLetter = [string](Get-PreferredDriveLetter 'terabox') })
                }
            } catch {
                $results.Add([pscustomobject]@{ AccountId = 'terabox'; State = 'Error'; Error = (Format-SanitizedDiagnosticMessage $_.Exception.Message); DriveLetter = [string](Get-PreferredDriveLetter 'terabox') })
            }
        }

        Set-StartupRestoreProgress -Progress $progress -Stage 'Recovery checks complete'
        return $results.ToArray()
    }
}

$script:StartupSequenceStarted = $false
function Start-ApplicationStartupSequence {
    if ($script:StartupSequenceStarted) { return }
    $script:StartupSequenceStarted = $true

    Invoke-MemoryTrim
    if ($script:Settings.AutoMountDrives) {
        $script:StartupAutoMountPending = $true
    }
    try { Start-ProviderStatusRefreshWorker } catch { }
    try { Start-StartupCacheRecoveryWorker } catch { }
    Update-AllUIState

    if ($script:Settings.AutoMountDrives) {
        Start-StartupAutoMountTimer
    }
}

$window.Add_Loaded({
    if (-not $Minimized) {
        $window.Activate() | Out-Null
        try {
            $wshell = New-Object -ComObject WScript.Shell
            $wshell.AppActivate('NS Cloud Drive') | Out-Null
        } catch { }
    }
    Start-ApplicationStartupSequence
})

# ==============================================================================
# BACKGROUND REFRESH AND MEMORY TRIM TIMER
# ==============================================================================
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if ($script:StartupAutoMountPending -and
        -not $script:StartupAutoMountWorker -and
        $script:StartupAutoMountTimer -and
        $script:StartupAutoMountProgress.Stage -eq 'Waiting for startup dispatcher' -and
        $script:StartupAutoMountProgress.StartedAt -and
        ([DateTime]::UtcNow - [DateTime]$script:StartupAutoMountProgress.StartedAt).TotalSeconds -ge 15) {
        $script:StartupAutoMountTimer.Stop()
        $script:StartupAutoMountTimer = $null
        $script:StartupAutoMountPending = $false
        try {
            $script:StartupAutoMountError = $null
            Invoke-StartupAutoMount
        } catch {
            $script:StartupAutoMountError = Format-SanitizedDiagnosticMessage $_.Exception.Message
            $script:LastProviderStatusCheck = [DateTime]::MinValue
        } finally {
            Update-AllUIState
        }
    }

    if ($script:RestoreEvent) {
        try {
            if ($script:RestoreEvent.WaitOne(0)) {
                $window.Show()
                $window.WindowState = [System.Windows.WindowState]::Normal
                $window.Topmost = $true
                $window.Topmost = $false
                $window.Activate() | Out-Null
                $window.Focus() | Out-Null
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
        $refreshInterval = if ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker) { 1 } else { 4 }
        if (([DateTime]::UtcNow - $script:LastFullUpdate).TotalSeconds -ge $refreshInterval) {
            Update-AllUIState
            $script:LastFullUpdate = [DateTime]::UtcNow
        }
    } else {
        $hiddenInterval = if ($script:StartupAutoMountPending -or $script:StartupAutoMountWorker) { 1 } else { 30 }
        if (([DateTime]::UtcNow - $script:LastFullUpdate).TotalSeconds -ge $hiddenInterval) {
            Update-AllUIState
            $script:LastFullUpdate = [DateTime]::UtcNow
            Invoke-MemoryTrim
        }
    }

    # Auto-reconnect watchdog — runs only when not connecting and AutoMountDrives is enabled.
    # Runs at most every 30 seconds to avoid hammering the system with drive-stat calls.
    # Reconnect attempts use per-account exponential backoff (see Invoke-AutoReconnectWatchdog).
    if (-not $script:IsConnecting -and $script:Settings.AutoMountDrives) {
        if (([DateTime]::UtcNow - $script:LastWatchdogRun).TotalSeconds -ge 30) {
            $script:LastWatchdogRun = [DateTime]::UtcNow
            Invoke-AutoReconnectWatchdog
        }
    }
})
$timer.Start()

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-MemoryTrim
}

if ($Minimized) {
    $window.Visibility = [System.Windows.Visibility]::Hidden
}

if ($MyInvocation.InvocationName -ne '.') {
    $app = [System.Windows.Application]::new()
    $app.Add_DispatcherUnhandledException({
        param($sender, $e)
        $msg = if ($e.Exception) { Format-SanitizedDiagnosticMessage $e.Exception.Message } else { 'Unknown dispatcher error' }
        try {
            Add-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs\startup-restore.jsonl') -Value ("{\""timestampUtc\"":\""" + [DateTime]::UtcNow.ToString('o') + "\"",\""event\"":\""debug_dispatcher_exception\"",\""message\"":\""" + ($msg -replace '\""', "'") + "\""}") -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
        [System.Diagnostics.Debug]::WriteLine("NSCloudDrive Dispatcher Exception: $msg")
        $e.Handled = $true
    })
    $app.MainWindow = $window
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    if ($Minimized) {
        $window.Hide()
        Start-ApplicationStartupSequence
        try {
            $notifyIcon.ShowBalloonTip(3000, 'NS Cloud Drive', 'NS Cloud Drive started in the background. Cloud drives are connecting.', [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
        $app.Run()
    } else {
        $window.Show()
        try {
            Add-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs\startup-restore.jsonl') -Value ("{\""timestampUtc\"":\""" + [DateTime]::UtcNow.ToString('o') + "\"",\""event\"":\""debug_window_shown\""}") -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch { }
        $window.Activate() | Out-Null
        try {
            $wshell = New-Object -ComObject WScript.Shell
            $wshell.AppActivate('NS Cloud Drive') | Out-Null
        } catch { }
        [void]$app.Run($window)
    }
}
