# Test-ExplorerIntegration.ps1 - Validates the per-user Explorer drive icon service
#
# Runs against an isolated HKCU registry root and a sandboxed LOCALAPPDATA so no
# real user settings, credentials, or drive icons are touched. This is a mocked/
# isolated unit test for the service itself; it cannot prove how Explorer renders
# icons on a real desktop session.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$originalLocalAppData = $env:LOCALAPPDATA
$sandbox = Join-Path $env:TEMP ('NSCloudDrive_ExplorerIcons_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:LOCALAPPDATA = $sandbox

$testRootId = [guid]::NewGuid().ToString('N')
$registryRoot = 'HKCU:\Software\NSCloudDriveTests\' + $testRootId + '\DriveIcons'
$foreignRoot = 'HKCU:\Software\NSCloudDriveTests\' + [guid]::NewGuid().ToString('N') + '\DriveIcons'
$logoDirectory = Join-Path $PSScriptRoot '..\assets\logos'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\ExplorerIntegration.ps1')

try {
    # 0. Provider assets must exist for the icon converter.
    foreach ($asset in @('googledrive.png', 'terabox.png')) {
        if (-not (Test-Path -LiteralPath (Join-Path $logoDirectory $asset) -PathType Leaf)) {
            throw "Provider logo asset is missing: $asset"
        }
    }
    $iconPath = Get-NSCloudDriveExplorerIconPath 'gdrive'
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'The generated .ico file must persist in the icons cache.' }
    $teraboxIconPath = Get-NSCloudDriveExplorerIconPath 'terabox'
    if (-not (Test-Path -LiteralPath $teraboxIconPath -PathType Leaf)) { throw 'The TeraBox .ico file must persist in the icons cache.' }
    Write-Output '  [PASS] Provider icon assets exist and convert to per-user .ico files'

    # 1. Register with an unowned, empty letter succeeds and stamps ownership.
    $registered = Invoke-NSCloudDriveExplorerIconRegistration -Action Register -DriveLetter 'Z' -ProviderId 'terabox' -RegistryRoot $registryRoot
    if (-not $registered.Success -or $registered.State -ne 'Registered') { throw "First registration must succeed: [$($registered.State)]" }
    $registration = Get-NSCloudDriveExplorerIconRegistration 'Z' $registryRoot
    if (-not $registration.IsOwned -or ($registration.IconPath -notlike '*.ico,0')) {
        throw 'Registration must write the icon default value and the NSCloudDriveOwner stamp.'
    }
    # Path comparison is structural: the value may use an 8.3 path alias, so
    # resolve it back to a leaf file and provider-specific file name instead of
    # comparing raw strings.
    $storedIconFile = ([string]$registration.IconPath) -replace ',0$', ''
    if (-not (Test-Path -LiteralPath $storedIconFile -PathType Leaf)) { throw "The registered icon file must exist: $storedIconFile" }
    if ([System.IO.Path]::GetFileName($storedIconFile) -ne 'terabox.ico') { throw "Registration must reference the TeraBox icon, got $storedIconFile." }
    Write-Output '  [PASS] Registration writes an owned DefaultIcon entry with an owner stamp'

    # 2. Registration is idempotent.
    $again = Invoke-NSCloudDriveExplorerIconRegistration -Action Register -DriveLetter 'Z' -ProviderId 'terabox' -RegistryRoot $registryRoot
    if (-not $again.Success -or $again.State -ne 'AlreadyRegistered') { throw 'An owned, matching registration must be reported as AlreadyRegistered.' }
    Write-Output '  [PASS] Repeating the same registration is a no-op (AlreadyRegistered)'

    # 3. A registration owned by another application must never be overwritten.
    New-Item -Path (Join-Path $foreignRoot 'Y') -Force | Out-Null
    New-Item -Path (Join-Path $foreignRoot 'Y\DefaultIcon') -Force | Out-Null
    Set-Item -LiteralPath (Join-Path $foreignRoot 'Y\DefaultIcon') -Value 'C:\Program Files\Some Other App\other.ico,0'
    Set-ItemProperty -LiteralPath (Join-Path $foreignRoot 'Y') -Name 'SomeOtherAppOwner' -Value 'Other App' -Type String
    $conflict = Invoke-NSCloudDriveExplorerIconRegistration -Action Register -DriveLetter 'Y' -ProviderId 'gdrive' -RegistryRoot $foreignRoot
    if ($conflict.Success) { throw 'Registering over a foreign icon must fail closed with a conflict.' }
    if ($conflict.State -ne 'Conflict') { throw "Foreign registration must be reported as Conflict, got [$($conflict.State)]." }
    $foreignValue = (Get-Item -LiteralPath (Join-Path $foreignRoot 'Y\DefaultIcon')).GetValue('')
    if ($foreignValue -ne 'C:\Program Files\Some Other App\other.ico,0') { throw 'The foreign icon value must remain untouched.' }
    Write-Output '  [PASS] Foreign drive icons are reported as conflicts and left untouched'

    # 4. Removing a foreign icon is a no-op.
    $notOwned = Invoke-NSCloudDriveExplorerIconRegistration -Action Remove -DriveLetter 'Y' -ProviderId 'gdrive' -RegistryRoot $foreignRoot
    if (-not $notOwned.Success -or $notOwned.State -ne 'NotOwned') { throw 'Removing a foreign icon must report NotOwned without touching it.' }
    $foreignStillThere = (Get-Item -LiteralPath (Join-Path $foreignRoot 'Y\DefaultIcon')).GetValue('')
    if ($foreignStillThere -ne 'C:\Program Files\Some Other App\other.ico,0') { throw 'The foreign icon key must survive a removal attempt.' }
    Write-Output '  [PASS] Removal is scoped to NS Cloud Drive-owned registrations'

    # 5. Removal of an owned registration cleans only application-owned values.
    $ownedStamps = @((Get-ItemProperty -LiteralPath (Join-Path $registryRoot 'Z')).PSObject.Properties.Name -contains 'NSCloudDriveOwner')
    if (-not $ownedStamps[0]) { throw 'The owned letter must expose an owner stamp before removal.' }
    $removed = Invoke-NSCloudDriveExplorerIconRegistration -Action Remove -DriveLetter 'Z' -ProviderId 'terabox' -RegistryRoot $registryRoot
    if (-not $removed.Success -or $removed.State -ne 'Removed') { throw "Removing an owned registration must succeed: [$($removed.State)]" }
    if (Test-Path -LiteralPath (Join-Path $registryRoot 'Z')) { throw 'An emptied owned letter key must be deleted entirely.' }
    Write-Output '  [PASS] Owned registrations are fully and reversibly removed on cleanup'

    # 6. Nothing from this test writes into the real per-user DriveIcons root.
    $realRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons'
    if (Test-Path -LiteralPath $realRoot) {
        foreach ($letter in @('Z', 'Y')) {
            $realKey = Join-Path $realRoot $letter
            if (Test-Path -LiteralPath $realKey -PathType Container) {
                $real = Get-NSCloudDriveExplorerIconRegistration $letter $realRoot
                if ($real.IsOwned) { throw 'The test must not write into the real user DriveIcons root.' }
            }
        }
    }
    Write-Output '  [PASS] Registry writes stayed inside the isolated test root'

    Write-Output '  [PASS] Explorer icon service verified in isolation.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    foreach ($path in @(('HKCU:\Software\NSCloudDriveTests\' + $testRootId), $foreignRoot)) {
        try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
