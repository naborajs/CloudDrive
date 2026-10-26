# NS Cloud Drive - Persistent Quality & Regression Checklist

This checklist must be executed and satisfied before any milestone, bug fix, or feature is approved.

---

## The 10-Point Verification Checklist

### 1. Root Cause Identification
- [ ] Root cause identified via source analysis, EventViewer logs, or reproducible test case.
- [ ] Documented in `.agents/architecture/ISSUE_TRACKER.md` and `docs/engineering/INCIDENTS_AND_FIXES.md`.

### 2. Surgical, Bounded Edit
- [ ] Changes are minimal and confined to the target module.
- [ ] No unrelated formatting, comment stripping, or whitespace churn.
- [ ] Git diff reviewed: `git diff --stat` shows expected file bounds.

### 3. Strict Mode Compliance (`Set-StrictMode -Version Latest`)
- [ ] Every property accessed on models/palettes is verified to exist.
- [ ] No `.Count` calls on un-wrapped scalar objects (always use `@($collection).Count`).
- [ ] No uninitialized variables or missing hashtable keys.
- **Verification Command**:
  ```powershell
  powershell.exe -NoProfile -Command "Set-StrictMode -Version Latest; $ErrorActionPreference='Stop'; . ./src/NSCloudDrive.ps1 -SyntaxCheckOnly"
  ```

### 4. Character Encoding Safety
- [ ] `src/NSCloudDrive.ps1` contains ZERO raw multi-byte unicode characters.
- [ ] All checkmarks, bullets, arrows, and symbols use `[char]0x...` syntax.
- **Verification Command**:
  ```powershell
  powershell.exe -NoProfile -Command "$c = [System.IO.File]::ReadAllText('src/NSCloudDrive.ps1'); if ($c -match '[\u0080-\uFFFF]') { throw 'Raw non-ASCII unicode characters detected!' } else { Write-Host 'Character encoding clean.' }"
  ```

### 5. CLR Threadpool & Concurrency Safety
- [ ] No PowerShell `ScriptBlock` passed to `[System.Threading.ThreadPool]::QueueUserWorkItem`.
- [ ] Any native CLR threadpool offloading uses compiled C# classes via `Add-Type`.
- [ ] No UI control manipulation from background runspaces without `Dispatcher.Invoke`.

### 6. File Lock Detection & In-Use Protection
- [ ] Cache cleanup or eviction probes file locks using `Test-FileInUse` (FileShare.None).
- [ ] Active uploads and locked files are protected from accidental deletion.
- [ ] User cache roots and reparse points are never deleted.

### 7. Security & Secret Redaction
- [ ] Zero Bearer tokens, OAuth client secrets, or cookies in log files, terminal outputs, or code.
- [ ] All tokens encrypted via DPAPI (`CurrentUser` scope).
- [ ] Cache directory paths validated against path traversal (`..` and reparse points).

### 8. Automated Unit Test Verification
- [ ] Module-specific test suite passes with exit code 0.
- [ ] Zero test regressions across existing 32 test suites.
- **Verification Command**:
  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Test-<ComponentName>.ps1
  ```

### 9. Independent Review Sign-Off
- [ ] Diff audited by `ns-reviewer`.
- [ ] Edge cases, error handling, and backwards compatibility verified.
- [ ] Reviewer issued explicit `APPROVED` verdict.

### 10. Clean Cleanup & Documentation
- [ ] All temporary test files in `%TEMP%` or `D:\CloudCache` removed.
- [ ] Documentation updated.
- [ ] User authorization obtained before any git commit or push.
