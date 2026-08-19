#!/usr/bin/env bash
# Deploy the namespace, three apps, and the OTel collector.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${CLUSTER:-obs-vm-tests}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

kubectl apply -f "$HERE/../k8s/"

echo "Waiting for rollouts..."
for d in otel-collector rating-api quote-api quote-web; do
  kubectl rollout status deployment/"$d" -n 01-simple-apps --timeout=120s
done

echo
kubectl get pods -n 01-simple-apps
echo
echo "Done. Reach the frontend: ./05-port-forward.sh  (then http://localhost:8080)"
