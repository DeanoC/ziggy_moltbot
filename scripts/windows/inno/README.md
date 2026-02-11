# ZiggyStarClaw Inno Setup installer (Windows)

This packaging flow produces a single `setup.exe` installer for Windows.

The installer:
- installs `ziggystarclaw-client.exe`, `ziggystarclaw-cli.exe`, and `ziggystarclaw-tray.exe` (if present)
- adds Start Menu/Desktop shortcuts
- launches `ziggystarclaw-client.exe --install-profile-only` at the end of install

## Prereqs

- Windows 10/11
- PowerShell 5.1+
- Inno Setup 6 (`ISCC.exe` available)
- Built Windows artifacts (`scripts/build-windows.ps1`)

## Quickstart

1) Build Windows binaries:

```powershell
./scripts/build-windows.ps1
```

2) Build installer:

```powershell
./scripts/windows/Build-ZscInstaller.ps1
```

`-Version` is optional; when omitted it is read from `build.zig.zon`.

If `ISCC.exe` is not on PATH, call the inner script with an explicit compiler path:

```powershell
./scripts/windows/inno/Build-ZscInnoInstaller.ps1 -IsccPath "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
```

3) Output:

```text
dist/inno-out/ZiggyStarClaw_Setup_1.0.0_x64.exe
```

## Notes

- `ziggystarclaw-tray.exe` is optional. If missing, installer still builds.
- Uninstall runs best-effort cleanup:
  - `ziggystarclaw-cli node profile apply --profile client`
