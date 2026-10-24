# ExplorerIntegration.ps1 - Per-user Explorer drive icons and labels for NS Cloud Drive
#
# Mechanism: the Windows Shell consults
#   HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\<X>\DefaultIcon
# (per-user) before the HKLM equivalent when drawing drive icons. Registering the
# icon under HKCU keeps the change limited to the current user's view of only the
# drive letters this application mounted, needs no elevation, and never overwrites
# machine-wide or third-party settings. Every key the app creates is stamped with
# an NSCloudDriveOwner value so cleanup can remove exactly what it owns.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:NSCloudDriveIconOwner = 'NS Cloud Drive'
$script:NSCloudDriveDriveIconsRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons'

# Compares a stored registry icon entry ("C:\path\icon.ico,0") against a freshly
# resolved icon file path. ENV-variable driven paths can legitimately appear in
# short 8.3 form, and GetFullPath expands short names only for existing files,
# so both sides are resolved to their long first-seen instance before compare.
function Test-NSCloudDriveIconEntryMatches([string]$StoredEntry, [string]$IconPath) {
    if ([string]::IsNullOrWhiteSpace($StoredEntry) -or [string]::IsNullOrWhiteSpace($IconPath)) { return $false }
    $storedFile = ([string]$StoredEntry) -replace ',0\s*$', ''
    try { $storedFile = [System.IO.Path]::GetFullPath($storedFile) } catch { return $false }
    try { $freshFile = [System.IO.Path]::GetFullPath($IconPath) } catch { return $false }
    if ([string]::Equals($storedFile, $freshFile, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    try {
        $expandedStored = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $storedFile -ErrorAction Stop).FullName)
        $expandedFresh = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $freshFile -ErrorAction Stop).FullName)
        return [string]::Equals($expandedStored, $expandedFresh, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-NSCloudDriveExplorerIconAsset([string]$ProviderId) {
    $assetName = switch ($ProviderId.ToLowerInvariant()) {
        { $_ -in @('gdrive', 'google', 'googledrive') } { 'googledrive.png'; break }
        { $_ -in @('terabox', 'tera-box') } { 'terabox.png'; break }
        default { throw "No Explorer icon is defined for provider '$ProviderId'." }
    }
    $path = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot (Join-Path '..\..\assets\logos' $assetName)))
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Provider icon asset is missing: $assetName" }
    return $path
}

function Get-NSCloudDriveExplorerIconPath([string]$ProviderId, [string]$SourceAsset = '') {
    $iconName = switch ($ProviderId.ToLowerInvariant()) {
        { $_ -in @('gdrive', 'google', 'googledrive') } { 'google-drive.ico'; break }
        { $_ -in @('terabox', 'tera-box') } { 'terabox.ico'; break }
        default { throw "No Explorer icon is defined for provider '$ProviderId'." }
    }
    $assetPath = if ($SourceAsset) { $SourceAsset } else { Get-NSCloudDriveExplorerIconAsset $ProviderId }
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) { throw 'Provider icon asset is unavailable.' }
    $directory = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\icons'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $iconPath = Join-Path $directory $iconName
    $sourceInfo = [System.IO.FileInfo]::new((Resolve-Path -LiteralPath $assetPath).Path)
    $targetInfo = if (Test-Path -LiteralPath $iconPath -PathType Leaf) { [System.IO.FileInfo]::new($iconPath) } else { $null }
    if (-not $targetInfo -or $targetInfo.LastWriteTimeUtc -lt $sourceInfo.LastWriteTimeUtc) {
        $tempIcon = "$iconPath.$([guid]::NewGuid().ToString('N')).tmp"
        $bitmap = $null; $scaled = $null; $graphics = $null; $icon = $null; $handle = [IntPtr]::Zero
        $baseDriveBmp = $null; $driveIconHandle = [IntPtr]::Zero
        try {
            if (-not ('NSCloudDrive.ExplorerNative' -as [type])) {
                Add-Type -Namespace NSCloudDrive -Name ExplorerNative -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr handle); [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern void SHChangeNotify(uint eventId, uint flags, string path1, System.IntPtr path2);'
            }
            if (-not ('NSCloudDrive.DriveIconBuilder' -as [type])) {
                Add-Type -Namespace NSCloudDrive -Name DriveIconBuilder -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)] public static extern uint PrivateExtractIcons(string szFileName, int nIconIndex, int cxIcon, int cyIcon, System.IntPtr[] phicon, uint[] piconid, uint nIcons, uint flags); [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr handle);'
            }
            Add-Type -AssemblyName System.Drawing
            try {
                $phicon = New-Object IntPtr[] 1
                $extractCount = [NSCloudDrive.DriveIconBuilder]::PrivateExtractIcons('C:\Windows\System32\imageres.dll', 27, 128, 128, $phicon, $null, 1, 0)
                if ($extractCount -gt 0 -and $phicon[0] -ne [IntPtr]::Zero) {
                    $driveIconHandle = $phicon[0]
                    $extractedIco = [System.Drawing.Icon]::FromHandle($driveIconHandle)
                    $baseDriveBmp = $extractedIco.ToBitmap()
                }
            } catch { }

            $bitmap = [System.Drawing.Bitmap]::new($sourceInfo.FullName)
            $scaled = [System.Drawing.Bitmap]::new(128, 128, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [System.Drawing.Graphics]::FromImage($scaled)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

            if ($baseDriveBmp) {
                # 1. Base drive chassis (native Windows disk drive look matching C: and D: drives)
                $graphics.DrawImage($baseDriveBmp, 0, 0, 128, 128)

                # 2. Provider logo badge on top-left of the drive (matching Windows OS logo on C: drive)
                $badgeW = 50
                $badgeH = 50
                $badgeX = 8
                $badgeY = 6
                if ($ProviderId.ToLowerInvariant() -in @('terabox', 'tera-box')) {
                    $radius = 10
                    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
                    $r = [System.Drawing.Rectangle]::new($badgeX, $badgeY, $badgeW, $badgeH)
                    $d = $radius * 2
                    $path.AddArc($r.X, $r.Y, $d, $d, 180, 90)
                    $path.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
                    $path.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
                    $path.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
                    $path.CloseFigure()
                    $state = $graphics.Save()
                    $graphics.SetClip($path)
                    $graphics.DrawImage($bitmap, $badgeX, $badgeY, $badgeW, $badgeH)
                    $graphics.Restore($state)
                    $path.Dispose()
                } else {
                    $graphics.DrawImage($bitmap, $badgeX, $badgeY, $badgeW, $badgeH)
                }
            } else {
                $graphics.DrawImage($bitmap, 0, 0, 128, 128)
            }
            $graphics.Dispose(); $graphics = $null
            $ms = [System.IO.MemoryStream]::new()
            $scaled.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $pngBytes = $ms.ToArray()
            $ms.Dispose()

            $fs = [System.IO.File]::Open($tempIcon, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $bw = [System.IO.BinaryWriter]::new($fs)
            try {
                $bw.Write([uint16]0)
                $bw.Write([uint16]1)
                $bw.Write([uint16]1)
                $bw.Write([byte]128)
                $bw.Write([byte]128)
                $bw.Write([byte]0)
                $bw.Write([byte]0)
                $bw.Write([uint16]1)
                $bw.Write([uint16]32)
                $bw.Write([uint32]$pngBytes.Length)
                $bw.Write([uint32]22)
                $bw.Write($pngBytes)
            } finally {
                $bw.Dispose()
                $fs.Dispose()
            }
            if (Test-Path -LiteralPath $iconPath) { Move-Item -LiteralPath $tempIcon -Destination $iconPath -Force } else { Move-Item -LiteralPath $tempIcon -Destination $iconPath }
        } finally {
            if ($graphics) { $graphics.Dispose() }; if ($scaled) { $scaled.Dispose() }; if ($icon) { $icon.Dispose() }; if ($bitmap) { $bitmap.Dispose() }
            if ($baseDriveBmp) { $baseDriveBmp.Dispose() }
            if ($driveIconHandle -ne [IntPtr]::Zero) { [NSCloudDrive.DriveIconBuilder]::DestroyIcon($driveIconHandle) | Out-Null }
            if ($handle -ne [IntPtr]::Zero) { [NSCloudDrive.ExplorerNative]::DestroyIcon($handle) | Out-Null }
            if (Test-Path -LiteralPath $tempIcon) { Remove-Item -LiteralPath $tempIcon -Force -ErrorAction SilentlyContinue }
        }
    }
    return $iconPath
}

function Get-NSCloudDriveExplorerIconRegistration([string]$DriveLetter, [string]$RegistryRoot = $script:NSCloudDriveDriveIconsRoot) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter -notmatch '^[A-Z]$') { throw 'Drive letter must be a single letter from A to Z.' }
    $letterKey = Join-Path $RegistryRoot $letter; $iconKey = Join-Path $letterKey 'DefaultIcon'
    $owner = $null; $icon = $null
    try { $owner = (Get-ItemProperty -LiteralPath $letterKey -Name 'NSCloudDriveOwner' -ErrorAction Stop).NSCloudDriveOwner } catch { }
    try { $icon = (Get-Item -LiteralPath $iconKey -ErrorAction Stop).GetValue('') } catch { }
    return [ordered]@{ DriveLetter = $letter; Owner = [string]$owner; IconPath = [string]$icon; IsOwned = ($owner -eq $script:NSCloudDriveIconOwner) }
}

function Set-NSCloudDriveExplorerIcon([string]$DriveLetter, [string]$IconPath, [string]$RegistryRoot = $script:NSCloudDriveDriveIconsRoot) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter -notmatch '^[A-Z]$') { throw 'Drive letter must be a single letter from A to Z.' }
    if (-not (Test-Path -LiteralPath $IconPath -PathType Leaf)) { throw 'The persistent icon file does not exist.' }
    $existing = Get-NSCloudDriveExplorerIconRegistration $letter $RegistryRoot
    $normalizedIcon = [System.IO.Path]::GetFullPath($IconPath)
    if ($existing.IsOwned) {
        if (-not (Test-NSCloudDriveIconEntryMatches $existing.IconPath $normalizedIcon)) { throw "Drive $letter`: has a different app icon; refusing to replace it." }
        return [ordered]@{ Success = $true; State = 'AlreadyRegistered'; DriveLetter = $letter; IconPath = $existing.IconPath }
    }
    if ($existing.IconPath) { return [ordered]@{ Success = $false; State = 'Conflict'; DriveLetter = $letter; IconPath = $existing.IconPath } }
    $letterKey = Join-Path $RegistryRoot $letter; $iconKey = Join-Path $letterKey 'DefaultIcon'
    New-Item -Path $letterKey -Force | Out-Null; New-Item -Path $iconKey -Force | Out-Null
    Set-Item -LiteralPath $iconKey -Value "$normalizedIcon,0"
    Set-ItemProperty -LiteralPath $letterKey -Name 'NSCloudDriveOwner' -Value $script:NSCloudDriveIconOwner -Type String
    if ($RegistryRoot -eq $script:NSCloudDriveDriveIconsRoot) {
        try {
            $classesRoot = 'HKCU:\Software\Classes\Applications\Explorer.exe\Drives'
            $classesLetterKey = Join-Path $classesRoot $letter
            $classesIconKey = Join-Path $classesLetterKey 'DefaultIcon'
            New-Item -Path $classesLetterKey -Force | Out-Null
            New-Item -Path $classesIconKey -Force | Out-Null
            Set-Item -LiteralPath $classesIconKey -Value "$normalizedIcon,0"
            Set-ItemProperty -LiteralPath $classesLetterKey -Name 'NSCloudDriveOwner' -Value $script:NSCloudDriveIconOwner -Type String
        } catch { }
    }
    return [ordered]@{ Success = $true; State = 'Registered'; DriveLetter = $letter; IconPath = "$normalizedIcon,0" }
}

function Remove-NSCloudDriveExplorerIcon([string]$DriveLetter, [string]$ExpectedIconPath, [string]$RegistryRoot = $script:NSCloudDriveDriveIconsRoot) {
    $current = Get-NSCloudDriveExplorerIconRegistration $DriveLetter $RegistryRoot
    if (-not $current.IsOwned) { return [ordered]@{ Success = $true; State = 'NotOwned'; DriveLetter = $current.DriveLetter } }
    if (-not (Test-NSCloudDriveIconEntryMatches $current.IconPath $ExpectedIconPath)) { return [ordered]@{ Success = $false; State = 'Conflict'; DriveLetter = $current.DriveLetter } }
    $letterKey = Join-Path $RegistryRoot $current.DriveLetter; $iconKey = Join-Path $letterKey 'DefaultIcon'
    if (Test-Path -LiteralPath $iconKey) { Remove-Item -LiteralPath $iconKey -Recurse -Force }
    Remove-ItemProperty -LiteralPath $letterKey -Name 'NSCloudDriveOwner' -ErrorAction SilentlyContinue
    $remaining = @((Get-Item -LiteralPath $letterKey).GetValueNames())
    $children = @(Get-ChildItem -LiteralPath $letterKey)
    if ($remaining.Count -eq 0 -and $children.Count -eq 0) { Remove-Item -LiteralPath $letterKey -Force }
    if ($RegistryRoot -eq $script:NSCloudDriveDriveIconsRoot) {
        try {
            $classesKey = Join-Path 'HKCU:\Software\Classes\Applications\Explorer.exe\Drives' $current.DriveLetter
            if (Test-Path -LiteralPath $classesKey) { Remove-Item -LiteralPath $classesKey -Recurse -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    return [ordered]@{ Success = $true; State = 'Removed'; DriveLetter = $current.DriveLetter }
}

function Update-NSCloudDriveExplorerItem([string]$DriveLetter, [switch]$DriveAdded) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter -notmatch '^[A-Z]$') { throw 'Drive letter must be a single letter from A to Z.' }
    if (-not ('NSCloudDrive.ExplorerNative' -as [type])) {
        Add-Type -Namespace NSCloudDrive -Name ExplorerNative -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr handle); [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern void SHChangeNotify(uint eventId, uint flags, string path1, System.IntPtr path2);'
    }
    if ($DriveAdded) { [NSCloudDrive.ExplorerNative]::SHChangeNotify(0x00000100, 0x00000005, "$letter`:\", [IntPtr]::Zero) }
    [NSCloudDrive.ExplorerNative]::SHChangeNotify(0x00002000, 0x00000005, "$letter`:\", [IntPtr]::Zero)
    try {
        # SHCNE_ASSOCCHANGED (0x08000000) tells Windows Explorer shell to refresh drive icons cache
        [NSCloudDrive.ExplorerNative]::SHChangeNotify(0x08000000, 0x0000, $null, [IntPtr]::Zero)
    } catch { }
    return $true
}

# Registers or removes this application's own Explorer icon for one drive
# letter. The action is idempotent, fails closed on foreign registrations
# (returns Conflict without touching them), and never throws into UI flows.
# $RegistryRoot defaults to the real per-user DriveIcons key and may be
# overridden by tests with an isolated sandbox root.
function Invoke-NSCloudDriveExplorerIconRegistration([string]$Action, [string]$DriveLetter, [string]$ProviderId, [string]$RegistryRoot = $script:NSCloudDriveDriveIconsRoot) {
    $letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    if ($letter -notmatch '^[A-Z]$') { throw 'Drive letter must be a single letter from A to Z.' }
    if ($Action -notin @('Register', 'Remove')) { throw 'Action must be Register or Remove.' }
    try {
        $iconPath = Get-NSCloudDriveExplorerIconPath $ProviderId
        $current = Get-NSCloudDriveExplorerIconRegistration $letter $RegistryRoot
        if ($Action -eq 'Register' -and $current.IsOwned -and (Test-NSCloudDriveIconEntryMatches $current.IconPath $iconPath)) {
            if ($RegistryRoot -eq $script:NSCloudDriveDriveIconsRoot) {
                try {
                    $classesLetterKey = Join-Path 'HKCU:\Software\Classes\Applications\Explorer.exe\Drives' $letter
                    $classesIconKey = Join-Path $classesLetterKey 'DefaultIcon'
                    New-Item -Path $classesLetterKey -Force | Out-Null
                    New-Item -Path $classesIconKey -Force | Out-Null
                    $normalizedIcon = [System.IO.Path]::GetFullPath($iconPath)
                    Set-Item -LiteralPath $classesIconKey -Value "$normalizedIcon,0"
                    Set-ItemProperty -LiteralPath $classesLetterKey -Name 'NSCloudDriveOwner' -Value $script:NSCloudDriveIconOwner -Type String
                } catch { }
            }
            Update-NSCloudDriveExplorerItem $letter | Out-Null
            return [ordered]@{ Success = $true; State = 'AlreadyRegistered'; DriveLetter = $letter }
        }
        if ($Action -eq 'Remove' -and -not $current.IsOwned) { return [ordered]@{ Success = $true; State = 'NotOwned'; DriveLetter = $letter } }
        if ($Action -eq 'Register' -and $current.IconPath) { return [ordered]@{ Success = $false; State = 'Conflict'; DriveLetter = $letter; IconPath = $current.IconPath } }
        if ($Action -eq 'Register') {
            $result = Set-NSCloudDriveExplorerIcon -DriveLetter $letter -IconPath $iconPath -RegistryRoot $RegistryRoot
        } else {
            $result = Remove-NSCloudDriveExplorerIcon -DriveLetter $letter -ExpectedIconPath $iconPath -RegistryRoot $RegistryRoot
        }
        Update-NSCloudDriveExplorerItem $letter | Out-Null
        return $result
    } catch {
        return [ordered]@{ Success = $false; State = 'Error'; DriveLetter = $letter; Error = (Format-SanitizedDiagnosticMessage ([string]$_.Exception.Message)) }
    }
}
