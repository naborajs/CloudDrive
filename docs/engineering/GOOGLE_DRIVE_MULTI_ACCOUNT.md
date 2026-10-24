# Google Drive Multi-Account Lifecycle and Isolation

This document records the verified design and known failure mechanisms in the
current code. It does not claim that concurrent mounting of multiple real
Google accounts has been accepted on a clean Windows machine.

## Identity model

Every newly created Google record receives an app-generated ID with the
`gdrive_` prefix and a GUID. `AccountId` is the stable application key. The
Google-returned email is stored in the record's `AccountEmail` field, while
`DisplayName` is a separate editable label. Never derive an account ID from a
display name, combine multiple results into one label, or infer a verified
identity from an OAuth success page.

The core record is normalized and persisted by
[`SettingsManager.ps1`](../../src/services/SettingsManager.ps1):

```text
Id, ProviderId, DisplayName, AccountEmail, DriveLetter, AutoMount,
OpenExplorerOnMount, ReadOnly, CacheDirectory, CacheMaxGigabytes,
CustomIcon, Created
```

`AccountEmail` records the provider identity captured during creation. A
future provider response still needs to be checked against the saved email.
`Test-GoogleDriveBackendSession -AccountId` performs this comparison and
returns `AuthRequired` on mismatch rather than allowing another identity to
appear under this account's drive.

## OAuth and identity verification

`Invoke-GoogleDriveAuthorization` selects the configured loopback OAuth/PKCE
path or the rclone authorization helper. In the native flow:

1. `Start-GoogleOAuthFlow` creates a cryptographically random OAuth state and
   PKCE verifier/challenge.
2. `Start-OAuthLoopbackListener` receives the callback on loopback and
   `Wait-OAuthLoopbackResponse` compares callback state with expected state.
   Do not weaken or bypass this check to address a missing-property error.
3. The native loopback handler renders an NS Cloud Drive-branded page after
   processing the callback. The rclone helper may show rclone's generic
   success page. Neither page alone means the app verified identity, saved an
   account, or mounted a drive.
4. The authorization code is exchanged for tokens. Browser callback success
   means code exchange/authorization succeeded; it does not mean that the
   app verified identity, saved an account, or mounted a drive.
5. `New-CloudAccountRecord` checks the returned token set through
   `Test-GoogleDriveBackendSession -TokensOverride ... -AccountId ...`.
   The provider attempts Google Drive API identity lookups, including
   `/files/root` owner metadata and `/about` user data. Google API quota/identity
   failure can therefore occur after browser authorization.
6. For a new account, a valid provider-returned email and
   `IdentityVerified = $true` are required. The generic `Google Drive User`
   rclone fallback name is not an authenticated email.
7. The user may retry the identity check without authorizing again. If identity
   remains unverified or the user cancels setup, the new staged account token
   session is removed and no account is added. Existing account records are
   not modified.
8. A duplicate verified Google email is rejected. Otherwise the account
   settings dialog calls `Add-CloudAccount`; it does not save the account when
   its identity check has failed.

Relevant implementation:

- [`GoogleDriveProvider.ps1`](../../src/providers/GoogleDriveProvider.ps1):
  `New-OAuthState`, `Build-GoogleAuthorizationUrl`,
  `Start-OAuthLoopbackListener`, `Wait-OAuthLoopbackResponse`,
  `Start-GoogleOAuthFlow`, `Exchange-GoogleAuthCode`,
  `Invoke-GoogleDriveAuthorization`, `Save-GoogleDriveTokens`,
  `Test-GoogleDriveBackendSession`, and
  `Get-GoogleDriveRcloneEnvironment`.
- [`ProviderConnectionWindow.ps1`](../../src/ui/ProviderConnectionWindow.ps1):
  `Connect-NewCloudAccount` and `New-CloudAccountRecord`.

The error path intentionally distinguishes successful authorization with
failed identity lookup from successful account creation. API permissions,
quota limits, custom OAuth configuration, network reachability, and identity
response shape can affect verification. A real-world root cause must be
captured from a sanitized error before assigning one of these as the cause.

## Credential and mount isolation

For non-empty account IDs, Google credentials are stored in a filename scoped
to that ID under `%LOCALAPPDATA%\NSCloudDrive\credentials`. `Get-GoogleDriveStoredTokens`
and `Save-GoogleDriveTokens` receive `AccountId`; account-scoped lookups must
not fall back to a legacy shared token file. Credential files use
DPAPI-backed `PSCredential` serialization and strict ACL handling.

`Get-GoogleDriveRcloneEnvironment` reads the scoped token and builds a remote
alias/environment for the account. The mount path in
[`VirtualDriveManager.ps1`](../../src/services/VirtualDriveManager.ps1):

- uses the account ID as `mountKey`;
- selects the saved account's drive letter and per-account mount settings;
- uses an application-owned empty `account-mount-isolated.conf` for account
  mounts so a user's global `rclone.conf` cannot contribute a same-named
  remote;
- places mount cache and log data under the mount-key namespace;
- checks drive-letter availability and process ownership;
- waits for Windows to expose the drive, then runs a filesystem-root
  verification before reporting success.

The mount process or the drive letter alone is not enough to establish which
Google identity it serves. Status refresh builds an `AccountStatuses` map keyed
by account ID. `Get-CachedUiDriveStatus` requires account-specific evidence and
guards against a reported account ID or drive letter that does not match the
requested account. The provider-wide `GoogleStatus` remains a separate
legacy/recovery observation.

`Start-ScopedDriveDisconnect` and `Stop-VirtualDriveMount` are scoped by
account ID and/or target letter. `Remove-CloudAccount` updates only the saved
registry entry; app-side disconnect cleanup is performed through the scoped
worker. No removal should delete remote files.

## The reproduced merged-card bug

The screenshot-like merged card was traced to a concrete PowerShell output
shape, not to merged persisted credentials:

- Before the fix, `Get-CloudAccounts` returned `,$list`, deliberately
  preventing the PowerShell pipeline from enumerating the list.
- Callers such as `$allAccounts = @(Get-CloudAccounts)` then wrapped that
  single array object in a new outer array.
- The UI iterated one outer item. PowerShell member enumeration over that
  inner array exposed multiple account names/emails as combined property
  values. The provider ID similarly became a combined string.
- The card's provider label and icon used different fallback behavior. A
  combined provider value failed the exact Google icon branch and the old
  icon helper's `else` selected the TeraBox asset, while the provider label
  still appeared Google-like. This produced the observed incorrect icon.
- A read-only settings inspection during investigation showed distinct
  persisted account records; the reproduced collection shape explains why
  the UI looked merged without evidence that those JSON records had merged.

Fixes:

1. [`Get-CloudAccounts`](../../src/services/SettingsManager.ps1) now emits
   records individually (`return $list`). Consumers that require a stable
   array use `@(Get-CloudAccounts)`.
2. Provider icon selection is an explicit switch. Unknown provider IDs map to
   no provider logo, and card labels use `Unknown provider` instead of
   defaulting to TeraBox.
3. The WPF regression renders two synthetic Google records and one synthetic
   TeraBox record and checks card count, exact names/emails/provider labels,
   and icon filenames.

Relevant commits:

- `4ba35515938ba25c3278688130a02ac961b49335` — account enumeration output
  contract and affected SettingsManager callers.
- `5aeec7bffa4fb972216931cc209b9917668c7e0b` — virtual-drive consumer array
  handling.
- `66a080b5016e803111539c43242c55da56d04c7e` — provider-dialog consumer
  array handling.
- `ee4f36862a8fc9eac740734d33b580f5d3cc5176` — UI account list/icon and
  account-vs-provider status corrections.
- `2c6a7791e3893c812f54026e8ca2ef2383d6a43a` — WPF account-card and status
  isolation regression.

Tests to run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AccountCreationSaveFlow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartupAutoMountTimer.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountIsolation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountLifecycle.ps1
```

The card-rendering regression uses synthetic account fixtures in an isolated
WPF process. It does not connect to Google, mount drives, or prove simultaneous
real-account isolation. See [Incidents and fixes](INCIDENTS_AND_FIXES.md) and
[Testing and validation](TESTING_AND_VALIDATION.md).

## Safe investigation checklist

1. Check `git status` and read the last commits before changing files.
2. Inspect account records without printing credential files or private
   account values. Compare counts, unique IDs, provider IDs, letters, and
   whether each identity field is scalar.
3. Trace `Get-CloudAccounts` through every caller. Test the raw function,
   assignment with `@(…)`, and the actual UI card rendering separately.
4. Inspect provider icon selection and provider labels independently.
5. Compare `AccountStatuses[$id]`, expected `DriveLetter`, process ownership,
   Windows drive visibility, and filesystem verification. Do not substitute
   provider-wide status for account ownership.
6. Use mocked identity results for reproducible tests; only perform live
   provider checks with explicit user permission and a disposable/isolated
   environment.
7. Preserve mounts and credentials. Do not “fix” the dashboard by deleting
   saved accounts, revoking tokens, or stopping an unowned process.
