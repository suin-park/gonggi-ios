#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Controlled Production Image-to-3D smoke (max 1 generation + optional idempotent replay).
  Secrets via SecureString only — never print tokens, URLs, or balances.

.NOTES
  Requires GONGGI_MOBILE_IMAGE3D_ENABLED=ON on production.
  Does NOT run as part of unit tests.
#>
param(
  [string]$BaseUrl = "https://www.3d-locker.com",
  [string]$JpegPath,
  [switch]$IdempotentReplayOnly,
  [string]$ExistingClientRequestId,
  [string]$ExistingSourceKey
)

$ErrorActionPreference = "Stop"

function Read-SecretPlain([string]$prompt) {
  $sec = Read-Host -AsSecureString -Prompt $prompt
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

$token = $env:GONGGI_MOBILE_BEARER
if (-not $token) {
  $token = Read-SecretPlain "Mobile Bearer (not echoed)"
}
if (-not $token) { throw "Bearer required" }

$headers = @{
  Authorization = "Bearer $token"
  Accept        = "application/json"
  "Content-Type" = "application/json"
}

function Invoke-Json([string]$Method, [string]$Path, $BodyObj) {
  $uri = "$BaseUrl$Path"
  $body = if ($null -ne $BodyObj) { ($BodyObj | ConvertTo-Json -Compress) } else { $null }
  try {
    if ($body) {
      return Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers -Body $body -UseBasicParsing
    }
    return Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers -UseBasicParsing
  } catch {
    $resp = $_.Exception.Response
    if (-not $resp) { throw }
    $reader = New-Object IO.StreamReader($resp.GetResponseStream())
    $text = $reader.ReadToEnd()
    return [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Content = $text }
  }
}

Write-Host "=== Image-to-3D production smoke (secrets redacted) ==="

# Credits snapshot (delta only later)
$me = Invoke-Json GET "/api/auth/me" $null
$meJson = $me.Content | ConvertFrom-Json
$creditsBefore = $null
if ($meJson.user.credits -ne $null) { $creditsBefore = [int]$meJson.user.credits }
elseif ($meJson.credits -ne $null) { $creditsBefore = [int]$meJson.credits }
Write-Host "auth_ok status=$($me.StatusCode) credits_present=$($null -ne $creditsBefore)"

$clientRequestId = if ($ExistingClientRequestId) { $ExistingClientRequestId } else { [guid]::NewGuid().ToString() }
$sourceKey = $ExistingSourceKey

if (-not $IdempotentReplayOnly) {
  if (-not $JpegPath -or -not (Test-Path $JpegPath)) {
    throw "Provide -JpegPath to a small JPEG (single object). Or use -IdempotentReplayOnly with existing ids."
  }
  $bytes = [IO.File]::ReadAllBytes((Resolve-Path $JpegPath))
  Write-Host "jpeg_bytes=$($bytes.Length) clientRequestId_suffix=$($clientRequestId.Substring([Math]::Max(0,$clientRequestId.Length-6)))"

  $presign = Invoke-Json POST "/api/mobile/assets/image-to-3d/presign" @{
    contentType   = "image/jpeg"
    contentLength = $bytes.Length
  }
  Write-Host "presign_status=$($presign.StatusCode)"
  $p = $presign.Content | ConvertFrom-Json
  if (-not $p.uploadUrl -or -not $p.sourceKey) { throw "presign missing fields" }
  $sourceKey = $p.sourceKey
  $putHeaders = @{ "Content-Type" = "image/jpeg" }
  # PUT without logging URL
  $put = Invoke-WebRequest -Uri $p.uploadUrl -Method PUT -Headers $putHeaders -Body $bytes -UseBasicParsing
  Write-Host "put_status=$($put.StatusCode)"

  $start = Invoke-Json POST "/api/mobile/assets/image-to-3d" @{
    sourceKey         = $sourceKey
    clientRequestId   = $clientRequestId
  }
  Write-Host "start_status=$($start.StatusCode)"
  $s = $start.Content | ConvertFrom-Json
  Write-Host "jobId_suffix=$($s.jobId.ToString().Substring([Math]::Max(0,$s.jobId.ToString().Length-6))) status=$($s.status) replay=$($s.replay)"
  $jobId = $s.jobId
} else {
  if (-not $sourceKey -or -not $ExistingClientRequestId) {
    throw "IdempotentReplayOnly needs -ExistingSourceKey and -ExistingClientRequestId"
  }
  $jobId = $null
}

# Idempotent replay (no second Meshy / charge expected)
$replay = Invoke-Json POST "/api/mobile/assets/image-to-3d" @{
  sourceKey       = $sourceKey
  clientRequestId = $clientRequestId
}
Write-Host "replay_status=$($replay.StatusCode)"
$r = $replay.Content | ConvertFrom-Json
Write-Host "replay_same_job=$($jobId -eq $null -or $r.jobId -eq $jobId) replay_flag=$($r.replay)"

$me2 = Invoke-Json GET "/api/auth/me" $null
$me2Json = $me2.Content | ConvertFrom-Json
$creditsAfter = $null
if ($me2Json.user.credits -ne $null) { $creditsAfter = [int]$me2Json.user.credits }
elseif ($me2Json.credits -ne $null) { $creditsAfter = [int]$me2Json.credits }
if ($null -ne $creditsBefore -and $null -ne $creditsAfter) {
  Write-Host "credit_delta=$($creditsAfter - $creditsBefore)"
} else {
  Write-Host "credit_delta=unavailable"
}

$jobs = Invoke-Json GET "/api/mobile/generation-jobs?status=active" $null
Write-Host "active_jobs_status=$($jobs.StatusCode)"

Remove-Item Env:GONGGI_MOBILE_BEARER -ErrorAction SilentlyContinue
$token = $null
Write-Host "=== done ==="
