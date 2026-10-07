#!/usr/bin/env bash
# quote-web -> http://localhost:8089 (8086/8087 are variant 06, 8088 is 07).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
kubectl config use-context "kind-${CLUSTER}" >/dev/null
echo "quote-web -> http://localhost:${WEB_PORT}  (Ctrl-C to stop)"
echo "After a redeploy the forward breaks (pods replaced) - just start it again."
kubectl port-forward -n "$NS" svc/quote-web "${WEB_PORT}:8080"
