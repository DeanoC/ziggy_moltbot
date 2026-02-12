# Spec: Windows Inno Setup Installer (MVP)

Goal: ship ZiggyStarClaw for Windows as a single download that installs and immediately opens install-profile setup.

## Installer deliverable

- `ZiggyStarClaw_Setup_<VERSION>_x64.exe`

## Runtime behavior

1. User downloads and runs the installer EXE.
2. Installer copies app binaries into Program Files.
3. Installer launches:
   - `ziggystarclaw-client.exe --install-profile-only`
4. Client shows only install profile choices:
   - Pure Client
   - Service Node
   - User Session Node
5. After profile apply completes, client exits.

## Build prerequisites

- Windows 10/11
- Inno Setup 6 (`ISCC.exe`)
- PowerShell 5.1+
- Built Windows binaries from `scripts/build-windows.ps1`

## Build pipeline

1. Build Windows binaries:
   - `scripts/build-windows.ps1`
2. Build installer:
   - `scripts/windows/Build-ZscInstaller.ps1`
   - (optional) override with `-Version <x.y.z>`
3. Upload generated EXE from `dist/inno-out/`.

## Packaged files

- `ziggystarclaw-client.exe`
- `ziggystarclaw-cli.exe`
- `ziggystarclaw-tray.exe` (optional)
- `LICENSE`
- `README.md`

## Uninstall behavior

Uninstall performs best-effort cleanup via:
- `ziggystarclaw-cli node profile apply --profile client`

This disables node runner modes and tray startup before binaries are removed.

## Acceptance criteria

- Fresh Windows VM can install from one EXE.
- On install completion, profile-only setup screen opens automatically.
- User can choose exactly one node mode (service or session) or pure client.
- After applying profile, app exits cleanly.
