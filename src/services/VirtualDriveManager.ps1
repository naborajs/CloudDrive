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

function Test-VirtualDriveFilesystem([string]$DriveRoot, [int]$TimeoutSeconds = 10) {
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

function Clear-StaleDriveLetterMapping([string]$DriveLetter) {
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

    # Remove only the stale Explorer cache entry for this drive letter. Server-share
    # entries belong to unrelated user mappings and must not be cleared globally.
    try {
        $mpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
        $letterSubKey = Join-Path $mpKey $letter
        if (Test-Path -LiteralPath $letterSubKey) {
            Remove-Item -LiteralPath $letterSubKey -Recurse -Force -ErrorAction SilentlyContinue
        }
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

function Find-ActiveMountProcess([string]$DriveLetter = '') {
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return $null }
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $targetPattern = "(?i)\bmount\b.*\s+[`"']?${letter}:\\?[`"']?(\s+|$)"

    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue
        if ($procs) {
            foreach ($p in $procs) {
                if ($p.CommandLine -and ($p.CommandLine -match $targetPattern)) {
                    return [ordered]@{
                        ProcessId = [int]$p.ProcessId
                        CommandLine = [string]$p.CommandLine
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
            $accs = Get-CloudAccounts
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

    $activeProc = Find-ActiveMountProcess -DriveLetter $letter
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
    } elseif ([string]::IsNullOrEmpty($AccountId) -and $script:MountProcess -and (-not $script:MountProcess.HasExited)) {
        $processAlive = $true
        $procId = $script:MountProcess.Id
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
    [switch]$FixedDisk = $false
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
        '--vfs-cache-max-age', '24h',
        '--vfs-cache-poll-interval', '1m',
        '--vfs-write-back', '5s',
        '--dir-cache-time', '15m',
        '--attr-timeout', '5s',
        '--links',
        '--ask-password=false',
        '--log-level', 'ERROR'
    )

    # Google Drive operations can leave WinFsp request threads waiting on remote
    # metadata or reads. Keep additional dispatcher capacity available so those
    # waits do not also starve unrelated Explorer metadata requests. This is
    # Google Drive-specific; TeraBox retains its current WinFsp defaults.
    if ($RemoteName -match '(?i)(^|[^a-z0-9])(?:gdrive|google)(?:$|[^a-z0-9])') {
        $args += @('--fuse-flag', '--ThreadCount=64')
    }

    if (-not [string]::IsNullOrEmpty($ConfigPath)) {
        $args += @('--config', $ConfigPath)
    }

    if (-not [string]::IsNullOrEmpty($LogFile)) {
        $args += @('--log-file', $LogFile)
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
    [int]$TimeoutSeconds = 90
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
    Clear-StaleDriveLetterMapping -DriveLetter $letter

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
    $mountArgs = Build-RcloneMountArguments -RemoteName $RemoteName -DriveLetter $letter -VolumeLabel $volName -CacheDirectory $providerCache -ConfigPath $mountConfigPath -LogFile $logPath -CacheMaxGigabytes $CacheMaxGigabytes -ReadOnly:$ReadOnly -FixedDisk
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

        $isMounted = [System.IO.DriveInfo]::GetDrives().Name -contains $driveRoot
        if ($isMounted) {
            $filesystemCheck = Test-VirtualDriveFilesystem -DriveRoot $driveRoot -TimeoutSeconds 10
            if (-not $filesystemCheck.Success) {
                $cleanup = Stop-VirtualDriveMount -ProviderId $resolvedProvider -AccountId $AccountId -DriveLetter $letter
                if (-not $cleanup.Success -or -not $cleanup.Verified) {
                    throw "Filesystem verification failed: $($filesystemCheck.Error) Cleanup could not be verified: $($cleanup.Message)"
                }
                throw "Mount process started, but filesystem verification failed: $($filesystemCheck.Error)"
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
                FilesystemVerified = $true
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
