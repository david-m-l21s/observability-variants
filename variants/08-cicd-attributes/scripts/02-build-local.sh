#!/usr/bin/env bash
# FALLBACK ONLY - the normal path is the GitHub Actions workflow.
#
# Builds the same images locally with the same Dockerfile, filling the build
# args from your local git checkout, and loads them into kind. Useful when the
# workflow or ghcr.io is not available, and to see that the Dockerfile does not
# depend on GitHub at all: any CI system only has to pass the same build args.
#
# Usage: ./02-build-local.sh            -> tag local-<short sha>
# Then:  ./04-deploy.sh local-<short sha> --no-pull
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"          # the cluster repo root
DOCKERFILE="$HERE/../docker/Dockerfile"

clean() { printf '%s' "$1" | tr ',= \t' '____'; }

sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
short="$(printf '%s' "$sha" | cut -c1-7)"
ref="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
url="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed 's/\.git$//' || echo unknown)"
tag="local-$short"
# git rev-parse may leave .git/index.lock behind on some setups; nothing here writes the index.

build() { # dir name target tag
  echo "==> $2 ($3) -> $IMAGE_PREFIX/$2:$4"
  docker build -f "$DOCKERFILE" --target "$3" \
    --build-arg APP="$1" \
    --build-arg SERVICE_VERSION="$tag" \
    --build-arg VCS_REVISION="$sha" \
    --build-arg VCS_REF_NAME="$(clean "$ref")" \
    --build-arg VCS_REPOSITORY_URL="$(clean "$url")" \
    --build-arg CICD_PIPELINE_NAME=local-build \
    --build-arg CICD_RUN_ID=local \
    --build-arg CICD_RUN_URL=none \
    --label org.opencontainers.image.version="$4" \
    --label org.opencontainers.image.revision="$sha" \
    -t "$IMAGE_PREFIX/$2:$4" "$ROOT/apps/$1"
  kind load docker-image "$IMAGE_PREFIX/$2:$4" --name "$CLUSTER"
}

build RatingApi rating-api final "$tag"
build RatingApi rating-api naive "$tag-naive"
build QuoteApi  quote-api  final "$tag"
build QuoteWeb  quote-web  final "$tag"

echo
echo "Done. Deploy with: ./04-deploy.sh $tag --no-pull"
