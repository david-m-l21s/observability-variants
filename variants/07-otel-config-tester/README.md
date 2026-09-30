# 07-otel-config-tester

Try out a tracing configuration from the **OTel Tracing Configurator** on a real app, with one command.

You make a configuration in the configurator page, copy one command, and paste it into a terminal. The script builds a small shop app (the *probe app*) with exactly the generated `Program.cs` snippet, packages and environment. It deploys the app into the kind cluster and sends a fixed set of requests. The spans go through a plain collector into ClickHouse, database `otel_config_tester`. You then look at the result yourself in the variant's Grafana or in ClickHouse.

There are no automatic checks yet. That is on purpose: the first goal is to see and understand what each option does.

## Prerequisites

These are the same as for the other variants. See `cluster/VARIANTS.md`.

- The kind cluster `obs-vm-tests` exists (`cluster/scripts/01-create-cluster.sh`).
- The `otel` user exists on the VM ClickHouse (`cluster/scripts/03-clickhouse-otel-user.sh`).
- The Lima VM (ClickHouse) is running.
- `docker`, `kind` and `kubectl` are installed. Node.js is optional: without it, `render.mjs` runs in the `node:22-alpine` container.

## First run

```bash
cd scripts
./04-deploy.sh              # namespace, collector, Grafana (once)
./05-port-forward.sh &      # Grafana :3003 and the probe's test page :8088 (keep it running)
./run.sh shop-api-full      # a saved configuration from configs/
```

After that, open the Grafana link that `run.sh` prints.

## The workflow

1. Open `configurator/otel-tracing-configurator.html` from **this folder**.
2. Change options. Then click **Copy run command**.
3. Paste the command into a terminal. It looks like this:

   ```bash
   '/Users/david/.../07-otel-config-tester/scripts/run.sh' 'eyJmdyI6Im5ldDkuMCIs…'
   ```

   The long argument is the whole configuration, base64-encoded (the same text as in "Copy config link"). The path is absolute, so the command works from any directory. If you open the page from somewhere else, the command starts with `./run.sh` and must be run from `scripts/`.
4. `run.sh` saves the configuration as `configs/<service.name>-<6 hex>.json`. The same configuration always gets the same name. Then it renders, builds, deploys and probes (see "What run.sh does").
5. Look at the run in Grafana (`?var-run=<run id>`) or in ClickHouse.

Other ways to start a run:

```bash
./run.sh backend-api                      # a saved configuration, by name
./run.sh configs/api-efcore.json          # the same, by path
./run.sh ~/Downloads/state.json           # any JSON file with configurator state
./run.sh '<payload>' --name my-test       # choose the name of a new configuration
./run.sh backend-api --quick              # skip the 200-request sampling burst
./run.sh backend-api --no-probe           # deploy only
./run.sh backend-api --env Development    # ASPNETCORE_ENVIRONMENT=Development
```

To open a saved configuration in the configurator again, use the link at the end of the `run.sh` output. You can also get it with `node scripts/render.mjs link configs/NAME.json`.

## What run.sh does

| Step | What happens | Skipped when |
|---|---|---|
| import | The payload becomes `configs/NAME.json`. Missing keys get the configurator defaults. | the argument already names a saved configuration |
| render | `render.mjs` writes `build/NAME/`: `app/` (Program.cs, .csproj, appsettings.json), `k8s/probe.yaml`, and `generated/` (the three configurator tabs and the checks, as text) | never |
| build | `docker build` of `build/NAME/app`. The image tag is a hash of the rendered app. | an image with that tag exists already |
| load | `kind load docker-image` | the kind node has the image already |
| deploy | `kubectl apply` of the probe Deployment and Service. `strategy: Recreate` stops the old pod before the new one starts. | never |
| probe | `06-probe.sh` through its own port-forward on `:18088`. It ends with `POST /probe/flush`. | `--no-probe` |

A second run of an unchanged configuration only redeploys and probes. That should take well under a minute. The first build of a new framework version pulls the .NET SDK image. The first build of a new package set runs `dotnet restore`.

**The generator code is not copied.** `render.mjs` reads the `GEN-START … GEN-END` block straight out of `configurator/otel-tracing-configurator.html` and runs it in Node. A change in the configurator is used by the next run. If the configurator is changed outside this folder, copy the new version into `configurator/`. The block must stay free of DOM (Document Object Model) and browser code.

### What the harness adds, and what it leaves alone

The harness adds only these things. Everything else comes from the configuration.

- The resource attributes **`test.run.id`** (`<name>-<yyyymmdd-hhmmss>`) and **`test.config.name`**. They are appended to the configuration's `OTEL_RESOURCE_ATTRIBUTES`, or set on their own when the configuration sets none. So `k8s.*` attributes appear only when the configuration's "k8s pod / namespace / node" option is on.
- `PROBE_*` environment variables for the app itself. They are not telemetry settings.
- `ASPNETCORE_ENVIRONMENT=Production` (change it with `--env`).

**The collector does nothing to the spans.** There is no `/health` drop and no sampling (variants 04–06 drop `/healthz` in the collector). Whether `/health` spans arrive is one of the things you test here.

### Options the probe app cannot run

`render.mjs` refuses configurations with **Redis, Npgsql, SqlClient or gRPC** switched on. The generated code for these needs a server that the probe does not have, or it would test nothing. EF Core (on SQLite), MassTransit and the Azure SDK are accepted. MassTransit and Azure SDK are only `AddSource(...)` lines, and the probe produces no spans for them.

## The probe app

`apps/OtelProbe/Program.template.cs` is a small shop with SQLite (a file in `/tmp`, deleted at every start), EF Core and HttpClient calls to itself through the Kubernetes service. The generated snippet replaces the `// @@OTEL_TRACING@@` marker, and the generated `using` lines replace `// @@OTEL_USINGS@@`. Nothing else changes between configurations.

`POST /api/orders` is the main flow. With everything switched on, one order is a trace like this one:

```
SERVER    POST /api/orders
├─ INTERNAL  Validate order                 custom source, events validation.passed / .failed
│  └─ CLIENT  SELECT customers              EF Core
├─ CLIENT    GET  (pricing SKU-004)         HttpClient, one per line, in parallel
│  └─ SERVER  GET /api/pricing/{sku}
│     ├─ CLIENT    SELECT products          EF Core
│     └─ INTERNAL  Apply discount rules     custom, event discount.evaluated
├─ CLIENT    GET  (pricing SKU-017)         …
├─ INTERNAL  Reserve stock                  custom, event stock.reserved / stock.insufficient
│  ├─ CLIENT  UPDATE products               EF Core, one per line (ExecuteUpdate)
│  └─ CLIENT  INSERT orders, order_lines    EF Core (SaveChanges)
└─ CLIENT    POST (notifications)           HttpClient
   └─ SERVER  POST /api/notifications
      └─ CLIENT  INSERT notifications       EF Core
```

The configuration decides what is left of this tree:

- Without the EF Core option, there are no `SELECT`/`UPDATE`/`INSERT` spans.
- Without an ActivitySource in the configuration, there are no custom spans. `render.mjs` sets the probe's source name (`PROBE_SOURCE`) to the **first** entry of the configuration's "ActivitySource names" list. A wildcard becomes `Probe`, so `T2A.*` becomes `T2A.Probe`. With an empty list, the name is `OtelProbe`, and nothing listens to it.
- Without ASP.NET Core instrumentation, every outgoing HttpClient call becomes its own root span.

The custom source name is also printed at the start of the probe output and stored in `build/NAME/generated/checks.txt`.

A background job, **"Stock sync"**, runs every 30 seconds. It is a custom root span with EF children and no HTTP request around it. Without the custom source, its database spans become separate root spans. The readiness probe calls `/health` every 10 seconds. Both keep producing spans after the probe script ends.

### What 06-probe.sh sends

Every request carries `x-tenant-id`, `x-correlation-id`, `Authorization` and `Cookie` headers.

| Section | Requests | Tests |
|---|---|---|
| noise | 3 × `/health /healthz /ready /alive /metrics /swagger/index.html /favicon.ico /css/site.css /js/site.js /lib/jquery.min.js /_framework/blazor.web.js /_content/app.css`, `POST /_blazor/negotiate` | path filter, file-extension filter |
| preflight | 3 × `OPTIONS /api/orders` with CORS headers | "Drop CORS preflight" |
| shop | products, `/api/v1.0/products` (a dot in the route), 20 orders, reads with JOINs; unknown customer (404), unknown SKU (400), no stock (409, rollback), quantity 0 (400) | EF Core, HttpClient, custom sources, deep traces |
| failures | `/api/fail` (exception in a custom span), `/api/fail/nested` (500 one level down), `/api/fail/unreachable` (DNS failure on the CLIENT span), `/api/fail/db` (SQL error) | RecordException, EnrichWithException |
| outgoing | 3 × `/api/diagnostics/ping`: GET `http://otel-collector:4318/` and GET self `/health` | FilterHttpRequestMessage (hosts, paths) |
| span size | 2 × `/api/wide` (200 attributes, one 20 000-character value, 40 events × 20 attributes, a child span with 40 links × 20 attributes), 2 × `/api/db/long-query` (SQL text of about 17 000 characters) | span limits, attribute value length |
| sampling | 200 × `GET /api/products/{sku}`, 8 in parallel (not with `--quick`) | sampler ratio: at 0.25, expect about 50 ± 18 of them |
| flush | `POST /probe/flush` (`TracerProvider.ForceFlush`), then 3 seconds of waiting | — |

### Changes to the configurator

The copy in `configurator/` differs from the uploaded version in three ways:

- The generators are pure functions in a `GEN-START … GEN-END` block. They take the configuration as a parameter, so Node can run them. `genEnv` (structured env list), `genAppsettings` and `genPackageList` were split out of the text generators. The generated text is unchanged.
- A **Copy run command** button was added next to "Copy config link".
- The hint for `EnableRazorComponentsSupport` said it does not compile on net9.0. In `OpenTelemetry.Instrumentation.AspNetCore` the property exists on every target framework. It only has an effect on .NET 10. The hint now says that. The option is still only offered for net10.0.

## The test page

The probe app serves a page at **<http://localhost:8088/>** (it needs `./05-port-forward.sh`). Use it to make traces by hand:

- **Shop**: pick a customer, set quantities (or click *Random order*) and place an order. You can then read the order back or list the customer's orders.
- **Scenarios**: one button each for the exception cases, out of stock, unknown SKU, outgoing calls to infrastructure, wide span, long SQL, a route with a dot, noise paths, and a 50-request sampling burst.
- **Requests from this page**: every request with its status and duration. The trace id comes from an `X-Trace-Id` response header that the template adds. It is marked *recorded* when the SERVER span will be exported, and *not recorded* when a Filter or the sampler dropped it. The trace id links to the Grafana dashboard with that trace selected. *Flush now* exports right away instead of after the batch delay.

The header comes from a small middleware in the template. It only reads `Activity.Current` and adds no spans or attributes. Loading the page is a request itself (`/`, `/favicon.ico`), so those spans appear unless the configuration filters them.

The `:8088` forward in `05-port-forward.sh` reconnects by itself when `run.sh` replaces the probe pod. Reload the page after a run: the header then shows the new run id.

## Where to look

### Grafana

Run `./05-port-forward.sh`. Then open <http://localhost:3003/d/otel-config-tester> (no login). The dashboard has these panels, from top to bottom:

- **Runs**: one row per run, with spans, traces, spans per trace, errors, and attribute size (characters in keys + values, a rough measure of row width). Click a run to select it.
- **Span shapes**: scope × kind × name, with counts, durations, errors and `as_root`. An `as_root` value above 0 for a CLIENT or database span means that its parent was not recorded.
- **Spans over time**, by scope.
- **Traces**, deepest first. Click a `trace_id`, and the **Trace** panel shows the waterfall.
- **Span attribute keys**, with the longest value per key. This panel is where the value length limit shows.
- **Events and links**: the count limits.
- **Resource attributes** of the run.

If the Trace panel stays empty, use Explore: choose the data source *ClickHouse-ConfigTester*, then the query type *Traces*, and paste the trace id. The data source is set up for the OTel table layout.

### ClickHouse

All queries filter on `ResourceAttributes['test.run.id']`. `run.sh` prints the run id.

```sql
-- all runs
SELECT ResourceAttributes['test.run.id'] AS run, any(ResourceAttributes['test.config.name']) AS config,
       min(Timestamp) AS started, count() AS spans, uniqExact(TraceId) AS traces
FROM otel_config_tester.otel_traces
GROUP BY run ORDER BY started DESC;

-- what one run produced
SELECT ScopeName, SpanKind, SpanName, count() AS spans, countIf(ParentSpanId = '') AS as_root
FROM otel_config_tester.otel_traces
WHERE ResourceAttributes['test.run.id'] = '<run id>'
GROUP BY ScopeName, SpanKind, SpanName ORDER BY ScopeName, spans DESC;

-- two runs side by side (for example, before and after one option)
SELECT SpanName,
       countIf(ResourceAttributes['test.run.id'] = '<run A>') AS a,
       countIf(ResourceAttributes['test.run.id'] = '<run B>') AS b
FROM otel_config_tester.otel_traces
WHERE ResourceAttributes['test.run.id'] IN ('<run A>', '<run B>')
GROUP BY SpanName ORDER BY greatest(a, b) DESC;

-- one order trace as a tree (the deepest trace of the run)
WITH (SELECT TraceId FROM otel_config_tester.otel_traces
      WHERE ResourceAttributes['test.run.id'] = '<run id>'
      GROUP BY TraceId ORDER BY count() DESC LIMIT 1) AS t
SELECT Timestamp, SpanId, ParentSpanId, SpanKind, SpanName, round(Duration / 1e6, 2) AS ms, StatusCode
FROM otel_config_tester.otel_traces WHERE TraceId = t ORDER BY Timestamp;

-- span limits: longest attribute values, and captured headers
SELECT key, max(length(SpanAttributes[key])) AS max_len, count() AS spans
FROM otel_config_tester.otel_traces ARRAY JOIN mapKeys(SpanAttributes) AS key
WHERE ResourceAttributes['test.run.id'] = '<run id>'
  AND (key IN ('probe.long_value', 'db.query.text', 'db.statement') OR key LIKE 'http.request.header.%')
GROUP BY key ORDER BY key;

-- sampling: how many of the 200 product reads were kept
SELECT count() AS kept_of_200
FROM otel_config_tester.otel_traces
WHERE ResourceAttributes['test.run.id'] = '<run id>'
  AND SpanKind = 'Server' AND SpanName = 'GET /api/products/{sku}';
```

## Saved configurations

| Name | What it is |
|---|---|
| `backend-api` | the configurator's defaults (preset "Backend API") |
| `api-efcore` | preset "API + EF Core" |
| `blazor-server`, `blazor-server-net10` | the Blazor presets. The probe is not a Blazor app, so the SignalR and Razor switches have nothing to switch off here. Only the path filters show an effect. |
| `worker-service` | preset "Worker service": no ASP.NET Core instrumentation |
| `shop-api-full` | "API + EF Core" plus the custom source `T2A.Shop`, header capture, noise and CORS filters, an outgoing filter, and the suggested span limits |

## Files

```
configurator/   the configurator page (source of the generators; open it from here)
configs/        one JSON file per configuration (committed)
apps/OtelProbe/ Program.template.cs, appsettings.template.json, Dockerfile, wwwroot/
k8s/            00 namespace, 20 collector (-> otel_config_tester), 40 Grafana (:3003)
scripts/        render.mjs, 04-deploy.sh, 05-port-forward.sh, 06-probe.sh, run.sh
build/          rendered output per configuration (git-ignored)
```

## Housekeeping

- Pause the variant: `../../variants.sh stop otel-config-tester`.
- Every configuration leaves an image `otel-probe:<hash>` in Docker and on the kind node. Remove old images with `docker image ls otel-probe` and `docker rmi`. On the node: `docker exec obs-vm-tests-control-plane crictl rmi --prune`.
- Remove all data: `DROP DATABASE otel_config_tester` on the VM ClickHouse.

## What is verified and what is not

Verified in the build session, outside the cluster:

- The refactored configurator generates **exactly** the same Program.cs, packages and env/appsettings text as the version it was made from. This was compared on all 5 presets plus 3 000 random configurations. The page loads without errors, and "Copy run command" produces a payload that `run.sh` accepts.
- The rendered `Program.cs` compiles for all saved configurations and 30 further random ones. This used the .NET 8 compiler against **stand-in** OpenTelemetry and EF Core APIs, because nuget.org is not reachable from the session. It catches mistakes in the template and in how the snippet is inserted. It does not prove that the real packages restore and build.
- The collector config passes `otelcol-contrib 0.146.1 validate`.
- Every dashboard query runs in ClickHouse (chdb) against a table created with the exporter's own DDL (v0.146.0).
- `run.sh` and `06-probe.sh` run end to end against fake `docker`/`kind`/`kubectl`/`curl` commands. `shellcheck` is clean. The scripts are written for bash 3.2.

Not verified: the real `docker build` (package restore, the floating `Microsoft.EntityFrameworkCore.Sqlite` `8.0.*`/`9.0.*`/`10.0.*` versions), the app at runtime, the Grafana provisioning, and the trace panel. Check these first on the first run.
