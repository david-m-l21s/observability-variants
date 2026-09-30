#!/usr/bin/env bash
# Send the fixed probe traffic to the probe app. run.sh calls this after every
# deployment; you can also run it by hand against ./05-port-forward.sh.
#
# The request set is the same for every configuration, so two runs differ only
# in what the configuration let through. Each section targets options of the
# configurator:
#
#   1 noise       /health /ready /metrics static files /_blazor ...   -> Filter, file-extension filter
#   2 preflight   OPTIONS with CORS headers                          -> "Drop CORS preflight"
#   3 shop        orders (deep traces), reads, business errors       -> EF Core, HttpClient, custom sources
#   4 failures    exceptions in handler / one level down / DNS / db  -> RecordException, EnrichWithException
#   5 outgoing    calls to the collector host and to /health         -> FilterHttpRequestMessage
#   6 span size   /api/wide, /api/db/long-query                      -> span limits
#   7 sampling    200 x GET /api/products/{sku}, 8 in parallel        -> sampler ratio (skipped with --quick)
#   8 flush       POST /probe/flush                                  -> everything exported now
#
# Every request carries x-tenant-id, x-correlation-id, Authorization and Cookie
# headers: "Request headers -> span attributes" can then be checked, including
# that the credential headers never show up.
#
# Usage: ./06-probe.sh [--quick] [base-url]      (default http://localhost:8088)
#        EXPECT_RUN_ID=<run id> ./06-probe.sh    (wait until the pod of that run answers)
# Written for bash 3.2 (macOS): no mapfile, no associative arrays.
set -euo pipefail

QUICK=0
BASE="http://localhost:8088"
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    http*) BASE="$a" ;;
    *) echo "Usage: $0 [--quick] [base-url]" >&2; exit 1 ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CODES="$TMP/codes"

HDRS=(-H "x-tenant-id: tenant-42" -H "x-correlation-id: probe-$$"
      -H "Authorization: Bearer probe-secret-token" -H "Cookie: session=probe-cookie")

# req METHOD PATH [JSON-BODY] -> prints the response body to stdout, records the status code.
req() {
  local m="$1" p="$2" d="${3:-}" out="$TMP/body" code
  if [ -n "$d" ]; then
    code=$(curl -s -o "$out" -w '%{http_code}' -X "$m" "${HDRS[@]}" \
      -H 'Content-Type: application/json' --data "$d" "$BASE$p" || true)
  else
    code=$(curl -s -o "$out" -w '%{http_code}' -X "$m" "${HDRS[@]}" "$BASE$p" || true)
  fi
  [ -n "$code" ] || code=000
  echo "$code" >> "$CODES"
  cat "$out" 2>/dev/null || true
}
q() { req "$@" >/dev/null; }

section() { : > "$CODES"; printf '%-11s' "$1"; }
summary() {
  # e.g. "200 x14  404 x3"
  sort "$CODES" | uniq -c | awk '{ printf "%s x%s  ", $2, $1 } END { print "" }'
}

# --- wait for the right pod --------------------------------------------------
for _ in $(seq 1 30); do
  info=$(curl -s "$BASE/probe/info" || true)
  run=$(printf '%s' "$info" | sed -n 's/.*"runId":"\([^"]*\)".*/\1/p')
  if [ -n "$run" ] && { [ -z "${EXPECT_RUN_ID:-}" ] || [ "$run" = "$EXPECT_RUN_ID" ]; }; then break; fi
  sleep 1
done
if [ -z "${run:-}" ]; then echo "The probe app does not answer on $BASE." >&2; exit 1; fi
if [ -n "${EXPECT_RUN_ID:-}" ] && [ "$run" != "$EXPECT_RUN_ID" ]; then
  echo "The probe app on $BASE is run '$run', expected '$EXPECT_RUN_ID'." >&2; exit 1
fi
src=$(printf '%s' "$info" | sed -n 's/.*"activitySource":"\([^"]*\)".*/\1/p')
fw=$(printf '%s' "$info" | sed -n 's/.*"framework":"\([^"]*\)".*/\1/p')
echo "Probing $BASE — run $run, ActivitySource $src, $fw"

# --- 1 noise -----------------------------------------------------------------
section "noise"
for _ in 1 2 3; do
  for p in /health /healthz /ready /alive /metrics /swagger/index.html /favicon.ico \
           /css/site.css /js/site.js /lib/jquery.min.js /_framework/blazor.web.js /_content/app.css; do
    q GET "$p"
  done
  q POST "/_blazor/negotiate?negotiateVersion=1"
done
summary

# --- 2 preflight ---------------------------------------------------------------
section "preflight"
for _ in 1 2 3; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$BASE/api/orders" \
    -H "Origin: http://shop.example" -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: content-type" || true)
  echo "${code:-000}" >> "$CODES"
done
summary

# --- 3 shop --------------------------------------------------------------------
order_body() { # customer -> JSON body with 1-4 random lines
  local n=$(( (RANDOM % 4) + 1 )) lines="" i
  for i in $(seq 1 "$n"); do
    lines="$lines{\"sku\":\"SKU-$(printf '%03d' $(( (RANDOM % 30) + 1 )))\",\"quantity\":$(( (RANDOM % 3) + 1 ))},"
  done
  printf '{"customerId":"%s","lines":[%s]}' "$1" "${lines%,}"
}

section "shop"
q GET /api/products
q GET /api/v1.0/products
q GET /api/products/SKU-005
ids=""
for _ in $(seq 1 20); do
  cust="C$(printf '%03d' $(( (RANDOM % 50) + 1 )))"
  body=$(req POST /api/orders "$(order_body "$cust")")
  id=$(printf '%s' "$body" | sed -n 's/.*"orderId":"\([0-9a-f]*\)".*/\1/p')
  [ -n "$id" ] && ids="$ids $id"
done
n=0
for id in $ids; do
  n=$((n + 1)); [ "$n" -le 5 ] || break
  q GET "/api/orders/$id"
done
for c in C001 C002 C003 C004 C005; do q GET "/api/customers/$c/orders?limit=5"; done
# business errors: unknown customer (404), unknown sku (400), no stock (409), bad quantity (400)
q POST /api/orders '{"customerId":"C999","lines":[{"sku":"SKU-001","quantity":1}]}'
q POST /api/orders '{"customerId":"C999","lines":[{"sku":"SKU-002","quantity":1}]}'
q POST /api/orders '{"customerId":"C010","lines":[{"sku":"SKU-404","quantity":1}]}'
q POST /api/orders '{"customerId":"C011","lines":[{"sku":"SKU-003","quantity":5000}]}'
q POST /api/orders '{"customerId":"C012","lines":[{"sku":"SKU-004","quantity":2},{"sku":"SKU-006","quantity":5000}]}'
q POST /api/orders '{"customerId":"C013","lines":[{"sku":"SKU-005","quantity":0}]}'
q GET /api/orders/does-not-exist
summary

# --- 4 failures ------------------------------------------------------------------
section "failures"
for _ in 1 2 3; do q GET /api/fail; done
for _ in 1 2; do q GET /api/fail/nested; q GET /api/fail/unreachable; q GET /api/fail/db; done
summary

# --- 5 outgoing --------------------------------------------------------------------
section "outgoing"
for _ in 1 2 3; do q GET /api/diagnostics/ping; done
summary

# --- 6 span size -------------------------------------------------------------------
section "span size"
for _ in 1 2; do q GET "/api/wide?attrs=200&events=40&links=40&valueLength=20000"; q GET "/api/db/long-query?n=1500"; done
summary

# --- 7 sampling ----------------------------------------------------------------------
if [ "$QUICK" -eq 0 ]; then
  section "sampling"
  for i in $(seq 1 200); do
    echo "$BASE/api/products/SKU-$(printf '%03d' $(( (i % 30) + 1 )))"
  done | xargs -P 8 -n 1 curl -s -o /dev/null -w '%{http_code}\n' "${HDRS[@]}" >> "$CODES" || true
  summary
fi

# --- 8 flush -------------------------------------------------------------------------
section "flush"
flushed=$(req POST /probe/flush)
summary
case "$flushed" in
  *'"flushed":true'*) ;;
  *) echo "  note: ForceFlush did not confirm ($flushed). Spans still arrive with the next export." ;;
esac
sleep 3 # collector batch timeout (1 s) + ClickHouse insert
echo "Probe finished for run $run."
