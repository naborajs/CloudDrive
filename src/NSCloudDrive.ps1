Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:Accent = '#5B5CE2'
$script:Muted = '#667085'

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

function Get-RclonePath {
    $candidate = Get-Command 'rclone.exe' -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    return $null
}

function Test-WinFsp {
    $paths = @(
        'C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll',
        'C:\Program Files\WinFsp\bin\winfsp-x64.dll'
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    return [bool](Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue)
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
$window.Width = 780
$window.Height = 650
$window.MinWidth = 680
$window.MinHeight = 560
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
$brandTitle.Children.Add((New-Label 'Your cloud storage, one drive at a time.' 13 $script:Muted)) | Out-Null
$brand.Children.Add($brandTitle) | Out-Null
$header.Children.Add($brand) | Out-Null
$header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 24)
$outer.Children.Add($header) | Out-Null

$content = [System.Windows.Controls.StackPanel]::new()
$outer.Children.Add($content) | Out-Null
$statusCard = New-Card 'Not connected' 'No cloud drive is mounted. Setup checks do not sign in or read account credentials.'
$content.Children.Add($statusCard) | Out-Null
$content.Children.Add((New-Card 'Windows drive' 'Planned mount point: T:\   |   Access mode: read-only during initial verification')) | Out-Null
$content.Children.Add((New-Card 'Local cache' 'Planned location: %LOCALAPPDATA%\NSCloudDrive\Cache   |   Proposed cap: 20 GB')) | Out-Null

$notice = [System.Windows.Controls.Border]::new()
$notice.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFF7E6')
$notice.CornerRadius = [System.Windows.CornerRadius]::new(10)
$notice.Padding = [System.Windows.Thickness]::new(16)
$notice.Margin = [System.Windows.Thickness]::new(0, 2, 0, 14)
$notice.Child = New-Label 'TeraBox support is unofficial and has not been validated on this PC. Mounting is intentionally unavailable until backend security and real read-only acceptance checks pass.' 13 '#704B00'
$content.Children.Add($notice) | Out-Null

$details = New-Label 'Setup checks have not been run.' 13 '#475467'
$details.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
$content.Children.Add($details) | Out-Null

$buttons = [System.Windows.Controls.StackPanel]::new()
$buttons.Orientation = 'Horizontal'
$checkButton = [System.Windows.Controls.Button]::new()
$checkButton.Content = 'Check setup'
$checkButton.Padding = [System.Windows.Thickness]::new(18, 10, 18, 10)
$checkButton.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
$checkButton.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($script:Accent)
$checkButton.Foreground = [System.Windows.Media.Brushes]::White
$checkButton.BorderThickness = [System.Windows.Thickness]::new(0)
$checkButton.Add_Click({
    $rclonePath = Get-RclonePath
    $items = [System.Collections.Generic.List[string]]::new()
    $items.Add(('rclone: ' + $(if ($rclonePath) { 'found' } else { 'not installed or not on PATH' })))
    $winfspAvailable = Test-WinFsp
    $items.Add(('WinFsp: ' + $(if ($winfspAvailable) { 'found' } else { 'not detected' })))
    $backendAvailable = $false
    if ($rclonePath) {
        $backendAvailable = Test-TeraBoxBackend $rclonePath
        $items.Add(('TeraBox backend: ' + $(if ($backendAvailable) { 'provider entry found; account access is untested' } else { 'not present in this rclone build' })))
    } else {
        $items.Add('TeraBox backend: cannot check without rclone')
    }
    $details.Text = $items -join "`n"
})
$buttons.Children.Add($checkButton) | Out-Null
$mountButton = [System.Windows.Controls.Button]::new()
$mountButton.Content = 'Mount T: (locked during verification)'
$mountButton.IsEnabled = $false
$mountButton.Padding = [System.Windows.Thickness]::new(18, 10, 18, 10)
$buttons.Children.Add($mountButton) | Out-Null
$content.Children.Add($buttons) | Out-Null

$footer = New-Label 'NS Cloud Drive • Windows desktop preview • No credentials are collected by this screen' 11 '#98A2B3'
$footer.HorizontalAlignment = 'Right'
[System.Windows.Controls.DockPanel]::SetDock($footer, 'Bottom')
$footer.Margin = [System.Windows.Thickness]::new(0, 18, 0, 0)
$outer.Children.Add($footer) | Out-Null

$app = [System.Windows.Application]::new()
[void]$app.Run($window)
