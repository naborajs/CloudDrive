<#
.SYNOPSIS
    Packages NS Cloud Drive v1.0.0 for GitHub Release distribution.
.DESCRIPTION
    Creates a clean, production-ready release directory and zip archive containing:
      - NSCloudDrive.exe (native 64-bit Windows executable)
      - NSCloudDrive.exe.sha256
      - README.md
      - LICENSE
      - src/
      - assets/
      - docs/
#>
param(
    [string]$Version = '1.0.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$distDir = Join-Path $repoRoot 'dist'
$pkgName = "NSCloudDrive-v$Version-Windows-x64"
$stageDir = Join-Path $distDir $pkgName
$zipFile = Join-Path $distDir "$pkgName.zip"
$exePath = Join-Path $repoRoot 'NSCloudDrive.exe'

Write-Host "=== NS Cloud Drive Release Packager ===" -ForegroundColor Cyan
Write-Host "Package: $pkgName"
Write-Host "Output:  $zipFile"

# 1. Verify executable exists
if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    Write-Host "Building executable first..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'Build-Executable.ps1')
}

# 2. Prepare staging directory
if (Test-Path -LiteralPath $distDir) {
    Remove-Item -LiteralPath $distDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

# 3. Copy files to staging
Write-Host "Staging files..." -ForegroundColor Green
Copy-Item -LiteralPath $exePath -Destination $stageDir
Copy-Item -LiteralPath (Join-Path $repoRoot 'NSCloudDrive.exe.sha256') -Destination $stageDir
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $stageDir
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $stageDir
if (Test-Path -LiteralPath (Join-Path $repoRoot 'CONTRIBUTING.md')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'CONTRIBUTING.md') -Destination $stageDir
}
if (Test-Path -LiteralPath (Join-Path $repoRoot 'NSCloudDrive.cmd')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'NSCloudDrive.cmd') -Destination $stageDir
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'src') -Destination $stageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'assets') -Destination $stageDir -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs') -Destination $stageDir -Recurse
if (Test-Path -LiteralPath (Join-Path $repoRoot 'lib')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'lib') -Destination $stageDir -Recurse
}
if (Test-Path -LiteralPath (Join-Path $repoRoot 'config')) {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'config') -Destination $stageDir -Recurse
}

# 4. Create ZIP archive
Write-Host "Creating zip archive: $zipFile..." -ForegroundColor Green
if (Test-Path -LiteralPath $zipFile) {
    Remove-Item -LiteralPath $zipFile -Force
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $zipFile, [System.IO.Compression.CompressionLevel]::Optimal, $false)

# 5. Compute SHA-256 of the release archive
$zipHash = (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash
$hashFile = Join-Path $distDir "$pkgName.zip.sha256"
Set-Content -LiteralPath $hashFile -Value "$zipHash *$pkgName.zip`n" -Encoding UTF8

Write-Host "`n=== RELEASE PACKAGE READY ===" -ForegroundColor Cyan
Write-Host "Archive:  $zipFile"
Write-Host "Size:     $([Math]::Round((Get-Item -LiteralPath $zipFile).Length / 1MB, 2)) MB"
Write-Host "SHA-256:  $zipHash"
Write-Host "Checksum: $hashFile"
