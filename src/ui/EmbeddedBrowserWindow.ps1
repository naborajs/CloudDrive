Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')

function Test-TeraBoxHost([string]$HostName) {
    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $validDomains = @(
        'terabox.com',
        '1024terabox.com',
        'terabox.app',
        'teraboxapp.com',
        '1024tera.com',
        'terabox1024.com',
        'teraboxcdn.com',
        'freeterabox.com',
        'nephobox.com'
    )
    foreach ($d in $validDomains) {
        if ($HostName.Equals($d, [System.StringComparison]::OrdinalIgnoreCase) -or
            $HostName.EndsWith(".$d", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Wait-WpfTask(
    [System.Threading.Tasks.Task]$Task,
    [int]$TimeoutMs = 5000,
    [System.Windows.Window]$Window = $null
) {
    if (-not $Task) { return $false }
    if ($Task.IsCompleted) { return $true }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $frame = [System.Windows.Threading.DispatcherFrame]::new()

    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $timer.Add_Tick({
        if ($Task.IsCompleted -or $sw.ElapsedMilliseconds -ge $TimeoutMs -or ($Window -and -not $Window.IsVisible)) {
            $timer.Stop()
            $frame.Continue = $false
        }
    })
    $timer.Start()

    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    return $Task.IsCompleted
}

function Find-EdgeWebView2Runtime {
    $searchPaths = @(
        'C:\Program Files (x86)\Microsoft\EdgeWebView\Application',
        'C:\Program Files\Microsoft\EdgeWebView\Application'
    )

    foreach ($basePath in $searchPaths) {
        if (Test-Path -LiteralPath $basePath) {
            $verDirs = @(Get-ChildItem -LiteralPath $basePath -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
                Sort-Object -Property {
                    try { [version]($_.Name) } catch { [version]'0.0.0.0' }
                } -Descending)

            if ($verDirs.Length -gt 0) {
                $candidate = $verDirs[0].FullName
                $msedgeDll = Join-Path $candidate 'msedge.dll'
                if (Test-Path -LiteralPath $msedgeDll) {
                    return $candidate
                }
            }
        }
    }

    # Registry fallbacks for Edge WebView2 Runtime
    $regPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )

    foreach ($rp in $regPaths) {
        try {
            if (Test-Path -LiteralPath $rp) {
                $item = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
                if ($item -and $item.location -and (Test-Path -LiteralPath $item.location)) {
                    return $item.location
                }
            }
        } catch { }
    }

    return $null
}

function Initialize-WebView2Assemblies {
    $searchDirs = @(
        (Join-Path $PSScriptRoot '..\..\lib\webview2'),
        'C:\Users\Naboraj_sarkar\AppData\Local\Temp\webview2_nupkg\lib\net462',
        'C:\Users\Naboraj_sarkar\Downloads\CloudPlayX'
    )

    $coreDll = $null
    $wpfDll = $null

    foreach ($dir in $searchDirs) {
        $c = Join-Path $dir 'Microsoft.Web.WebView2.Core.dll'
        $w = Join-Path $dir 'Microsoft.Web.WebView2.Wpf.dll'
        if ((Test-Path -LiteralPath $c) -and (Test-Path -LiteralPath $w)) {
            $coreDll = $c
            $wpfDll = $w
            break
        }
    }

    if (-not $coreDll -or -not $wpfDll) {
        return @{
            IsAvailable = $false
            RuntimePath = $null
            Error = 'WebView2 assemblies (Microsoft.Web.WebView2.Core.dll and Microsoft.Web.WebView2.Wpf.dll) not found in lib/webview2.'
        }
    }

    $runtimePath = Find-EdgeWebView2Runtime
    if (-not $runtimePath) {
        return @{
            IsAvailable = $false
            RuntimePath = $null
            Error = 'Microsoft Edge WebView2 Runtime is not installed on this system. Please install the WebView2 Evergreen Bootstrapper.'
        }
    }

    try {
        [System.Reflection.Assembly]::LoadFrom($coreDll) | Out-Null
        [System.Reflection.Assembly]::LoadFrom($wpfDll) | Out-Null
        return @{
            IsAvailable = $true
            RuntimePath = $runtimePath
            CoreDll = $coreDll
            WpfDll = $wpfDll
            Error = $null
        }
    } catch {
        return @{
            IsAvailable = $false
            RuntimePath = $runtimePath
            Error = "Failed to load WebView2 assemblies: $($_.Exception.Message)"
        }
    }
}

function Show-TeraBoxEmbeddedLoginWindow(
    [System.Windows.Window]$Owner = $null,
    [scriptblock]$OnLoginSucceeded = $null,
    [scriptblock]$OnStateChanged = $null
) {
    $wvInfo = Initialize-WebView2Assemblies
    if (-not $wvInfo.IsAvailable) {
        [System.Windows.MessageBox]::Show(
            "Cannot open embedded browser: $($wvInfo.Error)",
            'WebView2 Unavailable',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return [ordered]@{
            Success = $false
            Cancelled = $true
            Error = $wvInfo.Error
        }
    }

    $browserWin = [System.Windows.Window]::new()
    $browserWin.Title = 'TeraBox Sign-In - NS Cloud Drive'
    $browserWin.Width = 960
    $browserWin.Height = 720
    $browserWin.MinWidth = 800
    $browserWin.MinHeight = 600
    $browserWin.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $browserWin.Owner = $Owner }
    $browserWin.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')

    $rootGrid = [System.Windows.Controls.Grid]::new()
    $browserWin.Content = $rootGrid

    $rowTop = [System.Windows.Controls.RowDefinition]::new()
    $rowTop.Height = [System.Windows.GridLength]::Auto
    $rowMain = [System.Windows.Controls.RowDefinition]::new()
    $rowMain.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $rootGrid.RowDefinitions.Add($rowTop)
    $rootGrid.RowDefinitions.Add($rowMain)

    # Top banner card
    $headerBorder = [System.Windows.Controls.Border]::new()
    $headerBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F172A')
    $headerBorder.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
    [System.Windows.Controls.Grid]::SetRow($headerBorder, 0)
    $rootGrid.Children.Add($headerBorder) | Out-Null

    $headerDock = [System.Windows.Controls.DockPanel]::new()
    $headerBorder.Child = $headerDock

    # Right side action buttons
    $btnStack = [System.Windows.Controls.StackPanel]::new()
    $btnStack.Orientation = 'Horizontal'
    [System.Windows.Controls.DockPanel]::SetDock($btnStack, 'Right')
    $headerDock.Children.Add($btnStack) | Out-Null

    $checkBtn = [System.Windows.Controls.Button]::new()
    $checkBtn.Content = 'Check Connection Now'
    $checkBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $checkBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $checkBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
    $checkBtn.Foreground = [System.Windows.Media.Brushes]::White
    $checkBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $btnStack.Children.Add($checkBtn) | Out-Null

    $cancelBtn = [System.Windows.Controls.Button]::new()
    $cancelBtn.Content = 'Close'
    $cancelBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $cancelBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
    $cancelBtn.Foreground = [System.Windows.Media.Brushes]::White
    $cancelBtn.BorderThickness = [System.Windows.Thickness]::new(0)
    $cancelBtn.Add_Click({ $browserWin.Close() })
    $btnStack.Children.Add($cancelBtn) | Out-Null

    # Left side header texts
    $textStack = [System.Windows.Controls.StackPanel]::new()
    $headerDock.Children.Add($textStack) | Out-Null

    $titleBlock = [System.Windows.Controls.TextBlock]::new()
    $titleBlock.Text = 'Sign In to TeraBox'
    $titleBlock.FontSize = 15
    $titleBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
    $titleBlock.Foreground = [System.Windows.Media.Brushes]::White
    $textStack.Children.Add($titleBlock) | Out-Null

    $statusBlock = [System.Windows.Controls.TextBlock]::new()
    $statusBlock.Text = 'Sign in below. Once you see your files, NS Cloud Drive will automatically connect.'
    $statusBlock.FontSize = 11
    $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#94A3B8')
    $statusBlock.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    $textStack.Children.Add($statusBlock) | Out-Null

    # WebView2 container
    $wv = [Microsoft.Web.WebView2.Wpf.WebView2]::new()
    $props = [Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties]::new()
    $props.BrowserExecutableFolder = $wvInfo.RuntimePath
    $props.UserDataFolder = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\webview2-profile'
    $wv.CreationProperties = $props
    [System.Windows.Controls.Grid]::SetRow($wv, 1)
    $rootGrid.Children.Add($wv) | Out-Null

    $script:LoginCompleted = $false
    $script:CheckingSession = $false
    $script:SessionResult = $null

    $pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $pollTimer.Interval = [TimeSpan]::FromSeconds(1.5)

    $TryConnect = {
        param([bool]$Automatic = $true)

        if ($script:LoginCompleted -or $script:CheckingSession -or -not $wv.CoreWebView2) {
            return
        }

        $source = $wv.CoreWebView2.Source
        if ([string]::IsNullOrWhiteSpace($source)) { return }

        [Uri]$pageUri = $null
        if (-not [Uri]::TryCreate($source, [UriKind]::Absolute, [ref]$pageUri) -or
            $pageUri.Scheme -ne 'https' -or
            -not (Test-TeraBoxHost $pageUri.Host)) {
            if (-not $Automatic) {
                $statusBlock.Text = 'Please complete sign-in on the TeraBox website first.'
                $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FBBF24')
            }
            return
        }

        $script:CheckingSession = $true
        $pollTimer.Stop()
        $checkBtn.IsEnabled = $false

        try {
            $origin = "https://$($pageUri.Host)"

            # Non-blocking cookie retrieval for origin
            $cookieTask = $wv.CoreWebView2.CookieManager.GetCookiesAsync($origin)
            $cookieDone = Wait-WpfTask -Task $cookieTask -TimeoutMs 4000 -Window $browserWin
            if (-not $cookieDone -or -not $cookieTask.Result) {
                if (-not $Automatic) {
                    $statusBlock.Text = 'Unable to read browser cookies. Please try again.'
                    $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
                }
                return
            }

            $cookies = $cookieTask.Result
            $hasNdus = $false
            foreach ($c in $cookies) {
                if ($c.Name -eq 'ndus' -and -not [string]::IsNullOrEmpty($c.Value)) {
                    $hasNdus = $true
                    break
                }
            }

            if (-not $hasNdus) {
                if (-not $Automatic) {
                    $statusBlock.Text = 'TeraBox does not show you as signed in yet. Finish sign-in on the page below.'
                    $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FBBF24')
                }
                return
            }

            # ndus cookie present: transition UI
            $statusBlock.Text = 'Signed in. Checking the connection with TeraBox…'
            $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#38BDF8')

            # Extract window.jsToken from DOM asynchronously
            $jsToken = $null
            try {
                $scriptTask = $wv.CoreWebView2.ExecuteScriptAsync("typeof window.jsToken === 'string' ? window.jsToken : ''")
                $scriptDone = Wait-WpfTask -Task $scriptTask -TimeoutMs 3000 -Window $browserWin
                if ($scriptDone -and $scriptTask.Result) {
                    $rawToken = $scriptTask.Result
                    if ($rawToken.StartsWith('"') -and $rawToken.EndsWith('"') -and $rawToken.Length -gt 2) {
                        $jsToken = $rawToken.Substring(1, $rawToken.Length - 2)
                    } elseif ($rawToken -ne '""' -and -not [string]::IsNullOrEmpty($rawToken)) {
                        $jsToken = $rawToken
                    }
                }
            } catch { }

            # Build clean cookie string for active origin only
            $cookiePairs = @()
            foreach ($c in $cookies) {
                if (-not [string]::IsNullOrEmpty($c.Name) -and -not [string]::IsNullOrEmpty($c.Value)) {
                    $cookiePairs += "$($c.Name)=$($c.Value)"
                }
            }
            $cookieHeader = $cookiePairs -join '; '

            # Validate session against TeraBox backend non-blockingly
            $sessionOverride = @{
                Type = 'web-session'
                Secret = $cookieHeader
                JsToken = $jsToken
                BaseUrl = $origin
            }

            $testCheck = Test-TeraBoxBackendSession -SessionOverride $sessionOverride -Window $browserWin

            if ($testCheck.IsValid) {
                $script:LoginCompleted = $true

                # Store session with DPAPI
                Save-TeraBoxSession -Type 'web-session' -Secret $cookieHeader -JsToken $jsToken -BaseUrl $origin

                $scope = Test-TeraBoxAccountScope -SessionOverride $sessionOverride
                $files = Get-TeraBoxFileList -Directory $scope.RootPath -SessionOverride $sessionOverride -Window $browserWin
                $fileCount = if ($files.Success) { $files.ItemCount } else { 0 }

                $userName = if ($testCheck.UserInfo -and $testCheck.UserInfo.UserName) { $testCheck.UserInfo.UserName } else { 'TeraBox User' }
                $statusBlock.Text = "Connected as $userName ($fileCount files in root). Closing..."
                $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4ADE80')

                $script:SessionResult = [ordered]@{
                    Success = $true
                    UserName = $userName
                    ItemCount = $fileCount
                    Cookie = $cookieHeader
                    JsToken = $jsToken
                    BaseUrl = $origin
                }

                if ($OnLoginSucceeded) {
                    & $OnLoginSucceeded $script:SessionResult
                }

                # Clear browsing data from the isolated embedded profile
                try {
                    $clearTask = $wv.CoreWebView2.Profile.ClearBrowsingDataAsync()
                    [void](Wait-WpfTask -Task $clearTask -TimeoutMs 2000 -Window $browserWin)
                } catch { }

                # Brief delay so user sees confirmed success before window closes
                $closeTimer = [System.Windows.Threading.DispatcherTimer]::new()
                $closeTimer.Interval = [TimeSpan]::FromMilliseconds(800)
                $closeTimer.Add_Tick({
                    $closeTimer.Stop()
                    $browserWin.Close()
                })
                $closeTimer.Start()
                return
            } else {
                $errDetail = if ($testCheck.Error) { $testCheck.Error } else { 'TeraBox rejected the session.' }
                $statusBlock.Text = "TeraBox did not accept the session: $errDetail"
                $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
            }
        } finally {
            $script:CheckingSession = $false
            if (-not $script:LoginCompleted) {
                $checkBtn.IsEnabled = $true
                $pollTimer.Start()
            }
        }
    }

    $pollTimer.Add_Tick({ & $TryConnect $true })

    $checkBtn.Add_Click({ & $TryConnect $false })

    $wv.Add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if ($e.IsSuccess) {
            $wv.CoreWebView2.Settings.AreDevToolsEnabled = $false
            $wv.CoreWebView2.Settings.IsPasswordAutosaveEnabled = $false
            $wv.CoreWebView2.Settings.IsGeneralAutofillEnabled = $false
            $wv.CoreWebView2.Navigate('https://www.terabox.com/main')
            $pollTimer.Start()
        } else {
            $statusBlock.Text = "Embedded browser initialization failed: $($e.InitializationException.Message)"
            $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
        }
    })

    $browserWin.Add_Loaded({
        try {
            $wv.EnsureCoreWebView2Async()
        } catch {
            $statusBlock.Text = "Failed to launch WebView2: $($_.Exception.Message)"
            $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
        }
    })

    $browserWin.Add_Closing({
        $pollTimer.Stop()
        if (-not $script:LoginCompleted -and $OnStateChanged) {
            & $OnStateChanged 'Disconnected' 'Sign-in window was closed by the user.'
        }
    })

    [void]$browserWin.ShowDialog()

    if ($script:LoginCompleted -and $script:SessionResult) {
        return $script:SessionResult
    }

    return [ordered]@{
        Success = $false
        Cancelled = $true
        Error = 'Sign-in was not completed.'
    }
}
