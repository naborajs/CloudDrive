<#
.SYNOPSIS
    Packages NS Cloud Drive v2.0.0 for GitHub Release distribution (Windows & Linux).
.DESCRIPTION
    Creates clean, production-ready release distributions:
      1. Windows: NSCloudDrive-v2.0.0-Windows-x64.zip (+ SHA256 checksum)
         - NSCloudDrive.exe (native 64-bit Windows executable launcher)
         - NSCloudDrive.exe.sha256
         - src/, assets/, docs/, config/, lib/, README.md, LICENSE
      2. Linux VPS: NSCloudDrive-v2.0.0-Linux-x64.tar.gz (+ SHA256 checksum)
         - scripts/nsclouddrive (bash launcher)
         - scripts/install-linux.sh (one-click Ubuntu/Debian installer)
         - scripts/systemd/nsclouddrive.service (systemd unit file)
         - src/ (cli, models, services, providers)
         - assets/, docs/, config/, README.md, LICENSE
#>
param(
    [string]$Version = '2.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$distDir = Join-Path $repoRoot 'dist'

$winPkgName = "NSCloudDrive-v$Version-Windows-x64"
$winStageDir = Join-Path $distDir $winPkgName
$winZipFile = Join-Path $distDir "$winPkgName.zip"
$exePath = Join-Path $repoRoot 'NSCloudDrive.exe'

$linuxPkgName = "NSCloudDrive-v$Version-Linux-x64"
$linuxStageDir = Join-Path $distDir $linuxPkgName
$linuxTarFile = Join-Path $distDir "$linuxPkgName.tar.gz"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       NS Cloud Drive Unified Release Packager            " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Version: $Version"
Write-Host "Targets: Windows x64 (.zip) & Linux x64 (.tar.gz)" -ForegroundColor Yellow

# Clean dist directory
if (Test-Path -LiteralPath $distDir) {
    Remove-Item -LiteralPath $distDir -Recurse -Force
}
New-Item -ItemType Directory -Path $winStageDir -Force | Out-Null
New-Item -ItemType Directory -Path $linuxStageDir -Force | Out-Null

# ------------------------------------------------------------------------------
# 1. WINDOWS PACKAGE
# ------------------------------------------------------------------------------
Write-Host "`n[1/2] Building Windows Release Package ($winPkgName)..." -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    Write-Host "Building Windows executable first..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'Build-Executable.ps1')
}

Copy-Item -LiteralPath $exePath -Destination $winStageDir
Copy-Item -LiteralPath (Join-Path $repoRoot 'NSCloudDrive.exe.sha256') -Destination $winStageDir
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $winStageDir
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $winStageDir
if (Test-Path -LiteralPath (Join-Path $repoRoot 'CONTRIBUTING.md')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'CONTRIBUTING.md') -Destination $winStageDir
}
if (Test-Path -LiteralPath (Join-Path $repoRoot 'NSCloudDrive.cmd')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'NSCloudDrive.cmd') -Destination $winStageDir
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'src') -Destination $winStageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts') -Destination $winStageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets') -Destination $winStageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs') -Destination $winStageDir -Recurse
if (Test-Path -LiteralPath (Join-Path $repoRoot 'lib')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'lib') -Destination $winStageDir -Recurse
}
if (Test-Path -LiteralPath (Join-Path $repoRoot 'config')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'config') -Destination $winStageDir -Recurse
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($winStageDir, $winZipFile, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$winZipHash = (Get-FileHash -LiteralPath $winZipFile -Algorithm SHA256).Hash
Set-Content -LiteralPath (Join-Path $distDir "$winPkgName.zip.sha256") -Value "$winZipHash *$winPkgName.zip`n" -Encoding UTF8
Write-Host "  [OK] Windows archive created: $winZipFile" -ForegroundColor Green
Write-Host "       Size: $([Math]::Round((Get-Item -LiteralPath $winZipFile).Length / 1MB, 2)) MB | SHA-256: $winZipHash"

# ------------------------------------------------------------------------------
# 2. LINUX VPS PACKAGE
# ------------------------------------------------------------------------------
Write-Host "`n[2/2] Building Linux VPS Package ($linuxPkgName)..." -ForegroundColor Cyan

Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $linuxStageDir
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $linuxStageDir
if (Test-Path -LiteralPath (Join-Path $repoRoot 'CONTRIBUTING.md')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'CONTRIBUTING.md') -Destination $linuxStageDir
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'src') -Destination $linuxStageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts') -Destination $linuxStageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets') -Destination $linuxStageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs') -Destination $linuxStageDir -Recurse
if (Test-Path -LiteralPath (Join-Path $repoRoot 'config')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'config') -Destination $linuxStageDir -Recurse
}

# Create tar.gz using native tar utility
$tarCmd = Get-Command 'tar.exe', 'tar' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($tarCmd) {
    Push-Location $distDir
    try {
        & $tarCmd.Source -czf $linuxTarFile $linuxPkgName
    } finally {
        Pop-Location
    }
    $linuxTarHash = (Get-FileHash -LiteralPath $linuxTarFile -Algorithm SHA256).Hash
    Set-Content -LiteralPath (Join-Path $distDir "$linuxPkgName.tar.gz.sha256") -Value "$linuxTarHash *$linuxPkgName.tar.gz`n" -Encoding UTF8
    Write-Host "  [OK] Linux archive created: $linuxTarFile" -ForegroundColor Green
    Write-Host "       Size: $([Math]::Round((Get-Item -LiteralPath $linuxTarFile).Length / 1MB, 2)) MB | SHA-256: $linuxTarHash"
} else {
    Write-Host "  [WARN] tar utility not found; created directory $linuxStageDir for manual tarball generation." -ForegroundColor Yellow
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "         UNIFIED RELEASE DISTRIBUTION READY               " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Windows Release: $winZipFile" -ForegroundColor White
Write-Host "Linux Release:   $linuxTarFile" -ForegroundColor White
Write-Host "Dist Directory:  $distDir" -ForegroundColor White
