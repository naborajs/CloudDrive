Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

Write-Output 'Testing fail-closed mount ownership detection...'

$mountKey = 'gdrive_safety_test'
$rcPort = 59143
$matchingProcess = @{
    ProcessId = 4321
    Inspectable = $true
    Arguments = @(
        '/usr/bin/rclone', 'mount', 'gdrive_safety_test:', '/home/tester/CloudDrives/gdrive_safety_test',
        '--config', '/home/tester/.config/nsclouddrive/mount-gdrive_safety_test.conf',
        '--log-file', '/home/tester/.local/share/nsclouddrive/logs/rclone-gdrive_safety_test.log',
        '--rc-addr', "127.0.0.1:$rcPort", '--rc-no-auth', '--read-only'
    )
}
$activeEvidence = Get-LinuxRcloneMountProcessEvidence -ProcessSnapshots @($matchingProcess) -MountKey $mountKey
if (-not $activeEvidence.Known -or -not $activeEvidence.IsActive -or
    [int]$activeEvidence.ProcessId -ne 4321 -or [int]$activeEvidence.RcPort -ne $rcPort -or
    -not [bool]$activeEvidence.IsReadOnly) {
    throw 'A matching Linux rclone mount must produce exact account and RC-port evidence.'
}
Write-Output '  [PASS] Exact account log/config identity resolves its live mount and per-account RC port'

$inactiveEvidence = Get-LinuxRcloneMountProcessEvidence -ProcessSnapshots @() -MountKey $mountKey
if (-not $inactiveEvidence.Known -or $inactiveEvidence.IsActive) {
    throw 'A successful empty process snapshot must be known inactive.'
}
$unreadableEvidence = Get-LinuxRcloneMountProcessEvidence -ProcessSnapshots @($matchingProcess) -MountKey $mountKey -EnumerationSucceeded $false
if ($unreadableEvidence.Known) {
    throw 'A failed process enumeration must remain unknown instead of reporting an unmounted account.'
}
$uninspectableProcess = @{ ProcessId = 9876; Inspectable = $false; Arguments = @() }
$partialEvidence = Get-LinuxRcloneMountProcessEvidence -ProcessSnapshots @($matchingProcess, $uninspectableProcess) -MountKey $mountKey
if ($partialEvidence.Known) {
    throw 'An uninspectable rclone process must make account ownership unknown.'
}
Write-Output '  [PASS] Empty, failed-enumeration, and uninspectable-process states remain distinct'

if (Test-IsLinuxOperatingSystem) {
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('NSCloudDrive_MountOwnership_' + [Guid]::NewGuid().ToString('N'))
    $cacheRoot = Join-Path $sandbox 'cache'
    $stagedRoot = Join-Path (Join-Path $cacheRoot $mountKey) 'vfs'
    $metadataRoot = Join-Path (Join-Path $cacheRoot $mountKey) 'vfsMeta'
    $stagedPath = Join-Path $stagedRoot 'recovered-upload.bin'
    $metadataPath = Join-Path $metadataRoot 'recovered-upload.bin'
    $localSourceRoot = Join-Path $sandbox 'local-source'
    $linuxMountRoot = Join-Path (Join-Path $sandbox 'CloudDrives') $mountKey
    $mountConfigPath = Join-Path $sandbox "mount-$mountKey.conf"
    $mountLogPath = Join-Path $sandbox "rclone-$mountKey.log"
    $accountCacheRoot = Join-Path $cacheRoot $mountKey
    [void][System.IO.Directory]::CreateDirectory($stagedRoot)
    [void][System.IO.Directory]::CreateDirectory($metadataRoot)
    [void][System.IO.Directory]::CreateDirectory($localSourceRoot)
    [void][System.IO.Directory]::CreateDirectory($linuxMountRoot)
    [void][System.IO.Directory]::CreateDirectory($accountCacheRoot)
    [System.IO.File]::WriteAllText($mountConfigPath, '')
    [System.IO.File]::WriteAllText((Join-Path $localSourceRoot 'probe.txt'), 'local-only rclone mount fixture')
    [System.IO.File]::WriteAllText($stagedPath, 'preserve while mount ownership is uncertain')
    [System.IO.File]::WriteAllText($metadataPath, '{"Dirty": false}')

    $stagedInfo = Get-Item -LiteralPath $stagedPath
    $account = @{
        Id = $mountKey
        ProviderId = 'gdrive'
        DriveLetter = 'G'
        CacheDirectory = $cacheRoot
    }
    $job = @{
        Status = 'Completed and remotely confirmed'
        RecoveredFromVfsCache = $true
        StagedSourcePath = $stagedPath
        StagedSourceLastWriteUtc = $stagedInfo.LastWriteTimeUtc.ToUniversalTime().ToString('o')
        StagedSourceSha256 = (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash
        StagedMetadataSha256 = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash
        StagedCleanupStatus = 'Pending'
        FileSizeBytes = [int64]$stagedInfo.Length
        AccountId = $mountKey
        ProviderId = 'gdrive'
        DestinationAccount = $account
    }

    $originalSnapshot = (Get-Command Get-VirtualDriveMountProcessSnapshot).ScriptBlock
    $originalSettings = (Get-Command Get-NSCloudDriveSettings).ScriptBlock
    $originalHome = $env:HOME
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $rcPort = [int]$listener.LocalEndpoint.Port
    $listener.Stop()
    $rcloneProcess = $null
    $usingLiveMount = $false
    $global:TestMountOwnershipCacheRoot = $cacheRoot
    $global:TestMountOwnershipSnapshot = @{ Known = $true; Processes = @($matchingProcess) }
    try {
        $rclonePath = Find-RcloneBinary
        if ($rclonePath -and (Test-Path -LiteralPath '/dev/fuse')) {
            $mountArguments = @(
                'mount', ":local:$localSourceRoot", $linuxMountRoot,
                '--config', $mountConfigPath,
                '--log-file', $mountLogPath,
                '--cache-dir', $accountCacheRoot,
                '--vfs-cache-mode', 'writes',
                '--rc-addr', "127.0.0.1:$rcPort",
                '--read-only', '--log-level', 'INFO'
            )
            $mountStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $mountStartInfo.FileName = $rclonePath
            $mountStartInfo.UseShellExecute = $false
            foreach ($argument in $mountArguments) { $mountStartInfo.ArgumentList.Add([string]$argument) }
            $rcloneProcess = [System.Diagnostics.Process]::Start($mountStartInfo)
            if ($null -eq $rcloneProcess) { throw 'The local-only rclone mount did not start.' }
            if ($rcloneProcess.WaitForExit(2000)) {
                $mountLog = if (Test-Path -LiteralPath $mountLogPath) { [System.IO.File]::ReadAllText($mountLogPath) } else { '' }
                throw "The local-only rclone mount exited before becoming active: $mountLog"
            }

            $mountInfoLines = [System.IO.File]::ReadAllLines('/proc/self/mountinfo')
            $mountPointActive = $false
            foreach ($mountInfoLine in $mountInfoLines) {
                $mountInfoFields = @($mountInfoLine -split ' ')
                if ($mountInfoFields.Count -gt 4 -and [string]::Equals([string]$mountInfoFields[4], $linuxMountRoot, [System.StringComparison]::Ordinal)) {
                    $mountPointActive = $true
                    break
                }
            }
            if (-not $mountPointActive) {
                $mountLog = if (Test-Path -LiteralPath $mountLogPath) { [System.IO.File]::ReadAllText($mountLogPath) } else { '' }
                throw "The local-only rclone process stayed alive without mounting its test directory: $mountLog"
            }

            $actualSnapshot = Get-VirtualDriveMountProcessSnapshot
            $fixtureEvidence = Get-LinuxRcloneMountProcessEvidence `
                -ProcessSnapshots @($actualSnapshot.Processes) `
                -MountKey $mountKey `
                -EnumerationSucceeded ([bool]$actualSnapshot.Known)
            if (-not $fixtureEvidence.Known -or -not $fixtureEvidence.IsActive -or
                [int]$fixtureEvidence.ProcessId -ne [int]$rcloneProcess.Id -or [int]$fixtureEvidence.RcPort -ne $rcPort) {
                throw 'The real Linux /proc snapshot did not match the active local rclone mount.'
            }
            $global:TestMountOwnershipSnapshot = $actualSnapshot
            $usingLiveMount = $true
            Write-Output '  [PASS] Actual rclone process and /proc mount table identify the account mount'
        } else {
            $matchingProcess.Arguments[3] = $linuxMountRoot
            $matchingProcess.Arguments[5] = $mountConfigPath
            $matchingProcess.Arguments[7] = $mountLogPath
            $rcArgumentIndex = [System.Array]::IndexOf([object[]]$matchingProcess.Arguments, '--rc-addr')
            $matchingProcess.Arguments[$rcArgumentIndex + 1] = "127.0.0.1:$rcPort"
            $global:TestMountOwnershipSnapshot = @{ Known = $true; Processes = @($matchingProcess) }
            Write-Output '  [SKIP] Real local FUSE mount unavailable; exercising cleanup against a synthetic process snapshot'
        }

        Set-Item -Path Function:\Get-VirtualDriveMountProcessSnapshot -Value {
            return $global:TestMountOwnershipSnapshot
        }
        Set-Item -Path Function:\Get-NSCloudDriveSettings -Value {
            return @{ CacheDirectory = [string]$global:TestMountOwnershipCacheRoot; Accounts = @() }
        }
        $env:HOME = $sandbox

        $mountProcess = Find-ActiveMountProcess -DriveLetter 'G' -MountKey $mountKey
        if (-not $mountProcess -or [bool]$mountProcess.OwnershipUnknown -or [int]$mountProcess.RcPort -ne $rcPort) {
            throw 'The Linux process matcher did not find the live or simulated account mount.'
        }
        $mountStatus = Get-VirtualDriveStatus -DriveLetter 'G' -ProviderId 'gdrive' -AccountId $mountKey
        if (-not $mountStatus.ProcessRunning -or -not $mountStatus.IsMounted -or
            -not [string]::Equals([string]$mountStatus.DriveRoot, $linuxMountRoot, [System.StringComparison]::Ordinal)) {
            throw 'Linux mount status must use the account mount point and live process evidence.'
        }

        $vfsStatus = Get-VirtualDriveVfsStats -DriveLetter 'G' -AccountId $mountKey -ProviderId 'gdrive'
        if ($vfsStatus.IsActive -or [string]$vfsStatus.State -ne 'Remote state unknown' -or [int]$vfsStatus.RcPort -ne $rcPort) {
            throw 'An unreachable RC endpoint must produce Remote state unknown using the discovered account port.'
        }

        $cleanup = Invoke-ConfirmedStagedVfsSourceCleanup -Job $job
        if ($cleanup.Success -or [string]$job.StagedCleanupStatus -ne 'Pending: active mount cache ownership is unknown' -or
            -not (Test-Path -LiteralPath $stagedPath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            throw 'Cleanup must preserve both staged payload and metadata while the active mount RC endpoint is unavailable.'
        }
        Write-Output '  [PASS] Linux RC outage fails closed and preserves the exact staged data/metadata pair'
    } finally {
        Set-Item -Path Function:\Get-VirtualDriveMountProcessSnapshot -Value $originalSnapshot
        Set-Item -Path Function:\Get-NSCloudDriveSettings -Value $originalSettings
        $env:HOME = $originalHome
        if ($rcloneProcess) {
            try {
                if (-not $rcloneProcess.HasExited) {
                    $signalInfo = [System.Diagnostics.ProcessStartInfo]::new()
                    $signalInfo.FileName = '/bin/kill'
                    $signalInfo.UseShellExecute = $false
                    $signalInfo.ArgumentList.Add('-INT')
                    $signalInfo.ArgumentList.Add([string]$rcloneProcess.Id)
                    $signalProcess = [System.Diagnostics.Process]::Start($signalInfo)
                    if ($signalProcess) { $signalProcess.WaitForExit(5000) | Out-Null; $signalProcess.Dispose() }
                    if (-not $rcloneProcess.WaitForExit(5000)) { $rcloneProcess.Kill(); $rcloneProcess.WaitForExit(5000) | Out-Null }
                }
            } catch { }
            try { $rcloneProcess.Dispose() } catch { }
        }
        Remove-Variable -Name TestMountOwnershipSnapshot, TestMountOwnershipCacheRoot -Scope Global -ErrorAction SilentlyContinue
        $mountStillActive = $false
        if (Test-Path -LiteralPath '/proc/self/mountinfo') {
            foreach ($mountInfoLine in [System.IO.File]::ReadAllLines('/proc/self/mountinfo')) {
                $mountInfoFields = @($mountInfoLine -split ' ')
                if ($mountInfoFields.Count -gt 4 -and [string]::Equals([string]$mountInfoFields[4], $linuxMountRoot, [System.StringComparison]::Ordinal)) {
                    $mountStillActive = $true
                    break
                }
            }
        }
        if ($mountStillActive) {
            try {
                $unmountInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $unmountInfo.FileName = '/usr/bin/fusermount3'
                $unmountInfo.UseShellExecute = $false
                $unmountInfo.ArgumentList.Add('-u')
                $unmountInfo.ArgumentList.Add($linuxMountRoot)
                $unmountProcess = [System.Diagnostics.Process]::Start($unmountInfo)
                if ($unmountProcess) { $unmountProcess.WaitForExit(5000) | Out-Null; $unmountProcess.Dispose() }
            } catch { }
        }
        $mountStillActive = $false
        if (Test-Path -LiteralPath '/proc/self/mountinfo') {
            foreach ($mountInfoLine in [System.IO.File]::ReadAllLines('/proc/self/mountinfo')) {
                $mountInfoFields = @($mountInfoLine -split ' ')
                if ($mountInfoFields.Count -gt 4 -and [string]::Equals([string]$mountInfoFields[4], $linuxMountRoot, [System.StringComparison]::Ordinal)) {
                    $mountStillActive = $true
                    break
                }
            }
        }
        if ($mountStillActive) {
            Write-Error "Temporary test mount remains active; preserving sandbox at $sandbox."
        } elseif (Test-Path -LiteralPath $sandbox) {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($usingLiveMount -and $mountStillActive) { throw 'The temporary local test mount could not be detached safely.' }
    }
} else {
    Write-Output '  [SKIP] Live Linux RC-outage integration (pure process-parser checks ran on this platform)'
}

Write-Output 'All mount ownership safety tests passed.'
