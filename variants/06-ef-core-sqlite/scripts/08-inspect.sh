#!/usr/bin/env bash
# What did the EF Core instrumentation actually produce? Queries the variant's
# ClickHouse database (ef_core_sqlite) over the Lima port-forward on :8123.
#
# Usage: ./08-inspect.sh [minutes]   (default 60 - only spans from that window)
#
# A "db span" below = a span carrying db.system.name (new conventions) or
# db.system (old conventions). Deliberately NOT filtered on ScopeName, so the
# query does not depend on the instrumentation's ActivitySource name; section 1
# shows that name anyway.
set -euo pipefail
MIN="${1:-60}"
CH="${CH:-http://localhost:8123/?user=otel&password=otelpass&database=ef_core_sqlite}"

q() { # title, sql
  echo
  echo "== $1"
  curl -sS "$CH" --data-binary "$2 FORMAT PrettyCompactMonoBlock"
}

WIN="Timestamp > now() - INTERVAL $MIN MINUTE"
ISDB="(mapContains(SpanAttributes, 'db.system.name') OR mapContains(SpanAttributes, 'db.system'))"

q "1. Spans per service, instrumentation scope and DB_INSTRUMENTATION mode (last $MIN min)
   Expect: mode=none -> no EF scope row at all. mode=efcore -> an EF scope row, kind Client." "
SELECT ResourceAttributes['app.db_instrumentation'] AS mode,
       ServiceName, ScopeName, SpanKind, count() AS spans
FROM otel_traces WHERE $WIN
GROUP BY mode, ServiceName, ScopeName, SpanKind
ORDER BY mode, ServiceName, ScopeName"

q "2. DB span shapes. With OTEL_SEMCONV_STABILITY_OPT_IN=database the span name is
   db.query.summary ('INSERT quotes'); without it every span is named 'main'.
   roots = spans with no parent: the EnsureCreated statements at startup." "
SELECT SpanName,
       SpanAttributes['db.system.name'] AS sys_new,
       SpanAttributes['db.system']      AS sys_old,
       SpanAttributes['db.query.summary'] AS summary,
       count() AS spans,
       countIf(ParentSpanId = '') AS roots,
       round(quantile(0.5)(Duration) / 1e6, 3)  AS p50_ms,
       round(quantile(0.95)(Duration) / 1e6, 3) AS p95_ms
FROM otel_traces WHERE $WIN AND $ISDB
GROUP BY SpanName, sys_new, sys_old, summary
ORDER BY spans DESC"

q "3. Every attribute key that appears on db spans, and how often.
   LEAK CHECK: any db.query.parameter.* row means parameter values (personal
   data) are being stored. Expect none." "
SELECT arrayJoin(mapKeys(SpanAttributes)) AS key, count() AS spans,
       if(startsWith(key, 'db.query.parameter.'), '<<< LEAK', '') AS flag
FROM otel_traces WHERE $WIN AND $ISDB
GROUP BY key ORDER BY key"

q "4. One sample query text per span name, and its width in bytes.
   Literals are replaced by '?' (sanitized); parameters appear as @p0, @__id_0 ..." "
SELECT SpanName,
       any(if(SpanAttributes['db.query.text'] != '', SpanAttributes['db.query.text'],
              SpanAttributes['db.statement'])) AS sample_text,
       max(length(SpanAttributes['db.query.text']) + length(SpanAttributes['db.statement'])) AS max_bytes
FROM otel_traces WHERE $WIN AND $ISDB
GROUP BY SpanName ORDER BY SpanName"

q "5. Request time vs. DB time, per endpoint and mode (quote-api server spans).
   db_ms covers command EXECUTION only, not reading the result set, so
   req_ms - db_ms is not all 'app code'. mode=none -> db_spans 0: the DB time
   is still inside req_ms, you just cannot see it." "
WITH db AS (
  SELECT TraceId, ParentSpanId, sum(Duration) AS d, count() AS n
  FROM otel_traces WHERE $WIN AND $ISDB
  GROUP BY TraceId, ParentSpanId
)
SELECT r.SpanName AS route,
       r.ResourceAttributes['app.db_instrumentation'] AS mode,
       count() AS requests,
       round(avg(r.Duration) / 1e6, 2) AS req_ms,
       round(avg(db.d) / 1e6, 2)       AS db_ms,
       round(avg(db.n), 2)             AS db_spans_per_req
FROM otel_traces AS r
LEFT JOIN db ON db.TraceId = r.TraceId AND db.ParentSpanId = r.SpanId
WHERE r.Timestamp > now() - INTERVAL $MIN MINUTE
  AND r.ServiceName = 'quote-api' AND r.SpanAttributes['http.route'] != ''
GROUP BY route, mode ORDER BY route, mode"

q "6. quote-api log records by category. With ./07-switch.sh ef-logs the category
   Microsoft.EntityFrameworkCore.Database.Command appears: one log line per
   command, i.e. the same fact as the db span, stored a second time." "
SELECT ScopeName AS category, SeverityText AS severity, count() AS records
FROM otel_logs
WHERE Timestamp > now() - INTERVAL $MIN MINUTE AND ServiceName = 'quote-api'
GROUP BY category, severity ORDER BY records DESC"
q "7. Parameter VALUES per db span, newest first (only after ./07-switch.sh params).
   Empty result = parameters are off, which is the safe default." "
SELECT Timestamp, SpanName,
       mapFilter((k, v) -> startsWith(k, 'db.query.parameter.'), SpanAttributes) AS parameters,
       SpanAttributes['db.query.text'] AS query_text
FROM otel_traces
WHERE $WIN AND $ISDB
  AND length(mapFilter((k, v) -> startsWith(k, 'db.query.parameter.'), SpanAttributes)) > 0
ORDER BY Timestamp DESC LIMIT 15"
echo
