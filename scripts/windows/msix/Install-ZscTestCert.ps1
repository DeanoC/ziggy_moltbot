param(
  [Parameter(Mandatory=$true)][string]$CerPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CerPath)) {
  throw "Cert not found: $CerPath"
}

Write-Host "Installing cert into CurrentUser\\TrustedPeople: $CerPath" -ForegroundColor Cyan
Import-Certificate -FilePath $CerPath -CertStoreLocation 'Cert:\CurrentUser\TrustedPeople' | Out-Null
Write-Host "Done." -ForegroundColor Green
