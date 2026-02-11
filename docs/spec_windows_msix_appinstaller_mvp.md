# Spec: Windows MSIX + App Installer (MVP, legacy)

> Legacy path: active installer packaging has moved to Inno Setup.
> See `docs/spec_windows_inno_installer_mvp.md`.

Goal: ship ZiggyStarClaw for Windows 10/11 as a **painless download → install → connect node** experience.

This spec defines the **packaging + hosting + signing** pipeline for:
- `ZiggyStarClaw.msix` (desktop app package)
- `ZiggyStarClaw.appinstaller` (update-enabled installer)
- `DeanoC.cer` (public cert for test signing)

> NOTE: Self-signed certificates are acceptable for dev/alpha testers, but are not “painless” for general users. This spec is intentionally **MVP-first** with a path to a real cert.

---

## Non-goals (for MVP)

- No Windows Service (session 0). Full node capabilities (camera/screen/browser) require an interactive user session.
- No Store distribution.
- No fully trusted public certificate yet.

---

## Package identity (must be stable)

MSIX upgrade identity is keyed on `Name` + `Publisher`.

### Chosen publisher

- **Publisher DN:** `CN=DeanoC`

This must exactly match the certificate subject used to sign.

### Chosen package name

- **Name:** `DeanoC.ZiggyStarClaw`

### App identity

- **Application Id:** `ZiggyStarClaw`

### Versioning

- MSIX requires `A.B.C.D` numeric versions.
- Map ZiggyStarClaw semver to MSIX like:
  - `x.y.z` → `x.y.z.0`

---

## Distribution URLs (deanoc.com)

Host over HTTPS:

- App Installer file:
  - `https://deanoc.com/zsc/windows/ZiggyStarClaw.appinstaller`
- MSIX payload (versioned file name):
  - `https://deanoc.com/zsc/windows/ZiggyStarClaw_<VERSION>_x64.msix`
- Public test cert:
  - `https://deanoc.com/zsc/windows/DeanoC.cer`

---

## Installer UX

### For self-signed builds

User steps:
1. Install `DeanoC.cer` into **Current User → Trusted People**.
2. Open `ZiggyStarClaw.appinstaller`.

(We should provide a single docs page and/or a small “Install Certificate” helper for testers.)

### For real certificate later

- Replace signing cert with publicly trusted code-signing cert.
- Keep **Publisher DN identical** (`CN=DeanoC`) to preserve upgrade continuity.

---

## Runtime model (packaged app)

- Main app runs **in the interactive user session**.
- App should own onboarding:
  - set gateway URL/token
  - run node-register
  - show status + logs
  - start node at login

> A Windows Service can be added later for headless tasks, but it won’t satisfy camera/screen/browser.

---

## MSIX contents

Package should include:
- `ziggystarclaw-client.exe` (UI app)
- `ziggystarclaw-cli.exe` (helper/tooling; optional but useful)
- `ziggystarclaw-tray.exe` (node profile tray controls)
- icons/assets

MVP manifest uses `Windows.FullTrustApplication` entrypoint.

---

## Build prerequisites (packaging machine)

- Windows 10/11
- Windows SDK installed (provides `makeappx.exe` and `signtool.exe`)
- PowerShell 5.1+

---

## Build pipeline (MVP)

1. Build Windows artifacts:
   - `scripts/build-windows.ps1`
2. Stage MSIX directory:
   - copy EXEs + assets
   - generate `AppxManifest.xml`
3. Pack:
   - `makeappx pack /d <staging> /p <out.msix>`
4. Sign:
   - `signtool sign /fd SHA256 /a /f <pfx> /p <pwd> <out.msix>`
5. Generate `.appinstaller` pointing at `deanoc.com`
6. Emit installer helper script (`Install-ZiggyStarClaw.ps1`) that launches profile setup mode after install
7. Upload `.msix`, `.appinstaller`, `.cer`, installer helper script

---

## Files to add to repo (this spec)

- `scripts/windows/msix/New-ZscMsixSigningCert.ps1`
- `scripts/windows/msix/Install-ZscTestCert.ps1`
- `scripts/windows/msix/Build-ZscMsix.ps1`
- `scripts/windows/msix/templates/AppxManifest.xml.template`
- `scripts/windows/msix/templates/ZiggyStarClaw.appinstaller.template`

---

## Verification checklist

- Fresh Windows VM:
  - install cert
  - install via `.appinstaller`
  - run app
  - onboarding can save config
  - node-register completes
  - node appears connected in gateway
- Update test:
  - publish `1.0.0.0`, install
  - publish `1.0.0.1`, confirm update occurs on launch

---

## Follow-ups

- Create a real onboarding UI in-app (see `spec_windows_onboarding_tray_app.md`).
- Decide config/log paths for MSIX installs (prefer `%LOCALAPPDATA%\ZiggyStarClaw\...` and add migration from `%APPDATA%`).
- Add public code signing cert and ensure Publisher DN stays stable.
