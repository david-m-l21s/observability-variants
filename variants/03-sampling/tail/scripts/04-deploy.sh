#!/usr/bin/env bash
# Deploy the 03-tail-sampling variant: namespace, three apps (baseline images
# reused as-is, exporting ALL spans), and the collector whose tail_sampling
# processor keeps errors/slow/non-approved traces and ~10% of the rest, writing
# to ClickHouse database tail_sampling.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$HERE/../k8s"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="03-tail-sampling"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "$K8S/"

echo "Waiting for rollouts..."
for d in otel-collector rating-api quote-api quote-web; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=120s
done

echo
kubectl get pods -n "$NS"
echo
echo "Done. Reach the frontend: ./05-port-forward.sh  (then http://localhost:8083)"
