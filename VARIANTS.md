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
| `05-telescope-vs-microscope`| **Two log tiers, one TraceId bridge.** `quote-api`/`rating-api` rebuilt as `*-tm:v1` (only change: an explicit `telemetry.tier=debug` ILogger scope around developer detail, plus a config-toggled eligibility regression); `quote-web` reuses the baseline image. Collector splits ONE logs pipeline into TWO strict complements: system tier (INFO+ without a debug marker) → ClickHouse DB `telescope_vs_microscope`, debug tier (marked, or below INFO) → in-cluster Loki with 24h retention. Nothing duplicated — errors deliberately NOT copied to both, since the span already carries the failure. Ships its own Loki + Grafana (both datasources and the dashboard provisioned). Shows the telescope-then-microscope workflow and what it costs to keep debug logs out of the wide-event store. | built, not yet run |
| `06-ef-core-sqlite`      | **Database spans via EF Core.** `quote-api` rebuilt as `quote-api-ef:v1`: persists every quote through EF Core into **SQLite in-memory** (in-process, no DB pod) and adds `GET /quotes/{id}` + `GET /customers/{id}/quotes`. Provider-agnostic `OpenTelemetry.Instrumentation.EntityFrameworkCore` (prerelease), switchable in the same image via `DB_INSTRUMENTATION=efcore\|none`; mode is the resource attribute `app.db_instrumentation`. OTel packages bumped 1.9 → 1.19.x (required by the EF package). `OTEL_SEMCONV_STABILITY_OPT_IN=database`, parameter values off, EF per-command logs at Warning. `rating-api`/`quote-web` baseline images; baseline collector + healthz drop → DB `ef_core_sqlite`. Stepping stone before SQL Server / PostgreSQL. | built, not yet run |
| `07-otel-config-tester`  | **Try a configurator configuration on a real app.** One command (`scripts/run.sh`, pasted from the configurator's "Copy run command") renders the OTel Tracing Configurator's generated Program.cs snippet + packages + env into a dedicated probe app (`OtelProbe`: small shop, SQLite file + EF Core, HttpClient calls to itself, custom ActivitySource, background job), builds `otel-probe:<hash>` (skipped if unchanged), loads it into kind, deploys it and sends a fixed request set. Generators are read from the configurator HTML (`GEN-START…GEN-END`), not copied. Runs told apart by resource attribute `test.run.id`. Collector does nothing to spans (no health drop) → DB `otel_config_tester`. Own Grafana `:3003` with a runs/traces dashboard. No automatic assertions yet (inspect by hand). | built, not yet run |

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

### `05-telescope-vs-microscope`
- Built under `variants/05-telescope-vs-microscope/`. Only `quote-api` and `rating-api` are rebuilt (`quote-api-tm:v1`, `rating-api-tm:v1`); `quote-web:v1` is the baseline image, unchanged. Own DB `telescope_vs_microscope` + its own in-cluster Loki and Grafana. Not yet run on the cluster.
- **The rule:** log records split strictly, never duplicated. System tier = spans + INFO/WARN/ERROR without a debug marker → ClickHouse. Debug tier = anything marked `telemetry.tier=debug` OR below INFO severity → Loki, 24h. Errors are deliberately not duplicated: the span already carries `StatusCode`/`StatusMessage`.
- **Two axes on purpose.** The marker attribute answers "who is this for"; severity answers "how bad is this". The marker is primary (so a developer detail can hang off an `Error`, and a `Debug`-level business fact would not silently vanish); severity is the fallback that catches unmarked framework noise. Needs `IncludeScopes = true` on the OTel logging provider, or the scope never becomes an OTLP attribute.
- **The defect:** `QUOTE_ELIGIBILITY_RULESET=v2` drops `suburban` from the licensed regions in `quote-api`. Still HTTP 200, no exception, no latency or resource change — invisible to a status-code dashboard. Verified logic: with ages 20–70 the overall rejected share goes 0% → ~33%, and per region `suburban` goes 0% → 100% while `urban`/`rural` stay at 0%.
- Ports: quote-web `:8085`, grafana `:3002`, loki `:3101` (baseline `:8080`, 02 `:8081`, 03 `:8082`/`:8083`, 04 `:8094` + grafana `:3001` + webhook `:8090`).
- Scripts: `07-trigger-defect.sh {break|restore|flood|calm}` and `08-measure-split.sh`. `flood` turns on framework debug logging everywhere; re-running `08-measure-split.sh` should show Loki climbing steeply while the ClickHouse log count barely moves. That is the cost argument as a measurement.
- **Verified outside the cluster, not in it.** The collector config passes `otelcol-contrib:0.146.1 validate`, and an end-to-end run through that binary into a real `loki:3.0.0` confirmed the routing over 8 severity/marker combinations: marker wins over severity (a marked `Error` went to Loki only), unmarked `Debug` went to Loki, unmarked INFO/WARN/ERROR went to ClickHouse, no record was duplicated or lost. The Loki retention config starts clean. The C# changes compile. ClickHouse queries have not been run against data.
- **Trap found during the build, worth remembering:** in Loki's OTLP ingestion only `k8s_namespace_name`, `k8s_deployment_name` and `service_name` are index labels. `severity_text`, `telemetry_tier` and `trace_id` are structured metadata and only work as pipeline filters after a `|`. Using one inside the `{...}` selector returns zero rows silently — i.e. it would report a perfect split that isn't real.
- Watch on first run: `LogAttributes['telemetry.tier']` is the column the ClickHouse leak-check query uses; confirm the exporter's `otel_logs` schema still names it that. Also confirm the provisioned dashboard loads — provisioned panel `model` fields are version-sensitive across Grafana releases, same caveat as variant 04.

### `06-ef-core-sqlite`
- Built under `variants/06-ef-core-sqlite/`. Only `quote-api` is rebuilt (`quote-api-ef:v1`); `rating-api:v1` and `quote-web:v1` reused unchanged. Own DB `ef_core_sqlite`. No Grafana of its own: `scripts/08-inspect.sh` queries ClickHouse directly. Not yet run.
- **Why SQLite, not EF's InMemory provider:** InMemory is not relational, never executes a `DbCommand`, so the EF instrumentation emits zero spans. SQLite `Mode=Memory;Cache=Shared` + one kept-open connection = relational, in-process, no server. Data dies with the pod; `replicas: 1` for that reason.
- **Found while building (from the instrumentation source, not yet observed):** the EF package emits the OLD db conventions by default (`db.system`/`db.name`/`db.statement`, span name = database name, i.e. `main` for every SQLite span). `OTEL_SEMCONV_STABILITY_OPT_IN=database` gives `db.system.name`/`db.namespace`/`db.query.text` (sanitized)/`db.query.summary` and span names like `INSERT quotes`. No `db.operation.name` for text commands. The fuller attribute list we had in mind was SqlClient's.
- **Two duplication traps switched off:** query parameter values (`OTEL_DOTNET_EXPERIMENTAL_EFCORE_ENABLE_TRACE_DB_QUERY_PARAMETERS`, unset — personal data), and EF's own per-command `Information` log (`Microsoft.EntityFrameworkCore.Database.Command` → Warning), which would store every command twice, the log copy unsanitized.
- Ports: quote-web `:8086`, quote-api `:8087` (read endpoints; the baseline quote-web does not proxy them).
- Scripts: `06-generate-load.sh` (writes, both reads, one 404 miss), `07-switch.sh {none|efcore|old-semconv|new-semconv|ef-logs|ef-logs-off}` (each restarts the pod → in-memory DB empty, port-forward must be restarted), `08-inspect.sh [minutes]` (6 sections: scopes per mode, db span shapes + root spans from `EnsureCreated`, attribute keys + parameter leak check, sample query text + width, request vs db time, log categories).
- **Verified outside the cluster:** collector config passes `otelcol-contrib 0.146.1 validate`; `08-inspect.sh` SQL runs against a hand-built table with the exporter's column names (chdb); shellcheck clean. **Not verified:** the .NET build (nuget.org unreachable from the session) — package versions taken from nuget.org 2026-09-28.

### `07-otel-config-tester`
- Built under `variants/07-otel-config-tester/`. Workflow: configurator → **Copy run command** → paste → `run.sh` imports `configs/NAME.json` (name `<service.name>-<6 hex>`, deterministic), renders `build/NAME/`, builds only when the rendered app's hash is new, loads into kind only when the node lacks it, applies the probe Deployment (`Recreate`), runs `06-probe.sh` through its own port-forward `:18088`, ends with `POST /probe/flush` (ForceFlush). Saved configs: the 5 presets + `shop-api-full`.
- **One generator, two users:** the configurator's code generators were refactored into a pure `GEN-START…GEN-END` block (state as parameter); `scripts/render.mjs` runs that block in Node. Output checked identical to the original page on 5 presets + 3 000 random configurations.
- **The harness adds only** `test.run.id` / `test.config.name` (appended to the configuration's `OTEL_RESOURCE_ATTRIBUTES`) and `PROBE_*` app env. `k8s.namespace.name` appears only when the configuration asks for it.
- **Probe app:** `POST /api/orders` gives a 12–20 span trace (custom "Validate order" / "Reserve stock", parallel HttpClient pricing calls → SERVER → EF SELECT, EF UPDATE/INSERT in a transaction, a notification call one level further). Single-purpose endpoints for filters (noise paths, `/api/v1.0/…`, CORS preflight), exceptions (handler, nested, DNS, db), outgoing filters, span limits (`/api/wide`, `/api/db/long-query`), sampling (200 reads). Custom source name = first entry of the configuration's source list (`PROBE_SOURCE`), so custom spans appear exactly when configured. Redis/Npgsql/SqlClient/gRPC configurations are refused.
- **SQLite as a file (WAL), not in-memory as in 06:** parallel pricing calls + background writes would hit "database table is locked" in shared-cache memory mode, which does not wait.
- Found while building: `EnableRazorComponentsSupport` exists on all target frameworks in `OpenTelemetry.Instrumentation.AspNetCore` (only effective on .NET 10); the configurator hint claiming a net9.0 compile error was corrected. Also a real configurator bug (in the original page too): with only `service.name` set and no resource attributes, it emitted `.AddService(serviceName: "x")))` — one `)` too many, compile error. Fixed in the variant copy.
- **Test page** at `http://localhost:8088/` (served by the probe, `wwwroot/index.html`): shop with cart + order buttons, one button per scenario, and a request list with each trace id (from an `X-Trace-Id`/`X-Trace-Recorded` response header added by a read-only middleware) linking into the Grafana dashboard. `05-port-forward.sh` reconnects both forwards when pods are replaced.
- Ports: Grafana `:3003`, probe `:8088` (manual), `:18088` (run.sh internal).
- **Verified outside the cluster:** collector config passes `otelcol-contrib 0.146.1 validate`; dashboard SQL runs in chdb against the exporter's v0.146.0 DDL; rendered Program.cs compiles (net8 compiler, stand-in OTel/EF APIs) for all saved + 30 random configurations; run.sh/06-probe.sh end to end against fake docker/kind/kubectl/curl; shellcheck clean. **Not verified:** real package restore/build (nuget.org unreachable from the session; EF Sqlite uses floating `8.0.*`/`9.0.*`/`10.0.*`), runtime behaviour, Grafana provisioning and the trace panel.
