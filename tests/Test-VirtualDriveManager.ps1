Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')

Write-Output 'Testing VirtualDriveManager...'

# 1. Test binary discovery
$rclone = Find-RcloneBinary
if (-not $rclone -or -not (Test-Path -LiteralPath $rclone)) {
    throw 'Failed to locate a valid rclone binary'
}
Write-Output "  [PASS] Rclone binary located: $rclone"

# 2. Test WinFsp detection
$winfsp = Test-WinFspInstalled
if (-not $winfsp) {
    throw 'WinFsp was not detected on this machine'
}
Write-Output '  [PASS] WinFsp detected and running'

# 3. Test Drive Letter availability
$tAvail = Test-DriveLetterAvailable 'T'
$cAvail = Test-DriveLetterAvailable 'C'
if ($cAvail -ne $false) {
    throw 'Expected C: to be reported as unavailable/occupied'
}
Write-Output "  [PASS] Drive letter checks verified (T: available=$tAvail, C: occupied)"

# 4. Test Mount arguments builder
$mountArgs = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'T' -CacheDirectory 'D:\CloudCache\Test'
if ($mountArgs[0] -ne 'mount' -or
    $mountArgs[1] -ne 'gdrive:' -or
    $mountArgs[2] -ne 'T:\' -or
    $mountArgs -notcontains '--read-only' -or
    $mountArgs -notcontains '--vfs-cache-mode' -or
    $mountArgs -notcontains 'full' -or
    $mountArgs -notcontains '--network-mode') {
    throw "Mount arguments failed verification: $($mountArgs -join ' ')"
}
Write-Output '  [PASS] Mount arguments builder verified'

# 5. Test initial unmounted status
$status = Get-VirtualDriveStatus -DriveLetter 'T'
if ($status.IsMounted -ne $false) {
    throw 'Expected T: to be reported as not mounted initially'
}
Write-Output '  [PASS] Initial unmounted status verified'

Write-Output 'All VirtualDriveManager tests passed.'
