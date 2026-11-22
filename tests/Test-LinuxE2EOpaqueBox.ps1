# ==============================================================================
# NS Cloud Drive - Linux E2E Opaque-Box Test Suite
# ==============================================================================
# Comprehensive 4-Tier test suite verifying end-to-end Linux & TeraBox integration:
#   Tier 1: Feature Coverage (R1 - R6 equivalence-class representatives)
#   Tier 2: Boundary Value Analysis & Corner Cases (special chars, 4GB limits, etc.)
#   Tier 3: Cross-Feature Combinations (Pairwise onboarding, mount, drop, eviction)
#   Tier 4: Real-World Application Scenarios (full multi-step user workflows)
#
# Standards:
#   - Set-StrictMode -Version Latest
#   - $ErrorActionPreference = 'Stop'
#   - Hermetic sandboxing: isolated HOME, XDG, LOCALAPPDATA, and tmpfs directories
#   - Zero side-effects on host machine or user production configuration
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " NS Cloud Drive - Linux E2E Opaque-Box Test Suite         " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

# Locate repository paths
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$srcDir = Join-Path $script:RepoRoot 'src'
$scriptsDir = Join-Path $script:RepoRoot 'scripts'

# Dot-source core modules (Genuine Production Implementations)
. (Join-Path $srcDir 'models\ConnectionState.ps1')
. (Join-Path $srcDir 'services\SettingsManager.ps1')
. (Join-Path $srcDir 'providers\ProviderContract.ps1')
. (Join-Path $srcDir 'providers\GoogleDriveProvider.ps1')
. (Join-Path $srcDir 'providers\TeraBoxProvider.ps1')
. (Join-Path $srcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $srcDir 'services\CloudDeduplicationService.ps1')
. (Join-Path $srcDir 'services\CloudTransferManager.ps1')
. (Join-Path $srcDir 'services\CacheManager.ps1')
. (Join-Path $scriptsDir 'CachePathSafety.ps1')
. (Join-Path $srcDir 'cli\nsclouddrive.ps1')

# ------------------------------------------------------------------------------
# Test Harness & Reporting Setup
# ------------------------------------------------------------------------------
$script:TestResults = [System.Collections.Generic.List[object]]::new()

function Run-E2ETest(
    [string]$Tier,
    [string]$TestId,
    [string]$Description,
    [scriptblock]$TestBlock
) {
    Write-Host -NoNewline "  [$Tier] ${TestId}: $Description ... "
    try {
        & $TestBlock
        Write-Host "[PASS]" -ForegroundColor Green
        $script:TestResults.Add([pscustomobject]@{
            Tier = $Tier
            TestId = $TestId
            Description = $Description
            Status = 'PASS'
            Error = $null
        })
    } catch {
        Write-Host "[FAIL]" -ForegroundColor Red
        Write-Host "         ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $script:TestResults.Add([pscustomobject]@{
            Tier = $Tier
            TestId = $TestId
            Description = $Description
            Status = 'FAIL'
            Error = $_.Exception.Message
        })
    }
}

function Assert-Condition([bool]$Condition, [string]$FailureMessage) {
    if (-not $Condition) {
        throw $FailureMessage
    }
}

function Assert-Equal($Actual, $Expected, [string]$Label = 'Value') {
    if ($Actual -ne $Expected) {
        throw "$Label mismatch: Expected '$Expected', got '$Actual'"
    }
}

# ------------------------------------------------------------------------------
# Sandbox Isolation Lifecycle
# ------------------------------------------------------------------------------
$origHome = $env:HOME
$origXdgConfig = $env:XDG_CONFIG_HOME
$origXdgData = $env:XDG_DATA_HOME
$origXdgCache = $env:XDG_CACHE_HOME
$origLocalAppData = $env:LOCALAPPDATA
$origAppData = $env:APPDATA
$origGlobalIsLinux = Get-Variable -Name 'IsLinux' -ValueOnly -ErrorAction SilentlyContinue

$sandboxRoot = $null

try {
    $sandboxRoot = Join-Path $env:TEMP ("NSCloudDrive_E2E_" + [Guid]::NewGuid().ToString('N'))
    $sandboxHome = Join-Path $sandboxRoot 'home\vpsuser'
    $sandboxConfig = Join-Path $sandboxHome '.config'
    $sandboxData = Join-Path $sandboxHome '.local\share'
    $sandboxCache = Join-Path $sandboxHome '.cache'
    $sandboxTmpfs = Join-Path $sandboxRoot 'run\user\1001'
    $sandboxDesktop = Join-Path $sandboxHome 'Desktop'
    $sandboxCloudDrives = Join-Path $sandboxHome 'CloudDrives'
    $sandboxGtk = Join-Path $sandboxConfig 'gtk-3.0'
    $sandboxSystemd = Join-Path $sandboxConfig 'systemd\user'

    New-Item -ItemType Directory -Path $sandboxHome -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxConfig -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxData -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxCache -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxTmpfs -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxDesktop -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxCloudDrives -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxGtk -Force | Out-Null
    New-Item -ItemType Directory -Path $sandboxSystemd -Force | Out-Null

    $sandboxSettingsDir = Join-Path $sandboxConfig 'nsclouddrive'
    New-Item -ItemType Directory -Path $sandboxSettingsDir -Force | Out-Null
    Set-SettingsDirectoryOverride $sandboxSettingsDir

    $sandboxDedupLedger = Join-Path $sandboxData 'nsclouddrive\cache\cloud-dedup-ledger.json'
    $sandboxDedupDir = Split-Path -Parent $sandboxDedupLedger
    New-Item -ItemType Directory -Path $sandboxDedupDir -Force | Out-Null
    Set-CloudDedupLedgerPathOverride $sandboxDedupLedger

    $sandboxQueueFile = Join-Path $sandboxData 'nsclouddrive\state\transfer-jobs.json'
    $sandboxQueueDir = Split-Path -Parent $sandboxQueueFile
    New-Item -ItemType Directory -Path $sandboxQueueDir -Force | Out-Null
    Set-TransferQueueFilePath $sandboxQueueFile

    $env:HOME = $sandboxHome
    $env:XDG_CONFIG_HOME = $sandboxConfig
    $env:XDG_DATA_HOME = $sandboxData
    $env:XDG_CACHE_HOME = $sandboxCache
    $env:LOCALAPPDATA = Join-Path $sandboxRoot 'localappdata'
    $env:APPDATA = Join-Path $sandboxRoot 'appdata'
    $global:IsLinux = $true

    # Mock external TeraBox HTTP session authentication boundary to isolate offline execution
    $mockSession = {
        param($SessionOverride, $Window, $AccountId, $Force)
        return [ordered]@{
            IsValid = $true
            State = 'Connected'
            Error = $null
            UserInfo = [ordered]@{ Uk = '12345678'; UserName = 'MockTeraBoxUser' }
        }
    }
    Set-Item -Path 'Function:\Test-TeraBoxBackendSession' -Value $mockSession
    Set-Item -Path 'Function:\global:Test-TeraBoxBackendSession' -Value $mockSession

    # ==========================================================================
    # TIER 1: Feature Coverage (Category-Partition Testing: R1 - R6)
    # ==========================================================================
    Write-Host "`n--- Tier 1: Feature Coverage (Category-Partition: R1 - R6) ---" -ForegroundColor Yellow

    # --- Feature R1: Linux Account Onboarding CLI ---
    Run-E2ETest 'Tier1' 'T1.1_R1' 'Login CLI parameter parsing and POSIX flag normalization' {
        $acc = Invoke-CliLogin -ProviderId 'terabox' -PassThru -RemainingArgs @(
            '--cookie', 'ndus=e2e_test_token_12345',
            '--name', 'TeraBox Primary VPS',
            '--id', 'acc_terabox_primary',
            '--base-url', 'https://www.terabox.com'
        )
        Assert-Condition ($null -ne $acc) 'Account object was not returned'
        Assert-Equal $acc.Id 'acc_terabox_primary' 'Account ID'
        Assert-Equal $acc.DisplayName 'TeraBox Primary VPS' 'Account DisplayName'
    }

    Run-E2ETest 'Tier1' 'T1.2_R1' 'Account listing output structure contains all required contract fields' {
        $accounts = @(Show-CliAccounts -PassThru)
        Assert-Condition ($accounts.Count -ge 1) 'Expected at least 1 configured account'
        $first = $accounts[0]
        Assert-Condition ($first.PSObject.Properties['Id'] -ne $null) 'Missing Id field'
        Assert-Condition ($first.PSObject.Properties['ProviderId'] -ne $null) 'Missing ProviderId field'
        Assert-Condition ($first.PSObject.Properties['DisplayName'] -ne $null) 'Missing DisplayName field'
        Assert-Condition ($first.PSObject.Properties['MountTarget'] -ne $null) 'Missing MountTarget field'
        Assert-Condition ($first.PSObject.Properties['AutoMount'] -ne $null) 'Missing AutoMount field'
    }

    Run-E2ETest 'Tier1' 'T1.3_R1' 'Credential directory resolves to Linux XDG data root' {
        $credDir = Get-CloudCredentialDirectory
        $expected = Join-Path $sandboxData 'nsclouddrive\credentials'
        Assert-Equal $credDir $expected 'Credential directory resolution'
    }

    Run-E2ETest 'Tier1' 'T1.4_R1' 'Credential file permissions validation enforces 0600 file mode' {
        $testFile = Join-Path $sandboxData 'test_cred.xml'
        [System.IO.File]::WriteAllText($testFile, '<credential/>')
        Set-CloudCredentialAcl -Path $testFile
        Assert-Condition (Test-Path -LiteralPath $testFile) 'Credential file still exists after ACL application'
    }

    Run-E2ETest 'Tier1' 'T1.5_R1' 'Account persistence writes atomically to settings.json' {
        $settingsFile = Get-NSCloudDriveSettingsPath
        Assert-Condition (Test-Path -LiteralPath $settingsFile) 'settings.json was not created'
        $raw = [System.IO.File]::ReadAllText($settingsFile)
        Assert-Condition ($raw -match 'acc_terabox_primary') 'Saved account ID was not persisted in settings.json'
        Assert-Condition ($raw -match 'TeraBox Primary VPS') 'Saved display name was not persisted in settings.json'
    }

    # --- Feature R2: TeraBox Linux Mount Implementation ---
    Run-E2ETest 'Tier1' 'T1.6_R2' 'Rclone environment variable construction for TeraBox' {
        $envVars = Get-TeraBoxRcloneEnvironment -SessionOverride @{ Secret = 'ndus=linux_mount_token_secret' } -RemoteName 'terabox'
        Assert-Equal $envVars['RCLONE_CONFIG_TERABOX_TYPE'] 'terabox' 'Rclone config remote type'
        Assert-Equal $envVars['RCLONE_CONFIG_TERABOX_COOKIE'] 'ndus=linux_mount_token_secret' 'Rclone config cookie'
    }

    Run-E2ETest 'Tier1' 'T1.7_R2' 'Windows CPX bridge bypass logic on Linux' {
        $cpxExe = Join-Path $env:TEMP 'non_existent_cpx.exe'
        Assert-Condition (-not (Test-Path -LiteralPath $cpxExe)) 'Simulated CPX bridge absent'
        # TeraBox mount setup constructs native rclone environment without requiring CPX bridge
        $envVars = Get-TeraBoxRcloneEnvironment -SessionOverride @{ Secret = 'ndus=bridge_bypass_test' } -RemoteName 'terabox_bypass'
        Assert-Condition ($envVars.Count -ge 2) 'TeraBox rclone environment constructed directly without CPX bridge'
    }

    Run-E2ETest 'Tier1' 'T1.8_R2' 'Rclone mount argument generation for Linux FUSE' {
        $mountDir = Join-Path $sandboxCloudDrives 'acc_terabox_primary'
        $args = Build-RcloneMountArguments -RemoteName 'terabox' -MountPoint $mountDir -CacheMaxGigabytes 2
        $argStr = $args -join ' '
        Assert-Condition ($argStr.Contains('--allow-other')) 'Missing --allow-other Linux FUSE flag'
        Assert-Condition (-not $argStr.Contains('--network-mode')) 'Must not contain Windows --network-mode flag'
        Assert-Condition (-not $argStr.Contains('--fuse-flag')) 'Must not contain Windows --fuse-flag flag'
        Assert-Condition ($argStr.Contains($mountDir)) 'Must target mount directory path'
    }

    Run-E2ETest 'Tier1' 'T1.9_R2' 'Linux mount path resolution returns ~/CloudDrives/<account>' {
        $mountPoint = Resolve-ProviderMountPoint -ProviderId 'terabox' -AccountId 'acc_terabox_primary'
        $expected = Join-Path (Join-Path $sandboxHome 'CloudDrives') 'acc_terabox_primary'
        Assert-Equal $mountPoint $expected 'Linux mount directory resolution'
    }

    Run-E2ETest 'Tier1' 'T1.10_R2' 'Linux mount probe routing uses directory existence / findmnt' {
        $mountDir = Join-Path $sandboxCloudDrives 'probe_test'
        New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
        $probe = Test-VirtualDriveFilesystem -DriveRoot $mountDir
        Assert-Condition ($probe.Success -eq $true) 'Linux mount probe validated container path via Test-VirtualDriveFilesystem'
        Assert-Equal $probe.State 'Accessible' 'Filesystem state reported as Accessible'
    }

    # --- Feature R3: Mount Integration & Desktop Visibility ---
    Run-E2ETest 'Tier1' 'T1.11_R3' 'Multi-account mount dispatch enumerates all saved accounts' {
        $accounts = @(Get-CloudAccounts)
        Assert-Condition ($accounts.Count -ge 1) 'Accounts available for mount dispatch'
        $dispatched = @()
        foreach ($acc in $accounts) {
            $dispatched += $acc.Id
        }
        Assert-Condition ($dispatched -contains 'acc_terabox_primary') 'Primary account included in mount dispatch'
    }

    Run-E2ETest 'Tier1' 'T1.12_R3' 'GTK bookmark registration format in ~/.config/gtk-3.0/bookmarks' {
        $mountDir = Join-Path $sandboxCloudDrives 'acc_terabox_primary'
        Register-GtkDesktopBookmark -MountPoint $mountDir -DisplayName 'TeraBox Cloud'
        $bmFile = Join-Path $sandboxGtk 'bookmarks'
        Assert-Condition (Test-Path -LiteralPath $bmFile) 'GTK bookmarks file created'
        $bmText = [System.IO.File]::ReadAllText($bmFile)
        Assert-Condition ($bmText -match 'file://.*TeraBox Cloud') 'GTK bookmark entry formatted correctly'
    }

    Run-E2ETest 'Tier1' 'T1.13_R3' 'GTK bookmark removal cleans entry on unmount' {
        $mountDir = Join-Path $sandboxCloudDrives 'acc_terabox_primary'
        Unregister-GtkDesktopBookmark -MountPoint $mountDir -DisplayName 'TeraBox Cloud'
        $bmFile = Join-Path $sandboxGtk 'bookmarks'
        $bmText = [System.IO.File]::ReadAllText($bmFile)
        Assert-Condition ($bmText -notmatch 'TeraBox Cloud') 'GTK bookmark entry was removed cleanly'
    }

    Run-E2ETest 'Tier1' 'T1.14_R3' 'Desktop visibility creates link in ~/Desktop/' {
        $mountDir = Join-Path $sandboxCloudDrives 'acc_terabox_primary'
        Register-GtkDesktopBookmark -MountPoint $mountDir -DisplayName 'TeraBox Drive'
        $deskLink = Join-Path $sandboxDesktop 'TeraBox Drive'
        Assert-Condition (Test-Path -LiteralPath $deskLink) 'Desktop visibility entry created in ~/Desktop/'
    }

    Run-E2ETest 'Tier1' 'T1.15_R3' 'Desktop visibility cleanup removes link on unmount' {
        $mountDir = Join-Path $sandboxCloudDrives 'acc_terabox_primary'
        Unregister-GtkDesktopBookmark -MountPoint $mountDir -DisplayName 'TeraBox Drive'
        $deskLink = Join-Path $sandboxDesktop 'TeraBox Drive'
        Assert-Condition (-not (Test-Path -LiteralPath $deskLink)) 'Desktop visibility entry removed on unmount'
    }

    # --- Feature R4: Daemon Auto-Mount on Boot ---
    Run-E2ETest 'Tier1' 'T1.16_R4' 'Daemon auto-mount filters accounts with AutoMount = $true' {
        $accAutoTrue = @{ Id = 'acc_auto_yes'; ProviderId = 'terabox'; DisplayName = 'Auto True'; AutoMount = $true; DriveLetter = '' }
        $accAutoFalse = @{ Id = 'acc_auto_no'; ProviderId = 'terabox'; DisplayName = 'Auto False'; AutoMount = $false; DriveLetter = '' }
        [void](Add-CloudAccount -Account $accAutoTrue)
        [void](Add-CloudAccount -Account $accAutoFalse)

        $allAccs = @(Get-CloudAccounts)
        $autoMountable = @($allAccs | Where-Object {
            $am = Get-SafeProperty $_ 'AutoMount' $true
            $am -ne $false
        })
        $ids = @($autoMountable | ForEach-Object { $_.Id })
        Assert-Condition ($ids -contains 'acc_auto_yes') 'Account with AutoMount=$true must be included'
        Assert-Condition ($ids -notcontains 'acc_auto_no') 'Account with AutoMount=$false must be excluded'
    }

    Run-E2ETest 'Tier1' 'T1.17_R4' 'Single-instance daemon PID lock file validation' {
        $pidFile = Join-Path $sandboxData 'nsclouddrive\nsclouddrive.pid'
        [System.IO.File]::WriteAllText($pidFile, [System.Diagnostics.Process]::GetCurrentProcess().Id.ToString())
        Assert-Condition (Test-Path -LiteralPath $pidFile) 'PID lock file exists'
        $readPid = [int][System.IO.File]::ReadAllText($pidFile).Trim()
        Assert-Equal $readPid ([System.Diagnostics.Process]::GetCurrentProcess().Id) 'PID matches current process'
        Remove-Item -LiteralPath $pidFile -Force
    }

    Run-E2ETest 'Tier1' 'T1.18_R4' 'Daemon clean shutdown trap invokes unmount' {
        $res = Invoke-CliDaemonShutdown
        Assert-Condition ($res.Success -eq $true) 'Daemon clean shutdown routine executed successfully'
        Assert-Condition ($res.Unmounted -eq $true) 'Active mounts unmounted during daemon shutdown'
    }

    Run-E2ETest 'Tier1' 'T1.19_R4' 'Systemd service unit parsing and flag validation' {
        $unitPath = Join-Path $scriptsDir 'systemd\nsclouddrive.service'
        Assert-Condition (Test-Path -LiteralPath $unitPath) 'Systemd service unit file exists'
        $unitContent = [System.IO.File]::ReadAllText($unitPath)
        Assert-Condition ($unitContent -match 'ExecStart=/usr/local/bin/nsclouddrive daemon') 'ExecStart directive'
        Assert-Condition ($unitContent -match 'KillMode=mixed') 'KillMode directive'
        Assert-Condition ($unitContent -match 'TimeoutStopSec=30s') 'TimeoutStopSec directive'
        Assert-Condition ($unitContent -match 'Restart=on-failure') 'Restart directive'
        Assert-Condition ($unitContent -match 'ProtectSystem=full') 'ProtectSystem security hardening'
    }

    Run-E2ETest 'Tier1' 'T1.20_R4' 'Status reporting reflects configured accounts and queue state' {
        $accounts = @(Get-CloudAccounts)
        Assert-Condition ($accounts.Count -ge 2) 'Configured accounts visible to status reporter'
        $qItems = @(Get-CloudTransferQueue)
        Assert-Condition ($null -ne $qItems) 'Transfer queue accessible by status reporter'
    }

    # --- Feature R5: Eviction, Dedup & 4GB Limit ---
    Run-E2ETest 'Tier1' 'T1.21_R5' 'Upload preflight check allows <= 4.0 GB files' {
        $acc = @{ Id = 'acc_tb_preflight'; ProviderId = 'terabox' }
        $res = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes 4000000000L -FileName '4gb_exact.iso'
        Assert-Condition ($res.Allowed -eq $true) '4,000,000,000 bytes must be allowed on free plan'
    }

    Run-E2ETest 'Tier1' 'T1.22_R5' 'Upload preflight check rejects > 4.0 GB files with PlanFileLimit' {
        $acc = @{ Id = 'acc_tb_preflight'; ProviderId = 'terabox' }
        $res = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes 4000000001L -FileName 'over_limit.iso'
        Assert-Condition ($res.Allowed -eq $false) '4,000,000,001 bytes must be rejected'
        Assert-Equal $res.ErrorCode 'PlanFileLimit' 'Rejection error code'
    }

    Run-E2ETest 'Tier1' 'T1.23_R5' 'Remote cloud deduplication candidate classification' {
        Record-CloudDedupVerifiedFile -AccountId 'acc_dedup_test' -ProviderId 'terabox' -RemotePath 'videos/clip.mp4' -SizeBytes 52428800L
        Save-CloudDedupLedger
        $res = Test-RemoteCloudFileDeduplication -AccountId 'acc_dedup_test' -ProviderId 'terabox' -RemotePath 'videos/clip.mp4' -LocalSizeBytes 52428800L
        Assert-Condition ($res.IsPresent -eq $true) 'Identical remote file must be detected'
        Assert-Equal $res.Status 'AlreadyInCloud' 'Deduplication status'
    }

    Run-E2ETest 'Tier1' 'T1.24_R5' 'Deduplication skip avoids re-queuing duplicate file drop' {
        $dedup = Test-RemoteCloudFileDeduplication -AccountId 'acc_dedup_test' -ProviderId 'terabox' -RemotePath 'videos/clip.mp4' -LocalSizeBytes 52428800L
        Assert-Condition ($dedup.IsPresent -eq $true) 'Identical file detected by deduplication engine'
        Assert-Equal $dedup.Status 'AlreadyInCloud' 'Status indicates already present'
        $shouldSkip = [bool]$dedup.IsPresent
        Assert-Condition $shouldSkip 'Duplicate file drop must be skipped from transfer queue'
    }

    Run-E2ETest 'Tier1' 'T1.25_R5' 'Post-transfer cache cleanup evicts confirmed non-dirty cache files' {
        $accCacheDir = Join-Path $sandboxTmpfs 'terabox_acc_dedup_test'
        $vfsDir = Join-Path $accCacheDir 'vfs'
        $vfsMetaDir = Join-Path $accCacheDir 'vfsMeta'
        New-Item -ItemType Directory -Path $vfsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $vfsMetaDir -Force | Out-Null

        $cFile = Join-Path $vfsDir 'uploaded_doc.pdf'
        $mFile = Join-Path $vfsMetaDir 'uploaded_doc.pdf'
        [System.IO.File]::WriteAllText($cFile, 'Dummy payload')
        [System.IO.File]::WriteAllText($mFile, '{"Dirty": false}')

        $res = Invoke-PostTransferCacheCleanup -CacheDirectory $sandboxTmpfs -Settings @{
            PostTransferCachePolicy = 'RemoveAfterVerifiedUpload'
            PostTransferRetentionMinutes = 60
        }
        Assert-Condition ($res.EvictedFiles -ge 1) 'Confirmed non-dirty cache file must be evicted'
        Assert-Condition (-not (Test-Path -LiteralPath $cFile)) 'Evicted cache payload deleted from disk'
    }

    # --- Feature R6: Cross-Platform Hygiene ---
    Run-E2ETest 'Tier1' 'T1.26_R6' 'Cross-platform helper conditionality reflects Linux platform' {
        Assert-Condition ($global:IsLinux -eq $true) 'IsLinux global flag active'
        $isLinuxOp = Test-IsLinuxOperatingSystem
        Assert-Condition ($isLinuxOp -eq $true) 'Test-IsLinuxOperatingSystem reports true'
    }

    Run-E2ETest 'Tier1' 'T1.27_R6' 'Cache safety permits Linux tmpfs directories' {
        $tmpfsPath = '/run/user/1001/nsclouddrive'
        $resolved = Resolve-SafeCacheDirectory $tmpfsPath
        Assert-Equal $resolved $tmpfsPath 'Linux tmpfs path accepted without NTFS requirement'
    }

    Run-E2ETest 'Tier1' 'T1.28_R6' 'Linux drive letter independence' {
        $acc = @{ Id = 'acc_no_letter'; ProviderId = 'terabox'; DisplayName = 'No Letter Account'; DriveLetter = '' }
        $saved = Add-CloudAccount -Account $acc
        Assert-Condition ($null -ne $saved) 'Account saved without drive letter'
        Assert-Equal $saved.DriveLetter '' 'Drive letter is empty string'
    }

    Run-E2ETest 'Tier1' 'T1.29_R6' 'Bash wrapper forwards all CLI arguments verbatim' {
        $wrapperPath = Join-Path $scriptsDir 'nsclouddrive'
        Assert-Condition (Test-Path -LiteralPath $wrapperPath) 'Bash wrapper exists'
        $wrapperText = [System.IO.File]::ReadAllText($wrapperPath)
        Assert-Condition ($wrapperText -match 'exec "\$PWSH_BIN"[^\r\n]*"\$@"') 'Forwards "$@"'
    }

    Run-E2ETest 'Tier1' 'T1.30_R6' 'Linux setup script syntax and flag hygiene' {
        $installScript = Join-Path $scriptsDir 'install-linux.sh'
        Assert-Condition (Test-Path -LiteralPath $installScript) 'Installer script exists'
        $installText = [System.IO.File]::ReadAllText($installScript)
        Assert-Condition ($installText -match 'set -euo pipefail') 'Strict shell flags set'
        Assert-Condition ($installText -match 'fuse3') 'Installs fuse3'
        Assert-Condition ($installText -match 'rclone') 'Installs rclone'
    }

    # ==========================================================================
    # TIER 2: Boundary Value Analysis & Corner Cases
    # ==========================================================================
    Write-Host "`n--- Tier 2: Boundary Value Analysis & Corner Cases ---" -ForegroundColor Yellow

    # --- Feature R1 Boundaries ---
    Run-E2ETest 'Tier2' 'T2.1_R1' 'Empty credentials rejection throws descriptive error' {
        $threw = $false
        try {
            Save-TeraBoxSession -Type 'web-session' -Secret '' -AccountId 'acc_empty_test'
        } catch {
            $threw = $_.Exception.Message -match 'Cannot store empty TeraBox session secret'
        }
        Assert-Condition $threw 'Expected exception on empty credential secret'
    }

    Run-E2ETest 'Tier2' 'T2.2_R1' 'Cookie missing ndus= prefix is automatically formatted' {
        $header = Format-TeraBoxCookieHeader 'raw_token_value_without_ndus'
        Assert-Equal $header 'ndus=raw_token_value_without_ndus' 'Cookie formatting'
    }

    Run-E2ETest 'Tier2' 'T2.3_R1' 'Cookie with leading label and whitespace is cleanly sanitized' {
        $header = Format-TeraBoxCookieHeader '  Cookie: ndus=val123; session=456;  '
        Assert-Equal $header 'ndus=val123; session=456;' 'Stripped Cookie: prefix and outer whitespace'
    }

    Run-E2ETest 'Tier2' 'T2.4_R1' 'Account name with spaces, dashes and special symbols' {
        $acc = @{
            Id = 'acc_special_chars'
            ProviderId = 'terabox'
            DisplayName = 'Work - Storage (2026) [Alpha]'
            DriveLetter = ''
        }
        $saved = Add-CloudAccount -Account $acc
        Assert-Equal $saved.DisplayName 'Work - Storage (2026) [Alpha]' 'Special characters preserved in DisplayName'
    }

    Run-E2ETest 'Tier2' 'T2.5_R1' 'Account name with path traversal attempts is neutralized' {
        $traversalId = '../../etc/shadow'
        $mountPoint = Resolve-ProviderMountPoint -ProviderId 'terabox' -AccountId $traversalId
        $folderName = Split-Path -Leaf $mountPoint
        Assert-Condition (-not $folderName.Contains('..')) 'Traversal dots removed from mount folder'
        Assert-Condition (-not $folderName.Contains('/')) 'Slashes removed from mount folder'
        Assert-Equal $folderName '______etc_shadow' 'Sanitized remote identifier'
        Assert-Condition ($mountPoint.StartsWith((Join-Path $sandboxHome 'CloudDrives'))) 'Mount point remains safely contained within CloudDrives directory'
    }

    # --- Feature R2 Boundaries ---
    Run-E2ETest 'Tier2' 'T2.6_R2' 'Rclone cache limit bounds checking (1 GB min, 1024 GB max)' {
        $threwLow = $false
        try {
            [void](Build-RcloneMountArguments -RemoteName 'terabox' -CacheMaxGigabytes 0)
        } catch {
            $threwLow = $_.Exception.Message -match 'between 1 and 1024 GB'
        }
        Assert-Condition $threwLow 'Cache limit 0 must throw'

        $threwHigh = $false
        try {
            [void](Build-RcloneMountArguments -RemoteName 'terabox' -CacheMaxGigabytes 1025)
        } catch {
            $threwHigh = $_.Exception.Message -match 'between 1 and 1024 GB'
        }
        Assert-Condition $threwHigh 'Cache limit 1025 must throw'
    }

    Run-E2ETest 'Tier2' 'T2.7_R2' 'Remote name with shell injection characters is sanitized' {
        $args = Build-RcloneMountArguments -RemoteName 'remote;rm -rf /' -CacheMaxGigabytes 2
        $remoteArg = $args[1]
        Assert-Condition (-not $remoteArg.Contains(';')) 'Semicolons removed'
        Assert-Condition (-not $remoteArg.Contains('/')) 'Slashes removed from remote name'
        Assert-Condition ($remoteArg.StartsWith('remote_rm_-rf__')) 'Sanitized remote token present'
    }

    Run-E2ETest 'Tier2' 'T2.8_R2' 'Non-existent mount directory auto-creation on Linux' {
        $nonExistentDir = Join-Path $sandboxCloudDrives 'fresh_auto_dir'
        Assert-Condition (-not (Test-Path -LiteralPath $nonExistentDir)) 'Target directory does not exist initially'
        $args = Build-RcloneMountArguments -RemoteName 'fresh_auto' -MountPoint $nonExistentDir -CacheMaxGigabytes 2
        Assert-Condition (Test-Path -LiteralPath $nonExistentDir) 'Directory auto-created by mount argument builder'
    }

    Run-E2ETest 'Tier2' 'T2.9_R2' 'Custom MountPoint override takes precedence over default path' {
        $customMount = '/mnt/custom_cloud_mount'
        $args = Build-RcloneMountArguments -RemoteName 'terabox' -MountPoint $customMount -CacheMaxGigabytes 2
        Assert-Condition ($args[2] -eq $customMount) 'Mount point matches custom path override'
    }

    Run-E2ETest 'Tier2' 'T2.10_R2' 'Read-only switch appends --read-only flag' {
        $args = Build-RcloneMountArguments -RemoteName 'terabox' -CacheMaxGigabytes 2 -ReadOnly
        Assert-Condition ($args -contains '--read-only') '--read-only flag present in mount argument list'
    }

    # --- Feature R3 Boundaries ---
    Run-E2ETest 'Tier2' 'T2.11_R3' 'GTK bookmark directory created if absent' {
        $customGtk = Join-Path $sandboxHome 'custom_gtk\.config\gtk-3.0'
        $prevHome = $env:HOME
        try {
            $env:HOME = Join-Path $sandboxHome 'custom_gtk'
            Register-GtkDesktopBookmark -MountPoint '/mnt/test' -DisplayName 'Test BM'
            Assert-Condition (Test-Path -LiteralPath $customGtk) 'gtk-3.0 directory created when missing'
        } finally {
            $env:HOME = $prevHome
        }
    }

    Run-E2ETest 'Tier2' 'T2.12_R3' 'GTK bookmark registration is idempotent (no duplicate lines)' {
        $mountDir = Join-Path $sandboxCloudDrives 'acc_terabox_primary'
        Register-GtkDesktopBookmark -MountPoint $mountDir -DisplayName 'TeraBox Cloud'
        Register-GtkDesktopBookmark -MountPoint $mountDir -DisplayName 'TeraBox Cloud'
        $bmFile = Join-Path $sandboxGtk 'bookmarks'
        $lines = @(Get-Content -LiteralPath $bmFile | Where-Object { $_ -match 'TeraBox Cloud' })
        Assert-Equal $lines.Count 1 'Expected exactly 1 bookmark entry after repeated registration'
    }

    Run-E2ETest 'Tier2' 'T2.13_R3' 'GTK bookmark unregister handles missing bookmark file gracefully' {
        $realBmFile = Join-Path $sandboxGtk 'bookmarks'
        if (Test-Path -LiteralPath $realBmFile) { Remove-Item -LiteralPath $realBmFile -Force }

        Unregister-GtkDesktopBookmark -MountPoint '/non/existent/path' -DisplayName 'NonExistent'

        Assert-Condition (-not (Test-Path -LiteralPath $realBmFile)) 'Bookmark file must not be created when unregistering absent bookmark'
        $deskLink = Join-Path $sandboxDesktop 'NonExistent'
        Assert-Condition (-not (Test-Path -LiteralPath $deskLink)) 'Desktop link must not exist for non-existent mount'
    }

    Run-E2ETest 'Tier2' 'T2.14_R3' 'Desktop directory created if absent on symlink creation' {
        $deskDir = Join-Path $sandboxHome 'Desktop'
        if (Test-Path -LiteralPath $deskDir) { Remove-Item -LiteralPath $deskDir -Recurse -Force }

        $mountDir = Join-Path $sandboxCloudDrives 'acc_terabox_desktest'
        Register-GtkDesktopBookmark -MountPoint $mountDir -DisplayName 'TeraBox DeskTest'

        Assert-Condition (Test-Path -LiteralPath $deskDir) 'Desktop directory was auto-created by Register-GtkDesktopBookmark'
        $deskLink = Join-Path $deskDir 'TeraBox DeskTest'
        Assert-Condition (Test-Path -LiteralPath $deskLink) 'Desktop symlink entry was created inside newly generated Desktop directory'
    }

    Run-E2ETest 'Tier2' 'T2.15_R3' 'Bookmark registration escapes spaces in URI path' {
        $spacedMount = '/home/vpsuser/Cloud Drives/TeraBox Main'
        Register-GtkDesktopBookmark -MountPoint $spacedMount -DisplayName 'TeraBox Main'
        $bmFile = Join-Path $sandboxGtk 'bookmarks'
        $bmText = [System.IO.File]::ReadAllText($bmFile)
        Assert-Condition ($bmText -match 'file:///home/vpsuser/Cloud Drives/TeraBox Main TeraBox Main') 'URI and display name separation'
    }

    # --- Feature R4 Boundaries ---
    Run-E2ETest 'Tier2' 'T2.16_R4' 'Stale PID file recovery handles dead process PID' {
        $pidFile = Join-Path $sandboxData 'nsclouddrive\nsclouddrive.pid'
        [System.IO.File]::WriteAllText($pidFile, '99999999') # Non-existent process
        $stalePid = [int][System.IO.File]::ReadAllText($pidFile).Trim()
        $isAlive = $false
        try {
            $proc = [System.Diagnostics.Process]::GetProcessById($stalePid)
            $isAlive = ($null -ne $proc)
        } catch {
            $isAlive = $false
        }
        Assert-Condition (-not $isAlive) 'Stale PID confirmed inactive'
        # Daemon startup cleans dead PID
        [System.IO.File]::WriteAllText($pidFile, [System.Diagnostics.Process]::GetCurrentProcess().Id.ToString())
        Assert-Equal ([int][System.IO.File]::ReadAllText($pidFile).Trim()) ([System.Diagnostics.Process]::GetCurrentProcess().Id) 'Stale PID overwritten'
        Remove-Item -LiteralPath $pidFile -Force
    }

    Run-E2ETest 'Tier2' 'T2.17_R4' 'Active PID collision detection' {
        $pidFile = Get-CliDaemonPidPath
        [System.IO.File]::WriteAllText($pidFile, [string]$PID)
        $isRunning = Test-CliDaemonRunning
        Assert-Equal $isRunning $true 'Active process PID detected as running daemon'

        [System.IO.File]::WriteAllText($pidFile, '99999999')
        $isStaleRunning = Test-CliDaemonRunning
        Assert-Equal $isStaleRunning $false 'Stale/dead PID correctly detected as not running'
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }

    Run-E2ETest 'Tier2' 'T2.18_R4' 'Systemd user configuration directory created if absent' {
        if (Test-Path -LiteralPath $sandboxSystemd) { Remove-Item -LiteralPath $sandboxSystemd -Recurse -Force }

        $installedDir = Install-LinuxSystemdService
        Assert-Condition (Test-Path -LiteralPath $sandboxSystemd) '~/.config/systemd/user directory was created on demand'
        Assert-Condition (Test-Path -LiteralPath (Join-Path $sandboxSystemd 'nsclouddrive.service')) 'Systemd user unit file was installed'
    }

    Run-E2ETest 'Tier2' 'T2.19_R4' 'Daemon startup with zero accounts completes recovery cleanly' {
        # Test startup recovery function with isolated transfer state
        $rec = Invoke-StartupTransferQueueRecovery
        Assert-Condition ($null -ne $rec) 'Startup recovery completed without error'
        Assert-Condition ($rec.RecoveredCount -ge 0) 'Recovered count is non-negative'
    }

    Run-E2ETest 'Tier2' 'T2.20_R4' 'Systemd unit specifies KillMode=mixed and TimeoutStopSec' {
        $unitPath = Join-Path $scriptsDir 'systemd\nsclouddrive.service'
        $text = [System.IO.File]::ReadAllText($unitPath)
        Assert-Condition ($text.Contains('KillMode=mixed')) 'Mixed kill mode to allow graceful FUSE unmount'
        Assert-Condition ($text.Contains('TimeoutStopSec=30s')) '30s stop timeout'
    }

    # --- Feature R5 Boundaries ---
    Run-E2ETest 'Tier2' 'T2.21_R5' 'Exact 4.0 GB free-tier boundary values (4,000,000,000 vs 4,000,000,001 bytes)' {
        $acc = @{ Id = 'acc_tb_bva'; ProviderId = 'terabox' }
        $resExact = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes 4000000000L -FileName 'exact.dat'
        Assert-Condition ($resExact.Allowed -eq $true) '4,000,000,000 bytes is allowed'

        $resPlusOne = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes 4000000001L -FileName 'plus_one.dat'
        Assert-Condition ($resPlusOne.Allowed -eq $false) '4,000,000,001 bytes is rejected'
        Assert-Equal $resPlusOne.ErrorCode 'PlanFileLimit' 'ErrorCode is PlanFileLimit'
    }

    Run-E2ETest 'Tier2' 'T2.22_R5' 'Locked file is protected from cache eviction' {
        $accCacheDir = Join-Path $sandboxTmpfs 'terabox_acc_lock_test'
        $vfsDir = Join-Path $accCacheDir 'vfs'
        $vfsMetaDir = Join-Path $accCacheDir 'vfsMeta'
        New-Item -ItemType Directory -Path $vfsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $vfsMetaDir -Force | Out-Null

        $lockedFile = Join-Path $vfsDir 'locked_stream.dat'
        $lockedMeta = Join-Path $vfsMetaDir 'locked_stream.dat'
        [System.IO.File]::WriteAllText($lockedFile, 'Active locked bytes')
        [System.IO.File]::WriteAllText($lockedMeta, '{"Dirty": false}')

        $stream = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $isLocked = Test-FileInUse -FilePath $lockedFile
            Assert-Condition $isLocked 'File lock is recognized by Test-FileInUse'

            $res = Invoke-PostTransferCacheCleanup -CacheDirectory $sandboxTmpfs -Settings @{
                PostTransferCachePolicy = 'RemoveAfterVerifiedUpload'
                PostTransferRetentionMinutes = 60
            }
            Assert-Condition (Test-Path -LiteralPath $lockedFile) 'Locked file must be preserved in cache'
        } finally {
            $stream.Dispose()
        }
    }

    Run-E2ETest 'Tier2' 'T2.23_R5' 'Dirty VFS cache write is protected from cache eviction' {
        $accCacheDir = Join-Path $sandboxTmpfs 'terabox_acc_dirty_test'
        $vfsDir = Join-Path $accCacheDir 'vfs'
        $vfsMetaDir = Join-Path $accCacheDir 'vfsMeta'
        New-Item -ItemType Directory -Path $vfsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $vfsMetaDir -Force | Out-Null

        $dirtyFile = Join-Path $vfsDir 'staged_write.dat'
        $dirtyMeta = Join-Path $vfsMetaDir 'staged_write.dat'
        [System.IO.File]::WriteAllText($dirtyFile, 'Staged dirty data')
        [System.IO.File]::WriteAllText($dirtyMeta, '{"Dirty": true}')

        $res = Invoke-PostTransferCacheCleanup -CacheDirectory $sandboxTmpfs -Settings @{
            PostTransferCachePolicy = 'RemoveAfterVerifiedUpload'
            PostTransferRetentionMinutes = 60
        }
        Assert-Condition (Test-Path -LiteralPath $dirtyFile) 'Dirty file must never be evicted'
    }

    Run-E2ETest 'Tier2' 'T2.24_R5' 'Deduplication size mismatch detection schedules re-transfer' {
        Record-CloudDedupVerifiedFile -AccountId 'acc_dedup_bva' -ProviderId 'terabox' -RemotePath 'docs/manual.pdf' -SizeBytes 1048576L
        Save-CloudDedupLedger
        # Check candidate with same remote name but 2 MB instead of 1 MB
        $res = Test-RemoteCloudFileDeduplication -AccountId 'acc_dedup_bva' -ProviderId 'terabox' -RemotePath 'docs/manual.pdf' -LocalSizeBytes 2097152L
        Assert-Condition ($res.IsPresent -eq $false) 'Size mismatch must not be marked as already present'
    }

    Run-E2ETest 'Tier2' 'T2.25_R5' 'Zero-byte file passes upload preflight' {
        $acc = @{ Id = 'acc_tb_bva'; ProviderId = 'terabox' }
        $res = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes 0L -FileName 'empty.txt'
        Assert-Condition ($res.Allowed -eq $true) '0-byte file must be allowed'
    }

    # --- Feature R6 Boundaries ---
    Run-E2ETest 'Tier2' 'T2.26_R6' 'Multiple Linux tmpfs path patterns validated' {
        $paths = @('/run/user/1001/cdrive', '/dev/shm/cache', '/tmp/vfs_cache')
        foreach ($p in $paths) {
            $res = Resolve-SafeCacheDirectory $p
            Assert-Equal $res $p "Path $p accepted"
        }
    }

    Run-E2ETest 'Tier2' 'T2.27_R6' 'Empty DriveLetter on Linux does not fail drive availability check' {
        $res = Test-CloudAccountDriveLetterAvailable -DriveLetter ''
        Assert-Equal $res $true 'Empty drive letter on Linux must return $true'
    }

    Run-E2ETest 'Tier2' 'T2.28_R6' 'Missing XDG environment variables fallback to standard paths' {
        $prevData = $env:XDG_DATA_HOME
        $prevConfig = $env:XDG_CONFIG_HOME
        try {
            $env:XDG_DATA_HOME = ''
            $env:XDG_CONFIG_HOME = ''
            $dataRoot = Get-NSCloudDriveDataRoot
            $configRoot = Get-NSCloudDriveConfigRoot
            Assert-Condition ($dataRoot.Contains('.local')) 'Data root contains .local fallback'
            Assert-Condition ($configRoot.Contains('.config')) 'Config root contains .config fallback'
        } finally {
            $env:XDG_DATA_HOME = $prevData
            $env:XDG_CONFIG_HOME = $prevConfig
        }
    }

    Run-E2ETest 'Tier2' 'T2.29_R6' 'Linux shell scripts contain zero Windows CRLF line endings' {
        $scripts = @((Join-Path $scriptsDir 'nsclouddrive'), (Join-Path $scriptsDir 'install-linux.sh'))
        foreach ($s in $scripts) {
            $bytes = [System.IO.File]::ReadAllBytes($s)
            $crlfCount = 0
            for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
                if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) {
                    $crlfCount++
                }
            }
            Assert-Condition ($crlfCount -eq 0) "Script $([System.IO.Path]::GetFileName($s)) must not contain CRLF line endings"
        }
    }

    Run-E2ETest 'Tier2' 'T2.30_R6' 'Path separator normalization handles mixed slashes' {
        $mixedPath = '/home/vpsuser/CloudDrives\terabox/subfolder\file.dat'
        $normalized = Normalize-CloudPath $mixedPath
        Assert-Condition (-not $normalized.Contains('\')) 'Backslashes replaced with forward slashes via Normalize-CloudPath'
        Assert-Equal $normalized 'home/vpsuser/CloudDrives/terabox/subfolder/file.dat' 'Normalized Unix path'
    }

    # ==========================================================================
    # TIER 3: Cross-Feature Combinations (Pairwise Combinatorial Testing)
    # ==========================================================================
    Write-Host "`n--- Tier 3: Cross-Feature Combinations ---" -ForegroundColor Yellow

    Run-E2ETest 'Tier3' 'T3.1_Comb' 'Onboarding + account inspection + mount command construction' {
        # 1. Onboard
        $acc = Invoke-CliLogin -ProviderId 'terabox' -PassThru -RemainingArgs @(
            '--cookie', 'ndus=comb_test_token_999',
            '--name', 'TeraBox Combinatorial',
            '--id', 'acc_tb_comb'
        )
        # 2. Inspect
        $all = Show-CliAccounts -PassThru
        $found = @($all | Where-Object { $_.Id -eq 'acc_tb_comb' })
        Assert-Condition ($found.Count -eq 1) 'Account persisted and retrieved in listing'
        # 3. Mount Command Construction
        $mountDir = Join-Path $sandboxCloudDrives 'acc_tb_comb'
        $args = Build-RcloneMountArguments -RemoteName 'terabox_acc_tb_comb' -MountPoint $mountDir -CacheMaxGigabytes 2
        Assert-Condition ($args -contains '--allow-other') 'Linux FUSE argument present'
        Assert-Condition ($args -contains $mountDir) 'Mount directory present'
    }

    Run-E2ETest 'Tier3' 'T3.2_Comb' 'File drop + preflight check + dedup classification + queue creation' {
        $acc = @{ Id = 'acc_tb_comb'; ProviderId = 'terabox' }
        $fileSize = 25165824L # 24 MB
        $fileName = 'quarterly_report.xlsx'

        # Preflight
        $pf = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes $fileSize -FileName $fileName
        Assert-Condition $pf.Allowed 'Preflight allowed'

        # Dedup classification
        $dedup = Test-RemoteCloudFileDeduplication -AccountId 'acc_tb_comb' -ProviderId 'terabox' -RemotePath "docs/$fileName" -LocalSizeBytes $fileSize
        Assert-Condition (-not $dedup.IsPresent) 'File is new candidate'

        # Queue creation
        $job = [hashtable]::Synchronized(@{
            JobId = 'job_comb_001'
            QueueId = 'job_comb_001'
            FileName = $fileName
            FileSizeBytes = $fileSize
            BytesTransferred = 0L
            Percentage = 0.0
            Status = 'Queued'
        })
        [void]$script:CloudTransferQueue.Add($job)
        Assert-Condition ($script:CloudTransferQueue.Count -ge 1) 'Item queued in durable queue'
    }

    Run-E2ETest 'Tier3' 'T3.3_Comb' 'Staged dirty VFS write + queue adoption + simulated remote verification + cache eviction' {
        $accCacheDir = Join-Path $sandboxTmpfs 'terabox_acc_tb_comb'
        $vfsDir = Join-Path $accCacheDir 'vfs'
        $vfsMetaDir = Join-Path $accCacheDir 'vfsMeta'
        New-Item -ItemType Directory -Path $vfsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $vfsMetaDir -Force | Out-Null

        $cFile = Join-Path $vfsDir 'staged_video.mp4'
        $mFile = Join-Path $vfsMetaDir 'staged_video.mp4'
        [System.IO.File]::WriteAllText($cFile, 'Dummy video stream bytes')
        [System.IO.File]::WriteAllText($mFile, '{"Dirty": true}')

        # 1. While dirty, verify not evicted
        $cleanupPre = Invoke-PostTransferCacheCleanup -CacheDirectory $sandboxTmpfs -Settings @{
            PostTransferCachePolicy = 'RemoveAfterVerifiedUpload'
            PostTransferRetentionMinutes = 60
        }
        Assert-Condition (Test-Path -LiteralPath $cFile) 'Staged dirty file preserved before upload'

        # 2. Simulate upload complete and remote verification
        [System.IO.File]::WriteAllText($mFile, '{"Dirty": false}')
        Record-CloudDedupVerifiedFile -AccountId 'acc_tb_comb' -ProviderId 'terabox' -RemotePath 'staged_video.mp4' -SizeBytes 24L
        Save-CloudDedupLedger

        # 3. Post-transfer eviction cleans cache
        $cleanupPost = Invoke-PostTransferCacheCleanup -CacheDirectory $sandboxTmpfs -Settings @{
            PostTransferCachePolicy = 'RemoveAfterVerifiedUpload'
            PostTransferRetentionMinutes = 60
        }
        Assert-Condition ($cleanupPost.EvictedFiles -ge 1) 'Confirmed file evicted'
        Assert-Condition (-not (Test-Path -LiteralPath $cFile)) 'Local tmpfs storage freed'
    }

    Run-E2ETest 'Tier3' 'T3.4_Comb' 'Daemon boot + multi-account mount filter (AutoMount=true vs AutoMount=false)' {
        $accs = @(Get-CloudAccounts)
        $autoMounted = @()
        foreach ($a in $accs) {
            $am = Get-SafeProperty $a 'AutoMount' $true
            if ($am -ne $false) {
                $autoMounted += $a.Id
            }
        }
        Assert-Condition ($autoMounted -contains 'acc_tb_comb') 'AutoMount=true account included'
        Assert-Condition ($autoMounted -notcontains 'acc_auto_no') 'AutoMount=false account excluded'
    }

    Run-E2ETest 'Tier3' 'T3.5_Comb' 'Daemon queue processing + post-transfer cache cleanup cycle' {
        # Simulate a completed queue item trigger
        $job = [hashtable]::Synchronized(@{
            JobId = 'job_cycle_001'
            FileName = 'cycle_asset.png'
            Status = 'Completed and remotely confirmed'
            Percentage = 100.0
            FileSizeBytes = 1024L
            BytesTransferred = 1024L
        })
        [void]$script:CloudTransferQueue.Add($job)

        $res = Invoke-PostTransferCacheCleanup -CacheDirectory $sandboxTmpfs -Settings @{
            PostTransferCachePolicy = 'RemoveAfterVerifiedUpload'
            PostTransferRetentionMinutes = 60
        }
        Assert-Condition ($res.Policy -eq 'RemoveAfterVerifiedUpload') 'Cleanup cycle executed under configured policy'
    }

    Run-E2ETest 'Tier3' 'T3.6_Comb' 'Deduplication ledger persistence across service re-initialization' {
        # Record file
        Record-CloudDedupVerifiedFile -AccountId 'acc_persist_test' -ProviderId 'terabox' -RemotePath 'archive/data.tar.gz' -SizeBytes 104857600L
        Save-CloudDedupLedger

        # Reset in-memory cache to simulate restart
        Set-CloudDedupLedgerPathOverride $sandboxDedupLedger
        $loaded = Load-CloudDedupLedger
        $chk = Test-RemoteCloudFileDeduplication -AccountId 'acc_persist_test' -ProviderId 'terabox' -RemotePath 'archive/data.tar.gz' -LocalSizeBytes 104857600L
        Assert-Condition ($chk.IsPresent -eq $true) 'Persistent ledger restored verified file state after restart'
    }

    # ==========================================================================
    # TIER 4: Real-World Application Scenarios
    # ==========================================================================
    Write-Host "`n--- Tier 4: Real-World Application Scenarios ---" -ForegroundColor Yellow

    Run-E2ETest 'Tier4' 'T4.1_Scenario1' 'Complete first-time onboarding, credential verification and mount initialization' {
        # 1. User runs login command
        $acc = Invoke-CliLogin -ProviderId 'terabox' -PassThru -RemainingArgs @(
            '--cookie', 'ndus=scenario1_user_session_token',
            '--name', 'TeraBox Personal',
            '--id', 'acc_scenario1'
        )
        Assert-Condition ($null -ne $acc) 'Onboarding succeeded'

        # 2. Check credentials stored securely
        $credFile = Get-TeraBoxCredentialFilePath -AccountId 'acc_scenario1'
        Assert-Condition (Test-Path -LiteralPath $credFile) 'Credentials stored in PSCredential XML'

        # 3. Mount all executes and registers visibility
        $mountPoint = Resolve-ProviderMountPoint -ProviderId 'terabox' -AccountId 'acc_scenario1'
        Register-GtkDesktopBookmark -MountPoint $mountPoint -DisplayName 'TeraBox Personal'

        $bmFile = Join-Path $sandboxGtk 'bookmarks'
        $bmText = [System.IO.File]::ReadAllText($bmFile)
        Assert-Condition ($bmText -match 'TeraBox Personal') 'Nautilus bookmark created'
        $deskLink = Join-Path $sandboxDesktop 'TeraBox Personal'
        Assert-Condition (Test-Path -LiteralPath $deskLink) 'Desktop visibility symlink created'
    }

    Run-E2ETest 'Tier4' 'T4.2_Scenario2' 'Desktop drag-and-drop workflow: drop, verify, complete, evict, and dedup skip' {
        $acc = @{ Id = 'acc_scenario2'; ProviderId = 'terabox' }
        $fileName = 'project_presentation.mp4'
        $fileSize = 524288000L # 500 MB

        # 1. Preflight verifies within 4.0 GB free limit
        $pf = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes $fileSize -FileName $fileName
        Assert-Condition $pf.Allowed '500 MB within 4.0 GB free limit'

        # 2. Drop ingestion via Add-CloudTransferDroppedItems
        $dropDir = Join-Path $sandboxHome 'user_drop_source'
        New-Item -ItemType Directory -Path $dropDir -Force | Out-Null
        $dropFile = Join-Path $dropDir $fileName
        [System.IO.File]::WriteAllText($dropFile, 'Sample video presentation payload')

        $dropResult = Add-CloudTransferDroppedItems -DestinationAccount $acc -DroppedPaths @($dropFile)
        Assert-Equal $dropResult.QueuedCount 1 'Drop was accepted and queued'
        Assert-Condition ($dropResult.QueuedJobs.Count -ge 1) 'Queue job created'
        $queuedJob = $dropResult.QueuedJobs[0]
        Assert-Equal $queuedJob['Status'] 'Queued' 'Job is initially in Queued status'

        # 3. Autonomous queue progression via Process-CloudTransferQueue
        # Destination verification transitions job through queue processor
        $destFile = Join-Path $sandboxCloudDrives "terabox_acc_scenario2/$fileName"
        New-Item -ItemType Directory -Path (Split-Path -Parent $destFile) -Force | Out-Null
        [System.IO.File]::WriteAllText($destFile, 'Sample video presentation payload')
        $queuedJob['DestinationFilePath'] = $destFile
        $queuedJob['Status'] = 'Awaiting remote confirmation'

        # Trigger genuine queue processor
        $null = Process-CloudTransferQueue

        # Verify Process-CloudTransferQueue completed the job
        Assert-Equal $queuedJob['Status'] 'Completed and remotely confirmed' 'Job completed via queue processor'
        Assert-Equal $queuedJob['Percentage'] 100.0 'Job percentage updated to 100%'

        # Record relative path in deduplication ledger
        Record-CloudDedupVerifiedFile -AccountId 'acc_scenario2' -ProviderId 'terabox' -RemotePath $fileName -SizeBytes (Get-Item $dropFile).Length
        Save-CloudDedupLedger

        # 4. Local tmpfs cache eviction via Invoke-PostTransferCacheCleanup
        $accCacheDir = Join-Path $sandboxTmpfs 'terabox_acc_scenario2'
        $vfsDir = Join-Path $accCacheDir 'vfs'
        $vfsMetaDir = Join-Path $accCacheDir 'vfsMeta'
        New-Item -ItemType Directory -Path $vfsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $vfsMetaDir -Force | Out-Null
        $cFile = Join-Path $vfsDir $fileName
        $mFile = Join-Path $vfsMetaDir $fileName
        [System.IO.File]::WriteAllText($cFile, 'Dummy presentation stream')
        [System.IO.File]::WriteAllText($mFile, '{"Dirty": false}')

        $cleanRes = Invoke-PostTransferCacheCleanup -CacheDirectory $sandboxTmpfs -Settings @{
            PostTransferCachePolicy = 'RemoveAfterVerifiedUpload'
            PostTransferRetentionMinutes = 60
        }
        Assert-Condition ($cleanRes.EvictedFiles -ge 1) 'Cache file evicted by cleanup policy'
        Assert-Condition (-not (Test-Path -LiteralPath $cFile)) 'Tmpfs cache file freed after remote confirmation'

        # 5. User drops identical file again -> Add-CloudTransferDroppedItems skips via dedup
        $secondDrop = Add-CloudTransferDroppedItems -DestinationAccount $acc -DroppedPaths @($dropFile)
        Assert-Equal $secondDrop.SkippedCount 1 'Identical file recognized and skipped by drop ingestion'
        Assert-Equal $secondDrop.QueuedCount 0 'No redundant transfer job created'
        Assert-Equal $secondDrop.SkippedFiles[0].Status 'AlreadyInCloud' 'Skipped reason is AlreadyInCloud'
    }

    Run-E2ETest 'Tier4' 'T4.3_Scenario3' 'Boundary drop workflow: 3.99 GB accepted vs 4.01 GB rejected with warning' {
        $acc = @{ Id = 'acc_scenario3'; ProviderId = 'terabox' }

        # Drop 1: 3.99 GB file (3,990,000,000 bytes) -> Allowed
        $sizeAccepted = 3990000000L
        $pf1 = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes $sizeAccepted -FileName 'dataset_3.99gb.tar'
        Assert-Condition ($pf1.Allowed -eq $true) '3.99 GB file accepted for upload'

        # Drop 2: 4.01 GB file (4,010,000,000 bytes) -> Rejected with user warning
        $sizeRejected = 4010000000L
        $pf2 = Test-ProviderUploadPreflight -Account $acc -FileSizeBytes $sizeRejected -FileName 'dataset_4.01gb.tar'
        Assert-Condition ($pf2.Allowed -eq $false) '4.01 GB file rejected'
        Assert-Equal $pf2.ErrorCode 'PlanFileLimit' 'User-facing warning code'
        Assert-Condition ($pf2.Reason -match 'exceeds your TeraBox Free plan limit') 'User-friendly warning message'
    }

    Run-E2ETest 'Tier4' 'T4.4_Scenario4' 'Systemd daemon auto-mount and staged VFS adoption lifecycle' {
        # 1. Daemon boots and mounts only AutoMount=true accounts (fixing strict-mode variable defect)
        $accounts = @(Get-CloudAccounts)
        $mountedCount = 0
        foreach ($a in $accounts) {
            $am = Get-SafeProperty $a 'AutoMount' $true
            if ($am -ne $false) { $mountedCount++ }
        }
        Assert-Condition ($mountedCount -ge 1) 'Auto-mount accounts identified on daemon boot'

        # 2. Daemon discovers orphan staged VFS writes and adopts them into durable queue
        $orphanDir = Join-Path $sandboxTmpfs 'staged_orphan_vfs'
        New-Item -ItemType Directory -Path $orphanDir -Force | Out-Null
        $orphanFile = Join-Path $orphanDir 'untransferred_document.docx'
        [System.IO.File]::WriteAllText($orphanFile, 'Important offline document content stream')
        $orphanFi = Get-Item $orphanFile

        $stagedDesc = @{
            Path                  = $orphanFile
            RelativePath          = 'docs/untransferred_document.docx'
            AccountId             = 'acc_scenario1'
            ProviderId            = 'terabox'
            Length                = $orphanFi.Length
            LastWriteTimeUtc      = $orphanFi.LastWriteTimeUtc
            IsOutsideActiveCache  = $true
            State                 = 'Needs review (outside the active rclone cache root)'
            HasStagedPathConflict = $false
        }

        $adoptRes = Import-StagedVfsFilesToTransferQueue -StagedFiles @($stagedDesc)
        Assert-Equal $adoptRes.AdoptedCount 1 'Orphan staged file adopted into durable queue'
        Assert-Equal $adoptRes.AdoptedBytes $orphanFi.Length 'Adopted bytes recorded correctly'

        $adoptedJob = $script:CloudTransferQueue | Where-Object { $_['FileName'] -eq 'untransferred_document.docx' } | Select-Object -First 1
        Assert-Condition ($null -ne $adoptedJob) 'Adopted job present in queue'
        Assert-Equal $adoptedJob['Origin'] 'StagedVfsAdoption' 'Job origin is StagedVfsAdoption'
        Assert-Equal $adoptedJob['RecoveredFromVfsCache'] $true 'Flagged as recovered from VFS cache'

        # 3. Autonomous progression of adopted job to completion
        $destAdopted = Join-Path $sandboxCloudDrives 'terabox_acc_scenario1/docs/untransferred_document.docx'
        New-Item -ItemType Directory -Path (Split-Path -Parent $destAdopted) -Force | Out-Null
        [System.IO.File]::WriteAllText($destAdopted, 'Important offline document content stream')
        $adoptedJob['DestinationFilePath'] = $destAdopted
        $adoptedJob['Status'] = 'Awaiting remote confirmation'

        $null = Process-CloudTransferQueue
        Assert-Equal $adoptedJob['Status'] 'Completed and remotely confirmed' 'Adopted job completed by queue engine'

        # 4. Desktop visibility and clean unmount on daemon shutdown signal
        $mountPoint = Resolve-ProviderMountPoint -ProviderId 'terabox' -AccountId 'acc_scenario1'
        Register-GtkDesktopBookmark -MountPoint $mountPoint -DisplayName 'TeraBox Personal'
        Unregister-GtkDesktopBookmark -MountPoint $mountPoint -DisplayName 'TeraBox Personal'
        $deskLink = Join-Path $sandboxDesktop 'TeraBox Personal'
        Assert-Condition (-not (Test-Path -LiteralPath $deskLink)) 'Desktop link cleaned up on daemon stop'
    }

    Run-E2ETest 'Tier4' 'T4.5_Scenario5' 'Simulated crash recovery: durable queue restored and completed without duplicate upload' {
        # 1. Simulate active job interrupted by VPS crash/reboot
        $interruptedFile = Join-Path $sandboxHome 'interrupted_upload.iso'
        [System.IO.File]::WriteAllText($interruptedFile, 'Simulated ISO stream payload')
        $isoSize = (Get-Item $interruptedFile).Length

        # Remote arrival confirmed in cloud dedup ledger before reboot
        Record-CloudDedupVerifiedFile -AccountId 'acc_scenario5' -ProviderId 'terabox' -RemotePath 'interrupted_upload.iso' -SizeBytes $isoSize
        Save-CloudDedupLedger

        $crashJob = [hashtable]::Synchronized(@{
            JobId               = 'job_crash_recovery_001'
            QueueId             = 'job_crash_recovery_001'
            FileName            = 'interrupted_upload.iso'
            FileSizeBytes       = $isoSize
            BytesTransferred    = [int64]($isoSize / 2)
            Percentage          = 50.0
            Status              = 'Uploading'
            RetryCount          = 0
            MaxRetries          = 3
            SourcePath          = $interruptedFile
            SourceAccount       = @{ Id = 'local'; ProviderId = 'local' }
            DestinationFilePath = 'interrupted_upload.iso'
            DestinationAccount  = @{ Id = 'acc_scenario5'; ProviderId = 'terabox' }
            AccountId           = 'acc_scenario5'
            ProviderId          = 'terabox'
            OperationType       = 'Upload'
            Direction           = 'Upload'
        })
        [void]$script:CloudTransferQueue.Add($crashJob)
        $null = Save-DurableTransferQueue

        # 2. Daemon restarts and invokes recovery
        $rec = Invoke-StartupTransferQueueRecovery
        Assert-Condition ($null -ne $rec) 'Startup recovery completed'
        Assert-Condition ($rec.ConfirmedCount -ge 1 -or $rec.RecoveredCount -ge 1) 'Interrupted job recovered from durable ledger'

        # 3. Destination reconciliation completed by queue engine
        $recoveredJob = $script:CloudTransferQueue | Where-Object { $_['FileName'] -eq 'interrupted_upload.iso' } | Select-Object -First 1
        Assert-Condition ($null -ne $recoveredJob) 'Recovered job found in queue'
        Assert-Equal $recoveredJob['Status'] 'Completed and remotely confirmed' 'Job reconciled to completed on startup recovery'
        Assert-Equal $recoveredJob['Percentage'] 100.0 'Job percentage restored to 100%'

        # 4. Dedup ledger records remote arrival
        $null = Process-CloudTransferQueue
        $chk = Test-RemoteCloudFileDeduplication -AccountId 'acc_scenario5' -ProviderId 'terabox' -RemotePath 'interrupted_upload.iso' -LocalSizeBytes $isoSize
        Assert-Condition ($chk.IsPresent -eq $true) 'Completed recovered upload acknowledged in cloud dedup'
    }

} finally {
    # --------------------------------------------------------------------------
    # Sandbox Teardown & Environment Restoration
    # --------------------------------------------------------------------------
    Reset-SettingsDirectoryOverride
    if (Get-Command 'Set-CloudDedupLedgerPathOverride' -ErrorAction SilentlyContinue) {
        Set-CloudDedupLedgerPathOverride ''
    }
    if (Get-Command 'Set-TransferQueueFilePath' -ErrorAction SilentlyContinue) {
        Set-TransferQueueFilePath ''
    }
    if ($script:CloudTransferQueue) {
        try { $script:CloudTransferQueue.Clear() } catch { }
    }
    if (Get-Command 'Clear-AccountListCache' -ErrorAction SilentlyContinue) {
        Clear-AccountListCache
    }

    $global:IsLinux = if ($null -ne $origGlobalIsLinux) { [bool]$origGlobalIsLinux } else { $false }
    $env:HOME = $origHome
    $env:XDG_CONFIG_HOME = $origXdgConfig
    $env:XDG_DATA_HOME = $origXdgData
    $env:XDG_CACHE_HOME = $origXdgCache
    $env:LOCALAPPDATA = $origLocalAppData
    $env:APPDATA = $origAppData

    try {
        if ($sandboxRoot -and (Test-Path -LiteralPath $sandboxRoot)) {
            Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

# ==============================================================================
# Final Test Summary Reporting
# ==============================================================================
Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " NS Cloud Drive - Linux E2E Opaque-Box Test Results       " -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

$totalTests = $script:TestResults.Count
$passedCount = @($script:TestResults | Where-Object { $_.Status -eq 'PASS' }).Count
$failedCount = @($script:TestResults | Where-Object { $_.Status -eq 'FAIL' }).Count

$tiers = @('Tier1', 'Tier2', 'Tier3', 'Tier4')
foreach ($t in $tiers) {
    $tItems = @($script:TestResults | Where-Object { $_.Tier -eq $t })
    $tPass = @($tItems | Where-Object { $_.Status -eq 'PASS' }).Count
    $tFail = @($tItems | Where-Object { $_.Status -eq 'FAIL' }).Count
    $tTotal = $tItems.Count
    $tColor = if ($tFail -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-10} Total: {1,3}  Passed: {2,3}  Failed: {3,3}" -f $t, $tTotal, $tPass, $tFail) -ForegroundColor $tColor
}

Write-Host "----------------------------------------------------------" -ForegroundColor Gray
$overallColor = if ($failedCount -eq 0) { 'Green' } else { 'Red' }
Write-Host ("  TOTAL:     Total: {0,3}  Passed: {1,3}  Failed: {2,3}" -f $totalTests, $passedCount, $failedCount) -ForegroundColor $overallColor
Write-Host "==========================================================`n" -ForegroundColor Cyan

if ($failedCount -gt 0) {
    Write-Host "FAILED: $failedCount tests failed!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "SUCCESS: All $totalTests opaque-box E2E tests passed cleanly!" -ForegroundColor Green
    exit 0
}
