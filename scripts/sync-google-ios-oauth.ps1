# Sync Google iOS OAuth client id from Vercel production into Config/Auth.xcconfig.
# Does not print the secret/value. Requires vercel CLI + project link in apps/cloud.

$ErrorActionPreference = "Stop"
$cloud = Join-Path $PSScriptRoot "..\..\whik\apps\cloud"
if (-not (Test-Path (Join-Path $cloud ".vercel"))) {
  $cloud = "C:\projects\whik\apps\cloud"
}
$iosRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$tmp = Join-Path $cloud ".env.vercel.gauth.sync"
Push-Location $cloud
try {
  vercel env pull --environment=production $tmp --yes | Out-Null
  $val = (Get-Content $tmp | Where-Object { $_ -match '^GOOGLE_IOS_CLIENT_ID=' }) -replace '^GOOGLE_IOS_CLIENT_ID=','' -replace '"',''
  if (-not $val -or $val.Length -lt 20) { throw "GOOGLE_IOS_CLIENT_ID missing on Vercel production" }
  $parts = $val.Split('.')
  [array]::Reverse($parts)
  $reversed = $parts -join '.'
  $cfgDir = Join-Path $iosRoot "Config"
  New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
  @(
    '// Synced from Vercel GOOGLE_IOS_CLIENT_ID (public iOS OAuth client id).',
    '// Single source for Info.plist via XcodeGen; read via AppConfiguration — do not hardcode in Swift.',
    "GOOGLE_IOS_CLIENT_ID = $val",
    "GOOGLE_REVERSED_CLIENT_ID = $reversed"
  ) | Set-Content -Path (Join-Path $cfgDir "Auth.xcconfig") -Encoding UTF8
  Write-Host "Auth.xcconfig updated (clientIdLength=$($val.Length) reversedPrefix=$($reversed.Substring(0,[Math]::Min(22,$reversed.Length))))"
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Pop-Location
}
