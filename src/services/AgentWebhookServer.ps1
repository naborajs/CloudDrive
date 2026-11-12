Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    AgentWebhookServer provides a local HTTP listener for remote and local AI agents.
.DESCRIPTION
    Listens on 127.0.0.1:5998 (configurable) for incoming HTTP POST notifications from
    agents operating on Linux VPS or local environments (e.g. training completed,
    dataset ready, file generated). Triggers desktop alerts and optional auto-downloads.
#>

$script:AgentWebhookListener = $null
$script:AgentWebhookRunning = $false
$script:AgentWebhookPort = 5998
$script:AgentWebhookRequestCount = 0
$script:AgentWebhookCallback = $null

function Get-AgentWebhookStatus {
    [CmdletBinding()]
    param()

    return [ordered]@{
        IsRunning = [bool]($script:AgentWebhookRunning -and $null -ne $script:AgentWebhookListener -and $script:AgentWebhookListener.IsListening)
        Port = $script:AgentWebhookPort
        RequestCount = $script:AgentWebhookRequestCount
        Endpoint = "http://127.0.0.1:$($script:AgentWebhookPort)/agent-notify"
    }
}

function Start-AgentWebhookServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Port = 5998,

        [Parameter(Mandatory = $false)]
        [scriptblock]$OnNotificationReceived = $null
    )

    if ($script:AgentWebhookRunning -and $null -ne $script:AgentWebhookListener -and $script:AgentWebhookListener.IsListening) {
        if ($script:AgentWebhookPort -eq $Port) {
            return (Get-AgentWebhookStatus)
        }
        Stop-AgentWebhookServer
    }

    $script:AgentWebhookPort = $Port
    $script:AgentWebhookCallback = $OnNotificationReceived

    try {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()

        $script:AgentWebhookListener = $listener
        $script:AgentWebhookRunning = $true

        # Start asynchronous listen loop
        $listenCallback = $null
        $listenCallback = [System.AsyncCallback]{
            param($asyncResult)
            if (-not $script:AgentWebhookRunning -or $null -eq $script:AgentWebhookListener -or -not $script:AgentWebhookListener.IsListening) {
                return
            }

            try {
                $context = $script:AgentWebhookListener.EndGetContext($asyncResult)
                # Re-queue next async accept immediately
                if ($script:AgentWebhookRunning -and $script:AgentWebhookListener.IsListening) {
                    [void]$script:AgentWebhookListener.BeginGetContext($listenCallback, $null)
                }

                $script:AgentWebhookRequestCount++
                $req = $context.Request
                $resp = $context.Response

                $path = $req.Url.AbsolutePath.ToLowerInvariant()
                $method = $req.HttpMethod.ToUpperInvariant()

                # CORS and headers
                $resp.Headers.Add('Access-Control-Allow-Origin', '*')
                $resp.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
                $resp.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')

                if ($method -eq 'OPTIONS') {
                    $resp.StatusCode = 200
                    $resp.Close()
                    return
                }

                if ($path -eq '/health' -or $path -eq '/status') {
                    $payload = @{
                        status = 'online'
                        service = 'NSCloudDrive Agent Webhook Server'
                        port = $script:AgentWebhookPort
                        requestsProcessed = $script:AgentWebhookRequestCount
                    } | ConvertTo-Json -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    $resp.ContentType = 'application/json'
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    $resp.Close()
                    return
                }

                if ($path -eq '/agent-notify') {
                    $bodyText = ''
                    if ($req.HasEntityBody) {
                        $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                        $bodyText = $reader.ReadToEnd()
                        $reader.Close()
                    }

                    $parsed = $null
                    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                        try {
                            $parsed = ($bodyText | ConvertFrom-Json)
                        } catch { }
                    }

                    $evtTitle = if ($parsed -and $parsed.PSObject.Properties['title']) { [string]$parsed.title } else { 'Agent Notification' }
                    $evtMessage = if ($parsed -and $parsed.PSObject.Properties['message']) { [string]$parsed.message } else { 'Agent task completed.' }
                    $evtFile = if ($parsed -and $parsed.PSObject.Properties['file']) { [string]$parsed.file } else { '' }
                    $autoDownload = if ($parsed -and $parsed.PSObject.Properties['autoDownload']) { [bool]$parsed.autoDownload } else { $false }
                    $accountId = if ($parsed -and $parsed.PSObject.Properties['accountId']) { [string]$parsed.accountId } else { '' }

                    $notificationData = [ordered]@{
                        Event = if ($parsed -and $parsed.PSObject.Properties['event']) { [string]$parsed.event } else { 'job_done' }
                        Title = $evtTitle
                        Message = $evtMessage
                        File = $evtFile
                        AutoDownload = $autoDownload
                        AccountId = $accountId
                        ReceivedUtc = [DateTime]::UtcNow.ToString('o')
                    }

                    # Trigger registered callback if provided
                    if ($null -ne $script:AgentWebhookCallback) {
                        try {
                            & $script:AgentWebhookCallback $notificationData
                        } catch { }
                    }

                    # Record in transfer notification center if function exists
                    if (Get-Command 'Add-TransferNotificationEvent' -ErrorAction SilentlyContinue) {
                        try {
                            Add-TransferNotificationEvent -Type 'AgentWebhook' `
                                -ProviderId 'vps' `
                                -Path $evtFile `
                                -Message "Agent Webhook: $evtTitle - $evtMessage" `
                                -Status 'Completed' `
                                -Direction 'Push'
                        } catch { }
                    }

                    $respData = @{
                        status = 'received'
                        success = $true
                        title = $evtTitle
                        timestamp = [DateTime]::UtcNow.ToString('o')
                    } | ConvertTo-Json -Compress

                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($respData)
                    $resp.ContentType = 'application/json'
                    $resp.StatusCode = 200
                    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    $resp.Close()
                    return
                }

                # 404 for unknown endpoints
                $resp.StatusCode = 404
                $errBytes = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Not Found"}')
                $resp.ContentType = 'application/json'
                $resp.OutputStream.Write($errBytes, 0, $errBytes.Length)
                $resp.Close()
            } catch {
                # Listener shutting down or aborted
            }
        }

        [void]$listener.BeginGetContext($listenCallback, $null)
        return (Get-AgentWebhookStatus)
    } catch {
        $script:AgentWebhookRunning = $false
        if ($null -ne $script:AgentWebhookListener) {
            try { $script:AgentWebhookListener.Close() } catch { }
            $script:AgentWebhookListener = $null
        }
        throw "Failed to start Agent Webhook Server on port ${Port}: $($_.Exception.Message)"
    }
}

function Stop-AgentWebhookServer {
    [CmdletBinding()]
    param()

    $script:AgentWebhookRunning = $false
    if ($null -ne $script:AgentWebhookListener) {
        try {
            $script:AgentWebhookListener.Stop()
            $script:AgentWebhookListener.Close()
        } catch { }
        $script:AgentWebhookListener = $null
    }
    return (Get-AgentWebhookStatus)
}
