#!/usr/bin/env bash
# Measure the split, rather than asserting it.
#
# Prints, side by side:
#   1. what is in the SYSTEM store  (ClickHouse database telescope_vs_microscope)
#   2. what is in the DEBUG store   (in-cluster Loki)
#
# The two claims this checks:
#   - ClickHouse contains NO Debug rows. Not few. None.
#   - Loki contains only debug-tier records, and no unmarked Information rows.
#
# Requires: the Lima VM ClickHouse reachable on localhost:8123 (Lima forwards it,
# same as scripts/03-clickhouse-otel-user.sh uses) and ./05-port-forward.sh
# running so Loki is on localhost:3101.
set -euo pipefail
CH="${CH:-http://localhost:8123/?user=otel&password=otelpass}"
LOKI="${LOKI:-http://localhost:3101}"
WINDOW="${WINDOW:-60m}"
DB=telescope_vs_microscope

q() { curl -sS "$CH" --data-binary "$1"; }

echo "=============================================================="
echo " SYSTEM STORE  —  ClickHouse database $DB"
echo "=============================================================="
echo
echo "-- log records by severity (expect NO 'Debug' row) --"
q "SELECT SeverityText AS severity, count() AS records
   FROM $DB.otel_logs
   WHERE Timestamp > now() - INTERVAL 1 HOUR
   GROUP BY severity ORDER BY records DESC
   FORMAT PrettyCompact" || echo "  (query failed — is the Lima VM ClickHouse up?)"
echo
echo "-- any debug-tier record that leaked in (expect 0) --"
q "SELECT count() AS leaked_debug_tier_rows
   FROM $DB.otel_logs
   WHERE Timestamp > now() - INTERVAL 1 HOUR
     AND (LogAttributes['telemetry.tier'] = 'debug' OR SeverityText IN ('Debug','Trace'))
   FORMAT PrettyCompact" || true
echo
echo "-- totals --"
q "SELECT
     (SELECT count() FROM $DB.otel_logs   WHERE Timestamp > now() - INTERVAL 1 HOUR) AS log_rows,
     (SELECT count() FROM $DB.otel_traces WHERE Timestamp > now() - INTERVAL 1 HOUR) AS span_rows
   FORMAT PrettyCompact" || true

echo
echo "=============================================================="
echo " DEBUG STORE  —  Loki ($LOKI), last $WINDOW"
echo "=============================================================="
echo

# $1 = a full LogQL log selector (stream selector plus any pipeline stages).
#
# Only k8s_namespace_name, k8s_deployment_name and service_name are INDEX labels
# here — Loki's OTLP ingestion puts severity_text, telemetry_tier and trace_id in
# structured metadata. Those can therefore only be used as pipeline filters after
# a `|`, never inside the {...} selector. Putting them in the selector silently
# returns 0, which would make this script report a perfect split that isn't real.
loki_count() {
  curl -sS -G "$LOKI/loki/api/v1/query" \
    --data-urlencode "query=sum(count_over_time($1[$WINDOW]))" \
  | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    if d.get('status') != 'success':
        print('n/a'); raise SystemExit
    r=d.get('data',{}).get('result',[])
    print(int(float(r[0]['value'][1])) if r else 0)
except Exception:
    print('n/a')
"
}

NS_SEL='{k8s_namespace_name="05-telescope-vs-microscope"}'

total=$(loki_count "$NS_SEL")
marked=$(loki_count "$NS_SEL | telemetry_tier=\"debug\"")
echo "  lines in Loki (all services)            : $total"
echo "  of which explicitly marked telemetry.tier=debug : $marked"
echo "  the rest are unmarked Debug/Trace records (framework noise),"
echo "  which the severity axis routed here."
echo
echo "-- Information-severity lines in Loki that are NOT marked as debug tier --"
echo "-- (expect 0: those belong in ClickHouse) --"
leak=$(loki_count "$NS_SEL | severity_text=\"Information\" | telemetry_tier!=\"debug\"")
echo "  leaked_information_rows: $leak"
echo
echo "=============================================================="
echo " Read it like this: the two stores should not overlap at all."
echo " Run ./07-trigger-defect.sh flood, then this script again — Loki"
echo " climbs steeply, the ClickHouse log count barely moves."
echo "=============================================================="
