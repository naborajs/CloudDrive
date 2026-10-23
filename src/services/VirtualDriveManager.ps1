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

    # Clean stale MountPoints2 registry entries that cause Windows Explorer red X / offline overlays
    try {
        $mpKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2'
        if (Test-Path -LiteralPath $mpKey) {
            # Letter key, e.g. MountPoints2\G
            $letterSubKey = Join-Path $mpKey $letter
            if (Test-Path -LiteralPath $letterSubKey) {
                Remove-Item -LiteralPath $letterSubKey -Recurse -Force -ErrorAction SilentlyContinue
            }
            # Server share keys, e.g. ##server#Google Drive, ##server#TeraBox
            Get-ChildItem -LiteralPath $mpKey -ErrorAction SilentlyContinue | Where-Object {
                $_.PSChildName -like '##server#*'
            } | ForEach-Object {
                Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
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
            } elseif (-not [string]::IsNullOrEmpty($ProviderId)) {
                $letter = Get-PreferredDriveLetter $ProviderId
            } else {
                $letter = $script:DefaultDriveLetter
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
    } elseif ($script:MountProcess -and (-not $script:MountProcess.HasExited)) {
        $processAlive = $true
        $procId = $script:MountProcess.Id
    }

    if ($driveInfo) {
        $volumeLabel = $null
        $format = $null
        $freeSpace = [int64]0
        $totalSize = [int64]0

        try { $volumeLabel = $driveInfo.VolumeLabel } catch { }
        try { $format = $driveInfo.DriveFormat } catch { }
        try { $freeSpace = [int64]$driveInfo.AvailableFreeSpace } catch { }
        try { $totalSize = [int64]$driveInfo.TotalSize } catch { }

        # A drive is considered mounted ONLY if it is physically accessible AND supported by an active process or driver
        $isAccessible = $false
        try { $isAccessible = Test-Path -LiteralPath $driveRoot } catch { }

        $isManagedMount = $isAccessible -and $processAlive

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
    }
}

function Build-RcloneMountArguments(
    [string]$RemoteName,
    [string]$DriveLetter = $script:DefaultDriveLetter,
    [string]$VolumeLabel = '',
    [string]$CacheDirectory = $script:DefaultCacheDirectory,
    [string]$ConfigPath = (Join-Path $env:APPDATA 'rclone\rclone.conf'),
    [string]$LogFile = '',
    [switch]$ReadOnly = $false,
    [switch]$FixedDisk = $false
) {
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
        '--vfs-cache-max-size', '20G',
        '--vfs-cache-max-age', '24h',
        '--vfs-cache-poll-interval', '1m',
        '--vfs-write-back', '5s',
        '--dir-cache-time', '5m',
        '--attr-timeout', '1s',
        '--ask-password=false',
        '--log-level', 'ERROR'
    )

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
    [int]$TimeoutSeconds = 35
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
            $bridgeStatus = Start-TeraBoxBridge
            if ($bridgeStatus.Success) {
                $bridgeEnv = Get-TeraBoxBridgeRcloneEnvironment -BridgePassword $bridgeStatus.Password -Port $bridgeStatus.Port -RcloneBinary $rclonePath -RemoteName $RemoteName
                foreach ($k in $bridgeEnv.Keys) {
                    $EnvironmentVariables[$k] = $bridgeEnv[$k]
                }
            }
        } catch {
            throw "Failed to start TeraBox WebDAV bridge: $($_.Exception.Message)"
        }
    }

    $prefLetter = if (-not [string]::IsNullOrEmpty($DriveLetter)) { $DriveLetter } else { Get-PreferredDriveLetter $resolvedProvider }
    $cleanLetter = $prefLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $letter = if (Test-DriveLetterAvailable $cleanLetter) { $cleanLetter } else { Get-NextAvailableDriveLetter $cleanLetter }
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

    # Isolated cache directory per mountKey
    $providerCache = Join-Path $CacheDirectory $mountKey
    $mountArgs = Build-RcloneMountArguments -RemoteName $RemoteName -DriveLetter $letter -VolumeLabel $volName -CacheDirectory $providerCache -ConfigPath '' -LogFile $logPath -ReadOnly:$ReadOnly -FixedDisk
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
            return [ordered]@{
                Success = $true
                ProviderId = $resolvedProvider
                AccountId = $AccountId
                DriveLetter = $letter
                DriveRoot = $driveRoot
                VolumeLabel = $volName
                ProcessId = $proc.Id
                LogPath = $logPath
            }
        }

        [System.Threading.Thread]::Sleep(500)
    }

    # If timeout elapsed without mount appearing
    Stop-VirtualDriveMount -ProviderId $resolvedProvider -AccountId $AccountId
    throw "Mount operation timed out waiting for $driveRoot to appear in Windows."
}

function Stop-VirtualDriveMount(
    [string]$ProviderId = '',
    [string]$AccountId = '',
    [string]$DriveLetter = ''
) {
    $stoppedAny = $false

    # Determine which targets to stop
    $targets = @()
    $lettersToClean = @()
    if (-not [string]::IsNullOrEmpty($AccountId)) {
        $targets += $AccountId
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

    foreach ($target in $targets) {
        if ($script:ProviderDriveMapping.ContainsKey($target)) {
            $lettersToClean += $script:ProviderDriveMapping[$target]
        }
        if ($script:ActiveMountProcesses.ContainsKey($target)) {
            $p = $script:ActiveMountProcesses[$target]
            if ($p -and (-not $p.HasExited)) {
                try {
                    $p.Kill()
                    $p.WaitForExit(5000) | Out-Null
                    $stoppedAny = $true
                } catch { }
            }
            $script:ActiveMountProcesses.Remove($target)
        }
        if ($script:ProviderDriveMapping.ContainsKey($target)) {
            $script:ProviderDriveMapping.Remove($target)
        }
    }

    if ($targets.Count -eq 0 -and $script:MountProcess -and (-not $script:MountProcess.HasExited)) {
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
        try { Stop-TeraBoxBridge } catch { }
    }

    # Clean up any matching orphaned rclone processes
    try {
        $orphans = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '\bmount\b' }
        foreach ($proc in $orphans) {
            # If stopping a specific provider, only kill matching commandlines
            if (-not [string]::IsNullOrEmpty($ProviderId)) {
                if ($proc.CommandLine -match "${ProviderId}:") {
                    try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue; $stoppedAny = $true } catch { }
                }
            } else {
                try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue; $stoppedAny = $true } catch { }
            }
        }
    } catch { }

    [System.Threading.Thread]::Sleep(500)

    return [ordered]@{
        Success = $true
        Message = if ($stoppedAny) { 'Virtual drive unmounted cleanly.' } else { 'No active virtual drive mount found.' }
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
