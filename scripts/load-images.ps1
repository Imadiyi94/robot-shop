<#
.SYNOPSIS
    Load the pinned images into every Kind node and register digest references.

.DESCRIPTION
    `kind load docker-image` stores an image under its tag only. Kubernetes
    manifests that pin by digest (repo/name:tag@sha256:...) ask containerd for a
    digest-qualified name, which would otherwise miss the local store and trigger
    a registry pull - exactly what pre-loading is meant to avoid.

    This script therefore loads each image and then tags it by digest inside
    containerd on every node, so digest references resolve offline.

.PARAMETER ClusterName
    Kind cluster to load into. Never creates a cluster.

.EXAMPLE
    powershell -NoProfile -File scripts/load-images.ps1
#>
[CmdletBinding()]
param(
    [string]$ClusterName = "voting-app",
    [string]$PinsFile = ""
)

if ([string]::IsNullOrWhiteSpace($PinsFile)) {
    $PinsFile = Join-Path $PSScriptRoot "..\dist\image-pins.json"
}

if (-not (Test-Path $PinsFile)) {
    throw "Missing $PinsFile - run scripts/pull-images.ps1 first."
}

$pins = Get-Content $PinsFile -Raw | ConvertFrom-Json
$failed = @($pins | Where-Object { $_.status -ne "ok" -or -not $_.digest })
if ($failed.Count -gt 0) {
    throw "Unpinned images in ${PinsFile}: $($failed.image -join ', ')"
}

$nodes = @(kind get nodes --name $ClusterName)
if ($nodes.Count -lt 2) {
    throw "Expected a multi-node cluster named '$ClusterName', found $($nodes.Count) node(s)."
}

function Resolve-FullRef([string]$image) {
    # Docker's canonical name for a single-segment image is library/<name>.
    if ($image -notmatch "/") { return "docker.io/library/$image" }
    return "docker.io/$image"
}

foreach ($pin in $pins) {
    Write-Host "loading $($pin.image)"
    kind load docker-image $pin.image --name $ClusterName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "kind load failed for $($pin.image)" }

    $ref = Resolve-FullRef $pin.image
    $repo = ($ref -split ":")[0]
    $digestRef = "$repo@$($pin.digest)"

    foreach ($node in $nodes) {
        # ctr tag fails if the target name already exists, so treat an existing
        # digest ref as satisfied and re-check before failing.
        $existing = docker exec $node ctr -n k8s.io images ls -q 2>&1
        if ($existing -contains $digestRef) { continue }

        docker exec $node ctr -n k8s.io images tag $ref $digestRef 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $after = docker exec $node ctr -n k8s.io images ls -q 2>&1
            if ($after -notcontains $digestRef) {
                throw "ctr tag failed on $node for $digestRef"
            }
        }
    }
}

Write-Host ""
Write-Host "=== verification ==="
foreach ($node in $nodes) {
    $names = docker exec $node ctr -n k8s.io images ls -q 2>&1
    $pinned = @($pins | Where-Object {
        $ref = Resolve-FullRef $_.image
        $repo = ($ref -split ":")[0]
        $names -contains "$repo@$($_.digest)"
    })
    Write-Host "$node : $($pinned.Count)/$($pins.Count) digest refs present"
    if ($pinned.Count -ne $pins.Count) {
        $missing = $pins | Where-Object { $pinned.image -notcontains $_.image }
        throw "missing digest refs on ${node}: $($missing.image -join ', ')"
    }
}
