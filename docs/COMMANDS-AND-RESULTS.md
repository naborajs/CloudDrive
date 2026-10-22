# Commands and verification record

**Updated:** 2026-10-22. This records checks actually run; it does not certify an account mount.

| Check | Result | Scope / limitation |
| --- | --- | --- |
| Inspect the supplied `terabox-drive-starter` README, five scripts, and six research files | Completed. | Starter read-only mount scaffold and plans were preserved as references; the original sign-in task was not run. |
| Verify CloudDrive branch, origin, and working tree | `main`, origin is `https://github.com/naborajs/CloudDrive.git`, clean after each push. | Current Git state only. |
| Verify repository ignore rules with `git check-ignore --no-index --verbose` | Passed for representative env files, cookie/session/token files, rclone config, credential folder, cache, logs, build/dist folders, executable, and generated build manifest. | Path-pattern check only; no secret files were created or read. |
| `git ls-remote --symref` on requested backend repositories and REA | Current ref hashes and tags recorded in [FEASIBILITY.md](FEASIBILITY.md). | Read-only GitHub ref query; no repository binary downloaded or executed. |
| Shallow-clone `gulp79/rclone-extra` tag `v1.75.2-extra` and verify `HEAD` | `56bf13885494819bc801302ddf881279bdac7262`. | Public source checkout only; no release binary was downloaded or executed. |
| Recheck Windows build prerequisites | Git `2.55.0.windows.2` is present. Go, `x86_64-w64-mingw32-gcc`, `x86_64-w64-mingw32-g++`, `rclone.exe`, standard WinFsp x64 runtime DLL, and WinFsp `fuse.h` are absent. `dotnet.exe` exists but no .NET SDK is installed; neither is a Go-build prerequisite. | Command/path probes only; nothing installed. The exact standard WinFsp locations checked are recorded in [FEASIBILITY.md](FEASIBILITY.md). |
| Apply the committed cookie-safety patch to a clean detached worktree at that tag | `git apply --check`, patch application, and `git diff --check` passed; the changed source file is `backend/terabox/terabox.go`. | Static patch-application test only; no Go compiler is installed and no runtime secret-redaction test ran. |
| Re-audit HTTP dump redaction in the exact pinned source | The pinned `fs/fshttp` helper originally redacted `Authorization` and `X-Auth-Token`, but not request `Cookie` or response `Set-Cookie`; response dumps were logged without passing through the redactor. The project patch now adds those headers, handles repeated matching header lines, sanitizes response dumps unless explicit `--dump auth` is selected, and adds synthetic helper/curl unit cases. | Public source clone verified at `56bf13885494819bc801302ddf881279bdac7262`; `git apply --check` passed, then patch application and source `git diff --check` passed in an isolated temporary clone. The project patch diff was reviewed. The sanitizer retains the upstream 4 KiB search window. Go is absent, so tests—including response-dump integration—and the patched build were not run. Explicit `--dump auth` remains a sensitive opt-in and is not used by the NS Cloud Drive launcher. |
| Inspect pinned backend debug calls and option registry | `fs.Option.Sensitive` exists in the pinned rclone source; backend `debug()` returns when `DebugLevel < level`; `NewFs` contains the complete-options debug call removed by the patch. | Source review only. The patch pins backend debug level to zero, disabling all backend-specific debug traces. |
| Parse `scripts/Build-PatchedRclone.ps1` with the PowerShell parser | Passed. | Syntax only; build was not run. |
| Run the original `scripts/Build-PatchedRclone.ps1` with the original cgo prerequisites | Reproduced exact first error: `Exception: ...\scripts\Build-PatchedRclone.ps1:23` followed by `WinFsp FUSE development header fuse.h was not found under: C:\Program Files (x86)\WinFsp\inc\fuse`. The build root did not exist afterward. | Stopped at its first preflight guard, before source clone/download or build. This triggered review of the no-cgo route; no installation or source build occurred. |
| Parse and rerun revised `scripts/Build-PatchedRclone.ps1` using `CGO_ENABLED=0` | PowerShell parser passed. Helper now stops with `Required build tool is missing from PATH: go`; the build root did not exist afterward. The manifest code records Go version and `cgoEnabled: false`. | Confirms syntax, manifest fields, and missing-Go fail-fast behavior only. No source clone, Go compilation, provider-list check, or mount occurred. The revised no-cgo route is not yet built against this exact source tag. |
| Re-run the revised builder in the current Windows session | Blocked before the helper ran: PowerShell returned `AuthorizationManager check failed`. `Get-ExecutionPolicy -List` reports `RemoteSigned` at `LocalMachine`, with no policy set at the other scopes. | No execution-policy changes were made. This attempt does not test Go availability or build compatibility; the separately recorded missing-Go preflight remains the latest helper-level build result. |
| Check pinned Windows mount dependency for a no-cgo route | Pinned `go.mod` uses `github.com/winfsp/cgofuse v1.6.1-0.20260126094232-f2c4fccdb286`; current rclone and cgofuse docs describe Windows `CGO_ENABLED=0` support. | Dependency/source and documentation check only. The exact fork/tag compile remains unverified without Go. |
| Compare pinned Windows build workflow with official rclone/cgofuse guidance | Pinned workflow uses Go `1.26.x`, MinGW, WinFsp `v2.1` headers, cgo, and `cmount`; the pinned module uses cgofuse, and current rclone/cgofuse docs describe Windows cgo-disabled `cmount` support. The local builder now tries this route. | Source/documentation comparison and builder edit only. The no-cgo build against this exact fork has not compiled; the upstream workflow still references moving `rsrc@latest` and `master` icon inputs. |
| Inspect exact pinned TeraBox cookie path | Backend config requires full website cookie or `ndus`; the constructor logs the full options struct at backend debug level 1, and API requests send the option as the HTTP `Cookie` header. No cookie renewal flow was found; invalid-cookie errors are not a refresh flow. | Pinned source review only. No cookie was obtained or used; patched build and synthetic-secret log/config-redaction checks remain unrun. |
| Check pinned release asset trust evidence | GitHub release metadata publishes a Windows ZIP SHA-256; a signed/verified source tag is shown. No binary signature or build attestation was established. | Metadata/source inspection only. Asset not downloaded or executed; checksum alone does not verify publisher build provenance. |
| Parse `scripts/Start-ReadOnlyMount.ps1` with the PowerShell parser | Passed. | Syntax only; no mount was attempted. |
| Exercise the extracted read-only cache-path validator in Windows PowerShell | Passed for an ordinary local NTFS path; it rejected a volume root, UNC path, existing junction ancestor, and file path component. | Isolated function checks only; no cache directory was created and no mount was started. |
| Parse `scripts/RcloneConfigPassword.ps1` and exercise its missing-credential path | Passed; the helper exits with a clear error when its DPAPI credential file is absent. | Output was suppressed. No actual config password or provider session was used. |
| Synthetic DPAPI export/import and helper read-back in the current PowerShell host | Passed; compared the generated value in memory and did not print it. The temporary fixture was removed. | Tests the read helper and Windows DPAPI in this host, not the interactive `-Store` ACL branch. |
| Run `scripts/Test-RcloneConfigPassword.ps1` | Passed; repeatably checks synthetic DPAPI serialization/read-back, plaintext absence, user-and-SYSTEM ACLs on a temporary directory and file, and missing-credential failure; removes the fixture. | Does not exercise the interactive `-Store` prompt or the separate Windows PowerShell process. |
| Run the helper as a separate Windows PowerShell process | Blocked by this environment with `AuthorizationManager check failed`. | Does not establish a product defect or a pass; the launcher/password-command subprocess integration remains unverified. No rclone process or mount was involved. |
| Parse `scripts/Manage-UserMountStartup.ps1` and exercise its safety gate | Passed; it refuses registration without `-ReadOnlyAcceptancePassed`. No task with the reserved name existed. | Task registration, removal, scheduled retries, and logon mount were not run. Build/config prerequisites are absent. |
| Parse `src/NSCloudDrive.ps1` and exercise extracted setup-diagnostic functions | Passed; no verified pinned build was found, T: reported available, and D: reported NTFS with about 124 GiB free. | Function-level checks only; the WPF window was not launched, and no mount/cache directory was created. |
| Run the mount launcher without a built artifact | Safely stopped because `rclone.exe` and its build manifest are absent; the configured cache directory remained unchanged. | No config was read, no account authentication occurred, and no mount was started. |
| Inspect requested TeraBox backend Go source and docs | Confirmed source paths for listing, range-aware open, upload, move/copy, and delete; found cookie/debug exposure and unsupported zero-byte/unknown-size writes. | Static review only; methods were not called against TeraBox. |
| Review TeraBox official Open API integration documentation | Confirmed documented OAuth/device-code QR flow, separate client credential application, short-lived access/refresh tokens, and an assigned-application directory boundary. The current localized device-code docs say `user_code` and `verification_url` are unavailable and describe Base64 QR plus polling. | Documentation review only; no application request, token call, app approval attempt, or account access; no evidence of compatibility with the existing full drive or the consent UX. |
| Clone and inspect `mill-master/rclone-terabox` at `38482fe6bdabae350c627a43d3a4f57691bfb725` | Its QR helper calls website `/passport/qrcode/*` endpoints with Chrome-like headers, extracts `ndus`, passes it on the `rclone config create/update` argument list, and saves to regular config. | Source review only. The helper was not executed or adapted because it imitates a browser and exposes session data in process arguments/config. |
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
- `0bdeb8e` — pinned TeraBox cookie-safety patch.
- `68712f2` — pinned source audit results.
- `b0cbd90` — refine pinned cookie-safety patch.
- `7a43a0c` — add pinned Windows source builder.
- `4e376c8` — document build prerequisites and limits.
- `e806866` — record builder preflight result.
- `e71fa70` — qualify patched backend security status.
- `0beef0f` — add read-only mount launcher.
- `372738f` — document manual mount test.
- `7431a93` — record read-only launcher checks.
- `a916c3d` — document mount security boundaries.
- `d3559c4` — link acceptance gates to the scripts.
- `5e5fd46` — complete recent commit record.
- `ddcbf32` — clarify official Open API scope.
- `d08d3f6` — compare official API option.
- `9539dcb` — distinguish official OAuth from unofficial backend.
- `38d81fd` — record official API research.
- `a20c860` — reject browser-mimicking QR login helper.
- `bfdad0e` — reject unsafe QR session handling.
- `45714f1` — gate acceptance on compliant authentication.
- `54bf793` — add DPAPI-protected rclone config unlock helper.
- `e3d50de` — use local config unlock helper in the read-only launcher.
- `b6b18e1` — document local encrypted config unlock.
- `d54ef8b` — add gated per-user mount startup manager.
- `410ddda` — document opt-in read-only logon mounting.
- `c3de7ab` — update security notes for startup support.
- `42ff8fb` — clarify DPAPI helper test coverage.
- `20933d8` — add safe DPAPI helper self-test.
- `448e28f` — test DPAPI credential ACL policy.
- `1e08624` — record private credential ACL test.
- `7ae62dc` — record credential ACL self-test evidence.
- `5b43e6e` — document DPAPI helper regression command.
- `947fa3c` — add verified build and cache diagnostics.
- `2ecc9db` — document preview readiness diagnostics.
- `c9b3ab0` — clarify official TeraBox OAuth limitations.
- `0d10f2f` — ignore local credentials and runtime artifacts.
- `a1191aa` — reject unsafe read-only mount cache paths.
- `bb44e2f` — document read-only cache path guard.
- `7dabb23` — share cache path validation logic.
- `409d3c6` — record pinned backend build and auth blockers.
- `d206c42` — record exact Windows build preflight blocker.
- `a450a0e` — gate mount testing on build and auth evidence.
- `46ef5be` — document pinned TeraBox auth and log limits.
- `4c1ade9` — add exact local backend build prerequisites.
- `dae1386` — build Windows cmount without cgo toolchain.
- `68a2ed7` — update backend plan for no-cgo build.
- `1a02d4e` — document no-cgo Windows backend build.
- `9153dd0` — record no-cgo source build route.
- `0441474` — record revised no-cgo builder checks.
- `58b34cb` — update build acceptance prerequisites.
- `56290ec` — record Go toolchain in build manifest.
- `3372d40` — document build manifest evidence fields.
- `92795c3` — clarify build manifest verification scope.
- `1fb4d03` — record current builder execution policy block.
- `f9edfca` — redact TeraBox cookies from HTTP dumps.
- `23ba3c4` — document expanded cookie dump redaction.
- `5af6ea8` — record pinned HTTP redaction audit.
- `6d8d2e2` — clarify HTTP dump redaction limits.

## Required next evidence

1. After Go 1.26+ is installed locally, run the revised cgo-free pinned builder and verify the source commit, patch, Windows `cmount` tag, provider registration, and manifest. Install WinFsp runtime before any mount test; MinGW and Developer headers are not prerequisites for this builder path.
2. Test the DPAPI interactive save flow and native Windows PowerShell subprocess on an unrestricted Windows session; add/run synthetic-secret tests for backend config redaction and diagnostics.
3. Audit the exact pinned build's license notices; then verify provider registration. A compliant TeraBox sign-in path remains a blocker before any account access.
4. After compliant authentication is available, perform user-controlled read-only account tests locally; only then consider disposable writable/recovery/cache tests and record exact versions and observed results.
