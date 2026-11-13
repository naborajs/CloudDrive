# ==============================================================================
# NS Cloud Drive - Intelligent Cloud Deduplication & Delta Classifier Service
# Fast pre-transfer inspection: skips existing files with identical size & format.
# Detects format differences (e.g. PNG vs JPG) and size mismatches to re-send.
# Persists remote verification ledger across device restarts.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SettingsManager.ps1')

function Get-SafeFieldValue($Item, [string]$Name) {
    if ($null -eq $Item) { return $null }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $null
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
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
                    $enumOptions = [System.IO.SearchOption]::AllDirectories
                    $files = [System.IO.Directory]::EnumerateFiles($targetDir, '*', $enumOptions)
                    $rootLen = $targetDir.Length
                    foreach ($f in $files) {
                        $fi = [System.IO.FileInfo]::new($f)
                        $rel = $f.Substring($rootLen).TrimStart('\', '/').Replace('\', '/')
                        $fullRel = if ($cleanFolder) { "$cleanFolder/$rel" } else { $rel }
                        $normKey = $fullRel.ToLowerInvariant()
                        $inventory[$normKey] = [ordered]@{
                            Name      = $fi.Name
                            RelPath   = $fullRel
                            SizeBytes = [int64]$fi.Length
                            Format    = Get-FileFormatCategory $fi.Extension
                            Extension = $fi.Extension.ToLowerInvariant()
                            Source    = 'LocalVfsMount'
                        }
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
        [System.Collections.Generic.Dictionary[string, hashtable]]$RemoteInventoryMap
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
            -RemoteInventoryMap $inventory

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
