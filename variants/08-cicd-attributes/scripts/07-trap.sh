#!/usr/bin/env bash
# Switch the trap deployment on or off.
#   on   rating-api-naive gets 1 replica. The rating-api Service now spreads
#        calls over two pods: the correct one and the naive one.
#   off  back to 0 replicas.
# Usage: ./07-trap.sh on|off
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
kubectl config use-context "kind-${CLUSTER}" >/dev/null
case "${1:-}" in
  on)  kubectl scale deploy/rating-api-naive -n "$NS" --replicas=1
       kubectl rollout status deploy/rating-api-naive -n "$NS" --timeout=300s ;;
  off) kubectl scale deploy/rating-api-naive -n "$NS" --replicas=0 ;;
  *)   echo "Usage: $0 on|off" >&2; exit 2 ;;
esac
kubectl get pods -n "$NS" -l app=rating-api -L flavour
