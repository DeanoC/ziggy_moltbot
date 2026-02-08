param(
  [string]$Subject = 'CN=DeanoC',
  [string]$OutDir = 'dist/msix-signing',
  [string]$PfxName = 'DeanoC_ZiggyStarClaw_Test.pfx',
  [string]$CerName = 'DeanoC_ZiggyStarClaw_Test.cer'
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "Creating code-signing cert: $Subject" -ForegroundColor Cyan
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject -CertStoreLocation 'Cert:\CurrentUser\My'

$cerPath = Join-Path $OutDir $CerName
$pfxPath = Join-Path $OutDir $PfxName

Write-Host "Exporting public cert: $cerPath" -ForegroundColor Cyan
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

$pwd = Read-Host -AsSecureString "PFX password (for signing)"
Write-Host "Exporting PFX (private key): $pfxPath" -ForegroundColor Yellow
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pwd | Out-Null

Write-Host "Done." -ForegroundColor Green
Write-Host "CER: $cerPath"
Write-Host "PFX: $pfxPath"
