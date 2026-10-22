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
