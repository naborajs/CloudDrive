# Engineering Incidents and Verified Fixes

This is an evidence ledger, not a list of assumptions. “Verified” below means
the stated behavior was reproduced by source analysis or the named test; it
does not mean every fix was validated against live provider accounts or
concurrent Windows mounts. Commit identifiers are full hashes from repository
history unless explicitly noted otherwise.

## Incident summary

| Incident | Evidence status | Current disposition |
| --- | --- | --- |
| Google cards merged names/emails; Google cards showed TeraBox icon | Root cause reproduced from PowerShell output shape and WPF rendering | Fixed; synthetic WPF regression added |
| Account card borrowed provider-wide mount status | Root cause reproduced in the status fallback | Fixed; account-specific/mismatched status regression added |
| OAuth browser success followed by identity/account creation failure | Flow traced; mocked failure mode reproduced. No single live failure cause established | Safer verification/retry/error path; live API failure may still occur |
| `State` property missing | Two distinct code paths addressed: worker mount-state record shape and unsafe provider-result access. Historical exact original stack is unavailable | Regression coverage added; no claim of a live OAuth error reproduction |
| `ReadOnly` property missing | Legacy field absence confirmed and normalized; historical exception stack is unavailable | Safe `false` default tested; original throwing caller remains unconfirmed |
| Legacy/recovery Google mount shown separately from saved accounts | Distinct provider-only and saved-account paths confirmed | Recovery card no longer borrows saved identity/quota; ownership remains unresolved until evidence exists |
| `Get-VerifiedRclonePath` missing in TeraBox startup worker | Worker runspace scope cause confirmed by source and regression assertion | Worker-local resolver added; test is structural, not live TeraBox mounting |
| TeraBox bridge status object polluted by Boolean output | Root cause documented in source comment and fixed in commit | Shutdown helper output is discarded; inspect bridge tests for coverage |
| Logs page crash/freezing and Analytics stalls | Async/bounded implementations and tests are present | Isolated WPF/structural regression tests; no production performance certification |
| Automatic Explorer launch during recovery | Recovery-vs-user launch paths have a dedicated fix and test history | Recovery should not launch Explorer; real-world UX not certified across all paths |
| Mount timeout and stale status | Separate process/drive/filesystem states confirmed | Timeouts and process-preservation paths tested; actual provider/mount matrix incomplete |

## 1. Merged Google cards and wrong provider icon

**Observed symptom:** Two Google identities appeared as one card with joined
display names/email addresses. The same card could show a TeraBox icon despite
Google provider text.

**Reproduction:** The specific failure was reproduced by examining
PowerShell's output for a function that returns a non-enumerated array. The
old `Get-CloudAccounts` used `return ,$list`; a caller using
`@(Get-CloudAccounts)` wrapped that array as one outer item. In the UI, the
outer item was the inner account array, not an individual record. PowerShell's
adapted member enumeration yielded combined property values. The combined
provider string did not match the exact Google icon branch and an old
`if/else` mapping selected TeraBox.

**Root cause:** Collection-shape mismatch between
[`Get-CloudAccounts`](../../src/services/SettingsManager.ps1) and its callers,
plus a provider-icon fallback that treated every non-Google provider as
TeraBox. The source does not support the claim that the persisted settings
records themselves had merged.

**Fix:** `Get-CloudAccounts` now returns individual pipeline records; array
consumers explicitly wrap output where needed. UI icon selection is
provider-specific with no TeraBox fallback for unknown providers. The card
list renders each saved record independently.

**Commits:** `4ba35515938ba25c3278688130a02ac961b49335`,
`5aeec7bffa4fb972216931cc209b9917668c7e0b`,
`66a080b5016e803111539c43242c55da56d04c7e`,
`ee4f36862a8fc9eac740734d33b580f5d3cc5176`.

**Tests/evidence:** `Test-AccountCreationSaveFlow.ps1` verifies separate
records and independent rename. `Test-StartupAutoMountTimer.ps1` constructs an
isolated WPF window with two synthetic Google records and one TeraBox record,
then asserts exactly three cards with correct names/emails/provider labels and
icon asset names. This uses synthetic data; it is not a provider test.

**Watch for:** Removing `return ,` without reviewing all callers; double
wrapping or reintroducing array-valued card properties; icons selected by
position, display name, or an `else` branch. Re-run the exact WPF regression
after touching account retrieval or card construction.

## 2. Provider-wide mount status assigned to an account

**Observed symptom:** Dashboard cards could disagree with saved records, show
an account as mounted on another account's drive, or expose identity from a
provider-wide/legacy session.

**Reproduction:** In `Get-CachedUiDriveStatus`, an account-specific lookup
could miss `AccountStatuses[$AccountId]`, then continue to the provider-wide
`GoogleStatus`/`TeraBoxStatus`. A provider status describes that provider's
legacy mount; it is not proof that the saved account owns the mount. A stale
account status could also report a different target letter.

**Root cause:** Fallback crossed the account ownership boundary. Provider ID
and provider-level status are not unique account identifiers.

**Fix:** Account-specific lookups now return an unmounted account-shaped
result when account evidence is missing. Cached account status is rejected if
its reported account ID or drive letter contradicts the requested identity.
Provider-only mounts remain separately visible for recovery; they do not
borrow a saved account's name, email, quota, or configuration.

**Commits:** Earlier process-ownership guard:
`bf09f3c2de4a7d5726534a6f8445ceb628101ff8`. Legacy-vs-saved separation:
`d24e26fab77ca8ac267913cc1187a2d9f0bfaa4a`. Current UI evidence guard:
`ee4f36862a8fc9eac740734d33b580f5d3cc5176`. WPF regression:
`2c6a7791e3893c812f54026e8ca2ef2383d6a43a`.

**Tests/evidence:** `Test-StartupAutoMountTimer.ps1` asserts that a
provider-wide status without account-specific evidence, and a cached status
with a mismatched drive mapping, do not mark an account mounted. These tests
use synthetic snapshots and do not inspect active real mounts.

**Watch for:** Matching by display name or provider alone; falling back from
an account ID to provider status; assuming a Windows drive letter proves
ownership. Compare account ID, provider, letter, process owner, and filesystem
state explicitly.

## 3. OAuth browser success, failed identity verification, or failed save

**Observed symptom:** The browser displayed rclone's generic “Success! All
done! Please go back to rclone.” page, but the app did not create the expected
account or previously surfaced a missing `State` property.

**What is established:** The generic success page is produced by the rclone
authorization path and indicates that the browser callback completed. It
does not prove that NS Cloud Drive subsequently verified the returned
identity, persisted the account, mounted a filesystem, or refreshed the UI.
The native loopback OAuth path is different: it renders a local branded page
after validating the callback response. That implementation is in commit
`adc8a3ece65319a6f508566d7169dbc6d149c4bd`. The code traces these steps
separately.

`New-CloudAccountRecord` verifies the returned Google tokens through
`Test-GoogleDriveBackendSession`. The latter calls Drive API identity
endpoints and may use an rclone fallback. Google API errors, missing identity
fields, invalid email shape, identity mismatch, and duplicate email are
distinct failure cases. The mocked regression reproduces a valid token session
whose direct identity calls fail and whose fallback only returns a generic
display name. It asserts that this is not treated as verified and no
placeholder account is saved.

**Unresolved:** The earlier live account-creation failure was not captured with
a complete safe stack trace and provider response. It is therefore not
established that one API permission, OAuth client setting, callback, or
persistence operation caused every reported failure. Do not claim that
replacing the callback page alone fixes identity verification.

**Fixes:** Require a provider-verified email for new Google accounts, expose
sanitized identity failure reasons, provide retry without repeating OAuth,
discard the newly staged credentials if verification is abandoned, reject
duplicate verified identity, and leave prior accounts untouched.

**Commits:** Identity requirement:
`e97599e97290aa39120f508e79583fbfc8d3dc18`. Preserve account flow after OAuth:
`db47ccb17a4898c799fb9feb19c28ffb5c4a3a3d`.

**Tests/evidence:** `Test-GoogleAccountCreationRecovery.ps1` mocks API and
identity responses; it checks no placeholder persistence, verified identity
acceptance, missing-email handling, sanitized errors, and safe UI result
handling. This does not perform real authorization or prove every OAuth client
configuration.

**Watch for:** Treating authorization success as account creation success;
accepting a fabricated name/email; storing a token set under a different
account ID; weakening callback state validation to suppress an object error.
Reproduce with mocked Google API responses first, then obtain user permission
before any live authentication attempt.

## 4. Missing `State` property

Two separate implementation paths have been implicated; the original
historical exception stack was not preserved, so they must not be conflated.

### Mount progress object

Mount worker progress was consumed by UI code expecting a `.State` field.
`New-MountOperationState` now creates a synchronized record containing
`State`, `Stage`, `AccountId`, `DriveLetter`, `Error`, and timestamps.
`Test-MultiAccountLifecycle.ps1` verifies that the record exposes the state
and ownership fields. Commit:
`2732078f955a09ff8ecdaee3d84d096cc3ba89de`.

### Incomplete provider result

Provider results can be missing optional members, especially in failure
paths. UI code now uses `Get-SafeProperty` for provider `State` access and
normalizes incomplete dashboard status objects. The regression checks assert
that direct `$verify.State`/`$res.State` access is not used in the affected
creation path and that missing state becomes an explicit error state.
`Test-GoogleAccountCreationRecovery.ps1` exercises this with mocked results.
The corresponding safe-access correction is in repository history at
`a201ec617d7354cf35a6b2e1ef835f3c4a032af4`.

**Unresolved:** No evidence ties the original reported OAuth exception to
either exact call site. Both known fragile shapes now have coverage, but a
future recurrence must be diagnosed from its exact object type and stack.

## 5. Missing `ReadOnly` property

**Observed:** Account records from older settings may not contain the optional
`ReadOnly` field. The current normalization path in `Get-NSCloudDriveSettings`
and `Get-CloudAccounts` supplies `false`; account update also preserves or
defaults the field. The lifecycle test verifies a legacy record without the
field becomes read-write by default. Commit adding the test:
`aaaad755e4f720152d4a3a3833e8dd9768e40bfb`.

**Unresolved:** The exact historical object and call stack for
“The property 'ReadOnly' cannot be found on this object” are not available.
The evidence proves the missing-field case is normalized in current
settings paths, not that this was the sole original source. Do not simply
catch the property exception; trace the producer and consumer and add a
regression for that object shape.

## 6. Legacy mount and account-to-drive mismatch

**Observed symptom:** Google provider card and saved-account card showed
different status; old/recovery entries returned after reconnect; identity or
quota appeared attached to a mount without a verified association.

**Root cause:** The application supports both provider-only legacy mounts and
account-ID-based saved mounts. They can coexist. A provider's valid session
does not prove that a particular Windows drive letter is owned by a saved
account; identity and drive assignment require account-specific evidence.

**Fix:** `Update-AllUIState` computes whether a provider-level active mount can
be matched to an account-specific mounted status and letter. Unmatched mounts
are labeled recovery-needed without borrowing the provider session's identity
or quota. Saved account records remain visible separately and are not deleted
to make the counts appear consistent.

**Commits:** `d24e26fab77ca8ac267913cc1187a2d9f0bfaa4a`,
`ee4f36862a8fc9eac740734d33b580f5d3cc5176`.

**Verification limit:** The logic has mocked/structural coverage. The meaning
and owner of any existing mount must still be verified on the machine before
reconciliation, removal, or cleanup. Do not assign a legacy mount based only
on its provider label or drive letter.

## 7. TeraBox startup worker cannot resolve `Get-VerifiedRclonePath`

**Observed error:** A TeraBox startup restore path raised a
`CommandNotFoundException` for `Get-VerifiedRclonePath`.

**Root cause:** The UI defines a helper in its session, but a background
runspace has its own function scope and does not automatically inherit that
definition. The startup worker therefore defines a worker-local resolver.

**Fix and evidence:** `Invoke-StartupAutoMount` has a worker-local
`Get-VerifiedRclonePath`; `Test-MultiAccountLifecycle.ps1` asserts the
definition is within the worker region. The legacy restore fix is committed
as `f8ba4f1c75099127df5841448d543fe021c94ff0`.

**Limit:** This verifies helper availability structurally. It does not prove a
real TeraBox session, bridge, or mount works.

## 8. TeraBox bridge result had unexpected object shape

**Evidence:** `Start-TeraBoxBridge` contains a source comment explaining that
uncaptured `Stop-TeraBoxBridge` output leaked its `return $true` sentinel.
PowerShell then returned an array containing the Boolean and bridge status
dictionary; strict property access to `.Success` failed on the Boolean.

**Fix:** The shutdown helper result is explicitly discarded so the public
result remains the expected status dictionary. Commit:
`70083a20886e5c9ab74c8691b5501b085cce7f6d`.

This is a verified object-shape bug and should not be generalized into a claim
that all TeraBox `.State` errors have the same cause.

## 9. Mount process, filesystem, status, and Explorer

The implementation intentionally distinguishes process start, Windows drive
visibility, and filesystem-root verification. `Start-VirtualDriveMount`
waits for the drive and checks its root. A timeout must not be interpreted as
a healthy mount. Some timeout branches preserve a still-running process so
the UI can report the real state; do not kill it solely to clear an error.

Relevant evidence:

- Filesystem verification before success: commit
  `48495c080dcd8a6500ab6f9c42fe19672e9f40bf`.
- Preserve active process after a root-probe timeout: commit
  `ca37114d879c0c6fc11399a160a1bc001b24bc01` (test) and
  `916565d672434aab6da94a95f66a2fb662db0fa1` (status behavior).
- Scoped process ownership: commit
  `bf09f3c2de4a7d5726534a6f8445ceb628101ff8`.
- Recovery must not reopen Explorer: commit
  `19720495e59d8e2e64abe0a850669a02d2f93b9f`.

`Test-MultiAccountLifecycle.ps1`, `Test-VirtualDriveFilesystemVerification.ps1`,
`Test-ExplorerIntegration.ps1`, and
`Test-StartupAutoMountTimer.ps1` cover mocked, structural, or isolated
Windows behavior. They do not prove every drive, process, or Explorer
integration on a user's live system.

## 10. Logs and Analytics responsiveness

The current Logs implementation requests bounded pages on a background
operation, polls completion from a dispatcher timer, cancels when leaving the
page, and reports a 10-second timeout. Analytics storage checks run in a
background operation, and the sampler is started on Analytics entry and
stopped on navigation away. These replace unbounded/synchronous behavior in
the relevant paths.

Relevant commits include `8c0645bad555d4f6b3ae31a089aa73cfa000cf3f` (bounded
Logs viewer) and
`43dbedfb2db66266c04bb296206339dbc52fc245` (Logs/Analytics stabilization).
`Test-LogsPage.ps1`, `Test-AnalyticsPage.ps1`, and the isolated WPF
`Test-StartupAutoMountTimer.ps1` check page contracts and responsiveness
mechanisms. No long-duration performance or crash certification has been
performed.

## Reproduction policy

For any recurrence, capture (with secrets redacted) the exact call stack,
provider ID, account ID, expected drive letter, returned object type and
available property names. Reproduce with a sandbox or mocks first. Never dump
token files, cookies, full OAuth callback URLs, or live account emails into
logs/issues/docs. Read the associated engineering guide and test before
changing code.
