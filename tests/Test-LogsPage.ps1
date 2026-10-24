# Test-LogsPage.ps1 - Shared application log store + Logs page contract tests
#
# Behavioral part: exercises the REAL Write-NSCloudLog / Read-ApplicationLogEntries
# from src/models/ConnectionState.ps1 inside a sandboxed LOCALAPPDATA - verifying
# on-disk redaction of token material, bounded reads, rotation, and the
# DiagnosticLogging=Off gate. Structural part verifies the Logs page wiring in
# NSCloudDrive.ps1. All file writes stay inside the sandbox.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$originalLocalAppData = $env:LOCALAPPDATA
$sandbox = Join-Path $env:TEMP ('NSCloudDrive_LogsTest_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$env:LOCALAPPDATA = $sandbox

$failed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { $script:failed++; Write-Output "  [FAIL] $Message"; throw $Message }
    Write-Output "  [PASS] $Message"
}

try {
    . (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')

    # ---- 1. On-disk redaction of secret material ----
    $logDir = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\logs'
    $logPath = Get-ApplicationLogFilePath
    Write-NSCloudLog -Severity 'Error' -Provider 'gdrive' -AccountId 'acc1' -AccountLabel 'Work' `
        -Operation 'startup-restore' -DurationMilliseconds 1234 -Recovered $false `
        -Message 'Auth failed: ya29.FAKETOKEN123 rejected, refresh_token=1//SECRET098, Authorization: Bearer abc123'
    Assert-True (Test-Path -LiteralPath $logPath) 'application.jsonl is created on demand'
    $raw = [System.IO.File]::ReadAllText($logPath)
    Assert-True ($raw -notmatch 'ya29\.FAKETOKEN123') 'access-token format is redacted on disk'
    Assert-True ($raw -notmatch '1//SECRET098') 'refresh-token format is redacted on disk'
    Assert-True ($raw -notmatch 'Bearer abc123') 'bearer header material is redacted on disk'
    Assert-True ($raw -match 'ya29\.\[REDACTED\]') 'redaction marker present for token formats'
    Assert-True ($raw -match '"severity"\s*:\s*"Error"') 'severity field persisted'
    Assert-True ($raw -match '"operation"\s*:\s*"startup-restore"') 'operation field persisted'
    Assert-True ($raw -match '"recovered"\s*:\s*false') 'recovery status persisted'
    Assert-True ($raw -match '"durationMs"\s*:\s*1234') 'duration persisted'

    # ---- 2. Bounded reads ----
    Write-NSCloudLog -Severity 'Info' -Operation 'reconnect' -Message 'second entry'
    Write-NSCloudLog -Severity 'Warning' -Operation 'status-refresh' -Message 'third entry'
    $all = @(Read-ApplicationLogEntries 800)
    Assert-True ($all.Count -eq 3) "all entries readable (found $($all.Count))"
    $tail = @(Read-ApplicationLogEntries 1)
    Assert-True ($tail.Count -eq 1 -and ([string]$tail[0].message) -eq 'third entry') 'tail read is bounded and newest-included'
    $olderPage = @(Read-ApplicationLogEntries -MaxEntries 1 -SkipEntries 1)
    Assert-True ($olderPage.Count -eq 1 -and ([string]$olderPage[0].message) -eq 'second entry') 'older page skips the newest entry'
    $oldestPage = @(Read-ApplicationLogEntries -MaxEntries 1 -SkipEntries 2)
    Assert-True ($oldestPage.Count -eq 1 -and ([string]$oldestPage[0].accountId) -eq 'acc1') 'pagination can reach the oldest retained entry'

    # ---- 3. Rotation bounds storage ----
    $script:ApplicationLogRotateBytes = 100   # shrink for the test only
    Write-NSCloudLog -Severity 'Info' -Operation 'reconnect' -Message 'fourth entry triggers rotation'
    Assert-True (Test-Path -LiteralPath ($logPath + '.1')) 'rotated predecessor file kept on overflow'
    $rotatedRaw = [System.IO.File]::ReadAllText(($logPath + '.1'))
    Assert-True ($rotatedRaw -match 'first|second|third') 'old entries live in the rotated file'
    $freshRaw = [System.IO.File]::ReadAllText($logPath)
    Assert-True ($freshRaw -match 'fourth entry triggers rotation') 'new entry lands in the main file after rotation'
    $script:ApplicationLogRotateBytes = 2MB

    # ---- 4. DiagnosticLogging=Off gates writes ----
    $settingsPath = Join-Path $env:LOCALAPPDATA 'NSCloudDrive\settings.json'
    @{ DiagnosticLogging = 'Off' } | ConvertTo-Json -Compress | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $script:ApplicationLogCheckState.ReadAt = [DateTime]::MinValue   # expire the 5 s cache
    $sizeBefore = (Get-Item -LiteralPath $logPath).Length
    Write-NSCloudLog -Severity 'Info' -Operation 'reconnect' -Message 'must not be written while logging is Off'
    $sizeAfter = (Get-Item -LiteralPath $logPath).Length
    Assert-True ($sizeAfter -eq $sizeBefore) 'no bytes written when DiagnosticLogging is Off'

    # ---- 5. Structural contract for the Logs page in the main UI ----
    $mainSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\NSCloudDrive.ps1') -Raw
    Assert-True ($mainSource -match '\$navLogsItem = New-NavButton') 'Logs navigation item exists'
    Assert-True ($mainSource -match '\$navLogsItem\.Button\.Add_Click\(\{ Show-LogsView \}\)') 'Logs nav click wired'
    Assert-True ($mainSource -match 'function Show-LogsView') 'Show-LogsView exists'
    foreach ($fn in @('Show-DisksView', 'Show-OptionsView', 'Show-HelpView', 'Show-AnalyticsView')) {
        $pattern = 'function ' + $fn + ' \{[\s\S]?[\s\S]*?\$logsView\.Visibility = \[System\.Windows\.Visibility\]::Collapsed'
        Assert-True ($mainSource -match $pattern) "$fn hides the Logs view when switching"
    }
    Assert-True ($mainSource -match 'Write-NSCloudLog -Severity \$reconSeverity -AccountId \$key -Operation ''reconnect''') 'reconnect outcomes are logged'
    Assert-True ($mainSource -match 'Write-NSCloudLog -Severity \$legacySeverity -Provider \$providerKey -Operation ''legacy-mount''') 'legacy mount outcomes are logged'
    Assert-True ($mainSource -match 'Write-NSCloudLog -Severity \$restoreSeverity -AccountId \$key -Operation ''startup-restore''') 'startup restore outcomes are logged'
    Assert-True ($mainSource -match "Write-NSCloudLog -Severity 'Error' -Operation 'status-refresh'") 'status refresh failures are logged'
    Assert-True ($mainSource -match '\$script:LastLoggedAutoMountErrorText') 'startup failure logs are deduplicated'
    Assert-True ($mainSource -match 'Read-ApplicationLogEntries -MaxEntries \(\$pageSize \+ 1\) -SkipEntries \$skipEntries') 'background page load requests a bounded page and one look-ahead entry'
    Assert-True ($mainSource -match '\$script:LogsPageSize = 200') 'log pages have a bounded page size'
    Assert-True ($mainSource -match '\$logsOlderBtn\.Add_Click' -and $mainSource -match '\$logsNewerBtn\.Add_Click') 'older and newer log page controls are wired'
    Assert-True ($mainSource -match 'Start-NSBackgroundOperation') 'log file parsing runs off the WPF dispatcher'
    Assert-True ($mainSource -match 'LogsLoadTimer') 'log page polls for completion without blocking navigation'
    Assert-True ($mainSource -match 'TotalSeconds -gt 10') 'slow log loading is cancelled with a visible timeout'
    Assert-True ($mainSource -match 'function Format-LogsEntryLine') 'entry formatting exists'
    Assert-True ($mainSource -match '\$logsSeverityCombo') 'severity filter exists'
    Assert-True ($mainSource -match '\$logsAccountCombo') 'account filter exists'
    Assert-True ($mainSource -match 'Clear-NSCloudLogsFolder') 'clear action exists'
    Assert-True ($mainSource -match 'function Clear-NSCloudLogsFolder \{[\s\S]{0,500}Stop-LogsViewLoad') 'clear cancels an in-flight log read before removing files'
    Assert-True ($mainSource -match 'Unable to clear logs:') 'log clear failures remain visible'
    Assert-True ($mainSource -match "'application\.jsonl\.1'") 'clear removes rotated generations too'
    Assert-True ($mainSource -match 'Stored locally: %LOCALAPPDATA%') 'privacy notice states what is stored'
    Assert-True ($mainSource -match 'replaced with \[REDACTED\]') 'privacy notice states redaction honestly'
    Assert-True ($mainSource -match 'rotates at 2 MB') 'privacy notice states the retention bound'
    $readerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1') -Raw
    Assert-True ($readerSource -match 'function Read-ApplicationLogEntries\(\[int\]\$MaxEntries = 200, \[int\]\$SkipEntries = 0') 'log reader supports bounded pagination'
    Assert-True ($readerSource -notmatch '\[System\.IO\.File\]::ReadAllLines\(\$logPath\)') 'log reader does not load the entire file into memory'

    Write-Output '  [PASS] Logs page contract verified.'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    # Everything the test wrote lives under $sandbox (it was LOCALAPPDATA).
    try { if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
}

if ($failed -gt 0) { throw "$failed logs assertions failed." }
Write-Output '  [PASS] Application log store verified (mocked/sandboxed).'
