# NS Cloud Drive — Transfer Acceptance Test Matrix & Results

**Author / Maintainer:** NABORAJ SARKAR  
**Test Suite Reference:** `tests/Test-TransferBandwidthAndQueue.ps1`, `tests/Test-CacheManagement.ps1`, `tests/Test-EndToEndAcceptance.ps1`, `tests/Run-AllTests.ps1`  

---

## 1. Automated Acceptance Test Results

All automated tests use isolated temporary sandboxes and synthetic mock items to prevent consuming cloud quotas or leaking user data.

| Test ID | Test Scenario | Expected Result | Actual Result | Verification Evidence |
| :--- | :--- | :--- | :--- | :--- |
| **TC-01** | **Bandwidth Policy Defaults** | `BandwidthPolicy` defaults to `Unlimited` on fresh installs. | `Unlimited` verified; effective rate `'off'`. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-02** | **Preset Bandwidth Rate Mapping** | Presets (256k to 10M) map correctly to rclone bwlimit syntax. | Exact matching syntax produced across all presets. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-03** | **Custom Bandwidth Formatting** | Custom MB/s and KB/s values formatted without truncation. | `15 MB/s` -> `15M`, `850 KB/s` -> `850k`. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-04** | **VFS Writeback & Poll Tuning** | Poll interval 2s, writeback delay 1s to eliminate 10s gaps. | Arguments builder outputs `--vfs-cache-poll-interval 2s` and `--vfs-write-back 1s`. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-05** | **Google Drive Chunk Tuning** | Chunk size set to 32M and transfers capped at 4. | Arguments contain `--drive-chunk-size 32M` and `--transfers 4`. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-06** | **TeraBox Concurrency Tuning** | Transfers capped at 2 to prevent HTTP 429 locks. | Arguments contain `--transfers 2`. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-07** | **120-Item Queue Stress Test** | Ingest 120 mixed-size files (0 B, 10 KB, 5 MB) without memory bloat. | All 120 items enqueued and persisted to `transfer-jobs.json`. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-08** | **Single Item Cancellation** | Cancelling one item updates its state to `Cancelled` without affecting others. | Item transitioned to `Cancelled`; other 119 items untouched. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-09** | **Transient Error Backoff** | Transient errors transition to `Waiting for network/provider` with exponential delay. | Retry count incremented; `NextRetryUtc` calculated; scheduler advances to next file. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-10** | **Max Retries Permanent Failure** | Exceeding 3 retries transitions to `Failed` without wedging the queue. | Item marked `Failed`; subsequent items continue processing. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-11** | **UI 7-Bit ASCII Compliance** | `NSCloudDrive.ps1` contains 0 non-ASCII multi-byte characters. | Exact 0 non-ASCII bytes found across 484 KB source file. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-12** | **Honest Confirmation Labels** | UI shows *"Awaiting remote confirmation..."* when bytes reach 100%. | Labels present in UI and verified via AST/regex assertions. | `Test-TransferBandwidthAndQueue.ps1` (Exit Code 0) |
| **TC-13** | **Zero-Eviction on Dirty Staging** | Staged and in-use cache files are never evicted by TTL or cache quota cleanup. | Dirty files protected across all eviction passes. | `Test-CacheManagement.ps1` (Exit Code 0) |
| **TC-14** | **Windows Auto-Start Registration** | `AutoStartWithWindows` registers `NSCloudDrive.exe -Minimized` in HKCU Run. | Registry key creation and deletion verified. | `Test-StartupBehavior.ps1` (Exit Code 0) |

---

## 2. Reproducible Manual & Integration Test Procedures

### Test Scenario A: Multi-File Folder Transfer Verification
1. Launch NS Cloud Drive (`NSCloudDrive.exe`).
2. Verify virtual drives `G:` and `T:` are mounted and healthy in Disks view.
3. Open Windows File Explorer and navigate to `G:\`.
4. Copy a folder containing 50 images (~100 MB total) into `G:\PhotosTest`.
5. Observe:
   - Explorer copy dialog completes fast (local SSD staging).
   - NS Cloud Drive Disks page displays live transfer banner: *"Uploading to Cloud"*, showing current file name, progress bar, upload throughput, and remaining items in sub-queue.
   - Files upload continuously without ~10-second pauses between files.
   - When each file reaches 100% of bytes sent, status displays *"Awaiting remote confirmation..."* until remote provider acknowledges commit.
   - When the entire folder finishes, a single balloon notification appears: *"Folder 'PhotosTest' was successfully uploaded and verified"*.

### Test Scenario B: Explorer Closure Independence
1. Begin a large folder copy into drive `T:\`.
2. Immediately close the Windows File Explorer window.
3. Observe:
   - NS Cloud Drive live transfer card continues updating.
   - Network upload throughput continues progressing.
   - Transfer completes remotely without interruption.

### Test Scenario C: Simulated Reboot / Process Crash Recovery
1. Enqueue transfer items in `transfer-jobs.json`.
2. Terminate the application process.
3. Relaunch NS Cloud Drive with `-Minimized`.
4. Observe:
   - `Invoke-StartupTransferQueueRecovery` reconciles unconfirmed items.
   - Verified items marked `Completed and remotely confirmed`.
   - Interrupted items reset to `Queued` readiness.
   - Queue resumes processing automatically.

---

## 3. Unverified Cases & Real-Provider Limitations

1. **Large Real-Provider Bulk Uploads (>100 GB)**:
   - Real cloud accounts must not be used for automated regression testing. Full multi-gigabyte uploads against live production Google Drive and TeraBox accounts remain an end-user acceptance verification step.
2. **TeraBox Free Account File Size Limit**:
   - Files exceeding 4.0 GB cannot be uploaded to TeraBox free accounts. The UI warns the user, and `Test-ProviderUploadPreflight` flags the limit.
3. **Expired Google OAuth Tokens**:
   - If an account's refresh token has been revoked by Google, re-authorization via `Connect-NewCloudAccount` is required. Direct API calls fail with HTTP 401 until renewed.
