# ==============================================================================
# NS Cloud Drive - Intelligent Cloud Deduplication & Delta Classifier Service
# Fast pre-transfer inspection: skips existing files with identical size & format.
# Detects format differences (e.g. PNG vs JPG) and size mismatches to re-send.
# Persists remote verification ledger across device restarts.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\providers\ProviderContract.ps1')

function Get-SafeFieldValue($Item, [string]$Name) {
    return (Get-CloudProviderFieldValue $Item $Name $null)
}

$script:DedupLedgerCache = [hashtable]::Synchronized(@{})
$script:AccountMountRootCache = [hashtable]::Synchronized(@{})
$script:DedupLedgerPathOverride = $null
$script:DedupLedgerLoaded = $false
$script:DedupLedgerLock = [System.Object]::new()

function Get-CloudDedupLedgerPath {
    if ($script:DedupLedgerPathOverride) {
        return $script:DedupLedgerPathOverride
    }
    $baseDir = if (Get-Command 'Get-NSCloudDriveDataRoot' -ErrorAction SilentlyContinue) {
        Get-NSCloudDriveDataRoot
    } elseif ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA 'NSCloudDrive'
    } else {
        $homeDir = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
        Join-Path $homeDir '.local/share/nsclouddrive'
    }
    $cacheDir = Join-Path $baseDir 'cache'
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    return (Join-Path $cacheDir 'cloud-dedup-ledger.json')
}

function Set-CloudDedupLedgerPathOverride([string]$Path) {
    $script:DedupLedgerPathOverride = $Path
    $script:DedupLedgerLoaded = $false
    $script:DedupLedgerCache.Clear()
}

function Load-CloudDedupLedger {
    [System.Threading.Monitor]::Enter($script:DedupLedgerLock)
    try {
        $path = Get-CloudDedupLedgerPath
        $script:DedupLedgerCache.Clear()
        if (Test-Path -LiteralPath $path) {
            try {
                $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $arr = ConvertFrom-Json $raw
                    if ($arr) {
                        foreach ($entry in @($arr)) {
                            if ($entry -and $entry.Key) {
                                $ht = [ordered]@{}
                                $entry.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
                                $script:DedupLedgerCache[[string]$entry.Key] = $ht
                            }
                        }
                    }
                }
            } catch { }
        }
        $script:DedupLedgerLoaded = $true
        return $script:DedupLedgerCache
    } finally {
        [System.Threading.Monitor]::Exit($script:DedupLedgerLock)
    }
}

function Save-CloudDedupLedger {
    [System.Threading.Monitor]::Enter($script:DedupLedgerLock)
    try {
        $path = Get-CloudDedupLedgerPath
        $parent = [System.IO.Path]::GetDirectoryName($path)
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        $items = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($k in $script:DedupLedgerCache.Keys) {
            $items.Add($script:DedupLedgerCache[$k])
        }

        $json = ConvertTo-Json -InputObject @($items.ToArray()) -Depth 5
        $tmp = "$path.tmp.$([Guid]::NewGuid().ToString('N'))"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)

        [System.IO.File]::Copy($tmp, $path, $true)
        if (Test-Path -LiteralPath $tmp) {
            try { [System.IO.File]::Delete($tmp) } catch { }
        }
    } finally {
        [System.Threading.Monitor]::Exit($script:DedupLedgerLock)
    }
}

function Get-FileFormatCategory([string]$PathOrExtension) {
    if ([string]::IsNullOrWhiteSpace($PathOrExtension)) { return 'unknown' }
    $ext = [System.IO.Path]::GetExtension($PathOrExtension).TrimStart('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($ext)) { return 'none' }

    # Group common interchangeable extensions
    switch ($ext) {
        'jpeg' { return 'jpeg' }
        'jpg'  { return 'jpeg' }
        'png'  { return 'png' }
        'webp' { return 'webp' }
        'gif'  { return 'gif' }
        'bmp'  { return 'bmp' }
        'tiff' { return 'tiff' }
        'tif'  { return 'tiff' }
        'svg'  { return 'svg' }
        'mp4'  { return 'mp4' }
        'mkv'  { return 'mkv' }
        'mov'  { return 'mov' }
        'avi'  { return 'avi' }
        'mp3'  { return 'mp3' }
        'wav'  { return 'wav' }
        'flac' { return 'flac' }
        'pdf'  { return 'pdf' }
        'zip'  { return 'zip' }
        'tar'  { return 'tar' }
        'gz'   { return 'gz' }
        '7z'   { return '7z' }
        'json' { return 'json' }
        'xml'  { return 'xml' }
        'txt'  { return 'txt' }
        'csv'  { return 'csv' }
        default { return $ext }
    }
}

function Test-FileFormatMatch([string]$LocalPath, [string]$RemotePath) {
    $locFmt = Get-FileFormatCategory $LocalPath
    $remFmt = Get-FileFormatCategory $RemotePath
    return ($locFmt -eq $remFmt)
}

function Get-CloudDedupLedgerKey([string]$AccountId, [string]$NormalizedRemotePath) {
    $cleanPath = $NormalizedRemotePath.Trim().Replace('\', '/').TrimStart('/')
    return "${AccountId}:${cleanPath}".ToLowerInvariant()
}

function Record-CloudDedupVerifiedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountId,

        [Parameter(Mandatory = $true)]
        [string]$ProviderId,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [int64]$SizeBytes,

        [Parameter(Mandatory = $false)]
        [string]$Format = '',

        [Parameter(Mandatory = $false)]
        [string]$RemoteHash = '',

        [Parameter(Mandatory = $false)]
        [switch]$SkipPersist
    )

    if (-not $script:DedupLedgerLoaded) {
        Load-CloudDedupLedger | Out-Null
    }

    $cleanPath = $RemotePath.Trim().Replace('\', '/').TrimStart('/')
    $fName = [System.IO.Path]::GetFileName($cleanPath)
    $fmt = if ($Format) { $Format } else { Get-FileFormatCategory $cleanPath }
    $key = Get-CloudDedupLedgerKey -AccountId $AccountId -NormalizedRemotePath $cleanPath

    $record = [ordered]@{
        Key             = $key
        AccountId       = $AccountId
        ProviderId      = $ProviderId.ToLowerInvariant()
        RemotePath      = $cleanPath
        FileName        = $fName
        Extension       = [System.IO.Path]::GetExtension($cleanPath).ToLowerInvariant()
        Format          = $fmt
        SizeBytes       = $SizeBytes
        LastVerifiedUtc = [DateTime]::UtcNow.ToString('o')
        RemoteHash      = $RemoteHash
    }

    $script:DedupLedgerCache[$key] = $record

    if (-not $SkipPersist) {
        Save-CloudDedupLedger
    }
}

function Test-CloudDedupVerifiedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountId,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [int64]$SizeBytes,

        [Parameter(Mandatory = $false)]
        [string]$Format = ''
    )

    if (-not $script:DedupLedgerLoaded) {
        Load-CloudDedupLedger | Out-Null
    }

    $cleanPath = $RemotePath.Trim().Replace('\', '/').TrimStart('/')
    $key = Get-CloudDedupLedgerKey -AccountId $AccountId -NormalizedRemotePath $cleanPath

    if (-not $script:DedupLedgerCache.ContainsKey($key)) {
        return $false
    }

    $entry = $script:DedupLedgerCache[$key]
    $recordedSize = [int64]$entry['SizeBytes']
    if ($recordedSize -ne $SizeBytes) {
        return $false
    }

    if ($Format) {
        $recordedFmt = [string]$entry['Format']
        if ($recordedFmt -and $recordedFmt -ne $Format) {
            return $false
        }
    }

    return $true
}

function Test-RemoteCloudFileDeduplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountId,

        [Parameter(Mandatory = $false)]
        [string]$ProviderId = '',

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [int64]$LocalSizeBytes,

        [Parameter(Mandatory = $false)]
        [string]$LocalFilePath = '',

        [Parameter(Mandatory = $false)]
        [object]$Account = $null,

        # Recovery and re-drop flows must check live provider state instead of
        # trusting a ledger entry that may have become stale since it was written.
        [switch]$RequireLiveCheck
    )

    $cleanPath = $RemotePath.Trim().Replace('\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($cleanPath)) {
        return [ordered]@{ IsPresent = $false; Status = 'EmptyPath'; Reason = 'Remote path is empty.' }
    }

    $localExt = [System.IO.Path]::GetExtension($cleanPath).ToLowerInvariant()
    $localFmt = Get-FileFormatCategory $localExt

    # 1. Fast Path: Check in-memory deduplication ledger cache (0 ms). This is
    # useful for ordinary UI summaries, but it is not authoritative during a
    # restart or a user re-drop: the remote object may since have changed.
    if (-not $RequireLiveCheck -and (Test-CloudDedupVerifiedFile -AccountId $AccountId -RemotePath $cleanPath -SizeBytes $LocalSizeBytes -Format $localFmt)) {
        return [ordered]@{
            IsPresent       = $true
            Status          = 'AlreadyInCloud'
            RemoteSizeBytes = $LocalSizeBytes
            Format          = $localFmt
            Reason          = "Verified in cloud storage via local deduplication ledger ($LocalSizeBytes bytes, $localFmt)."
        }
    }

    # 2. Fast Path: Direct virtual mount check (O(1) filesystem query)
    $mountRoot = ''
    $mountRcPort = 0
    $prov = if ($ProviderId) { $ProviderId } else { 'gdrive' }

    if ($AccountId -and $script:AccountMountRootCache.ContainsKey($AccountId)) {
        $mountRoot = [string]$script:AccountMountRootCache[$AccountId]
    } else {
        if ($Account) {
            $accProv = [string](Get-SafeFieldValue $Account 'ProviderId')
            if (-not $ProviderId -and $accProv) { $prov = $accProv }
            $mountPathVal = [string](Get-SafeFieldValue $Account 'MountPath')
            if (-not $mountPathVal) { $mountPathVal = [string](Get-SafeFieldValue $Account 'MountPoint') }
            if ($mountPathVal -and (Test-Path -LiteralPath $mountPathVal -ErrorAction SilentlyContinue)) {
                $mountRoot = $mountPathVal
            } else {
                $letterVal = [string](Get-SafeFieldValue $Account 'DriveLetter')
                if ($letterVal) {
                    $letter = $letterVal.ToUpperInvariant().TrimEnd(':')
                    if ($letter -match '^[A-Z]$' -and (Test-Path -LiteralPath "${letter}:\" -ErrorAction SilentlyContinue)) {
                        $mountRoot = "${letter}:\"
                    }
                }
            }
        }

        if (-not $mountRoot -and (Get-Command Resolve-ProviderMountPoint -ErrorAction SilentlyContinue)) {
            try {
                $candMount = Resolve-ProviderMountPoint -ProviderId $prov -AccountId $AccountId
                if ($candMount -and (Test-Path -LiteralPath $candMount -ErrorAction SilentlyContinue)) {
                    $mountRoot = $candMount
                }
            } catch { }
        }

        if ($AccountId -and $mountRoot) {
            $script:AccountMountRootCache[$AccountId] = $mountRoot
        }
    }

    if (Get-Command Get-VirtualDriveStatus -ErrorAction SilentlyContinue) {
        try {
            $status = Get-VirtualDriveStatus -AccountId $AccountId -ProviderId $prov
            if (-not $mountRoot -and $status -and $status.IsMounted -and $status.DriveRoot -and (Test-Path -LiteralPath $status.DriveRoot -ErrorAction SilentlyContinue)) {
                $mountRoot = [string]$status.DriveRoot
            }
            if ($status -and $status.DriveLetter -and ($status.IsMounted -or $status.ProcessRunning) -and (Get-Command Get-VirtualDriveRcPort -ErrorAction SilentlyContinue)) {
                $mountRcPort = [int](Get-VirtualDriveRcPort -DriveLetter ([string]$status.DriveLetter))
            } elseif ($status -and $status.PSObject.Properties['RcPort']) {
                $mountRcPort = [int]$status.RcPort
            }
        } catch { }
    }

    if (-not $RequireLiveCheck -and $mountRoot -and (Test-Path -LiteralPath $mountRoot -ErrorAction SilentlyContinue)) {
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $cleanRel = $cleanPath.Replace('/', $sep).Replace('\', $sep)
        $targetCloudPath = Join-Path $mountRoot $cleanRel
        if ([System.IO.File]::Exists($targetCloudPath)) {
            try {
                $remoteFi = [System.IO.FileInfo]::new($targetCloudPath)
                $remoteSize = [int64]$remoteFi.Length
                $remoteExt = $remoteFi.Extension.ToLowerInvariant()
                $remoteFmt = Get-FileFormatCategory $remoteExt

                # Format discrimination (e.g. PNG vs JPG)
                if ($localFmt -ne $remoteFmt) {
                    return [ordered]@{
                        IsPresent       = $false
                        Status          = 'FormatMismatch'
                        RemoteSizeBytes = $remoteSize
                        Format          = $remoteFmt
                        Reason          = "Format mismatch: local is $($localFmt.ToUpper()), cloud has $($remoteFmt.ToUpper()). Re-sending as different format."
                    }
                }

                # Exact byte size comparison
                if ($remoteSize -eq $LocalSizeBytes) {
                    try {
                        Record-CloudDedupVerifiedFile `
                            -AccountId $AccountId `
                            -ProviderId $prov `
                            -RemotePath $cleanPath `
                            -SizeBytes $LocalSizeBytes `
                            -Format $localFmt `
                            -SkipPersist
                    } catch { }

                    return [ordered]@{
                        IsPresent       = $true
                        Status          = 'AlreadyInCloud'
                        RemoteSizeBytes = $remoteSize
                        Format          = $localFmt
                        Reason          = "Already present in cloud storage with matching format ($localFmt) and exact byte size ($remoteSize bytes). Upload skipped."
                    }
                } else {
                    return [ordered]@{
                        IsPresent       = $false
                        Status          = 'SizeMismatch'
                        RemoteSizeBytes = $remoteSize
                        Format          = $localFmt
                        Reason          = "Size mismatch: local has $LocalSizeBytes bytes, cloud has $remoteSize bytes. Re-sending updated file."
                    }
                }
            } catch { }
        } else {
            # Check if same basename exists with different format in parent folder
            try {
                $parentCloudDir = [System.IO.Path]::GetDirectoryName($targetCloudPath)
                if ($parentCloudDir -and [System.IO.Directory]::Exists($parentCloudDir)) {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($targetCloudPath)
                    $matchingFiles = [System.IO.Directory]::EnumerateFiles($parentCloudDir, "$baseName.*", [System.IO.SearchOption]::TopDirectoryOnly)
                    foreach ($mf in $matchingFiles) {
                        $mfi = [System.IO.FileInfo]::new($mf)
                        $mExt = $mfi.Extension.ToLowerInvariant()
                        $mFmt = Get-FileFormatCategory $mExt
                        if ($mFmt -ne $localFmt) {
                            return [ordered]@{
                                IsPresent       = $false
                                Status          = 'FormatMismatch'
                                RemoteSizeBytes = [int64]$mfi.Length
                                Format          = $mFmt
                                Reason          = "Format collision in cloud folder: local is $($localFmt.ToUpper()), cloud has $($mfi.Name) ($($mFmt.ToUpper())). Re-sending."
                            }
                        }
                    }
                }
            } catch { }

            # Drive is mounted and file does not exist on virtual drive.
            return [ordered]@{
                IsPresent       = $false
                Status          = 'New'
                RemoteSizeBytes = 0L
                Format          = $localFmt
                Reason          = 'Not found in mounted cloud storage. Queued for upload.'
            }
        }
    }

    # 3. Direct Rclone RC operations/stat fallback (only if virtual drive is unmounted/headless)
    try {
        $cleanLetter = if ($mountRoot) { $mountRoot.ToUpperInvariant().TrimEnd(':').TrimEnd('\') } else { '' }
        $rcPort = $mountRcPort
        if ($cleanLetter.Length -eq 1) {
            $rcPort = 5580 + ([int]$cleanLetter[0] - [int][char]'A')
        }
        if ($rcPort -gt 0) {
            $fsVal = "$prov`:"
            $body = @{ fs = $fsVal; remote = $cleanPath } | ConvertTo-Json
            $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$rcPort/operations/stat")
            $req.Method = 'POST'
            $req.ContentType = 'application/json'
            $req.Timeout = 1500
            $req.ReadWriteTimeout = 1500
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $req.ContentLength = $bytes.Length
            $os = $req.GetRequestStream()
            try {
                $os.Write($bytes, 0, $bytes.Length)
            } finally {
                $os.Dispose()
            }
            $resp = $req.GetResponse()
            try {
                $sr = [System.IO.StreamReader]::new($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                try {
                    $respJson = $sr.ReadToEnd()
                    if ($respJson) {
                        $statObj = ConvertFrom-Json $respJson
                        if ($statObj -and $statObj.item) {
                            $requestedName = [System.IO.Path]::GetFileName($cleanPath)
                            $returnedName = [string]$statObj.item.Name
                            $statSize = 0L
                            if (-not $statObj.item.PSObject.Properties['IsDir'] -or -not $statObj.item.PSObject.Properties['Size'] -or -not [int64]::TryParse([string]$statObj.item.Size, [ref]$statSize) -or $statSize -lt 0L) {
                                return [ordered]@{
                                    IsPresent = $false
                                    Status = 'Unavailable'
                                    RemoteSizeBytes = 0L
                                    Format = 'unknown'
                                    Reason = 'The provider stat response did not include a valid file type and byte size.'
                                }
                            }
                            if ([bool]$statObj.item.IsDir) {
                                return [ordered]@{
                                    IsPresent = $false
                                    Status = 'PathMismatch'
                                    RemoteSizeBytes = $statSize
                                    Format = 'directory'
                                    Reason = 'A directory exists at the destination path; it is not an uploaded file.'
                                }
                            }
                            $returnedPath = if ($statObj.item.PSObject.Properties['Path']) { ([string]$statObj.item.Path).Trim('/').Replace('\', '/') } else { '' }
                            $exactPathMatches = if ($returnedPath) {
                                [string]::Equals($returnedPath, $cleanPath, [System.StringComparison]::Ordinal)
                            } else {
                                [string]::Equals($returnedName, $requestedName, [System.StringComparison]::Ordinal)
                            }
                            if (-not $exactPathMatches) {
                                return [ordered]@{
                                    IsPresent = $false
                                    Status = 'PathMismatch'
                                    RemoteSizeBytes = $statSize
                                    Format = Get-FileFormatCategory ([System.IO.Path]::GetExtension($returnedName))
                                    Reason = 'The provider returned a different file name or path than the requested destination.'
                                }
                            }
                            $rcSize = $statSize
                            $rcExt = [System.IO.Path]::GetExtension([string]$statObj.item.Name).ToLowerInvariant()
                            $rcFmt = Get-FileFormatCategory $rcExt
                            if ($rcFmt -eq $localFmt -and $rcSize -eq $LocalSizeBytes) {
                                try {
                                    Record-CloudDedupVerifiedFile `
                                        -AccountId $AccountId `
                                        -ProviderId $prov `
                                        -RemotePath $cleanPath `
                                        -SizeBytes $LocalSizeBytes `
                                        -Format $localFmt `
                                        -SkipPersist
                                } catch { }
                                return [ordered]@{
                                    IsPresent       = $true
                                    Status          = 'AlreadyInCloud'
                                    RemoteSizeBytes = $rcSize
                                    Format          = $localFmt
                                    Reason          = "Already present in cloud storage via rclone RC verification ($rcSize bytes). Upload skipped."
                                }
                            } elseif ($rcFmt -ne $localFmt) {
                                return [ordered]@{
                                    IsPresent       = $false
                                    Status          = 'FormatMismatch'
                                    RemoteSizeBytes = $rcSize
                                    Format          = $rcFmt
                                    Reason          = "Format mismatch: local is $($localFmt.ToUpper()), cloud has $($rcFmt.ToUpper()). Re-sending."
                                }
                            } else {
                                return [ordered]@{
                                    IsPresent       = $false
                                    Status          = 'SizeMismatch'
                                    RemoteSizeBytes = $rcSize
                                    Format          = $localFmt
                                    Reason          = "Size mismatch: local has $LocalSizeBytes bytes, cloud has $rcSize bytes. Re-sending."
                                }
                            }
                        }
                    }
                } finally {
                    $sr.Dispose()
                }
            } finally {
                $resp.Dispose()
            }
        }
    } catch {
        # A failed stat request is not evidence that the object is absent. Rclone
        # returns a not-found error for a confirmed miss; transport/auth/provider
        # failures must remain distinct so schedulers can safely defer the upload.
        $responseBody = ''
        try {
            $response = $_.Exception.Response
            if ($response) {
                $responseStream = $response.GetResponseStream()
                if ($responseStream) {
                    $reader = [System.IO.StreamReader]::new($responseStream, [System.Text.Encoding]::UTF8)
                    try { $responseBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            }
        } catch { }
        $errorText = ([string]$_.Exception.Message + ' ' + $responseBody)
        if ($errorText -match '(?i)(object|file|directory|path).{0,40}(not found|does not exist|doesn''t exist)|\b404\b.{0,30}\bnot found\b') {
            return [ordered]@{
                IsPresent = $false
                Status = 'New'
                RemoteSizeBytes = 0L
                Format = $localFmt
                Reason = 'Provider confirmed that the destination path is absent.'
            }
        }
    }

    # Some platforms/providers do not expose a mounted RC endpoint. Fall back to
    # a fresh provider directory listing so absence and unavailability remain
    # distinct without depending on drive letters or a stale VFS cache.
    $liveAccount = $Account
    if (-not $liveAccount -and (Get-Command Get-CloudAccounts -ErrorAction SilentlyContinue)) {
        try {
            $liveAccount = @(Get-CloudAccounts | Where-Object { [string](Get-SafeFieldValue $_ 'Id') -eq $AccountId } | Select-Object -First 1)[0]
        } catch { }
    }
    if ($liveAccount -and (Get-Command Get-CloudDirectoryContents -ErrorAction SilentlyContinue)) {
        $separator = $cleanPath.LastIndexOf('/')
        $parentPath = if ($separator -ge 0) { $cleanPath.Substring(0, $separator) } else { '' }
        $expectedName = if ($separator -ge 0) { $cleanPath.Substring($separator + 1) } else { $cleanPath }
        try {
            $providerItems = @(Get-CloudDirectoryContents -Account $liveAccount -Path $parentPath -BypassLocalMount)
            $remoteItem = $null
            $remoteDirectory = $false
            foreach ($providerItem in $providerItems) {
                if ($providerItem -and $providerItem.Contains('Name') -and [string]::Equals([string]$providerItem['Name'], $expectedName, [System.StringComparison]::Ordinal)) {
                    if (-not $providerItem.Contains('IsDir')) {
                        return [ordered]@{
                            IsPresent = $false
                            Status = 'Unavailable'
                            RemoteSizeBytes = 0L
                            Format = 'unknown'
                            Reason = 'The provider listing did not identify whether the destination item is a file.'
                        }
                    }
                    if ([bool]$providerItem['IsDir']) {
                        $remoteDirectory = $true
                        continue
                    }
                    $candidateSize = 0L
                    if (-not $providerItem.Contains('Size') -or -not [int64]::TryParse([string]$providerItem['Size'], [ref]$candidateSize) -or $candidateSize -lt 0L) {
                        return [ordered]@{
                            IsPresent = $false
                            Status = 'Unavailable'
                            RemoteSizeBytes = 0L
                            Format = 'unknown'
                            Reason = 'The provider listing did not include a valid file byte size.'
                        }
                    }
                    if (-not $remoteItem) { $remoteItem = $providerItem }
                    if ($candidateSize -eq $LocalSizeBytes) {
                        $remoteItem = $providerItem
                        break
                    }
                }
            }
            if (-not $remoteItem) {
                if ($remoteDirectory) {
                    return [ordered]@{
                        IsPresent = $false
                        Status = 'PathMismatch'
                        RemoteSizeBytes = 0L
                        Format = 'directory'
                        Reason = 'A directory exists at the destination path; it is not an uploaded file.'
                    }
                }
                return [ordered]@{
                    IsPresent = $false
                    Status = 'New'
                    RemoteSizeBytes = 0L
                    Format = $localFmt
                    Reason = 'The live provider listing confirmed that the destination path is absent.'
                }
            }

            $reportedPath = if ($remoteItem.Contains('Path')) { ([string]$remoteItem['Path']).Trim('/').Replace('\', '/') } else { '' }
            # rclone lsjson reports Path relative to the path being listed. Since
            # this request lists the destination's parent folder, restore that
            # prefix before comparing it with the queued destination path.
            if (-not $reportedPath) {
                $remotePath = $cleanPath
            } elseif ($parentPath -and -not [string]::Equals($reportedPath, $parentPath, [System.StringComparison]::Ordinal) -and -not $reportedPath.StartsWith("$parentPath/", [System.StringComparison]::Ordinal)) {
                $remotePath = "$parentPath/$reportedPath"
            } else {
                $remotePath = $reportedPath
            }
            if (-not [string]::Equals($remotePath, $cleanPath, [System.StringComparison]::Ordinal)) {
                return [ordered]@{
                    IsPresent = $false
                    Status = 'PathMismatch'
                    RemoteSizeBytes = [int64]$remoteItem['Size']
                    Format = Get-FileFormatCategory ([System.IO.Path]::GetExtension([string]$remoteItem['Name']))
                    Reason = 'The provider returned a different destination path than the requested file.'
                }
            }
            $remoteSize = [int64]$remoteItem['Size']
            $remoteFormat = Get-FileFormatCategory ([System.IO.Path]::GetExtension([string]$remoteItem['Name']))
            if ($remoteFormat -ne $localFmt) {
                return [ordered]@{
                    IsPresent = $false
                    Status = 'FormatMismatch'
                    RemoteSizeBytes = $remoteSize
                    Format = $remoteFormat
                    Reason = 'A different file format exists at the destination path.'
                }
            }
            if ($remoteSize -ne $LocalSizeBytes) {
                return [ordered]@{
                    IsPresent = $false
                    Status = 'SizeMismatch'
                    RemoteSizeBytes = $remoteSize
                    Format = $remoteFormat
                    Reason = "Destination size is $remoteSize bytes; local file is $LocalSizeBytes bytes."
                }
            }
            try {
                Record-CloudDedupVerifiedFile -AccountId $AccountId -ProviderId $prov -RemotePath $cleanPath -SizeBytes $LocalSizeBytes -Format $localFmt -SkipPersist
            } catch { }
            return [ordered]@{
                IsPresent = $true
                Status = 'AlreadyInCloud'
                RemoteSizeBytes = $remoteSize
                Format = $remoteFormat
                Reason = 'The live provider listing confirmed the exact name, path, and byte size.'
            }
        } catch {
            $listingError = [string]$_.Exception.Message
            if ($listingError -match '(?i)(directory|folder|path).{0,40}(not found|does not exist|doesn''t exist)|\b404\b.{0,30}\bnot found\b') {
                return [ordered]@{
                    IsPresent = $false
                    Status = 'New'
                    RemoteSizeBytes = 0L
                    Format = $localFmt
                    Reason = 'The provider confirmed that the destination folder is absent.'
                }
            }
        }
    }

    return [ordered]@{
        IsPresent       = $false
        Status          = 'Unavailable'
        RemoteSizeBytes = 0L
        Format          = $localFmt
        Reason          = 'No live provider check was available. Transfer is deferred until the destination can be verified.'
    }
}

function Sync-CloudDedupInventoryFromDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountId,

        [Parameter(Mandatory = $false)]
        [string]$ProviderId = 'gdrive',

        [Parameter(Mandatory = $false)]
        [string]$DriveRoot = ''
    )

    $root = $DriveRoot
    if (-not $root -and (Get-Command Get-VirtualDriveStatus -ErrorAction SilentlyContinue)) {
        try {
            $status = Get-VirtualDriveStatus -AccountId $AccountId -ProviderId $ProviderId
            if ($status -and $status.IsMounted) {
                $root = $status.DriveRoot
            }
        } catch { }
    }

    if (-not $root -or -not (Test-Path -LiteralPath $root)) {
        return 0
    }

    $enumOptions = [System.IO.SearchOption]::AllDirectories
    $files = [System.IO.Directory]::EnumerateFiles($root, '*', $enumOptions)
    $rootLen = $root.TrimEnd('\', '/').Length
    $count = 0

    foreach ($f in $files) {
        try {
            $fi = [System.IO.FileInfo]::new($f)
            $rel = $f.Substring($rootLen).TrimStart('\', '/').Replace('\', '/')
            $fmt = Get-FileFormatCategory $fi.Extension
            Record-CloudDedupVerifiedFile `
                -AccountId $AccountId `
                -ProviderId $ProviderId `
                -RemotePath $rel `
                -SizeBytes ([int64]$fi.Length) `
                -Format $fmt `
                -SkipPersist
            $count++
        } catch { }
    }

    if ($count -gt 0) {
        Save-CloudDedupLedger
    }
    return $count
}

function Get-RemoteFileInventoryMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$DestinationAccount,

        [Parameter(Mandatory = $false)]
        [string]$DestinationFolderPath = '',

        [Parameter(Mandatory = $false)]
        [string[]]$DestinationFolderPaths = @(),

        [Parameter(Mandatory = $false)]
        [switch]$BypassMount,

        [Parameter(Mandatory = $false)]
        [switch]$BypassLedger
    )

    $inventory = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::Ordinal)
    $accId = [string](Get-SafeFieldValue $DestinationAccount 'Id')
    $provId = [string](Get-SafeFieldValue $DestinationAccount 'ProviderId')
    if (-not $provId) { $provId = 'gdrive' }

    $cleanFolder = if ($DestinationFolderPath) { $DestinationFolderPath.Trim().Replace('\', '/').TrimStart('/').TrimEnd('/') } else { '' }

    # Fast-Path 1: Read through mounted virtual drive for non-recovery lookups.
    # Recovery/drop scans bypass the mount cache and query the provider directly.
    if (-not $BypassMount -and -not $BypassLedger -and (Get-Command Get-VirtualDriveStatus -ErrorAction SilentlyContinue)) {
        try {
            $mountStatus = Get-VirtualDriveStatus -AccountId $accId -ProviderId $provId
            if ($mountStatus -and $mountStatus.IsMounted -and (Test-Path -LiteralPath $mountStatus.DriveRoot)) {
                $targetDir = if ($cleanFolder) { Join-Path $mountStatus.DriveRoot ($cleanFolder.Replace('/', '\')) } else { $mountStatus.DriveRoot }
                if (Test-Path -LiteralPath $targetDir -PathType Container) {
                    $enumOptions = if ($cleanFolder) { [System.IO.SearchOption]::AllDirectories } else { [System.IO.SearchOption]::TopDirectoryOnly }
                    $files = [System.IO.Directory]::EnumerateFiles($targetDir, '*', $enumOptions)
                    $rootLen = $targetDir.Length
                    $hasNewMountFiles = $false
                    foreach ($f in $files) {
                        $fi = [System.IO.FileInfo]::new($f)
                        $rel = $f.Substring($rootLen).TrimStart('\', '/').Replace('\', '/')
                        $fullRel = if ($cleanFolder) { "$cleanFolder/$rel" } else { $rel }
                        $normKey = $fullRel
                        $fmt = Get-FileFormatCategory $fi.Extension
                        $inventory[$normKey] = [ordered]@{
                            Name      = $fi.Name
                            RelPath   = $fullRel
                            SizeBytes = [int64]$fi.Length
                            Format    = $fmt
                            Extension = $fi.Extension.ToLowerInvariant()
                            Source    = 'LocalVfsMount'
                        }
                        if ($accId) {
                            Record-CloudDedupVerifiedFile `
                                -AccountId $accId `
                                -ProviderId $provId `
                                -RemotePath $fullRel `
                                -SizeBytes ([int64]$fi.Length) `
                                -Format $fmt `
                                -SkipPersist
                            $hasNewMountFiles = $true
                        }
                    }
                    if ($hasNewMountFiles) {
                        try { Save-CloudDedupLedger } catch { }
                    }
                    return $inventory
                }
            }
        } catch { }
    }

    # Live listing is limited to destination parent folders represented by the
    # current batch. Each successfully listed folder records an exact scope;
    # missing paths outside those folders still require a direct provider check.
    if ($BypassLedger) {
        if (Get-Command Get-CloudDirectoryContents -ErrorAction SilentlyContinue) {
            $folders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            if ($DestinationFolderPaths -and $DestinationFolderPaths.Count -gt 0) {
                foreach ($folderPath in $DestinationFolderPaths) {
                    if ($null -eq $folderPath) { continue }
                    $normalizedFolder = ([string]$folderPath).Trim().Replace('\', '/').Trim('/').TrimStart('/')
                    [void]$folders.Add($normalizedFolder)
                }
            } else {
                [void]$folders.Add($cleanFolder)
            }

            foreach ($normalizedFolder in $folders) {
                try {
                    $children = @(Get-CloudDirectoryContents -Account $DestinationAccount -Path $normalizedFolder -BypassLocalMount)
                } catch {
                    $listingError = [string]$_.Exception.Message
                    $scopeKey = '{0}:{1}' -f "`0nscd_live_inventory_scope", $normalizedFolder
                    if ($listingError -match '(?i)(directory|folder|path).{0,40}(not found|does not exist|doesn''t exist)|\b404\b.{0,30}\bnot found\b') {
                        $inventory[$scopeKey] = [ordered]@{ Name = ''; RelPath = $normalizedFolder; SizeBytes = 0L; Format = ''; Extension = ''; Source = 'LiveProviderInventoryScope' }
                    } else {
                        $inventory[$scopeKey] = [ordered]@{ Name = ''; RelPath = $normalizedFolder; SizeBytes = 0L; Format = ''; Extension = ''; Source = 'LiveProviderInventoryUnavailableScope' }
                    }
                    continue
                }
                $folderComplete = $true
                foreach ($child in $children) {
                    if (-not $child -or -not $child.Contains('Name') -or -not $child.Contains('IsDir')) {
                        $folderComplete = $false
                        break
                    }
                    $childName = [string]$child['Name']
                    if ([string]::IsNullOrWhiteSpace($childName) -or $childName -in @('.', '..') -or $childName.Contains('/') -or $childName.Contains('\')) {
                        $folderComplete = $false
                        break
                    }
                    $childPath = if ($normalizedFolder) { "$normalizedFolder/$childName" } else { $childName }
                    if ([bool]$child['IsDir']) {
                        $inventory[$childPath] = [ordered]@{
                            Name = $childName
                            RelPath = $childPath
                            SizeBytes = 0L
                            Format = 'directory'
                            Extension = ''
                            Source = 'LiveProviderInventory'
                            IsDirectory = $true
                        }
                        continue
                    }
                    $fiName = $childName
                    $sizeBytes = 0L
                    if (-not $child.Contains('Size') -or -not [int64]::TryParse([string]$child['Size'], [ref]$sizeBytes) -or $sizeBytes -lt 0L) {
                        $folderComplete = $false
                        break
                    }
                    $extension = [System.IO.Path]::GetExtension($fiName).ToLowerInvariant()
                    $inventory[$childPath] = [ordered]@{
                        Name = $fiName
                        RelPath = $childPath
                        SizeBytes = $sizeBytes
                        Format = Get-FileFormatCategory $extension
                        Extension = $extension
                        Source = 'LiveProviderInventory'
                        IsDirectory = $false
                        ModTime = [string]$child['ModTime']
                    }
                }
                if ($folderComplete) {
                    $scopeKey = '{0}:{1}' -f "`0nscd_live_inventory_scope", $normalizedFolder
                    $inventory[$scopeKey] = [ordered]@{
                        Name = ''
                        RelPath = $normalizedFolder
                        SizeBytes = 0L
                        Format = ''
                        Extension = ''
                        Source = 'LiveProviderInventoryScope'
                    }
                } else {
                    $scopeKey = '{0}:{1}' -f "`0nscd_live_inventory_scope", $normalizedFolder
                    $inventory[$scopeKey] = [ordered]@{
                        Name = ''
                        RelPath = $normalizedFolder
                        SizeBytes = 0L
                        Format = ''
                        Extension = ''
                        Source = 'LiveProviderInventoryUnavailableScope'
                    }
                }
            }
        } else {
            $unavailableFolders = if ($DestinationFolderPaths -and $DestinationFolderPaths.Count -gt 0) { $DestinationFolderPaths } else { @($cleanFolder) }
            foreach ($folderPath in $unavailableFolders) {
                $normalizedFolder = ([string]$folderPath).Trim().Replace('\', '/').Trim('/').TrimStart('/')
                $scopeKey = '{0}:{1}' -f "`0nscd_live_inventory_scope", $normalizedFolder
                $inventory[$scopeKey] = [ordered]@{ Name = ''; RelPath = $normalizedFolder; SizeBytes = 0L; Format = ''; Extension = ''; Source = 'LiveProviderInventoryUnavailableScope' }
            }
        }
        return $inventory
    }

    # Fast-Path 2: Inspect durable local deduplication ledger
    if (-not $script:DedupLedgerLoaded) {
        Load-CloudDedupLedger | Out-Null
    }

    $prefix = "${accId}:"
    if ($cleanFolder) {
        $prefix = "${accId}:${cleanFolder}/".ToLowerInvariant()
    }

    foreach ($k in $script:DedupLedgerCache.Keys) {
        $kLower = [string]$k.ToLowerInvariant()
        if ($kLower.StartsWith($prefix) -or ($cleanFolder -eq '' -and $kLower.StartsWith("${accId}:"))) {
            $entry = $script:DedupLedgerCache[$k]
            $entryRel = [string]$entry['RemotePath']
        $normKey = $entryRel
            if (-not $inventory.ContainsKey($normKey)) {
                $inventory[$normKey] = [ordered]@{
                    Name      = [string]$entry['FileName']
                    RelPath   = $entryRel
                    SizeBytes = [int64]$entry['SizeBytes']
                    Format    = [string]$entry['Format']
                    Extension = [string]$entry['Extension']
                    Source    = 'DurableLedger'
                }
            }
        }
    }

    return $inventory
}

function Classify-TransferCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LocalFilePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRelativePath,

        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.Dictionary[string, hashtable]]$RemoteInventoryMap,

        [Parameter(Mandatory = $false)]
        [object]$DestinationAccount = $null
    )

    if (-not (Test-Path -LiteralPath $LocalFilePath -PathType Leaf)) {
        return [ordered]@{
            Status         = 'MissingLocalFile'
            ShouldTransfer = $false
            Reason         = "Local source file does not exist: $LocalFilePath"
            LocalFilePath  = $LocalFilePath
            RelativePath   = $DestinationRelativePath
            LocalSizeBytes = 0L
            RemoteSizeBytes= 0L
            LocalFormat    = 'unknown'
            RemoteFormat   = 'unknown'
        }
    }

    $fi = [System.IO.FileInfo]::new($LocalFilePath)
    $localSize = [int64]$fi.Length
    $localExt = $fi.Extension.ToLowerInvariant()
    $localFmt = Get-FileFormatCategory $localExt

    $cleanRel = $DestinationRelativePath.Trim().Replace('\', '/').TrimStart('/')
    $key = $cleanRel
    $inventoryScopePrefix = "`0nscd_live_inventory_scope:"

    # 1. Does candidate file exist in destination inventory?
    if (-not $RemoteInventoryMap.ContainsKey($key)) {
        $parent = [string][System.IO.Path]::GetDirectoryName($cleanRel).Replace('\', '/')
        $scopeKey = '{0}{1}' -f $inventoryScopePrefix, $parent
        if ($RemoteInventoryMap.ContainsKey($scopeKey)) {
            $scope = $RemoteInventoryMap[$scopeKey]
            if ([string]$scope['Source'] -ne 'LiveProviderInventoryScope') {
                return [ordered]@{
                    Status = 'Unavailable'
                    ShouldTransfer = $false
                    Reason = 'The live provider listing for this destination folder could not be verified; transfer is deferred.'
                    LocalFilePath = $LocalFilePath
                    RelativePath = $cleanRel
                    LocalSizeBytes = $localSize
                    RemoteSizeBytes = 0L
                    LocalFormat = $localFmt
                    RemoteFormat = 'unknown'
                }
            }
            return [ordered]@{
                Status = 'New'
                ShouldTransfer = $true
                Reason = 'The live provider listing confirmed this destination path is absent.'
                LocalFilePath = $LocalFilePath
                RelativePath = $cleanRel
                LocalSizeBytes = $localSize
                RemoteSizeBytes = 0L
                LocalFormat = $localFmt
                RemoteFormat = 'none'
            }
        }
        if ($DestinationAccount) {
            $accId = [string](Get-SafeFieldValue $DestinationAccount 'Id')
            $provId = [string](Get-SafeFieldValue $DestinationAccount 'ProviderId')
            $directCheck = Test-RemoteCloudFileDeduplication -AccountId $accId -ProviderId $provId -RemotePath $cleanRel -LocalSizeBytes $localSize -LocalFilePath $LocalFilePath -Account $DestinationAccount -RequireLiveCheck
            if ($directCheck.IsPresent) {
                return [ordered]@{
                    Status          = 'AlreadyInCloud'
                    ShouldTransfer  = $false
                    Reason          = [string]$directCheck.Reason
                    LocalFilePath   = $LocalFilePath
                    RelativePath    = $cleanRel
                    LocalSizeBytes  = $localSize
                    RemoteSizeBytes = [int64]$directCheck.RemoteSizeBytes
                    LocalFormat     = $localFmt
                    RemoteFormat    = [string]$directCheck.Format
                }
            } elseif ($directCheck.Status -in @('FormatMismatch', 'SizeMismatch', 'PathMismatch')) {
                return [ordered]@{
                    Status          = [string]$directCheck.Status
                    ShouldTransfer  = $true
                    Reason          = [string]$directCheck.Reason
                    LocalFilePath   = $LocalFilePath
                    RelativePath    = $cleanRel
                    LocalSizeBytes  = $localSize
                    RemoteSizeBytes = [int64]$directCheck.RemoteSizeBytes
                    LocalFormat     = $localFmt
                    RemoteFormat    = [string]$directCheck.Format
                }
            } elseif ($directCheck.Status -eq 'Unavailable') {
                return [ordered]@{
                    Status = 'Unavailable'
                    ShouldTransfer = $false
                    Reason = [string]$directCheck.Reason
                    LocalFilePath = $LocalFilePath
                    RelativePath = $cleanRel
                    LocalSizeBytes = $localSize
                    RemoteSizeBytes = [int64]$directCheck.RemoteSizeBytes
                    LocalFormat = $localFmt
                    RemoteFormat = 'unknown'
                }
            }
        }

        # Check if same base name exists with a DIFFERENT format/extension (e.g. photo.png vs photo.jpg)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($cleanRel)
        $parentRel = [System.IO.Path]::GetDirectoryName($cleanRel).Replace('\', '/')
        $matchedDifferentFormat = $null

        foreach ($existingKey in $RemoteInventoryMap.Keys) {
            if ($existingKey.StartsWith($inventoryScopePrefix, [System.StringComparison]::Ordinal)) { continue }
            $exItem = $RemoteInventoryMap[$existingKey]
            $exBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$exItem['RelPath'])
            $exParent = [System.IO.Path]::GetDirectoryName([string]$exItem['RelPath']).Replace('\', '/')
            if ([string]::Equals($exBase, $baseName, [System.StringComparison]::Ordinal) -and [string]::Equals($exParent, $parentRel, [System.StringComparison]::Ordinal)) {
                $matchedDifferentFormat = $exItem
                break
            }
        }

        if ($matchedDifferentFormat) {
            return [ordered]@{
                Status         = 'FormatMismatch'
                ShouldTransfer = $true
                Reason         = "Format mismatch: local is $($localFmt.ToUpper()) ($($fi.Name)), remote has $($matchedDifferentFormat['Format'].ToUpper()) ($($matchedDifferentFormat['Name'])). Re-sending as different format."
                LocalFilePath  = $LocalFilePath
                RelativePath   = $cleanRel
                LocalSizeBytes = $localSize
                RemoteSizeBytes= [int64]$matchedDifferentFormat['SizeBytes']
                LocalFormat    = $localFmt
                RemoteFormat   = [string]$matchedDifferentFormat['Format']
            }
        }

        return [ordered]@{
            Status         = 'New'
            ShouldTransfer = $true
            Reason         = "New file not present in cloud storage."
            LocalFilePath  = $LocalFilePath
            RelativePath   = $cleanRel
            LocalSizeBytes = $localSize
            RemoteSizeBytes= 0L
            LocalFormat    = $localFmt
            RemoteFormat   = 'none'
        }
    }

    # 2. File exists at exact destination path: inspect format and size
    $remote = $RemoteInventoryMap[$key]
    if ($remote.ContainsKey('IsDirectory') -and [bool]$remote['IsDirectory']) {
        return [ordered]@{
            Status = 'PathMismatch'
            ShouldTransfer = $true
            Reason = 'A directory exists at the exact destination path; it is not an uploaded file.'
            LocalFilePath = $LocalFilePath
            RelativePath = $cleanRel
            LocalSizeBytes = $localSize
            RemoteSizeBytes = 0L
            LocalFormat = $localFmt
            RemoteFormat = 'directory'
        }
    }
    $remoteSize = [int64]$remote['SizeBytes']
    $remoteFmt = [string]$remote['Format']
    $remoteExt = [string]$remote['Extension']

    # Check format match (e.g. PNG vs JPG)
    if ($localFmt -ne $remoteFmt) {
        return [ordered]@{
            Status         = 'FormatMismatch'
            ShouldTransfer = $true
            Reason         = "Format mismatch: local file is $localFmt but destination file is $remoteFmt. Re-sending."
            LocalFilePath  = $LocalFilePath
            RelativePath   = $cleanRel
            LocalSizeBytes = $localSize
            RemoteSizeBytes= $remoteSize
            LocalFormat    = $localFmt
            RemoteFormat   = $remoteFmt
        }
    }

    # Check size match
    if ($localSize -ne $remoteSize) {
        return [ordered]@{
            Status         = 'SizeMismatch'
            ShouldTransfer = $true
            Reason         = "Size mismatch: local has $localSize bytes, cloud has $remoteSize bytes. Re-sending modified file."
            LocalFilePath  = $LocalFilePath
            RelativePath   = $cleanRel
            LocalSizeBytes = $localSize
            RemoteSizeBytes= $remoteSize
            LocalFormat    = $localFmt
            RemoteFormat   = $remoteFmt
        }
    }

    # 3. Everything matches: destination file exists, extension/format matches, exact size matches!
    return [ordered]@{
        Status         = 'AlreadyInCloud'
        ShouldTransfer = $false
        Reason         = "File already present in cloud with identical format ($localFmt) and size ($localSize bytes). Skipping transfer to save time."
        LocalFilePath  = $LocalFilePath
        RelativePath   = $cleanRel
        LocalSizeBytes = $localSize
        RemoteSizeBytes= $remoteSize
        LocalFormat    = $localFmt
        RemoteFormat   = $remoteFmt
    }
}

function Classify-TransferBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$FilePaths,

        [Parameter(Mandatory = $true)]
        [object]$DestinationAccount,

        [Parameter(Mandatory = $false)]
        [string]$DestinationFolderPath = '',

        [Parameter(Mandatory = $false)]
        [string]$SourceRootPath = ''
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $inventory = Get-RemoteFileInventoryMap `
        -DestinationAccount $DestinationAccount `
        -DestinationFolderPath $DestinationFolderPath

    $results = [System.Collections.Generic.List[hashtable]]::new()
    $alreadyInCloud = [System.Collections.Generic.List[hashtable]]::new()
    $toTransfer = [System.Collections.Generic.List[hashtable]]::new()

    $totalScanned = 0
    $skippedBytes = 0L
    $bytesToSend = 0L
    $newCount = 0
    $modifiedCount = 0

    $cleanSourceRoot = if ($SourceRootPath) { $SourceRootPath.TrimEnd('\', '/') } else { '' }

    foreach ($fp in $FilePaths) {
        if (-not $fp) { continue }
        $totalScanned++

        $relPath = if ($cleanSourceRoot -and $fp.StartsWith($cleanSourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $fp.Substring($cleanSourceRoot.Length).TrimStart('\', '/').Replace('\', '/')
        } else {
            [System.IO.Path]::GetFileName($fp)
        }

        $destRel = if ($DestinationFolderPath) {
            $df = $DestinationFolderPath.Trim().Replace('\', '/').TrimStart('/').TrimEnd('/')
            "$df/$relPath"
        } else {
            $relPath
        }

        $classification = Classify-TransferCandidate `
            -LocalFilePath $fp `
            -DestinationRelativePath $destRel `
            -RemoteInventoryMap $inventory `
            -DestinationAccount $DestinationAccount

        $results.Add($classification)

        if ($classification.Status -eq 'AlreadyInCloud') {
            $alreadyInCloud.Add($classification)
            $skippedBytes += [int64]$classification.LocalSizeBytes
        } else {
            $toTransfer.Add($classification)
            $bytesToSend += [int64]$classification.LocalSizeBytes
            if ($classification.Status -eq 'New') {
                $newCount++
            } else {
                $modifiedCount++
            }
        }
    }

    $sw.Stop()

    $summary = [ordered]@{
        TotalScanned        = $totalScanned
        AlreadyInCloudCount = $alreadyInCloud.Count
        NewFilesCount       = $newCount
        ModifiedFilesCount  = $modifiedCount
        FilesToTransferCount= $toTransfer.Count
        SkippedBytes        = $skippedBytes
        BytesToTransfer     = $bytesToSend
        ClassificationMs    = $sw.ElapsedMilliseconds
    }

    return [ordered]@{
        Summary        = $summary
        AlreadyInCloud = @($alreadyInCloud.ToArray())
        ToTransfer     = @($toTransfer.ToArray())
        AllDetails     = @($results.ToArray())
    }
}
