# NS Cloud Drive handoff

**Reviewed:** 2026-10-22

**Repository:** `C:\Users\Naboraj_sarkar\Documents\Codex\CloudDrive` (`CloudDri` as supplied does not exist)

**Branch:** `main`; **working tree at review start:** clean; **remote:** `origin` → `https://github.com/naborajs/CloudDrive.git`

**Latest project commit before this handoff record:** `e7aea03` (`Keep mount gated on supported auth bridge`), pushed to `origin/main`.

## Current state

This is a Windows-first feasibility scaffold, not a working TeraBox drive application. The only UI is a PowerShell/WPF setup preview. It checks local prerequisites and keeps mounting disabled. There is no successful backend build, TeraBox sign-in, live account list/read, or `T:` mount.

The authentication bridge is the primary stop condition. The pinned unofficial backend requires a website cookie/`ndus`, with no documented interactive handoff or renewal. WebView2 can persist its own profile, but this does not provide a permitted backend handoff or prove API access. The official TeraBox API requires provider-issued application credentials and documents app-assigned-folder scope; access to the existing account root is not established. Do not add cookie extraction or replay, and do not present a WebView login page as a connected account.

## What is implemented

- `src/NSCloudDrive.ps1` — branded WPF preview, local setup checks, verified-build manifest/hash checks, provider-registration check, WinFsp/drive/cache diagnostics. The mount control is locked; the screen does not read credentials.
- `scripts/Build-PatchedRclone.ps1` — pins `gulp79/rclone-extra` tag `v1.75.2-extra`, commit `56bf13885494819bc801302ddf881279bdac7262`; applies the local safety patch; attempts a Windows x64 `cmount` build with `CGO_ENABLED=0`; checks target/provider and writes a manifest. **Not successfully built.**
- `patches/rclone-terabox-v1.75.2-extra-secret-safety.patch` — marks the cookie config option sensitive, removes the full-options debug trace, disables backend-specific debug, and extends normal HTTP-dump redaction for `Cookie`/`Set-Cookie`. Patch applicability/source diff checks passed; Go tests, compilation, runtime redaction and config-redaction remain unverified. Explicit auth/body dumps remain sensitive.
- `scripts/Start-ReadOnlyMount.ps1` — guarded foreground read-only mount scaffold: verifies manifest/hashes, encrypted rclone config, free `T:`, NTFS local cache volume and space; proposed cache target is 20 GiB/24 hours. It has never mounted a drive; no account config was read or tested in this audit.
- `scripts/RcloneConfigPassword.ps1` and `scripts/Test-RcloneConfigPassword.ps1` — DPAPI-backed, current-user-protected helper for the **rclone config encryption password only**, not TeraBox auth.
- `scripts/CachePathSafety.ps1` — cache path validation helper.
- `scripts/Manage-UserMountStartup.ps1` — opt-in per-user scheduled-task scaffold, gated on read-only acceptance. No task was registered; do not enable it before manual mount acceptance.
- Research, security, acceptance, compatibility, and architecture records are under `docs/`.

## Tests and build evidence

Latest successful checks recorded in `docs/COMMANDS-AND-RESULTS.md`:

- PowerShell parser checks for the build/mount/config helpers passed; this is syntax validation only.
- Cache-path validator checks passed for a normal local NTFS path and rejected unsafe representative paths.
- Synthetic DPAPI read-back and temporary ACL checks passed in the current PowerShell host; this did not test the interactive save flow or TeraBox credentials.
- The cookie-safety patch passed `git apply --check` and source `git diff --check` on the exact pinned source.
- The original cgo build helper stopped at its first guard: WinFsp `fuse.h` missing. The revised no-cgo helper stopped at `Required build tool is missing from PATH: go` without creating a build directory. Neither attempted compilation.
- A separate `AuthorizationManager check failed` occurred when launching another PowerShell process; it happened before the helper ran and is not a build result. `LocalMachine` policy was `RemoteSigned`, machine/user policies undefined. No policy was changed.

Local dependency probe: Git present; Go, MinGW GCC/G++, `rclone.exe`, WinFsp runtime DLL and checked FUSE headers absent. The current no-cgo build path needs Git and Go 1.26+; MinGW and WinFsp development headers are not build prerequisites for that path. WinFsp runtime is required for a mount. No software was installed. Do not install dependencies or make privileged changes without authorization.

## Important paths and commands

Run from the repository root in Windows PowerShell:

```powershell
# Preview only
powershell.exe -NoProfile -STA -File .\src\NSCloudDrive.ps1

# Build pinned backend (requires Git and Go 1.26+; compile is unverified)
powershell.exe -NoProfile -File .\scripts\Build-PatchedRclone.ps1

# Synthetic config-password helper checks (does not authenticate TeraBox)
powershell.exe -NoProfile -File .\scripts\Test-RcloneConfigPassword.ps1

# Manual read-only mount, only after build, supported auth, and local config are accepted
powershell.exe -NoProfile -File .\scripts\Start-ReadOnlyMount.ps1
```

Related records: `docs/FEASIBILITY.md`, `docs/SECURITY-AND-LIMITATIONS.md`, `docs/COMMANDS-AND-RESULTS.md`, `docs/MANUAL-ACCEPTANCE.md`, `docs/IMPLEMENTATION-PLAN.md`, `docs/ADR-0001-architecture.md`, and `README.md`.

## CLOUDPLAY X 0.9.15 reference investigation

The user-provided `CloudPlayX.zip` and `CloudPlayX.TeraBox.dll` attachments were inspected read-only in their temporary attachment locations. No installer, app, DLL, or bundled executable was run, and none was copied into this repository. The DLL's static assembly/file metadata identifies it as `CloudPlayX.TeraBox`, version `0.9.15.0`, product `CLOUDPLAY X`; metadata does not verify its code behavior or provenance.

**What the supplied package documents (claims, not independently executed here):**

- `ARCHITECTURE.md` describes a custom `CloudPlayX.TeraBox` component (`TeraBoxAuth`, `TeraBoxApi`, `TeraBoxWebDavBridge`), with a loopback-only WebDAV server and random DPAPI-stored Basic-auth password. rclone's standard WebDAV remote points to that bridge; rclone + WinFsp provide the Explorer drive. This is distinct from the unofficial `rclone-extra` cookie backend currently pinned by NS Cloud Drive.
- The package documents the official TeraBox Open Platform OAuth/device-code route and separately labels website-session login unofficial. `BUILD_STATUS.md` contains 0.8.0 real-account website-session claims, but also says that route is unofficial and notes possible account restriction. These claims are not proof for this repo or authorization to replay website cookies. `TERABOX_RESEARCH.md` points to `TERABOX_INTEGRATION.md`, which is absent from the supplied archive, so the detailed connector/auth implementation could not be checked.
- The package describes one content cache: rclone's sparse VFS cache. CLOUDPLAY X's Smart Cache inspects rclone range metadata and physical sparse-file usage, applies budget/free-space guards and marker-guarded eviction, and schedules predictive prefetch through the mounted drive into that same rclone cache; it says it does not maintain a second content cache.
- `docs/NATIVE_RCLONE.md` describes a custom rclone v1.75.2 patch (`v1.75.2-cloudplayx.3`) that defers hydration of missing ranges for dirty sparse files to bounded writeback workers, plus durable metadata and local progress checkpoints. The archive contains patch/tests and a bundled rclone binary, but this handoff did not rebuild or run them.
- `RELEASE_0.9.15.md` calls the candidate a preview and lists write staging, atomic metadata, progress checkpoints, and open-file safeguards. `LAUNCH_READINESS_2026-10-21.md` still says general release/gameplay is not validated and reports very slow uncached TeraBox reads in its recorded run. `BUILD_STATUS.md` and `TEST_REPORT.md` are headed 0.8.0, so versioned claims must not be merged into one assumed 0.9.15 test result.

**Unverified:** source-level correctness of the custom TeraBox DLL, WebDAV bridge security and operation coverage, exact bundled rclone build provenance, whether 0.9.15 tests were run against those exact packaged bits, and any clean-machine behavior. The archive contains no C# source entries, only compiled application assemblies and selected native patch/test material; do not add binaries to Git. Ask for the source repository/commit and complete integration docs before porting any implementation.

## Next steps — in order

1. Resolve the supported auth/scope blocker with TeraBox: obtain written developer guidance/app approval for a Windows desktop authorization flow and confirm whether it can read the existing account root. If the supported API is app-folder-only, decide whether that narrower scope is acceptable; do not simulate full-drive access.
2. Only after a supported auth route is confirmed, install Go 1.26+ from the official distribution with authorization; compile the pinned, patched backend and verify the build manifest, `windows/amd64`, `cmount`, and `terabox` provider registration. Run the Go redaction tests with synthetic values.
3. Review source/build provenance, license notices, all secret/log paths, and any CloudPlay X source offered for comparison. Do not use its cookie-based flow based only on release notes or a DLL.
4. Install WinFsp runtime with authorization. Configure auth locally through the supported flow; verify account scope before mounting. Then run `MANUAL-ACCEPTANCE.md` Gate 1 and read-only Gate 2, capture sanitized evidence, and test `T:` visibility/list/read/unmount.
5. Keep writes, cache-cleanup automation, and the sign-in startup task disabled until their separate acceptance gates pass.

Never put cookies, tokens, passwords, browser profiles, cache data, installers, or compiled binaries in Git. Preserve the one-file-per-commit-and-push workflow; inspect `git status` and the file-specific diff before each commit. Do not force-push or discard unrelated changes.
