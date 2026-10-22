Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot '..\providers\GoogleDriveProvider.ps1')

function New-UIElement-Label([string]$Text, [int]$Size = 13, [string]$Color = '#172033', [bool]$Bold = $false) {
    $block = [System.Windows.Controls.TextBlock]::new()
    $block.Text = $Text
    $block.FontSize = $Size
    $block.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    if ($Bold) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $block.TextWrapping = 'Wrap'
    return $block
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
   • Test Users: Add your Google account email under 'Test users' (required while publishing status is 'Testing').
   • Click Save and Continue.

4. Create OAuth 2.0 Desktop Credentials:
   • Navigate to 'APIs & Services' > 'Credentials' > '+ CREATE CREDENTIALS' > 'OAuth client ID'.
   • Application type: Select 'Desktop app'.
   • Name: 'NS Cloud Drive Desktop Client'.
   • Click 'CREATE'.

5. Configure NS Cloud Drive:
   • Click 'DOWNLOAD JSON' in Google Cloud Console.
   • Copy the downloaded JSON file into:
     $env:LOCALAPPDATA\NSCloudDrive\config\google-oauth.json
     (Or drop the downloaded 'client_secret_*.json' directly into that folder).
   • Alternatively, set the environment variable:
     setx GOOGLE_CLIENT_ID "your-client-id.apps.googleusercontent.com"

Note: Native desktop apps use PKCE (RFC 7636); a client secret is NOT required.
"@
    Show-DiagnosticsDialog -Title 'Google Drive Setup' -DiagnosticsContent $instructions -Owner $Owner
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

function Show-ProviderConnectionWindow([string]$ProviderId, [System.Windows.Window]$Owner = $null, [scriptblock]$OnStateChanged = $null) {
    $providerInfo = $null
    if ($ProviderId -eq 'terabox') {
        $providerInfo = Get-TeraBoxProviderInfo
    } elseif ($ProviderId -eq 'gdrive') {
        $providerInfo = Get-GoogleDriveProviderInfo
    } else {
        throw "Unsupported provider ID: $ProviderId"
    }

    $win = [System.Windows.Window]::new()
    $win.Title = "Connect $($providerInfo.Name) - NS Cloud Drive"
    $win.Width = 720
    $win.Height = 620
    $win.MinWidth = 640
    $win.MinHeight = 540
    $win.WindowStartupLocation = 'CenterOwner'
    if ($Owner) { $win.Owner = $Owner }
    $win.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
    $win.FontFamily = 'Segoe UI'

    $root = [System.Windows.Controls.DockPanel]::new()
    $root.Margin = [System.Windows.Thickness]::new(24)
    $win.Content = $root

    # Header section
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
    $titleBox.Children.Add((New-UIElement-Label "Connect $($providerInfo.Name)" 18 '#0F172A' $true)) | Out-Null
    $titleBox.Children.Add((New-UIElement-Label "Authenticate and validate access before mounting as virtual drive." 12 '#64748B')) | Out-Null
    $brandPanel.Children.Add($titleBox) | Out-Null
    $headerStack.Children.Add($brandPanel) | Out-Null
    $root.Children.Add($headerStack) | Out-Null

    # Status & Progress Card
    $statusCard = [System.Windows.Controls.Border]::new()
    $statusCard.Background = [System.Windows.Media.Brushes]::White
    $statusCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
    $statusCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $statusCard.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $statusCard.Padding = [System.Windows.Thickness]::new(16)
    $statusCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)

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
    $statusBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F2F4F7')
    $statusRow.Children.Add($statusBadge) | Out-Null
    $statusStack.Children.Add($statusRow) | Out-Null

    $statusDesc = New-UIElement-Label 'No account is connected.' 12 '#64748B'
    $statusDesc.Margin = [System.Windows.Thickness]::new(0, 6, 0, 8)
    $statusStack.Children.Add($statusDesc) | Out-Null

    $progressBar = [System.Windows.Controls.ProgressBar]::new()
    $progressBar.Height = 4
    $progressBar.IsIndeterminate = $false
    $progressBar.Visibility = 'Collapsed'
    $progressBar.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($providerInfo.AccentColor)
    $statusStack.Children.Add($progressBar) | Out-Null

    # Explanation and Action Area
    $contentScroll = [System.Windows.Controls.ScrollViewer]::new()
    $contentScroll.VerticalScrollBarVisibility = 'Auto'
    $contentScroll.HorizontalScrollBarVisibility = 'Disabled'
    $root.Children.Add($contentScroll) | Out-Null

    $contentStack = [System.Windows.Controls.StackPanel]::new()
    $contentScroll.Content = $contentStack

    $contentStack.Children.Add($statusCard) | Out-Null

    $isWindowClosing = $false
    $win.Add_Closing({ $isWindowClosing = $true })

    # Diagnostics log buffer
    $script:LogBuffer = [System.Collections.Generic.List[string]]::new()
    $script:LogBuffer.Add("[$([DateTime]::Now.ToString('HH:mm:ss'))] Opened connection window for $($providerInfo.Name)")

    $actionCard = [System.Windows.Controls.Border]::new()
    $actionCard.Background = [System.Windows.Media.Brushes]::White
    $actionCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
    $actionCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $actionCard.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $actionCard.Padding = [System.Windows.Thickness]::new(16)
    $actionCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    $actionStack = [System.Windows.Controls.StackPanel]::new()
    $actionCard.Child = $actionStack
    $contentStack.Children.Add($actionCard) | Out-Null

    # Update State Helper
    $UpdateState = {
        param([string]$NewState, [string]$CustomMessage = $null)
        $info = Get-ConnectionStateInfo $NewState
        $badgeText.Text = $info.Label
        $badgeText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($info.BadgeColor)
        $statusBadge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($info.BadgeBackground)

        if ($CustomMessage) {
            $statusDesc.Text = $CustomMessage
            $script:LogBuffer.Add("[$([DateTime]::Now.ToString('HH:mm:ss'))] $NewState - $CustomMessage")
        } else {
            $statusDesc.Text = $info.Description
            $script:LogBuffer.Add("[$([DateTime]::Now.ToString('HH:mm:ss'))] $NewState - $($info.Description)")
        }

        if ($NewState -in @('OpeningSignIn', 'ValidatingAuthorization', 'CheckingAccountScope', 'ListingFiles', 'Reconnecting')) {
            $progressBar.Visibility = 'Visible'
            $progressBar.IsIndeterminate = $true
        } else {
            $progressBar.Visibility = 'Collapsed'
            $progressBar.IsIndeterminate = $false
        }

        if ($OnStateChanged) {
            & $OnStateChanged $ProviderId $NewState
        }
    }

    if ($ProviderId -eq 'terabox') {
        $actionStack.Children.Add((New-UIElement-Label 'TeraBox Authentication' 15 '#0F172A' $true)) | Out-Null
        $methodDesc = New-UIElement-Label 'Sign in using the legitimate TeraBox website. The session will be validated through genuine backend API checks before mounting is unlocked.' 12 '#64748B'
        $methodDesc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 12)
        $actionStack.Children.Add($methodDesc) | Out-Null

        $openWebBtn = [System.Windows.Controls.Button]::new()
        $openWebBtn.Content = '1. Open TeraBox Website Sign-in'
        $openWebBtn.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
        $openWebBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        $openWebBtn.HorizontalAlignment = 'Left'
        $openWebBtn.Add_Click({
            & $UpdateState 'OpeningSignIn' 'Opening official TeraBox sign-in in browser...'
            [System.Diagnostics.Process]::Start('https://www.terabox.com/') | Out-Null
            & $UpdateState 'AwaitingUserAuth' 'Please sign in to your TeraBox account on the website, then click "I''ve signed in — Connect" below.'
        })
        $actionStack.Children.Add($openWebBtn) | Out-Null

        $validateBtn = [System.Windows.Controls.Button]::new()
        $validateBtn.Content = '2. I''ve signed in — Connect'
        $validateBtn.Padding = [System.Windows.Thickness]::new(14, 8, 14, 8)
        $validateBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($providerInfo.AccentColor)
        $validateBtn.Foreground = [System.Windows.Media.Brushes]::White
        $validateBtn.BorderThickness = [System.Windows.Thickness]::new(0)
        $validateBtn.HorizontalAlignment = 'Left'
        $validateBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

        $validateBtn.Add_Click({
            & $UpdateState 'ValidatingAuthorization' 'Testing connection against TeraBox backend...'
            $check = Test-TeraBoxBackendSession
            if ($check.IsValid) {
                & $UpdateState 'CheckingAccountScope' 'Checking accessible directories...'
                $scope = Test-TeraBoxAccountScope
                & $UpdateState 'ListingFiles' "Testing file access in root ($($scope.RootPath))..."
                $files = Get-TeraBoxFileList -Directory $scope.RootPath
                if ($files.Success) {
                    & $UpdateState 'Connected' "Connected as $($check.UserInfo.UserName) ($($files.ItemCount) files found in root)."
                } else {
                    & $UpdateState 'Connected' "Connected as $($check.UserInfo.UserName) (Directory listing returned 0 items or pending initial upload)."
                }
            } else {
                & $UpdateState $check.State $check.Error
            }
        })
        $actionStack.Children.Add($validateBtn) | Out-Null
    } elseif ($ProviderId -eq 'gdrive') {
        $actionStack.Children.Add((New-UIElement-Label 'Google Drive Authorization' 15 '#0F172A' $true)) | Out-Null
        $methodDesc = New-UIElement-Label 'Sign in using Google''s official OAuth 2.0 flow with PKCE (RFC 7636). A local loopback listener will securely receive the authorization code.' 12 '#64748B'
        $methodDesc.Margin = [System.Windows.Thickness]::new(0, 4, 0, 10)
        $actionStack.Children.Add($methodDesc) | Out-Null

        $oauthCfg = Get-GoogleOAuthConfig

        # Configuration status banner
        $cfgCard = [System.Windows.Controls.Border]::new()
        $cfgCard.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $cfgCard.Padding = [System.Windows.Thickness]::new(12)
        $cfgCard.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)

        $cfgStack = [System.Windows.Controls.StackPanel]::new()
        $cfgCard.Child = $cfgStack

        if ($oauthCfg.IsConfigured) {
            $cfgCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#ECFDF5')
            $cfgCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#A7F3D0')
            $cfgCard.BorderThickness = [System.Windows.Thickness]::new(1)
            $maskedId = if ($oauthCfg.ClientId.Length -gt 16) { $oauthCfg.ClientId.Substring(0, 12) + '...' + $oauthCfg.ClientId.Substring($oauthCfg.ClientId.Length - 4) } else { $oauthCfg.ClientId }
            $cfgLabel = New-UIElement-Label "OAuth Client Configured ($maskedId)" 12 '#065F46' $true
            $cfgStack.Children.Add($cfgLabel) | Out-Null
            $cfgSub = New-UIElement-Label 'PKCE desktop authorization ready. Click "Sign in with Google" to connect.' 11 '#047857'
            $cfgSub.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
            $cfgStack.Children.Add($cfgSub) | Out-Null
        } else {
            $cfgCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FEF3C7')
            $cfgCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FCD34D')
            $cfgCard.BorderThickness = [System.Windows.Thickness]::new(1)
            $cfgLabel = New-UIElement-Label 'Google OAuth Client ID Required' 12 '#92400E' $true
            $cfgStack.Children.Add($cfgLabel) | Out-Null
            $cfgSub = New-UIElement-Label 'A Desktop app OAuth client ID is required to connect to Google Drive. Client secret is optional with PKCE.' 11 '#78350F'
            $cfgSub.Margin = [System.Windows.Thickness]::new(0, 2, 0, 8)
            $cfgStack.Children.Add($cfgSub) | Out-Null

            $cfgBtnRow = [System.Windows.Controls.WrapPanel]::new()

            $guideBtn = [System.Windows.Controls.Button]::new()
            $guideBtn.Content = 'View Setup Guide'
            $guideBtn.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
            $guideBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
            $guideBtn.Add_Click({ Show-GoogleSetupInstructionsDialog -Owner $win })
            $cfgBtnRow.Children.Add($guideBtn) | Out-Null

            $openDirBtn = [System.Windows.Controls.Button]::new()
            $openDirBtn.Content = 'Open Config Folder'
            $openDirBtn.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
            $openDirBtn.Add_Click({
                if (-not (Test-Path -LiteralPath $oauthCfg.ConfigDirectory)) {
                    New-Item -ItemType Directory -Path $oauthCfg.ConfigDirectory -Force | Out-Null
                }
                [System.Diagnostics.Process]::Start('explorer.exe', $oauthCfg.ConfigDirectory) | Out-Null
            })
            $cfgBtnRow.Children.Add($openDirBtn) | Out-Null
            $cfgStack.Children.Add($cfgBtnRow) | Out-Null
        }
        $actionStack.Children.Add($cfgCard) | Out-Null

        $signInBtn = [System.Windows.Controls.Button]::new()
        $signInBtn.Content = 'Sign in with Google'
        $signInBtn.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
        $signInBtn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F9D58')
        $signInBtn.Foreground = [System.Windows.Media.Brushes]::White
        $signInBtn.BorderThickness = [System.Windows.Thickness]::new(0)
        $signInBtn.HorizontalAlignment = 'Left'
        $signInBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)

        $signInBtn.Add_Click({
            $currentOauth = Get-GoogleOAuthConfig
            if (-not $currentOauth.IsConfigured) {
                & $UpdateState 'Error' "Google OAuth Client ID is not configured. Click 'View Setup Guide' above for instructions or set GOOGLE_CLIENT_ID."
                Show-GoogleSetupInstructionsDialog -Owner $win
                return
            }

            & $UpdateState 'OpeningSignIn' 'Starting local authorization listener...'
            $state = New-OAuthState
            $verifier = New-PkceVerifier
            $challenge = New-PkceChallenge $verifier
            try {
                $listenerCtx = Start-OAuthLoopbackListener -ExpectedState $state
                $authUrl = Build-GoogleAuthorizationUrl -ClientId $currentOauth.ClientId -RedirectUri $listenerCtx.RedirectUri -State $state -CodeChallenge $challenge
                & $UpdateState 'AwaitingUserAuth' "Please complete Google authorization in the browser ($($listenerCtx.RedirectUri))..."
                [System.Diagnostics.Process]::Start($authUrl) | Out-Null

                # Asynchronously wait for callback without blocking UI thread completely
                $waitResult = Wait-OAuthLoopbackResponse -ListenerContext $listenerCtx -CancelCheck { $isWindowClosing -or -not $win.IsVisible }
                if ($waitResult.Success) {
                    & $UpdateState 'ValidatingAuthorization' 'Exchanging authorization code with PKCE verifier...'
                    $tokenResult = Exchange-GoogleAuthCode -ClientId $currentOauth.ClientId -ClientSecret $currentOauth.ClientSecret -Code $waitResult.Code -RedirectUri $listenerCtx.RedirectUri -CodeVerifier $verifier
                    if ($tokenResult.Success) {
                        & $UpdateState 'CheckingAccountScope' 'Verifying Google Drive scope...'
                        $verify = Test-GoogleDriveBackendSession -TokensOverride $tokenResult.Tokens
                        if ($verify.IsValid) {
                            & $UpdateState 'ListingFiles' 'Testing Google Drive file query...'
                            $files = Get-GoogleDriveFileList -TokensOverride $tokenResult.Tokens
                            if ($files.Success) {
                                & $UpdateState 'Connected' "Connected as $($verify.UserInfo.DisplayName) ($($files.ItemCount) items found in root)."
                            } else {
                                & $UpdateState 'Connected' "Connected as $($verify.UserInfo.DisplayName) (Directory listing returned 0 items)."
                            }
                        } else {
                            & $UpdateState $verify.State $verify.Error
                        }
                    } else {
                        & $UpdateState 'Error' $tokenResult.Error
                    }
                } else {
                    & $UpdateState 'Error' $waitResult.Error
                }
            } catch {
                & $UpdateState 'Error' (Format-SanitizedDiagnosticMessage $_.Exception.Message)
            }
        })
        $actionStack.Children.Add($signInBtn) | Out-Null
    }

    # Common buttons row: Test connection, Disconnect, Diagnostics
    $commonButtons = [System.Windows.Controls.WrapPanel]::new()
    $commonButtons.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)

    $testBtn = [System.Windows.Controls.Button]::new()
    $testBtn.Content = 'Test connection'
    $testBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $testBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
    $testBtn.Add_Click({
        if ($ProviderId -eq 'terabox') {
            & $UpdateState 'ValidatingAuthorization' 'Validating TeraBox session...'
            $res = Test-TeraBoxBackendSession
            if ($res.IsValid) {
                & $UpdateState 'Connected' "Verified connection for $($res.UserInfo.UserName)"
            } else {
                & $UpdateState $res.State $res.Error
            }
        } else {
            & $UpdateState 'ValidatingAuthorization' 'Validating Google Drive session...'
            $res = Test-GoogleDriveBackendSession
            if ($res.IsValid) {
                & $UpdateState 'Connected' "Verified connection for $($res.UserInfo.DisplayName)"
            } else {
                & $UpdateState $res.State $res.Error
            }
        }
    })
    $commonButtons.Children.Add($testBtn) | Out-Null

    $disconnectBtn = [System.Windows.Controls.Button]::new()
    $disconnectBtn.Content = 'Disconnect'
    $disconnectBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $disconnectBtn.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
    $disconnectBtn.Add_Click({
        if ($ProviderId -eq 'terabox') {
            Remove-TeraBoxSession
        } else {
            Remove-GoogleDriveSession
        }
        & $UpdateState 'Disconnected' 'Locally stored session removed cleanly.'
    })
    $commonButtons.Children.Add($disconnectBtn) | Out-Null

    $diagBtn = [System.Windows.Controls.Button]::new()
    $diagBtn.Content = 'View Diagnostics'
    $diagBtn.Padding = [System.Windows.Thickness]::new(12, 6, 12, 6)
    $diagBtn.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $diagBtn.Add_Click({
        $diagText = $script:LogBuffer -join "`r`n"
        Show-DiagnosticsDialog -Title $providerInfo.Name -DiagnosticsContent $diagText -Owner $win
    })
    $commonButtons.Children.Add($diagBtn) | Out-Null

    $actionStack.Children.Add($commonButtons) | Out-Null

    # Initial check on open
    if ($ProviderId -eq 'terabox') {
        $initial = Test-TeraBoxBackendSession
        if ($initial.IsValid) {
            & $UpdateState 'Connected' "Existing session active for $($initial.UserInfo.UserName)"
        } else {
            & $UpdateState $initial.State $initial.Error
        }
    } else {
        $initial = Test-GoogleDriveBackendSession
        if ($initial.IsValid) {
            & $UpdateState 'Connected' "Existing session active for $($initial.UserInfo.DisplayName)"
        } else {
            & $UpdateState $initial.State $initial.Error
        }
    }

    [void]$win.ShowDialog()
}
