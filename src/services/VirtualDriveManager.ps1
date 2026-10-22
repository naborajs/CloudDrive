Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\scripts\CachePathSafety.ps1')
. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

$script:DefaultDriveLetter = 'T'
$script:DefaultCacheDirectory = 'D:\CloudCache'
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

function Get-VirtualDriveStatus([string]$DriveLetter = $script:DefaultDriveLetter) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $driveRoot = "$letter`:\"
    $driveInfo = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq $driveRoot }

    $processAlive = $false
    if ($script:MountProcess -and (-not $script:MountProcess.HasExited)) {
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

        return [ordered]@{
            IsMounted = $true
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
    [string]$CacheDirectory = $script:DefaultCacheDirectory,
    [string]$ConfigPath = (Join-Path $env:APPDATA 'rclone\rclone.conf')
) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $driveRoot = "$letter`:\"
    $safeCache = Resolve-SafeCacheDirectory $CacheDirectory

    $args = @(
        'mount',
        "${RemoteName}:",
        $driveRoot,
        '--read-only',
        '--network-mode',
        '--volname', 'NS Cloud Drive',
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
    [string]$DriveLetter = $script:DefaultDriveLetter,
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

    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    $driveRoot = "$letter`:\"

    if (-not (Test-DriveLetterAvailable $letter)) {
        throw "Drive letter $letter`: is already occupied or mounted."
    }

    $mountArgs = Build-RcloneMountArguments -RemoteName $RemoteName -DriveLetter $letter -CacheDirectory $CacheDirectory -ConfigPath ''

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
    $script:MountProcess = $proc

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($proc.HasExited) {
            $err = $proc.StandardError.ReadToEnd()
            $script:MountProcess = $null
            throw "rclone mount exited prematurely (exit code $($proc.ExitCode)): $err"
        }

        $isMounted = [System.IO.DriveInfo]::GetDrives().Name -contains $driveRoot
        if ($isMounted) {
            return [ordered]@{
                Success = $true
                DriveLetter = $letter
                DriveRoot = $driveRoot
                ProcessId = $proc.Id
            }
        }

        [System.Threading.Thread]::Sleep(500)
    }

    # If timeout elapsed without mount appearing
    Stop-VirtualDriveMount
    throw "Mount operation timed out waiting for $driveRoot to appear in Windows."
}

function Stop-VirtualDriveMount {
    $stoppedAny = $false
    if ($script:MountProcess -and (-not $script:MountProcess.HasExited)) {
        try {
            $script:MountProcess.Kill()
            $script:MountProcess.WaitForExit(5000) | Out-Null
            $stoppedAny = $true
        } catch { }
        $script:MountProcess = $null
    }

    # Check for orphaned rclone mount processes using Win32_Process
    try {
        $orphans = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '\bmount\b' }
        foreach ($proc in $orphans) {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
                $stoppedAny = $true
            } catch { }
        }
    } catch { }

    # Brief delay to allow WinFsp kernel release
    [System.Threading.Thread]::Sleep(500)

    return [ordered]@{
        Success = $true
        Message = if ($stoppedAny) { 'Virtual drive unmounted cleanly.' } else { 'No active virtual drive mount found.' }
    }
}
