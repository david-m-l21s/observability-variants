#!/usr/bin/env bash
# Drive all three database paths:
#   write  POST quote-web /api/quote          -> quote-api INSERT
#   read   GET  quote-api /quotes/{id}        -> SELECT by primary key
#   read   GET  quote-api /customers/{id}/quotes -> SELECT by index, ORDER BY
# plus one lookup of an id that does not exist (404, still a db span).
#
# Only 10 customer ids are used, so the history endpoint returns several rows.
# About 1 in 10 drivers is under 18, so Rejected quotes are stored too.
#
# Usage: ./06-generate-load.sh [count] [web-url] [api-url]
set -euo pipefail
COUNT="${1:-60}"
WEB="${2:-http://localhost:8086}"
API="${3:-http://localhost:8087}"

VEHICLES=(small medium suv)
REGIONS=(urban rural suburban)
COVERS=(basic comprehensive)

writes=0; reads=0; last_id=""
echo "Sending $COUNT quotes to $WEB, reading back through $API ..."
for i in $(seq 1 "$COUNT"); do
  cust="CUST-$(printf '%02d' $(( (RANDOM % 10) + 1 )))"
  vehicle="${VEHICLES[$((RANDOM % 3))]}"
  region="${REGIONS[$((RANDOM % 3))]}"
  cover="${COVERS[$((RANDOM % 2))]}"
  if [ $((RANDOM % 10)) -eq 0 ]; then age=17; else age=$((20 + RANDOM % 51)); fi

  resp=$(curl -s -X POST "$WEB/api/quote" -H 'Content-Type: application/json' \
    -d "{\"customerId\":\"$cust\",\"vehicleType\":\"$vehicle\",\"driverAge\":$age,\"region\":\"$region\",\"coverageLevel\":\"$cover\"}" \
    || true)
  writes=$((writes + 1))
  # System.Text.Json web defaults -> camelCase "quoteId".
  id=$(printf '%s' "$resp" | sed -n 's/.*"quoteId":"\([0-9a-f]*\)".*/\1/p')
  [ -n "$id" ] && last_id="$id"

  if [ -n "$id" ] && [ $((i % 2)) -eq 0 ]; then
    curl -s -o /dev/null "$API/quotes/$id" || true; reads=$((reads + 1))
  fi
  if [ $((i % 3)) -eq 0 ]; then
    curl -s -o /dev/null "$API/customers/$cust/quotes?limit=10" || true; reads=$((reads + 1))
  fi
  sleep 0.2
done

# One miss: a well-formed id that was never written.
code=$(curl -s -o /dev/null -w '%{http_code}' "$API/quotes/00000000000000000000000000000000" || true)
reads=$((reads + 1))

echo "Done: $writes writes, $reads reads (the miss returned HTTP $code, expect 404)."
[ -n "$last_id" ] && echo "Last quote: curl -s $API/quotes/$last_id"
[ -z "$last_id" ] && echo "WARN: no quoteId parsed from any response - is ./05-port-forward.sh running?" >&2
echo "Collector batches every ~5s. Then: ./08-inspect.sh"
