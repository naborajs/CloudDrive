Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\scripts\CachePathSafety.ps1')
. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot 'SettingsManager.ps1')

$script:DefaultDriveLetter = 'T'
$script:DefaultCacheDirectory = 'D:\CloudCache'
$script:ActiveMountProcesses = @{}
$script:ProviderDriveMapping = @{}
$script:MountProcess = $null

function Find-RcloneBinary([string]$CustomPath = '') {
    if (-not [string]::IsNullOrEmpty($CustomPath) -and (Test-Path -LiteralPath $CustomPath -PathType Leaf)) {
        return $CustomPath
    }

    $candidates = @()
    if ($env:RCLONE_EXE_PATH) {
        $candidates += $env:RCLONE_EXE_PATH
    }
    $candidates += (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra\rclone.exe')
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE 'Downloads\CloudPlayX\tools\rclone\rclone.exe')
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

function Get-VirtualDriveStatus(
    [string]$DriveLetter = '',
    [string]$ProviderId = ''
) {
    $letter = ''
    if (-not [string]::IsNullOrEmpty($DriveLetter)) {
        $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    } elseif (-not [string]::IsNullOrEmpty($ProviderId)) {
        if ($script:ProviderDriveMapping.ContainsKey($ProviderId)) {
            $letter = $script:ProviderDriveMapping[$ProviderId]
        } else {
            $letter = Get-PreferredDriveLetter $ProviderId
        }
    } else {
        $letter = $script:DefaultDriveLetter
    }

    $driveRoot = "$letter`:\"
    $driveInfo = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq $driveRoot }

    $processAlive = $false
    if (-not [string]::IsNullOrEmpty($ProviderId) -and $script:ActiveMountProcesses.ContainsKey($ProviderId)) {
        $p = $script:ActiveMountProcesses[$ProviderId]
        if ($p -and (-not $p.HasExited)) { $processAlive = $true }
    } elseif ($script:MountProcess -and (-not $script:MountProcess.HasExited)) {
        $processAlive = $true
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

        # A drive is only considered mounted by this virtual drive manager if:
        # 1. An active rclone mount process is running for it, OR
        # 2. It is a WinFsp/FUSE filesystem created with our provider volume label
        $isManagedMount = $processAlive -or (
            $format -and ($format -like '*WinFsp*' -or $format -like '*FUSE*') -and
            ($volumeLabel -in @('Google Drive', 'TeraBox', 'NS Cloud Drive'))
        )

        return [ordered]@{
            IsMounted = [bool]$isManagedMount
            ProviderId = $ProviderId
            DriveLetter = $letter
            DriveRoot = $driveRoot
            VolumeLabel = $volumeLabel
            Format = $format
            FreeSpace = $freeSpace
            TotalSize = $totalSize
            ProcessRunning = $processAlive
        }
    }

    return [ordered]@{
        IsMounted = $false
        ProviderId = $ProviderId
        DriveLetter = $letter
        DriveRoot = $driveRoot
        VolumeLabel = $null
        Format = $null
        FreeSpace = 0
        TotalSize = 0
        ProcessRunning = $processAlive
    }
}

function Build-RcloneMountArguments(
    [string]$RemoteName,
    [string]$DriveLetter = $script:DefaultDriveLetter,
    [string]$VolumeLabel = '',
    [string]$CacheDirectory = $script:DefaultCacheDirectory,
    [string]$ConfigPath = (Join-Path $env:APPDATA 'rclone\rclone.conf')
) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $driveRoot = "$letter`:\"
    $safeCache = Resolve-SafeCacheDirectory $CacheDirectory

    $volName = if (-not [string]::IsNullOrEmpty($VolumeLabel)) {
        $VolumeLabel
    } elseif ($RemoteName -match '(?i)gdrive|google') {
        'Google Drive'
    } elseif ($RemoteName -match '(?i)terabox') {
        'TeraBox'
    } else {
        'NS Cloud Drive'
    }

    $args = @(
        'mount',
        "${RemoteName}:",
        $driveRoot,
        '--read-only',
        '--network-mode',
        '--volname', $volName,
        '--cache-dir', $safeCache,
        '--vfs-cache-mode', 'full',
        '--vfs-cache-max-size', '20G',
        '--vfs-cache-max-age', '24h',
        '--vfs-cache-poll-interval', '1m',
        '--dir-cache-time', '5m',
        '--attr-timeout', '1s',
        '--ask-password=false',
        '--log-level', 'ERROR'
    )

    if (-not [string]::IsNullOrEmpty($ConfigPath)) {
        $args += @('--config', $ConfigPath)
    }

    return $args
}

function Start-VirtualDriveMount(
    [Parameter(Mandatory = $true)]
    [string]$RemoteName,
    [string]$ProviderId = '',
    [string]$DriveLetter = '',
    [string]$VolumeLabel = '',
    [string]$CacheDirectory = $script:DefaultCacheDirectory,
    [hashtable]$EnvironmentVariables = @{},
    [int]$TimeoutSeconds = 15
) {
    if (-not (Test-WinFspInstalled)) {
        throw 'WinFsp is not installed or running. Cannot mount virtual drive.'
    }

    $rclonePath = Find-RcloneBinary
    if (-not $rclonePath) {
        throw 'No valid rclone executable found on this machine.'
    }

    $resolvedProvider = if (-not [string]::IsNullOrEmpty($ProviderId)) { $ProviderId } else { $RemoteName }
    $prefLetter = if (-not [string]::IsNullOrEmpty($DriveLetter)) { $DriveLetter } else { Get-PreferredDriveLetter $resolvedProvider }
    $letter = Get-NextAvailableDriveLetter $prefLetter
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

    # Isolated provider cache directory
    $providerCache = Join-Path $CacheDirectory $resolvedProvider
    $mountArgs = Build-RcloneMountArguments -RemoteName $RemoteName -DriveLetter $letter -VolumeLabel $volName -CacheDirectory $providerCache -ConfigPath ''

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclonePath
    $psi.Arguments = ($mountArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true

    foreach ($key in $EnvironmentVariables.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$EnvironmentVariables[$key]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:ActiveMountProcesses[$resolvedProvider] = $proc
    $script:ProviderDriveMapping[$resolvedProvider] = $letter
    $script:MountProcess = $proc

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($proc.HasExited) {
            $err = $proc.StandardError.ReadToEnd()
            $script:ActiveMountProcesses.Remove($resolvedProvider)
            $script:ProviderDriveMapping.Remove($resolvedProvider)
            if ($script:MountProcess -eq $proc) { $script:MountProcess = $null }
            throw "rclone mount exited prematurely (exit code $($proc.ExitCode)): $err"
        }

        $isMounted = [System.IO.DriveInfo]::GetDrives().Name -contains $driveRoot
        if ($isMounted) {
            return [ordered]@{
                Success = $true
                ProviderId = $resolvedProvider
                DriveLetter = $letter
                DriveRoot = $driveRoot
                VolumeLabel = $volName
                ProcessId = $proc.Id
            }
        }

        [System.Threading.Thread]::Sleep(500)
    }

    # If timeout elapsed without mount appearing
    Stop-VirtualDriveMount -ProviderId $resolvedProvider
    throw "Mount operation timed out waiting for $driveRoot to appear in Windows."
}

function Stop-VirtualDriveMount(
    [string]$ProviderId = '',
    [string]$DriveLetter = ''
) {
    $stoppedAny = $false

    # Determine which providers to stop
    $targets = @()
    if (-not [string]::IsNullOrEmpty($ProviderId)) {
        $targets += $ProviderId
    } elseif (-not [string]::IsNullOrEmpty($DriveLetter)) {
        $cleanLetter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
        foreach ($pidKey in $script:ProviderDriveMapping.Keys) {
            if ($script:ProviderDriveMapping[$pidKey] -eq $cleanLetter) {
                $targets += $pidKey
            }
        }
    } else {
        $targets = @($script:ActiveMountProcesses.Keys)
    }

    foreach ($target in $targets) {
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
