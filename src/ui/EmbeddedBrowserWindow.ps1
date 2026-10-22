Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')

$script:CurrentBrowserWindow = $null
$script:BrowserWindowClosed = $false

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

    try {
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    } finally {
        $timer.Stop()
    }
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
    $script:CurrentBrowserWindow = $browserWin
    $script:BrowserWindowClosed = $false
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
    $cancelBtn.Add_Click({
        if ($script:CurrentBrowserWindow) { $script:CurrentBrowserWindow.Close() }
    })
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
    $script:LastTestedCookie = ''
    $script:LastTestedTime = [DateTime]::MinValue

    $pollTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $pollTimer.Interval = [TimeSpan]::FromSeconds(2)

    $TryConnect = {
        param([bool]$Automatic = $true)

        if ($script:BrowserWindowClosed -or $script:LoginCompleted -or $script:CheckingSession) {
            return
        }

        $activeWin = $script:CurrentBrowserWindow
        if (-not $activeWin -or -not $activeWin.IsVisible) {
            return
        }

        if (-not $wv.CoreWebView2) {
            if (-not $Automatic) {
                $statusBlock.Text = 'Embedded browser is still initializing. Please wait a moment.'
                $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FBBF24')
            }
            return
        }

        $source = $wv.CoreWebView2.Source
        if ([string]::IsNullOrWhiteSpace($source)) {
            if (-not $Automatic) {
                $statusBlock.Text = 'Waiting for page to load...'
                $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#94A3B8')
            }
            return
        }

        [Uri]$pageUri = $null
        if (-not [Uri]::TryCreate($source, [UriKind]::Absolute, [ref]$pageUri) -or
            $pageUri.Scheme -ne 'https' -or
            -not (Test-TeraBoxHost $pageUri.Host)) {
            if (-not $Automatic) {
                $statusBlock.Text = 'Please navigate to TeraBox and sign in below before checking connection.'
                $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FBBF24')
            }
            return
        }

        $script:CheckingSession = $true
        $pollTimer.Stop()
        $checkBtn.IsEnabled = $false

        try {
            $origin = "https://$($pageUri.Host)"

            # Capture active WebView2 UserAgent via DOM execution
            $ua = $null
            try {
                $uaTask = $wv.CoreWebView2.ExecuteScriptAsync("navigator.userAgent")
                $uaDone = Wait-WpfTask -Task $uaTask -TimeoutMs 2000 -Window $activeWin
                if ($uaDone -and $uaTask.Result) {
                    $rawUa = [string]$uaTask.Result
                    if ($rawUa.StartsWith('"') -and $rawUa.EndsWith('"') -and $rawUa.Length -gt 2) {
                        $ua = $rawUa.Substring(1, $rawUa.Length - 2)
                    } else {
                        $ua = $rawUa
                    }
                }
            } catch { }
            if (-not $ua) {
                try {
                    if ($wv.CoreWebView2.Settings -and $wv.CoreWebView2.Settings.UserAgent) {
                        $ua = [string]$wv.CoreWebView2.Settings.UserAgent
                    }
                } catch { }
            }

            # Non-blocking cookie retrieval across domains and active origin
            $cookieList = [System.Collections.Generic.List[Microsoft.Web.WebView2.Core.CoreWebView2Cookie]]::new()
            try {
                $allTask = $wv.CoreWebView2.CookieManager.GetCookiesAsync("")
                $allDone = Wait-WpfTask -Task $allTask -TimeoutMs 3000 -Window $activeWin
                if ($allDone -and $allTask.Result) {
                    foreach ($c in $allTask.Result) {
                        $cookieList.Add($c)
                    }
                }
            } catch { }

            if ($cookieList.Count -eq 0) {
                $cookieTask = $wv.CoreWebView2.CookieManager.GetCookiesAsync($origin)
                $cookieDone = Wait-WpfTask -Task $cookieTask -TimeoutMs 3000 -Window $activeWin
                if ($cookieDone -and $cookieTask.Result) {
                    foreach ($c in $cookieTask.Result) {
                        $cookieList.Add($c)
                    }
                }
            }

            $cookieDict = [ordered]@{}
            $hasNdus = $false
            foreach ($c in $cookieList) {
                if ($c.Name -eq 'ndus' -and -not [string]::IsNullOrEmpty($c.Value)) {
                    $hasNdus = $true
                }
                if (-not [string]::IsNullOrEmpty($c.Name) -and -not [string]::IsNullOrEmpty($c.Value)) {
                    $cookieDict[$c.Name] = $c.Value
                }
            }

            if (-not $hasNdus) {
                if (-not $Automatic) {
                    $statusBlock.Text = 'No active TeraBox session found. Complete sign-in on the page below and try again.'
                    $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FBBF24')
                }
                return
            }

            # Build clean cookie string for active origin only
            $cookiePairs = @()
            foreach ($k in $cookieDict.Keys) {
                $cookiePairs += "$k=$($cookieDict[$k])"
            }
            $cookieHeader = $cookiePairs -join '; '

            # Extract window.jsToken from DOM asynchronously
            $jsToken = $null
            try {
                $scriptTask = $wv.CoreWebView2.ExecuteScriptAsync("typeof window.jsToken === 'string' ? window.jsToken : ''")
                $scriptDone = Wait-WpfTask -Task $scriptTask -TimeoutMs 3000 -Window $activeWin
                if ($scriptDone -and $scriptTask.Result) {
                    $rawToken = $scriptTask.Result
                    if ($rawToken.StartsWith('"') -and $rawToken.EndsWith('"') -and $rawToken.Length -gt 2) {
                        $jsToken = $rawToken.Substring(1, $rawToken.Length - 2)
                    } elseif ($rawToken -ne '""' -and -not [string]::IsNullOrEmpty($rawToken)) {
                        $jsToken = $rawToken
                    }
                }
            } catch { }

            # Avoid spamming the backend during automatic polling if nothing changed recently
            $checkKey = "$cookieHeader|$jsToken"
            $now = [DateTime]::UtcNow
            if ($Automatic -and $script:LastTestedCookie -eq $checkKey -and ($now - $script:LastTestedTime).TotalSeconds -lt 5) {
                return
            }
            $script:LastTestedCookie = $checkKey
            $script:LastTestedTime = $now

            # Session cookie detected: inform user that backend validation is taking place
            $statusBlock.Text = 'Session detected. Validating authorization with TeraBox…'
            $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#38BDF8')

            # Validate session against TeraBox backend non-blockingly
            $sessionOverride = @{
                Type = 'web-session'
                Secret = $cookieHeader
                JsToken = $jsToken
                BaseUrl = $origin
                UserAgent = $ua
            }

            $testCheck = Test-TeraBoxBackendSession -SessionOverride $sessionOverride -Window $activeWin

            if ($testCheck.IsValid) {
                $script:LoginCompleted = $true

                # Store session with DPAPI (including active BaseUrl and UserAgent)
                $activeOrigin = if ($testCheck.UserInfo -and $testCheck.UserInfo.BaseUrl) { $testCheck.UserInfo.BaseUrl } else { $origin }
                Save-TeraBoxSession -Type 'web-session' -Secret $cookieHeader -JsToken $jsToken -BaseUrl $activeOrigin -UserAgent $ua

                $scope = Test-TeraBoxAccountScope -SessionOverride $sessionOverride
                $files = Get-TeraBoxFileList -Directory $scope.RootPath -SessionOverride $sessionOverride -Window $activeWin
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
                    BaseUrl = $activeOrigin
                    UserAgent = $ua
                }

                if ($OnLoginSucceeded) {
                    & $OnLoginSucceeded $script:SessionResult
                }

                # Clear browsing data from the isolated embedded profile
                try {
                    $clearTask = $wv.CoreWebView2.Profile.ClearBrowsingDataAsync()
                    [void](Wait-WpfTask -Task $clearTask -TimeoutMs 2000 -Window $activeWin)
                } catch { }

                # Brief delay so user sees confirmed success before window closes
                $closeTimer = [System.Windows.Threading.DispatcherTimer]::new()
                $closeTimer.Interval = [TimeSpan]::FromMilliseconds(800)
                $closeTimer.Add_Tick({
                    $closeTimer.Stop()
                    if ($script:CurrentBrowserWindow) {
                        $script:CurrentBrowserWindow.Close()
                    }
                })
                $closeTimer.Start()
                return
            } else {
                $errDetail = if ($testCheck.Error) { $testCheck.Error } else { 'TeraBox rejected the session.' }
                $statusBlock.Text = "Validation failed: $errDetail"
                $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
            }
        } finally {
            $script:CheckingSession = $false
            if (-not $script:LoginCompleted -and -not $script:BrowserWindowClosed) {
                $checkBtn.IsEnabled = $true
                $pollTimer.Start()
            }
        }
    }

    $pollTimer.Add_Tick({ & $TryConnect $true })

    $checkBtn.Add_Click({ & $TryConnect $false })

    $wv.Add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if ($script:BrowserWindowClosed -or -not $script:CurrentBrowserWindow) { return }
        if ($e.IsSuccess) {
            $wv.CoreWebView2.Settings.AreDevToolsEnabled = $false
            $wv.CoreWebView2.Settings.IsPasswordAutosaveEnabled = $false
            $wv.CoreWebView2.Settings.IsGeneralAutofillEnabled = $false
            $wv.CoreWebView2.Add_NavigationCompleted({
                param($s, $args)
                $script:LastTestedCookie = ''
            })
            $wv.CoreWebView2.Navigate('https://www.terabox.com/main')
            if (-not $script:BrowserWindowClosed) {
                $pollTimer.Start()
            }
        } else {
            $statusBlock.Text = "Embedded browser initialization failed: $($e.InitializationException.Message)"
            $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
        }
    })

    $browserWin.Add_Loaded({
        if ($script:BrowserWindowClosed -or -not $script:CurrentBrowserWindow) { return }
        try {
            $wv.EnsureCoreWebView2Async()
        } catch {
            $statusBlock.Text = "Failed to launch WebView2: $($_.Exception.Message)"
            $statusBlock.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F87171')
        }
    })

    $browserWin.Add_Closing({
        if ($pollTimer) { $pollTimer.Stop() }

        # If login was not marked complete yet, check if there is an active valid session before closing
        if (-not $script:LoginCompleted) {
            try {
                if ($wv -and $wv.CoreWebView2) {
                    & $TryConnect $false
                }
            } catch { }

            # If still not marked complete, check if a valid DPAPI session already exists
            if (-not $script:LoginCompleted) {
                try {
                    $savedSession = Get-TeraBoxSession
                    if ($savedSession -and $savedSession.Secret) {
                        $savedCheck = Test-TeraBoxBackendSession -SessionOverride $savedSession -Window $browserWin
                        if ($savedCheck.IsValid) {
                            $script:LoginCompleted = $true
                            $uName = if ($savedCheck.UserInfo -and $savedCheck.UserInfo.UserName) { $savedCheck.UserInfo.UserName } else { 'TeraBox User' }
                            $script:SessionResult = [ordered]@{
                                Success = $true
                                UserName = $uName
                                ItemCount = 0
                                Cookie = $savedSession.Secret
                                JsToken = $savedSession.JsToken
                                BaseUrl = $savedSession.BaseUrl
                                UserAgent = $savedSession.UserAgent
                            }
                            if ($OnLoginSucceeded) {
                                & $OnLoginSucceeded $script:SessionResult
                            }
                        }
                    }
                } catch { }
            }
        }

        $script:BrowserWindowClosed = $true

        if (-not $script:LoginCompleted -and $OnStateChanged) {
            try {
                & $OnStateChanged 'Disconnected' 'Sign-in window was closed by the user.'
            } catch { }
        }
    })

    $browserWin.Add_Closed({
        $script:BrowserWindowClosed = $true
        if ($pollTimer) { $pollTimer.Stop() }
        $script:CurrentBrowserWindow = $null
    })

    try {
        [void]$browserWin.ShowDialog()
    } finally {
        $script:BrowserWindowClosed = $true
        if ($pollTimer) { $pollTimer.Stop() }
        $script:CurrentBrowserWindow = $null
        try { $wv.Dispose() } catch { }
    }

    if ($script:LoginCompleted -and $script:SessionResult) {
        return $script:SessionResult
    }

    return [ordered]@{
        Success = $false
        Cancelled = $true
        Error = 'Sign-in was not completed.'
    }
}
