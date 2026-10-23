Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\services\TeraBoxBridgeManager.ps1')

$originalLocalAppData = $env:LOCALAPPDATA
$sandbox = Join-Path $env:TEMP ('NSCloudDrive_TeraBoxIsolation_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:LOCALAPPDATA = $sandbox
try {
    $accountOne = 'terabox_' + [guid]::NewGuid().ToString('N')
    $accountTwo = 'terabox_' + [guid]::NewGuid().ToString('N')
    $portOne = Get-TeraBoxBridgePort -AccountId $accountOne
    $portTwo = Get-TeraBoxBridgePort -AccountId $accountTwo
    if ($portOne -eq $portTwo -or $portOne -lt 30000 -or $portOne -gt 39999 -or $portTwo -lt 30000 -or $portTwo -gt 39999) {
        throw 'Independent accounts must receive distinct unprivileged bridge ports.'
    }
    if ((Get-TeraBoxBridgePort -AccountId $accountOne) -ne $portOne -or (Get-TeraBoxBridgePort) -ne 19191) {
        throw 'Per-account ports must be stable and preserve the legacy bridge port.'
    }

    $homeOne = Get-TeraBoxBridgeHomeDirectory -AccountId $accountOne
    $homeTwo = Get-TeraBoxBridgeHomeDirectory -AccountId $accountTwo
    if ($homeOne -eq $homeTwo) { throw 'TeraBox accounts must use separate bridge homes.' }

    $sessionOne = @{ Secret = 'ndus=isolated_test_one'; BaseUrl = 'https://www.terabox.com'; UserAgent = 'test-agent' }
    $sessionTwo = @{ Secret = 'ndus=isolated_test_two'; BaseUrl = 'https://www.terabox.com'; UserAgent = 'test-agent' }
    Set-TeraBoxBridgeSecrets -Session $sessionOne -HomeDirectory $homeOne | Out-Null
    Set-TeraBoxBridgeSecrets -Session $sessionTwo -HomeDirectory $homeTwo | Out-Null
    if ((Get-TeraBoxBridgeExistingPassword -HomeDirectory $homeOne) -eq (Get-TeraBoxBridgeExistingPassword -HomeDirectory $homeTwo)) {
        throw 'Separate account bridge credentials must not be shared.'
    }

    $managerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\services\TeraBoxBridgeManager.ps1') -Raw
    $mountSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1') -Raw
    if ($managerSource -notmatch 'IndexOf\(\$homeDir' -or $managerSource -notmatch 'Get-TeraBoxBridgePort -AccountId \$AccountId') {
        throw 'Bridge stop/start must use the matching account home and its deterministic port.'
    }
    if ($mountSource -notmatch 'Start-TeraBoxBridge -AccountId \$AccountId' -or $mountSource -notmatch 'Stop-TeraBoxBridge -AccountId \$AccountId') {
        throw 'Mount and unmount must pass the account identity to the bridge manager.'
    }
    if ($mountSource -notmatch 'EnvironmentVariables\.Remove\(\$sessionCookieKey\)') {
        throw 'The rclone WebDAV child process must not inherit the browser session cookie.'
    }
    if ($mountSource -notmatch 'ownedLetter' -or $mountSource -notmatch 'ProviderId\}:' ) {
        throw 'Orphaned rclone cleanup must be scoped by the account drive and provider.'
    }

    Write-Output '  [PASS] TeraBox account sessions use isolated homes, protected bridge secrets, stable distinct ports, and account-scoped cleanup.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}
