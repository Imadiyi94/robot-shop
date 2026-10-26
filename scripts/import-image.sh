#!/usr/bin/env bash
# Import a single image into every Kind node, bypassing `kind load`.
#
# `kind load docker-image` runs `ctr images import --all-platforms`. With Docker
# 29 the saved index (OCI layout, attestations included) advertises child
# manifests the tarball does not contain, so containerd aborts with
# "content digest sha256:... not found". Naming the target platform makes
# containerd resolve only the manifest whose content is actually present.
#
# Usage: bash scripts/import-image.sh <image-ref> <sha256-digest>
set -euo pipefail

IMAGE="${1:?usage: import-image.sh <image-ref> <sha256-digest>}"
DIGEST="${2:?usage: import-image.sh <image-ref> <sha256-digest>}"
CLUSTER="${CLUSTER:-voting-app}"

# Single-segment names are canonicalised to docker.io/library/<name>.
case "$IMAGE" in
  */*) REPO="docker.io/${IMAGE%%:*}" ;;
  *)   REPO="docker.io/library/${IMAGE%%:*}" ;;
esac
DIGEST_REF="${REPO}@${DIGEST}"

for node in $(kind get nodes --name "$CLUSTER"); do
  echo "--- $node ---"
  docker save "$IMAGE" | docker exec -i "$node" ctr -n k8s.io images import \
    --digests --platform linux/amd64 - 2>&1 | tail -2
  # ctr tag is not idempotent; an existing digest ref already satisfies the goal.
  if docker exec "$node" ctr -n k8s.io images ls -q | grep -qx "$DIGEST_REF"; then
    echo "digest ref already present"
  else
    docker exec "$node" ctr -n k8s.io images tag "$REPO:${IMAGE##*:}" "$DIGEST_REF"
  fi
done
