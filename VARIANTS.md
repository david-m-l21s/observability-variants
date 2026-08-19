# Variant registry

Each variant is a **Kubernetes namespace** in the `obs-vm-tests` cluster. All
variants send to the same off-cluster ClickHouse on the Lima VM and are told
apart by the `k8s.namespace.name` resource attribute. Update this file whenever a
variant is added, changed, or archived.

## Naming

```
<NN>-<short-description>
```

- **`<NN>`** — two-digit sequence in the order variants are added (`01`, `02`, …).
- **`<short-description>`** — a few kebab-case words for what's special about the
  variant (`simple-apps`, `runtime-injection`, …).
- Namespaces are DNS-1123 labels: lowercase, digits, `-`, ≤63 chars.
- A single experiment may need **more than one namespace** (e.g. an A/B). Keep the
  same `<NN>` and vary the description: `03-head-sampling`, `03-tail-sampling`.

## Per-variant ClickHouse tables

A variant can write to its own tables **entirely from its collector config** — no
VM or ClickHouse changes. The ClickHouse exporter runs `CREATE TABLE IF NOT EXISTS`
on startup (`create_schema: true`, default) as the `otel` user, using the table
names you set:

```yaml
exporters:
  clickhouse:
    endpoint: tcp://otel:otelpass@host.docker.internal:9000?dial_timeout=10s&compress=lz4
    database: default
    create_schema: true
    traces_table_name: <prefix>_otel_traces
    logs_table_name:   <prefix>_otel_logs
    metrics_tables:                         # note: nested block, not metrics_table_name
      gauge:                 { name: <prefix>_otel_metrics_gauge }
      sum:                   { name: <prefix>_otel_metrics_sum }
      summary:               { name: <prefix>_otel_metrics_summary }
      histogram:             { name: <prefix>_otel_metrics_histogram }
      exponential_histogram: { name: <prefix>_otel_metrics_exp_histogram }
```

**Chosen approach: one database per variant.** Set `database: <name>` (standard
`otel_*` table names) rather than prefixing tables. `<name>` = the namespace's
descriptive part, hyphens→underscores, numeric prefix dropped (ClickHouse
identifiers can't start with a digit or contain `-`). So `02-runtime-injection` →
`database: runtime_injection`. The baseline stays in the default `default` database.
Teardown is a clean `DROP DATABASE runtime_injection`. In Grafana, point the query
at the variant's database.

## Controlling variants

Don't leave every variant running at once — use `./variants.sh` (operates on any
variant namespace; stop = scale to 0, which frees CPU/RAM but keeps config + data):

```bash
./variants.sh status                 # what's running, per variant
./variants.sh stop   runtime-injection   # or the full ns, or 'all'
./variants.sh resume runtime-injection
```

To remove a variant entirely (not just pause it): `kubectl delete namespace <ns>`.

## On-disk layout

```
cluster/
  k8s/                       # baseline (01-simple-apps): namespace, apps, collector
  variants/
    <NN-name>/               # ONLY the manifests that differ from the baseline
                             # (may hold sub-folders if the variant is an A/B —
                             #  e.g. 03-sampling/head/ and 03-sampling/tail/)
  VARIANTS.md                # this file
```

Deploy a variant with `kubectl apply -f variants/<NN-name>/` (reuses the shared
app images). Add a row below before you deploy.

## Variants

| Namespace                | What's special                                                                 | Status   |
|--------------------------|--------------------------------------------------------------------------------|----------|
| `01-simple-apps`         | Baseline. In-code OTel SDK + `Activity` enrichment; lean collector (`otlp → batch → clickhouse`). | baseline |
| `02-runtime-injection`   | OTel Operator injects instrumentation at runtime — no OTel NuGet libs in the apps; `Activity` business enrichment kept via BCL. Collector as baseline but exports to its own ClickHouse database `runtime_injection` (standard `otel_*` tables). Endpoint is HTTP **4318** (.NET auto-instr default), not gRPC 4317. Tests whether zero-code injection still yields wide events, and its overhead. | built, not yet run |
| `03-head-sampling`       | **Sampling A/B (head).** Baseline images reused as-is; sampling done in the app SDK via `OTEL_TRACES_SAMPLER=parentbased_traceidratio` + `ARG=0.1` (env only, no code). Root (`quote-web`) decides; whole-trace keep at ~10%, blind to outcome. Collector = plain baseline pipeline → database `head_sampling`. | built, not yet run |
| `03-tail-sampling`       | **Sampling A/B (tail).** Baseline images reused as-is, exporting ALL spans. Collector `tail_sampling` processor keeps errors + slow (>250 ms) + `insurance.decision` in {Rejected,Referred} at 100%, routine at ~10%. `replicas: 1` (whole trace must hit one collector) → database `tail_sampling`. Shows sampling that preserves the interesting wide events. | built, not yet run |
| `04-spanmetrics-alerting`| **Alerting, end to end.** Baseline images reused as-is. Collector adds the `spanmetrics` connector (`calls`/`duration`, DELTA temporality, `insurance.decision` dimension) → database `spanmetrics_alerting`. Ships its own in-cluster Grafana (provisioned datasource + contact point + 4 alert rules: error-rate, rejection-rate, p95 latency on raw spans, no-traffic dead-man) and a self-contained webhook stub that shows fired alerts. Shows how to alert on wide events, who owns which alert, and how to make it easy. | built, not yet run |

## Ideas / backlog

- **eBPF** — Beyla, zero code and zero agent. How much wide-event context survives?
- **collector memory_limiter** — baseline + `memory_limiter` + tuned queue; graceful degradation when the VM ClickHouse slows.

## Findings log

Append notes per variant as results come in (keeps the table narrow).

### `01-simple-apps` (baseline)
- _pending first run._

### `02-runtime-injection`
- Built as a standalone clone under `variants/02-runtime-injection/` (SDK-free `-ri` images, OTel Operator injection, own `runtime_injection` DB). Not yet run. Watch: arm64 injection (experimental) — amd64 fallback documented.

### `03-head-sampling` / `03-tail-sampling`
- Built under `variants/03-sampling/` as a head-vs-tail A/B. Both **reuse the baseline `*:v1` images unchanged** — no new image build; sampling is pure config. Head = SDK env vars (10%, blind); tail = collector `tail_sampling` processor (keep errors/slow/non-approved 100%, routine ~10%). Own DBs `head_sampling` / `tail_sampling`. Not yet run.
- Frontends: head `:8082`, tail `:8083` (baseline `:8080`, `02` `:8081`).
- Demo note: `Referred` (risk ≥ 80) is currently unreachable in RatingApi (formula tops out ≈ 59); `Rejected` (age < 18) is the reliable "interesting" case. Send the SAME batch load to both namespaces for a fair comparison.

### `04-spanmetrics-alerting`
- Built under `variants/04-spanmetrics-alerting/`. Reuses baseline `*:v1` images unchanged. Collector adds the `spanmetrics` connector (DELTA temporality, `insurance.decision` dimension) → DB `spanmetrics_alerting`. Own **in-cluster** Grafana (provisioned, reaches ClickHouse via `host.docker.internal`, so the VM Grafana is untouched) + a stdlib-Python webhook stub. Four alert rules: error-rate + rejection-rate (spanmetrics), p95 latency (raw spans, the deliberate hybrid), no-traffic dead-man. Not yet run.
- Frontends: quote-web `:8084`, grafana `:3001`, webhook stub `:8090`.
- Test triggers: `07-trigger-incidents.sh {cascade|rejections|silence|restore}`. Watch alerts appear on the stub page. Expect 1–3 min (eval interval + `for`).
- Watch on first run: Grafana provisioned alert-rule `model` fields (`queryType`/`format`) are version-sensitive — SQL + thresholds are correct, but a rule may need a small model tweak or UI re-entry. Metric name may be `calls` vs `calls_total` across collector versions.
