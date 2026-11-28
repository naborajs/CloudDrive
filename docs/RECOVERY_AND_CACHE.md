# NS Cloud Drive — Recovery, Staging Retention & Cache Architecture

**Author / Maintainer:** NABORAJ SARKAR  
**Technical Modules:** `src/services/CacheManager.ps1`, `src/services/VirtualDriveManager.ps1`, `src/services/CloudTransferManager.ps1`  

---

## 1. Storage & Cache Namespace Taxonomy

Caching in NS Cloud Drive is a fundamental reliability requirement, not merely a performance optimization. The cache directory (`D:\CloudCache` or `%LOCALAPPDATA%\NSCloudDrive\cache`) is partitioned into distinct functional layers:

```
D:\CloudCache\
  ├── <AccountId_A>\
  │     ├── vfs\             <- Staged upload sources and active read caches
  │     │     └── <remote>\
  │     └── vfsMeta\         <- Metadata tracking state, dirty flags, and timestamps
  │           └── <remote>\
  │                 └── file.dat (JSON: { "Dirty": true, "AccessTime": ... })
  └── <AccountId_B>\
        ├── vfs\
        └── vfsMeta\
```

### Data Categorization & Protection Rules

| Category | Description | Protection Policy |
| :--- | :--- | :--- |
| **1. Disposable Read / Preview Cache** | Older cache data from previous full-cache mounts, with explicit clean metadata (`Dirty: false`, no open locks). | Reads are no longer disk-cached by new mounts. Historical clean data is eligible after its mount root is inactive and the configured TTL has expired. |
| **2. Pending Write-Back Data** | Files copied to virtual drives waiting for remote transmission (`Dirty: true` in `vfsMeta`). | **STRICTLY IMMUNE TO EVICTION.** Remains until the provider confirms the upload or the user handles the failed job. |
| **3. Active Upload Sources** | Files actively being read and streamed by rclone or transfer workers (`Test-FileInUse` returns `$true`). | **STRICTLY IMMUNE TO EVICTION.** File locking prevents access. |
| **4. Recoverable Failed / Cancelled Staging** | Staged files whose uploads failed transiently or were paused by the user. | **RETAINED SAFELY.** Staging preserved so user does not lose copied data. |
| **5. Uploaded Data Awaiting Remote Confirmation** | 100% of bytes sent, but awaiting cloud commit/hash verification. | **RETAINED.** Staged file must exist until remote verification passes. |
| **6. Successfully Completed Data** | Files confirmed remotely. | The durable queue removes only the exact linked staged revision after remote confirmation, SHA-256, size/write-time and path rechecks, current mount ownership checks, and exclusive handle acquisition. Locked or changed sources remain protected and are retried or re-queued. |

---

## 2. Inactivity Cache Eviction TTL Policy

New mounts use rclone `--vfs-cache-mode writes`, so browsing and previews do not fill the local write-back cache. The mount's `--vfs-cache-max-age` follows the selected policy: 5 minutes for remove-after-confirmation, 45 minutes for keep-cache, or the configured custom duration (bounded to 30 days). rclone owns cleanup inside the active VFS root.

`Invoke-InactivityCacheEviction` also reclaims only old, inactive VFS roots. It never removes files from a root reported by a live mount, and it preserves dirty, missing/invalid-metadata, locked, or actively queued files. Clean inactive VFS entries follow the selected cache policy: 5 minutes for `RemoveAfterVerifiedUpload`, 45 minutes for `KeepCache`, and the bounded custom duration for `CustomRetention`. The older size-based 5/20/45-minute rules apply only to the other managed cache data, not to VFS entries.

- **Cache smaller than 1 GB**: **5-minute** inactivity TTL for non-VFS cache data.
- **Cache from 1 GB through 3 GB inclusive**: **20-minute** inactivity TTL for non-VFS cache data.
- **Cache larger than 3 GB**: **45-minute** inactivity TTL for non-VFS cache data.

### Safety Guards Before File Eviction:
1. **Dirty Check**: Inspects the paired `vfsMeta` file. `Dirty: true`, missing metadata, or invalid metadata aborts eviction for VFS data.
2. **File Lock Check**: Calls `Test-FileInUse` (`[System.IO.File]::Open(..., FileMode.Open, FileAccess.ReadWrite, FileShare.None)`). If locked, eviction is aborted.
3. **Mount Ownership**: Active cache roots are excluded; when an active mount cannot report its VFS root, its entire account cache is protected.
4. **Transfer Scope**: Post-transfer cleanup accepts only remotely confirmed durable jobs with an exact staged-source path, persisted SHA-256, and unchanged size/write-time. It does not sweep all files that look clean.
5. **Physical Drive Guard**: Existing general cache cleanup verifies the target does not touch protected system roots (`C:\`, `C:\Windows`, user Desktop/Documents).
6. **Namespace Isolation**: Staged-source deletion is bounded strictly to the verified account VFS namespace (`<AccountId>\vfs\*`).

Sidecar lookup changes only the `vfs` segment directly under the account cache directory. Remote path segments that happen to be named `vfs` or `vfsMeta` remain unchanged, and filesystem normalization preserves valid Linux filename whitespace.

On Windows, cleanup removes the checked file through its exclusive handle. On Linux, it atomically moves the checked path into a private mode-0700 sibling `.nscd-delete-*` directory, hashes the claimed object against the held stream, and deletes only an exact match. A mismatch is restored if the original path is empty; otherwise the claim remains for preservation. Startup recovery restores stale interrupted claims and does not delete their payloads. Other temporary-file recovery is limited to stale exact NS-owned data/metadata test patterns outside all VFS namespaces; generic `.tmp`, `.partial`, editor backup, and rclone temporary files are not removed.

New settings default to `RemoveAfterVerifiedUpload`. An older unversioned `KeepCache` value is preserved because older releases also allowed users to select it, and the stored value cannot distinguish an explicit choice from the old default. Exact recovered upload staging is still removed after live remote confirmation; the policy controls other clean cache retention.

## 3. Selection Scope, Restart, and Cleanup

The Windows file picker sends only selected source paths to the durable transfer queue. It does not copy those files onto the mounted drive or into VFS staging. The queue records each selection before transfer, performs remote destination matching in a background runspace, skips exact remote matches, and resumes outstanding jobs after an application or device restart. Original local source files are not deleted.

Dirty cache files from older sessions may not have a durable record of the selection that created them. They are shown as items needing review and are not automatically uploaded. Re-drop the original files to create exact durable jobs. If a re-selected file uniquely matches an orphaned cache entry by provider account, relative path, size, and unchanged staged revision, that exact cache source is linked to the new job and removed only after remote confirmation. Ambiguous or unlinked data remains preserved.

Periodic inactivity scans, Options cleanup, Cache Inspector inventory/cleanup/eviction, cache statistics, and Analytics staged-upload scans can traverse large cache trees, so the desktop UI runs them in background workers. The inspector displays up to 250 filtered rows at once. Deletion rechecks current mount ownership and clean metadata while holding exclusive handles; when state is unknown, files are preserved. Existing mounted rclone processes keep their original cache arguments until the mount is restarted.

---

## 4. Restart & Crash Recovery Protocol

```mermaid
sequenceDiagram
    autonumber
    participant Boot as Windows OS Boot / App Launch
    participant Launcher as NSCloudDrive.exe
    participant App as NSCloudDrive.ps1
    participant Recov as Durable transfer queue recovery
    participant Cache as VFS cache review scan
    participant Cloud as Cloud Provider (GDrive/TeraBox)

    Boot->>Launcher: Launch via HKCU Run (-Minimized)
    Launcher->>App: Start Application (STA Runspace)
    App->>Recov: Load transfer-jobs.json
    Recov->>Cloud: Check exact selected destinations
    alt File verified on cloud
        Recov->>Recov: Mark "Completed and remotely confirmed"
    else File incomplete or missing
        Recov->>Recov: Keep missing work queued; clear stale worker lease
    end
    App->>Cache: Scan staged cache in background
    Cache->>App: Report untracked dirty files for review
    App->>App: Do not upload without the original selection
    App->>Cloud: Resume selected durable jobs; skip exact matches
    Cloud-->>App: Confirm selected destination
    App->>Cache: Remove only a linked staged cache revision
```

### Recovery Verification Checklist:
- [x] Durable queue reconstruction from `transfer-jobs.json`.
- [x] Unverified interrupted jobs reset to `Queued` readiness.
- [x] Completed remote uploads detected before retrying.
- [x] Exact selected jobs resume from durable queue state; orphaned cache entries require user re-selection.
- [x] Synthetic restart regression preserves unconfirmed jobs and skips exact remotely confirmed files; original local source files remain untouched by cache cleanup.
