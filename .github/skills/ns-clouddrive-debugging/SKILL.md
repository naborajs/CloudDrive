---
name: ns-clouddrive-debugging
description: 'Use when investigating NS Cloud Drive PowerShell/WPF issues involving Google Drive or TeraBox authentication, account identity, persistence, mounts, drive status, Explorer, Logs, Analytics, or multi-account isolation.'
---

# NS Cloud Drive Debugging

Use this workflow for bug fixes and investigations in the NS Cloud Drive
repository. It is designed for a new coding agent without prior chat context.
Preserve existing credentials, account records, active mounts, cache data, and
remote files.

## Required first reads

**Read the relevant engineering documentation and regression tests before debugging an issue that has already been encountered. Never repeat a known failed approach without explaining why it is now justified.**

Start with:

1. [`ARCHITECTURE.md`](../../../docs/engineering/ARCHITECTURE.md) for the
   source map and state boundaries.
2. [`GOOGLE_DRIVE_MULTI_ACCOUNT.md`](../../../docs/engineering/GOOGLE_DRIVE_MULTI_ACCOUNT.md)
   for account identity and Google OAuth/mount isolation.
3. [`INCIDENTS_AND_FIXES.md`](../../../docs/engineering/INCIDENTS_AND_FIXES.md)
   for verified root causes, limits, and known regressions.
4. [`TERABOX_TROUBLESHOOTING.md`](../../../docs/engineering/TERABOX_TROUBLESHOOTING.md)
   for TeraBox-specific runspace, bridge, and concurrency limits.
5. [`TESTING_AND_VALIDATION.md`](../../../docs/engineering/TESTING_AND_VALIDATION.md)
   for safe test selection and evidence categories.
6. The narrowest relevant test file under `tests/`.

Then inspect `git status --short --branch`, recent commits, and the exact
current source. Do not assume the implementation still matches an old report.

## Repository lifecycle map

- App startup and WPF/UI state: `src/NSCloudDrive.ps1`
- Account settings/persistence: `src/services/SettingsManager.ps1`
- Google OAuth, identity, tokens, API and rclone environment:
  `src/providers/GoogleDriveProvider.ps1`
- TeraBox sessions and provider calls: `src/providers/TeraBoxProvider.ps1`
- rclone process, drive mapping, filesystem verification and disconnect:
  `src/services/VirtualDriveManager.ps1`
- TeraBox CPX bridge: `src/services/TeraBoxBridgeManager.ps1`
- Background operations: `src/services/BackgroundOperationManager.ps1`
- Account UI/create flow: `src/ui/ProviderConnectionWindow.ps1`
- TeraBox embedded browser sign-in: `src/ui/EmbeddedBrowserWindow.ps1`
- Cache safety, cleanup, startup recovery: `src/services/CacheManager.ps1`
- Synthetic/WPF regressions: `tests/`

The expected account trace is:

```text
provider callback/auth
  -> token/session for AccountId
  -> provider identity verification
  -> saved account record
  -> account-specific config/environment and cache namespace
  -> mount process owned by AccountId and drive letter
  -> Windows drive detection and filesystem-root verification
  -> AccountStatuses snapshot
  -> UI card derived from that saved record and account-specific status
```

Trace every arrow. Authorization success, saved-account presence, a running
process, a Windows drive, a verified filesystem, and a UI "Mounted" label are
different facts.

## Investigation procedure

### 1. Establish a safe baseline

- Read the worktree status before editing. Preserve unrelated and user-owned
  changes; never reset or clean the repository.
- Read recent commits and targeted `git log -- <file>` history. Search tests
  and incident documentation before proposing a fix.
- Do not print settings contents, credential files, tokens, cookies, callback
  URLs, private emails, or secret environment variables.
- Do not disconnect drives, terminate processes, delete caches, revoke
  sessions, or touch remote files unless the user explicitly authorizes a
  safe, scoped integration test.

### 2. Trace identity and persistence

- Follow the provider's AccountId from OAuth/login through provider
  verification, persistence, mount, status refresh, disconnect, and restart.
- Verify Google identity from provider-returned data. A browser success page or
  generic display name is not identity proof.
- Treat `DisplayName` as an editable label, not an identity key.
- Compare scalar fields and record counts without revealing their values:
  unique IDs, provider IDs, drive letters, and whether emails remain attached
  to their original record.
- Review all `Get-CloudAccounts` callers for PowerShell array enumeration and
  double wrapping. In this repository, collection-shape changes need tests
  for the raw function, wrapped consumer, and actual WPF card renderer.
- Verify token/session paths, rclone environment/config isolation, cache path,
  mount key, process ownership, and drive letter are scoped to the same ID.

### 3. Trace status and object shapes

- Inspect exact object type and available property names before attributing a
  `.State`, `.ReadOnly`, `.Success`, or similar property exception.
- Use safe property access only where the property is optional; do not use it
  to hide an invalid result or skip required validation.
- PowerShell functions emit all uncaptured pipeline output. Check for helper
  return values leaking beside a status object; callers may receive an
  `Object[]` rather than a dictionary.
- **A background runspace does not automatically inherit UI-local functions.**
  Dot-source required modules or define worker-local helpers explicitly.
  See Historical Bug H below.
- Never associate provider-wide/legacy mount status with a saved account
  unless account ID, target drive letter, process ownership, and relevant
  filesystem evidence support that mapping.
- Distinguish process alive, Windows drive visible, filesystem root accessible,
  provider authenticated, and UI snapshot current.

### 4. Reproduce before implementation

- Write a minimal isolated regression for the observed object/identity/status
  shape before changing production code.
- Prefer synthetic accounts and mocked HTTP/provider responses; use a
  temporary settings/config root and isolated WPF harness as existing tests
  do.
- For a UI merge/icon bug, assert distinct rendered cards, exact synthetic
  identities, provider labels, and provider icon assets.
- For a status bug, assert that missing or mismatched account evidence does
  not report that account as mounted.
- Keep real-provider, Windows integration, and mock results separate in the
  report. Read the test body before running anything that might use live
  configuration or active mounts.

### 5. Implement the smallest complete fix

- Preserve working Google Drive behavior while changing TeraBox or shared
  services; compare provider-specific call sites and test both providers.
- Keep per-account identity, session, config, cache, process, drive letter,
  progress state, and status independent.
- Do not fabricate identity, force a status to healthy, merge provider
  results, or suppress errors with broad catches.
- Keep blocking provider/mount/log/quota work off the WPF dispatcher. Use
  bounded waits, explicit failures, and existing background-operation
  patterns.
- Preserve unknown legacy mounts as recovery-needed until ownership is
  established. Do not silently attach them to the first saved account.

### 6. Verify and report

- Run the focused regression, then the narrow safe related suite from
  [`TESTING_AND_VALIDATION.md`](../../../docs/engineering/TESTING_AND_VALIDATION.md).
- Check `git diff --check`, inspect the final diff, and verify each referenced
  test actually ran successfully.
- Describe test evidence accurately: unit/mocked, structural, isolated WPF,
  live provider, or Windows mount integration.
- State unresolved root causes, unverified concurrent-account behavior, and
  exact real-world limitations. Passing tests do not establish production
  readiness.
- Follow the repository's one-changed-file-per-commit rule when committing.
  Never rewrite published history or force-push.

## TeraBox connection sequence (verified against current source)

Every step below maps to functions in `src/providers/TeraBoxProvider.ps1`,
`src/services/TeraBoxBridgeManager.ps1`, `src/services/VirtualDriveManager.ps1`,
and `src/ui/EmbeddedBrowserWindow.ps1`.

### Sign-in to session persistence

1. `Show-TeraBoxEmbeddedLoginWindow` (EmbeddedBrowserWindow.ps1:166) opens a
   WebView2 browser with an isolated user-data profile at
   `%LOCALAPPDATA%\NSCloudDrive\webview2-profile\<AccountId>` and navigates to
   `https://www.terabox.com/main`.
2. The embedded browser polls cookies via
   `CoreWebView2.CookieManager.GetCookiesAsync`. When an `ndus` cookie is
   detected, it builds a cookie header and validates it against
   `Test-TeraBoxBackendSession` (TeraBoxProvider.ps1:397), which calls
   `https://<base>/api/check/login?app_id=250528&channel=dubox&clienttype=0`.
3. On `errno == 0`, `Save-TeraBoxSession` (TeraBoxProvider.ps1:167) stores the
   cookie under `%LOCALAPPDATA%\NSCloudDrive\credentials\terabox-session-<safeAccountId>.xml`
   as a DPAPI-protected `PSCredential`, with restrictive ACLs (current user +
   SYSTEM only). Bridge credentials (`terabox.bridge.key`,
   `terabox.websession.key`) are also DPAPI-protected per account home at
   `%LOCALAPPDATA%\NSCloudDrive\terabox-bridge\<safeAccountId>`.
4. `Show-TeraBoxEmbeddedLoginWindow` returns a `SessionResult` containing
   `Success`, `AccountId`, `UserName`, `ItemCount`, `Cookie`, `JsToken`,
   `BaseUrl`, `UserAgent`.

### Session validation (mount / status / analytics)

5. `Test-TeraBoxBackendSession -AccountId <id>` reads only the account-scoped
   session file (**never** the legacy shared `terabox-session.xml`), validates
   against the backend, caches the result for 120 seconds in
   `$script:TeraBoxSessionCache`, and returns `{ IsValid, State, Error, UserInfo }`.
   `UserInfo` contains `UserName`, `Uk`, `BaseUrl`, `UserAgent`, quota totals.
   A missing account-specific file returns `State = 'Disconnected'` — never
   silently fall back to the legacy shared session.

### Bridge startup (per account)

6. `Start-TeraBoxBridge -AccountId <id>` (TeraBoxBridgeManager.ps1:203):
   - Resolves port via `Get-TeraBoxBridgePort` (SHA256 of AccountId mod 10000 +
     30000, in range 30000-39999).
   - Locates `cpx.exe` via `Find-CpxBinary` (checks `%LOCALAPPDATA%`
     `NSCloudDrive\tools\cpx\cpx.exe`, a downloads path, a reference project
     path, then PATH).
   - Loads or creates per-account bridge home at
     `%LOCALAPPDATA%\NSCloudDrive\terabox-bridge\<safeAccountId>` via
     `Initialize-TeraBoxBridgeHome` (writes `settings.json`, `cache/`, `logs/`).
   - If an existing bridge is healthy on that port (authenticated health check
     at `http://127.0.0.1:<port>/.cloudplayx/health`), returns its status
     without starting a new process.
   - Otherwise terminates any unhealthy bridge on that port
     (`[void](Stop-TeraBoxBridge ...)` — output discarded, see Bug I below),
     writes bridge secrets via `Set-TeraBoxBridgeSecrets` (DPAPI key +
     web-session payload), starts `cpx.exe terabox-bridge --port <n> --home
     "<homeDir>"`, polls health for up to `WaitTimeoutSec` (default 10s), and
     returns `{ Success, Port, Url, User, Password, ProcessId }`.
   - **Never** terminates a bridge belonging to a different account; matching
     uses exact `--home` argument resolution, not substring prefix.

### rclone mount via bridge

7. `Start-VirtualDriveMount` (VirtualDriveManager.ps1:406) with `RemoteName =
   'terabox'`:
   - Calls `Start-TeraBoxBridge -AccountId $AccountId`.
   - Calls `Get-TeraBoxBridgeRcloneEnvironment -BridgePassword <pw> -Port <p>`
     to build `RCLONE_CONFIG_TERABOX_TYPE=webdav`,
     `RCLONE_CONFIG_TERABOX_URL=http://127.0.0.1:<port>/`,
     `RCLONE_CONFIG_TERABOX_USER=cpx`, `RCLONE_CONFIG_TERABOX_PASS=<obscured>`.
   - Removes any `RCLONE_CONFIG_TERABOX_COOKIE` from env (bridge uses user/pass,
     not cookie).
   - Validates WinFsp is installed, rclone binary exists, and drive letter is
     available (`Test-DriveLetterAvailable`; `Get-NextAvailableDriveLetter`
     fallback on conflict).
   - Launches `rclone.exe mount terabox: <letter>:` with per-account cache
     namespace under `<CacheDirectory>\<mountKey>` and an empty
     `account-mount-isolated.conf` (so user's global `rclone.conf` cannot
     bleed same-named remotes into per-account mounts).
   - Polls `DriveInfo.GetDrives()` for the letter, then runs
     `Test-VirtualDriveFilesystem` (cmd `dir /b` with bounded timeout) before
     reporting `FilesystemVerified = $true`.
   - Records process ownership in `$script:ActiveMountProcesses[$mountKey]`
     and `$script:ProviderDriveMapping[$mountKey]` keyed by AccountId.

### Disconnect / removal

8. `Start-ScopedDriveDisconnect` (NSCloudDrive.ps1:2988) runs
   `Stop-VirtualDriveMount -AccountId <id>` in a background worker, then
   `Stop-TeraBoxBridge -AccountId <id>` (which terminates only cpx processes
   whose `--home` matches this account's isolated home). On successful verified
   disconnect, `Remove-CloudAccount` deletes the settings record, session file,
   cache directory, bridge home, WebView2 profile, and per-account rclone logs.
   **Never deletes remote cloud files.**

## Provider-specific function scope requirements (background runspaces)

Background runspaces (`Start-NSBackgroundOperation`) dot-source only
`models\ConnectionState.ps1`, providers, and `services\VirtualDriveManager.ps1`.
**Functions defined only in `NSCloudDrive.ps1` are NOT available in the
worker runspace.** Any helper called inside a worker script block must be
either:

- dot-sourced inside the worker (e.g. `VirtualDriveManager.ps1` is dot-sourced,
  so `Find-RcloneBinary`, `Get-VirtualDriveStatus`, `Test-VirtualDriveFilesystem`
  are available), or
- defined worker-locally inside the script block.

Functions that require worker-local definitions:
- `Get-VerifiedRclonePath` (defined in `NSCloudDrive.ps1:130` at UI scope — must
  be redefined inside each worker that needs it).
- `Get-CachedUiDriveStatus` / `Update-AllUIState` (UI-only, never call from a
  worker).

## Historical bugs (verified against current source)

### Bug H — `Get-VerifiedRclonePath` runspace-scope (TeraBox startup/restore)

**Symptom:** `The term 'Get-VerifiedRclonePath' is not recognized as the name
of a cmdlet...` during TeraBox mount startup or reconnect.

**Root cause:** `Invoke-StartupAutoMount` (NSCloudDrive.ps1:~4852) dot-sources
providers/services but does not define `Get-VerifiedRclonePath` inside its
worker script block. The UI-script helper at line 130 is not visible in the
worker runspace.

**Fix:** Worker-local `Get-VerifiedRclonePath` defined inside
`Invoke-StartupAutoMount` (~line 4883) and `Invoke-AutoReconnectWatchdog`
(~line 4711), each calling `Find-RcloneBinary` + `Test-Path -Leaf`.

### Bug I — Disconnect error-shape (`ErrorRecord` vs raw `Exception`)

**Symptom:** `The property 'Exception' cannot be found on this object.` during
account disconnect.

**Root cause:** `Complete-NSBackgroundOperation`
(BackgroundOperationManager.ps1:41) stores both `ErrorRecord` objects (from the
PowerShell error stream, which have `.Exception`) **and** raw `Exception`
objects (thrown inside the worker, which do **not** have `.Exception`).
`Complete-AvailableDriveDisconnectWorkers`
(NSCloudDrive.ps1:~3089) accessed `$completed.Errors[0].Exception.Message`
directly.

**Fix:** Safe extraction at NSCloudDrive.ps1:~3089–3092: check
`-is [System.Management.Automation.ErrorRecord]`, then `.Exception.Message`;
otherwise fall back to `.Message`.

### Bug J — `$closeTimer` dispatcher closure (TeraBox embedded sign-in)

**Symptom:** `The variable '$closeTimer' cannot be retrieved because it has
not been set.` in the WPF dispatcher during TeraBox sign-in success.

**Root cause:** `$closeTimer` was defined inside the `if ($testCheck.IsValid)`
branch inside `$TryConnect` (EmbeddedBrowserWindow.ps1), but the
`DispatcherTimer.Add_Tick` nested closure could not reliably capture a variable
defined inside a conditional branch.

**Fix:** Declare `$closeTimer = $null` at `$TryConnect` scriptblock scope
(EmbeddedBrowserWindow.ps1:294) before the conditional.

## Known limitations (documented, not fixable in this task)

- **Concurrent real TeraBox mounts:** Not verified against two live TeraBox
  accounts. The architecture supports per-account sessions, bridge homes, ports,
  and caches, but concurrent operation has not been demonstrated. Do not claim
  support.
- **TeraBox backend is unofficial/community:** No documented refresh contract;
  TeraBox terms restrict non-public interfaces. Session expiration is possible
  at any time.
- **Live OAuth for Google Drive:** Requires a configured OAuth Client ID
  (`GOOGLE_CLIENT_ID` env or `client_secret.json` in config). No real
  authorization was performed in this repository.
- **Live mount testing:** `Test-WriteAndUploadVerification.ps1` and
  `Test-EndToEndAcceptance.ps1` may use configured provider sessions; do not run
  against active user mounts without explicit approval.

## Safe testing procedures

**Never** disconnect, remount, or terminate healthy production drives just to
achieve test coverage. **Never** print credential files, tokens, cookies, or
private account values.

### Regression test commands (safe, mocked/sandboxed)

```powershell
# Run focused safe regression suite
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SettingsManager.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TeraBoxProvider.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TeraBoxBridgeManager.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TeraBoxAccountIsolation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GoogleAccountCreationRecovery.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AccountCreationSaveFlow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountLifecycle.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountIsolation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartupAutoMountTimer.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AnalyticsPage.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-DesktopUIRegression.ps1
```

### Before changing TeraBox code, inspect

- `git status --short --branch` and `git log --oneline -10`
- `src/providers/TeraBoxProvider.ps1` — session validation, cookie handling
- `src/services/TeraBoxBridgeManager.ps1` — bridge lifecycle, port/home isolation
- `src/services/VirtualDriveManager.ps1` — mount start/stop, process ownership
- `src/ui/EmbeddedBrowserWindow.ps1` — WebView2 sign-in flow
- `src/NSCloudDrive.ps1` — startup restore, reconnect watchdog, disconnect flow
- `tests/Test-TeraBoxAccountIsolation.ps1` and `tests/Test-TeraBoxProvider.ps1`
- `docs/engineering/TERABOX_TROUBLESHOOTING.md`

## Troubleshooting checklist

| Symptom | First place to inspect |
|---------|----------------------|
| `Get-VerifiedRclonePath` not recognized | Worker script block inside `Invoke-StartupAutoMount` / `Invoke-AutoReconnectWatchdog` — is the helper defined worker-locally? |
| `The property 'Exception' cannot be found` on disconnect | `Complete-AvailableDriveDisconnectWorkers` — is `$completed.Errors[0]` an `ErrorRecord` or raw `Exception`? |
| `$closeTimer` dispatcher exception | `Show-TeraBoxEmbeddedLoginWindow` — is `$closeTimer` declared at scriptblock scope? |
| TeraBox bridge won't start | `Find-CpxBinary` paths, port collision, `terabox-bridge` home dir permissions |
| Account card shows wrong provider icon | `New-AccountDiskIcon` switch — explicit `gdrive`/`terabox` branches, no `else` fallback to TeraBox |
| Two accounts merged into one card | `Get-CloudAccounts` return shape — must emit individual records, not `return ,$list` |
| Legacy mount attributed to saved account | `Get-CachedUiDriveStatus` — must reject cached status whose AccountId/DriveLetter contradicts the requested identity |
| Sign-in window closes without saving | `Show-TeraBoxEmbeddedLoginWindow` `Add_Closing` — checks `LoginCompleted` and existing DPAPI session |
