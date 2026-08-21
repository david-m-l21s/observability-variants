#!/usr/bin/env bash
# Flip the pieces this variant demonstrates. Pick one.
#
# Usage: ./07-trigger-defect.sh <scenario>
#
#   break     switch quote-api to eligibility ruleset v2, in which "suburban"
#             was silently dropped from the licensed regions. Still HTTP 200,
#             still fast, no exception, no extra memory. Then send load.
#             -> the telescope sees it, a status-code dashboard does not.
#
#   restore   switch quote-api back to ruleset v1.
#
#   flood     set Logging__LogLevel__Default=Debug on all three services, so the
#             ASP.NET Core and HttpClient debug torrent starts flowing. All of it
#             carries no telemetry.tier marker and sits below INFO, so ALL of it
#             goes to Loki. Run ./08-measure-split.sh before and after: the
#             ClickHouse log count barely moves, Loki's climbs steeply.
#             This is the cost argument, as a measurement rather than a claim.
#
#   calm      undo flood.
#
# Note: each of these is an env change, so the pods roll. That is on purpose —
# it is what a configuration change looks like in production, and it gives the
# dashboard a clean before/after edge.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="05-telescope-vs-microscope"
URL="${URL:-http://localhost:8085}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

case "${1:-}" in
  break)
    echo "Switching quote-api to eligibility ruleset v2 (suburban unlicensed)..."
    kubectl set env deploy/quote-api -n "$NS" QUOTE_ELIGIBILITY_RULESET=v2
    kubectl rollout status deploy/quote-api -n "$NS" --timeout=180s
    echo "Sending 90 quotes over the broken ruleset..."
    "$HERE/06-generate-load.sh" 90 "$URL"
    echo
    echo "Now look at the dashboard (http://localhost:3002):"
    echo "  - 'Rejected share per region' should isolate suburban"
    echo "  - 'Decisions by region and ruleset' should pin it to ruleset v2"
    echo "  - error rate, latency and resources are unchanged"
    echo "Undo with: ./07-trigger-defect.sh restore"
    ;;
  restore)
    echo "Switching quote-api back to eligibility ruleset v1..."
    kubectl set env deploy/quote-api -n "$NS" QUOTE_ELIGIBILITY_RULESET=v1
    kubectl rollout status deploy/quote-api -n "$NS" --timeout=180s
    echo "Send fresh traffic (./06-generate-load.sh); suburban should recover."
    ;;
  flood)
    echo "Run ./08-measure-split.sh FIRST and note the two numbers."
    echo "Turning on framework debug logging on all three services..."
    for d in quote-api rating-api quote-web; do
      kubectl set env deploy/"$d" -n "$NS" Logging__LogLevel__Default=Debug Logging__LogLevel__Microsoft=Debug
    done
    for d in quote-api rating-api quote-web; do
      kubectl rollout status deploy/"$d" -n "$NS" --timeout=180s
    done
    echo "Sending 90 quotes with the debug torrent on..."
    "$HERE/06-generate-load.sh" 90 "$URL"
    echo
    echo "Now run ./08-measure-split.sh again. Expect: Loki up a lot,"
    echo "ClickHouse log rows up only by the handful of INFO lines."
    echo "Undo with: ./07-trigger-defect.sh calm"
    ;;
  calm)
    echo "Turning framework debug logging back off..."
    for d in quote-api rating-api quote-web; do
      kubectl set env deploy/"$d" -n "$NS" Logging__LogLevel__Default=Information Logging__LogLevel__Microsoft=Warning
    done
    for d in quote-api rating-api quote-web; do
      kubectl rollout status deploy/"$d" -n "$NS" --timeout=180s
    done
    echo "Done."
    ;;
  *)
    echo "Usage: $0 {break|restore|flood|calm}" >&2
    exit 1
    ;;
esac
