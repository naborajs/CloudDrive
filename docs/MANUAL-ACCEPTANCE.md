# Manual acceptance plan

**Status:** Not run. This is a test plan, not evidence that a TeraBox mount works.

Use a disposable folder and non-important test files in the account. Keep the app read-only until every read test passes. Do not paste session cookies, passwords, or raw configuration into chat, source files, logs, or bug reports.

## Gate 0: source, build, and local prerequisites

- [ ] Pin the backend source commit and record its license notices and build tool versions.
- [ ] Verify session settings are marked sensitive and synthetic credentials do not appear in logs, exceptions, debug output, crash reports, or sanitized support exports.
- [ ] Build a Windows binary with the TeraBox backend and Windows mount support from reviewed source; record its SHA-256.
- [ ] Install WinFsp from its official source and verify the version.
- [ ] Verify `rclone config providers` lists `terabox` without displaying configuration values.
- [ ] Confirm the cache volume is NTFS, has adequate free space, and is not a reparse point or shared/network folder.
- [ ] Confirm T: is unused and the mount will run non-elevated in the intended interactive Windows account.

Do not attempt authentication if any of the security/build checks fail.

## Gate 1: user-controlled local authentication

- [ ] Use only a user-confirmed provider login flow. Do not manually export/copy browser cookies.
- [ ] Keep the login local to the signed-in user. Do not print the credential or config content.
- [ ] Verify the app stores or bridges the session only through the reviewed Windows-protected mechanism; check file ACLs without copying the secret.
- [ ] Verify canceling login stores no partial credential and creates no mount.
- [ ] Verify a sanitized diagnostic does not contain the credential, auth URL parameters, account identifiers, or personal file names.

If the reviewed backend only supports cookie copying, stop and report the limitation instead of asking the user to paste a cookie.

## Gate 2: read-only mount

- [ ] Start the mount as `T:` in read-only mode, non-elevated, with `D:\CloudCache\TeraBox` and a 20 GiB best-effort size target.
- [ ] Verify the app reports `ReadOnlyMounted` only after T: is visible in the same user's File Explorer session and a remote health/list probe succeeds.
- [ ] Browse root and nested folders, including Unicode names, duplicate-looking names, directories with many entries, and files with unusual extensions.
- [ ] Compare metadata displayed by Explorer with the TeraBox web/app view; record known limitations for modtime/hash.
- [ ] Open and read a small disposable file, then independently compare its contents to the source.
- [ ] Read a larger test file within the backend's documented size limits. Compare content independently; note that the published size and throughput limits are maintainer-reported.
- [ ] Test partial/random reads by seeking within a large file. Verify only requested data is transferred on demand and record cache behavior.
- [ ] Confirm the remote cannot be modified through T: in read-only mode.
- [ ] Disconnect/reconnect the network during listing and reading. Confirm clear offline state, bounded retry, and recovery without duplicate mounts.
- [ ] Close files and cleanly unmount. Verify Explorer releases T: and the cache remains intact.

## Gate 3: disposable writable operations

Run only after Gate 2 passes and the backend credential/logging gate is closed. Use a dedicated empty test directory and independently inspect remote state after each operation.

- [ ] Upload a nonempty small file; wait for completion and read it back remotely. Compare content.
- [ ] Overwrite an existing disposable file; verify which copy is present remotely and whether any temporary duplicate remains.
- [ ] Create and remove an empty directory.
- [ ] Rename and move a file; independently verify source/destination names.
- [ ] Move a directory and verify its full contents.
- [ ] Delete a disposable file; verify whether it is in TeraBox trash. Do not enable permanent deletion by default.
- [ ] Test duplicate-name/conflict behavior and ensure the UI reports conflicts rather than silently overwriting valuable data.
- [ ] Test Unicode and long-but-valid file names.
- [ ] Record unsupported behavior, including zero-byte and unknown-length uploads if still rejected by the selected backend.

## Gate 4: interruption, recovery, and cache safety

- [ ] Interrupt network access during a read; verify the app reports failure and retries only after connectivity returns.
- [ ] Interrupt a disposable upload after local close; verify the local staged file remains and the app reports pending/uncertain state.
- [ ] Exit or restart the app with a pending write. Verify the cache/config are reused and the app does not delete staged data.
- [ ] Verify remote state independently before marking a write complete.
- [ ] Fill the cache toward its configured target, close handles, and observe age/size eviction. Verify open/pending files remain protected and understand temporary overage.
- [ ] Verify cache cleanup only removes confirmed cache entries, never remote objects, pending writes, partial uploads, or the whole cache root.
- [ ] Test low disk space and full-disk handling without losing staged data.

## Gate 5: auth expiry and persistence

Only perform session-expiry testing through a supported user-controlled revoke/re-login flow. Do not corrupt or expose a live session to simulate expiry.

- [ ] Confirm an expired/revoked session becomes `NeedsReauthentication`, not an infinite retry loop.
- [ ] Reauthenticate locally and verify the same mount recovers without displaying a secret.
- [ ] Repeat launch, mount, stop, and restart to verify idempotence and no duplicate T: mounts.
- [ ] Test sleep/resume, network changes, sign-out, multiple user sessions, and T: conflicts.
- [ ] Only after all previous gates pass, enable optional per-user sign-in startup; verify it waits for network, uses the same account/config, and reports failures visibly.
- [ ] Remove startup opt-in and uninstall; confirm credentials are removed only with explicit user intent and cache/pending data is preserved.

## Acceptance record

| Test | Date | Windows / WinFsp / backend build | Result | Sanitized evidence location | Notes |
| --- | --- | --- | --- | --- | --- |
| | | | Not run | | |
