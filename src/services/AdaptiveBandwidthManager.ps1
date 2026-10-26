Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SettingsManager.ps1')
. (Join-Path $PSScriptRoot 'VirtualDriveManager.ps1')

# ==============================================================================
# ADAPTIVE BANDWIDTH SCHEDULER & CONGESTION CONTROLLER
# ==============================================================================

$script:AdaptiveBandwidthState = [hashtable]::Synchronized(@{
    LastCheckUtc = [DateTime]::MinValue
    LastProbeUtc = [DateTime]::MinValue
    CachedLatencyMs = 25.0
    BaselineLatencyMs = 25.0
    RecentLatencies = [System.Collections.Generic.List[double]]::new()
    IsCongested = $false
    IsGamingDetected = $false
    CurrentAppliedRate = 'off'
    ObservedUploadSpeed = 0.0
    LastRampUpUtc = [DateTime]::MinValue
    StepDownCount = 0
})

$script:KnownLatencySensitiveProcesses = @(
    'steam', 'valorant', 'riotclientservices', 'leagueclient',
    'cs2', 'dota2', 'fortniteclient-win64-shipping', 'discord',
    'zoom', 'teams', 'obs64'
)

function Test-GamingWorkloadActive {
    [CmdletBinding()]
    param()

    try {
        $activeProcs = @(Get-Process -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName -ErrorAction SilentlyContinue)
        if (-not $activeProcs -or $activeProcs.Count -eq 0) { return $false }

        foreach ($p in $script:KnownLatencySensitiveProcesses) {
            if ($activeProcs -contains $p) {
                return $true
            }
        }
    } catch { }
    return $false
}

function Measure-NetworkLatencyProbe {
    [CmdletBinding()]
    param(
        [string]$TargetHost = '1.1.1.1',
        [int]$TimeoutMs = 300
    )

    $now = [DateTime]::UtcNow
    # Bound probe frequency to at most once every 10 seconds to avoid network noise
    if (($now - [DateTime]$script:AdaptiveBandwidthState.LastProbeUtc).TotalSeconds -lt 10 -and $script:AdaptiveBandwidthState.CachedLatencyMs -gt 0) {
        return [double]$script:AdaptiveBandwidthState.CachedLatencyMs
    }

    $measuredLatency = 0.0
    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $reply = $ping.Send($TargetHost, $TimeoutMs)
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $measuredLatency = [double]$reply.RoundtripTime
            $script:AdaptiveBandwidthState.CachedLatencyMs = $measuredLatency
            $script:AdaptiveBandwidthState.LastProbeUtc = $now

            # Track rolling baseline (min latency seen over last 10 samples)
            $script:AdaptiveBandwidthState.RecentLatencies.Add($measuredLatency)
            if ($script:AdaptiveBandwidthState.RecentLatencies.Count -gt 10) {
                $script:AdaptiveBandwidthState.RecentLatencies.RemoveAt(0)
            }
            $minVal = $measuredLatency
            foreach ($sample in $script:AdaptiveBandwidthState.RecentLatencies) {
                if ($sample -gt 0 -and $sample -lt $minVal) { $minVal = $sample }
            }
            $script:AdaptiveBandwidthState.BaselineLatencyMs = [Math]::Max(10.0, $minVal)
        } else {
            # Packet dropped or timed out - potential congestion
            $measuredLatency = 250.0
            $script:AdaptiveBandwidthState.CachedLatencyMs = 250.0
            $script:AdaptiveBandwidthState.LastProbeUtc = $now
        }
        $ping.Dispose()
    } catch {
        # Fallback to cached latency if ICMP is blocked
        $measuredLatency = [double]$script:AdaptiveBandwidthState.CachedLatencyMs
    }

    return $measuredLatency
}

function Calculate-AdaptiveBandwidthTarget {
    [CmdletBinding()]
    param(
        [double]$ObservedUploadSpeedBytesPerSec,
        [double]$CurrentLatencyMs,
        [double]$BaselineLatencyMs,
        [bool]$IsGamingDetected,
        [string]$Sensitivity = 'Balanced',
        [int]$CustomLimitValue = 0,
        [string]$CustomLimitUnit = 'MB/s'
    )

    # 1. Congestion evaluation
    $latencyRatio = if ($BaselineLatencyMs -gt 0) { $CurrentLatencyMs / $BaselineLatencyMs } else { 1.0 }
    $isCongested = ($latencyRatio -ge 2.2 -or $CurrentLatencyMs -ge 120.0)

    # 2. Base sensitivity multipliers
    $congestionMultiplier = switch ($Sensitivity) {
        'Conservative' { 0.25 }
        'Aggressive'   { 0.75 }
        default        { 0.50 } # Balanced
    }

    # 3. Determine target rate string
    if ($IsGamingDetected) {
        # Immediate low-impact throttling for gaming / conferencing
        $gamingRate = switch ($Sensitivity) {
            'Conservative' { '250k' }
            'Aggressive'   { '1.5M' }
            default        { '500k' }
        }
        return $gamingRate
    }

    if ($isCongested) {
        # Back off proportionally based on observed capacity
        if ($ObservedUploadSpeedBytesPerSec -gt 500000.0) {
            $targetBytes = [Math]::Max(256000.0, $ObservedUploadSpeedBytesPerSec * $congestionMultiplier)
            $kb = [int][Math]::Round($targetBytes / 1024.0)
            return "${kb}k"
        } else {
            return '250k'
        }
    }

    # No congestion: clear limits to allow full line speed
    return 'off'
}

function Invoke-AdaptiveBandwidthCheck {
    [CmdletBinding()]
    param(
        [hashtable]$Settings = $null
    )

    if (-not $Settings) { $Settings = Get-NSCloudDriveSettings }
    $policy = if ($Settings.BandwidthPolicy) { [string]$Settings.BandwidthPolicy } else { 'Unlimited' }

    $targetRate = 'off'
    $gamingActive = $false
    $latencyMs = 25.0
    $isCongested = $false

    if ($policy -eq 'Unlimited') {
        $targetRate = 'off'
    } elseif ($policy -eq 'MinimalBackground') {
        $targetRate = '256k'
        $gamingActive = $false
        $isCongested = $false
    } elseif ($policy -eq 'Limited') {
        $targetRate = Get-EffectiveBandwidthLimitRate -Settings $Settings
        $gamingActive = $false
        $isCongested = $false
    } elseif ($policy -eq 'Custom') {
        $targetRate = Get-EffectiveBandwidthLimitRate -Settings $Settings
        $gamingActive = $false
        $isCongested = $false
    } else {
        # Policy is Adaptive
        $latencyMs = Measure-NetworkLatencyProbe
        $baseLatency = [double]$script:AdaptiveBandwidthState.BaselineLatencyMs
        if ($Settings.DetectGamingTraffic) {
            $gamingActive = Test-GamingWorkloadActive
        }

        # Aggregate current active upload throughput from all virtual drives
        $totalSpeed = 0.0
        try {
            $accounts = @(Get-CloudAccounts)
            foreach ($acc in $accounts) {
                $letter = [string]$acc.DriveLetter
                if ($letter) {
                    $st = Get-VirtualDriveVfsStats -DriveLetter $letter
                    if ($st.IsActive -and $st.UploadsInProgress -gt 0) {
                        $totalSpeed += [double]$st.SmoothedSpeed
                    }
                }
            }
        } catch { }

        $script:AdaptiveBandwidthState.ObservedUploadSpeed = $totalSpeed
        $sensitivity = if ($Settings.AdaptiveSensitivity) { [string]$Settings.AdaptiveSensitivity } else { 'Balanced' }

        $targetRate = Calculate-AdaptiveBandwidthTarget `
            -ObservedUploadSpeedBytesPerSec $totalSpeed `
            -CurrentLatencyMs $latencyMs `
            -BaselineLatencyMs $baseLatency `
            -IsGamingDetected $gamingActive `
            -Sensitivity $sensitivity

        $latencyRatio = if ($baseLatency -gt 0) { $latencyMs / $baseLatency } else { 1.0 }
        $isCongested = ($latencyRatio -ge 2.2 -or $latencyMs -ge 120.0)
    }

    # Apply rate across all mounted drives only when changed
    if ($targetRate -ne $script:AdaptiveBandwidthState.CurrentAppliedRate) {
        Set-AllVirtualDrivesBandwidthLimit -Rate $targetRate | Out-Null
        $script:AdaptiveBandwidthState.CurrentAppliedRate = $targetRate
    }

    $script:AdaptiveBandwidthState.LastCheckUtc = [DateTime]::UtcNow
    $script:AdaptiveBandwidthState.IsCongested = $isCongested
    $script:AdaptiveBandwidthState.IsGamingDetected = $gamingActive

    return [ordered]@{
        Policy = $policy
        AppliedRate = $targetRate
        LatencyMs = [Math]::Round($latencyMs, 1)
        BaselineLatencyMs = [Math]::Round([double]$script:AdaptiveBandwidthState.BaselineLatencyMs, 1)
        IsCongested = $isCongested
        GamingActive = $gamingActive
        ObservedUploadSpeedBytesPerSec = [Math]::Round([double]$script:AdaptiveBandwidthState.ObservedUploadSpeed, 1)
        LastEvaluatedUtc = $script:AdaptiveBandwidthState.LastCheckUtc
    }
}
