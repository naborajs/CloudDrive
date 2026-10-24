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
    elseif ($contract.RequiredNames.Contains($ProviderId)) { $word = $ProviderId }
    else { return [ordered]@{ ProviderId = $ProviderId; Satisfied = $false; Missing = @('Unknown provider id: unsupported ids cannot be wired into the account UI.'); Word = $ProviderId } }

    # A provider not registered with RequiredNames (like proton) is refused
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

function Get-CloudProviderContractSummary {
    # Registry of wired provider ids (must match known ids above). Future
    # providers join this list ONLY together with a real implementation.
    $summary = @()
    foreach ($providerId in @('gdrive', 'terabox')) {
        $check = Test-ProviderContract -ProviderId $providerId
        $summary += $check
    }
    return $summary
}
