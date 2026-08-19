# 03-sampling — head vs tail, side by side

The same three services as every other variant — `QuoteWeb → QuoteApi → RatingApi`,
byte-for-byte the baseline images — but now we **sample** the traces instead of
keeping all of them. This variant exists to make one tension concrete:

> Wide events are only useful if the interesting event is actually in the store.
> Sampling reduces volume, but *what* you drop decides whether observability
> survives the cut.

To show that, `03` deploys **two** namespaces you can compare against each other
and against the baseline:

| Sub-variant | Namespace | Where the decision is made | ClickHouse DB |
|-------------|-----------|----------------------------|---------------|
| **head** | `03-head-sampling` | in the **app SDK**, at trace start, blind to outcome | `head_sampling` |
| **tail** | `03-tail-sampling` | in the **collector**, after the whole trace is seen | `tail_sampling` |

Baseline `01-simple-apps` (in `default`, unsampled) is the reference for "what
100% looks like".

## The business use case

QuoteWeb serves a lot of routine motor-quote traffic. Most requests are healthy
`Approved` quotes that all look the same — keeping every one of them is expensive
and low-value. What the team actually needs to see is the **exceptions**: quotes
that errored, quotes that were slow, and quotes the business rules flagged
(`Rejected`, `Referred`). So the target policy is: **keep 100% of the interesting
traces, keep ~10% of the routine ones.**

That policy is exactly what tail sampling can express and head sampling cannot —
which is the whole point of running them side by side.

### head sampling (`03-head-sampling`)

No code change. The apps reuse the baseline images; we just set two environment
variables (supported by the OpenTelemetry .NET SDK since 1.8.0; the apps pin
1.9.0):

```
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1
```

`QuoteWeb` is the root of the trace, so **its** sampler makes the real 10%
keep/drop decision. `parentbased_*` means `QuoteApi` and `RatingApi` honour that
decision, so a trace is kept or dropped **as a whole** — you never get half a
trace. The collector pipeline is the plain baseline pipeline; it only ever
receives the 10% the apps chose to send.

The catch: the decision happens **before** the request runs, so head sampling is
blind. An error or a `Rejected` quote is dropped at the same 90% rate as a boring
`Approved` one. Cheapest option (dropped traces cost nothing downstream), worst
fidelity for the events you care about.

### tail sampling (`03-tail-sampling`)

The apps export **every** span (no sampler env — default is keep-all). The
`tail_sampling` processor in the collector buffers each trace, waits for all
three spans, then applies the policy. A trace is kept if it matches **any** of:

- **keep-errors** — any span with status `ERROR` → 100%
- **keep-slow** — trace latency over `250 ms` → 100%
- **keep-non-approved** — `insurance.decision` is `Rejected` or `Referred` → 100%
- **sample-routine** — everything else → ~10% (probabilistic)

So the interesting wide events survive in full and the routine `Approved` traffic
is thinned to ~10%. The cost: the apps and the network still carry 100% of the
spans, and the collector has to hold whole traces in memory — you pay for the
data you ultimately throw away. It also needs a **single collector replica** (all
spans of a trace must reach the same instance); `replicas: 1` is set.

## Prerequisites (shared, run once)

The baseline app **images** are reused as-is, so they must already be built and
loaded into the cluster. From `cluster/scripts/`:

1. `./01-create-cluster.sh` — the kind cluster `obs-vm-tests`.
2. `./02-build-and-load-images.sh` — builds `rating-api:v1`, `quote-api:v1`,
   `quote-web:v1` (this variant adds **no** new images).
3. `./03-clickhouse-otel-user.sh` — the `otel` user on the VM ClickHouse.

The Lima VM (ClickHouse + Grafana) must be running.

## Run it

The two sub-variants are independent — run one, both, in any order.

```bash
# head sampling -> http://localhost:8082
cd head/scripts
./04-deploy.sh
./05-port-forward.sh

# tail sampling -> http://localhost:8083   (separate terminal)
cd tail/scripts
./04-deploy.sh
./05-port-forward.sh
```

### Generate enough traffic to see the effect

With only a handful of manual clicks, "keep 10%" is invisible (you might keep 0
of 5). Fire a batch so the ratios show up. Against either frontend:

```bash
# 50 routine Approved quotes (age 30 -> Approved)
for i in $(seq 1 50); do
  curl -s -X POST http://localhost:8082/api/quote \
    -H 'Content-Type: application/json' \
    -d '{"customerId":"LOAD","vehicleType":"small","driverAge":30,"region":"rural","coverageLevel":"basic"}' >/dev/null
done

# a few Rejected quotes (age < 18 -> Rejected, the "interesting" decision)
for i in $(seq 1 5); do
  curl -s -X POST http://localhost:8082/api/quote \
    -H 'Content-Type: application/json' \
    -d '{"customerId":"MINOR","vehicleType":"small","driverAge":16,"region":"urban","coverageLevel":"basic"}' >/dev/null
done
```

Point the same loop at `http://localhost:8083` for the tail namespace. Sending
the **same** load to both is what makes the comparison fair.

Note on triggering the keep policies:
- **Rejected** is easy: any `driverAge < 18`. This is the reliable "interesting"
  case to demo.
- **Referred** needs `insurance.risk_score >= 80`, which the current RatingApi
  formula tops out below (max ≈ 59) — so it won't fire until the rating logic
  changes. It's in the policy for when it does. (We're not touching the apps.)
- **Errors** / **slow** are kept when they occur (e.g. scale RatingApi to 0 and
  submit → QuoteApi span goes `ERROR`). They won't appear in a clean run.

## Compare the results

Run the same query against each database and compare the counts. The headline is
**how many routine vs interesting traces each approach kept.**

```bash
CH='http://localhost:8123/?user=otel&password=otelpass'

# Root spans kept per database (one root span = one kept trace).
for db in default head_sampling tail_sampling; do
  echo "== $db =="
  curl -s "$CH" --data-binary "
    SELECT count() AS kept_traces
    FROM ${db}.otel_traces
    WHERE ServiceName = 'quote-web' AND ParentSpanId = ''"
done

# For tail: routine (Approved) vs interesting (everything else) that survived.
curl -s "$CH" --data-binary "
  SELECT SpanAttributes['insurance.decision'] AS decision, count() AS kept
  FROM tail_sampling.otel_traces
  WHERE ServiceName = 'quote-api'
  GROUP BY decision ORDER BY kept DESC FORMAT PrettyCompact"
```

What you should see, given identical load:

- **`default`** — every trace (the 100% reference).
- **`head_sampling`** — ~10% of *all* traces, including only ~10% of the
  `Rejected` ones. The interesting events are thinned just as hard as the routine.
- **`tail_sampling`** — ~10% of `Approved` traces but **all** the `Rejected`
  (and any errors/slow). Far fewer rows than `default`, yet the exceptions are
  fully preserved.

That contrast — head throws away exceptions, tail keeps them — is the takeaway.

In Grafana (`http://localhost:3000`) point the ClickHouse query at the
`head_sampling` or `tail_sampling` database to see the same thing on a dashboard.

## Teardown

```bash
kubectl delete namespace 03-head-sampling 03-tail-sampling

CH='http://localhost:8123/?user=otel&password=otelpass'
curl -s "$CH" --data-binary "DROP DATABASE IF EXISTS head_sampling"
curl -s "$CH" --data-binary "DROP DATABASE IF EXISTS tail_sampling"
```

The baseline (`01-simple-apps` / `default`) and its images are untouched.
