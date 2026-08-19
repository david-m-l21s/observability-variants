#!/usr/bin/env bash
# Port-forward the 03-tail-sampling frontend to http://localhost:8083.
# (Baseline 8080, 02-runtime-injection 8081, head 8082, tail 8083.)
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
PORT="${1:-8083}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null
echo "quote-web (03-tail-sampling) -> http://localhost:${PORT}  (Ctrl-C to stop)"
kubectl port-forward -n 03-tail-sampling svc/quote-web "${PORT}:8080"
