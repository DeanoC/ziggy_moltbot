# Packaging

ZiggyStarClaw ships release bundles for Linux, Windows, Android, and WASM.

## One-command packaging

```bash
scripts/package-release.sh
```

## Windows Inno Setup Installer (current)

Windows installer packaging is driven by Inno Setup scripts intended to run on a Windows packaging machine:

- `scripts/windows/Build-ZscInstaller.ps1`
- `scripts/windows/inno/README.md`
- `scripts/windows/inno/Build-ZscInnoInstaller.ps1`

See: `docs/spec_windows_inno_installer_mvp.md`

This will:
- Build all targets (native, Windows, WASM, Android).
- Build CLI bundles for both profiles:
  - full CLI (`ziggystarclaw-cli`)
  - node-only CLI (`ziggystarclaw-cli`, built with `-Dcli_operator=false`)
- Gather artifacts into `dist/ziggystarclaw_<version>_<date>/`.
- Produce `.zip` and `.tar.gz` bundles plus `checksums.txt`.
- Include `ZiggyStarClaw_Setup_<version>_x64.exe` when present (from `dist/inno-out/` by default).
- Emit `update.json` as a placeholder update manifest.

### Options
- `--no-build`: Use existing artifacts.
- `--skip-wasm`: Skip the WASM build.
- `--skip-node-only`: Skip node-only CLI packaging.
- `--version=X.Y.Z`: Override version.
- `--date=YYYYMMDD`: Override the date.
- `--windows-installer=PATH`: Path to a prebuilt Inno installer EXE to include.
- `--require-windows-installer`: Fail if installer EXE is missing.

## Output structure

```
dist/ziggystarclaw_<version>_<date>/
  linux/
  windows/
  android/
  wasm/
  symbols/
  cli-node-only-linux/
  cli-node-only-windows/
  ziggystarclaw_linux_<version>.zip
  ziggystarclaw_linux_<version>.tar.gz
  ziggystarclaw_windows_<version>.zip
  ZiggyStarClaw_Setup_<version>_x64.exe   # optional
  ziggystarclaw_android_<version>.zip
  ziggystarclaw_wasm_<version>.zip
  ziggystarclaw_cli_node_only_linux_<version>.zip
  ziggystarclaw_cli_node_only_linux_<version>.tar.gz
  ziggystarclaw_cli_node_only_windows_<version>.zip
  checksums.txt
  update.json
```

## Update manifest (hook)

`update.json` is emitted as a simple manifest that can be published alongside your release artifacts.
It is not wired into the app yet, but provides a stable format to integrate auto-update later.
