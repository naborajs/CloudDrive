Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')

$localRoot = $env:SystemDrive + '\'
$accessible = Test-VirtualDriveFilesystem -DriveRoot $localRoot -TimeoutSeconds 5
if (-not $accessible.Success -or $accessible.State -ne 'Accessible') {
    throw "Local filesystem verification failed: $($accessible.Error)"
}

$invalidPathRejected = $false
try { Test-VirtualDriveFilesystem -DriveRoot '..\' | Out-Null } catch { $invalidPathRejected = $true }
if (-not $invalidPathRejected) { throw 'Filesystem checks must reject paths that are not drive roots.' }

$invalidTimeoutRejected = $false
try { Test-VirtualDriveFilesystem -DriveRoot $localRoot -TimeoutSeconds 0 | Out-Null } catch { $invalidTimeoutRejected = $true }
if (-not $invalidTimeoutRejected) { throw 'Filesystem checks must reject unbounded or invalid timeout values.' }

$managerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1') -Raw
if ($managerSource -notmatch 'Test-VirtualDriveFilesystem -DriveRoot \$driveRoot -TimeoutSeconds 10' -or $managerSource -notmatch 'FilesystemVerified = \$true') {
    throw 'The mount launcher must verify directory enumeration before returning success.'
}
$timeoutBranch = [regex]::Match($managerSource, "(?s)if \(\`$filesystemCheck\.State -eq 'Timeout'\) \{.*?\}").Value
if (-not $timeoutBranch -or
    $timeoutBranch -notmatch 'remains running' -or
    $timeoutBranch -match 'Stop-VirtualDriveMount') {
    throw 'A slow root probe must report unverified readiness without terminating the newly started mount process.'
}
if ($managerSource -notmatch 'Find-ActiveMountProcess -DriveLetter \$letter -MountKey \$mountKey') {
    throw 'Drive status must verify the process belongs to the selected account/provider namespace.'
}
if ($managerSource -notmatch 'already in use\. Choose another letter') {
    throw 'An occupied explicitly assigned drive letter must produce a conflict instead of silently changing letters.'
}

Write-Output '  [PASS] New mounts require a successful root probe, slow probes preserve the process, and explicit drive-letter conflicts are rejected.'
