#!/usr/bin/env bash
# Generate a healthy baseline of quote traffic across all three regions, so the
# dashboard has a "before" to compare against. Run this BEFORE breaking
# anything, otherwise you only see a broken system and not a change.
#
# Region mix is deliberately even, so that when suburban later goes to 100%
# rejected the other two visibly stay put.
#
# Usage: ./06-generate-load.sh [count] [url]
#   count  number of quotes to send (default 90)
#   url    frontend base URL (default http://localhost:8085)
set -euo pipefail
COUNT="${1:-90}"
URL="${2:-http://localhost:8085}"

REGIONS=(urban rural suburban)
VEHICLES=(small medium suv)
COVERS=(basic comprehensive)

echo "Sending $COUNT quotes to $URL across regions: ${REGIONS[*]} ..."
for i in $(seq 1 "$COUNT"); do
  region="${REGIONS[$((RANDOM % 3))]}"
  vehicle="${VEHICLES[$((RANDOM % 3))]}"
  cover="${COVERS[$((RANDOM % 2))]}"
  # Ages 20-70 only, so age is never the reason for a rejection here and the
  # region signal stays clean.
  age=$((20 + RANDOM % 51))
  curl -s -X POST "$URL/api/quote" \
    -H 'Content-Type: application/json' \
    -d "{\"customerId\":\"LOAD-$i\",\"vehicleType\":\"$vehicle\",\"driverAge\":$age,\"region\":\"$region\",\"coverageLevel\":\"$cover\"}" \
    >/dev/null || true
  sleep 0.2
done
echo "Done. Collector batches every ~5s; the dashboard refreshes every 10s."
