# TeraBoxBridgeManager.ps1 - Manages the local CPX WebDAV bridge daemon for TeraBox
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security

$script:BridgeEntropy = [System.Text.Encoding]::UTF8.GetBytes('CloudPlayX.v1.secret')
$script:DefaultBridgePort = 19191
$script:RunningBridgeProcess = $null
# Per-account bridge process handles keyed by the safe account id. The legacy
# single $script:RunningBridgeProcess handle is kept for backward compatibility.
$script:RunningBridgeProcesses = @{}

function Get-TeraBoxBridgePort([string]$AccountId = '') {
    if ([string]::IsNullOrWhiteSpace($AccountId) -or $AccountId -eq 'terabox') { return $script:DefaultBridgePort }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($AccountId)) } finally { $sha.Dispose() }
    $value = [BitConverter]::ToUInt32($digest, 0)
    # Keep per-account listeners in a stable high unprivileged range, below
    # Windows' usual dynamic client-port range. A collision is detected by the
    # caller's authenticated health check without terminating the other service.
    return 30000 + [int]($value % 10000)
}

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
    param(
        [string]$AccountId = ''
    )

    $homeDir = if (-not [string]::IsNullOrEmpty($AccountId) -and $AccountId -ne 'terabox') {
        $safeAccId = [regex]::Replace($AccountId, '[^a-zA-Z0-9_\-]', '_')
        Join-Path $env:LOCALAPPDATA "NSCloudDrive\terabox-bridge\$safeAccId"
    } else {
        Join-Path $env:LOCALAPPDATA 'NSCloudDrive\terabox-bridge'
    }

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

function Get-TeraBoxBridgeExistingPassword([string]$HomeDirectory = $null) {
    try {
        $dir = if ($HomeDirectory) { $HomeDirectory } else { Get-TeraBoxBridgeHomeDirectory }
        $keyFile = Join-Path $dir 'terabox.bridge.key'
        if (Test-Path -LiteralPath $keyFile -PathType Leaf) {
            $encBytes = [System.IO.File]::ReadAllBytes($keyFile)
            $decBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $encBytes,
                $script:BridgeEntropy,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            return [System.Text.Encoding]::UTF8.GetString($decBytes)
        }
    } catch { }
    return $null
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
        [string]$AccountId = '',
        [int]$Port = 0,
        [int]$WaitTimeoutSec = 10
    )

    if ($Port -le 0) { $Port = Get-TeraBoxBridgePort -AccountId $AccountId }

    $cpx = Find-CpxBinary
    if (-not $cpx) {
        throw 'CPX WebDAV bridge daemon executable (cpx.exe) was not found.'
    }

    $session = if ($SessionOverride) {
        $SessionOverride
    } else {
        . (Join-Path $PSScriptRoot '..\providers\TeraBoxProvider.ps1')
        Get-TeraBoxStoredSession -AccountId $AccountId
    }

    if (-not $session -or -not $session.Secret) {
        throw 'No valid TeraBox session found. Please sign in to TeraBox first.'
    }

    $homeDir = Get-TeraBoxBridgeHomeDirectory -AccountId $AccountId
    $existingPw = Get-TeraBoxBridgeExistingPassword -HomeDirectory $homeDir

    # Check if already healthy with existing password
    if ($existingPw -and (Test-TeraBoxBridgeHealth -Port $Port -BridgePassword $existingPw -TimeoutSec 1)) {
        $runningHandle = $null
        if ($script:RunningBridgeProcesses.ContainsKey($AccountId) -and $script:RunningBridgeProcesses[$AccountId] -and (-not $script:RunningBridgeProcesses[$AccountId].HasExited)) {
            $runningHandle = $script:RunningBridgeProcesses[$AccountId]
        }
        return [ordered]@{
            Success = $true
            Port = $Port
            Url = "http://127.0.0.1:$Port/"
            User = 'cpx'
            Password = $existingPw
            ProcessId = if ($runningHandle) { $runningHandle.Id } else { $null }
        }
    }

    # If an unhealthy or unresponsive cpx bridge is running, terminate it before starting fresh
    try {
        # Discard the sentinel output of the shutdown helper: called uncaptured
        # it leaked its 'return $true' into this function's pipeline, so the
        # cold-start result became an Object[] of two items and the consumer's
        # StrictMode property access on 'Success' threw
        # PropertyNotFoundException instead of returning the status dictionary.
        [void](Stop-TeraBoxBridge -Port $Port -AccountId $AccountId -BridgePassword $existingPw)
        Start-Sleep -Milliseconds 250
    } catch { }

    $secret = Set-TeraBoxBridgeSecrets -Session $session -HomeDirectory $homeDir

    # Start cpx.exe background bridge process
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $cpx
    $psi.Arguments = "terabox-bridge --port $Port --home `"$homeDir`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:RunningBridgeProcess = $proc
    $script:RunningBridgeProcesses[$AccountId] = $proc

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
        [string]$AccountId = '',
        [int]$Port = 0,
        [string]$BridgePassword = $null
    )

    if ($Port -le 0) { $Port = Get-TeraBoxBridgePort -AccountId $AccountId }
    $homeDir = Get-TeraBoxBridgeHomeDirectory -AccountId $AccountId
    if (-not $BridgePassword) { $BridgePassword = Get-TeraBoxBridgeExistingPassword -HomeDirectory $homeDir }

    # Only send the shutdown request when this account's bridge credential is
    # available. Unauthenticated shutdown requests could affect another local
    # service bound to the same port.
    try {
        if ($BridgePassword) {
        $headers = @{}
        $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("cpx:$BridgePassword"))
        $headers['Authorization'] = "Basic $auth"
        [void](Invoke-WebRequest -Uri "http://127.0.0.1:$Port/.cloudplayx/shutdown" -Method Post -Headers $headers -TimeoutSec 2 -UseBasicParsing -ErrorAction SilentlyContinue)
        }
    } catch { }

    # Terminate only a bridge whose --home argument resolves exactly to this
    # account's isolated home directory. The legacy home is a prefix of every
    # per-account home, so a substring match would also terminate unrelated
    # account bridges; match the quoted argument value itself instead.
    try {
        $expectedHome = [System.IO.Path]::GetFullPath($homeDir).TrimEnd('\')
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'cpx.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if (-not $p.CommandLine -or -not $p.CommandLine.Contains('terabox-bridge')) { continue }
            $homeArgMatch = [regex]::Match($p.CommandLine, '--home\s+"([^"]+)"|--home\s+([^\s"]+)')
            $procHome = if ($homeArgMatch.Success) {
                $value = if ($homeArgMatch.Groups[1].Success -and $homeArgMatch.Groups[1].Value) { $homeArgMatch.Groups[1].Value } else { $homeArgMatch.Groups[2].Value }
                try { [System.IO.Path]::GetFullPath($value).TrimEnd('\') } catch { '' }
            } else { '' }
            if ([string]::IsNullOrEmpty($procHome)) { continue }
            if (-not [string]::Equals($procHome, $expectedHome, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            if ($script:RunningBridgeProcesses.ContainsKey($AccountId) -and $script:RunningBridgeProcesses[$AccountId] -and $script:RunningBridgeProcesses[$AccountId].Id -eq [int]$p.ProcessId) {
                $script:RunningBridgeProcesses.Remove($AccountId)
            }
            if ($script:RunningBridgeProcess -and $script:RunningBridgeProcess.Id -eq [int]$p.ProcessId) { $script:RunningBridgeProcess = $null }
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
