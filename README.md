# NS Cloud Drive

**NS Cloud Drive** is a Windows desktop-first project for accessing cloud files through a virtual drive in File Explorer, with on-demand reads and bounded local caching.

> **Development status:** early feasibility and implementation stage. No TeraBox account has been connected, no backend has been verified against a live account, and no mount is currently claimed to work.

## Product direction

- Windows desktop app with a clear drive and connection status.
- Virtual-drive integration through a supported Windows userspace filesystem layer.
- On-demand access instead of copying the whole cloud account locally.
- Bounded cache with protection for pending or uncertain writes.
- Explicit transfer/synchronization state, diagnostics, and optional per-user sign-in startup.
- Modular provider and mount-manager boundaries so other desktop providers can be added later. Mobile is not in scope for this project.

## TeraBox feasibility

TeraBox support is being investigated through an unofficial rclone backend. The upstream contribution is not part of official rclone, and source-level operations do not prove account compatibility or reliable file behavior. No credentials are stored in this repository. Do not send cookies, passwords, or session tokens in issues or chats.

See the research and acceptance plan in the project documentation as it is added. A real mount will only be described as working after backend registration, read-only browsing, file reads, and File Explorer visibility have been tested on Windows. Writes and startup persistence require separate tests.

## Safety and intended use

Use a cloud drive for photos, videos, documents, archives, installers, backups, and closed project copies. A cloud mount is not equivalent to a local SSD. Games, active codebases, Git operations, builds, and package managers may be unreliable due to network latency, throttling, session expiry, file locking, and provider filesystem behavior. Keep active work local and copy it to cloud storage when closed.

## Cloud Account Connection and Virtual Drive

NS Cloud Drive supports connecting both **TeraBox** and **Google Drive** accounts through a dedicated desktop interface with explicit connection validation:

- **TeraBox connection flow**:
  1. Click **Connect TeraBox** from the main dashboard.
  2. The dedicated connection window opens explaining the authentication method.
  3. The user opens the legitimate TeraBox website and completes authentication personally.
  4. Click **I've signed in — Connect** to trigger genuine backend validation (`/api/check/login`), account scope verification, and root directory file listing.
  5. The account appears as connected only after backend verification succeeds.

- **Google Drive connection flow**:
  1. Configure your Google OAuth client ID and secret via environment variables (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`) or JSON configuration at `%LOCALAPPDATA%\NSCloudDrive\config\google-oauth.json`.
  2. Click **Connect Google Drive** from the main dashboard.
  3. Click **Sign in with Google** to launch the official Google OAuth 2.0 flow in the system browser using an RFC 8252 loopback callback on `127.0.0.1`.
  4. The local listener cryptographically verifies the `state` parameter to prevent CSRF attacks.
  5. The authorization code is exchanged for tokens with minimum necessary read-only scope (`drive.readonly`).
  6. File querying is validated via Google Drive API v3 (`/files`), and tokens are stored in current-user DPAPI storage.

- **Virtual Drive Mount**:
  - Once a provider connection is validated, the virtual drive can be mounted as `T:` in read-only mode with full on-demand VFS caching (20 GiB best-effort cap on fixed NTFS).
  - Unmount controls cleanly stop the mount process without deleting cached files.

## Running the Automated Test Suite

To run all automated regression tests across the state machine, provider adapters, virtual drive manager, UI layout constraints, and DPAPI credential helpers:

```powershell
powershell.exe -NoProfile -File .\tests\Run-AllTests.ps1
```

All 6 test suites verify:
- Connection state lifecycle, transitions, and secret sanitization (`Test-ConnectionState.ps1`).
- TeraBox provider metadata, fail-closed handling, DPAPI persistence, and scope checking (`Test-TeraBoxProvider.ps1`).
- Google Drive provider metadata, cryptographic state entropy, fail-closed handling, DPAPI persistence, OAuth client configuration discovery, and auth URL formatting with validation (`Test-GoogleDriveProvider.ps1`).
- Virtual drive manager rclone binary discovery, WinFsp detection, drive availability, and mount argument formatting (`Test-VirtualDriveManager.ps1`).
- Desktop UI regression: non-conflicting parameter names (avoiding read-only `$PID`), explicit horizontal scrollbar constraints to prevent WPF layout overflow, and clean STA window initialization (`Test-DesktopUIRegression.ps1`).
- DPAPI config-encryption password storage, private ACLs, and plaintext absence (`Test-RcloneConfigPassword.ps1`).

## Development preview

On Windows, open PowerShell and run:

```powershell
powershell.exe -NoProfile -STA -File .\src\NSCloudDrive.ps1
```

The preview needs Windows PowerShell 5.1 with WPF. **Check setup** looks for the project build, verifies its source/patch/build manifest and executable hashes before checking provider registration, reports WinFsp markers, T: availability, and whether the cache volume is NTFS with at least 25 GiB free. An rclone executable found only on `PATH` is reported but not run. These are local checks only; provider registration does not prove login or file access. The mount button is deliberately locked. No account credentials are requested or read.

The preview has only been syntax-checked on the development PC. Its UI and prerequisite detection have not yet been acceptance-tested on a clean Windows install. Do not install an unofficial binary from an unknown source.

## Pinned backend build helper

[`scripts/Build-PatchedRclone.ps1`](scripts/Build-PatchedRclone.ps1) builds a Windows x64 executable from the pinned `gulp79/rclone-extra` source tag and applies the repository's cookie-safety patch. It refuses to reuse an existing build folder and verifies the executable reports both `cmount` and the `terabox` provider. It does not install prerequisites, configure an account, or test a live TeraBox connection.

The pinned source requires Go 1.26 or newer. The project helper builds its Windows `cmount` target with `CGO_ENABLED=0`; the pinned source uses cgofuse, whose Windows no-cgo mode is documented by [rclone](https://rclone.org/install/) and [cgofuse](https://github.com/winfsp/cgofuse). This removes MinGW and WinFsp FUSE development headers from the local build prerequisites. WinFsp itself is still required at runtime to mount the filesystem. The pinned upstream workflow uses a separate cgo-enabled MinGW build; the project helper does not copy that workflow and this exact no-cgo build still requires a successful compile before it is considered verified. See also the [pinned backend workflow](https://github.com/gulp79/rclone-extra/blob/v1.75.2-extra/.github/workflows/build.yml).

After installing Go from a source you trust, run the helper from the repository root:

```powershell
powershell.exe -NoProfile -File .\scripts\Build-PatchedRclone.ps1
```

The helper needs Git (already present in this environment) and Go 1.26 or newer; it does not require MinGW or WinFsp Developer headers. The resulting files are kept under `%LOCALAPPDATA%\NSCloudDrive\builds\rclone-extra-v1.75.2-extra`. Its `rclone.build.json` records the source commit, Go version, cgo mode, patch hash, executable hash, target, build tag, and backend. The revised helper passes PowerShell syntax and missing-Go preflight checks, but has not compiled the pinned source. A successful build must report `windows/amd64`, `cmount`, and the registered `terabox` provider. Account login, Explorer mounting, file reads, and writes remain unverified.

## Read-only mount test

After a successful build and after a TeraBox remote has been configured locally with rclone's encrypted configuration, start the manual read-only test:

```powershell
powershell.exe -NoProfile -File .\scripts\Start-ReadOnlyMount.ps1
```

The launcher verifies the build manifest and file hashes, checks that T: is free and the cache volume is NTFS with at least 25 GiB free, confirms the rclone configuration is encrypted and decryptable, then runs rclone visibly in the signed-in user's session. It uses the local DPAPI helper below to unlock the config without prompting twice or putting the unlock password in command-line arguments. Press Ctrl+C in that window to unmount. It does not write remotely, create a startup task, or delete cache files.

### Optional local config unlock

After an encrypted rclone config has been prepared locally, you can store its **config-encryption password** for the current Windows account:

```powershell
powershell.exe -NoProfile -File .\scripts\RcloneConfigPassword.ps1 -Store
```

The password is entered through a hidden prompt and exported as a current-user DPAPI-protected PowerShell credential under `%LOCALAPPDATA%\NSCloudDrive\credentials`, with an ACL limited to that user and SYSTEM. The launcher supplies it to rclone through its documented password-command interface. This is a convenience for unlocking the encrypted rclone file; it does not create a TeraBox login, store a TeraBox cookie, prove the backend works, or create a startup task. A process or attacker already running as the same Windows user may still be able to use or retrieve the credential. To remove it, delete `rclone-config.xml` from that folder while the mount is stopped.

To run the synthetic helper regression checks without using an account credential:

```powershell
powershell.exe -NoProfile -File .\scripts\Test-RcloneConfigPassword.ps1
```

No compliant sign-in flow for the unofficial cookie-based backend has been established yet. Do not paste session values into chat, scripts, logs, or this repository. The launcher is scaffolding for a later locally configured and reviewed test; a successful script parse or build is not proof that a live T: mount works.

### Optional sign-in startup

After the backend and local authentication pass the manual read-only acceptance checks, the per-user task can be registered explicitly:

```powershell
powershell.exe -NoProfile -File .\scripts\Manage-UserMountStartup.ps1 -Enable -ReadOnlyAcceptancePassed
```

This registers a limited, interactive-user logon task for the **read-only** mount. It does not start the task immediately, run as SYSTEM, or elevate. The task has up to three scheduled retries if startup fails. To remove the task:

```powershell
powershell.exe -NoProfile -File .\scripts\Manage-UserMountStartup.ps1 -Remove
```

The task has not been registered or tested on this PC. It does not prove network reconnect behavior; connection recovery and visible failure reporting remain acceptance work. Do not enable it until the documented live read-only checks pass.

## License

License terms will be selected and documented before distributing application binaries or source derived from third-party projects.
