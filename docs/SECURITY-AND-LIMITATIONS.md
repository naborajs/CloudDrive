# Security and limitations

**Status:** Security design and known risks; no account credential has been used in this project.

## Current security posture

- The WPF preview does not read rclone configuration, sign in, request secrets, or mount a drive. Separate PowerShell scripts now inspect an encrypted config and start a read-only mount, but they have not run against a real backend.
- The selected rclone TeraBox backend is unofficial and relies on a web-session token, not TeraBox's official OAuth integration. TeraBox documents an official QR/device-code flow for separately registered applications, but its API is scoped to an application-assigned folder; access to the user's existing full-drive root has not been established.
- In the reviewed backend, the `cookie` field is required but not marked sensitive. The backend constructor's level-1 debug statement formats the full options struct, which contains that cookie. Higher debug levels are documented to include request/response parameters or bodies.
- A patch is committed for the pinned `v1.75.2-extra` source: it marks the cookie option sensitive, removes the options-struct debug statement, and disables backend-specific debug output. It has only passed patch-application checks; it has not been compiled or tested with synthetic credentials.
- A pinned-source Windows build helper and a read-only mount launcher are committed. The launcher checks the build manifest and hashes, requires an encrypted/decryptable rclone config, uses a 20 GiB best-effort cache, sets backend debug to zero, and runs in the current user session. Both scripts are syntax/preflight-tested only; no executable or mount exists on this PC.
- `scripts/RcloneConfigPassword.ps1` is designed to locally store the **rclone config-encryption password** as a current-user DPAPI-protected PowerShell credential, with an ACL for that user and SYSTEM. The launcher supplies it through rclone's documented password-command feature and disables interactive fallback. This is not TeraBox authentication and does not store or acquire a TeraBox cookie. A synthetic DPAPI read-back, plaintext-absence check, ACL application to a temporary directory/file, and missing-credential fail-closed check passed in the current PowerShell host. The interactive `-Store` prompt and separate Windows PowerShell subprocess are unverified; the latter was blocked by this environment's `AuthorizationManager` restrictions.
- `scripts/Manage-UserMountStartup.ps1` defines opt-in registration/removal for a limited, interactive-user logon task. Registration requires a matching build, encrypted config, and an explicit read-only acceptance flag. The task has not been registered; its behavior and reconnect handling are unverified.
- The third-party QR helper is not TeraBox's documented Open API device-code flow: it imitates browser headers against website login endpoints, extracts ndus, passes it as an rclone config command-line argument, and stores it in ordinary config. It is not compatible with this project's no-browser-impersonation and secret-handling requirements; we did not run it.
- No account was authenticated, no user files were listed, and no remote file operation was executed.

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

## Not implemented or not verified

- No compliant TeraBox sign-in or session renewal implementation. The backend's cookie-based setup is blocked; the DPAPI helper protects only the separate rclone config-encryption password.
- The backend patch exists, but has not been compiled; no synthetic-secret logging or config-redaction test has run.
- The DPAPI helper's synthetic read-back and temporary ACL checks passed in the current host, but the interactive save flow, native PowerShell subprocess, encrypted-config mount path, and actual rclone password-command integration have not been tested.
- No mount manager, health-state machine, or clean-unmount implementation.
- No cache usage reporting or pending-write state tracking.
- No startup task/service has been created.
- The startup task manager exists but has not registered a task or been tested; the explicit acceptance gate is not evidence that the read-only acceptance tests passed.
- No remote account, Explorer drive, read, write, interruption, eviction, or recovery behavior has been tested.

Do not describe NS Cloud Drive as a functioning TeraBox mount until the corresponding evidence is recorded in [the acceptance plan](MANUAL-ACCEPTANCE.md) and [the command record](COMMANDS-AND-RESULTS.md).
