Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = Join-Path $projectRoot 'src\NSCloudDrive.ps1'
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
    if ($result.Pending -or $result.DispatchError) {
        throw "Startup timer did not complete cleanly: $($result | ConvertTo-Json -Compress)"
    }
    Write-Output '  [PASS] Startup dispatcher timer clears pending state without a scope error.'
} finally {
    if ($child -and -not $child.HasExited) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
    }
    $env:LOCALAPPDATA = $originalLocalAppData
    if ($null -eq $originalTestRoot) { Remove-Item Env:NSCD_TEST_ROOT -ErrorAction SilentlyContinue } else { $env:NSCD_TEST_ROOT = $originalTestRoot }
    if ($null -eq $originalResultPath) { Remove-Item Env:NSCD_TEST_RESULT -ErrorAction SilentlyContinue } else { $env:NSCD_TEST_RESULT = $originalResultPath }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
