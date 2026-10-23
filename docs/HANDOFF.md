# NS Cloud Drive Handover & Architecture Status

**Reviewed & Updated:** 2026-10-23 (Phase 2 Redesign & Resource Optimization)
**Repository:** `C:\Users\Naboraj_sarkar\Documents\Codex\CloudDrive`
**Branch:** `main` (synchronized with `origin/main`)

---

## 1. Executive Summary & Phase 2 Enhancements

NS Cloud Drive has been completely modernized into an ultra-clean, production-ready Windows cloud drive management application inspired directly by Air Live Drive. Phase 2 introduces a native three-theme engine, in-place account customization, dedicated documentation, safe system diagnostics, and optimized background resource management while preserving 100% of the Phase 1 fixed disk mounting, multi-account isolation, and WebDAV bridge capabilities.

The application delivers:
1. **Three Native Themes (Pure Black, Translucent, Pure White):**
   - **Pure Black:** High-contrast deep black surfaces (`#000000` canvas, `#080808` sidebar, `#0E0E10` cards, `#FFFFFF` crisp primary text, `#9E9E9E` secondary text). Ideal for OLED screens and dark-mode focus.
   - **Translucent:** Restrained dark acrylic glass style with native alpha transparency (`#13161CE6` canvas, `#0E1117D8` sidebar, `#1A1E29CC` cards, `#94A3B8` secondary text). Degrades gracefully on all Windows builds without external heavy libraries.
   - **Pure White:** Clean light theme (`#F8FAFC` canvas, `#F1F5F9` sidebar, `#FFFFFF` cards with `#E2E8F0` separators, `#0F172A` high-contrast dark charcoal text).
   - Dynamic live switching in the UI without restarting the application; theme choice persists in `settings.json`.
2. **Air Live Drive User Experience & Navigation Sidebar:**
   - Left navigation sidebar (66px width) with one-click view switching (`Disks`, `Options`, `Help`).
   - Cloud disk cards matching reference UX: 3D hard drive graphic with overlaid provider logo badge, bold account identity, direct `Connect` / `Disconnect` action buttons, in-line drive letter selector (`in [ G: v ]`), quick action icon buttons (📁 Explorer, ⚙ Account Options, ⬆ Upload, ✕ Remove), storage usage progress bars with "X free of Y" display, and truthful real-time status pills (`● Mounted (G:)`, `● Ready to connect`, `● Disconnected`, `● Mounting...`, `● Disconnecting...`).
3. **In-Place Account Customization Modal:**
   - Clicking the ⚙ icon on any cloud disk card opens the dedicated `Show-CloudAccountSetupModal`.
   - Allows renaming display names (e.g. "Work Google Drive" or "Personal Media"), reassigning drive letters, toggling auto-mount, toggling auto-opening Windows File Explorer on connect, and toggling Read-Only filesystem mode.
   - Updates account metadata cleanly via `Update-CloudAccount` without touching account IDs, OAuth tokens, DPAPI credentials, or backend remotes.
4. **Comprehensive Options View:**
   - General preferences: Windows login auto-start, minimize to tray on close, start minimized, auto-mount on startup, auto-open Explorer on mount.
   - Appearance & Themes card: Instant radio-button theme selection between Pure Black, Translucent, and Pure White.
   - Cache Management policy: Configurable maximum cache quota (`10 GB`, `20 GB`, `50 GB`, `100 GB`), live cache usage metrics, clean cache button, and open cache directory shortcut.
   - Diagnostics & System Health: One-click memory trimming and safe system diagnostics modal.
5. **Dedicated Help & Information View:**
   - Embedded documentation view covering Quick Start, Security & DPAPI encryption, Provider capabilities, and Performance architecture.
6. **Safe System Diagnostics Modal:**
   - Real-time diagnostics displaying Process ID (`$PID`), working set RAM, private memory, thread count, WinFsp driver status, rclone engine path, active mount mapping, and cache volume usage.
   - Strict secret exclusion: Tokens, authorization codes, cookies, and secrets are strictly excluded and never displayed or logged.
   - Live "Trim Working Set" action triggering Win32 `EmptyWorkingSet`.
7. **Ultra-Low Resource Footprint & Background Operation:**
   - Working set memory trims to ~10-15 MB on idle and window minimization.
   - Low-frequency health polling: 4-second checks when window is visible, relaxed 30-second checks when running minimized in the background.
   - No continuous remote file enumerations or busy polling loops.
8. **Preserved Phase 1 Mounting & Isolation Integrity:**
   - Native Fixed Disk local mounting (no network redirector "red X" or `FUSE-rclone` issues).
   - TeraBox local loopback WebDAV bridge (`cpx.exe terabox-bridge --port 19191`) with DPAPI encryption.
   - Multi-account isolation for Google Drive and TeraBox with isolated WebView2 user data folders, token files, and bridge directories.

---

## 2. Architecture & Components

| Component | Path | Description |
| :--- | :--- | :--- |
| **Main Application** | `src/NSCloudDrive.ps1` | WPF desktop application with 3-theme engine, Air Live Drive navigation, account cards, diagnostics modal, tray integration, and memory trimming. |
| **Connection & Setup UI** | `src/ui/ProviderConnectionWindow.ps1` | Themed modal dialogs: `Show-AddCloudDiskModal`, `Show-CloudAccountSetupModal`, `Get-ModalThemePalette`. |
| **Settings Manager** | `src/services/SettingsManager.ps1` | Multi-account registry, 3-theme resolution (`Resolve-AppTheme`), cache quota policies, and Windows startup management. |
| **Virtual Drive Manager** | `src/services/VirtualDriveManager.ps1` | Orchestrates read-write `rclone mount` with WinFsp fixed disk mode, active mount reconciliation, VFS full caching, and clean unmounting. |
| **TeraBox Bridge Manager** | `src/services/TeraBoxBridgeManager.ps1` | Manages local loopback WebDAV daemon, DPAPI secret exchange, and rclone environment configuration. |
| **Embedded Browser** | `src/ui/EmbeddedBrowserWindow.ps1` | Edge WebView2 modal handling interactive sign-in, user-agent extraction, cookie synchronization, and clean lifecycle management. |
| **TeraBox Provider** | `src/providers/TeraBoxProvider.ps1` | Session validation, regional API dispatch, quota retrieval, and DPAPI credential persistence. |
| **Google Drive Provider** | `src/providers/GoogleDriveProvider.ps1` | One-click rclone desktop OAuth, token refresh lifecycle, multi-account token isolation, and dynamic rclone remotes. |

---

## 3. Test Suites & Verification

All 13 automated test suites pass with 100% success rate:

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
