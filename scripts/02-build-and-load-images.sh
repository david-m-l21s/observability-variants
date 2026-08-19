#!/usr/bin/env bash
# Build the three service images with Docker and load them into the kind cluster.
# Images (tag v1): rating-api, quote-api, quote-web.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$HERE/../apps"
CLUSTER="${CLUSTER:-obs-vm-tests}"

build_and_load() {
  local dir="$1" img="$2"
  echo "==> Building $img from apps/$dir"
  docker build -t "$img" "$APPS/$dir"
  echo "==> Loading $img into kind ($CLUSTER)"
  kind load docker-image "$img" --name "$CLUSTER"
}

build_and_load RatingApi rating-api:v1
build_and_load QuoteApi  quote-api:v1
build_and_load QuoteWeb  quote-web:v1

echo "Done. Next: ./03-clickhouse-otel-user.sh (once), then ./04-deploy.sh"
