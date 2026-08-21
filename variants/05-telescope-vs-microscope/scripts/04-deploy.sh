#!/usr/bin/env bash
# Deploy the 05-telescope-vs-microscope variant: namespace, rating-api and
# quote-api (rebuilt -tm images), quote-web (baseline image), the collector with
# the split logs pipeline, the in-cluster Loki (debug store) and the in-cluster
# Grafana (provisioned datasources + dashboard).
#
# Spans and INFO+ logs go to the ClickHouse database `telescope_vs_microscope`
# on the Lima VM. Debug-tier logs go to Loki and nowhere else.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$HERE/../k8s"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="05-telescope-vs-microscope"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "$K8S/"

echo "Waiting for rollouts..."
for d in otel-collector loki rating-api quote-api quote-web grafana; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=240s
done

echo
kubectl get pods -n "$NS"
echo
echo "Done. Start the port-forwards: ./05-port-forward.sh"
echo "  quote-web -> http://localhost:8085"
echo "  grafana   -> http://localhost:3002   (dashboard: Variants / 05 Telescope vs. Microscope)"
echo "  loki      -> http://localhost:3101   (used by ./08-measure-split.sh)"
echo
echo "Then: ./06-generate-load.sh, ./07-trigger-defect.sh break, ./08-measure-split.sh"
