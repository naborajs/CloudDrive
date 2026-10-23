Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue

# Win32 Process Suspend and Resume for pause/resume transfer support
$ntdllDef = @"
using System;
using System.Runtime.InteropServices;
public static class Win32ProcessControl {
    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtSuspendProcess(IntPtr processHandle);

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtResumeProcess(IntPtr processHandle);
}
"@
Add-Type -TypeDefinition $ntdllDef -ErrorAction SilentlyContinue

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')
. (Join-Path $PSScriptRoot '..\providers\GoogleDriveProvider.ps1')
. (Join-Path $PSScriptRoot 'TeraBoxBridgeManager.ps1')
. (Join-Path $PSScriptRoot 'VirtualDriveManager.ps1')

$script:ActiveTransferJobs = @{}

# ==============================================================================
# SPEED & ETA CALCULATION ENGINE
# ==============================================================================

function Calculate-SmoothedSpeedAndEta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int64]$BytesTransferred,

        [Parameter(Mandatory = $true)]
        [int64]$TotalBytes,

        [Parameter(Mandatory = $true)]
        [double]$InstantSpeedBytesPerSec,

        [double]$PreviousSmoothedSpeed = 0,

        [double]$SmoothingFactor = 0.25,

        [double]$ElapsedSeconds = 0
    )

    # 1. Exponential Moving Average for transfer speed to eliminate wild fluctuations
    $smoothedSpeed = if ($PreviousSmoothedSpeed -gt 0) {
        ($SmoothingFactor * $InstantSpeedBytesPerSec) + ((1.0 - $SmoothingFactor) * $PreviousSmoothedSpeed)
    } else {
        $InstantSpeedBytesPerSec
    }

    # 2. Average speed over the entire elapsed duration
    $averageSpeed = if ($ElapsedSeconds -gt 0.5) {
        $BytesTransferred / $ElapsedSeconds
    } else {
        $smoothedSpeed
    }

    # 3. ETA Calculation with division-by-zero protection and unknown-size handling
    $etaSeconds = $null
    $percentage = -1.0

    if ($TotalBytes -gt 0) {
        $pct = [Math]::Round(($BytesTransferred / $TotalBytes) * 100, 1)
        $percentage = [Math]::Min(100.0, [Math]::Max(0.0, $pct))

        $remainingBytes = [Math]::Max(0L, ($TotalBytes - $BytesTransferred))
        if ($remainingBytes -eq 0L) {
            $etaSeconds = 0
        } elseif ($smoothedSpeed -ge 256.0) {
            $eta = [Math]::Round($remainingBytes / $smoothedSpeed)
            # Bound ETA to reasonable range (max 30 days) to prevent integer overflow or absurd display
            $etaSeconds = [Math]::Min(2592000, [int]$eta)
        }
    }

    return [ordered]@{
        BytesTransferred = $BytesTransferred
        TotalBytes = $TotalBytes
        Percentage = $percentage
        InstantSpeedBytesPerSec = [Math]::Round($InstantSpeedBytesPerSec, 1)
        SmoothedSpeedBytesPerSec = [Math]::Round($smoothedSpeed, 1)
        AverageSpeedBytesPerSec = [Math]::Round($averageSpeed, 1)
        EtaSeconds = $etaSeconds
        ElapsedSeconds = [Math]::Round($ElapsedSeconds, 1)
    }
}

function Format-TransferSpeed([double]$BytesPerSec) {
    if ($BytesPerSec -ge 1GB) {
        return "$([Math]::Round($BytesPerSec / 1GB, 2)) GB/s"
    } elseif ($BytesPerSec -ge 1MB) {
        return "$([Math]::Round($BytesPerSec / 1MB, 2)) MB/s"
    } elseif ($BytesPerSec -ge 1KB) {
        return "$([Math]::Round($BytesPerSec / 1KB, 1)) KB/s"
    } elseif ($BytesPerSec -gt 0) {
        return "$([Math]::Round($BytesPerSec, 0)) B/s"
    } else {
        return "0 B/s"
    }
}

function Format-EtaTimeSpan([Nullable[int]]$Seconds) {
    if ($null -eq $Seconds) {
        return "Calculating..."
    }
    if ($Seconds -le 0) {
        return "0s"
    }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalHours -ge 1) {
        return "$([int]$ts.TotalHours)h $($ts.Minutes)m"
    } elseif ($ts.Minutes -ge 1) {
        return "$($ts.Minutes)m $($ts.Seconds)s"
    } else {
        return "$($ts.Seconds)s"
    }
}

# ==============================================================================
# PROVIDER TRANSFER ENVIRONMENT GENERATION
# ==============================================================================

function Get-CloudAccountTransferRemoteEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Account,

        [Parameter(Mandatory = $true)]
        [string]$RemoteAlias
    )

    $rclonePath = Find-RcloneBinary
    if (-not $rclonePath -or -not (Test-Path -LiteralPath $rclonePath -PathType Leaf)) {
        throw "rclone binary not found. Cannot configure cloud transfer remote."
    }

    $providerId = if ($Account.ContainsKey('ProviderId')) { $Account.ProviderId } else { 'gdrive' }
    $accountId = if ($Account.ContainsKey('Id')) { $Account.Id } else { '' }

    if ($providerId -eq 'gdrive') {
        $gEnv = Get-GoogleDriveRcloneEnvironment -AccountId $accountId -RemoteName $RemoteAlias
        return $gEnv
    } elseif ($providerId -eq 'terabox') {
        $bridgeStatus = Start-TeraBoxBridge
        if (-not $bridgeStatus.Success) {
            throw "Failed to start TeraBox loopback WebDAV bridge for transfer: $($bridgeStatus.Error)"
        }
        $tbEnv = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword $bridgeStatus.Password -Port $bridgeStatus.Port -RcloneBinary $rclonePath -RemoteName $RemoteAlias
        return $tbEnv
    } else {
        throw "Unsupported provider for cloud transfer: $providerId"
    }
}

# ==============================================================================
# CLOUD FILE AND DIRECTORY LISTING
# ==============================================================================

function Get-CloudDirectoryContents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Account,

        [string]$Path = ''
    )

    $rclonePath = Find-RcloneBinary
    if (-not $rclonePath -or -not (Test-Path -LiteralPath $rclonePath -PathType Leaf)) {
        throw "rclone binary not found."
    }

    $tempRemote = "browse_" + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $envVars = Get-CloudAccountTransferRemoteEnvironment -Account $Account -RemoteAlias $tempRemote

    $cleanPath = $Path.TrimStart('/').TrimEnd('/')
    $targetSpec = if ($cleanPath) { "${tempRemote}:${cleanPath}" } else { "${tempRemote}:" }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclonePath
    $psi.Arguments = "lsjson `"$targetSpec`" --max-depth 1"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($k in $envVars.Keys) {
        $psi.EnvironmentVariables[$k] = $envVars[$k]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit(15000) | Out-Null

    if ($proc.ExitCode -ne 0) {
        $sanitizedErr = Format-SanitizedDiagnosticMessage $stderr
        throw "Failed to list cloud directory '$cleanPath': $sanitizedErr"
    }

    $items = @()
    if ($stdout) {
        try {
            $parsed = $stdout | ConvertFrom-Json
            if ($parsed) {
                foreach ($item in $parsed) {
                    $items += [ordered]@{
                        Name = $item.Name
                        Path = $item.Path
                        IsDir = [bool]$item.IsDir
                        Size = if ($item.Size -ge 0) { [int64]$item.Size } else { 0L }
                        MimeType = if ($item.PSObject.Properties['MimeType']) { $item.MimeType } else { '' }
                        ModTime = if ($item.PSObject.Properties['ModTime']) { $item.ModTime } else { '' }
                    }
                }
            }
        } catch { }
    }

    return $items
}

# ==============================================================================
# START CLOUD-TO-CLOUD TRANSFER
# ==============================================================================

function Start-CloudTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$SourceAccount,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [hashtable]$DestinationAccount,

        [Parameter(Mandatory = $false)]
        [string]$DestinationPath = '',

        [ValidateSet('Overwrite', 'Skip', 'Rename')]
        [string]$ConflictAction = 'Skip',

        [switch]$IsMove,

        [string]$BandwidthLimit = ''
    )

    $rclonePath = Find-RcloneBinary
    if (-not $rclonePath -or -not (Test-Path -LiteralPath $rclonePath -PathType Leaf)) {
        throw "rclone binary not found. Cannot start transfer."
    }

    $jobId = "transfer_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $srcRemote = "src_" + $jobId
    $dstRemote = "dst_" + $jobId

    $srcEnv = Get-CloudAccountTransferRemoteEnvironment -Account $SourceAccount -RemoteAlias $srcRemote
    $dstEnv = Get-CloudAccountTransferRemoteEnvironment -Account $DestinationAccount -RemoteAlias $dstRemote

    $cleanSrcPath = $SourcePath.TrimStart('/').TrimEnd('/')
    $cleanDstPath = $DestinationPath.TrimStart('/').TrimEnd('/')

    $srcSpec = if ($cleanSrcPath) { "${srcRemote}:${cleanSrcPath}" } else { "${srcRemote}:" }
    $dstSpec = if ($cleanDstPath) { "${dstRemote}:${cleanDstPath}" } else { "${dstRemote}:" }

    # Build rclone streaming arguments
    # Important: Uses rclone copy/move streaming relay. No large file writes to local OS drive.
    $commandVerb = if ($IsMove) { 'move' } else { 'copy' }
    $argsList = @(
        $commandVerb,
        $srcSpec,
        $dstSpec,
        '--stats', '500ms',
        '--use-json-log',
        '-v',
        '--retries', '3',
        '--low-level-retries', '5'
    )

    if ($ConflictAction -eq 'Skip') {
        $argsList += '--ignore-existing'
    }

    if ($BandwidthLimit) {
        $argsList += '--bwlimit'
        $argsList += $BandwidthLimit
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclonePath
    $psi.Arguments = ($argsList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # Merge environment variables for both remotes
    foreach ($k in $srcEnv.Keys) { $psi.EnvironmentVariables[$k] = $srcEnv[$k] }
    foreach ($k in $dstEnv.Keys) { $psi.EnvironmentVariables[$k] = $dstEnv[$k] }

    $logBuffer = [System.Collections.Generic.List[string]]::new()
    $errorBuffer = [System.Collections.Generic.List[string]]::new()

    $jobRecord = [ordered]@{
        JobId = $jobId
        Process = $null
        StartTime = [DateTime]::UtcNow
        EndTime = $null
        SourceAccount = $SourceAccount
        DestinationAccount = $DestinationAccount
        SourcePath = $SourcePath
        DestinationPath = $DestinationPath
        IsMove = [bool]$IsMove
        ConflictAction = $ConflictAction
        Status = 'Running'
        IsPaused = $false
        BytesTransferred = 0L
        TotalBytes = 0L
        SmoothedSpeed = 0.0
        AverageSpeed = 0.0
        EtaSeconds = $null
        Percentage = 0.0
        LastError = ''
        RecentLogs = $logBuffer
        RecentErrors = $errorBuffer
        Mode = 'Streaming Relay'
        IsServerSide = $false
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true

    # Asynchronous line reading from stderr where rclone writes its JSON log & progress
    $jobRecordRef = $jobRecord
    $onDataReceived = {
        param($sender, $eventArgs)
        if ($eventArgs.Data) {
            $line = $eventArgs.Data
            try {
                $parsed = $line | ConvertFrom-Json
                if ($parsed -and $parsed.PSObject.Properties['stats'] -and $parsed.stats) {
                    $st = $parsed.stats
                    $bTrans = if ($st.PSObject.Properties['bytes']) { [int64]$st.bytes } else { 0L }
                    $tBytes = if ($st.PSObject.Properties['totalBytes']) { [int64]$st.totalBytes } else { 0L }
                    $spd = if ($st.PSObject.Properties['speed']) { [double]$st.speed } else { 0.0 }
                    $elap = if ($st.PSObject.Properties['elapsedTime']) { [double]$st.elapsedTime } else { 0.0 }

                    $calc = Calculate-SmoothedSpeedAndEta -BytesTransferred $bTrans -TotalBytes $tBytes -InstantSpeedBytesPerSec $spd -PreviousSmoothedSpeed $jobRecordRef.SmoothedSpeed -ElapsedSeconds $elap

                    $jobRecordRef.BytesTransferred = $calc.BytesTransferred
                    $jobRecordRef.TotalBytes = $calc.TotalBytes
                    $jobRecordRef.Percentage = $calc.Percentage
                    $jobRecordRef.SmoothedSpeed = $calc.SmoothedSpeedBytesPerSec
                    $jobRecordRef.AverageSpeed = $calc.AverageSpeedBytesPerSec
                    $jobRecordRef.EtaSeconds = $calc.EtaSeconds

                    if ($st.PSObject.Properties['errors'] -and [int]$st.errors -gt 0) {
                        $jobRecordRef.LastError = "Errors recorded during transfer: $($st.errors)"
                    }
                } elseif ($parsed -and $parsed.PSObject.Properties['msg'] -and $parsed.msg) {
                    $sanitizedMsg = Format-SanitizedDiagnosticMessage $parsed.msg
                    if ($parsed.level -eq 'error') {
                        $jobRecordRef.LastError = $sanitizedMsg
                        $jobRecordRef.RecentErrors.Add($sanitizedMsg)
                    } else {
                        $jobRecordRef.RecentLogs.Add($sanitizedMsg)
                    }
                }
            } catch {
                # Fallback for plain text log lines
                $clean = Format-SanitizedDiagnosticMessage $line
                $jobRecordRef.RecentLogs.Add($clean)
            }
        }
    }

    $proc.Add_ErrorDataReceived($onDataReceived)
    $proc.Add_OutputDataReceived($onDataReceived)

    $proc.Start() | Out-Null
    $proc.BeginErrorReadLine()
    $proc.BeginOutputReadLine()

    $jobRecord.Process = $proc
    $script:ActiveTransferJobs[$jobId] = $jobRecord

    return $jobRecord
}

# ==============================================================================
# TRANSFER STATUS, SUSPEND, RESUME, AND CANCELLATION
# ==============================================================================

function Get-CloudTransferStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    if (-not $script:ActiveTransferJobs.ContainsKey($JobId)) {
        return $null
    }

    $job = $script:ActiveTransferJobs[$JobId]
    $proc = $job.Process

    if ($proc) {
        if ($proc.HasExited) {
            $job.EndTime = [DateTime]::UtcNow
            if ($proc.ExitCode -eq 0) {
                $job.Status = 'Completed'
                $job.Percentage = 100.0
                $job.EtaSeconds = 0
            } else {
                if ($job.Status -ne 'Cancelled') {
                    $job.Status = 'Failed'
                    if (-not $job.LastError) {
                        $job.LastError = "Process exited with code $($proc.ExitCode)"
                    }
                }
            }
        }
    }

    $speedFmt = Format-TransferSpeed $job.SmoothedSpeed
    $etaFmt = Format-EtaTimeSpan $job.EtaSeconds

    return [ordered]@{
        JobId = $job.JobId
        Status = $job.Status
        IsPaused = $job.IsPaused
        Mode = $job.Mode
        IsServerSide = $job.IsServerSide
        SourceAccount = $job.SourceAccount.DisplayName
        DestinationAccount = $job.DestinationAccount.DisplayName
        SourcePath = $job.SourcePath
        DestinationPath = $job.DestinationPath
        BytesTransferred = $job.BytesTransferred
        TotalBytes = $job.TotalBytes
        Percentage = $job.Percentage
        SpeedFormatted = $speedFmt
        EtaFormatted = $etaFmt
        SmoothedSpeed = $job.SmoothedSpeed
        AverageSpeed = $job.AverageSpeed
        EtaSeconds = $job.EtaSeconds
        StartTime = $job.StartTime
        EndTime = $job.EndTime
        LastError = $job.LastError
        RecentLogs = @($job.RecentLogs)
        RecentErrors = @($job.RecentErrors)
    }
}

function Suspend-CloudTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    if (-not $script:ActiveTransferJobs.ContainsKey($JobId)) {
        return $false
    }

    $job = $script:ActiveTransferJobs[$JobId]
    if ($job.Process -and -not $job.Process.HasExited) {
        try {
            [Win32ProcessControl]::NtSuspendProcess($job.Process.Handle) | Out-Null
            $job.IsPaused = $true
            $job.Status = 'Paused'
            return $true
        } catch { }
    }
    return $false
}

function Resume-CloudTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    if (-not $script:ActiveTransferJobs.ContainsKey($JobId)) {
        return $false
    }

    $job = $script:ActiveTransferJobs[$JobId]
    if ($job.Process -and -not $job.Process.HasExited) {
        try {
            [Win32ProcessControl]::NtResumeProcess($job.Process.Handle) | Out-Null
            $job.IsPaused = $false
            $job.Status = 'Running'
            return $true
        } catch { }
    }
    return $false
}

function Stop-CloudTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )

    if (-not $script:ActiveTransferJobs.ContainsKey($JobId)) {
        return $false
    }

    $job = $script:ActiveTransferJobs[$JobId]
    $job.Status = 'Cancelled'
    $job.EndTime = [DateTime]::UtcNow

    if ($job.Process -and -not $job.Process.HasExited) {
        try {
            # Resume first if suspended so kill signal terminates it cleanly
            if ($job.IsPaused) {
                try { [Win32ProcessControl]::NtResumeProcess($job.Process.Handle) | Out-Null } catch { }
            }
            $job.Process.Kill()
            $job.Process.WaitForExit(3000) | Out-Null
        } catch { }
    }
    return $true
}
