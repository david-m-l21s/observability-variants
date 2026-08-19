#!/usr/bin/env bash
# Trigger each alert on demand, so you can watch it move Normal -> Pending ->
# Firing and land on the webhook stub page (http://localhost:8090). Pick one.
#
# Usage: ./07-trigger-incidents.sh <scenario>
#   cascade     scale rating-api to 0, then send quotes  -> error-rate + p95 fire
#   rejections  send a batch of under-18 quotes          -> rejection-rate fires
#   silence     scale quote-web to 0                      -> no-traffic fires
#   restore     scale rating-api and quote-web back to 1  -> alerts resolve
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="04-spanmetrics-alerting"
URL="${URL:-http://localhost:8094}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

scenario="${1:-}"
case "$scenario" in
  cascade)
    echo "Scaling rating-api to 0 (quote-api calls will now error)..."
    kubectl scale deploy/rating-api -n "$NS" --replicas=0
    kubectl rollout status deploy/rating-api -n "$NS" --timeout=60s || true
    echo "Sending 40 quotes that now fail downstream..."
    for i in $(seq 1 40); do
      curl -s -X POST "$URL/api/quote" -H 'Content-Type: application/json' \
        -d '{"customerId":"CASCADE","vehicleType":"suv","driverAge":40,"region":"urban","coverageLevel":"comprehensive"}' \
        >/dev/null || true
      sleep 0.2
    done
    echo "Watch http://localhost:8090 — error-rate (and p95) should fire within ~1-2m."
    echo "Undo with: ./07-trigger-incidents.sh restore"
    ;;
  rejections)
    echo "Sending 40 under-18 quotes (each is Rejected in quote-api)..."
    for i in $(seq 1 40); do
      curl -s -X POST "$URL/api/quote" -H 'Content-Type: application/json' \
        -d '{"customerId":"MINOR","vehicleType":"small","driverAge":16,"region":"urban","coverageLevel":"basic"}' \
        >/dev/null || true
      sleep 0.2
    done
    echo "Watch http://localhost:8090 — rejection-rate should fire within ~2-3m."
    ;;
  silence)
    echo "Scaling quote-web to 0 (no traffic reaches the frontend)..."
    kubectl scale deploy/quote-web -n "$NS" --replicas=0
    echo "Watch http://localhost:8090 — no-traffic dead-man's switch fires within ~2m."
    echo "Undo with: ./07-trigger-incidents.sh restore"
    ;;
  restore)
    echo "Restoring rating-api and quote-web to 1 replica..."
    kubectl scale deploy/rating-api -n "$NS" --replicas=1
    kubectl scale deploy/quote-web  -n "$NS" --replicas=1
    kubectl rollout status deploy/rating-api -n "$NS" --timeout=120s || true
    kubectl rollout status deploy/quote-web  -n "$NS" --timeout=120s || true
    echo "Send fresh traffic (./06-generate-load.sh); alerts should resolve."
    ;;
  *)
    echo "Usage: $0 {cascade|rejections|silence|restore}" >&2
    exit 1
    ;;
esac
