#!/usr/bin/env bash
# Port-forward what this variant needs:
#   grafana -> http://localhost:3003   (dashboard "OTel config tester", no login)
#   probe   -> http://localhost:8088   (the probe app of the current run; its test page is at /)
#
# kubectl port-forward sticks to ONE pod, and run.sh replaces the probe pod on
# every run. So each forward runs in a loop and reconnects to the new pod by
# itself (a few seconds after run.sh finishes). Leave this script running.
# (run.sh does not need :8088: it opens its own forward on :18088.)
#
# Ports avoid the ones already used: baseline 8080, 02 8081, 03 8082/8083,
# 04 8094 + 3001 + 8090, 05 8085 + 3002 + 3101, 06 8086 + 8087.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="07-otel-config-tester"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

loops=()
cleanup() {
  for l in "${loops[@]}"; do pkill -P "$l" 2>/dev/null || true; kill "$l" 2>/dev/null || true; done
}
trap cleanup EXIT INT TERM

forever() { # service local-port remote-port
  while true; do
    kubectl port-forward -n "$NS" "svc/$1" "$2:$3" >/dev/null 2>&1 || true
    sleep 2
  done
}

forever grafana 3003 3000 & loops+=($!)
forever probe 8088 8080 & loops+=($!)

echo "Forwarding (Ctrl-C to stop all; both reconnect when their pod is replaced):"
echo "  grafana -> http://localhost:3003/d/otel-config-tester"
echo "  probe   -> http://localhost:8088/   (test page; waits for the first ./run.sh)"
wait
