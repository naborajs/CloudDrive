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
$script:DedupLedgerPathOverride = $null
$script:DedupLedgerLoaded = $false
$script:DedupLedgerLock = [System.Object]::new()

function Get-CloudDedupLedgerPath {
    if ($script:DedupLedgerPathOverride) {
        return $script:DedupLedgerPathOverride
    }
    $cacheDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\cache'
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
        [System.Collections.IDictionary]$Account = $null
    )

    $cleanPath = $RemotePath.Trim().Replace('\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($cleanPath)) {
        return [ordered]@{ IsPresent = $false; Status = 'EmptyPath'; Reason = 'Remote path is empty.' }
    }

    $localExt = [System.IO.Path]::GetExtension($cleanPath).ToLowerInvariant()
    $localFmt = Get-FileFormatCategory $localExt

    # 1. Fast Path: Check in-memory deduplication ledger cache (0 ms)
    if (Test-CloudDedupVerifiedFile -AccountId $AccountId -RemotePath $cleanPath -SizeBytes $LocalSizeBytes -Format $localFmt) {
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
    $prov = if ($ProviderId) { $ProviderId } else { 'gdrive' }
    if ($Account) {
        if (-not $ProviderId -and $Account.Contains('ProviderId')) { $prov = [string]$Account['ProviderId'] }
        if ($Account.Contains('DriveLetter') -and $Account['DriveLetter']) {
            $letter = ([string]$Account['DriveLetter']).ToUpperInvariant().TrimEnd(':')
            if ($letter -match '^[A-Z]$' -and (Test-Path -LiteralPath "${letter}:\" -ErrorAction SilentlyContinue)) {
                $mountRoot = "${letter}:\"
            }
        }
    }

    if (-not $mountRoot -and (Get-Command Get-VirtualDriveStatus -ErrorAction SilentlyContinue)) {
        try {
            $status = Get-VirtualDriveStatus -AccountId $AccountId -ProviderId $prov
            if ($status -and $status.IsMounted -and $status.DriveRoot -and (Test-Path -LiteralPath $status.DriveRoot -ErrorAction SilentlyContinue)) {
                $mountRoot = $status.DriveRoot
            }
        } catch { }
    }

    if ($mountRoot) {
        $targetCloudPath = Join-Path $mountRoot ($cleanPath.Replace('/', '\'))
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
                if ([System.IO.Directory]::Exists($parentCloudDir)) {
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
        }
    }

    # 3. Direct Rclone RC operations/stat fallback
    try {
        $cleanLetter = if ($mountRoot) { $mountRoot.ToUpperInvariant().TrimEnd(':').TrimEnd('\') } else { '' }
        $rcPort = 0
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
                            $rcSize = [int64]$statObj.item.Size
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
    } catch { }

    return [ordered]@{
        IsPresent       = $false
        Status          = 'New'
        RemoteSizeBytes = 0L
        Format          = $localFmt
        Reason          = 'Not found in cloud storage. Queued for upload.'
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
        [System.Collections.IDictionary]$DestinationAccount,

        [Parameter(Mandatory = $false)]
        [string]$DestinationFolderPath = '',

        [Parameter(Mandatory = $false)]
        [switch]$BypassMount
    )

    $inventory = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $accId = [string](Get-SafeFieldValue $DestinationAccount 'Id')
    $provId = [string](Get-SafeFieldValue $DestinationAccount 'ProviderId')
    if (-not $provId) { $provId = 'gdrive' }

    $cleanFolder = if ($DestinationFolderPath) { $DestinationFolderPath.Trim().Replace('\', '/').TrimStart('/').TrimEnd('/') } else { '' }

    # Fast-Path 1: Read through mounted Windows Virtual Drive if active
    if (-not $BypassMount -and (Get-Command Get-VirtualDriveStatus -ErrorAction SilentlyContinue)) {
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
                        $normKey = $fullRel.ToLowerInvariant()
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
            $normKey = $entryRel.ToLowerInvariant()
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
        [System.Collections.IDictionary]$DestinationAccount = $null
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
    $key = $cleanRel.ToLowerInvariant()

    # 1. Does candidate file exist in destination inventory?
    if (-not $RemoteInventoryMap.ContainsKey($key)) {
        if ($DestinationAccount) {
            $accId = [string](Get-SafeFieldValue $DestinationAccount 'Id')
            $provId = [string](Get-SafeFieldValue $DestinationAccount 'ProviderId')
            $directCheck = Test-RemoteCloudFileDeduplication -AccountId $accId -ProviderId $provId -RemotePath $cleanRel -LocalSizeBytes $localSize -LocalFilePath $LocalFilePath -Account $DestinationAccount
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
            } elseif ($directCheck.Status -in @('FormatMismatch', 'SizeMismatch')) {
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
            }
        }

        # Check if same base name exists with a DIFFERENT format/extension (e.g. photo.png vs photo.jpg)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($cleanRel)
        $parentRel = [System.IO.Path]::GetDirectoryName($cleanRel).Replace('\', '/')
        $matchedDifferentFormat = $null

        foreach ($existingKey in $RemoteInventoryMap.Keys) {
            $exItem = $RemoteInventoryMap[$existingKey]
            $exBase = [System.IO.Path]::GetFileNameWithoutExtension([string]$exItem['RelPath'])
            $exParent = [System.IO.Path]::GetDirectoryName([string]$exItem['RelPath']).Replace('\', '/')
            if ($exBase -eq $baseName -and $exParent -eq $parentRel) {
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
        [System.Collections.IDictionary]$DestinationAccount,

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
