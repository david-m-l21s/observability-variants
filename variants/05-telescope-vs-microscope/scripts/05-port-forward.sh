#!/usr/bin/env bash
# Port-forward the three things this variant needs:
#   quote-web -> http://localhost:8085   (submit quotes / receive load)
#   grafana   -> http://localhost:3002   (the dashboard, both stores)
#   loki      -> http://localhost:3101   (so 08-measure-split.sh can count lines)
# Ports avoid the ones already used: baseline 8080, 02 -> 8081, 03 -> 8082/8083,
# 04 -> 8094 + grafana 3001 + webhook 8090.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="05-telescope-vs-microscope"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

kubectl port-forward -n "$NS" svc/quote-web 8085:8080 & pids+=($!)
kubectl port-forward -n "$NS" svc/grafana   3002:3000 & pids+=($!)
kubectl port-forward -n "$NS" svc/loki      3101:3100 & pids+=($!)

echo "Forwarding (Ctrl-C to stop all):"
echo "  quote-web -> http://localhost:8085"
echo "  grafana   -> http://localhost:3002"
echo "  loki      -> http://localhost:3101"
wait
