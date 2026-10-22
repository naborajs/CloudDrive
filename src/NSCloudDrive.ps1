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
. (Join-Path $PSScriptRoot 'ui\ProviderConnectionWindow.ps1')

$script:Accent = '#5B5CE2'
$script:Muted = '#667085'
$script:Settings = Get-NSCloudDriveSettings
$script:BuildRoot = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra'
$script:PatchPath = Join-Path $PSScriptRoot '..\patches\rclone-terabox-v1.75.2-extra-secret-safety.patch'
$script:CacheDirectory = if ($script:Settings.CacheDirectory) { $script:Settings.CacheDirectory } else { 'D:\CloudCache' }
$script:GDriveLetter = Get-PreferredDriveLetter 'gdrive'
$script:TeraBoxLetter = Get-PreferredDriveLetter 'terabox'
$script:IsExiting = $false
$script:AppMutex = $null
$script:RestoreEvent = $null
$script:LastFullUpdate = [DateTime]::UtcNow

# Enforce single instance when launched as standalone application
if ($MyInvocation.InvocationName -ne '.') {
    $isNewInstance = $false
    try {
        $script:AppMutex = [System.Threading.Mutex]::new($true, 'Local\NSCloudDrive_AppMutex', [ref]$isNewInstance)
    } catch [System.Threading.AbandonedMutexException] {
        # Previous instance was abruptly terminated without releasing the mutex; we now own it
        $isNewInstance = $true
    } catch {
        # Fail open to allow desktop launch if mutex inspection encounters environment policy limits
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

function New-Label([string]$Text, [int]$Size = 14, [string]$Color = '#172033', [bool]$Bold = $false) {
    $label = [System.Windows.Controls.TextBlock]::new()
    $label.Text = $Text
    $label.FontSize = $Size
    $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $label.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $label.TextWrapping = 'Wrap'
    return $label
}

function New-Card([string]$Title, [string]$Description) {
    $border = [System.Windows.Controls.Border]::new()
    $border.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
    $border.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E6EAF2')
    $border.BorderThickness = [System.Windows.Thickness]::new(1)
    $border.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $border.Padding = [System.Windows.Thickness]::new(18)
    $border.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $stack = [System.Windows.Controls.StackPanel]::new()
    $stack.Children.Add((New-Label $Title 16 '#172033' $true)) | Out-Null
    $descriptionBlock = New-Label $Description 13 $script:Muted
    $descriptionBlock.Margin = [System.Windows.Thickness]::new(0, 7, 0, 0)
    $stack.Children.Add($descriptionBlock) | Out-Null
    $border.Child = $stack
    return $border
}

function Get-VerifiedRclonePath {
    $executable = Join-Path $script:BuildRoot 'rclone.exe'
    $manifestPath = Join-Path $script:BuildRoot 'rclone.build.json'
    $hasPatchedFiles = $true
    foreach ($path in @($executable, $manifestPath, $script:PatchPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $hasPatchedFiles = $false; break }
    }

    if ($hasPatchedFiles) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $patchHash = (Get-FileHash -LiteralPath $script:PatchPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $executableHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($manifest.sourceCommit -eq '56bf13885494819bc801302ddf881279bdac7262' -and
                $manifest.target -eq 'windows/amd64' -and
                $manifest.buildTag -eq 'cmount' -and
                $manifest.backend -eq 'terabox' -and
                $manifest.patchSha256 -eq $patchHash -and
                $manifest.executableSha256 -eq $executableHash) {
                return $executable
            }
        } catch { }
    }

    # Also check if any available rclone binary on the system already supports the terabox backend
    $systemRclone = Find-RcloneBinary
    if ($systemRclone) {
        try {
            $providers = & $systemRclone --config= config providers 2>$null | Out-String
            if ($LASTEXITCODE -eq 0 -and $providers -match '(?i)\bterabox\b') {
                return $systemRclone
            }
        } catch { }
    }

    return $null
}

function Get-DriveAvailability([string]$Letter) {
    $drivePath = "$($Letter.ToUpperInvariant()):\"
    $occupied = [System.IO.DriveInfo]::GetDrives().Name -contains $drivePath
    if ($occupied) { return "$($Letter.ToUpperInvariant()): is already in use" }
    return "$($Letter.ToUpperInvariant()): is available"
}

function Get-CacheVolumeDiagnostic([string]$Path) {
    try {
        $volumeRoot = [System.IO.Path]::GetPathRoot($Path)
        $volume = [System.IO.DriveInfo]::new($volumeRoot)
        if (-not $volume.IsReady) { return "Cache volume $volumeRoot is not ready" }
        $freeGiB = [Math]::Floor($volume.AvailableFreeSpace / 1GB)
        if ($volume.DriveFormat -ne 'NTFS') { return "Cache volume $volumeRoot uses $($volume.DriveFormat); NTFS is required" }
        if ($volume.AvailableFreeSpace -lt 25GB) { return "Cache volume $volumeRoot has $freeGiB GiB free; at least 25 GiB is required" }
        return "Cache volume $volumeRoot is NTFS with $freeGiB GiB free"
    } catch {
        return "Cache volume could not be checked: $($_.Exception.Message)"
    }
}

# --- Main Window Construction ---
$window = [System.Windows.Window]::new()
$window.Title = 'NS Cloud Drive'
$window.Width = 880
$window.Height = 740
$window.MinWidth = 760
$window.MinHeight = 620
$window.WindowStartupLocation = 'CenterScreen'
$window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5F7FB')
$window.FontFamily = 'Segoe UI'

$outer = [System.Windows.Controls.DockPanel]::new()
$outer.LastChildFill = $true
$outer.Margin = [System.Windows.Thickness]::new(28)
$window.Content = $outer

# Header
$header = [System.Windows.Controls.StackPanel]::new()
[System.Windows.Controls.DockPanel]::SetDock($header, 'Top')
$brand = [System.Windows.Controls.StackPanel]::new()
$brand.Orientation = 'Horizontal'
$mark = [System.Windows.Controls.Border]::new()
$mark.Width = 42; $mark.Height = 42; $mark.CornerRadius = [System.Windows.CornerRadius]::new(12)
$mark.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Accent)
$markText = New-Label 'NS' 16 '#FFFFFF' $true
$markText.HorizontalAlignment = 'Center'; $markText.VerticalAlignment = 'Center'
$mark.Child = $markText
$mark.Margin = [System.Windows.Thickness]::new(0, 0, 13, 0)
$brand.Children.Add($mark) | Out-Null
$brandTitle = [System.Windows.Controls.StackPanel]::new()
$brandTitle.Children.Add((New-Label 'NS Cloud Drive' 24 '#172033' $true)) | Out-Null
$brandTitle.Children.Add((New-Label 'Native Windows virtual drives for Google Drive and TeraBox with on-demand caching.' 13 $script:Muted)) | Out-Null
$brand.Children.Add($brandTitle) | Out-Null
$header.Children.Add($brand) | Out-Null
$header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 18)
$outer.Children.Add($header) | Out-Null

# Main Scroll Viewer (Constrained Width to prevent horizontal overflow)
$mainScroll = [System.Windows.Controls.ScrollViewer]::new()
$mainScroll.VerticalScrollBarVisibility = 'Auto'
$mainScroll.HorizontalScrollBarVisibility = 'Disabled'
$outer.Children.Add($mainScroll) | Out-Null

$content = [System.Windows.Controls.StackPanel]::new()
$mainScroll.Content = $content

# --- Provider Drives Grid (Side-by-Side Cards) ---
$providersGrid = [System.Windows.Controls.Grid]::new()
$providersGrid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
$col1 = [System.Windows.Controls.ColumnDefinition]::new()
$col1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$col2 = [System.Windows.Controls.ColumnDefinition]::new()
$col2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$providersGrid.ColumnDefinitions.Add($col1)
$providersGrid.ColumnDefinitions.Add($col2)

# --- 1. Google Drive Card ---
$gdCard = [System.Windows.Controls.Border]::new()
$gdCard.Background = [System.Windows.Media.Brushes]::White
$gdCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
$gdCard.BorderThickness = [System.Windows.Thickness]::new(1)
$gdCard.CornerRadius = [System.Windows.CornerRadius]::new(12)
$gdCard.Padding = [System.Windows.Thickness]::new(18)
$gdCard.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$gdStack = [System.Windows.Controls.StackPanel]::new()
$gdCard.Child = $gdStack

$gdHeaderStack = [System.Windows.Controls.StackPanel]::new()
$gdHeaderStack.Orientation = 'Horizontal'
$gdDot = [System.Windows.Controls.Border]::new()
$gdDot.Width = 10; $gdDot.Height = 10; $gdDot.CornerRadius = [System.Windows.CornerRadius]::new(5)
$gdDot.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
$gdDot.Margin = [System.Windows.Thickness]::new(0, 4, 8, 0)
$gdHeaderStack.Children.Add($gdDot) | Out-Null
$gdHeaderStack.Children.Add((New-Label "Google Drive (Drive $($script:GDriveLetter):)" 16 '#1E293B' $true)) | Out-Null
$gdStack.Children.Add($gdHeaderStack) | Out-Null

$gdStatusLabel = New-Label 'Status: Checking...' 12 '#64748B'
$gdStatusLabel.Margin = [System.Windows.Thickness]::new(0, 6, 0, 4)
$gdStack.Children.Add($gdStatusLabel) | Out-Null

$gdQuotaLabel = New-Label 'Cloud Storage: Checking...' 12 '#475467'
$gdQuotaLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
$gdStack.Children.Add($gdQuotaLabel) | Out-Null

$gdMountLabel = New-Label "Virtual Drive: Unmounted ($($script:GDriveLetter):\ available)" 12 '#475467'
$gdMountLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
$gdStack.Children.Add($gdMountLabel) | Out-Null

$gdActions = [System.Windows.Controls.WrapPanel]::new()
$gdConnectBtn = [System.Windows.Controls.Button]::new()
$gdConnectBtn.Content = 'Connect Account'
$gdConnectBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$gdConnectBtn.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
$gdConnectBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
$gdConnectBtn.Foreground = [System.Windows.Media.Brushes]::White
$gdConnectBtn.BorderThickness = [System.Windows.Thickness]::new(0)

$gdMountBtn = [System.Windows.Controls.Button]::new()
$gdMountBtn.Content = "Mount $($script:GDriveLetter): Drive"
$gdMountBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$gdMountBtn.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)

$gdExplorerBtn = [System.Windows.Controls.Button]::new()
$gdExplorerBtn.Content = 'Open in Explorer'
$gdExplorerBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$gdExplorerBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
$gdExplorerBtn.IsEnabled = $false

$gdActions.Children.Add($gdConnectBtn) | Out-Null
$gdActions.Children.Add($gdMountBtn) | Out-Null
$gdActions.Children.Add($gdExplorerBtn) | Out-Null
$gdStack.Children.Add($gdActions) | Out-Null

[System.Windows.Controls.Grid]::SetColumn($gdCard, 0)
$providersGrid.Children.Add($gdCard) | Out-Null

# --- 2. TeraBox Card ---
$tbCard = [System.Windows.Controls.Border]::new()
$tbCard.Background = [System.Windows.Media.Brushes]::White
$tbCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
$tbCard.BorderThickness = [System.Windows.Thickness]::new(1)
$tbCard.CornerRadius = [System.Windows.CornerRadius]::new(12)
$tbCard.Padding = [System.Windows.Thickness]::new(18)
$tbCard.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
$tbStack = [System.Windows.Controls.StackPanel]::new()
$tbCard.Child = $tbStack

$tbHeaderStack = [System.Windows.Controls.StackPanel]::new()
$tbHeaderStack.Orientation = 'Horizontal'
$tbDot = [System.Windows.Controls.Border]::new()
$tbDot.Width = 10; $tbDot.Height = 10; $tbDot.CornerRadius = [System.Windows.CornerRadius]::new(5)
$tbDot.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2D60FF')
$tbDot.Margin = [System.Windows.Thickness]::new(0, 4, 8, 0)
$tbHeaderStack.Children.Add($tbDot) | Out-Null
$tbHeaderStack.Children.Add((New-Label "TeraBox (Drive $($script:TeraBoxLetter):)" 16 '#1E293B' $true)) | Out-Null
$tbStack.Children.Add($tbHeaderStack) | Out-Null

$tbStatusLabel = New-Label 'Status: Checking...' 12 '#64748B'
$tbStatusLabel.Margin = [System.Windows.Thickness]::new(0, 6, 0, 4)
$tbStack.Children.Add($tbStatusLabel) | Out-Null

$tbQuotaLabel = New-Label 'Cloud Storage: Not provided by provider' 12 '#475467'
$tbQuotaLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
$tbStack.Children.Add($tbQuotaLabel) | Out-Null

$tbMountLabel = New-Label "Virtual Drive: Unmounted ($($script:TeraBoxLetter):\ available)" 12 '#475467'
$tbMountLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
$tbStack.Children.Add($tbMountLabel) | Out-Null

$tbActions = [System.Windows.Controls.WrapPanel]::new()
$tbConnectBtn = [System.Windows.Controls.Button]::new()
$tbConnectBtn.Content = 'Connect Account'
$tbConnectBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$tbConnectBtn.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)
$tbConnectBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2D60FF')
$tbConnectBtn.Foreground = [System.Windows.Media.Brushes]::White
$tbConnectBtn.BorderThickness = [System.Windows.Thickness]::new(0)

$tbMountBtn = [System.Windows.Controls.Button]::new()
$tbMountBtn.Content = "Mount $($script:TeraBoxLetter): Drive"
$tbMountBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$tbMountBtn.Margin = [System.Windows.Thickness]::new(0, 0, 6, 6)

$tbExplorerBtn = [System.Windows.Controls.Button]::new()
$tbExplorerBtn.Content = 'Open in Explorer'
$tbExplorerBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$tbExplorerBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
$tbExplorerBtn.IsEnabled = $false

$tbActions.Children.Add($tbConnectBtn) | Out-Null
$tbActions.Children.Add($tbMountBtn) | Out-Null
$tbActions.Children.Add($tbExplorerBtn) | Out-Null
$tbStack.Children.Add($tbActions) | Out-Null

[System.Windows.Controls.Grid]::SetColumn($tbCard, 1)
$providersGrid.Children.Add($tbCard) | Out-Null

$content.Children.Add($providersGrid) | Out-Null

# --- 3. Local Cache & Explorer Notice Card ---
$cacheCard = [System.Windows.Controls.Border]::new()
$cacheCard.Background = [System.Windows.Media.Brushes]::White
$cacheCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E6EAF2')
$cacheCard.BorderThickness = [System.Windows.Thickness]::new(1)
$cacheCard.CornerRadius = [System.Windows.CornerRadius]::new(12)
$cacheCard.Padding = [System.Windows.Thickness]::new(18)
$cacheCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
$cacheStack = [System.Windows.Controls.StackPanel]::new()
$cacheCard.Child = $cacheStack

$cacheStack.Children.Add((New-Label 'Local Cache & File Explorer Integration' 16 '#172033' $true)) | Out-Null
$cacheDesc = New-Label 'File Explorer is the primary interface. Files stream on demand with read-only protection and bounded local caching.' 13 $script:Muted
$cacheDesc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 10)
$cacheStack.Children.Add($cacheDesc) | Out-Null

$cacheStatsLabel = New-Label "Cache Directory: $($script:CacheDirectory)   |   Usage: Calculating..." 12 '#344054'
$cacheStatsLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
$cacheStack.Children.Add($cacheStatsLabel) | Out-Null

$openCacheBtn = [System.Windows.Controls.Button]::new()
$openCacheBtn.Content = 'Open Local Cache Folder'
$openCacheBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$openCacheBtn.HorizontalAlignment = 'Left'
$openCacheBtn.Add_Click({
    if (-not (Test-Path -LiteralPath $script:CacheDirectory)) {
        New-Item -ItemType Directory -Path $script:CacheDirectory -Force | Out-Null
    }
    [System.Diagnostics.Process]::Start('explorer.exe', $script:CacheDirectory) | Out-Null
})
$cacheStack.Children.Add($openCacheBtn) | Out-Null

$content.Children.Add($cacheCard) | Out-Null

# --- 4. Background & Startup Settings Card ---
$settingsCard = [System.Windows.Controls.Border]::new()
$settingsCard.Background = [System.Windows.Media.Brushes]::White
$settingsCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E6EAF2')
$settingsCard.BorderThickness = [System.Windows.Thickness]::new(1)
$settingsCard.CornerRadius = [System.Windows.CornerRadius]::new(12)
$settingsCard.Padding = [System.Windows.Thickness]::new(18)
$settingsCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
$settingsStack = [System.Windows.Controls.StackPanel]::new()
$settingsCard.Child = $settingsStack

$settingsStack.Children.Add((New-Label 'Background Operation & Startup Preferences' 16 '#172033' $true)) | Out-Null
$settingsDesc = New-Label 'Configure persistent connection recovery and low-resource background operation.' 13 $script:Muted
$settingsDesc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 10)
$settingsStack.Children.Add($settingsDesc) | Out-Null

$chkStartup = [System.Windows.Controls.CheckBox]::new()
$chkStartup.Content = 'Start NS Cloud Drive with Windows (Logon in user session)'
$chkStartup.IsChecked = (Test-WindowsStartupEnabled)
$chkStartup.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$chkStartup.Add_Click({
    Set-WindowsStartupEnabled -Enable ($chkStartup.IsChecked -eq $true)
    $script:Settings.AutoStartWithWindows = ($chkStartup.IsChecked -eq $true)
    Set-NSCloudDriveSettings $script:Settings
})
$settingsStack.Children.Add($chkStartup) | Out-Null

$chkAutoMount = [System.Windows.Controls.CheckBox]::new()
$chkAutoMount.Content = 'Automatically mount connected cloud drives on startup'
$chkAutoMount.IsChecked = $script:Settings.AutoMountDrives
$chkAutoMount.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$chkAutoMount.Add_Click({
    $script:Settings.AutoMountDrives = ($chkAutoMount.IsChecked -eq $true)
    Set-NSCloudDriveSettings $script:Settings
})
$settingsStack.Children.Add($chkAutoMount) | Out-Null

$chkMinimizeTray = [System.Windows.Controls.CheckBox]::new()
$chkMinimizeTray.Content = 'Minimize to System Tray on window close (Keeps virtual drives available)'
$chkMinimizeTray.IsChecked = $script:Settings.MinimizeToTrayOnClose
$chkMinimizeTray.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
$chkMinimizeTray.Add_Click({
    $script:Settings.MinimizeToTrayOnClose = ($chkMinimizeTray.IsChecked -eq $true)
    Set-NSCloudDriveSettings $script:Settings
})
$settingsStack.Children.Add($chkMinimizeTray) | Out-Null

$content.Children.Add($settingsCard) | Out-Null

# --- 5. System Diagnostics Section ---
$details = New-Label 'Setup checks have not been run.' 13 '#475467'
$details.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
$content.Children.Add($details) | Out-Null

$diagButton = [System.Windows.Controls.Button]::new()
$diagButton.Content = 'Run Setup Diagnostics'
$diagButton.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
$diagButton.HorizontalAlignment = 'Left'
$diagButton.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
$diagButton.Add_Click({
    $rclonePath = Find-RcloneBinary
    $items = [System.Collections.Generic.List[string]]::new()
    $items.Add(('rclone: ' + $(if ($rclonePath) { "found at $rclonePath" } else { 'executable not found' })))
    $winfspAvailable = Test-WinFspInstalled
    $items.Add(('WinFsp: ' + $(if ($winfspAvailable) { 'detected and running' } else { 'not detected' })))
    $items.Add(('Google Drive letter: ' + (Get-DriveAvailability $script:GDriveLetter)))
    $items.Add(('TeraBox letter: ' + (Get-DriveAvailability $script:TeraBoxLetter)))
    $items.Add(('Cache path: ' + $script:CacheDirectory))
    $items.Add((Get-CacheVolumeDiagnostic $script:CacheDirectory))
    $details.Text = $items -join "`n"
})
$content.Children.Add($diagButton) | Out-Null

# Footer
$footer = New-Label 'NS Cloud Drive • Windows Desktop • On-demand streaming, DPAPI protected, and low-resource background operation' 11 '#98A2B3'
$footer.HorizontalAlignment = 'Right'
[System.Windows.Controls.DockPanel]::SetDock($footer, 'Bottom')
$footer.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
$outer.Children.Add($footer) | Out-Null

# --- Core UI & State Refresh Logic ---
function Update-AllUIState {
    # 1. Google Drive Status & Quota
    $gdCheck = Test-GoogleDriveBackendSession
    if ($gdCheck.IsValid) {
        $gdStatusLabel.Text = "Status: Connected ($($gdCheck.UserInfo.DisplayName) - $($gdCheck.UserInfo.EmailAddress))"
        $gdConnectBtn.Content = 'Manage / Disconnect'
        if ($gdCheck.UserInfo.QuotaTotal -gt 0) {
            $usedGb = [Math]::Round($gdCheck.UserInfo.QuotaUsed / 1GB, 2)
            $totalGb = [Math]::Round($gdCheck.UserInfo.QuotaTotal / 1GB, 2)
            $freeGb = [Math]::Round(($gdCheck.UserInfo.QuotaTotal - $gdCheck.UserInfo.QuotaUsed) / 1GB, 2)
            $pct = [Math]::Round(($gdCheck.UserInfo.QuotaUsed / $gdCheck.UserInfo.QuotaTotal) * 100, 1)
            $gdQuotaLabel.Text = "Cloud Storage: $usedGb GB of $totalGb GB used ($freeGb GB free, $pct%)"
        } else {
            $gdQuotaLabel.Text = "Cloud Storage: $([Math]::Round($gdCheck.UserInfo.QuotaUsed / 1GB, 2)) GB used"
        }
    } else {
        $gdStatusLabel.Text = "Status: $($gdCheck.State)"
        $gdConnectBtn.Content = 'Connect Google Drive'
        $gdQuotaLabel.Text = 'Cloud Storage: Not connected'
    }

    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) {
        $gdMountLabel.Text = "Virtual Drive: Mounted as $($gdStatus.DriveLetter):\ (Volume: $($gdStatus.VolumeLabel))"
        $gdMountBtn.Content = "Unmount $($gdStatus.DriveLetter):"
        $gdExplorerBtn.IsEnabled = $true
    } else {
        $gdMountLabel.Text = "Virtual Drive: Unmounted ($($script:GDriveLetter):\ available)"
        $gdMountBtn.Content = "Mount $($script:GDriveLetter): Drive"
        $gdExplorerBtn.IsEnabled = $false
    }

    # 2. TeraBox Status & Quota
    $tbCheck = Test-TeraBoxBackendSession
    if ($tbCheck.IsValid) {
        $tbStatusLabel.Text = "Status: Connected ($($tbCheck.UserInfo.UserName))"
        $tbConnectBtn.Content = 'Manage / Disconnect'
        $tbQuotaLabel.Text = 'Cloud Storage: Account active'
    } else {
        $tbStatusLabel.Text = "Status: $($tbCheck.State)"
        $tbConnectBtn.Content = 'Connect TeraBox'
        $tbQuotaLabel.Text = 'Cloud Storage: Not provided by provider'
    }

    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) {
        $tbMountLabel.Text = "Virtual Drive: Mounted as $($tbStatus.DriveLetter):\ (Volume: $($tbStatus.VolumeLabel))"
        $tbMountBtn.Content = "Unmount $($tbStatus.DriveLetter):"
        $tbExplorerBtn.IsEnabled = $true
    } else {
        $tbMountLabel.Text = "Virtual Drive: Unmounted ($($script:TeraBoxLetter):\ available)"
        $tbMountBtn.Content = "Mount $($script:TeraBoxLetter): Drive"
        $tbExplorerBtn.IsEnabled = $false
    }

    # 3. Cache Usage
    $cStats = Get-CacheUsageStatistics -CacheDirectory $script:CacheDirectory
    $cacheStatsLabel.Text = "Cache Directory: $($cStats.CacheDirectory)   |   Usage: $($cStats.UsedFormatted) / $($cStats.TargetMaxFormatted) soft limit ($($cStats.VolumeFreeFormatted) free on volume)"
}

# --- Action Event Handlers ---
$gdConnectBtn.Add_Click({
    Show-ProviderConnectionWindow -ProviderId 'gdrive' -Owner $window -OnStateChanged {
        param($providerIdParam, $stateParam)
        Update-AllUIState
    }
})

$tbConnectBtn.Add_Click({
    Show-ProviderConnectionWindow -ProviderId 'terabox' -Owner $window -OnStateChanged {
        param($providerIdParam, $stateParam)
        Update-AllUIState
    }
})

$gdMountBtn.Add_Click({
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) {
        Stop-VirtualDriveMount -ProviderId 'gdrive' | Out-Null
        Update-AllUIState
        [System.Windows.MessageBox]::Show("Google Drive unmounted from $($gdStatus.DriveLetter):", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    $gdCheck = Test-GoogleDriveBackendSession
    if (-not $gdCheck.IsValid) {
        [System.Windows.MessageBox]::Show('Please connect and validate your Google Drive account before mounting.', 'Authentication Required', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $gdMountBtn.IsEnabled = $false
    $gdMountBtn.Content = 'Mounting...'
    try {
        $envVars = Get-GoogleDriveRcloneEnvironment
        $res = Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -VolumeLabel 'Google Drive' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars
        if ($res.Success) {
            [System.Windows.MessageBox]::Show("Google Drive mounted successfully as $($res.DriveLetter):`nYou can now open File Explorer and access your files.", 'Google Drive Mounted', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    } catch {
        [System.Windows.MessageBox]::Show("Failed to mount Google Drive: $($_.Exception.Message)", 'Mount Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    } finally {
        $gdMountBtn.IsEnabled = $true
        Update-AllUIState
    }
})

$tbMountBtn.Add_Click({
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) {
        Stop-VirtualDriveMount -ProviderId 'terabox' | Out-Null
        Update-AllUIState
        [System.Windows.MessageBox]::Show("TeraBox unmounted from $($tbStatus.DriveLetter):", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    $tbCheck = Test-TeraBoxBackendSession
    if (-not $tbCheck.IsValid) {
        [System.Windows.MessageBox]::Show('Please connect and validate your TeraBox account before mounting.', 'Authentication Required', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $verifiedRclone = Get-VerifiedRclonePath
    if (-not $verifiedRclone) {
        [System.Windows.MessageBox]::Show("TeraBox mounting requires the patched, verified rclone build containing the TeraBox backend.`nPlease run scripts\Build-PatchedRclone.ps1 first to prepare the binary.", 'Build Required', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $tbMountBtn.IsEnabled = $false
    $tbMountBtn.Content = 'Mounting...'
    try {
        $tbEnvVars = Get-TeraBoxRcloneEnvironment
        $res = Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -VolumeLabel 'TeraBox' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars
        if ($res.Success) {
            [System.Windows.MessageBox]::Show("TeraBox mounted successfully as $($res.DriveLetter):`nYou can now open File Explorer and access your files.", 'TeraBox Mounted', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    } catch {
        [System.Windows.MessageBox]::Show("Failed to mount TeraBox: $($_.Exception.Message)", 'Mount Error', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    } finally {
        $tbMountBtn.IsEnabled = $true
        Update-AllUIState
    }
})

$gdExplorerBtn.Add_Click({
    $status = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($status.IsMounted) {
        [System.Diagnostics.Process]::Start('explorer.exe', $status.DriveRoot) | Out-Null
    }
})

$tbExplorerBtn.Add_Click({
    $status = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($status.IsMounted) {
        [System.Diagnostics.Process]::Start('explorer.exe', $status.DriveRoot) | Out-Null
    }
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

$menuMountGD = $trayMenu.Items.Add("Mount Google Drive ($($script:GDriveLetter):)")
$menuMountGD.Add_Click({
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) {
        Stop-VirtualDriveMount -ProviderId 'gdrive' | Out-Null
    } else {
        $gdCheck = Test-GoogleDriveBackendSession
        if ($gdCheck.IsValid) {
            $envVars = Get-GoogleDriveRcloneEnvironment
            Start-VirtualDriveMount -RemoteName 'gdrive' -ProviderId 'gdrive' -DriveLetter $script:GDriveLetter -VolumeLabel 'Google Drive' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $envVars | Out-Null
        }
    }
    Update-AllUIState
})

$menuOpenGD = $trayMenu.Items.Add("Open Google Drive ($($script:GDriveLetter):\)")
$menuOpenGD.Add_Click({
    $gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
    if ($gdStatus.IsMounted) { [System.Diagnostics.Process]::Start('explorer.exe', $gdStatus.DriveRoot) | Out-Null }
})

$trayMenu.Items.Add('-') | Out-Null

$menuMountTB = $trayMenu.Items.Add("Mount TeraBox ($($script:TeraBoxLetter):)")
$menuMountTB.Add_Click({
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) {
        Stop-VirtualDriveMount -ProviderId 'terabox' | Out-Null
    } else {
        $tbCheck = Test-TeraBoxBackendSession
        if ($tbCheck.IsValid -and (Get-VerifiedRclonePath)) {
            $tbEnvVars = Get-TeraBoxRcloneEnvironment
            Start-VirtualDriveMount -RemoteName 'terabox' -ProviderId 'terabox' -DriveLetter $script:TeraBoxLetter -VolumeLabel 'TeraBox' -CacheDirectory $script:CacheDirectory -EnvironmentVariables $tbEnvVars | Out-Null
        }
    }
    Update-AllUIState
})

$menuOpenTB = $trayMenu.Items.Add("Open TeraBox ($($script:TeraBoxLetter):\)")
$menuOpenTB.Add_Click({
    $tbStatus = Get-VirtualDriveStatus -ProviderId 'terabox'
    if ($tbStatus.IsMounted) { [System.Diagnostics.Process]::Start('explorer.exe', $tbStatus.DriveRoot) | Out-Null }
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

# Handle minimize-to-tray on window close
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

# --- Background UI Polling & Restore Event Listener Timer ---
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    # Check if a second instance signaled to restore the window to foreground
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

    # Throttle full remote status polling: every 3s when visible, every 30s when hidden in tray
    if ($window.IsVisible) {
        if (([DateTime]::UtcNow - $script:LastFullUpdate).TotalSeconds -ge 3) {
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

# Initial state population
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

# If launched with -Minimized, do not show main window
if ($Minimized) {
    $window.Visibility = [System.Windows.Visibility]::Hidden
}

# Run in STA if called as script
if ($MyInvocation.InvocationName -ne '.') {
    $app = [System.Windows.Application]::new()
    if ($Minimized) {
        $window.Hide()
        # Keep application alive in tray even if window is hidden
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
