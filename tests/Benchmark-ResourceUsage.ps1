Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output '====================================================='
Write-Output 'NS Cloud Drive - Empirical Resource & Performance Benchmark'
Write-Output '====================================================='

# 1. System Environment
$os = (Get-CimInstance Win32_OperatingSystem).Caption
$osVer = (Get-CimInstance Win32_OperatingSystem).Version
$cpu = (Get-CimInstance Win32_Processor).Name
$totalRamGb = [Math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB, 2)

Write-Output "Environment: $os (Build $osVer)"
Write-Output "CPU:         $cpu"
Write-Output "Memory:      $totalRamGb GB Physical RAM"
Write-Output ''

# 2. Benchmark Cold Startup Time & Memory
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1')).Path
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$proc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList "-NoProfile -STA -Command `"& { . '$scriptPath'; [System.Threading.Thread]::Sleep(3000) }`"" `
    -PassThru

# Monitor process while warming up
[System.Threading.Thread]::Sleep(1500)
$sw.Stop()

$proc.Refresh()
$wsMb = [Math]::Round($proc.WorkingSet64 / 1MB, 2)
$pmMb = [Math]::Round($proc.PrivateMemorySize64 / 1MB, 2)

Write-Output "Cold Startup Time:    $($sw.ElapsedMilliseconds) ms"
Write-Output "WPF STA Working Set:  $wsMb MB"
Write-Output "Private Memory:       $pmMb MB"

# 3. CPU Sample
$cpuStart = $proc.TotalProcessorTime
$sampleSw = [System.Diagnostics.Stopwatch]::StartNew()
[System.Threading.Thread]::Sleep(1500)
$proc.Refresh()
$cpuEnd = $proc.TotalProcessorTime
$sampleSw.Stop()

$cpuUsedMs = ($cpuEnd - $cpuStart).TotalMilliseconds
$wallMs = $sampleSw.Elapsed.TotalMilliseconds
$cpuPercent = [Math]::Round(($cpuUsedMs / ($wallMs * [Environment]::ProcessorCount)) * 100, 2)

Write-Output "Idle CPU (Sampled):   $cpuPercent %"

# Cleanup benchmark process
try {
    $proc.Kill()
    $proc.WaitForExit(2000) | Out-Null
} catch { }

# 4. Cache Path & Disk Status
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
$cacheStats = Get-CacheUsageStatistics 'D:\CloudCache'
Write-Output ''
Write-Output "Cache Location:       $($cacheStats.CacheDirectory)"
Write-Output "Current Cache Size:   $($cacheStats.UsedFormatted)"
Write-Output "Configured Max Limit: $($cacheStats.TargetMaxFormatted)"
Write-Output "Host Volume Free:     $($cacheStats.VolumeFreeFormatted)"

Write-Output ''
Write-Output '====================================================='
Write-Output 'Benchmark Completed Successfully'
Write-Output '====================================================='
