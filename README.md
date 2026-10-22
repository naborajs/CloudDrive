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

## License

License terms will be selected and documented before distributing application binaries or source derived from third-party projects.
