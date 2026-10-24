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

# 4. Test Mount arguments builder (Read-Write default and Read-Only switch)
$mountArgs = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'T' -CacheDirectory 'D:\CloudCache\Test' -ConfigPath ''
if ($mountArgs[0] -ne 'mount' -or
    $mountArgs[1] -ne 'gdrive:' -or
    $mountArgs[2] -ne 'T:\' -or
    $mountArgs -contains '--read-only' -or
    $mountArgs -notcontains '--vfs-cache-mode' -or
    $mountArgs -notcontains 'full' -or
    $mountArgs -notcontains '--network-mode' -or
    $mountArgs -notcontains '--ask-password=false' -or
    $mountArgs -notcontains '--dir-cache-time' -or
    $mountArgs -notcontains '--attr-timeout' -or
    $mountArgs -notcontains '--links') {
    throw "Mount arguments failed verification (should be read-write by default): $($mountArgs -join ' ')"
}

$roMountArgs = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'T' -CacheDirectory 'D:\CloudCache\Test' -ConfigPath '' -ReadOnly
if ($roMountArgs -notcontains '--read-only') {
    throw "Read-only mount arguments should contain --read-only flag: $($roMountArgs -join ' ')"
}
Write-Output '  [PASS] Mount arguments builder (read-write default & explicit read-only) verified'

# 5. Test initial unmounted status
# When the app is running, drives may already be mounted.  We verify that
# Get-VirtualDriveStatus returns a well-formed object with an IsMounted property.
# Strict unmounted assertion is skipped when T: is already in use.
$status = Get-VirtualDriveStatus -DriveLetter 'T'
$hasMountedState = $false
if ($status -is [System.Collections.IDictionary]) {
    $hasMountedState = $status.Contains('IsMounted')
} elseif ($null -ne $status) {
    $hasMountedState = $null -ne $status.PSObject.Properties['IsMounted']
}
if (-not $hasMountedState) {
    throw 'Get-VirtualDriveStatus must return an object with an IsMounted property'
}
if ($status.IsMounted) {
    Write-Output '  [PASS] Get-VirtualDriveStatus returns well-formed object for T: (currently mounted — live environment)'
} else {
    Write-Output '  [PASS] Initial unmounted status verified (T: is free)'
}

# 6. Test Stop-VirtualDriveMount returns cleanly when not mounted
$stopResult = Stop-VirtualDriveMount
if (-not $stopResult.Success) {
    throw 'Stop-VirtualDriveMount expected to succeed cleanly'
}
Write-Output '  [PASS] Stop-VirtualDriveMount clean invocation verified'

# 7. Test Get-NextAvailableDriveLetter
$nextLetter = Get-NextAvailableDriveLetter 'T'
if (-not (Test-DriveLetterAvailable $nextLetter)) {
    throw "Returned drive letter $nextLetter should be available"
}
# When C is preferred, must fall back to an available letter
$fallbackFromC = Get-NextAvailableDriveLetter 'C'
if ($fallbackFromC -eq 'C') {
    throw 'Preferred occupied drive letter C should have resulted in an alternate available letter'
}
if (-not (Test-DriveLetterAvailable $fallbackFromC)) {
    throw "Fallback drive letter $fallbackFromC should be available"
}
Write-Output '  [PASS] Next available drive letter allocation and conflict resolution verified'

# 8. Test Volume labels in Build-RcloneMountArguments
$gdMountArgs = Build-RcloneMountArguments -RemoteName 'gdrive' -DriveLetter 'G' -ConfigPath ''
if ($gdMountArgs -notcontains '--volname' -or $gdMountArgs[$gdMountArgs.IndexOf('--volname') + 1] -ne 'Google Drive') {
    throw "Google Drive volume name missing or incorrect: $($gdMountArgs -join ' ')"
}
$tbMountArgs = Build-RcloneMountArguments -RemoteName 'terabox' -DriveLetter 'T' -ConfigPath ''
if ($tbMountArgs -notcontains '--volname' -or $tbMountArgs[$tbMountArgs.IndexOf('--volname') + 1] -ne 'TeraBox') {
    throw "TeraBox volume name missing or incorrect: $($tbMountArgs -join ' ')"
}
Write-Output '  [PASS] Distinct provider volume labels verified'

# 9. Test Cache usage statistics calculation
$cacheStats = Get-CacheUsageStatistics -CacheDirectory 'D:\CloudCache'
if ($null -eq $cacheStats.UsedBytes -or $null -eq $cacheStats.TargetMaxBytes) {
    throw 'Cache stats missing required numeric properties'
}
if ($cacheStats.TargetMaxFormatted -ne '20.00 GiB') {
    throw "TargetMaxFormatted mismatch: $($cacheStats.TargetMaxFormatted)"
}
Write-Output '  [PASS] Cache usage statistics calculation verified'

# 10. Test Multi-provider Get-VirtualDriveStatus
$gdStatus = Get-VirtualDriveStatus -ProviderId 'gdrive'
if ($gdStatus.IsMounted -ne $false -or $gdStatus.ProviderId -ne 'gdrive') {
    throw 'Expected gdrive status object with ProviderId=gdrive and IsMounted=false initially'
}
Write-Output '  [PASS] Provider-specific virtual drive status verified'

# 11. Test Multi-account Get-VirtualDriveStatus with AccountId
$accountStatus = Get-VirtualDriveStatus -AccountId 'gdrive_work' -ProviderId 'gdrive'
if ($accountStatus.IsMounted -ne $false) {
    throw 'Expected account status object to reflect unmounted state'
}
Write-Output '  [PASS] Multi-account virtual drive status tracking verified'

Write-Output 'All VirtualDriveManager tests passed.'
