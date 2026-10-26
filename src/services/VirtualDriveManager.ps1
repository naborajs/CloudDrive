Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\scripts\CachePathSafety.ps1')
. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'SettingsManager.ps1')
. (Join-Path $PSScriptRoot 'TeraBoxBridgeManager.ps1')

$script:DefaultDriveLetter = 'T'
$script:DefaultCacheDirectory = 'D:\CloudCache'
$script:ActiveMountProcesses = @{}
$script:ProviderDriveMapping = @{}
$script:MountProcess = $null
$script:VfsSmoothedSpeeds = @{}
$script:VfsItemSmoothedSpeeds = @{}

if (-not ([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveHelper').Type) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

namespace NSCloudDrive
{
    public static class VirtualDriveHelper
    {
        public static void PrewarmRoot(int rcPort)
        {
            if (rcPort <= 0) return;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    Thread.Sleep(200);
                    HttpWebRequest req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + rcPort + "/vfs/stats");
                    req.Method = "POST";
                    req.ContentType = "application/json";
                    req.Timeout = 4000;
                    using (WebResponse resp = req.GetResponse()) { }
                }
                catch { }
            });
        }
    }
}
"@ -ErrorAction SilentlyContinue
    } catch { }
}

if (-not ([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveKeepAliveHelper').Type) {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

namespace NSCloudDrive
{
    public static class VirtualDriveKeepAliveHelper
    {
        public static bool PingRc(int rcPort, int timeoutMs = 2000)
        {
            if (rcPort <= 0) return false;
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + rcPort + "/vfs/stats");
                req.Method = "POST";
                req.ContentType = "application/json";
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                byte[] body = Encoding.UTF8.GetBytes("{}");
                req.ContentLength = body.Length;
                using (Stream stream = req.GetRequestStream())
                {
                    stream.Write(body, 0, body.Length);
                }
                using (WebResponse resp = req.GetResponse()) { }
                return true;
            }
            catch
            {
                try
                {
                    HttpWebRequest req2 = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + rcPort + "/core/version");
                    req2.Method = "POST";
                    req2.ContentType = "application/json";
                    req2.Timeout = timeoutMs;
                    req2.ReadWriteTimeout = timeoutMs;
                    byte[] body2 = Encoding.UTF8.GetBytes("{}");
                    req2.ContentLength = body2.Length;
                    using (Stream stream2 = req2.GetRequestStream())
                    {
                        stream2.Write(body2, 0, body2.Length);
                    }
                    using (WebResponse resp2 = req2.GetResponse()) { }
                    return true;
                }
                catch
                {
                    return false;
                }
            }
        }

        public static void PingRcAsync(int rcPort, int timeoutMs = 2000)
        {
            if (rcPort <= 0) return;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                PingRc(rcPort, timeoutMs);
            });
        }

        public static bool PingDriveRoot(string driveRoot)
        {
            if (string.IsNullOrEmpty(driveRoot)) return false;
            try
            {
                DirectoryInfo di = new DirectoryInfo(driveRoot);
                if (di.Exists)
                {
                    var attr = di.Attributes;
                    return true;
                }
                return false;
            }
            catch
            {
                return false;
            }
        }

        public static void PingDriveRootAsync(string driveRoot)
        {
            if (string.IsNullOrEmpty(driveRoot)) return;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                PingDriveRoot(driveRoot);
            });
        }
    }
}
"@ -ErrorAction SilentlyContinue
    } catch { }
}

function Format-SafeProcessArgument([string]$Argument) {
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument -notmatch '[\s"\\]') { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\+)(")', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    $escaped = $escaped -replace '"', '\"'
    return "`"$escaped`""
}

function Find-RcloneBinary([string]$CustomPath = '') {
    if (-not [string]::IsNullOrEmpty($CustomPath) -and (Test-Path -LiteralPath $CustomPath -PathType Leaf)) {
        return $CustomPath
    }

    $candidates = @()
    if ($env:RCLONE_EXE_PATH) {
        $candidates += $env:RCLONE_EXE_PATH
    }
    $candidates += (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\rclone\rclone.exe')
    $candidates += (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra\rclone.exe')
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE 'Downloads\CloudPlayX\tools\rclone\rclone.exe')
        $candidates += (Join-Path $env:USERPROFILE 'Downloads\CloudPlayX_extracted\CloudPlayX\tools\rclone\rclone.exe')
    }

    $onPath = Get-Command 'rclone.exe' -ErrorAction SilentlyContinue
    if ($onPath) {
        $candidates += $onPath.Source
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Get-VerifiedRclonePath([string]$CustomPath = '') {
    $r = Find-RcloneBinary -CustomPath $CustomPath
    if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) {
        return $r
    }
    return $null
}

function Test-WinFspInstalled {
    $paths = @(
        'C:\Program Files (x86)\WinFsp\bin\winfsp-x64.dll',
        'C:\Program Files\WinFsp\bin\winfsp-x64.dll'
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { return $true }
    }

    # Check WinFsp registry keys for custom install locations
    $regKeys = @(
        'HKLM:\Software\WOW6432Node\WinFsp',
        'HKLM:\Software\WinFsp'
    )
    foreach ($regKey in $regKeys) {
        if (Test-Path -LiteralPath $regKey) {
            try {
                $installDir = (Get-ItemProperty -LiteralPath $regKey -Name 'InstallDir' -ErrorAction SilentlyContinue).InstallDir
                if ($installDir -and (Test-Path -LiteralPath (Join-Path $installDir 'bin\winfsp-x64.dll'))) {
                    return $true
                }
            } catch { }
        }
    }

    # Check service status
    $svc = Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        return $true
    }

    return $false
}

function Test-DriveLetterAvailable([string]$DriveLetter) {
    if ([string]::IsNullOrEmpty($DriveLetter)) { return $false }
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter.Length -ne 1) { return $false }
    $path = "$letter`:\"
    $used = [System.IO.DriveInfo]::GetDrives().Name -contains $path
    return (-not $used)
}

function Get-VirtualDriveRcPort([string]$DriveLetter) {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return 5580 }
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter.Length -ne 1) { return 5580 }
    return 5580 + ([int]$letter[0] - [int][char]'A')
}

function Test-VirtualDriveFilesystem([string]$DriveRoot, [int]$TimeoutSeconds = 5) {
    if ($DriveRoot -notmatch '^[A-Za-z]:\\$') { throw 'A valid drive root is required for the filesystem check.' }
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 30) { throw 'Filesystem check timeout must be between 1 and 30 seconds.' }

    # Enumerate the root in a child process so a stalled WinFsp callback cannot
    # hold the WPF dispatcher or this worker forever. The directory output is
    # discarded; only the process result is used as the accessibility signal.
    $command = 'dir /b "{0}" > NUL 2>&1' -f $DriveRoot
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $startInfo.Arguments = "/d /c $command"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            return [ordered]@{ Success = $false; State = 'Timeout'; Error = "Filesystem root did not respond within $TimeoutSeconds seconds." }
        }
        if ($process.ExitCode -ne 0) {
            return [ordered]@{ Success = $false; State = 'Unavailable'; Error = 'Windows could not enumerate the mounted filesystem root.' }
        }
        return [ordered]@{ Success = $true; State = 'Accessible'; Error = $null }
    } finally {
        $process.Dispose()
    }
}

function Clear-StaleDriveLetterMapping([string]$DriveLetter, [string]$VolumeLabel = '') {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return }
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter.Length -ne 1) { return }

    # Clean orphaned network redirector mapping if present (eliminates Explorer red X artifacts)
    try {
        $null = & net.exe use "$letter`:" /delete /y 2>&1
    } catch { }

    # Clean orphaned subst mapping if present
    try {
        $null = & subst.exe "$letter`:" /d 2>&1
    } catch { }

    # Clean stale HKCU:\Network\$letter if present
    try {
        $netKey = "HKCU:\Network\$letter"
        if (Test-Path -LiteralPath $netKey) {
            Remove-Item -LiteralPath $netKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }

    # Remove stale Explorer cache entry for this drive letter.
    try {
        $mpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
        $letterSubKey = Join-Path $mpKey $letter
        if (Test-Path -LiteralPath $letterSubKey) {
            Remove-Item -LiteralPath $letterSubKey -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Also purge any stale rclone/WinFsp network redirector keys (##server#*) that cause Explorer
        # to treat fixed disk mounts as "Network locations" with "\\server".
        try {
            $regBase = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2', $true)
            if ($regBase) {
                $purged = $false
                foreach ($subKey in $regBase.GetSubKeyNames()) {
                    if ([string]::IsNullOrEmpty($VolumeLabel) -or $subKey -eq "##server#$VolumeLabel" -or $subKey -like '##server#*') {
                        try {
                            $regBase.DeleteSubKeyTree($subKey)
                            $purged = $true
                        } catch { }
                    }
                }
                $regBase.Close()
                if ($purged -and ('NSCloudDrive.ExplorerNative' -as [type])) {
                    try {
                        [NSCloudDrive.ExplorerNative]::SHChangeNotify(0x08000000, 0x0000, $null, [IntPtr]::Zero)
                    } catch { }
                }
            }
        } catch { }
    } catch { }
}

function Get-NextAvailableDriveLetter([string]$PreferredLetter = 'T') {
    $cleanPref = $PreferredLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($cleanPref.Length -eq 1 -and (Test-DriveLetterAvailable $cleanPref)) {
        return $cleanPref
    }

    $candidates = @('G', 'T', 'S', 'V', 'W', 'X', 'Y', 'Z', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R')
    foreach ($cand in $candidates) {
        if (Test-DriveLetterAvailable $cand) {
            return $cand
        }
    }

    throw 'No available drive letters found on system.'
}

function Test-MountProcessOwnership([string]$CommandLine, [string]$DriveLetter, [string]$MountKey) {
    if ([string]::IsNullOrWhiteSpace($CommandLine) -or
        [string]::IsNullOrWhiteSpace($DriveLetter) -or
        [string]::IsNullOrWhiteSpace($MountKey)) { return $false }

    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $targetPattern = "(?i)\bmount\b.*\s+[`"']?${letter}:\\?[`"']?(\s+|$)"
    $logPattern = '(?i)(?:^|[\\/"\s])rclone-' + [regex]::Escape($MountKey) + '\.log(?:["\s]|$)'
    return ($CommandLine -match $targetPattern) -and ($CommandLine -match $logPattern)
}

function Find-ActiveMountProcess([string]$DriveLetter = '', [string]$MountKey = '') {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return $null }

    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($p in $procs) {
                $ownsMount = if ($MountKey) {
                    Test-MountProcessOwnership -CommandLine ([string]$p.CommandLine) -DriveLetter $DriveLetter -MountKey $MountKey
                } else {
                    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
                    $targetPattern = "(?i)\bmount\b.*\s+[`"']?${letter}:\\?[`"']?(\s+|$)"
                    [bool]($p.CommandLine -and ($p.CommandLine -match $targetPattern))
                }
                if ($ownsMount) {
                    return [ordered]@{
                        ProcessId = [int]$p.ProcessId
                        IsReadOnly = ($p.CommandLine -match '--read-only')
                    }
                }
            }
        }
    } catch { }
    return $null
}

function Get-VirtualDriveStatus(
    [string]$DriveLetter = '',
    [string]$ProviderId = '',
    [string]$AccountId = ''
) {
    $mountKey = if (-not [string]::IsNullOrEmpty($AccountId)) {
        $AccountId
    } elseif (-not [string]::IsNullOrEmpty($ProviderId)) {
        $ProviderId
    } else {
        ''
    }

    $letter = ''
    if (-not [string]::IsNullOrEmpty($DriveLetter)) {
        $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    } elseif (-not [string]::IsNullOrEmpty($mountKey) -and $script:ProviderDriveMapping.ContainsKey($mountKey)) {
        $letter = $script:ProviderDriveMapping[$mountKey]
    } elseif (-not [string]::IsNullOrEmpty($AccountId)) {
        try {
            $accs = @(Get-CloudAccounts)
            $matched = $accs | Where-Object { $_.Id -eq $AccountId } | Select-Object -First 1
            if ($matched -and $matched.DriveLetter) {
                $letter = $matched.DriveLetter
            } elseif ($matched -and -not [string]::IsNullOrEmpty($ProviderId)) {
                $letter = Get-PreferredDriveLetter $ProviderId
            } elseif ($matched) {
                $letter = $script:DefaultDriveLetter
            } else {
                # An unknown account must not inherit a provider's default letter;
                # that can make an unrelated primary mount look like this account.
                $letter = ''
            }
        } catch {
            $letter = $script:DefaultDriveLetter
        }
    } elseif (-not [string]::IsNullOrEmpty($ProviderId)) {
        $letter = Get-PreferredDriveLetter $ProviderId
    } else {
        $letter = $script:DefaultDriveLetter
    }

    $driveRoot = "$letter`:\"
    $driveInfo = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq $driveRoot }

    $activeProc = if ($mountKey) {
        Find-ActiveMountProcess -DriveLetter $letter -MountKey $mountKey
    } else {
        Find-ActiveMountProcess -DriveLetter $letter
    }
    $processAlive = $false
    $procId = $null
    $isReadOnly = $false

    if ($activeProc) {
        $processAlive = $true
        $procId = $activeProc.ProcessId
        $isReadOnly = $activeProc.IsReadOnly
        if (-not [string]::IsNullOrEmpty($mountKey)) {
            $script:ProviderDriveMapping[$mountKey] = $letter
        }
    } elseif (-not [string]::IsNullOrEmpty($mountKey) -and $script:ActiveMountProcesses.ContainsKey($mountKey)) {
        $p = $script:ActiveMountProcesses[$mountKey]
        if ($p -and (-not $p.HasExited)) {
            $processAlive = $true
            $procId = $p.Id
        }
    }

    if ($driveInfo) {
        # Do not probe the filesystem root or query volume metadata here. A WinFsp
        # provider can block those calls while its remote backend is slow, and this
        # function is called from the UI refresh timer. This is a local mount signal,
        # not a remote listing/read health check.
        $volumeLabel = $null
        $format = $null
        $freeSpace = [int64]0
        $totalSize = [int64]0
        $isManagedMount = $processAlive

        return [ordered]@{
            IsMounted = [bool]$isManagedMount
            ProviderId = $ProviderId
            AccountId = $AccountId
            DriveLetter = $letter
            DriveRoot = $driveRoot
            VolumeLabel = $volumeLabel
            Format = $format
            FreeSpace = $freeSpace
            TotalSize = $totalSize
            IsReadOnly = $isReadOnly
            ProcessRunning = $processAlive
            ProcessId = $procId
            MountState = $null
        }
    }

    return [ordered]@{
        IsMounted = $false
        ProviderId = $ProviderId
        AccountId = $AccountId
        DriveLetter = $letter
        DriveRoot = $driveRoot
        VolumeLabel = $null
        Format = $null
        FreeSpace = 0
        TotalSize = 0
        IsReadOnly = $false
        ProcessRunning = $processAlive
        ProcessId = $procId
        MountState = $null
    }
}

function Build-RcloneMountArguments(
    [string]$RemoteName,
    [string]$DriveLetter = $script:DefaultDriveLetter,
    [string]$VolumeLabel = '',
    [string]$CacheDirectory = $script:DefaultCacheDirectory,
    [string]$ConfigPath = (Join-Path $env:APPDATA 'rclone\rclone.conf'),
    [string]$LogFile = '',
    [int]$CacheMaxGigabytes = 20,
    [switch]$ReadOnly = $false,
    [switch]$FixedDisk = $false,
    [int]$RcPort = 0,
    [string]$InitialBwLimit = ''
) {
    if ($CacheMaxGigabytes -lt 1 -or $CacheMaxGigabytes -gt 1024) {
        throw 'The VFS cache limit must be between 1 and 1024 GB.'
    }
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $driveRoot = "$letter`:\"
    $safeCache = Resolve-SafeCacheDirectory $CacheDirectory

    $volName = if (-not [string]::IsNullOrEmpty($VolumeLabel)) {
        [regex]::Replace($VolumeLabel, '["\r\n]', '').Trim()
    } elseif ($RemoteName -match '(?i)gdrive|google') {
        'Google Drive'
    } elseif ($RemoteName -match '(?i)terabox') {
        'TeraBox'
    } else {
        'NS Cloud Drive'
    }
    if ([string]::IsNullOrWhiteSpace($volName)) { $volName = 'NS Cloud Drive' }

    $cleanRemote = [regex]::Replace($RemoteName, '[^a-zA-Z0-9_\-]', '_')
    $args = @(
        'mount',
        "${cleanRemote}:",
        $driveRoot
    )

    if ($ReadOnly) {
        $args += '--read-only'
    }

    if (-not $FixedDisk) {
        $args += '--network-mode'
    }

    $args += @(
        '--volname', $volName,
        '--cache-dir', $safeCache,
        '--vfs-cache-mode', 'full',
        '--vfs-cache-max-size', "${CacheMaxGigabytes}G",
        '--vfs-cache-max-age', '72h',
        '--vfs-cache-poll-interval', '2s',
        '--vfs-write-back', '1s',
        '--vfs-fast-fingerprint',
        '--vfs-read-chunk-size', '4M',
        '--vfs-read-chunk-size-limit', '32M',
        '--vfs-read-ahead', '16M',
        '--buffer-size', '16M',
        '--dir-cache-time', '72h',
        '--attr-timeout', '30s',
        '--links',
        '--ask-password=false',
        '--log-level', 'ERROR'
    )

    # WinFsp request threads: 64 threads for ALL mounts (both Google Drive and TeraBox).
    # Prevents concurrent metadata, thumbnail, EXIF, and streaming byte requests from starving
    # WinFsp's default 4-thread pool during media inspection (e.g. Windows Photos / Explorer),
    # eliminating RPC timeouts and application crashes.
    $args += @('--fuse-flag', '--ThreadCount=64')

    # Provider-tuned streaming chunk size and transfer concurrency
    if ($cleanRemote -match '(?i)(?:gdrive|google)') {
        $args += @(
            '--drive-chunk-size', '32M',
            '--drive-upload-cutoff', '32M',
            '--transfers', '4'
        )
    } elseif ($cleanRemote -match '(?i)terabox') {
        $args += @(
            '--transfers', '2'
        )
    } else {
        $args += @(
            '--transfers', '4'
        )
    }

    if (-not [string]::IsNullOrEmpty($InitialBwLimit) -and $InitialBwLimit -ne 'off') {
        $args += @('--bwlimit', $InitialBwLimit)
    }

    if (-not [string]::IsNullOrEmpty($ConfigPath)) {
        $args += @('--config', $ConfigPath)
    }

    if (-not [string]::IsNullOrEmpty($LogFile)) {
        $args += @('--log-file', $LogFile)
    }

    if ($RcPort -gt 0) {
        $args += @(
            '--rc',
            '--rc-addr', "127.0.0.1:$RcPort",
            '--rc-no-auth'
        )
    }

    # Set WinFsp filesystem name to NTFS so Windows File Explorer displays clean volume format
    $args += @('--fuse-flag', '--FileSystemName=NTFS')

    return $args
}

function Start-VirtualDriveMount(
    [Parameter(Mandatory = $true)]
    [string]$RemoteName,
    [string]$ProviderId = '',
    [string]$AccountId = '',
    [string]$DriveLetter = '',
    [string]$VolumeLabel = '',
    [string]$CacheDirectory = $script:DefaultCacheDirectory,
    [hashtable]$EnvironmentVariables = @{},
    [switch]$ReadOnly = $false,
    [int]$CacheMaxGigabytes = 20,
    [int]$TimeoutSeconds = 90,
    [string]$InitialBwLimit = '',
    [hashtable]$Progress = $null
) {
    if (-not (Test-WinFspInstalled)) {
        throw 'WinFsp is not installed or running. Cannot mount virtual drive.'
    }

    $rclonePath = Find-RcloneBinary
    if (-not $rclonePath) {
        throw 'No valid rclone executable found on this machine.'
    }

    $resolvedProvider = if (-not [string]::IsNullOrEmpty($ProviderId)) { $ProviderId } else { $RemoteName }
    $mountKey = if (-not [string]::IsNullOrEmpty($AccountId)) { $AccountId } elseif (-not [string]::IsNullOrEmpty($ProviderId)) { $ProviderId } else { $RemoteName }

    # If TeraBox is being mounted, start the local CPX WebDAV bridge and configure WebDAV rclone remote
    if ($RemoteName -eq 'terabox' -or $resolvedProvider -eq 'terabox') {
        try {
            $bridgeStatus = Start-TeraBoxBridge -AccountId $AccountId
            if ($bridgeStatus.Success) {
                $bridgeEnv = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword $bridgeStatus.Password -Port $bridgeStatus.Port -RcloneBinary $rclonePath -RemoteName $RemoteName
                foreach ($k in $bridgeEnv.Keys) {
                    $EnvironmentVariables[$k] = $bridgeEnv[$k]
                }
                $remoteKey = [regex]::Replace($RemoteName.ToUpperInvariant(), '[^A-Z0-9_]', '_')
                $sessionCookieKey = "RCLONE_CONFIG_${remoteKey}_COOKIE"
                if ($EnvironmentVariables.ContainsKey($sessionCookieKey)) { $EnvironmentVariables.Remove($sessionCookieKey) }
            }
        } catch {
            throw "Failed to start TeraBox WebDAV bridge: $($_.Exception.Message)"
        }
    }

    $prefLetter = if (-not [string]::IsNullOrEmpty($DriveLetter)) { $DriveLetter } else { Get-PreferredDriveLetter $resolvedProvider }
    $cleanLetter = $prefLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if (-not (Test-DriveLetterAvailable $cleanLetter)) {
        if (-not [string]::IsNullOrEmpty($DriveLetter)) {
            throw "Drive letter $cleanLetter`: is already in use. Choose another letter before mounting this account."
        }
        $cleanLetter = Get-NextAvailableDriveLetter $cleanLetter
    }
    $letter = $cleanLetter
    $driveRoot = "$letter`:\"

    $volName = if (-not [string]::IsNullOrEmpty($VolumeLabel)) {
        $VolumeLabel
    } elseif ($resolvedProvider -eq 'gdrive') {
        'Google Drive'
    } elseif ($resolvedProvider -eq 'terabox') {
        'TeraBox'
    } else {
        'NS Cloud Drive'
    }

    # Clean any stale/orphaned network or subst mapping for this drive letter to prevent Explorer red X artifacts
    Clear-StaleDriveLetterMapping -DriveLetter $letter -VolumeLabel $volName

    # Prepare rotating log file for this mount under %LOCALAPPDATA%\NSCloudDrive\logs\
    $logDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logPath = Join-Path $logDir "rclone-$mountKey.log"
    if (Test-Path -LiteralPath $logPath) {
        try {
            $fi = [System.IO.FileInfo]::new($logPath)
            if ($fi.Length -gt 5MB) {
                $oldLog = Join-Path $logDir "rclone-$mountKey.1.log"
                Move-Item -LiteralPath $logPath -Destination $oldLog -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    # Isolated cache and config namespace per mountKey
    $providerCache = Join-Path $CacheDirectory $mountKey
    $mountConfigPath = ''
    if (-not [string]::IsNullOrEmpty($AccountId)) {
        # Account mounts must not inherit settings from the user's global
        # rclone.conf: rclone can merge same-named remotes from that file
        # with the environment variables this application sets, so a global
        # "gdrive:" or "terabox:" remote could bleed unrelated keys (shared
        # drive flags, export formats, root folders) into a per-account
        # remote. An empty, app-owned config file guarantees each account's
        # remote is defined only by its own environment variables.
        $mountConfigPath = Join-Path (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config') 'account-mount-isolated.conf'
        if (-not (Test-Path -LiteralPath $mountConfigPath)) {
            try {
                $cfgDir = Split-Path -Parent $mountConfigPath
                if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
                [System.IO.File]::WriteAllText($mountConfigPath, '', [System.Text.Encoding]::ASCII)
            } catch { $mountConfigPath = '' }
        }
    }
    if ([string]::IsNullOrEmpty($InitialBwLimit)) {
        try {
            if (Get-Command Get-EffectiveBandwidthLimitRate -ErrorAction SilentlyContinue) {
                $InitialBwLimit = Get-EffectiveBandwidthLimitRate
            }
        } catch { }
    }
    $rcPort = Get-VirtualDriveRcPort -DriveLetter $letter
    $mountArgs = Build-RcloneMountArguments -RemoteName $RemoteName -DriveLetter $letter -VolumeLabel $volName -CacheDirectory $providerCache -ConfigPath $mountConfigPath -LogFile $logPath -CacheMaxGigabytes $CacheMaxGigabytes -ReadOnly:$ReadOnly -FixedDisk -RcPort $rcPort -InitialBwLimit $InitialBwLimit
    # Ensure mount target is clean drive letter without trailing backslash (e.g. 'G:') for rclone/WinFsp
    # This prevents Windows command-line escaping into '"G:\\"' and avoids fallback network share caching
    $mountArgs[2] = "$letter`:"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclonePath
    $psi.Arguments = ($mountArgs | ForEach-Object { Format-SafeProcessArgument $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Direct rclone output to log file rather than unconsumed pipe to prevent buffer deadlocks and broken pipe crashes
    $psi.RedirectStandardError = $false

    foreach ($key in $EnvironmentVariables.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$EnvironmentVariables[$key]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:ActiveMountProcesses[$mountKey] = $proc
    $script:ProviderDriveMapping[$mountKey] = $letter
    $script:MountProcess = $proc

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($proc.HasExited) {
            $err = ''
            if (Test-Path -LiteralPath $logPath) {
                try {
                    $err = (Get-Content -LiteralPath $logPath -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
                } catch { }
            }
            $script:ActiveMountProcesses.Remove($mountKey)
            $script:ProviderDriveMapping.Remove($mountKey)
            if ($script:MountProcess -eq $proc) { $script:MountProcess = $null }
            throw "rclone mount exited prematurely (exit code $($proc.ExitCode)): $err"
        }

        if ($rcPort -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge 4) {
            $isRcAlive = $false
            try {
                $null = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/core/version" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 1 -ErrorAction Stop
                $isRcAlive = $true
            } catch { }
            if ($isRcAlive -and $Progress -and $Progress.Stage -notmatch 'Waiting for provider readiness') {
                $Progress.Stage = 'Waiting for provider readiness...'
            }
        }

        $isMounted = [System.IO.DriveInfo]::GetDrives().Name -contains $driveRoot
        if ($isMounted) {
            if ($Progress) {
                $Progress.Stage = "Verifying $letter`: mount"
            }
            # Bounded root probe (reduced from default 10s to 5s for fast Google Drive responsiveness)
            # Legacy check signature: Test-VirtualDriveFilesystem -DriveRoot $driveRoot -TimeoutSeconds 10
            $filesystemCheck = Test-VirtualDriveFilesystem -DriveRoot $driveRoot -TimeoutSeconds 5
            $filesystemVerified = [bool]$filesystemCheck.Success

            if (-not $filesystemCheck.Success) {
                if ($filesystemCheck.State -eq 'Timeout') {
                    # Mount process remains running; probe rclone RC port responsiveness
                    $isProcAlive = ($null -ne $proc -and -not $proc.HasExited)
                    $isRcAlive = $false
                    if ($rcPort -gt 0) {
                        try {
                            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/vfs/stats" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 1 -ErrorAction Stop
                            $isRcAlive = $true
                        } catch {
                            try {
                                $null = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/core/version" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 1 -ErrorAction Stop
                                $isRcAlive = $true
                            } catch { }
                        }
                    }

                    if ($isProcAlive -and ($isRcAlive -or $rcPort -le 0)) {
                        # Slow initial directory response; allow a bounded retry of 3 seconds
                        $retryCheck = Test-VirtualDriveFilesystem -DriveRoot $driveRoot -TimeoutSeconds 3
                        if ($retryCheck.Success) {
                            $filesystemCheck = $retryCheck
                            $filesystemVerified = $true
                        } else {
                            # Drive letter is present in Windows and rclone process is alive;
                            # mark FilesystemUnverified rather than throwing an unrecoverable exception
                            $filesystemVerified = $false
                        }
                    } else {
                        throw "Mount process $($proc.Id) remains running, but the filesystem root check timed out and rclone RC is unresponsive: $($filesystemCheck.Error)"
                    }
                } else {
                    $cleanup = Stop-VirtualDriveMount -ProviderId $resolvedProvider -AccountId $AccountId -DriveLetter $letter
                    if (-not $cleanup.Success -or -not $cleanup.Verified) {
                        throw "Filesystem verification failed: $($filesystemCheck.Error) Cleanup could not be verified: $($cleanup.Message)"
                    }
                    throw "Mount process started, but filesystem verification failed: $($filesystemCheck.Error)"
                }
            }

            # Asynchronously pre-warm the root directory cache using native CLR threadpool
            # (avoids PowerShell ScriptBlock TLS crash in CLR ThreadPool)
            if ($rcPort -gt 0) {
                try {
                    if (([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveHelper').Type) {
                        [NSCloudDrive.VirtualDriveHelper]::PrewarmRoot($rcPort)
                    }
                } catch { }
            }

            # Reconcile any orphaned VFS cache directories from previous sessions/tokens
            try {
                Sync-VirtualDriveOrphanedVfsCache -CacheDirectory $CacheDirectory -AccountId $AccountId -DriveLetter $letter
            } catch {
                if (Get-Command Write-NSCloudLog -ErrorAction SilentlyContinue) {
                    try {
                        Write-NSCloudLog -Severity 'Warning' -AccountId $AccountId -Operation 'vfs-reconciliation' `
                            -Message "Non-blocking orphan cache sync failed: $($_.Exception.Message)"
                    } catch { }
                }
            }

            return [ordered]@{
                Success = $true
                ProviderId = $resolvedProvider
                AccountId = $AccountId
                DriveLetter = $letter
                DriveRoot = $driveRoot
                VolumeLabel = $volName
                ProcessId = $proc.Id
                LogPath = $logPath
                FilesystemVerified = $filesystemVerified # FilesystemVerified = $true when verified
                FilesystemUnverified = (-not $filesystemVerified)
                RcPort = $rcPort
            }
        }

        [System.Threading.Thread]::Sleep(500)
    }

    # If timeout elapsed without mount appearing
    $cleanup = Stop-VirtualDriveMount -ProviderId $resolvedProvider -AccountId $AccountId -DriveLetter $letter
    if (-not $cleanup.Success -or -not $cleanup.Verified) {
        throw "Mount operation timed out waiting for $driveRoot to appear in Windows, and cleanup could not be verified: $($cleanup.Message)"
    }
    throw "Mount operation timed out waiting for $driveRoot to appear in Windows."
}

function Stop-VirtualDriveMount(
    [string]$ProviderId = '',
    [string]$AccountId = '',
    [string]$DriveLetter = ''
) {
    $stoppedAny = $false
    $stopErrors = [System.Collections.Generic.List[string]]::new()
    $managedProcessIds = [System.Collections.Generic.List[int]]::new()

    # Determine which targets to stop
    $targets = @()
    $lettersToClean = @()
    if (-not [string]::IsNullOrEmpty($AccountId)) {
        $targets += $AccountId
        if ([string]::IsNullOrWhiteSpace($DriveLetter)) {
            try {
                $account = Get-CloudAccount -AccountId $AccountId
                if ($account -and $account.DriveLetter) {
                    $ownedLetter = ([string]$account.DriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\')
                    $lettersToClean += $ownedLetter
                }
            } catch { }
        }
    } elseif (-not [string]::IsNullOrEmpty($ProviderId)) {
        $targets += $ProviderId
    } elseif (-not [string]::IsNullOrEmpty($DriveLetter)) {
        $cleanLetter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
        $lettersToClean += $cleanLetter
        foreach ($pidKey in $script:ProviderDriveMapping.Keys) {
            if ($script:ProviderDriveMapping[$pidKey] -eq $cleanLetter) {
                $targets += $pidKey
            }
        }
    } else {
        $targets = @($script:ActiveMountProcesses.Keys)
    }
    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $lettersToClean += $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    }

    # The shared $script:MountProcess handle may point at any account's rclone
    # process (the most recently started mount). Killing it as a fallback while
    # servicing a scoped request would terminate an unrelated account's mount.
    $hasScopeFilter = (-not [string]::IsNullOrEmpty($AccountId)) -or
                      (-not [string]::IsNullOrEmpty($ProviderId)) -or
                      (-not [string]::IsNullOrEmpty($DriveLetter))

    foreach ($target in $targets) {
        if ($script:ProviderDriveMapping.ContainsKey($target)) {
            $lettersToClean += $script:ProviderDriveMapping[$target]
        }
        if ($script:ActiveMountProcesses.ContainsKey($target)) {
            $p = $script:ActiveMountProcesses[$target]
            if ($p -and (-not $p.HasExited)) {
                try {
                    $managedProcessIds.Add([int]$p.Id)
                    $p.Kill()
                    if ($p.WaitForExit(5000)) { $stoppedAny = $true }
                    else { $stopErrors.Add("Mount process $($p.Id) did not exit within 5 seconds.") }
                } catch { $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
            }
            $script:ActiveMountProcesses.Remove($target)
        }
        if ($script:ProviderDriveMapping.ContainsKey($target)) {
            $script:ProviderDriveMapping.Remove($target)
        }
    }

    if (-not $hasScopeFilter -and $targets.Count -eq 0 -and $script:MountProcess -and (-not $script:MountProcess.HasExited)) {
        try {
            $script:MountProcess.Kill()
            $script:MountProcess.WaitForExit(5000) | Out-Null
            $stoppedAny = $true
        } catch { }
        $script:MountProcess = $null
    }

    # Clean any stale network redirector or subst mappings for affected drive letters
    foreach ($cl in ($lettersToClean | Select-Object -Unique)) {
        Clear-StaleDriveLetterMapping -DriveLetter $cl
    }

    # If stopping TeraBox, also gracefully terminate TeraBox bridge daemon
    if ($ProviderId -eq 'terabox' -or $AccountId -match 'terabox' -or ($targets -contains 'terabox')) {
        try { Stop-TeraBoxBridge -AccountId $AccountId } catch { }
    }

    # Clean up any matching orphaned rclone processes. Ownership is decided by
    # the per-account cache/log path segment rclone was started with: account
    # mounts embed their AccountId, legacy provider mounts do not. A scoped
    # request must never terminate a process owned by a different account, and
    # a provider-wide request must not terminate any account-owned process.
    try {
        $savedAccountIds = @()
        try { $savedAccountIds = @((Get-CloudAccounts) | ForEach-Object { [string]$_.Id }) } catch { }
        $orphans = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '\bmount\b' }
        foreach ($proc in $orphans) {
            if ([string]::IsNullOrEmpty($proc.CommandLine)) { continue }
            $ownerAccountId = ''
            foreach ($accId in $savedAccountIds) {
                if (-not [string]::IsNullOrEmpty($accId) -and $proc.CommandLine.Contains($accId)) { $ownerAccountId = $accId; break }
            }

            if (-not [string]::IsNullOrEmpty($ownerAccountId)) {
                # Account-owned process: only a request scoped to this exact
                # account (and, when a letter is known, that letter) may stop it.
                if ([string]::Equals($ownerAccountId, [string]$AccountId, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ((-not [string]::IsNullOrEmpty($DriveLetter)) -or $lettersToClean.Count -gt 0) {
                        $ownedLetter = if (-not [string]::IsNullOrEmpty($DriveLetter)) {
                            $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
                        } else { [string]$lettersToClean[0] }
                        $targetPattern = "(?i)\bmount\b.*\s+[`"']?${ownedLetter}:\\?[`"']?(\s+|$)"
                        if ($proc.CommandLine -match $targetPattern) {
                            try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; $stoppedAny = $true } catch { $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
                        }
                    } else {
                        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; $stoppedAny = $true } catch { $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
                    }
                } elseif (-not $hasScopeFilter -and $proc.CommandLine -match '(?i)NSCloudDrive[\\/]+logs[\\/]+rclone-') {
                    try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; $stoppedAny = $true } catch { $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
                }
                continue
            }

            # Legacy (no account) mount process. Only legacy scopes reach here:
            # a request carrying an AccountId must never stop unowned mounts.
            if ([string]::IsNullOrEmpty($AccountId)) {
                $shouldStop = $false
                if ((-not [string]::IsNullOrEmpty($DriveLetter)) -and (-not [string]::IsNullOrEmpty($ProviderId))) {
                    $ownedLetter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
                    $targetPattern = "(?i)\bmount\b.*\s+[`"']?${ownedLetter}:\\?[`"']?(\s+|$)"
                    $shouldStop = ($proc.CommandLine -match $targetPattern -and $proc.CommandLine -match "(?i)\b${ProviderId}:")
                } elseif ([string]::IsNullOrEmpty($DriveLetter) -and (-not [string]::IsNullOrEmpty($ProviderId))) {
                    $shouldStop = ($proc.CommandLine -match "(?i)\b${ProviderId}:")
                } elseif ([string]::IsNullOrEmpty($DriveLetter) -and [string]::IsNullOrEmpty($ProviderId)) {
                    $shouldStop = $true
                }
                if ($shouldStop) {
                    try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; $stoppedAny = $true } catch { $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
                }
            } elseif (-not $hasScopeFilter) {
                # Unscoped shutdown is limited to this application's legacy
                # rclone processes. Never terminate unrelated rclone mounts.
                $appLogPattern = '(?i)NSCloudDrive[\\/]+logs[\\/]+rclone-'
                if ($proc.CommandLine -match $appLogPattern -or $managedProcessIds.Contains([int]$proc.ProcessId)) {
                    try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop; $stoppedAny = $true } catch { $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message))) }
                }
            }
        }
    } catch {
        $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)))
    }

    foreach ($cl in ($lettersToClean | Select-Object -Unique)) {
        Clear-StaleDriveLetterMapping -DriveLetter $cl
    }

    $cleanLetters = @($lettersToClean | Select-Object -Unique)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $remainingProcesses = @()
    $remainingDrives = @()
    do {
        $remainingProcesses = @()
        $remainingDrives = @()
        try {
            $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction Stop |
                Where-Object { $_.CommandLine -match '\bmount\b' })
            foreach ($proc in $processes) {
                $commandLine = [string]$proc.CommandLine
                $ownedByAccount = ''
                foreach ($accId in $savedAccountIds) {
                    if (-not [string]::IsNullOrEmpty($accId) -and $commandLine.Contains($accId)) {
                        $ownedByAccount = $accId
                        break
                    }
                }
                $matchesRequest = $false
                if (-not [string]::IsNullOrEmpty($AccountId)) {
                    $matchesRequest = [string]::Equals($ownedByAccount, $AccountId, [System.StringComparison]::OrdinalIgnoreCase)
                } elseif (-not [string]::IsNullOrEmpty($ProviderId)) {
                    if ([string]::IsNullOrEmpty($ownedByAccount) -and $commandLine -match "(?i)\b${ProviderId}:") {
                        if (-not [string]::IsNullOrEmpty($DriveLetter)) {
                            $cleanLetter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
                            $targetPattern = "(?i)\bmount\b.*\s+[`"']?${cleanLetter}:\\?[`"']?(\s+|$)"
                            $matchesRequest = $commandLine -match $targetPattern
                        } else {
                            $matchesRequest = $true
                        }
                    }
                } elseif ($commandLine -match '(?i)NSCloudDrive[\\/]+logs[\\/]+rclone-') {
                    $matchesRequest = $true
                }
                if ($matchesRequest) { $remainingProcesses += $proc }
            }
        } catch {
            $stopErrors.Add((Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)))
            break
        }

        foreach ($cl in $cleanLetters) {
            $root = "$cl`:\"
            if ([System.IO.DriveInfo]::GetDrives().Name -contains $root) {
                $remainingDrives += $root
            }
        }

        if ($remainingProcesses.Count -eq 0 -and $remainingDrives.Count -eq 0) {
            return [ordered]@{
                Success = $true
                Verified = $true
                Stopped = $stoppedAny
                Message = if ($stoppedAny) { 'Virtual drive unmounted and verified.' } else { 'No matching virtual drive mount remained.' }
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        [System.Threading.Thread]::Sleep(250)
    } while ($true)

    $details = [System.Collections.Generic.List[string]]::new()
    if ($remainingProcesses.Count -gt 0) { $details.Add("$($remainingProcesses.Count) matching rclone mount process(es) are still running.") }
    if ($remainingDrives.Count -gt 0) { $details.Add("Drive $([string]::Join(', ', $remainingDrives)) is still present in Windows.") }
    foreach ($errorText in $stopErrors) {
        if ($errorText) { $details.Add($errorText) }
    }
    return [ordered]@{
        Success = $false
        Verified = $false
        Stopped = $stoppedAny
        Message = [string]::Join(' ', $details.ToArray())
    }
}

function Get-CacheUsageStatistics([string]$CacheDirectory = $script:DefaultCacheDirectory) {
    $usedBytes = [int64]0
    if (Test-Path -LiteralPath $CacheDirectory) {
        try {
            $files = Get-ChildItem -LiteralPath $CacheDirectory -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                $usedBytes += [int64]$f.Length
            }
        } catch { }
    }

    $targetMaxBytes = [int64](20L * 1024L * 1024L * 1024L) # 20 GiB
    $volumeFreeBytes = [int64]0
    try {
        $root = [System.IO.Path]::GetPathRoot($CacheDirectory)
        $dInfo = [System.IO.DriveInfo]::new($root)
        if ($dInfo.IsReady) {
            $volumeFreeBytes = [int64]$dInfo.AvailableFreeSpace
        }
    } catch { }

    return [ordered]@{
        CacheDirectory = $CacheDirectory
        UsedBytes = $usedBytes
        UsedFormatted = "$([Math]::Round($usedBytes / 1GB, 2)) GiB"
        TargetMaxBytes = $targetMaxBytes
        TargetMaxFormatted = "20.00 GiB"
        VolumeFreeBytes = $volumeFreeBytes
        VolumeFreeFormatted = "$([Math]::Round($volumeFreeBytes / 1GB, 2)) GiB"
    }
}

function Test-VirtualDriveWriteSupported([string]$DriveLetter = '') {
    $status = Get-VirtualDriveStatus -DriveLetter $DriveLetter
    if (-not $status.IsMounted) { return $false }
    if ($status.IsReadOnly) { return $false }
    return $true
}

function Get-MountLogContent([string]$MountKey, [int]$Tail = 50) {
    $logDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs'
    $logPath = Join-Path $logDir "rclone-$MountKey.log"
    if (Test-Path -LiteralPath $logPath) {
        try {
            return (Get-Content -LiteralPath $logPath -Tail $Tail -ErrorAction SilentlyContinue)
        } catch { }
    }
    return @()
}

function Get-VirtualDriveVfsStats {
    [CmdletBinding()]
    param(
        [string]$DriveLetter = '',
        [string]$AccountId = '',
        [string]$ProviderId = ''
    )

    $letter = if ($DriveLetter) {
        $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    } else {
        $st = Get-VirtualDriveStatus -AccountId $AccountId -ProviderId $ProviderId
        if ($st -and $st.DriveLetter) { $st.DriveLetter } else { '' }
    }

    if (-not $letter) {
        return [ordered]@{
            IsActive = $false
            DriveLetter = ''
            RcPort = 0
            UploadsInProgress = 0
            UploadsQueued = 0
            BytesTransferred = 0L
            TotalBytes = 0L
            TransferSpeed = 0.0
            SmoothedSpeed = 0.0
            OverallEta = $null
            SmoothedEta = $null
            Errors = 0
            LastError = $null
            Transferring = @()
            QueuedItems = @()
            AllTransfers = @()
            CacheBytesUsed = 0L
            DiskCachePath = ''
            DiskCacheMetaPath = ''
            State = 'Remote state unknown'
        }
    }

    $rcPort = Get-VirtualDriveRcPort -DriveLetter $letter

    try {
        $vfsResp = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/vfs/stats" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 1 -ErrorAction Stop
        $coreResp = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/core/stats" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 1 -ErrorAction Stop

        $uploadsInProg = 0
        $uploadsQueued = 0
        $cacheBytes = 0L
        $diskCachePath = ''
        $diskCacheMetaPath = ''
        if ($vfsResp -and $vfsResp.PSObject.Properties['diskCache'] -and $vfsResp.diskCache) {
            $dc = $vfsResp.diskCache
            if ($dc.PSObject.Properties['uploadsInProgress']) { $uploadsInProg = [int]$dc.uploadsInProgress }
            if ($dc.PSObject.Properties['uploadsQueued']) { $uploadsQueued = [int]$dc.uploadsQueued }
            if ($dc.PSObject.Properties['bytesUsed']) { $cacheBytes = [int64]$dc.bytesUsed }
            if ($dc.PSObject.Properties['path'] -and $dc.path) { $diskCachePath = [string]$dc.path }
            if ($dc.PSObject.Properties['pathMeta'] -and $dc.pathMeta) { $diskCacheMetaPath = [string]$dc.pathMeta }
        }

        $bTrans = 0L
        $speed = 0.0
        $errCount = 0
        $lastErr = $null
        $transferring = @()

        $totalBytes = 0L
        $overallEta = $null
        if ($coreResp) {
            if ($coreResp.PSObject.Properties['bytes']) { $bTrans = [int64]$coreResp.bytes }
            if ($coreResp.PSObject.Properties['totalBytes']) { $totalBytes = [int64]$coreResp.totalBytes }
            if ($coreResp.PSObject.Properties['speed']) { $speed = [double]$coreResp.speed }
            if ($coreResp.PSObject.Properties['errors']) { $errCount = [int]$coreResp.errors }
            if ($coreResp.PSObject.Properties['eta'] -and $null -ne $coreResp.eta) { $overallEta = [int]$coreResp.eta }
            if ($coreResp.PSObject.Properties['lastError'] -and $coreResp.lastError) { $lastErr = [string]$coreResp.lastError }
            if ($coreResp.PSObject.Properties['transferring'] -and $coreResp.transferring) {
                foreach ($t in $coreResp.transferring) {
                    $rawName = if ($t.PSObject.Properties['name']) { [string]$t.name } else { '' }
                    $baseName = if ($rawName) { [System.IO.Path]::GetFileName($rawName) } else { '' }
                    $itemSize = if ($t.PSObject.Properties['size']) { [int64]$t.size } else { 0L }
                    $itemBytes = if ($t.PSObject.Properties['bytes']) { [int64]$t.bytes } else { 0L }
                    $itemPct = if ($t.PSObject.Properties['percentage']) { [double]$t.percentage } else { 0.0 }
                    $itemSpd = if ($t.PSObject.Properties['speed']) { [double]$t.speed } else { 0.0 }
                    $itemKey = "$letter`:$rawName"

                    $prevItemSpd = if ($script:VfsItemSmoothedSpeeds.ContainsKey($itemKey)) { [double]$script:VfsItemSmoothedSpeeds[$itemKey] } else { 0.0 }
                    $smoothedItemSpd = if ($prevItemSpd -gt 0 -and $itemSpd -gt 0) {
                        (0.25 * $itemSpd) + (0.75 * $prevItemSpd)
                    } elseif ($itemSpd -gt 0) {
                        $itemSpd
                    } else {
                        0.0
                    }
                    $script:VfsItemSmoothedSpeeds[$itemKey] = $smoothedItemSpd

                    $itemRemaining = [Math]::Max(0L, $itemSize - $itemBytes)
                    $itemEta = if ($itemRemaining -eq 0L) {
                        0
                    } elseif ($smoothedItemSpd -ge 256.0) {
                        [Math]::Min(2592000, [int][Math]::Round($itemRemaining / $smoothedItemSpd))
                    } elseif ($t.PSObject.Properties['eta'] -and $null -ne $t.eta) {
                        [int]$t.eta
                    } else {
                        $null
                    }

                    $srcFs = if ($t.PSObject.Properties['srcFs']) { [string]$t.srcFs } else { '' }
                    $dstFs = if ($t.PSObject.Properties['dstFs']) { [string]$t.dstFs } else { '' }
                    $isUpload = ($uploadsInProg -gt 0 -or $uploadsQueued -gt 0)
                    if ($srcFs -match '(?i)CloudCache' -or ($dstFs -and $dstFs -match '(?i)(?:gdrive|terabox)')) {
                        $isUpload = $true
                    } elseif ($srcFs -match '(?i)(?:gdrive|terabox)') {
                        $isUpload = $false
                    }
                    $transferState = if ($isUpload) { 'Uploading to cloud' } else { 'Streaming from cloud' }
                    $direction = if ($isUpload) { 'Upload' } else { 'Download' }

                    $transferring += [ordered]@{
                        TransferId = "$letter`:$baseName"
                        Name = $baseName
                        RelativePath = $rawName
                        Size = $itemSize
                        Bytes = $itemBytes
                        Percentage = $itemPct
                        Speed = $itemSpd
                        SmoothedSpeed = $smoothedItemSpd
                        Eta = $itemEta
                        State = $transferState
                        Drive = $letter
                        SrcFs = $srcFs
                        DstFs = $dstFs
                        IsUpload = $isUpload
                        Direction = $direction
                    }
                }
            }
        }

        # Query vfs/queue for staged files queued for upload
        $queuedItems = @()
        try {
            $qResp = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/vfs/queue" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 1 -ErrorAction SilentlyContinue
            if ($qResp -and $qResp.PSObject.Properties['queue'] -and $qResp.queue) {
                foreach ($qi in $qResp.queue) {
                    $qName = if ($qi.PSObject.Properties['name']) { [string]$qi.name } else { '' }
                    $qSize = if ($qi.PSObject.Properties['size']) { [int64]$qi.size } else { 0L }
                    $qId = if ($qi.PSObject.Properties['id']) { [int]$qi.id } else { 0 }
                    $qExpiry = if ($qi.PSObject.Properties['expiry']) { [string]$qi.expiry } else { '' }
                    $shortName = if ($qName) { [System.IO.Path]::GetFileName($qName) } else { '' }
                    $queuedItems += [ordered]@{
                        TransferId = "$letter`:$shortName"
                        QueueId = $qId
                        Name = $shortName
                        RelativePath = $qName
                        Size = $qSize
                        Bytes = 0L
                        Percentage = 0.0
                        Speed = 0.0
                        SmoothedSpeed = 0.0
                        Eta = $null
                        State = 'Queued for cloud upload'
                        Drive = $letter
                        Expiry = $qExpiry
                        IsUpload = $true
                        Direction = 'Upload'
                    }
                }
            }
        } catch { }

        # Smooth speed using Exponential Moving Average (alpha = 0.25)
        $prevSpeed = if ($script:VfsSmoothedSpeeds.ContainsKey($letter)) { [double]$script:VfsSmoothedSpeeds[$letter] } else { 0.0 }
        $smoothedSpeed = if ($prevSpeed -gt 0 -and $speed -gt 0) {
            (0.25 * $speed) + (0.75 * $prevSpeed)
        } elseif ($speed -gt 0) {
            $speed
        } else {
            0.0
        }
        $script:VfsSmoothedSpeeds[$letter] = $smoothedSpeed

        # Jitter-free bounded ETA
        $remainingBytes = [Math]::Max(0L, $totalBytes - $bTrans)
        $smoothedEta = if ($remainingBytes -eq 0L) {
            0
        } elseif ($smoothedSpeed -ge 256.0) {
            [Math]::Min(2592000, [int][Math]::Round($remainingBytes / $smoothedSpeed))
        } else {
            $overallEta
        }

        $state = if ($errCount -gt 0 -and $uploadsInProg -eq 0 -and $uploadsQueued -eq 0) {
            'Failed'
        } elseif ($uploadsInProg -gt 0) {
            'Uploading to provider'
        } elseif ($uploadsQueued -gt 0) {
            'Locally cached or queued'
        } else {
            'Remotely confirmed'
        }

        return [ordered]@{
            IsActive = $true
            DriveLetter = $letter
            RcPort = $rcPort
            UploadsInProgress = $uploadsInProg
            UploadsQueued = $uploadsQueued
            BytesTransferred = $bTrans
            TotalBytes = $totalBytes
            TransferSpeed = $speed
            SmoothedSpeed = $smoothedSpeed
            OverallEta = $overallEta
            SmoothedEta = $smoothedEta
            Errors = $errCount
            LastError = $lastErr
            Transferring = $transferring
            QueuedItems = $queuedItems
            AllTransfers = (@($transferring) + @($queuedItems))
            CacheBytesUsed = $cacheBytes
            DiskCachePath = $diskCachePath
            DiskCacheMetaPath = $diskCacheMetaPath
            State = $state
        }
    } catch {
        return [ordered]@{
            IsActive = $false
            DriveLetter = $letter
            RcPort = $rcPort
            UploadsInProgress = 0
            UploadsQueued = 0
            BytesTransferred = 0L
            TotalBytes = 0L
            TransferSpeed = 0.0
            SmoothedSpeed = 0.0
            OverallEta = $null
            SmoothedEta = $null
            Errors = 0
            LastError = $null
            Transferring = @()
            QueuedItems = @()
            AllTransfers = @()
            CacheBytesUsed = 0L
            DiskCachePath = ''
            DiskCacheMetaPath = ''
            State = 'Remote state unknown'
        }
    }
}

function Set-VirtualDriveBandwidthLimit {
    [CmdletBinding()]
    param(
        [string]$DriveLetter = '',
        [string]$Rate = 'off'
    )

    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $rcPort = Get-VirtualDriveRcPort -DriveLetter $letter
    if ($rcPort -le 0) { return $false }

    try {
        $body = @{ rate = $Rate } | ConvertTo-Json
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/core/bwlimit" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 2 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-VirtualDriveBandwidthLimit {
    [CmdletBinding()]
    param(
        [string]$DriveLetter = ''
    )

    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $rcPort = Get-VirtualDriveRcPort -DriveLetter $letter
    if ($rcPort -le 0) { return $null }

    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/core/bwlimit" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 1 -ErrorAction Stop
        return $resp
    } catch {
        return $null
    }
}

function Set-AllVirtualDrivesBandwidthLimit {
    [CmdletBinding()]
    param(
        [string]$Rate = 'off'
    )
    $results = @{}
    try {
        $accounts = @(Get-CloudAccounts)
        foreach ($acc in $accounts) {
            $letter = [string]$acc.DriveLetter
            if ($letter) {
                $ok = Set-VirtualDriveBandwidthLimit -DriveLetter $letter -Rate $Rate
                $results[$letter] = $ok
            }
        }
    } catch { }
    return $results
}

function Reset-VirtualDriveStats {
    [CmdletBinding()]
    param(
        [string]$DriveLetter = ''
    )

    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $rcPort = Get-VirtualDriveRcPort -DriveLetter $letter
    if ($rcPort -le 0) { return $false }

    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/core/stats-reset" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 2 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-VirtualDriveActiveErrors {
    [CmdletBinding()]
    param(
        [string]$DriveLetter = '',
        [string]$AccountId = '',
        [string]$ProviderId = ''
    )

    $stats = Get-VirtualDriveVfsStats -DriveLetter $DriveLetter -AccountId $AccountId -ProviderId $ProviderId
    $errors = [System.Collections.Generic.List[string]]::new()

    if ($stats.LastError) {
        $errors.Add($stats.LastError)
    }

    $mountKey = if ($AccountId) { $AccountId } elseif ($ProviderId) { $ProviderId } else { '' }
    if ($mountKey) {
        $logPath = Join-Path (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs') "rclone-$mountKey.log"
        if (Test-Path -LiteralPath $logPath) {
            try {
                $lines = Get-Content -LiteralPath $logPath -Tail 25 -ErrorAction SilentlyContinue
                foreach ($line in $lines) {
                    if ($line -match '(?i)ERROR\s*:\s*(.+)$') {
                        $errText = $matches[1].Trim()
                        if (-not $errors.Contains($errText)) {
                            $errors.Add($errText)
                        }
                    }
                }
            } catch { }
        }
    }

    return @($errors)
}

function Invoke-VirtualDriveCacheRefresh(
    [int]$RcPort,
    [string]$Dir = '',
    [switch]$Recursive = $false
) {
    if ($RcPort -le 0) { return $false }
    try {
        $body = @{}
        if (-not [string]::IsNullOrEmpty($Dir)) {
            $body['dir'] = $Dir
        }
        if ($Recursive) {
            $body['recursive'] = $true
        }
        $jsonBody = $body | ConvertTo-Json -Compress
        $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$RcPort/vfs/refresh")
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Timeout = 6000
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        $resp = $req.GetResponse()
        $resp.Close()
        return $true
    } catch {
        return $false
    }
}

function Stop-VirtualDriveTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter,
        [string]$FileName = ''
    )

    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')

    $status = Get-VirtualDriveStatus -DriveLetter $letter
    if (-not $status.IsMounted) {
        return [ordered]@{
            Success = $false
            State = 'Failed'
            DriveLetter = $letter
            Error = "Drive ${letter}: is not mounted."
        }
    }

    $rcPort = Get-VirtualDriveRcPort -DriveLetter $letter
    if ($rcPort -le 0) {
        return [ordered]@{
            Success = $false
            State = 'Failed'
            DriveLetter = $letter
            Error = 'No valid RC port available for virtual drive'
        }
    }

    try {
        # 1. Temporarily throttle bandwidth to freeze upload packet flow
        Set-VirtualDriveBandwidthLimit -DriveLetter $letter -Rate '1B' | Out-Null

        # 2. Check and suspend items in the VFS upload queue
        try {
            $qResp = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/vfs/queue" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 2 -ErrorAction Stop
            if ($qResp -and $qResp.PSObject.Properties['queue'] -and $qResp.queue) {
                foreach ($item in $qResp.queue) {
                    $itemName = if ($item.PSObject.Properties['name']) { [string]$item.name } else { '' }
                    if ([string]::IsNullOrEmpty($FileName) -or $itemName -like "*$FileName*") {
                        if ($item.PSObject.Properties['id']) {
                            # Set expiry 1000 days in future to freeze the item from being uploaded
                            $body = @{ id = [int]$item.id; expiry = 86400000.0 } | ConvertTo-Json
                            Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/vfs/queue-set-expiry" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 2 -ErrorAction SilentlyContinue | Out-Null
                        }
                    }
                }
            }
        } catch { }

        # 3. Reset VFS and core transfer statistics
        Reset-VirtualDriveStats -DriveLetter $letter | Out-Null

        # 4. Release bandwidth limit back to normal
        Set-VirtualDriveBandwidthLimit -DriveLetter $letter -Rate 'off' | Out-Null

        return [ordered]@{
            Success = $true
            State = 'Cancelled'
            DriveLetter = $letter
            CancelledAt = [DateTime]::UtcNow
        }
    } catch {
        # Restore bandwidth on error
        try { Set-VirtualDriveBandwidthLimit -DriveLetter $letter -Rate 'off' | Out-Null } catch { }
        return [ordered]@{
            Success = $false
            State = 'Failed'
            DriveLetter = $letter
            Error = $_.Exception.Message
        }
    }
}

function Sync-VirtualDriveOrphanedVfsCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$CacheDirectory = $script:DefaultCacheDirectory,
        [Parameter(Mandatory = $false)]
        [string]$AccountId = '',
        [Parameter(Mandatory = $false)]
        [string]$DriveLetter = ''
    )

    $results = [System.Collections.Generic.List[PSObject]]::new()
    if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
        $CacheDirectory = $script:DefaultCacheDirectory
    }
    if (-not (Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
        return @($results.ToArray())
    }

    # Discover candidate account directories:
    # 1. If $AccountId is specified: $CacheDirectory\$AccountId (or $CacheDirectory itself if matching)
    # 2. Otherwise: all subdirectories of $CacheDirectory containing a 'vfs' folder, plus $CacheDirectory\vfs if present
    $accountDirs = [System.Collections.Generic.List[PSObject]]::new()

    if (-not [string]::IsNullOrEmpty($AccountId)) {
        $specificDir = Join-Path $CacheDirectory $AccountId
        if (Test-Path -LiteralPath (Join-Path $specificDir 'vfs') -PathType Container) {
            $accountDirs.Add([pscustomobject]@{ Id = $AccountId; Path = $specificDir })
        } elseif (Test-Path -LiteralPath (Join-Path $CacheDirectory 'vfs') -PathType Container) {
            $accountDirs.Add([pscustomobject]@{ Id = $AccountId; Path = $CacheDirectory })
        }
    } else {
        try {
            $subDirs = @(Get-ChildItem -LiteralPath $CacheDirectory -Directory -Force -ErrorAction SilentlyContinue)
            if ($subDirs.Count -gt 0) {
                foreach ($sd in $subDirs) {
                    $subVfs = Join-Path $sd.FullName 'vfs'
                    if (Test-Path -LiteralPath $subVfs -PathType Container) {
                        $accId = $sd.Name
                        $accountDirs.Add([pscustomobject]@{ Id = $accId; Path = $sd.FullName })
                    }
                }
            }
        } catch { }

        if ($accountDirs.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $CacheDirectory 'vfs') -PathType Container)) {
            $accountDirs.Add([pscustomobject]@{ Id = 'default'; Path = $CacheDirectory })
        }
    }

    foreach ($acc in $accountDirs) {
        $accId = [string]$acc.Id
        $accPath = [string]$acc.Path
        $vfsBase = Join-Path $accPath 'vfs'
        $metaBase = Join-Path $accPath 'vfsMeta'

        if (-not (Test-Path -LiteralPath $vfsBase -PathType Container)) {
            continue
        }

        # Step 1: Discover the active VFS cache path
        $activeVfs = ''
        $activeMeta = ''

        # Attempt A: Query Get-VirtualDriveVfsStats using DriveLetter or AccountId
        $candidateLetter = if (-not [string]::IsNullOrEmpty($DriveLetter)) {
            $DriveLetter
        } elseif ((Get-Variable -Name 'ProviderDriveMapping' -Scope Script -ErrorAction SilentlyContinue) -and $script:ProviderDriveMapping.ContainsKey($accId)) {
            [string]$script:ProviderDriveMapping[$accId]
        } else {
            ''
        }

        if (-not [string]::IsNullOrEmpty($candidateLetter)) {
            try {
                $vfsStats = Get-VirtualDriveVfsStats -DriveLetter $candidateLetter -AccountId $accId
                if ($vfsStats -and $vfsStats.PSObject.Properties['IsActive'] -and $vfsStats.IsActive -eq $true) {
                    if ($vfsStats.PSObject.Properties['DiskCachePath'] -and $vfsStats.DiskCachePath) {
                        $rawPath = [string]$vfsStats.DiskCachePath -replace '^\\\\\?\\', ''
                        if ($rawPath.StartsWith($vfsBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $activeVfs = $rawPath.TrimEnd('\', '/')
                        }
                    }
                    if ($vfsStats.PSObject.Properties['DiskCacheMetaPath'] -and $vfsStats.DiskCacheMetaPath) {
                        $rawMeta = [string]$vfsStats.DiskCacheMetaPath -replace '^\\\\\?\\', ''
                        if ($rawMeta.StartsWith($metaBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $activeMeta = $rawMeta.TrimEnd('\', '/')
                        }
                    }
                }
            } catch { }
        }

        # Attempt B: Fallback to the newest {hash} directory under <account>/vfs
        $hashDirs = @(Get-ChildItem -LiteralPath $vfsBase -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\{[^\}]+\}$' } |
            Sort-Object -Property LastWriteTimeUtc -Descending)

        if ([string]::IsNullOrEmpty($activeVfs)) {
            if ($hashDirs.Count -gt 0) {
                $activeVfs = $hashDirs[0].FullName.TrimEnd('\', '/')
            } else {
                # Fallback to newest directory under vfsBase if no {hash} directory matched
                $allDirs = @(Get-ChildItem -LiteralPath $vfsBase -Directory -Force -ErrorAction SilentlyContinue |
                    Sort-Object -Property LastWriteTimeUtc -Descending)
                if ($allDirs.Count -gt 0) {
                    $activeVfs = $allDirs[0].FullName.TrimEnd('\', '/')
                }
            }
        }

        if ([string]::IsNullOrEmpty($activeVfs)) {
            continue
        }

        if ([string]::IsNullOrEmpty($activeMeta)) {
            $activeLeaf = Split-Path -Path $activeVfs -Leaf
            $activeMeta = Join-Path $metaBase $activeLeaf
        }

        # Step 2: Enumerate all other orphaned / historical directories under vfsBase
        $allVfsDirs = @(Get-ChildItem -LiteralPath $vfsBase -Directory -Force -ErrorAction SilentlyContinue)
        $orphanDirs = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
        foreach ($d in $allVfsDirs) {
            if ($d.FullName.TrimEnd('\', '/') -ne $activeVfs) {
                $orphanDirs.Add($d)
            }
        }

        if ($orphanDirs.Count -eq 0) {
            # No orphaned directories to reconcile for this account
            $results.Add([pscustomobject]@{
                AccountId             = $accId
                ActiveVfsPath         = $activeVfs
                MigratedFiles         = 0
                MigratedBytes         = 0L
                DuplicateFilesRemoved = 0
                CleanedDirectories    = 0
            })
            continue
        }

        # Ensure active target directories exist
        if (-not (Test-Path -LiteralPath $activeVfs -PathType Container)) {
            New-Item -ItemType Directory -Path $activeVfs -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $activeMeta -PathType Container)) {
            New-Item -ItemType Directory -Path $activeMeta -Force | Out-Null
        }

        $migratedCount = 0
        $migratedBytes = 0L
        $duplicateCount = 0
        $cleanedDirs = 0

        # Process orphan directories from oldest to newest so newest files win
        $sortedOrphans = @($orphanDirs | Sort-Object -Property LastWriteTimeUtc)

        foreach ($orphanDir in $sortedOrphans) {
            $orphanVfsDir = $orphanDir.FullName.TrimEnd('\', '/')
            $orphanLeaf = $orphanDir.Name
            $orphanMetaDir = Join-Path $metaBase $orphanLeaf

            $orphanFiles = @(Get-ChildItem -LiteralPath $orphanVfsDir -Recurse -File -Force -ErrorAction SilentlyContinue)
            $orphanVfsPrefix = $orphanVfsDir + '\'

            foreach ($of in $orphanFiles) {
                # Skip temporary / lock / partial files
                if ($of.Name -like '*.tmp' -or
                    $of.Name -like '*.partial' -or
                    $of.Name -like '*.lock' -or
                    $of.Name -like '*.rclone-tmp' -or
                    $of.Name -like '*~' -or
                    $of.Name -like '.write_test_*') {
                    continue
                }

                $relPath = if ($of.FullName.StartsWith($orphanVfsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $of.FullName.Substring($orphanVfsPrefix.Length)
                } else {
                    $of.Name
                }

                $targetVfsFile = Join-Path $activeVfs $relPath
                $targetMetaFile = Join-Path $activeMeta $relPath
                $sourceMetaFile = Join-Path $orphanMetaDir $relPath

                $targetExists = Test-Path -LiteralPath $targetVfsFile -PathType Leaf

                if ($targetExists) {
                    # Target exists: evaluate whether orphan is newer or more complete
                    $targetItem = Get-Item -LiteralPath $targetVfsFile -Force -ErrorAction SilentlyContinue
                    $shouldOverwrite = $false
                    if ($targetItem) {
                        if ($of.Length -gt $targetItem.Length) {
                            $shouldOverwrite = $true
                        } elseif ($of.Length -eq $targetItem.Length -and $of.LastWriteTimeUtc -gt $targetItem.LastWriteTimeUtc) {
                            $shouldOverwrite = $true
                        }
                    }

                    if ($shouldOverwrite) {
                        try {
                            Copy-Item -LiteralPath $of.FullName -Destination $targetVfsFile -Force -ErrorAction Stop
                            Remove-Item -LiteralPath $of.FullName -Force -ErrorAction SilentlyContinue
                            $migratedCount++
                            $migratedBytes += [int64]$of.Length

                            if (Test-Path -LiteralPath $sourceMetaFile -PathType Leaf) {
                                Copy-Item -LiteralPath $sourceMetaFile -Destination $targetMetaFile -Force -ErrorAction SilentlyContinue
                                Remove-Item -LiteralPath $sourceMetaFile -Force -ErrorAction SilentlyContinue
                            }
                        } catch {
                            if (Get-Command Write-NSCloudLog -ErrorAction SilentlyContinue) {
                                try {
                                    Write-NSCloudLog -Severity 'Warning' -AccountId $accId -Operation 'vfs-reconciliation' `
                                        -Message "Failed to overwrite duplicate active file with newer orphan file $($of.FullName): $($_.Exception.Message)"
                                } catch { }
                            }
                        }
                    } else {
                        # Target is already equal or better: safely clean up redundant orphan file
                        try {
                            Remove-Item -LiteralPath $of.FullName -Force -ErrorAction SilentlyContinue
                            $duplicateCount++
                            if (Test-Path -LiteralPath $sourceMetaFile -PathType Leaf) {
                                Remove-Item -LiteralPath $sourceMetaFile -Force -ErrorAction SilentlyContinue
                            }
                        } catch { }
                    }
                } else {
                    # Target does not exist: migrate file and its metadata to active VFS cache
                    try {
                        $targetDir = [System.IO.Path]::GetDirectoryName($targetVfsFile)
                        if ($targetDir -and -not (Test-Path -LiteralPath $targetDir -PathType Container)) {
                            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                        }

                        # Move file atomically
                        Move-Item -LiteralPath $of.FullName -Destination $targetVfsFile -Force -ErrorAction Stop
                        $migratedCount++
                        $migratedBytes += [int64]$of.Length

                        # Move matching vfsMeta file if present
                        if (Test-Path -LiteralPath $sourceMetaFile -PathType Leaf) {
                            $targetMetaDir = [System.IO.Path]::GetDirectoryName($targetMetaFile)
                            if ($targetMetaDir -and -not (Test-Path -LiteralPath $targetMetaDir -PathType Container)) {
                                New-Item -ItemType Directory -Path $targetMetaDir -Force | Out-Null
                            }
                            Move-Item -LiteralPath $sourceMetaFile -Destination $targetMetaFile -Force -ErrorAction SilentlyContinue
                        }
                    } catch {
                        if (Get-Command Write-NSCloudLog -ErrorAction SilentlyContinue) {
                            try {
                                Write-NSCloudLog -Severity 'Warning' -AccountId $accId -Operation 'vfs-reconciliation' `
                                    -Message "Failed to migrate orphan file $($of.FullName) to active VFS: $($_.Exception.Message)"
                            } catch { }
                        }
                    }
                }
            }

            # If orphan VFS directory is now empty of files, clean it up
            $remainingFiles = @(Get-ChildItem -LiteralPath $orphanVfsDir -Recurse -File -Force -ErrorAction SilentlyContinue)
            if ($remainingFiles.Count -eq 0) {
                try {
                    Remove-Item -LiteralPath $orphanVfsDir -Recurse -Force -ErrorAction SilentlyContinue
                    $cleanedDirs++
                } catch { }
            }

            # Also clean up orphan vfsMeta directory if empty
            if (Test-Path -LiteralPath $orphanMetaDir -PathType Container) {
                $remainingMeta = @(Get-ChildItem -LiteralPath $orphanMetaDir -Recurse -File -Force -ErrorAction SilentlyContinue)
                if ($remainingMeta.Count -eq 0) {
                    try {
                        Remove-Item -LiteralPath $orphanMetaDir -Recurse -Force -ErrorAction SilentlyContinue
                    } catch { }
                }
            }
        }

        # If files were migrated and the mount is active, trigger rclone cache refresh
        if ($migratedCount -gt 0 -and -not [string]::IsNullOrEmpty($candidateLetter)) {
            $rcPort = Get-VirtualDriveRcPort -DriveLetter $candidateLetter
            if ($rcPort -gt 0) {
                try {
                    $null = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/vfs/refresh" -Method Post `
                        -ContentType 'application/json' -Body '{"recursive":true}' -TimeoutSec 2 -ErrorAction SilentlyContinue
                } catch { }
            }
        }

        if ($migratedCount -gt 0 -or $duplicateCount -gt 0 -or $cleanedDirs -gt 0) {
            $logMsg = "Reconciled orphaned VFS cache for account '$accId': migrated $migratedCount staged file(s) ($migratedBytes bytes), removed $duplicateCount redundant duplicate(s), cleaned $cleanedDirs orphaned hash folder(s)."
            if (Get-Command Write-NSCloudLog -ErrorAction SilentlyContinue) {
                try {
                    Write-NSCloudLog -Severity 'Info' -AccountId $accId -Operation 'vfs-reconciliation' -Message $logMsg
                } catch { }
            }
        }

        $results.Add([pscustomobject]@{
            AccountId             = $accId
            ActiveVfsPath         = $activeVfs
            MigratedFiles         = $migratedCount
            MigratedBytes         = $migratedBytes
            DuplicateFilesRemoved = $duplicateCount
            CleanedDirectories    = $cleanedDirs
        })
    }

    return @($results.ToArray())
}

function Get-VirtualDrivePendingUploads {
    [CmdletBinding()]
    param(
        [string]$CacheDirectory = $script:DefaultCacheDirectory,
        [string[]]$MountCacheDirectories = @()
    )

    $pendingMap = [System.Collections.Generic.Dictionary[string, PSObject]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        return ,@()
    }

    # Discover candidate directories that contain a 'vfs' folder:
    # 1. $CacheDirectory\vfs (legacy flat structure)
    # 2. $CacheDirectory\<account>\vfs
    # 3. Explicit $MountCacheDirectories if provided
    $targets = [System.Collections.Generic.List[string]]::new()
    $rootVfs = Join-Path $CacheDirectory 'vfs'
    if (Test-Path -LiteralPath $rootVfs -PathType Container) {
        $targets.Add($rootVfs)
    }

    try {
        $subDirs = @(Get-ChildItem -LiteralPath $CacheDirectory -Directory -Force -ErrorAction SilentlyContinue)
        if ($subDirs.Count -gt 0) {
            foreach ($sd in $subDirs) {
                $subVfs = Join-Path $sd.FullName 'vfs'
                if (Test-Path -LiteralPath $subVfs -PathType Container) {
                    $targets.Add($subVfs)
                }
            }
        }
    } catch { }

    if ($MountCacheDirectories) {
        foreach ($mDir in $MountCacheDirectories) {
            if (-not $mDir) { continue }
            $mVfs = Join-Path $mDir 'vfs'
            if (Test-Path -LiteralPath $mVfs -PathType Container) {
                if (-not $targets.Contains($mVfs)) { $targets.Add($mVfs) }
            } elseif (Test-Path -LiteralPath $mDir -PathType Container) {
                if (-not $targets.Contains($mDir)) { $targets.Add($mDir) }
            }
        }
    }

    foreach ($vfsDir in $targets) {
        try {
            $files = @(Get-ChildItem -LiteralPath $vfsDir -Recurse -File -Force -ErrorAction SilentlyContinue)
            if ($files.Count -eq 0) { continue }

            $vfsPrefix = $vfsDir.TrimEnd('\', '/') + '\'

            foreach ($f in $files) {
                # Ignore temporary / lock / partial files
                if ($f.Name -like '*.tmp' -or
                    $f.Name -like '*.partial' -or
                    $f.Name -like '*.lock' -or
                    $f.Name -like '*.rclone-tmp' -or
                    $f.Name -like '*~' -or
                    $f.Name -like '.write_test_*') {
                    continue
                }

                # Derive matching vfsMeta path
                $metaPath = $f.FullName -replace '([\\/])vfs([\\/])', '$1vfsMeta$2'
                $isDirty = $false
                $hasMeta = $false

                if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
                    $hasMeta = $true
                    try {
                        $metaContent = Get-Content -LiteralPath $metaPath -Raw -ErrorAction Stop
                        $metaJson = $metaContent | ConvertFrom-Json
                        if ($metaJson -and $metaJson.PSObject.Properties['Dirty'] -and $metaJson.Dirty -eq $true) {
                            $isDirty = $true
                        }
                    } catch {
                        # If meta cannot be read, verify if file is in use/locked before treating as dirty
                        try {
                            $testStream = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                            $testStream.Close()
                            $testStream.Dispose()
                        } catch {
                            $isDirty = $true
                        }
                    }
                } else {
                    # No vfsMeta yet; only treat as pending if actively locked/written or in an active upload queue.
                    # Do NOT treat arbitrary read-cache files or 0-byte orphan files without vfsMeta as pending uploads.
                    if ($f.Length -gt 0) {
                        try {
                            $testStream = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                            $testStream.Close()
                            $testStream.Dispose()
                        } catch {
                            $isDirty = $true
                        }
                    }
                }

                # Only include truly dirty staged files (not clean read/synced cache)
                if ($isDirty) {
                    # Infer account ID from path if inside <accountId>/vfs
                    $accId = ''
                    $provId = ''
                    $parentDir = [System.IO.Path]::GetDirectoryName($vfsDir)
                    if ($parentDir) {
                        $parentName = [System.IO.Path]::GetFileName($parentDir)
                        if ($parentName -match '^(gdrive|terabox)(?:_(.+))?$') {
                            $provId = $Matches[1]
                            $accId = $parentName
                        }
                    }

                    # Determine logical relative path inside virtual drive (strip remote{hash} / remote folder)
                    $relToVfs = if ($f.FullName.StartsWith($vfsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $f.FullName.Substring($vfsPrefix.Length)
                    } else {
                        $f.Name
                    }

                    $firstSlash = $relToVfs.IndexOfAny(@([char]'/', [char]'\'))
                    $logicalRelPath = $relToVfs
                    if ($firstSlash -gt 0) {
                        $firstSeg = $relToVfs.Substring(0, $firstSlash)
                        if ($firstSeg -match '\{[^\}]+\}$' -or $firstSeg -match '^(?:gdrive|terabox)$') {
                            $logicalRelPath = $relToVfs.Substring($firstSlash + 1)
                        }
                    }

                    # Deduplicate across multiple hash folders for the same account & file path
                    $dedupeKey = "$accId|$logicalRelPath"
                    $shouldReplace = $false
                    if (-not $pendingMap.ContainsKey($dedupeKey)) {
                        $shouldReplace = $true
                    } else {
                        $existing = $pendingMap[$dedupeKey]
                        # Retain newest / most complete version
                        if ($f.Length -gt $existing.Length) {
                            $shouldReplace = $true
                        } elseif ($f.Length -eq $existing.Length) {
                            if ($f.LastWriteTimeUtc -gt $existing.LastWriteTimeUtc) {
                                $shouldReplace = $true
                            } elseif ($f.LastWriteTimeUtc -eq $existing.LastWriteTimeUtc) {
                                if ($hasMeta -and -not $existing.HasMeta) {
                                    $shouldReplace = $true
                                }
                            }
                        }
                    }

                    if ($shouldReplace) {
                        $pendingMap[$dedupeKey] = [pscustomobject]@{
                            Path = $f.FullName
                            Name = $f.Name
                            RelativePath = $logicalRelPath
                            Length = [int64]$f.Length
                            LastWriteTimeUtc = $f.LastWriteTimeUtc
                            AccountId = $accId
                            ProviderId = $provId
                            IsDirty = $true
                            HasMeta = $hasMeta
                            State = 'UploadPending'
                        }
                    }
                }
            }
        } catch { }
    }

    if ($pendingMap.Count -eq 0) {
        return ,@()
    }
    return @($pendingMap.Values)
}

function Invoke-VirtualDriveKeepAlive {
    [CmdletBinding()]
    param(
        [switch]$Synchronous = $false
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $script:ActiveMountProcesses -or $script:ActiveMountProcesses.Count -eq 0) {
        return @($results.ToArray())
    }

    $activeKeys = @($script:ActiveMountProcesses.Keys)
    foreach ($key in $activeKeys) {
        try {
            if (-not $script:ActiveMountProcesses.ContainsKey($key)) { continue }
            $proc = $script:ActiveMountProcesses[$key]
            if ($null -eq $proc -or $proc.HasExited) { continue }

            $letter = ''
            if ($script:ProviderDriveMapping.ContainsKey($key)) {
                $letter = [string]$script:ProviderDriveMapping[$key]
            }

            $driveRoot = if (-not [string]::IsNullOrEmpty($letter)) {
                "$($letter.ToUpperInvariant().TrimEnd(':').TrimEnd('\'))`:\"
            } else { '' }

            $rcPort = 0
            if (-not [string]::IsNullOrEmpty($letter)) {
                $rcPort = Get-VirtualDriveRcPort $letter
            }

            $success = $false
            $method = if ($rcPort -gt 0) { 'RC' } else { 'DriveStat' }

            if ($rcPort -gt 0) {
                if ($Synchronous) {
                    if (([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveKeepAliveHelper').Type) {
                        $success = [NSCloudDrive.VirtualDriveKeepAliveHelper]::PingRc($rcPort, 2000)
                    } else {
                        try {
                            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/vfs/stats" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 2 -ErrorAction Stop
                            $success = $true
                        } catch {
                            try {
                                $null = Invoke-RestMethod -Uri "http://127.0.0.1:$rcPort/core/version" -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 2 -ErrorAction Stop
                                $success = $true
                            } catch { }
                        }
                    }
                } else {
                    if (([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveKeepAliveHelper').Type) {
                        [NSCloudDrive.VirtualDriveKeepAliveHelper]::PingRcAsync($rcPort, 2000)
                    } else {
                        [NSCloudDrive.VirtualDriveHelper]::PrewarmRoot($rcPort)
                    }
                    $success = $true
                }
            } elseif (-not [string]::IsNullOrEmpty($driveRoot)) {
                if ($Synchronous) {
                    if (([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveKeepAliveHelper').Type) {
                        $success = [NSCloudDrive.VirtualDriveKeepAliveHelper]::PingDriveRoot($driveRoot)
                    } else {
                        $success = [System.IO.Directory]::Exists($driveRoot)
                    }
                } else {
                    if (([System.Management.Automation.PSTypeName]'NSCloudDrive.VirtualDriveKeepAliveHelper').Type) {
                        [NSCloudDrive.VirtualDriveKeepAliveHelper]::PingDriveRootAsync($driveRoot)
                    } else {
                        try {
                            $null = [System.IO.Directory]::Exists($driveRoot)
                        } catch { }
                    }
                    $success = $true
                }
            }

            $results.Add([pscustomobject]@{
                MountKey        = $key
                DriveLetter     = $letter
                DriveRoot       = $driveRoot
                RcPort          = $rcPort
                KeepAliveMethod = $method
                Success         = $success
            })
        } catch { }
    }

    return @($results.ToArray())
}
