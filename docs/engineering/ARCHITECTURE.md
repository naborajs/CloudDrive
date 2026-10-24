# NS Cloud Drive Architecture

This guide describes the repository at the implementation snapshot ending in
`2c6a7791e3893c812f54026e8ca2ef2383d6a43a`. Documentation commits may follow
that snapshot; consult the current source when behavior changes. This is an
experimental Windows application, not a production-readiness claim.

## Project map

| Area | Responsibility |
| --- | --- |
| [`src/NSCloudDrive.ps1`](../../src/NSCloudDrive.ps1) | WPF application entry point, startup/restore orchestration, timers, provider status snapshots, disk/account cards, Analytics and Logs views, user actions, and UI-side recovery state. |
| [`src/models/ConnectionState.ps1`](../../src/models/ConnectionState.ps1) | Connection-state helpers and `New-MountOperationState`, the synchronized progress record shared with mount workers. |
| [`src/services/SettingsManager.ps1`](../../src/services/SettingsManager.ps1) | Settings normalization and atomic JSON persistence; account list CRUD, drive-letter allocation, and settings migration defaults. |
| [`src/providers/GoogleDriveProvider.ps1`](../../src/providers/GoogleDriveProvider.ps1) | Google OAuth, loopback callback/state validation, PKCE, account-scoped token storage, Google API identity/quota checks, and per-account rclone environment variables. |
| [`src/providers/TeraBoxProvider.ps1`](../../src/providers/TeraBoxProvider.ps1) | TeraBox session persistence, backend validation, account-scoped session use, and rclone environment configuration. Web-session mode uses an unofficial community backend. |
| [`src/services/VirtualDriveManager.ps1`](../../src/services/VirtualDriveManager.ps1) | rclone mount arguments/processes, process ownership, account-to-letter mapping, filesystem-root verification, disconnect, and mount status. |
| [`src/services/TeraBoxBridgeManager.ps1`](../../src/services/TeraBoxBridgeManager.ps1) | Local CPX WebDAV bridge, per-account bridge home/port/password, health checks, and lifecycle. |
| [`src/services/BackgroundOperationManager.ps1`](../../src/services/BackgroundOperationManager.ps1) | Bounded background operations used to keep provider checks, mounting, logs, and storage checks off the WPF dispatcher. |
| [`src/services/CacheManager.ps1`](../../src/services/CacheManager.ps1) | Cache namespace validation, in-use checks, and conservative startup recovery. |
| [`src/services/ExplorerIntegration.ps1`](../../src/services/ExplorerIntegration.ps1) | Per-user Explorer drive icon registration/removal with ownership checks. |
| [`src/services/CloudTransferManager.ps1`](../../src/services/CloudTransferManager.ps1) | Provider-to-provider transfer orchestration. Live transfer recovery and data-integrity guarantees are not established by unit tests. |
| [`src/ui/ProviderConnectionWindow.ps1`](../../src/ui/ProviderConnectionWindow.ps1) | Account settings dialogs and `Connect-NewCloudAccount` / `New-CloudAccountRecord` workflows. |
| [`src/ui/EmbeddedBrowserWindow.ps1`](../../src/ui/EmbeddedBrowserWindow.ps1) | Embedded browser support used by the TeraBox sign-in experience. |
| [`tests/`](../../tests) | PowerShell tests. Read each test to distinguish isolated mocks, source/structure assertions, sandboxed Windows tests, and tests that contact configured providers. |

The application is Windows-only PowerShell/WPF and must be launched in STA.
`NSCloudDrive.ps1` dot-sources the model, providers, services, and UI modules
before loading settings and constructing the main window. Its startup logic
uses a dispatcher timer to schedule restore work rather than performing
mounts on the UI thread. A separate mutex guards standalone launches; dot
sourcing in tests avoids normal standalone startup behavior.

## Runtime layers and state

There is no single Windows API registry that proves every aspect of an
account's connection. The application deals with several separate facts:

1. **Saved account:** a JSON `Accounts` record loaded by `Get-CloudAccounts`.
   It contains an app-generated `Id`, `ProviderId`, editable `DisplayName`,
   `AccountEmail`, `DriveLetter`, mount options, cache options, icon override,
   and creation timestamp. The email field is persisted as account metadata;
   identity is checked against the provider when validating a Google session.
2. **Authenticated provider identity:** a provider response for the tokens or
   session belonging to an account ID. For Google, `Test-GoogleDriveBackendSession`
   marks identity verified only after it has retrieved an actual provider
   identity. A successful browser callback alone does not prove this step.
3. **Mount process:** a running `rclone` process whose command line, account
   key, log namespace, and target letter are checked by the virtual-drive
   manager. A process can exist even when Windows has not exposed a usable
   drive.
4. **Verified filesystem:** a drive root detected by Windows and probed by
   `Test-VirtualDriveFilesystem`. A timeout or failure is not equivalent to a
   successful mount.
5. **Windows/Explorer drive:** a drive visible to Windows. Visibility and
   successful browsing are valuable evidence, but do not, by themselves, prove
   which saved account owns it.
6. **UI status:** account-scoped and legacy/provider-scoped results are kept
   separately in status snapshots and operation-state dictionaries. The
   account card must not infer ownership from a provider-wide result.

The distinction is important for recovery: an active but unidentified mount
may be shown as recovery-needed. It must not borrow another Google account's
email, display name, quota, configuration, or icon.

## Google account lifecycle

The current account creation path is:

1. `Connect-NewCloudAccount` in `ProviderConnectionWindow.ps1` prevents a
   nested creation flow and invokes `New-CloudAccountRecord`.
2. `New-CloudAccountRecord` creates a new `gdrive_<GUID>` ID and calls
   `Invoke-GoogleDriveAuthorization -AccountId $accId`.
3. `Invoke-GoogleDriveAuthorization` uses the configured native OAuth flow
   when a client ID is available, otherwise it may use the rclone authorization
   helper. The native flow creates PKCE material and a random OAuth `state`.
   The loopback listener checks the callback state before accepting the code.
4. Returned tokens are checked through `Test-GoogleDriveBackendSession` using
   that account ID. Google Drive API identity endpoints are tried; an rclone
   fallback may validate the session/quota, but a generic fallback name is not
   accepted as a verified email identity for a new account.
5. The UI rejects an unverified/missing email and duplicate verified Google
   email, and it does not persist an account on identity failure. A verified
   identity is passed to `Show-CloudAccountSetupModal`, where `Add-CloudAccount`
   persists exactly one record. A failed save removes the newly staged
   account-scoped session; it does not overwrite another saved record.
6. A successful save queues an account-specific mount request. The UI
   watchdog and `Start-VirtualDriveMount` use that ID, provider, saved drive
   letter, options, and cache settings.
7. The mount manager creates a scoped rclone environment, launches rclone,
   waits for the drive to appear, then verifies the filesystem root. Only the
   verified result is reported as a successful mount.
8. Background status refresh stores a provider snapshot plus an
   `AccountStatuses` map. `Update-AllUIState` renders cards from saved records
   and checks status by account ID and expected letter.
9. Startup restoration reloads saved accounts and attempts their account-scoped
   lifecycle. A provider-only mount that cannot be tied to a saved ID remains
   an unidentified legacy/recovery state.

Relevant entry points include `Start-GoogleOAuthFlow`,
`Start-OAuthLoopbackListener`, `Wait-OAuthLoopbackResponse`,
`Invoke-GoogleDriveAuthorization`,
`Test-GoogleDriveBackendSession`, `Get-GoogleDriveRcloneEnvironment`,
`New-CloudAccountRecord`, `Add-CloudAccount`, `Start-VirtualDriveMount`,
`Get-VirtualDriveStatus`, `Start-ProviderStatusRefreshWorker`,
`Update-AllUIState`, and `Invoke-StartupAutoMount`.

The native loopback flow renders an NS Cloud Drive-branded local page after
evaluating the callback response. The alternate rclone authorization helper
may display rclone's generic success page. Neither page proves identity
verification, account persistence, or successful mounting.

## Account isolation boundaries

For account-scoped Google operations, `AccountId` is the key carried from
OAuth through storage, mount, status, and removal:

- Google credentials are stored at
  `%LOCALAPPDATA%\NSCloudDrive\credentials\google-tokens-<safeAccountId>.xml`.
  The token file is DPAPI-backed and protected with a restrictive Windows ACL.
  Empty/legacy account IDs use the legacy shared token file; account code must
  pass the ID explicitly and must not silently fall back to it.
- `Get-GoogleDriveRcloneEnvironment` reads tokens for that ID and constructs
  a distinct remote alias and environment variables. Account mount processes
  use the application-owned empty `account-mount-isolated.conf` rather than
  merging a user's global rclone configuration.
- The mount key is the account ID. It namespaces rclone log names and cache
  directories (under the configured cache root), and is used for process
  ownership and status lookup.
- Each saved record has its own drive letter. `Test-CloudAccountDriveLetterAvailable`
  prevents collisions in the account registry; the mount manager separately
  checks Windows letter availability.
- `AccountMountStates` is keyed by account ID. Mount operations carry
  `AccountId` and `DriveLetter`; `New-MountOperationState` also guarantees a
  `State` field for UI consumers.
- Display names are labels only. They are editable and not used as identity
  keys. Two accounts with the same label remain distinct by ID and verified
  identity.
- Provider icons and labels are selected from each record's `ProviderId`.
  Unknown values should remain unknown rather than falling through to a
  different provider's icon.

Synthetic account-isolation tests exercise separate IDs, token/config
namespaces, status ownership, and cleanup scope. They are not proof that two
real Google identities can be mounted concurrently on a user's Windows
machine.

## Persistence, caches, and external processes

- Settings: `%LOCALAPPDATA%\NSCloudDrive\config\settings.json`.
  `Get-NSCloudDriveSettings` normalizes optional/legacy fields. Writes go to a
  temporary file and replace the prior file; malformed input is surfaced and
  preserved rather than silently overwritten.
- OAuth client configuration can come from environment variables or supported
  config paths described by `Get-GoogleOAuthConfig`. Never place private
  OAuth credentials in documentation or commits.
- Account credentials: `%LOCALAPPDATA%\NSCloudDrive\credentials\`. Google and
  TeraBox use provider-specific, account-specific filenames for scoped flows.
- Logs: `%LOCALAPPDATA%\NSCloudDrive\logs\`. `application.jsonl` is the bounded
  structured application log; rclone uses a per-mount log path. Logs are not
  a substitute for a live process/filesystem check.
- Cache: configured in settings/account options; mount code adds a mount-key
  namespace. Startup cache recovery is restricted to recognized account or
  provider namespaces. Pending-write and eviction safety still need isolated
  real-mount testing.
- rclone and CPX are child processes. Mount and disconnect logic attempts to
  establish ownership from account key, drive letter, process metadata, and
  log/config markers before acting. Do not manually kill processes or delete
  caches as a debugging shortcut.
- TeraBox adds a CPX WebDAV bridge. Its credentials, bridge home, port, and
  mount are intended to be scoped by account ID. The TeraBox web-session
  backend remains unofficial; independent concurrent TeraBox operation has
  not been demonstrated.

## UI, resource views, and diagnostics

`NSCloudDrive.ps1` owns the main WPF window and navigation. Provider checks,
mount work, storage quota checks, and log reading use background operations
where implemented. The Analytics page starts resource sampling when entered
and stops it on navigation away. Storage values are shown only when the
provider returns verified quota data; unknown values are unavailable rather
than fabricated. The Logs page reads bounded pages asynchronously, provides
filters/search, and applies a timeout.

`Start-ExplorerWindow` opens Explorer only for an explicit call path or a
setting/user action. Recovery/startup code should not open Explorer merely
because a mount was restored. Explorer icon registration is a separate,
ownership-tracked feature in `ExplorerIntegration.ps1`.

## Validation commands

Run from the repository root in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AccountCreationSaveFlow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GoogleAccountCreationRecovery.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountLifecycle.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountIsolation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartupAutoMountTimer.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SettingsManager.ps1
```

See [Testing and validation](TESTING_AND_VALIDATION.md) before running
provider or mount-oriented tests. `Run-AllTests.ps1` includes tests with
different safety profiles and should not be run blindly while user mounts or
provider sessions are active.
