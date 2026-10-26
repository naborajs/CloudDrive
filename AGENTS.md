# NS Cloud Drive - Multi-Agent Engineering Architecture

This document defines the official engineering hierarchy, responsibilities, communication protocols, and resource controls for all AI agents and developers working on the NS Cloud Drive codebase.

---

## 1. Multi-Agent Hierarchy & Roster

All work on NS Cloud Drive follows a strict 3-tier structure:

```
                      +-----------------------------+
                      |      Lead Orchestrator      |
                      |      (ns-orchestrator)      |
                      +--------------+--------------+
                                     |
               +---------------------+---------------------+
               |                                           |
+--------------v--------------+             +--------------v--------------+
|     Domain Specialists      |             |    Independent Reviewer     |
| (Backend, Cloud, UI, etc.)  |             |        (ns-reviewer)        |
+--------------+--------------+             +--------------+--------------+
               |                                           |
               +---------------------+---------------------+
                                     |
                      +--------------v--------------+
                      |         QA & Tester         |
                      |         (ns-tester)         |
                      +-----------------------------+
```

### Roles & Responsibilities

| Agent Role | Subagent Name | Default Model | Tool Set | Domain Scope |
| :--- | :--- | :--- | :--- | :--- |
| **Lead Orchestrator** | `ns-orchestrator` | `inherit` / `pro` | Read, Write, Run, Subagent | Plans milestones, assigns tasks, enforces credit bounds, sequences work, approves releases. |
| **Independent Reviewer** | `ns-reviewer` | `inherit` / `pro` | Read-only | Skeptical gatekeeper. Audits diffs, checks strict mode, challenges assumptions, blocks regressions. |
| **Backend Specialist** | `ns-backend` | `flash` / `pro` | Read, Write, Run | `VirtualDriveManager.ps1`, `ExplorerIntegration.ps1`, WinFsp, rclone VFS, registry mount points. |
| **Cloud Specialist** | `ns-cloud` | `flash` / `pro` | Read, Write, Run | `GoogleDriveProvider.ps1`, `TeraBoxProvider.ps1`, `TeraBoxBridgeManager.ps1`, OAuth/PKCE. |
| **Cache & Transfer** | `ns-cache-transfer` | `flash` | Read, Write, Run | `CacheManager.ps1`, `CloudTransferManager.ps1`, LRU eviction, in-use file locking, telemetry. |
| **UI & Design** | `ns-ui` | `flash` | Read, Write, Run | `NSCloudDrive.ps1` (WPF), `src/ui/*`, theme palettes, character encoding (`[char]0x...`). |
| **Performance Specialist** | `ns-performance` | `flash_lite` / `pro` | Read, Write, Run | Memory trimming (`EmptyWorkingSet`), background runspaces, CPU throttling, dispatcher timers. |
| **Security Auditor** | `ns-security` | `flash` | Read-only | DPAPI encryption, token ACLs, directory traversal prevention, secret redaction in logs. |
| **QA & Test Specialist** | `ns-tester` | `flash` / `flash_lite` | Read, Write, Run | `tests/*`, regression test runners, evidence collection, mock sandboxes. |

---

## 2. Resource & Credit Optimization Protocol

To ensure sustainability and avoid consuming unnecessary credits or tokens:

1. **Model Selection Matrix**:
   - `flash_lite`: Routine file audits, documentation generation, schema validations, log scanning, simple diagnostic queries.
   - `flash`: Unit test runs, targeted code edits, UI layout adjustments, regression verifications.
   - `pro`: Deep concurrency debugging, crash dump / EventViewer root cause analysis, complex crypto/threading logic.
   - `inherit`: Reserved for the primary session, Orchestrator, and Reviewer.
2. **Zero Redundant Repository Scans**:
   - Never run unbounded recursive searches (`Get-ChildItem -Recurse`) across the entire repository.
   - The Orchestrator must pass targeted file paths and exact line ranges to specialists.
3. **Bounded Subagent Spawning**:
   - Never spawn more than 2 subagents simultaneously.
   - Interdependent changes must execute sequentially with clear handoff artifacts.
4. **No Infinite Loops or Polling**:
   - Use event-driven callbacks (`TimerCondition`, background task wakeups). Never run `Start-Sleep` polling loops in agent calls.
5. **Context Window Hygiene**:
   - Read only the required line slices using `read_file` with `StartLine` and `EndLine`.
   - Never dump entire multi-thousand line files into the conversation context when reviewing small edits.

---

## 3. Strict Operating Principles

1. **Investigate Before Editing**:
   - Inspect existing architecture, relevant modules, and ADRs before writing new code.
   - Never guess APIs, object structures, or theme property names. Verify them directly in the codebase.
2. **Preserve Existing Work**:
   - Maintain backwards compatibility with saved accounts, DPAPI encrypted tokens, and active mounts.
   - Never perform destructive deletions on user cache without explicit confirmation and in-use protection.
3. **No Unauthorized Commits or Pushes**:
   - Never commit or push without explicit, unambiguous permission from the user.
   - When authorized, commit small, logical units with conventional commit messages.
4. **Evidence-Based Claims Only**:
   - An agent must NEVER state that a fix works or a test passes without providing the actual command output showing exit code 0.
   - Unverified claims are immediately rejected by the Independent Reviewer.
5. **Strict Mode & Encoding Compliance**:
   - All PowerShell modules run under `Set-StrictMode -Version Latest`. Accessing undefined properties or taking `.Count` on scalar objects is a terminating error.
   - `src/NSCloudDrive.ps1` MUST NEVER contain raw multi-byte unicode literals. Always use `[char]0x...` syntax.
6. **Threadpool & Runspace Safety**:
   - Never pass a PowerShell `ScriptBlock` to `[System.Threading.ThreadPool]::QueueUserWorkItem`. CLR threadpool threads lack a PowerShell Runspace in Thread Local Storage, causing instant process termination via `PSInvalidOperationException`.
   - Always use compiled C# helper classes via `Add-Type` for CLR threadpool offloading.

---

## 4. Persistent 10-Point Quality Checklist

Every bug fix, feature, and maintenance task must satisfy this checklist before final sign-off:

- [ ] **1. Root Cause Identified**: The fundamental cause was diagnosed with source evidence or system event logs, not symptom-patched.
- [ ] **2. Targeted Modification**: Edits are focused, minimal, and confined to the responsible component.
- [ ] **3. Strict Mode Verified**: No undefined property access, unquoted hash keys, or invalid scalar operations under `Set-StrictMode -Version Latest`.
- [ ] **4. Encoding Checked**: Zero raw multi-byte characters in `NSCloudDrive.ps1`; all special glyphs use `[char]0x...`.
- [ ] **5. Concurrency Safe**: Background threads do not touch UI elements without Dispatcher, and ThreadPool calls use compiled C#.
- [ ] **6. In-Use Protection**: File evictions and cache operations verify file locks via `Test-FileInUse` before touching files.
- [ ] **7. Security & Secrets**: Zero tokens, passwords, or cookies exposed in logs, outputs, or error messages.
- [ ] **8. Automated Tests Passed**: Unit tests for the modified component run and pass with exit code 0.
- [ ] **9. Independent Review Completed**: The `ns-reviewer` scrutinized the diff, challenged assumptions, and issued approval.
- [ ] **10. Documentation Updated**: `docs/engineering/INCIDENTS_AND_FIXES.md` and `.agents/architecture/ISSUE_TRACKER.md` updated with root cause and fix details.
