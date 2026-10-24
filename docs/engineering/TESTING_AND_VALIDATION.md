# Testing and Validation Guide

Tests in this repository have different safety and evidence profiles. A
passing mocked or structural test proves only the behavior represented by its
fixtures and assertions. It does not certify real provider accounts,
concurrent mounts, or production reliability.

## Test categories

### Synthetic, mocked, or structural tests

These tests are the preferred first step for account and UI code because they
do not need a live provider identity or a real cloud mount:

| Test | Evidence scope |
| --- | --- |
| `Test-AccountCreationSaveFlow.ps1` | Sandboxed account save, independent IDs/emails/rename, validation, array contract, and connection-handler wiring. |
| `Test-GoogleAccountCreationRecovery.ps1` | Mocked Google API/identity and OAuth result shapes, no placeholder persistence, sanitized errors, missing fields, and account creation recovery. |
| `Test-MultiAccountLifecycle.ps1` | Synthetic lifecycle, identity mismatch/match, mount-state shape, settings, removal, worker wiring, and account-scoped paths. |
| `Test-MultiAccountIsolation.ps1` | Synthetic Google/TeraBox credential/config/remote and status isolation. |
| `Test-TeraBoxAccountIsolation.ps1` | Synthetic TeraBox session, bridge-secret, port/home, and cleanup isolation. |
| `Test-SettingsManager.ps1` | Sandboxed settings persistence, CRUD, migration/defaults, drive-letter allocation, and atomic write behavior. |
| `Test-AnalyticsPage.ps1` | Structural/on-demand Analytics contracts and no fabricated quota/resource values; no live quota call. |
| `Test-LogsPage.ps1` | Sandboxed log persistence/redaction/bounds and structural Logs-page behavior. |
| `Test-StartupAutoMountTimer.ps1` | Isolated WPF process/dispatcher, synthetic account cards/statuses, and Logs navigation/page behavior. |
| `Test-ExplorerIntegration.ps1` | Explorer icon registry behavior confined to an isolated test root. |
| `Test-DesktopUIRegression.ps1` | STA application load, UI structure, branding, and singleton behavior. |
| `Test-VirtualDriveFilesystemVerification.ps1` | Filesystem probe contract and timeout handling; inspect its fixture to confirm the current test mode before running. |
| `Test-GoogleDriveProvider.ps1` | OAuth/PKCE, credential namespace and API behavior using test doubles/temporary storage; not a real Google login. |
| `Test-TeraBoxProvider.ps1` | Session/provider logic using synthetic or mocked responses; not a live TeraBox login. |

### Tests needing careful preflight

Do not run a test just because it is named a regression test. Read the test
body first and determine whether it starts, stops, or inspects real processes
or uses the configured `%LOCALAPPDATA%`.

- `Test-WriteAndUploadVerification.ps1` includes provider listing checks using
  the configured Google and TeraBox sessions. A prior run returned read-only
  file listings for the currently configured sessions. It did not validate
  two Google accounts concurrently or prove mount isolation. Do not rerun
  without explicit user approval and a safe isolated account/configuration.
- `Run-AllTests.ps1` includes `Test-WriteAndUploadVerification.ps1` and other
  Windows/mount-oriented suites. It is not a universally safe smoke-test
  command while active mounts or provider sessions exist.
- `Test-EndToEndAcceptance.ps1` includes app/provider-integration assertions;
  inspect its setup and side effects before running in an environment with
  real credentials.

### Real Windows/provider integration tests

The following require a dedicated disposable Windows profile and test
accounts, explicit user authorization, and an agreed cleanup plan:

- Complete OAuth in an actual browser and verify the returned identity against
  the intended account.
- Mount two distinct Google identities simultaneously, check each Windows
  drive's contents, restart, disconnect one account, and prove the other
  remains mounted and unchanged.
- Validate Explorer create/read/write behavior and pending-write safety.
- Exercise real disconnect/reconnect and startup restore without stopping
  unrelated processes.
- Independently establish whether multiple TeraBox sessions can remain
  authenticated and mounted concurrently.

These have **not** been established by the synthetic tests. Do not run them
against a user's important files or active mounts.

## Recommended focused commands

From the repository root in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AccountCreationSaveFlow.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GoogleAccountCreationRecovery.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountLifecycle.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountIsolation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TeraBoxAccountIsolation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartupAutoMountTimer.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SettingsManager.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-AnalyticsPage.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LogsPage.ps1
```

For the full suite, first review
[`Run-AllTests.ps1`](../../tests/Run-AllTests.ps1) and confirm every test's
provider/process side effects are acceptable:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AllTests.ps1
```

CI runs PowerShell AST parsing, a secret-pattern scan, and the full test
runner on `windows-latest` in
[`ci.yml`](../../.github/workflows/ci.yml). CI does not use the user's live
account, and its result is not live provider or production certification.

## Validation history relevant to account merging

The following assertions have been observed passing in isolated/synthetic
tests after the array-shape and status-ownership fixes:

- `Test-AccountCreationSaveFlow.ps1`: two saved records keep their email and
  display-name association when a second account is added or the first is
  renamed.
- `Test-StartupAutoMountTimer.ps1`: the WPF UI renders two synthetic Google
  cards and one synthetic TeraBox card, with correct labels/emails/icons; an
  account is not marked mounted from provider-only or mismatched status.
- `Test-MultiAccountLifecycle.ps1` and `Test-MultiAccountIsolation.ps1`:
  account-specific state/configuration and selected-account operations are
  checked using test fixtures.

In a prior validation, `Test-WriteAndUploadVerification.ps1` also listed files
from the currently configured Google and TeraBox provider sessions. This was
single-session read-only provider evidence and did **not** verify concurrent
Google mounts or concurrent TeraBox support.

## Documentation-only checks

For documentation changes, verify:

1. Every relative Markdown link resolves to a tracked or newly-created file.
2. Every named function exists in the current source (`rg -n "function Name"
   src`).
3. Commit hashes resolve with `git show <hash>` and refer to the stated files.
4. Commands point to scripts actually present under `tests`.
5. Docs contain no credential, cookie, token, authorization code, or private
   account data.
6. `git diff --check` is clean and each documentation commit changes exactly
   one file.

See [Incidents and fixes](INCIDENTS_AND_FIXES.md) and
[Google Drive multi-account](GOOGLE_DRIVE_MULTI_ACCOUNT.md) for the specific
regressions.
