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
$originalLocalAppData = $env:LOCALAPPDATA
$originalTestRoot = $env:NSCD_TEST_ROOT
$originalResultPath = $env:NSCD_TEST_RESULT
$child = $null

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
. $quotedMainScript
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
`$window.ShowInTaskbar = `$false
`$window.WindowState = [System.Windows.WindowState]::Minimized
`$probe = [System.Windows.Threading.DispatcherTimer]::new()
`$probe.Interval = [TimeSpan]::FromSeconds(3)
`$probe.Add_Tick({
    `$probe.Stop()
    `$result = [ordered]@{
        Pending = [bool]`$script:StartupAutoMountPending
        HasWorker = (`$null -ne `$script:StartupAutoMountWorker)
        DispatchError = `$script:StartupAutoMountError
        RestoreStage = [string]`$script:StartupAutoMountProgress.Stage
        TeraBoxProgress = `$tbProgressLabel
        GoogleProgress = `$gdProgressLabel
    }
    [System.IO.File]::WriteAllText(`$env:NSCD_TEST_RESULT, (`$result | ConvertTo-Json -Compress))
    `$script:IsExiting = `$true
    `$window.Close()
    `$app.Shutdown()
})
`$probe.Start()
[void]`$window.Show()
[void]`$app.Run(`$window)
"@
    $harness | Set-Content -LiteralPath $harnessPath -Encoding UTF8

    $env:LOCALAPPDATA = $testRoot
    $env:NSCD_TEST_ROOT = $testRoot
    $env:NSCD_TEST_RESULT = $resultPath
    $child = Start-Process -FilePath (Get-Command 'powershell.exe' -ErrorAction Stop).Source -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $harnessPath) -PassThru -WindowStyle Hidden
    if (-not $child.WaitForExit(20000)) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        throw 'The isolated WPF startup probe exceeded its 20 second bound.'
    }
    if ($child.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "The isolated WPF startup probe failed (exit code $($child.ExitCode))."
    }

    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($result.Pending -or $result.DispatchError -or $result.RestoreStage -ne 'Recovery checks complete') {
        throw "Startup timer did not complete cleanly: $($result | ConvertTo-Json -Compress)"
    }
    if ($result.TeraBoxProgress -notmatch '^Validating TeraBox session \(0:07\)$' -or
        $result.GoogleProgress -notmatch '^Waiting for Google Drive restore \(0:25\)$') {
        throw "Startup restore labels do not isolate the active provider or stage timer: $($result | ConvertTo-Json -Compress)"
    }
    Write-Output '  [PASS] Restore status is provider-specific and its elapsed time is stage-scoped.'
    Write-Output '  [PASS] Startup dispatcher completes and publishes its final restore stage without a scope error.'
} finally {
    if ($child -and -not $child.HasExited) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    if ($null -eq $originalTestRoot) { Remove-Item Env:NSCD_TEST_ROOT -ErrorAction SilentlyContinue } else { $env:NSCD_TEST_ROOT = $originalTestRoot }
    if ($null -eq $originalResultPath) { Remove-Item Env:NSCD_TEST_RESULT -ErrorAction SilentlyContinue } else { $env:NSCD_TEST_RESULT = $originalResultPath }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
