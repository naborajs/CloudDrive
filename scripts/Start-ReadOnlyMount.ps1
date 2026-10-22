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

$rclonePath = Join-Path $BuildRoot 'rclone.exe'
$manifestPath = Join-Path $BuildRoot 'rclone.build.json'
$patchPath = Join-Path $PSScriptRoot '..\patches\rclone-terabox-v1.75.2-extra-secret-safety.patch'

foreach ($path in @($rclonePath, $manifestPath, $ConfigPath, $patchPath)) {
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

$cacheRoot = [System.IO.Path]::GetPathRoot($CacheDirectory)
$cacheVolume = [System.IO.DriveInfo]::new($cacheRoot)
if (-not $cacheVolume.IsReady -or $cacheVolume.DriveFormat -ne 'NTFS') {
    throw "The cache volume must be a ready NTFS volume: $cacheRoot"
}
if ($cacheVolume.AvailableFreeSpace -lt 25GB) {
    throw "At least 25 GiB must be free on the cache volume before using the 20 GiB best-effort cache: $cacheRoot"
}

& $rclonePath --config $ConfigPath config encryption check
if ($LASTEXITCODE -ne 0) {
    throw 'The rclone configuration must be encrypted and decryptable before mounting. No mount was started.'
}

if (-not (Test-Path -LiteralPath $CacheDirectory)) {
    New-Item -ItemType Directory -Path $CacheDirectory | Out-Null
}

Write-Output "Starting read-only $RemoteName mount at $drivePath. Keep this window open; press Ctrl+C to unmount."
Write-Output 'Backend diagnostics are disabled. No log file is written.'

& $rclonePath mount "${RemoteName}:" $drivePath `
    --config $ConfigPath `
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
