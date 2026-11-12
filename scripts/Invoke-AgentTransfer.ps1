<#
.SYNOPSIS
    NS Cloud Drive - Autonomous Agent File Transfer CLI
.DESCRIPTION
    High-speed, verifiable file transfer utility between local workstation and Linux VPS
    where AI coding agents operate. Supports Push, Pull, List, and Sync.
.EXAMPLE
    .\scripts\Invoke-AgentTransfer.ps1 -Direction Push -LocalPath "C:\bigfile.iso" -RemotePath "/home/agent/workspace/"
    .\scripts\Invoke-AgentTransfer.ps1 -Direction Pull -RemotePath "/home/agent/output.zip" -LocalPath "C:\Downloads\"
    .\scripts\Invoke-AgentTransfer.ps1 -Direction List -RemotePath "/home/agent" -AsJson
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('Push', 'Pull', 'List', 'Sync')]
    [string]$Direction,

    [Parameter(Mandatory = $false, Position = 1)]
    [string]$LocalPath = '',

    [Parameter(Mandatory = $false, Position = 2)]
    [string]$RemotePath = '',

    [Parameter(Mandatory = $false)]
    [string]$AccountId = '',

    [Parameter(Mandatory = $false)]
    [bool]$HugeFileMode = $true,

    [Parameter(Mandatory = $false)]
    [switch]$Checksum,

    [Parameter(Mandatory = $false)]
    [switch]$Compress,

    [Parameter(Mandatory = $false)]
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$bridgeScript = Join-Path $scriptDir '..\src\services\AgentTransferBridge.ps1'

if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "Cannot locate AgentTransferBridge at: $bridgeScript"
}

. $bridgeScript

if (-not $AsJson) {
    Write-Host "=== NS Cloud Drive - Autonomous Agent File Transfer ===" -ForegroundColor Cyan
    Write-Host "Direction: $Direction"
    if ($LocalPath) { Write-Host "Local:     $LocalPath" }
    if ($RemotePath) { Write-Host "Remote:    $RemotePath" }
    Write-Host "Mode:      $([string](if ($HugeFileMode) { 'Huge File Accelerated (SFTP 256k chunks, 64M buffer)' } else { 'Standard SFTP' }))"
    Write-Host "--------------------------------------------------------"
}

try {
    $progressCallback = if (-not $AsJson) {
        {
            param($info)
            $pct = if ($info.Percent) { "$($info.Percent)%" } else { '...' }
            $spd = if ($info.Speed) { "$($info.Speed)" } else { '' }
            $tx = if ($info.Transferred -and $info.Total) { "$($info.Transferred) / $($info.Total)" } else { '' }
            Write-Host -NoNewline "`r[Transferring] $pct  $tx  $spd                      "
        }
    } else {
        $null
    }

    $transferParams = @{
        Direction = $Direction
    }
    if ($AccountId) { $transferParams['AccountId'] = $AccountId }
    if ($LocalPath) { $transferParams['LocalPath'] = $LocalPath }
    if ($RemotePath) { $transferParams['RemotePath'] = $RemotePath }
    if ($HugeFileMode) { $transferParams['HugeFileMode'] = $true }
    if ($Checksum) { $transferParams['Checksum'] = $true }
    if ($Compress) { $transferParams['Compress'] = $true }
    if ($progressCallback) { $transferParams['ProgressCallback'] = $progressCallback }

    $result = Start-AgentFileTransfer @transferParams

    if ($AsJson) {
        $result | ConvertTo-Json -Depth 4
    } else {
        Write-Host "`n--------------------------------------------------------"
        Write-Host "[SUCCESS] Agent transfer completed successfully!" -ForegroundColor Green
        if ($result.DurationSec) { Write-Host "Duration:  $($result.DurationSec) seconds" }
        if ($result.Entries) {
            Write-Host "Remote directory contents ($($result.Entries.Count) items):"
            foreach ($entry in $result.Entries) {
                Write-Host "  - $entry"
            }
        }
    }
    exit 0
} catch {
    if ($AsJson) {
        @{
            Success = $false
            Error = $_.Exception.Message
        } | ConvertTo-Json -Depth 4
    } else {
        Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
    exit 1
}
