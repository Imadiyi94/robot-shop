<#
.SYNOPSIS
    Pull the 13 Stan's Robot Shop images and record their cryptographic digests.

.DESCRIPTION
    Docker Hub DNS resolution is intermittent on this workstation (auth.docker.io
    and the CloudFront blob host sporadically fail with "no such host"), so each
    pull is retried. Layer content is cached, so a retry resumes rather than
    restarts.

    Digests are read from the pulled manifest (RepoDigests) rather than queried
    separately, which guarantees the recorded digest is exactly the content that
    gets loaded into the Kind nodes.

.OUTPUTS
    dist/image-pins.json  - array of { image, digest, status }

.EXAMPLE
    powershell -NoProfile -File scripts/pull-images.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputFile = (Join-Path $PSScriptRoot "..\dist\image-pins.json"),
    [int]$MaxAttempts = 6
)

$images = @(
    "robotshop/rs-web:latest",
    "robotshop/rs-catalogue:latest",
    "robotshop/rs-cart:latest",
    "robotshop/rs-payment:latest",
    "robotshop/rs-user:latest",
    "robotshop/rs-shipping:latest",
    "robotshop/rs-ratings:latest",
    "robotshop/rs-dispatch:latest",
    "robotshop/rs-mongodb:latest",
    "robotshop/rs-mysql-db:latest",
    "robotshop/rs-load:latest",
    "redis:4.0.6",
    "rabbitmq:3.7-management-alpine"
)

$results = @()

foreach ($img in $images) {
    $ok = $false
    for ($attempt = 1; $attempt -le $MaxAttempts -and -not $ok; $attempt++) {
        docker pull $img *> $null
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
        }
        elseif ($attempt -lt $MaxAttempts) {
            Write-Host "     retry $attempt for $img"
            Start-Sleep -Seconds 3
        }
    }

    if (-not $ok) {
        Write-Host "FAIL $img"
        $results += [pscustomobject]@{ image = $img; digest = $null; status = "failed" }
        continue
    }

    $ref = docker image inspect $img --format '{{index .RepoDigests 0}}'
    $digest = ($ref -split "@")[1]
    Write-Host "OK   $img  $digest"
    $results += [pscustomobject]@{ image = $img; digest = $digest; status = "ok" }
}

$dir = Split-Path -Parent $OutputFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$results | ConvertTo-Json -Depth 3 | Set-Content -Encoding ascii $OutputFile

$failed = @($results | Where-Object status -ne "ok")
Write-Host ""
Write-Host "pulled $($results.Count - $failed.Count)/$($results.Count) images"
if ($failed.Count -gt 0) {
    Write-Host "failed: $($failed.image -join ', ')"
    exit 1
}
