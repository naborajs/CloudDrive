Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SettingsManager.ps1')
. (Join-Path $PSScriptRoot 'AgentTransferBridge.ps1')

$script:SyncPairsConfigPathOverride = $null
$script:ActiveSyncWatchers = [ordered]@{}
$script:ActiveSyncDebounceTimers = [ordered]@{}

function Get-SyncPairsConfigPath {
    if ($script:SyncPairsConfigPathOverride) {
        return $script:SyncPairsConfigPathOverride
    }
    $baseDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\config'
    if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }
    return (Join-Path $baseDir 'sync-pairs.json')
}

function Set-SyncPairsConfigPathOverride([string]$Path) {
    $script:SyncPairsConfigPathOverride = $Path
}

function Get-SyncPairs {
    $path = Get-SyncPairsConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = ConvertFrom-Json $raw
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } catch {
        return @()
    }
}

function Save-SyncPairs([array]$SyncPairs) {
    $path = Get-SyncPairsConfigPath
    $parent = [System.IO.Path]::GetDirectoryName($path)
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = ConvertTo-Json -InputObject @($SyncPairs) -Depth 10
    $tmp = "$path.tmp.$([Guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)

    # Atomic rename/replace
    if (Test-Path -LiteralPath $path) {
        [System.IO.File]::Replace($tmp, $path, $null)
    } else {
        [System.IO.File]::Move($tmp, $path)
    }
}

function New-SyncPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$LocalPath,

        [Parameter(Mandatory = $true)]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [string]$ProviderId,

        [Parameter(Mandatory = $false)]
        [string]$AccountId = '',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Push', 'Pull', 'Sync', 'BiDirectional')]
        [string]$Direction = 'Push',

        [Parameter(Mandatory = $false)]
        [int]$IntervalMinutes = 5,

        [Parameter(Mandatory = $false)]
        [bool]$WatchFileSystem = $true,

        [Parameter(Mandatory = $false)]
        [string]$Filter = '*',

        [Parameter(Mandatory = $false)]
        [bool]$Compress = $true
    )

    if ([string]::IsNullOrWhiteSpace($LocalPath)) {
        throw "LocalPath cannot be empty"
    }

    # Normalize paths
    $resolvedLocal = [System.IO.Path]::GetFullPath($LocalPath)
    if (-not (Test-Path -LiteralPath $resolvedLocal)) {
        New-Item -ItemType Directory -Path $resolvedLocal -Force | Out-Null
    }

    $id = "sync_" + [Guid]::NewGuid().ToString('N')
    $newPair = [ordered]@{
        Id                = $id
        Name              = $Name
        LocalPath         = $resolvedLocal
        RemotePath        = $RemotePath
        ProviderId        = $ProviderId.ToLowerInvariant()
        AccountId         = $AccountId
        Direction         = $Direction
        IntervalMinutes   = [Math]::Max(0, $IntervalMinutes)
        WatchFileSystem   = $WatchFileSystem
        Filter            = if ($Filter) { $Filter } else { '*' }
        Compress          = $Compress
        Enabled           = $true
        CreatedAtUtc      = [DateTime]::UtcNow.ToString('o')
        LastSyncTime      = $null
        LastStatus        = 'Pending'
        LastError         = ''
        DurationSec       = 0
        FilesTransferred  = 0
        BytesTransferred  = 0
    }

    $existing = @(Get-SyncPairs)
    $all = @($existing) + @($newPair)
    Save-SyncPairs -SyncPairs $all

    if ($WatchFileSystem) {
        try { Start-SyncPairWatcher -SyncPairId $id } catch { }
    }

    return [pscustomobject]$newPair
}

function Remove-SyncPair([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    Stop-SyncPairWatcher -SyncPairId $Id

    $existing = @(Get-SyncPairs)
    $filtered = @($existing | Where-Object { [string]$_.Id -ne $Id })
    if ($filtered.Count -ne $existing.Count) {
        Save-SyncPairs -SyncPairs $filtered
        return $true
    }
    return $false
}

function Get-SyncPairById([string]$Id) {
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $pairs = @(Get-SyncPairs)
    foreach ($p in $pairs) {
        if ([string]$p.Id -eq $Id) { return $p }
    }
    return $null
}

function Update-SyncPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [hashtable]$Properties
    )

    $pairs = @(Get-SyncPairs)
    $found = $false
    for ($i = 0; $i -lt $pairs.Count; $i++) {
        if ([string]$pairs[$i].Id -eq $Id) {
            $ht = [ordered]@{}
            $pairs[$i].PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            foreach ($k in $Properties.Keys) {
                $ht[$k] = $Properties[$k]
            }
            $pairs[$i] = [pscustomobject]$ht
            $found = $true
            break
        }
    }

    if ($found) {
        Save-SyncPairs -SyncPairs $pairs
        return $true
    }
    return $false
}

function Invoke-SyncPairExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncPairId,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun
    )

    $pair = Get-SyncPairById -Id $SyncPairId
    if (-not $pair) {
        throw "Sync pair with ID '$SyncPairId' not found."
    }

    if (-not [bool]$pair.Enabled) {
        return @{ Success = $false; Error = "Sync pair is disabled." }
    }

    [void](Update-SyncPair -Id $SyncPairId -Properties @{ LastStatus = 'Running'; LastError = '' })

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $transferSuccess = $false
    $transferError = ''
    $bytes = 0
    $files = 0

    try {
        $provider = [string]$pair.ProviderId
        $direction = [string]$pair.Direction
        $localPath = [string]$pair.LocalPath
        $remotePath = [string]$pair.RemotePath
        $compress = if ($null -ne $pair.Compress) { [bool]$pair.Compress } else { $true }
        $accountId = [string]$pair.AccountId

        if ($provider -eq 'vps') {
            # Execute through AgentTransferBridge
            $xferDirection = switch ($direction) {
                'Pull' { 'Pull' }
                'Sync' { 'Sync' }
                'BiDirectional' { 'Sync' }
                Default { 'Push' }
            }

            $res = Start-AgentFileTransfer `
                -AccountId $accountId `
                -Direction $xferDirection `
                -LocalPath $localPath `
                -RemotePath $remotePath `
                -Compress:$compress

            if ($res.Success) {
                $transferSuccess = $true
                $bytes = [int64]$res.BytesTransferred
                $files = [int]$res.FilesTransferred
            } else {
                $transferSuccess = $false
                $transferError = [string]$res.Error
            }
        } else {
            # Execute cloud provider transfer via rclone remote mapping
            $rclone = Find-RcloneBinary
            if (-not $rclone) { throw "Rclone binary not found on system." }

            # Build provider transfer environment
            $accList = @(Get-CloudAccounts)
            $account = $null
            if ($accountId) {
                $account = $accList | Where-Object { [string]$_.Id -eq $accountId } | Select-Object -First 1
            }
            if (-not $account) {
                $account = $accList | Where-Object { [string]$_.ProviderId -eq $provider } | Select-Object -First 1
            }

            if (-not $account) {
                throw "No configured account found for provider '$provider'."
            }

            $remoteEnv = Get-CloudAccountTransferRemoteEnvironment -Account $account -ProviderId $provider -RemoteName 'syncremote'
            $rcloneCmd = if ($direction -in @('Sync', 'BiDirectional')) { 'sync' } else { 'copy' }
            $src = if ($direction -eq 'Pull') { "syncremote:$remotePath" } else { $localPath }
            $dst = if ($direction -eq 'Pull') { $localPath } else { "syncremote:$remotePath" }

            $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
            $pinfo.FileName = $rclone
            $pinfo.Arguments = "$rcloneCmd `"$src`" `"$dst`" --stats 1s --stats-one-line -v"
            $pinfo.UseShellExecute = $false
            $pinfo.RedirectStandardOutput = $true
            $pinfo.RedirectStandardError = $true
            $pinfo.CreateNoWindow = $true

            if ($remoteEnv) {
                foreach ($k in $remoteEnv.Keys) {
                    $pinfo.EnvironmentVariables[$k] = [string]$remoteEnv[$k]
                }
            }

            $proc = [System.Diagnostics.Process]::Start($pinfo)
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit(300000)

            if ($proc.ExitCode -eq 0) {
                $transferSuccess = $true
            } else {
                $transferSuccess = $false
                $transferError = if ($stderr) { $stderr.Trim() } else { "Exit code $($proc.ExitCode)" }
            }
        }
    } catch {
        $transferSuccess = $false
        $transferError = $_.Exception.Message
    } finally {
        $sw.Stop()
    }

    $dur = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    $statusText = if ($transferSuccess) { 'Success' } else { 'Failed' }

    [void](Update-SyncPair -Id $SyncPairId -Properties @{
        LastSyncTime     = [DateTime]::UtcNow.ToString('o')
        LastStatus       = $statusText
        LastError        = $transferError
        DurationSec      = $dur
        FilesTransferred = $files
        BytesTransferred = $bytes
    })

    return [ordered]@{
        Success          = $transferSuccess
        SyncPairId       = $SyncPairId
        Status           = $statusText
        Error            = $transferError
        DurationSec      = $dur
        FilesTransferred = $files
        BytesTransferred = $bytes
    }
}

function Start-SyncPairWatcher([string]$SyncPairId, [int]$DebounceSeconds = 3) {
    if ([string]::IsNullOrWhiteSpace($SyncPairId)) { return }
    $pair = Get-SyncPairById -Id $SyncPairId
    if (-not $pair) { return }

    $localPath = [string]$pair.LocalPath
    if (-not (Test-Path -LiteralPath $localPath)) { return }

    # Clean existing watcher if already active
    Stop-SyncPairWatcher -SyncPairId $SyncPairId

    $fsw = [System.IO.FileSystemWatcher]::new()
    $fsw.Path = $localPath
    $fsw.Filter = if ($pair.Filter) { [string]$pair.Filter } else { '*.*' }
    $fsw.IncludeSubdirectories = $true
    $fsw.NotifyFilter = [System.IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'

    # Debounce timer
    $timer = [System.Timers.Timer]::new(([TimeSpan]::FromSeconds($DebounceSeconds).TotalMilliseconds))
    $timer.AutoReset = $false

    $action = {
        param($source, $eventArgs)
        $t = $script:ActiveSyncDebounceTimers[$SyncPairId]
        if ($t) {
            $t.Stop()
            $t.Start()
        }
    }

    $timerElapsed = {
        param($source, $eventArgs)
        try {
            Invoke-SyncPairExecution -SyncPairId $SyncPairId | Out-Null
        } catch { }
    }

    Register-ObjectEvent -InputObject $timer -EventName 'Elapsed' -Action $timerElapsed | Out-Null
    Register-ObjectEvent -InputObject $fsw -EventName 'Changed' -Action $action | Out-Null
    Register-ObjectEvent -InputObject $fsw -EventName 'Created' -Action $action | Out-Null
    Register-ObjectEvent -InputObject $fsw -EventName 'Deleted' -Action $action | Out-Null
    Register-ObjectEvent -InputObject $fsw -EventName 'Renamed' -Action $action | Out-Null

    $fsw.EnableRaisingEvents = $true

    $script:ActiveSyncWatchers[$SyncPairId] = $fsw
    $script:ActiveSyncDebounceTimers[$SyncPairId] = $timer
}

function Stop-SyncPairWatcher([string]$SyncPairId) {
    if ($script:ActiveSyncDebounceTimers.Contains($SyncPairId)) {
        try {
            $timer = $script:ActiveSyncDebounceTimers[$SyncPairId]
            $timer.Stop()
            $timer.Dispose()
        } catch { }
        $script:ActiveSyncDebounceTimers.Remove($SyncPairId)
    }

    if ($script:ActiveSyncWatchers.Contains($SyncPairId)) {
        try {
            $fsw = $script:ActiveSyncWatchers[$SyncPairId]
            $fsw.EnableRaisingEvents = $false
            $fsw.Dispose()
        } catch { }
        $script:ActiveSyncWatchers.Remove($SyncPairId)
    }
}

function Stop-AllSyncPairWatchers {
    $keys = @($script:ActiveSyncWatchers.Keys)
    foreach ($k in $keys) {
        Stop-SyncPairWatcher -SyncPairId $k
    }
}

function Start-AllSyncPairWatchers {
    $pairs = @(Get-SyncPairs)
    foreach ($p in $pairs) {
        if ([bool]$p.Enabled -and [bool]$p.WatchFileSystem) {
            try {
                Start-SyncPairWatcher -SyncPairId ([string]$p.Id)
            } catch { }
        }
    }
}
