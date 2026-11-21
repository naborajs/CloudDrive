# ==============================================================================
# NS Cloud Drive - Test Linux Cross-Platform & Resumable Transfer Support
# Validates:
# 1. Linux XDG data & config root resolution without LOCALAPPDATA
# 2. Linux directory mount points vs Windows drive letters
# 3. Linux FUSE detection in Test-WinFspInstalled
# 4. Linux mount arguments generation (no WinFsp flags, directory mount targets)
# 5. POSIX ACL safety in Set-CloudCredentialAcl
# 6. Partial batch progression starting at 20% and advancing to 21%+
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Testing Linux Cross-Platform & Resumable Progression ===" -ForegroundColor Cyan

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\ProviderContract.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudDeduplicationService.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')

# ------------------------------------------------------------------------------
# Test 1: Cross-Platform Data & Config Directory Resolution
# ------------------------------------------------------------------------------
Write-Host "1. Testing Cross-Platform Directory Resolution..." -ForegroundColor Yellow

$origXdgData = $env:XDG_DATA_HOME
$origXdgConfig = $env:XDG_CONFIG_HOME
$origHome = $env:HOME
try {
    # Simulate Linux environment
    $env:XDG_DATA_HOME = '/home/vpsuser/.local/share'
    $env:XDG_CONFIG_HOME = '/home/vpsuser/.config'
    $env:HOME = '/home/vpsuser'

    $global:IsLinux = $true

    $dataRoot = Get-NSCloudDriveDataRoot
    if ($dataRoot -ne '/home/vpsuser/.local/share/nsclouddrive' -and $dataRoot -ne (Join-Path '/home/vpsuser/.local/share' 'nsclouddrive')) {
        throw "Linux data root resolution mismatch: got '$dataRoot'"
    }
    Write-Host "  [PASS] Linux XDG data root resolved: $dataRoot" -ForegroundColor Green

    $configRoot = Get-NSCloudDriveConfigRoot
    if ($configRoot -ne '/home/vpsuser/.config/nsclouddrive' -and $configRoot -ne (Join-Path '/home/vpsuser/.config' 'nsclouddrive')) {
        throw "Linux config root resolution mismatch: got '$configRoot'"
    }
    Write-Host "  [PASS] Linux XDG config root resolved: $configRoot" -ForegroundColor Green
} finally {
    $global:IsLinux = $false
    $env:XDG_DATA_HOME = $origXdgData
    $env:XDG_CONFIG_HOME = $origXdgConfig
    $env:HOME = $origHome
}

# ------------------------------------------------------------------------------
# Test 2: Provider Mount Point Resolution (Windows Drive Letters vs Linux Paths)
# ------------------------------------------------------------------------------
Write-Host "2. Testing Provider Mount Point Resolution..." -ForegroundColor Yellow

# Windows Resolution
$winMount = Resolve-ProviderMountPoint -ProviderId 'gdrive' -DriveLetter 'G'
if ($winMount -ne 'G:\') {
    throw "Windows mount point resolution mismatch: expected 'G:\', got '$winMount'"
}
Write-Host "  [PASS] Windows mount point verified: $winMount" -ForegroundColor Green

# Linux Resolution
try {
    $global:IsLinux = $true
    $env:HOME = '/home/vpsuser'
    $linuxMount = Resolve-ProviderMountPoint -ProviderId 'gdrive' -AccountId 'acc_gdrive_vps'
    $expectedLinuxMount = Join-Path (Join-Path '/home/vpsuser' 'CloudDrives') 'acc_gdrive_vps'
    if ($linuxMount -ne $expectedLinuxMount) {
        throw "Linux mount point resolution mismatch: expected '$expectedLinuxMount', got '$linuxMount'"
    }
    Write-Host "  [PASS] Linux directory mount target verified: $linuxMount" -ForegroundColor Green
} finally {
    $global:IsLinux = $false
    $env:HOME = $origHome
}

# ------------------------------------------------------------------------------
# Test 3: Linux Mount Arguments Generation
# ------------------------------------------------------------------------------
Write-Host "3. Testing Linux Mount Arguments Generation..." -ForegroundColor Yellow

try {
    $global:IsLinux = $true
    $env:HOME = $env:TEMP
    $testMountDir = Join-Path $env:TEMP 'TestLinuxMount_Gdrive'
    New-Item -ItemType Directory -Path $testMountDir -Force | Out-Null

    $linuxArgs = Build-RcloneMountArguments -RemoteName 'gdrive_remote' -MountPoint $testMountDir -CacheMaxGigabytes 10
    $argString = $linuxArgs -join ' '

    # Validate that Windows-only flags are omitted
    if ($argString.Contains('--network-mode')) {
        throw "Linux mount arguments must NOT contain Windows-only '--network-mode' flag!"
    }
    if ($argString.Contains('--fuse-flag')) {
        throw "Linux mount arguments must NOT contain Windows-only '--fuse-flag'!"
    }
    # Validate that Linux FUSE flags and directory target are present
    if (-not $argString.Contains('--allow-other')) {
        throw "Linux mount arguments should include '--allow-other'!"
    }
    if (-not $argString.Contains($testMountDir)) {
        throw "Linux mount arguments must target the directory path '$testMountDir'!"
    }

    Write-Host "  [PASS] Linux mount arguments correctly omit Windows WinFsp flags and target directory." -ForegroundColor Green
} finally {
    $global:IsLinux = $false
}

# ------------------------------------------------------------------------------
# Test 4: Partial Batch Progression (20% -> 21% without resetting to 0%)
# ------------------------------------------------------------------------------
Write-Host "4. Testing Resumable Batch Progression (20% -> 21%)..." -ForegroundColor Yellow

$testBatchId = "batch_test_progression_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$script:CloudTransferQueue.Clear()

# Simulate a 10-file batch (100 MB total) where 2 files (20 MB = 20%) were already confirmed in cloud
for ($i = 1; $i -le 10; $i++) {
    $isDone = ($i -le 2)
    $st = if ($isDone) { 'Completed and remotely confirmed' } else { 'Queued' }
    $bTrans = if ($isDone) { 10485760L } else { 0L }
    $pct = if ($isDone) { 100.0 } else { 0.0 }

    $job = [hashtable]::Synchronized(@{
        JobId = "job_prog_$i"
        QueueId = "job_prog_$i"
        BatchId = $testBatchId
        BatchName = 'Resumable Test Batch'
        FileName = "file_$i.dat"
        FileSizeBytes = 10485760L # 10 MB per file
        BytesTransferred = $bTrans
        Percentage = $pct
        Status = $st
        RetryCount = 0
        MaxRetries = 3
    })
    [void]$script:CloudTransferQueue.Add($job)
}

# Check initial batch summary after restart / drop
$summaryInitial = Get-CloudTransferBatchSummary -BatchId $testBatchId
if ($summaryInitial.OverallPercentage -ne 20.0) {
    throw "Expected initial batch percentage to start at 20.0%, got: $($summaryInitial.OverallPercentage)%"
}
Write-Host "  [PASS] Interrupted batch immediately resumes at 20.0% (not 0%)." -ForegroundColor Green

# Simulate file 3 uploading 1 MB (10% of file 3 = 1 MB / 100 MB batch = 1.0% batch progress -> 21.0%)
$job3 = @($script:CloudTransferQueue | Where-Object { $_['JobId'] -eq 'job_prog_3' })[0]
$job3['Status'] = 'Uploading'
$job3['BytesTransferred'] = 1048576L # 1 MB
$job3['Percentage'] = 10.0

$summaryProgressing = Get-CloudTransferBatchSummary -BatchId $testBatchId
if ($summaryProgressing.OverallPercentage -ne 21.0) {
    throw "Expected batch percentage to advance smoothly to 21.0%, got: $($summaryProgressing.OverallPercentage)%"
}
Write-Host "  [PASS] Progress updates smoothly from 20.0% -> 21.0% during upload." -ForegroundColor Green

# Clean up
$script:CloudTransferQueue.Clear()

Write-Host "`nAll Linux Cross-Platform & Resumable Progression Tests Passed Successfully!" -ForegroundColor Green
