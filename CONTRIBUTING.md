# Contributing to NS Cloud Drive

Thank you for your interest in contributing to **NS Cloud Drive**!

This project provides a native Windows virtual filesystem manager for Google Drive and TeraBox, developed by **NABORAJ SARKAR**.

---

## Code of Conduct

Please be respectful, constructive, and considerate when submitting issues or pull requests.

---

## Architecture & Engineering Principles

Before making changes, please familiarize yourself with the project's engineering principles:

1. **Strict Mode Enforcement**:
   - All PowerShell modules (`src/`, `tests/`) must run cleanly under `Set-StrictMode -Version Latest`.
   - Accessing undefined properties or taking `.Count` on scalar/null objects is a terminating error. Guard with `@($items).Count` or explicit `if ($items)`.

2. **Character Encoding Rules**:
   - `src/NSCloudDrive.ps1` **MUST NEVER contain raw multi-byte unicode characters**.
   - Always use `[char]0x...` syntax (e.g., `[char]0x2807` for drag grips, `[char]0x25B2` for triangles) to prevent codepage corruption across different Windows locales.

3. **Thread Safety & Dispatcher Rules**:
   - Background threads must never touch WPF UI elements directly. Always route through `$window.Dispatcher.Invoke(...)`.
   - Never pass PowerShell `ScriptBlock` to `[System.Threading.ThreadPool]::QueueUserWorkItem`. Always use compiled C# helper classes via `Add-Type`.

4. **Security & DPAPI Credentials**:
   - Secrets, tokens, and cookies must never be logged or written in plaintext.
   - Credentials must use DPAPI-backed `PSCredential` storage with strict per-user ACLs.

---

## Development Setup

### Prerequisites
- **Windows 10 / 11** (64-bit).
- **WinFsp**: Windows File System Proxy (v2.0 or later).
- **Microsoft .NET Framework 4.8** (pre-installed on Windows 10/11).
- **rclone** (v1.65 or later).

### Running from Source
To launch the desktop application directly from PowerShell:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\src\NSCloudDrive.ps1
```

Or run the convenience launcher:
```cmd
.\NSCloudDrive.cmd
```

---

## Running the Automated Test Suites

NS Cloud Drive includes a comprehensive automated regression suite. All tests must pass before submitting a pull request:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-VirtualDriveManager.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SettingsManager.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-BackendCorrectnessAndSync.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CacheManagement.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CloudTransferManager.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-OptionsPage.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-SecurityAudit.ps1
```

---

## Building the Executable Launcher

To compile the standalone `NSCloudDrive.exe` binary:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Executable.ps1
```

---

## Reporting Issues & Feature Requests

- **Bug Reports**: Open an issue at [GitHub Issues](https://github.com/naborajs/CloudDrive/issues/new) using the Bug Report template.
- **Contact**: For project inquiries, reach out to NABORAJ SARKAR at `nishant.ns.business@gmail.com`.
