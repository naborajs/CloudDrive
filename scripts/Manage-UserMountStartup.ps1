[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Enable,
    [switch]$Remove,
    [switch]$ReadOnlyAcceptancePassed,
    [string]$BuildRoot = (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\builds\rclone-extra-v1.75.2-extra'),
    [string]$ConfigPath = (Join-Path $env:APPDATA 'rclone\rclone.conf')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Enable -and $Remove) {
    throw 'Choose either -Enable or -Remove, not both.'
}
if ($Enable -and -not $ReadOnlyAcceptancePassed) {
    throw 'Run the documented manual read-only acceptance checks first, then explicitly supply -ReadOnlyAcceptancePassed.'
}
if (-not $Enable -and -not $Remove) {
    throw 'No change made. Use -Enable to register logon mounting or -Remove to delete this named task.'
}

$taskName = 'NS Cloud Drive (TeraBox)'
$taskPath = '\'
$launcherPath = Join-Path $PSScriptRoot 'Start-ReadOnlyMount.ps1'
$helperPath = Join-Path $PSScriptRoot 'RcloneConfigPassword.ps1'
$rclonePath = Join-Path $BuildRoot 'rclone.exe'
$manifestPath = Join-Path $BuildRoot 'rclone.build.json'
$patchPath = Join-Path $PSScriptRoot '..\patches\rclone-terabox-v1.75.2-extra-secret-safety.patch'
$passwordHostPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

Import-Module ScheduledTasks -ErrorAction Stop
$existingTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction SilentlyContinue

if ($Remove) {
    if (-not $existingTask) {
        Write-Output 'No NS Cloud Drive logon task exists; nothing was removed.'
        exit 0
    }
    if ($PSCmdlet.ShouldProcess($TaskName, 'Remove current-user logon mount task')) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Confirm:$false
        Write-Output 'Removed the named NS Cloud Drive logon task.'
    }
    exit 0
}

if ($existingTask) {
    throw "A task named '$TaskName' already exists. Remove that exact task first if you intend to replace it."
}

foreach ($path in @($launcherPath, $helperPath, $rclonePath, $manifestPath, $ConfigPath, $patchPath, $passwordHostPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file was not found: $path"
    }
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$expectedPatchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
$actualExecutableHash = (Get-FileHash -LiteralPath $rclonePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($manifest.sourceCommit -ne '56bf13885494819bc801302ddf881279bdac7262' -or
    $manifest.target -ne 'windows/amd64' -or
    $manifest.buildTag -ne 'cmount' -or
    $manifest.backend -ne 'terabox' -or
    $manifest.patchSha256 -ne $expectedPatchHash -or
    $manifest.executableSha256 -ne $actualExecutableHash) {
    throw 'The build manifest does not match the pinned source, patch, and executable.'
}

$previousPasswordCommand = $env:RCLONE_PASSWORD_COMMAND
try {
    $env:RCLONE_PASSWORD_COMMAND = '"' + $passwordHostPath + '" -NoLogo -NoProfile -NonInteractive -File "' + $helperPath + '"'
    & $rclonePath --config $ConfigPath --ask-password=false config encryption check *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'The rclone configuration must be encrypted and locally unlockable before logon mounting can be enabled.'
    }
}
finally {
    $env:RCLONE_PASSWORD_COMMAND = $previousPasswordCommand
}

$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$actionArguments = '-NoLogo -NoProfile -File "' + $launcherPath + '" -BuildRoot "' + $BuildRoot + '" -ConfigPath "' + $ConfigPath + '"'
$action = New-ScheduledTaskAction -Execute $passwordHostPath -Argument $actionArguments -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentSid
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 2) `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId $currentSid -LogonType Interactive -RunLevel Limited

if ($PSCmdlet.ShouldProcess($TaskName, "Register read-only T: mount at sign-in for SID $currentSid")) {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -TaskPath $taskPath `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal `
        -Description 'Starts the NS Cloud Drive read-only TeraBox mount in the signed-in user session.' | Out-Null
    Write-Output 'Registered the current-user read-only mount task. It was not started now.'
}
