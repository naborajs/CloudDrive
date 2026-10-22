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
| Re-audit HTTP dump redaction in the exact pinned source | The pinned `fs/fshttp` helper originally redacted `Authorization` and `X-Auth-Token`, but not request `Cookie` or response `Set-Cookie`; response dumps were logged without passing through the redactor. The project patch now covers those headers and repeated values in the full header block, preserves CRLF boundaries, leaves bodies unchanged, sanitizes response dumps unless explicit `--dump auth` is selected, and adds helper/curl plus long-header/body-preservation synthetic cases. | Fresh public source clone verified at `56bf13885494819bc801302ddf881279bdac7262`; `git apply --check` passed, then patch application and source `git diff --check` passed in an isolated temporary clone. The project patch diff was reviewed. Go is absent, so Go tests—including response-dump integration—and the patched build were not run. Explicit `--dump auth` and body dumps remain sensitive and are not used by the NS Cloud Drive launcher. |
| Inspect pinned backend debug calls and option registry | `fs.Option.Sensitive` exists in the pinned rclone source; backend `debug()` returns when `DebugLevel < level`; `NewFs` contains the complete-options debug call removed by the patch. | Source review only. The patch pins backend debug level to zero, disabling all backend-specific debug traces. |
| Review Microsoft WebView2 authentication and profile guidance | WebView2 supports a persistent per-app user data folder for cookies/profile data; Microsoft warns against scraping cookies or tokens from embedded login flows and recommends the system browser or OS broker for OAuth. | Official documentation review only. No WebView2 dependency, login flow, profile, or persistence test was created. Persistent browser cookies do not provide a backend handoff. |
| Review TeraBox terms and official Open API for a supported bridge | Terms limit access to publicly supported interfaces. Open API docs require separately issued app credentials and scope listing to an application-assigned folder; the published device-code docs mark `user_code` and `verification_url` unavailable. | Official documentation review only. No application request or OAuth request was made; no existing-root scope was established. No legal conclusion is made about cookie replay. |
| Recheck local auth/build prerequisites | Git is present; Go, MinGW GCC/G++, and `rclone.exe` are missing. Standard WinFsp x64 runtime DLL and FUSE header are absent. `MachinePolicy` and `UserPolicy` are `Undefined`; `LocalMachine` execution policy is `RemoteSigned`. | Read-only command/path probes. No software was installed and no execution policy was changed. |
| Decide whether to implement WebView2-to-rclone session handoff | Stopped: the pinned backend documents manual cookie configuration and has no supported session handoff or renewal. Cookie extraction/replay is not established as a publicly supported TeraBox integration. | Feasibility decision from source and official documentation only. No cookie was extracted, no account was authenticated, and no browser/backend bridge was tested. |
| Parse `scripts/Build-PatchedRclone.ps1` with the PowerShell parser | Passed. | Syntax only; build was not run. |
| Run the original `scripts/Build-PatchedRclone.ps1` with the original cgo prerequisites | Reproduced exact first error: `Exception: ...\scripts\Build-PatchedRclone.ps1:23` followed by `WinFsp FUSE development header fuse.h was not found under: C:\Program Files (x86)\WinFsp\inc\fuse`. The build root did not exist afterward. | Stopped at its first preflight guard, before source clone/download or build. This triggered review of the no-cgo route; no installation or source build occurred. |
| Parse and rerun revised `scripts/Build-PatchedRclone.ps1` using `CGO_ENABLED=0` | PowerShell parser passed. Helper now stops with `Required build tool is missing from PATH: go`; the build root did not exist afterward. The manifest code records Go version and `cgoEnabled: false`. | Confirms syntax, manifest fields, and missing-Go fail-fast behavior only. No source clone, Go compilation, provider-list check, or mount occurred. The revised no-cgo route is not yet built against this exact source tag. |
| Re-run the revised builder in the current Windows session | Blocked before the helper ran: PowerShell returned `AuthorizationManager check failed`. `Get-ExecutionPolicy -List` reports `RemoteSigned` at `LocalMachine`, with no policy set at the other scopes. | No execution-policy changes were made. This attempt does not test Go availability or build compatibility; the separately recorded missing-Go preflight remains the latest helper-level build result. |
| Check pinned Windows mount dependency for a no-cgo route | Pinned `go.mod` uses `github.com/winfsp/cgofuse v1.6.1-0.20260126094232-f2c4fccdb286`; current rclone and cgofuse docs describe Windows `CGO_ENABLED=0` support. | Dependency/source and documentation check only. The exact fork/tag compile remains unverified without Go. |
| Compare pinned Windows build workflow with official rclone/cgofuse guidance | Pinned workflow uses Go `1.26.x`, MinGW, WinFsp `v2.1` headers, cgo, and `cmount`; the pinned module uses cgofuse, and current rclone/cgofuse docs describe Windows cgo-disabled `cmount` support. The local builder now tries this route. | Source/documentation comparison and builder edit only. The no-cgo build against this exact fork has not compiled; the upstream workflow still references moving `rsrc@latest` and `master` icon inputs. |
| Inspect exact pinned TeraBox authentication docs and code | The backend README requires copying a full website cookie or `ndus` from a browser via an extension or developer tools. Source sends the configured value as an HTTP `Cookie` header; no interactive login or refresh flow exists. README claims a one-year cookie lifetime, which is maintainer-reported and unverified. The constructor's original level-1 debug call logged the full options struct. | Exact pinned source/docs review at `56bf13885494819bc801302ddf881279bdac7262`; no authentication was attempted and no credential was obtained or used. The patch's Go tests and build remain unrun. Browser-cookie copying is not an approved NS Cloud Drive login flow. |
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
- `74511e7` — record pinned TeraBox login limitation.
- `a34ef6c` — redact sensitive headers throughout HTTP headers.
- `7f8afcd` — update cookie dump redaction status.
- `7b29561` — add provider connection state model.
- `592c65b` — add connection state machine tests.
- `4a48855` — add TeraBox provider implementation.
- `6eb8ad6` — add TeraBox provider tests.
- `4fdaee7` — add Google Drive provider implementation.
- `6985124` — add Google Drive provider tests.
- `4f2b199` — add virtual drive manager service.
- `9cfc82a` — add virtual drive manager tests.
- `e224f60` — add shared provider connection UI window.
- `387ddc8` — integrate provider connection flows in desktop UI.
- `ec77719` — add automated test suite runner.
- `0d54aa9` — add Google OAuth client configuration check and non-blocking listener.
- `300ba8d` — validate Google OAuth configuration and wrap connection dialog controls.
- `3fd44d2` — resolve read-only pid variable conflict and prevent desktop layout overflow.
- `8c0ad13` — add OAuth client configuration and empty client ID validation tests.
- `4e93d57` — add desktop UI regression tests for pid conflict and scroll constraints.
- `fb7f73b` — register desktop UI regression test suite in test runner.
- `4286cba` — implement PKCE challenge and flexible desktop client config discovery for Google OAuth.
- `050b74a` — add PKCE S256 test vector and installed client json discovery tests.
- `a84bd4f` — add Google OAuth setup guide dialog and PKCE authorization workflow.
- `1157710` — replace misleading TeraBox web login with truthful feasibility interface.

## Automated test suite verification

Run `powershell.exe -NoProfile -File .\tests\Run-AllTests.ps1`:
- `Test-ConnectionState.ps1`: Verified 10 connection states, valid state machine transitions, fail-closed invalid transition rejection, and sensitive credential sanitization.
- `Test-TeraBoxProvider.ps1`: Verified provider metadata, fail-closed handling without session, DPAPI-protected session persistence and clean deletion, and account scope validation.
- `Test-GoogleDriveProvider.ps1`: Verified provider metadata, cryptographic state generation entropy and URL-safety, RFC 7636 PKCE S256 verifier and official Appendix B test vector challenge computation, fail-closed handling without tokens, DPAPI-protected token persistence and clean deletion, Google installed client format JSON discovery without requiring client secret, and OAuth authorization URL construction with PKCE challenge.
- `Test-VirtualDriveManager.ps1`: Verified rclone binary discovery, WinFsp runtime and service detection, drive availability checks, and read-only VFS cache mount argument formatting.
- `Test-DesktopUIRegression.ps1`: Verified that no read-only `$pid` parameter declarations exist in `src/`, that `NSCloudDrive.ps1` and `ProviderConnectionWindow.ps1` explicitly disable horizontal scrollbar measurement to prevent layout overflow, and that `NSCloudDrive.ps1` loads cleanly in an STA session.
- `Test-RcloneConfigPassword.ps1`: Verified synthetic DPAPI read-back, plaintext-at-rest absence, user/SYSTEM private ACLs, and missing-credential fail-closed behavior.

**Result: 6 Passed, 0 Failed.**

## Required next evidence

1. Interactive local user sign-in through the TeraBox dedicated connection window (`Show-ProviderConnectionWindow 'terabox'`) and Google OAuth 2.0 flow (`Show-ProviderConnectionWindow 'gdrive'`).
2. Test File Explorer visibility of `T:\` and read an existing file once live account validation completes.
3. Keep writable mode disabled until read-only acceptance gates are satisfied.
