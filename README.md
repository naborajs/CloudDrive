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
  1. Click **Add Cloud Disk** -> select **Google Drive**.
  2. Click **Sign in with Google** to launch 1-click authorization via rclone's verified desktop client with full read-write scope (`drive`). No Google Cloud Project or client ID configuration is required for standard users. (Optional custom Google Cloud client ID/secret is also supported).
  3. The authorization handler validates user identity via root Drive metadata (`/files/root`), applies rate-limit backoff, retrieves storage quota via API/rclone, and stores DPAPI-encrypted tokens.
  4. Mounts to drive `G:` (or user preference) as **Google Drive** with read-write Explorer access.
  5. Supports multiple simultaneous Google accounts (e.g. Personal `G:` and Work `H:`) with isolated token storage.

- **TeraBox connection flow**:
  1. Click **Connect TeraBox** or **Add Cloud Disk** -> **TeraBox**.
  2. The embedded Edge WebView2 authentication window opens.
  3. Complete sign-in normally. NS Cloud Drive automatically extracts session parameters (`ndus`, `BDUSS`, `jsToken`, User-Agent, and regional API endpoints) without exposing credentials.
  4. The session is validated against `/api/check/login` and stored in current-user DPAPI storage.
  5. The local WebDAV bridge daemon (`cpx.exe terabox-bridge --port 19191`) is started with DPAPI-encrypted shared secret.
  6. Mounts to drive `T:` (or user-chosen drive letter) in read-write mode with `--vfs-cache-mode full` and `--vfs-write-back 5s`. Files can be created, edited, copied, and streamed directly in Windows Explorer.

- **Independent Multi-Drive Mounts**:
  - Both providers and multiple accounts can be mounted simultaneously to separate drive letters.
  - Active mounts are reconciled across application restarts via process inspection (`Find-ActiveMountProcess`).
  - Clean unmount controls terminate rclone and WinFsp cleanly without deleting cached files.

## Running the Automated Test Suite

To run all automated regression tests across the state machine, provider adapters, virtual drive manager, settings manager, UI layout constraints, DPAPI credential helpers, and live provider validation:

```powershell
powershell.exe -NoProfile -File .\tests\Run-AllTests.ps1
```

All 11 test suites verify:
- Connection state lifecycle, transitions, and secret sanitization across JSON, queries, and raw tokens (`Test-ConnectionState.ps1`).
- TeraBox provider metadata, fail-closed handling, DPAPI persistence, regional host failover, and strict mode parsing (`Test-TeraBoxProvider.ps1`).
- TeraBox WebDAV bridge discovery, DPAPI entropy key generation, and remote environment variables (`Test-TeraBoxBridgeManager.ps1`).
- Google Drive provider metadata, PKCE verifiers, fail-closed handling, multi-account token isolation, and 1-click desktop authorization (`Test-GoogleDriveProvider.ps1`).
- Virtual drive manager rclone binary discovery, WinFsp detection, drive availability, read-write mount arguments, active process reconciliation, and volume labeling (`Test-VirtualDriveManager.ps1`).
- Settings manager defaults, custom persistence, drive preferences, placeholder account purging, and Windows user logon startup registry configuration (`Test-SettingsManager.ps1`).
- Desktop UI regression: non-conflicting parameter names, explicit horizontal scrollbar constraints, single-instance mutex, and clean STA window initialization (`Test-DesktopUIRegression.ps1`).
- Embedded WebView2 runtime detection, host verification, and non-blocking dispatcher pumps (`Test-EmbeddedBrowserWindow.ps1`).
- End-to-end acceptance: multi-account token isolation, dynamic remotes, virtual drive status isolation, and Win32 `EmptyWorkingSet` memory trimming (`Test-EndToEndAcceptance.ps1`).
- Write protection prevention, direct upload verification, and live provider account integrity (`Test-WriteAndUploadVerification.ps1`).
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

### Option 1 — Quick Launch (Double-Click or CMD)

Double-click `NSCloudDrive.cmd` directly in Windows File Explorer, or run from Command Prompt:

```cmd
.\NSCloudDrive.cmd
```

### Option 2 — PowerShell Terminal

From the project root directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\src\NSCloudDrive.ps1
```

Or from any folder using the full path:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "C:\Users\Naboraj_sarkar\Documents\Codex\CloudDrive\src\NSCloudDrive.ps1"
```

Or start minimized to the System Tray:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\src\NSCloudDrive.ps1 -Minimized
```

## Pinned backend build helper

[`scripts/Build-PatchedRclone.ps1`](scripts/Build-PatchedRclone.ps1) builds a Windows x64 executable from the pinned `gulp79/rclone-extra` source tag and applies the repository's cookie-safety patch. It refuses to reuse an existing build folder and verifies the executable reports both `cmount` and the `terabox` provider.

```powershell
powershell.exe -NoProfile -File .\scripts\Build-PatchedRclone.ps1
```

## License

License terms will be selected and documented before distributing application binaries or source derived from third-party projects.
