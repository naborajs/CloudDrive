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
$script:TransferQueueStateUnavailable = $false
$script:TransferQueueFile = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\state\transfer-jobs.json')
$script:CustomTransferQueueFile = $null

# Staged revisions already confirmed on the provider, keyed by the same identity the
# pending summary uses. This is deliberately independent of queue jobs: clearing the
# completed list must not turn a preserved staged file back into a fresh upload.
$script:CloudTransferSettledStaged = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:CloudTransferSettledStagedLimit = 5000

function Get-CloudTransferFieldValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]$Item,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-CloudTransferSettledStagedEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Identity)

    if ([string]::IsNullOrEmpty($Identity)) { return $null }
    if ($script:CloudTransferSettledStaged.ContainsKey($Identity)) {
        return $script:CloudTransferSettledStaged[$Identity]
    }
    return $null
}

function Add-CloudTransferSettledStagedRevision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][int64]$Size,
        [Parameter(Mandatory = $true)][string]$LastWriteUtc
    )

    # A settlement without a revision timestamp cannot be matched safely, so it is
    # refused rather than stored as a wildcard.
    if ([string]::IsNullOrEmpty($Identity) -or [string]::IsNullOrWhiteSpace($LastWriteUtc)) { return }

    $script:CloudTransferSettledStaged[$Identity] = @{
        Size         = $Size
        LastWriteUtc = $LastWriteUtc
        ConfirmedUtc = [DateTime]::UtcNow.ToString('o')
    }

    if ($script:CloudTransferSettledStaged.Count -gt $script:CloudTransferSettledStagedLimit) {
        $excess = $script:CloudTransferSettledStaged.Count - $script:CloudTransferSettledStagedLimit
        $oldest = @($script:CloudTransferSettledStaged.GetEnumerator() |
            Sort-Object -Property @{ Expression = { [string]$_.Value.ConfirmedUtc } } |
            Select-Object -First $excess)
        foreach ($entry in $oldest) { [void]$script:CloudTransferSettledStaged.Remove($entry.Key) }
    }
}

function Update-CloudTransferSettledStagedLedger {
    [CmdletBinding()]
    param([object[]]$Jobs = @())

    foreach ($job in @($Jobs)) {
        if ($null -eq $job) { continue }
        if ([string](Get-CloudTransferFieldValue $job 'Status') -ne 'Completed and remotely confirmed') { continue }
        # Only adopted files need a durable settlement record; ordinary queue jobs keep
        # their own completed record and never leave a preserved staged source behind.
        if (-not [bool](Get-CloudTransferFieldValue $job 'RecoveredFromVfsCache')) { continue }

        $path = [string](Get-CloudTransferFieldValue $job 'DestinationFilePath')
        if ([string]::IsNullOrEmpty($path)) { $path = [string](Get-CloudTransferFieldValue $job 'RelativePath') }
        $accountId = [string](Get-CloudTransferFieldValue $job 'AccountId')
        $providerId = [string](Get-CloudTransferFieldValue $job 'ProviderId')
        $stagedWrite = [string](Get-CloudTransferFieldValue $job 'StagedSourceLastWriteUtc')
        if ([string]::IsNullOrEmpty($path) -or [string]::IsNullOrEmpty($accountId) -or [string]::IsNullOrWhiteSpace($stagedWrite)) { continue }

        $identity = Get-CloudTransferStagedIdentity -AccountId $accountId -ProviderId $providerId -RelativePath $path
        Add-CloudTransferSettledStagedRevision -Identity $identity `
            -Size ([int64](Get-CloudTransferFieldValue $job 'FileSizeBytes')) -LastWriteUtc $stagedWrite
    }
}

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

function Get-CloudTransferProviderId {
    [CmdletBinding()]
    param([AllowNull()][object]$Account)

    if ($null -eq $Account) { return '' }
    $provider = [string](Get-CloudTransferFieldValue $Account 'ProviderId')
    if ([string]::IsNullOrWhiteSpace($provider)) { return '' }
    return $provider.Trim().ToLowerInvariant()
}

function Get-CloudTransferPathIdentity {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Path = '',
        [bool]$IsLocal = $false
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ($IsLocal) {
        # Never call GetFullPath() on an rclone extended-length path: it rejects the
        # \\?\ prefix. Normalize the prefix first so identity stays stable.
        $localPath = $Path
        if ($localPath.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $localPath = '\\' + $localPath.Substring(8)
        } elseif ($localPath.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
            $localPath = $localPath.Substring(4)
        }
        try {
            return [System.IO.Path]::GetFullPath($localPath).TrimEnd('\', '/').ToUpperInvariant()
        } catch {
            return $localPath.Replace('\', '/').TrimEnd('/').ToUpperInvariant()
        }
    }
    return (Normalize-CloudPath -Path $Path).ToLowerInvariant()
}

function Resolve-CloudTransferOperation {
    <#
    .SYNOPSIS
    Resolves the intended transfer operation from explicit account providers.

    Direction is never inferred from a drive letter, file name, extension, UI label
    or working directory. If either endpoint provider is unknown, the result is
    invalid and the caller must pause the job for reconciliation instead of guessing.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$SourceAccount,
        [AllowEmptyString()][string]$SourcePath = '',
        [AllowNull()][object]$DestinationAccount,
        [AllowEmptyString()][string]$DestinationPath = '',
        [AllowEmptyString()][string]$DestinationFilePath = '',
        [AllowEmptyString()][string]$DeclaredOperationType = ''
    )

    $result = [ordered]@{
        IsValid             = $false
        OperationType       = 'Unknown'
        Direction           = 'Unknown'
        SourceProvider      = ''
        DestinationProvider = ''
        SourceAccountId     = ''
        DestinationAccountId = ''
        Reason              = ''
    }

    $result.SourceProvider = Get-CloudTransferProviderId $SourceAccount
    $result.DestinationProvider = Get-CloudTransferProviderId $DestinationAccount
    $result.SourceAccountId = [string](Get-CloudTransferFieldValue $SourceAccount 'Id')
    $result.DestinationAccountId = [string](Get-CloudTransferFieldValue $DestinationAccount 'Id')

    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        $result.Reason = 'Source path is missing; transfer direction cannot be established.'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($result.SourceProvider)) {
        $result.Reason = 'Source account provider is unknown; transfer direction cannot be established.'
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($result.DestinationProvider)) {
        $result.Reason = 'Destination account provider is unknown; transfer direction cannot be established.'
        return $result
    }

    $srcLocal = ($result.SourceProvider -eq 'local')
    $dstLocal = ($result.DestinationProvider -eq 'local')

    if ($srcLocal -and $dstLocal) {
        $result.Reason = 'Source and destination are both local; there is no cloud operation to perform.'
        return $result
    }

    if ($srcLocal) {
        $result.OperationType = 'Upload'
        $result.Direction = 'Upload'
    } elseif ($dstLocal) {
        if ([string]::IsNullOrWhiteSpace($DestinationPath) -and [string]::IsNullOrWhiteSpace($DestinationFilePath)) {
            $result.Reason = 'Download destination path is missing; transfer direction cannot be established.'
            return $result
        }
        $result.OperationType = 'Download'
        $result.Direction = 'Download'
    } else {
        $result.OperationType = 'CloudCopy'
        $result.Direction = 'CloudToCloud'
    }

    if (-not [string]::IsNullOrWhiteSpace($DeclaredOperationType) -and $DeclaredOperationType -ne 'Unknown') {
        if ($DeclaredOperationType -ne $result.OperationType) {
            $result.Reason = "Persisted operation '$DeclaredOperationType' does not match its endpoints (resolved '$($result.OperationType)')."
            $result.OperationType = 'Unknown'
            $result.Direction = 'Unknown'
            return $result
        }
    }

    $result.IsValid = $true
    return $result
}

function Get-CloudTransferJobOperation {
    <#
    .SYNOPSIS
    Resolves a persisted job's operation without path or drive-letter inference.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Job)

    $declared = [string](Get-CloudTransferFieldValue $Job 'OperationType')
    $sourceProvider = [string](Get-CloudTransferFieldValue $Job 'SourceProvider')
    $destinationProvider = [string](Get-CloudTransferFieldValue $Job 'DestinationProvider')
    if ([string]::IsNullOrWhiteSpace($sourceProvider)) {
        $sourceProvider = Get-CloudTransferProviderId (Get-CloudTransferFieldValue $Job 'SourceAccount')
    }
    if ([string]::IsNullOrWhiteSpace($destinationProvider)) {
        $destinationProvider = Get-CloudTransferProviderId (Get-CloudTransferFieldValue $Job 'DestinationAccount')
    }

    $sourceAccountId = [string](Get-CloudTransferFieldValue $Job 'SourceAccountId')
    if ([string]::IsNullOrWhiteSpace($sourceAccountId)) {
        $sourceAccountId = [string](Get-CloudTransferFieldValue (Get-CloudTransferFieldValue $Job 'SourceAccount') 'Id')
    }
    $destinationAccountId = [string](Get-CloudTransferFieldValue $Job 'DestinationAccountId')
    if ([string]::IsNullOrWhiteSpace($destinationAccountId)) {
        $destinationAccountId = [string](Get-CloudTransferFieldValue (Get-CloudTransferFieldValue $Job 'DestinationAccount') 'Id')
    }

    $sourcePath = [string](Get-CloudTransferFieldValue $Job 'SourcePath')
    $destinationDirectory = [string](Get-CloudTransferFieldValue $Job 'DestinationDirectory')
    if ([string]::IsNullOrWhiteSpace($destinationDirectory)) {
        $destinationDirectory = [string](Get-CloudTransferFieldValue $Job 'DestinationPath')
    }
    $destinationFilePath = [string](Get-CloudTransferFieldValue $Job 'DestinationFilePath')
    if ([string]::IsNullOrWhiteSpace($destinationFilePath)) {
        $fileName = [string](Get-CloudTransferFieldValue $Job 'FileName')
        if ($fileName) {
            $destinationFilePath = if ($destinationDirectory) { Normalize-CloudPath "$destinationDirectory/$fileName" } else { $fileName }
        }
    }

    $sourceStub = @{ Id = $sourceAccountId; ProviderId = $sourceProvider }
    $destinationStub = @{ Id = $destinationAccountId; ProviderId = $destinationProvider }

    return Resolve-CloudTransferOperation `
        -SourceAccount $sourceStub `
        -SourcePath $sourcePath `
        -DestinationAccount $destinationStub `
        -DestinationPath $destinationDirectory `
        -DestinationFilePath $destinationFilePath `
        -DeclaredOperationType $declared
}

function Get-CloudTransferLogicalKey {
    [CmdletBinding()]
    param(
        [ValidateSet('Upload', 'Download', 'CloudCopy', 'Unknown')][string]$OperationType = 'Unknown',
        [string]$SourceProvider = '',
        [string]$SourceAccountId = '',
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$DestinationProvider = '',
        [string]$DestinationAccountId = '',
        [Parameter(Mandatory = $true)][string]$DestinationFilePath,
        [int64]$FileSizeBytes = 0L,
        [string]$SourceLastWriteUtc = ''
    )

    $sourceIsLocal = ($SourceProvider -eq 'local')
    $destinationIsLocal = ($DestinationProvider -eq 'local')
    $sourceIdentity = Get-CloudTransferPathIdentity -Path $SourcePath -IsLocal $sourceIsLocal
    $destinationIdentity = Get-CloudTransferPathIdentity -Path $DestinationFilePath -IsLocal $destinationIsLocal
    $seed = @(
        $OperationType.ToLowerInvariant(),
        $SourceProvider.ToLowerInvariant(),
        $SourceAccountId.ToLowerInvariant(),
        $sourceIdentity,
        $DestinationProvider.ToLowerInvariant(),
        $DestinationAccountId.ToLowerInvariant(),
        $destinationIdentity,
        [string]$FileSizeBytes,
        $SourceLastWriteUtc
    ) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($seed)
        $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
        return $hash
    } finally { $sha.Dispose() }
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

    $providerId = Get-CloudTransferProviderId $Account
    if ([string]::IsNullOrWhiteSpace($providerId)) { $providerId = 'gdrive' }
    $accountId = [string](Get-CloudTransferFieldValue $Account 'Id')
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

    $providerId = Get-CloudTransferProviderId $Account
    if ([string]::IsNullOrWhiteSpace($providerId)) { $providerId = 'gdrive' }
    $accountId = [string](Get-CloudTransferFieldValue $Account 'Id')

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

    $providerId = Get-CloudTransferProviderId $Account
    if ([string]::IsNullOrWhiteSpace($providerId)) { $providerId = 'gdrive' }
    $accountId = [string](Get-CloudTransferFieldValue $Account 'Id')

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

    $providerId = Get-CloudTransferProviderId $Account
    if ([string]::IsNullOrWhiteSpace($providerId)) { $providerId = 'gdrive' }
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

        # Explicit persisted intent. When supplied, it is validated against the
        # account providers; it never overrides them.
        [ValidateSet('Upload', 'Download', 'CloudCopy', '')]
        [string]$OperationType = '',

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

    # Pre-flight check on destination account plan and file size limits.
    # A local destination has no provider upload plan to check.
    if ($DestinationAccount -and (Get-CloudTransferProviderId $DestinationAccount) -ne 'local') {
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

    $operation = Resolve-CloudTransferOperation `
        -SourceAccount $SourceAccount `
        -SourcePath $SourcePath `
        -DestinationAccount $DestinationAccount `
        -DestinationPath $DestinationPath `
        -DestinationFilePath $DestinationPath `
        -DeclaredOperationType $OperationType
    if (-not $operation.IsValid) {
        throw "Transfer direction could not be resolved safely: $($operation.Reason)"
    }

    # Local endpoints come from the account provider only. A drive letter, file
    # extension or a path that happens to exist locally must never flip direction.
    $srcIsLocal = ($operation.SourceProvider -eq 'local')
    $dstIsLocal = ($operation.DestinationProvider -eq 'local')

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

    $isLoopbackStaging = ((Get-CloudTransferProviderId $DestinationAccount) -eq 'terabox')

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
                if ($job.VerificationStatus -ne 'Remotely confirmed' -and $job.Status -notin @('Failed', 'Awaiting remote confirmation') -and $job.Status -notlike 'Needs attention*') {
                    $job.Status = 'Verifying remote file'
                    $job.VerificationStatus = 'Verifying remote file'
                    $cleanItemName = [System.IO.Path]::GetFileName([string]$job.SourcePath.Replace('/', '\').TrimEnd('\'))
                    $destItemName = if ($cleanItemName) { $cleanItemName } else { [string]$job.SourcePath }
                    $destFullPath = if ($job.DestinationPath) { Normalize-CloudPath "$($job.DestinationPath)/$destItemName" } else { $destItemName }
                    $localSource = [string](Get-CloudTransferFieldValue $job 'SourcePath')
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
                        $job.Status = 'Awaiting remote confirmation'
                        $job.VerificationStatus = 'Awaiting remote confirmation'
                        $job.LastError = if ($vRes -and $vRes['Reason']) { [string]$vRes['Reason'] } else { 'Remote state is temporarily unknown.' }
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
        SourceAccount = if ($job.SourceAccount) {
            $name = [string](Get-CloudTransferFieldValue $job.SourceAccount 'DisplayName')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-CloudTransferFieldValue $job.SourceAccount 'Id') }
            $name
        } else { '' }
        DestinationAccount = if ($job.DestinationAccount) {
            $name = [string](Get-CloudTransferFieldValue $job.DestinationAccount 'DisplayName')
            if ([string]::IsNullOrWhiteSpace($name)) { $name = [string](Get-CloudTransferFieldValue $job.DestinationAccount 'Id') }
            $name
        } else { '' }
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
        RemoteHash = [string](Get-CloudTransferFieldValue $job 'RemoteHash')
        VerificationType = [string](Get-CloudTransferFieldValue $job 'VerificationType')
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
    if ($ErrorMessage -match '(?i)(quota exceeded|quotaExceeded|rateLimitExceeded|userRateLimitExceeded|resource_exhausted|too many requests|HTTP 429)') {
        return $false
    }
    if ($ErrorMessage -match '(?i)(invalid_grant|invalid credentials|unauthorized|authentication failed|permission denied|exceeds.*TeraBox.*plan limit|PlanFileLimit|403 Forbidden|404 Not Found|invalid character|file name too long|access denied|is a directory|illegal character|cannot find the path)') {
        return $true
    }
    return $false
}

function Get-TransferRetryDelaySeconds {
    [CmdletBinding()]
    param(
        [int]$RetryCount = 0,
        [string]$ErrorMessage = ''
    )

    if ($ErrorMessage -match '(?i)Retry-After\s*[:=]\s*(\d+)') {
        return [Math]::Max(1.0, [Math]::Min(3600.0, [double]$Matches[1]))
    }
    $exponent = [Math]::Max(0, [Math]::Min(9, $RetryCount))
    return [Math]::Min(300.0, [Math]::Pow(2.0, $exponent))
}

# ==============================================================================
# DURABLE QUEUE PERSISTENCE (transfer-jobs.json)
# ==============================================================================

function ConvertTo-TransferAccountSnapshot {
    [CmdletBinding()]
    param([AllowNull()][object]$Account)

    if ($null -eq $Account) { return @{} }
    $snapshot = @{}
    $entries = if ($Account -is [System.Collections.IDictionary]) {
        $Account.GetEnumerator() | ForEach-Object { @{ Name = [string]$_.Key; Value = $_.Value } }
    } else {
        $Account.PSObject.Properties | ForEach-Object { @{ Name = [string]$_.Name; Value = $_.Value } }
    }
    foreach ($entry in $entries) {
        if ($entry.Name -match '(?i)(token|secret|password|pass|cookie|ndus|ndut|authorization|credential|private.?key)') { continue }
        $value = $entry.Value
        if ($null -eq $value -or $value -is [string] -or $value.GetType().IsValueType) {
            $snapshot[$entry.Name] = $value
        } elseif ($value -is [System.Collections.IDictionary] -or $value -is [pscustomobject]) {
            $snapshot[$entry.Name] = ConvertTo-TransferAccountSnapshot -Account $value
        } elseif ($value -is [System.Array] -or $value -is [System.Collections.IList]) {
            $safeItems = [System.Collections.Generic.List[object]]::new()
            foreach ($child in $value) {
                if ($child -is [System.Collections.IDictionary] -or $child -is [pscustomobject]) {
                    $safeItems.Add((ConvertTo-TransferAccountSnapshot -Account $child))
                } elseif ($null -eq $child -or $child -is [string] -or $child.GetType().IsValueType) {
                    $safeItems.Add($child)
                }
            }
            $snapshot[$entry.Name] = $safeItems.ToArray()
        }
    }
    return $snapshot
}

function Resolve-TransferAccountSnapshot {
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary]$Snapshot)

    if ($null -eq $Snapshot) { return @{} }
    $accountId = [string](Get-CloudTransferFieldValue $Snapshot 'Id')
    if ($accountId -and (Get-Command Get-CloudAccount -ErrorAction SilentlyContinue)) {
        try {
            $storedAccount = Get-CloudAccount -AccountId $accountId
            if ($storedAccount) { return $storedAccount }
        } catch { }
    }
    return $Snapshot
}

function Set-TransferStateInitializedMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$QueuePath)

    $markerPath = "$QueuePath.initialized"
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) { return $true }
    $markerDir = [System.IO.Path]::GetDirectoryName($markerPath)
    if ($markerDir -and -not (Test-Path -LiteralPath $markerDir -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($markerDir)
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($markerPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("NSCloudDrive transfer state initialized `n$([DateTime]::UtcNow.ToString('o'))`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        return $true
    } catch [System.IO.IOException] {
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) { return $true }
        throw
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

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

        # Persist the resolved operation even for legacy records that predate it.
        $jobOperation = Get-CloudTransferJobOperation -Job $item
        $storedOperationType = if ($item.ContainsKey('OperationType') -and $item['OperationType']) { [string]$item['OperationType'] } elseif ($jobOperation.IsValid) { [string]$jobOperation.OperationType } else { 'Unknown' }
        $storedDirection = if ($item.ContainsKey('Direction') -and $item['Direction']) { [string]$item['Direction'] } elseif ($jobOperation.IsValid) { [string]$jobOperation.Direction } else { 'Unknown' }

        $jH = [ordered]@{
            JobId = $jId
            QueueId = $qId
            BatchId = if ($item.ContainsKey('BatchId')) { [string]$item['BatchId'] } else { '' }
            BatchName = if ($item.ContainsKey('BatchName')) { [string]$item['BatchName'] } else { '' }
            TransferKey = if ($item.ContainsKey('TransferKey')) { [string]$item['TransferKey'] } else { '' }
            OperationType = $storedOperationType
            Direction = $storedDirection
            SourceProvider = if ($item.ContainsKey('SourceProvider')) { [string]$item['SourceProvider'] } else { [string]$jobOperation.SourceProvider }
            DestinationProvider = if ($item.ContainsKey('DestinationProvider')) { [string]$item['DestinationProvider'] } else { [string]$jobOperation.DestinationProvider }
            SourceAccountId = if ($item.ContainsKey('SourceAccountId')) { [string]$item['SourceAccountId'] } else { [string]$jobOperation.SourceAccountId }
            DestinationAccountId = if ($item.ContainsKey('DestinationAccountId')) { [string]$item['DestinationAccountId'] } else { [string]$jobOperation.DestinationAccountId }
            Origin = if ($item.ContainsKey('Origin')) { [string]$item['Origin'] } else { 'Legacy' }
            PreviousJobId = if ($item.ContainsKey('PreviousJobId')) { [string]$item['PreviousJobId'] } else { '' }
            ReconciliationStatus = if ($item.ContainsKey('ReconciliationStatus')) { [string]$item['ReconciliationStatus'] } else { 'None' }
            StatusBeforeReconciliation = if ($item.ContainsKey('StatusBeforeReconciliation')) { [string]$item['StatusBeforeReconciliation'] } else { '' }
            # Staged-cache adoption linkage. Without these fields a restart would lose
            # the evidence needed to match a confirmed upload to its staged revision.
            StagedSourcePath = if ($item.ContainsKey('StagedSourcePath')) { [string]$item['StagedSourcePath'] } else { '' }
            StagedSourceLastWriteUtc = if ($item.ContainsKey('StagedSourceLastWriteUtc')) { [string]$item['StagedSourceLastWriteUtc'] } else { '' }
            RecoveredFromVfsCache = if ($item.ContainsKey('RecoveredFromVfsCache')) { [bool]$item['RecoveredFromVfsCache'] } else { $false }
            RecoveryBatchId = if ($item.ContainsKey('RecoveryBatchId')) { [string]$item['RecoveryBatchId'] } else { '' }
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
            VerificationRetryCount = if ($item.ContainsKey('VerificationRetryCount')) { [int]$item['VerificationRetryCount'] } else { 0 }
            MaxRetries = if ($item.ContainsKey('MaxRetries')) { [int]$item['MaxRetries'] } else { 3 }
            NextRetryUtc = $nextRetryStr
            LastError = if ($item.ContainsKey('LastError')) { [string]$item['LastError'] } else { '' }
            EnqueuedUtc = $enqueuedStr
            SourceLastWriteUtc = if ($item.ContainsKey('SourceLastWriteUtc')) { [string]$item['SourceLastWriteUtc'] } else { '' }
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
            SourceAccount = if ($item.ContainsKey('SourceAccount')) { ConvertTo-TransferAccountSnapshot -Account $item['SourceAccount'] } else { @{} }
            DestinationAccount = if ($item.ContainsKey('DestinationAccount')) { ConvertTo-TransferAccountSnapshot -Account $item['DestinationAccount'] } else { @{} }
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

    # Capture settlement evidence before the caller can drop completed jobs.
    Update-CloudTransferSettledStagedLedger -Jobs @($script:CloudTransferQueue)

    $payload = [ordered]@{
        Version = '2.0'
        LastUpdatedUtc = [DateTime]::UtcNow.ToString('o')
        ActiveBatchId = $activeBatchId
        Jobs = $jobsList.ToArray()
        SettledStagedRevisions = @($script:CloudTransferSettledStaged.GetEnumerator() | ForEach-Object {
            [ordered]@{
                Identity     = [string]$_.Key
                Size         = [int64]$_.Value.Size
                LastWriteUtc = [string]$_.Value.LastWriteUtc
                ConfirmedUtc = [string]$_.Value.ConfirmedUtc
            }
        })
    }

    $json = $payload | ConvertTo-Json -Depth 10

    # Write in the destination directory so replacement stays on one volume.
    $tmpFile = "$targetFile.$([Guid]::NewGuid().ToString('N')).tmp"
    $backupFile = "$targetFile.bak.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tmpFile, $json, [System.Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $targetFile) {
            $existingIsValid = $false
            try {
                $existing = [System.IO.File]::ReadAllText($targetFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                $existingIsValid = ($existing -and $existing.PSObject.Properties['Jobs'])
            } catch { }

            if ($existingIsValid) {
                # File.Replace creates this versioned backup and swaps the new file
                # atomically. Backups are retained so a prior valid state is recoverable.
            } else {
                $backupIsValid = $false
                $backupCandidates = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($targetFile)) -Filter (([System.IO.Path]::GetFileName($targetFile)) + '.bak.*') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
                foreach ($backupCandidate in $backupCandidates) {
                    try {
                        $backup = [System.IO.File]::ReadAllText($backupCandidate.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                        if ($backup -and $backup.PSObject.Properties['Jobs']) { $backupIsValid = $true; break }
                    } catch { }
                }
                if (-not $backupIsValid -and (Test-Path -LiteralPath "$targetFile.bak" -PathType Leaf)) {
                    try {
                        $backup = [System.IO.File]::ReadAllText("$targetFile.bak", [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
                        $backupIsValid = ($backup -and $backup.PSObject.Properties['Jobs'])
                    } catch { }
                }
                if (-not $backupIsValid) {
                    throw "Refusing to replace unreadable transfer state without a valid backup: $targetFile"
                }
                $corruptFile = "$targetFile.corrupt.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).$([Guid]::NewGuid().ToString('N'))"
                $backupFile = $corruptFile
            }
            # File.Replace is atomic on the supported local Windows filesystems. If it fails,
            # keep the old primary and backup and report the persistence failure.
            [System.IO.File]::Replace($tmpFile, $targetFile, $backupFile)
        } else {
            [System.IO.File]::Move($tmpFile, $targetFile)
        }
        Set-TransferStateInitializedMarker -QueuePath $targetFile | Out-Null
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
    $candidates = @()
    if (Test-Path -LiteralPath $targetFile -PathType Leaf) { $candidates += $targetFile }
    if (Test-Path -LiteralPath "$targetFile.bak" -PathType Leaf) { $candidates += "$targetFile.bak" }
    $versionedBackups = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($targetFile)) -Filter (([System.IO.Path]::GetFileName($targetFile)) + '.bak.*') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($versionedBackup in $versionedBackups) { $candidates += $versionedBackup.FullName }
    if ($candidates.Count -eq 0) {
        $markerPath = "$targetFile.initialized"
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            throw "Transfer state is missing even though this installation previously initialized it. Queue and backups were not recreated: $targetFile"
        }
        # A first-run empty queue is valid, but mark that fact so later disappearance
        # of every durable snapshot is reported as state loss rather than empty work.
        Set-TransferStateInitializedMarker -QueuePath $targetFile | Out-Null
        return 0
    }

    $parsed = $null
    $selectedFile = ''
    $readErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        try {
            $jsonText = [System.IO.File]::ReadAllText($candidate, [System.Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($jsonText)) { throw 'State file is empty.' }
            $candidatePayload = $jsonText | ConvertFrom-Json -ErrorAction Stop
            if (-not $candidatePayload -or -not $candidatePayload.PSObject.Properties['Jobs']) {
                throw 'State file has no Jobs collection.'
            }
            if ($candidatePayload.Jobs -isnot [System.Array] -and $candidatePayload.Jobs -isnot [System.Collections.IList]) {
                throw 'State file Jobs collection is not an array.'
            }
            if ($candidatePayload.PSObject.Properties['Version'] -and [string]$candidatePayload.Version -notin @('1.0', '2.0')) {
                throw "Unsupported transfer-state schema version '$($candidatePayload.Version)'."
            }
            $parsed = $candidatePayload
            $selectedFile = $candidate
            break
        } catch {
            $readErrors.Add((Split-Path -Leaf $candidate) + ': ' + $_.Exception.Message)
        }
    }
    if (-not $parsed) {
        throw "Unable to read durable transfer state. Primary and backup were preserved. $($readErrors -join '; ')"
    }
    if ($selectedFile -ne $targetFile -and (Get-Command Write-NSCloudLog -ErrorAction SilentlyContinue)) {
        try { Write-NSCloudLog -Severity 'Warning' -Operation 'transfer-state-recovery' -Message 'Primary transfer state was unreadable; loaded the preserved backup.' } catch { }
    }

    # Build the complete replacement in isolation. A malformed record must not leave a partial queue.
    $loadedItems = [System.Collections.Generic.List[hashtable]]::new()
    $loadedCount = 0

    foreach ($j in @($parsed.Jobs)) {
        $jId = if ($j.PSObject.Properties['JobId'] -and $j.JobId) { [string]$j.JobId } elseif ($j.PSObject.Properties['QueueId'] -and $j.QueueId) { [string]$j.QueueId } else { throw 'Transfer record has no stable JobId or QueueId.' }
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
            TransferKey = if ($j.PSObject.Properties['TransferKey'] -and $j.TransferKey) { [string]$j.TransferKey } else { '' }
            OperationType = if ($j.PSObject.Properties['OperationType'] -and $j.OperationType) { [string]$j.OperationType } else { '' }
            Direction = if ($j.PSObject.Properties['Direction'] -and $j.Direction) { [string]$j.Direction } else { '' }
            SourceProvider = if ($j.PSObject.Properties['SourceProvider'] -and $j.SourceProvider) { [string]$j.SourceProvider } else { '' }
            DestinationProvider = if ($j.PSObject.Properties['DestinationProvider'] -and $j.DestinationProvider) { [string]$j.DestinationProvider } else { '' }
            SourceAccountId = if ($j.PSObject.Properties['SourceAccountId'] -and $j.SourceAccountId) { [string]$j.SourceAccountId } else { '' }
            DestinationAccountId = if ($j.PSObject.Properties['DestinationAccountId'] -and $j.DestinationAccountId) { [string]$j.DestinationAccountId } else { '' }
            Origin = if ($j.PSObject.Properties['Origin'] -and $j.Origin) { [string]$j.Origin } else { 'Legacy' }
            PreviousJobId = if ($j.PSObject.Properties['PreviousJobId'] -and $j.PreviousJobId) { [string]$j.PreviousJobId } else { '' }
            ReconciliationStatus = if ($j.PSObject.Properties['ReconciliationStatus'] -and $j.ReconciliationStatus) { [string]$j.ReconciliationStatus } else { 'None' }
            StatusBeforeReconciliation = if ($j.PSObject.Properties['StatusBeforeReconciliation'] -and $j.StatusBeforeReconciliation) { [string]$j.StatusBeforeReconciliation } else { '' }
            StagedSourcePath = if ($j.PSObject.Properties['StagedSourcePath'] -and $j.StagedSourcePath) { [string]$j.StagedSourcePath } else { '' }
            StagedSourceLastWriteUtc = if ($j.PSObject.Properties['StagedSourceLastWriteUtc'] -and $j.StagedSourceLastWriteUtc) { [string]$j.StagedSourceLastWriteUtc } else { '' }
            RecoveredFromVfsCache = if ($j.PSObject.Properties['RecoveredFromVfsCache']) { [bool]$j.RecoveredFromVfsCache } else { $false }
            RecoveryBatchId = if ($j.PSObject.Properties['RecoveryBatchId'] -and $j.RecoveryBatchId) { [string]$j.RecoveryBatchId } else { '' }
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
            VerificationRetryCount = if ($j.PSObject.Properties['VerificationRetryCount']) { [int]$j.VerificationRetryCount } else { 0 }
            MaxRetries = if ($j.PSObject.Properties['MaxRetries']) { [int]$j.MaxRetries } else { 3 }
            NextRetryUtc = $nextRetry
            LastError = if ($j.PSObject.Properties['LastError'] -and $j.LastError) { [string]$j.LastError } else { '' }
            EnqueuedUtc = $enqueued
            SourceLastWriteUtc = if ($j.PSObject.Properties['SourceLastWriteUtc'] -and $j.SourceLastWriteUtc) { [string]$j.SourceLastWriteUtc } else { '' }
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
            SourceAccount = Resolve-TransferAccountSnapshot -Snapshot $srcAcc
            DestinationAccount = Resolve-TransferAccountSnapshot -Snapshot $dstAcc
            RemoteHash = if ($j.PSObject.Properties['RemoteHash'] -and $j.RemoteHash) { [string]$j.RemoteHash } else { '' }
            VerificationType = if ($j.PSObject.Properties['VerificationType'] -and $j.VerificationType) { [string]$j.VerificationType } else { '' }
        })

        # Migration + fail-closed validation. Legacy records may predate the explicit
        # operation field; resolve it from the persisted account providers only. If an
        # endpoint provider is missing, the job is preserved but never scheduled with
        # a guessed direction.
        $jobOperation = Get-CloudTransferJobOperation -Job $item
        if ($jobOperation.IsValid) {
            if ([string]::IsNullOrWhiteSpace([string]$item['OperationType']) -or [string]$item['OperationType'] -eq 'Unknown') {
                $item['OperationType'] = [string]$jobOperation.OperationType
            }
            if ([string]::IsNullOrWhiteSpace([string]$item['Direction']) -or [string]$item['Direction'] -eq 'Unknown') {
                $item['Direction'] = [string]$jobOperation.Direction
            }
            if ([string]::IsNullOrWhiteSpace([string]$item['SourceProvider'])) { $item['SourceProvider'] = [string]$jobOperation.SourceProvider }
            if ([string]::IsNullOrWhiteSpace([string]$item['DestinationProvider'])) { $item['DestinationProvider'] = [string]$jobOperation.DestinationProvider }
            if ([string]::IsNullOrWhiteSpace([string]$item['SourceAccountId'])) { $item['SourceAccountId'] = [string]$jobOperation.SourceAccountId }
            if ([string]::IsNullOrWhiteSpace([string]$item['DestinationAccountId'])) { $item['DestinationAccountId'] = [string]$jobOperation.DestinationAccountId }
            if ([string]$item['ReconciliationStatus'] -eq 'Required' -and [string]$item['StatusBeforeReconciliation']) {
                # A previous load marked this record unresolved; the endpoints are now
                # complete again, so restore the preserved pre-reconciliation state.
                $item['Status'] = [string]$item['StatusBeforeReconciliation']
                $item['StatusBeforeReconciliation'] = ''
                $item['ReconciliationStatus'] = 'None'
                $item['LastError'] = ''
            }
        } else {
            # "Both local" is not a cloud operation, but local paths may be used as
            # stand-ins for remote storage. Preserve the original status so startup
            # recovery can attempt direct destination verification.
            $isBothLocal = [string]$jobOperation.Reason -match '(?i)both local'
            if (-not $isBothLocal) {
                $terminalStatuses = @('Completed and remotely confirmed', 'Completed', 'Failed', 'Cancelled', 'Superseded')
                if ([string]$item['Status'] -notin $terminalStatuses) {
                    if ([string]::IsNullOrWhiteSpace([string]$item['StatusBeforeReconciliation'])) {
                        $item['StatusBeforeReconciliation'] = [string]$item['Status']
                    }
                    $item['Status'] = 'Needs reconciliation: operation unresolved'
                    $item['ReconciliationStatus'] = 'Required'
                    $item['LastError'] = [string]$jobOperation.Reason
                    $item['WorkerPid'] = 0
                    $item['WorkerLeaseUtc'] = $null
                    $item['JobId'] = ''
                }
            }
        }

        $loadedItems.Add($item)
        $loadedCount++
    }

    $script:CloudTransferQueue.Clear()
    foreach ($loadedItem in $loadedItems) { [void]$script:CloudTransferQueue.Add($loadedItem) }

    # Settlement evidence is part of durable state; reload it with the jobs so a restart
    # cannot resurrect a preserved staged file that was already verified on the provider.
    $script:CloudTransferSettledStaged.Clear()
    if ($parsed.PSObject.Properties['SettledStagedRevisions'] -and $parsed.SettledStagedRevisions) {
        foreach ($entry in @($parsed.SettledStagedRevisions)) {
            if ($null -eq $entry) { continue }
            $entryIdentity = [string](Get-CloudTransferFieldValue $entry 'Identity')
            $entryWrite = [string](Get-CloudTransferFieldValue $entry 'LastWriteUtc')
            if ([string]::IsNullOrEmpty($entryIdentity) -or [string]::IsNullOrWhiteSpace($entryWrite)) { continue }
            $entrySize = [int64](Get-CloudTransferFieldValue $entry 'Size')
            $script:CloudTransferSettledStaged[$entryIdentity] = @{
                Size         = $entrySize
                LastWriteUtc = $entryWrite
                ConfirmedUtc = [string](Get-CloudTransferFieldValue $entry 'ConfirmedUtc')
            }
        }
    }

    Set-TransferStateInitializedMarker -QueuePath $targetFile | Out-Null

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

    $srcAccId = [string](Get-CloudTransferFieldValue $SourceAccount 'Id')
    $srcProvId = Get-CloudTransferProviderId $SourceAccount
    if ([string]::IsNullOrWhiteSpace($srcProvId)) { $srcProvId = 'local' }
    $dstAccId = [string](Get-CloudTransferFieldValue $DestinationAccount 'Id')
    $dstProvId = Get-CloudTransferProviderId $DestinationAccount
    if ([string]::IsNullOrWhiteSpace($dstProvId)) { $dstProvId = 'gdrive' }

    # Streaming recursive enumeration using [System.IO.Directory]::EnumerateFiles
    # Avoids loading entire tree into memory for folders with thousands of files
    $filesEnumerate = [System.IO.Directory]::EnumerateFiles($cleanSourceRoot, '*', [System.IO.SearchOption]::AllDirectories)
    $createdJobs = [System.Collections.Generic.List[hashtable]]::new()
    $knownTransferKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($existingJob in @($script:CloudTransferQueue)) {
        $tk = [string](Get-CloudTransferFieldValue $existingJob 'TransferKey')
        if ($tk) {
            $knownTransferKeys.Add($tk) | Out-Null
        }
    }
    $totalBatchBytes = 0L
    $totalFilesScanned = 0
    $alreadyTrackedCount = 0

    foreach ($filePath in $filesEnumerate) {
        $fi = [System.IO.FileInfo]::new($filePath)
        $fileSize = [int64]$fi.Length
        $totalBatchBytes += $fileSize
        $totalFilesScanned++
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

        $sourceLastWriteUtc = $fi.LastWriteTimeUtc.ToString('o')
        $transferKey = Get-CloudTransferLogicalKey `
            -OperationType 'Upload' `
            -SourceProvider 'local' `
            -SourceAccountId $srcAccId `
            -SourcePath $filePath `
            -DestinationProvider $dstProvId `
            -DestinationAccountId $dstAccId `
            -DestinationFilePath $cleanDest `
            -FileSizeBytes $fileSize `
            -SourceLastWriteUtc $sourceLastWriteUtc
        if (-not $knownTransferKeys.Add($transferKey)) {
            $alreadyTrackedCount++
            continue
        }

        $jobId = "job_$transferKey"
        $jobItem = [hashtable]::Synchronized(@{
            JobId = $jobId
            QueueId = $jobId
            TransferKey = $transferKey
            SourceLastWriteUtc = $sourceLastWriteUtc
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
            VerificationRetryCount = 0
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

    # Persist the complete batch before returning confirmation. If persistence fails,
    # remove only the new in-memory records; the local source files remain untouched.
    try {
        Save-DurableTransferQueue | Out-Null
    } catch {
        foreach ($created in $createdJobs) { [void]$script:CloudTransferQueue.Remove($created) }
        throw
    }

    return [ordered]@{
        BatchId = $batchId
        BatchName = $batchName
        TotalFiles = $totalFilesScanned
        NewlyQueuedFiles = $createdJobs.Count
        AlreadyTrackedFiles = $alreadyTrackedCount
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

function Get-CloudTransferJobDestinationPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Job)

    $destItemName = [string](Get-CloudTransferFieldValue $Job 'FileName')
    if ([string]::IsNullOrWhiteSpace($destItemName)) {
        $sourcePath = [string](Get-CloudTransferFieldValue $Job 'SourcePath')
        if ($sourcePath.Contains('/')) {
            $destItemName = $sourcePath.Substring($sourcePath.LastIndexOf('/') + 1)
        } else {
            $destItemName = [System.IO.Path]::GetFileName($sourcePath)
        }
    }

    $destinationFilePath = [string](Get-CloudTransferFieldValue $Job 'DestinationFilePath')
    if (-not [string]::IsNullOrWhiteSpace($destinationFilePath)) { return $destinationFilePath }

    $destinationPath = [string](Get-CloudTransferFieldValue $Job 'DestinationPath')
    if (-not [string]::IsNullOrWhiteSpace($destinationPath)) {
        return "$destinationPath/$destItemName"
    }
    return $destItemName
}

function Test-CloudTransferJobDestination {
    <#
    .SYNOPSIS
    Verifies the intended destination of a persisted job.

    Uploads and cloud copies verify the remote object. Downloads verify the local
    file. The operation comes from the persisted record, never from the path shape.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Job)

    $operation = Get-CloudTransferJobOperation -Job $Job
    if (-not $operation.IsValid) { return $null }

    $destinationPath = Get-CloudTransferJobDestinationPath -Job $Job
    $size = [int64](Get-CloudTransferFieldValue $Job 'FileSizeBytes')
    $sourcePath = [string](Get-CloudTransferFieldValue $Job 'SourcePath')
    $destinationAccount = Get-CloudTransferFieldValue $Job 'DestinationAccount'

    if ($operation.OperationType -eq 'Download') {
        return Test-RemoteCloudFileVerification -Account $destinationAccount -RemotePath $destinationPath -ExpectedSizeBytes $size -LocalSourcePath ''
    }
    return Test-RemoteCloudFileVerification -Account $destinationAccount -RemotePath $destinationPath -ExpectedSizeBytes $size -LocalSourcePath $sourcePath
}

function Invoke-StartupTransferQueueRecovery {
    [CmdletBinding()]
    param()

    # Load persistent queue from disk
    $null = Load-DurableTransferQueue
    $script:TransferQueueStateUnavailable = $false
    $recoveredCount = 0
    $confirmedCount = 0
    $resetCount = 0
    $reconciliationCount = 0

    $now = [DateTime]::UtcNow
    foreach ($item in @($script:CloudTransferQueue)) {
        $status = [string]$item['Status']
        if ($status -in @('Completed and remotely confirmed', 'Completed', 'Failed', 'Cancelled', 'Superseded')) { continue }

        $jobOperation = Get-CloudTransferJobOperation -Job $item
        $skipOperationValidation = $false
        if (-not $jobOperation.IsValid) {
            # A local-to-local record is not a cloud operation, but the test harness
            # and some legacy flows use local paths as stand-ins for remote storage.
            # Attempt direct destination verification before marking for reconciliation.
            $isBothLocal = [string]$jobOperation.Reason -match '(?i)both local'
            if ($isBothLocal) {
                $vRes = $null
                try {
                    $vRes = Test-RemoteCloudFileVerification -Account $item['DestinationAccount'] -RemotePath (Get-CloudTransferJobDestinationPath -Job $item) -ExpectedSizeBytes ([int64]$item['FileSizeBytes']) -LocalSourcePath ([string]$item['SourcePath'])
                } catch { }
                if ($null -ne $vRes) {
                    # Treat as a normal recovery job: bypass operation validation and
                    # verify against the local destination path.
                    $skipOperationValidation = $true
                }
            }
            if (-not $skipOperationValidation) {
                if ($status -ne 'Needs reconciliation: operation unresolved') {
                    if ([string]::IsNullOrWhiteSpace([string]$item['StatusBeforeReconciliation'])) {
                        $item['StatusBeforeReconciliation'] = $status
                    }
                    $item['Status'] = 'Needs reconciliation: operation unresolved'
                    $item['ReconciliationStatus'] = 'Required'
                    $item['LastError'] = [string]$jobOperation.Reason
                    $item['JobId'] = ''
                    $item['WorkerPid'] = 0
                    $item['WorkerLeaseUtc'] = $null
                    $reconciliationCount++
                }
                continue
            }
        }

        if ($status -in @('Uploading', 'Staging', 'Waiting for network/provider', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file')) {
            $recoveredCount++
            # Reconcile against the intended destination only.
            $vRes = $null
            try {
                if ($skipOperationValidation) {
                    $vRes = Test-RemoteCloudFileVerification -Account $item['DestinationAccount'] -RemotePath (Get-CloudTransferJobDestinationPath -Job $item) -ExpectedSizeBytes ([int64]$item['FileSizeBytes']) -LocalSourcePath ([string]$item['SourcePath'])
                } else {
                    $vRes = Test-CloudTransferJobDestination -Job $item
                }
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
                $item['ReconciliationStatus'] = 'None'
                if ($vRes.Contains('RemoteHash')) {
                    $item['RemoteHash'] = [string]$vRes['RemoteHash']
                }
                if ($vRes.Contains('VerificationType')) {
                    $item['VerificationType'] = [string]$vRes['VerificationType']
                }
                $confirmedCount++
            } elseif ($vRes -and $vRes['Status'] -eq 'Failed' -and [string]$vRes['Reason'] -match '(?i)(not found|size mismatch)') {
                # The destination answered, but the expected object is absent or incomplete.
                # Retry within the existing bounded budget; never reset it on reboot.
                $item['WorkerPid'] = 0
                $item['WorkerLeaseUtc'] = $null
                $item['JobId'] = ''
                $retries = [int]$item['RetryCount']
                $maxRetries = [int]$item['MaxRetries']
                if ($retries -lt $maxRetries) {
                    $item['RetryCount'] = $retries + 1
                    $item['NextRetryUtc'] = $now.AddSeconds((Get-TransferRetryDelaySeconds -RetryCount ([int]$item['RetryCount']) -ErrorMessage ([string]$vRes['Reason'])))
                    $item['Status'] = 'Waiting for network/provider'
                    $item['LastError'] = [string]$vRes['Reason']
                } else {
                    $item['Status'] = 'Failed'
                    $item['LastError'] = "Restart recovery found an absent or incomplete destination object after retry limit: $($vRes['Reason'])"
                    $item['CompletedUtc'] = $null
                }
                $resetCount++
            } else {
                # A failed or unavailable destination check is not proof that no object exists.
                # Keep the job in verification state and retry verification with backoff.
                $item['Status'] = 'Awaiting remote confirmation'
                $item['JobId'] = ''
                $item['WorkerPid'] = 0
                $item['WorkerLeaseUtc'] = $null
                $item['VerificationRetryCount'] = [int]$item['VerificationRetryCount'] + 1
                $item['LastError'] = if ($vRes -and $vRes['Reason']) { [string]$vRes['Reason'] } else { 'Destination state could not be verified after restart.' }
                if ([int]$item['VerificationRetryCount'] -ge 6) {
                    $item['Status'] = 'Needs attention: remote verification unavailable'
                } else {
                    $item['NextRetryUtc'] = $now.AddSeconds((Get-TransferRetryDelaySeconds -RetryCount ([int]$item['VerificationRetryCount']) -ErrorMessage ([string]$item['LastError'])))
                }
                $resetCount++
            }
        }
    }

    if ($recoveredCount -gt 0 -or $reconciliationCount -gt 0) {
        Save-DurableTransferQueue | Out-Null
    }

    return [ordered]@{
        RecoveredCount      = $recoveredCount
        ConfirmedCount      = $confirmedCount
        ResetCount          = $resetCount
        ReconciliationCount = $reconciliationCount
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

        [string]$RelativePath = '',

        # Revision of the source at queue time. For a local source it is read from
        # the file itself when the caller does not supply it, so a changed file is a
        # different logical transfer rather than a silently suppressed duplicate.
        [string]$SourceLastWriteUtc = '',

        # Explicit intent. When omitted the operation is resolved from the two
        # account providers; an unresolved endpoint is paused, never guessed.
        [ValidateSet('Upload', 'Download', 'CloudCopy', '')]
        [string]$OperationType = '',

        [string]$Origin = 'UserRequest',

        [string]$PreviousJobId = '',

        # Only an explicit user retry may create a second attempt for a terminal job.
        [switch]$AllowNewAttempt,

        # Callers that add many jobs (startup cache adoption) persist once themselves
        # instead of rewriting the durable state file for every single job.
        [switch]$SkipPersist
    )

    $queueId = "queue_" + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $cleanSrc = Normalize-CloudPath -Path $SourcePath
    $fileName = if ($cleanSrc.Contains('/')) { $cleanSrc.Substring($cleanSrc.LastIndexOf('/') + 1) } else { $cleanSrc }

    $srcAccId = [string](Get-CloudTransferFieldValue $SourceAccount 'Id')
    $dstAccId = [string](Get-CloudTransferFieldValue $DestinationAccount 'Id')
    $dstProvId = Get-CloudTransferProviderId $DestinationAccount

    $operation = Resolve-CloudTransferOperation `
        -SourceAccount $SourceAccount `
        -SourcePath $SourcePath `
        -DestinationAccount $DestinationAccount `
        -DestinationPath $DestinationPath `
        -DestinationFilePath $(if ($DestinationPath) { Normalize-CloudPath "$DestinationPath/$fileName" } else { $fileName }) `
        -DeclaredOperationType $OperationType

    $resolvedOperation = [string]$operation.OperationType
    $resolvedDirection = [string]$operation.Direction
    $resolvedDestinationFilePath = if ($resolvedOperation -eq 'Download') {
        # A download's destination is a concrete local file, not a remote-style
        # "<dir>/<name>" pair. Persist the caller's intended local target verbatim.
        if ($DestinationPath) { $DestinationPath } else { $fileName }
    } elseif ($DestinationPath) {
        Normalize-CloudPath "$DestinationPath/$fileName"
    } else {
        $fileName
    }
    $resolvedDestinationDirectory = if ($resolvedOperation -eq 'Download') {
        try { [System.IO.Path]::GetDirectoryName($resolvedDestinationFilePath) } catch { '' }
    } else {
        $DestinationPath
    }

    $effectiveSourceLastWriteUtc = $SourceLastWriteUtc
    if ([string]::IsNullOrWhiteSpace($effectiveSourceLastWriteUtc) -and $operation.IsValid -and [string]$operation.SourceProvider -eq 'local') {
        try {
            if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
                $effectiveSourceLastWriteUtc = ([System.IO.FileInfo]::new($SourcePath)).LastWriteTimeUtc.ToString('o')
            }
        } catch { }
    }

    $transferKey = Get-CloudTransferLogicalKey `
        -OperationType $(if ($operation.IsValid) { $resolvedOperation } else { 'Unknown' }) `
        -SourceProvider ([string]$operation.SourceProvider) `
        -SourceAccountId $srcAccId `
        -SourcePath $SourcePath `
        -DestinationProvider ([string]$operation.DestinationProvider) `
        -DestinationAccountId $dstAccId `
        -DestinationFilePath $resolvedDestinationFilePath `
        -FileSizeBytes $FileSizeBytes `
        -SourceLastWriteUtc $effectiveSourceLastWriteUtc

    # A logical transfer is identified by operation + both endpoints + revision.
    # Repeated discovery of the same intended operation must never enqueue a second
    # worker, and a terminal job must not be revived implicitly.
    $existingJob = $null
    foreach ($existing in @($script:CloudTransferQueue)) {
        if ($null -eq $existing) { continue }
        $existingKey = [string](Get-CloudTransferFieldValue $existing 'TransferKey')
        if ($existingKey -and [string]::Equals($existingKey, $transferKey, [System.StringComparison]::OrdinalIgnoreCase)) {
            $existingJob = $existing
            break
        }
    }
    if ($null -ne $existingJob) {
        $existingStatus = [string](Get-CloudTransferFieldValue $existingJob 'Status')
        $terminal = $existingStatus -in @('Completed and remotely confirmed', 'Completed', 'Failed', 'Cancelled', 'Superseded')
        if (-not ($terminal -and $AllowNewAttempt)) {
            if (Get-Command Write-NSCloudLog -ErrorAction SilentlyContinue) {
                try {
                    Write-NSCloudLog -Severity 'Info' -Operation 'transfer-duplicate-suppressed' `
                        -Message "Suppressed a duplicate logical transfer for '$fileName' (existing status: $existingStatus)."
                } catch { }
            }
            return $null
        }
        if (-not $PreviousJobId) { $PreviousJobId = [string](Get-CloudTransferFieldValue $existingJob 'JobId') }
    }

    $initialStatus = if ($operation.IsValid) { 'Queued' } else { 'Needs reconciliation: operation unresolved' }
    $reconciliationStatus = if ($operation.IsValid) { 'None' } else { 'Required' }

    $item = [hashtable]::Synchronized(@{
        JobId = $queueId
        QueueId = $queueId
        BatchId = $BatchId
        BatchName = $BatchName
        TransferKey = $transferKey
        OperationType = $(if ($operation.IsValid) { $resolvedOperation } else { 'Unknown' })
        Direction = $(if ($operation.IsValid) { $resolvedDirection } else { 'Unknown' })
        SourceProvider = [string]$operation.SourceProvider
        DestinationProvider = [string]$operation.DestinationProvider
        SourceAccountId = $srcAccId
        DestinationAccountId = $dstAccId
        Origin = $Origin
        PreviousJobId = $PreviousJobId
        ReconciliationStatus = $reconciliationStatus
        StatusBeforeReconciliation = ''
        # AccountId/ProviderId remain the destination aliases expected by the
        # existing Transfer Center and pending-summary code.
        AccountId = $dstAccId
        ProviderId = $dstProvId
        SourceAccount = $SourceAccount
        SourcePath = $SourcePath
        DestinationAccount = $DestinationAccount
        DestinationPath = $DestinationPath
        DestinationFilePath = $resolvedDestinationFilePath
        DestinationDirectory = $resolvedDestinationDirectory
        RelativePath = if ($RelativePath) { $RelativePath } else { $fileName }
        ConflictAction = $ConflictAction
        IsMove = [bool]$IsMove
        SourceLastWriteUtc = $effectiveSourceLastWriteUtc
        Status = $initialStatus
        RetryCount = 0
        VerificationRetryCount = 0
        MaxRetries = $MaxRetries
        NextRetryUtc = [DateTime]::MinValue
        EnqueuedUtc = [DateTime]::UtcNow
        StartedUtc = $null
        CompletedUtc = $null
        LastProgressUtc = $null
        WorkerPid = 0
        WorkerLeaseUtc = $null
        LastError = if ($operation.IsValid) { '' } else { [string]$operation.Reason }
        FileName = $fileName
        FileSizeBytes = $FileSizeBytes
        BytesTransferred = 0L
        Percentage = 0.0
        SmoothedSpeed = 0.0
        EtaSeconds = $null
        BandwidthLimit = $BandwidthLimit
    })

    [void]$script:CloudTransferQueue.Add($item)
    if (-not $SkipPersist) {
        try {
            Save-DurableTransferQueue | Out-Null
        } catch {
            [void]$script:CloudTransferQueue.Remove($item)
            throw
        }
    }
    return $item
}

function Get-CloudTransferAccountKey {
    [CmdletBinding()]
    param(
        [string]$AccountId = '',
        [string]$ProviderId = ''
    )

    # Cache directories are named "<provider>_<accountId>", while account records may
    # store either form. Both sides of a staged/queue comparison use this one key.
    $normalized = ([string]$AccountId).Trim().ToLowerInvariant()
    $provider = ([string]$ProviderId).Trim().ToLowerInvariant()
    if ($provider -and $normalized.StartsWith("$provider`_", [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring($provider.Length + 1)
    }
    return $normalized
}

function Get-CloudTransferStagedIdentity {
    [CmdletBinding()]
    param(
        [string]$AccountId = '',
        [string]$ProviderId = '',
        [string]$RelativePath = ''
    )

    # Must stay byte-identical to the identity built inside Get-CloudTransferPendingSummary
    # so an adopted job is recognized as covering its staged source.
    $normalized = Get-CloudTransferAccountKey -AccountId $AccountId -ProviderId $ProviderId
    $path = ([string]$RelativePath).Replace('\', '/').Trim('/').ToLowerInvariant()
    return "$normalized|$path"
}

function Import-StagedVfsFilesToTransferQueue {
    <#
    .SYNOPSIS
    Adopts dirty rclone VFS staged files that live outside the live cache root.

    rclone resolves its upload queue once when the mount starts, so a staged file
    left in a superseded cache root (for example after the cache root name changes)
    is never transmitted by the running process. This function turns each such file
    into a durable transfer job that the application uploads and verifies itself,
    without copying, moving, or deleting the staged source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$StagedFiles = @(),

        [Parameter(Mandatory = $false)]
        [object[]]$Accounts = @(),

        [Parameter(Mandatory = $false)]
        [string]$BatchName = 'Recovered staged uploads',

        [Parameter(Mandatory = $false)]
        [int]$MaxFilesPerPass = 250
    )

    $result = [ordered]@{
        AdoptedCount       = 0
        AdoptedBytes       = 0L
        AlreadyQueuedCount = 0
        AlreadySettledCount = 0
        SupersededCount    = 0
        SkippedCount       = 0
        FailedCount        = 0
        BatchId            = ''
        JobIds             = @()
    }

    if ($null -eq $StagedFiles -or @($StagedFiles).Count -eq 0) { return $result }
    if ($script:TransferQueueStateUnavailable) { return $result }
    if ($MaxFilesPerPass -le 0) { return $result }

    $readField = {
        param($Item, [string]$Name)
        if ($null -eq $Item) { return $null }
        if ($Item -is [System.Collections.IDictionary]) {
            if ($Item.Contains($Name)) { return $Item[$Name] }
            return $null
        }
        $prop = $Item.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }

    $accountIndex = @{}
    foreach ($account in @($Accounts)) {
        $accountId = [string](& $readField $account 'Id')
        if (-not [string]::IsNullOrEmpty($accountId)) {
            $accountProvider = [string](& $readField $account 'ProviderId')
            $accountKey = Get-CloudTransferAccountKey -AccountId $accountId -ProviderId $accountProvider
            if ($accountKey) { $accountIndex[$accountKey] = $account }
        }
    }

    $coveredIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $activeIdentityJobs = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $settledRevisions = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Durable settlements survive the completed list being cleared.
    foreach ($ledgerEntry in $script:CloudTransferSettledStaged.GetEnumerator()) {
        $settledRevisions[$ledgerEntry.Key] = [pscustomobject]@{
            Size         = [int64]$ledgerEntry.Value.Size
            LastWriteUtc = [string]$ledgerEntry.Value.LastWriteUtc
        }
    }
    foreach ($job in @($script:CloudTransferQueue)) {
        if ($null -eq $job) { continue }
        $jobStatus = [string](& $readField $job 'Status')
        $jobAccount = [string](& $readField $job 'AccountId')
        $jobProvider = [string](& $readField $job 'ProviderId')
        $jobPath = [string](& $readField $job 'DestinationFilePath')
        if ([string]::IsNullOrEmpty($jobPath)) { $jobPath = [string](& $readField $job 'RelativePath') }
        if ([string]::IsNullOrEmpty($jobPath) -or [string]::IsNullOrEmpty($jobAccount)) { continue }

        $identity = Get-CloudTransferStagedIdentity -AccountId $jobAccount -ProviderId $jobProvider -RelativePath $jobPath
        if ($jobStatus -eq 'Completed and remotely confirmed') {
            $settledRevisions[$identity] = [pscustomobject]@{
                Size         = [int64](& $readField $job 'FileSizeBytes')
                LastWriteUtc = [string](& $readField $job 'StagedSourceLastWriteUtc')
            }
        } elseif ($jobStatus -in @('Cancelled', 'Superseded', 'Failed') -or $jobStatus -match '^Needs attention') {
            # A terminal job is never revived implicitly. It stays visible until the
            # user retries it or the staged revision changes.
            [void]$coveredIdentities.Add($identity)
        } else {
            $activeIdentityJobs[$identity] = $job
        }
    }

    $batchId = 'recovery_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $activeBatchName = if ([string]::IsNullOrWhiteSpace($BatchName) -or $BatchName -eq 'Recovered staged uploads') {
        "Recovered staged uploads ($([DateTime]::Now.ToString('yyyy-MM-dd HH:mm')))"
    } else {
        $BatchName
    }
    $localSourceAccount = @{ Id = 'local'; ProviderId = 'local'; Label = 'Local staging cache' }
    $adoptedJobs = [System.Collections.Generic.List[object]]::new()
    $supersededJobs = [System.Collections.Generic.List[object]]::new()

    foreach ($file in @($StagedFiles)) {
        if ($result.AdoptedCount -ge $MaxFilesPerPass) { break }
        if ($null -eq $file) { continue }

        $path = [string](& $readField $file 'Path')
        $relativePath = [string](& $readField $file 'RelativePath')
        $accountId = [string](& $readField $file 'AccountId')
        $providerId = [string](& $readField $file 'ProviderId')
        $length = [int64](& $readField $file 'Length')
        $lastWriteRaw = & $readField $file 'LastWriteTimeUtc'
        $outsideActiveCache = [bool](& $readField $file 'IsOutsideActiveCache')
        $hasConflict = [bool](& $readField $file 'HasStagedPathConflict')
        $state = [string](& $readField $file 'State')

        if ([string]::IsNullOrEmpty($path) -or [string]::IsNullOrEmpty($relativePath) -or [string]::IsNullOrEmpty($accountId)) {
            $result.SkippedCount++
            continue
        }
        # Files inside the live cache root belong to rclone's own write-back queue.
        # Never race it with a second uploader. When the active root is unknown the
        # scanner reports them as inside, so this fails closed.
        if (-not $outsideActiveCache) { $result.SkippedCount++; continue }
        # The scanner tags orphan-root files with a review status to keep rclone's own
        # writer away from them; that specific status is the adoption case, not an
        # ambiguity. Any other "Needs review" reason (for example two dirty copies of
        # the same path) must still be skipped rather than guessed.
        $ambiguousReview = $state -match '^Needs review' -and $state -notmatch 'outside the active rclone cache root'
        if ($hasConflict -or $ambiguousReview) { $result.SkippedCount++; continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $result.FailedCount++; continue }

        $lastWriteUtc = ''
        if ($lastWriteRaw -is [DateTime]) {
            $lastWriteUtc = ([DateTime]$lastWriteRaw).ToUniversalTime().ToString('o')
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$lastWriteRaw)) {
            $lastWriteUtc = [string]$lastWriteRaw
        }

        $identity = Get-CloudTransferStagedIdentity -AccountId $accountId -ProviderId $providerId -RelativePath $relativePath
        if ($coveredIdentities.Contains($identity)) { $result.AlreadyQueuedCount++; continue }
        if ($settledRevisions.ContainsKey($identity)) {
            $settled = $settledRevisions[$identity]
            if ([int64]$settled.Size -eq $length -and -not [string]::IsNullOrEmpty($settled.LastWriteUtc) -and $settled.LastWriteUtc -eq $lastWriteUtc) {
                $result.AlreadySettledCount++
                continue
            }
        }

        # One logical staged path has at most one non-terminal job. A newer staged
        # revision replaces an older queued job, but never interrupts bytes that are
        # already in flight.
        if ($activeIdentityJobs.ContainsKey($identity)) {
            $activeJob = $activeIdentityJobs[$identity]
            $activeStatus = [string](& $readField $activeJob 'Status')
            $activeSize = [int64](& $readField $activeJob 'FileSizeBytes')
            $activeWrite = [string](& $readField $activeJob 'StagedSourceLastWriteUtc')
            if ($activeSize -eq $length -and -not [string]::IsNullOrEmpty($activeWrite) -and $activeWrite -eq $lastWriteUtc) {
                $result.AlreadyQueuedCount++
                continue
            }
            if ($activeStatus -in @('Uploading', 'Staging', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file')) {
                # Do not supersede a job that is transmitting or awaiting verification.
                # The next pass re-evaluates it once it reaches a terminal state.
                $result.SkippedCount++
                continue
            }
            $supersededJobs.Add([pscustomobject]@{
                Job             = $activeJob
                PreviousStatus  = $activeStatus
                PreviousError   = [string](& $readField $activeJob 'LastError')
                PreviousJobId   = [string](& $readField $activeJob 'JobId')
                PreviousCompletedUtc = & $readField $activeJob 'CompletedUtc'
            })
            $activeJob['Status'] = 'Superseded'
            $activeJob['CompletedUtc'] = [DateTime]::UtcNow
            $activeJob['WorkerPid'] = 0
            $activeJob['WorkerLeaseUtc'] = $null
            $activeJob['JobId'] = ''
            $activeJob['LastError'] = 'Superseded by a newer staged revision of the same file.'
            $result.SupersededCount++
            [void]$activeIdentityJobs.Remove($identity)
        }

        $normalizedRelative = Normalize-CloudPath -Path $relativePath
        $destinationDir = if ($normalizedRelative.Contains('/')) { $normalizedRelative.Substring(0, $normalizedRelative.LastIndexOf('/')) } else { '' }

        $normalizedAccountId = Get-CloudTransferAccountKey -AccountId $accountId -ProviderId $providerId
        $destinationAccount = if ($normalizedAccountId -and $accountIndex.ContainsKey($normalizedAccountId)) {
            $accountIndex[$normalizedAccountId]
        } else {
            @{ Id = if ($normalizedAccountId) { $normalizedAccountId } else { $accountId }; ProviderId = $providerId }
        }
        if ($destinationAccount -isnot [System.Collections.IDictionary]) {
            $destinationAccount = ConvertTo-TransferAccountSnapshot -Account $destinationAccount
        }
        if (-not $destinationAccount.Contains('Id')) { $destinationAccount['Id'] = $accountId }
        if (-not $destinationAccount.Contains('ProviderId') -and $providerId) { $destinationAccount['ProviderId'] = $providerId }

        try {
            $job = Add-CloudTransferQueueItem `
                -SourceAccount $localSourceAccount `
                -SourcePath $path `
                -DestinationAccount $destinationAccount `
                -DestinationPath $destinationDir `
                -ConflictAction 'Overwrite' `
                -MaxRetries 5 `
                -FileSizeBytes $length `
                -BatchId $batchId `
                -BatchName $activeBatchName `
                -RelativePath $normalizedRelative `
                -SourceLastWriteUtc $lastWriteUtc `
                -OperationType 'Upload' `
                -Origin 'StagedVfsAdoption' `
                -SkipPersist
            if ($null -eq $job) {
                # The durable queue already holds this exact logical transfer.
                $result.AlreadyQueuedCount++
                continue
            }
            $job['StagedSourcePath'] = $path
            $job['StagedSourceLastWriteUtc'] = $lastWriteUtc
            # The scheduler re-checks this revision before uploading, so a staged file
            # that changes while queued is reported instead of uploading stale bytes.
            $job['SourceLastWriteUtc'] = $lastWriteUtc
            $job['RecoveredFromVfsCache'] = $true
            $job['RecoveryBatchId'] = $batchId
            [void]$coveredIdentities.Add($identity)
            [void]$activeIdentityJobs.Remove($identity)
            $adoptedJobs.Add($job)
            $result.AdoptedCount++
            $result.AdoptedBytes += $length
        } catch {
            $result.FailedCount++
        }
    }

    if ($adoptedJobs.Count -gt 0 -or $supersededJobs.Count -gt 0) {
        try {
            Save-DurableTransferQueue | Out-Null
        } catch {
            foreach ($job in $adoptedJobs) { [void]$script:CloudTransferQueue.Remove($job) }
            foreach ($entry in $supersededJobs) {
                $entry.Job['Status'] = $entry.PreviousStatus
                $entry.Job['LastError'] = $entry.PreviousError
                $entry.Job['JobId'] = $entry.PreviousJobId
                $entry.Job['CompletedUtc'] = $entry.PreviousCompletedUtc
            }
            $result.AdoptedCount = 0
            $result.AdoptedBytes = 0L
            $result.SupersededCount = 0
            $result.FailedCount = @($StagedFiles).Count
            throw
        }
        $result.BatchId = $batchId
        $result.JobIds = @($adoptedJobs | ForEach-Object { [string]$_['JobId'] })
        if (Get-Command Write-NSCloudLog -ErrorAction SilentlyContinue) {
            try {
                Write-NSCloudLog -Severity 'Info' -Operation 'staged-upload-adoption' `
                    -Message "Adopted $($result.AdoptedCount) orphaned staged file(s) ($($result.AdoptedBytes) bytes) into the durable transfer queue; staged sources were left untouched."
            } catch { }
        }
    }

    return $result
}

function Get-CloudTransferPendingSummary {
    [CmdletBinding()]
    param(
        [object[]]$QueueItems = @(),
        [object[]]$StagedFiles = @()
    )

    $seenJobs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $stagedCovered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenStaged = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Remotely confirmed revisions: a staged source whose exact size and write time
    # were already verified on the provider must not keep inflating the pending count.
    $settledRevisions = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Durable settlements remain valid even after the completed jobs are cleared.
    foreach ($ledgerEntry in $script:CloudTransferSettledStaged.GetEnumerator()) {
        $settledRevisions[$ledgerEntry.Key] = [pscustomobject]@{
            Size         = [int64]$ledgerEntry.Value.Size
            LastWriteUtc = [string]$ledgerEntry.Value.LastWriteUtc
        }
    }
    $counts = [ordered]@{
        QueuedCount = 0
        StagingCount = 0
        UploadingCount = 0
        RetryingCount = 0
        AwaitingVerificationCount = 0
        StagedOnlyCount = 0
        FailedCount = 0
        CancelledCount = 0
        CompletedCount = 0
        UnknownCount = 0
        DuplicateJobCount = 0
        ConflictCount = 0
        NeedsReviewCount = 0
        ReconciliationCount = 0
        SupersededCount = 0
        UploadCount = 0
        DownloadCount = 0
        CloudCopyCount = 0
    }

    $normalizeAccountKey = {
        param([string]$AccountId, [string]$ProviderId)
        $normalized = ([string]$AccountId).Trim().ToLowerInvariant()
        $provider = ([string]$ProviderId).Trim().ToLowerInvariant()
        if ($provider -and $normalized.StartsWith("$provider`_", [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalized = $normalized.Substring($provider.Length + 1)
        }
        return $normalized
    }

    foreach ($item in $QueueItems) {
        if ($null -eq $item -or $item -isnot [System.Collections.IDictionary]) { continue }
        $status = if ($item.Contains('Status')) { [string]$item['Status'] } else { '' }
        $accountId = if ($item.Contains('AccountId')) { [string]$item['AccountId'] } else { '' }
        $providerId = if ($item.Contains('ProviderId')) { [string]$item['ProviderId'] } else { '' }
        if (-not $accountId -and $item.Contains('DestinationAccount') -and $item['DestinationAccount'] -is [System.Collections.IDictionary]) {
            if ($item['DestinationAccount'].Contains('Id')) { $accountId = [string]$item['DestinationAccount']['Id'] }
            if (-not $providerId -and $item['DestinationAccount'].Contains('ProviderId')) { $providerId = [string]$item['DestinationAccount']['ProviderId'] }
        }
        $logicalPath = if ($item.Contains('DestinationFilePath')) { [string]$item['DestinationFilePath'] } else { '' }
        if (-not $logicalPath -and $item.Contains('RelativePath')) { $logicalPath = [string]$item['RelativePath'] }
        $jobId = if ($item.Contains('JobId')) { [string]$item['JobId'] } elseif ($item.Contains('QueueId')) { [string]$item['QueueId'] } else { '' }
        $recordKey = if ($item.Contains('TransferKey') -and $item['TransferKey']) { "transfer|$($item['TransferKey'])" } elseif ($item.Contains('QueueId') -and $item['QueueId']) { "queue|$($item['QueueId'])" } elseif ($jobId) { "job|$jobId" } else { "unknown|$([Guid]::NewGuid().ToString('N'))" }
        $accountKey = & $normalizeAccountKey $accountId $providerId
        $pathKey = if ($accountKey -and $logicalPath) { "$accountKey|$($logicalPath.Replace('\','/').Trim('/').ToLowerInvariant())" } else { '' }
        # A completed older revision must not hide a newer dirty VFS revision at the
        # same destination path. Other queue states already account for that path.
        if ($pathKey -and $status -ne 'Completed and remotely confirmed') { $stagedCovered.Add($pathKey) | Out-Null }
        if ($pathKey -and $status -eq 'Completed and remotely confirmed') {
            $settledRevisions[$pathKey] = [pscustomobject]@{
                Size         = if ($item.Contains('FileSizeBytes')) { [int64]$item['FileSizeBytes'] } else { -1L }
                LastWriteUtc = if ($item.Contains('StagedSourceLastWriteUtc')) { [string]$item['StagedSourceLastWriteUtc'] } else { '' }
            }
        }
        if (-not $seenJobs.Add($recordKey)) {
            $counts.DuplicateJobCount++
            continue
        }

        if ($item.Contains('HasStagedPathConflict') -and $item['HasStagedPathConflict']) {
            $counts.ConflictCount++
            $counts.NeedsReviewCount++
        }

        $jobOperation = Get-CloudTransferJobOperation -Job $item
        $operationType = if ($jobOperation.IsValid) { [string]$jobOperation.OperationType } else { [string](Get-CloudTransferFieldValue $item 'OperationType') }
        switch ($operationType) {
            'Upload' { $counts.UploadCount++ }
            'Download' { $counts.DownloadCount++ }
            'CloudCopy' { $counts.CloudCopyCount++ }
        }

        # An unresolved record is preserved and surfaced for reconciliation; it is
        # not pending work and must not inflate the active count.
        if ($status -eq 'Needs reconciliation: operation unresolved' -or [string](Get-CloudTransferFieldValue $item 'ReconciliationStatus') -eq 'Required') {
            $counts.ReconciliationCount++
            $counts.NeedsReviewCount++
            continue
        }

        switch -Regex ($status) {
            '^Completed and remotely confirmed$' { $counts.CompletedCount++; break }
            '^Cancelled$' { $counts.CancelledCount++; break }
            '^Superseded$' { $counts.SupersededCount++; break }
            '^Failed$|^Needs attention' { $counts.FailedCount++; break }
            '^Queued$' { $counts.QueuedCount++; break }
            '^Staging$|^Staged$' { $counts.StagingCount++; break }
            '^Uploading$' { $counts.UploadingCount++; break }
            '^Waiting for network/provider$' { $counts.RetryingCount++; break }
            '^Upload pending remote confirmation$|^Awaiting remote confirmation$|^Verifying remote file$' { $counts.AwaitingVerificationCount++; break }
            default { $counts.UnknownCount++; break }
        }
    }

    foreach ($item in $StagedFiles) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Collections.ICollection] -and $item -isnot [string] -and $item -isnot [System.Collections.IDictionary]) {
            if ($item.Count -eq 0) { continue }
        }
        $accountId = ''
        $logicalPath = ''
        $path = ''
        $providerId = ''
        $stagedBytes = -1L
        $stagedWriteRaw = $null
        if ($item -is [System.Collections.IDictionary]) {
            if ($item.Contains('AccountId')) { $accountId = [string]$item['AccountId'] }
            if ($item.Contains('ProviderId')) { $providerId = [string]$item['ProviderId'] }
            if ($item.Contains('RelativePath')) { $logicalPath = [string]$item['RelativePath'] }
            if ($item.Contains('Path')) { $path = [string]$item['Path'] }
            if ($item.Contains('Length')) { $stagedBytes = [int64]$item['Length'] }
            if ($item.Contains('LastWriteTimeUtc')) { $stagedWriteRaw = $item['LastWriteTimeUtc'] }
        } else {
            if ($item.PSObject.Properties['AccountId']) { $accountId = [string]$item.AccountId }
            if ($item.PSObject.Properties['ProviderId']) { $providerId = [string]$item.ProviderId }
            if ($item.PSObject.Properties['RelativePath']) { $logicalPath = [string]$item.RelativePath }
            if ($item.PSObject.Properties['Path']) { $path = [string]$item.Path }
            if ($item.PSObject.Properties['Length']) { $stagedBytes = [int64]$item.Length }
            if ($item.PSObject.Properties['LastWriteTimeUtc']) { $stagedWriteRaw = $item.LastWriteTimeUtc }
        }
        if (-not $accountId -or -not $logicalPath) {
            if (-not $path -and -not $logicalPath) { continue }
            # Do not merge records when account/path identity is incomplete.
            $identity = if ($path) { "staged|$($path.ToLowerInvariant())" } else { "staged|$([Guid]::NewGuid().ToString('N'))" }
        } else {
            $accountKey = & $normalizeAccountKey $accountId $providerId
            $identity = "$accountKey|$($logicalPath.Replace('\','/').Trim('/').ToLowerInvariant())"
        }
        if ($stagedCovered.Contains($identity)) { continue }
        if ($settledRevisions.ContainsKey($identity)) {
            $settled = $settledRevisions[$identity]
            $stagedWrite = if ($stagedWriteRaw -is [DateTime]) { ([DateTime]$stagedWriteRaw).ToUniversalTime().ToString('o') } else { [string]$stagedWriteRaw }
            if ([int64]$settled.Size -eq $stagedBytes -and -not [string]::IsNullOrEmpty($settled.LastWriteUtc) -and $settled.LastWriteUtc -eq $stagedWrite) {
                # This exact staged revision is already confirmed on the provider.
                continue
            }
        }
        if ($seenStaged.Add($identity)) {
            $counts.StagedOnlyCount++
            $hasConflict = if ($item -is [System.Collections.IDictionary]) { $item.Contains('HasStagedPathConflict') -and [bool]$item['HasStagedPathConflict'] } elseif ($item.PSObject.Properties['HasStagedPathConflict']) { [bool]$item.HasStagedPathConflict } else { $false }
            $state = if ($item -is [System.Collections.IDictionary] -and $item.Contains('State')) { [string]$item['State'] } elseif ($item.PSObject.Properties['State']) { [string]$item.State } else { '' }
            if ($hasConflict) { $counts.ConflictCount++ }
            if ($hasConflict -or $state -match '^Needs review') { $counts.NeedsReviewCount++ }
        }
    }

    $counts.PendingCount = [int]$counts.QueuedCount + [int]$counts.StagingCount + [int]$counts.UploadingCount +
        [int]$counts.RetryingCount + [int]$counts.AwaitingVerificationCount + [int]$counts.StagedOnlyCount + [int]$counts.UnknownCount
    $counts.TotalTrackedCount = [int]$counts.PendingCount + [int]$counts.FailedCount + [int]$counts.CancelledCount +
        [int]$counts.CompletedCount + [int]$counts.ReconciliationCount + [int]$counts.SupersededCount
    return $counts
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

    if ($script:TransferQueueStateUnavailable) {
        return (Get-CloudTransferQueue)
    }

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
            # Fail closed: if neither named mutex can be acquired, do not schedule
            # transfers without cross-process ownership.
            $hasMutexLock = $false
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

            # Fail closed on an unresolved operation. The record and its files stay
            # intact; only scheduling is blocked until reconciliation is explicit.
            if ($status -notin @('Completed and remotely confirmed', 'Completed', 'Failed', 'Cancelled', 'Superseded')) {
                $jobOperation = Get-CloudTransferJobOperation -Job $item
                if (-not $jobOperation.IsValid) {
                    if ($status -ne 'Needs reconciliation: operation unresolved') {
                        if ([string]::IsNullOrWhiteSpace([string]$item['StatusBeforeReconciliation'])) {
                            $item['StatusBeforeReconciliation'] = $status
                        }
                        $item['Status'] = 'Needs reconciliation: operation unresolved'
                        $item['ReconciliationStatus'] = 'Required'
                        $item['LastError'] = [string]$jobOperation.Reason
                        $item['WorkerPid'] = 0
                        $item['WorkerLeaseUtc'] = $null
                        $item['JobId'] = ''
                        $stateChanged = $true
                    }
                    continue
                }
            }

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

                $lastProgressAge = 0.0
                if ($item.ContainsKey('LastProgressUtc') -and ($item['LastProgressUtc'] -is [DateTime])) {
                    $lastProgressAge = ($now - [DateTime]$item['LastProgressUtc']).TotalSeconds
                }
                if ($isProcessAlive -and $lastProgressAge -ge 300.0) {
                    $activeJobId = [string]$item['JobId']
                    try { Stop-CloudTransfer -JobId $activeJobId | Out-Null } catch { }
                    $item['WorkerPid'] = 0
                    $item['WorkerLeaseUtc'] = $null
                    $item['JobId'] = ''
                    $retries = [int]$item['RetryCount']
                    $maxR = [int]$item['MaxRetries']
                    if ($retries -lt $maxR) {
                        $item['RetryCount'] = $retries + 1
                        $item['NextRetryUtc'] = $now.AddSeconds((Get-TransferRetryDelaySeconds -RetryCount ([int]$item['RetryCount']) -ErrorMessage 'stalled transfer worker'))
                        $item['Status'] = 'Waiting for network/provider'
                        $item['LastError'] = 'Owned transfer worker made no byte progress for 300 seconds and was stopped for a bounded retry.'
                    } else {
                        $item['Status'] = 'Failed'
                        $item['LastError'] = 'Owned transfer worker remained stalled through the retry limit. Check connectivity and retry manually.'
                        $item['CompletedUtc'] = $now
                    }
                    $stateChanged = $true
                    continue
                }

                if (-not $isProcessAlive -and ($leaseAge -gt 60.0 -or ($workerPid -gt 0 -and -not $script:ActiveTransferJobs.ContainsKey([string]$item['JobId'])))) {
                    # Reclaim abandoned worker
                    $item['WorkerPid'] = 0
                    $item['WorkerLeaseUtc'] = $null
                    $retries = [int]$item['RetryCount']
                    $maxR = [int]$item['MaxRetries']
                    if ($retries -lt $maxR) {
                        $item['RetryCount'] = $retries + 1
                        $backoff = Get-TransferRetryDelaySeconds -RetryCount ([int]$item['RetryCount']) -ErrorMessage 'worker process disconnected'
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
                    $previousBytes = [int64]$item['BytesTransferred']
                    $item['Percentage'] = [double]$jobStatus.Percentage
                    $item['SmoothedSpeed'] = [double]$jobStatus.SmoothedSpeed
                    $item['EtaSeconds'] = $jobStatus.EtaSeconds
                    $item['BytesTransferred'] = [int64]$jobStatus.BytesTransferred
                    $item['WorkerLeaseUtc'] = $now
                    if ([int64]$jobStatus.BytesTransferred -gt $previousBytes) {
                        $item['LastProgressUtc'] = $now
                    }
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
                        $item['NextRetryUtc'] = $now.AddSeconds(2)
                        $stateChanged = $true
                    } elseif ($jobStatus.Status -eq 'Awaiting remote confirmation' -or $jobStatus.VerificationStatus -eq 'Awaiting remote confirmation') {
                        $item['Status'] = 'Awaiting remote confirmation'
                        $item['LastError'] = if ($jobStatus.LastError) { [string]$jobStatus.LastError } else { 'Remote state is temporarily unknown.' }
                        $item['VerificationRetryCount'] = [int]$item['VerificationRetryCount'] + 1
                        if ([int]$item['VerificationRetryCount'] -ge 6) {
                            $item['Status'] = 'Needs attention: remote verification unavailable'
                        } else {
                            $item['NextRetryUtc'] = $now.AddSeconds((Get-TransferRetryDelaySeconds -RetryCount ([int]$item['VerificationRetryCount']) -ErrorMessage ([string]$item['LastError'])))
                        }
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
                            $backoff = Get-TransferRetryDelaySeconds -RetryCount ([int]$item['RetryCount']) -ErrorMessage $err
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
                $verificationDue = if ($item.ContainsKey('NextRetryUtc') -and $item['NextRetryUtc'] -is [DateTime]) { [DateTime]$item['NextRetryUtc'] } else { [DateTime]::MinValue }
                if ($verificationDue -gt $now) { continue }
                # Strict progression: transition to the verification state.
                $item['Status'] = 'Verifying remote file'

                $vRes = $null
                try {
                    $vRes = Test-CloudTransferJobDestination -Job $item
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
                } elseif ($vRes -and $vRes['Status'] -eq 'Failed' -and [string]$vRes['Reason'] -match '(?i)(not found|size mismatch)') {
                    $retries = [int]$item['RetryCount']
                    $maxR = [int]$item['MaxRetries']
                    if ($retries -lt $maxR) {
                        $item['RetryCount'] = $retries + 1
                        $backoff = Get-TransferRetryDelaySeconds -RetryCount ([int]$item['RetryCount']) -ErrorMessage ([string]$vRes['Reason'])
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
                    $item['VerificationRetryCount'] = [int]$item['VerificationRetryCount'] + 1
                    $item['LastError'] = if ($vRes -and $vRes['Reason']) { [string]$vRes['Reason'] } else { 'Remote state could not be verified.' }
                    if ([int]$item['VerificationRetryCount'] -ge 6) {
                        $item['Status'] = 'Needs attention: remote verification unavailable'
                    } else {
                        $item['Status'] = 'Awaiting remote confirmation'
                        $item['NextRetryUtc'] = $now.AddSeconds((Get-TransferRetryDelaySeconds -RetryCount ([int]$item['VerificationRetryCount']) -ErrorMessage ([string]$item['LastError'])))
                    }
                    $stateChanged = $true
                }
            }
        }

        # Step 2: Concurrency bounds by the cloud provider that owns the transfer.
        # A download is bounded by its source provider; an upload or cloud copy by
        # its destination provider.
        $activeStatuses = @('Uploading', 'Upload pending remote confirmation', 'Awaiting remote confirmation', 'Verifying remote file')
        $tbActiveCount = 0
        $gdActiveCount = 0
        $otherActiveCount = 0
        foreach ($activeItem in @($script:CloudTransferQueue)) {
            if ($null -eq $activeItem -or [string]$activeItem['Status'] -notin $activeStatuses) { continue }
            $activeOperation = Get-CloudTransferJobOperation -Job $activeItem
            $concProvider = if ($activeOperation.IsValid -and $activeOperation.OperationType -eq 'Download') {
                [string]$activeOperation.SourceProvider
            } elseif ($activeOperation.IsValid) {
                [string]$activeOperation.DestinationProvider
            } else {
                'unknown'
            }
            switch ($concProvider) {
                'terabox' { $tbActiveCount++ }
                'gdrive' { $gdActiveCount++ }
                default { $otherActiveCount++ }
            }
        }

        $totalActiveCount = $tbActiveCount + $gdActiveCount + $otherActiveCount

        # Step 3: Schedule next eligible queued items
        while ($totalActiveCount -lt $MaxConcurrent) {
            $eligible = $null
            foreach ($q in @($script:CloudTransferQueue)) {
                if ($null -eq $q) { continue }
                if ([string]$q['ReconciliationStatus'] -eq 'Required') { continue }

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
                    $qOperation = Get-CloudTransferJobOperation -Job $q
                    if (-not $qOperation.IsValid) { continue }
                    $concProvider = if ($qOperation.OperationType -eq 'Download') { [string]$qOperation.SourceProvider } else { [string]$qOperation.DestinationProvider }
                    if ($concProvider -eq 'terabox' -and $tbActiveCount -ge 2) {
                        continue # Bounded: TeraBox max 2 concurrent workers
                    }
                    if ($concProvider -eq 'gdrive' -and $gdActiveCount -ge 4) {
                        continue # Bounded: Google Drive max 4 concurrent workers
                    }

                    $eligible = $q
                    break
                }
            }

            if (-not $eligible) {
                break
            }

            $eligibleOperation = Get-CloudTransferJobOperation -Job $eligible
            if (-not $eligibleOperation.IsValid) { continue }

            # The source-revision guard only applies to a local source. A remote
            # source path is not a local file and must not be reported as missing.
            if ($eligibleOperation.OperationType -eq 'Upload' -and
                $eligible.ContainsKey('TransferKey') -and $eligible['TransferKey'] -and
                $eligible.ContainsKey('SourceLastWriteUtc') -and $eligible['SourceLastWriteUtc']) {
                $sourceChanged = $false
                $sourceError = ''
                if (-not (Test-Path -LiteralPath ([string]$eligible['SourcePath']) -PathType Leaf)) {
                    $sourceChanged = $true
                    $sourceError = 'Source file is missing; restore it and rescan the folder.'
                } else {
                    $currentSource = [System.IO.FileInfo]::new([string]$eligible['SourcePath'])
                    if ([int64]$currentSource.Length -ne [int64]$eligible['FileSizeBytes'] -or
                        $currentSource.LastWriteTimeUtc.ToString('o') -ne [string]$eligible['SourceLastWriteUtc']) {
                        $sourceChanged = $true
                        $sourceError = 'Source file changed after queueing; rescan the folder to queue the current version.'
                    }
                }
                if ($sourceChanged) {
                    $eligible['Status'] = 'Needs attention: source file changed'
                    $eligible['LastError'] = $sourceError
                    $eligible['WorkerPid'] = 0
                    $eligible['CompletedUtc'] = $null
                    $stateChanged = $true
                    continue
                }
            }

            # Launch transfer for eligible item
            $eligible['Status'] = 'Uploading'
            $eligible['StartedUtc'] = [DateTime]::UtcNow
            $eligible['WorkerLeaseUtc'] = [DateTime]::UtcNow
            $eligible['LastProgressUtc'] = [DateTime]::UtcNow
            $eligibleBw = if ($eligible.ContainsKey('BandwidthLimit') -and $eligible['BandwidthLimit']) { [string]$eligible['BandwidthLimit'] } else { $GlobalBandwidthLimit }

            $destDirToPass = if ($eligibleOperation.OperationType -eq 'Download') {
                if ($eligible.ContainsKey('DestinationDirectory') -and $eligible['DestinationDirectory']) {
                    [string]$eligible['DestinationDirectory']
                } else {
                    [string]$eligible['DestinationPath']
                }
            } elseif ($eligible.ContainsKey('DestinationDirectory') -and $eligible['DestinationDirectory']) {
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
                    -OperationType $eligibleOperation.OperationType `
                    -BandwidthLimit $eligibleBw

                $eligible['JobId'] = $job.JobId
                $eligible['WorkerPid'] = if ($job.Process) { $job.Process.Id } else { 0 }
                $totalActiveCount++
                $concProvider = if ($eligibleOperation.OperationType -eq 'Download') { [string]$eligibleOperation.SourceProvider } else { [string]$eligibleOperation.DestinationProvider }
                if ($concProvider -eq 'terabox') { $tbActiveCount++ } else { $gdActiveCount++ }
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
                    $backoff = Get-TransferRetryDelaySeconds -RetryCount ([int]$eligible['RetryCount']) -ErrorMessage $err
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
        # Harvest settlement evidence before the completed jobs disappear.
        Update-CloudTransferSettledStagedLedger -Jobs @($script:CloudTransferQueue)
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
