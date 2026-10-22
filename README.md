# NS Cloud Drive

**NS Cloud Drive** is a Windows desktop-first project for accessing cloud files through a virtual drive in File Explorer, with on-demand reads and bounded local caching.

> **Development status:** early feasibility and implementation stage. No TeraBox account has been connected, no backend has been verified against a live account, and no mount is currently claimed to work.

## Product direction

- Windows desktop app with a clear drive and connection status.
- Virtual-drive integration through a supported Windows userspace filesystem layer.
- On-demand access instead of copying the whole cloud account locally.
- Bounded cache with protection for pending or uncertain writes.
- Explicit transfer/synchronization state, diagnostics, and optional per-user sign-in startup.
- Modular provider and mount-manager boundaries so other desktop providers can be added later. Mobile is not in scope for this project.

## TeraBox feasibility

TeraBox support is being investigated through an unofficial rclone backend. The upstream contribution is not part of official rclone, and source-level operations do not prove account compatibility or reliable file behavior. No credentials are stored in this repository. Do not send cookies, passwords, or session tokens in issues or chats.

See the research and acceptance plan in the project documentation as it is added. A real mount will only be described as working after backend registration, read-only browsing, file reads, and File Explorer visibility have been tested on Windows. Writes and startup persistence require separate tests.

## Safety and intended use

Use a cloud drive for photos, videos, documents, archives, installers, backups, and closed project copies. A cloud mount is not equivalent to a local SSD. Games, active codebases, Git operations, builds, and package managers may be unreliable due to network latency, throttling, session expiry, file locking, and provider filesystem behavior. Keep active work local and copy it to cloud storage when closed.

## Development preview

On Windows, open PowerShell and run:

```powershell
powershell.exe -NoProfile -STA -File .\src\NSCloudDrive.ps1
```

The preview needs Windows PowerShell 5.1 with WPF. **Check setup** reports whether rclone is on `PATH`, whether common WinFsp installation markers are present, and whether the installed rclone lists a TeraBox provider. These are local checks only; provider registration does not prove login or file access. The mount button is deliberately locked. No account credentials are requested or read.

The preview has only been syntax-checked on the development PC. Its UI and prerequisite detection have not yet been acceptance-tested on a clean Windows install. Do not install an unofficial binary from an unknown source.

## Pinned backend build helper

[`scripts/Build-PatchedRclone.ps1`](scripts/Build-PatchedRclone.ps1) builds a Windows x64 executable from the pinned `gulp79/rclone-extra` source tag and applies the repository's cookie-safety patch. It refuses to reuse an existing build folder and verifies the executable reports both `cmount` and the `terabox` provider. It does not install prerequisites, configure an account, or test a live TeraBox connection.

The pinned source requires Go 1.26 or newer. Its Windows `cmount` build workflow also uses MinGW and WinFsp FUSE development headers; the helper checks for these prerequisites before downloading source. rclone's Windows mounting guidance requires WinFsp, and the Developer feature is required when building with cgo. See [rclone Windows build instructions](https://rclone.org/install/) and the [pinned backend workflow](https://github.com/gulp79/rclone-extra/blob/v1.75.2-extra/.github/workflows/build.yml).

After installing those prerequisites through sources you trust, run the helper from the repository root:

```powershell
powershell.exe -NoProfile -File .\scripts\Build-PatchedRclone.ps1
```

The resulting files are kept under `%LOCALAPPDATA%\NSCloudDrive\builds\rclone-extra-v1.75.2-extra`. A successful build proves only that the pinned source builds and registers the provider; the build has not yet been run in this environment, and account login, Explorer mounting, file reads, and writes remain unverified.

## Read-only mount test

After a successful build and after a TeraBox remote has been configured locally with rclone's encrypted configuration, start the manual read-only test:

```powershell
powershell.exe -NoProfile -File .\scripts\Start-ReadOnlyMount.ps1
```

The launcher verifies the build manifest and file hashes, checks that T: is free and the cache volume is NTFS with at least 25 GiB free, confirms the rclone configuration is encrypted and decryptable, then runs rclone visibly in the signed-in user's session. It uses the local DPAPI helper below to unlock the config without prompting twice or putting the unlock password in command-line arguments. Press Ctrl+C in that window to unmount. It does not write remotely, create a startup task, or delete cache files.

### Optional local config unlock

After an encrypted rclone config has been prepared locally, you can store its **config-encryption password** for the current Windows account:

```powershell
powershell.exe -NoProfile -File .\scripts\RcloneConfigPassword.ps1 -Store
```

The password is entered through a hidden prompt and exported as a current-user DPAPI-protected PowerShell credential under `%LOCALAPPDATA%\NSCloudDrive\credentials`, with an ACL limited to that user and SYSTEM. The launcher supplies it to rclone through its documented password-command interface. This is a convenience for unlocking the encrypted rclone file; it does not create a TeraBox login, store a TeraBox cookie, prove the backend works, or create a startup task. A process or attacker already running as the same Windows user may still be able to use or retrieve the credential. To remove it, delete `rclone-config.xml` from that folder while the mount is stopped.

No compliant sign-in flow for the unofficial cookie-based backend has been established yet. Do not paste session values into chat, scripts, logs, or this repository. The launcher is scaffolding for a later locally configured and reviewed test; a successful script parse or build is not proof that a live T: mount works.

## License

License terms will be selected and documented before distributing application binaries or source derived from third-party projects.
