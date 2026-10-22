# Commands and verification record

**Updated:** 2026-10-22. This records checks actually run; it does not certify an account mount.

| Check | Result | Scope / limitation |
| --- | --- | --- |
| Inspect the supplied `terabox-drive-starter` README, five scripts, and six research files | Completed. | Starter read-only mount scaffold and plans were preserved as references; the original sign-in task was not run. |
| Verify CloudDrive branch, origin, and working tree | `main`, origin is `https://github.com/naborajs/CloudDrive.git`, clean after each push. | Current Git state only. |
| `git ls-remote --symref` on requested backend repositories and REA | Current ref hashes and tags recorded in [FEASIBILITY.md](FEASIBILITY.md). | Read-only GitHub ref query; no repository binary downloaded or executed. |
| Inspect requested TeraBox backend Go source and docs | Confirmed source paths for listing, range-aware open, upload, move/copy, and delete; found cookie/debug exposure and unsupported zero-byte/unknown-size writes. | Static review only; methods were not called against TeraBox. |
| Parse the supplied five PowerShell starter scripts | All five parsed. | Syntax check only; no mount or account operation. |
| Parse `src/NSCloudDrive.ps1` with `System.Management.Automation.Language.Parser` | Passed. | Does not prove rendered UI or button behavior. |
| Load WPF runtime assemblies with Windows PowerShell in STA mode | Passed. | Assembly-load smoke check only; the preview window was not visually or interactively acceptance-tested. |
| `Get-Command rclone.exe, go.exe, dotnet.exe, node.exe` | Only `dotnet.exe` and `node.exe` found (Git is also installed). | rclone and Go are absent from PATH. |
| `dotnet --list-sdks` | No SDKs returned. | .NET runtime is present, SDK is not. |
| `dotnet --list-runtimes` | `Microsoft.NETCore.App 8.0.21`. | No .NET 10 runtime/SDK verification. |
| Check `D:\` readiness and filesystem | `D:\` exists, is a fixed NTFS volume, about 124 GiB available at check time. | Space is time-varying; no cache directory was created. |
| Check standard WinFsp x64 DLL path | Not found. | WinFsp is not installed at the standard path; no mount was attempted. |
| Check Windows WPF framework assembly path | `PresentationFramework.dll` exists. | Framework assembly availability does not validate the app's visual behavior. |
| Attempt `Get-CimInstance Win32_LogicalDisk` | Denied by the environment. | Used .NET `DriveInfo` for local volume readiness/free-space evidence instead. |
| TeraBox sign-in/list/read/write, Windows mount/Explorer visibility, cache eviction, disconnect recovery | Not run. | No backend-enabled binary, WinFsp, account session, or authorized live account test was used. |
| Install software, create startup task/service, change registry, or modify remote data | Not performed. | None was necessary for the checks above. |

## Git commits pushed

Each commit changed one file and was pushed to `origin/main`:

- `aeb1173` — branded Windows setup preview.
- `0abbdb3` — Windows implementation plan.
- `4d3175c` — preview launch/limitations in README.
- `cb0634a` — remove unnecessary execution-policy bypass from launch command.
- `330d70b` — current backend feasibility audit.
- `4914cb4` — backend compatibility matrix.
- `7023470` — Windows desktop architecture decision.

## Required next evidence

1. Pin the selected backend tag/commit and review license notices.
2. Patch cookie sensitivity and secret-safe debug output; add synthetic-secret tests.
3. Build and inspect a backend-enabled Windows binary with WinFsp mount support.
4. Verify provider registration without exposing config, then perform user-controlled read-only account tests locally.
5. Only after read tests pass, run disposable writable/recovery/cache tests and update this record with exact versions and observed results.
