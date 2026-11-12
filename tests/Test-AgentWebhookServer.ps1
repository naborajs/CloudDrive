# Test-AgentWebhookServer.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Write-Output "  [FAIL] $Message"
        throw $Message
    }
    Write-Output "  [PASS] $Message"
}

Write-Output 'Testing Agent Webhook Server...'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$webhookScript = Join-Path $repoRoot 'src\services\AgentWebhookServer.ps1'

Assert-True (Test-Path -LiteralPath $webhookScript) 'AgentWebhookServer.ps1 exists'

. $webhookScript

$testPort = 5997

try {
    # 1. Start server
    $status = Start-AgentWebhookServer -Port $testPort
    Assert-True $status.IsRunning "Agent Webhook Server is running on port $testPort"

    # 2. Test /health endpoint
    $healthResp = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/health" -Method Get -TimeoutSec 5
    Assert-True ($healthResp.status -eq 'online') "Health endpoint returned online status"

    # 3. Test /agent-notify endpoint
    $postBody = @{
        event = 'training_complete'
        title = 'Model Checkpoint Ready'
        message = 'Agent finished training epoch 100.'
        file = '/workspace/models/checkpoint.bin'
        autoDownload = $true
    } | ConvertTo-Json

    $notifyResp = Invoke-RestMethod -Uri "http://127.0.0.1:$testPort/agent-notify" -Method Post -Body $postBody -ContentType 'application/json' -TimeoutSec 5
    Assert-True ($notifyResp.success -eq $true) "Notify endpoint accepted payload and returned success"

    Start-Sleep -Milliseconds 300
    $latest = Get-LatestAgentNotifications -Limit 5
    Assert-True ($latest.Count -gt 0) "Get-LatestAgentNotifications retrieved recorded notification"
    Assert-True ($latest[0].event -eq 'training_complete') "Event type correctly parsed in notification log"
    Assert-True ($latest[0].file -eq '/workspace/models/checkpoint.bin') "File path correctly parsed in notification log"

    # 4. Stop server
    $stopStatus = Stop-AgentWebhookServer
    Assert-True (-not $stopStatus.IsRunning) "Agent Webhook Server stopped cleanly"

    Write-Output 'Agent Webhook Server tests passed successfully.'
} finally {
    try { Stop-AgentWebhookServer } catch { }
}
