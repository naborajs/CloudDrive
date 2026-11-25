#!/usr/bin/env pwsh
# ==============================================================================
# NS Cloud Drive - Cross-Platform CLI & VPS Daemon
# Supports Linux (Ubuntu, Debian, Arch, RHEL) and Windows
# Provides headless mounting, automated queue syncing, and background daemon
# ==============================================================================

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Target = '',

    [Parameter(Position = 2)]
    [string]$Destination = '',

    [switch]$Help,
    [switch]$Foreground,
    [string]$LogFile = '',
    [string]$BandwidthLimit = '',

    # Onboarding & credential options
    [string]$Cookie = '',
    [string]$Token = '',
    [string]$DisplayName = '',
    [string]$AccountId = '',
    [string]$BaseUrl = 'https://www.terabox.com',
    [string]$User = '',
    [string]$Password = '',
    [string]$Endpoint = '',
    [string]$Bucket = '',
    [object]$AutoMount = $true,
    [switch]$ReadOnly,
    [switch]$Browser,
    [switch]$LoginSecretsFromEnv,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($LoginSecretsFromEnv) {
    if (-not $Cookie -and $env:NS_CLOUD_DRIVE_LOGIN_COOKIE) { $Cookie = $env:NS_CLOUD_DRIVE_LOGIN_COOKIE }
    if (-not $Token -and $env:NS_CLOUD_DRIVE_LOGIN_JSTOKEN) { $Token = $env:NS_CLOUD_DRIVE_LOGIN_JSTOKEN }
    Remove-Item Env:NS_CLOUD_DRIVE_LOGIN_COOKIE -ErrorAction SilentlyContinue
    Remove-Item Env:NS_CLOUD_DRIVE_LOGIN_JSTOKEN -ErrorAction SilentlyContinue
}

$script:CliDir = $PSScriptRoot
$script:SrcDir = (Split-Path -Parent $script:CliDir)
$script:AccountListCache = $null
$script:AccountListCacheAt = [DateTime]::MinValue
$script:AccountListCacheTtlSec = 5

# Import Core Models & Services (Headless - Zero UI/WPF dependency)
. (Join-Path $script:SrcDir 'models\ConnectionState.ps1')
. (Join-Path $script:SrcDir 'services\SettingsManager.ps1')
. (Join-Path $script:SrcDir 'providers\ProviderContract.ps1')
. (Join-Path $script:SrcDir 'providers\GoogleDriveProvider.ps1')
if (-not (Get-Command 'Test-TeraBoxBackendSession' -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SrcDir 'providers\TeraBoxProvider.ps1')
}
. (Join-Path $script:SrcDir 'providers\VpsProvider.ps1')
. (Join-Path $script:SrcDir 'providers\ProtonDriveProvider.ps1')
. (Join-Path $script:SrcDir 'providers\MegaProvider.ps1')
. (Join-Path $script:SrcDir 'providers\S3Provider.ps1')
. (Join-Path $script:SrcDir 'services\VirtualDriveManager.ps1')
. (Join-Path $script:SrcDir 'services\CloudDeduplicationService.ps1')
. (Join-Path $script:SrcDir 'services\CloudTransferManager.ps1')

function Get-SafeCount([object]$Collection) {
    if ($null -eq $Collection) { return 0 }
    return @($Collection).Count
}

function Show-CliBanner {
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "       NS Cloud Drive - Cross-Platform Linux/Windows      " -ForegroundColor White
    Write-Host "==========================================================" -ForegroundColor Cyan
}

function Show-CliHelp {
    Show-CliBanner
    Write-Host "Usage: nsclouddrive <command> [arguments] [options]`n" -ForegroundColor Yellow
    Write-Host "Commands:" -ForegroundColor White
    Write-Host "  app, gui                    Launch the standalone Desktop GUI application" -ForegroundColor Gray
    Write-Host "  login [provider] [options]  Authenticate and onboard cloud account (e.g. login terabox)" -ForegroundColor Gray
    Write-Host "  status                      Show connection, mount states, and active transfers" -ForegroundColor Gray
    Write-Host "  accounts                    List all configured cloud accounts" -ForegroundColor Gray
    Write-Host "  mount [all | <account/prov>] Mount cloud storage to filesystem (e.g. ~/CloudDrives/gdrive)" -ForegroundColor Gray
    Write-Host "  unmount [all | <account/pr>] Safely unmount active cloud drives" -ForegroundColor Gray
    Write-Host "  transfer <source> <account> [destPath] Resumable deduplicated cloud transfer" -ForegroundColor Gray
    Write-Host "  cloud-copy <sourceAccount> <sourcePath> <destinationAccount> [destinationPath] Resumable cloud-to-cloud copy" -ForegroundColor Gray
    Write-Host "  queue                       Display current durable transfer queue and progress" -ForegroundColor Gray
    Write-Host "  clear-queue                 Remove completed and settled jobs from transfer queue" -ForegroundColor Gray
    Write-Host "  recover                     Run silent startup recovery and restart reconciliation" -ForegroundColor Gray
    Write-Host "  ui [start|stop|status]      Launch the Web UI dashboard on http://127.0.0.1:8899" -ForegroundColor Gray
    Write-Host "  daemon                      Run continuous background service (auto-mount & sync)" -ForegroundColor Gray
    Write-Host "  help                        Show this help message`n" -ForegroundColor Gray
    Write-Host "Examples:" -ForegroundColor White
    Write-Host "  nsclouddrive ui" -ForegroundColor Gray
    Write-Host "  nsclouddrive login terabox --browser" -ForegroundColor Gray
    Write-Host "  nsclouddrive login terabox --cookie `"ndus=...`" --name `"Personal TeraBox`"" -ForegroundColor Gray
    Write-Host "  nsclouddrive accounts" -ForegroundColor Gray
    Write-Host "  nsclouddrive status" -ForegroundColor Gray
    Write-Host "  nsclouddrive mount all" -ForegroundColor Gray
    Write-Host "  nsclouddrive transfer /data/backups gdrive /backups" -ForegroundColor Gray
    Write-Host "  nsclouddrive daemon" -ForegroundColor Gray
}

function Show-CliAccounts {
    [CmdletBinding()]
    param(
        [switch]$PassThru
    )

    if (-not $PassThru) {
        Show-CliBanner
    }
    $accounts = @(Get-CloudAccounts)
    $accCount = Get-SafeCount $accounts
    if (-not $PassThru) {
        Write-Host "`n[ Configured Cloud Accounts: $accCount ]" -ForegroundColor Cyan
        if ($accCount -eq 0) {
            Write-Host "  No accounts configured. Use 'nsclouddrive login <provider>' to add an account." -ForegroundColor Yellow
            return
        }
    }

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($acc in $accounts) {
        $accId = [string](Get-CloudProviderFieldValue $acc 'Id' '')
        $prov = [string](Get-CloudProviderFieldValue $acc 'ProviderId' '')
        $name = [string](Get-CloudProviderFieldValue $acc 'DisplayName' $accId)
        $email = [string](Get-CloudProviderFieldValue $acc 'AccountEmail' '')
        if ([string]::IsNullOrWhiteSpace($email)) {
            $email = [string](Get-CloudProviderFieldValue $acc 'Email' 'N/A')
        }
        $autoMount = [bool](Get-CloudProviderFieldValue $acc 'AutoMount' $true)
        $dLetter = [string](Get-CloudProviderFieldValue $acc 'DriveLetter' '')
        $mountTarget = Resolve-ProviderMountPoint -ProviderId $prov -AccountId $accId -DriveLetter $dLetter

        $mStatus = Get-VirtualDriveStatus -AccountId $accId -ProviderId $prov
        $isMounted = [bool]($mStatus -and $mStatus.IsMounted)
        $statusColor = if ($isMounted) { 'Green' } else { 'DarkGray' }
        $mountInfo = if ($isMounted) { "Mounted ($($mStatus.DriveRoot))" } else { 'Unmounted' }

        if (-not $PassThru) {
            Write-Host "`n  * Account:      $name" -ForegroundColor White
            Write-Host "    Provider:     $prov" -ForegroundColor Gray
            Write-Host "    ID:           $accId" -ForegroundColor Gray
            Write-Host "    Email:        $email" -ForegroundColor Gray
            Write-Host "    Mount Target: $mountTarget" -ForegroundColor Cyan
            Write-Host "    Status:       $mountInfo" -ForegroundColor $statusColor
            Write-Host "    AutoMount:    $autoMount" -ForegroundColor Gray
        } else {
            $result.Add([pscustomobject]@{
                Id = $accId
                ProviderId = $prov
                DisplayName = $name
                AccountEmail = $email
                DriveLetter = $dLetter
                MountTarget = $mountTarget
                Status = $mountInfo
                AutoMount = $autoMount
                IsMounted = $isMounted
            })
        }
    }
    if (-not $PassThru) {
        Write-Host ""
    } else {
        return $result
    }
}

function Show-CliStatus {
    Show-CliBanner
    $accounts = @(Get-CloudAccounts)
    $accCount = Get-SafeCount $accounts
    Write-Host "`n[ Configured Accounts: $accCount ]" -ForegroundColor Cyan
    if ($accCount -eq 0) {
        Write-Host "  No accounts configured. Use desktop app or credentials folder to add accounts." -ForegroundColor Yellow
    } else {
        foreach ($acc in $accounts) {
            $accId = [string](Get-CloudProviderFieldValue $acc 'Id' '')
            $prov = [string](Get-CloudProviderFieldValue $acc 'ProviderId' '')
            $email = [string](Get-CloudProviderFieldValue $acc 'AccountEmail' '')
            if ([string]::IsNullOrWhiteSpace($email)) {
                $email = [string](Get-CloudProviderFieldValue $acc 'Email' 'N/A')
            }
            $mStatus = Get-VirtualDriveStatus -AccountId $accId -ProviderId $prov
            $isMounted = [bool]($mStatus -and $mStatus.IsMounted)
            $mountPath = if ($isMounted) { $mStatus.DriveRoot } else { 'Unmounted' }
            $statusColor = if ($isMounted) { 'Green' } else { 'DarkGray' }
            Write-Host "  * [$prov] $accId ($email)" -ForegroundColor White
            Write-Host "    Mount: $mountPath (Mounted=$isMounted)" -ForegroundColor $statusColor
        }
    }

    $rawQ = @()
    try {
        if (Get-Command Get-CloudTransferQueue -ErrorAction SilentlyContinue) {
            $rawQ = @(Get-CloudTransferQueue)
        }
    } catch { }
    $checkQ = if ((Get-SafeCount $rawQ) -gt 0 -and $rawQ[0] -is [array]) { @($rawQ[0]) } else { $rawQ }
    $queued = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -eq 'Queued' })
    $active = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -in @('Uploading', 'Staging') })
    $completed = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -eq 'Completed and remotely confirmed' })
    $failed = @($checkQ | Where-Object { $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('Status') -and $_['Status'] -eq 'Failed' })

    Write-Host "`n[ Transfer Queue State ]" -ForegroundColor Cyan
    Write-Host "  Queued: $(Get-SafeCount $queued) | Active: $(Get-SafeCount $active) | Completed: $(Get-SafeCount $completed) | Failed: $(Get-SafeCount $failed)" -ForegroundColor White
}

function Read-SafePrompt([string]$Prompt) {
    try {
        return (Read-Host -Prompt $Prompt)
    } catch {
        return $null
    }
}

function Invoke-CliLogin {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$ProviderId = '',

        [string]$Cookie = '',
        [string]$Token = '',
        [string]$DisplayName = '',
        [string]$AccountId = '',
        [string]$BaseUrl = 'https://www.terabox.com',
        [string]$User = '',
        [string]$Password = '',
        [string]$Endpoint = '',
        [string]$Bucket = '',
        [string]$DriveLetter = '',
        [object]$AutoMount = $true,
        [switch]$ReadOnly,
        [switch]$Browser,
        [switch]$LoginSecretsFromEnv,
        [switch]$PassThru,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$RemainingArgs = @()
    )

    if (-not $PassThru) {
        Show-CliBanner
    }

    $cleanProvider = $ProviderId
    $cleanAutoMount = if ($null -ne $AutoMount) { [bool]$AutoMount } else { $true }
    $cleanReadOnly = [bool]$ReadOnly
    $cleanBrowser = [bool]$Browser
    $cleanLoginSecretsFromEnv = [bool]$LoginSecretsFromEnv
    $cleanCookie = $Cookie
    $cleanToken = $Token
    $cleanDisplayName = $DisplayName
    $cleanAccountId = $AccountId
    $cleanBaseUrl = if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl } else { 'https://www.terabox.com' }
    $cleanUser = $User
    $cleanPassword = $Password
    $cleanEndpoint = $Endpoint
    $cleanBucket = $Bucket
    $finalAccId = $null
    $cleanDriveLetter = $DriveLetter

    if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
        $i = 0
        while ($i -lt $RemainingArgs.Count) {
            $arg = [string]$RemainingArgs[$i]
            if ([string]::IsNullOrWhiteSpace($arg)) {
                $i++
                continue
            }

            $key = $arg
            $val = $null

            if ($arg -match '^--?([^=]+)=(.*)$') {
                $key = $Matches[1]
                $val = $Matches[2]
            } elseif ($arg -match '^--?(.+)$') {
                $key = $Matches[1]
                if ($i + 1 -lt $RemainingArgs.Count -and $RemainingArgs[$i + 1] -notmatch '^-') {
                    $val = $RemainingArgs[$i + 1]
                    $i++
                } else {
                    $val = 'true'
                }
            } elseif ([string]::IsNullOrWhiteSpace($cleanProvider)) {
                $cleanProvider = $arg
                $i++
                continue
            }

            $normalizedKey = $key.ToLowerInvariant().Replace('_', '-')
            switch ($normalizedKey) {
                'provider'     { if (-not $cleanProvider) { $cleanProvider = $val } }
                'provider-id'  { if (-not $cleanProvider) { $cleanProvider = $val } }
                'providerid'   { if (-not $cleanProvider) { $cleanProvider = $val } }
                'cookie'       { if (-not $cleanCookie) { $cleanCookie = $val } }
                'token'        { if (-not $cleanToken) { $cleanToken = $val } }
                'name'         { if (-not $cleanDisplayName) { $cleanDisplayName = $val } }
                'display-name' { if (-not $cleanDisplayName) { $cleanDisplayName = $val } }
                'displayname'  { if (-not $cleanDisplayName) { $cleanDisplayName = $val } }
                'id'           { if (-not $cleanAccountId) { $cleanAccountId = $val } }
                'account-id'   { if (-not $cleanAccountId) { $cleanAccountId = $val } }
                'accountid'    { if (-not $cleanAccountId) { $cleanAccountId = $val } }
                'base-url'     { $cleanBaseUrl = $val }
                'baseurl'      { $cleanBaseUrl = $val }
                'user'         { if (-not $cleanUser) { $cleanUser = $val } }
                'username'     { if (-not $cleanUser) { $cleanUser = $val } }
                'email'        { if (-not $cleanUser) { $cleanUser = $val } }
                'password'     { if (-not $cleanPassword) { $cleanPassword = $val } }
                'pass'         { if (-not $cleanPassword) { $cleanPassword = $val } }
                'endpoint'     { if (-not $cleanEndpoint) { $cleanEndpoint = $val } }
                'bucket'       { if (-not $cleanBucket) { $cleanBucket = $val } }
                'drive-letter' { if (-not $cleanDriveLetter) { $cleanDriveLetter = $val } }
                'driveletter'  { if (-not $cleanDriveLetter) { $cleanDriveLetter = $val } }
                'drive'        { if (-not $cleanDriveLetter) { $cleanDriveLetter = $val } }
                'auto-mount'   { $cleanAutoMount = ($val -ne 'false' -and $val -ne '0') }
                'automount'    { $cleanAutoMount = ($val -ne 'false' -and $val -ne '0') }
                'no-auto-mount'{ $cleanAutoMount = $false }
                'no-automount' { $cleanAutoMount = $false }
                'read-only'    { $cleanReadOnly = ($val -ne 'false' -and $val -ne '0') }
                'readonly'     { $cleanReadOnly = ($val -ne 'false' -and $val -ne '0') }
                'browser'      { $cleanBrowser = ($val -ne 'false' -and $val -ne '0') }
                'login-secrets-from-env' { $cleanLoginSecretsFromEnv = ($val -ne 'false' -and $val -ne '0') }
                'passthru'     { $PassThru = ($val -ne 'false' -and $val -ne '0') }
                'pass-thru'    { $PassThru = ($val -ne 'false' -and $val -ne '0') }
            }
            $i++
        }
    }

    if ($cleanLoginSecretsFromEnv) {
        if (-not $cleanCookie -and $env:NS_CLOUD_DRIVE_LOGIN_COOKIE) { $cleanCookie = $env:NS_CLOUD_DRIVE_LOGIN_COOKIE }
        if (-not $cleanToken -and $env:NS_CLOUD_DRIVE_LOGIN_JSTOKEN) { $cleanToken = $env:NS_CLOUD_DRIVE_LOGIN_JSTOKEN }
        Remove-Item Env:NS_CLOUD_DRIVE_LOGIN_COOKIE -ErrorAction SilentlyContinue
        Remove-Item Env:NS_CLOUD_DRIVE_LOGIN_JSTOKEN -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($cleanProvider)) {
        Write-Host "`nSupported Cloud Providers:" -ForegroundColor Cyan
        Write-Host "  1) terabox (TeraBox Cloud - 1024 GB Free)" -ForegroundColor White
        Write-Host "  2) gdrive  (Google Drive)" -ForegroundColor White
        Write-Host "  3) vps     (VPS / Remote SFTP)" -ForegroundColor White
        Write-Host "  4) proton  (Proton Drive)" -ForegroundColor White
        Write-Host "  5) mega    (MEGA Cloud - 20 GB Free)" -ForegroundColor White
        Write-Host "  6) s3      (S3 / Object Storage)" -ForegroundColor White
        $choice = Read-SafePrompt -Prompt "Enter provider name or number [terabox]"
        $choice = if ($null -ne $choice) { ([string]$choice).Trim().ToLowerInvariant() } else { '' }
        $cleanProvider = switch ($choice) {
            '1' { 'terabox' }
            '2' { 'gdrive' }
            '3' { 'vps' }
            '4' { 'proton' }
            '5' { 'mega' }
            '6' { 's3' }
            ''  { 'terabox' }
            default { $choice }
        }
    }

    $provKey = $cleanProvider.ToLowerInvariant()

    $linuxVar = Get-Variable -Name 'IsLinux' -ValueOnly -ErrorAction SilentlyContinue
    $onLinux = if ($null -ne $linuxVar) { [bool]$linuxVar } elseif ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Unix) { $true } else { $false }

    $cleanLetter = if (-not [string]::IsNullOrWhiteSpace($cleanDriveLetter)) {
        ([string]$cleanDriveLetter).ToUpperInvariant().TrimEnd(':').TrimEnd('\')
    } else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($cleanLetter) -and -not $onLinux) {
        $prefLetter = if (Get-Command 'Get-PreferredDriveLetter' -ErrorAction SilentlyContinue) { Get-PreferredDriveLetter $provKey } else { 'G' }
        $cleanLetter = if (Get-Command 'Get-NextAvailableDriveLetter' -ErrorAction SilentlyContinue) { Get-NextAvailableDriveLetter $prefLetter } else { 'G' }
    }
    switch ($provKey) {
        'terabox' {
            if ($cleanBrowser) {
                Write-Host "Launching automated browser sign-in for TeraBox..." -ForegroundColor Cyan
                $pyScript = Join-Path $script:SrcDir 'web\cdp_interceptor.py'
                $pythonBin = if (Get-Command 'python3' -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }
                & $pythonBin -c "import cdp_interceptor, time, json; s = cdp_interceptor.login_session; s.start();
while s.state in ('launching', 'waiting', 'detected', 'validating'):
    time.sleep(1.5)
st = s.get_status()
print(json.dumps(st))
" | ForEach-Object {
                    try {
                        $st = $_ | ConvertFrom-Json
                        if ($st.state -eq 'success') {
                            Write-Host "  [SUCCESS] $($st.message)" -ForegroundColor Green
                        } else {
                            Write-Host "  [STATUS] $($st.message)" -ForegroundColor Yellow
                        }
                    } catch {
                        Write-Host "  $_" -ForegroundColor Gray
                    }
                }
                return
            }
            if ([string]::IsNullOrWhiteSpace($cleanCookie)) {
                $promptSecret = Read-SafePrompt -Prompt "Enter TeraBox ndus cookie (or full cookie string)"
                $cleanCookie = if ($promptSecret) { ([string]$promptSecret).Trim() } else { '' }
                if ([string]::IsNullOrWhiteSpace($cleanCookie)) {
                    Write-Host "  [ERROR] Missing required credentials. In non-interactive mode, pass values via CLI options." -ForegroundColor Red
                    return
                }
            }

            $formattedCookie = Format-TeraBoxCookieHeader $cleanCookie
            Write-Host "Validating TeraBox session credentials..." -ForegroundColor Cyan
            $validation = Test-TeraBoxBackendSession -SessionOverride @{
                Type = 'web-session'
                Secret = $formattedCookie
                BaseUrl = $cleanBaseUrl
            }

            if (-not $validation -or -not $validation.IsValid) {
                $errMsg = if ($validation -and $validation.Error) { $validation.Error } else { 'Session validation failed. Check your cookie and try again.' }
                Write-Host "  [ERROR] $errMsg" -ForegroundColor Red
                return
            }

            $uk = $null
            $uname = $null
            if ($validation.UserInfo) {
                $uk = Get-SafeProperty $validation.UserInfo 'Uk' $null
                $uname = Get-SafeProperty $validation.UserInfo 'UserName' $null
            }

            $finalAccId = if (-not [string]::IsNullOrWhiteSpace($cleanAccountId)) {
                $cleanAccountId
            } elseif ($uk) {
                "terabox_" + ([string]$uk -replace '[^a-zA-Z0-9_\-]', '_')
            } else {
                'terabox_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            }

            $finalDispName = if (-not [string]::IsNullOrWhiteSpace($cleanDisplayName)) {
                $cleanDisplayName
            } elseif ($uname) {
                "TeraBox ($uname)"
            } else {
                "TeraBox ($finalAccId)"
            }

            # Save session credentials securely
            Save-TeraBoxSession -Type 'web-session' -Secret $formattedCookie -BaseUrl $cleanBaseUrl -AccountId $finalAccId
            $credPath = Get-TeraBoxCredentialFilePath -AccountId $finalAccId
            Set-CloudCredentialAcl -Path $credPath

            # Register in SettingsManager
            $accountRecord = @{
                Id = $finalAccId
                ProviderId = 'terabox'
                DisplayName = $finalDispName
                AccountEmail = ''
                DriveLetter = $cleanLetter
                AutoMount = $cleanAutoMount
                ReadOnly = $cleanReadOnly
            }

            if (Test-CloudAccountPersisted $finalAccId) {
                $null = Update-CloudAccount $accountRecord
            } else {
                $null = Add-CloudAccount $accountRecord
            }

            $mountTarget = Resolve-ProviderMountPoint -ProviderId 'terabox' -AccountId $finalAccId -DriveLetter $cleanLetter
            Write-Host "  [SUCCESS] TeraBox account '$finalAccId' ($finalDispName) configured successfully." -ForegroundColor Green
            Write-Host "  Mount Target: $mountTarget" -ForegroundColor Cyan
            Write-Host "  AutoMount:    $cleanAutoMount" -ForegroundColor Gray
            Write-Host "  To mount now: nsclouddrive mount $finalAccId" -ForegroundColor Gray
        }

        'mega' {
            if ([string]::IsNullOrWhiteSpace($cleanUser)) {
                $promptUser = Read-SafePrompt -Prompt "Enter MEGA account email"
                $cleanUser = if ($promptUser) { ([string]$promptUser).Trim() } else { '' }
                if ([string]::IsNullOrWhiteSpace($cleanUser)) {
                    Write-Host "  [ERROR] Missing required credentials. In non-interactive mode, pass values via CLI options." -ForegroundColor Red
                    return
                }
            }
            if ([string]::IsNullOrWhiteSpace($cleanPassword)) {
                $promptPass = Read-SafePrompt -Prompt "Enter MEGA account password"
                $cleanPassword = if ($promptPass) { ([string]$promptPass).Trim() } else { '' }
                if ([string]::IsNullOrWhiteSpace($cleanPassword)) {
                    Write-Host "  [ERROR] Missing required credentials. In non-interactive mode, pass values via CLI options." -ForegroundColor Red
                    return
                }
            }

            $finalAccId = if (-not [string]::IsNullOrWhiteSpace($cleanAccountId)) {
                $cleanAccountId
            } else {
                'mega_' + ($cleanUser -replace '[^a-zA-Z0-9_\-]', '_')
            }
            $finalDispName = if (-not [string]::IsNullOrWhiteSpace($cleanDisplayName)) {
                $cleanDisplayName
            } else {
                "MEGA ($cleanUser)"
            }

            $null = Save-MegaSession -AccountId $finalAccId -SessionData @{ User = $cleanUser; Password = $cleanPassword }
            $credPath = Get-MegaCredentialFilePath -AccountId $finalAccId
            Set-CloudCredentialAcl -Path $credPath

            $accountRecord = @{
                Id = $finalAccId
                ProviderId = 'mega'
                DisplayName = $finalDispName
                AccountEmail = $cleanUser
                DriveLetter = $cleanLetter
                AutoMount = $cleanAutoMount
                ReadOnly = $cleanReadOnly
            }

            if (Test-CloudAccountPersisted $finalAccId) {
                $null = Update-CloudAccount $accountRecord
            } else {
                $null = Add-CloudAccount $accountRecord
            }

            $mountTarget = Resolve-ProviderMountPoint -ProviderId 'mega' -AccountId $finalAccId -DriveLetter $cleanLetter
            Write-Host "  [SUCCESS] MEGA account '$finalAccId' ($finalDispName) configured successfully." -ForegroundColor Green
            Write-Host "  Mount Target: $mountTarget" -ForegroundColor Cyan
            Write-Host "  AutoMount:    $cleanAutoMount" -ForegroundColor Gray
        }

        'vps' {
            if ([string]::IsNullOrWhiteSpace($cleanEndpoint)) {
                $promptEndpoint = Read-SafePrompt -Prompt "Enter SSH Host / IP"
                $cleanEndpoint = if ($promptEndpoint) { ([string]$promptEndpoint).Trim() } else { '' }
                if ([string]::IsNullOrWhiteSpace($cleanEndpoint)) {
                    Write-Host "  [ERROR] Missing required credentials. In non-interactive mode, pass values via CLI options." -ForegroundColor Red
                    return
                }
            }
            if ([string]::IsNullOrWhiteSpace($cleanUser)) {
                $promptUser = Read-SafePrompt -Prompt "Enter SSH Username"
                $cleanUser = if ($promptUser) { ([string]$promptUser).Trim() } else { '' }
                if ([string]::IsNullOrWhiteSpace($cleanUser)) {
                    Write-Host "  [ERROR] Missing required credentials. In non-interactive mode, pass values via CLI options." -ForegroundColor Red
                    return
                }
            }
            if ([string]::IsNullOrWhiteSpace($cleanPassword)) {
                $promptPass = Read-SafePrompt -Prompt "Enter SSH Password (or leave empty for key auth)"
                $cleanPassword = if ($promptPass) { ([string]$promptPass).Trim() } else { '' }
            }

            $finalAccId = if (-not [string]::IsNullOrWhiteSpace($cleanAccountId)) {
                $cleanAccountId
            } else {
                'vps_' + ($cleanEndpoint -replace '[^a-zA-Z0-9_\-]', '_')
            }
            $finalDispName = if (-not [string]::IsNullOrWhiteSpace($cleanDisplayName)) {
                $cleanDisplayName
            } else {
                "VPS ($cleanEndpoint)"
            }

            $null = Save-VpsSession -AccountId $finalAccId -SessionData @{ Host = $cleanEndpoint; User = $cleanUser; Password = $cleanPassword }
            $credPath = Get-VpsCredentialFilePath -AccountId $finalAccId
            Set-CloudCredentialAcl -Path $credPath

            $accountRecord = @{
                Id = $finalAccId
                ProviderId = 'vps'
                DisplayName = $finalDispName
                AccountEmail = "$cleanUser@$cleanEndpoint"
                DriveLetter = $cleanLetter
                AutoMount = $cleanAutoMount
                ReadOnly = $cleanReadOnly
            }

            if (Test-CloudAccountPersisted $finalAccId) {
                $null = Update-CloudAccount $accountRecord
            } else {
                $null = Add-CloudAccount $accountRecord
            }

            $mountTarget = Resolve-ProviderMountPoint -ProviderId 'vps' -AccountId $finalAccId -DriveLetter $cleanLetter
            Write-Host "  [SUCCESS] VPS account '$finalAccId' ($finalDispName) configured successfully." -ForegroundColor Green
            Write-Host "  Mount Target: $mountTarget" -ForegroundColor Cyan
            Write-Host "  AutoMount:    $cleanAutoMount" -ForegroundColor Gray
        }

        'gdrive' {
            if ([string]::IsNullOrWhiteSpace($cleanToken)) {
                Write-Host "  Google Drive requires OAuth authorization." -ForegroundColor Yellow
                Write-Host "  Pass --token <access_token> or authenticate via desktop app." -ForegroundColor Yellow
                return
            }

            $finalAccId = if (-not [string]::IsNullOrWhiteSpace($cleanAccountId)) {
                $cleanAccountId
            } else {
                'gdrive_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            }
            $finalDispName = if (-not [string]::IsNullOrWhiteSpace($cleanDisplayName)) {
                $cleanDisplayName
            } else {
                "Google Drive ($finalAccId)"
            }

            $null = Save-GoogleDriveTokens -TokenData @{ access_token = $cleanToken } -AccountId $finalAccId
            $credPath = Get-GoogleCredentialFilePath -AccountId $finalAccId
            Set-CloudCredentialAcl -Path $credPath

            $accountRecord = @{
                Id = $finalAccId
                ProviderId = 'gdrive'
                DisplayName = $finalDispName
                AccountEmail = ''
                DriveLetter = $cleanLetter
                AutoMount = $cleanAutoMount
                ReadOnly = $cleanReadOnly
            }

            if (Test-CloudAccountPersisted $finalAccId) {
                $null = Update-CloudAccount $accountRecord
            } else {
                $null = Add-CloudAccount $accountRecord
            }

            $mountTarget = Resolve-ProviderMountPoint -ProviderId 'gdrive' -AccountId $finalAccId -DriveLetter $cleanLetter
            Write-Host "  [SUCCESS] Google Drive account '$finalAccId' configured successfully." -ForegroundColor Green
            Write-Host "  Mount Target: $mountTarget" -ForegroundColor Cyan
            Write-Host "  AutoMount:    $cleanAutoMount" -ForegroundColor Gray
        }

        'proton' {
            if ([string]::IsNullOrWhiteSpace($cleanUser)) {
                $promptUser = Read-SafePrompt -Prompt "Enter Proton account username/email"
                $cleanUser = if ($promptUser) { ([string]$promptUser).Trim() } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($cleanPassword)) {
                $promptPass = Read-SafePrompt -Prompt "Enter Proton account password"
                $cleanPassword = if ($promptPass) { ([string]$promptPass).Trim() } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($cleanUser) -or [string]::IsNullOrWhiteSpace($cleanPassword)) {
                Write-Host "  [ERROR] Missing required credentials. In non-interactive mode, pass values via CLI options." -ForegroundColor Red
                return
            }

            $finalAccId = if (-not [string]::IsNullOrWhiteSpace($cleanAccountId)) {
                $cleanAccountId
            } else {
                'proton_' + ($cleanUser -replace '[^a-zA-Z0-9_\-]', '_')
            }
            $finalDispName = if (-not [string]::IsNullOrWhiteSpace($cleanDisplayName)) {
                $cleanDisplayName
            } else {
                "Proton ($cleanUser)"
            }

            $null = Save-ProtonDriveSession -AccountId $finalAccId -SessionData @{ Username = $cleanUser; Password = $cleanPassword }
            $credPath = Get-ProtonDriveCredentialFilePath -AccountId $finalAccId
            Set-CloudCredentialAcl -Path $credPath

            $accountRecord = @{
                Id = $finalAccId
                ProviderId = 'proton'
                DisplayName = $finalDispName
                AccountEmail = $cleanUser
                DriveLetter = $cleanLetter
                AutoMount = $cleanAutoMount
                ReadOnly = $cleanReadOnly
            }

            if (Test-CloudAccountPersisted $finalAccId) {
                $null = Update-CloudAccount $accountRecord
            } else {
                $null = Add-CloudAccount $accountRecord
            }

            $mountTarget = Resolve-ProviderMountPoint -ProviderId 'proton' -AccountId $finalAccId -DriveLetter $cleanLetter
            Write-Host "  [SUCCESS] Proton Drive account '$finalAccId' configured successfully." -ForegroundColor Green
            Write-Host "  Mount Target: $mountTarget" -ForegroundColor Cyan
            Write-Host "  AutoMount:    $cleanAutoMount" -ForegroundColor Gray
        }

        's3' {
            if ([string]::IsNullOrWhiteSpace($cleanEndpoint)) {
                $promptEndpoint = Read-SafePrompt -Prompt "Enter S3 Endpoint URL (e.g. https://s3.amazonaws.com)"
                $cleanEndpoint = if ($promptEndpoint) { ([string]$promptEndpoint).Trim() } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($cleanUser)) {
                $promptUser = Read-SafePrompt -Prompt "Enter S3 Access Key ID"
                $cleanUser = if ($promptUser) { ([string]$promptUser).Trim() } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($cleanPassword)) {
                $promptPass = Read-SafePrompt -Prompt "Enter S3 Secret Access Key"
                $cleanPassword = if ($promptPass) { ([string]$promptPass).Trim() } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($cleanBucket)) {
                $promptBucket = Read-SafePrompt -Prompt "Enter S3 Bucket Name"
                $cleanBucket = if ($promptBucket) { ([string]$promptBucket).Trim() } else { '' }
            }
            if ([string]::IsNullOrWhiteSpace($cleanEndpoint) -or [string]::IsNullOrWhiteSpace($cleanUser) -or [string]::IsNullOrWhiteSpace($cleanPassword)) {
                Write-Host "  [ERROR] Missing required credentials. In non-interactive mode, pass values via CLI options." -ForegroundColor Red
                return
            }

            $finalAccId = if (-not [string]::IsNullOrWhiteSpace($cleanAccountId)) {
                $cleanAccountId
            } else {
                's3_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            }
            $finalDispName = if (-not [string]::IsNullOrWhiteSpace($cleanDisplayName)) {
                $cleanDisplayName
            } else {
                "S3 ($cleanBucket)"
            }

            $null = Save-S3Session -AccountId $finalAccId -SessionData @{
                Endpoint = $cleanEndpoint
                AccessKey = $cleanUser
                SecretKey = $cleanPassword
                AccessKeyId = $cleanUser
                SecretAccessKey = $cleanPassword
                Bucket = $cleanBucket
            }
            $credPath = Get-S3CredentialFilePath -AccountId $finalAccId
            Set-CloudCredentialAcl -Path $credPath

            $accountRecord = @{
                Id = $finalAccId
                ProviderId = 's3'
                DisplayName = $finalDispName
                AccountEmail = ''
                DriveLetter = $cleanLetter
                AutoMount = $cleanAutoMount
                ReadOnly = $cleanReadOnly
            }

            if (Test-CloudAccountPersisted $finalAccId) {
                $null = Update-CloudAccount $accountRecord
            } else {
                $null = Add-CloudAccount $accountRecord
            }

            $mountTarget = Resolve-ProviderMountPoint -ProviderId 's3' -AccountId $finalAccId -DriveLetter $cleanLetter
            Write-Host "  [SUCCESS] S3 account '$finalAccId' configured successfully." -ForegroundColor Green
            Write-Host "  Mount Target: $mountTarget" -ForegroundColor Cyan
            Write-Host "  AutoMount:    $cleanAutoMount" -ForegroundColor Gray
        }

        default {
            Write-Host "  [ERROR] Unsupported provider '$cleanProvider'. Supported providers: terabox, gdrive, vps, proton, mega, s3." -ForegroundColor Red
        }
    }

    if ($PassThru -and -not [string]::IsNullOrWhiteSpace($finalAccId)) {
        return (Get-CloudAccount $finalAccId)
    }
}

function Register-GtkDesktopBookmark {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName = ''
    )

    $homeDir = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
    $gtkDir = Join-Path (Join-Path $homeDir '.config') 'gtk-3.0'
    if (-not (Test-Path -LiteralPath $gtkDir)) {
        New-Item -ItemType Directory -Path $gtkDir -Force | Out-Null
    }
    $bookmarkFile = Join-Path $gtkDir 'bookmarks'
    $label = if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName } else { [System.IO.Path]::GetFileName($MountPoint.TrimEnd('\', '/')) }
    $normMount = $MountPoint.Replace('\', '/')
    $uri = if ($normMount.StartsWith('/')) { "file://$normMount" } else { "file:///$normMount" }
    $line = "$uri $label"

    $existing = @()
    if (Test-Path -LiteralPath $bookmarkFile) {
        $existing = @(Get-Content -LiteralPath $bookmarkFile -ErrorAction SilentlyContinue)
    }
    if ($existing -notcontains $line -and @($existing | Where-Object { $_.StartsWith("$uri ") }).Count -eq 0) {
        Add-Content -LiteralPath $bookmarkFile -Value $line
    }

    $desktopDir = Join-Path $homeDir 'Desktop'
    if (-not (Test-Path -LiteralPath $desktopDir)) {
        New-Item -ItemType Directory -Path $desktopDir -Force | Out-Null
    }
    $desktopLink = Join-Path $desktopDir $label
    if (-not (Test-Path -LiteralPath $desktopLink)) {
        try {
            $null = New-Item -ItemType SymbolicLink -Path $desktopLink -Target $MountPoint -Force -ErrorAction Stop
        } catch {
            [System.IO.File]::WriteAllText($desktopLink, "[Desktop Entry]`nType=Link`nURL=$uri`nName=$label")
        }
    }
}

function Unregister-GtkDesktopBookmark {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MountPoint,

        [Parameter(Mandatory = $false)]
        [string]$DisplayName = ''
    )

    $homeDir = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
    $gtkDir = Join-Path (Join-Path $homeDir '.config') 'gtk-3.0'
    $bookmarkFile = Join-Path $gtkDir 'bookmarks'
    $normMount = $MountPoint.Replace('\', '/')
    $uri = if ($normMount.StartsWith('/')) { "file://$normMount" } else { "file:///$normMount" }

    if (Test-Path -LiteralPath $bookmarkFile) {
        $existing = @(Get-Content -LiteralPath $bookmarkFile -ErrorAction SilentlyContinue)
        $filtered = @($existing | Where-Object { -not $_.StartsWith("$uri ") -and -not ($_ -eq $uri) })
        [System.IO.File]::WriteAllLines($bookmarkFile, $filtered)
    }

    $label = if (-not [string]::IsNullOrWhiteSpace($DisplayName)) { $DisplayName } else { [System.IO.Path]::GetFileName($MountPoint.TrimEnd('\', '/')) }
    $desktopDir = Join-Path $homeDir 'Desktop'
    $desktopLink = Join-Path $desktopDir $label
    if (Test-Path -LiteralPath $desktopLink) {
        Remove-Item -LiteralPath $desktopLink -Force -ErrorAction SilentlyContinue
    }
}

function Get-CliDaemonPidPath {
    $homeDir = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
    $runtimeDir = if ($env:XDG_RUNTIME_DIR) {
        $env:XDG_RUNTIME_DIR
    } else {
        Join-Path (Join-Path $homeDir '.local') 'run'
    }
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }
    return (Join-Path $runtimeDir 'nsclouddrive.pid')
}

function Test-CliDaemonRunning {
    $pidFile = Get-CliDaemonPidPath
    if (-not (Test-Path -LiteralPath $pidFile)) {
        return $false
    }
    $rawPid = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($rawPid)) {
        return $false
    }
    $parsedPid = 0
    if (-not [int]::TryParse($rawPid.Trim(), [ref]$parsedPid)) {
        return $false
    }
    try {
        $proc = [System.Diagnostics.Process]::GetProcessById($parsedPid)
        return ($null -ne $proc -and -not $proc.HasExited)
    } catch {
        return $false
    }
}

function Invoke-CliDaemonShutdown {
    $unmounted = $false
    try {
        $stopRes = Stop-VirtualDriveMount
        $unmounted = $true
    } catch {
        $unmounted = $false
    }
    $pidFile = Get-CliDaemonPidPath
    if (Test-Path -LiteralPath $pidFile) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Success = $true
        Unmounted = $unmounted
    }
}

function Install-LinuxSystemdService {
    $homeDir = if ($env:HOME) { $env:HOME } else { [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile) }
    $systemdUserDir = if ($env:XDG_CONFIG_HOME) {
        Join-Path $env:XDG_CONFIG_HOME 'systemd/user'
    } else {
        Join-Path (Join-Path $homeDir '.config') 'systemd/user'
    }
    if (-not (Test-Path -LiteralPath $systemdUserDir)) {
        New-Item -ItemType Directory -Path $systemdUserDir -Force | Out-Null
    }
    $unitPath = Join-Path $systemdUserDir 'nsclouddrive.service'
    $unitContent = @'
[Unit]
Description=NS Cloud Drive User Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/pwsh -NoProfile -File %h/CloudDrive/src/cli/nsclouddrive.ps1 daemon
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
'@
    [System.IO.File]::WriteAllText($unitPath, $unitContent)
    return $systemdUserDir
}

function Invoke-CliMount {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$TargetAccount = 'all',

        [switch]$OnlyAutoMount
    )

    $accounts = @(Get-CloudAccounts)
    if ($accounts.Count -eq 0) {
        Write-Host "No accounts found to mount." -ForegroundColor Yellow
        return
    }

    $toMount = @()
    if ([string]::IsNullOrWhiteSpace($TargetAccount) -or $TargetAccount -eq 'all') {
        $toMount = $accounts
    } else {
        $toMount = @($accounts | Where-Object {
            $aid = [string](Get-CloudProviderFieldValue $_ 'Id')
            $provId = [string](Get-CloudProviderFieldValue $_ 'ProviderId')
            $aid -eq $TargetAccount -or $provId -eq $TargetAccount
        })
    }

    if ($OnlyAutoMount) {
        $toMount = @($toMount | Where-Object {
            $am = Get-CloudProviderFieldValue $_ 'AutoMount' $true
            $am -ne $false
        })
    }

    if ($toMount.Count -eq 0) {
        Write-Host "No matching accounts found for target '$TargetAccount'." -ForegroundColor Yellow
        return
    }

    foreach ($acc in $toMount) {
        $accId = [string](Get-CloudProviderFieldValue $acc 'Id')
        $prov = [string](Get-CloudProviderFieldValue $acc 'ProviderId')
        Write-Host "Mounting $accId ($prov)..." -ForegroundColor Cyan
        try {
            $mountRes = Start-VirtualDriveMount -ProviderId $prov -AccountId $accId
            if ($mountRes.Success) {
                Write-Host "  [SUCCESS] Mounted to $($mountRes.DriveRoot)" -ForegroundColor Green
                try {
                    $dName = [string](Get-CloudProviderFieldValue $acc 'DisplayName' $accId)
                    Register-GtkDesktopBookmark -MountPoint $mountRes.DriveRoot -DisplayName $dName
                } catch { }
            } else {
                Write-Host "  [FAILED] Could not mount: $($mountRes.Message)" -ForegroundColor Red
            }
        } catch {
            Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Invoke-CliUnmount([string]$TargetAccount = 'all') {
    Write-Host "Unmounting targets..." -ForegroundColor Cyan
    try {
        if ([string]::IsNullOrWhiteSpace($TargetAccount) -or $TargetAccount -eq 'all') {
            $accounts = @(Get-CloudAccounts)
            foreach ($acc in $accounts) {
                $aid = [string](Get-CloudProviderFieldValue $acc 'Id')
                $provId = [string](Get-CloudProviderFieldValue $acc 'ProviderId')
                $mStatus = Get-VirtualDriveStatus -AccountId $aid -ProviderId $provId
                $mRoot = if ($mStatus -and $mStatus.DriveRoot) { $mStatus.DriveRoot } else { Resolve-ProviderMountPoint -ProviderId $provId -AccountId $aid }
                $dName = [string](Get-CloudProviderFieldValue $acc 'DisplayName' $aid)
                try { Unregister-GtkDesktopBookmark -MountPoint $mRoot -DisplayName $dName } catch { }
            }
            $res = Stop-VirtualDriveMount
        } else {
            $accObj = Get-CloudAccount $TargetAccount
            $provId = if ($accObj -and $accObj.ProviderId) { [string]$accObj.ProviderId } else { $TargetAccount }
            $mStatus = Get-VirtualDriveStatus -AccountId $TargetAccount -ProviderId $provId
            $mRoot = if ($mStatus -and $mStatus.DriveRoot) { $mStatus.DriveRoot } else { Resolve-ProviderMountPoint -ProviderId $provId -AccountId $TargetAccount }
            $dName = if ($accObj -and $accObj.DisplayName) { [string]$accObj.DisplayName } else { $TargetAccount }
            try { Unregister-GtkDesktopBookmark -MountPoint $mRoot -DisplayName $dName } catch { }
            $res = Stop-VirtualDriveMount -AccountId $TargetAccount -ProviderId $TargetAccount
        }
        Write-Host "  [SUCCESS] $($res.Message)" -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Invoke-CliTransfer([string]$SourcePath, [string]$TargetAccount, [string]$DestSubPath = '') {
    if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath)) {
        Write-Host "Source path not found: $SourcePath" -ForegroundColor Red
        return
    }

    $accounts = @(Get-CloudAccounts)
    $destAcc = @($accounts | Where-Object {
        $aid = [string](Get-CloudProviderFieldValue $_ 'Id')
        $provId = [string](Get-CloudProviderFieldValue $_ 'ProviderId')
        $aid -eq $TargetAccount -or $provId -eq $TargetAccount
    }) | Select-Object -First 1

    if (-not $destAcc) {
        Write-Host "Destination account '$TargetAccount' not found in settings." -ForegroundColor Red
        return
    }

    $destAccId = [string](Get-CloudProviderFieldValue $destAcc 'Id')
    $destProvId = [string](Get-CloudProviderFieldValue $destAcc 'ProviderId')
    $localAcc = @{ Id = 'local'; ProviderId = 'local'; Label = 'Local Storage' }
    Write-Host "Analyzing '$SourcePath' for cloud transfer..." -ForegroundColor Cyan

    $isDir = (Test-Path -LiteralPath $SourcePath -PathType Container)
    if ($isDir) {
        $batch = Add-CloudTransferFolderBatch -SourceAccount $localAcc -SourceFolderPath $SourcePath `
            -DestinationAccount $destAcc -DestinationFolderPath $DestSubPath -ConflictAction Skip
        Write-Host "  Ingested Folder Batch: $($batch.BatchName) ($($batch.TotalFiles) files, $($batch.TotalBytes) bytes)" -ForegroundColor White
        Write-Host "  Already in Cloud (Skipped): $($batch.AlreadyInCloudCount) files ($($batch.AlreadyInCloudBytes) bytes)" -ForegroundColor Green
        Write-Host "  Queued for Transfer: $($batch.QueuedCount) files" -ForegroundColor Yellow

        $summary = Get-CloudTransferBatchSummary -BatchId $batch.BatchId
        if ($summary) {
            Write-Host "  Batch Initial Progression: $($summary.OverallPercentage)%" -ForegroundColor Cyan
        }
    } else {
        $fi = [System.IO.FileInfo]::new($SourcePath)
        $cleanDest = if ($DestSubPath) { Normalize-CloudPath "$DestSubPath/$($fi.Name)" } else { $fi.Name }
        $dedup = Test-RemoteCloudFileDeduplication -AccountId $destAccId -ProviderId $destProvId `
            -RemotePath $cleanDest -LocalSizeBytes $fi.Length -LocalFilePath $SourcePath -Account $destAcc
        if ($dedup.IsPresent) {
            Write-Host "  [SKIPPED] File already exists in cloud with matching format and exact byte size ($($fi.Length) bytes)." -ForegroundColor Green
            return
        }
        $job = Add-CloudTransferQueueItem -SourceAccount $localAcc -SourcePath $SourcePath `
            -DestinationAccount $destAcc -DestinationPath $DestSubPath -ConflictAction Skip
        Write-Host "  [QUEUED] Job enqueued: $($job.JobId) ($($fi.Length) bytes)" -ForegroundColor Yellow
    }

    Write-Host "Processing queue in background..." -ForegroundColor Cyan
    $null = Process-CloudTransferQueue
}

function Invoke-CliCloudCopy([string]$SourceAccountId, [string]$SourcePath, [string]$DestinationAccountId, [string]$DestinationPath = '') {
    if ([string]::IsNullOrWhiteSpace($SourceAccountId) -or [string]::IsNullOrWhiteSpace($SourcePath) -or [string]::IsNullOrWhiteSpace($DestinationAccountId)) {
        throw 'Usage: nsclouddrive cloud-copy <sourceAccount> <sourcePath> <destinationAccount> [destinationPath]'
    }
    if ($SourcePath.StartsWith('/') -or $SourcePath.Contains('\') -or $SourcePath.StartsWith('-') -or
        @($SourcePath.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0) {
        throw 'Source path must be a relative cloud path without parent-directory segments.'
    }
    if ($DestinationPath -and ($DestinationPath.StartsWith('/') -or $DestinationPath.Contains('\') -or $DestinationPath.StartsWith('-') -or
        @($DestinationPath.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0)) {
        throw 'Destination path must be a relative cloud folder path without parent-directory segments.'
    }

    $accounts = @(Get-CloudAccounts)
    $sourceAccount = @($accounts | Where-Object { [string](Get-CloudProviderFieldValue $_ 'Id') -eq $SourceAccountId }) | Select-Object -First 1
    $destinationAccount = @($accounts | Where-Object { [string](Get-CloudProviderFieldValue $_ 'Id') -eq $DestinationAccountId }) | Select-Object -First 1
    if (-not $sourceAccount -or -not $destinationAccount) {
        throw 'Source or destination account was not found in local settings.'
    }
    if ([string](Get-CloudProviderFieldValue $sourceAccount 'ProviderId') -eq 'local' -or
        [string](Get-CloudProviderFieldValue $destinationAccount 'ProviderId') -eq 'local') {
        throw 'Cloud copy requires cloud accounts at both endpoints.'
    }

    $normalizedSourcePath = Normalize-CloudPath -Path $SourcePath
    $sourceParent = if ($normalizedSourcePath.Contains('/')) { $normalizedSourcePath.Substring(0, $normalizedSourcePath.LastIndexOf('/')) } else { '' }
    $sourceName = if ($normalizedSourcePath.Contains('/')) { $normalizedSourcePath.Substring($normalizedSourcePath.LastIndexOf('/') + 1) } else { $normalizedSourcePath }
    $sourceEntry = $null
    foreach ($entry in @(Get-CloudDirectoryContents -Account $sourceAccount -Path $sourceParent -BypassLocalMount)) {
        if ([string]::Equals([string](Get-CloudProviderFieldValue $entry 'Name'), $sourceName, [System.StringComparison]::Ordinal)) {
            $sourceEntry = $entry
            break
        }
    }
    if ($null -eq $sourceEntry) { throw "Cloud source path '$normalizedSourcePath' was not found." }

    $batch = Add-CloudTransferRemoteBatch `
        -SourceAccount $sourceAccount `
        -SourcePath $normalizedSourcePath `
        -SourceIsDirectory:([bool](Get-CloudProviderFieldValue $sourceEntry 'IsDir')) `
        -DestinationAccount $destinationAccount `
        -DestinationFolderPath (Normalize-CloudPath -Path $DestinationPath) `
        -ConflictAction 'Skip'

    Write-Host "Cloud copy scanned $($batch.TotalFiles) file(s)." -ForegroundColor Cyan
    Write-Host "  Already present or same location: $($batch.AlreadyPresentCount)" -ForegroundColor Green
    Write-Host "  Already tracked in durable queue: $($batch.AlreadyQueuedCount)" -ForegroundColor Cyan
    Write-Host "  Queued for resumable copy: $($batch.QueuedCount)" -ForegroundColor Yellow
    if ($batch.QueuedCount -gt 0) {
        $null = Process-CloudTransferQueue
        Write-Host 'Transfer workers started; progress is available with `nsclouddrive queue`.' -ForegroundColor Cyan
    }
}

function Show-CliQueue {
    $rawQ = @()
    try {
        if (Get-Command Get-CloudTransferQueue -ErrorAction SilentlyContinue) {
            $rawQ = @(Get-CloudTransferQueue)
        }
    } catch { }
    $checkQ = if ((Get-SafeCount $rawQ) -gt 0 -and $rawQ[0] -is [array]) { @($rawQ[0]) } else { $rawQ }
    $qCount = Get-SafeCount $checkQ
    Write-Host "`n=== Durable Transfer Queue ($qCount items) ===" -ForegroundColor Cyan
    if ($qCount -eq 0) {
        Write-Host "  Queue is empty." -ForegroundColor DarkGray
        return
    }

    foreach ($item in $checkQ) {
        $name = [string]$item['FileName']
        $st = [string]$item['Status']
        $pct = [double]$item['Percentage']
        $sz = [int64]$item['FileSizeBytes']
        $col = switch ($st) {
            'Completed and remotely confirmed' { 'Green' }
            'Uploading' { 'Yellow' }
            'Queued' { 'Cyan' }
            'Failed' { 'Red' }
            default { 'Gray' }
        }
        Write-Host "  * [$st] $name ($sz bytes) - $pct%" -ForegroundColor $col
    }
}

function Start-CliDaemon {
    Show-CliBanner
    Write-Host "Starting NS Cloud Drive Daemon for Linux VPS / Background Service..." -ForegroundColor Green
    Write-Host "Auto-mounting configured accounts..." -ForegroundColor Cyan
    Invoke-CliMount -TargetAccount 'all' -OnlyAutoMount

    # Recovery needs a live provider view to tell an absent object from an
    # unreachable remote. Start the configured mounts before reconciling jobs.
    Write-Host "Running startup recovery after mount initialization..." -ForegroundColor Cyan
    try {
        $rec = Invoke-StartupTransferQueueRecovery
        Write-Host "  Recovery Summary: $($rec.RecoveredCount) recovered, $($rec.ConfirmedCount) confirmed, $($rec.ResetCount) reset." -ForegroundColor White
    } catch {
        Write-Host "  Recovery notice: $($_.Exception.Message)" -ForegroundColor DarkGray
    }

    $pidFile = Get-CliDaemonPidPath
    [System.IO.File]::WriteAllText($pidFile, [System.Diagnostics.Process]::GetCurrentProcess().Id.ToString())

    Write-Host "`nDaemon active. Listening for transfer queue work (Press Ctrl+C to stop)..." -ForegroundColor Green
    $cycle = 0
    try {
        while ($true) {
            try {
                $null = Process-CloudTransferQueue
                $cycle++
                if ($cycle % 60 -eq 0) {
                    # Periodic log rotation & maintenance every 5 minutes
                    $null = Invoke-LogMaintenance
                }
            } catch { }
            [System.Threading.Thread]::Sleep(5000)
        }
    } finally {
        $null = Invoke-CliDaemonShutdown
    }
}

function Invoke-CliUi {
    [CmdletBinding()]
    param(
        [string]$SubAction = 'start',
        [int]$Port = 8899
    )

    $uiScript = Join-Path $script:SrcDir 'web\app.py'
    if (-not (Test-Path $uiScript)) {
        Write-Host "Web UI script not found at $uiScript" -ForegroundColor Red
        return
    }

    $pythonBin = if (Get-Command 'python3' -ErrorAction SilentlyContinue) { 'python3' } else { 'python' }

    switch ($SubAction.ToLowerInvariant()) {
        'stop' {
            Write-Host "Stopping NS Cloud Drive Web UI..." -ForegroundColor Cyan
            if ($IsLinux) {
                $null = & fuser -k "${Port}/tcp" 2>&1
            }
            Write-Host "Web UI stopped." -ForegroundColor Green
        }
        'status' {
            try {
                $resp = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/api/state" -TimeoutSec 3 -ErrorAction Stop
                Write-Host "NS Cloud Drive Web UI is running on http://127.0.0.1:${Port}" -ForegroundColor Green
                Write-Host "  Service: $($resp.service)" -ForegroundColor White
                Write-Host "  Accounts: $(Get-SafeCount $resp.accounts)" -ForegroundColor White
            } catch {
                Write-Host "NS Cloud Drive Web UI is not running on port $Port." -ForegroundColor DarkGray
            }
        }
        default {
            Write-Host "Starting NS Cloud Drive Web UI on http://127.0.0.1:${Port}..." -ForegroundColor Green
            $envCopy = [System.Collections.IDictionary]([System.Environment]::GetEnvironmentVariables())
            if ($IsLinux -and -not $envCopy.Contains('DISPLAY')) {
                $envCopy['DISPLAY'] = ':1'
            }
            $procStart = [System.Diagnostics.ProcessStartInfo]::new()
            $procStart.FileName = $pythonBin
            $procStart.Arguments = "`"$uiScript`" --port $Port"
            $procStart.UseShellExecute = $false
            $procStart.CreateNoWindow = $true
            foreach ($k in $envCopy.Keys) {
                $procStart.EnvironmentVariables[[string]$k] = [string]$envCopy[$k]
            }
            $proc = [System.Diagnostics.Process]::Start($procStart)
            Start-Sleep -Milliseconds 1000
            Write-Host "NS Cloud Drive Web UI launched (PID $($proc.Id)) on http://127.0.0.1:${Port}" -ForegroundColor Green

            if ($IsLinux -and (Get-Command 'chromium' -ErrorAction SilentlyContinue) -and ($envCopy.Contains('DISPLAY') -or (Test-Path '/tmp/.X11-unix/X1'))) {
                Start-Process -FilePath 'chromium' -ArgumentList "http://127.0.0.1:${Port}" -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-CliApp {
    [CmdletBinding()]
    param()

    $appLauncher = Join-Path (Split-Path -Parent $script:SrcDir) 'scripts/nsclouddrive-app'
    if ($IsLinux -and (Test-Path $appLauncher)) {
        Write-Host "Launching NS Cloud Drive Desktop Application..." -ForegroundColor Green
        $null = Start-Process -FilePath '/usr/bin/env' -ArgumentList "bash `"$appLauncher`"" -ErrorAction SilentlyContinue
        return
    }

    # Fallback to UI server & browser
    Invoke-CliUi -SubAction 'start'
}

# Command Dispatcher
if ($MyInvocation.InvocationName -eq '.' -or $Command.ToLowerInvariant() -in @('', 'import', 'none')) {
    return
}

# Auto-launch desktop app if invoked with no arguments in a graphical desktop session
if (-not $PSBoundParameters.ContainsKey('Command') -and -not $Help -and $IsLinux) {
    if ($env:DISPLAY -or (Test-Path '/tmp/.X11-unix/X1') -or (Test-Path '/tmp/.X11-unix/X0')) {
        Invoke-CliApp
        return
    }
}

switch ($Command.ToLowerInvariant()) {
    'app'          { Invoke-CliApp }
    'gui'          { Invoke-CliApp }
    'status'       { Show-CliStatus }
    'accounts'     { Show-CliAccounts }
    'ui'           { Invoke-CliUi -SubAction $Target }
    'login'        {
        $loginProvider = $Target
        $allRemaining = @()
        if ($Target -match '^--?') {
            $loginProvider = ''
            $allRemaining += $Target
        }
        if (-not [string]::IsNullOrWhiteSpace($Destination)) {
            $allRemaining += $Destination
        }
        if ($RemainingArgs) {
            $allRemaining += $RemainingArgs
        }
        Invoke-CliLogin -ProviderId $loginProvider `
            -Cookie $Cookie -Token $Token -DisplayName $DisplayName -AccountId $AccountId `
            -BaseUrl $BaseUrl -User $User -Password $Password -Endpoint $Endpoint -Bucket $Bucket `
            -AutoMount $AutoMount -ReadOnly:$ReadOnly -Browser:$Browser -LoginSecretsFromEnv:$LoginSecretsFromEnv -RemainingArgs $allRemaining
    }
    'mount'        { Invoke-CliMount -TargetAccount $Target }
    'unmount'      { Invoke-CliUnmount -TargetAccount $Target }
    'transfer'     { Invoke-CliTransfer -SourcePath $Target -TargetAccount $Destination -DestSubPath '' }
    'cloud-copy'   {
        $destinationAccountId = if ($RemainingArgs.Count -gt 0) { [string]$RemainingArgs[0] } else { '' }
        $destinationPath = if ($RemainingArgs.Count -gt 1) { [string]$RemainingArgs[1] } else { '' }
        Invoke-CliCloudCopy -SourceAccountId $Target -SourcePath $Destination `
            -DestinationAccountId $destinationAccountId -DestinationPath $destinationPath
    }
    'queue'        { Show-CliQueue }
    'clear-queue'  { Clear-CloudTransferQueue; Write-Host "Transfer queue cleared." -ForegroundColor Green }
    'recover'      {
        $rec = Invoke-StartupTransferQueueRecovery
        Write-Host "Startup recovery finished: $($rec.RecoveredCount) recovered, $($rec.ConfirmedCount) confirmed, $($rec.ResetCount) reset." -ForegroundColor Green
    }
    'daemon'       { Start-CliDaemon }
    default        { Show-CliHelp }
}
