Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\..\scripts\CachePathSafety.ps1')
. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')

$script:DefaultDriveLetter = 'T'
$script:DefaultCacheDirectory = 'D:\CloudCache'
$script:MountProcess = $null

function Find-RcloneBinary {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra\rclone.exe'),
        'C:\Users\Naboraj_sarkar\Downloads\CloudPlayX\tools\rclone\rclone.exe'
    )
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
    return [bool](Get-Service -Name 'WinFsp.Launcher' -ErrorAction SilentlyContinue)
}

function Test-DriveLetterAvailable([string]$DriveLetter) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':')
    $path = "$letter`:\"
    $used = [System.IO.DriveInfo]::GetDrives().Name -contains $path
    return (-not $used)
}

function Get-VirtualDriveStatus([string]$DriveLetter = $script:DefaultDriveLetter) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':')
    $driveRoot = "$letter`:\"
    $driveInfo = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.Name -eq $driveRoot }

    $processAlive = $false
    if ($script:MountProcess -and (-not $script:MountProcess.HasExited)) {
        $processAlive = $true
    }

    if ($driveInfo) {
        return [ordered]@{
            IsMounted = $true
            DriveLetter = $letter
            DriveRoot = $driveRoot
            VolumeLabel = $driveInfo.VolumeLabel
            Format = $driveInfo.DriveFormat
            FreeSpace = $driveInfo.AvailableFreeSpace
            TotalSize = $driveInfo.TotalSize
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
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':')
    $driveRoot = "$letter`:\"
    $safeCache = Resolve-SafeCacheDirectory $CacheDirectory

    $args = @(
        'mount',
        "${RemoteName}:",
        $driveRoot,
        '--config', $ConfigPath,
        '--read-only',
        '--network-mode',
        '--volname', 'NS Cloud Drive',
        '--cache-dir', $safeCache,
        '--vfs-cache-mode', 'full',
        '--vfs-cache-max-size', '20G',
        '--vfs-cache-max-age', '24h',
        '--vfs-cache-poll-interval', '1m',
        '--log-level', 'ERROR'
    )
    return $args
}

function Stop-VirtualDriveMount {
    if ($script:MountProcess -and (-not $script:MountProcess.HasExited)) {
        try {
            $script:MountProcess.Kill()
            $script:MountProcess.WaitForExit(5000) | Out-Null
        } catch { }
        $script:MountProcess = $null
    }

    # Also check if any orphaned rclone mount process exists
    $orphans = Get-Process -Name 'rclone' -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'mount' }
    foreach ($proc in $orphans) {
        try {
            $proc.Kill()
            $proc.WaitForExit(3000) | Out-Null
        } catch { }
    }

    return [ordered]@{
        Success = $true
        Message = 'Virtual drive unmounted cleanly.'
    }
}
