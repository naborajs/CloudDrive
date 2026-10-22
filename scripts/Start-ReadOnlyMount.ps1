[CmdletBinding()]
param(
    [string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra'),
    [string]$ConfigPath = (Join-Path $env:APPDATA 'rclone\rclone.conf'),
    [string]$CacheDirectory = 'D:\CloudCache\TeraBox',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]*$')]
    [string]$RemoteName = 'terabox',
    [ValidatePattern('^[A-Za-z]$')]
    [string]$DriveLetter = 'T'
)

$ErrorActionPreference = 'Stop'

function Resolve-SafeCacheDirectory([string]$Path) {
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw 'The cache directory must be an absolute local drive path.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($volumeRoot -notmatch '^[A-Za-z]:\\$') {
        throw 'The cache directory must be on a local drive, not a network or device path.'
    }

    $normalizedPath = $fullPath.TrimEnd('\')
    if ($normalizedPath -eq $volumeRoot.TrimEnd('\')) {
        throw 'The cache directory cannot be the root of a volume.'
    }

    $volume = [System.IO.DriveInfo]::new($volumeRoot)
    if (-not $volume.IsReady -or $volume.DriveType -ne [System.IO.DriveType]::Fixed -or $volume.DriveFormat -ne 'NTFS') {
        throw "The cache must be on a ready, fixed NTFS volume: $volumeRoot"
    }
    if ($volume.AvailableFreeSpace -lt 25GB) {
        throw "At least 25 GiB must be free on the cache volume before using the 20 GiB best-effort cache: $volumeRoot"
    }

    $rootWithoutSeparator = $volumeRoot.TrimEnd('\')
    $currentPath = $normalizedPath
    while ($currentPath -and $currentPath -ne $rootWithoutSeparator) {
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force
            if (-not $item.PSIsContainer) {
                throw "A cache path component is not a directory: $currentPath"
            }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The cache path cannot contain a junction or symbolic link: $currentPath"
            }
        }

        $parent = [System.IO.Directory]::GetParent($currentPath)
        if (-not $parent) { break }
        $currentPath = $parent.FullName.TrimEnd('\')
    }

    return $fullPath
}

$rclonePath = Join-Path $BuildRoot 'rclone.exe'
$manifestPath = Join-Path $BuildRoot 'rclone.build.json'
$patchPath = Join-Path $PSScriptRoot '..\patches\rclone-terabox-v1.75.2-extra-secret-safety.patch'
$passwordHelperPath = Join-Path $PSScriptRoot 'RcloneConfigPassword.ps1'
$passwordHostPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

foreach ($path in @($rclonePath, $manifestPath, $ConfigPath, $patchPath, $passwordHelperPath, $passwordHostPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file was not found: $path"
    }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$expectedPatchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
$actualExecutableHash = (Get-FileHash -LiteralPath $rclonePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($manifest.sourceCommit -ne '56bf13885494819bc801302ddf881279bdac7262' -or
    $manifest.target -ne 'windows/amd64' -or
    $manifest.buildTag -ne 'cmount' -or
    $manifest.backend -ne 'terabox' -or
    $manifest.patchSha256 -ne $expectedPatchHash -or
    $manifest.executableSha256 -ne $actualExecutableHash) {
    throw 'The build manifest does not match the pinned source, patch, and executable.'
}

$drivePath = "$($DriveLetter.ToUpperInvariant()):\"
if ([System.IO.DriveInfo]::GetDrives().Name -contains $drivePath) {
    throw "Drive $drivePath is already in use. Choose another drive letter or disconnect the existing drive first."
}

$CacheDirectory = Resolve-SafeCacheDirectory -Path $CacheDirectory

$previousPasswordCommand = $env:RCLONE_PASSWORD_COMMAND
try {
    $quotedHelperPath = '"' + $passwordHelperPath + '"'
    $env:RCLONE_PASSWORD_COMMAND = '"' + $passwordHostPath + '" -NoLogo -NoProfile -NonInteractive -File ' + $quotedHelperPath

    & $rclonePath --config $ConfigPath --ask-password=false config encryption check
    if ($LASTEXITCODE -ne 0) {
        throw 'The rclone configuration must be encrypted and locally unlockable before mounting. No mount was started.'
    }

    if (-not (Test-Path -LiteralPath $CacheDirectory)) {
        New-Item -ItemType Directory -Path $CacheDirectory | Out-Null
    }
    $CacheDirectory = Resolve-SafeCacheDirectory -Path $CacheDirectory

    Write-Output "Starting read-only $RemoteName mount at $drivePath. Keep this window open; press Ctrl+C to unmount."
    Write-Output 'Backend diagnostics are disabled. No log file is written.'

    & $rclonePath mount "${RemoteName}:" $drivePath `
        --config $ConfigPath `
        --ask-password=false `
        --read-only `
        --network-mode `
        --volname 'NS Cloud Drive' `
        --cache-dir $CacheDirectory `
        --vfs-cache-mode full `
        --vfs-cache-max-size 20G `
        --vfs-cache-max-age 24h `
        --vfs-cache-poll-interval 1m `
        --terabox-debug-level 0 `
        --log-level ERROR

    if ($LASTEXITCODE -ne 0) {
        throw "rclone mount exited with code $LASTEXITCODE. Any files in the cache are preserved; do not delete them if a future writable mount has been used."
    }
}
finally {
    $env:RCLONE_PASSWORD_COMMAND = $previousPasswordCommand
}
