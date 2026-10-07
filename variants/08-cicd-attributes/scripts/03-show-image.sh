#!/usr/bin/env bash
# Step 1 of the test: what did the pipeline bake into the image?
# Pulls the images and prints their OCI labels and OTEL_* environment.
# Nothing is started; this only reads image metadata.
#
# Usage: ./03-show-image.sh [tag]     (default: latest)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
TAG="${1:-latest}"

show() { # image
  echo "== $1"
  docker pull -q "$1" >/dev/null
  docker inspect "$1" --format '{{range $k, $v := .Config.Labels}}  label {{$k}} = {{$v}}{{"\n"}}{{end}}' \
    | grep 'org.opencontainers' || true
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep '^OTEL_' | sed 's/^/  env   /' | tr ',' '\n' | sed 's/^\([a-z]\)/            \1/'
  docker inspect "$1" --format '  entrypoint {{json .Config.Entrypoint}}'
  echo
}

for app in $APPS; do show "$IMAGE_PREFIX/$app:$TAG"; done
if [ "$TAG" = latest ]; then
  v="$(docker inspect "$IMAGE_PREFIX/rating-api:latest" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
  show "$IMAGE_PREFIX/rating-api:$v-naive"
else
  show "$IMAGE_PREFIX/rating-api:$TAG-naive"
fi
echo "final: build values in OTEL_BUILD_ATTRIBUTES, merged at start by the entrypoint."
echo "naive: build values directly in OTEL_RESOURCE_ATTRIBUTES - the manifest will overwrite them."
