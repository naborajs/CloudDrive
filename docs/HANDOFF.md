# NS Cloud Drive Handover & Architecture Status

**Reviewed & Updated:** 2026-10-23 (Phase 3 Cloud-to-Cloud Transfers, Minimal Cache & Live Network Statistics)
**Repository:** `C:\Users\Naboraj_sarkar\Documents\Codex\CloudDrive`
**Branch:** `main` (synchronized with `origin/main`)

---

## 1. Executive Summary & Capabilities

NS Cloud Drive has been completely modernized into an ultra-clean, production-ready Windows cloud drive management application inspired directly by Air Live Drive. Phase 3 implements reliable cloud-to-cloud file transfers between connected accounts, minimal and in-use protected local caching, and accurate real-time network transfer metrics, building upon Phase 1's fixed disk mounts and Phase 2's 3-theme interface.

### Core Capabilities:
1. **Cloud-to-Cloud Streaming Transfers (Google Drive ↔ TeraBox & Multi-Account):**
   - **Interactive Transfer Dialog (`Show-CloudTransferModal`):** Accessible via the "+ Transfer Files" toolbar button in the Disks view.
   - **Dual Cloud Explorer:** Left-side source account/directory browser with file sizes, right-side destination account/directory browser.
   - **Streaming Relay Architecture:** Streams file data in bounded memory chunks (4–8 MiB) directly between source and destination HTTP connections without writing full temporary files to the local OS drive.
   - **Supported Directions:** Google Drive to TeraBox, TeraBox to Google Drive, and transfers between multiple Google Drive or TeraBox accounts.
   - **Truthful Operation Transparency:** Explicitly labels transfers as "Streaming Relay" (`IsServerSide = $false`) rather than fabricating non-existent cross-provider server-side copy support.
   - **Conflict Handling:** Supports `Skip existing files` (default/recommended) and `Overwrite`.
   - **Pause, Resume, and Cancel:** Native Win32 thread suspension (`NtSuspendProcess`) and resumption (`NtResumeProcess`) allows pausing and resuming active transfers without killing the process or corrupting the stream. Clean cancellation terminates processes cleanly.
2. **Accurate Real-Time Network & Transfer Statistics:**
   - **Speed Smoothing (Exponential Moving Average):** Smooths noisy network spikes using $\alpha = 0.25$ ($\text{EMA}_t = \alpha \cdot \text{Speed}_t + (1 - \alpha) \cdot \text{EMA}_{t-1}$) to display stable, trustworthy throughput rates.
   - **Accurate Division-by-Zero Protected ETA:** Calculates realistic remaining time from remaining bytes and smoothed speed. Suppresses ETA until sufficient throughput data is collected, and shows indeterminate progress when total file size is unknown.
   - **Live Progress Reporting:** Emits real-time bytes transferred, total size, percentage, elapsed duration, throughput, and error counters parsed directly from rclone's structured 500ms JSON stats feed.
3. **Cache Management & OS Drive Protection:**
   - **In-Use File Protection (`Test-FileInUse`):** Automatically tests exclusive file handles before eviction. Files currently held by active `rclone mount` processes, media players, or in-progress transfers are strictly protected and never deleted.
   - **Configurable Cache Location & Safety Checks (`Test-CacheDirectorySafety`):** Users can select any custom folder on secondary fixed storage. Detects and warns if the cache is placed on the operating system drive (`C:`) or low-space volumes.
   - **LRU Size Eviction & Inactivity Cleanup (`Invoke-SafeCacheCleanup`):** Automatically purges oldest-accessed evictable files when the configured quota (`10 GB`, `20 GB`, `50 GB`, `100 GB`) is reached.
   - **Startup Recovery (`Invoke-StartupCacheRecovery`):** Automatically cleans up orphaned temporary partial chunks (`.partial`, `.rclone-tmp`, `*~`) left behind by unexpected system reboots or application crashes.
   - **Manual "Clean Cache" Action:** Reclaims non-locked cache files immediately and truthfully reports: `Cleaned X MB (Y files). Z files protected in-use.`
4. **Three Native Themes (Pure Black, Translucent, Pure White):**
   - High-contrast OLED Pure Black (`#000000`), Dark Acrylic Glass Translucent (`#13161CE6`), and Clean Light Pure White (`#F8FAFC`).
5. **Phase 1 & 2 Mount Stability:**
   - Fixed Disk local mounting (no network redirector "red X" or `FUSE-rclone` issues).
   - Local loopback WebDAV bridge for TeraBox (`cpx.exe terabox-bridge --port 19191`) with DPAPI encryption.
   - Multi-account isolation for Google Drive and TeraBox.
   - Ultra-low idle RAM (~10-15 MB on minimize via Win32 `EmptyWorkingSet`).

---

## 2. Architecture & Components

| Component | Path | Description |
| :--- | :--- | :--- |
| **Main Application** | `src/NSCloudDrive.ps1` | WPF desktop application with 3-theme engine, Air Live Drive navigation, account cards, transfer action, cache settings, and memory trimming. |
| **Cloud Transfer Manager** | `src/services/CloudTransferManager.ps1` | Manages streaming relay transfers between remotes, rclone JSON stats monitoring, speed smoothing, ETA calculations, and pause/resume. |
| **Cache Manager** | `src/services/CacheManager.ps1` | In-use file lock detection (`Test-FileInUse`), LRU cache quota enforcement, OS drive safety checks, and startup recovery. |
| **Connection & Setup UI** | `src/ui/ProviderConnectionWindow.ps1` | Themed modal dialogs: `Show-CloudTransferModal`, `Show-AddCloudDiskModal`, `Show-CloudAccountSetupModal`, `Get-ModalThemePalette`. |
| **Settings Manager** | `src/services/SettingsManager.ps1` | Multi-account registry, 3-theme resolution (`Resolve-AppTheme`), cache quota policies, and Windows startup management. |
| **Virtual Drive Manager** | `src/services/VirtualDriveManager.ps1` | Orchestrates read-write `rclone mount` with WinFsp fixed disk mode, active mount reconciliation, VFS full caching, and clean unmounting. |
| **TeraBox Bridge Manager** | `src/services/TeraBoxBridgeManager.ps1` | Manages local loopback WebDAV daemon, DPAPI secret exchange, and rclone environment configuration. |
| **Embedded Browser** | `src/ui/EmbeddedBrowserWindow.ps1` | Edge WebView2 modal handling interactive sign-in, user-agent extraction, cookie synchronization, and clean lifecycle management. |
| **TeraBox Provider** | `src/providers/TeraBoxProvider.ps1` | Session validation, regional API dispatch, quota retrieval, and DPAPI credential persistence. |
| **Google Drive Provider** | `src/providers/GoogleDriveProvider.ps1` | One-click rclone desktop OAuth, token refresh lifecycle, multi-account token isolation, and dynamic rclone remotes. |

---

## 3. Test Suites & Verification

All 15 automated test suites pass with 100% success rate:

```powershell
powershell -ExecutionPolicy Bypass -File tests/Run-AllTests.ps1
```

- `Test-ConnectionState.ps1` — State machine and secret sanitization.
- `Test-TeraBoxProvider.ps1` — DPAPI session load/save, quota parsing, and error-handling.
- `Test-TeraBoxBridgeManager.ps1` — WebDAV daemon discovery, DPAPI entropy key generation, and remote environment variables.
- `Test-GoogleDriveProvider.ps1` — OAuth state, PKCE verifier, multi-account token isolation, and dynamic remotes.
- `Test-VirtualDriveManager.ps1` — WinFsp detection, rclone mount argument generation (read-write default & fixed disk), and drive letter conflict checks.
- `Test-SettingsManager.ps1` — Multi-account registry CRUD, settings serialization, placeholder purge, and startup tasks.
- `Test-DesktopUIRegression.ps1` — STA window construction, modal interfaces, single-instance mutex, and scrollbar constraints.
- `Test-EmbeddedBrowserWindow.ps1` — WebView2 runtime detection, host verification, and non-blocking dispatcher pumps.
- `Test-MultiAccountIsolation.ps1` — Multi-account credential isolation, WebView2 profiles, bridge homes, and truthful drive states.
- `Test-ThemesAndAccountCustomization.ps1` — 3-theme palette generation, runtime theme switching in STA, account customization field preservation, and diagnostics safety.
- `Test-CloudTransferManager.ps1` — Streaming relay remote mapping, speed smoothing (EMA), division-by-zero protected ETA, transfer lifecycle, and data integrity.
- `Test-CacheManagement.ps1` — In-use file lock detection, detailed statistics, LRU size quota eviction, OS drive safety warnings, and startup partial recovery.
- `Test-EndToEndAcceptance.ps1` — Multi-account token isolation, WebDAV environment, drive status isolation, and memory trimming (~10 MB working set).
- `Test-WriteAndUploadVerification.ps1` — Read-write mount arguments, upload verification, and live account integrity.
- `Test-RcloneConfigPassword.ps1` — DPAPI encryption and access control verification.

---

## 4. Launching the Application

From repository root:
```cmd
.\NSCloudDrive.cmd
```
or via PowerShell:
```powershell
powershell.exe -NoProfile -STA -File .\src\NSCloudDrive.ps1
```
