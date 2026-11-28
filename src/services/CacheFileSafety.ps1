Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([System.Management.Automation.PSTypeName]'NSCloudDrive.SafeCacheFileHandle').Type) {
    $safeDeleteSource = @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NSCloudDrive
{
    public static class SafeCacheFileHandle
    {
        private const uint GenericRead = 0x80000000;
        private const uint DeleteAccess = 0x00010000;
        private const uint OpenExisting = 3;
        private const uint OpenReparsePoint = 0x00200000;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileDispositionInfo
        {
            public byte DeleteFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle handle,
            int fileInformationClass,
            ref FileDispositionInfo information,
            uint bufferSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("libc", CharSet = CharSet.Ansi, SetLastError = true, EntryPoint = "unlink")]
        private static extern int UnixUnlink(string path);

        [DllImport("libc", CharSet = CharSet.Ansi, SetLastError = true, EntryPoint = "open")]
        private static extern int UnixOpenRead(string path, int flags);

        [DllImport("libc", CharSet = CharSet.Ansi, SetLastError = true, EntryPoint = "chmod")]
        private static extern int UnixChmod(string path, uint mode);

        public static SafeFileHandle OpenExclusiveReadDelete(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                GenericRead | DeleteAccess,
                0,
                IntPtr.Zero,
                OpenExisting,
                OpenReparsePoint,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (handle != null) handle.Dispose();
                throw new System.ComponentModel.Win32Exception(error, "Could not open the cache file exclusively.");
            }
            return handle;
        }

        public static bool MarkForDeletion(SafeFileHandle handle, out int error)
        {
            FileDispositionInfo information = new FileDispositionInfo();
            information.DeleteFile = 1;
            bool succeeded = SetFileInformationByHandle(
                handle,
                4,
                ref information,
                (uint)Marshal.SizeOf(typeof(FileDispositionInfo)));
            error = succeeded ? 0 : Marshal.GetLastWin32Error();
            return succeeded;
        }

        public static bool UnlinkUnixPath(string path, out int error)
        {
            int result = UnixUnlink(path);
            error = result == 0 ? 0 : Marshal.GetLastWin32Error();
            return result == 0;
        }

        public static SafeFileHandle OpenUnixRead(string path)
        {
            int descriptor = UnixOpenRead(path, 0);
            if (descriptor < 0)
            {
                int error = Marshal.GetLastWin32Error();
                throw new System.ComponentModel.Win32Exception(error, "Could not open the cache path for identity verification.");
            }
            return new SafeFileHandle(new IntPtr(descriptor), true);
        }

        public static bool RestrictUnixDirectory(string path, out int error)
        {
            int result = UnixChmod(path, 0x1C0); // 0700: owner only
            error = result == 0 ? 0 : Marshal.GetLastWin32Error();
            return result == 0;
        }
    }
}
"@
    try {
        Add-Type -TypeDefinition $safeDeleteSource -ErrorAction Stop
    } catch {
        if (-not ([System.Management.Automation.PSTypeName]'NSCloudDrive.SafeCacheFileHandle').Type) { throw }
    }
}

function Open-CacheFileExclusiveRead {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $safeHandle = [NSCloudDrive.SafeCacheFileHandle]::OpenExclusiveReadDelete($Path)
        try {
            return [System.IO.FileStream]::new($safeHandle, [System.IO.FileAccess]::Read)
        } catch {
            $safeHandle.Dispose()
            throw
        }
    }

    return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
}

function Get-CacheStreamSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

    $originalPosition = $Stream.Position
    try {
        $Stream.Position = 0
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        if ($Stream.CanSeek) { $Stream.Position = $originalPosition }
    }
}

function Get-CachePathSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $safeHandle = $null
    try {
        if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $stream = Open-CacheFileExclusiveRead -Path $Path
        } else {
            $safeHandle = [NSCloudDrive.SafeCacheFileHandle]::OpenUnixRead($Path)
            $stream = [System.IO.FileStream]::new($safeHandle, [System.IO.FileAccess]::Read)
            $safeHandle = $null
        }
        return Get-CacheStreamSha256 -Stream $stream
    } finally {
        if ($stream) { $stream.Dispose() }
        elseif ($safeHandle) { $safeHandle.Dispose() }
    }
}

function Remove-CacheFileByExclusiveHandle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.IO.FileStream]$Stream,
        [string]$ExpectedSha256 = ''
    )

    if ([Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $nativeError = 0
        if (-not [NSCloudDrive.SafeCacheFileHandle]::MarkForDeletion($Stream.SafeFileHandle, [ref]$nativeError)) {
            throw [System.ComponentModel.Win32Exception]::new($nativeError, 'Could not mark the verified cache file handle for deletion.')
        }
        return
    }

    # Unix permits unlinking a different file after a path swap even while the
    # original stream is open. Atomically claim the pathname in a private sibling
    # directory, verify the claimed object's content against the held stream, then
    # delete that claimed revision. If it changed, restore it when the original
    # pathname is still free; otherwise preserve the claim for manual recovery.
    $streamHash = if ($ExpectedSha256) { $ExpectedSha256 } else { Get-CacheStreamSha256 -Stream $Stream }
    $pathItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($pathItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The cache path became a reparse point before its atomic claim.'
    }
    $parentDirectory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not $parentDirectory) { throw 'The cache file has no parent directory for a safe claim.' }
    $claimDirectory = Join-Path $parentDirectory ('.nscd-delete-' + [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($claimDirectory)
    $permissionError = 0
    if (-not [NSCloudDrive.SafeCacheFileHandle]::RestrictUnixDirectory($claimDirectory, [ref]$permissionError)) {
        try { [System.IO.Directory]::Delete($claimDirectory, $false) } catch { }
        throw [System.ComponentModel.Win32Exception]::new($permissionError, 'Could not make the temporary cache claim private.')
    }

    $claimPath = Join-Path $claimDirectory ([System.IO.Path]::GetFileName($Path))
    $movedToClaim = $false
    $preserveClaim = $false
    try {
        [System.IO.File]::Move($Path, $claimPath)
        $movedToClaim = $true
        $claimedItem = Get-Item -LiteralPath $claimPath -Force -ErrorAction Stop
        if (($claimedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The claimed cache object is a reparse point.'
        }
        $claimedHash = Get-CachePathSha256 -Path $claimPath
        if (-not [string]::Equals($claimedHash, $streamHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            if (-not (Test-Path -LiteralPath $Path)) {
                [System.IO.File]::Move($claimPath, $Path)
                $movedToClaim = $false
            } else {
                $preserveClaim = $true
            }
            throw 'The cache pathname was replaced with different content; the replacement was preserved.'
        }
        [System.IO.File]::Delete($claimPath)
        $movedToClaim = $false
    } finally {
        if ($movedToClaim -and [System.IO.File]::Exists($claimPath)) {
            if (-not (Test-Path -LiteralPath $Path)) {
                try {
                    [System.IO.File]::Move($claimPath, $Path)
                    $movedToClaim = $false
                } catch { $preserveClaim = $true }
            } else {
                $preserveClaim = $true
            }
        }
        if (-not $preserveClaim -and [System.IO.Directory]::Exists($claimDirectory)) {
            try { [System.IO.Directory]::Delete($claimDirectory, $false) } catch { }
        }
    }
}
