#!/usr/bin/env bash
# Port-forward the 03-head-sampling frontend to http://localhost:8082.
# (Baseline uses 8080, 02-runtime-injection uses 8081, so head gets 8082.)
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
PORT="${1:-8082}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null
echo "quote-web (03-head-sampling) -> http://localhost:${PORT}  (Ctrl-C to stop)"
kubectl port-forward -n 03-head-sampling svc/quote-web "${PORT}:8080"
