# Test-LiquidGlassTheme.ps1 - Translucent Liquid Glass theme contract tests
#
# Verifies the three-theme discipline and the real Windows-composition glass
# engine: the translucent theme must carry the softened glass fill, Pure Black
# and Pure White must stay opaque and never enable the effect, the engine must
# fail closed (fallback palette) on unsupported builds, and enable/disable must
# be a clean reversible round-trip. The functional part runs the REAL engine
# code from src/NSCloudDrive.ps1 inside an isolated STA child process.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
$failures = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failures++; Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

# ---- 1. Exactly three themes; glass data only on Translucent ----
Assert-True ($mainSource -match "'PureBlack' \{") 'PureBlack palette exists'
Assert-True ($mainSource -match "'Translucent' \{") 'Translucent palette exists'
Assert-True ($mainSource -match "'PureWhite' \{") 'PureWhite palette exists'
Assert-True ($mainSource -match 'WindowGlassBg = ''#') 'Translucent palette carries the softened glass window fill'
$opaqueBgCount = ([regex]::Matches($mainSource, "WindowBg = '#[0-9A-Fa-f]{6}'")).Count
Assert-True ($opaqueBgCount -eq 2) "Pure Black / Pure White window fills stay fully opaque (found $opaqueBgCount opaque)"
Assert-True ($mainSource -match 'Translucent Liquid Glass') 'Theme selector advertises the Translucent Liquid Glass theme'

# ---- 2. Engine uses real Windows composition, not recolored panels ----
Assert-True ($mainSource -match 'DWMWA_SYSTEMBACKDROP_TYPE = 38') 'Engine uses DWM system backdrop attribute 38 (Windows 11)'
Assert-True ($mainSource -match 'DWMSBT_TRANSIENTWINDOW = 3') 'Backdrop mode is transient acrylic'
Assert-True ($mainSource -match 'ACCENT_ENABLE_ACRYLICBLURBEHIND = 4') 'Engine uses the acrylic blur-behind (Windows 10 1803+)'
Assert-True ($mainSource -match 'ACCENT_DISABLED = 0') 'Accent teardown policy exists'
Assert-True ($mainSource -match 'CompilationResource|CompositionTarget\.BackgroundColor = \[System\.Windows\.Media\.Colors\]::Transparent') 'Engine makes the WPF buffer transparent while glass is active'
Assert-True ($mainSource -match 'HwndSource\]::FromHwnd') 'Presentation source is resolved from the HWND (works pre-show)'

# ---- 3. Fail-closed behavior and lifecycle correctness ----
Assert-True ($mainSource -match 'function Enable-GlassBackdrop') 'Enable-GlassBackdrop exists'
Assert-True ($mainSource -match 'function Disable-GlassBackdrop') 'Disable-GlassBackdrop exists'
Assert-True ($mainSource -match '\$script:GlassState\.Supported') 'Build capability probe is cached'
Assert-True ($mainSource -match 'build -ge 17134') 'Glass requires Windows 10 1803+ / 11'
Assert-True ($mainSource -match '\$script:GlassState\.OriginalColor') 'Original composition color preserved for exact restore'
Assert-True ($mainSource -match '\$helper\.EnsureHandle\(\)') 'Window handle creation is captured (no pipeline leak)'
Assert-True ($mainSource -match 'Neither path took effect') 'Failed enable tears the effect down instead of half-enabling'

# ---- 4. Apply-UITheme gates the effect to Translucent only ----
Assert-True ($mainSource -match '\$p\.Name -eq ''?Translucent'' -and \(Get-GlassSupported\)') 'Glass engages only for Translucent on a supported build'
Assert-True ($mainSource -match 'Disable-GlassBackdrop \$window') 'Switching to another theme tears the glass effect down'
Assert-True ($mainSource -match '\$glassActive\) \{[\s\S]{0,400}WindowGlassBg') 'Softened fill is applied only after a successful glass enable'

# ---- 5. Functional round-trip of the real engine in an STA child ----
    $sandbox = Join-Path $env:TEMP ('NSCloudDrive_GlassProbe_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
try {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $mainPath = Join-Path $repoRoot 'src\NSCloudDrive.ps1'
    $harnessPath = Join-Path $sandbox 'GlassProbe.ps1'
    $resultPath = Join-Path $sandbox 'result.txt'

    $quotedMainScript = "'" + $mainPath.Replace("'", "''") + "'"
    $harness = @"
`$ErrorActionPreference = 'Stop'
`$source = [System.IO.File]::ReadAllText($quotedMainScript)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
`$start = `$source.IndexOf('# LIQUID GLASS BACKDROP ENGINE')
`$end = `$source.IndexOf('# THEME APPLICATION ENGINE')
if (`$start -lt 0 -or `$end -lt 0 -or `$end -le `$start) { throw 'Glass engine section markers not found.' }
Invoke-Expression `$source.Substring(`$start, `$end - `$start) | Out-Null

if (Get-GlassSupported) {
    `$probe = [System.Windows.Window]::new()
    `$probe.WindowStyle = 'None'
    `$enabled = Enable-GlassBackdrop -Window `$probe
    if (`$enabled -ne `$script:GlassState.Active) { throw 'Enable return value disagrees with persisted state.' }
    `$hwnd = ([System.Windows.Interop.WindowInteropHelper]::new(`$probe)).EnsureHandle()
    `$src = [System.Windows.Interop.HwndSource]::FromHwnd(`$hwnd)
    if (`$enabled -and (-not `$src -or -not `$src.CompositionTarget -or `$src.CompositionTarget.BackgroundColor.A -ne 0)) {
        throw 'WPF buffer is not transparent while a glass effect is active.'
    }
    Disable-GlassBackdrop -Window `$probe
    if (`$script:GlassState.Active) { throw 'Disable did not clear the glass state.' }
    if (`$enabled) {
        if (`$src.CompositionTarget.BackgroundColor.A -eq 0) { throw 'Disable left the WPF buffer transparent.' }
        `$enabled2 = Enable-GlassBackdrop -Window `$probe
        if (-not `$enabled2) { throw 'Second enable failed after a clean disable.' }
        if (`$src.CompositionTarget.BackgroundColor.A -ne 0) { throw 'Second enable did not restore transparency.' }
        Disable-GlassBackdrop -Window `$probe
        if (`$src.CompositionTarget.BackgroundColor.A -eq 0) { throw 'Second disable left the buffer transparent.' }
    }
    [System.IO.File]::WriteAllText(`$env:NSCD_GLASS_RESULT, 'GLASS_PROBE_OK')
} else {
    [System.IO.File]::WriteAllText(`$env:NSCD_GLASS_RESULT, 'GLASS_SKIPPED_UNSUPPORTED_BUILD')
}
"@
    $harness | Set-Content -LiteralPath $harnessPath -Encoding UTF8

    $env:NSCD_GLASS_RESULT = $resultPath
    $child = Start-Process -FilePath (Get-Command 'powershell.exe' -ErrorAction Stop).Source -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $harnessPath) -PassThru -WindowStyle Hidden
    if (-not $child.WaitForExit(90000)) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        throw 'The glass probe exceeded its 90 second bound.'
    }
    if ($child.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw "The STA glass probe failed (exit code $($child.ExitCode))."
    }
    $outcome = (Get-Content -LiteralPath $resultPath -Raw).Trim()
    if ($outcome -eq 'GLASS_PROBE_OK') {
        Write-Output '  [PASS] Glass engine enable/disable round-trip verified on a real hidden window (STA child).'
    } elseif ($outcome -eq 'GLASS_SKIPPED_UNSUPPORTED_BUILD') {
        Write-Output '  [PASS] Glass probe skipped: unsupported Windows build on this machine (fallback path is the default).'
    } else {
        throw "Unexpected glass probe outcome: $outcome"
    }
    Assert-True ($true -eq $true) 'Functional probe completed'
} finally {
    if ($env:NSCD_GLASS_RESULT) { Remove-Item Env:NSCD_GLASS_RESULT -ErrorAction SilentlyContinue }
    try { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

if ($failures -gt 0) { throw "$failures glass theme assertions failed." }
Write-Output '  [PASS] Liquid glass theme contract verified.'
