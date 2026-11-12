<#
.SYNOPSIS
    CLI runner and manager for NS Cloud Drive automated sync pairs.
.DESCRIPTION
    Allows command-line and automated AI agents to execute, list, add, remove,
    and watch sync pairs between local workspaces and remote VPS/cloud storage.
.EXAMPLE
    .\Invoke-SyncPair.ps1 -Action List
    .\Invoke-SyncPair.ps1 -Action Run -SyncPairId sync_12345
    .\Invoke-SyncPair.ps1 -Action Add -Name "VPS Agent Sync" -LocalPath "C:\Data\Agent" -RemotePath "/home/agent/workspace" -ProviderId vps
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [ValidateSet('Run', 'List', 'Add', 'Remove', 'Watch')]
    [string]$Action = 'List',

    [Parameter(Mandatory = $false)]
    [string]$SyncPairId = '',

    [Parameter(Mandatory = $false)]
    [string]$Name = '',

    [Parameter(Mandatory = $false)]
    [string]$LocalPath = '',

    [Parameter(Mandatory = $false)]
    [string]$RemotePath = '',

    [Parameter(Mandatory = $false)]
    [string]$ProviderId = 'vps',

    [Parameter(Mandatory = $false)]
    [string]$AccountId = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('Push', 'Pull', 'Sync', 'BiDirectional')]
    [string]$Direction = 'Push',

    [Parameter(Mandatory = $false)]
    [int]$IntervalMinutes = 5,

    [Parameter(Mandatory = $false)]
    [switch]$Watch,

    [Parameter(Mandatory = $false)]
    [switch]$Compress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerScript = Join-Path $PSScriptRoot '..\src\services\SyncPairManager.ps1'
if (-not (Test-Path -LiteralPath $managerScript)) {
    throw "SyncPairManager.ps1 not found at $managerScript"
}
. $managerScript

switch ($Action) {
    'List' {
        $pairs = @(Get-SyncPairs)
        if ($pairs.Count -eq 0) {
            Write-Host "No sync pairs configured." -ForegroundColor Yellow
            return
        }
        Write-Host "Configured Sync Pairs ($($pairs.Count)):" -ForegroundColor Cyan
        $pairs | Format-Table -Property Id, Name, Direction, ProviderId, LocalPath, RemotePath, LastStatus, LastSyncTime -AutoSize
    }

    'Run' {
        if ([string]::IsNullOrWhiteSpace($SyncPairId)) {
            $pairs = @(Get-SyncPairs)
            if ($pairs.Count -eq 0) {
                Write-Error "No sync pairs configured to run."
                return
            }
            $SyncPairId = [string]$pairs[0].Id
            Write-Host "No SyncPairId provided. Running first sync pair: $SyncPairId ($($pairs[0].Name))" -ForegroundColor Gray
        }

        Write-Host "Executing sync pair $SyncPairId..." -ForegroundColor Cyan
        $res = Invoke-SyncPairExecution -SyncPairId $SyncPairId
        if ($res.Success) {
            Write-Host "Sync completed successfully in $($res.DurationSec)s!" -ForegroundColor Green
            Write-Host "Transferred: $($res.FilesTransferred) files, $($res.BytesTransferred) bytes." -ForegroundColor Gray
        } else {
            Write-Error "Sync failed: $($res.Error)"
        }
    }

    'Add' {
        if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($LocalPath) -or [string]::IsNullOrWhiteSpace($RemotePath)) {
            throw "Add action requires -Name, -LocalPath, and -RemotePath."
        }

        $created = New-SyncPair `
            -Name $Name `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath `
            -ProviderId $ProviderId `
            -AccountId $AccountId `
            -Direction $Direction `
            -IntervalMinutes $IntervalMinutes `
            -WatchFileSystem ([bool]$Watch) `
            -Compress ([bool]$Compress)

        Write-Host "Created new sync pair:" -ForegroundColor Green
        $created | Format-List -Property Id, Name, ProviderId, Direction, LocalPath, RemotePath, WatchFileSystem
    }

    'Remove' {
        if ([string]::IsNullOrWhiteSpace($SyncPairId)) {
            throw "Remove action requires -SyncPairId."
        }
        $ok = Remove-SyncPair -Id $SyncPairId
        if ($ok) {
            Write-Host "Removed sync pair $SyncPairId." -ForegroundColor Green
        } else {
            Write-Warning "Sync pair $SyncPairId not found."
        }
    }

    'Watch' {
        Write-Host "Starting filesystem watchers for all enabled sync pairs..." -ForegroundColor Cyan
        Start-AllSyncPairWatchers
        Write-Host "Watchers active. Press Ctrl+C to stop." -ForegroundColor Green
        try {
            while ($true) {
                [System.Threading.Thread]::Sleep(1000)
            }
        } finally {
            Stop-AllSyncPairWatchers
            Write-Host "Watchers stopped." -ForegroundColor Gray
        }
    }
}
