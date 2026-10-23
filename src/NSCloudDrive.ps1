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

Add-Type -MemberDefinition '[DllImport("psapi.dll")] public static extern int EmptyWorkingSet(IntPtr hwProc);' -Name 'Win32' -Namespace 'NSCloudDrive' -ErrorAction SilentlyContinue

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
. (Join-Path $PSScriptRoot 'ui\EmbeddedBrowserWindow.ps1')
. (Join-Path $PSScriptRoot 'ui\ProviderConnectionWindow.ps1')

$script:Settings = Get-NSCloudDriveSettings
if (-not $PSBoundParameters.ContainsKey('Minimized') -and $script:Settings.StartMinimized) {
    $Minimized = [switch]::Present
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

function Get-VerifiedRclonePath {
    $r = Find-RcloneBinary
    if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) {
        return $r
    }
    return $null
}

function Get-WpfBitmapImage([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
            $bmp.BeginInit()
            $bmp.UriSource = [System.Uri]::new((Resolve-Path $Path).Path)
            $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bmp.EndInit()
            $bmp.Freeze()
            return $bmp
        } catch { }
    }
    return $null
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
    $provLogoPath = if ($ProviderId -eq 'gdrive') {
        Join-Path $PSScriptRoot '..\assets\logos\googledrive.png'
    } else {
        Join-Path $PSScriptRoot '..\assets\logos\terabox.png'
    }
    $provBmp = Get-WpfBitmapImage $provLogoPath
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
        if ($selected -eq 'gdrive') {
            $created = Connect-NewCloudAccount -Owner $window -ProviderId 'gdrive'
            if ($created) {
                try {
                    $remoteName = if ($created.Id) { [regex]::Replace($created.Id, '[^a-zA-Z0-9_\-]', '_') } else { 'gdrive' }
                    $envVars = Get-GoogleDriveRcloneEnvironment -AccountId $created.Id -RemoteName $remoteName
                    $res = Start-VirtualDriveMount -RemoteName $remoteName -ProviderId 'gdrive' -AccountId $created.Id -DriveLetter $created.DriveLetter -VolumeLabel $created.DisplayName -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars
                    if ($res.Success -and $script:Settings.OpenExplorerOnMount) {
                        Start-ExplorerWindow $res.DriveRoot
                    }
                } catch { }
                Update-AllUIState
                Invoke-MemoryTrim
            }
        } elseif ($selected -eq 'terabox') {
            $created = Connect-NewCloudAccount -Owner $window -ProviderId 'terabox'
            if ($created) {
                try {
                    $remoteName = if ($created.Id) { [regex]::Replace($created.Id, '[^a-zA-Z0-9_\-]', '_') } else { 'terabox' }
                    $tbEnvVars = Get-TeraBoxRcloneEnvironment -AccountId $created.Id
                    $res = Start-VirtualDriveMount -RemoteName $remoteName -ProviderId 'terabox' -AccountId $created.Id -DriveLetter $created.DriveLetter -VolumeLabel $created.DisplayName -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars
                    if ($res.Success -and $script:Settings.OpenExplorerOnMount) {
                        Start-ExplorerWindow $res.DriveRoot
                    }
                } catch { }
                Update-AllUIState
                Invoke-MemoryTrim
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

# --- Providers Container (Grid required by regression test suite) ---
$providersGrid = [System.Windows.Controls.Grid]::new()
$providersGrid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
$rowGd = [System.Windows.Controls.RowDefinition]::new()
$rowGd.Height = [System.Windows.GridLength]::Auto
$rowTb = [System.Windows.Controls.RowDefinition]::new()
$rowTb.Height = [System.Windows.GridLength]::Auto
$providersGrid.RowDefinitions.Add($rowGd)
$providersGrid.RowDefinitions.Add($rowTb)
$content.Children.Add($providersGrid) | Out-Null

$accountsStack = [System.Windows.Controls.StackPanel]::new()
$content.Children.Add($accountsStack) | Out-Null

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

$optStartupChk = [System.Windows.Controls.CheckBox]::new()
$optStartupChk.Content = 'Run NS Cloud Drive at Windows login'
$optStartupChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optStartupChk.IsChecked = (Test-WindowsStartupEnabled)
$optStartupChk.Margin = [System.Windows.Thickness]::new(0, 12, 0, 8)
$optStartupChk.Add_Click({
    $c = ($optStartupChk.IsChecked -eq $true)
    Set-WindowsStartupEnabled -Enable $c
    $script:Settings.AutoStartWithWindows = $c
    Set-NSCloudDriveSettings $script:Settings
})
$genStack.Children.Add($optStartupChk) | Out-Null

$optTrayChk = [System.Windows.Controls.CheckBox]::new()
$optTrayChk.Content = 'Minimize to system tray on close'
$optTrayChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optTrayChk.IsChecked = $script:Settings.MinimizeToTrayOnClose
$optTrayChk.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$optTrayChk.Add_Click({
    $script:Settings.MinimizeToTrayOnClose = ($optTrayChk.IsChecked -eq $true)
    Set-NSCloudDriveSettings $script:Settings
})
$genStack.Children.Add($optTrayChk) | Out-Null

$optStartMinChk = [System.Windows.Controls.CheckBox]::new()
$optStartMinChk.Content = 'Start application minimized to system tray'
$optStartMinChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optStartMinChk.IsChecked = $script:Settings.StartMinimized
$optStartMinChk.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$optStartMinChk.Add_Click({
    $script:Settings.StartMinimized = ($optStartMinChk.IsChecked -eq $true)
    Set-NSCloudDriveSettings $script:Settings
})
$genStack.Children.Add($optStartMinChk) | Out-Null

$optExplorerChk = [System.Windows.Controls.CheckBox]::new()
$optExplorerChk.Content = 'Open Windows File Explorer automatically on connect'
$optExplorerChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optExplorerChk.IsChecked = $script:Settings.OpenExplorerOnMount
$optExplorerChk.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$optExplorerChk.Add_Click({
    $script:Settings.OpenExplorerOnMount = ($optExplorerChk.IsChecked -eq $true)
    Set-NSCloudDriveSettings $script:Settings
})
$genStack.Children.Add($optExplorerChk) | Out-Null

$optAutoMountChk = [System.Windows.Controls.CheckBox]::new()
$optAutoMountChk.Content = 'Automatically mount cloud drives on startup'
$optAutoMountChk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$optAutoMountChk.IsChecked = $script:Settings.AutoMountDrives
$optAutoMountChk.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
$optAutoMountChk.Add_Click({
    $script:Settings.AutoMountDrives = ($optAutoMountChk.IsChecked -eq $true)
    Set-NSCloudDriveSettings $script:Settings
})
$genStack.Children.Add($optAutoMountChk) | Out-Null

# Card B: Theme Selection (Pure Black, Translucent, Pure White)
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

$rbThemeTranslucent = [System.Windows.Controls.RadioButton]::new()
$rbThemeTranslucent.GroupName = 'ThemeSelection'
$rbThemeTranslucent.Content = 'Translucent (Dark acrylic glass appearance)'
$rbThemeTranslucent.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$rbThemeTranslucent.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$themeStack.Children.Add($rbThemeTranslucent) | Out-Null

$rbThemePureWhite = [System.Windows.Controls.RadioButton]::new()
$rbThemePureWhite.GroupName = 'ThemeSelection'
$rbThemePureWhite.Content = 'Pure White (Clean light theme with subtle separators)'
$rbThemePureWhite.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$rbThemePureWhite.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
$themeStack.Children.Add($rbThemePureWhite) | Out-Null

$currResolvedTheme = Resolve-AppTheme $script:Settings.Theme
if ($currResolvedTheme -eq 'PureBlack') {
    $rbThemePureBlack.IsChecked = $true
} elseif ($currResolvedTheme -eq 'Translucent') {
    $rbThemeTranslucent.IsChecked = $true
} elseif ($currResolvedTheme -eq 'PureWhite') {
    $rbThemePureWhite.IsChecked = $true
}

$rbThemePureBlack.Add_Checked({
    $script:Settings.Theme = 'PureBlack'
    Set-NSCloudDriveSettings $script:Settings
    Apply-UITheme 'PureBlack'
})
$rbThemeTranslucent.Add_Checked({
    $script:Settings.Theme = 'Translucent'
    Set-NSCloudDriveSettings $script:Settings
    Apply-UITheme 'Translucent'
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

$browseCacheBtn = [System.Windows.Controls.Button]::new()
$browseCacheBtn.Content = 'Browse...'
$browseCacheBtn.Padding = [System.Windows.Thickness]::new(10, 2, 10, 2)
$browseCacheBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBg)
$browseCacheBtn.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.ButtonBorder)
$browseCacheBtn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextPrimary)
$browseCacheBtn.Cursor = [System.Windows.Input.Cursors]::Hand
[System.Windows.Controls.DockPanel]::SetDock($browseCacheBtn, 'Right')
$cachePathRow.Children.Add($browseCacheBtn) | Out-Null

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
foreach ($sz in @(10, 20, 50, 100)) {
    [void]$cacheQuotaCombo.Items.Add("$($sz) GB")
}
$currQuota = if ($script:Settings.CacheMaxGigabytes) { $script:Settings.CacheMaxGigabytes } else { 20 }
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
    try {
        $res = Invoke-SafeCacheCleanup -CacheDirectory $script:CacheDirectory -Force
        $mbCleaned = [Math]::Round($res.CleanedBytes / 1MB, 1)
        if ($res.SkippedInUseCount -gt 0) {
            $cacheUsageLabel.Text = "Cleaned $mbCleaned MB ($($res.CleanedFiles) files). $($res.SkippedInUseCount) files protected in-use by active mounts."
            $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#60A5FA')
        } else {
            $cacheUsageLabel.Text = "Cache cleared successfully ($mbCleaned MB reclaimed)."
            $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
        }
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
    if (-not (Test-Path -LiteralPath $script:CacheDirectory)) {
        New-Item -ItemType Directory -Path $script:CacheDirectory -Force | Out-Null
    }
    Start-ExplorerWindow $script:CacheDirectory
})
$cacheActionStack.Children.Add($openCacheBtn) | Out-Null

# Card D: Diagnostics & System Health
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
    Invoke-MemoryTrim
    $diagDescLabel.Text = 'Memory working set trimmed. Current process memory reclaimed.'
    $diagDescLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')
})
$diagBtnRow.Children.Add($trimMemBtn) | Out-Null

# ------------------------------------------------------------------------------
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

# ==============================================================================
# SAFE SYSTEM DIAGNOSTICS MODAL
# ==============================================================================
function Show-SystemDiagnosticsModal([System.Windows.Window]$Owner = $null) {
    $p = Get-MainThemePalette $script:Settings.Theme
    $diagWin = [System.Windows.Window]::new()
    $diagWin.Title = 'NS Cloud Drive - System Diagnostics'
    $diagWin.Width = 560
    $diagWin.Height = 490
    $diagWin.MinWidth = 500
    $diagWin.MinHeight = 400
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
            $vLbl = New-Label ($Metrics[$k].ToString()) 11 $p.TextPrimary $true
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

        Add-DiagMetric 'Application Process' ([ordered]@{
            'Process ID (PID)' = $PID
            'Process Name' = $proc.ProcessName
            'Working Set RAM' = "$wsMb MB"
            'Private Memory' = "$pmMb MB"
            'Thread Count' = $threads
            'Theme Active' = (Resolve-AppTheme $script:Settings.Theme)
        })

        $winfspStatus = if (Test-WinFspInstalled) { 'Installed & Operational' } else { 'Not Detected' }
        $rclonePath = Find-RcloneBinary
        $rcloneStatus = if ($rclonePath -and (Test-Path -LiteralPath $rclonePath -PathType Leaf)) { $rclonePath } else { 'Not Found' }

        Add-DiagMetric 'Filesystem Subsystem' ([ordered]@{
            'WinFsp Driver' = $winfspStatus
            'rclone Engine' = $rcloneStatus
            'Cache Target' = $script:CacheDirectory
            'Cache Max Quota' = "$($script:Settings.CacheMaxGigabytes) GB"
        })

        $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
        $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
        $mountInfo = [ordered]@{}
        $mountInfo['Google Drive'] = if ($gdStatus.IsMounted) { "Mounted ($($gdStatus.DriveLetter):)" } else { 'Disconnected' }
        $mountInfo['TeraBox'] = if ($tbStatus.IsMounted) { "Mounted ($($tbStatus.DriveLetter):)" } else { 'Disconnected' }

        $accounts = Get-CloudAccounts
        if ($accounts) {
            foreach ($acc in $accounts) {
                if ($acc.Id -notlike 'test_*' -and $acc.AccountEmail -notin @('personal@gmail.com', 'work@company.com', 'terabox_user')) {
                    $st = Get-VirtualDriveStatus -AccountId $acc.Id -ProviderId $acc.ProviderId
                    $mountInfo["Account ($($acc.DisplayName))"] = if ($st.IsMounted) { "Mounted ($($st.DriveLetter):)" } else { 'Disconnected' }
                }
            }
        }
        Add-DiagMetric 'Mounted Drive Allocations' $mountInfo
    }

    $trimBtn.Add_Click({
        Invoke-MemoryTrim
        & $populateData
    })

    & $populateData
    $diagWin.ShowDialog() | Out-Null
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
        $chk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
    }
    foreach ($rb in @($rbThemePureBlack, $rbThemeTranslucent, $rbThemePureWhite)) {
        $rb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.TextPrimary)
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

    Update-NavActiveState
}

function Update-NavActiveState {
    $p = $script:Palette
    foreach ($item in @(
        @{ Nav = $navDisksItem; View = 'Disks' },
        @{ Nav = $navOptionsItem; View = 'Options' },
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
    Update-NavActiveState
}

function Update-CacheUsageDisplay {
    try {
        $st = Get-DetailedCacheStatistics -CacheDirectory $script:CacheDirectory
        $mbTotal = [Math]::Round($st.TotalSizeBytes / 1MB, 1)
        $mbInUse = [Math]::Round($st.InUseBytes / 1MB, 1)
        $gbFree = [Math]::Round($st.DriveFreeBytes / 1GB, 1)
        $osNotice = if ($st.IsSystemDrive) { " (OS Drive Warning)" } else { "" }
        $cacheUsageLabel.Text = "Total: $mbTotal MB ($($st.TotalFileCount) files) â€¢ In-Use: $mbInUse MB ($($st.InUseCount) locked) â€¢ Free on $($st.DriveLetter): $gbFree GB$osNotice"
        $cacheUsageLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextSecondary)
    } catch { }
}

function Show-OptionsView {
    $script:CurrentView = "Options"
    $disksView.Visibility = [System.Windows.Visibility]::Collapsed
    $optionsView.Visibility = [System.Windows.Visibility]::Visible
    $helpView.Visibility = [System.Windows.Visibility]::Collapsed
    Update-NavActiveState

    Update-CacheUsageDisplay
}

function Show-HelpView {
    $script:CurrentView = 'Help'
    $disksView.Visibility = [System.Windows.Visibility]::Collapsed
    $optionsView.Visibility = [System.Windows.Visibility]::Collapsed
    $helpView.Visibility = [System.Windows.Visibility]::Visible
    Update-NavActiveState
}

$navDisksItem.Button.Add_Click({ Show-DisksView })
$navOptionsItem.Button.Add_Click({ Show-OptionsView })
$navHelpItem.Button.Add_Click({ Show-HelpView })
$backToDisksBtn.Add_Click({ Show-DisksView })

# Apply active theme immediately
Apply-UITheme $script:Settings.Theme

# ==============================================================================
# UI STATE SYNCHRONIZER
# ==============================================================================
function Update-AllUIState {
    if ($script:IsConnecting) { return }

    # 1. Google Drive State
    $gdCheck = Test-GoogleDriveBackendSession
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'

    if ($gdCheck.IsValid) {
        $dispName = if ($gdCheck.UserInfo) { Get-SafeProperty $gdCheck.UserInfo 'DisplayName' $null } else { $null }
        $emailAddr = if ($gdCheck.UserInfo) { Get-SafeProperty $gdCheck.UserInfo 'EmailAddress' '' } else { '' }
        $userDisplay = if ($dispName) { $dispName } else { $emailAddr }
        if (-not $userDisplay -or $userDisplay -eq 'Google Drive User') {
            try {
                $accs = Get-CloudAccounts
                $primaryGd = $accs | Where-Object { $_.ProviderId -eq 'gdrive' } | Select-Object -First 1
                if ($primaryGd) {
                    if ($primaryGd.DisplayName) { $userDisplay = $primaryGd.DisplayName }
                    if ($primaryGd.AccountEmail) { $emailAddr = $primaryGd.AccountEmail }
                }
            } catch { }
        }
        if (-not $userDisplay) { $userDisplay = 'Google Drive' }

        $gdNameLabel.Text = $userDisplay
        $gdAccountText.Text = if ($emailAddr) { $emailAddr } else { 'Connected' }
        $gdErrorText.Visibility = 'Collapsed'

        $gdTotal = if ($gdCheck.UserInfo) { [int64](Get-SafeProperty $gdCheck.UserInfo 'QuotaTotal' (Get-SafeProperty $gdCheck.UserInfo 'QuotaTotalBytes' 0)) } else { 0L }
        $gdUsed = if ($gdCheck.UserInfo) { [int64](Get-SafeProperty $gdCheck.UserInfo 'QuotaUsed' (Get-SafeProperty $gdCheck.UserInfo 'QuotaUsedBytes' 0)) } else { 0L }

        if ($gdTotal -gt 0) {
            $freeBytes = [Math]::Max(0L, ($gdTotal - $gdUsed))
            $freeTb = [Math]::Round($freeBytes / 1TB, 2)
            $totalTb = [Math]::Round($gdTotal / 1TB, 2)
            $pct = [Math]::Round(($gdUsed / $gdTotal) * 100, 1)

            $gdStorageBar.Value = [Math]::Min(100, [Math]::Max(0, $pct))
            $gdStorageBar.Visibility = 'Visible'
            $gdQuotaText.Text = "$freeTb TB free of $totalTb TB"
            $gdQuotaText.Visibility = 'Visible'
        } else {
            $gdStorageBar.Visibility = 'Collapsed'
            $gdQuotaText.Visibility = 'Collapsed'
        }

        if ($gdStatus.IsMounted) {
            $gdStatusText.Text = ([string][char]0x25CF + ' Mounted (' + $gdStatus.DriveLetter + ':)')
            $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillMounted)

            $gdActionBtn.Content = 'Disconnect'
            $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
            $gdLetterCombo.IsEnabled = $false
            $gdExplorerBtn.IsEnabled = $true
            $gdUploadBtn.IsEnabled = $true
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
        $gdNameLabel.Text = 'Google Drive'
        $gdState = Get-SafeProperty $gdCheck 'State' ''
        $gdErr = Get-SafeProperty $gdCheck 'Error' ''
        if ($gdState -eq 'AuthenticationExpired') {
            $gdAccountText.Text = 'Session expired. Click Connect to re-authenticate.'
            $gdErrorText.Text = if ($gdErr) { $gdErr } else { 'Session expired.' }
            $gdErrorText.Visibility = 'Visible'
        } else {
            $gdAccountText.Text = 'Not connected'
            $gdErrorText.Visibility = 'Collapsed'
        }

        $gdStorageBar.Visibility = 'Collapsed'
        $gdQuotaText.Visibility = 'Collapsed'

        $gdStatusText.Text = ([string][char]0x25CF + ' Disconnected')
        $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextMuted)

        $gdActionBtn.Content = 'Connect'
        $gdActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
        $gdLetterCombo.IsEnabled = $true
        $gdExplorerBtn.IsEnabled = $false
        $gdUploadBtn.IsEnabled = $false
    }

    # 2. TeraBox State
    $tbCheck = Test-TeraBoxBackendSession
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'

    if ($tbCheck.IsValid) {
        $tbUName = if ($tbCheck.UserInfo) { Get-SafeProperty $tbCheck.UserInfo 'UserName' 'TeraBox User' } else { 'TeraBox User' }
        $tbDisplayName = 'TeraBox'
        if ($tbUName -eq 'TeraBox User') {
            try {
                $accs = Get-CloudAccounts
                $primaryTb = $accs | Where-Object { $_.ProviderId -eq 'terabox' } | Select-Object -First 1
                if ($primaryTb) {
                    if ($primaryTb.DisplayName) { $tbDisplayName = $primaryTb.DisplayName }
                    if ($primaryTb.AccountEmail) { $tbUName = $primaryTb.AccountEmail }
                }
            } catch { }
        }
        $tbNameLabel.Text = $tbDisplayName
        $tbAccountText.Text = $tbUName
        $tbErrorText.Visibility = 'Collapsed'

        $tbTotal = if ($tbCheck.UserInfo) { [int64](Get-SafeProperty $tbCheck.UserInfo 'QuotaTotal' (Get-SafeProperty $tbCheck.UserInfo 'QuotaTotalBytes' 0)) } else { 0L }
        $tbUsed = if ($tbCheck.UserInfo) { [int64](Get-SafeProperty $tbCheck.UserInfo 'QuotaUsed' (Get-SafeProperty $tbCheck.UserInfo 'QuotaUsedBytes' 0)) } else { 0L }

        if ($tbTotal -gt 0) {
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

        if ($tbStatus.IsMounted) {
            $tbStatusText.Text = ([string][char]0x25CF + ' Mounted (' + $tbStatus.DriveLetter + ':)')
            $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillMounted)

            $tbActionBtn.Content = 'Disconnect'
            $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Danger)
            $tbLetterCombo.IsEnabled = $false
            $tbExplorerBtn.IsEnabled = $true
            $tbUploadBtn.IsEnabled = $true
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
        $tbNameLabel.Text = 'TeraBox'
        $tbState = Get-SafeProperty $tbCheck 'State' ''
        $tbErr = Get-SafeProperty $tbCheck 'Error' ''
        if ($tbState -eq 'AuthenticationExpired') {
            $tbAccountText.Text = 'Session expired. Click Connect to re-authenticate.'
            $tbErrorText.Text = if ($tbErr) { $tbErr } else { 'Session expired.' }
            $tbErrorText.Visibility = 'Visible'
        } else {
            $tbAccountText.Text = 'Not connected'
            $tbErrorText.Visibility = 'Collapsed'
        }

        $tbStorageBar.Visibility = 'Collapsed'
        $tbQuotaText.Visibility = 'Collapsed'

        $tbStatusText.Text = ([string][char]0x25CF + ' Disconnected')
        $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.TextMuted)

        $tbActionBtn.Content = 'Connect'
        $tbActionBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.Accent)
        $tbLetterCombo.IsEnabled = $true
        $tbExplorerBtn.IsEnabled = $false
        $tbUploadBtn.IsEnabled = $false
    }

    # 3. Dynamic Multi-Account Cards
    $accountsStack.Children.Clear()
    $allAccounts = @()
    try {
        $rawAccs = Get-CloudAccounts
        if ($rawAccs) {
            foreach ($acc in $rawAccs) {
                if ($acc.Id -notlike 'test_*' -and $acc.AccountEmail -notin @('personal@gmail.com', 'work@company.com', 'terabox_user')) {
                    $allAccounts += $acc
                }
            }
        }
    } catch { }

    if ($allAccounts -and $allAccounts.Count -gt 0) {
        $p = $script:Palette
        $secLabel = New-Label 'ADDITIONAL CONNECTED DRIVES' 11 $p.TextSecondary $true
        $secLabel.Margin = [System.Windows.Thickness]::new(2, 6, 0, 8)
        $accountsStack.Children.Add($secLabel) | Out-Null

        foreach ($acc in $allAccounts) {
            $aCard = [System.Windows.Controls.Border]::new()
            $aCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.CardBg)
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

            $aName = New-Label $acc.DisplayName 15 $p.TextPrimary $true
            $aInfoStack.Children.Add($aName) | Out-Null

            $aEmailText = if ($acc.AccountEmail) { $acc.AccountEmail } else { 'Drive: ' + $acc.DriveLetter + ':' }
            $aEmail = New-Label $aEmailText 11 $p.TextSecondary
            $aEmail.Margin = [System.Windows.Thickness]::new(0, 1, 0, 6)
            $aInfoStack.Children.Add($aEmail) | Out-Null

            $aActionRow = [System.Windows.Controls.StackPanel]::new()
            $aActionRow.Orientation = 'Horizontal'
            $aActionRow.VerticalAlignment = 'Center'
            $aInfoStack.Children.Add($aActionRow) | Out-Null

            $aStatus = Get-VirtualDriveStatus -AccountId $acc.Id -ProviderId $acc.ProviderId

            $aBtn = [System.Windows.Controls.Button]::new()
            $aBtn.Padding = [System.Windows.Thickness]::new(16, 5, 16, 5)
            $aBtn.Height = 28
            $aBtn.MinWidth = 85
            $aBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
            $aBtn.FontSize = 12
            $aBtn.BorderThickness = [System.Windows.Thickness]::new(0)
            $aBtn.Cursor = [System.Windows.Input.Cursors]::Hand

            $currAcc = $acc
            if ($aStatus.IsMounted) {
                $aBtn.Content = 'Disconnect'
                $aBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Danger)
                $aBtn.Foreground = [System.Windows.Media.Brushes]::White
                $aBtn.Add_Click({
                    Stop-VirtualDriveMount -AccountId $currAcc.Id -ProviderId $currAcc.ProviderId | Out-Null
                    Update-AllUIState
                })
            } else {
                $aBtn.Content = 'Connect'
                $aBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($p.Accent)
                $aBtn.Foreground = [System.Windows.Media.Brushes]::White
                $aBtn.Add_Click({
                    try {
                        if ($currAcc.ProviderId -eq 'gdrive') {
                            $remoteName = if ($currAcc.Id) { [regex]::Replace($currAcc.Id, '[^a-zA-Z0-9_\-]', '_') } else { 'gdrive' }
                            $envVars = Get-GoogleDriveRcloneEnvironment -AccountId $currAcc.Id -RemoteName $remoteName
                            Start-VirtualDriveMount -RemoteName $remoteName -ProviderId 'gdrive' -AccountId $currAcc.Id -DriveLetter $currAcc.DriveLetter -VolumeLabel $currAcc.DisplayName -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars | Out-Null
                        } elseif ($currAcc.ProviderId -eq 'terabox') {
                            $remoteName = if ($currAcc.Id) { [regex]::Replace($currAcc.Id, '[^a-zA-Z0-9_\-]', '_') } else { 'terabox' }
                            $tbEnvVars = Get-TeraBoxRcloneEnvironment -AccountId $currAcc.Id
                            Start-VirtualDriveMount -RemoteName $remoteName -ProviderId 'terabox' -AccountId $currAcc.Id -DriveLetter $currAcc.DriveLetter -VolumeLabel $currAcc.DisplayName -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars | Out-Null
                        }
                    } catch { }
                    Update-AllUIState
                })
            }
            $aActionRow.Children.Add($aBtn) | Out-Null

            $aInLabel = New-Label 'in' 12 $p.TextSecondary
            $aInLabel.VerticalAlignment = 'Center'
            $aInLabel.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
            $aActionRow.Children.Add($aInLabel) | Out-Null

            $aCombo = [System.Windows.Controls.ComboBox]::new()
            $aCombo.Width = 56
            $aCombo.Height = 28
            $aCombo.VerticalContentAlignment = 'Center'
            $aCombo.IsEnabled = (-not $aStatus.IsMounted)
            foreach ($l in $driveLetters) { [void]$aCombo.Items.Add("$($l):") }
            $aCombo.SelectedItem = "$($currAcc.DriveLetter):"
            $aCombo.Add_SelectionChanged({
                if ($aCombo.SelectedItem) {
                    $sel = $aCombo.SelectedItem.ToString().TrimEnd(':')
                    $currAcc.DriveLetter = $sel
                    Update-CloudAccount -Account $currAcc | Out-Null
                }
            })
            $aActionRow.Children.Add($aCombo) | Out-Null

            $aExpBtn = New-QuickIconButton ([char]::ConvertFromUtf32(0x1F4C1)) 'Open in Windows File Explorer'
            $aExpBtn.IsEnabled = $aStatus.IsMounted
            $aExpBtn.Add_Click({
                Start-ExplorerWindow ($currAcc.DriveLetter + ':\')
            })
            $aActionRow.Children.Add($aExpBtn) | Out-Null

            $aSetBtn = New-QuickIconButton ([string][char]0x2699) 'Account Options'
            $aSetBtn.Add_Click({
                $savedAcc = Show-CloudAccountSetupModal -Owner $window -ProviderId $currAcc.ProviderId -InitialAccount $currAcc -Theme $script:Settings.Theme
                if ($savedAcc) {
                    Update-CloudAccount -Account $savedAcc | Out-Null
                    Update-AllUIState
                }
            })
            $aActionRow.Children.Add($aSetBtn) | Out-Null

            $aUpBtn = New-QuickIconButton ([string][char]0x2191) 'Upload Files'
            $aUpBtn.IsEnabled = $aStatus.IsMounted
            $aUpBtn.Add_Click({
                Show-UploadDialog -DriveLetter $currAcc.DriveLetter -ParentWindow $window
            })
            $aActionRow.Children.Add($aUpBtn) | Out-Null

            $aRemBtn = New-QuickIconButton ([string][char]0x2715) 'Disconnect and Remove'
            $aRemBtn.Add_Click({
                Stop-VirtualDriveMount -AccountId $currAcc.Id -ProviderId $currAcc.ProviderId | Out-Null
                Remove-CloudAccount -AccountId $currAcc.Id | Out-Null
                Update-AllUIState
            })
            $aActionRow.Children.Add($aRemBtn) | Out-Null

            # Col 2: Status
            $aRightStack = [System.Windows.Controls.StackPanel]::new()
            $aRightStack.VerticalAlignment = 'Center'
            $aRightStack.HorizontalAlignment = 'Right'
            $aRightStack.Width = 220
            $aRightStack.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
            [System.Windows.Controls.Grid]::SetColumn($aRightStack, 2)
            $aGrid.Children.Add($aRightStack) | Out-Null

            $pillText = if ($aStatus.IsMounted) { [string][char]0x25CF + ' Mounted (' + $aStatus.DriveLetter + ':)' } else { [string][char]0x25CF + ' Ready to connect' }
            $pillColor = if ($aStatus.IsMounted) { $p.PillMounted } else { $p.PillConnected }
            $aStatusLbl = New-Label $pillText 11 $pillColor $true
            $aStatusLbl.HorizontalAlignment = 'Right'
            $aRightStack.Children.Add($aStatusLbl) | Out-Null

            $accountsStack.Children.Add($aCard) | Out-Null
        }
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

        foreach ($srcFile in $dlg.FileNames) {
            try {
                $fName = [System.IO.Path]::GetFileName($srcFile)
                $destPath = Join-Path $driveRoot $fName
                [System.IO.File]::Copy($srcFile, $destPath, $true)
                $uploaded++
            } catch {
                $failed++
                $errMsgs += "$([System.IO.Path]::GetFileName($srcFile)): $($_.Exception.Message)"
            }
        }

        if ($failed -eq 0) {
            [System.Windows.MessageBox]::Show('Successfully uploaded ' + $uploaded + ' file(s) to ' + $cleanLetter + ': (' + $driveRoot + ').', 'Upload Complete', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        } else {
            $msg = "Uploaded: $uploaded`nFailed: $failed`n`nDetails:`n" + ($errMsgs -join "`n")
            [System.Windows.MessageBox]::Show($msg, 'Upload Notice', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        }
    }
}

# ------------------------------------------------------------------------------
# GOOGLE DRIVE: Connect / Disconnect Action
# ------------------------------------------------------------------------------
$gdActionBtn.Add_Click({
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) {
        $gdStatusText.Text = [string][char]0x25CF + ' Disconnecting...'
        $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $gdActionBtn.IsEnabled = $false
        try {
            Stop-VirtualDriveMount -ProviderId 'gdrive' | Out-Null
        } finally {
            $gdActionBtn.IsEnabled = $true
            Update-AllUIState
        }
        return
    }

    $gdCheck = Test-GoogleDriveBackendSession
    if ($gdCheck.IsValid) {
        $gdStatusText.Text = [string][char]0x25CF + ' Mounting...'
        $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $gdActionBtn.IsEnabled = $false
        try {
            $envVars = Get-GoogleDriveRcloneEnvironment
            $mRes = Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -VolumeLabel 'Google Drive' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars
            if ($mRes.Success -and $script:Settings.OpenExplorerOnMount) {
                Start-ExplorerWindow $mRes.DriveRoot
            }
        } catch {
            $gdErrorText.Text = "Mount failed: $($_.Exception.Message)"
            $gdErrorText.Visibility = 'Visible'
        } finally {
            $gdActionBtn.IsEnabled = $true
            Update-AllUIState
        }
        return
    }

    $script:IsConnecting = $true
    $gdStatusText.Text = [string][char]0x25CF + ' Connecting...'
    $gdStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillConnected)
    $gdErrorText.Visibility = 'Collapsed'
    $gdActionBtn.IsEnabled = $false

    try {
        $gdAccountText.Text = 'Awaiting Google sign-in approval in browser...'
        $authRes = Invoke-GoogleDriveAuthorization -TimeoutSeconds 120 -CancelCheck { -not $window.IsVisible }
        if ($authRes.Success) {
            $gdAccountText.Text = 'Verifying Google Drive account access...'
            $verify = Test-GoogleDriveBackendSession -TokensOverride $authRes.Tokens
            if ($verify.IsValid) {
                Save-GoogleDriveTokens -TokenData $authRes.Tokens

                if (Test-WinFspInstalled) {
                    $gdAccountText.Text = 'Mounting virtual drive (' + $script:GDriveLetter + ':)...'
                    try {
                        $envVars = Get-GoogleDriveRcloneEnvironment
                        $mRes = Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -VolumeLabel 'Google Drive' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars
                        if ($mRes.Success -and $script:Settings.OpenExplorerOnMount) {
                            Start-ExplorerWindow $mRes.DriveRoot
                        }
                    } catch {
                        $gdErrorText.Text = 'Connected, but could not mount ' + $script:GDriveLetter + ': ' + $_.Exception.Message
                        $gdErrorText.Visibility = 'Visible'
                    }
                }
            } else {
                $gdErrorText.Text = "Validation failed: $($verify.Error)"
                $gdErrorText.Visibility = 'Visible'
            }
        } else {
            $gdErrorText.Text = "Sign-in cancelled or failed: $($authRes.Error)"
            $gdErrorText.Visibility = 'Visible'
        }
    } catch {
        $gdErrorText.Text = "Error: $($_.Exception.Message)"
        $gdErrorText.Visibility = 'Visible'
    } finally {
        $script:IsConnecting = $false
        $gdActionBtn.IsEnabled = $true
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
    $existing = (Get-CloudAccounts) | Where-Object { $_.ProviderId -eq 'gdrive' -and $_.Id -notlike 'test_*' } | Select-Object -First 1
    if (-not $existing) {
        $existing = @{
            Id = 'gdrive_primary'
            ProviderId = 'gdrive'
            DisplayName = 'Google Drive'
            AccountEmail = ''
            DriveLetter = $script:GDriveLetter
            AutoMount = $script:Settings.AutoMountDrives
            OpenExplorerOnMount = $script:Settings.OpenExplorerOnMount
            ReadOnly = $false
        }
    }
    $res = Show-CloudAccountSetupModal -Owner $window -ProviderId 'gdrive' -InitialAccount $existing -Theme $script:Settings.Theme
    if ($res) {
        $script:GDriveLetter = $res.DriveLetter
        Set-PreferredDriveLetter -ProviderId 'gdrive' -DriveLetter $res.DriveLetter
        Update-CloudAccount -Account $res | Out-Null
        Update-AllUIState
    }
})

$gdUploadBtn.Add_Click({
    Show-UploadDialog -DriveLetter $script:GDriveLetter -ParentWindow $window
})

$gdRemoveBtn.Add_Click({
    $conf = [System.Windows.MessageBox]::Show('Are you sure you want to disconnect and remove Google Drive?', 'Remove Cloud Drive', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($conf -eq [System.Windows.MessageBoxResult]::Yes) {
        Stop-VirtualDriveMount -ProviderId 'gdrive' | Out-Null
        Remove-GoogleDriveSession
        $gdErrorText.Visibility = 'Collapsed'
        Update-AllUIState
    }
})

# ------------------------------------------------------------------------------
# TERABOX: Connect / Disconnect Action
# ------------------------------------------------------------------------------
$tbActionBtn.Add_Click({
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) {
        $tbStatusText.Text = [string][char]0x25CF + ' Disconnecting...'
        $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $tbActionBtn.IsEnabled = $false
        try {
            Stop-VirtualDriveMount -ProviderId 'terabox' | Out-Null
        } finally {
            $tbActionBtn.IsEnabled = $true
            Update-AllUIState
        }
        return
    }

    $tbCheck = Test-TeraBoxBackendSession
    if ($tbCheck.IsValid) {
        $tbStatusText.Text = [string][char]0x25CF + ' Mounting...'
        $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillWarning)
        $tbActionBtn.IsEnabled = $false
        try {
            $tbEnvVars = Get-TeraBoxRcloneEnvironment
            $mRes = Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -VolumeLabel 'TeraBox' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars
            if ($mRes.Success -and $script:Settings.OpenExplorerOnMount) {
                Start-ExplorerWindow $mRes.DriveRoot
            }
        } catch {
            $tbErrorText.Text = "Mount failed: $($_.Exception.Message)"
            $tbErrorText.Visibility = 'Visible'
        } finally {
            $tbActionBtn.IsEnabled = $true
            Update-AllUIState
        }
        return
    }

    $script:IsConnecting = $true
    $tbStatusText.Text = [string][char]0x25CF + ' Connecting...'
    $tbStatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Palette.PillConnected)
    $tbErrorText.Visibility = 'Collapsed'
    $tbActionBtn.IsEnabled = $false

    try {
        $loginRes = Show-TeraBoxEmbeddedLoginWindow -Owner $window
        if ($loginRes.Success) {
            $tbAccountText.Text = 'Mounting virtual drive (' + $script:TeraBoxLetter + ':)...'
            $verifiedRclone = Get-VerifiedRclonePath
            if ($verifiedRclone -and (Test-WinFspInstalled)) {
                try {
                    $tbEnvVars = Get-TeraBoxRcloneEnvironment
                    $mRes = Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -VolumeLabel 'TeraBox' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars
                    if ($mRes.Success -and $script:Settings.OpenExplorerOnMount) {
                        Start-ExplorerWindow $mRes.DriveRoot
                    }
                } catch {
                    $tbErrorText.Text = 'Connected, but could not mount ' + $script:TeraBoxLetter + ': ' + $_.Exception.Message
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
        $tbActionBtn.IsEnabled = $true
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
    $existing = (Get-CloudAccounts) | Where-Object { $_.ProviderId -eq 'terabox' -and $_.Id -notlike 'test_*' } | Select-Object -First 1
    if (-not $existing) {
        $existing = @{
            Id = 'terabox_primary'
            ProviderId = 'terabox'
            DisplayName = 'TeraBox'
            AccountEmail = ''
            DriveLetter = $script:TeraBoxLetter
            AutoMount = $script:Settings.AutoMountDrives
            OpenExplorerOnMount = $script:Settings.OpenExplorerOnMount
            ReadOnly = $false
        }
    }
    $res = Show-CloudAccountSetupModal -Owner $window -ProviderId 'terabox' -InitialAccount $existing -Theme $script:Settings.Theme
    if ($res) {
        $script:TeraBoxLetter = $res.DriveLetter
        Set-PreferredDriveLetter -ProviderId 'terabox' -DriveLetter $res.DriveLetter
        Update-CloudAccount -Account $res | Out-Null
        Update-AllUIState
    }
})

$tbUploadBtn.Add_Click({
    Show-UploadDialog -DriveLetter $script:TeraBoxLetter -ParentWindow $window
})

$tbRemoveBtn.Add_Click({
    $conf = [System.Windows.MessageBox]::Show('Are you sure you want to disconnect and remove TeraBox?', 'Remove Cloud Drive', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($conf -eq [System.Windows.MessageBoxResult]::Yes) {
        Stop-VirtualDriveMount -ProviderId 'terabox' | Out-Null
        Remove-TeraBoxSession
        $tbErrorText.Visibility = 'Collapsed'
        Update-AllUIState
    }
})

# ==============================================================================
# SYSTEM TRAY INTEGRATION
# ==============================================================================
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

$window.Add_StateChanged({
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
        Invoke-MemoryTrim
    }
})

function Invoke-StartupAutoMount {
    if (-not $script:Settings.AutoMountDrives) { return }
    try {
        $accounts = Get-CloudAccounts
        if ($accounts -and $accounts.Count -gt 0) {
            foreach ($acc in $accounts) {
                if ($acc.AutoMount) {
                    try {
                        if ($acc.ProviderId -eq 'gdrive') {
                            $envVars = Get-GoogleDriveRcloneEnvironment -AccountId $acc.Id -RemoteName 'gdrive'
                            Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -AccountId $acc.Id -DriveLetter $acc.DriveLetter -VolumeLabel $acc.DisplayName -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars | Out-Null
                        } elseif ($acc.ProviderId -eq 'terabox' -and (Get-VerifiedRclonePath)) {
                            $tbEnvVars = Get-TeraBoxRcloneEnvironment -AccountId $acc.Id
                            Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -AccountId $acc.Id -DriveLetter $acc.DriveLetter -VolumeLabel $acc.DisplayName -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars | Out-Null
                        }
                    } catch { }
                }
            }
        } else {
            # Fallback to default primary providers if no custom accounts configured
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
        }
        if ($window.Dispatcher) {
            $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
                Update-AllUIState
            }) | Out-Null
        }
    } catch { }
}

$window.Add_Loaded({
    if (-not $Minimized) {
        $window.Activate() | Out-Null
        try {
            $wshell = New-Object -ComObject WScript.Shell
            $wshell.AppActivate('NS Cloud Drive') | Out-Null
        } catch { }
    }
    Invoke-MemoryTrim

    # Run auto-mount asynchronously in background so the UI is immediately visible and responsive
    if ($script:Settings.AutoMountDrives) {
        [System.Threading.Tasks.Task]::Run({
            Invoke-StartupAutoMount
        }) | Out-Null
    }
})

# ==============================================================================
# BACKGROUND REFRESH AND MEMORY TRIM TIMER
# ==============================================================================
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
            Invoke-MemoryTrim
        }
    }
})
$timer.Start()

if ($MyInvocation.InvocationName -ne '.') {
    # Fast initial UI population (takes < 5ms with session caching)
    Update-AllUIState

    try { Invoke-StartupCacheRecovery -CacheDirectory $script:CacheDirectory | Out-Null } catch { }

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
        [System.Diagnostics.Debug]::WriteLine("NSCloudDrive Dispatcher Exception: $msg")
        $e.Handled = $true
    })
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
