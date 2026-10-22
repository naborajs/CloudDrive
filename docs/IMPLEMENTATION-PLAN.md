# NS Cloud Drive: Windows implementation plan

## What has been verified so far

- This repository is a clean Windows-first application project on `main`.
- Windows PowerShell 5.1 with WPF is available on the development PC; the desktop preview script parses successfully.
- The PC currently has no `rclone.exe`, Go toolchain, .NET SDK, or WinFsp installation, so no mount or backend integration has been run.
- Upstream rclone documents Windows mounting through WinFsp and supports network-drive mode. Its full VFS cache mode supports random reads, but its size and age cleanup are periodic; open cache files cannot be evicted and limits can be exceeded temporarily.
- The TeraBox implementations inspected are unofficial. The `rclone-extra` backend documents cookie-based authentication and includes a configurable debug level that can emit request and response detail. That means logs must be treated as potentially sensitive until audited and redacted.
- `morluto/rea` is a reverse-engineering toolkit for lawful research, not a TeraBox storage connector or a required dependency. Do not use it to bypass authentication, CAPTCHA, quotas, or access controls.

### Current phase gate (2026-10-22)

The original cgo pinned-source builder was run and reproduced a preflight failure before it created a build directory or cloned anything: `WinFsp FUSE development header fuse.h was not found under: C:\Program Files (x86)\WinFsp\inc\fuse`. Review then found that the pinned source uses `github.com/winfsp/cgofuse` and both rclone and cgofuse document Windows `!cgo` mounting builds. The project builder now sets `CGO_ENABLED=0`, so it no longer needs MinGW or WinFsp development headers to compile. The local machine still lacks Go and the WinFsp runtime DLL; Git is present, and the .NET SDK is irrelevant. The revised helper was syntax-checked and safely stops because Go is missing; no compilation has occurred. No software was installed.

The pinned `gulp79/rclone-extra` tag and source patch are identified, and patch application had passed on the exact tag. The tag's own Windows workflow uses Go 1.26.x, MinGW, WinFsp v2.1 headers, cgo, and `cmount`; its repository-owned workflow has not been edited. The local project builder now uses the official no-cgo route because the pinned dependency version is cgofuse and the current rclone/cgofuse guidance documents it for Windows. This exact fork build still needs a real compile before it is considered validated. The Windows release ZIP has a published checksum but no verified artifact signature/build attestation in the evidence collected, so it is not accepted as a trusted prebuilt.

The backend requires a website cookie/`ndus`, transmits it in the Cookie header, and has no supported interactive login or renewal path. Its level-1 setup debug call includes the complete options struct. A source patch addresses the debug disclosure path but is uncompiled and has not passed synthetic-secret or config-redaction tests. Authentication is therefore not ready for account testing, even if a source build succeeds. Do not request or handle session credentials to unblock development.

## Architecture

Keep the Windows application split into these replaceable parts:

1. **Desktop UI** — branded connection state, drive controls, cache status, diagnostics, and clear pending-upload warnings.
2. **Provider adapter** — provider-specific configuration and safe operations. TeraBox implementation remains isolated because it is unofficial and could stop working independently of the UI.
3. **Mount manager** — starts, observes, and stops the filesystem process; uses WinFsp/rclone only after the selected backend passes acceptance checks.
4. **Cache manager** — one per-user cache root, explicit capacity and age policy, free-space warning, and protection against cleaning files with uncertain upload state.
5. **Session store** — no secrets in source, command-line arguments, logs, crash reports, or UI diagnostics. Prefer an audited interactive provider flow and Windows Credential Manager/DPAPI protection where supported. Verify how the backend consumes credentials before shipping; rclone config obfuscation alone is not encryption.

Keep the provider and filesystem layers independent of the desktop UI so another desktop provider can be added later. Mobile is out of scope.

## Delivery phases

### 1. Feasibility and dependency checks

- Pin exact upstream and backend commits; review license, build provenance, update activity, authentication path, and all debug/logging paths.
- Build the backend from reviewed source in a reproducible Windows environment. Do not accept an unverified third-party executable as trusted.
- The current cgo-free builder needs Go 1.26 or newer and Git; no MinGW compiler or WinFsp Developer headers are required to compile. Install a current Go Windows x64 release from [go.dev/dl](https://go.dev/dl/) only when authorized. WinFsp runtime is still required before mounting; its official MSI is available at [winfsp.dev](https://winfsp.dev/rel/). No dependency installation is authorized/performed by this project run.
- In a fresh PowerShell, verify `go version`, then run `powershell.exe -NoProfile -File .\scripts\Build-PatchedRclone.ps1` from the repository root. The helper pins source/patch, builds `windows/amd64` with `cmount`, and must report `terabox` in the built provider list. Do not treat the official no-cgo guidance as proof the exact fork compiles; keep the compile outcome as a required test.
- Run the pinned builder and require all its checks: expected source commit, patch applicability, `windows/amd64`, `cmount`, `terabox` provider registration, and build manifest/hash. Record syntax checks, build success, and any later runtime tests as distinct evidence.
- Verify the built executable's provider list reports the backend and determine whether its config flow can avoid copying session cookies manually.
- Treat this as an explicit auth gate: the current cookie-only backend has no approved/reliable session acquisition and renewal design for this application. Do not continue to account tests merely because a backend-enabled executable was built. Reassess only if the maintainer/backend documents a permitted flow that can be implemented without credential copying, log exposure, or process-argument exposure, or if a documented official API scope is accepted for a separate provider.
- Keep the app's mount action disabled until backend source review and local acceptance are complete.

### 2. Read-only mount proof

- Blocked until both a verified backend-enabled Windows build and a permitted local authentication configuration exist. WinFsp installation, drive-letter readiness, account browsing, and file-read tests have not been reached. Do not schedule startup or test write operations while this gate remains open.
- Install WinFsp from its official distribution channel in a disposable Windows test profile, then use only the project-verified backend-enabled build for the mount proof.
- Configure a test remote locally; never put credentials in this repository, screenshots, chat, or logs.
- Start a read-only `T:` mount in the signed-in user's session, using a dedicated cache directory and a unique process identity.
- Test Explorer listing, nested folders, metadata, small and large file reads, partial/random reads, offline behavior, disconnects, and clean unmount.
- Capture sanitized diagnostics and record exact Windows, WinFsp, rclone, and backend versions.

### 3. Safe write and cache validation

- Only after read-only acceptance, use a disposable test folder for create, overwrite, rename, move, delete, zero-byte files, interrupted upload, and restart recovery tests.
- Treat rclone cache caps as best-effort eviction targets, not hard quotas: the documented cache poll interval and open files can allow temporary overage.
- Do not automatically delete cache contents on exit or uninstall. First prove all writes reached the remote; preserve the cache and warn if upload state is uncertain.
- Add a safe-stop flow that stops accepting writes, waits for pending transfers, reports unresolved items, and unmounts without force-killing the filesystem process.

### 4. Desktop integration and sign-in persistence

- Replace this PowerShell preview with a maintained Windows desktop implementation after the mount/backend boundary is proven. Keep the UI unable to read raw credential files or dump provider configuration.
- Add tray/status behavior, mount health checks, cache usage, reconnect controls, and clear offline/pending-write indicators.
- Make startup opt-in and per-user. Start after sign-in and network availability, and display failure state instead of silently retrying forever. Do not run as SYSTEM or create a machine-wide service for a user's session drive.
- Test sleep/resume, network changes, sign-out, multiple sessions, drive-letter conflicts, shutdown, and app upgrades.

### 5. Packaging and release

- Pin and document dependency versions, licenses, checksums, and source links. Sign the app and installer where feasible.
- Build on a clean Windows machine and verify install, upgrade, uninstall, credential removal, cache preservation, and recovery behavior.
- Publish only after the acceptance matrix passes; label unofficial TeraBox support and its limits plainly.

## Initial settings to validate

| Setting | Starting proposal | Guardrail |
| --- | --- | --- |
| Drive letter | `T:` | Detect conflicts and let the user choose later |
| First access mode | Read-only | Do not enable writes until test phase 3 passes |
| VFS cache mode | `full` | Enables random access, but consumes local disk space |
| Cache root | `%LOCALAPPDATA%\\NSCloudDrive\\Cache` | Per-user, outside the repository |
| VFS cache size | 20 GiB | Best-effort target; warn before local disk becomes low |
| Cache age | 24 hours | Age eviction does not mean data was safely uploaded |
| Startup | Off by default | Opt-in per-user sign-in after manual acceptance |

## Current preview

`src/NSCloudDrive.ps1` is a WPF setup preview. It can check whether rclone is on `PATH`, whether common WinFsp installation markers exist, and whether an rclone build lists a TeraBox provider. It does not mount a drive, configure an account, access a session, or establish that the backend works.

## References

- [rclone mount on Windows and VFS caching](https://rclone.org/commands/rclone_mount/)
- [rclone `config providers`](https://rclone.org/commands/rclone_config_providers/)
- [WinFsp](https://winfsp.dev/)
- [REA reverse-engineering toolkit](https://github.com/morluto/rea)
- [Unofficial TeraBox backend source](https://github.com/Temkina/rclone-extra/tree/master/backend/terabox)
- [Unofficial backend documentation](https://github.com/Temkina/rclone-extra/blob/master/docs/content/terabox.md)
- [Alternative QR-login TeraBox fork](https://github.com/mill-master/rclone-terabox)
