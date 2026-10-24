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
        Accounts = @()
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
`$script:ProviderStatusSnapshot = [pscustomobject]@{ GoogleStatus = `$incompleteStatus }
`$cachedStatus = Get-CachedUiDriveStatus -ProviderId 'gdrive'
if (-not `$cachedStatus.Contains('MountState') -or `$null -ne `$cachedStatus['MountState'] -or
    -not `$cachedStatus.Contains('IsReadOnly') -or `$cachedStatus['IsReadOnly']) {
    throw 'An incomplete provider status was not normalized with safe MountState and IsReadOnly defaults.'
}
Update-AllUIState
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
`$probe = [System.Windows.Threading.DispatcherTimer]::new()
`$probe.Interval = [TimeSpan]::FromSeconds(3)
`$probe.Add_Tick({
    `$probe.Stop()
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
        -not $result.CachedStatusHasReadOnly -or $result.CachedStatusReadOnly) {
        throw "Startup timer did not complete cleanly: $($result | ConvertTo-Json -Compress)"
    }
    if ($result.TeraBoxProgress -notmatch '^Validating TeraBox session \(0:25\)$' -or
        $result.GoogleProgress -notmatch '^Waiting for Google Drive restore \(0:25\)$') {
        throw "Startup restore labels do not isolate the active provider or preserve overall elapsed time: $($result | ConvertTo-Json -Compress)"
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
