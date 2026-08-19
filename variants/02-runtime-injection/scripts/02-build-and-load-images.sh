#!/usr/bin/env bash
# Build the three SDK-free variant images and load them into the kind cluster.
# Images are distinctly named (-ri) so they never collide with v1's images:
#   rating-api-ri:v1, quote-api-ri:v1, quote-web-ri:v1
#
# Apple Silicon note: .NET ARM64 auto-instrumentation is experimental. If runtime
# injection misbehaves on arm64, rebuild everything as amd64 (emulated) by setting
# PLATFORM=linux/amd64 here AND recreating the cluster the same way. See README.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$HERE/../apps"
CLUSTER="${CLUSTER:-obs-vm-tests}"

PLATFORM_ARG=""
[ -n "${PLATFORM:-}" ] && PLATFORM_ARG="--platform ${PLATFORM}"

build_and_load() {
  local dir="$1" img="$2"
  echo "==> Building $img from apps/$dir ${PLATFORM:+(platform $PLATFORM)}"
  docker build ${PLATFORM_ARG} -t "$img" "$APPS/$dir"
  echo "==> Loading $img into kind ($CLUSTER)"
  kind load docker-image "$img" --name "$CLUSTER"
}

build_and_load RatingApi rating-api-ri:v1
build_and_load QuoteApi  quote-api-ri:v1
build_and_load QuoteWeb  quote-web-ri:v1

echo "Done. Next: ./04-deploy.sh"
