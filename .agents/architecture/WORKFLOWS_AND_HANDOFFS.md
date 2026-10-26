# NS Cloud Drive - Workflows, Handoffs & Escalation Protocols

This document defines the structured operational workflows, handoff schemas, and escalation pathways for all maintenance and bug-fixing tasks.

---

## 1. The 5-Stage Engineering Lifecycle

Every bug fix, optimization, and feature request follows this non-negotiable sequence:

```
[Stage 1: Intake & Triage]
       |
       v
[Stage 2: Targeted Investigation]
       |
       v
[Stage 3: Minimal Implementation]
       |
       v
[Stage 4: Independent Review]  <---+ (If Rejected: Revise & Resubmit)
       |                            |
       +--- Approved? --------------+
       | Yes
       v
[Stage 5: Test Verification & Evidence]
       |
       v
[User Sign-Off & Status Reporting]
```

---

### Stage 1: Intake & Triage
- **Actor**: `ns-orchestrator`
- **Actions**:
  1. Parse the user request or incident symptom.
  2. Check existing issue log in `.agents/architecture/ISSUE_TRACKER.md` and `docs/engineering/INCIDENTS_AND_FIXES.md` to see if a similar bug class was documented.
  3. Determine affected modules and assign the primary specialist.
  4. Select the optimal model tier (`flash_lite` for inspection, `flash` for standard fixes, `pro` for complex threading).
  5. Provide the specialist with exact file paths and line ranges to prevent expensive broad repo scans.

---

### Stage 2: Targeted Investigation
- **Actor**: Domain Specialist (e.g., `ns-backend`, `ns-cloud`, `ns-ui`)
- **Actions**:
  1. Inspect the assigned code section using `read_file` with precise `StartLine` and `EndLine`.
  2. Inspect relevant test scripts in `tests/`.
  3. Reproduce the defect or verify the root cause.
  4. Formulate a minimal, backwards-compatible solution plan.
  5. **Handoff Artifact**: Investigation Report containing:
     - Exact root cause explanation.
     - Affected file paths and line numbers.
     - Proposed diff outline.
     - Identified edge cases and regression risks.

---

### Stage 3: Minimal Surgical Implementation
- **Actor**: Domain Specialist
- **Actions**:
  1. Make targeted edits using `edit_file`.
  2. Avoid modifying unrelated formatting, comments, or adjacent functions.
  3. Ensure `Set-StrictMode -Version Latest` compliance:
     - Verify property names exist on models/palettes.
     - Avoid taking `.Count` on scalar objects without array wrapping `@()`.
  4. Ensure character encoding compliance:
     - Never insert raw multi-byte unicode characters into `src/NSCloudDrive.ps1`; use `[char]0x...`.
  5. **Handoff Artifact**: Implementation Handoff containing:
     - `git diff` output of the changes.
     - Summary of changes made.
     - Self-test result.

---

### Stage 4: Independent Review
- **Actor**: `ns-reviewer` (Read-Only)
- **Actions**:
  1. Review the git diff against the target files.
  2. Verify strict mode compatibility and character encoding.
  3. Challenge assumptions: "What happens if the drive is offline?", "What happens if the network drops?", "Does this break multi-account isolation?".
  4. Check whether existing tests cover the change or new unit tests are needed.
  5. **Review Verdict**:
     - `APPROVED`: Change is safe, clean, and ready for automated testing.
     - `REJECTED`: Specific defects or risks cited with file links and line ranges. Returned to Stage 3 for remediation.

---

### Stage 5: Test Verification & Evidence Capture
- **Actor**: `ns-tester`
- **Actions**:
  1. Execute the relevant component test suite (e.g., `tests/Test-VirtualDriveManager.ps1`).
  2. Execute master suite probe (`tests/Run-AllTests.ps1`).
  3. Capture the full console output, including test execution time and 0 exit code.
  4. Verify that temporary test directories in `%TEMP%` or `D:\CloudCache` were cleaned up.
  5. **Handoff Artifact**: Test Evidence Block containing:
     - Verbatim command executed.
     - Full stdout/stderr.
     - Exit code (must be 0).
     - Confirmed pass count.

---

## 2. Standard Handoff Schema

All agent-to-agent handoffs must be formatted in structured Markdown:

```markdown
### AGENT HANDOFF: [Task Name]
- **From**: [Sender Agent Name]
- **To**: [Recipient Agent Name]
- **Status**: [INVESTIGATION_COMPLETE | READY_FOR_REVIEW | TESTS_PASSED | REJECTED]
- **Affected Files**:
  - `path/to/file.ps1` (Lines X-Y)
- **Summary**:
  [Concise 2-3 sentence overview]
- **Verification Evidence**:
  ```powershell
  # Actual test run command and output
  ```
- **Action Required by Recipient**:
  [Specific next step]
```

---

## 3. Escalation Rules

1. **Elevation to `pro` Model**:
   - Escalate from `flash` to `pro` when:
     - A bug involves inter-thread communication or CLR / PowerShell runspace threading.
     - A memory leak or deadlock persists after one remediation attempt.
     - Cryptographic authentication (PKCE/OAuth) fails with ambiguous provider errors.
2. **Escalation to User (Human-in-the-Loop)**:
   - Immediately halt and consult the user when:
     - An operation requires deleting user cache directories or tokens.
     - Git commit or push is required.
     - Third-party provider terms or API credentials require browser authentication.
     - Conflicting requirements exist between features.
3. **Loop Defense**:
   - If a specialist fails a test twice on the same fix:
     - DO NOT attempt a third blind edit.
     - Orchestrator halts execution, requests Reviewer analysis, and presents the dilemma to the user.
