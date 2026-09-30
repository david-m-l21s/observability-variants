#!/usr/bin/env bash
# Deploy the fixed part of 07-otel-config-tester: namespace, collector
# (-> ClickHouse database otel_config_tester on the Lima VM, created by the
# exporter on first start) and the variant's own Grafana.
#
# The probe app is NOT deployed here. Each configuration brings its own image
# and env, so ./run.sh renders, builds and deploys it per configuration.
# run.sh calls this script itself if the collector is missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="07-otel-config-tester"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "$HERE/../k8s/"

echo "Waiting for rollouts..."
for d in otel-collector grafana; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=300s
done

echo
kubectl get pods -n "$NS"
echo
echo "Done. Next: ./05-port-forward.sh (Grafana), then ./run.sh <configuration>"
