#!/usr/bin/env bash
# Port-forward this variant's frontend to http://localhost:8081 (8081 so it can
# run alongside v1's 8080). Grafana is on the Lima VM at http://localhost:3000.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
PORT="${1:-8081}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null
echo "quote-web (runtime-injection) -> http://localhost:${PORT}  (Ctrl-C to stop)"
kubectl port-forward -n 02-runtime-injection svc/quote-web "${PORT}:8080"
