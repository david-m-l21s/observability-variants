# 05-telescope-vs-microscope — two log tiers, one TraceId bridge

The same three services as every other variant — `QuoteWeb → QuoteApi → RatingApi` —
but this variant answers a different question:

> Observability works on **systems**, not on **functions**. The wide-event store
> should be a telescope, not a microscope: it localizes a problem, and only then
> do logs or a debugger explain the exact code. So which telemetry belongs in the
> wide-event store, and where does the rest go?

The answer implemented here is a **strict two-tier split of log records**:

| Tier | Contains | Store | Retention |
| --- | --- | --- | --- |
| **System** (telescope) | Spans with their attributes, plus log records at `Information`, `Warning`, `Error` | ClickHouse, database `telescope_vs_microscope` | long |
| **Debug** (microscope) | Anything marked `telemetry.tier=debug`, plus anything below `Information` severity | In-cluster Loki | 24h |

**Nothing is written to both.** In particular, errors are **not** duplicated into
the debug store. A system-relevant failure is already visible on the span as
`StatusCode` + `StatusMessage`, so a second copy in Loki would store the same
fact twice. The only link between the two stores is the **TraceId**.

Loki is deliberately a placeholder. The point of this variant is the routing
rule, not the product — in T2A the debug store could just as well be the Splunk
that is staying around anyway.

## What differs from the baseline

1. **The collector has two log pipelines instead of one** (`k8s/20-otel-collector.yaml`).
   Each has a `filter` processor, and the two conditions are strict complements.
2. **`QuoteApi` and `RatingApi` mark their own debug output** with a tier
   attribute, and are rebuilt as `quote-api-tm:v1` / `rating-api-tm:v1`.
   `QuoteWeb` is unchanged and reuses the baseline `quote-web:v1`.
3. **An in-cluster Loki** (`k8s/30-loki.yaml`) is the debug store.
4. **An in-cluster Grafana** (`k8s/40-grafana.yaml`) with both datasources and a
   provisioned dashboard, so the VM Grafana stays untouched.
5. **`QuoteApi` carries a deliberate defect behind an env var**, so the telescope
   has something real to localize.

## The two axes, and why severity alone is not enough

Severity answers *how bad is this*. It does not answer *who is this for*. Those
are different questions, and collapsing them causes trouble in both directions: a
stack trace attached to an `Error` is developer detail, and a business-relevant
fact logged at `Debug` would silently vanish from the system store.

So the marker is an explicit attribute, set with an `ILogger` scope:

```csharp
using (logger.BeginScope(TelemetryTier.Debug))
{
    logger.LogDebug("Ruleset {Ruleset} licenses regions: {Regions}",
        ruleset, string.Join(",", licensedRegions));
}
```

```csharp
static class TelemetryTier
{
    public static readonly Dictionary<string, object> Debug = new()
    {
        ["telemetry.tier"] = "debug"
    };
}
```

This requires `IncludeScopes = true` on the OpenTelemetry logging provider —
without it the scope's key/value pairs never become OTLP log-record attributes
and the collector has nothing to filter on.

Severity is still used as a **second** axis, so that library and framework debug
output — which will never carry a marker — is routed correctly without anyone
retrofitting anything:

```yaml
# The filter processor DROPS what matches. Read these as "thrown away".
filter/system_tier:                     # -> ClickHouse
  logs:
    log_record:
      - severity_number < SEVERITY_NUMBER_INFO
      - 'attributes["telemetry.tier"] == "debug"'

filter/debug_tier:                      # -> Loki
  logs:
    log_record:
      - 'severity_number >= SEVERITY_NUMBER_INFO and attributes["telemetry.tier"] != "debug"'
```

A record with no `telemetry.tier` attribute compares as `nil != "debug"`, which
is true, so unmarked `Information` and above is correctly dropped from the debug
pipeline. The two conditions are exact complements: every record lands in one
store and only one.

## The defect the telescope has to find

`QuoteApi` reads an eligibility ruleset from the environment:

```csharp
var ruleset = builder.Configuration["QUOTE_ELIGIBILITY_RULESET"] ?? "v1";
var licensedRegions = ruleset == "v2"
    ? new[] { "urban", "rural" }              // the regression: suburban dropped
    : new[] { "urban", "rural", "suburban" };
```

Under `v2`, every suburban quote is rejected. This is deliberately invisible to
classical monitoring: HTTP stays 200, no exception is thrown, latency does not
move, CPU and memory do not move. A dashboard built on status codes and resource
metrics reports a perfectly healthy system.

What makes it findable is *where each piece of information is put*:

```csharp
// SYSTEM TIER — two values, costs nothing, queryable across every service.
span?.SetTag("quote.ruleset", ruleset);
span?.SetTag("insurance.decision", "Rejected");

// DEBUG TIER — free text, high cardinality, explains one function only.
logger.LogDebug("Quote {QuoteId} eligibility reasons: {Reasons}", quoteId, ...);
```

Note also what is **absent**: the baseline logs a `Warning` when it rejects a
quote. That `Warning` is gone here on purpose. A rejection is a normal business
outcome, not an incident, so it belongs on the span as an attribute rather than
in a log line.

## Prerequisites (shared, run once)

```bash
# from cluster/scripts
./01-create-cluster.sh            # if the kind cluster doesn't exist yet
./02-build-and-load-images.sh     # needed once for the baseline quote-web:v1
./03-clickhouse-otel-user.sh      # once, creates otel:otelpass in the Lima VM
```

## Run it

```bash
# from cluster/variants/05-telescope-vs-microscope/scripts
./02-build-and-load-images.sh     # builds quote-api-tm:v1 and rating-api-tm:v1
./04-deploy.sh
./05-port-forward.sh              # leave running in its own terminal
```

| What | Where |
| --- | --- |
| quote-web | http://localhost:8085 |
| Grafana | http://localhost:3002 → *Variants / 05 Telescope vs. Microscope* |
| Loki (for the measure script) | http://localhost:3101 |

## The walkthrough

The dashboard's top panel repeats these four steps, so it can be followed
without this file.

**1. Establish a baseline, then break it.**

```bash
./06-generate-load.sh             # 90 quotes, even mix of urban/rural/suburban
./07-trigger-defect.sh break      # switch to ruleset v2, then send 90 more
```

Ages are drawn from 20–70 only, so age is never a rejection reason and the region
signal stays clean. Expect the overall rejected share to go from 0% to about 33%.

**2. Localize — telescope.** *Rejected share per region over time* isolates
`suburban` at 100% while `urban` and `rural` stay at 0%. *Decisions by region and
ruleset* adds the second half of the answer: only pods on `quote.ruleset = v2`
reject it. *Rating calls over time* shows the effect one service downstream, since
a rejected quote never reaches `rating-api` — and `rating-api` needed no
instrumentation for that to be visible. No log line has been read yet.

**3. Prove the split.**

```bash
./08-measure-split.sh
```

It prints ClickHouse log records by severity (expect **no** `Debug` row), a
leak check for debug-tier records that made it into ClickHouse (expect **0**),
and the Loki line counts. Then:

```bash
./07-trigger-defect.sh flood      # framework debug logging on, everywhere
./08-measure-split.sh             # compare
./07-trigger-defect.sh calm
```

Loki's count climbs steeply; the ClickHouse log count barely moves. That is the
cost argument as a measurement rather than a claim.

**4. Explain — microscope.** Click a `trace_id` in *Rejected quotes to
investigate*, or paste one into the `traceId` variable at the top. The panel at
the bottom right shows the debug lines for that single request, including which
region list the code actually used. From here it is a debugging problem, not an
observability problem.

## Query the two stores directly (optional)

```bash
# SYSTEM store — no Debug rows should ever exist here
curl -s 'http://localhost:8123/?user=otel&password=otelpass' --data-binary "
  SELECT SeverityText, count() FROM telescope_vs_microscope.otel_logs
  GROUP BY SeverityText ORDER BY 2 DESC FORMAT PrettyCompact"

# SYSTEM store — the telescope query, in one line
curl -s 'http://localhost:8123/?user=otel&password=otelpass' --data-binary "
  SELECT SpanAttributes['insurance.region'] AS region,
         SpanAttributes['quote.ruleset']    AS ruleset,
         countIf(SpanAttributes['insurance.decision']='Rejected') AS rejected,
         count() AS total
  FROM telescope_vs_microscope.otel_traces
  WHERE ServiceName='quote-api' AND SpanAttributes['insurance.decision'] != ''
  GROUP BY region, ruleset ORDER BY region FORMAT PrettyCompact"
```

```bash
# DEBUG store — one trace's debug lines
curl -sG http://localhost:3101/loki/api/v1/query_range \
  --data-urlencode '{k8s_namespace_name="05-telescope-vs-microscope"} | trace_id = "<paste>"'
```

## Known caveats

- **Only `k8s_namespace_name`, `k8s_deployment_name` and `service_name` are index
  labels in Loki.** `severity_text`, `telemetry_tier` and `trace_id` arrive as
  structured metadata, so they can only be used as pipeline filters after a `|`,
  never inside the `{...}` stream selector. Putting one in the selector returns
  zero rows silently — which would make the split look perfect when it is not.
  `allow_structured_metadata: true` in the Loki config is what keeps them
  queryable at all.
- **Log records with no severity at all** (`severity_number = 0`) land in the
  debug store, because `0 < SEVERITY_NUMBER_INFO`. Harmless for these .NET
  services, worth checking for any foreign telemetry source.
- **`Logging__LogLevel__Program=Debug` is required** for the app's own `LogDebug`
  lines to exist. Without it the .NET default minimum level is `Information` and
  the microscope is dark, no matter what the collector does.
- **Loki's storage is an `emptyDir`.** Deleting the pod throws the debug logs
  away, which is the correct blast radius for this tier but does mean a pod
  restart mid-demo loses the drill-down data.
- **The env-var toggles roll the pods.** That is intentional (it is what a
  configuration change looks like in production, and it gives the dashboard a
  clean before/after edge), but it means a ~15s gap in the traffic.
- **Not yet run on the cluster.** The collector config, the split behaviour, the
  Loki config and every LogQL query in the dashboard and scripts were verified
  against a real `otelcol-contrib:0.146.1` and a real `loki:3.0.0` outside the
  cluster; the app changes were compile-checked. The ClickHouse queries have not
  been executed against data.

## Follow-up worth trying

- **Delete the narrative `Information` logs.** `logger.LogInformation("Quote ...
  Approved ...")` mostly restates span attributes. A stricter version of this
  variant would drop them and leave the system store as spans only, which is the
  logical end point of "observability works on systems".
- **Turn the microscope off by default.** Ship with `Program=Information` and
  raise it to `Debug` on one service only after the telescope has pointed at it.
  Costs a pod restart, and makes the two-step workflow physical.
- **Route the debug tier to Splunk instead of Loki**, to see whether the split is
  an easier sell when it needs no new product.

## Teardown

```bash
kubectl delete namespace 05-telescope-vs-microscope
# and, in ClickHouse:
curl -s 'http://localhost:8123/?user=otel&password=otelpass' \
  --data-binary 'DROP DATABASE IF EXISTS telescope_vs_microscope'
```
