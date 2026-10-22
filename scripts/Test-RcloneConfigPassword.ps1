[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workRoot = Join-Path $repositoryRoot 'work'
$createdWorkRoot = $false
if (-not (Test-Path -LiteralPath $workRoot)) {
    New-Item -ItemType Directory -Path $workRoot | Out-Null
    $createdWorkRoot = $true
}

$testRoot = Join-Path $workRoot ('RcloneConfigPassword-' + [Guid]::NewGuid().ToString('N'))
$resolvedWorkRoot = [System.IO.Path]::GetFullPath($workRoot) + [System.IO.Path]::DirectorySeparatorChar
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($resolvedWorkRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary test path escaped the repository work folder.'
}

$credentialDirectory = Join-Path $testRoot 'NSCloudDrive\credentials'
$credentialPath = Join-Path $credentialDirectory 'rclone-config.xml'
$helperPath = Join-Path $PSScriptRoot 'RcloneConfigPassword.ps1'
$savedLocalAppData = $env:LOCALAPPDATA
$savedConsoleOut = [Console]::Out
$consoleCapture = [System.IO.StringWriter]::new()
$secureMarker = $null
$marker = 'synthetic-' + [Guid]::NewGuid().ToString('N')

try {
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw 'The password helper script is missing.'
    }

    New-Item -ItemType Directory -Path $credentialDirectory -Force | Out-Null
    $secureMarker = ConvertTo-SecureString $marker -AsPlainText -Force
    $credential = [System.Management.Automation.PSCredential]::new('synthetic-test-only', $secureMarker)
    Export-Clixml -InputObject $credential -LiteralPath $credentialPath

    $savedContent = Get-Content -LiteralPath $credentialPath -Raw
    if ($savedContent.Contains($marker)) {
        throw 'The synthetic marker was found in the serialized credential file.'
    }

    $env:LOCALAPPDATA = $testRoot
    [Console]::SetOut($consoleCapture)
    & $helperPath
    $retrieved = $consoleCapture.ToString().TrimEnd([char[]]@("`r", "`n"))
    if ($retrieved -cne $marker) {
        throw 'The helper did not return the synthetic marker exactly.'
    }

    $env:LOCALAPPDATA = Join-Path $testRoot 'missing-credential-profile'
    try {
        & $helperPath | Out-Null
        throw 'The helper unexpectedly succeeded without a credential file.'
    } catch {
        if ($_.Exception.Message -notmatch 'No local unlock credential is stored') {
            throw
        }
    }
}
finally {
    [Console]::SetOut($savedConsoleOut)
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($secureMarker) { $secureMarker.Dispose() }
    $marker = $null
    $retrieved = $null
    $consoleCapture.Dispose()

    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
    if ($createdWorkRoot -and (Test-Path -LiteralPath $workRoot) -and
        (Get-ChildItem -LiteralPath $workRoot -Force | Measure-Object).Count -eq 0) {
        Remove-Item -LiteralPath $workRoot
    }
}

Write-Output 'Synthetic DPAPI fixture/read-helper round-trip passed; plaintext-at-rest and missing-credential checks passed. No real credential was used.'
