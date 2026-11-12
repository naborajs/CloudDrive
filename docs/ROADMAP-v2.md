# NS Cloud Drive — Version 2.0 Engineering Roadmap & Architecture Specification

**Document Version:** 2.0.0-DRAFT  
**Author:** NABORAJ SARKAR & AI Orchestra  
**Target Release:** NS Cloud Drive v2.0.0  
**Repository:** `C:\Users\Naboraj_sarkar\Documents\Codex\CloudDrive`  
**Base Stable Tag:** `v1.0.0` (Commit `2559d0c`)  

---

## 1. Executive Summary & Vision

**NS Cloud Drive v1.0.0** successfully established a rock-solid, production-grade virtual filesystem daemon for Windows 10/11 x64, mounting Google Drive and TeraBox accounts into Windows File Explorer with live capacity meters, on-demand streaming, and resilient background transfer queues.

**Version 2.0** elevates NS Cloud Drive into an enterprise-grade autonomous multi-cloud and remote workstation. The defining capabilities of Version 2.0 include:

1. **VPS SSH / SFTP Remote Server Integration**: Direct SSH/SFTP connection to user-owned VPS instances (e.g. where AI agents, remote builds, or servers reside). Mount remote filesystems as native Windows drive letters (e.g. `V:`) with WinFsp / rclone SFTP, enabling frictionless bidirectional massive file transfers between local workstation, remote agents, and cloud drives.
2. **Proton Drive Integration**: Native zero-knowledge encrypted cloud storage integration using SRP / rclone `protondrive` backend.
3. **Microsoft OneDrive & Multi-Cloud Expansion**: Native Microsoft Graph / rclone OAuth integration.
4. **Autonomous Agent & Headless Pipeline**: Programmatic transfer endpoints, folder watching, and high-speed streaming transfers.
5. **Cross-Platform Roadmap (Linux First)**: Portable CLI daemon and FUSE mounting for Linux environments, followed by macOS in future milestones.
6. **Strict 1:1 GitHub Commit & Push Protocol**: Every single modified file is committed and pushed individually to GitHub `main` with granular attribution.

```
+---------------------------------------------------------------------------------------------------+
|                                  NS Cloud Drive v2.0 Workstation                                  |
+---------------------------------------------------------------------------------------------------+
|  [ Google Drive ]    [ TeraBox ]     [ VPS / SSH (NEW) ]     [ Proton Drive (NEW) ]  [ OneDrive ] |
|  OAuth 2.0 PKCE      CPX Bridge      SFTP / SSH Keys         SRP / rclone Backend    MS Graph     |
+---------+-----------------+-------------------+-----------------------+-------------------+-------+
          |                 |                   |                       |                   |
          +-----------------+---------+---------+-----------------------+-------------------+
                                      |
                                      v
+---------------------------------------------------------------------------------------------------+
|                             Unified Provider Abstraction Layer                                    |
|             (ProviderContract.ps1: Info, TestSession, Save, Stored, Remove, Env, List)            |
+-------------------------------------+-------------------------------------------------------------+
                                      |
                                      v
+---------------------------------------------------------------------------------------------------+
|                       Virtual Drive Manager (WinFsp + Rclone VFS Engine)                          |
|         FixedDisk Mode • Isolated RC Ports • Deterministic Multi-Mount Namespaces                  |
+-------------------------------------+-------------------------------------------------------------+
                                      |
                                      v
+---------------------------------------------------------------------------------------------------+
|                              Windows 11 File Explorer Integration                                 |
|         G:\ (Google)   T:\ (TeraBox)   V:\ (VPS Agent)   P:\ (Proton)   O:\ (OneDrive)            |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. Milestone Breakdown & Architectural Specifications

### Milestone 1: VPS / Remote Server (SSH & SFTP) Provider Engine (`vps`)

The VPS provider bridges local workstations and remote servers/VPSs (such as instances running remote coding agents, data processing, or large storage).

#### 1.1 Provider Contract Implementation (`src/providers/VpsProvider.ps1`)
Implements all 7 methods required by `Get-CloudProviderContract`:
1. `Get-VpsProviderInfo`:
   - `SupportsOAuth = $false`
   - `SupportsManualSession = $true` (Host, Port, User, Password or Private Key, Remote Path)
   - `SupportsQuota = $true` (Remote disk usage via SFTP/statvfs)
   - `SupportsMultipleAccounts = $true` (Connect multiple distinct VPS/servers independently)
2. `Test-VpsBackendSession`:
   - Validates SSH/SFTP connectivity to the remote host using rclone's `sftp` backend.
   - Probes remote root folder readability and disk statistics (`TotalSpace`, `UsedSpace`, `FreeSpace`).
   - Returns verified identity (`user@host:port:path`).
3. `Save-VpsSession`:
   - Persists SSH credentials (passwords, private key paths, or raw PEM keys) encrypted under Windows DPAPI (`ProtectedData`).
   - File path: `%LOCALAPPDATA%\NSCloudDrive\credentials\vps-session-<AccountId>.xml`.
   - Restrictive ACL inheritance: Current User + NT AUTHORITY\SYSTEM only.
4. `Get-VpsStoredSession`:
   - Retrieves decrypted credentials strictly scoped to `$AccountId`.
5. `Remove-VpsSession`:
   - Safely wipes account-scoped credentials and session files.
6. `Get-VpsRcloneEnvironment`:
   - Emits rclone mount environment variables:
     * `RCLONE_CONFIG_<REMOTE>_TYPE = "sftp"`
     * `RCLONE_CONFIG_<REMOTE>_HOST = <Host>`
     * `RCLONE_CONFIG_<REMOTE>_PORT = <Port>`
     * `RCLONE_CONFIG_<REMOTE>_USER = <User>`
     * `RCLONE_CONFIG_<REMOTE>_PASS = <ObscuredPass>` (if password used)
     * `RCLONE_CONFIG_<REMOTE>_KEY_FILE = <KeyPath>` (if key file used)
     * `RCLONE_CONFIG_<REMOTE>_KEY_PEM = <KeyPem>` (if inline PEM used)
     * `RCLONE_CONFIG_<REMOTE>_KEY_FILE_PASS = <ObscuredPassphrase>`
7. `Get-VpsFileList`:
   - Direct remote directory listing for the Transfer Center and file browser.

#### 1.2 UI & Visual Integration
- Add **VPS / Remote Server (SSH & SFTP)** card to `Show-AddCloudDiskModal`.
- Create `Show-VpsSetupModal`:
  * Hostname / IP address (e.g. VPS IP).
  * Port (default 22).
  * Username (e.g. `root` or user account).
  * Authentication selector: Password or SSH Private Key file (`.pem`, `.key`, OpenSSH).
  * Remote Path root (default `/`).
  * Live "Test SSH Connection" verification button before saving.
- Assign default drive letter: `V:`.
- Official server/terminal brand icon: `assets/logos/vps.png` and SVG path in `NSCloudDrive.ps1`.

---

### Milestone 2: Proton Drive Provider Engine (`proton`)

Proton Drive provides private, zero-knowledge encrypted cloud storage.

#### 2.1 Provider Contract Implementation (`src/providers/ProtonDriveProvider.ps1`)
Implements all 7 methods required by `Get-CloudProviderContract`:
1. `Get-ProtonDriveProviderInfo`:
   - `SupportsOAuth = $false`
   - `SupportsManualSession = $true` (SRP username / password / 2FA / mailbox password)
   - `SupportsQuota = $true`
   - `SupportsMultipleAccounts = $true`
2. `Test-ProtonDriveBackendSession`:
   - Validates Proton credentials against rclone's built-in `protondrive` backend.
   - Retrieves storage quota (`TotalSpace`, `UsedSpace`, `FreeSpace`) and account identity.
3. `Save-ProtonDriveSession`:
   - Persists Proton credentials and session keys encrypted under Windows DPAPI (`ProtectedData`).
   - File path: `%LOCALAPPDATA%\NSCloudDrive\credentials\proton-session-<AccountId>.xml`.
4. `Get-ProtonDriveStoredSession`:
   - Scoped credential retrieval.
5. `Remove-ProtonDriveSession`:
   - Safe account-scoped purge.
6. `Get-ProtonDriveRcloneEnvironment`:
   - Emits `RCLONE_CONFIG_<REMOTE>_TYPE = "protondrive"`, username, obscured password, 2FA code, and mailbox password.
7. `Get-ProtonDriveFileList`:
   - Remote folder listings for transfer operations.

#### 2.2 UI & Visual Integration
- Add **Proton Drive** card to `Show-AddCloudDiskModal`.
- Create `Show-ProtonDriveSetupModal` with username, password, and optional 2FA / mailbox password inputs.
- Assign default drive letter: `P:`.
- Branding asset: `assets/logos/protondrive.png` and SVG path in `NSCloudDrive.ps1`.

---

### Milestone 3: Microsoft OneDrive & SharePoint Provider Engine (`onedrive`)

- Loopback OAuth 2.0 (RFC 8252) with PKCE verifier.
- Microsoft Graph API quota and identity integration (`/me/drive`).
- Personal and business drive support.
- Default drive letter: `O:`.

---

### Milestone 4: Windows Explorer Context Menus & Shell Polish

1. **Context Menu Actions**:
   - "Copy Cloud / VPS Share Path"
   - "Evict Local Cache (Free Up Space)"
   - "Pin Offline (Keep on SSD)"
2. **Transfer Center Multi-Remote Routing**:
   - Seamless transfers between any pair of providers: Google Drive $\leftrightarrow$ TeraBox $\leftrightarrow$ VPS $\leftrightarrow$ Proton Drive.

---

### Milestone 5: Linux CLI Daemon & Multi-Platform Architecture

1. **Linux FUSE Mount Daemon**:
   - Portable PowerShell Core / bash daemon running rclone VFS mounts on Linux distributions (Ubuntu, Debian, Fedora, Arch).
   - Systemd user service templates (`ns-clouddrive.service`).
   - Mounting under `~/CloudDrives/<Provider>`.
2. **Headless Agent API**:
   - Local JSON-RPC / socket endpoint allowing local and remote agents to trigger file transfers, check drive statuses, and query cache states programmatically.

---

### Milestone 6: Distribution, Automated Testing & 1:1 Push Protocol

1. **Automated Test Suites**:
   - `tests/Test-VpsProvider.ps1`: Comprehensive SFTP credential, environment, and contract tests.
   - `tests/Test-ProtonDriveProvider.ps1`: Proton Drive contract, DPAPI, and environment tests.
   - Full regression suite execution across all 43+ test scripts.
2. **1:1 File Commit and Push Protocol**:
   - Every file change is committed and pushed individually to GitHub `main` with clear, conventional commit messages.

---

## 3. 10-Point Quality Checklist for v2.0

Before merging any milestone into `main` or building the v2.0 release:

- [ ] **1. Root Cause & Architecture Adherence**: Every provider conforms strictly to `ProviderContract.ps1`.
- [ ] **2. Targeted Modification**: File changes are modular and non-overlapping.
- [ ] **3. Strict Mode Verified**: All code passes under `Set-StrictMode -Version Latest`.
- [ ] **4. Encoding Checked**: Zero raw multi-byte characters in `src/NSCloudDrive.ps1`; special glyphs use `[char]0x...`.
- [ ] **5. Concurrency Safe**: Background thread runspaces dot-source all required dependencies; no missing helper calls.
- [ ] **6. In-Use Protection**: Staged and dirty cache files are never evicted.
- [ ] **7. Security & Secrets**: DPAPI encryption applied with strict ACLs; zero secrets leaked in logs or error traces.
- [ ] **8. Automated Tests Passed**: 100% test suites pass with exit code `0`.
- [ ] **9. Independent Review Completed**: `orchestra-reviewer` formal sign-off on diffs.
- [ ] **10. Documentation Updated**: `README.md`, `USER_GUIDE.md`, and `task-ledger.json` synchronized.
