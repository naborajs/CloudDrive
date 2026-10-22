# Backend compatibility matrix

**Checked:** 2026-10-22. “Implemented” means a source code path or documentation claim was found. It does not mean a remote operation passed.

| Requirement | `derrundetisch/rclone-extra` | `gulp79/rclone-extra` | `mill-master/rclone-terabox` | Verified here |
| --- | --- | --- | --- | --- |
| Repository / ref | Public `master`, `76d99f6` (= `v1.73.4-extra`); no tags in this repo. | Public `master`, `9773567`; signed release `v1.75.2-extra` at `56bf138`, with 12 later commits on `master`. | Public `main`, `38482fe`; three commits, no release tags. | Refs verified with read-only `git ls-remote`; these are snapshots, not endorsement. |
| Ownership / relationship | Unofficial fork. README points its release badge to gulp79. | Unofficial rclone fork with TeraBox code attributed to x1arch. | Wrapper/overlay based on x1arch's same backend contribution. | All three share backend ancestry; they do not independently confirm protocol correctness. |
| License | rclone-derived license file present; exact pinned notices require review before redistribution. | rclone-derived license file present; exact pinned notices require review before redistribution. | README declares MIT and repository includes a license file. | No legal review performed. |
| Build dependencies | Go/rclone source; exact current build and Windows `cmount` flags not documented in the README. | Go 1.25 for current source tree (`go.mod`); Windows build/release asset flags not verified. | Git, Go, Python 3; `build.sh` defaults to rclone v1.75.0 and runs `go build`; README specifies Linux/macOS and FUSE. | No build run; Go is absent here. |
| Windows filesystem | Generic rclone supports Windows mounting through WinFsp; custom backend binary must include Windows mount support. | Same; release page lists assets, but no asset was confirmed to contain this backend plus Windows `cmount` support. | README documents Unix FUSE and Linux/macOS requirements, not a Windows build. | No backend binary or WinFsp installed. |
| Directory listing | Backend `List` and `NewObject` implemented. | Same x1arch backend paths present. | README claims `ls`/mount use. | No account listing run. |
| Reads / range requests | `Object.Open` obtains a download URL and forwards rclone range options. | Same source lineage. | README claims downloads/copy/mount. | No file read or partial/range test. |
| Uploads / replacement | `Put`, `PutUnchecked`, and `Update` paths exist; explicitly rejects zero-byte and unknown-size uploads. | Same backend source observed at pinned release. | README claims copy; repeats the zero-byte limitation. | No upload or read-back test. |
| Create/delete directories | `Mkdir`, `Rmdir`, `Purge`, and delete paths exist. | Same source lineage. | Not separately documented/tested. | No mutation run. |
| Rename/move/copy | `Move`, `DirMove`, and server-side `Copy` paths exist. | Same source lineage. | README reports server-side copy can be asynchronous and concurrent copies can return an unfinished-task error. | No conflicts/concurrency/durability test. |
| Metadata integrity | `SetModTime` returns unsupported; filesystem advertises no hash types although objects carry an MD5 field. | Same source behavior at reviewed tag. | No additional guarantee documented. | No metadata/hash comparison test. |
| Limits | Maintainer docs report free upload max 4 GB, premium max 128 GB, minimum 1 byte. | Same docs/backend family. | README repeats 4 GB/128 GB and reports speeds. | These values are maintainer reports, not verified limits or guarantees. |
| Authentication | Backend docs require a website cookie or `ndus`; do not follow their cookie-copy instructions. | Same backend authentication. Cookie option not marked sensitive; constructor debug call includes the options struct. | QR login lets the user confirm with the TeraBox phone app, then stores a website session token in rclone config. | No authentication or session renewal test; no credentials requested. |
| Credential/log handling | Debug level 1 logs calls/parameters; source formats the entire options struct, which includes Cookie. Higher levels include request/response details. | Same source at current `master` and reviewed `v1.75.2-extra`. | QR login avoids manual copying but does not protect the token at rest in the ordinary rclone config. | Source review only; no synthetic-secret runtime log test yet. |
| Session expiry / refresh | Docs estimate about one year; no supported OAuth refresh flow verified. | Same. | Wrapper says rerun login helper when expired; its lifetime statement is author-reported. | Expiry and renewal untested. |
| Interrupted transfers | VFS can keep staged writes for retry if the same cache/config is reused; backend idempotency unknown. | Same. | No Windows recovery claim. | Not tested. |
| Automated tests | No account or Windows integration evidence found in inspected docs/source. | No account or Windows integration evidence found in inspected docs/source. | Three-commit wrapper; no release or Windows integration evidence. | No candidate test suite executed. |

## Selection

`gulp79/rclone-extra` is the current source-build candidate to investigate further because its signed `v1.75.2-extra` release is newer than the requested `derrundetisch` fork's `v1.73.4-extra` source snapshot. Do not download/use a release binary until the exact asset is checked for the TeraBox backend, Windows mount support, provenance, and license notices. The QR wrapper remains a possible login-flow reference, but its documented build/mount support does not establish Windows compatibility or secure token storage.

No candidate currently satisfies the production gate. First pin source, correct/guard cookie sensitivity and debug output, add synthetic-secret regression tests, and build a Windows `cmount` binary. Then test read-only operations against a user-owned account in a disposable Windows profile. Keep writes and startup persistence disabled until their own tests pass.

## Official TeraBox Open API (separate option)

TeraBox's [official integration docs](https://www.terabox.com/integrations/docs/chinese) document OAuth authorization-code and QR/device-code flows, but app credentials (`client_id`, `client_secret`, and `private_secret`) require a separate application request. The same API confines file paths to an application-assigned folder under `From: Other Applications/...`; the docs do not show access to the user's existing full-drive root. It is a potentially supported option for an app-specific folder, not a verified substitute for the whole-account mount. No application was registered and no token request was made.

## Source links

- [Requested fork](https://github.com/derrundetisch/rclone-extra)
- [Requested fork's TeraBox implementation](https://github.com/derrundetisch/rclone-extra/blob/master/backend/terabox/terabox.go)
- [Requested fork's TeraBox docs](https://github.com/derrundetisch/rclone-extra/blob/master/docs/content/terabox.md)
- [rclone-extra upstream release](https://github.com/gulp79/rclone-extra/releases/tag/v1.75.2-extra)
- [QR-login wrapper](https://github.com/mill-master/rclone-terabox)
- [Official rclone PR #8508](https://github.com/rclone/rclone/pull/8508)
- [rclone Windows mount docs](https://rclone.org/commands/rclone_mount/)
- [WinFsp](https://winfsp.dev/)
