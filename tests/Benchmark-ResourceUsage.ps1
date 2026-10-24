Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output '====================================================='
Write-Output 'NS Cloud Drive - Read-only Process Resource Snapshot'
Write-Output '====================================================='

$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-Output "Environment: $($os.Caption) (Build $($os.Version))"
Write-Output "CPU:         $($cpu.Name)"
Write-Output "Logical CPUs: $([Environment]::ProcessorCount)"
Write-Output ''

$appProcessIds = @(
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" |
        Where-Object { $_.CommandLine -match '(?i)NSCloudDrive\.ps1' } |
        ForEach-Object { [int]$_.ProcessId }
)
$targets = [System.Collections.Generic.List[object]]::new()
foreach ($processId in $appProcessIds) {
    $process = Get-Process -Id $processId -ErrorAction Stop
    $targets.Add([pscustomobject]@{ Role = 'NS Cloud Drive UI'; Process = $process })
}
foreach ($process in @(Get-Process -Name rclone, cpx -ErrorAction SilentlyContinue)) {
    $targets.Add([pscustomobject]@{ Role = 'Mount/provider'; Process = $process })
}

if ($appProcessIds.Count -eq 0) {
    Write-Output 'NS Cloud Drive UI: not running; app startup/idle memory cannot be measured.'
}
if ($targets.Count -eq 0) {
    Write-Output 'No NS Cloud Drive or mount/provider process was found.'
    exit 0
}

$before = @{}
foreach ($target in $targets) {
    $process = $target.Process
    $process.Refresh()
    $before[[int]$process.Id] = [pscustomobject]@{
        Cpu = $process.TotalProcessorTime
        SampledAt = [DateTime]::UtcNow
    }
}

$sampleSeconds = 3
Start-Sleep -Seconds $sampleSeconds
$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in $targets) {
    $process = $target.Process
    try {
        $process.Refresh()
        if ($process.HasExited) {
            $results.Add([pscustomobject]@{ Role = $target.Role; PID = $process.Id; Status = 'Exited during sample' })
            continue
        }
        $initial = $before[[int]$process.Id]
        $elapsedMs = ([DateTime]::UtcNow - $initial.SampledAt).TotalMilliseconds
        $cpuMs = ($process.TotalProcessorTime - $initial.Cpu).TotalMilliseconds
        $cpuPercent = if ($elapsedMs -gt 0) {
            [Math]::Round(($cpuMs / ($elapsedMs * [Environment]::ProcessorCount)) * 100, 3)
        } else { 0 }
        $results.Add([pscustomobject]@{
            Role = $target.Role
            PID = $process.Id
            Process = $process.ProcessName
            WorkingSetMiB = [Math]::Round($process.WorkingSet64 / 1MB, 2)
            PrivateMiB = [Math]::Round($process.PrivateMemorySize64 / 1MB, 2)
            CPUPercent = $cpuPercent
            CpuSecondsTotal = [Math]::Round($process.TotalProcessorTime.TotalSeconds, 2)
            Handles = $process.HandleCount
            Threads = $process.Threads.Count
            Status = 'Sampled'
        })
    } catch [System.InvalidOperationException] {
        $results.Add([pscustomobject]@{ Role = $target.Role; PID = $process.Id; Status = 'Exited during sample' })
    }
}

$results | Format-Table -AutoSize
Write-Output ''
Write-Output "CPU sample duration: approximately $sampleSeconds seconds."
Write-Output 'This script did not launch, stop, or modify any process and did not scan cache files.'
Write-Output 'Startup time requires a separately instrumented clean launch; it is not estimated here.'
