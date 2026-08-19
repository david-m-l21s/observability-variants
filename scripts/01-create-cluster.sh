#!/usr/bin/env bash
# Create the local kind cluster "obs-vm-tests". Run once. Needs: kind, kubectl.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-obs-vm-tests}"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "kind cluster '$CLUSTER' already exists — skipping create."
else
  kind create cluster --config "$HERE/../kind-cluster.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER}"
echo "Done. Next: ./02-build-and-load-images.sh"
