#!/usr/bin/env pwsh
# ==============================================================================
# Test-LinuxDesktopApp.ps1
# Automated test suite for Linux Desktop Application packaging, launcher,
# XDG desktop entries, asset serving, and CLI integration.
# ==============================================================================

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TotalTests = 0
$script:PassedTests = 0
$script:FailedTests = 0

function Assert-Condition {
    param(
        [string]$Description,
        [bool]$Condition,
        [string]$Details = ''
    )
    $script:TotalTests++
    if ($Condition) {
        $script:PassedTests++
        Write-Host "  [PASS] $Description" -ForegroundColor Green
    } else {
        $script:FailedTests++
        Write-Host "  [FAIL] $Description" -ForegroundColor Red
        if ($Details) {
            Write-Host "         $Details" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n=== Test Suite: Linux Desktop Application Packaging & Integration ===" -ForegroundColor Cyan

$testRoot = $PSScriptRoot
$repoRoot = (Split-Path -Parent $testRoot)
$desktopFile = Join-Path $repoRoot 'scripts\desktop\nsclouddrive.desktop'
$appLauncher = Join-Path $repoRoot 'scripts\nsclouddrive-app'
$installer = Join-Path $repoRoot 'scripts\install-linux.sh'
$providerWindow = Join-Path $repoRoot 'src\ui\ProviderConnectionWindow.ps1'
$transferManager = Join-Path $repoRoot 'src\services\CloudTransferManager.ps1'
$cliFile = Join-Path $repoRoot 'src\cli\nsclouddrive.ps1'
$appPy = Join-Path $repoRoot 'src\web\app.py'
$logoPng = Join-Path $repoRoot 'assets\logos\clouddrive.png'

# Phase 1: Desktop Entry File Integrity
Write-Host "`n[Phase 1] Desktop Entry & Launcher Scripts" -ForegroundColor White
Assert-Condition "nsclouddrive.desktop exists" (Test-Path -LiteralPath $desktopFile)
$desktopContent = Get-Content -LiteralPath $desktopFile -Raw
Assert-Condition "Desktop entry specifies Name=NS Cloud Drive" ($desktopContent -match "Name=NS Cloud Drive")
Assert-Condition "Desktop entry specifies Type=Application" ($desktopContent -match "Type=Application")
Assert-Condition "Desktop entry specifies Exec=/usr/local/bin/nsclouddrive-app" ($desktopContent -match "Exec=/usr/local/bin/nsclouddrive-app")
Assert-Condition "Desktop entry specifies Icon=nsclouddrive" ($desktopContent -match "Icon=nsclouddrive")
Assert-Condition "Desktop entry specifies Categories" ($desktopContent -match "Categories=.*Network")
Assert-Condition "Desktop entry contains desktop actions (MountAll, UnmountAll, Status)" (
    $desktopContent.Contains('[Desktop Action MountAll]') -and
    $desktopContent.Contains('[Desktop Action UnmountAll]') -and
    $desktopContent.Contains('[Desktop Action Status]')
)

# Phase 2: App Launcher Script
Write-Host "`n[Phase 2] App Launcher Script Validation" -ForegroundColor White
Assert-Condition "nsclouddrive-app launcher exists" (Test-Path -LiteralPath $appLauncher)
$launcherContent = Get-Content -LiteralPath $appLauncher -Raw
Assert-Condition "Launcher contains bash shebang" ($launcherContent.StartsWith("#!/usr/bin/env bash") -or $launcherContent.StartsWith("#!/bin/bash"))
Assert-Condition "Launcher includes fallback to auto-start UI service" ($launcherContent.Contains("nsclouddrive-ui.service") -and $launcherContent.Contains("test_server"))
Assert-Condition "Launcher specifies standalone window app mode" ($launcherContent.Contains("--app=") -and $launcherContent.Contains("--class="))
Assert-Condition "Launcher specifies window size dimensions" ($launcherContent.Contains("--window-size="))

# Phase 3: Installer Desktop Integration
Write-Host "`n[Phase 3] Linux Installer Desktop Integration" -ForegroundColor White
$installContent = Get-Content -LiteralPath $installer -Raw
Assert-Condition "Installer installs /usr/local/bin/nsclouddrive-app" ($installContent.Contains("/usr/local/bin/nsclouddrive-app"))
Assert-Condition "Installer installs /usr/local/bin/nsclouddrive-gui" ($installContent.Contains("/usr/local/bin/nsclouddrive-gui"))
Assert-Condition "Installer installs nsclouddrive.desktop" ($installContent.Contains("/usr/share/applications/nsclouddrive.desktop"))
Assert-Condition "Installer installs desktop shortcut on ~/Desktop" ($installContent.Contains('USER_DESKTOP_DIR') -and $installContent.Contains('NS Cloud Drive.desktop'))
Assert-Condition "Installer copies official logos to /usr/share/pixmaps & hicolor" ($installContent.Contains("/usr/share/pixmaps") -and $installContent.Contains("hicolor"))
Assert-Condition "Installer preserves the invoking desktop user's HOME when called through sudo" ($installContent.Contains('SUDO_USER') -and $installContent.Contains('NSCD_INSTALLER_USER_CONTEXT'))
Assert-Condition "Installer re-enters through bash when the script is not executable" ($installContent.Contains('NSCD_INSTALLER_USER_CONTEXT=1 bash "$SCRIPT_DIR/install-linux.sh"'))
Assert-Condition "Installer supports musl detection and validates portable PowerShell startup" ($installContent.Contains("ld-musl-") -and $installContent.Contains('PowerShell could not start with this distribution'))
Assert-Condition "Installer writes the real checkout path into the per-user UI service" ($installContent.Contains('systemd_quote_path') -and $installContent.Contains('WorkingDirectory=%s'))

# Phase 3b: Responsive same-provider cloud-copy scanning
$providerWindowContent = Get-Content -LiteralPath $providerWindow -Raw
Assert-Condition "Cloud-copy folder inventory runs in an MTA runspace and returns a scan-only plan" (
    $providerWindowContent.Contains('CreateRunspace()') -and
    $providerWindowContent.Contains('ApartmentState]::MTA') -and
    $providerWindowContent.Contains('BeginInvoke()') -and
    $providerWindowContent.Contains('OnlyScan = $true') -and
    $providerWindowContent.Contains('-ScanPlan') -and
    $providerWindowContent.Contains('setCloudCopySelectionEnabled $false') -and
    $providerWindowContent.Contains('setCloudCopySelectionEnabled $true')
)
$transferManagerContent = Get-Content -LiteralPath $transferManager -Raw
Assert-Condition "Cancelled cloud listings clean up their child rclone process" (
    $transferManagerContent.Contains('CloudDirectoryListingCancellationSource') -and
    $transferManagerContent.Contains('$listingCancellationSource.IsCancellationRequested') -and
    $transferManagerContent.Contains('finally {') -and
    $transferManagerContent.Contains('$proc.Kill()')
)

# Phase 4: CLI Dispatcher Commands (app / gui)
Write-Host "`n[Phase 4] CLI Dispatcher Commands" -ForegroundColor White
$cliContent = Get-Content -LiteralPath $cliFile -Raw
Assert-Condition "CLI contains Invoke-CliApp definition" ($cliContent.Contains("function Invoke-CliApp"))
Assert-Condition "CLI routes 'app' command" ($cliContent.Contains("'app'          { Invoke-CliApp }"))
Assert-Condition "CLI routes 'gui' command" ($cliContent.Contains("'gui'          { Invoke-CliApp }"))

# Phase 5: Web Server Static Asset Serving
Write-Host "`n[Phase 5] Static Asset Serving (/assets/logos/...)" -ForegroundColor White
$pyBin = if (Get-Command 'python' -ErrorAction SilentlyContinue) { 'python' } elseif (Get-Command 'python3' -ErrorAction SilentlyContinue) { 'python3' } else { $null }

if ($pyBin) {
    $testPort = 8996
    $procStart = [System.Diagnostics.ProcessStartInfo]::new()
    $procStart.FileName = $pyBin
    $procStart.Arguments = "`"$appPy`" --port $testPort"
    $procStart.UseShellExecute = $false
    $procStart.CreateNoWindow = $true
    $srvProc = [System.Diagnostics.Process]::Start($procStart)

    Start-Sleep -Milliseconds 1500

    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $logoUrl = "http://127.0.0.1:$testPort/assets/logos/clouddrive.png"
        $resp = Invoke-WebRequest -Uri $logoUrl -UseBasicParsing -TimeoutSec 4
        Assert-Condition "GET /assets/logos/clouddrive.png returns 200 OK" ($resp.StatusCode -eq 200)
        $contentType = @($resp.Headers['Content-Type']) -join ';'
        Assert-Condition "GET /assets/logos/clouddrive.png Content-Type is image/png" ([string]$contentType -like "*image/png*")
        Assert-Condition "GET /assets/logos/clouddrive.png returned valid byte stream" ($resp.RawContentLength -gt 1000)

        # Test TeraBox logo
        $tbUrl = "http://127.0.0.1:$testPort/assets/logos/terabox.png"
        $tbResp = Invoke-WebRequest -Uri $tbUrl -UseBasicParsing -TimeoutSec 4
        Assert-Condition "GET /assets/logos/terabox.png returns 200 OK" ($tbResp.StatusCode -eq 200)

    } finally {
        if ($srvProc -and -not $srvProc.HasExited) {
            $srvProc.Kill()
            $srvProc.WaitForExit(2000)
        }
    }
}

# Summary
Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Total Tests:  $script:TotalTests" -ForegroundColor White
Write-Host "Passed:       $script:PassedTests" -ForegroundColor Green
Write-Host "Failed:       $script:FailedTests" -ForegroundColor $(if ($script:FailedTests -gt 0) { 'Red' } else { 'Green' })

if ($script:FailedTests -gt 0) {
    exit 1
} else {
    exit 0
}
