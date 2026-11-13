<#
.SYNOPSIS
    CLI utility for NS Cloud Drive intelligent pre-transfer deduplication and format/size inspection.
.DESCRIPTION
    Scans files prior to upload against cloud storage inventory and the durable ledger.
    Classifies files into AlreadyInCloud (Skipped), New, SizeMismatch, and FormatMismatch (e.g. PNG vs JPG).
.EXAMPLE
    .\Invoke-CloudDeduplication.ps1 -SourcePath "C:\Photos" -ProviderId gdrive -DestinationPath "Backup"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$SourcePath,

    [Parameter(Mandatory = $false)]
    [string]$AccountId = '',

    [Parameter(Mandatory = $false)]
    [string]$ProviderId = 'gdrive',

    [Parameter(Mandatory = $false)]
    [string]$DestinationPath = '',

    [Parameter(Mandatory = $false)]
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$serviceScript = Join-Path $PSScriptRoot '..\src\services\CloudDeduplicationService.ps1'
if (-not (Test-Path -LiteralPath $serviceScript)) {
    throw "CloudDeduplicationService.ps1 not found at $serviceScript"
}
. $serviceScript

if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Source path does not exist: $SourcePath"
}

# Resolve Account
$accList = @(Get-CloudAccounts)
$targetAccount = $null
if ($AccountId) {
    $targetAccount = $accList | Where-Object { [string]$_.Id -eq $AccountId } | Select-Object -First 1
}
if (-not $targetAccount) {
    $targetAccount = $accList | Where-Object { [string]$_.ProviderId -eq $ProviderId } | Select-Object -First 1
}
if (-not $targetAccount) {
    $targetAccount = @{
        Id = if ($AccountId) { $AccountId } else { "${ProviderId}_default" }
        ProviderId = $ProviderId
    }
}

Write-Host "Scanning source files for cloud deduplication..." -ForegroundColor Cyan

$files = @()
$isDir = (Test-Path -LiteralPath $SourcePath -PathType Container)
if ($isDir) {
    $files = @([System.IO.Directory]::EnumerateFiles($SourcePath, '*', [System.IO.SearchOption]::AllDirectories))
} else {
    $files = @($SourcePath)
}

if ($files.Count -eq 0) {
    Write-Host "No files found to classify." -ForegroundColor Yellow
    return
}

$root = if ($isDir) { $SourcePath } else { [System.IO.Path]::GetDirectoryName($SourcePath) }

$batch = Classify-TransferBatch `
    -FilePaths $files `
    -DestinationAccount $targetAccount `
    -DestinationFolderPath $DestinationPath `
    -SourceRootPath $root

$s = $batch.Summary
Write-Host "`n=== CLOUD DEDUPLICATION & DELTA CLASSIFICATION REPORT ===" -ForegroundColor Green
Write-Host "Destination: $($targetAccount.ProviderId) ($($targetAccount.Id))" -ForegroundColor Gray
Write-Host "Total Scanned:          $($s.TotalScanned) files" -ForegroundColor White
Write-Host "Already in Cloud:       $($s.AlreadyInCloudCount) files (SKIPPED - will not waste time/bandwidth)" -ForegroundColor Green
Write-Host "New Files to Send:      $($s.NewFilesCount) files" -ForegroundColor Yellow
Write-Host "Modified / Re-send:     $($s.ModifiedFilesCount) files (Format or size mismatch)" -ForegroundColor Magenta
Write-Host "Total to Transfer:      $($s.FilesToTransferCount) files" -ForegroundColor Cyan
Write-Host "Skipped Data:           $([Math]::Round($s.SkippedBytes / 1MB, 2)) MB" -ForegroundColor Green
Write-Host "Data to Transfer:       $([Math]::Round($s.BytesToTransfer / 1MB, 2)) MB" -ForegroundColor Cyan
Write-Host "Inspection Duration:    $($s.ClassificationMs) ms" -ForegroundColor Gray

if ($Detailed -and $batch.AllDetails.Count -gt 0) {
    Write-Host "`nDetailed File Breakdown:" -ForegroundColor Cyan
    $batch.AllDetails | Format-Table -Property Status, RelativePath, LocalSizeBytes, RemoteSizeBytes, LocalFormat, RemoteFormat, Reason -AutoSize
}
