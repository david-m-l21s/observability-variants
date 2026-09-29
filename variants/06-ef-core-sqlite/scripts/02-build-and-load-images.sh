#!/usr/bin/env bash
# Build the one changed image and load it into the kind cluster:
#   quote-api-ef:v1   (EF Core + SQLite + EF Core instrumentation)
#
# rating-api and quote-web are NOT rebuilt: they are unchanged in this variant,
# so the manifests reuse the baseline images rating-api:v1 and quote-web:v1.
# Run the baseline's scripts/02-build-and-load-images.sh once if they're missing.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$HERE/../apps"
CLUSTER="${CLUSTER:-obs-vm-tests}"

echo "==> Building quote-api-ef:v1 from variants/06-ef-core-sqlite/apps/QuoteApi"
docker build -t quote-api-ef:v1 "$APPS/QuoteApi"
echo "==> Loading quote-api-ef:v1 into kind ($CLUSTER)"
kind load docker-image quote-api-ef:v1 --name "$CLUSTER"

for img in rating-api:v1 quote-web:v1; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo
    echo "NOTE: $img not found locally. This variant reuses the baseline image."
    echo "      Build it once with ../../../scripts/02-build-and-load-images.sh"
  fi
done

echo "Done. Next: ./04-deploy.sh"
