#!/usr/bin/env bash
# Port-forward the three things you look at for this variant:
#   quote-web     -> http://localhost:8084   (submit quotes)
#   grafana       -> http://localhost:3001   (alert rules + their state)
#   alert webhook -> http://localhost:8090   (fired alerts, refreshes every 5s)
# Runs all three in the background and waits; Ctrl-C stops them together.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="04-spanmetrics-alerting"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kubectl port-forward -n "$NS" svc/quote-web     8094:8080 & pids+=($!)
kubectl port-forward -n "$NS" svc/grafana       3001:3000 & pids+=($!)
kubectl port-forward -n "$NS" svc/alert-webhook 8090:8080 & pids+=($!)

echo "Forwarding (Ctrl-C to stop all):"
echo "  quote-web      -> http://localhost:8094"
echo "  grafana        -> http://localhost:3001"
echo "  alert webhook  -> http://localhost:8090"
wait
