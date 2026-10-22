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
