#!/usr/bin/env bash
# Generate steady, healthy quote traffic so the spanmetrics counters have data
# and the alerts sit in a calm "Normal" state. Run this first, before triggering
# an incident, so you can see the state CHANGE rather than a cold start.
#
# Usage: ./06-generate-load.sh [count] [url]
#   count  number of quotes to send (default 60)
#   url    frontend base URL (default http://localhost:8084)
set -euo pipefail
COUNT="${1:-60}"
URL="${2:-http://localhost:8094}"

echo "Sending $COUNT routine (Approved) quotes to $URL ..."
for i in $(seq 1 "$COUNT"); do
  curl -s -X POST "$URL/api/quote" \
    -H 'Content-Type: application/json' \
    -d '{"customerId":"LOAD","vehicleType":"small","driverAge":30,"region":"rural","coverageLevel":"basic"}' \
    >/dev/null || true
  sleep 0.2
done
echo "Done. Metrics flush every ~15s; alert rules evaluate every ~1m."
