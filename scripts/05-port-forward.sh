#!/usr/bin/env bash
# Port-forward the frontend to http://localhost:8080.
# Grafana is NOT here — it runs on the Lima VM at http://localhost:3000.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
PORT="${1:-8080}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null
echo "quote-web -> http://localhost:${PORT}  (Ctrl-C to stop)"
kubectl port-forward -n 01-simple-apps svc/quote-web "${PORT}:8080"
