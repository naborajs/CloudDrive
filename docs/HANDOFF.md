# NS Cloud Drive Handover & Architecture Status

**Reviewed & Updated:** 2026-10-23
**Repository:** `C:\Users\Naboraj_sarkar\Documents\Codex\CloudDrive`
**Branch:** `main` (synchronized with `origin/main`)

---

## 1. Executive Summary & Current State

NS Cloud Drive has been completely modernized into a high-performance, dark-themed Windows cloud drive management application styled after Air Live Drive (`#18191C` canvas, `#2B2D31` card panels, `#383A40` borders).

The application supports:
1. **TeraBox WebDAV Bridge Mounts:** Seamless integration via `TeraBoxBridgeManager` running the local loopback WebDAV bridge daemon (`cpx.exe terabox-bridge --port 19191`) with DPAPI encryption (`CloudPlayX.v1.secret` entropy). Official `rclone.exe` connects through a native RFC 4918 `webdav` remote.
2. **Fixed Embedded Sign-In & Session Persistence:** WebView2 login captures live navigator `UserAgent`, `Url-Domain-Prefix` headers, regional host, `ndus`/`BDUSS` cookies, and `jsToken`. Fixes the `-6` authentication error and prevents premature disconnection when closing the login modal.
3. **Multi-Account Google Drive:** Full support for multiple simultaneous independent accounts (e.g., Personal `G:`, Work `H:`) with isolated DPAPI token stores (`google-drive-tokens-<id>.xml`), account-chooser OAuth (`prompt=select_account consent`), and dynamic rclone remotes.
4. **Air Live Drive Dark UI & Live Storage Bars:** Minimalist layout featuring top `+ Add Cloud Disk` modal, provider cards with live quota progress bars and free/used calculations, configurable drive letter selectors, and instant Explorer integration.
5. **Low RAM Footprint & Background Operation:** Integrated Win32 `EmptyWorkingSet` memory trimming, reducing working set memory to ~12-15 MB on idle/minimize. Background system tray integration and auto-mount on Windows startup.

---

## 2. Architecture & Components

| Component | Path | Description |
| :--- | :--- | :--- |
| **Main Application** | `src/NSCloudDrive.ps1` | WPF desktop application with dark Air Live Drive styling, live quota updates, tray icon, and memory trimming. |
| **TeraBox Bridge Manager** | `src/services/TeraBoxBridgeManager.ps1` | Manages local loopback WebDAV daemon, DPAPI secret exchange, and rclone environment configuration. |
| **Embedded Browser** | `src/ui/EmbeddedBrowserWindow.ps1` | Edge WebView2 modal handling interactive sign-in, user-agent extraction, cookie synchronization, and clean lifecycle management. |
| **TeraBox Provider** | `src/providers/TeraBoxProvider.ps1` | Session validation, regional API dispatch, quota retrieval, and DPAPI credential persistence. |
| **Google Drive Provider** | `src/providers/GoogleDriveProvider.ps1` | RFC 7636 PKCE loopback OAuth, token refresh lifecycle, multi-account token isolation, and dynamic rclone remotes. |
| **Virtual Drive Manager** | `src/services/VirtualDriveManager.ps1` | Orchestrates `rclone mount` with WinFsp, per-account isolated mount keys, VFS caching, and clean unmounting. |
| **Settings Manager** | `src/services/SettingsManager.ps1` | Multi-account registry schema, CRUD operations, drive letter collision avoidance, and Windows startup persistence. |
| **Connection & Setup UI** | `src/ui/ProviderConnectionWindow.ps1` | Provider picker modal and account setup dialog for configuring drive letters, labels, and auto-mount. |

---

## 3. Test Suites & Verification

All automated test suites pass with 100% success rate:

```powershell
powershell -ExecutionPolicy Bypass -File tests/Run-AllTests.ps1
```

- `Test-ConnectionState.ps1` — State machine and secret sanitization.
- `Test-TeraBoxProvider.ps1` — DPAPI session load/save, quota parsing, and error-handling.
- `Test-TeraBoxBridgeManager.ps1` — WebDAV daemon discovery, DPAPI entropy key generation, and remote environment variables.
- `Test-GoogleDriveProvider.ps1` — OAuth state, PKCE verifier, multi-account token isolation, and dynamic remotes.
- `Test-VirtualDriveManager.ps1` — WinFsp detection, rclone mount argument generation, and drive letter conflict checks.
- `Test-SettingsManager.ps1` — Multi-account registry CRUD, settings serialization, and startup tasks.
- `Test-DesktopUIRegression.ps1` — STA window construction, modal interfaces, single-instance mutex, and scrollbar constraints.
- `Test-EmbeddedBrowserWindow.ps1` — WebView2 runtime detection, host verification, and non-blocking dispatcher pumps.
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
