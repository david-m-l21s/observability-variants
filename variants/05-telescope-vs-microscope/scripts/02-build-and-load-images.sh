#!/usr/bin/env bash
# Build the two changed service images and load them into the kind cluster.
# Distinctly named (-tm) so they never collide with the baseline's images:
#   rating-api-tm:v1, quote-api-tm:v1
#
# quote-web is NOT rebuilt: it is unchanged in this variant, so the manifests
# reuse the baseline image quote-web:v1 as-is. Run the baseline's
# scripts/02-build-and-load-images.sh at least once if quote-web:v1 is missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$HERE/../apps"
CLUSTER="${CLUSTER:-obs-vm-tests}"

build_and_load() {
  local dir="$1" img="$2"
  echo "==> Building $img from variants/05-telescope-vs-microscope/apps/$dir"
  docker build -t "$img" "$APPS/$dir"
  echo "==> Loading $img into kind ($CLUSTER)"
  kind load docker-image "$img" --name "$CLUSTER"
}

build_and_load RatingApi rating-api-tm:v1
build_and_load QuoteApi  quote-api-tm:v1

if ! docker image inspect quote-web:v1 >/dev/null 2>&1; then
  echo
  echo "NOTE: quote-web:v1 not found locally. This variant reuses the baseline"
  echo "      frontend. Build it once with ../../../scripts/02-build-and-load-images.sh"
fi

echo "Done. Next: ./04-deploy.sh"
