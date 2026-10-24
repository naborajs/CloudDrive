# TeraBox Troubleshooting and Verification Limits

This document separates known code-level fixes from unresolved live-provider
behavior. TeraBox has an unofficial web-session backend and a CPX WebDAV
bridge. A passing unit or structural test is not evidence that real TeraBox
mounts are reliable or that concurrent independent TeraBox accounts work.

## Provider path

The main implementation is in:

- [`TeraBoxProvider.ps1`](../../src/providers/TeraBoxProvider.ps1):
  `Get-TeraBoxCredentialFilePath`, `Get-TeraBoxStoredSession`,
  `Save-TeraBoxSession`, `Remove-TeraBoxSession`,
  `Get-TeraBoxRcloneEnvironment`, `Test-TeraBoxBackendSession`, and file
  listing/session helpers.
- [`TeraBoxBridgeManager.ps1`](../../src/services/TeraBoxBridgeManager.ps1):
  account-scoped bridge home/port/password, `Start-TeraBoxBridge`,
  `Stop-TeraBoxBridge`, health checks, and process bookkeeping.
- [`VirtualDriveManager.ps1`](../../src/services/VirtualDriveManager.ps1):
  `Start-VirtualDriveMount`, `Get-VirtualDriveStatus`, and
  `Stop-VirtualDriveMount`.
- [`NSCloudDrive.ps1`](../../src/NSCloudDrive.ps1):
  startup restore, `Get-VerifiedRclonePath`, the worker-local helper,
  provider/account cards, recovery states, and background status updates.
- [`ProviderConnectionWindow.ps1`](../../src/ui/ProviderConnectionWindow.ps1):
  `Connect-NewCloudAccount` and `New-CloudAccountRecord`.

TeraBox supports a browser web-session mode and a separate official Open
Platform mode that needs provider-issued credentials and has app-folder
limitations. Do not treat cookies copied from a browser as a supported
configuration. The bridge is local loopback plumbing; it does not make the
web-session backend official or guarantee provider compatibility.

## Known issue: `Get-VerifiedRclonePath` is not recognized

**Observed error:** A startup/restore worker can report
`Get-VerifiedRclonePath` as an unknown command.

**Verified cause:** A PowerShell background runspace has its own function
scope. Defining `Get-VerifiedRclonePath` in the WPF/UI script does not make it
available in the worker automatically.

**Current code:** `Invoke-StartupAutoMount` defines the resolver within the
worker script block. The UI helper also exists at main-script scope. Do not
remove the worker-local function on the assumption that functions are shared
between runspaces.

**Fix evidence:** `f8ba4f1c75099127df5841448d543fe021c94ff0` adds equivalent
legacy startup restore verification. `Test-MultiAccountLifecycle.ps1`
asserts that the resolver is defined in the startup worker region.
This is structural coverage, not a real TeraBox mount test.

## Known issue: bridge result/property shape

`Start-TeraBoxBridge` previously allowed a Boolean return value from
`Stop-TeraBoxBridge` to leak into the caller's output. PowerShell then emitted
an array containing the sentinel and status dictionary; strict access to
`.Success` failed on the Boolean object.

The current code explicitly discards the stop helper output. The root cause is
documented at the call site and the fix is in
`70083a20886e5c9ab74c8691b5501b085cce7f6d`. This is a verified
PowerShell output-shape bug; it is not evidence that every TeraBox
`State`/property error has this cause.

## Missing `.State` and stale status

Provider/UI code has previously encountered incomplete result objects and
direct property reads under strict mode. The main UI now uses `Get-SafeProperty`
for optional provider result fields and status normalization. Mount progress
objects are built with `New-MountOperationState`, which includes `State`,
`Stage`, `AccountId`, and `DriveLetter`.

Regression coverage exists in `Test-GoogleAccountCreationRecovery.ps1`,
`Test-MultiAccountLifecycle.ps1`, and the isolated WPF
`Test-StartupAutoMountTimer.ps1`. These cover known result shapes and do not
prove every TeraBox branch. The exact historical stack for a user-observed
`.State` failure is unavailable; capture the current object type, properties,
and stack if it recurs.

## Mount, retry, disconnect, and recovery problems

Potential sources to inspect in order:

1. Is the account record present and is its `ProviderId` exactly `terabox`?
2. Does the record's `AccountId` resolve to its own TeraBox session file?
   Account-scoped `Get-TeraBoxStoredSession` must not silently read the
   legacy shared session.
3. Does `Test-TeraBoxBackendSession -AccountId <id>` validate that same
   session? Check `State`, sanitized `Error`, and `UserInfo` without printing
   cookies or credentials.
4. Does `Start-TeraBoxBridge -AccountId <id>` use the matching session,
   home, port, and health-check password? Does the process exit or fail its
   bounded readiness check?
5. Does `Get-TeraBoxRcloneEnvironment -AccountId <id>` produce the expected
   account-scoped environment? Do not dump its secret-bearing values.
6. Does `Start-VirtualDriveMount` use the saved letter and ID? Is the rclone
   process actually owned by that ID?
7. Did Windows expose the drive, and did `Test-VirtualDriveFilesystem`
   verify its root? A live CPX/rclone process alone is not a usable mount.
8. Does the account-specific status snapshot agree with the saved ID and
   letter? Provider-wide `TeraBoxStatus` is not proof that a given saved
   account owns the mount.
9. For disconnect, verify the selected account ID, letter, bridge ownership,
   and final Windows status. Do not stop an unowned bridge/process or remove
   settings simply to clear a stale card.

The code includes account-scoped session filenames and cache/bridge
namespaces, process ownership checks, bounded worker operations, and explicit
recovery states. Source presence and mocked tests do not establish that all
retry/disconnect sequences are correct under provider throttling, Windows
mount delays, or a changing TeraBox website.

## Account name and mount association

Display names are editable labels, not proof of provider identity. TeraBox
session validation may return a provider username; the UI must only display
that information for the same account-specific session. An unregistered
provider mount must remain an unidentified recovery mount and must not inherit
the first saved TeraBox account's label or quota.

When diagnosing a mismatch, compare:

- saved account ID/provider/drive letter;
- account-specific session key and bridge key;
- process ownership and command-line mount target;
- the filesystem root seen by Windows;
- account-specific status snapshot versus provider-wide fallback.

Never use display name, array position, or “first TeraBox record” as the
association key.

## Session persistence and concurrency limitations

`Get-TeraBoxCredentialFilePath` provides per-account credential paths for
non-legacy account IDs, and account-specific session reads avoid fallback to
the shared legacy session. `Test-TeraBoxAccountIsolation.ps1` exercises
credential, bridge-secret, home, port, and cleanup isolation with synthetic
fixtures. The `Start-TeraBoxBridge` source also keeps a process map keyed by
account ID, but contains a legacy singleton field in addition to that map.

**Unverified:** The repository has not established reliable concurrent mounts
for two real TeraBox accounts. Do not claim concurrent support based on
synthetic unique-port/session tests. Test this separately on an isolated
Windows machine with disposable accounts before making a support claim.

## UI freezes and async boundaries

Provider checks, bridge/mount operations, and status work should not block the
WPF dispatcher. Use the existing background-operation manager and verify
completion on the dispatcher; keep timeouts bounded and surface errors.
Analytics must sample only while its page is active, and Logs must keep bounded
reads. Relevant UI regression suites are listed in
[Testing and validation](TESTING_AND_VALIDATION.md).

Do not add another polling timer or synchronous provider request to a UI
handler. A stale status should be diagnosed by following the operation to its
completion/result and refreshing the relevant status snapshot—not by marking
the card healthy or suppressing an exception.

## Safe tests

These tests are designed to be synthetic, structural, or sandboxed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TeraBoxProvider.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TeraBoxBridgeManager.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TeraBoxAccountIsolation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MultiAccountLifecycle.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartupAutoMountTimer.ps1
```

Read each test before running it. Avoid the full runner when a test may inspect
or contact the currently configured provider. No test above proves concurrent
real TeraBox support or safe operations on existing user mounts.
