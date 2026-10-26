Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $projectRoot 'src\NSCloudDrive.ps1'
$mainSource = Get-Content -LiteralPath $mainScript -Raw
$testRoot = Join-Path $env:TEMP ('NSCloudDrive-startup-timer-' + [guid]::NewGuid().ToString('N'))
$settingsDirectory = Join-Path $testRoot 'NSCloudDrive\config'
$cacheDirectory = Join-Path $testRoot 'cache'
$resultPath = Join-Path $testRoot 'result.json'
$harnessPath = Join-Path $testRoot 'startup-probe.ps1'
$stdoutPath = Join-Path $testRoot 'startup-probe.stdout.log'
$stderrPath = Join-Path $testRoot 'startup-probe.stderr.log'
$tracePath = Join-Path $testRoot 'startup-probe.trace.log'
$originalLocalAppData = $env:LOCALAPPDATA
$originalTestRoot = $env:NSCD_TEST_ROOT
$originalResultPath = $env:NSCD_TEST_RESULT
$originalTracePath = $env:NSCD_TEST_TRACE
$child = $null
$preserveTestRoot = $false

try {
    if ($mainSource -notmatch 'StageStartedAt = \[DateTime\]::UtcNow') {
        throw 'Startup restore stages must own their elapsed-time origin.'
    }
    if ($mainSource -notmatch "Get-StartupRestoreDisplay -ProviderId 'terabox'") {
        throw 'TeraBox status must use its provider-specific restore progress.'
    }
    if ($mainSource -notmatch 'Set-StartupRestoreProgress -Progress \$progress -Stage ''Validating TeraBox session'' -ProviderId ''terabox''') {
        throw 'TeraBox startup validation must publish its provider identity and stage.'
    }
    if ($mainSource -notmatch '\$refreshInterval = if \(\$script:StartupAutoMountPending -or \$script:StartupAutoMountWorker\) \{ 1 \} else \{ 4 \}') {
        throw 'Startup progress must refresh once per second without increasing idle refresh work.'
    }
    if ($mainSource -match '\$restoreStateLabel') {
        throw 'Startup restore labels must not share one provider stage across all drive cards.'
    }
    if ($mainSource -notmatch 'function Ensure-UiDriveStatusShape' -or $mainSource -notmatch 'MountState = \$null') {
        throw 'UI drive status snapshots must safely expose the optional MountState property.'
    }

    New-Item -ItemType Directory -Path $settingsDirectory, $cacheDirectory -Force | Out-Null
    $settings = [ordered]@{
        AutoMountDrives = $true
        AutoStartWithWindows = $false
        MinimizeToTrayOnClose = $false
        StartMinimized = $false
        OpenExplorerOnMount = $false
        Theme = 'Light'
        CacheDirectory = $cacheDirectory
        CacheMaxGigabytes = 1
        DiagnosticLogging = 'Off'
        HealthCheckIntervalSec = 4
        ProviderDriveLetters = @{ gdrive = 'G'; terabox = 'T' }
        Accounts = @(
            [ordered]@{
                Id = 'google-account-a'
                ProviderId = 'gdrive'
                DisplayName = 'Naboraj Sarkar'
                AccountEmail = 'naboraj-a@example.test'
                DriveLetter = 'G'
                AutoMount = $false
                OpenExplorerOnMount = $false
                ReadOnly = $false
            },
            [ordered]@{
                Id = 'google-account-b'
                ProviderId = 'gdrive'
                DisplayName = 'Bidyutraj Sarkar'
                AccountEmail = 'bidyutraj-b@example.test'
                DriveLetter = 'H'
                AutoMount = $false
                OpenExplorerOnMount = $false
                ReadOnly = $false
            },
            [ordered]@{
                Id = 'terabox-account'
                ProviderId = 'terabox'
                DisplayName = 'Synthetic TeraBox'
                AccountEmail = 'terabox-user@example.test'
                DriveLetter = 'T'
                AutoMount = $false
                OpenExplorerOnMount = $false
                ReadOnly = $false
            }
        )
    }
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $settingsDirectory 'settings.json') -Encoding UTF8

    $quotedMainScript = "'" + $mainScript.Replace("'", "''") + "'"
    $harness = @"
`$ErrorActionPreference = 'Stop'
`$env:LOCALAPPDATA = `$env:NSCD_TEST_ROOT
Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'before-main-source'
. $quotedMainScript
Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'after-main-source'
function Start-ProviderStatusRefreshWorker {}
function Start-StartupCacheRecoveryWorker {}
function Invoke-StartupAutoMount {
    `$script:StartupAutoMountPending = `$false
    `$script:StartupAutoMountWorker = `$null
    `$script:StartupAutoMountProgress.Stage = 'Recovery checks complete'
}
`$incompleteStatus = [pscustomobject]@{
    IsMounted = `$false
    ProcessRunning = `$false
    DriveLetter = 'G'
    DriveRoot = 'G:\'
    ProcessId = `$null
}
`$mountedSnapshot = [ordered]@{ IsMounted = `$true; ProcessRunning = `$true; DriveLetter = 'H'; DriveRoot = 'H:\'; ProcessId = 12345 }
`$script:AccountMountStates['probe-account'] = [ordered]@{ State = 'Error'; Stage = 'Root probe timed out'; Error = 'probe timeout'; DriveLetter = 'H' }
`$script:LegacyMountStates['gdrive'] = [ordered]@{ State = 'Error'; Stage = 'Root probe timed out'; Error = 'probe timeout'; DriveLetter = 'G' }
`$script:ProviderStatusSnapshot = [pscustomobject]@{
    GoogleStatus = `$mountedSnapshot
    AccountStatuses = @{ 'probe-account' = `$mountedSnapshot }
}
`$failedAccountLiveStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive' -AccountId 'probe-account' -DriveLetter 'H'
`$failedLegacyLiveStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive' -DriveLetter 'G'
`$script:ProviderStatusSnapshot = [pscustomobject]@{
    GoogleStatus = `$mountedSnapshot
    AccountStatuses = @{}
}
`$unmappedAccountStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive' -AccountId 'google-account-a' -DriveLetter 'G'
`$script:ProviderStatusSnapshot = [pscustomobject]@{
    GoogleStatus = `$mountedSnapshot
    AccountStatuses = @{ 'google-account-a' = `$mountedSnapshot }
}
`$script:AccountMountStates['google-account-a'] = [ordered]@{ State = 'Error'; Stage = 'Mapping validation'; Error = 'stale drive mapping'; DriveLetter = 'G' }
`$mismatchedAccountStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive' -AccountId 'google-account-a' -DriveLetter 'G'
`$script:AccountMountStates.Remove('probe-account')
`$script:AccountMountStates.Remove('google-account-a')
`$script:LegacyMountStates.Remove('gdrive')
`$script:ProviderStatusSnapshot = [pscustomobject]@{ GoogleStatus = `$incompleteStatus }
`$cachedStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive'
if (-not `$cachedStatus.Contains('MountState') -or `$null -ne `$cachedStatus['MountState'] -or
    -not `$cachedStatus.Contains('IsReadOnly') -or `$null -ne `$cachedStatus['IsReadOnly']) {
    throw 'An incomplete provider status was not normalized with safe MountState and unavailable IsReadOnly values.'
}
Update-AllUIState
`$accountCards = @(`$accountsStack.Children | Where-Object { `$_ -is [System.Windows.Controls.Border] })
`$renderedAccountCards = @(
    foreach (`$card in `$accountCards) {
        `$iconContainer = @(`$card.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.Grid] } | Select-Object -First 1)[0]
        `$infoStack = @(`$card.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.StackPanel] } | Select-Object -First 1)[0]
        `$badge = @(`$iconContainer.Children | Where-Object { `$_ -is [System.Windows.Controls.Border] } | Select-Object -First 1)[0]
        [pscustomobject]@{
            Provider = [string]`$infoStack.Children[0].Text
            Name = [string]`$infoStack.Children[1].Text
            Email = [string]`$infoStack.Children[2].Text
            IconFile = [System.IO.Path]::GetFileName([string]`$badge.Child.Source.UriSource.LocalPath)
        }
    }
)
`$script:StartupAutoMountPending = `$true
`$script:StartupAutoMountWorker = `$null
`$script:StartupAutoMountProgress.Stage = 'Waiting for startup dispatcher'
`$script:StartupAutoMountProgress.ProviderId = ''
`$script:StartupAutoMountProgress.DriveLetter = ''
`$script:StartupAutoMountProgress.AccountId = ''
`$script:StartupAutoMountProgress.StartedAt = [DateTime]::UtcNow.AddSeconds(-3)
`$script:StartupAutoMountProgress.StageStartedAt = `$script:StartupAutoMountProgress.StartedAt
`$dispatcherWaitStart = Get-StartupRestoreDisplay -ProviderId 'terabox' -DriveLetter 'T'
Start-Sleep -Milliseconds 1200
`$dispatcherWaitAfter = Get-StartupRestoreDisplay -ProviderId 'terabox' -DriveLetter 'T'
`$script:StartupAutoMountPending = `$true
`$script:StartupAutoMountWorker = [pscustomobject]@{ StartedAt = [DateTime]::UtcNow.AddSeconds(-7) }
`$script:StartupAutoMountProgress.ProviderId = 'terabox'
`$script:StartupAutoMountProgress.DriveLetter = 'T'
`$script:StartupAutoMountProgress.AccountId = ''
`$script:StartupAutoMountProgress.Stage = 'Validating TeraBox session'
`$script:StartupAutoMountProgress.StartedAt = [DateTime]::UtcNow.AddSeconds(-25)
`$script:StartupAutoMountProgress.StageStartedAt = [DateTime]::UtcNow.AddSeconds(-7)
`$tbProgressLabel = Get-StartupRestoreDisplay -ProviderId 'terabox' -DriveLetter 'T'
`$gdProgressLabel = Get-StartupRestoreDisplay -ProviderId 'gdrive' -DriveLetter 'G'
`$script:StartupAutoMountPending = `$false
`$script:StartupAutoMountWorker = `$null
`$app = [System.Windows.Application]::new()
Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'after-application'
`$app.Add_DispatcherUnhandledException({
    param(`$sender, `$eventArgs)
    Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value ("dispatcher-error: " + `$eventArgs.Exception.ToString())
    `$eventArgs.Handled = `$true
})
`$window.ShowInTaskbar = `$false
Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'after-window-taskbar'
`$window.WindowState = [System.Windows.WindowState]::Minimized
Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'after-window-state'
`$fixtureLogDirectory = Join-Path `$env:LOCALAPPDATA 'NSCloudDrive\logs'
New-Item -ItemType Directory -Path `$fixtureLogDirectory -Force | Out-Null
`$fixtureLog = @(
    '{"timestampUtc":"2026-01-01T00:00:00Z","severity":"Info","provider":"gdrive","accountId":"probe-account","accountLabel":"Synthetic account","operation":"mount","durationMs":10,"message":"synthetic searchable marker","recovered":true}',
    '{"timestampUtc":"2026-01-01T00:00:01Z","severity":"Warning","provider":"terabox","accountId":"probe-terabox","accountLabel":"Synthetic TeraBox","operation":"restore","durationMs":20,"message":"secondary synthetic entry","recovered":null}'
)
[System.IO.File]::WriteAllText((Join-Path `$fixtureLogDirectory 'application.jsonl'), [string]::Join([Environment]::NewLine, `$fixtureLog) + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
`$logsNavigationError = `$null
try {
    Show-LogsView
    Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'logs-view-shown'
} catch {
    `$logsNavigationError = [string]`$_.Exception.Message
}
`$probe = [System.Windows.Threading.DispatcherTimer]::new()
`$probe.Interval = [TimeSpan]::FromSeconds(5)
`$probe.Add_Tick({
    `$probe.Stop()
    `$logsLoadCompletedBeforeNavigation = (`$null -eq `$script:LogsLoadOperation)
    `$logsStatusBeforeNavigation = [string]`$logsStatusLine.Text
    `$logsPageEntryCount = `$script:LogsRenderedEntries.Count
    `$logsAccountFilterValue = [string]`$logsAccountCombo.Items[1]
    `$logsSearchBox.Text = 'synthetic searchable marker'
    `$logsTextBeforeNavigation = [string]`$logsTextBox.Text
    Show-DisksView
    `$result = [ordered]@{
        Pending = [bool]`$script:StartupAutoMountPending
        HasWorker = (`$null -ne `$script:StartupAutoMountWorker)
        DispatchError = `$script:StartupAutoMountError
        RestoreStage = [string]`$script:StartupAutoMountProgress.Stage
        DispatcherWaitStart = `$dispatcherWaitStart
        DispatcherWaitAfter = `$dispatcherWaitAfter
        TeraBoxProgress = `$tbProgressLabel
        GoogleProgress = `$gdProgressLabel
        CachedStatusHasMountState = `$cachedStatus.Contains('MountState')
        CachedStatusMountState = `$cachedStatus['MountState']
        CachedStatusHasReadOnly = `$cachedStatus.Contains('IsReadOnly')
        CachedStatusReadOnly = `$cachedStatus['IsReadOnly']
        UnmappedAccountIsMounted = [bool]`$unmappedAccountStatus.IsMounted
        UnmappedAccountProcessRunning = [bool]`$unmappedAccountStatus.ProcessRunning
        MismatchedAccountIsMounted = [bool]`$mismatchedAccountStatus.IsMounted
        MismatchedAccountProcessRunning = [bool]`$mismatchedAccountStatus.ProcessRunning
        AccountCardCount = `$renderedAccountCards.Count
        AccountCardProviders = @(`$renderedAccountCards | ForEach-Object { `$_.Provider })
        AccountCardNames = @(`$renderedAccountCards | ForEach-Object { `$_.Name })
        AccountCardEmails = @(`$renderedAccountCards | ForEach-Object { `$_.Email })
        AccountCardIcons = @(`$renderedAccountCards | ForEach-Object { `$_.IconFile })
        LogsNavigationError = `$logsNavigationError
        LogsLoadCompleted = `$logsLoadCompletedBeforeNavigation
        LogsViewCollapsedAfterNavigation = (`$logsView.Visibility -eq [System.Windows.Visibility]::Collapsed)
        LogsStatus = `$logsStatusBeforeNavigation
        PreservesAccountProcessAfterError = (`$failedAccountLiveStatus.IsMounted -and `$failedAccountLiveStatus.ProcessRunning -and `$failedAccountLiveStatus.MountState.State -eq 'Error')
        PreservesLegacyProcessAfterError = (`$failedLegacyLiveStatus.IsMounted -and `$failedLegacyLiveStatus.ProcessRunning -and `$failedLegacyLiveStatus.MountState.State -eq 'Error')
        LogsText = `$logsTextBeforeNavigation
        LogsPageEntryCount = `$logsPageEntryCount
        LogsAccountFilterValue = `$logsAccountFilterValue
    }
    [System.IO.File]::WriteAllText(`$env:NSCD_TEST_RESULT, (`$result | ConvertTo-Json -Compress))
    Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'probe-tick'
    `$script:IsExiting = `$true
    `$window.Close()
    `$app.Shutdown()
})
`$probe.Start()
Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'after-probe-start'
[void]`$window.Show()
Add-Content -LiteralPath `$env:NSCD_TEST_TRACE -Value 'after-window-show'
[void]`$app.Run(`$window)
"@
    $harness | Set-Content -LiteralPath $harnessPath -Encoding UTF8

    $env:LOCALAPPDATA = $testRoot
    $env:NSCD_TEST_ROOT = $testRoot
    $env:NSCD_TEST_RESULT = $resultPath
    $env:NSCD_TEST_TRACE = $tracePath
    $child = Start-Process -FilePath (Get-Command 'powershell.exe' -ErrorAction Stop).Source -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $harnessPath) -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (-not $child.WaitForExit(20000)) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        throw 'The isolated WPF startup probe exceeded its 20 second bound.'
    }
    $child.Refresh()
    $exitCode = $child.ExitCode
    if (($null -ne $exitCode -and $exitCode -ne 0) -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        $trace = if (Test-Path -LiteralPath $tracePath) { Get-Content -LiteralPath $tracePath -Raw } else { '' }
        $preserveTestRoot = $true
        throw "The isolated WPF startup probe failed (exit code $exitCode, hasExited=$($child.HasExited), id=$($child.Id)). stdout: $stdout stderr: $stderr trace: $trace. Probe files: $testRoot"
    }

    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    $trace = if (Test-Path -LiteralPath $tracePath) { Get-Content -LiteralPath $tracePath -Raw } else { '' }
    if ($trace -match 'dispatcher-error:') {
        throw "The dispatcher raised an unexpected UI exception: $trace"
    }
    if ($result.Pending -or $result.HasWorker -or $result.DispatchError -or $result.RestoreStage -ne 'Recovery checks complete' -or
        -not $result.CachedStatusHasMountState -or $null -ne $result.CachedStatusMountState -or
        -not $result.CachedStatusHasReadOnly -or $null -ne $result.CachedStatusReadOnly -or
        $result.UnmappedAccountIsMounted -or $result.UnmappedAccountProcessRunning -or
        $result.MismatchedAccountIsMounted -or $result.MismatchedAccountProcessRunning) {
        throw "Startup timer did not complete cleanly: $($result | ConvertTo-Json -Compress)"
    }
    if ($result.AccountCardCount -ne 3 -or
        ($result.AccountCardProviders -join '|') -ne 'Google Drive|Google Drive|TeraBox' -or
        ($result.AccountCardNames -join '|') -ne 'Naboraj Sarkar|Bidyutraj Sarkar|Synthetic TeraBox' -or
        ($result.AccountCardEmails -join '|') -ne 'naboraj-a@example.test|bidyutraj-b@example.test|terabox-user@example.test' -or
        ($result.AccountCardIcons -join '|') -ne 'googledrive.png|googledrive.png|terabox.png') {
        throw "Account cards merged identities or rendered provider metadata/icons incorrectly: $($result | ConvertTo-Json -Compress)"
    }
    if ($result.TeraBoxProgress -notmatch '^Validating TeraBox session \(0:25\)$' -or
        $result.GoogleProgress -notmatch '^Waiting for Google Drive restore \(0:25\)$') {
        throw "Startup restore labels do not isolate the active provider or preserve overall elapsed time: $($result | ConvertTo-Json -Compress)"
    }
    if ($result.LogsNavigationError -or -not $result.LogsLoadCompleted -or
        -not $result.LogsViewCollapsedAfterNavigation -or
        $result.LogsStatus -match 'failed|timed out' -or $result.LogsPageEntryCount -ne 2 -or
        $result.LogsAccountFilterValue -ne 'Synthetic account' -or
        $result.LogsText -notmatch 'synthetic searchable marker' -or
        $result.LogsText -match 'secondary synthetic entry') {
        throw "Logs navigation or bounded background loading did not complete cleanly: $($result | ConvertTo-Json -Compress)"
    }
    if (-not $result.PreservesAccountProcessAfterError -or -not $result.PreservesLegacyProcessAfterError) {
        throw "A live account or legacy mount was hidden after a transient health-check error: $($result | ConvertTo-Json -Compress)"
    }
    $waitStart = [regex]::Match([string]$result.DispatcherWaitStart, '\((\d+):(\d{2})\)$')
    $waitAfter = [regex]::Match([string]$result.DispatcherWaitAfter, '\((\d+):(\d{2})\)$')
    if (-not $waitStart.Success -or -not $waitAfter.Success) {
        throw "Startup dispatcher wait did not show elapsed time: $($result | ConvertTo-Json -Compress)"
    }
    $waitStartSeconds = ([int]$waitStart.Groups[1].Value * 60) + [int]$waitStart.Groups[2].Value
    $waitAfterSeconds = ([int]$waitAfter.Groups[1].Value * 60) + [int]$waitAfter.Groups[2].Value
    if ($waitAfterSeconds -le $waitStartSeconds) {
        throw "Startup dispatcher timer did not advance: $($result | ConvertTo-Json -Compress)"
    }
    Write-Output '  [PASS] Startup dispatcher wait timer advances before the worker starts.'
    Write-Output '  [PASS] Restore status is provider-specific and its elapsed time is monotonic across stages.'
    Write-Output '  [PASS] Startup dispatcher completes and publishes its final restore stage without a scope error.'
    Write-Output '  [PASS] Logs paging, account filtering, search, and navigation work in the isolated WPF dispatcher.'
    Write-Output '  [PASS] Cached account and legacy mounts remain visible after transient health-check errors.'
    Write-Output '  [PASS] The WPF account cards keep two Google identities and TeraBox separate with provider-matched icons.'
    Write-Output '  [PASS] A provider-wide legacy status is not attributed to an account without account-specific mount evidence.'
} finally {
    if ($child -and -not $child.HasExited) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    if ($null -eq $originalTestRoot) { Remove-Item Env:NSCD_TEST_ROOT -ErrorAction SilentlyContinue } else { $env:NSCD_TEST_ROOT = $originalTestRoot }
    if ($null -eq $originalResultPath) { Remove-Item Env:NSCD_TEST_RESULT -ErrorAction SilentlyContinue } else { $env:NSCD_TEST_RESULT = $originalResultPath }
    if ($null -eq $originalTracePath) { Remove-Item Env:NSCD_TEST_TRACE -ErrorAction SilentlyContinue } else { $env:NSCD_TEST_TRACE = $originalTracePath }
    if (-not $preserveTestRoot -and (Test-Path -LiteralPath $testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
