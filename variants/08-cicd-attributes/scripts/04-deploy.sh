#!/usr/bin/env bash
# Deploy 08-cicd-attributes with one CI build.
#
# Usage: ./04-deploy.sh [tag|latest] [--load|--no-pull]
#   tag        a CI version like 7-a1b2c3d (see the workflow run summary).
#   latest     (default) resolved to the concrete version via the image label,
#              so the manifests never say :latest and a new build replaces pods.
#   (default)  the kind node pulls from ghcr.io itself, like a real cluster.
#   --load     docker pull on the Mac + kind load. Use if the node cannot reach
#              ghcr.io (proxy) or the packages are still private.
#   --no-pull  the images are already in kind (after ./02-build-local.sh).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
TAG="${1:-latest}"
MODE="${2:-}"
BUILD="$HERE/../build"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

if [ "$TAG" = latest ]; then
  echo "Resolving :latest ..."
  docker pull -q "$IMAGE_PREFIX/rating-api:latest" >/dev/null
  TAG="$(docker inspect "$IMAGE_PREFIX/rating-api:latest" \
           --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
  [ -n "$TAG" ] || { echo "No org.opencontainers.image.version label on :latest" >&2; exit 1; }
  echo "  latest = $TAG"
fi

if [ "$MODE" = "--load" ]; then
  for img in rating-api:"$TAG" rating-api:"$TAG"-naive quote-api:"$TAG" quote-web:"$TAG"; do
    echo "==> pull + kind load $IMAGE_PREFIX/$img"
    docker pull -q "$IMAGE_PREFIX/$img" >/dev/null
    kind load docker-image "$IMAGE_PREFIX/$img" --name "$CLUSTER"
  done
fi

# Render: replace the two placeholders, nothing else.
mkdir -p "$BUILD"
for f in "$HERE"/../k8s/*.yaml; do
  sed -e "s|__IMAGE_PREFIX__|$IMAGE_PREFIX|g" -e "s|__TAG__|$TAG|g" "$f" > "$BUILD/$(basename "$f")"
done
if grep -l '__[A-Z_]*__' "$BUILD"/*.yaml; then echo "Unrendered placeholder left (files above)" >&2; exit 1; fi

# Keep the trap's replica count across redeploys (the manifest says 0).
naive_replicas="$(kubectl get deploy rating-api-naive -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"

kubectl apply -f "$BUILD/"
kubectl scale deploy/rating-api-naive -n "$NS" --replicas="${naive_replicas:-0}" >/dev/null

echo "Waiting for rollouts (first pull from ghcr.io can take a minute)..."
for d in otel-collector rating-api quote-api quote-web; do
  kubectl rollout status deployment/"$d" -n "$NS" --timeout=300s
done
[ "${naive_replicas:-0}" -gt 0 ] && kubectl rollout status deployment/rating-api-naive -n "$NS" --timeout=300s

echo
kubectl get pods -n "$NS" -L flavour -o wide | cut -c1-120
echo
echo "Deployed version $TAG."
echo "Next: ./05-port-forward.sh (other terminal), ./06-generate-load.sh, ./08-inspect.sh"
