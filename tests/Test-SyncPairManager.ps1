<#
.SYNOPSIS
    Unit test suite for SyncPairManager.ps1.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Testing SyncPairManager service..." -ForegroundColor Cyan

$serviceScript = Join-Path $PSScriptRoot '..\src\services\SyncPairManager.ps1'
if (-not (Test-Path -LiteralPath $serviceScript)) {
    Write-Error "FAIL: SyncPairManager.ps1 does not exist"
    exit 1
}
Write-Host "  [PASS] SyncPairManager.ps1 exists" -ForegroundColor Green

. $serviceScript

$testTempDir = Join-Path $env:TEMP ("SyncPairTest_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testTempDir -Force | Out-Null
$testCfgPath = Join-Path $testTempDir 'sync-pairs.json'
Set-SyncPairsConfigPathOverride $testCfgPath

$testLocalDir = Join-Path $testTempDir 'local_workspace'
New-Item -ItemType Directory -Path $testLocalDir -Force | Out-Null

try {
    # 1. Initial empty state
    $initial = @(Get-SyncPairs)
    if ($initial.Count -ne 0) {
        throw "Expected empty sync pairs initially, got $($initial.Count)"
    }
    Write-Host "  [PASS] Initial empty sync pairs list verified" -ForegroundColor Green

    # 2. Add new sync pair
    $created = New-SyncPair `
        -Name 'Agent Workspace Sync' `
        -LocalPath $testLocalDir `
        -RemotePath '/home/agent/workspace' `
        -ProviderId 'vps' `
        -AccountId 'vps_test_123' `
        -Direction 'Push' `
        -IntervalMinutes 10 `
        -WatchFileSystem $false `
        -Compress $true

    if (-not $created -or -not $created.Id -or -not ($created.Id -like 'sync_*')) {
        throw "Failed to create sync pair with valid ID"
    }
    if ($created.Name -ne 'Agent Workspace Sync') {
        throw "Name mismatch: expected 'Agent Workspace Sync', got '$($created.Name)'"
    }
    if ($created.Direction -ne 'Push') {
        throw "Direction mismatch: expected 'Push', got '$($created.Direction)'"
    }
    if ($created.IntervalMinutes -ne 10) {
        throw "Interval mismatch: expected 10, got $($created.IntervalMinutes)"
    }
    if ($created.Compress -ne $true) {
        throw "Compress mismatch: expected true, got $($created.Compress)"
    }
    Write-Host "  [PASS] New-SyncPair creation and field validation verified" -ForegroundColor Green

    # 3. Retrieve pairs
    $all = @(Get-SyncPairs)
    if ($all.Count -ne 1) {
        throw "Expected 1 sync pair in store, got $($all.Count)"
    }
    Write-Host "  [PASS] Get-SyncPairs returns stored sync pair" -ForegroundColor Green

    # 4. Retrieve by ID
    $fetched = Get-SyncPairById -Id ([string]$created.Id)
    if (-not $fetched -or $fetched.Id -ne $created.Id) {
        throw "Failed to fetch sync pair by ID"
    }
    Write-Host "  [PASS] Get-SyncPairById returns matching record" -ForegroundColor Green

    # 5. Update pair properties
    $updated = Update-SyncPair -Id ([string]$created.Id) -Properties @{
        IntervalMinutes = 15
        Compress = $false
        LastStatus = 'Success'
    }
    if (-not $updated) {
        throw "Update-SyncPair returned false"
    }
    $refetched = Get-SyncPairById -Id ([string]$created.Id)
    if ($refetched.IntervalMinutes -ne 15 -or $refetched.Compress -ne $false -or $refetched.LastStatus -ne 'Success') {
        throw "Update-SyncPair did not persist updated properties"
    }
    Write-Host "  [PASS] Update-SyncPair persists property modifications" -ForegroundColor Green

    # 6. Test Watcher lifecycle (start, stop)
    Start-SyncPairWatcher -SyncPairId ([string]$created.Id) -DebounceSeconds 1
    if (-not $script:ActiveSyncWatchers.Contains([string]$created.Id)) {
        throw "Active sync watcher was not registered"
    }
    Stop-SyncPairWatcher -SyncPairId ([string]$created.Id)
    if ($script:ActiveSyncWatchers.Contains([string]$created.Id)) {
        throw "Active sync watcher was not cleaned up after Stop"
    }
    Write-Host "  [PASS] Sync pair watcher registration and cleanup verified" -ForegroundColor Green

    # 7. Remove sync pair
    $removed = Remove-SyncPair -Id ([string]$created.Id)
    if (-not $removed) {
        throw "Remove-SyncPair returned false"
    }
    $afterRemove = @(Get-SyncPairs)
    if ($afterRemove.Count -ne 0) {
        throw "Expected 0 sync pairs after removal, got $($afterRemove.Count)"
    }
    Write-Host "  [PASS] Remove-SyncPair successfully removes record from store" -ForegroundColor Green

    Write-Host "`nAll SyncPairManager tests passed successfully!" -ForegroundColor Green
    exit 0
} finally {
    Stop-AllSyncPairWatchers
    if (Test-Path -LiteralPath $testTempDir) {
        try { Remove-Item -LiteralPath $testTempDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}
