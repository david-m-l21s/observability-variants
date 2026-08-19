# 04-spanmetrics-alerting — alerting on wide events, end to end

The same three services as every other variant — `QuoteWeb → QuoteApi → RatingApi`,
byte-for-byte the baseline images — but this variant answers a different question:

> A wide-event store is only an operational tool if it can **tell you** when
> something is wrong. How do we alert on these events, who owns the alerts, and
> how do we make that easy?

It adds three things to the baseline and changes no app code:

1. The collector runs the **`spanmetrics` connector**, which turns the span
   stream into small pre-aggregated metrics (`calls`, `duration`) in ClickHouse.
2. A small **in-cluster Grafana**, provisioned entirely from config, holds four
   alert rules over those metrics (plus one over raw spans).
3. A tiny **webhook stub** receives fired alerts and shows them on a web page,
   so the whole loop is self-contained — no Slack or PagerDuty account needed.

Everything writes to the ClickHouse database **`spanmetrics_alerting`**.

## Why alert on `spanmetrics` and not raw spans

You *can* aggregate raw spans in Grafana, and for one-off investigation you
should. But an alert rule runs the same query every minute, forever, and often
needs long history. `spanmetrics` pre-aggregates at write time, so alert queries
are cheap, evenly spaced, and — because the connector sits *before* any sampling
— complete even when traces are sampled (as in variant `03`). Latency is the one
signal we deliberately keep on raw spans, because a 95th-percentile over the
`Duration` column is simpler than histogram math. So this variant demonstrates
the honest real-world mix: mostly `spanmetrics`, latency and the dead-man's
switch on raw spans.

The connector keeps `insurance.decision` as a metric dimension. That is what
makes the business alert (rejection-rate) possible — a plain APM tool has no
such field.

## Why Grafana runs in the cluster here

Your normal Grafana lives off-cluster on the Lima VM. The alert path, though,
must reach both ClickHouse *and* the in-cluster webhook stub. From inside the
cluster that is one clean direction: ClickHouse via `host.docker.internal` (the
same path the collector already uses) and the stub via service DNS. So this
variant ships its own provisioned Grafana and leaves the VM Grafana untouched.

## Who owns which alert (the point behind the demo)

| Alert | Owner in real life | Why |
|-------|--------------------|-----|
| Service error rate | the service / vertical team | they know their own reliability target |
| Rejection-rate spike | fraud / underwriting | a business signal, not a technical one |
| Latency p95 | the service / vertical team | their service-level objective |
| No traffic / ingestion gap | the platform (observability) team | watch-the-watcher, shared infra |

The labels on each rule (`team`, `severity`) are what a real notification policy
would route on. Here everything routes to the one webhook stub, tagged with the
team that *would* have been paged, so you can see the routing without real
paging.

**Making it easy (not built here, but this is the paved path):** the error-rate
rule is a single rule grouped by service, so it already covers every service and
every future service with no per-service work. You only generate per-service
rules when a team needs its own threshold. A team's contribution then shrinks to
a few values (service, threshold, route) that a template expands — no ClickHouse
SQL in their hands.

## Prerequisites (shared, run once)

The baseline app **images** are reused as-is, so they must exist in the cluster.
From `cluster/scripts/`:

1. `./01-create-cluster.sh` — the kind cluster `obs-vm-tests`.
2. `./02-build-and-load-images.sh` — `rating-api:v1`, `quote-api:v1`, `quote-web:v1`
   (this variant builds **no** new images).
3. `./03-clickhouse-otel-user.sh` — the `otel` user on the VM ClickHouse.

The Lima VM (ClickHouse) must be running. Grafana here is in-cluster, so you do
**not** need the VM Grafana for this variant. The cluster nodes need outbound
internet the first time, to pull `python:3.12-slim`, `grafana/grafana`, and the
Grafana ClickHouse datasource plugin.

## Run it

```bash
cd scripts
./04-deploy.sh          # namespace, apps, collector, grafana, webhook stub
./05-port-forward.sh    # quote-web :8084, grafana :3001, webhook :8090
```

Ports (baseline `:8080`, `02` `:8081`, `03` `:8082`/`:8083`, this one `:8084`):

- `http://localhost:8084` — submit quotes
- `http://localhost:3001` — Grafana; Alerting → Alert rules shows the four rules
  and their state (anonymous editor access; `admin`/`admin` to log in)
- `http://localhost:8090` — the webhook stub; fired alerts appear here, newest
  first, page refreshes every 5s

## See the alerts fire

Generate calm traffic first, so you watch the state *change* rather than a cold
start:

```bash
./06-generate-load.sh            # ~60 healthy Approved quotes
```

Then trigger one scenario at a time:

```bash
./07-trigger-incidents.sh cascade      # rating-api -> 0, send quotes: error-rate (+p95) fire
./07-trigger-incidents.sh rejections   # batch of under-18 quotes: rejection-rate fires
./07-trigger-incidents.sh silence      # quote-web -> 0: no-traffic dead-man's switch fires
./07-trigger-incidents.sh restore      # scale back; alerts resolve
```

| Alert | Trigger | Mechanism |
|-------|---------|-----------|
| `Service error rate high` | `cascade` | spanmetrics `calls`, error share > 20% |
| `Quote rejection rate spike` | `rejections` | spanmetrics `calls` filtered on `insurance.decision` > 30% |
| `Quote p95 latency high` | load / CPU pressure | raw spans, `quantile(0.95)(Duration)` > 500 ms |
| `No quote traffic` | `silence` | raw spans, count over 2m < 1 (fires on empty too) |

**Timing note for a live demo:** an alert does not fire the instant a threshold
is crossed. Grafana evaluates rules on an interval (1m here) and each rule has a
`for` duration before it moves Pending → Firing. So expect 1–3 minutes. Metrics
also flush every ~15s. Script in a short wait rather than assuming it broke.

## Verify the metrics directly (optional)

```bash
CH='http://localhost:8123/?user=otel&password=otelpass'

# spanmetrics 'calls' by service and status
curl -s "$CH" --data-binary "
  SELECT ServiceName, Attributes['status.code'] AS status, sum(Value) AS calls
  FROM spanmetrics_alerting.otel_metrics_sum
  WHERE MetricName = 'calls' AND TimeUnix > now() - INTERVAL 10 MINUTE
  GROUP BY ServiceName, status ORDER BY ServiceName FORMAT PrettyCompact"

# rejection share (quote-api)
curl -s "$CH" --data-binary "
  SELECT Attributes['insurance.decision'] AS decision, sum(Value) AS calls
  FROM spanmetrics_alerting.otel_metrics_sum
  WHERE MetricName = 'calls' AND ServiceName = 'quote-api'
    AND TimeUnix > now() - INTERVAL 10 MINUTE
  GROUP BY decision ORDER BY calls DESC FORMAT PrettyCompact"
```

## Known caveats

- **The alert-rule provisioning is the fiddly part.** Grafana's provisioned
  alert-rule model (the `data[].model` fields, and the ClickHouse datasource
  `queryType`/`format` keys) varies between Grafana and plugin versions. If a
  rule imports but shows a query error, the fix is almost always a small tweak to
  those model fields — the SQL and thresholds themselves (shown above and in
  `40-grafana.yaml`) are the real content and are correct. As a fallback you can
  create the same rule in the UI: paste the SQL, reduce `last`, threshold as in
  the table.
- **Metric names.** The connector emits `calls` and `duration` by default; some
  collector versions used `calls_total`. If the metric queries return nothing,
  check the actual `MetricName` values in `otel_metrics_sum`.
- **DELTA temporality** is set on the connector so windowed `sum(Value)` queries
  are correct without counter-delta math. If you switch it to cumulative, the
  alert SQL must change.
- **Referred** (`risk >= 80`) is still unreachable in the current RatingApi
  (formula tops out ≈ 59), so only `Rejected` (age < 18) drives the rejection
  alert. Same note as `03`.
- **`for` + eval interval** mean alerts are intentionally slow to fire; that is
  correct behavior, not a fault.

## Teardown

```bash
kubectl delete namespace 04-spanmetrics-alerting

CH='http://localhost:8123/?user=otel&password=otelpass'
curl -s "$CH" --data-binary "DROP DATABASE IF EXISTS spanmetrics_alerting"
```

The baseline (`01-simple-apps` / `default`), the VM Grafana, and the shared
images are untouched.
