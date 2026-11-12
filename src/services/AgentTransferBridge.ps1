Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\providers\VpsProvider.ps1')
. (Join-Path $PSScriptRoot 'VirtualDriveManager.ps1')

<#
.SYNOPSIS
    AgentTransferBridge provides high-speed, direct file transfers between the local
    workstation and remote VPS instances where AI agents operate.
.DESCRIPTION
    Supports push (local -> VPS), pull (VPS -> local), remote listing, and continuous sync.
    Optimized for massive file transfers (models, datasets, archives) using multi-chunked
    SFTP streaming, buffer tuning, and checksum verification.
#>

function Get-AgentVpsAccounts {
    [CmdletBinding()]
    param()

    $accounts = @()
    if (Get-Command 'Get-AllCloudAccounts' -ErrorAction SilentlyContinue) {
        $all = Get-AllCloudAccounts
        foreach ($acc in @($all)) {
            if ($acc.ProviderId -eq 'vps') {
                $accounts += $acc
            }
        }
    }

    if ($accounts.Count -eq 0) {
        # Check credential directory for stored sessions if no account manifest exists
        $credDir = Get-VpsCredentialDirectory
        if (Test-Path -LiteralPath $credDir) {
            $files = Get-ChildItem -LiteralPath $credDir -Filter 'vps-session-*.xml' -File -ErrorAction SilentlyContinue
            foreach ($f in @($files)) {
                $m = [regex]::Match($f.Name, '^vps-session-(.+)\.xml$')
                if ($m.Success) {
                    $accId = $m.Groups[1].Value
                    $sess = Get-VpsStoredSession -AccountId $accId
                    if ($null -ne $sess) {
                        $accounts += [ordered]@{
                            Id = $accId
                            DisplayName = "VPS ($accId)"
                            ProviderId = 'vps'
                            DriveLetter = 'V'
                        }
                    }
                }
            }
        }
    }

    return ,@($accounts)
}

function Start-AgentFileTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$AccountId = '',

        [Parameter(Mandatory = $true)]
        [ValidateSet('Push', 'Pull', 'List', 'Sync')]
        [string]$Direction,

        [Parameter(Mandatory = $false)]
        [string]$LocalPath = '',

        [Parameter(Mandatory = $false)]
        [string]$RemotePath = '',

        [Parameter(Mandatory = $false)]
        [switch]$HugeFileMode,

        [Parameter(Mandatory = $false)]
        [switch]$Checksum,

        [Parameter(Mandatory = $false)]
        [switch]$Compress,

        [Parameter(Mandatory = $false)]
        [scriptblock]$ProgressCallback = $null,

        [Parameter(Mandatory = $false)]
        [string]$RcloneBinary = ''
    )

    # 1. Resolve Account
    $accounts = Get-AgentVpsAccounts
    $targetAccount = $null
    if (-not [string]::IsNullOrWhiteSpace($AccountId)) {
        foreach ($a in @($accounts)) {
            if ([string]$a.Id -eq $AccountId) {
                $targetAccount = $a
                break
            }
        }
    }
    if ($null -eq $targetAccount -and $accounts.Count -gt 0) {
        $targetAccount = $accounts[0]
        $AccountId = [string]$targetAccount.Id
    }

    if ($null -eq $targetAccount -and [string]::IsNullOrWhiteSpace($AccountId)) {
        throw 'No VPS account found. Please connect a Linux VPS server in NS Cloud Drive first.'
    }

    # 2. Retrieve session credentials
    $session = Get-VpsStoredSession -AccountId $AccountId
    if ($null -eq $session) {
        throw "Could not retrieve stored credentials for VPS account '$AccountId'."
    }

    # 3. Locate rclone binary
    $rclone = if (-not [string]::IsNullOrWhiteSpace($RcloneBinary)) { $RcloneBinary } else { Get-VerifiedRclonePath }
    if (-not $rclone -or -not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
        throw 'Rclone binary not found. Please verify NS Cloud Drive installation.'
    }

    # 4. Build isolated remote environment
    $remoteName = "vps_agent_$($AccountId -replace '[^a-zA-Z0-9_]', '_')"
    $envVars = Get-VpsRcloneEnvironment -AccountId $AccountId -RemoteName $remoteName -RcloneBinary $rclone

    # 5. Sanitize remote path
    $baseRemotePath = [string](Get-VpsFieldValue $session 'RemotePath' '')
    $targetRemotePath = $RemotePath
    if ([string]::IsNullOrWhiteSpace($targetRemotePath)) {
        $targetRemotePath = if (-not [string]::IsNullOrWhiteSpace($baseRemotePath)) { $baseRemotePath } else { '.' }
    }
    $targetRemotePath = ($targetRemotePath -replace '\\', '/')
    if ($targetRemotePath -match '^[a-zA-Z]:') {
        # Normalize accidental windows drive letter in remote path
        $targetRemotePath = '/' + ($targetRemotePath -replace '^[a-zA-Z]:[/\\]*', '')
    }

    $remoteTargetSpec = "${remoteName}:${targetRemotePath}"

    # 6. Execute based on direction
    $startTime = [DateTime]::UtcNow

    if ($Direction -eq 'List') {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $rclone
        $psi.Arguments = "lsf `"$remoteTargetSpec`" --format `"p`" --dirsfirst"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        foreach ($k in $envVars.Keys) {
            $psi.EnvironmentVariables[$k] = [string]$envVars[$k]
        }

        $p = [System.Diagnostics.Process]::Start($psi)
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()

        if ($p.ExitCode -ne 0) {
            throw "Failed to list remote directory '$targetRemotePath' on VPS: $stderr"
        }

        $entries = @()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $lines = ($stdout -split "`r?`n")
            foreach ($l in $lines) {
                $trimmed = $l.Trim()
                if ($trimmed) { $entries += $trimmed }
            }
        }

        return [ordered]@{
            Success = $true
            Direction = 'List'
            AccountId = $AccountId
            RemotePath = $targetRemotePath
            Entries = $entries
            DurationMs = [int]([DateTime]::UtcNow - $startTime).TotalMilliseconds
        }
    }

    # Validate local path for transfer
    if ([string]::IsNullOrWhiteSpace($LocalPath)) {
        throw 'LocalPath must be specified for Push, Pull, or Sync transfers.'
    }

    $isLocalDir = $false
    if ($Direction -eq 'Push') {
        if (-not (Test-Path -LiteralPath $LocalPath)) {
            throw "Local path does not exist: '$LocalPath'"
        }
        $isLocalDir = (Test-Path -LiteralPath $LocalPath -PathType Container)
    } elseif ($Direction -in @('Pull', 'Sync')) {
        $parent = [System.IO.Path]::GetDirectoryName($LocalPath)
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    # 7. Build transfer command and arguments
    $rcloneSubCmd = 'copy'
    $src = ''
    $dst = ''

    if ($Direction -eq 'Push') {
        if ($isLocalDir) {
            $rcloneSubCmd = 'copy'
            $src = (Resolve-Path -LiteralPath $LocalPath).Path
            $dst = $remoteTargetSpec
        } else {
            $rcloneSubCmd = 'copyto'
            $src = (Resolve-Path -LiteralPath $LocalPath).Path
            $dst = $remoteTargetSpec
            # If remote path ends with / or is a dir, append filename
            if ($targetRemotePath.EndsWith('/') -or $targetRemotePath -eq '.' -or [string]::IsNullOrEmpty($targetRemotePath)) {
                $fname = [System.IO.Path]::GetFileName($src)
                $dst = "${remoteName}:${targetRemotePath.TrimEnd('/')}/$fname"
            }
        }
    } elseif ($Direction -eq 'Pull') {
        $rcloneSubCmd = 'copyto'
        $src = $remoteTargetSpec
        $dst = $LocalPath
    } elseif ($Direction -eq 'Sync') {
        $rcloneSubCmd = 'sync'
        $src = (Resolve-Path -LiteralPath $LocalPath).Path
        $dst = $remoteTargetSpec
    }

    $argsList = [System.Collections.Generic.List[string]]::new()
    $argsList.Add($rcloneSubCmd)
    $argsList.Add("`"$src`"")
    $argsList.Add("`"$dst`"")
    $argsList.Add('--stats')
    $argsList.Add('1s')
    $argsList.Add('--stats-one-line')

    if ($HugeFileMode) {
        $argsList.Add('--sftp-chunk-size')
        $argsList.Add('256k')
        $argsList.Add('--buffer-size')
        $argsList.Add('64M')
        $argsList.Add('--transfers')
        $argsList.Add('4')
        $argsList.Add('--checkers')
        $argsList.Add('8')
    }

    if ($Checksum) {
        $argsList.Add('--checksum')
    }

    if ($Compress) {
        $argsList.Add('--sftp-compress')
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $rclone
    $psi.Arguments = ($argsList -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    foreach ($k in $envVars.Keys) {
        $psi.EnvironmentVariables[$k] = [string]$envVars[$k]
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $lastSpeed = ''
    $lastPercent = 0
    $lastTransferredBytes = 0L

    # Read stderr asynchronously for progress updates
    $errReader = [System.Threading.Tasks.Task]::Run([System.Action]{
        while (-not $proc.HasExited) {
            $line = $proc.StandardError.ReadLine()
            if ($null -ne $line) {
                # Format: 1.234 MiB / 10 MiB, 12%, 1.2 MiB/s, ETA 7s
                if ($line -match '(\d+[\.\d]*\s*[KMGT]?i?B)\s*/\s*(\d+[\.\d]*\s*[KMGT]?i?B).*?(\d+)%.*?([0-9\.]+\s*[KMGT]?i?B/s)') {
                    if ($null -ne $ProgressCallback) {
                        try {
                            & $ProgressCallback @{
                                Transferred = $Matches[1]
                                Total = $Matches[2]
                                Percent = [int]$Matches[3]
                                Speed = $Matches[4]
                                RawLine = $line
                            }
                        } catch { }
                    }
                }
            }
        }
    })

    $stdoutContent = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    [void]$errReader.Wait(2000)

    $elapsed = [DateTime]::UtcNow - $startTime

    if ($proc.ExitCode -ne 0) {
        $stderrRest = $proc.StandardError.ReadToEnd()
        throw "Transfer failed with exit code $($proc.ExitCode): $stderrRest"
    }

    # Record notification in transfer history if available
    if (Get-Command 'Add-TransferNotificationEvent' -ErrorAction SilentlyContinue) {
        try {
            $transferName = [System.IO.Path]::GetFileName($LocalPath)
            if ([string]::IsNullOrWhiteSpace($transferName)) { $transferName = 'Agent Sync' }
            Add-TransferNotificationEvent -Type 'AgentTransfer' `
                -ProviderId 'vps' `
                -Path $LocalPath `
                -Message "Agent $Direction completed successfully: $transferName" `
                -Status 'Completed' `
                -Direction $Direction
        } catch { }
    }

    return [ordered]@{
        Success = $true
        Direction = $Direction
        AccountId = $AccountId
        LocalPath = $LocalPath
        RemotePath = $targetRemotePath
        DurationMs = [int]$elapsed.TotalMilliseconds
        DurationSec = [Math]::Round($elapsed.TotalSeconds, 2)
        ExitCode = 0
    }
}
