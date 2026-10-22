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

# 4. Test TeraBox host validation
$validHosts = @('terabox.com', 'www.terabox.com', 'dm.terabox.com', 'www.1024tera.com', 'terabox.app', '1024terabox.com', 'freeterabox.com')
foreach ($vh in $validHosts) {
    if (-not (Test-TeraBoxHost $vh)) {
        throw "Expected host '$vh' to be recognized as valid TeraBox host"
    }
}

$invalidHosts = @('google.com', 'accounts.google.com', 'not-terabox.com', 'terabox.com.attacker.com', '', '   ')
foreach ($ih in $invalidHosts) {
    if (Test-TeraBoxHost $ih) {
        throw "Expected host '$ih' to be rejected as invalid TeraBox host"
    }
}
Write-Output '  [PASS] TeraBox host validation verified'

# 5. Test Wait-WpfTask non-blocking dispatcher task execution
$completedTask = [System.Threading.Tasks.Task]::FromResult("done")
if (-not (Wait-WpfTask -Task $completedTask -TimeoutMs 1000)) {
    throw 'Expected Wait-WpfTask to immediately return true for completed task'
}

$asyncTask = [System.Threading.Tasks.Task]::Delay(150)
$waitResult = Wait-WpfTask -Task $asyncTask -TimeoutMs 2000
if (-not $waitResult) {
    throw 'Expected Wait-WpfTask to pump dispatcher and complete async delay task'
}

$infiniteTask = [System.Threading.Tasks.TaskCompletionSource[bool]]::new().Task
$timeoutResult = Wait-WpfTask -Task $infiniteTask -TimeoutMs 200
if ($timeoutResult) {
    throw 'Expected Wait-WpfTask to return false on timeout for incomplete task'
}
Write-Output '  [PASS] Wait-WpfTask non-blocking dispatcher pump verified'

Write-Output 'All EmbeddedBrowserWindow tests passed.'
