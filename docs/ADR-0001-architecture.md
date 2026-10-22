# ADR-0001: Windows desktop and mount architecture

**Status:** Accepted for application scaffolding; TeraBox integration remains blocked on the backend security/build gate.
**Date:** 2026-10-22

## Context

The supplied starter contains PowerShell setup/diagnostic scripts and research, but no compiled desktop app. The CloudDrive repository has a WPF PowerShell preview only. Windows PowerShell and WPF assemblies are present, but this machine has no .NET SDK, Go toolchain, rclone, or WinFsp. A live TeraBox mount cannot be tested here.

The available TeraBox rclone backends are unofficial and use website-session auth. The inspected backend option does not mark its cookie as sensitive and its debug call formats the full options struct. Therefore a UI shell is not permission to enable auth or mounting.

## Decision

### Desktop application

Build the production desktop app as **WPF targeting .NET 10 (`net10.0-windows`)**. Keep the current PowerShell WPF screen as a short-lived diagnostic preview, not the shipping application.

Reasons:

- Native Windows desktop integration and accessibility are the primary product requirements.
- WPF has a small dependency surface and works naturally with Windows process/session APIs.
- .NET 10 is active LTS through November 14, 2028; .NET 8 reaches end of support on November 10, 2026. Build tooling is not present here, so the target framework cannot yet be compiled in this environment.
- Keep assemblies/interfaces Windows-specific now, with provider and mount-manager boundaries independent from the UI. Do not implement mobile support.

### Process and filesystem

- Reuse rclone and WinFsp for the userspace filesystem; do not write a kernel driver or protocol client.
- The mount manager runs as a **per-user process in the interactive sign-in session**, not as SYSTEM. This is required for drive visibility and access to the user's local settings/secrets.
- Keep mount execution isolated from the UI thread. Model explicit states (`Disconnected`, `BackendMissing`, `Authenticating`, `ReadOnlyMounted`, `WritableMounted`, `Reconnecting`, `NeedsReauthentication`, `Stopping`, `Error`). A launched process is not proof that T: is mounted or that the remote is reachable.
- Start read-only with `T:` and the `D:\CloudCache\TeraBox` default only after local checks pass. A 20 GiB VFS limit and 24-hour age are proposed eviction targets, not guaranteed hard limits.
- Do not implement auto-start until manual Explorer/read tests and write/recovery gates pass. Then offer opt-in per-user sign-in startup and test idempotence, network recovery, and sign-out behavior.

### Provider and secret boundaries

- Define a provider capability interface for list/read/write/move/delete and surface unverified or disabled operations accurately. Keep TeraBox-specific login/config code out of UI and mount lifecycle code.
- Require a reviewed, pinned backend build that marks the session option sensitive and has secret-safe debug behavior. Add regression tests using a synthetic token before allowing sign-in.
- Store app-managed secrets through a Windows-protected store (Credential Manager or DPAPI) with ACL-restricted local configuration. Never put credentials in source, command-line args, logs, telemetry, or exported diagnostics.
- Do not use the QR helper until its Windows behavior and config-token handling have been audited. Never request or manually extract a cookie in chat or a script.
- Do not dump or parse raw rclone config in the app. Keep backend debug disabled and treat third-party output as sensitive until sanitized.

### Cache and shutdown

- Default content cache to `D:\CloudCache\TeraBox`; allow a future user-selectable path. Require sufficient space and display actual usage.
- Keep cache policy separate from remote provider logic. VFS max size and age trigger eviction but can be exceeded by open files and poll timing.
- Do not delete cache directories automatically on exit, sign-out, uninstall, or error. On shutdown, stop accepting writes, wait for known pending operations, and preserve/report any uncertain local data.
- Select and test a clean unmount/control mechanism before writable mode. Never use `Stop-Process -Force` as normal stop behavior.

## Alternatives considered

| Alternative | Decision |
| --- | --- |
| PowerShell WPF | Keep only as a fast preview. It is harder to package, test, and maintain as a polished desktop product. |
| WinUI 3 | Reconsider only if Windows shell integration demands its extra app SDK/package surface; WPF meets current requirements with fewer dependencies. |
| Electron | Not selected; no existing web stack and larger runtime/maintenance surface for a Windows-native utility. |
| Windows service / SYSTEM | Not selected; drive letters are session-specific and the service would complicate user config and secret access. |
| Custom filesystem driver or TeraBox protocol client | Rejected while rclone/WinFsp are viable; unnecessary kernel risk and protocol-maintenance burden. |

## Consequences and gates

- A Windows SDK setup and clean build are required before the .NET 10 app can be tested or packaged.
- The desktop UI can be developed against a fake/local provider for UI tests, but must not simulate a successful cloud mount.
- The current backend cannot pass the secret-safety gate without source changes and tests. Keep mount/auth controls disabled until a patched build, provider registration, WinFsp presence, and read-only acceptance are proven.
- Write access, cache cleanup automation, and sign-in startup each require their own acceptance evidence before being enabled.

## References

- [Microsoft .NET support policy](https://dotnet.microsoft.com/en-us/platform/support/policy)
- [WPF target framework guidance](https://learn.microsoft.com/en-us/dotnet/standard/frameworks)
- [rclone Windows mount docs](https://rclone.org/commands/rclone_mount/)
- [WinFsp](https://winfsp.dev/)
- [Backend security/source review](FEASIBILITY.md)
