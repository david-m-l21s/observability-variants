#!/usr/bin/env bash
# Deploy 06-ef-core-sqlite: namespace, rating-api + quote-web (baseline images),
# quote-api (quote-api-ef:v1) and the collector -> ClickHouse database
# ef_core_sqlite on the Lima VM (created by the exporter on first start).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="06-ef-core-sqlite"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "$HERE/../k8s/"

echo "Waiting for rollouts..."
for d in otel-collector rating-api quote-api quote-web; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=180s
done

echo
kubectl get pods -n "$NS"
echo
echo "Done. Start the port-forwards: ./05-port-forward.sh"
echo "Then: ./06-generate-load.sh and ./08-inspect.sh"
