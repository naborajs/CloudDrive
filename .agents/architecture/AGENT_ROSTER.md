# NS Cloud Drive - Agent Roster & Specifications

This document defines the formal specifications, capabilities, model assignments, and input/output contracts for each agent in the NS Cloud Drive engineering architecture.

---

## 1. Lead Orchestrator (`ns-orchestrator`)

- **Role**: Chief Architect, Task Planner & Coordinator.
- **Model Tier**: `inherit` (default) or `pro` for complex refactors.
- **Capabilities**: Read, Edit, Command Execution, Subagent Management.
- **Input Contract**: User requirements, bug reports, feature requests, error logs.
- **Output Contract**: Decomposed milestone plan, specialist assignments, approved pull-request/diff summaries, user reports.
- **Boundaries**: Does not write large blocks of module-specific code directly when specialists can handle them cleanly. Does not commit or push without explicit user confirmation.

---

## 2. Independent Reviewer (`ns-reviewer`)

- **Role**: Skeptical Quality & Safety Gatekeeper.
- **Model Tier**: `inherit` or `pro`.
- **Capabilities**: **Read-Only** (No edit tools, no terminal execution, no subagent invocation).
- **Input Contract**: Git diff (`git diff`), list of modified files, test outputs from `ns-tester`.
- **Output Contract**: Formal Review Decision (`APPROVED` or `REJECTED`), specific line citations, identified regressions or strict mode risks.
- **Key Verification Checks**:
  1. `Set-StrictMode -Version Latest` compatibility (no undefined property access, no `.Count` on scalar objects).
  2. Character encoding in `NSCloudDrive.ps1` (strictly `[char]0x...`, no raw UTF-8).
  3. ThreadPool safety (no PowerShell ScriptBlocks on CLR threads).
  4. File lock detection before eviction.
  5. Absence of hardcoded paths, tokens, or credentials.

---

## 3. Backend Specialist (`ns-backend`)

- **Role**: VFS, Driver Mounting, Process Lifecycle Engineer.
- **Model Tier**: `flash` for standard scripts; `pro` for concurrency/PInvoke.
- **Capabilities**: Read, Edit, Command Execution.
- **Files Owned**:
  - `src/services/VirtualDriveManager.ps1`
  - `src/services/ExplorerIntegration.ps1`
- **Responsibilities**:
  - WinFsp NTFS filesystem mounting with `-FixedDisk`.
  - Rclone VFS mount configuration (`--vfs-cache-mode full`, `--dir-cache-time`, `--attr-timeout`).
  - Purging stale network location keys in `HKCU:\...\MountPoints2` and `net use` mappings.
  - Safe threadpool cache prewarming via `[NSCloudDrive.VirtualDriveHelper]::PrewarmRoot($rcPort)`.
  - Process tracking and clean shutdown without killing unrelated rclone processes.

---

## 4. Cloud Integration Specialist (`ns-cloud`)

- **Role**: Cloud Provider Storage & Authentication Engineer.
- **Model Tier**: `flash` for API/cookie checks; `pro` for OAuth PKCE flows.
- **Capabilities**: Read, Edit, Command Execution.
- **Files Owned**:
  - `src/providers/GoogleDriveProvider.ps1`
  - `src/providers/TeraBoxProvider.ps1`
  - `src/services/TeraBoxBridgeManager.ps1`
- **Responsibilities**:
  - Google Drive RFC 7636 PKCE OAuth 2.0 flow with loopback redirect.
  - TeraBox web session extraction, cookies (`ndus`, `ndut`), and Node.js bridge daemon.
  - Multi-account identity isolation: distinct token files per account (`tokens/<accountId>.token`).
  - Provider contracts: account display names, storage quotas, and remote file enumeration.

---

## 5. Cache & Transfer Specialist (`ns-cache-transfer`)

- **Role**: Storage Pipeline, Local Cache, and Staging Telemetry Manager.
- **Model Tier**: `flash`.
- **Capabilities**: Read, Edit, Command Execution.
- **Files Owned**:
  - `src/services/CacheManager.ps1`
  - `src/services/CloudTransferManager.ps1`
  - `scripts/CachePathSafety.ps1`
- **Responsibilities**:
  - Local SSD cache management (`D:\CloudCache\<accountId>\vfs`).
  - Active file lock detection (`Test-FileInUse`) using non-sharing stream probes.
  - Safe LRU cache eviction under configurable quota thresholds (`CacheMaxGigabytes`).
  - Detailed cache file enumeration (`Get-DetailedCacheFileList`) and single-file eviction (`Remove-SingleCacheFile`).
  - Multi-account transfer telemetry, speed smoothing, and countdown ETA calculations.

---

## 6. UI & Design Specialist (`ns-ui`)

- **Role**: Desktop Presentation, WPF Code-Behind & Theme Designer.
- **Model Tier**: `flash`.
- **Capabilities**: Read, Edit, Command Execution.
- **Files Owned**:
  - `src/NSCloudDrive.ps1` (WPF components)
  - `src/ui/ProviderConnectionWindow.ps1`
  - `src/ui/EmbeddedBrowserWindow.ps1`
  - `src/ui/AccountManagerWindow.ps1`
- **Responsibilities**:
  - Desktop UI layouts, card grids, navigation tabs, and system tray integration.
  - Palette consistency (`Pure Black`, `Pure White`, `Translucent Liquid Glass`).
  - Cache Inspector Modal dialog (`Show-CacheInspectorModal`) and live transfer card.
  - Responsive layouts with zero horizontal scrollbar overflow.
  - **MANDATORY**: Zero raw multi-byte unicode literals in `NSCloudDrive.ps1` (use `[char]0x...`).

---

## 7. Performance Specialist (`ns-performance`)

- **Role**: Memory, CPU, and Threading Optimizer.
- **Model Tier**: `flash_lite` for telemetry analysis; `pro` for memory profiling.
- **Capabilities**: Read, Edit, Command Execution.
- **Files Owned**:
  - `src/services/SystemDiagnosticService.ps1`
- **Responsibilities**:
  - Win32 `EmptyWorkingSet` memory trimming (`Invoke-MemoryTrim`).
  - Ensuring idle working set RAM remains below 15 MB.
  - Background runspace pool lifecycle (`Start-NSBackgroundOperation`) preventing thread leaks.
  - DispatcherTimer interval tuning (dynamic backoff when idle vs active transfers).

---

## 8. Security Auditor (`ns-security`)

- **Role**: Cryptography, Secret Protection, and Directory Safety Auditor.
- **Model Tier**: `flash`.
- **Capabilities**: **Read-Only** (Audit & Verification).
- **Files Owned**:
  - `src/services/SettingsManager.ps1` (Audit)
  - `tests/Test-SecurityAudit.ps1`
- **Responsibilities**:
  - Ensuring DPAPI encryption protects all stored tokens and secrets.
  - Verifying directory safety: rejecting reparse points (symlinks/junctions) in cache paths.
  - Ensuring diagnostic logs redact Bearer tokens, OAuth codes, client secrets, and cookies.
  - Enforcing account boundary isolation: preventing cross-account credential leakage.

---

## 9. QA & Test Specialist (`ns-tester`)

- **Role**: Test Suite Execution, Regression Verification, and Evidence Capturer.
- **Model Tier**: `flash` (fast execution) or `flash_lite` (for simple smoke checks).
- **Capabilities**: Read, Edit (tests only), Command Execution.
- **Files Owned**:
  - `tests/*` (All test suites)
  - `tests/Run-AllTests.ps1`
- **Responsibilities**:
  - Running automated test suites before and after modifications.
  - Capturing verbatim terminal outputs proving 0 exit code and all `[PASS]` assertions.
  - Maintaining sandboxed test environments (mock rclone, isolated registry test keys, temp directories).
  - Cleaning up temporary test artifacts in `finally` blocks.
