#!/usr/bin/env bash
# Port-forward what this variant needs:
#   quote-web -> http://localhost:8086   (form + POST /api/quote, the write path)
#   quote-api -> http://localhost:8087   (GET /quotes/{id}, GET /customers/{id}/quotes)
# quote-api is forwarded directly because the read endpoints are new and the
# baseline quote-web (reused unchanged) does not proxy them.
# Ports avoid the ones already used: baseline 8080, 02 8081, 03 8082/8083,
# 04 8094 + 3001 + 8090, 05 8085 + 3002 + 3101.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="06-ef-core-sqlite"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kubectl port-forward -n "$NS" svc/quote-web 8086:8080 & pids+=($!)
kubectl port-forward -n "$NS" svc/quote-api 8087:8080 & pids+=($!)

echo "Forwarding (Ctrl-C to stop all):"
echo "  quote-web -> http://localhost:8086"
echo "  quote-api -> http://localhost:8087"
wait
