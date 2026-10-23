# Security and Limitations

**Status:** Production-Ready Architecture, Verified Threat Model, and Hardened Implementation.

## 1. Comprehensive Threat Model

### A. Assets Requiring Protection
- **OAuth 2.0 Credentials:** Google Drive access tokens and long-lived refresh tokens.
- **Provider Session Secrets:** TeraBox web session cookies (`ndus`, `BDUSS`), `jsToken`, and loopback bridge secrets.
- **Filesystem Integrity:** User files on the host operating system, preventing unauthorized writes, traversal, or deletion.
- **User Cloud Data:** Stored cloud files; transfers and eviction must guarantee zero accidental data loss or corruption.
- **Host System Resources:** Memory, CPU, and disk space on the OS drive (`C:`), maintaining low idle footprint and preventing drive starvation.

### B. Trust Boundaries
1. **Interactive User Session:** NS Cloud Drive runs strictly with the standard interactive user's privileges. It never requires or requests administrative elevation, preventing privilege escalation vulnerabilities.
2. **Provider Cloud Endpoints:** Google Drive APIs (`googleapis.com`) and TeraBox servers (`terabox.com`). All network communication is enforced over TLS 1.2/1.3 with certificate validation.
3. **Local Loopback Daemons:** The local CPX WebDAV bridge daemon and rclone communicate strictly over loopback (`127.0.0.1`) with dynamically generated cryptographically random DPAPI-protected bearer/basic passwords. No interfaces are bound to external network adapters.
4. **Child Process Execution:** External executables (`rclone.exe`, `cpx.exe`, `explorer.exe`) are launched using sanitized, parameter-escaped command-line arguments. User-controlled paths cannot inject arbitrary CLI flags.
5. **Local Storage & Cache:** `%LOCALAPPDATA%\NSCloudDrive` and the configured cache directory (`D:\CloudCache`). Access is restricted by private NTFS access control lists.

### C. Authentication & Session Security
- **Google Drive Native Desktop OAuth 2.0 (RFC 8252):** Employs loopback IP redirection on `127.0.0.1` with a random local port.
- **RFC 7636 PKCE:** Enforces Proof Key for Code Exchange with SHA-256 code challenge (`S256`) and cryptographically random 43-character `code_verifier`. Protects against authorization-code interception.
- **Cryptographic State Parameter:** Every OAuth flow generates a cryptographically secure random `state` token verified upon callback to defeat Cross-Site Request Forgery (CSRF).
- **DPAPI Credential Storage:** Provider tokens and session keys are encrypted at rest using Windows Data Protection API (DPAPI) scoped exclusively to `DataProtectionScope.CurrentUser`.
- **Directory & File ACL Inheritance:** Credential storage folders (`%LOCALAPPDATA%\NSCloudDrive\credentials`) and credential files enforce explicit Windows Access Control Lists (`SetAccessRuleProtection($true, $false)`) granting `FullControl` solely to the current user SID and `SYSTEM`. Directory ACLs configure `ContainerInherit` and `ObjectInherit` so newly generated credentials inherit restrictive permissions automatically.
- **Immediate Token Revocation:** Disconnecting an account triggers an immediate HTTP POST revocation request directly to Google's revocation endpoint, invalidating consent tokens on the provider side.

### D. Process Execution & Command Injection Defense
- **Win32 Argument Escaping (`Format-SafeProcessArgument`):** External process invocations format arguments adhering to Win32 command line parser rules. Quotes and backslashes preceding quotes are rigorously escaped (`\"`, `\\"`), preventing argument breakout and injection.
- **Cloud Path Traversal Normalization (`Normalize-CloudPath`):** Remote file paths undergo traversal normalization: backslashes are converted to forward slashes, control characters (`\x00`–`\x1F`, `\x7F`) are stripped, and all relative `.` and `..` segments are resolved safely. Cloud file paths cannot escape directory roots.
- **Sanitized Remote Aliases & Volume Labels:** Rclone remote names and drive volume labels are filtered through strict alphanumeric whitelists (`[^a-zA-Z0-9_\-]`), defeating flag injection into `rclone.exe mount` or `lsjson`.
- **Safe Explorer Shell Launch (`Start-ExplorerWindow`):** Windows File Explorer launches wrap paths in explicit quotes and guard against exceptions, preventing malformed paths from opening unmapped root directories.

### E. File, Cache & Operating System Protection
- **OS Drive Protection:** `Test-CacheDirectorySafety` validates that cloud caches are placed on non-OS volumes (dedicated NTFS storage recommended) and warns users if cache paths reside on `%SystemDrive%`.
- **In-Use File Lock Protection (`Test-FileInUse`):** Cache eviction and cleanup routines inspect file stream locks via `[System.IO.File]::Open(..., ReadWrite, None)`. Any file currently being read, streamed, or uploaded is strictly skipped from eviction.
- **LRU Cache Quota Bounding:** When the cache exceeds the configured quota (e.g. 20 GB default, selectable up to 200 GB), an eviction sweep removes unpinned, inactive cache chunks in Least-Recently-Used order based on `LastAccessTimeUtc`.
- **Interrupted File Recovery:** On application startup, `Invoke-StartupCacheRecovery` cleans up abandoned `.partial`, `.tmp`, and `.rclone-tmp` files without touching active cache entries.
- **Zero Local Overwrites During Transfers:** Cloud-to-cloud transfers operate in streaming relay mode via `rclone copy` / `rclone move`, piping data between cloud providers without buffering intermediate full-size files on the host operating system drive.

### F. Network & Secret Sanitization
- **Strict TLS Verification:** Native TLS certificate validation is enforced for all REST queries and provider endpoints. No certificate verification bypasses or insecure flags are permitted.
- **Multi-Pattern Diagnostic Redaction (`Format-SanitizedDiagnosticMessage`):** All exception messages, log lines, transfer status records, and diagnostic outputs pass through a deterministic secret sanitizer that redacts:
  - OAuth access tokens (`ya29.*`) and refresh tokens (`1//.*`).
  - TeraBox session cookies (`ndus=*`, `BDUSS=*`).
  - Authorization headers (`Bearer *`, `Basic *`).
  - JSON credential fields (`access_token`, `refresh_token`, `client_secret`, `password`, `code`).
  - Query parameters and request cookies (`Cookie: *`, `Set-Cookie: *`).
- **Zero Secret Output:** Diagnostics, console streams, and UI status badges never emit plain-text secrets or credential fragments.

---

## 2. Multi-Account Isolation Architecture

NS Cloud Drive supports running multiple cloud accounts concurrently with complete separation:
1. **Isolated Token Files:** Each account stores credentials in an account-specific file:
   - `google-tokens-<safeAccountId>.xml`
   - `terabox-session-<safeAccountId>.xml`
2. **Dynamic Rclone Remotes:** Mount and transfer commands dynamically allocate per-account remote aliases:
   - `RCLONE_CONFIG_<SAFEACCID>_TYPE=drive`
   - `RCLONE_CONFIG_<SAFEACCID>_TOKEN={...}`
   Eliminates collisions between multiple Google Drive or TeraBox connections.
3. **Independent Drive Letter Allocation:** Each account is mapped to its own virtual drive letter (`G:`, `T:`, `H:`, `I:`, etc.) with collision detection and automatic fallback to the next available drive letter.
4. **Independent VFS Cache Trees:** VFS cache folders are compartmentalized by account ID within the root cache directory:
   - `D:\CloudCache\<AccountId>\vfs`
5. **Independent Process Lifecycles:** Unmounting or removing one account terminates only the corresponding `rclone.exe` child process; other mounted drives continue operating without interruption.

---

## 3. Operational Limits and Known Provider Characteristics

### A. Google Drive
- **API Rate Limits:** Google Drive API v3 enforces standard per-user and per-project query quotas. The application implements exponential backoff and jitter (`Invoke-GoogleDriveApiWithRetry`) to gracefully handle HTTP 403 / 429 rate limits.
- **Shared vs. Custom Client Credentials:** By default, Google Drive discovers publisher-bundled credentials (`config/google-oauth.json`) or auto-discovers client secrets in Downloads. Users may also provide their own Google Cloud OAuth Client ID for dedicated quota.

### B. TeraBox
- **Community WebDAV Bridge:** TeraBox full-drive access operates via the local CPX WebDAV bridge daemon (`cpx.exe terabox-bridge`). TeraBox web sessions do not have a documented OAuth contract and depend on session cookies captured during legitimate login.
- **Open Platform API Limitations:** TeraBox's official Open Platform API (`open.terabox.com`) restricts third-party application access to `/From: Other Applications/<App_Name>/` rather than user root, requiring the loopback WebDAV bridge for full-drive mounting.
- **Upload File Size Bounds:** Free TeraBox accounts enforce a 4 GB single-file upload limit (128 GB for Premium accounts). The provider enforces this server-side.

### C. Virtual Filesystem (WinFsp & VFS Cache)
- **Local Application Compatibility:** While virtual drives appear in Windows File Explorer as fixed NTFS volumes (`FixedDisk`), operations with high random I/O (such as active Git repositories, large database files, or active software compilation) should remain on local SSDs, copying completed assets to cloud drives.
- **Offline Access:** Files not present in the local VFS cache require active network connectivity to stream on-demand. Cached files remain readable offline until eviction.

---

## 4. Verification and Automated Test Evidence

The security model is verified continuously by the automated test suite (`tests/Run-AllTests.ps1`) comprising 15 comprehensive test suites:
1. `Test-ConnectionState.ps1`: Fail-closed state transitions and secret sanitization across JSON, queries, and raw tokens.
2. `Test-TeraBoxProvider.ps1`: Session DPAPI persistence, strict directory ACLs, and fail-closed credential validation.
3. `Test-TeraBoxBridgeManager.ps1`: Loopback daemon configuration, DPAPI secret encryption, and WebDAV rclone environment isolation.
4. `Test-GoogleDriveProvider.ps1`: RFC 7636 PKCE S256 test vectors, loopback authorization, token isolation, and dynamic rclone remotes.
5. `Test-VirtualDriveManager.ps1`: WinFsp detection, drive conflict resolution, VFS mount argument escaping, and process lifecycle cleanup.
6. `Test-SettingsManager.ps1`: Multi-account CRUD, preferred drive letter validation, and Windows startup registry settings.
7. `Test-DesktopUIRegression.ps1`: Layout width constraints, STA window construction, and single-instance mutex handling.
8. `Test-EmbeddedBrowserWindow.ps1`: Microsoft Edge WebView2 runtime verification, isolated profile directory, and non-blocking dispatcher pump.
9. `Test-MultiAccountIsolation.ps1`: Isolation across multiple concurrent Google Drive and TeraBox accounts, remotes, and drive mappings.
10. `Test-ThemesAndAccountCustomization.ps1`: Three-theme rendering (Pure Black, Translucent, Pure White) and safe diagnostic metrics.
11. `Test-CloudTransferManager.ps1`: Streaming relay transfer, speed smoothing, zero-division protection, path traversal normalization, and argument injection defense.
12. `Test-CacheManagement.ps1`: In-use file lock protection, LRU cache eviction, OS drive detection, and startup recovery of orphaned chunks.
13. `Test-EndToEndAcceptance.ps1`: Multi-account persistence, isolated DPAPI tokens, dynamic rclone remotes, and Win32 `EmptyWorkingSet` memory trimming (168 MB down to < 10 MB).
14. `Test-WriteAndUploadVerification.ps1`: VFS full write-back, read-write default, upload verification, and live backend querying.
15. `Test-RcloneConfigPassword.ps1`: Synthetic DPAPI credential storage, private ACL enforcement, and plaintext-at-rest checks.
