# NS Cloud Drive — Project Technical State & Architectural Map

**Last Updated:** 2026-10-26  
**Repository Root:** `C:\Users\Naboraj_sarkar\Documents\Codex\CloudDrive`  
**Current Git Branch:** `main`  
**Application Entry Point:** `NSCloudDrive.exe` -> `src/launcher/Program.cs` -> `src/NSCloudDrive.ps1`  
**Author / Developer:** NABORAJ SARKAR  

---

## 1. Executive Summary & Current Operational State

NS Cloud Drive is a native Windows desktop application that mounts remote cloud storage providers (Google Drive and TeraBox) as virtual NTFS/WinFsp drive letters (`G:`, `H:`, `T:`, `N:`, `I:`) in Windows File Explorer.

The application combines:
1. **WPF GUI (`src/NSCloudDrive.ps1`)**: Single-threaded apartment (STA) PowerShell application rendering account cards, real-time disk transfer telemetry, cache inspection, system options, and diagnostics.
2. **Virtual Filesystem Engine (`src/services/VirtualDriveManager.ps1`)**: WinFsp + rclone VFS mount daemon orchestrator with isolated remote control (RC) HTTP ports per drive, DPAPI credential binding, and dynamic rate limiting.
3. **Resilient Transfer Queue & Cloud Transfer Engine (`src/services/CloudTransferManager.ps1`)**: Durable JSON queue (`transfer-jobs.json`), streaming directory ingestion, bounded concurrency, worker lease watchdogs, exponential retry backoff, and remote cloud verification.
4. **Adaptive Bandwidth & Cache Management (`src/services/AdaptiveBandwidthManager.ps1`, `src/services/CacheManager.ps1`)**: Inactivity-based TTL eviction (5m for <1GB, 20m for 1-3GB, 45m for >3GB), in-use and dirty file locks protection, and user-configurable bandwidth throttling.
5. **Native C# Launcher (`src/launcher/Program.cs`)**: Single-instance mutex enforcement, STA runspace hosting, minimize-to-tray lifecycle, and memory working set trimming via Win32 `EmptyWorkingSet`.

---

## 2. Repository & Working Environment Inspection

### 2.1 Git Status & Diff Summary
- **Branch:** `main` (synchronized with `origin/main`).
- **Uncommitted Modifications:**
  - `src/NSCloudDrive.ps1`: Card drag-and-drop mouse capture engine, live transfer multi-account aggregation, honest confirmation state labels, notification deduplication.
  - `src/services/CloudTransferManager.ps1`: Resilient queue manager (`Add-CloudTransferFolderBatch`, `Process-CloudTransferQueue`, `Save-DurableTransferQueue`, `Invoke-StartupTransferQueueRecovery`).
  - `src/services/VirtualDriveManager.ps1`: Mount tuning (`--vfs-cache-poll-interval 2s`, `--vfs-write-back 1s`, `--drive-chunk-size 32M`, `--transfers 4` for Google Drive and `--transfers 2` for TeraBox), RC bandwidth limits, `MountPoints2` cleanup.
  - `src/services/SettingsManager.ps1`: Bandwidth policies (`Unlimited`, `Limited`, `MinimalBackground`, `Adaptive`, `Custom`), preset formatting (`Get-EffectiveBandwidthLimitRate`).
  - `src/services/CacheManager.ps1`: Inactivity cache eviction, detailed cache enumeration, single-file eviction.
- **Untracked Additions:**
  - `src/services/AdaptiveBandwidthManager.ps1`
  - `task-ledger.json` (TASK-005 active)
  - `.agents/architecture/` (roster, guidelines, issue tracker)
  - `tests/Test-TransferBandwidthAndQueue.ps1`
  - `tests/Test-CardDragAndDrop.ps1`
  - `tests/Test-BackendCorrectnessAndSync.ps1`
  - `scripts/Package-Release.ps1`

### 2.2 System & Runtime Dependencies
- **PowerShell Version:** 5.1 (Desktop Edition) running under `Set-StrictMode -Version Latest`.
- **Operating System:** Windows 10/11 x64.
- **Virtual Filesystem Driver:** WinFsp (Windows File System Proxy) 2.0+.
- **FUSE Engine:** Rclone v1.65+ (located in `%LOCALAPPDATA%\NSCloudDrive\tools\rclone\rclone.exe` or PATH).
- **Embedded Browser:** WebView2 Runtime (Microsoft.Web.WebView2.Core / Wpf).
- **Security:** Windows DPAPI (`System.Security.Cryptography.ProtectedData`) for OAuth tokens and session secrets.

---

## 3. Communication & Transfer Pipeline Architecture

```
[ Windows File Explorer ]               [ UI / Cloud-to-Cloud Modal ]
         |                                           |
         v (File Write)                              v (Batch Ingest)
+------------------------+                  +--------------------------------+
| WinFsp / rclone Mount  |                  | CloudTransferManager Queue     |
| (--vfs-cache-mode full)|                  | (Add-CloudTransferFolderBatch) |
+-----------+------------+                  +---------------+----------------+
            |                                               |
            v                                               v
+------------------------+                  +--------------------------------+
| Local NVMe Cache       |                  | transfer-jobs.json (Durable)   |
| (D:\CloudCache\vfs\*)  |                  +---------------+----------------+
| vfsMeta: {Dirty: true} |                                  |
+-----------+------------+                  +---------------v----------------+
            |                               | Process-CloudTransferQueue     |
            v                               | (Named Mutex, Worker Leases,   |
+------------------------+                  | Concurrency Caps, Retries)     |
| Rclone Streaming Flush |                  +---------------+----------------+
| (--vfs-write-back 1s)  |                                  |
+-----------+------------+                                  v
            |                               +--------------------------------+
            +------------------------------>| Cloud Storage Providers        |
                                            | (Google Drive / TeraBox)       |
                                            +--------------------------------+
```

### 3.1 VFS Write-Back Pipeline (Explorer Drag & Drop)
1. **Local Staging**: Files copied into virtual drive letter (`G:\`, `T:\`) are immediately written to local SSD cache (`D:\CloudCache\<AccountId>\vfs\<remote>\...`) at NVMe speeds (500 MB/s - 1.3 GB/s).
2. **Metadata Tagging**: Rclone writes `<path>.vfsMeta` recording `{ "Dirty": true }`.
3. **Write-Back Delay**: After `--vfs-write-back 1s`, rclone initiates background streaming upload to cloud.
4. **Telemetry Export**: Rclone RC endpoint (`/core/stats`, `/vfs/stats`, `/vfs/queue`) on deterministic port (T=5599, G=5586, etc.) serves live stats to `Get-VirtualDriveVfsStats`.
5. **Confirmation & Commit**: Once cloud provider acknowledges remote write, rclone marks `Dirty: false`.

### 3.2 Durable Transfer Queue Pipeline (Application Engine)
1. **Streaming Ingestion**: `Add-CloudTransferFolderBatch` enumerates directories recursively via streaming `[System.IO.Directory]::EnumerateFiles` without loading file contents into memory.
2. **Durable Persistence**: Atomically writes queue state to `%LOCALAPPDATA%\NSCloudDrive\state\transfer-jobs.json` via GUID `.tmp` file and `[System.IO.File]::Replace`.
3. **Execution & Concurrency**: `Process-CloudTransferQueue` schedules jobs under global named mutex `Global\NSCloudDrive_TransferScheduler_Mutex`, capping TeraBox at 2 workers and Google Drive at 4 workers.
4. **Retry Backoff**: Transient errors trigger exponential delay ($2^{\text{RetryCount}}$ seconds, max 60s, max 3 retries) and non-blocking queue progression.
5. **Remote Verification**: `Test-RemoteCloudFileVerification` verifies remote file presence and size before marking `Completed and remotely confirmed`.

---

## 4. Requirement Verification & Gap Analysis

| Requirement | Current Code Status | Verification Evidence | Gap / Remediation Needed |
| :--- | :--- | :--- | :--- |
| **1. Durable Folder Queue** | Implemented in `CloudTransferManager.ps1` | `tests/Test-TransferBandwidthAndQueue.ps1` passed | Needs UI integration for folder selection and continuous scheduler pumping. |
| **2. Continuous Queue Progression** | Implemented in `Process-CloudTransferQueue` | 120-item stress test passed | `NSCloudDrive.ps1` timer does not yet call `Process-CloudTransferQueue`. |
| **3. Non-Blocking Failure Progression** | Implemented (`Test-IsPermanentTransferError`) | Unit test passed (exit code 0) | Fully functioning. |
| **4. Restart Recovery** | Implemented (`Invoke-StartupTransferQueueRecovery`) | Unit tested in isolation | Must be triggered in `Start-ApplicationStartupSequence`. |
| **5. Automatic Background Worker Startup** | Implemented (HKCU Run key + CLI `-Minimized`) | `Test-StartupBehavior.ps1` passed | Fully functioning. |
| **6. Explorer Independence** | Verified (rclone runs detached from Explorer) | Process hierarchy audit confirmed | Fully functioning; closing Explorer does not stop transfers. |
| **7. Safe Staged-Data Retention** | Implemented (zero-eviction on dirty/locked files) | `Test-CacheManagement.ps1` passed | Inactivity eviction preserves dirty files across all paths. |
| **8. User Bandwidth Limits** | Implemented (Unlimited default, presets, RC API) | `Test-TransferBandwidthAndQueue.ps1` passed | Global cap applies to all mounts and workers without multiplication. |
| **9. Provider Concurrency & Chunk Tuning** | Implemented (32M GDrive, 2 transfers TeraBox) | Mount argument tests passed | Eliminates TeraBox 429 locks and 10s idle gaps. |
| **10. Honest Progress & Completion** | Implemented ("Awaiting remote confirmation...") | UI ASCII & regex audit passed | `Update-LiveTransferActivity` must check pending uploads during inter-file gaps. |
| **11. Multi-Account GDrive & TeraBox** | Implemented (DPAPI, isolated configs/caches) | `Test-MultiAccountLifecycle.ps1` passed | Preserved intact. Old token 401 in test suite requires graceful handling. |
| **12. Regression Test Coverage** | 33 test suites (32 passed, 1 live 401 token) | `tests/Run-AllTests.ps1` | Add synthetic restart recovery and queue progression test suite. |
| **13. Documentation Integrity** | Maintained across `docs/` and `task-ledger.json` | Inspection verified | Maintain factual records without claiming unverified behavior. |

---

## 5. Confirmed Root Causes of Historical Transfer Defects

1. **Premature Completion & UI Disappearance During Gaps**:
   - *Root Cause:* In `Update-LiveTransferActivity`, when rclone completed one file and waited 1-2 seconds before picking up the next dirty file, `$allActiveTransfers` momentarily became empty. The UI immediately executed the `else` branch, setting status to *"All files synchronized and confirmed"*, and collapsing the live card after 6 seconds.
   - *Remediation:* `Update-LiveTransferActivity` must inspect `Get-VirtualDrivePendingUploads` and `$script:CloudTransferQueue`. If pending items remain, it must display *"Resuming Background Sync • Queued for upload"* rather than declaring false completion.

2. **10-Second to 15-Second Idle Gaps Between Files**:
   - *Root Cause:* Rclone default `--vfs-cache-poll-interval` was 15s and `--vfs-write-back` was 5s. After writing a file, rclone waited up to 15s before scanning the cache directory for the next dirty file.
   - *Remediation:* Tuned to `--vfs-cache-poll-interval 2s` and `--vfs-write-back 1s` in `Build-RcloneMountArguments`.

3. **Queue Stalling After ~3 Files (TeraBox 429 Lockout)**:
   - *Root Cause:* Rclone defaulted to 4 concurrent transfers (`--transfers 4`). TeraBox WebDAV bridge and web endpoints enforce a strict concurrency ceiling of 2. Parallel requests triggered HTTP 429 (Too Many Requests), stalling or killing the transfer workers.
   - *Remediation:* Bounded TeraBox mounts and queue workers to `--transfers 2`.

4. **100% "Starting upload..." Display Confusion**:
   - *Root Cause:* When all bytes were transmitted across the socket (`bytesTransferred == fileSizeBytes`), rclone waited for cloud API response and checksum commit. The UI had fallback text defaulting to `"Starting upload..."` when bytes remaining was 0.
   - *Remediation:* Replaced with honest lifecycle status: `"All bytes transmitted • Awaiting cloud verification"` and `"Awaiting remote confirmation..."`.

5. **Transfer Queue Inaction in Background UI**:
   - *Root Cause:* While `CloudTransferManager.ps1` had full durable queue logic (`Process-CloudTransferQueue`), neither the background dispatcher timer nor the application startup sequence ever called it.
   - *Remediation:* Wire `Process-CloudTransferQueue` into the background dispatcher loop and `Invoke-StartupTransferQueueRecovery` into `Start-ApplicationStartupSequence`.
