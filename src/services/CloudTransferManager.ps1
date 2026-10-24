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
# COMMAND LINE & PATH SANITIZATION
# ==============================================================================

function Format-SafeProcessArgument([string]$Argument) {
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument -notmatch '[\s"\\]') { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\+)(")', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    $escaped = $escaped -replace '"', '\"'
    return "`"$escaped`""
}

function Normalize-CloudPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $clean = $Path.Replace('\', '/').Trim()
    $clean = [regex]::Replace($clean, '[\x00-\x1F\x7F]', '')
    $segments = $clean.Split('/') | Where-Object { $_ -ne '' -and $_ -ne '.' }
    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($seg in $segments) {
        if ($seg -eq '..') {
            if ($resolved.Count -gt 0) {
                $resolved.RemoveAt($resolved.Count - 1)
            }
        } else {
            $resolved.Add($seg)
        }
    }
    return ($resolved -join '/')
}

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

function Format-TransferThroughput([double]$BytesPerSec, [bool]$IsLoopbackStaging = $false) {
    if ($BytesPerSec -le 0) {
        return "0 B/s (0.0 Mbps)"
    }
    $mbps = [Math]::Round(($BytesPerSec * 8) / 1000000.0, 1)
    $speedStr = Format-TransferSpeed $BytesPerSec
    if ($IsLoopbackStaging) {
        return "Staging to local bridge: $speedStr ($mbps Mbps) • Cloud upload pending"
    }
    return "$speedStr ($mbps Mbps)"
}

function Test-ProviderUploadPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Account,

        [Parameter(Mandatory = $true)]
        [int64]$FileSizeBytes,

        [string]$FileName = ''
    )

    $providerId = if ($Account.ContainsKey('ProviderId')) { [string]$Account.ProviderId } else { 'gdrive' }
    $accountId = if ($Account.ContainsKey('Id')) { [string]$Account.Id } else { '' }
    $cleanFileName = if ($FileName) { $FileName } else { 'Selected file' }

    if ($providerId -eq 'terabox') {
        # Check TeraBox plan limits via CPX status endpoint
        $bridgeStatus = $null
        try {
            $bridgeStatus = Get-TeraBoxBridgeStatus -AccountId $accountId
        } catch { }

        $plan = if ($bridgeStatus -and $bridgeStatus.Plan) { $bridgeStatus.Plan } else { 'Free' }
        $isPremium = if ($bridgeStatus) { [bool]$bridgeStatus.IsPremium } else { $false }
        $maxFileLimit = if ($bridgeStatus -and $bridgeStatus.MaxFileSizeBytes -gt 0) {
            [int64]$bridgeStatus.MaxFileSizeBytes
        } elseif ($isPremium) {
            128L * 1000 * 1000 * 1000 # 128 GB
        } else {
            4L * 1000 * 1000 * 1000   # 4 GB
        }

        if ($FileSizeBytes -gt $maxFileLimit) {
            $fileGb = [Math]::Round($FileSizeBytes / 1GB, 2)
            $limitGb = if ($maxFileLimit -eq 4000000000L) { '4.0 GB' } elseif ($maxFileLimit -eq 128000000000L) { '128 GB' } else { "$([Math]::Round($maxFileLimit / 1GB, 1)) GB" }
            return [ordered]@{
                Allowed = $false
                Reason = "File '$cleanFileName' ($fileGb GB) exceeds your TeraBox $plan plan limit of $limitGb per file. Upload cancelled to prevent data loss."
                ErrorCode = 'PlanFileLimit'
                LimitBytes = $maxFileLimit
                ProviderId = $providerId
                Plan = $plan
            }
        }

        # Check quota if known
        if ($bridgeStatus -and $bridgeStatus.QuotaTotal -gt 0L) {
            $freeQuota = [Math]::Max(0L, ($bridgeStatus.QuotaTotal - $bridgeStatus.QuotaUsed))
            if ($FileSizeBytes -gt $freeQuota) {
                $reqGb = [Math]::Round($FileSizeBytes / 1GB, 2)
                $availGb = [Math]::Round($freeQuota / 1GB, 2)
                return [ordered]@{
                    Allowed = $false
                    Reason = "Insufficient TeraBox cloud storage quota. Required: $reqGb GB, Available: $availGb GB."
                    ErrorCode = 'QuotaExceeded'
                    LimitBytes = $freeQuota
                    ProviderId = $providerId
                    Plan = $plan
                }
            }
        }

        return [ordered]@{
            Allowed = $true
            Reason = ''
            ErrorCode = ''
            LimitBytes = $maxFileLimit
            ProviderId = $providerId
            Plan = $plan
        }
    } elseif ($providerId -eq 'gdrive') {
        # Google Drive single file max size is 5 TB
        $gdriveMaxFileLimit = 5497558138880L # 5 TB
        if ($FileSizeBytes -gt $gdriveMaxFileLimit) {
            return [ordered]@{
                Allowed = $false
                Reason = "File '$cleanFileName' exceeds Google Drive's 5 TB single file limit."
                ErrorCode = 'PlanFileLimit'
                LimitBytes = $gdriveMaxFileLimit
                ProviderId = $providerId
                Plan = 'Standard'
            }
        }

        return [ordered]@{
            Allowed = $true
            Reason = ''
            ErrorCode = ''
            LimitBytes = $gdriveMaxFileLimit
            ProviderId = $providerId
            Plan = 'Standard'
        }
    } else {
        return [ordered]@{
            Allowed = $true
            Reason = ''
            ErrorCode = ''
            LimitBytes = 0L
            ProviderId = $providerId
            Plan = 'Standard'
        }
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
        # Dictionary-style access: the bridge status is an ordered dictionary
        # and carries no 'Error' key on the success path, so StrictMode
        # property access of a missing key would throw and mask the real
        # bridge failure instead of reporting it.
        $bridgeStatus = Start-TeraBoxBridge
        if (-not ($bridgeStatus -is [System.Collections.IDictionary] -and $bridgeStatus['Success'])) {
            throw "Failed to start TeraBox loopback WebDAV bridge for transfer: $(if ($bridgeStatus -is [System.Collections.IDictionary]) { [string]$bridgeStatus['Error'] } else { 'unexpected bridge status' })"
        }
        $tbEnv = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword $bridgeStatus['Password'] -Port $bridgeStatus['Port'] -RcloneBinary $rclonePath -RemoteName $RemoteAlias
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

        [string]$Path = '',

        [switch]$BypassLocalMount = $false
    )

    $providerId = if ($Account.ContainsKey('ProviderId')) { $Account.ProviderId } else { 'gdrive' }
    $accountId = if ($Account.ContainsKey('Id')) { $Account.Id } else { '' }

    # Fast-path: If the drive is already mounted locally in Windows Explorer and bypass was not requested
    if (-not $BypassLocalMount) {
        try {
            $mountStatus = Get-VirtualDriveStatus -AccountId $accountId -ProviderId $providerId
            if ($mountStatus -and $mountStatus.IsMounted -and (Test-Path -LiteralPath $mountStatus.DriveRoot)) {
                $cleanPath = Normalize-CloudPath -Path $Path
                $localDir = if ($cleanPath) { Join-Path $mountStatus.DriveRoot ($cleanPath.Replace('/', '\')) } else { $mountStatus.DriveRoot }
                if (Test-Path -LiteralPath $localDir) {
                    $items = @()
                    $children = Get-ChildItem -LiteralPath $localDir -ErrorAction SilentlyContinue
                    foreach ($child in $children) {
                        $isDir = $child.PSIsContainer
                        $relPath = if ($cleanPath) { "$cleanPath/$($child.Name)" } else { $child.Name }
                        $items += [ordered]@{
                            Name = $child.Name
                            Path = $relPath
                            IsDir = [bool]$isDir
                            Size = if ($isDir) { 0L } else { [int64]$child.Length }
                            MimeType = ''
                            ModTime = $child.LastWriteTime.ToString('o')
                        }
                    }
                    return $items
                }
            }
        } catch { }
    }

    $rclonePath = Find-RcloneBinary
    if (-not $rclonePath -or -not (Test-Path -LiteralPath $rclonePath -PathType Leaf)) {
        throw "rclone binary not found."
    }

    $tempRemote = "browse_" + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $envVars = Get-CloudAccountTransferRemoteEnvironment -Account $Account -RemoteAlias $tempRemote

    $cleanPath = Normalize-CloudPath -Path $Path
    $targetSpec = if ($cleanPath) { "${tempRemote}:${cleanPath}" } else { "${tempRemote}:" }
    $safeTargetArg = Format-SafeProcessArgument $targetSpec

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclonePath
    $psi.Arguments = "lsjson $safeTargetArg --max-depth 1"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($k in $envVars.Keys) {
        $psi.EnvironmentVariables[$k] = $envVars[$k]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.WaitForExit(100)) {
        if ($sw.ElapsedMilliseconds -gt 15000) {
            try { $proc.Kill() } catch { }
            throw "Timed out waiting for directory listing of '$cleanPath'."
        }
        try {
            if ([System.Windows.Application]::Current) {
                [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            }
        } catch { }
    }
    $proc.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

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
# REMOTE CLOUD FILE VERIFICATION
# ==============================================================================

function Test-RemoteCloudFileVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Account,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [int64]$ExpectedSizeBytes = -1L
    )

    $cleanPath = Normalize-CloudPath -Path $RemotePath
    $parentPath = ''
    $fileName = $cleanPath
    if ($cleanPath.Contains('/')) {
        $idx = $cleanPath.LastIndexOf('/')
        $parentPath = $cleanPath.Substring(0, $idx)
        $fileName = $cleanPath.Substring($idx + 1)
    }

    try {
        $items = Get-CloudDirectoryContents -Account $Account -Path $parentPath -BypassLocalMount
        $found = $null
        foreach ($item in $items) {
            if ($item.Name -eq $fileName) {
                $found = $item
                break
            }
        }

        if (-not $found) {
            return [ordered]@{
                Verified = $false
                Status = 'Failed'
                Reason = "File '$fileName' not found on remote cloud provider after upload completed."
                RemoteSizeBytes = 0L
                ExpectedSizeBytes = $ExpectedSizeBytes
            }
        }

        if ($ExpectedSizeBytes -ge 0L -and $found.Size -ne $ExpectedSizeBytes) {
            return [ordered]@{
                Verified = $false
                Status = 'Failed'
                Reason = "Remote file size mismatch for '$fileName': remote has $($found.Size) bytes, expected $ExpectedSizeBytes bytes."
                RemoteSizeBytes = $found.Size
                ExpectedSizeBytes = $ExpectedSizeBytes
            }
        }

        return [ordered]@{
            Verified = $true
            Status = 'Remotely confirmed'
            Reason = ''
            RemoteSizeBytes = $found.Size
            ExpectedSizeBytes = $ExpectedSizeBytes
        }
    } catch {
        return [ordered]@{
            Verified = $false
            Status = 'Remote state unknown'
            Reason = "Could not verify remote file '$fileName': $($_.Exception.Message)"
            RemoteSizeBytes = 0L
            ExpectedSizeBytes = $ExpectedSizeBytes
        }
    }
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

    $cleanSrcPath = Normalize-CloudPath -Path $SourcePath
    $cleanDstPath = Normalize-CloudPath -Path $DestinationPath

    # Pre-flight check on destination account plan and file size limits
    if ($DestinationAccount) {
        $srcSize = 0L
        try {
            $srcItems = Get-CloudDirectoryContents -Account $SourceAccount -Path $cleanSrcPath
            if ($srcItems -and $srcItems.Count -eq 1 -and (-not $srcItems[0].IsDir)) {
                $srcSize = [int64]$srcItems[0].Size
            }
        } catch { }

        if ($srcSize -gt 0L) {
            $fName = if ($cleanSrcPath.Contains('/')) { $cleanSrcPath.Substring($cleanSrcPath.LastIndexOf('/') + 1) } else { $cleanSrcPath }
            $preflight = Test-ProviderUploadPreflight -Account $DestinationAccount -FileSizeBytes $srcSize -FileName $fName
            if (-not $preflight.Allowed) {
                throw $preflight.Reason
            }
        }
    }

    $srcSpec = if ($cleanSrcPath) { "${srcRemote}:${cleanSrcPath}" } else { "${srcRemote}:" }
    $dstSpec = if ($cleanDstPath) { "${dstRemote}:${cleanDstPath}" } else { "${dstRemote}:" }

    # Build rclone streaming arguments
    # Important: Uses rclone copy/move streaming relay. No large file writes to local OS drive.
    $commandVerb = if ($IsMove) { 'move' } else { 'copy' }
    $rawArgs = @(
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
        $rawArgs += '--ignore-existing'
    }

    if ($BandwidthLimit) {
        $rawArgs += '--bwlimit'
        $rawArgs += [regex]::Replace($BandwidthLimit, '[^0-9a-zA-Z]', '')
    }

    $escapedArgs = ($rawArgs | ForEach-Object { Format-SafeProcessArgument $_ }) -join ' '

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclonePath
    $psi.Arguments = $escapedArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # Merge environment variables for both remotes
    foreach ($k in $srcEnv.Keys) { $psi.EnvironmentVariables[$k] = $srcEnv[$k] }
    foreach ($k in $dstEnv.Keys) { $psi.EnvironmentVariables[$k] = $dstEnv[$k] }

    $logBuffer = [System.Collections.Generic.List[string]]::new()
    $errorBuffer = [System.Collections.Generic.List[string]]::new()

    $isLoopbackStaging = ($DestinationAccount.ContainsKey('ProviderId') -and $DestinationAccount.ProviderId -eq 'terabox')

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
        Status = 'Uploading to provider'
        VerificationStatus = 'Uploading to provider'
        IsLoopbackStaging = [bool]$isLoopbackStaging
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
                if ($job.VerificationStatus -ne 'Remotely confirmed' -and $job.Status -ne 'Failed') {
                    $job.Status = 'Verifying remote file'
                    $job.VerificationStatus = 'Verifying remote file'
                    $destItemName = if ($job.SourcePath.Contains('/')) { $job.SourcePath.Substring($job.SourcePath.LastIndexOf('/') + 1) } else { $job.SourcePath }
                    $destFullPath = if ($job.DestinationPath) { "$($job.DestinationPath)/$destItemName" } else { $destItemName }
                    $vRes = Test-RemoteCloudFileVerification -Account $job.DestinationAccount -RemotePath $destFullPath -ExpectedSizeBytes $job.TotalBytes
                    if ($vRes.Verified) {
                        $job.Status = 'Remotely confirmed'
                        $job.VerificationStatus = 'Remotely confirmed'
                        $job.Percentage = 100.0
                        $job.EtaSeconds = 0
                    } else {
                        $job.Status = 'Failed'
                        $job.VerificationStatus = 'Failed'
                        $job.LastError = $vRes.Reason
                    }
                }
            } else {
                if ($job.Status -ne 'Cancelled') {
                    $job.Status = 'Failed'
                    $job.VerificationStatus = 'Failed'
                    if (-not $job.LastError) {
                        $job.LastError = "Process exited with code $($proc.ExitCode)"
                    }
                }
            }
        }
    }

    $isLoopback = if ($job.ContainsKey('IsLoopbackStaging')) { [bool]$job.IsLoopbackStaging } else { $false }
    $speedFmt = Format-TransferSpeed $job.SmoothedSpeed
    $throughputFmt = Format-TransferThroughput -BytesPerSec $job.SmoothedSpeed -IsLoopbackStaging $isLoopback
    $etaFmt = Format-EtaTimeSpan $job.EtaSeconds

    return [ordered]@{
        JobId = $job.JobId
        Status = $job.Status
        VerificationStatus = $job.VerificationStatus
        IsPaused = $job.IsPaused
        Mode = $job.Mode
        IsServerSide = $job.IsServerSide
        IsLoopbackStaging = $isLoopback
        SourceAccount = $job.SourceAccount.DisplayName
        DestinationAccount = $job.DestinationAccount.DisplayName
        SourcePath = $job.SourcePath
        DestinationPath = $job.DestinationPath
        BytesTransferred = $job.BytesTransferred
        TotalBytes = $job.TotalBytes
        Percentage = $job.Percentage
        SpeedFormatted = $speedFmt
        ThroughputFormatted = $throughputFmt
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
