#!/usr/bin/env bash
# Deploy the 02-runtime-injection variant. Order matters: the namespace and the
# Instrumentation CR must exist BEFORE the app pods are created, or the operator
# won't inject the agent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S="$HERE/../k8s"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="02-runtime-injection"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

# 1. Namespace + Instrumentation CR first.
kubectl apply -f "$K8S/00-namespace.yaml"
kubectl apply -f "$K8S/05-instrumentation.yaml"
kubectl -n "$NS" get instrumentation runtime-injection

# 2. Collector, then the apps (which get the agent injected on creation).
kubectl apply -f "$K8S/20-otel-collector.yaml"
kubectl apply -f "$K8S/10-rating-api.yaml" -f "$K8S/11-quote-api.yaml" -f "$K8S/12-quote-web.yaml"

echo "Waiting for rollouts..."
for d in otel-collector rating-api quote-api quote-web; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=180s
done

echo
kubectl get pods -n "$NS"
echo
echo "Confirm the agent was injected (expect an opentelemetry-auto-instrumentation init container):"
echo "  kubectl get pod -n $NS -l app=quote-api -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo"
echo
echo "Reach the frontend: ./05-port-forward.sh  (then http://localhost:8081)"
