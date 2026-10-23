# Manage-ExplorerDriveIcon.ps1 - Administrator helper for machine-wide drive icons
#
# The application registers per-user drive icons automatically under HKCU. This
# script is an opt-in tool for administrators who want the provider icon (or its
# removal) applied machine-wide under HKLM. It must be run elevated for the
# machine-wide root, and it only ever touches the drive letter passed in, never
# other drives. Existing foreign registrations are reported and left unchanged.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Register', 'Remove')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$DriveLetter,

    [Parameter(Mandatory = $true)]
    [string]$ProviderId,

    [string]$RegistryRoot = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\ExplorerIntegration.ps1')

$letter = $DriveLetter.ToUpperInvariant().TrimEnd(':').TrimEnd('\')
if ($Action -eq 'Register') {
    $iconPath = Get-NSCloudDriveExplorerIconPath $ProviderId
    $result = Set-NSCloudDriveExplorerIcon -DriveLetter $letter -IconPath $iconPath -RegistryRoot $RegistryRoot
} else {
    $iconPath = Get-NSCloudDriveExplorerIconPath $ProviderId
    $result = Remove-NSCloudDriveExplorerIcon -DriveLetter $letter -ExpectedIconPath $iconPath -RegistryRoot $RegistryRoot
}

Update-NSCloudDriveExplorerItem -DriveLetter $letter | Out-Null
$result | ConvertTo-Json -Compress
