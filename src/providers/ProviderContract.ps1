# ==============================================================================
# PROVIDER CONTRACT (Phase 15 - for future providers such as Proton Drive)
# ==============================================================================
# The currently working providers (Google Drive, TeraBox) authenticate very
# differently: Google uses an rclone-driven OAuth flow with a loopback
# callback; TeraBox uses the application's own embedded browser login and a
# bridge service. The contract below therefore caps REQUIREMENTS (what every
# provider must be able to do) without forcing mechanisms (how they do it).
#
# A future provider implementation must be reviewed against this contract
# BEFORE it is wired into the UI; Test-ProviderContracts.ps1 fails when a
# wired provider does not satisfy it. No placeholder or fake connector ships
# for providers that do not have a real integration yet.

function Get-CloudProviderContract {
    # Returns the contract as data so help/comments and tests stay in sync.
    # Each member lists the required provider-facing functions plus the value
    # semantics the account UI relies on.
    return [ordered]@{
        # Stable provider id used for account ids (e.g. 'proton_<hex>') and
        # mount worker keys. Always ASCII letters/digits.
        ProviderIdFormat = '^[a-zA-Z][a-zA-Z0-9_]*$'

        # Capability flags MUST be reported by Get-<P>ProviderInfo:
        #   SupportsOAuth        - provider authorizes via OAuth (may use any
        #                          supported helper, e.g. rclone authorize)
        #   SupportsManualSession - provider supports explicit session entry
        #                          (e.g. cookie/value direct)
        #   SupportsQuota        - reliable usage/limit retrieval exists;
        #                          otherwise the UI must show no quota data
        #   SupportsMultipleAccounts - per-account isolation is actually
        #                          supported; if false, connecting a second
        #                          account of this provider must be refused
        #                          with a clear error, never silently merged
        CapabilityKeys = @(
            'SupportsOAuth', 'SupportsManualSession', 'SupportsQuota', 'SupportsMultipleAccounts'
        )

        # Required function surface. Templates below are the documentation
        # view; Test-ProviderContract holds the EXACT per-provider names so a
        # rename cannot silently weaken the contract:
        RequiredFunctionTemplates = @(
            'Get-<P>ProviderInfo',        # -> capability flags (above)
            'Test-<P>BackendSession',     # -> [ordered] session check result:
                                          #    IsValid, State, and when identity
                                          #    matters: IdentityVerified,
                                          #    IdentitySource, IdentityError.
                                          #    MUST NOT fabricate identities for
                                          #    unsaved accounts; fallback-derived
                                          #    identities are NOT verified.
            'Save-<P>Session',            # persists credential material per
                                          #    AccountId using DPAPI-backed
                                          #    PSCredential + strict ACL, never
                                          #    plaintext files
            'Get-<P>Stored(Tokens|Session)', # reads credentials for one AccountId
            'Remove-<P>Session',          # removes ONLY the AccountId-owned
                                          #    credential state; touching other
                                          #    accounts is a contract violation
            'Get-<P>RcloneEnvironment',   # env vars for the mount helper, built
                                          #    for one AccountId (or legacy)
            'Get-<P>FileList'             # basic browsing used by transfer UI
        )

        # Exact required names per wired provider id (checked by
        # Test-ProviderContract). A future provider is added here ONLY with a
        # real implementation - same as the wired-provider summary.
        RequiredNames = [ordered]@{
            gdrive  = @(
                'Get-GoogleDriveProviderInfo',
                'Test-GoogleDriveBackendSession',
                'Save-GoogleDriveTokens',
                'Get-GoogleDriveStoredTokens',
                'Remove-GoogleDriveSession',
                'Get-GoogleDriveRcloneEnvironment',
                'Get-GoogleDriveFileList'
            )
            terabox = @(
                'Get-TeraBoxProviderInfo',
                'Test-TeraBoxBackendSession',
                'Save-TeraBoxSession',
                'Get-TeraBoxStoredSession',
                'Remove-TeraBoxSession',
                'Get-TeraBoxRcloneEnvironment',
                'Get-TeraBoxFileList'
            )
            vps     = @(
                'Get-VpsProviderInfo',
                'Test-VpsBackendSession',
                'Save-VpsSession',
                'Get-VpsStoredSession',
                'Remove-VpsSession',
                'Get-VpsRcloneEnvironment',
                'Get-VpsFileList'
            )
            proton  = @(
                'Get-ProtonDriveProviderInfo',
                'Test-ProtonDriveBackendSession',
                'Save-ProtonDriveSession',
                'Get-ProtonDriveStoredSession',
                'Remove-ProtonDriveSession',
                'Get-ProtonDriveRcloneEnvironment',
                'Get-ProtonDriveFileList'
            )
            mega    = @(
                'Get-MegaProviderInfo',
                'Test-MegaBackendSession',
                'Save-MegaSession',
                'Get-MegaStoredSession',
                'Remove-MegaSession',
                'Get-MegaRcloneEnvironment',
                'Get-MegaFileList'
            )
            s3      = @(
                'Get-S3ProviderInfo',
                'Test-S3BackendSession',
                'Save-S3Session',
                'Get-S3StoredSession',
                'Remove-S3Session',
                'Get-S3RcloneEnvironment',
                'Get-S3FileList'
            )
        }

        # Mount semantics:
        # MountMechanism   = which service performs the filesystem side
        MountMechanism     = 'winfsp-rclone-vfs'   # current shared implementation

        # Identity rules carried over from the Google OAuth fix:
        IdentityRules = @(
            'A session result for an UNSAVED account must never present a',
            'placeholder identity as verified; IdentityVerified must be',
            '$false with a sanitized IdentityError. Duplicate identities must',
            'be handled intentionally (user prompt), never auto-merged.'
        )
    }
}

function Test-ProviderContract {
    # Returns the contract check for ONE provider id ('gdrive' | 'terabox' |
    # future ids). Missing members are reported with the concrete function
    # names expected; the result never mutates anything.
    [CmdletBinding()]
    param([string]$ProviderId)

    $contract = Get-CloudProviderContract
    $missing = [System.Collections.Generic.List[string]]::new()

    if ($ProviderId -eq 'proton') { $word = 'Proton Drive' }
    elseif ($ProviderId -eq 'vps') { $word = 'VPS / Remote Server' }
    elseif ($ProviderId -eq 'mega') { $word = 'MEGA' }
    elseif ($ProviderId -eq 's3') { $word = 'S3 / Metal' }
    elseif ($contract.RequiredNames.Contains($ProviderId)) { $word = $ProviderId }
    else { return [ordered]@{ ProviderId = $ProviderId; Satisfied = $false; Missing = @('Unknown provider id: unsupported ids cannot be wired into the account UI.'); Word = $ProviderId } }

    # A provider not registered with RequiredNames is refused
    # upfront: there is no implementation to wire and no fake connector.
    if (-not $contract.RequiredNames.Contains($ProviderId)) {
        $missing.Add("No required-function registration for '$word' yet; a real implementation must be added to the contract map before wiring.");
    }

    $required = @()
    if ($contract.RequiredNames.Contains($ProviderId)) {
        $required = @($contract.RequiredNames[$ProviderId])
    }

    foreach ($name in $required) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { $missing.Add($name) }
    }

    return [ordered]@{
        ProviderId = $ProviderId
        Word = $word
        Satisfied = ($missing.Count -eq 0)
        Missing = $missing
    }
}

function Get-RegisteredCloudProviders {
    return @('gdrive', 'terabox', 'vps', 'proton', 'mega', 's3')
}

function Get-CloudProviderContractSummary {
    # Registry of wired provider ids (must match known ids above). Future
    # providers join this list ONLY together with a real implementation.
    $summary = @()
    foreach ($providerId in (Get-RegisteredCloudProviders)) {
        $check = Test-ProviderContract -ProviderId $providerId
        $summary += $check
    }
    return $summary
}

# ==============================================================================
# UNIFIED PROVIDER DISPATCHERS & INFRASTRUCTURE
# ==============================================================================

function Get-CloudProviderFieldValue([object]$Object, [string]$Field, [object]$DefaultValue = $null) {
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Field)) { return $DefaultValue }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Field)) {
            $val = $Object[$Field]
            if ($null -ne $val) { return $val }
            return $DefaultValue
        }
        return $DefaultValue
    }

    if ($Object.PSObject -and $Object.PSObject.Properties) {
        $prop = $Object.PSObject.Properties[$Field]
        if ($null -ne $prop -and $null -ne $prop.Value) {
            return $prop.Value
        }
    }

    return $DefaultValue
}

function Set-CloudCredentialAcl([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return }
    try {
        $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
        $isDir = (Test-Path -LiteralPath $Path -PathType Container)
        $acl = if ($isDir) {
            [System.IO.Directory]::GetAccessControl($Path)
        } else {
            [System.IO.File]::GetAccessControl($Path)
        }
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($acl.Access)) {
            [void]$acl.RemoveAccessRuleSpecific($existingRule)
        }
        foreach ($sid in @($userSid, $systemSid)) {
            $rule = if ($isDir) {
                [System.Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
            } else {
                [System.Security.AccessControl.FileSystemAccessRule]::new(
                    $sid,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow
                )
            }
            [void]$acl.SetAccessRule($rule)
        }
        if ($isDir) {
            [System.IO.Directory]::SetAccessControl($Path, $acl)
        } else {
            [System.IO.File]::SetAccessControl($Path, $acl)
        }
    } catch {
        throw "Unable to restrict permissions on credential path '$Path': $($_.Exception.Message)"
    }
}

function Get-CloudProviderInfo([string]$ProviderId) {
    if ([string]::IsNullOrWhiteSpace($ProviderId)) { return $null }
    $func = switch ($ProviderId.ToLowerInvariant()) {
        'gdrive'  { 'Get-GoogleDriveProviderInfo' }
        'terabox' { 'Get-TeraBoxProviderInfo' }
        'vps'     { 'Get-VpsProviderInfo' }
        'proton'  { 'Get-ProtonDriveProviderInfo' }
        'mega'    { 'Get-MegaProviderInfo' }
        's3'      { 'Get-S3ProviderInfo' }
        default   { $null }
    }
    if ($func -and (Get-Command $func -ErrorAction SilentlyContinue)) {
        return (& $func)
    }
    return $null
}

function Test-CloudProviderBackendSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderId,
        [Parameter(Mandatory = $false)]
        [hashtable]$SessionOverride = $null,
        [Parameter(Mandatory = $false)]
        [string]$AccountId = '',
        [Parameter(Mandatory = $false)]
        [switch]$Force = $false
    )

    switch ($ProviderId.ToLowerInvariant()) {
        'gdrive' {
            if ($null -ne $SessionOverride) {
                return (Test-GoogleDriveBackendSession -TokensOverride $SessionOverride -AccountId $AccountId -Force:$Force)
            }
            return (Test-GoogleDriveBackendSession -AccountId $AccountId -Force:$Force)
        }
        'terabox' {
            if ($null -ne $SessionOverride) {
                return (Test-TeraBoxBackendSession -SessionOverride $SessionOverride -AccountId $AccountId -Force:$Force)
            }
            return (Test-TeraBoxBackendSession -AccountId $AccountId -Force:$Force)
        }
        'vps' {
            if ($null -ne $SessionOverride) {
                return (Test-VpsBackendSession -SessionOverride $SessionOverride -AccountId $AccountId -Force:$Force)
            }
            return (Test-VpsBackendSession -AccountId $AccountId -Force:$Force)
        }
        'proton' {
            if ($null -ne $SessionOverride) {
                return (Test-ProtonDriveBackendSession -SessionOverride $SessionOverride -AccountId $AccountId -Force:$Force)
            }
            return (Test-ProtonDriveBackendSession -AccountId $AccountId -Force:$Force)
        }
        'mega' {
            if ($null -ne $SessionOverride) {
                return (Test-MegaBackendSession -SessionOverride $SessionOverride -AccountId $AccountId -Force:$Force)
            }
            return (Test-MegaBackendSession -AccountId $AccountId -Force:$Force)
        }
        's3' {
            if ($null -ne $SessionOverride) {
                return (Test-S3BackendSession -SessionOverride $SessionOverride -AccountId $AccountId -Force:$Force)
            }
            return (Test-S3BackendSession -AccountId $AccountId -Force:$Force)
        }
        default {
            return [ordered]@{
                IsValid = $false
                State = 'Disconnected'
                Error = "Unsupported provider '$ProviderId'"
            }
        }
    }
}

function Get-CloudProviderRcloneEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderId,
        [Parameter(Mandatory = $false)]
        [string]$AccountId = '',
        [Parameter(Mandatory = $true)]
        [string]$RemoteName,
        [Parameter(Mandatory = $false)]
        [string]$RcloneBinary = ''
    )

    switch ($ProviderId.ToLowerInvariant()) {
        'gdrive' {
            return (Get-GoogleDriveRcloneEnvironment -AccountId $AccountId -RemoteName $RemoteName)
        }
        'terabox' {
            if ($null -ne (Get-Command 'Get-TeraBoxRcloneEnvironment' -ErrorAction SilentlyContinue)) {
                return (Get-TeraBoxRcloneEnvironment -AccountId $AccountId -RemoteName $RemoteName)
            }
            return @{}
        }
        'vps' {
            return (Get-VpsRcloneEnvironment -AccountId $AccountId -RemoteName $RemoteName -RcloneBinary $RcloneBinary)
        }
        'proton' {
            return (Get-ProtonDriveRcloneEnvironment -AccountId $AccountId -RemoteName $RemoteName -RcloneBinary $RcloneBinary)
        }
        'mega' {
            return (Get-MegaRcloneEnvironment -AccountId $AccountId -RemoteName $RemoteName -RcloneBinary $RcloneBinary)
        }
        's3' {
            return (Get-S3RcloneEnvironment -AccountId $AccountId -RemoteName $RemoteName -RcloneBinary $RcloneBinary)
        }
        default {
            throw "Unsupported provider for rclone environment: '$ProviderId'"
        }
    }
}

function Remove-CloudProviderSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProviderId,
        [Parameter(Mandatory = $false)]
        [string]$AccountId = ''
    )

    switch ($ProviderId.ToLowerInvariant()) {
        'gdrive'  { Remove-GoogleDriveSession -AccountId $AccountId }
        'terabox' { Remove-TeraBoxSession -AccountId $AccountId }
        'vps'     { Remove-VpsSession -AccountId $AccountId }
        'proton'  { Remove-ProtonDriveSession -AccountId $AccountId }
        'mega'    { Remove-MegaSession -AccountId $AccountId }
        's3'      { Remove-S3Session -AccountId $AccountId }
        default   { }
    }
}
