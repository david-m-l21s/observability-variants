#!/usr/bin/env bash
# Deploy the 04-spanmetrics-alerting variant: namespace, three apps (baseline
# images reused as-is), the collector (with the spanmetrics connector), the
# in-cluster Grafana (provisioned datasource + contact point + alert rules), and
# the webhook stub. Everything writes to the ClickHouse database
# `spanmetrics_alerting`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$HERE/../k8s"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="04-spanmetrics-alerting"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "$K8S/"

echo "Waiting for rollouts..."
for d in otel-collector rating-api quote-api quote-web alert-webhook grafana; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=180s
done

echo
kubectl get pods -n "$NS"
echo
echo "Done. Start the port-forwards: ./05-port-forward.sh"
echo "  quote-web      -> http://localhost:8094"
echo "  grafana        -> http://localhost:3001  (anonymous editor; admin/admin to log in)"
echo "  alert webhook  -> http://localhost:8090"
echo
echo "Then generate load (./06-generate-load.sh) and trigger incidents (./07-trigger-incidents.sh)."
