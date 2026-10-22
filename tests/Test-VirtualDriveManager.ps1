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
if (Test-DriveLetterAvailable '') {
    throw 'Empty drive letter should be unavailable'
}
if (Test-DriveLetterAvailable 'INVALID') {
    throw 'Multi-character drive letter should be unavailable'
}
# Test formatting flexibility: 'C:\' and 'C:' should also be occupied
if (Test-DriveLetterAvailable 'C:\' -ne $false -or Test-DriveLetterAvailable 'C:' -ne $false) {
    throw 'Expected C:\ and C: to be recognized as occupied'
}
Write-Output "  [PASS] Drive letter checks verified (T: available=$tAvail, C: occupied)"

# 4. Test Mount arguments builder
$mountArgs = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'T' -CacheDirectory 'D:\CloudCache\Test' -ConfigPath ''
if ($mountArgs[0] -ne 'mount' -or
    $mountArgs[1] -ne 'gdrive:' -or
    $mountArgs[2] -ne 'T:\' -or
    $mountArgs -notcontains '--read-only' -or
    $mountArgs -notcontains '--vfs-cache-mode' -or
    $mountArgs -notcontains 'full' -or
    $mountArgs -notcontains '--network-mode' -or
    $mountArgs -notcontains '--ask-password=false' -or
    $mountArgs -notcontains '--dir-cache-time' -or
    $mountArgs -notcontains '--attr-timeout') {
    throw "Mount arguments failed verification: $($mountArgs -join ' ')"
}
Write-Output '  [PASS] Mount arguments builder verified'

# 5. Test initial unmounted status
$status = Get-VirtualDriveStatus -DriveLetter 'T'
if ($status.IsMounted -ne $false) {
    throw 'Expected T: to be reported as not mounted initially'
}
Write-Output '  [PASS] Initial unmounted status verified'

# 6. Test Stop-VirtualDriveMount returns cleanly when not mounted
$stopResult = Stop-VirtualDriveMount
if (-not $stopResult.Success) {
    throw 'Stop-VirtualDriveMount expected to succeed cleanly'
}
Write-Output '  [PASS] Stop-VirtualDriveMount clean invocation verified'

Write-Output 'All VirtualDriveManager tests passed.'
