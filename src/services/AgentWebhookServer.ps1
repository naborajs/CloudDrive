Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    AgentWebhookServer provides a local HTTP listener for remote and local AI agents.
.DESCRIPTION
    Listens on 127.0.0.1:5998 (configurable) in a dedicated MTA Runspace for incoming
    HTTP POST notifications from agents operating on Linux VPS or local environments
    (e.g. training completed, dataset ready, file generated). Triggers desktop alerts and
    persists notifications to agent-notifications.jsonl.
#>

$script:AgentWebhookRunspace = $null
$script:AgentWebhookPowerShell = $null
$script:AgentWebhookAsyncHandle = $null
$script:AgentWebhookRunning = $false
$script:AgentWebhookPort = 5998

function Get-AgentNotificationLogPath {
    return (Join-Path $env:LOCALAPPDATA 'NSCloudDrive\state\agent-notifications.jsonl')
}

function Get-AgentWebhookStatus {
    [CmdletBinding()]
    param()

    return [ordered]@{
        IsRunning = [bool]($script:AgentWebhookRunning -and $null -ne $script:AgentWebhookRunspace)
        Port = $script:AgentWebhookPort
        Endpoint = "http://127.0.0.1:$($script:AgentWebhookPort)/agent-notify"
        HealthEndpoint = "http://127.0.0.1:$($script:AgentWebhookPort)/health"
    }
}

function Get-LatestAgentNotifications {
    [CmdletBinding()]
    param([int]$Limit = 20)

    $logPath = Get-AgentNotificationLogPath
    if (-not (Test-Path -LiteralPath $logPath)) {
        return @()
    }

    $results = @()
    try {
        $lines = [System.IO.File]::ReadAllLines($logPath)
        for ($i = $lines.Length - 1; $i -ge 0 -and $results.Count -lt $Limit; $i--) {
            $line = $lines[$i].Trim()
            if ($line) {
                try {
                    $results += ($line | ConvertFrom-Json)
                } catch { }
            }
        }
    } catch { }

    return ,@($results)
}

function Start-AgentWebhookServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Port = 5998
    )

    if ($script:AgentWebhookRunning -and $null -ne $script:AgentWebhookRunspace) {
        if ($script:AgentWebhookPort -eq $Port) {
            return (Get-AgentWebhookStatus)
        }
        Stop-AgentWebhookServer
    }

    $script:AgentWebhookPort = $Port
    $logFile = Get-AgentNotificationLogPath

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
    $rs.Open()

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs

    [void]$ps.AddScript({
        param([int]$p, [string]$targetLog)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$p/")
        try {
            $listener.Start()
        } catch {
            return
        }

        while ($listener.IsListening) {
            try {
                $context = $listener.GetContext()
                $req = $context.Request
                $resp = $context.Response
                $path = $req.Url.AbsolutePath.ToLowerInvariant()
                $method = $req.HttpMethod.ToUpperInvariant()

                $resp.Headers.Add('Access-Control-Allow-Origin', '*')
                $resp.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
                $resp.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')

                if ($method -eq 'OPTIONS') {
                    $resp.StatusCode = 200
                    $resp.Close()
                    continue
                }

                if ($path -eq '/health' -or $path -eq '/status') {
                    $payload = '{"status":"online","service":"NSCloudDrive Agent Webhook Server","success":true}'
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $bytes.Length
                    $resp.KeepAlive = $false
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    $resp.Close()
                    continue
                }

                if ($path -eq '/agent-notify') {
                    $bodyText = ''
                    if ($req.HasEntityBody) {
                        $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                        $bodyText = $reader.ReadToEnd()
                        $reader.Close()
                    }

                    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                        try {
                            $parentDir = [System.IO.Path]::GetDirectoryName($targetLog)
                            if (-not [string]::IsNullOrEmpty($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
                                [void][System.IO.Directory]::CreateDirectory($parentDir)
                            }
                            # Normalize to single-line JSONL entry
                            $normalizedEntry = $null
                            try {
                                $normalizedEntry = ($bodyText | ConvertFrom-Json | ConvertTo-Json -Compress)
                            } catch {
                                $normalizedEntry = ($bodyText -replace '[\r\n]+', ' ')
                            }
                            [System.IO.File]::AppendAllText($targetLog, "$normalizedEntry`r`n")
                        } catch { }
                    }

                    $respData = '{"status":"received","success":true}'
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($respData)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $bytes.Length
                    $resp.KeepAlive = $false
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    $resp.Close()
                    continue
                }

                $resp.StatusCode = 404
                $resp.KeepAlive = $false
                $resp.Close()
            } catch {
                break
            }
        }
        try { $listener.Close() } catch { }
    }).AddArgument($Port).AddArgument($logFile)

    $script:AgentWebhookRunspace = $rs
    $script:AgentWebhookPowerShell = $ps
    $script:AgentWebhookAsyncHandle = $ps.BeginInvoke()
    $script:AgentWebhookRunning = $true

    # Brief warm-up sleep
    Start-Sleep -Milliseconds 250
    return (Get-AgentWebhookStatus)
}

function Stop-AgentWebhookServer {
    [CmdletBinding()]
    param()

    $script:AgentWebhookRunning = $false

    if ($null -ne $script:AgentWebhookPowerShell) {
        try {
            $wc = [System.Net.WebClient]::new()
            try { $wc.DownloadString("http://127.0.0.1:$($script:AgentWebhookPort)/health") | Out-Null } catch { }
            $wc.Dispose()
        } catch { }
        try { $script:AgentWebhookPowerShell.Stop() } catch { }
        try { $script:AgentWebhookPowerShell.Dispose() } catch { }
        $script:AgentWebhookPowerShell = $null
    }

    if ($null -ne $script:AgentWebhookRunspace) {
        try { $script:AgentWebhookRunspace.Close() } catch { }
        try { $script:AgentWebhookRunspace.Dispose() } catch { }
        $script:AgentWebhookRunspace = $null
    }

    return (Get-AgentWebhookStatus)
}
