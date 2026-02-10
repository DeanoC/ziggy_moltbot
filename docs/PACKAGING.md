# Packaging

ZiggyStarClaw ships release bundles for Linux, Windows, Android, and WASM.

## One-command packaging

```bash
scripts/package-release.sh
```

## Windows MSIX + App Installer (MVP)

MSIX packaging is currently driven by PowerShell scripts intended to run on a Windows packaging machine:

- `scripts/windows/msix/README.md`
- `scripts/windows/msix/Build-ZscMsix.ps1`

See: `docs/spec_windows_msix_appinstaller_mvp.md`

This will:
- Build all targets (native, Windows, WASM, Android).
- Gather artifacts into `dist/ziggystarclaw_<version>_<date>/`.
- Produce `.zip` and `.tar.gz` bundles plus `checksums.txt`.
- Emit `update.json` as a placeholder update manifest.

### Options
- `--no-build`: Use existing artifacts.
- `--skip-wasm`: Skip the WASM build.
- `--version=X.Y.Z`: Override version.
- `--date=YYYYMMDD`: Override the date.

## Output structure

```
dist/ziggystarclaw_<version>_<date>/
  linux/
  windows/
  android/
  wasm/
  symbols/
  ziggystarclaw_linux_<version>.zip
  ziggystarclaw_linux_<version>.tar.gz
  ziggystarclaw_windows_<version>.zip
  ziggystarclaw_android_<version>.zip
  ziggystarclaw_wasm_<version>.zip
  checksums.txt
  update.json
```

## Update manifest (hook)

`update.json` is emitted as a simple manifest that can be published alongside your release artifacts.
It is not wired into the app yet, but provides a stable format to integrate auto-update later.
