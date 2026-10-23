Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\services\BackgroundOperationManager.ps1')

Write-Output 'Testing BackgroundOperationManager...'

$worker = Start-NSBackgroundOperation -ScriptBlock {
    param([int]$DelayMilliseconds)
    Start-Sleep -Milliseconds $DelayMilliseconds
    'background-result'
} -ArgumentList 300

if (Test-NSBackgroundOperationCompleted $worker) {
    Stop-NSBackgroundOperation $worker
    throw 'A delayed worker must not complete synchronously.'
}

$waitClock = [System.Diagnostics.Stopwatch]::StartNew()
while (-not (Test-NSBackgroundOperationCompleted $worker) -and $waitClock.Elapsed.TotalSeconds -lt 5) {
    Start-Sleep -Milliseconds 25
}
$waitClock.Stop()
if (-not (Test-NSBackgroundOperationCompleted $worker)) {
    Stop-NSBackgroundOperation $worker
    throw 'The background worker did not complete within the test bound.'
}

$result = Complete-NSBackgroundOperation $worker
if ($result.HadErrors -or $result.Output.Count -ne 1 -or $result.Output[0] -ne 'background-result') {
    throw 'The completed background worker returned an unexpected result.'
}
Write-Output '  [PASS] Nonblocking execution and result collection verified'

$failedWorker = Start-NSBackgroundOperation -ScriptBlock { throw 'synthetic-worker-error' }
if (-not $failedWorker.Handle.AsyncWaitHandle.WaitOne(5000)) {
    Stop-NSBackgroundOperation $failedWorker
    throw 'The synthetic failing worker did not complete within the test bound.'
}
$failedResult = Complete-NSBackgroundOperation $failedWorker
if (-not $failedResult.HadErrors -or $failedResult.Errors.Count -eq 0) {
    throw 'Terminating worker errors must be returned to the caller.'
}
Write-Output '  [PASS] Terminating error capture verified'

$stoppableWorker = Start-NSBackgroundOperation -ScriptBlock {
    while ($true) { Start-Sleep -Milliseconds 50 }
}
Stop-NSBackgroundOperation $stoppableWorker
Write-Output '  [PASS] Worker cancellation verified'

Write-Output 'All BackgroundOperationManager tests passed.'
