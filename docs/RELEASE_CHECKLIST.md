# Release Checklist

Use this checklist to prepare and ship a ZiggyStarClaw release.

## Prep
- [ ] Update version in `build.zig.zon`.
- [ ] Update README status and any highlights for this release.
- [ ] Review `docs/ZIGGYSTARCLAW_IMPLEMENTATION_PLAN.md` and mark completed items.
- [ ] Ensure Android keystore settings are correct (or use the example keystore for dev builds).

## Build + Package
- [ ] Build Windows installer on Windows (`scripts/windows/Build-ZscInstaller.ps1`) and ensure `dist/inno-out/ZiggyStarClaw_Setup_<version>_x64.exe` exists.
- [ ] Run `scripts/package-release.sh`.
- [ ] Verify `dist/ziggystarclaw_<version>_<date>/` exists.
- [ ] Check `checksums.txt` and `update.json` are present.

## Smoke Tests
- [ ] Native Linux: launch `ziggystarclaw-client`, connect and send a message.
- [ ] Windows: launch `ziggystarclaw-client.exe`, connect and send a message.
- [ ] WASM: open `ziggystarclaw-client.html` in a local server and connect.
- [ ] Android: install `ziggystarclaw_android.apk`, connect and send a message.

## Release
- [ ] Tag the commit (e.g. `vX.Y.Z`) and push.
- [ ] Draft release notes and attach bundles from `dist/`.
- [ ] Publish update manifest (`update.json`) if you are wiring auto-update.
