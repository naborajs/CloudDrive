# NS Cloud Drive - Credit & Resource Optimization Guide

This guide defines the resource management rules, token-saving controls, and model tier allocation policies for the NS Cloud Drive engineering architecture.

---

## 1. Model Tier Selection Matrix

Antigravity supports four model routing options when invoking subagents via `invoke_subagent`. Match each task to the lowest-cost model capable of executing it reliably:

| Model Tier | Cost Profile | Latency | Recommended Use Cases in NS Cloud Drive | Strictly Prohibited Use Cases |
| :--- | :--- | :--- | :--- | :--- |
| **`flash_lite`** | Ultra-Low (~15% of Pro) | Very Fast (<2s) | - Routine diagnostic checks<br>- Reading documentation/ADRs<br>- Parsing log files for error patterns<br>- Validating JSON schema structures<br>- Initial file path discovery | - Modifying core concurrency code<br>- Complex cryptographic logic<br>- Multi-file refactoring<br>- Independent diff review |
| **`flash`** | Low (~30% of Pro) | Fast (2-5s) | - Running automated unit test suites<br>- Targeted edits in UI / XAML / styles<br>- Cache utility functions (`CacheManager.ps1`)<br>- Unit test suite authorship<br>- Standard API endpoint mapping | - Concurrency root-cause debugging<br>- Final quality gate approvals |
| **`pro`** | Standard (100%) | Moderate (5-15s) | - Multithreading & Runspace TLS analysis<br>- WinFsp / rclone low-level driver interactions<br>- Windows EventViewer crash dump diagnosis<br>- DPAPI & RFC 7636 PKCE crypto validation | - Simple text searches<br>- Formatting documentation<br>- Running pre-written test scripts |
| **`inherit`** | Same as Parent | Variable | - Lead Orchestrator planning<br>- Independent Reviewer final diff audit<br>- Conversational interaction with user | - Routine maintenance chores |

---

## 2. Anti-Patterns & Resource Leaks to Avoid

### Anti-Pattern 1: The Blind Recursive Scan
- **Bad**: Running `Get-ChildItem -Recurse` across the entire project directory.
- **Why**: Loads thousands of file names, builds massive pipeline buffers, wastes token context, and slows response time.
- **Rule**: Orchestrator must provide explicit file paths (e.g. `src/services/CacheManager.ps1`) and line bounds.

### Anti-Pattern 2: The Monolithic Context Dump
- **Bad**: Reading all 7,000+ lines of `src/NSCloudDrive.ps1` to change a 5-line button handler.
- **Why**: Consumes ~25,000+ tokens per read, rapidly exhausting model context and bloating credit usage.
- **Rule**: Use targeted search (`Select-String` or grep) to locate the exact line range, then call `read_file` with `StartLine` and `EndLine` bounded to $\pm 30$ lines of context.

### Anti-Pattern 3: Unbounded Subagent Spawning
- **Bad**: Spawning 5-8 subagents concurrently to explore different features.
- **Why**: Multiplies token consumption exponentially, causes git workspace lock contention, and creates overlapping file edits.
- **Rule**: Maximum of **2 subagents** active concurrently. When subagents perform interdependent work, execute sequentially with structured handoffs.

### Anti-Pattern 4: The Polling Loop
- **Bad**: Calling `Start-Sleep -Seconds 2` in a while loop to check process status or file existence.
- **Why**: Burns compute cycles, risks hitting tool timeout limits, and clutters logs.
- **Rule**: Rely on Antigravity's reactive wakeup mechanism or bounded single-shot checks.

---

## 3. Token Budgeting by Task Type

| Engineering Task | Target Token Budget | Recommended Agent Flow |
| :--- | :--- | :--- |
| **Simple Bug Fix (Single File)** | < 12,000 tokens | 1. `ns-orchestrator` plans (2k tokens)<br>2. Specialist inspects & edits (5k tokens, `flash`)<br>3. `ns-reviewer` audits diff (2k tokens, `inherit`)<br>4. `ns-tester` verifies (3k tokens, `flash`) |
| **Component UI Enhancement** | < 18,000 tokens | 1. `ns-orchestrator` plans (3k tokens)<br>2. `ns-ui` inspects & edits (8k tokens, `flash`)<br>3. `ns-reviewer` audits diff (3k tokens, `inherit`)<br>4. `ns-tester` verifies (4k tokens, `flash`) |
| **Deep Concurrency / Crash Fix** | < 28,000 tokens | 1. `ns-orchestrator` plans (4k tokens)<br>2. `ns-backend` diagnoses with `pro` (12k tokens)<br>3. `ns-reviewer` scrutinizes safety (5k tokens)<br>4. `ns-tester` verifies test suite (7k tokens) |
