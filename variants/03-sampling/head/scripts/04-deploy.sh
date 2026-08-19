#!/usr/bin/env bash
# Deploy the 03-head-sampling variant: namespace, three apps (baseline images
# reused as-is, but with OTEL_TRACES_SAMPLER env for in-SDK head sampling), and
# the collector (plain pipeline -> ClickHouse database head_sampling).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$HERE/../k8s"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="03-head-sampling"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "$K8S/"

echo "Waiting for rollouts..."
for d in otel-collector rating-api quote-api quote-web; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=120s
done

echo
kubectl get pods -n "$NS"
echo
echo "Done. Reach the frontend: ./05-port-forward.sh  (then http://localhost:8082)"
