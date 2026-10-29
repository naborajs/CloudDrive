Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output '============================================'
Write-Output 'NS Cloud Drive - Automated Test Suite'
Write-Output '============================================'

$testScripts = @(
    (Join-Path $PSScriptRoot 'Test-ConnectionState.ps1'),
    (Join-Path $PSScriptRoot 'Test-BackgroundOperationManager.ps1'),
    (Join-Path $PSScriptRoot 'Test-StartupAutoMountTimer.ps1'),
    (Join-Path $PSScriptRoot 'Test-LiquidGlassTheme.ps1'),
    (Join-Path $PSScriptRoot 'Test-LogsPage.ps1'),
    (Join-Path $PSScriptRoot 'Test-ProviderContracts.ps1'),
    (Join-Path $PSScriptRoot 'Test-SecurityAudit.ps1'),
    (Join-Path $PSScriptRoot 'Test-GoogleAccountCreationRecovery.ps1'),
    (Join-Path $PSScriptRoot 'Test-AnalyticsPage.ps1'),
    (Join-Path $PSScriptRoot 'Test-TeraBoxProvider.ps1'),
    (Join-Path $PSScriptRoot 'Test-TeraBoxBridgeManager.ps1'),
    (Join-Path $PSScriptRoot 'Test-GoogleDriveProvider.ps1'),
    (Join-Path $PSScriptRoot 'Test-VirtualDriveManager.ps1'),
    (Join-Path $PSScriptRoot 'Test-SettingsManager.ps1'),
    (Join-Path $PSScriptRoot 'Test-AccountCreationSaveFlow.ps1'),
    (Join-Path $PSScriptRoot 'Test-VirtualDriveFilesystemVerification.ps1'),
    (Join-Path $PSScriptRoot 'Test-DesktopUIRegression.ps1'),
    (Join-Path $PSScriptRoot 'Test-EmbeddedBrowserWindow.ps1'),
    (Join-Path $PSScriptRoot 'Test-MultiAccountIsolation.ps1'),
    (Join-Path $PSScriptRoot 'Test-TeraBoxAccountIsolation.ps1'),
    (Join-Path $PSScriptRoot 'Test-MultiAccountLifecycle.ps1'),
    (Join-Path $PSScriptRoot 'Test-ExplorerIntegration.ps1'),
    (Join-Path $PSScriptRoot 'Test-ThemesAndAccountCustomization.ps1'),
    (Join-Path $PSScriptRoot 'Test-OptionsPage.ps1'),
    (Join-Path $PSScriptRoot 'Test-CloudTransferManager.ps1'),
    (Join-Path $PSScriptRoot 'Test-TransferTelemetryAndVerification.ps1'),
    (Join-Path $PSScriptRoot 'Test-TransferBandwidthAndQueue.ps1'),
    (Join-Path $PSScriptRoot 'Test-TransferRecoveryAndProgression.ps1'),
    (Join-Path $PSScriptRoot 'Test-CacheManagement.ps1'),
    (Join-Path $PSScriptRoot 'Test-MountIsolationAndAnalyticsDormancy.ps1'),
    (Join-Path $PSScriptRoot 'Test-StartupBehavior.ps1'),
    (Join-Path $PSScriptRoot 'Test-EndToEndAcceptance.ps1'),
    (Join-Path $PSScriptRoot 'Test-WriteAndUploadVerification.ps1'),
    (Join-Path $PSScriptRoot 'Test-TeraBoxStreamingAndMaintenance.ps1'),
    (Join-Path $PSScriptRoot 'Test-OrphanedVfsCacheReconciliation.ps1'),
    (Join-Path $PSScriptRoot 'Test-StagedVfsQueueAdoption.ps1'),
    (Join-Path $PSScriptRoot 'Test-TransferAdoptionToWorkerE2E.ps1'),
    (Join-Path $PSScriptRoot 'Test-TransferDirectionAndIdentity.ps1'),
    (Join-Path $PSScriptRoot 'Test-OrderedDictionaryAccountTransfer.ps1'),
    (Join-Path $PSScriptRoot 'Test-EmptyPendingUploadsSummary.ps1'),
    (Join-Path $PSScriptRoot '..\scripts\Test-RcloneConfigPassword.ps1')
)

$passed = 0
$failed = 0

foreach ($script in $testScripts) {
    $scriptName = Split-Path $script -Leaf
    Write-Output "`n[RUNNING] $scriptName"
    try {
        & $script
        $passed++
        Write-Output "[PASSED]  $scriptName"
    } catch {
        $failed++
        Write-Error "[FAILED]  ${scriptName}: $($_.Exception.Message)"
    }
}

Write-Output "`n============================================"
Write-Output "Test Results: $passed Passed, $failed Failed"
Write-Output '============================================'

if ($failed -gt 0) {
    exit 1
}
