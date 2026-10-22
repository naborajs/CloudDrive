Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot 'models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot 'providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot 'services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot 'ui\ProviderConnectionWindow.ps1')

$script:Accent = '#5B5CE2'
$script:Muted = '#667085'
$script:BuildRoot = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra'
$script:PatchPath = Join-Path $PSScriptRoot '..\patches\rclone-terabox-v1.75.2-extra-secret-safety.patch'
$script:CacheDirectory = 'D:\CloudCache'
$script:DriveLetter = 'T'

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
    foreach ($path in @($executable, $manifestPath, $script:PatchPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    }

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
    } catch { return $null }
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

function Test-TeraBoxBackend([string]$RclonePath) {
    try {
        $raw = & $RclonePath 'config' 'providers' 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) { return $false }
        $data = $raw | ConvertFrom-Json
        foreach ($provider in $data.providers) {
            if ([string]$provider.Name -match '(?i)terabox') { return $true }
        }
    } catch { return $false }
    return $false
}

$window = [System.Windows.Window]::new()
$window.Title = 'NS Cloud Drive'
$window.Width = 840
$window.Height = 720
$window.MinWidth = 720
$window.MinHeight = 600
$window.WindowStartupLocation = 'CenterScreen'
$window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F5F7FB')
$window.FontFamily = 'Segoe UI'

$outer = [System.Windows.Controls.DockPanel]::new()
$outer.LastChildFill = $true
$outer.Margin = [System.Windows.Thickness]::new(28)
$window.Content = $outer

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
$brandTitle.Children.Add((New-Label 'Multi-provider cloud storage virtual drive with on-demand caching.' 13 $script:Muted)) | Out-Null
$brand.Children.Add($brandTitle) | Out-Null
$header.Children.Add($brand) | Out-Null
$header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
$outer.Children.Add($header) | Out-Null

$mainScroll = [System.Windows.Controls.ScrollViewer]::new()
$mainScroll.VerticalScrollBarVisibility = 'Auto'
$mainScroll.HorizontalScrollBarVisibility = 'Disabled'
$outer.Children.Add($mainScroll) | Out-Null

$content = [System.Windows.Controls.StackPanel]::new()
$mainScroll.Content = $content

# Provider Accounts Card
$accountsCard = [System.Windows.Controls.Border]::new()
$accountsCard.Background = [System.Windows.Media.Brushes]::White
$accountsCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E6EAF2')
$accountsCard.BorderThickness = [System.Windows.Thickness]::new(1)
$accountsCard.CornerRadius = [System.Windows.CornerRadius]::new(12)
$accountsCard.Padding = [System.Windows.Thickness]::new(18)
$accountsCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)

$accountsStack = [System.Windows.Controls.StackPanel]::new()
$accountsCard.Child = $accountsStack
$accountsStack.Children.Add((New-Label 'Cloud Accounts' 16 '#172033' $true)) | Out-Null
$accountsDesc = New-Label 'Connect and validate your cloud providers below.' 13 $script:Muted
$accountsDesc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
$accountsStack.Children.Add($accountsDesc) | Out-Null

# Provider buttons grid
$providersGrid = [System.Windows.Controls.Grid]::new()
$col1 = [System.Windows.Controls.ColumnDefinition]::new()
$col1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$col2 = [System.Windows.Controls.ColumnDefinition]::new()
$col2.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
$providersGrid.ColumnDefinitions.Add($col1)
$providersGrid.ColumnDefinitions.Add($col2)

# TeraBox card in grid
$tbBorder = [System.Windows.Controls.Border]::new()
$tbBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
$tbBorder.BorderThickness = [System.Windows.Thickness]::new(1)
$tbBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
$tbBorder.Padding = [System.Windows.Thickness]::new(14)
$tbBorder.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
$tbStack = [System.Windows.Controls.StackPanel]::new()
$tbBorder.Child = $tbStack
$tbStack.Children.Add((New-Label 'TeraBox' 14 '#1E293B' $true)) | Out-Null
$tbStatusLabel = New-Label 'Status: Disconnected' 12 '#64748B'
$tbStatusLabel.Margin = [System.Windows.Thickness]::new(0, 4, 0, 8)
$tbStack.Children.Add($tbStatusLabel) | Out-Null
$tbBtn = [System.Windows.Controls.Button]::new()
$tbBtn.Content = 'Connect TeraBox'
$tbBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$tbBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2D60FF')
$tbBtn.Foreground = [System.Windows.Media.Brushes]::White
$tbBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$tbBtn.Add_Click({
    Show-ProviderConnectionWindow -ProviderId 'terabox' -Owner $window -OnStateChanged {
        param($providerIdParam, $stateParam)
        $tbStatusLabel.Text = "Status: $stateParam"
    }
})
$tbStack.Children.Add($tbBtn) | Out-Null
[System.Windows.Controls.Grid]::SetColumn($tbBorder, 0)
$providersGrid.Children.Add($tbBorder) | Out-Null

# Google Drive card in grid
$gdBorder = [System.Windows.Controls.Border]::new()
$gdBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
$gdBorder.BorderThickness = [System.Windows.Thickness]::new(1)
$gdBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
$gdBorder.Padding = [System.Windows.Thickness]::new(14)
$gdBorder.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
$gdStack = [System.Windows.Controls.StackPanel]::new()
$gdBorder.Child = $gdStack
$gdStack.Children.Add((New-Label 'Google Drive' 14 '#1E293B' $true)) | Out-Null
$gdStatusLabel = New-Label 'Status: Disconnected' 12 '#64748B'
$gdStatusLabel.Margin = [System.Windows.Thickness]::new(0, 4, 0, 8)
$gdStack.Children.Add($gdStatusLabel) | Out-Null
$gdBtn = [System.Windows.Controls.Button]::new()
$gdBtn.Content = 'Connect Google Drive'
$gdBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
$gdBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
$gdBtn.Foreground = [System.Windows.Media.Brushes]::White
$gdBtn.BorderThickness = [System.Windows.Thickness]::new(0)
$gdBtn.Add_Click({
    Show-ProviderConnectionWindow -ProviderId 'gdrive' -Owner $window -OnStateChanged {
        param($providerIdParam, $stateParam)
        $gdStatusLabel.Text = "Status: $stateParam"
    }
})
$gdStack.Children.Add($gdBtn) | Out-Null
[System.Windows.Controls.Grid]::SetColumn($gdBorder, 1)
$providersGrid.Children.Add($gdBorder) | Out-Null

$accountsStack.Children.Add($providersGrid) | Out-Null
$content.Children.Add($accountsCard) | Out-Null

# Virtual drive status card
$driveCard = New-Card 'Windows virtual drive' 'Planned mount point: T:\   |   Access mode: read-only on-demand cache'
$content.Children.Add($driveCard) | Out-Null

# Local cache card
$content.Children.Add((New-Card 'Local cache' "Location: $script:CacheDirectory   |   Eviction target: 20 GiB (NTFS)")) | Out-Null

# Security & Diagnostic notice
$notice = [System.Windows.Controls.Border]::new()
$notice.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF7E6')
$notice.CornerRadius = [System.Windows.CornerRadius]::new(10)
$notice.Padding = [System.Windows.Thickness]::new(14)
$notice.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
$notice.Child = New-Label 'Virtual drive mounts start in read-only mode to protect your files. Connecting an account requires explicit validation of permitted scope and file access.' 12 '#704B00'
$content.Children.Add($notice) | Out-Null

$details = New-Label 'Setup checks have not been run.' 13 '#475467'
$details.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
$content.Children.Add($details) | Out-Null

$buttons = [System.Windows.Controls.WrapPanel]::new()
$buttons.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

$checkButton = [System.Windows.Controls.Button]::new()
$checkButton.Content = 'Check setup'
$checkButton.Padding = [System.Windows.Thickness]::new(16, 9, 16, 9)
$checkButton.Margin = [System.Windows.Thickness]::new(0, 0, 10, 8)
$checkButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Accent)
$checkButton.Foreground = [System.Windows.Media.Brushes]::White
$checkButton.BorderThickness = [System.Windows.Thickness]::new(0)
$checkButton.Add_Click({
    $rclonePath = Find-RcloneBinary
    $items = [System.Collections.Generic.List[string]]::new()
    if ($rclonePath) {
        $items.Add(('rclone: found at ' + $rclonePath))
    } else {
        $items.Add('rclone: executable not found')
    }
    $winfspAvailable = Test-WinFspInstalled
    $items.Add(('WinFsp: ' + $(if ($winfspAvailable) { 'detected and running' } else { 'not detected' })))
    $items.Add((Get-DriveAvailability $script:DriveLetter))
    $items.Add(('Cache path: ' + $script:CacheDirectory))
    $items.Add((Get-CacheVolumeDiagnostic $script:CacheDirectory))

    # Check provider sessions
    $tbCheck = Test-TeraBoxBackendSession
    $items.Add(('TeraBox: ' + $(if ($tbCheck.IsValid) { "Connected ($($tbCheck.UserInfo.UserName))" } else { "Not connected ($($tbCheck.State))" })))
    $tbStatusLabel.Text = "Status: $($tbCheck.State)"

    $gdCheck = Test-GoogleDriveBackendSession
    $items.Add(('Google Drive: ' + $(if ($gdCheck.IsValid) { "Connected ($($gdCheck.UserInfo.DisplayName))" } else { "Not connected ($($gdCheck.State))" })))
    $gdStatusLabel.Text = "Status: $($gdCheck.State)"

    $details.Text = $items -join "`n"
})
$buttons.Children.Add($checkButton) | Out-Null

$mountButton = [System.Windows.Controls.Button]::new()
$mountButton.Content = 'Mount T: Virtual Drive'
$mountButton.Padding = [System.Windows.Thickness]::new(16, 9, 16, 9)
$mountButton.Margin = [System.Windows.Thickness]::new(0, 0, 10, 8)
$mountButton.Add_Click({
    $status = Get-VirtualDriveStatus -DriveLetter $script:DriveLetter
    if ($status.IsMounted) {
        [System.Windows.MessageBox]::Show("Drive $($script:DriveLetter): is already mounted.", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    # Verify provider connection before mounting
    $tbCheck = Test-TeraBoxBackendSession
    $gdCheck = Test-GoogleDriveBackendSession

    if (-not $tbCheck.IsValid -and -not $gdCheck.IsValid) {
        [System.Windows.MessageBox]::Show('Please connect at least one cloud account (TeraBox or Google Drive) and validate access before mounting.', 'Mount Blocked', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    [System.Windows.MessageBox]::Show("Mounting virtual drive as $($script:DriveLetter): in read-only mode...", 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
})
$buttons.Children.Add($mountButton) | Out-Null

$unmountButton = [System.Windows.Controls.Button]::new()
$unmountButton.Content = 'Unmount T:'
$unmountButton.Padding = [System.Windows.Thickness]::new(16, 9, 16, 9)
$unmountButton.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
$unmountButton.Add_Click({
    $res = Stop-VirtualDriveMount
    [System.Windows.MessageBox]::Show($res.Message, 'NS Cloud Drive', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
})
$buttons.Children.Add($unmountButton) | Out-Null

$content.Children.Add($buttons) | Out-Null

$footer = New-Label 'NS Cloud Drive • Windows Desktop • Secure local credentials & sanitized diagnostics' 11 '#98A2B3'
$footer.HorizontalAlignment = 'Right'
[System.Windows.Controls.DockPanel]::SetDock($footer, 'Bottom')
$footer.Margin = [System.Windows.Thickness]::new(0, 18, 0, 0)
$outer.Children.Add($footer) | Out-Null

# Run in STA if called as script
if ($MyInvocation.InvocationName -ne '.') {
    $app = [System.Windows.Application]::new()
    [void]$app.Run($window)
}
