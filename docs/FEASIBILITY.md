# TeraBox virtual-drive feasibility

**Research date:** 2026-10-22
**Status:** Phase 1 source audit in progress; no Windows mount or account test has passed.

## Decision

A Windows virtual drive is technically plausible with rclone and WinFsp. The selected full-drive backend is unofficial and depends on a web-session credential. TeraBox also documents an official Open API with QR/device authorization, but it requires a separately registered app and confines file paths to an application-assigned directory; the docs do not establish access to the user's existing full drive. No backend is verified against this Windows PC or the user's account. Keep the mount action disabled until the chosen scope, secret handling, Windows build, and read-only live test pass.

For a future Windows build, `gulp79/rclone-extra` is currently the strongest source candidate of those reviewed because it publishes signed rclone-based releases and contains the TeraBox backend. This is a **candidate, not an approved binary or verified Windows release**. The requested `derrundetisch/rclone-extra` repository is a separate fork with an older source tag and its README points users to `gulp79`'s releases. The `mill-master/rclone-terabox` project offers a QR login helper but its own documented build and mount instructions target Linux/macOS and FUSE. None is independently validated against a live account.

No cookies, passwords, account files, or remote data were read or requested for this audit.

## Repository identity and release evidence

These refs were checked read-only with `git ls-remote --symref` on 2026-10-22:

| Repository | Default branch / observed ref | Release evidence | Finding |
| --- | --- | --- | --- |
| [`derrundetisch/rclone-extra`](https://github.com/derrundetisch/rclone-extra) | `master` at `76d99f693b579f43dccc90c3aebe0a5c6a92f27e`; this is tag `v1.73.4-extra` | No tags returned for this repository. README release badge points to `gulp79/rclone-extra`. | Public unofficial fork; backend source exists. Do not treat `gulp79` assets as assets published by this fork. |
| [`gulp79/rclone-extra`](https://github.com/gulp79/rclone-extra) | `master` at `97735670d0eb9b1a2da7fe597243ae3f9feb967d` | `v1.75.2-extra` at `56bf13885494819bc801302ddf881279bdac7262`, GitHub release marked signed/verified on 2026-10-09; release says 12 commits have since landed on `master`. | More current source/release cadence among these rclone-extra repos. Release page lists 12 assets, but the Windows asset's backend/build flags and provenance were not verified. |
| [`mill-master/rclone-terabox`](https://github.com/mill-master/rclone-terabox) | `main` at `38482fe6bdabae350c627a43d3a4f57691bfb725` | No tags/releases returned. README reports 3 commits. | Separate wrapper around x1arch backend. Build script defaults to rclone `v1.75.0`; README specifies Linux/macOS, Python 3, and FUSE for mounting. |
| [`rclone/rclone` PR #8508](https://github.com/rclone/rclone/pull/8508) | Pull request branch `x1arch:backend/terabox` at `d00cbdf4946b8e80b8c78e9f49b4092214750b38` | Still open when checked. | Author labels the integration unofficial, alpha, unfinished, and not tested for all scenarios. |

The `derrundetisch` README explicitly says it is an unofficial fork, attributes TeraBox to x1arch, and directs its release badge to `gulp79`. `gulp79` and `mill-master` both incorporate x1arch's TeraBox implementation. Their shared ancestry means their READMEs are not independent evidence of protocol correctness.

## Official Open API alternative

TeraBox's [Open API integration documentation](https://www.terabox.com/integrations/docs/chinese) describes authorization-code and device-code QR flows. It says an integration vendor must separately apply for `client_id`, `client_secret`, and `private_secret`; the access token lasts two days and refresh tokens last 30 days, with each refresh token usable once. The same docs constrain file paths to the directory assigned to that application under `From: Other Applications/...` (the list API likewise requires a path under the assigned application ID). The current [localized device-code documentation](https://www.terabox.com/integrations/docs/indonesian) says the `user_code` and `verification_url` values are not available; it documents a Base64 QR response and an interval for polling. A supported-looking OAuth protocol therefore still needs app approval and its actual user-consent UX must be confirmed with TeraBox.

This is a documented official OAuth integration option, unlike the website-cookie backend. It may be suitable for a future app-specific folder, but we have no application credentials and no evidence that this API can access the user's existing TeraBox root or provide the requested full-drive view. The project therefore keeps the unofficial backend as a **research candidate** for the full-drive scope while recording the official API as a separate, potentially narrower provider option. No OAuth request was made, no app was registered, and the app-approval process was not attempted.

## Browser-to-backend authentication review (2026-10-22)

**Decision: stop before implementing embedded-browser login or a cookie bridge.** The requested user experience is not supported by a documented, permitted bridge in the sources reviewed.

- Microsoft documents that an unpackaged WebView2 app can keep its browser profile under the current user's `%LOCALAPPDATA%`, and that cookies/profile data persist across app launches. This is browser-profile persistence only; it does not guarantee TeraBox session lifetime, revocation behavior, or backend compatibility. Microsoft explicitly warns against scraping authentication tokens or cookies from embedded login flows and recommends the system browser or an OS broker for OAuth. A WebView2 login page showing an account is not proof that a separate rclone process can use the session. See [WebView2 authentication and SSO guidance](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2#authentication-and-sso-in-webview2) and [WebView2 user data folders](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/overview-features-apis).
- The pinned `gulp79/rclone-extra` backend expects a full website cookie or `ndus` in its `cookie` configuration field and sends it as an HTTP `Cookie` header. Its README tells users to copy the cookie from browser developer tools. The inspected code has no documented browser-session handoff, supported interactive login, refresh-token flow, or cookie renewal. Expiry, device/session binding, and whether copying a WebView2 cookie to another process works after restart are not established. The project patch addresses some source-level logging paths but is uncompiled and is not a credential-handoff mechanism.
- TeraBox's [Terms of Service](https://www.terabox.com/terms/duty) require access through publicly supported interfaces and prohibit scraping or circumventing security/authentication measures. The terms and official integration documentation reviewed do not establish permission for extracting a WebView2 website cookie and replaying it through this unofficial backend. This is a feasibility/safety finding, not a legal interpretation. Do not implement or test that cookie replay path.
- TeraBox's [Open API documentation](https://www.terabox.com/integrations/docs/chinese) describes app registration and OAuth/device authorization, but requires TeraBox-issued application credentials and describes file listing under the directory assigned to that application. The currently published localized device-flow documentation marks `user_code` and `verification_url` unavailable. No evidence establishes access to the user's existing root, and no app credentials or approval are available here. This API could be reassessed as a separate provider if TeraBox approves the app and confirms the required scope; it is not a full-drive bridge today.

Accordingly, NS Cloud Drive cannot reliably detect backend authentication success, distinguish expiry from other backend errors, renew the session, or prove session persistence across app restarts through a supported integration. WebView2 profile persistence by itself does not change those facts. No browser control, cookie extraction, authentication attempt, account access, or credential collection was performed. **Authentication and the real-account mount remain blocked.** The smallest resolving experiment is to obtain TeraBox's written developer guidance/app approval confirming (a) a supported user authorization flow for a Windows desktop client and (b) read access to the existing account root, then reassess the official API. If the documented scope remains app-folder-only, it cannot satisfy the current full-drive objective.

The [`mill-master/rclone-terabox` QR helper](https://github.com/mill-master/rclone-terabox/blob/main/bin/terabox-login) is **not** the official `/oauth/devicecode` flow. Its source requests the website `/passport/qrcode/get` and `/passport/qrcode/login` endpoints, sends a Chrome-like User-Agent and browser-style headers, extracts the resulting `ndus` web-session cookie, and passes `cookie=<ndus>` to `rclone config create/update` as a child-process argument before saving it to ordinary rclone config. We did not run it. This approach is unsuitable for NS Cloud Drive: it imitates a browser, and it exposes the session briefly in process arguments and stores it without config encryption. Do not port or use it under this project's security requirements.

## Source-level capability review

The current `derrundetisch/master` backend source at the ref above advertises rclone interfaces for listing, quota reporting, server-side copy/move, directory move, purge, cleanup, unchecked put, and file operations. Source implementation is evidence of code paths only; it does not prove the remote operation succeeds or is durable.

| Capability | Source/doc evidence | Status for this account and Windows |
| --- | --- | --- |
| List directories and metadata | `List` and `NewObject` map names, IDs, size, server modified time, and an MD5 field. | Implemented in source; not live-tested. |
| Read and download | `Object.Open` obtains a download link, applies rclone range options, and performs an HTTP GET. | Range-aware code exists; partial reads, large files, resume, and Explorer reads are untested. |
| Create/upload and overwrite | `Put`, `PutUnchecked`, and `Update` call upload paths. | Source paths exist; backend explicitly rejects unknown-size and zero-byte uploads. No write has been tested. |
| Directory create/delete | `Mkdir` and `Rmdir` exist. | Source paths exist; delete semantics are untested. |
| File rename/move/copy | `Move`, `DirMove`, and `Copy` call server-side operations. | Source paths exist; conflict handling, asynchronous completion, concurrency, and durability are untested. |
| Delete/trash | `Remove`, `Purge`, and `delete_permanently` option exist. | Potentially destructive paths; no delete test has been run. |
| Hashes/modification times | Filesystem advertises no rclone hash types and `SetModTime` returns unsupported. An object still returns an MD5 field. | Do not rely on rclone hash-based integrity checks or preserved modification times. |
| File-size limits | Backend docs report a 4 GB free-account upload limit, 128 GB premium limit, and minimum size of 1 byte. | Maintainer-reported only; not independently verified. |
| Authentication/session renewal | Requested fork docs require a website cookie / `ndus`. The wrapper's QR helper automates the website login endpoints and stores the resulting `ndus` token; it is not the official device-code API flow. Separately, official Open API docs specify an app-registered OAuth/device-code flow for an assigned application folder. | Unofficial backend: no compliant safe login flow or renewal test established; the wrapper imitates a browser and exposes the token in a child-process argument. Official API: application credentials require separate registration and its app-folder scope does not establish access to the existing account root. No authentication was attempted. Do not manually extract or send cookies. |
| Interrupted transfers | Rclone VFS can retain staged writes for retry when the same cache/config is reused. Backend upload idempotency and recovery guarantees are not established. | Unknown; preserve cache on any uncertain write. |
| Concurrent reads/writes | Upload thread setting and API code exist. Wrapper docs report server-side copy may be asynchronous and concurrent copies may fail as unfinished tasks. | No stress/concurrency testing. |
| Windows mount | Official rclone supports Windows through WinFsp. Custom backend build must also include Windows mount support. | No backend-enabled Windows build or mount tested. Candidate release asset/build flags unverified. |
| License | `gulp79` and `mill-master` describe MIT licensing; rclone-extra includes upstream license files. | Do a pinned dependency/notice audit before redistribution. No legal conclusion made here. |
| Automated backend tests | No live-account or Windows integration evidence located in the inspected source/docs. | Treat all TeraBox operations as unverified until acceptance tests pass. |

## Credential exposure finding

At current `derrundetisch/master`, the `cookie` option is required but is not marked `Sensitive` in `fs.RegInfo`. The backend's `Options` struct contains `Cookie`. Its constructor calls the backend debug helper with the full options struct (`%+v`) at debug level 1. The docs define level 1 as logging calls and parameters; higher levels include response bodies and request details. Therefore:

- Do not use backend debug levels 1–4 or distribute raw logs.
- A normal rclone config may contain a raw session credential unless rclone config encryption is separately enabled; config obfuscation is not a secure secret store.
- The current preview does not read or edit config. Any future app must audit a pinned source revision, force debug off, protect config ACLs, prevent config dumps, and avoid writing session material to process arguments, UI diagnostics, and crash reports.
- The QR helper reduces manual copying but writes the resulting session into ordinary rclone configuration; QR login alone does not solve at-rest protection.

This code review is not a substitute for runtime log-capture testing against synthetic secrets. The source should be patched or wrapped only after selecting a pinned commit and adding a regression test that verifies the secret cannot appear in normal or diagnostic output.

### Pinned-source patch progress

The source candidate is now pinned for patch development to `gulp79/rclone-extra` tag `v1.75.2-extra`, commit `56bf13885494819bc801302ddf881279bdac7262`. This is the tag commit, not the repository's newer `master` head. Static inspection of that exact checkout confirmed the cookie option lacks `Sensitive: true`, `NewFs` logs the complete options struct at backend debug level 1, and backend debug calls are gated by `Options.DebugLevel`.

[`patches/rclone-terabox-v1.75.2-extra-secret-safety.patch`](../patches/rclone-terabox-v1.75.2-extra-secret-safety.patch) marks the cookie option sensitive, removes the options-struct log, and forces the backend-specific debug level to zero after reading configuration. The patch was applied to a clean detached worktree at the pinned tag and passed `git apply --check` and `git diff --check` there. This confirms patch applicability and source-diff cleanliness only. Go is unavailable here, so compilation, rclone config-redaction behavior, synthetic-secret log capture, and provider operations remain untested. Do not use this patch as a security guarantee until those tests pass.

## REA relevance

The current [`morluto/rea`](https://github.com/morluto/rea) project is an MIT-licensed agent/MCP reverse-engineering toolkit for applications, JavaScript/Electron apps, .NET assemblies, and native binaries. Its current installer restricts supported hosts to macOS and selected Linux distributions; its package metadata requires Node.js 22.19+, 24.11+, or 26+. It is not a TeraBox connector, filesystem driver, or authentication method. No owned TeraBox application binary or unanswered implementation question justifies installing/running it for this phase, so it was not used. Do not use reverse engineering to defeat authentication, CAPTCHA, quotas, rate limits, or access controls.

## Windows feasibility and cache behavior

- [Official rclone mount documentation](https://rclone.org/commands/rclone_mount/) says Windows mounting requires WinFsp. Network-drive mode is available for a drive letter and can be more appropriate for a slower/unreliable remote than a fixed disk.
- `--vfs-cache-mode full` supports random access and sparse on-demand reads; it does not mean a full account download. Reads may still generate substantial local cache use.
- `--vfs-cache-max-size` and age are eviction targets, not hard quotas. Eviction is periodic and open files cannot be removed. An application must not delete cache files when the remote upload state is uncertain.
- Mounts need to run in the interactive signed-in user session if T: is to be visible in that user's Explorer. An elevated mount may be invisible to a non-elevated Explorer.
- Games and active codebases remain unverified and are poor initial workloads: random I/O, file locks, latency, session expiry, throttling, and remote filesystem semantics can break behavior. Work locally and copy closed files/projects to the mount.

## Build and authentication gate recheck (2026-10-22)

The first build failure was reproduced by running `scripts/Build-PatchedRclone.ps1` from the repository root. It stopped before creating the build directory or cloning source with this exact error:

```text
Exception: ...\scripts\Build-PatchedRclone.ps1:23
WinFsp FUSE development header fuse.h was not found under: C:\Program Files (x86)\WinFsp\inc\fuse
```

The local prerequisite probe also found Git (`2.55.0.windows.2`) but no Go executable, no MinGW GCC/G++ commands, no `rclone.exe`, no standard WinFsp x64 runtime DLL, and no WinFsp FUSE header in either standard install location checked. The .NET runtime is present, but the .NET SDK is not; neither is needed for this Go build. The current error is the first guard reached, not a claim that installing only the header will complete the build.

The pinned source is `gulp79/rclone-extra` tag `v1.75.2-extra`, commit `56bf13885494819bc801302ddf881279bdac7262`. Its tag was checked in a source-only clone. The root `COPYING` file is MIT-licensed; a complete third-party notice/license audit for redistribution remains outstanding. The tag is shown as GitHub-verified, but that authenticates the tagged source commit, not the release executable. The release page publishes a Windows ZIP checksum (`d5a5d9383a607ccb1af9a871d4cb92906121f32cf111497adb94958b99315c69`), but no artifact signature or build attestation was established. We did not download or execute it, so option 1 (trusted compatible release) is not satisfied.

The pinned workflow builds Windows on Ubuntu with Go `1.26.x`, MinGW, WinFsp `v2.1` headers, cgo enabled, and the `cmount` tag. It also obtains `rsrc@latest` and an icon from the moving rclone `master` branch, so that workflow is not fully reproducible as written. The pinned `go.mod` uses `github.com/winfsp/cgofuse` version `v1.6.1-0.20260126094232-f2c4fccdb286`. Official rclone and cgofuse guidance document a Windows no-cgo `cmount` build. The project builder has therefore been changed to try `CGO_ENABLED=0`, pinning the same source tag/commit and applying the cookie-safety patch while removing MinGW and WinFsp Developer headers from build prerequisites. This exact fork build remains unverified until Go is available and compilation plus provider checks pass. The WinFsp runtime is still required to mount. The prior cgo build route was not used successfully; its exact first header failure is recorded above.

**Next local build steps (not performed here):** Git is already installed. Install Go 1.26 or newer from the official Go distribution, then in a fresh PowerShell verify `go version` and run `powershell.exe -NoProfile -File .\scripts\Build-PatchedRclone.ps1`. The revised builder's local preflight now stops at `Required build tool is missing from PATH: go`; it did not create its build root. A successful build must print `windows/amd64`, the `cmount` tag, and a provider list containing `terabox`, and produce its build manifest. Install WinFsp runtime from its official MSI only before attempting a mount; Developer headers are no longer a build requirement for this no-cgo path. No software was installed during this audit.

### Pinned backend auth and secret handling

At the pinned tag, the backend's setup asks for a full website cookie or just `ndus`. `NewFs` normalizes that value and logs the full options struct through the backend debug helper at level 1; the helper emits it when that debug level is enabled. API requests set the supplied value as the HTTP `Cookie` header. The code has no interactive supported login or cookie-renewal flow: a rejected cookie is an error, not a refresh path. It does persist some non-cookie values such as `jsToken`, base URL, and expiring metadata in the rclone config. An encrypted rclone config can protect its contents at rest, but does not create a supported provider sign-in/renewal contract.

The repository patch marks the option sensitive, removes the options-struct debug call, and disables backend-specific debug output. Patch application was checked on the exact pinned source earlier; in this environment, compilation, synthetic-secret log capture, and rclone-level redaction behavior remain unverified. Even if those checks pass, the only documented credential path remains manual website-cookie configuration. No compliant, reliable full-drive login was established, so the live account-mount gate is currently blocked. Never put a cookie in chat, an issue, command history, or diagnostics.

The unofficial backend remains the only candidate in this project for existing full-drive scope, not an approved provider. The official Open API remains a separate narrower candidate: it requires application credentials/approval and documents an assigned-application directory, without establishing access to an existing account root.

## Local environment evidence

- The starter project under `outputs/terabox-drive-starter/` was inspected, including its README, five scripts, and six research documents. Its scripts parse, but its sign-in task has not been installed and its mount has not been run.
- The current CloudDrive repository has a WPF preview and implementation plan. The preview is not a mount manager; its mount control is locked.
- Current local checks show `rclone.exe`, Go, WinFsp's standard x64 DLL, and the .NET SDK are unavailable. .NET runtime 8 is installed. The WPF assemblies are present.
- No software was installed; no account was authenticated; no remote list/read/write operation was run; no scheduled task/service or startup registration was created.

## Phase 1 exit criteria

1. Choose and pin an exact backend source commit and record its license/notices.
2. Resolve or guard the credential disclosure path and test logging with synthetic values.
3. Produce a reproducible Windows build containing the backend and `cmount` support; verify `rclone config providers` reports `terabox` before any authentication.
4. For full-drive scope, obtain a user-confirmed login flow that does not require copying cookies into chat or scripts, and document secure local session storage/renewal. If official Open API credentials are available, assess its assigned-folder scope as a separate provider rather than assuming it can expose the existing root.
5. Only then proceed to an actual read-only mount and File Explorer test. No account credential is needed to continue source/build work; any later interactive account test must remain local to the user.
