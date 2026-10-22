# Security and limitations

**Status:** Security design and known risks; no account credential has been used in this project.

## Current security posture

- The only current app code is a WPF preview. It does not read rclone configuration, sign in, request secrets, or mount a drive.
- All TeraBox implementations reviewed are unofficial. The inspected backend relies on a web-session token, not an official OAuth integration.
- In the reviewed backend, the `cookie` field is required but not marked sensitive. The backend constructor's level-1 debug statement formats the full options struct, which contains that cookie. Higher debug levels are documented to include request/response parameters or bodies.
- A patch is committed for the pinned `v1.75.2-extra` source: it marks the cookie option sensitive, removes the options-struct debug statement, and disables backend-specific debug output. It has only passed patch-application checks; it has not been compiled or tested with synthetic credentials.
- The QR-login helper prevents manual cookie copying but writes the obtained session token to the ordinary rclone config. That does not establish safe at-rest storage or Windows compatibility.
- No account was authenticated, no user files were listed, and no remote file operation was executed.

## Secret-handling requirements before adding sign-in

1. Compile the pinned patch and add tests proving a synthetic secret never appears in logs, exceptions, config-redacted output, or diagnostics. The current patch is not yet a security guarantee.
2. Prefer a user-confirmed QR/device authorization flow. If only cookie copy is available, keep sign-in unavailable; do not ask for or collect a cookie through chat, a script, an issue, or a screenshot.
3. Store the session under the current Windows user's Credential Manager or DPAPI-protected storage. Do not store it in Git, ordinary settings JSON, command-line arguments, environment that persists beyond the child process, telemetry, or crash dumps.
4. If a reviewed backend must receive a session through a process environment variable, decrypt it only in memory immediately before process start, set it only in the child environment, clear the parent copy, and verify child logs/process diagnostics do not export it. This is a design option, not implemented or verified here.
5. Keep app settings and secret storage separate. Restrict config/diagnostic ACLs to the current user and SYSTEM. Protect the device and cache volume with BitLocker where available.
6. Never run the user's mount as SYSTEM. The interactive user's drive visibility and secret scope are more important than a background service abstraction.
7. Keep backend debug level zero. Avoid raw rclone config dumps and `--dump` diagnostics. Treat third-party error strings, request URLs, remote names, and file names as sensitive until a synthetic-secret sanitization test proves otherwise.
8. Reauthenticate only through a user-initiated provider flow. Do not bypass authentication, CAPTCHA, access controls, quotas, rate limits, or other provider protections.

## Cache and data integrity

- The VFS cache contains local content, including potentially sensitive user files. Default it to the user's `D:\CloudCache\TeraBox` only after checking that D: is available, NTFS, writable, and has enough free space.
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

- This provider is unofficial, has no supported OAuth/session renewal contract, and may stop working after server changes.
- The inspected backend source refuses zero-byte and unknown-size uploads, does not advertise rclone hash support, and cannot set modification time. Report these as limitations unless later source/build evidence changes.
- Published 4 GB free/128 GB premium upload limits, session lifetime, and transfer speeds are backend-maintainer reports, not guarantees.
- Rclone and WinFsp provide filesystem plumbing, not a promise that every Windows application will behave as if T: were a local SSD.
- Games, active codebases, Git operations, package managers, and builds can fail or become slow because of network latency, random I/O, locks, session expiry, throttling, and remote filesystem behavior. Keep active work local and copy closed files/projects to cloud storage.

## Not implemented or not verified

- No secure sign-in or session renewal implementation.
- The backend patch exists, but has not been compiled; no synthetic-secret logging or config-redaction test has run.
- No mount manager, health-state machine, or clean-unmount implementation.
- No cache usage reporting or pending-write state tracking.
- No startup task/service has been created.
- No remote account, Explorer drive, read, write, interruption, eviction, or recovery behavior has been tested.

Do not describe NS Cloud Drive as a functioning TeraBox mount until the corresponding evidence is recorded in [the acceptance plan](MANUAL-ACCEPTANCE.md) and [the command record](COMMANDS-AND-RESULTS.md).
