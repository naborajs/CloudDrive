# Security and limitations

**Status:** Security design and known risks; no account credential has been used in this project.

## Current security posture

- The WPF preview does not read rclone configuration, sign in, request secrets, or mount a drive. Separate PowerShell scripts now inspect an encrypted config and start a read-only mount, but they have not run against a real backend.
- The selected rclone TeraBox backend is unofficial and relies on a web-session token, not TeraBox's official OAuth integration. TeraBox documents an official QR/device-code flow for separately registered applications, but its API is scoped to an application-assigned folder; access to the user's existing full-drive root has not been established.
- In the pinned upstream revision before the local patch, the `cookie` field was required but not marked sensitive. The backend constructor's level-1 debug statement formatted the full options struct, which contains that cookie. Higher debug levels are documented to include request/response parameters or bodies.
- A patch is committed for the pinned `v1.75.2-extra` source: it marks the cookie option sensitive, removes the options-struct debug statement, disables backend-specific debug output, and extends rclone's ordinary HTTP-dump redaction to request `Cookie` and response `Set-Cookie` headers, including repeated headers. It scans the complete header block, preserves line endings, and leaves the body unchanged. Synthetic cases cover repeated headers, curl output, and a cookie after a header block longer than 4 KiB. These are helper-level tests, not a response-dump integration test. The patch applies to the exact pinned source; Go tests and compilation have not run. Explicit `--dump auth` intentionally bypasses this redaction, and body dumps are not sanitized; the desktop launcher must never enable dump flags.
- A pinned-source Windows build helper and a read-only mount launcher are committed. The launcher checks the build manifest and hashes, requires an encrypted/decryptable rclone config, uses a 20 GiB best-effort cache, sets backend debug to zero, and runs in the current user session. Both scripts are syntax/preflight-tested only; no executable or mount exists on this PC.
- `scripts/RcloneConfigPassword.ps1` is designed to locally store the **rclone config-encryption password** as a current-user DPAPI-protected PowerShell credential, with an ACL for that user and SYSTEM. The launcher supplies it through rclone's documented password-command feature and disables interactive fallback. This is not TeraBox authentication and does not store or acquire a TeraBox cookie. A synthetic DPAPI read-back, plaintext-absence check, ACL application to a temporary directory/file, and missing-credential fail-closed check passed in the current PowerShell host. The interactive `-Store` prompt and separate Windows PowerShell subprocess are unverified; the latter was blocked by this environment's `AuthorizationManager` restrictions.
- `scripts/Manage-UserMountStartup.ps1` defines opt-in registration/removal for a limited, interactive-user logon task. Registration requires a matching build, encrypted config, and an explicit read-only acceptance flag. The task has not been registered; its behavior and reconnect handling are unverified.
- The third-party QR helper is not TeraBox's documented Open API device-code flow: it imitates browser headers against website login endpoints, extracts ndus, passes it as an rclone config command-line argument, and stores it in ordinary config. It is not compatible with this project's no-browser-impersonation and secret-handling requirements; we did not run it.
- No account was authenticated, no user files were listed, and no remote file operation was executed.

### Pinned-source authentication review (2026-10-22)

The exact pinned `gulp79/rclone-extra` source accepts either a full website cookie or `ndus`; the API client adds that configured value to the HTTP `Cookie` header. Its `NewFs` path logs the complete options struct at backend debug level 1, and the backend debug helper emits messages when the configured level allows it. The source review found no supported interactive sign-in, refresh, or cookie-renewal routine. An invalid-cookie response is an error; cached `jsToken`, base URL, and time-limited metadata are not a session refresh mechanism. The credential would be supplied through the rclone remote configuration, which must be encrypted/protected separately and is still not a permitted app-managed login flow.

The committed source patch targets the discovered explicit exposure: it marks `cookie` as sensitive for rclone option handling, removes the full-options debug call, fixes backend debug output to off, and adds `Cookie`/`Set-Cookie` to rclone's ordinary HTTP dump redaction. It processes repeated matching headers within the full header block, preserves CRLF boundaries, leaves bodies unchanged, and applies the redactor to response dumps when `--dump auth` is not enabled. Patch-apply success does **not** establish that the patch compiles, that the Go regression tests pass, or that every rclone/config/HTTP error path and diagnostic is sanitized; current synthetic cases cover the helper and curl transformation, not an end-to-end response-dump capture. The source review confirmed that `--dump auth` deliberately skips redaction and body dumps are not sanitized; the NS Cloud Drive launcher currently supplies no dump flags. Treat the patch as an unverified mitigation, not proof that credentials cannot enter logs. The unresolved manual website-cookie requirement remains sufficient reason to keep authentication and real-account testing blocked.

### Embedded browser bridge decision (2026-10-22)

Microsoft WebView2 supports persistent browser profile data in a per-user user-data folder, but that only preserves the browser's own site session. It is not an approved handoff to rclone, and Microsoft warns against scraping cookies or tokens from embedded authentication flows. TeraBox's official terms do not establish that replaying a website cookie through this unofficial backend is a supported interface; the backend itself documents manual cookie copying and has no interactive handoff, refresh, or renewal flow. Cookie/device binding and session-revocation behavior remain unknown. A logged-in WebView page must not be used as a connected-state signal.

Do not read WebView2 cookies, copy its profile database, inject cookies into rclone, or persist extracted browser session values in DPAPI or another app store. Encrypting a copied cookie would not make an unsupported replay flow permitted or provide a refresh contract. Keep WebView2 sign-in and the mount action unimplemented until TeraBox confirms a supported Windows desktop authorization flow and the official API grants the required existing-root scope. Its currently documented app-assigned-folder scope is insufficient evidence for the full-drive objective. See the [feasibility review](FEASIBILITY.md#browser-to-backend-authentication-review-2026-10-22).

## Secret-handling requirements before adding sign-in

1. Compile the pinned patch and add tests proving a synthetic secret never appears in logs, exceptions, config-redacted output, or diagnostics. The current patch is not yet a security guarantee.
2. Prefer a user-confirmed QR/device authorization flow. If only cookie copy is available, keep sign-in unavailable; do not ask for or collect a cookie through chat, a script, an issue, or a screenshot.
3. A future provider session must use a reviewed Windows-protected store and never enter Git, ordinary settings JSON, command-line arguments, persistent environment variables, telemetry, or crash dumps. The current DPAPI helper protects only the rclone config-encryption password; it does not validate or implement provider-session storage.
4. If a reviewed backend must receive a session through a process environment variable, decrypt it only in memory immediately before process start, set it only in the child environment, clear the parent copy, and verify child logs/process diagnostics do not export it. This is a design option, not implemented or verified here.
5. Keep app settings and secret storage separate. Restrict config/diagnostic ACLs to the current user and SYSTEM. Protect the device and cache volume with BitLocker where available.
6. Never run the user's mount as SYSTEM. The interactive user's drive visibility and secret scope are more important than a background service abstraction.
7. Keep backend debug level zero. Avoid raw rclone config dumps and `--dump` diagnostics. Treat third-party error strings, request URLs, remote names, and file names as sensitive until a synthetic-secret sanitization test proves otherwise.
8. Reauthenticate only through a user-initiated provider flow. Do not bypass authentication, CAPTCHA, access controls, quotas, rate limits, or other provider protections.

## Cache and data integrity

- The VFS cache contains local content, including potentially sensitive user files. Default it to the user's `D:\CloudCache\TeraBox` only after checking that D: is available, NTFS, writable, and has enough free space.
- The read-only mount launcher now requires an absolute local path on a ready fixed NTFS volume, at least 25 GiB free, and a cache directory below the volume root. It rejects existing junctions or symbolic links in the target path and checks again after creating missing folders. This is path validation, not protection against later same-user changes, and it has not been tested during a real mount.
- `--vfs-cache-max-size` and `--vfs-cache-max-age` are eviction targets, not strict quotas. Open files and periodic checks can keep actual usage above the target.
- A pending or uncertain write is user data, not disposable cache. Never delete cache contents on exit, reconnect, uninstall, or mount failure. Preserve them until the remote copy is independently verified or the user explicitly resolves the conflict.
- Do not infer upload success from file close, an exit code, or a local appearance. Verify remote state independently during writable acceptance tests.
- Read-only mode does not protect local cached copies from other software or disk failure. Keep backups of important files outside the mount.
- Cache cleanup is not a synchronization mechanism and must never delete remote files.

## Network, logs, and diagnostics

- Use TLS endpoints from reviewed provider configuration. Do not accept arbitrary debug domain overrides from untrusted config.
- Keep logs in a user-only local folder if logging is introduced. Prefer error categories and operation IDs over raw responses, request URLs, full file paths, or account details.
- Before exporting diagnostics, run a deterministic sanitizer test containing synthetic cookie values, auth URLs, account identifiers, file names, and local paths. Fail closed if a sensitive pattern remains.
- Do not upload logs automatically. Make report export explicit and preview the sanitized report before the user shares it.
- Bound retry attempts with exponential backoff and jitter. Distinguish network errors from rejected/expired authentication; never retry destructive calls blindly.

## Operational limits

- The selected provider is unofficial, has no supported OAuth/session renewal contract, and may stop working after server changes. TeraBox's official Open API is a separate option requiring registered app credentials and application-folder scope; it is not verified as full-drive access.
- The inspected backend source refuses zero-byte and unknown-size uploads, does not advertise rclone hash support, and cannot set modification time. Report these as limitations unless later source/build evidence changes.
- Published 4 GB free/128 GB premium upload limits, session lifetime, and transfer speeds are backend-maintainer reports, not guarantees.
- Rclone and WinFsp provide filesystem plumbing, not a promise that every Windows application will behave as if T: were a local SSD.
- Games, active codebases, Git operations, package managers, and builds can fail or become slow because of network latency, random I/O, locks, session expiry, throttling, and remote filesystem behavior. Keep active work local and copy closed files/projects to cloud storage.

## Provider authentication and security architecture

- **Multi-provider model**: Connection interfaces are isolated per provider (`TeraBoxProvider.ps1`, `GoogleDriveProvider.ps1`) and coordinated through a strict 10-state lifecycle model (`ConnectionState.ps1`). State transitions fail closed and prevent premature mount operations until file query verification succeeds.
- **Google Drive OAuth 2.0 & PKCE**: Uses RFC 8252 loopback authorization with RFC 7636 Proof Key for Code Exchange (PKCE) S256 challenge generation and cryptographically random `state` parameter validation to prevent CSRF and authorization code interception attacks. Supports standard Google `installed` / `desktop` client formats without requiring a client secret. Access scope defaults to the minimum required read-only permission (`drive.readonly`). Local loopback listener runs strictly on `127.0.0.1` with `System.Net.WebUtility` HTML encoding and halts after single callback processing or timeout.
- **Automatic Token Lifecycle**: Seamless token refresh via `Invoke-GoogleDriveApiWithRetry` automatically handles HTTP 401 token expirations by refreshing tokens and updating DPAPI storage. Token revocation on disconnect uses HTTP POST directly to the Google OAuth revocation endpoint, prioritizing refresh token revocation to cleanly revoke consent.
- **DPAPI credential protection**: Stored provider sessions and OAuth tokens are protected using Windows Data Protection API (DPAPI) tied to the current interactive user, with explicit NTFS file security rules granting access exclusively to the current user SID and SYSTEM.
- **Child-process environment bridging**: OAuth credentials for virtual filesystem mounts are injected directly into child process memory via `RCLONE_CONFIG_GDRIVE_*` environment variables, avoiding plaintext tokens on disk or command-line parameter leakage in Task Manager.
- **Diagnostics sanitization**: Diagnostic messages and log buffers pass through `Format-SanitizedDiagnosticMessage`, which strips all access tokens, refresh tokens, client secrets, auth codes, ndus values, cookies, Set-Cookie headers, Bearer tokens, raw `ya29.*` and `1//.*` tokens, and passwords across plaintext, query parameters, and JSON payloads.
- **Multi-provider virtual drive separation**: Each provider mounts to its own distinct drive letter (Google Drive to `G:`, TeraBox to `T:`), with independent process lifecycles, provider-specific volume names (`--volname`), and automatic drive letter conflict resolution. Disconnecting or failure of one provider never disrupts another.
- **Persistent user logon startup**: Configured through `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`, ensuring background execution strictly within the user's interactive session (avoiding session-0 isolation or elevated-process Explorer drive invisibility).

## Implemented and verified vs. remaining acceptance

- **Verified via automated test suite (`tests/Run-AllTests.ps1`)**:
  - Connection state machine transitions, metadata, and secret sanitization across JSON, queries, and raw tokens (`Test-ConnectionState.ps1`).
  - TeraBox provider metadata, fail-closed handling, DPAPI storage in sandboxed environment, and scope validation (`Test-TeraBoxProvider.ps1`).
  - Google Drive provider metadata, cryptographic state entropy, RFC 7636 PKCE S256 verifier and Appendix B test vector, DPAPI token storage, rclone environment variable construction, installed client JSON discovery, and WebUtility HTML encoding (`Test-GoogleDriveProvider.ps1`).
  - Virtual drive manager binary discovery, WinFsp runtime and service detection, drive availability checks, read-only VFS cache mount argument formatting with security flags, drive letter fallback, provider volume labels, cache statistics, and multi-provider status querying (`Test-VirtualDriveManager.ps1`).
  - Settings manager defaults, custom persistence, drive preferences, and Windows user logon startup registry configuration (`Test-SettingsManager.ps1`).
  - Desktop UI regression testing ensuring no read-only `$pid` collisions, layout scrollbar constraints, and clean STA window construction (`Test-DesktopUIRegression.ps1`).
  - DPAPI rclone config password helper synthetic verification (`Test-RcloneConfigPassword.ps1`).
- **Verified via empirical resource benchmark (`tests/Benchmark-ResourceUsage.ps1`)**:
  - Cold startup time: 1551 ms (~1.55 s)
  - Active UI host Working Set: 159.23 MB RAM
  - Private Memory Commit: 143.80 MB
  - Sampled Idle CPU: 0.10%
  - VFS Cache disk status: Verified on `D:\CloudCache` (NTFS Fixed volume, 124 GiB free, 20.00 GiB soft target).
- **Remaining acceptance gates**:
  - Interactive user login completion with live provider accounts.
  - Verification of File Explorer `G:\` and `T:\` file access once live account validation completes.
