#!/usr/bin/env bash
# Install cert-manager + the OpenTelemetry Operator into the shared kind cluster.
# CLUSTER-WIDE and shared by all future injection variants — run ONCE.
# Assumes the cluster already exists (../../scripts/01-create-cluster.sh).
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

echo "==> Installing cert-manager (operator prerequisite)..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

echo "==> Installing the OpenTelemetry Operator..."
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
kubectl -n opentelemetry-operator-system rollout status deploy/opentelemetry-operator-controller-manager --timeout=180s

echo "Done. Operator + cert-manager ready. Next: ./02-build-and-load-images.sh"
