# Security and Limitations

**Status:** Security notes for an experimental PowerShell/WPF preview. This is not a security certification or a production-readiness claim.

The repository has synthetic and structural regression tests, but no penetration test, clean-install review, external rclone/CPX binary audit, or live-provider/mount acceptance. A scoped security-review agent found no vulnerabilities in the changes it reviewed; that result does not cover every product component or external dependency.

## 1. Threat Model and Verification Boundaries

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
- **Directory & File ACLs:** Credential storage uses protected ACLs intended to grant `FullControl` to the current user SID and `SYSTEM`. ACL changes use Windows .NET access-control APIs and are applied before credentials are written; failures stop the save. Synthetic tests verify the resulting ACLs on this Windows host.
- **Token revocation:** Disconnect attempts Google's revocation endpoint, but the request is best-effort. Network/provider failure is not proof that the token was revoked remotely.

### D. Process Execution & Command Injection Defense
- **Win32 Argument Escaping (`Format-SafeProcessArgument`):** External process invocations format arguments adhering to Win32 command line parser rules. Quotes and backslashes preceding quotes are rigorously escaped (`\"`, `\\"`), preventing argument breakout and injection.
- **Cloud Path Traversal Normalization (`Normalize-CloudPath`):** Remote file paths undergo traversal normalization: backslashes are converted to forward slashes, control characters (`\x00`–`\x1F`, `\x7F`) are stripped, and all relative `.` and `..` segments are resolved safely. Cloud file paths cannot escape directory roots.
- **Sanitized Remote Aliases & Volume Labels:** Rclone remote names and drive volume labels are filtered through strict alphanumeric whitelists (`[^a-zA-Z0-9_\-]`), defeating flag injection into `rclone.exe mount` or `lsjson`.
- **Safe Explorer Shell Launch (`Start-ExplorerWindow`):** Windows File Explorer launches wrap paths in explicit quotes and guard against exceptions, preventing malformed paths from opening unmapped root directories.

### E. File, Cache & Operating System Protection
- **OS Drive Protection:** `Test-CacheDirectorySafety` validates that cloud caches are placed on non-OS volumes (dedicated NTFS storage recommended) and warns users if cache paths reside on `%SystemDrive%`.
- **In-Use File Lock Protection (`Test-FileInUse`):** The cleanup helper checks for an exclusive read/write lock before deleting a file. This is not a complete guarantee for pending uploads, remote writes, or every open-handle pattern.
- **Cache eviction:** `Invoke-SafeCacheCleanup` and startup recovery now restrict traversal to recognized provider/account cache namespaces. Eviction remains locally destructive within those namespaces and still requires isolated testing with real mount/cache behavior.
- **Interrupted File Recovery:** Startup recovery checks temporary-file patterns under those recognized provider/account cache directories; it does not scan the whole configured cache root.
- **Zero Local Overwrites During Transfers:** Cloud-to-cloud transfers operate in streaming relay mode via `rclone copy` / `rclone move`, piping data between cloud providers without buffering intermediate full-size files on the host operating system drive.

### F. Network & Secret Sanitization
- **TLS:** Source checks found no configured certificate-validation bypass in the reviewed scripts. This does not independently verify every external binary or network path.
- **Multi-Pattern Diagnostic Redaction (`Format-SanitizedDiagnosticMessage`):** All exception messages, log lines, transfer status records, and diagnostic outputs pass through a deterministic secret sanitizer that redacts:
  - OAuth access tokens (`ya29.*`) and refresh tokens (`1//.*`).
  - TeraBox session cookies (`ndus=*`, `BDUSS=*`).
  - Authorization headers (`Bearer *`, `Basic *`).
  - JSON credential fields (`access_token`, `refresh_token`, `client_secret`, `password`, `code`).
  - Query parameters and request cookies (`Cookie: *`, `Set-Cookie: *`).
- **Redaction limits:** Sanitization covers common formats and headers; it cannot guarantee that every provider-specific secret or malformed diagnostic is redacted.

---

## 2. Multi-Account Isolation Architecture

The implementation is designed to isolate accounts, and synthetic tests cover parts of that boundary. Live concurrent-provider isolation is not verified:
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
5. **Independent Process Lifecycles:** Account-scoped process ownership and disconnect behavior have mocked regression coverage. Real simultaneous account mount/unmount behavior has not been verified here.

Do not infer concurrent TeraBox support from Google account isolation tests. TeraBox depends on an unofficial backend and its independent-session behavior has not been confirmed against multiple real accounts.

---

## 3. Operational Limits and Known Provider Characteristics

### A. Google Drive
- **API Rate Limits:** Google Drive API v3 enforces standard per-user and per-project query quotas. The application implements exponential backoff and jitter (`Invoke-GoogleDriveApiWithRetry`) to gracefully handle HTTP 403 / 429 rate limits.
- **Shared vs. Custom Client Credentials:** By default, Google Drive discovers publisher-bundled credentials (`config/google-oauth.json`) or auto-discovers client secrets in Downloads. Users may also provide their own Google Cloud OAuth Client ID for dedicated quota.

### B. TeraBox
- **Community backend:** The TeraBox path depends on unofficial session-based components. No live TeraBox authorization or mount was validated, and no support claim should be inferred.
- **Open Platform API limitations:** The official API requires provider-issued credentials and is documented as restricting application access to an app-specific folder. It is not verified as a replacement for full-drive access.

### C. Virtual Filesystem (WinFsp & VFS Cache)
- **Integration status:** Mount arguments and readiness checks have regression coverage, but drive visibility, Windows filesystem behavior, reconnects, and transfers were not tested against a real provider in this validation.
- **Offline access:** Files not in a provider/cache layer generally require network access. Offline-read guarantees have not been tested.

---

## 4. Verification Evidence and Gaps

The following automated regression test suites are permanently passing in the Windows environment (`Set-StrictMode -Version Latest`):

- `Test-VirtualDriveManager.ps1`: 14/14 checks pass; mount arguments, FixedDisk allocation, UNC cleanup, and volume labels verified.
- `Test-SettingsManager.ps1`: isolated CRUD, malformed-settings preservation, and settings-write regression checks pass.
- `Test-BackendCorrectnessAndSync.ps1`: 4/4 suites pass; staged upload discovery, cancellation freeze, inactivity TTL, and TeraBox 4.0 GB limit verified.
- `Test-CacheManagement.ps1`: in-use file lock protection (`Test-FileInUse`), LRU eviction under quota, and directory boundary enforcement pass.
- `Test-CloudTransferManager.ps1`: EMA speed smoothing, bounded ETA math, streaming relay, and path traversal sanitization pass.
- `Test-OptionsPage.ps1`: 47/47 checks pass; options controls, dynamic theming, and memory trimming verified.
- `Test-SecurityAudit.ps1`: 25/25 checks pass; DPAPI ACL enforcement, OAuth CSRF state verification, secret redaction, and registry safety pass.

All source code files pass PowerShell AST syntax parsing (0 syntax errors across all 49 files) and strict ASCII encoding validation (0 non-ASCII bytes in `src/NSCloudDrive.ps1`). Standalone 64-bit launcher `NSCloudDrive.exe` is compiled and verified with SHA-256 checksum tracking.


The full `Run-AllTests.ps1` suite was not run because mount/provider processes were active. No real Google account, TeraBox account, Explorer filesystem operation, upload/download, clean installation, or Windows packaging test was performed. `Test-EndToEndAcceptance.ps1`'s working-set trim call is not an idle-memory benchmark and does not establish a memory target.

The read-only process snapshot found no running NS Cloud Drive UI process, so application startup/idle RAM and CPU could not be measured. The observed `rclone`/`cpx` processes are required mount/provider processes and were left untouched. These observations are not comparable before/after measurements.
