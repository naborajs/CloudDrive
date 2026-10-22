# NS Cloud Drive

**NS Cloud Drive** is a Windows desktop-first project for accessing cloud files through native virtual drives in File Explorer, with on-demand reads, bounded local caching, and persistent background operation.

> **Development status:** Multi-provider architecture with native Google Drive (OAuth 2.0 PKCE, drive `G:`) and TeraBox feasibility integration (drive `T:`), verified WinFsp userspace filesystem mounts, and low-resource System Tray operation.

## Product direction

- **File Explorer is the Primary Interface**: Open folders, inspect files, copy, paste, and stream on-demand directly in Windows Explorer without needing to use a custom file-transfer UI.
- **Separate Native-Looking Drives**: Each connected provider mounts to its own distinct Windows drive letter with an intuitive volume label (e.g. `Google Drive (G:)` and `TeraBox (T:)`), independent mount lifecycles, and automatic drive letter conflict resolution.
- **Real Cloud Capacity Reporting**: Live display of provider storage quota (used space, total space, percentage used, remaining space) and distinct local cache disk usage.
- **On-Demand VFS Caching**: 20 GiB soft-target LRU cache on fixed NTFS (`D:\CloudCache`) avoids full-drive pre-downloads and protects pending writes.
- **Persistent Connections Across Restarts**: Per-user logon startup and automatic mount recovery in the user's interactive Windows session.
- **Low RAM and CPU Consumption**: Background System Tray operation with throttled idle timers (~159 MB working set, 0.1% idle CPU).

## Cloud Account Connection and Virtual Drives

NS Cloud Drive supports connecting both **Google Drive** and **TeraBox** accounts through a dedicated desktop interface with explicit connection validation:

- **Google Drive connection flow**:
  1. Configure your Google OAuth client ID and optional secret via environment variables (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`) or standard Google desktop client JSON at `%LOCALAPPDATA%\NSCloudDrive\config\google-oauth.json`.
  2. Click **Connect Google Drive** from the main dashboard.
  3. Click **Sign in with Google** to launch the official Google OAuth 2.0 flow in the system browser using an RFC 8252 loopback callback on `127.0.0.1` protected by RFC 7636 PKCE S256 challenge generation.
  4. The local listener cryptographically verifies the `state` parameter to prevent CSRF attacks.
  5. The authorization code is exchanged for tokens with minimum necessary read-only scope (`drive.readonly`).
  6. File querying and user quota are validated via Google Drive API v3 (`/about`, `/files`), and tokens are stored in current-user DPAPI storage with automatic token refresh retries.
  7. Mounts to drive `G:` (or user preference) as **Google Drive**.

- **TeraBox connection flow**:
  1. Click **Connect TeraBox** from the main dashboard.
  2. The dedicated connection window opens explaining the authentication method and truthful feasibility disclosure.
  3. The user opens the legitimate TeraBox website and completes authentication personally.
  4. Manual session tokens are validated against `/api/check/login` and stored in current-user DPAPI storage.
  5. Mounts to drive `T:` (or user preference) as **TeraBox** using the patched, verified rclone binary.

- **Independent Multi-Drive Mounts**:
  - Both providers can be mounted simultaneously to separate drive letters.
  - A failure or disconnect in one provider never drops or disrupts the other.
  - Clean unmount controls terminate rclone and WinFsp cleanly without deleting cached files.

## Running the Automated Test Suite

To run all automated regression tests across the state machine, provider adapters, virtual drive manager, settings manager, UI layout constraints, and DPAPI credential helpers:

```powershell
powershell.exe -NoProfile -File .\tests\Run-AllTests.ps1
```

All 7 test suites verify:
- Connection state lifecycle, transitions, and secret sanitization across JSON, queries, and raw tokens (`Test-ConnectionState.ps1`).
- TeraBox provider metadata, fail-closed handling, DPAPI persistence in sandboxed storage, and scope checking (`Test-TeraBoxProvider.ps1`).
- Google Drive provider metadata, cryptographic state entropy, RFC 7636 PKCE S256 verifiers, fail-closed handling, DPAPI persistence, rclone environment variable construction, OAuth client configuration discovery, and auth URL formatting with validation (`Test-GoogleDriveProvider.ps1`).
- Virtual drive manager rclone binary discovery, WinFsp detection, drive availability, mount argument formatting with security flags, next available drive letter allocation, distinct provider volume labels, cache statistics, and multi-provider virtual drive status querying (`Test-VirtualDriveManager.ps1`).
- Settings manager defaults, custom persistence, drive preferences, and Windows user logon startup registry configuration (`Test-SettingsManager.ps1`).
- Desktop UI regression: non-conflicting parameter names (avoiding read-only `$PID`), explicit horizontal scrollbar constraints to prevent WPF layout overflow, and clean STA window initialization (`Test-DesktopUIRegression.ps1`).
- DPAPI config-encryption password storage, private ACLs, and plaintext absence (`Test-RcloneConfigPassword.ps1`).

## Resource & Performance Benchmark

To measure and record real-world memory, CPU utilization, startup speed, and cache status:

```powershell
powershell.exe -NoProfile -File .\tests\Benchmark-ResourceUsage.ps1
```

Empirical benchmarks measured on Windows 11 (AMD Ryzen 9 8940HX, 16 cores / 32 threads, 16 GB RAM):
- **Cold Startup Time**: 1551 ms (~1.55 s)
- **Idle Working Set RAM**: 159.23 MB
- **Idle Private Memory**: 143.80 MB
- **Idle CPU Utilization**: 0.10%
- **Host VFS Cache**: `D:\CloudCache` on NTFS Fixed volume with 124 GiB free; 20.00 GiB soft target.

## Launching the Application

On Windows, open PowerShell and run:

```powershell
powershell.exe -NoProfile -STA -File .\src\NSCloudDrive.ps1
```

Or start minimized to the System Tray:

```powershell
powershell.exe -NoProfile -STA -File .\src\NSCloudDrive.ps1 -Minimized
```

## Pinned backend build helper

[`scripts/Build-PatchedRclone.ps1`](scripts/Build-PatchedRclone.ps1) builds a Windows x64 executable from the pinned `gulp79/rclone-extra` source tag and applies the repository's cookie-safety patch. It refuses to reuse an existing build folder and verifies the executable reports both `cmount` and the `terabox` provider.

```powershell
powershell.exe -NoProfile -File .\scripts\Build-PatchedRclone.ps1
```

## License

License terms will be selected and documented before distributing application binaries or source derived from third-party projects.
