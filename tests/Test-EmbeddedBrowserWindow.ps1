Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\ui\EmbeddedBrowserWindow.ps1')

Write-Output 'Testing EmbeddedBrowserWindow...'

# 1. Test Edge WebView2 Runtime detection
$runtime = Find-EdgeWebView2Runtime
if (-not $runtime) {
    throw 'Find-EdgeWebView2Runtime failed to locate installed Edge WebView2 Runtime.'
}
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'msedge.dll'))) {
    throw "msedge.dll not found in detected runtime path: $runtime"
}
Write-Output "  [PASS] Edge WebView2 Runtime detected: $runtime"

# 2. Test WebView2 assembly initialization
$init = Initialize-WebView2Assemblies
if (-not $init.IsAvailable) {
    throw "Initialize-WebView2Assemblies reported unavailable: $($init.Error)"
}
if (-not $init.CoreDll -or -not (Test-Path -LiteralPath $init.CoreDll)) {
    throw "CoreDll path invalid: $($init.CoreDll)"
}
if (-not $init.WpfDll -or -not (Test-Path -LiteralPath $init.WpfDll)) {
    throw "WpfDll path invalid: $($init.WpfDll)"
}
Write-Output '  [PASS] WebView2 assemblies loaded and verified'

# 3. Test CreationProperties instantiation and configuration
$props = [Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties]::new()
$props.BrowserExecutableFolder = $runtime
$props.UserDataFolder = Join-Path $env:TEMP 'NSCloudDrive_WV_TestProfile'
if ($props.BrowserExecutableFolder -ne $runtime) {
    throw 'CreationProperties BrowserExecutableFolder mismatch'
}
if (-not $props.UserDataFolder.Contains('NSCloudDrive_WV_TestProfile')) {
    throw 'CreationProperties UserDataFolder mismatch'
}
Write-Output '  [PASS] CoreWebView2CreationProperties configured successfully'

Write-Output 'All EmbeddedBrowserWindow tests passed.'
