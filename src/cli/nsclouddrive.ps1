#!/usr/bin/env pwsh
# ==============================================================================
# NS Cloud Drive - Cross-Platform CLI & VPS Daemon
# Supports Linux (Ubuntu, Debian, Arch, RHEL) and Windows
# Provides headless mounting, automated queue syncing, and background daemon
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Target = '',

    [Parameter(Position = 2)]
    [string]$Destination = '',

    [switch]$Help,
    [switch]$Foreground,
    [string]$LogFile = '',
    [string]$BandwidthLimit = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CliDir = $PSScriptRoot
$script:SrcDir = (Split-Path -Parent $script:CliDir)

# Import Core Models & Services (Headless - Zero UI/WPF dependency)
. (Join-Path $script:SrcDir 'models\ConnectionState.ps1')
. (Join-Path $script:SrcDir 'services\SettingsManager.ps1')
. (Join-Path $script:SrcDir 'providers\ProviderContract.ps1')
. (Join-Path $script:SrcDir 'providers\GoogleDriveProvider.ps1')
. (Join-Path $script:SrcDir 'providers\TeraBoxProvider.ps1')
. (Join-Path $script:SrcDir 'providers\VpsProvider.ps1')
. (Join-Path $script:SrcDir 'providers\ProtonDriveProvider.ps1')
. (Join-Path $script:SrcDir 'providers\MegaProvider.ps1')
. (Join-Path $script:SrcDir 'providers\S3Provider.ps1')
. (Join-Path $script:SrcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $script:SrcDir 'services\CloudDeduplicationService.ps1')
. (Join-Path $script:SrcDir 'services\CloudTransferManager.ps1')

function Get-SafeCount([object]$Collection) {
    if ($null -eq $Collection) { return 0 }
    return @($Collection).Count
}

function Show-CliBanner {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "       NS Cloud Drive - Cross-Platform Linux/Windows      " -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Cyan
}

function Show-CliHelp {
    Show-CliBanner
    Write-Host "Usage: nsclouddrive <command> [arguments] [options]`n" -ForegroundColor Yellow
    Write-Host "Commands:" -ForegroundColor White
    Write-Host "  status                      Show connection, mount states, and active transfers" -ForegroundColor Gray
    Write-Host "  accounts                    List all configured cloud accounts" -ForegroundColor Gray
    Write-Host "  mount [all | <account/prov>] Mount cloud storage to filesystem (e.g. ~/CloudDrives/gdrive)" -ForegroundColor Gray
    Write-Host "  unmount [all | <account/pr>] Safely unmount active cloud drives" -ForegroundColor Gray
    Write-Host "  transfer <source> <account> [destPath] Resumable deduplicated cloud transfer" -ForegroundColor Gray
    Write-Host "  queue                       Display current durable transfer queue and progress" -ForegroundColor Gray
    Write-Host "  clear-queue                 Remove completed and settled jobs from transfer queue" -ForegroundColor Gray
    Write-Host "  recover                     Run silent startup recovery and restart reconciliation" -ForegroundColor Gray
    Write-Host "  daemon                      Run continuous background service (auto-mount & sync)" -ForegroundColor Gray
    Write-Host "  help                        Show this help message`n" -ForegroundColor Gray
    Write-Host "Examples:" -ForegroundColor White
    Write-Host "  nsclouddrive status" -ForegroundColor Gray
    Write-Host "  nsclouddrive mount all" -ForegroundColor Gray
    Write-Host "  nsclouddrive transfer /data/backups gdrive /backups" -ForegroundColor Gray
    Write-Host "  nsclouddrive daemon" -ForegroundColor Gray
}

function Show-CliStatus {
    Show-CliBanner
    $accounts = @(Get-CloudAccounts)
    $accCount = Get-SafeCount $accounts
    Write-Host "`n[ Configured Accounts: $accCount ]" -ForegroundColor Cyan
    if ($accCount -eq 0) {
        Write-Host "  No accounts configured. Use desktop app or credentials folder to add accounts." -ForegroundColor Yellow
    } else {
        foreach ($acc in $accounts) {
            $accId = [string](Get-CloudProviderFieldValue $acc 'Id' '')
            $prov = [string](Get-CloudProviderFieldValue $acc 'ProviderId' '')
            $email = [string](Get-CloudProviderFieldValue $acc 'Email' 'N/A')
            $mStatus = Get-VirtualDriveStatus -AccountId $accId -ProviderId $prov
            $isMounted = [bool]($mStatus -and $mStatus.IsMounted)
            $mountPath = if ($isMounted) { $mStatus.DriveRoot } else { 'Unmounted' }
            $statusColor = if ($isMounted) { 'Green' } else { 'DarkGray' }
            Write-Host "  * [$prov] $accId ($email)" -ForegroundColor White
            Write-Host "    Mount: $mountPath (Mounted=$isMounted)" -ForegroundColor $statusColor
        }
    }

    $rawQ = @()
    try {
        if (Get-Command Get-CloudTransferQueue -ErrorAction SilentlyContinue) {
            $rawQ = @(Get-CloudTransferQueue)
        }
    } catch { }
    $checkQ = if ((Get-SafeCount $rawQ) -gt 0 -and $rawQ[0] -is [array]) { @($rawQ[0]) } else { $rawQ }
    $queued = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -eq 'Queued' })
    $active = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -in @('Uploading', 'Staging') })
    $completed = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -eq 'Completed and remotely confirmed' })
    $failed = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -eq 'Failed' })

    Write-Host "`n[ Transfer Queue State ]" -ForegroundColor Cyan
    Write-Host "  Queued: $(Get-SafeCount $queued) | Active: $(Get-SafeCount $active) | Completed: $(Get-SafeCount $completed) | Failed: $(Get-SafeCount $failed)" -ForegroundColor White
}

function Invoke-CliMount([string]$TargetAccount = 'all') {
    $accounts = @(Get-CloudAccounts)
    if ($accounts.Count -eq 0) {
        Write-Host "No accounts found to mount." -ForegroundColor Yellow
        return
    }

    $toMount = @()
    if ([string]::IsNullOrWhiteSpace($TargetAccount) -or $TargetAccount -eq 'all') {
        $toMount = $accounts
    } else {
        $toMount = @($accounts | Where-Object {
            $aid = [string](Get-CloudProviderFieldValue $_ 'Id')
            $pid = [string](Get-CloudProviderFieldValue $_ 'ProviderId')
            $aid -eq $TargetAccount -or $pid -eq $TargetAccount
        })
    }

    if ($toMount.Count -eq 0) {
        Write-Host "No matching accounts found for target '$TargetAccount'." -ForegroundColor Red
        return
    }

    foreach ($acc in $toMount) {
        $accId = [string](Get-CloudProviderFieldValue $acc 'Id')
        $prov = [string](Get-CloudProviderFieldValue $acc 'ProviderId')
        Write-Host "Mounting $accId ($prov)..." -ForegroundColor Cyan
        try {
            $mountRes = Start-VirtualDriveMount -ProviderId $prov -AccountId $accId
            if ($mountRes.Success) {
                Write-Host "  [SUCCESS] Mounted to $($mountRes.DriveRoot)" -ForegroundColor Green
            } else {
                Write-Host "  [FAILED] Could not mount: $($mountRes.Message)" -ForegroundColor Red
            }
        } catch {
            Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Invoke-CliUnmount([string]$TargetAccount = 'all') {
    Write-Host "Unmounting targets..." -ForegroundColor Cyan
    try {
        if ([string]::IsNullOrWhiteSpace($TargetAccount) -or $TargetAccount -eq 'all') {
            $res = Stop-VirtualDriveMount
        } else {
            $res = Stop-VirtualDriveMount -AccountId $TargetAccount -ProviderId $TargetAccount
        }
        Write-Host "  [SUCCESS] $($res.Message)" -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-CliTransfer([string]$SourcePath, [string]$TargetAccount, [string]$DestSubPath = '') {
    if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath)) {
        Write-Host "Source path not found: $SourcePath" -ForegroundColor Red
        return
    }

    $accounts = @(Get-CloudAccounts)
    $destAcc = @($accounts | Where-Object {
        $aid = [string](Get-CloudProviderFieldValue $_ 'Id')
        $pid = [string](Get-CloudProviderFieldValue $_ 'ProviderId')
        $aid -eq $TargetAccount -or $pid -eq $TargetAccount
    }) | Select-Object -First 1

    if (-not $destAcc) {
        Write-Host "Destination account '$TargetAccount' not found in settings." -ForegroundColor Red
        return
    }

    $destAccId = [string](Get-CloudProviderFieldValue $destAcc 'Id')
    $destProvId = [string](Get-CloudProviderFieldValue $destAcc 'ProviderId')
    $localAcc = @{ Id = 'local'; ProviderId = 'local'; Label = 'Local Storage' }
    Write-Host "Analyzing '$SourcePath' for cloud transfer..." -ForegroundColor Cyan

    $isDir = (Test-Path -LiteralPath $SourcePath -PathType Container)
    if ($isDir) {
        $batch = Add-CloudTransferFolderBatch -SourceAccount $localAcc -SourceFolderPath $SourcePath `
            -DestinationAccount $destAcc -DestinationFolderPath $DestSubPath -ConflictAction Skip
        Write-Host "  Ingested Folder Batch: $($batch.BatchName) ($($batch.TotalFiles) files, $($batch.TotalBytes) bytes)" -ForegroundColor White
        Write-Host "  Already in Cloud (Skipped): $($batch.AlreadyInCloudCount) files ($($batch.AlreadyInCloudBytes) bytes)" -ForegroundColor Green
        Write-Host "  Queued for Transfer: $($batch.QueuedCount) files" -ForegroundColor Yellow

        $summary = Get-CloudTransferBatchSummary -BatchId $batch.BatchId
        if ($summary) {
            Write-Host "  Batch Initial Progression: $($summary.OverallPercentage)%" -ForegroundColor Cyan
        }
    } else {
        $fi = [System.IO.FileInfo]::new($SourcePath)
        $cleanDest = if ($DestSubPath) { Normalize-CloudPath "$DestSubPath/$($fi.Name)" } else { $fi.Name }
        $dedup = Test-RemoteCloudFileDeduplication -AccountId $destAccId -ProviderId $destProvId `
            -RemotePath $cleanDest -LocalSizeBytes $fi.Length -LocalFilePath $SourcePath -Account $destAcc
        if ($dedup.IsPresent) {
            Write-Host "  [SKIPPED] File already exists in cloud with matching format and exact byte size ($($fi.Length) bytes)." -ForegroundColor Green
            return
        }
        $job = Add-CloudTransferQueueItem -SourceAccount $localAcc -SourcePath $SourcePath `
            -DestinationAccount $destAcc -DestinationPath $DestSubPath -ConflictAction Skip
        Write-Host "  [QUEUED] Job enqueued: $($job.JobId) ($($fi.Length) bytes)" -ForegroundColor Yellow
    }

    Write-Host "Processing queue in background..." -ForegroundColor Cyan
    $null = Process-CloudTransferQueue
}

function Show-CliQueue {
    $rawQ = @()
    try {
        if (Get-Command Get-CloudTransferQueue -ErrorAction SilentlyContinue) {
            $rawQ = @(Get-CloudTransferQueue)
        }
    } catch { }
    $checkQ = if ((Get-SafeCount $rawQ) -gt 0 -and $rawQ[0] -is [array]) { @($rawQ[0]) } else { $rawQ }
    $qCount = Get-SafeCount $checkQ
    Write-Host "`n=== Durable Transfer Queue ($qCount items) ===" -ForegroundColor Cyan
    if ($qCount -eq 0) {
        Write-Host "  Queue is empty." -ForegroundColor DarkGray
        return
    }

    foreach ($item in $checkQ) {
        $name = [string]$item['FileName']
        $st = [string]$item['Status']
        $pct = [double]$item['Percentage']
        $sz = [int64]$item['FileSizeBytes']
        $col = switch ($st) {
            'Completed and remotely confirmed' { 'Green' }
            'Uploading' { 'Yellow' }
            'Queued' { 'Cyan' }
            'Failed' { 'Red' }
            default { 'Gray' }
        }
        Write-Host "  * [$st] $name ($sz bytes) - $pct%" -ForegroundColor $col
    }
}

function Start-CliDaemon {
    Show-CliBanner
    Write-Host "Starting NS Cloud Drive Daemon for Linux VPS / Background Service..." -ForegroundColor Green
    Write-Host "Running initial startup recovery & restart reconciliation..." -ForegroundColor Cyan
    try {
        $rec = Invoke-StartupTransferQueueRecovery
        Write-Host "  Recovery Summary: $($rec.RecoveredCount) recovered, $($rec.ConfirmedCount) confirmed, $($rec.ResetCount) reset." -ForegroundColor White
    } catch {
        Write-Host "  Recovery notice: $($_.Exception.Message)" -ForegroundColor DarkGray
    }

    Write-Host "Auto-mounting configured accounts..." -ForegroundColor Cyan
    Invoke-CliMount -TargetAccount 'all'

    Write-Host "`nDaemon active. Listening for transfer queue work (Press Ctrl+C to stop)..." -ForegroundColor Green
    $cycle = 0
    while ($true) {
        try {
            $null = Process-CloudTransferQueue
            $cycle++
            if ($cycle % 60 -eq 0) {
                # Periodic log rotation & maintenance every 5 minutes
                $null = Invoke-LogMaintenance
            }
        } catch { }
        [System.Threading.Thread]::Sleep(5000)
    }
}

# Command Dispatcher
switch ($Command.ToLowerInvariant()) {
    'status'       { Show-CliStatus }
    'accounts'     { Show-CliStatus }
    'mount'        { Invoke-CliMount -TargetAccount $Target }
    'unmount'      { Invoke-CliUnmount -TargetAccount $Target }
    'transfer'     { Invoke-CliTransfer -SourcePath $Target -TargetAccount $Destination -DestSubPath '' }
    'queue'        { Show-CliQueue }
    'clear-queue'  { Clear-CloudTransferQueue; Write-Host "Transfer queue cleared." -ForegroundColor Green }
    'recover'      {
        $rec = Invoke-StartupTransferQueueRecovery
        Write-Host "Startup recovery finished: $($rec.RecoveredCount) recovered, $($rec.ConfirmedCount) confirmed, $($rec.ResetCount) reset." -ForegroundColor Green
    }
    'daemon'       { Start-CliDaemon }
    default        { Show-CliHelp }
}
