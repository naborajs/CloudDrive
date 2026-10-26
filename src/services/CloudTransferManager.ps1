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
$script:CloudTransferQueue = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$script:TransferQueueFile = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\state\transfer-jobs.json')
$script:CustomTransferQueueFile = $null

function Set-TransferQueueFilePath([string]$Path) {
    $script:CustomTransferQueueFile = $Path
}

function Get-TransferQueueFilePath {
    if ($script:CustomTransferQueueFile) {
        return $script:CustomTransferQueueFile
    }
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\state\transfer-jobs.json')
}

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
    $mbpsStr = "{0:0.0}" -f $mbps
    $speedStr = if ($BytesPerSec -ge 1GB) {
        "$("{0:0.0}" -f ($BytesPerSec / 1GB)) GB/s"
    } elseif ($BytesPerSec -ge 1MB) {
        "$("{0:0.0}" -f ($BytesPerSec / 1MB)) MB/s"
    } elseif ($BytesPerSec -ge 1KB) {
        "$("{0:0.0}" -f ($BytesPerSec / 1KB)) KB/s"
    } else {
        "$([Math]::Round($BytesPerSec, 0)) B/s"
    }

    if ($IsLoopbackStaging) {
        return "Staging to local bridge: $speedStr ($mbpsStr Mbps) $([char]0x2022) Cloud upload pending"
    }
    return "$speedStr ($mbpsStr Mbps)"
}

function Test-ProviderUploadPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Account,

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
        [System.Collections.IDictionary]$Account,

        [Parameter(Mandatory = $true)]
        [string]$RemoteAlias
    )

    $rclonePath = Find-RcloneBinary
    if (-not $rclonePath -or -not (Test-Path -LiteralPath $rclonePath -PathType Leaf)) {
        throw "rclone binary not found. Cannot configure cloud transfer remote."
    }

    $providerId = if ($Account.ContainsKey('ProviderId')) { $Account.ProviderId } else { 'gdrive' }
    $accountId = if ($Account.ContainsKey('Id')) { $Account.Id } else { '' }

    if ($providerId -eq 'local') {
        return @{}
    } elseif ($providerId -eq 'gdrive') {
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
        [System.Collections.IDictionary]$Account,

        [string]$Path = '',

        [switch]$BypassLocalMount = $false
    )

    $providerId = if ($Account.ContainsKey('ProviderId')) { $Account.ProviderId } else { 'gdrive' }
    $accountId = if ($Account.ContainsKey('Id')) { $Account.Id } else { '' }

    if ($providerId -eq 'local') {
        $localDir = $Path
        $items = @()
        if (Test-Path -LiteralPath $localDir -PathType Container) {
            $children = Get-ChildItem -LiteralPath $localDir -ErrorAction SilentlyContinue
            foreach ($child in $children) {
                $isDir = $child.PSIsContainer
                $relPath = if ($Path) { "$Path/$($child.Name)" } else { $child.Name }
                $items += [ordered]@{
                    Name = $child.Name
                    Path = $relPath
                    IsDir = [bool]$isDir
                    Size = if ($isDir) { 0L } else { [int64]$child.Length }
                    MimeType = ''
                    ModTime = $child.LastWriteTime.ToString('o')
                    Hash = ''
                }
            }
        }
        return $items
    }

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
                            Hash = ''
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
    $psi.Arguments = "lsjson $safeTargetArg --max-depth 1 --hash"
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
                foreach ($item in @($parsed)) {
                    $itemHash = ''
                    if ($item.PSObject.Properties['Hashes'] -and $null -ne $item.Hashes) {
                        if ($item.Hashes.PSObject.Properties['MD5'] -and -not [string]::IsNullOrEmpty([string]$item.Hashes.MD5)) {
                            $itemHash = [string]$item.Hashes.MD5
                        } elseif ($item.Hashes.PSObject.Properties['md5'] -and -not [string]::IsNullOrEmpty([string]$item.Hashes.md5)) {
                            $itemHash = [string]$item.Hashes.md5
                        }
                    }

                    $itemName = if ($item.PSObject.Properties['Name']) { [string]$item.Name } else { '' }
                    $itemPath = if ($item.PSObject.Properties['Path']) { [string]$item.Path } else { '' }
                    $itemIsDir = if ($item.PSObject.Properties['IsDir']) { [bool]$item.IsDir } else { $false }
                    $itemSize = if ($item.PSObject.Properties['Size'] -and $item.Size -ge 0) { [int64]$item.Size } else { 0L }
                    $itemMime = if ($item.PSObject.Properties['MimeType']) { [string]$item.MimeType } else { '' }
                    $itemMod = if ($item.PSObject.Properties['ModTime']) { [string]$item.ModTime } else { '' }

                    $items += [ordered]@{
                        Name = $itemName
                        Path = $itemPath
                        IsDir = $itemIsDir
                        Size = $itemSize
                        MimeType = $itemMime
                        ModTime = $itemMod
                        Hash = $itemHash
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
        [System.Collections.IDictionary]$Account,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [int64]$ExpectedSizeBytes = -1L,

        [string]$LocalSourcePath = '',

        [string]$ExpectedMd5Hash = ''
    )

    $providerId = if ($Account.Contains('ProviderId')) { [string]$Account['ProviderId'] } else { 'gdrive' }
    $effectiveExpectedMd5 = ''
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMd5Hash)) {
        $effectiveExpectedMd5 = $ExpectedMd5Hash.Trim().ToLowerInvariant()
    }

    if ($providerId -eq 'local' -or (Test-Path -LiteralPath $RemotePath -PathType Leaf)) {
        if (Test-Path -LiteralPath $RemotePath -PathType Leaf) {
            $fi = [System.IO.FileInfo]::new($RemotePath)
            if ($ExpectedSizeBytes -ge 0L -and $fi.Length -ne $ExpectedSizeBytes) {
                return [ordered]@{
                    Verified = $false
                    Status = 'Failed'
                    Reason = "Local file size mismatch for '$($fi.Name)': local has $($fi.Length) bytes, expected $ExpectedSizeBytes bytes."
                    RemoteSizeBytes = $fi.Length
                    ExpectedSizeBytes = $ExpectedSizeBytes
                    RemoteHash = ''
                    ExpectedHash = $effectiveExpectedMd5
                    VerificationType = 'Size'
                    ProviderId = $providerId
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($effectiveExpectedMd5)) {
                $localHash = ''
                $md5 = [System.Security.Cryptography.MD5]::Create()
                $fs = $null
                try {
                    $fs = [System.IO.File]::OpenRead($RemotePath)
                    $hashBytes = $md5.ComputeHash($fs)
                    $localHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
                } finally {
                    if ($null -ne $fs) { $fs.Dispose() }
                    $md5.Dispose()
                }

                if ($localHash -ne $effectiveExpectedMd5) {
                    return [ordered]@{
                        Verified = $false
                        Status = 'Failed'
                        Reason = "Local file MD5 checksum mismatch for '$($fi.Name)': destination has '$localHash', expected '$effectiveExpectedMd5'."
                        RemoteSizeBytes = $fi.Length
                        ExpectedSizeBytes = $ExpectedSizeBytes
                        RemoteHash = $localHash
                        ExpectedHash = $effectiveExpectedMd5
                        VerificationType = 'MD5Checksum'
                        ProviderId = $providerId
                    }
                }

                return [ordered]@{
                    Verified = $true
                    Status = 'Remotely confirmed'
                    Reason = ''
                    RemoteSizeBytes = $fi.Length
                    ExpectedSizeBytes = $ExpectedSizeBytes
                    RemoteHash = $localHash
                    ExpectedHash = $effectiveExpectedMd5
                    VerificationType = 'MD5Checksum'
                    ProviderId = $providerId
                }
            }

            return [ordered]@{
                Verified = $true
                Status = 'Remotely confirmed'
                Reason = ''
                RemoteSizeBytes = $fi.Length
                ExpectedSizeBytes = $ExpectedSizeBytes
                RemoteHash = ''
                ExpectedHash = ''
                VerificationType = 'SizeAndPresence'
                ProviderId = $providerId
            }
        } else {
            return [ordered]@{
                Verified = $false
                Status = 'Failed'
                Reason = "File not found at destination path: $RemotePath"
                RemoteSizeBytes = 0L
                ExpectedSizeBytes = $ExpectedSizeBytes
                RemoteHash = ''
                ExpectedHash = $effectiveExpectedMd5
                VerificationType = 'None'
                ProviderId = $providerId
            }
        }
    }

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
        foreach ($item in @($items)) {
            if ($item.Contains('Name') -and $item['Name'] -eq $fileName) {
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
                RemoteHash = ''
                ExpectedHash = $effectiveExpectedMd5
                VerificationType = 'None'
                ProviderId = $providerId
            }
        }

        $remoteSize = if ($found.Contains('Size')) { [int64]$found['Size'] } else { 0L }
        $remoteHash = if ($found.Contains('Hash')) { [string]$found['Hash'] } else { '' }

        if ($ExpectedSizeBytes -ge 0L -and $remoteSize -ne $ExpectedSizeBytes) {
            return [ordered]@{
                Verified = $false
                Status = 'Failed'
                Reason = "Remote file size mismatch for '$fileName': remote has $remoteSize bytes, expected $ExpectedSizeBytes bytes."
                RemoteSizeBytes = $remoteSize
                ExpectedSizeBytes = $ExpectedSizeBytes
                RemoteHash = $remoteHash
                ExpectedHash = $effectiveExpectedMd5
                VerificationType = 'Size'
                ProviderId = $providerId
            }
        }

        $verificationType = 'SizeAndPresence'

        if ($providerId -in @('gdrive', 'google')) {
            # Compute expected MD5 if not provided and local source exists
            if ([string]::IsNullOrWhiteSpace($effectiveExpectedMd5) -and -not [string]::IsNullOrWhiteSpace($LocalSourcePath) -and (Test-Path -LiteralPath $LocalSourcePath -PathType Leaf)) {
                $md5 = [System.Security.Cryptography.MD5]::Create()
                $fs = $null
                try {
                    $fs = [System.IO.File]::OpenRead($LocalSourcePath)
                    $hashBytes = $md5.ComputeHash($fs)
                    $effectiveExpectedMd5 = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
                } catch {
                    $effectiveExpectedMd5 = ''
                } finally {
                    if ($null -ne $fs) { $fs.Dispose() }
                    $md5.Dispose()
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($remoteHash) -and -not [string]::IsNullOrWhiteSpace($effectiveExpectedMd5)) {
                if ($remoteHash.ToLowerInvariant() -ne $effectiveExpectedMd5) {
                    return [ordered]@{
                        Verified = $false
                        Status = 'Failed'
                        Reason = "Remote MD5 checksum mismatch for '$fileName': remote has '$remoteHash', source has '$effectiveExpectedMd5'."
                        RemoteSizeBytes = $remoteSize
                        ExpectedSizeBytes = $ExpectedSizeBytes
                        RemoteHash = $remoteHash
                        ExpectedHash = $effectiveExpectedMd5
                        VerificationType = 'MD5Checksum'
                        ProviderId = $providerId
                    }
                }
                $verificationType = 'MD5Checksum'
            } else {
                $verificationType = 'SizeAndPresence'
            }
        } elseif ($providerId -eq 'terabox') {
            # TeraBox does not expose MD5 in WebDAV lsjson. Verify size matches $ExpectedSizeBytes and $found.ModTime is present.
            $modTime = if ($found.Contains('ModTime')) { [string]$found['ModTime'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($modTime)) {
                return [ordered]@{
                    Verified = $false
                    Status = 'Failed'
                    Reason = "Remote file '$fileName' on TeraBox is missing modification timestamp metadata."
                    RemoteSizeBytes = $remoteSize
                    ExpectedSizeBytes = $ExpectedSizeBytes
                    RemoteHash = $remoteHash
                    ExpectedHash = $effectiveExpectedMd5
                    VerificationType = 'SizeAndModTime'
                    ProviderId = $providerId
                }
            }
            $verificationType = 'SizeAndModTime'
        } else {
            $verificationType = 'SizeAndPresence'
        }

        return [ordered]@{
            Verified = $true
            Status = 'Remotely confirmed'
            Reason = ''
            RemoteSizeBytes = $remoteSize
            ExpectedSizeBytes = $ExpectedSizeBytes
            RemoteHash = $remoteHash
            ExpectedHash = $effectiveExpectedMd5
            VerificationType = $verificationType
            ProviderId = $providerId
        }
    } catch {
        return [ordered]@{
            Verified = $false
            Status = 'Remote state unknown'
            Reason = "Could not verify remote file '$fileName': $($_.Exception.Message)"
            RemoteSizeBytes = 0L
            ExpectedSizeBytes = $ExpectedSizeBytes
            RemoteHash = ''
            ExpectedHash = $effectiveExpectedMd5
            VerificationType = 'None'
            ProviderId = $providerId
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
        [System.Collections.IDictionary]$SourceAccount,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$DestinationAccount,

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

    if ([string]::IsNullOrEmpty($BandwidthLimit)) {
        try {
            if (Get-Command Get-EffectiveBandwidthLimitRate -ErrorAction SilentlyContinue) {
                $BandwidthLimit = Get-EffectiveBandwidthLimitRate
            }
        } catch { }
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
            $srcItems = @(Get-CloudDirectoryContents -Account $SourceAccount -Path $cleanSrcPath)
            if ($srcItems.Count -eq 1 -and (-not $srcItems[0].IsDir)) {
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

    $srcProvider = if ($SourceAccount.ContainsKey('ProviderId')) { [string]$SourceAccount['ProviderId'] } else { 'gdrive' }
    $dstProvider = if ($DestinationAccount.ContainsKey('ProviderId')) { [string]$DestinationAccount['ProviderId'] } else { 'gdrive' }

    $srcIsLocal = ($srcProvider -eq 'local' -or ($SourcePath -match '^[A-Za-z]:[\\/]') -or (Test-Path -LiteralPath $SourcePath -PathType Leaf))
    $dstIsLocal = ($dstProvider -eq 'local' -or ($DestinationPath -match '^[A-Za-z]:[\\/]'))

    $srcSpec = if ($srcIsLocal) { $SourcePath } else { if ($cleanSrcPath) { "${srcRemote}:${cleanSrcPath}" } else { "${srcRemote}:" } }
    $dstSpec = if ($dstIsLocal) { $DestinationPath } else { if ($cleanDstPath) { "${dstRemote}:${cleanDstPath}" } else { "${dstRemote}:" } }

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

    if (-not [string]::IsNullOrEmpty($BandwidthLimit) -and $BandwidthLimit -ne 'off') {
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
        RemoteHash = ''
        VerificationType = ''
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
                    if ($parsed.PSObject.Properties['level'] -and $parsed.level -eq 'error') {
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
                    $cleanItemName = [System.IO.Path]::GetFileName([string]$job.SourcePath.Replace('/', '\').TrimEnd('\'))
                    $destItemName = if ($cleanItemName) { $cleanItemName } else { [string]$job.SourcePath }
                    $destFullPath = if ($job.DestinationPath) { Normalize-CloudPath "$($job.DestinationPath)/$destItemName" } else { $destItemName }
                    $localSource = if ($job.ContainsKey('SourcePath')) { [string]$job.SourcePath } else { '' }
                    $vRes = Test-RemoteCloudFileVerification -Account $job.DestinationAccount -RemotePath $destFullPath -ExpectedSizeBytes ([int64]$job.TotalBytes) -LocalSourcePath $localSource
                    if ($vRes -and $vRes['Verified']) {
                        $job.Status = 'Remotely confirmed'
                        $job.VerificationStatus = 'Remotely confirmed'
                        $job.Percentage = 100.0
                        $job.EtaSeconds = 0
                        if ($vRes.Contains('RemoteHash')) {
                            $job['RemoteHash'] = [string]$vRes['RemoteHash']
                        }
                        if ($vRes.Contains('VerificationType')) {
                            $job['VerificationType'] = [string]$vRes['VerificationType']
                        }
                    } else {
                        $job.Status = 'Failed'
                        $job.VerificationStatus = 'Failed'
                        $job.LastError = [string]$vRes['Reason']
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

    $isLoopback = if ($job.Contains('IsLoopbackStaging')) { [bool]$job.IsLoopbackStaging } else { $false }
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
        RemoteHash = if ($job.ContainsKey('RemoteHash')) { [string]$job['RemoteHash'] } else { '' }
        VerificationType = if ($job.ContainsKey('VerificationType')) { [string]$job['VerificationType'] } else { '' }
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
    $job.Status = 'Cancelling'
    $job.VerificationStatus = 'Cancelling'

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

    $job.Status = 'Cancelled'
    $job.VerificationStatus = 'Cancelled'
    $job.EndTime = [DateTime]::UtcNow
    return $true
}

# ==============================================================================
# ERROR CLASSIFICATION
# ==============================================================================

function Test-IsPermanentTransferError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ErrorMessage = ''
    )

    if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { return $false }
    if ($ErrorMessage -match '(?i)(exceeds.*TeraBox.*plan limit|PlanFileLimit|403 Forbidden|404 Not Found|QuotaExceeded|invalid character|file name too long|access denied|is a directory|illegal character|cannot find the path)') {
        return $true
    }
    return $false
}

# ==============================================================================
# DURABLE QUEUE PERSISTENCE (transfer-jobs.json)
# ==============================================================================

function Save-DurableTransferQueue {
    [CmdletBinding()]
    param(
        [string]$FilePath = ''
    )

    $targetFile = if ($FilePath) { $FilePath } else { Get-TransferQueueFilePath }
    $targetDir = [System.IO.Path]::GetDirectoryName($targetFile)
    if (-not [string]::IsNullOrEmpty($targetDir) -and -not (Test-Path -LiteralPath $targetDir)) {
        [void][System.IO.Directory]::CreateDirectory($targetDir)
    }

    $jobsList = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in @($script:CloudTransferQueue)) {
        $jId = if ($item.ContainsKey('JobId') -and $item['JobId']) { [string]$item['JobId'] } else { [string]$item['QueueId'] }
        $qId = if ($item.ContainsKey('QueueId') -and $item['QueueId']) { [string]$item['QueueId'] } else { $jId }

        $nextRetryStr = $null
        if ($item.ContainsKey('NextRetryUtc') -and ($item['NextRetryUtc'] -is [DateTime]) -and ($item['NextRetryUtc'] -gt [DateTime]::MinValue)) {
            $nextRetryStr = ([DateTime]$item['NextRetryUtc']).ToString('o')
        }
        $enqueuedStr = if ($item.ContainsKey('EnqueuedUtc') -and ($item['EnqueuedUtc'] -is [DateTime])) { ([DateTime]$item['EnqueuedUtc']).ToString('o') } else { [DateTime]::UtcNow.ToString('o') }
        $startedStr = if ($item.ContainsKey('StartedUtc') -and ($item['StartedUtc'] -is [DateTime])) { ([DateTime]$item['StartedUtc']).ToString('o') } else { $null }
        $completedStr = if ($item.ContainsKey('CompletedUtc') -and ($item['CompletedUtc'] -is [DateTime])) { ([DateTime]$item['CompletedUtc']).ToString('o') } else { $null }
        $lastProgStr = if ($item.ContainsKey('LastProgressUtc') -and ($item['LastProgressUtc'] -is [DateTime])) { ([DateTime]$item['LastProgressUtc']).ToString('o') } else { $null }
        $leaseStr = if ($item.ContainsKey('WorkerLeaseUtc') -and ($item['WorkerLeaseUtc'] -is [DateTime])) { ([DateTime]$item['WorkerLeaseUtc']).ToString('o') } else { $null }

        $jH = [ordered]@{
            JobId = $jId
            QueueId = $qId
            BatchId = if ($item.ContainsKey('BatchId')) { [string]$item['BatchId'] } else { '' }
            BatchName = if ($item.ContainsKey('BatchName')) { [string]$item['BatchName'] } else { '' }
            AccountId = if ($item.ContainsKey('AccountId')) { [string]$item['AccountId'] } else { '' }
            ProviderId = if ($item.ContainsKey('ProviderId')) { [string]$item['ProviderId'] } else { '' }
            SourcePath = if ($item.ContainsKey('SourcePath')) { [string]$item['SourcePath'] } else { '' }
            DestinationPath = if ($item.ContainsKey('DestinationPath')) { [string]$item['DestinationPath'] } else { '' }
            DestinationFilePath = if ($item.ContainsKey('DestinationFilePath')) { [string]$item['DestinationFilePath'] } else { '' }
            DestinationDirectory = if ($item.ContainsKey('DestinationDirectory')) { [string]$item['DestinationDirectory'] } else { '' }
            RelativePath = if ($item.ContainsKey('RelativePath')) { [string]$item['RelativePath'] } else { '' }
            FileName = if ($item.ContainsKey('FileName')) { [string]$item['FileName'] } else { '' }
            FileSizeBytes = if ($item.ContainsKey('FileSizeBytes')) { [int64]$item['FileSizeBytes'] } else { 0L }
            BytesTransferred = if ($item.ContainsKey('BytesTransferred')) { [int64]$item['BytesTransferred'] } else { 0L }
            Status = if ($item.ContainsKey('Status')) { [string]$item['Status'] } else { 'Queued' }
            RetryCount = if ($item.ContainsKey('RetryCount')) { [int]$item['RetryCount'] } else { 0 }
            MaxRetries = if ($item.ContainsKey('MaxRetries')) { [int]$item['MaxRetries'] } else { 3 }
            NextRetryUtc = $nextRetryStr
            LastError = if ($item.ContainsKey('LastError')) { [string]$item['LastError'] } else { '' }
            EnqueuedUtc = $enqueuedStr
            StartedUtc = $startedStr
            CompletedUtc = $completedStr
            LastProgressUtc = $lastProgStr
            WorkerPid = if ($item.ContainsKey('WorkerPid')) { [int]$item['WorkerPid'] } else { 0 }
            WorkerLeaseUtc = $leaseStr
            BandwidthLimit = if ($item.ContainsKey('BandwidthLimit')) { [string]$item['BandwidthLimit'] } else { '' }
            ConflictAction = if ($item.ContainsKey('ConflictAction')) { [string]$item['ConflictAction'] } else { 'Skip' }
            IsMove = if ($item.ContainsKey('IsMove')) { [bool]$item['IsMove'] } else { $false }
            Percentage = if ($item.ContainsKey('Percentage')) { [double]$item['Percentage'] } else { 0.0 }
            SmoothedSpeed = if ($item.ContainsKey('SmoothedSpeed')) { [double]$item['SmoothedSpeed'] } else { 0.0 }
            EtaSeconds = if ($item.ContainsKey('EtaSeconds') -and $null -ne $item['EtaSeconds']) { [int]$item['EtaSeconds'] } else { $null }
            SourceAccount = if ($item.ContainsKey('SourceAccount')) { $item['SourceAccount'] } else { @{} }
            DestinationAccount = if ($item.ContainsKey('DestinationAccount')) { $item['DestinationAccount'] } else { @{} }
        }
        $jobsList.Add($jH)
    }

    $activeBatchId = ''
    foreach ($j in $jobsList) {
        if ($j['BatchId'] -and $j['Status'] -notin @('Completed and remotely confirmed', 'Failed', 'Cancelled')) {
            $activeBatchId = [string]$j['BatchId']
            break
        }
    }

    $payload = [ordered]@{
        Version = '1.0'
        LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
        ActiveBatchId = $activeBatchId
        Jobs = $jobsList.ToArray()
    }

    $json = $payload | ConvertTo-Json -Depth 10

    # Atomic write: serialize to a temporary file (.tmp) and atomically move/replace into place
    $tmpFile = "$targetFile.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmpFile, $json, [System.Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $targetFile) {
            try {
                [System.IO.File]::Replace($tmpFile, $targetFile, $null)
            } catch {
                Move-Item -LiteralPath $tmpFile -Destination $targetFile -Force
            }
        } else {
            [System.IO.File]::Move($tmpFile, $targetFile)
        }
        return $true
    } finally {
        if (Test-Path -LiteralPath $tmpFile) {
            try { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Load-DurableTransferQueue {
    [CmdletBinding()]
    param(
        [string]$FilePath = ''
    )

    $targetFile = if ($FilePath) { $FilePath } else { Get-TransferQueueFilePath }
    if (-not (Test-Path -LiteralPath $targetFile -PathType Leaf)) {
        return 0
    }

    $jsonText = [System.IO.File]::ReadAllText($targetFile, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return 0
    }

    $parsed = $null
    try {
        $parsed = $jsonText | ConvertFrom-Json
    } catch {
        return 0
    }

    if (-not $parsed -or -not $parsed.PSObject.Properties['Jobs']) {
        return 0
    }

    $script:CloudTransferQueue.Clear()
    $loadedCount = 0

    foreach ($j in @($parsed.Jobs)) {
        $jId = if ($j.PSObject.Properties['JobId'] -and $j.JobId) { [string]$j.JobId } elseif ($j.PSObject.Properties['QueueId'] -and $j.QueueId) { [string]$j.QueueId } else { "job_" + [Guid]::NewGuid().ToString('N').Substring(0, 8) }
        $qId = if ($j.PSObject.Properties['QueueId'] -and $j.QueueId) { [string]$j.QueueId } else { $jId }

        $srcAcc = @{}
        if ($j.PSObject.Properties['SourceAccount'] -and $j.SourceAccount) {
            if ($j.SourceAccount -is [System.Collections.IDictionary]) {
                $srcAcc = [hashtable]$j.SourceAccount
            } else {
                foreach ($prop in $j.SourceAccount.PSObject.Properties) {
                    $srcAcc[$prop.Name] = $prop.Value
                }
            }
        }
        $dstAcc = @{}
        if ($j.PSObject.Properties['DestinationAccount'] -and $j.DestinationAccount) {
            if ($j.DestinationAccount -is [System.Collections.IDictionary]) {
                $dstAcc = [hashtable]$j.DestinationAccount
            } else {
                foreach ($prop in $j.DestinationAccount.PSObject.Properties) {
                    $dstAcc[$prop.Name] = $prop.Value
                }
            }
        }

        $nextRetry = [DateTime]::MinValue
        if ($j.PSObject.Properties['NextRetryUtc'] -and $j.NextRetryUtc) {
            try { $nextRetry = [DateTime]::Parse([string]$j.NextRetryUtc).ToUniversalTime() } catch { }
        }
        $enqueued = [DateTime]::UtcNow
        if ($j.PSObject.Properties['EnqueuedUtc'] -and $j.EnqueuedUtc) {
            try { $enqueued = [DateTime]::Parse([string]$j.EnqueuedUtc).ToUniversalTime() } catch { }
        }
        $started = $null
        if ($j.PSObject.Properties['StartedUtc'] -and $j.StartedUtc) {
            try { $started = [DateTime]::Parse([string]$j.StartedUtc).ToUniversalTime() } catch { }
        }
        $completed = $null
        if ($j.PSObject.Properties['CompletedUtc'] -and $j.CompletedUtc) {
            try { $completed = [DateTime]::Parse([string]$j.CompletedUtc).ToUniversalTime() } catch { }
        }
        $lastProg = $null
        if ($j.PSObject.Properties['LastProgressUtc'] -and $j.LastProgressUtc) {
            try { $lastProg = [DateTime]::Parse([string]$j.LastProgressUtc).ToUniversalTime() } catch { }
        }
        $lease = $null
        if ($j.PSObject.Properties['WorkerLeaseUtc'] -and $j.WorkerLeaseUtc) {
            try { $lease = [DateTime]::Parse([string]$j.WorkerLeaseUtc).ToUniversalTime() } catch { }
        }

        $item = [hashtable]::Synchronized(@{
            JobId = $jId
            QueueId = $qId
            BatchId = if ($j.PSObject.Properties['BatchId'] -and $j.BatchId) { [string]$j.BatchId } else { '' }
            BatchName = if ($j.PSObject.Properties['BatchName'] -and $j.BatchName) { [string]$j.BatchName } else { '' }
            AccountId = if ($j.PSObject.Properties['AccountId'] -and $j.AccountId) { [string]$j.AccountId } else { '' }
            ProviderId = if ($j.PSObject.Properties['ProviderId'] -and $j.ProviderId) { [string]$j.ProviderId } else { '' }
            SourcePath = if ($j.PSObject.Properties['SourcePath'] -and $j.SourcePath) { [string]$j.SourcePath } else { '' }
            DestinationPath = if ($j.PSObject.Properties['DestinationPath'] -and $j.DestinationPath) { [string]$j.DestinationPath } else { '' }
            DestinationFilePath = if ($j.PSObject.Properties['DestinationFilePath'] -and $j.DestinationFilePath) { [string]$j.DestinationFilePath } else { '' }
            DestinationDirectory = if ($j.PSObject.Properties['DestinationDirectory'] -and $j.DestinationDirectory) { [string]$j.DestinationDirectory } else { '' }
            RelativePath = if ($j.PSObject.Properties['RelativePath'] -and $j.RelativePath) { [string]$j.RelativePath } else { '' }
            FileName = if ($j.PSObject.Properties['FileName'] -and $j.FileName) { [string]$j.FileName } else { '' }
            FileSizeBytes = if ($j.PSObject.Properties['FileSizeBytes']) { [int64]$j.FileSizeBytes } else { 0L }
            BytesTransferred = if ($j.PSObject.Properties['BytesTransferred']) { [int64]$j.BytesTransferred } else { 0L }
            Status = if ($j.PSObject.Properties['Status'] -and $j.Status) { [string]$j.Status } else { 'Queued' }
            RetryCount = if ($j.PSObject.Properties['RetryCount']) { [int]$j.RetryCount } else { 0 }
            MaxRetries = if ($j.PSObject.Properties['MaxRetries']) { [int]$j.MaxRetries } else { 3 }
            NextRetryUtc = $nextRetry
            LastError = if ($j.PSObject.Properties['LastError'] -and $j.LastError) { [string]$j.LastError } else { '' }
            EnqueuedUtc = $enqueued
            StartedUtc = $started
            CompletedUtc = $completed
            LastProgressUtc = $lastProg
            WorkerPid = if ($j.PSObject.Properties['WorkerPid']) { [int]$j.WorkerPid } else { 0 }
            WorkerLeaseUtc = $lease
            BandwidthLimit = if ($j.PSObject.Properties['BandwidthLimit'] -and $j.BandwidthLimit) { [string]$j.BandwidthLimit } else { '' }
            ConflictAction = if ($j.PSObject.Properties['ConflictAction'] -and $j.ConflictAction) { [string]$j.ConflictAction } else { 'Skip' }
            IsMove = if ($j.PSObject.Properties['IsMove']) { [bool]$j.IsMove } else { $false }
            Percentage = if ($j.PSObject.Properties['Percentage']) { [double]$j.Percentage } else { 0.0 }
            SmoothedSpeed = if ($j.PSObject.Properties['SmoothedSpeed']) { [double]$j.SmoothedSpeed } else { 0.0 }
            EtaSeconds = if ($j.PSObject.Properties['EtaSeconds'] -and $null -ne $j.EtaSeconds) { [int]$j.EtaSeconds } else { $null }
            SourceAccount = $srcAcc
            DestinationAccount = $dstAcc
            RemoteHash = if ($j.PSObject.Properties['RemoteHash'] -and $j.RemoteHash) { [string]$j.RemoteHash } else { '' }
            VerificationType = if ($j.PSObject.Properties['VerificationType'] -and $j.VerificationType) { [string]$j.VerificationType } else { '' }
        })

        [void]$script:CloudTransferQueue.Add($item)
        $loadedCount++
    }

    return $loadedCount
}

# ==============================================================================
# DURABLE FOLDER BATCH INGESTION & PIPELINE
# ==============================================================================

function Add-CloudTransferFolderBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$SourceAccount,

        [Parameter(Mandatory = $true)]
        [string]$SourceFolderPath,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$DestinationAccount,

        [Parameter(Mandatory = $false)]
        [string]$DestinationFolderPath = '',

        [ValidateSet('Overwrite', 'Skip', 'Rename')]
        [string]$ConflictAction = 'Skip',

        [switch]$IsMove,

        [string]$BandwidthLimit = ''
    )

    if ([string]::IsNullOrWhiteSpace($SourceFolderPath)) {
        throw "SourceFolderPath cannot be empty."
    }

    if (-not (Test-Path -LiteralPath $SourceFolderPath -PathType Container)) {
        throw "Source folder does not exist or is not a directory: $SourceFolderPath"
    }

    $cleanSourceRoot = $SourceFolderPath.TrimEnd('\', '/')
    $folderItem = Get-Item -LiteralPath $cleanSourceRoot -ErrorAction Stop
    $batchName = if ($folderItem -and $folderItem.Name) { $folderItem.Name } else { [System.IO.Path]::GetFileName($cleanSourceRoot) }
    if (-not $batchName) { $batchName = 'FolderBatch' }

    $batchId = "batch_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $rootLen = $cleanSourceRoot.Length

    $srcAccId = if ($SourceAccount.ContainsKey('Id')) { [string]$SourceAccount['Id'] } else { '' }
    $srcProvId = if ($SourceAccount.ContainsKey('ProviderId')) { [string]$SourceAccount['ProviderId'] } else { 'local' }
    $dstAccId = if ($DestinationAccount.ContainsKey('Id')) { [string]$DestinationAccount['Id'] } else { '' }
    $dstProvId = if ($DestinationAccount.ContainsKey('ProviderId')) { [string]$DestinationAccount['ProviderId'] } else { 'gdrive' }

    # Streaming recursive enumeration using [System.IO.Directory]::EnumerateFiles
    # Avoids loading entire tree into memory for folders with thousands of files
    $filesEnumerate = [System.IO.Directory]::EnumerateFiles($cleanSourceRoot, '*', [System.IO.SearchOption]::AllDirectories)
    $createdJobs = [System.Collections.Generic.List[hashtable]]::new()
    $totalBatchBytes = 0L

    foreach ($filePath in $filesEnumerate) {
        $fi = [System.IO.FileInfo]::new($filePath)
        $fileSize = [int64]$fi.Length
        $totalBatchBytes += $fileSize
        $fileName = $fi.Name

        # Compute relative subfolder path (e.g. "subA/file.txt")
        $relPath = $filePath.Substring($rootLen).TrimStart('\', '/').Replace('\', '/')

        # Compute clean destination file path (preserves folder hierarchy)
        $cleanDest = if ($DestinationFolderPath) {
            Normalize-CloudPath -Path "$DestinationFolderPath/$relPath"
        } else {
            Normalize-CloudPath -Path $relPath
        }

        # Compute destination parent directory for rclone copy
        $destDir = if ($cleanDest.Contains('/')) {
            $cleanDest.Substring(0, $cleanDest.LastIndexOf('/'))
        } else {
            ''
        }

        $jobId = "job_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $jobItem = [hashtable]::Synchronized(@{
            JobId = $jobId
            QueueId = $jobId
            BatchId = $batchId
            BatchName = $batchName
            AccountId = $dstAccId
            ProviderId = $dstProvId
            SourceAccount = $SourceAccount
            DestinationAccount = $DestinationAccount
            SourcePath = $filePath
            DestinationPath = $destDir
            DestinationFilePath = $cleanDest
            DestinationDirectory = $destDir
            RelativePath = $relPath
            ConflictAction = $ConflictAction
            IsMove = [bool]$IsMove
            Status = 'Queued'
            RetryCount = 0
            MaxRetries = 3
            NextRetryUtc = [DateTime]::MinValue
            EnqueuedUtc = [DateTime]::UtcNow
            StartedUtc = $null
            CompletedUtc = $null
            LastProgressUtc = $null
            WorkerPid = 0
            WorkerLeaseUtc = $null
            LastError = ''
            FileName = $fileName
            FileSizeBytes = $fileSize
            BytesTransferred = 0L
            Percentage = 0.0
            SmoothedSpeed = 0.0
            EtaSeconds = $null
            BandwidthLimit = $BandwidthLimit
            RemoteHash = ''
            VerificationType = ''
        })

        [void]$script:CloudTransferQueue.Add($jobItem)
        $createdJobs.Add($jobItem)
    }

    # CRITICAL: Atomically call Save-DurableTransferQueue BEFORE returning the batch confirmation to the caller!
    Save-DurableTransferQueue | Out-Null

    return [ordered]@{
        BatchId = $batchId
        BatchName = $batchName
        TotalFiles = $createdJobs.Count
        TotalBytes = $totalBatchBytes
        Jobs = $createdJobs.ToArray()
    }
}

# ==============================================================================
# BATCH TELEMETRY & SUMMARY
# ==============================================================================

function Get-CloudTransferBatchSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BatchId
    )

    $batchItems = @($script:CloudTransferQueue | Where-Object {
        $_.ContainsKey('BatchId') -and $_['BatchId'] -eq $BatchId
    })

    if ($batchItems.Count -eq 0) {
        return $null
    }

    $batchName = [string]$batchItems[0]['BatchName']
    $totalFiles = $batchItems.Count
    $totalBytes = 0L
    $bytesTransferred = 0L
    $queuedCount = 0
    $uploadingCount = 0
    $awaitingCount = 0
    $completedCount = 0
    $failedCount = 0
    $cancelledCount = 0

    foreach ($item in $batchItems) {
        $st = [string]$item['Status']
        $fSize = [int64]$item['FileSizeBytes']
        $bTrans = [int64]$item['BytesTransferred']
        $totalBytes += $fSize

        switch ($st) {
            'Queued' { $queuedCount++; $bytesTransferred += $bTrans }
            'Staging' { $queuedCount++; $bytesTransferred += $bTrans }
            'Staged' { $queuedCount++; $bytesTransferred += $bTrans }
            'Waiting for network/provider' { $queuedCount++; $bytesTransferred += $bTrans }
            'Uploading' { $uploadingCount++; $bytesTransferred += $bTrans }
            'Upload pending remote confirmation' { $awaitingCount++; $bytesTransferred += [Math]::Max($bTrans, $fSize) }
            'Awaiting remote confirmation' { $awaitingCount++; $bytesTransferred += [Math]::Max($bTrans, $fSize) }
            'Verifying remote file' { $awaitingCount++; $bytesTransferred += [Math]::Max($bTrans, $fSize) }
            'Completed and remotely confirmed' { $completedCount++; $bytesTransferred += $fSize }
            'Failed' { $failedCount++; $bytesTransferred += $bTrans }
            'Cancelled' { $cancelledCount++; $bytesTransferred += $bTrans }
            default { $queuedCount++; $bytesTransferred += $bTrans }
        }
    }

    $pct = 0.0
    if ($totalBytes -gt 0L) {
        $pct = [Math]::Min(100.0, [Math]::Round(($bytesTransferred / [double]$totalBytes) * 100.0, 1))
    } elseif ($totalFiles -gt 0) {
        $pct = [Math]::Min(100.0, [Math]::Round(($completedCount / [double]$totalFiles) * 100.0, 1))
    }

    $isComplete = ($totalFiles -gt 0 -and ($completedCount + $failedCount + $cancelledCount) -eq $totalFiles)

    return [ordered]@{
        BatchId = $BatchId
        BatchName = $batchName
        TotalFiles = $totalFiles
        TotalBytes = $totalBytes
        QueuedCount = $queuedCount
        UploadingCount = $uploadingCount
        AwaitingConfirmationCount = $awaitingCount
        CompletedCount = $completedCount
        FailedCount = $failedCount
        CancelledCount = $cancelledCount
        BytesTransferred = $bytesTransferred
        OverallPercentage = $pct
        IsComplete = $isComplete
    }
}

function Stop-CloudTransferBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BatchId
    )

    $cancelledAny = $false
    foreach ($item in @($script:CloudTransferQueue)) {
        if ($item.ContainsKey('BatchId') -and $item['BatchId'] -eq $BatchId -and $item['Status'] -notin @('Completed and remotely confirmed', 'Failed', 'Cancelled')) {
            if ($item.ContainsKey('JobId') -and $item['JobId']) {
                try { Stop-CloudTransfer -JobId [string]$item['JobId'] | Out-Null } catch { }
            }
            $item['Status'] = 'Cancelled'
            $item['CompletedUtc'] = [DateTime]::UtcNow
            $cancelledAny = $true
        }
    }

    if ($cancelledAny) {
        Save-DurableTransferQueue | Out-Null
    }

    return $cancelledAny
}

# ==============================================================================
# STARTUP CRASH / RESTART RECOVERY
# ==============================================================================

function Invoke-StartupTransferQueueRecovery {
    [CmdletBinding()]
    param()

    # Load persistent queue from disk
    $null = Load-DurableTransferQueue
    $recoveredCount = 0
    $confirmedCount = 0
    $resetCount = 0

    $now = [DateTime]::UtcNow
    foreach ($item in @($script:CloudTransferQueue)) {
        $status = [string]$item['Status']
        if ($status -in @('Uploading', 'Staging', 'Waiting for network/provider', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file')) {
            $recoveredCount++
            # Reconcile against remote destination
            $destItemName = if ($item.ContainsKey('FileName') -and $item['FileName']) {
                [string]$item['FileName']
            } elseif ($item['SourcePath'].Contains('/')) {
                $item['SourcePath'].Substring($item['SourcePath'].LastIndexOf('/') + 1)
            } else {
                [System.IO.Path]::GetFileName([string]$item['SourcePath'])
            }

            $destFullPath = if ($item.ContainsKey('DestinationFilePath') -and $item['DestinationFilePath']) {
                [string]$item['DestinationFilePath']
            } elseif ($item.ContainsKey('DestinationPath') -and $item['DestinationPath']) {
                "$($item['DestinationPath'])/$destItemName"
            } else {
                $destItemName
            }

            $sourcePath = if ($item.ContainsKey('SourcePath')) { [string]$item['SourcePath'] } else { '' }
            $vRes = $null
            try {
                $vRes = Test-RemoteCloudFileVerification -Account $item['DestinationAccount'] -RemotePath $destFullPath -ExpectedSizeBytes ([int64]$item['FileSizeBytes']) -LocalSourcePath $sourcePath
            } catch { }

            if ($vRes -and $vRes['Verified']) {
                $item['Status'] = 'Completed and remotely confirmed'
                $item['Percentage'] = 100.0
                if ($item.ContainsKey('FileSizeBytes') -and [int64]$item['FileSizeBytes'] -gt 0L) {
                    $item['BytesTransferred'] = [int64]$item['FileSizeBytes']
                }
                $item['CompletedUtc'] = $now
                $item['WorkerPid'] = 0
                $item['WorkerLeaseUtc'] = $null
                if ($vRes.Contains('RemoteHash')) {
                    $item['RemoteHash'] = [string]$vRes['RemoteHash']
                }
                if ($vRes.Contains('VerificationType')) {
                    $item['VerificationType'] = [string]$vRes['VerificationType']
                }
                $confirmedCount++
            } else {
                # Interrupted job not verified remotely: reset to Queued readiness
                $item['Status'] = 'Queued'
                $item['JobId'] = ''
                $item['WorkerPid'] = 0
                $item['WorkerLeaseUtc'] = $null
                $item['RetryCount'] = 0
                $item['NextRetryUtc'] = [DateTime]::MinValue
                $resetCount++
            }
        }
    }

    if ($recoveredCount -gt 0) {
        Save-DurableTransferQueue | Out-Null
    }

    return [ordered]@{
        RecoveredCount = $recoveredCount
        ConfirmedCount = $confirmedCount
        ResetCount = $resetCount
    }
}

# ==============================================================================
# RESILIENT MULTI-FILE TRANSFER QUEUE MANAGER
# ==============================================================================

function Add-CloudTransferQueueItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$SourceAccount,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$DestinationAccount,

        [Parameter(Mandatory = $false)]
        [string]$DestinationPath = '',

        [ValidateSet('Overwrite', 'Skip', 'Rename')]
        [string]$ConflictAction = 'Skip',

        [switch]$IsMove,

        [int]$MaxRetries = 3,

        [int64]$FileSizeBytes = 0L,

        [string]$BandwidthLimit = '',

        [string]$BatchId = '',

        [string]$BatchName = '',

        [string]$RelativePath = ''
    )

    $queueId = "queue_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $cleanSrc = Normalize-CloudPath -Path $SourcePath
    $fileName = if ($cleanSrc.Contains('/')) { $cleanSrc.Substring($cleanSrc.LastIndexOf('/') + 1) } else { $cleanSrc }

    $srcAccId = if ($SourceAccount.ContainsKey('Id')) { [string]$SourceAccount['Id'] } else { '' }
    $dstAccId = if ($DestinationAccount.ContainsKey('Id')) { [string]$DestinationAccount['Id'] } else { '' }
    $dstProvId = if ($DestinationAccount.ContainsKey('ProviderId')) { [string]$DestinationAccount['ProviderId'] } else { 'gdrive' }

    $item = [hashtable]::Synchronized(@{
        JobId = $queueId
        QueueId = $queueId
        BatchId = $BatchId
        BatchName = $BatchName
        AccountId = $dstAccId
        ProviderId = $dstProvId
        SourceAccount = $SourceAccount
        SourcePath = $SourcePath
        DestinationAccount = $DestinationAccount
        DestinationPath = $DestinationPath
        DestinationFilePath = if ($DestinationPath) { Normalize-CloudPath "$DestinationPath/$fileName" } else { $fileName }
        DestinationDirectory = $DestinationPath
        RelativePath = if ($RelativePath) { $RelativePath } else { $fileName }
        ConflictAction = $ConflictAction
        IsMove = [bool]$IsMove
        Status = 'Queued'
        RetryCount = 0
        MaxRetries = $MaxRetries
        NextRetryUtc = [DateTime]::MinValue
        EnqueuedUtc = [DateTime]::UtcNow
        StartedUtc = $null
        CompletedUtc = $null
        LastProgressUtc = $null
        WorkerPid = 0
        WorkerLeaseUtc = $null
        LastError = ''
        FileName = $fileName
        FileSizeBytes = $FileSizeBytes
        BytesTransferred = 0L
        Percentage = 0.0
        SmoothedSpeed = 0.0
        EtaSeconds = $null
        BandwidthLimit = $BandwidthLimit
    })

    [void]$script:CloudTransferQueue.Add($item)
    Save-DurableTransferQueue | Out-Null
    return $item
}

function Get-CloudTransferQueue {
    [CmdletBinding()]
    param()

    $copy = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($item in @($script:CloudTransferQueue)) {
        $copy.Add([hashtable]$item.Clone())
    }
    return ,@($copy.ToArray())
}

function Process-CloudTransferQueue {
    [CmdletBinding()]
    param(
        [int]$MaxConcurrent = 4,
        [string]$GlobalBandwidthLimit = ''
    )

    # Authoritative Single Scheduler Coordination via Named Mutex
    $mutexName = 'Global\NSCloudDrive_TransferScheduler_Mutex'
    $schedulerMutex = $null
    $hasMutexLock = $false
    try {
        $schedulerMutex = [System.Threading.Mutex]::new($false, $mutexName)
        $hasMutexLock = $schedulerMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $hasMutexLock = $true
    } catch {
        try {
            $schedulerMutex = [System.Threading.Mutex]::new($false, 'Local\NSCloudDrive_TransferScheduler_Mutex')
            $hasMutexLock = $schedulerMutex.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $hasMutexLock = $true
        } catch {
            $hasMutexLock = $true
        }
    }

    if (-not $hasMutexLock) {
        if ($schedulerMutex) { try { $schedulerMutex.Dispose() } catch { } }
        return (Get-CloudTransferQueue)
    }

    try {
        $now = [DateTime]::UtcNow
        $stateChanged = $false

        if ([string]::IsNullOrEmpty($GlobalBandwidthLimit)) {
            try {
                if (Get-Command Get-EffectiveBandwidthLimitRate -ErrorAction SilentlyContinue) {
                    $GlobalBandwidthLimit = Get-EffectiveBandwidthLimitRate
                }
            } catch { }
        }

        # Step 1: Monitor active workers, leases, and progress
        foreach ($item in @($script:CloudTransferQueue)) {
            $status = [string]$item['Status']

            # Worker lease watchdog & abandoned job reclaim
            if ($status -eq 'Uploading') {
                $workerPid = if ($item.ContainsKey('WorkerPid')) { [int]$item['WorkerPid'] } else { 0 }
                $isProcessAlive = $false
                if ($workerPid -gt 0) {
                    try {
                        $p = [System.Diagnostics.Process]::GetProcessById($workerPid)
                        if (-not $p.HasExited) { $isProcessAlive = $true }
                    } catch {
                        $isProcessAlive = $false
                    }
                } elseif ($item.ContainsKey('JobId') -and $item['JobId'] -and $script:ActiveTransferJobs.ContainsKey([string]$item['JobId'])) {
                    $actJob = $script:ActiveTransferJobs[[string]$item['JobId']]
                    if ($actJob.Process -and -not $actJob.Process.HasExited) {
                        $isProcessAlive = $true
                    }
                }

                $leaseAge = 0.0
                if ($item.ContainsKey('WorkerLeaseUtc') -and ($item['WorkerLeaseUtc'] -is [DateTime])) {
                    $leaseAge = ($now - [DateTime]$item['WorkerLeaseUtc']).TotalSeconds
                }

                if (-not $isProcessAlive -and ($leaseAge -gt 60.0 -or ($workerPid -gt 0 -and -not $script:ActiveTransferJobs.ContainsKey([string]$item['JobId'])))) {
                    # Reclaim abandoned worker
                    $item['WorkerPid'] = 0
                    $item['WorkerLeaseUtc'] = $null
                    $retries = [int]$item['RetryCount']
                    $maxR = [int]$item['MaxRetries']
                    if ($retries -lt $maxR) {
                        $item['RetryCount'] = $retries + 1
                        $backoff = [Math]::Min(60.0, [Math]::Pow(2, [int]$item['RetryCount']))
                        $item['NextRetryUtc'] = $now.AddSeconds($backoff)
                        $item['Status'] = 'Waiting for network/provider'
                        $item['LastError'] = "Worker process disconnected. Reclaimed for retry."
                    } else {
                        $item['Status'] = 'Failed'
                        $item['LastError'] = "Worker process died and max retries exceeded."
                        $item['CompletedUtc'] = $now
                    }
                    $item['JobId'] = ''
                    $stateChanged = $true
                    continue
                }
            }

            if ($status -eq 'Uploading' -and -not [string]::IsNullOrEmpty([string]$item['JobId'])) {
                $jobId = [string]$item['JobId']
                $jobStatus = Get-CloudTransferStatus -JobId $jobId
                if ($null -ne $jobStatus) {
                    $item['Percentage'] = [double]$jobStatus.Percentage
                    $item['SmoothedSpeed'] = [double]$jobStatus.SmoothedSpeed
                    $item['EtaSeconds'] = $jobStatus.EtaSeconds
                    $item['BytesTransferred'] = [int64]$jobStatus.BytesTransferred
                    $item['WorkerLeaseUtc'] = $now
                    $item['LastProgressUtc'] = $now
                    if ($jobStatus.TotalBytes -gt 0L) {
                        $item['FileSizeBytes'] = [int64]$jobStatus.TotalBytes
                    }

                    if ($jobStatus.Status -eq 'Remotely confirmed' -or $jobStatus.VerificationStatus -eq 'Remotely confirmed') {
                        $item['Status'] = 'Completed and remotely confirmed'
                        $item['Percentage'] = 100.0
                        $item['CompletedUtc'] = [DateTime]::UtcNow
                        $item['WorkerPid'] = 0
                        if ($jobStatus.Contains('RemoteHash')) {
                            $item['RemoteHash'] = [string]$jobStatus.RemoteHash
                        }
                        if ($jobStatus.Contains('VerificationType')) {
                            $item['VerificationType'] = [string]$jobStatus.VerificationType
                        }
                        $stateChanged = $true
                    } elseif ($jobStatus.Status -eq 'Verifying remote file' -or $jobStatus.VerificationStatus -eq 'Verifying remote file') {
                        $item['Status'] = 'Awaiting remote confirmation'
                        $stateChanged = $true
                    } elseif ($jobStatus.Status -eq 'Failed' -or $jobStatus.VerificationStatus -eq 'Failed') {
                        $err = if ($jobStatus.LastError) { [string]$jobStatus.LastError } else { 'Transfer process failed' }
                        $item['LastError'] = $err
                        $item['WorkerPid'] = 0

                        $isPerm = Test-IsPermanentTransferError -ErrorMessage $err
                        $retries = [int]$item['RetryCount']
                        $maxR = [int]$item['MaxRetries']

                        if (-not $isPerm -and $retries -lt $maxR) {
                            $item['RetryCount'] = $retries + 1
                            $backoff = [Math]::Min(60.0, [Math]::Pow(2, [int]$item['RetryCount']))
                            $item['NextRetryUtc'] = $now.AddSeconds($backoff)
                            $item['Status'] = 'Waiting for network/provider'
                            $item['JobId'] = ''
                        } else {
                            $item['Status'] = 'Failed'
                            $item['CompletedUtc'] = [DateTime]::UtcNow
                        }
                        $stateChanged = $true
                    } elseif ($jobStatus.Status -eq 'Cancelled') {
                        $item['Status'] = 'Cancelled'
                        $item['CompletedUtc'] = [DateTime]::UtcNow
                        $item['WorkerPid'] = 0
                        $stateChanged = $true
                    }
                }
            } elseif ($status -in @('Awaiting remote confirmation', 'Upload pending remote confirmation', 'Verifying remote file')) {
                # Strict progression: transition to 'Verifying remote file'
                $item['Status'] = 'Verifying remote file'

                $destItemName = if ($item.ContainsKey('FileName') -and $item['FileName']) {
                    [string]$item['FileName']
                } elseif ($item['SourcePath'].Contains('/')) {
                    $item['SourcePath'].Substring($item['SourcePath'].LastIndexOf('/') + 1)
                } else {
                    [System.IO.Path]::GetFileName([string]$item['SourcePath'])
                }

                $destFullPath = if ($item.ContainsKey('DestinationFilePath') -and $item['DestinationFilePath']) {
                    [string]$item['DestinationFilePath']
                } elseif ($item.ContainsKey('DestinationPath') -and $item['DestinationPath']) {
                    "$($item['DestinationPath'])/$destItemName"
                } else {
                    $destItemName
                }

                $sourcePath = if ($item.ContainsKey('SourcePath')) { [string]$item['SourcePath'] } else { '' }
                $vRes = $null
                try {
                    $vRes = Test-RemoteCloudFileVerification -Account $item['DestinationAccount'] -RemotePath $destFullPath -ExpectedSizeBytes ([int64]$item['FileSizeBytes']) -LocalSourcePath $sourcePath
                } catch { }

                if ($vRes -and $vRes['Verified']) {
                    $item['Status'] = 'Completed and remotely confirmed'
                    $item['Percentage'] = 100.0
                    $item['CompletedUtc'] = [DateTime]::UtcNow
                    $item['WorkerPid'] = 0
                    if ($vRes.Contains('RemoteHash')) {
                        $item['RemoteHash'] = [string]$vRes['RemoteHash']
                    }
                    if ($vRes.Contains('VerificationType')) {
                        $item['VerificationType'] = [string]$vRes['VerificationType']
                    }
                    $stateChanged = $true
                } elseif ($vRes -and $vRes['Status'] -eq 'Failed') {
                    $retries = [int]$item['RetryCount']
                    $maxR = [int]$item['MaxRetries']
                    if ($retries -lt $maxR) {
                        $item['RetryCount'] = $retries + 1
                        $backoff = [Math]::Min(60.0, [Math]::Pow(2, [int]$item['RetryCount']))
                        $item['NextRetryUtc'] = $now.AddSeconds($backoff)
                        $item['Status'] = 'Waiting for network/provider'
                        $item['JobId'] = ''
                    } else {
                        $item['Status'] = 'Failed'
                        $item['LastError'] = [string]$vRes['Reason']
                        $item['CompletedUtc'] = [DateTime]::UtcNow
                    }
                    $stateChanged = $true
                } else {
                    $item['Status'] = 'Awaiting remote confirmation'
                }
            }
        }

        # Step 2: Concurrency Bounds (TeraBox destination: max 2, Google Drive: max 4)
        $tbActiveCount = @($script:CloudTransferQueue | Where-Object {
            $_['Status'] -in @('Uploading', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file') -and
            ($_.ContainsKey('DestinationAccount') -and $_['DestinationAccount'] -and ($_.DestinationAccount.ContainsKey('ProviderId')) -and $_['DestinationAccount']['ProviderId'] -eq 'terabox')
        }).Count

        $gdActiveCount = @($script:CloudTransferQueue | Where-Object {
            $_['Status'] -in @('Uploading', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file') -and
            ($_.ContainsKey('DestinationAccount') -and $_['DestinationAccount'] -and ($_.DestinationAccount.ContainsKey('ProviderId')) -and $_['DestinationAccount']['ProviderId'] -eq 'gdrive')
        }).Count

        $otherActiveCount = @($script:CloudTransferQueue | Where-Object {
            $_['Status'] -in @('Uploading', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file') -and
            ($_.ContainsKey('DestinationAccount') -and $_['DestinationAccount'] -and ($_.DestinationAccount.ContainsKey('ProviderId')) -and $_['DestinationAccount']['ProviderId'] -notin @('terabox', 'gdrive'))
        }).Count

        $totalActiveCount = $tbActiveCount + $gdActiveCount + $otherActiveCount

        # Step 3: Schedule next eligible queued items
        while ($totalActiveCount -lt $MaxConcurrent) {
            $eligible = $null
            foreach ($q in @($script:CloudTransferQueue)) {
                $canRun = $false
                if ($q['Status'] -eq 'Queued') {
                    $canRun = $true
                } elseif ($q['Status'] -eq 'Waiting for network/provider') {
                    $retryTime = if ($q.ContainsKey('NextRetryUtc') -and ($q['NextRetryUtc'] -is [DateTime])) { [DateTime]$q['NextRetryUtc'] } else { [DateTime]::MinValue }
                    if ($retryTime -le $now) {
                        $canRun = $true
                    }
                }

                if ($canRun) {
                    $destProv = if ($q.ContainsKey('DestinationAccount') -and $q['DestinationAccount'] -and ($q['DestinationAccount'].ContainsKey('ProviderId'))) { [string]$q['DestinationAccount']['ProviderId'] } else { 'gdrive' }
                    if ($destProv -eq 'terabox' -and $tbActiveCount -ge 2) {
                        continue # Bounded: TeraBox max 2 concurrent workers
                    }
                    if ($destProv -eq 'gdrive' -and $gdActiveCount -ge 4) {
                        continue # Bounded: Google Drive max 4 concurrent workers
                    }

                    $eligible = $q
                    break
                }
            }

            if (-not $eligible) {
                break
            }

            # Launch transfer for eligible item
            $eligible['Status'] = 'Uploading'
            $eligible['StartedUtc'] = [DateTime]::UtcNow
            $eligible['WorkerLeaseUtc'] = [DateTime]::UtcNow
            $eligible['LastProgressUtc'] = [DateTime]::UtcNow
            $eligibleBw = if ($eligible.ContainsKey('BandwidthLimit') -and $eligible['BandwidthLimit']) { [string]$eligible['BandwidthLimit'] } else { $GlobalBandwidthLimit }

            $destDirToPass = if ($eligible.ContainsKey('DestinationDirectory') -and $eligible['DestinationDirectory']) {
                [string]$eligible['DestinationDirectory']
            } elseif ($eligible.ContainsKey('DestinationPath')) {
                [string]$eligible['DestinationPath']
            } else {
                ''
            }

            try {
                $job = Start-CloudTransfer `
                    -SourceAccount $eligible['SourceAccount'] `
                    -SourcePath $eligible['SourcePath'] `
                    -DestinationAccount $eligible['DestinationAccount'] `
                    -DestinationPath $destDirToPass `
                    -ConflictAction $eligible['ConflictAction'] `
                    -IsMove:$eligible['IsMove'] `
                    -BandwidthLimit $eligibleBw

                $eligible['JobId'] = $job.JobId
                $eligible['WorkerPid'] = if ($job.Process) { $job.Process.Id } else { 0 }
                $totalActiveCount++
                $destProv = if ($eligible.ContainsKey('DestinationAccount') -and $eligible['DestinationAccount'] -and $eligible['DestinationAccount'].ContainsKey('ProviderId')) { [string]$eligible['DestinationAccount']['ProviderId'] } else { 'gdrive' }
                if ($destProv -eq 'terabox') { $tbActiveCount++ } else { $gdActiveCount++ }
                $stateChanged = $true
            } catch {
                $err = $_.Exception.Message
                $eligible['LastError'] = $err
                $eligible['WorkerPid'] = 0
                $isPerm = Test-IsPermanentTransferError -ErrorMessage $err
                $retries = [int]$eligible['RetryCount']
                $maxR = [int]$eligible['MaxRetries']

                if (-not $isPerm -and $retries -lt $maxR) {
                    $eligible['RetryCount'] = $retries + 1
                    $backoff = [Math]::Min(60.0, [Math]::Pow(2, [int]$eligible['RetryCount']))
                    $eligible['NextRetryUtc'] = [DateTime]::UtcNow.AddSeconds($backoff)
                    $eligible['Status'] = 'Waiting for network/provider'
                    $eligible['JobId'] = ''
                } else {
                    $eligible['Status'] = 'Failed'
                    $eligible['CompletedUtc'] = [DateTime]::UtcNow
                }
                $stateChanged = $true
            }
        }

        if ($stateChanged) {
            Save-DurableTransferQueue | Out-Null
        }

        return (Get-CloudTransferQueue)
    } finally {
        if ($hasMutexLock -and $schedulerMutex) {
            try { $schedulerMutex.ReleaseMutex() } catch { }
            try { $schedulerMutex.Dispose() } catch { }
        }
    }
}

function Stop-CloudTransferQueueItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueId
    )

    $item = $null
    foreach ($q in @($script:CloudTransferQueue)) {
        if ($q.ContainsKey('QueueId') -and $q['QueueId'] -eq $QueueId) {
            $item = $q
            break
        } elseif ($q.ContainsKey('JobId') -and $q['JobId'] -eq $QueueId) {
            $item = $q
            break
        }
    }
    if (-not $item) { return $false }

    if ($item.ContainsKey('JobId') -and $item['JobId']) {
        try {
            Stop-CloudTransfer -JobId [string]$item['JobId'] | Out-Null
        } catch { }
    }
    $item['Status'] = 'Cancelled'
    $item['CompletedUtc'] = [DateTime]::UtcNow
    $item['WorkerPid'] = 0
    Save-DurableTransferQueue | Out-Null
    return $true
}

function Clear-CloudTransferQueue {
    [CmdletBinding()]
    param(
        [switch]$All = $false
    )

    if ($All) {
        foreach ($item in @($script:CloudTransferQueue)) {
            if ($item.ContainsKey('JobId') -and $item['JobId'] -and $item['Status'] -in @('Uploading', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file')) {
                try { Stop-CloudTransfer -JobId [string]$item['JobId'] | Out-Null } catch { }
            }
        }
        $script:CloudTransferQueue.Clear()
    } else {
        $toRemove = @($script:CloudTransferQueue | Where-Object { $_['Status'] -in @('Completed and remotely confirmed', 'Failed', 'Cancelled') })
        foreach ($rem in $toRemove) {
            [void]$script:CloudTransferQueue.Remove($rem)
        }
    }

    Save-DurableTransferQueue | Out-Null
}

# Automatically load queue on module load if persistent state file exists
try {
    $initStateFile = Get-TransferQueueFilePath
    if (Test-Path -LiteralPath $initStateFile -PathType Leaf) {
        Load-DurableTransferQueue | Out-Null
    }
} catch { }
