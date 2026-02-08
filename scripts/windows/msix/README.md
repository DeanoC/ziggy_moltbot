# ZiggyStarClaw MSIX tooling (Windows)

These scripts are intended to be run on **Windows 10/11** on a packaging machine.

They create a self-signed test certificate (Publisher `CN=DeanoC`), build an MSIX, sign it, and generate an `.appinstaller` file pointing at deanoc.com.

## Prereqs

- Windows SDK (makeappx + signtool)
- PowerShell 5.1+
- Built artifacts exist (`scripts/build-windows.ps1`)

## Files

- `New-ZscMsixSigningCert.ps1` → creates/exports signing cert (PFX + CER)
- `Install-ZscTestCert.ps1` → installs CER into CurrentUser Trusted People
- `Build-ZscMsix.ps1` → stages, packs, signs, emits `.appinstaller`

## Quickstart

1) Build:

```powershell
./scripts/build-windows.ps1
```

2) Create a self-signed cert:

```powershell
./scripts/windows/msix/New-ZscMsixSigningCert.ps1 -OutDir dist/msix-signing
```

3) Build MSIX:

```powershell
./scripts/windows/msix/Build-ZscMsix.ps1 \
  -Version 1.0.0.0 \
  -BaseUrl https://deanoc.com/zsc/windows \
  -PfxPath dist/msix-signing/DeanoC_ZiggyStarClaw_Test.pfx \
  -CerPath dist/msix-signing/DeanoC_ZiggyStarClaw_Test.cer
```

4) Upload `dist/msix-out/*` to the website.
