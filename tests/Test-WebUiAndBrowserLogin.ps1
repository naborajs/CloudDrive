#!/usr/bin/env pwsh
# ==============================================================================
# Test-WebUiAndBrowserLogin.ps1
# Comprehensive automated verification suite for NS Cloud Drive Linux Web UI
# and CDP browser automated sign-in architecture.
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

Write-Host "`n=== Test Suite: Web UI & Automated Browser Login ===" -ForegroundColor Cyan

$testRoot = $PSScriptRoot
$repoRoot = (Split-Path -Parent $testRoot)
$webDir = Join-Path $repoRoot 'src\web'
$appPy = Join-Path $webDir 'app.py'
$cdpPy = Join-Path $webDir 'cdp_interceptor.py'
$htmlFile = Join-Path $webDir 'index.html'
$cliFile = Join-Path $repoRoot 'src\cli\nsclouddrive.ps1'
$serviceFile = Join-Path $repoRoot 'scripts\systemd\nsclouddrive-ui.service'

# Phase 1: File Existence & Integrity
Write-Host "`n[Phase 1] Asset Existence & Structural Integrity" -ForegroundColor White
Assert-Condition "app.py exists in src/web" (Test-Path -LiteralPath $appPy)
Assert-Condition "cdp_interceptor.py exists in src/web" (Test-Path -LiteralPath $cdpPy)
Assert-Condition "index.html exists in src/web" (Test-Path -LiteralPath $htmlFile)
Assert-Condition "nsclouddrive-ui.service exists in scripts/systemd" (Test-Path -LiteralPath $serviceFile)

# Phase 2: HTML Content & Windows UI Parity
Write-Host "`n[Phase 2] HTML Dashboard Content & Windows Parity" -ForegroundColor White
$htmlContent = Get-Content -LiteralPath $htmlFile -Raw
Assert-Condition "HTML contains NS Cloud Drive brand" ($htmlContent.Contains('NS Cloud Drive'))
Assert-Condition "HTML contains PureBlack palette styling" ($htmlContent.Contains('--bg-window: #000000') -and $htmlContent.Contains('--accent-green: #22c55e'))
Assert-Condition "HTML contains Direct Sign-In modal view" ($htmlContent.Contains('modalTeraBoxFlow') -and $htmlContent.Contains('Launch TeraBox Sign-In'))
Assert-Condition "HTML contains pulse status spinner for auto-capture" ($htmlContent.Contains('pulse-status') -and $htmlContent.Contains('spinner'))
Assert-Condition "HTML contains navigation views (disks, transfers, settings, analytics)" (
    $htmlContent.Contains('view-disks') -and
    $htmlContent.Contains('view-transfers') -and
    $htmlContent.Contains('view-settings') -and
    $htmlContent.Contains('view-analytics')
)

# Phase 3: Python Syntax & Module Validation
Write-Host "`n[Phase 3] Python Syntax Compilation" -ForegroundColor White
$pyBin = if (Get-Command 'python' -ErrorAction SilentlyContinue) { 'python' } elseif (Get-Command 'python3' -ErrorAction SilentlyContinue) { 'python3' } else { $null }

if ($pyBin) {
    $compileApp = & $pyBin -m py_compile $appPy 2>&1
    Assert-Condition "app.py passes py_compile with exit code 0" ($LASTEXITCODE -eq 0) ([string]$compileApp)

    $compileCdp = & $pyBin -m py_compile $cdpPy 2>&1
    Assert-Condition "cdp_interceptor.py passes py_compile with exit code 0" ($LASTEXITCODE -eq 0) ([string]$compileCdp)
} else {
    Write-Host "  [SKIP] Python binary not found in path for syntax check." -ForegroundColor Yellow
}

# Phase 4: Local Server HTTP Endpoints
Write-Host "`n[Phase 4] Local Server HTTP API Verification" -ForegroundColor White
if ($pyBin) {
    $testPort = 8995
    $procStart = [System.Diagnostics.ProcessStartInfo]::new()
    $procStart.FileName = $pyBin
    $procStart.Arguments = "`"$appPy`" --port $testPort"
    $procStart.UseShellExecute = $false
    $procStart.CreateNoWindow = $true
    $srvProc = [System.Diagnostics.Process]::Start($procStart)

    Start-Sleep -Milliseconds 1500

    try {
        # Test GET /
        $respHtml = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/" -Method Get -TimeoutSec 4
        Assert-Condition "GET / returns 200 with HTML title" ($respHtml -like "*<title>NS Cloud Drive</title>*")

        # Test GET /api/state
        $respState = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/state" -Method Get -TimeoutSec 4
        Assert-Condition "GET /api/state returns JSON with service field" ($null -ne $respState.service)
        Assert-Condition "GET /api/state returns JSON with accounts list" ($null -ne $respState.accounts)
        Assert-Condition "GET /api/state returns JSON with mounts list" ($null -ne $respState.mounts)
        Assert-Condition "GET /api/state returns JSON with queue list" ($null -ne $respState.queue)

        # Test GET /api/login/browser/status
        $respLoginSt = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/login/browser/status" -Method Get -TimeoutSec 4
        Assert-Condition "GET /api/login/browser/status returns idle state" ($respLoginSt.state -eq 'idle')

        # Test POST /api/action with invalid action
        $badReq = $false
        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/api/action" -Method Post -Body '{"action":"invalid_xyz"}' -ContentType 'application/json' -TimeoutSec 4
        } catch {
            $badReq = $true
        }
        Assert-Condition "POST /api/action with invalid action correctly returns error" ($badReq)

    } finally {
        if ($srvProc -and -not $srvProc.HasExited) {
            $srvProc.Kill()
            $srvProc.WaitForExit(2000)
        }
    }
}

# Phase 5: CLI Dispatcher UI & Browser Support
Write-Host "`n[Phase 5] CLI Command Dispatcher Integration" -ForegroundColor White
$cliContent = Get-Content -LiteralPath $cliFile -Raw
Assert-Condition "CLI contains Invoke-CliUi definition" ($cliContent.Contains('function Invoke-CliUi'))
Assert-Condition "CLI dispatcher routes 'ui' action" ($cliContent.Contains("'ui'           { Invoke-CliUi -SubAction `$Target }"))
Assert-Condition "CLI contains -Browser parameter" ($cliContent.Contains('[switch]$Browser'))
Assert-Condition "CLI help document contains ui examples" ($cliContent.Contains('nsclouddrive ui'))

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
