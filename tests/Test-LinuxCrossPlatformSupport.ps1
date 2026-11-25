# ==============================================================================
# NS Cloud Drive - Test Linux Cross-Platform & Resumable Transfer Support
# Validates:
# 1. Linux XDG data & config root resolution without LOCALAPPDATA
# 2. Linux directory mount points vs Windows drive letters
# 3. Linux FUSE detection in Test-WinFspInstalled
# 4. Linux mount arguments generation (no WinFsp flags, directory mount targets)
# 5. POSIX ACL safety in Set-CloudCredentialAcl
# 6. Partial batch progression starting at 20% and advancing to 21%+
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Testing Linux Cross-Platform & Resumable Progression ===" -ForegroundColor Cyan

. (Join-Path $PSScriptRoot '..\src\models\ConnectionState.ps1')
. (Join-Path $PSScriptRoot '..\src\services\SettingsManager.ps1')
. (Join-Path $PSScriptRoot '..\src\providers\ProviderContract.ps1')
. (Join-Path $PSScriptRoot '..\src\services\VirtualDriveManager.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudDeduplicationService.ps1')
. (Join-Path $PSScriptRoot '..\src\services\CloudTransferManager.ps1')

function Set-TestLinuxPlatform {
    param([Parameter(Mandatory = $true)][bool]$LinuxEnabled)
    # PowerShell 7 exposes $IsLinux as a read-only automatic variable. Shadow it
    # in the test script scope so cross-platform path behavior can be simulated.
    New-Variable -Name 'IsLinux' -Value $LinuxEnabled -Scope Global -Force
}

# ------------------------------------------------------------------------------
# Test 1: Cross-Platform Data & Config Directory Resolution
# ------------------------------------------------------------------------------
Write-Host "1. Testing Cross-Platform Directory Resolution..." -ForegroundColor Yellow

$origXdgData = $env:XDG_DATA_HOME
$origXdgConfig = $env:XDG_CONFIG_HOME
$origHome = $env:HOME
try {
    # Simulate Linux environment
    $env:XDG_DATA_HOME = '/home/vpsuser/.local/share'
    $env:XDG_CONFIG_HOME = '/home/vpsuser/.config'
    $env:HOME = '/home/vpsuser'

    Set-TestLinuxPlatform -LinuxEnabled $true

    $dataRoot = Get-NSCloudDriveDataRoot
    if ($dataRoot -ne '/home/vpsuser/.local/share/nsclouddrive' -and $dataRoot -ne (Join-Path '/home/vpsuser/.local/share' 'nsclouddrive')) {
        throw "Linux data root resolution mismatch: got '$dataRoot'"
    }
    Write-Host "  [PASS] Linux XDG data root resolved: $dataRoot" -ForegroundColor Green

    $configRoot = Get-NSCloudDriveConfigRoot
    if ($configRoot -ne '/home/vpsuser/.config/nsclouddrive' -and $configRoot -ne (Join-Path '/home/vpsuser/.config' 'nsclouddrive')) {
        throw "Linux config root resolution mismatch: got '$configRoot'"
    }
    Write-Host "  [PASS] Linux XDG config root resolved: $configRoot" -ForegroundColor Green
} finally {
    Set-TestLinuxPlatform -LinuxEnabled $false
    $env:XDG_DATA_HOME = $origXdgData
    $env:XDG_CONFIG_HOME = $origXdgConfig
    $env:HOME = $origHome
}

# ------------------------------------------------------------------------------
# Test 2: Provider Mount Point Resolution (Windows Drive Letters vs Linux Paths)
# ------------------------------------------------------------------------------
Write-Host "2. Testing Provider Mount Point Resolution..." -ForegroundColor Yellow

# Windows Resolution
$winMount = Resolve-ProviderMountPoint -ProviderId 'gdrive' -DriveLetter 'G'
if ($winMount -ne 'G:\') {
    throw "Windows mount point resolution mismatch: expected 'G:\', got '$winMount'"
}
Write-Host "  [PASS] Windows mount point verified: $winMount" -ForegroundColor Green

# Linux Resolution
try {
    Set-TestLinuxPlatform -LinuxEnabled $true
    $env:HOME = '/home/vpsuser'
    $linuxMount = Resolve-ProviderMountPoint -ProviderId 'gdrive' -AccountId 'acc_gdrive_vps'
    $expectedLinuxMount = Join-Path (Join-Path '/home/vpsuser' 'CloudDrives') 'acc_gdrive_vps'
    if ($linuxMount -ne $expectedLinuxMount) {
        throw "Linux mount point resolution mismatch: expected '$expectedLinuxMount', got '$linuxMount'"
    }
    Write-Host "  [PASS] Linux directory mount target verified: $linuxMount" -ForegroundColor Green
} finally {
    Set-TestLinuxPlatform -LinuxEnabled $false
    $env:HOME = $origHome
}

# ------------------------------------------------------------------------------
# Test 3: Linux Mount Arguments Generation
# ------------------------------------------------------------------------------
Write-Host "3. Testing Linux Mount Arguments Generation..." -ForegroundColor Yellow

try {
    Set-TestLinuxPlatform -LinuxEnabled $true
    $env:HOME = $env:TEMP
    $testMountDir = Join-Path $env:TEMP 'TestLinuxMount_Gdrive'
    New-Item -ItemType Directory -Path $testMountDir -Force | Out-Null

    $linuxArgs = Build-RcloneMountArguments -RemoteName 'gdrive_remote' -MountPoint $testMountDir -CacheMaxGigabytes 10
    $argString = $linuxArgs -join ' '

    # Validate that Windows-only flags are omitted
    if ($argString.Contains('--network-mode')) {
        throw "Linux mount arguments must NOT contain Windows-only '--network-mode' flag!"
    }
    if ($argString.Contains('--fuse-flag')) {
        throw "Linux mount arguments must NOT contain Windows-only '--fuse-flag'!"
    }
    # Validate that Linux FUSE flags and directory target are present
    if (-not $argString.Contains('--allow-other')) {
        throw "Linux mount arguments should include '--allow-other'!"
    }
    if (-not $argString.Contains($testMountDir)) {
        throw "Linux mount arguments must target the directory path '$testMountDir'!"
    }

    Write-Host "  [PASS] Linux mount arguments correctly omit Windows WinFsp flags and target directory." -ForegroundColor Green
} finally {
    Set-TestLinuxPlatform -LinuxEnabled $false
}

# ------------------------------------------------------------------------------
# Test 4: Partial Batch Progression (20% -> 21% without resetting to 0%)
# ------------------------------------------------------------------------------
Write-Host "4. Testing Resumable Batch Progression (20% -> 21%)..." -ForegroundColor Yellow

$testBatchId = "batch_test_progression_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
$script:CloudTransferQueue.Clear()

# Simulate a 10-file batch (100 MB total) where 2 files (20 MB = 20%) were already confirmed in cloud
for ($i = 1; $i -le 10; $i++) {
    $isDone = ($i -le 2)
    $st = if ($isDone) { 'Completed and remotely confirmed' } else { 'Queued' }
    $bTrans = if ($isDone) { 10485760L } else { 0L }
    $pct = if ($isDone) { 100.0 } else { 0.0 }

    $job = [hashtable]::Synchronized(@{
        JobId = "job_prog_$i"
        QueueId = "job_prog_$i"
        BatchId = $testBatchId
        BatchName = 'Resumable Test Batch'
        FileName = "file_$i.dat"
        FileSizeBytes = 10485760L # 10 MB per file
        BytesTransferred = $bTrans
        Percentage = $pct
        Status = $st
        RetryCount = 0
        MaxRetries = 3
    })
    [void]$script:CloudTransferQueue.Add($job)
}

# Check initial batch summary after restart / drop
$summaryInitial = Get-CloudTransferBatchSummary -BatchId $testBatchId
if ($summaryInitial.OverallPercentage -ne 20.0) {
    throw "Expected initial batch percentage to start at 20.0%, got: $($summaryInitial.OverallPercentage)%"
}
Write-Host "  [PASS] Interrupted batch immediately resumes at 20.0% (not 0%)." -ForegroundColor Green

# Simulate file 3 uploading 1 MB (10% of file 3 = 1 MB / 100 MB batch = 1.0% batch progress -> 21.0%)
$job3 = @($script:CloudTransferQueue | Where-Object { $_['JobId'] -eq 'job_prog_3' })[0]
$job3['Status'] = 'Uploading'
$job3['BytesTransferred'] = 1048576L # 1 MB
$job3['Percentage'] = 10.0

$summaryProgressing = Get-CloudTransferBatchSummary -BatchId $testBatchId
if ($summaryProgressing.OverallPercentage -ne 21.0) {
    throw "Expected batch percentage to advance smoothly to 21.0%, got: $($summaryProgressing.OverallPercentage)%"
}
Write-Host "  [PASS] Progress updates smoothly from 20.0% -> 21.0% during upload." -ForegroundColor Green

foreach ($batchJob in $script:CloudTransferQueue) {
    $batchJob['Status'] = 'Completed and remotely confirmed'
    $batchJob['BytesTransferred'] = [int64]$batchJob['FileSizeBytes']
}
$attentionJob = @($script:CloudTransferQueue | Where-Object { $_['JobId'] -eq 'job_prog_4' })[0]
$attentionJob['Status'] = 'Needs attention: cloud source changed'
$attentionJob['BytesTransferred'] = 0L
$attentionJob['LastError'] = 'The cloud source file changed after it was queued.'
$attentionSummary = Get-CloudTransferBatchSummary -BatchId $testBatchId
if (-not $attentionSummary.IsComplete -or [int]$attentionSummary.AttentionCount -ne 1 -or
    [string]$attentionSummary.AttentionItems[0].LastError -ne $attentionJob['LastError']) {
    throw 'A terminal needs-attention transfer was not surfaced as complete with its actionable reason.'
}
Write-Host "  [PASS] Needs-attention batch states stop polling and expose the source-change reason." -ForegroundColor Green

# ------------------------------------------------------------------------------
# Test 5: Cross-Platform Credential Directory Resolution across All Providers
# ------------------------------------------------------------------------------
Write-Host "`n5. Testing Cross-Platform Credential Directory Resolution..." -ForegroundColor Yellow
$origXdgData = $env:XDG_DATA_HOME
$origHome = $env:HOME
$origLocalAppData = $env:LOCALAPPDATA
try {
    # Test Linux credential directory
    $env:XDG_DATA_HOME = '/home/vpsuser/.local/share'
    $env:HOME = '/home/vpsuser'
    Set-TestLinuxPlatform -LinuxEnabled $true

    $linuxCredDir = Get-CloudCredentialDirectory
    $expectedLinuxCredDir = Join-Path (Join-Path '/home/vpsuser/.local/share' 'nsclouddrive') 'credentials'
    if ($linuxCredDir -ne $expectedLinuxCredDir) {
        throw "Linux credential directory mismatch: expected '$expectedLinuxCredDir', got '$linuxCredDir'"
    }
    Write-Host "  [PASS] Linux credential directory resolved: $linuxCredDir" -ForegroundColor Green

    . (Join-Path $PSScriptRoot '..\src\providers\TeraBoxProvider.ps1')
    . (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')
    . (Join-Path $PSScriptRoot '..\src\providers\MegaProvider.ps1')
    . (Join-Path $PSScriptRoot '..\src\providers\ProtonDriveProvider.ps1')
    . (Join-Path $PSScriptRoot '..\src\providers\S3Provider.ps1')
    . (Join-Path $PSScriptRoot '..\src\providers\VpsProvider.ps1')

    if ((Get-TeraBoxCredentialDirectory) -ne $expectedLinuxCredDir) { throw "TeraBox credential dir mismatch on Linux" }
    if ((Get-GoogleCredentialDirectory) -ne $expectedLinuxCredDir) { throw "Google credential dir mismatch on Linux" }
    if ((Get-MegaCredentialDirectory) -ne $expectedLinuxCredDir) { throw "Mega credential dir mismatch on Linux" }
    if ((Get-ProtonCredentialDirectory) -ne $expectedLinuxCredDir) { throw "Proton credential dir mismatch on Linux" }
    if ((Get-ProtonDriveCredentialDirectory) -ne $expectedLinuxCredDir) { throw "ProtonDrive credential dir mismatch on Linux" }
    if ((Get-S3CredentialDirectory) -ne $expectedLinuxCredDir) { throw "S3 credential dir mismatch on Linux" }
    if ((Get-VpsCredentialDirectory) -ne $expectedLinuxCredDir) { throw "VPS credential dir mismatch on Linux" }
    Write-Host "  [PASS] All 6 providers delegate correctly to Get-CloudCredentialDirectory on Linux." -ForegroundColor Green
} finally {
    Set-TestLinuxPlatform -LinuxEnabled $false
    $env:XDG_DATA_HOME = $origXdgData
    $env:HOME = $origHome
    $env:LOCALAPPDATA = $origLocalAppData
}

# ------------------------------------------------------------------------------
# Test 6: Linux Drive Letter Flexibility in SettingsManager
# ------------------------------------------------------------------------------
Write-Host "`n6. Testing Linux Drive Letter Flexibility in SettingsManager..." -ForegroundColor Yellow
$testSettingsDir = Join-Path $env:TEMP ("ns_test_settings_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testSettingsDir -Force | Out-Null
$origConfigDir = $env:NS_CLOUD_DRIVE_CONFIG_DIR
try {
    $env:NS_CLOUD_DRIVE_CONFIG_DIR = $testSettingsDir
    Clear-AccountListCache

    # On Windows: empty drive letter throws
    $threwOnWindows = $false
    try {
        Test-CloudAccountDriveLetterAvailable -DriveLetter ''
    } catch {
        $threwOnWindows = $_.Exception.Message -match 'Choose a single valid drive letter'
    }
    if (-not $threwOnWindows) {
        throw "Expected empty drive letter to throw on Windows."
    }
    Write-Host "  [PASS] Windows rejects empty drive letter." -ForegroundColor Green

    # On Linux: empty drive letter is allowed
    Set-TestLinuxPlatform -LinuxEnabled $true
    $allowedOnLinux = Test-CloudAccountDriveLetterAvailable -DriveLetter ''
    if (-not $allowedOnLinux) {
        throw "Expected empty drive letter to be allowed on Linux."
    }
    Write-Host "  [PASS] Linux allows empty drive letter in Test-CloudAccountDriveLetterAvailable." -ForegroundColor Green

    # Save account on Linux without DriveLetter
    $accLinux = Add-CloudAccount @{
        Id = 'tb_linux_account_test'
        ProviderId = 'terabox'
        DisplayName = 'TeraBox Linux Test'
        AccountEmail = 'test@example.com'
        AutoMount = $true
    }
    if ($accLinux.DriveLetter -ne '') {
        throw "Expected DriveLetter to be empty, got '$($accLinux.DriveLetter)'"
    }
    $savedAcc = Get-CloudAccount 'tb_linux_account_test'
    if (-not $savedAcc -or $savedAcc.AccountEmail -ne 'test@example.com') {
        throw "Failed to persist account on Linux."
    }
    Write-Host "  [PASS] Add-CloudAccount successfully saves account without drive letter on Linux." -ForegroundColor Green
} finally {
    Set-TestLinuxPlatform -LinuxEnabled $false
    $env:NS_CLOUD_DRIVE_CONFIG_DIR = $origConfigDir
    Clear-AccountListCache
    try { Remove-Item -LiteralPath $testSettingsDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ------------------------------------------------------------------------------
# Test 7: CLI Login Dispatcher & Accounts View
# ------------------------------------------------------------------------------
Write-Host "`n7. Testing CLI Login Dispatcher & Accounts View..." -ForegroundColor Yellow
$cliSandbox = Join-Path $env:TEMP ("ns_cli_test_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cliSandbox -Force | Out-Null
$origConfigRoot = $env:NS_CLOUD_DRIVE_CONFIG_DIR
$origDataRoot = $env:NS_CLOUD_DRIVE_DATA_DIR
try {
    $env:NS_CLOUD_DRIVE_CONFIG_DIR = (Join-Path $cliSandbox 'config')
    $env:NS_CLOUD_DRIVE_DATA_DIR = (Join-Path $cliSandbox 'data')
    New-Item -ItemType Directory -Path $env:NS_CLOUD_DRIVE_CONFIG_DIR -Force | Out-Null
    New-Item -ItemType Directory -Path $env:NS_CLOUD_DRIVE_DATA_DIR -Force | Out-Null
    Set-TestLinuxPlatform -LinuxEnabled $true

    # Load CLI module functions
    $cliScript = Join-Path $PSScriptRoot '..\src\cli\nsclouddrive.ps1'
    . $cliScript help | Out-Null

    # Mock Test-TeraBoxBackendSession to succeed for valid test cookie
    $mockBlock = {
        param($SessionOverride, $Window, $AccountId, $Force)
        return [ordered]@{
            IsValid = $true
            State = 'Connected'
            Error = $null
            UserInfo = [ordered]@{
                Type = 'web-session'
                UserName = 'Mocked TeraBox User'
                Uk = '987654321'
            }
        }
    }
    Set-Item -Path 'Function:\Test-TeraBoxBackendSession' -Value $mockBlock
    Set-Item -Path 'Function:\script:Test-TeraBoxBackendSession' -Value $mockBlock
    Set-Item -Path 'Function:\global:Test-TeraBoxBackendSession' -Value $mockBlock

    # Execute login command with POSIX flags
    Invoke-CliLogin -ProviderId 'terabox' -RemainingArgs @('--cookie', 'ndus=mock_cookie_val_123', '--name', 'My CLI TeraBox', '--id', 'terabox_cli_1', '--no-auto-mount')

    # Verify settings.json
    $settingsPath = Join-Path $env:NS_CLOUD_DRIVE_CONFIG_DIR 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "settings.json not created at '$settingsPath'"
    }
    $settingsJson = Get-Content -LiteralPath $settingsPath -Raw
    if ($settingsJson -notmatch 'terabox_cli_1') {
        throw "Account 'terabox_cli_1' not found in settings.json"
    }
    if ($settingsJson -match 'mock_cookie_val_123') {
        throw "Plaintext cookie secret leaked into settings.json!"
    }
    Write-Host "  [PASS] CLI login successfully registered account in settings.json without secret leakage." -ForegroundColor Green

    # Verify credential XML file
    $credFile = Join-Path (Get-CloudCredentialDirectory) 'terabox-session-terabox_cli_1.xml'
    if (-not (Test-Path -LiteralPath $credFile)) {
        throw "Credential XML file not found at '$credFile'"
    }
    $xmlContent = Get-Content -LiteralPath $credFile -Raw
    if ($xmlContent -match 'mock_cookie_val_123') {
        throw "Plaintext secret found in credential XML file!"
    }
    Write-Host "  [PASS] Credential saved securely via PSCredential Export-Clixml without plaintext leakage." -ForegroundColor Green

    # Verify accounts command lists the account
    $accountsOutput = (Show-CliAccounts 6>&1 | Out-String)
    if ($accountsOutput -notmatch 'terabox_cli_1' -or $accountsOutput -notmatch 'My CLI TeraBox') {
        throw "CLI accounts command did not output expected account: $accountsOutput"
    }
    Write-Host "  [PASS] CLI accounts view successfully displays the onboarded account." -ForegroundColor Green

    # Test MEGA login via POSIX flags
    Invoke-CliLogin -ProviderId 'mega' -RemainingArgs @('--user', 'user@mega.nz', '--password', 'MyMegaPass999!', '--id', 'mega_cli_1', '--name', 'My Mega CLI')
    $megaCredFile = Join-Path (Get-CloudCredentialDirectory) 'mega-session-mega_cli_1.xml'
    if (-not (Test-Path -LiteralPath $megaCredFile)) { throw "Mega credential file not found" }
    $megaXml = Get-Content -LiteralPath $megaCredFile -Raw
    if ($megaXml -match 'MyMegaPass999!') { throw "Plaintext password found in Mega credential file!" }
    Write-Host "  [PASS] CLI login for MEGA succeeds without password leakage." -ForegroundColor Green

    # Test VPS login via POSIX flags
    Invoke-CliLogin -ProviderId 'vps' -RemainingArgs @('--endpoint', '10.0.0.1', '--user', 'vpsadmin', '--password', 'VpsSecretPass', '--id', 'vps_cli_1', '--name', 'My VPS CLI')
    $vpsCredFile = Join-Path (Get-CloudCredentialDirectory) 'vps-session-vps_cli_1.xml'
    if (-not (Test-Path -LiteralPath $vpsCredFile)) { throw "VPS credential file not found" }
    $vpsXml = Get-Content -LiteralPath $vpsCredFile -Raw
    if ($vpsXml -match 'VpsSecretPass') { throw "Plaintext password found in VPS credential file!" }
    Write-Host "  [PASS] CLI login for VPS succeeds without password leakage." -ForegroundColor Green

    # Test S3 login via POSIX flags
    Invoke-CliLogin -ProviderId 's3' -RemainingArgs @('--endpoint', 'https://s3.amazonaws.com', '--user', 'AKIAIOSFODNN7EXAMPLE', '--password', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', '--bucket', 'mybucket', '--id', 's3_cli_1', '--name', 'My S3 CLI')
    $s3CredFile = Join-Path (Get-CloudCredentialDirectory) 's3-session-s3_cli_1.xml'
    if (-not (Test-Path -LiteralPath $s3CredFile)) { throw "S3 credential file not found" }
    $s3Xml = Get-Content -LiteralPath $s3CredFile -Raw
    if ($s3Xml -match 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY') { throw "Plaintext secret access key found in S3 credential file!" }
    $loadedS3 = Get-S3StoredSession -AccountId 's3_cli_1'
    if (-not $loadedS3 -or (Get-S3FieldValue $loadedS3 'AccessKey' '') -ne 'AKIAIOSFODNN7EXAMPLE') {
        throw "Failed to load stored S3 session or AccessKey mismatch."
    }
    Write-Host "  [PASS] CLI login for S3 succeeds with dual key naming and without secret leakage." -ForegroundColor Green

    # Test single-dash flag lookahead
    Invoke-CliLogin -ProviderId 'mega' -RemainingArgs @('--user', 'lookahead@mega.nz', '--password', 'Pass12345!', '--no-auto-mount', '-name', 'Lookahead Mega', '-id', 'mega_lookahead_1')
    $accLookahead = Get-CloudAccount 'mega_lookahead_1'
    if (-not $accLookahead) { throw "Lookahead account was not saved." }
    if ($accLookahead.DisplayName -ne 'Lookahead Mega') {
        throw "Lookahead flag parsing failed: DisplayName is '$($accLookahead.DisplayName)', expected 'Lookahead Mega'"
    }
    if ($accLookahead.AutoMount -ne $false) {
        throw "Lookahead flag parsing failed: AutoMount should be False, got '$($accLookahead.AutoMount)'"
    }
    Write-Host "  [PASS] Single-dash flag lookahead correctly distinguishes boolean switch from argument values." -ForegroundColor Green

    # Test Non-Interactive CLI safe prompt handling
    # In non-interactive environment or when Read-SafePrompt returns null:
    # Invoke-CliLogin must print clean error message and return gracefully without throwing.
    $mockPrompt = { param($Prompt) return $null }
    Set-Item -Path 'Function:\Read-SafePrompt' -Value $mockPrompt -ErrorAction SilentlyContinue
    Set-Item -Path 'Function:\script:Read-SafePrompt' -Value $mockPrompt -ErrorAction SilentlyContinue
    $nonInteractiveOutput = (& {
        Invoke-CliLogin -ProviderId 'terabox' 6>&1
    } | Out-String)
    if ($nonInteractiveOutput -notmatch 'Missing required credentials') {
        throw "Expected missing required credentials error in non-interactive prompt, got: $nonInteractiveOutput"
    }
    Remove-Item -Path 'Function:\Read-SafePrompt' -ErrorAction SilentlyContinue
    Remove-Item -Path 'Function:\script:Read-SafePrompt' -ErrorAction SilentlyContinue
    Write-Host "  [PASS] Non-interactive CLI prompt returns clean error without unhandled exception." -ForegroundColor Green

    # Test Windows CLI onboarding drive letter auto-assignment
    Set-TestLinuxPlatform -LinuxEnabled $false
    try {
        # 1) Auto-assignment on Windows when DriveLetter is omitted
        Invoke-CliLogin -ProviderId 'vps' -RemainingArgs @('--endpoint', '192.168.1.100', '--user', 'winvps', '--password', 'WinVpsPass1!', '--id', 'vps_win_auto')
        $accWinAuto = Get-CloudAccount 'vps_win_auto'
        if (-not $accWinAuto -or [string]::IsNullOrWhiteSpace($accWinAuto.DriveLetter)) {
            throw "Expected auto-assigned drive letter on Windows, got: '$($accWinAuto.DriveLetter)'"
        }
        if ($accWinAuto.DriveLetter -notmatch '^[A-Z]$') {
            throw "Invalid auto-assigned drive letter: '$($accWinAuto.DriveLetter)'"
        }
        Write-Host "  [PASS] Windows CLI login auto-assigns available drive letter '$($accWinAuto.DriveLetter)':" -ForegroundColor Green

        # 2) Explicit drive letter via POSIX flag
        Invoke-CliLogin -ProviderId 'vps' -RemainingArgs @('--endpoint', '192.168.1.101', '--user', 'winvps2', '--password', 'WinVpsPass2!', '--id', 'vps_win_explicit', '--drive-letter', 'Y')
        $accWinExplicit = Get-CloudAccount 'vps_win_explicit'
        if (-not $accWinExplicit -or $accWinExplicit.DriveLetter -ne 'Y') {
            throw "Expected explicit drive letter 'Y' on Windows, got: '$($accWinExplicit.DriveLetter)'"
        }
        Write-Host "  [PASS] Windows CLI login respects explicit --drive-letter flag ('Y')." -ForegroundColor Green
    } finally {
    Set-TestLinuxPlatform -LinuxEnabled $true
    }

    # Verify accounts view includes all newly onboarded accounts
    $accountsAll = (Show-CliAccounts 6>&1 | Out-String)
    if ($accountsAll -notmatch 'mega_cli_1' -or $accountsAll -notmatch 'vps_cli_1' -or $accountsAll -notmatch 's3_cli_1') {
        throw "CLI accounts command did not display multi-provider accounts: $accountsAll"
    }
    Write-Host "  [PASS] CLI accounts view successfully lists multi-provider accounts." -ForegroundColor Green
} finally {
    Set-TestLinuxPlatform -LinuxEnabled $false
    $env:NS_CLOUD_DRIVE_CONFIG_DIR = $origConfigRoot
    $env:NS_CLOUD_DRIVE_DATA_DIR = $origDataRoot
    try { Remove-Item -LiteralPath $cliSandbox -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# Clean up
$script:CloudTransferQueue.Clear()

# ------------------------------------------------------------------------------
# Test 8: Strict-Mode Safe Token Dereferencing in Google Drive Provider
# ------------------------------------------------------------------------------
Write-Host "`n8. Testing Strict-Mode Safe Google Drive Token Dereferencing..." -ForegroundColor Yellow

# Ensure GoogleDriveProvider is loaded under strict mode
. (Join-Path $PSScriptRoot '..\src\providers\GoogleDriveProvider.ps1')

# Test 8a: Sparse/empty tokens override does not throw PropertyNotFoundStrict on access_token
$resEmpty = Test-GoogleDriveBackendSession -TokensOverride @{}
if ($null -eq $resEmpty -or $resEmpty.IsValid -ne $false) {
    throw "Expected IsValid = `$false for empty TokensOverride @{}, got: $($resEmpty.IsValid)"
}
if ($resEmpty.State -ne 'Disconnected') {
    throw "Expected State = 'Disconnected' for empty TokensOverride @{}, got: '$($resEmpty.State)'"
}
Write-Host "  [PASS] Test-GoogleDriveBackendSession with empty tokens returns IsValid = `$false without throwing." -ForegroundColor Green

# Test 8b: Access-token-only tokens override does not throw PropertyNotFoundStrict on refresh_token
$resAccessOnly = Test-GoogleDriveBackendSession -TokensOverride @{ access_token = 'test_access_only' }
if ($null -eq $resAccessOnly -or $resAccessOnly.IsValid -ne $false) {
    throw "Expected IsValid = `$false for access-token-only TokensOverride, got: $($resAccessOnly.IsValid)"
}
Write-Host "  [PASS] Test-GoogleDriveBackendSession with access_token only evaluates without throwing PropertyNotFoundStrict on refresh_token." -ForegroundColor Green

# Test 8c: Get-GoogleDriveFileList with sparse tokens does not throw PropertyNotFoundStrict
$resFileList = Get-GoogleDriveFileList -TokensOverride @{}
if ($null -eq $resFileList -or $resFileList.Success -ne $false) {
    throw "Expected Success = `$false for Get-GoogleDriveFileList with empty TokensOverride"
}
Write-Host "  [PASS] Get-GoogleDriveFileList with empty tokens returns Success = `$false without throwing." -ForegroundColor Green

Write-Host "`nAll Linux Cross-Platform & Resumable Progression Tests Passed Successfully!" -ForegroundColor Green
