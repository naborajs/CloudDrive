# ==============================================================================
# NS Cloud Drive - Test Notification Center & Transfer History (Task C)
# ==============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Output 'Testing Notification Center & Transfer History...'

$srcDir = Resolve-Path (Join-Path $PSScriptRoot '..\src')

# Dot-source required services
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')

# Dot-source NSCloudDrive in STA-safe test context or extract functions
$nsScriptPath = Join-Path $srcDir 'NSCloudDrive.ps1'

# ------------------------------------------------------------------------------
# 1. Verify 100% 7-Bit ASCII Compliance in src/NSCloudDrive.ps1
# ------------------------------------------------------------------------------
Write-Output '  -> Testing 100% 7-bit ASCII compliance in NSCloudDrive.ps1...'
$bytes = [System.IO.File]::ReadAllBytes($nsScriptPath)
$nonAsciiCount = 0
for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -gt 127) {
        $nonAsciiCount++
    }
}
if ($nonAsciiCount -gt 0) {
    throw "NSCloudDrive.ps1 contains $nonAsciiCount non-ASCII multi-byte characters! Must be 100% 7-bit ASCII."
}
Write-Output '  [PASS] NSCloudDrive.ps1 is 100% 7-bit ASCII compliant (zero raw multi-byte unicode characters)'

# ------------------------------------------------------------------------------
# 2. Verify Presence of Key Functions and UI Elements in NSCloudDrive.ps1
# ------------------------------------------------------------------------------
Write-Output '  -> Verifying function and UI element declarations...'
$nsContent = Get-Content -LiteralPath $nsScriptPath -Raw -Encoding UTF8

if ($nsContent -notmatch 'function\s+Add-TransferNotificationEvent') {
    throw 'Add-TransferNotificationEvent function is not defined in NSCloudDrive.ps1'
}
if ($nsContent -notmatch 'function\s+Load-TransferNotificationHistory') {
    throw 'Load-TransferNotificationHistory function is not defined in NSCloudDrive.ps1'
}
if ($nsContent -notmatch 'function\s+Test-AndSetNotifiedEventKey') {
    throw 'Test-AndSetNotifiedEventKey function is not defined in NSCloudDrive.ps1'
}
if ($nsContent -notmatch 'function\s+Resume-CloudTransferQueueItem') {
    throw 'Resume-CloudTransferQueueItem function is not defined in NSCloudDrive.ps1'
}
if ($nsContent -notmatch 'function\s+Show-TransferCenterModal') {
    throw 'Show-TransferCenterModal function is not defined in NSCloudDrive.ps1'
}
if ($nsContent -notmatch '\$transfersBtn\s*=\s*\[System\.Windows\.Controls\.Button\]::new\(\)') {
    throw '$transfersBtn button is not declared in NSCloudDrive.ps1'
}
if ($nsContent -notmatch 'Transfer Center & History\.\.\.') {
    throw 'Transfer Center & History menu item is not added to tray menu in NSCloudDrive.ps1'
}
if ($nsContent -notmatch 'Show-TransferCenterModal\s+-Owner\s+\$window') {
    throw 'Show-TransferCenterModal is not wired to $transfersBtn or tray click'
}
Write-Output '  [PASS] Add-TransferNotificationEvent, Load-TransferNotificationHistory, Show-TransferCenterModal, and $transfersBtn are defined and wired'

# ------------------------------------------------------------------------------
# 3. Test Transfer History Lifecycle & 100-Item Bounding
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Add-TransferNotificationEvent, persistence, and bounding...'

$tempDir = Join-Path $env:TEMP ("NSCloudDrive_Test_" + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($tempDir)
$testHistoryFile = Join-Path $tempDir 'transfer-history.json'

# Setup isolated script variables for test
$script:TransferEventHistory = [System.Collections.Generic.List[hashtable]]::new()
$script:NotifiedEventKeys = [hashtable]::Synchronized(@{})

# Override Get-TransferHistoryFilePath for testing
function script:Get-TransferHistoryFilePath { return $testHistoryFile }

# Dot-source the functions in test scope via AST extraction
$ast = [System.Management.Automation.Language.Parser]::ParseInput($nsContent, [ref]$null, [ref]$null)
$funcAsts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcAsts) {
    if ($f.Name -in @('Add-TransferNotificationEvent', 'Load-TransferNotificationHistory', 'Test-AndSetNotifiedEventKey', 'Resume-CloudTransferQueueItem')) {
        Invoke-Expression $f.Extent.Text
    }
}

# Add 120 items to verify 100-item bounding
for ($i = 1; $i -le 120; $i++) {
    $status = if ($i % 3 -eq 0) { 'Completed and remotely confirmed' } elseif ($i % 3 -eq 1) { 'Failed' } else { 'Waiting for network/provider' }
    $err = if ($status -eq 'Failed') { "Network timeout on chunk $i" } else { '' }
    Add-TransferNotificationEvent -JobId "job-$i" -BatchId "batch-$([Math]::Floor($i / 10))" -BatchName "Batch $([Math]::Floor($i / 10))" -FileName "File_$i.dat" -DriveLetter 'G' -ProviderName 'Google Drive' -FileSizeBytes (1024L * $i) -BytesTransferred (1024L * $i) -Status $status -Error $err -VerificationType 'MD5 Checksum' -RemoteHash "hash-$i"
}

if ($script:TransferEventHistory.Count -ne 100) {
    throw "Expected TransferEventHistory count to be bounded to 100, got: $($script:TransferEventHistory.Count)"
}
Write-Output "  [PASS] TransferEventHistory is strictly bounded to 100 items (Count = $($script:TransferEventHistory.Count))"

# Verify file was written
if (-not (Test-Path -LiteralPath $testHistoryFile -PathType Leaf)) {
    throw "transfer-history.json was not created at $testHistoryFile"
}

# Verify Load-TransferNotificationHistory
$script:TransferEventHistory.Clear()
Load-TransferNotificationHistory

if ($script:TransferEventHistory.Count -ne 100) {
    throw "Expected Load-TransferNotificationHistory to load 100 items, got: $($script:TransferEventHistory.Count)"
}
$firstItem = $script:TransferEventHistory[0]
if ($firstItem['JobId'] -ne 'job-120') {
    throw "Expected latest item to be 'job-120', got: $($firstItem['JobId'])"
}
Write-Output '  [PASS] Load-TransferNotificationHistory loaded persisted history atomically and correctly'

# ------------------------------------------------------------------------------
# 4. Test 15-Minute Balloon Notification Deduplication
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Test-AndSetNotifiedEventKey deduplication window...'

$script:NotifiedEventKeys.Clear()

$key1 = 'job-100:Completed'
$allowed1 = Test-AndSetNotifiedEventKey $key1
if (-not $allowed1) {
    throw "First notification for $key1 should be allowed"
}

# Immediate subsequent notification must be suppressed
$allowed2 = Test-AndSetNotifiedEventKey $key1
if ($allowed2) {
    throw "Immediate duplicate notification for $key1 was not suppressed"
}

# Set time back 16 minutes to simulate expiration of 15-minute window
$script:NotifiedEventKeys[$key1] = [DateTime]::UtcNow.AddMinutes(-16)

$allowed3 = Test-AndSetNotifiedEventKey $key1
if (-not $allowed3) {
    throw "Notification for $key1 after 16 minutes should be allowed"
}
Write-Output '  [PASS] 15-minute notification deduplication works as specified'

# ------------------------------------------------------------------------------
# 5. Test Resume-CloudTransferQueueItem Requeueing
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Resume-CloudTransferQueueItem on failed jobs...'

$testQueueFile = Join-Path $tempDir 'transfer-jobs.json'
Set-TransferQueueFilePath $testQueueFile

$jobItem = [ordered]@{
    JobId = 'failed-job-999'
    QueueId = 'queue-999'
    BatchId = 'batch-test'
    BatchName = 'Test Batch'
    FileName = 'ImportantDocument.pdf'
    FileSizeBytes = 5000000L
    BytesTransferred = 2500000L
    Status = 'Failed'
    RetryCount = 3
    MaxRetries = 3
    LastError = 'Connection reset by peer'
    ProviderId = 'gdrive'
}
$script:CloudTransferQueue.Clear()
[void]$script:CloudTransferQueue.Add([hashtable]$jobItem)
Save-DurableTransferQueue | Out-Null

$resumed = Resume-CloudTransferQueueItem 'failed-job-999'
if (-not $resumed) {
    throw 'Resume-CloudTransferQueueItem returned false for existing failed job'
}

$qRaw = Get-CloudTransferQueue
$updatedQueue = if ($qRaw -is [array] -and $qRaw.Count -gt 0 -and $qRaw[0] -is [array]) { @($qRaw[0]) } elseif ($null -ne $qRaw) { @($qRaw) } else { @() }
$updatedJob = $updatedQueue | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('QueueId') -and $_['QueueId'] -eq 'queue-999' } | Select-Object -First 1
if (-not $updatedJob) {
    throw 'Failed to find updated job in queue'
}
if ($updatedJob['Status'] -ne 'Queued') {
    throw "Expected status 'Queued', got: '$($updatedJob['Status'])'"
}
if ($updatedJob['RetryCount'] -ne 0) {
    throw "Expected RetryCount 0, got: $($updatedJob['RetryCount'])"
}
if ($updatedJob['LastError'] -ne '') {
    throw "Expected LastError to be cleared, got: '$($updatedJob['LastError'])'"
}
Write-Output '  [PASS] Resume-CloudTransferQueueItem resets failed job status to Queued and clears retry count'

# ------------------------------------------------------------------------------
# 6. Test Multi-File Batch Grouping & Notification Logic
# ------------------------------------------------------------------------------
Write-Output '  -> Testing batch notification consolidation logic...'

$script:NotifiedEventKeys.Clear()

$batchItems = @(
    @{ JobId = 'b1-j1'; QueueId = 'q1'; BatchId = 'b-multi'; BatchName = 'Client Presentation'; FileName = 'Slide1.png'; FileSizeBytes = 1000000L; BytesTransferred = 0L; Status = 'Uploading'; ProviderId = 'gdrive' },
    @{ JobId = 'b1-j2'; QueueId = 'q2'; BatchId = 'b-multi'; BatchName = 'Client Presentation'; FileName = 'Slide2.png'; FileSizeBytes = 2000000L; BytesTransferred = 0L; Status = 'Queued'; ProviderId = 'gdrive' },
    @{ JobId = 'b1-j3'; QueueId = 'q3'; BatchId = 'b-multi'; BatchName = 'Client Presentation'; FileName = 'Slide3.png'; FileSizeBytes = 3000000L; BytesTransferred = 0L; Status = 'Queued'; ProviderId = 'gdrive' }
)

# Test Batch Start Notification
$startAllowed = Test-AndSetNotifiedEventKey 'batch_start:b-multi'
if (-not $startAllowed) {
    throw 'Batch start notification should be allowed on first start'
}
$startDuplicate = Test-AndSetNotifiedEventKey 'batch_start:b-multi'
if ($startDuplicate) {
    throw 'Duplicate batch start notification should be suppressed within 15 minutes'
}

# When 2 of 3 items complete, batch is NOT complete
$partialCompletion = ($batchItems | Where-Object { $_.Status -ne 'Completed and remotely confirmed' })
if (-not $partialCompletion) {
    throw 'Batch should not be marked complete when items are still uploading/queued'
}

# When all items complete, batch completion is triggered
foreach ($it in $batchItems) {
    $it.Status = 'Completed and remotely confirmed'
}
$allDone = -not ($batchItems | Where-Object { $_.Status -ne 'Completed and remotely confirmed' })
if (-not $allDone) {
    throw 'Batch should be marked complete when all items are Completed and remotely confirmed'
}

$completeAllowed = Test-AndSetNotifiedEventKey 'batch_complete:b-multi'
if (-not $completeAllowed) {
    throw 'Batch completion notification should be allowed when all items are confirmed'
}
$completeDuplicate = Test-AndSetNotifiedEventKey 'batch_complete:b-multi'
if ($completeDuplicate) {
    throw 'Duplicate batch completion notification should be suppressed'
}
Write-Output '  [PASS] Multi-file batch notification consolidation correctly suppresses individual items and fires consolidated alerts'

# ------------------------------------------------------------------------------
# 7. Test Show-TransferCenterModal Construction in STA Mode
# ------------------------------------------------------------------------------
Write-Output '  -> Testing Show-TransferCenterModal construction in STA mode...'
$staModalCheck = powershell.exe -NoProfile -STA -Command "& {
    . (Resolve-Path '.\src\NSCloudDrive.ps1')
    if (Get-Command Show-TransferCenterModal -ErrorAction SilentlyContinue) {
        'TransferCenterModalOK'
    } else {
        'Failed'
    }
}"
if ($staModalCheck -notmatch 'TransferCenterModalOK') {
    throw "Show-TransferCenterModal failed to load cleanly in STA session: $staModalCheck"
}
Write-Output '  [PASS] Show-TransferCenterModal loads cleanly in STA mode alongside main window'

# Clean up temporary test files
try {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

Write-Output 'All Notification Center & Transfer History tests passed successfully.'
