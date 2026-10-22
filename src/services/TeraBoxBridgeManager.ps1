# TeraBoxBridgeManager.ps1 - Manages the local CPX WebDAV bridge daemon for TeraBox
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

$script:BridgeEntropy = [System.Text.Encoding]::UTF8.GetBytes('CloudPlayX.v1.secret')
$script:DefaultBridgePort = 19191
$script:RunningBridgeProcess = $null

function Find-CpxBinary {
    [CmdletBinding()]
    param()

    # 1. Pinned local app tools directory
    $localTool = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\tools\cpx\cpx.exe'
    if (Test-Path -LiteralPath $localTool) {
        return $localTool
    }

    # 2. Extracted downloads package
    $downloadPath = 'C:\Users\Naboraj_sarkar\Downloads\CloudPlayX_extracted\CloudPlayX\cpx.exe'
    if (Test-Path -LiteralPath $downloadPath) {
        return $downloadPath
    }

    # 3. Reference project bin / publish folder
    $refCli = 'D:\Projects\CloudPlayX\src\CloudPlayX.Cli\bin\Debug\net10.0-windows\cpx.exe'
    if (Test-Path -LiteralPath $refCli) {
        return $refCli
    }

    # 4. PATH lookup
    $cmd = Get-Command 'cpx.exe' -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    return $null
}

function Get-TeraBoxBridgeHomeDirectory {
    [CmdletBinding()]
    param()

    $homeDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\terabox-bridge'
    if (-not (Test-Path -LiteralPath $homeDir)) {
        [void](New-Item -ItemType Directory -Path $homeDir -Force)
    }
    return $homeDir
}

function Initialize-TeraBoxBridgeHome {
    [CmdletBinding()]
    param(
        [string]$HomeDirectory = $null
    )

    $dir = if ($HomeDirectory) { $HomeDirectory } else { Get-TeraBoxBridgeHomeDirectory }
    $cacheDir = Join-Path $dir 'cache'
    $logDir = Join-Path $dir 'logs'

    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    if (-not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
    if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }

    $settingsPath = Join-Path $dir 'settings.json'
    $settings = [ordered]@{
        TeraBox = [ordered]@{
            Transport = 'web'
            WebRoot = '/'
        }
        Cache = [ordered]@{
            CacheRoot = $cacheDir
            MinFreeSpaceBytes = 536870912
        }
    }

    $json = ConvertTo-Json -InputObject $settings -Depth 5
    [System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.Encoding]::UTF8)

    return $dir
}

function Set-TeraBoxBridgeSecrets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Session,
        [string]$HomeDirectory = $null,
        [string]$BridgePassword = $null
    )

    $dir = if ($HomeDirectory) { $HomeDirectory } else { Get-TeraBoxBridgeHomeDirectory }
    [void](Initialize-TeraBoxBridgeHome -HomeDirectory $dir)

    # Generate or reuse bridge password
    $secret = if ($BridgePassword) {
        $BridgePassword
    } else {
        $tokenBytes = [byte[]]::new(18)
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
        'cpx_' + [Convert]::ToBase64String($tokenBytes).Replace('+', '').Replace('/', '').Replace('=', '')
    }

    # Encrypt bridge secret with DPAPI and CloudPlayX entropy
    $secretBytes = [System.Text.Encoding]::UTF8.GetBytes($secret)
    $encSecret = [System.Security.Cryptography.ProtectedData]::Protect(
        $secretBytes,
        $script:BridgeEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $keyFile = Join-Path $dir 'terabox.bridge.key'
    [System.IO.File]::WriteAllBytes($keyFile, $encSecret)

    # Format web-session payload conforming to CloudPlayX TeraBoxWebSession record
    $baseUrl = if ($Session.ContainsKey('BaseUrl') -and $Session.BaseUrl) { [string]$Session.BaseUrl } else { 'https://www.terabox.com' }
    $cookie = if ($Session.ContainsKey('Secret') -and $Session.Secret) { [string]$Session.Secret } else { '' }
    $ua = if ($Session.ContainsKey('UserAgent') -and $Session.UserAgent) { [string]$Session.UserAgent } else { 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
    $jsToken = if ($Session.ContainsKey('JsToken') -and $Session.JsToken) { [string]$Session.JsToken } else { $null }

    $webSessionObj = [ordered]@{
        BaseUrl = $baseUrl
        Cookie = $cookie
        UserAgent = $ua
        JsToken = $jsToken
        SignedIn = [DateTime]::UtcNow.ToString('o')
    }

    $wsJson = ConvertTo-Json -InputObject $webSessionObj -Depth 5
    $wsBytes = [System.Text.Encoding]::UTF8.GetBytes($wsJson)
    $encWs = [System.Security.Cryptography.ProtectedData]::Protect(
        $wsBytes,
        $script:BridgeEntropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    $sessionFile = Join-Path $dir 'terabox.websession.key'
    [System.IO.File]::WriteAllBytes($sessionFile, $encWs)

    return $secret
}

function Test-TeraBoxBridgeHealth {
    [CmdletBinding()]
    param(
        [int]$Port = 19191,
        [string]$BridgePassword = $null,
        [int]$TimeoutSec = 3
    )

    try {
        $headers = @{}
        if ($BridgePassword) {
            $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("cpx:$BridgePassword"))
            $headers['Authorization'] = "Basic $auth"
        }
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/.cloudplayx/health" -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Start-TeraBoxBridge {
    [CmdletBinding()]
    param(
        [hashtable]$SessionOverride = $null,
        [int]$Port = 19191,
        [int]$WaitTimeoutSec = 10
    )

    $cpx = Find-CpxBinary
    if (-not $cpx) {
        throw 'CPX WebDAV bridge daemon executable (cpx.exe) was not found.'
    }

    $session = if ($SessionOverride) {
        $SessionOverride
    } else {
        . (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')
        Get-TeraBoxStoredSession
    }

    if (-not $session -or -not $session.Secret) {
        throw 'No valid TeraBox session found. Please sign in to TeraBox first.'
    }

    $homeDir = Get-TeraBoxBridgeHomeDirectory
    $secret = Set-TeraBoxBridgeSecrets -Session $session -HomeDirectory $homeDir

    # Check if already healthy
    if (Test-TeraBoxBridgeHealth -Port $Port -BridgePassword $secret -TimeoutSec 1) {
        return [ordered]@{
            Success = $true
            Port = $Port
            Url = "http://127.0.0.1:$Port/"
            User = 'cpx'
            Password = $secret
            ProcessId = if ($script:RunningBridgeProcess -and -not $script:RunningBridgeProcess.HasExited) { $script:RunningBridgeProcess.Id } else { $null }
        }
    }

    # Start cpx.exe background bridge process
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $cpx
    $psi.Arguments = "terabox-bridge --port $Port --home `"$homeDir`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:RunningBridgeProcess = $proc

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    while ($sw.Elapsed.TotalSeconds -lt $WaitTimeoutSec) {
        if ($proc.HasExited) {
            throw "TeraBox WebDAV bridge process exited prematurely with code $($proc.ExitCode)."
        }
        if (Test-TeraBoxBridgeHealth -Port $Port -BridgePassword $secret -TimeoutSec 1) {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $ready) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        throw "Timed out waiting for TeraBox WebDAV bridge to become ready on port $Port."
    }

    return [ordered]@{
        Success = $true
        Port = $Port
        Url = "http://127.0.0.1:$Port/"
        User = 'cpx'
        Password = $secret
        ProcessId = $proc.Id
    }
}

function Stop-TeraBoxBridge {
    [CmdletBinding()]
    param(
        [int]$Port = 19191,
        [string]$BridgePassword = $null
    )

    # 1. Attempt graceful shutdown via POST /.cloudplayx/shutdown
    try {
        $headers = @{}
        if ($BridgePassword) {
            $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("cpx:$BridgePassword"))
            $headers['Authorization'] = "Basic $auth"
        }
        [void](Invoke-WebRequest -Uri "http://127.0.0.1:$Port/.cloudplayx/shutdown" -Method Post -Headers $headers -TimeoutSec 2 -UseBasicParsing -ErrorAction SilentlyContinue)
    } catch { }

    # 2. Terminate tracked process if still alive
    if ($script:RunningBridgeProcess -and -not $script:RunningBridgeProcess.HasExited) {
        try {
            $script:RunningBridgeProcess.Kill()
            [void]$script:RunningBridgeProcess.WaitForExit(2000)
        } catch { }
        $script:RunningBridgeProcess = $null
    }

    # 3. Clean up any orphaned cpx processes running terabox-bridge
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'cpx.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.CommandLine -and $p.CommandLine.Contains('terabox-bridge')) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }

    return $true
}

function Get-TeraBoxBridgeRcloneEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BridgePassword,
        [int]$Port = 19191,
        [string]$RcloneBinary = $null,
        [string]$RemoteName = 'terabox'
    )

    $obscured = $null
    if ($RcloneBinary -and (Test-Path -LiteralPath $RcloneBinary)) {
        try {
            $obscured = (& $RcloneBinary obscure $BridgePassword 2>$null).Trim()
        } catch { }
    }

    $upperRemote = $RemoteName.ToUpperInvariant()

    $envVars = [ordered]@{
        "RCLONE_CONFIG_${upperRemote}_TYPE" = 'webdav'
        "RCLONE_CONFIG_${upperRemote}_URL" = "http://127.0.0.1:$Port/"
        "RCLONE_CONFIG_${upperRemote}_VENDOR" = 'other'
        "RCLONE_CONFIG_${upperRemote}_USER" = 'cpx'
    }

    if ($obscured) {
        $envVars["RCLONE_CONFIG_${upperRemote}_PASS"] = $obscured
    }

    return $envVars
}
