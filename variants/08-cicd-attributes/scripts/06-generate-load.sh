#!/usr/bin/env bash
# Send quotes through quote-web -> quote-api -> rating-api.
# Usage: ./06-generate-load.sh [count] [web-url]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
COUNT="${1:-40}"
WEB="${2:-http://localhost:${WEB_PORT}}"

VEHICLES=(small medium suv)
REGIONS=(urban rural suburban)
COVERS=(basic comprehensive)

ok=0; fail=0
echo "Sending $COUNT quotes to $WEB ..."
for _ in $(seq 1 "$COUNT"); do
  cust="CUST-$(printf '%02d' $(( (RANDOM % 10) + 1 )))"
  if [ $((RANDOM % 10)) -eq 0 ]; then age=17; else age=$((20 + RANDOM % 51)); fi
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WEB/api/quote" \
    -H 'Content-Type: application/json' \
    -d "{\"customerId\":\"$cust\",\"vehicleType\":\"${VEHICLES[$((RANDOM % 3))]}\",\"driverAge\":$age,\"region\":\"${REGIONS[$((RANDOM % 3))]}\",\"coverageLevel\":\"${COVERS[$((RANDOM % 2))]}\"}" \
    || echo 000)
  if [ "$code" = 200 ]; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
  sleep 0.2
done
echo "Done: $ok OK, $fail failed."
[ "$ok" -eq 0 ] && echo "WARN: nothing succeeded - is ./05-port-forward.sh running?" >&2
echo "The collector batches every ~5 s. Then: ./08-inspect.sh"
