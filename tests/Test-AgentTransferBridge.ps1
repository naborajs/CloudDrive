# Test-AgentTransferBridge.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        Write-Output "  [FAIL] $Message"
        throw $Message
    }
    Write-Output "  [PASS] $Message"
}

Write-Output 'Testing AgentTransferBridge & Agent CLI...'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bridgePath = Join-Path $repoRoot 'src\services\AgentTransferBridge.ps1'
$cliPath = Join-Path $repoRoot 'scripts\Invoke-AgentTransfer.ps1'

# 1. Verify existence and syntax
Assert-True (Test-Path -LiteralPath $bridgePath) 'AgentTransferBridge.ps1 exists'
Assert-True (Test-Path -LiteralPath $cliPath) 'Invoke-AgentTransfer.ps1 CLI exists'

$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($bridgePath, [ref]$null, [ref]$parseErrors)
Assert-True ($null -eq $parseErrors -or $parseErrors.Count -eq 0) 'AgentTransferBridge.ps1 parses cleanly'

$null = [System.Management.Automation.Language.Parser]::ParseFile($cliPath, [ref]$null, [ref]$parseErrors)
Assert-True ($null -eq $parseErrors -or $parseErrors.Count -eq 0) 'Invoke-AgentTransfer.ps1 parses cleanly'

# 2. Dot-source bridge in isolated scope
. $bridgePath

# 3. Test Get-AgentVpsAccounts
$accounts = @(Get-AgentVpsAccounts)
Assert-True ($accounts -is [System.Array]) 'Get-AgentVpsAccounts returns an array'

# 4. Test parameter validations
$threwMissing = $false
try {
    Start-AgentFileTransfer -AccountId 'nonexistent-vps-999' -Direction 'Push' -LocalPath 'C:\test.bin'
} catch {
    $threwMissing = $true
}
Assert-True $threwMissing 'Start-AgentFileTransfer throws appropriately on missing VPS session'

$threwMissingPath = $false
try {
    Start-AgentFileTransfer -AccountId 'nonexistent-vps-999' -Direction 'Push' -LocalPath ''
} catch {
    $threwMissingPath = $true
}
Assert-True $threwMissingPath 'Start-AgentFileTransfer throws on empty local path for push'

# 5. Test CLI invocation in dry/JSON mode
$cliOutput = powershell.exe -NoProfile -File $cliPath -Direction Push -LocalPath "nonexistent_file.bin" -AsJson 2>&1 | Out-String
Assert-True ($cliOutput -match 'Success' -or $cliOutput -match 'Error') 'Invoke-AgentTransfer CLI produces valid JSON output'
$jsonObj = $cliOutput | ConvertFrom-Json
Assert-True ($jsonObj.Success -eq $false) 'Invoke-AgentTransfer correctly returns Success: false for nonexistent inputs'

Write-Output 'AgentTransferBridge & Agent CLI tests passed.'
