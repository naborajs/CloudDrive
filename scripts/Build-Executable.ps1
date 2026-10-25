<#
.SYNOPSIS
    Builds the native 64-bit Windows executable launcher for NS Cloud Drive.

.DESCRIPTION
    Compiles NSCloudDrive.exe using the built-in Microsoft .NET Framework 4.8 C# compiler (csc.exe).
    The resulting executable:
      - Runs as a native Windows GUI application (no flashing black console window).
      - Embeds the official high-resolution multi-size NS Cloud Drive icon.
      - Includes DPI awareness manifest (PerMonitorV2) and Windows 10/11 compatibility.
      - Handles single-instance detection and window restoration automatically.
      - Seamlessly hosts and monitors the PowerShell WPF application.

.PARAMETER CreateDesktopShortcut
    Creates a shortcut on the user's Desktop pointing to NSCloudDrive.exe.

.PARAMETER CreateStartMenuShortcut
    Creates a shortcut in the user's Start Menu Programs folder.

.PARAMETER UpdateStartupRegistry
    Updates the Windows Startup registry (HKCU\...\Run) to execute NSCloudDrive.exe on login.
#>
param(
    [switch]$CreateDesktopShortcut,
    [switch]$CreateStartMenuShortcut,
    [switch]$UpdateStartupRegistry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$launcherDir = Join-Path $repoRoot 'src\launcher'
$outputExe = Join-Path $repoRoot 'NSCloudDrive.exe'
$iconPath = Join-Path $repoRoot 'assets\logos\clouddrive.ico'
$pngLogo = Join-Path $repoRoot 'assets\logos\clouddrive.png'
$manifestPath = Join-Path $launcherDir 'app.manifest'
$programCs = Join-Path $launcherDir 'Program.cs'
$assemblyCs = Join-Path $launcherDir 'AssemblyInfo.cs'

Write-Host "=== NS Cloud Drive Executable Builder ===" -ForegroundColor Cyan
Write-Host "Target output: $outputExe"

# 1. Ensure high-resolution compliant .ico exists
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    if (Test-Path -LiteralPath $pngLogo -PathType Leaf) {
        Write-Host "Generating multi-resolution icon from $pngLogo..." -ForegroundColor Yellow
        $genScript = Join-Path $PSScriptRoot 'Generate-Icon.py'
        if (Test-Path -LiteralPath $genScript) {
            python $genScript
        }
    } else {
        Write-Warning "Source logo not found. Icon will be skipped."
        $iconPath = $null
    }
}

# 2. Find csc.exe compiler
$cscPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $cscPath -PathType Leaf)) {
    # Check 32-bit fallback
    $cscPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $cscPath -PathType Leaf)) {
    throw "C# compiler (csc.exe) not found at expected .NET Framework location."
}

Write-Host "Using compiler: $cscPath"

# 3. Assemble compiler arguments
$compilerArgs = @(
    '/nologo',
    '/target:winexe',
    '/platform:x64',
    '/optimize+',
    '/highentropyva+',
    "/out:`"$outputExe`"",
    '/r:System.dll',
    '/r:System.Core.dll',
    '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll'
)

$smaPath = Join-Path $env:SystemRoot 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll'
if (-not (Test-Path -LiteralPath $smaPath -PathType Leaf)) {
    $smaPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\System.Management.Automation.dll'
}
if (Test-Path -LiteralPath $smaPath -PathType Leaf) {
    $compilerArgs += "/r:`"$smaPath`""
}

if ($iconPath -and (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    $compilerArgs += "/win32icon:`"$iconPath`""
}
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $compilerArgs += "/win32manifest:`"$manifestPath`""
}

$compilerArgs += "`"$programCs`""
$compilerArgs += "`"$assemblyCs`""

# Handle locked executable if currently running
if (Test-Path -LiteralPath $outputExe -PathType Leaf) {
    try {
        $testStream = [System.IO.File]::Open($outputExe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $testStream.Close()
        $testStream.Dispose()
    } catch {
        $oldBackup = "$outputExe.old"
        if (Test-Path -LiteralPath $oldBackup) { Remove-Item -LiteralPath $oldBackup -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $outputExe -Destination $oldBackup -Force
        Write-Host "Existing running executable moved to $oldBackup for replacement." -ForegroundColor Yellow
    }
}

# 4. Compile
Write-Host "Compiling NSCloudDrive.exe..." -ForegroundColor Cyan
$pinfo = New-Object System.Diagnostics.ProcessStartInfo
$pinfo.FileName = $cscPath
$pinfo.Arguments = ($compilerArgs -join ' ')
$pinfo.RedirectStandardOutput = $true
$pinfo.RedirectStandardError = $true
$pinfo.UseShellExecute = $false
$pinfo.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::Start($pinfo)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

if ($proc.ExitCode -ne 0) {
    Write-Error "Compilation failed with exit code $($proc.ExitCode):`n$stdout`n$stderr"
    return $false
}

if (-not (Test-Path -LiteralPath $outputExe -PathType Leaf)) {
    throw "Compilation completed but $outputExe was not produced."
}

$fileInfo = Get-Item -LiteralPath $outputExe
Write-Host "Compilation SUCCESSFUL!" -ForegroundColor Green
Write-Host "Output: $($fileInfo.FullName) ($([math]::Round($fileInfo.Length / 1KB, 1)) KB)"

# Verify file metadata
$versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($outputExe)
Write-Host "File Description: $($versionInfo.FileDescription)"
Write-Host "Product Name:     $($versionInfo.ProductName)"
Write-Host "Company Name:     $($versionInfo.CompanyName)"
Write-Host "Product Version:  $($versionInfo.ProductVersion)"

# 5. Optional: Desktop Shortcut
if ($CreateDesktopShortcut) {
    try {
        $desktopDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
        $shortcutPath = Join-Path $desktopDir 'NS Cloud Drive.lnk'
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($shortcutPath)
        $sc.TargetPath = $outputExe
        $sc.WorkingDirectory = $repoRoot
        $sc.Description = 'NS Cloud Drive Virtual Filesystem Manager'
        if ($iconPath -and (Test-Path -LiteralPath $iconPath)) {
            $sc.IconLocation = "$outputExe,0"
        }
        $sc.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sc) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        Write-Host "Desktop shortcut created: $shortcutPath" -ForegroundColor Green
    } catch {
        Write-Warning "Could not create desktop shortcut: $($_.Exception.Message)"
    }
}

# 6. Optional: Start Menu Shortcut
if ($CreateStartMenuShortcut) {
    try {
        $programsDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
        $shortcutPath = Join-Path $programsDir 'NS Cloud Drive.lnk'
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($shortcutPath)
        $sc.TargetPath = $outputExe
        $sc.WorkingDirectory = $repoRoot
        $sc.Description = 'NS Cloud Drive Virtual Filesystem Manager'
        if ($iconPath -and (Test-Path -LiteralPath $iconPath)) {
            $sc.IconLocation = "$outputExe,0"
        }
        $sc.Save()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sc) | Out-Null
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) | Out-Null
        Write-Host "Start Menu shortcut created: $shortcutPath" -ForegroundColor Green
    } catch {
        Write-Warning "Could not create Start Menu shortcut: $($_.Exception.Message)"
    }
}

# 7. Optional: Update Windows Startup Registry
if ($UpdateStartupRegistry) {
    try {
        . (Join-Path $repoRoot 'src\services\SettingsManager.ps1')
        $settings = Get-NSCloudDriveSettings
        if ($settings -and $settings.AutoStartWithWindows) {
            Set-WindowsStartupEnabled -Enable $true
            Write-Host "Windows Startup registry updated to point to NSCloudDrive.exe." -ForegroundColor Green
        }
    } catch {
        Write-Warning "Could not update startup registry: $($_.Exception.Message)"
    }
}

# 8. Flush Windows Shell Icon Cache
try {
    Add-Type -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);' -Name 'ShellNotify' -Namespace 'NSCloudDrive' -ErrorAction SilentlyContinue
    [NSCloudDrive.ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero) # SHCNE_ASSOCCHANGED
    Write-Host "Windows Shell icon cache refreshed." -ForegroundColor Green
} catch { }

Write-Host "Done! NSCloudDrive.exe is ready for use." -ForegroundColor Cyan
return $true
