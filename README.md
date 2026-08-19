# Cluster + .NET apps phase — motor insurance quote

A local **kind** cluster running three lean .NET services that emit wide events
to the **off-cluster** ClickHouse on the Lima VM (see `../Lima-VM/`). Grafana also
runs on the VM (`http://localhost:3000`).

## The apps

A motor insurance instant-quote flow — one trace, three spans:

```
QuoteWeb  ──HTTP──▶  QuoteApi  ──HTTP──▶  RatingApi
(frontend/BFF)       (backend)            (downstream calc)
```

- **QuoteWeb** — serves a small form, proxies the submission to QuoteApi. No logic.
- **QuoteApi** — validates, calls RatingApi, applies tax + a decision rule, returns the quote.
- **RatingApi** — pure calculation: vehicle + driver + region + coverage → risk score + base premium.

Each service uses OTel auto-instrumentation (ASP.NET Core + HttpClient) and adds
business attributes (`insurance.vehicle_type`, `insurance.risk_score`,
`insurance.final_premium`, `insurance.decision`, …) to the request span, so every
request becomes a wide event. In-memory only — no DB, no messaging, no Dapr yet.

## Layout

```
cluster/
  kind-cluster.yaml          single-node kind cluster "obs-vm-tests"
  apps/
    RatingApi/  QuoteApi/  QuoteWeb/   (Program.cs + .csproj + Dockerfile each)
  k8s/
    00-namespace.yaml
    10-rating-api.yaml  11-quote-api.yaml  12-quote-web.yaml
    20-otel-collector.yaml   (exports to the VM ClickHouse)
  scripts/
    01-create-cluster.sh
    02-build-and-load-images.sh
    03-clickhouse-otel-user.sh
    04-deploy.sh
    05-port-forward.sh
```

## Prerequisites (on the Mac)

- Docker Desktop running, and the Lima VM `clickhouse` up (`limactl list`).
- `kind`  → `brew install kind`
- `kubectl` → `brew install kubectl`

(.NET is **not** needed locally — the images build inside Docker.)

## Run it

```bash
cd scripts
./01-create-cluster.sh          # kind cluster "obs-vm-tests"
./02-build-and-load-images.sh   # build 3 images, load into kind
./03-clickhouse-otel-user.sh    # create otel:otelpass on the VM ClickHouse (once)
./04-deploy.sh                  # namespace + apps + collector, waits for rollout
./05-port-forward.sh            # quote-web -> http://localhost:8080
```

Open `http://localhost:8080`, fill the form, and click **Get quote**. That drives
`QuoteWeb → QuoteApi → RatingApi` and emits telemetry through the collector to the
VM's ClickHouse.

## Verify wide events land

From the Mac (Lima forwards ClickHouse to `localhost`):

```bash
# spans arriving, newest first
curl -s 'http://localhost:8123/?user=otel&password=otelpass' --data-binary "
  SELECT Timestamp, ServiceName, SpanName,
         SpanAttributes['insurance.decision']     AS decision,
         SpanAttributes['insurance.final_premium'] AS premium
  FROM otel_traces
  ORDER BY Timestamp DESC LIMIT 15 FORMAT PrettyCompact"

# span count per service
curl -s 'http://localhost:8123/?user=otel&password=otelpass' --data-binary "
  SELECT ServiceName, count() FROM otel_traces
  GROUP BY ServiceName ORDER BY ServiceName FORMAT PrettyCompact"
```

In Grafana (`http://localhost:3000`), the ClickHouse datasource already points at
the VM's local ClickHouse — query `otel_traces` / `otel_logs`.

## Troubleshooting

- **Collector can't reach ClickHouse / `host.docker.internal` won't resolve.**
  On Docker Desktop for Mac this normally resolves from kind pods. Check:
  `kubectl logs -n 01-simple-apps deploy/otel-collector`. From the node:
  `docker exec obs-vm-tests-control-plane getent hosts host.docker.internal`. Fallback:
  add a `hostAliases` entry on the collector pod mapping `host.docker.internal` to
  your Mac's LAN IP, or point the exporter endpoint at that IP.
- **`otel` auth fails.** Re-run `03-clickhouse-otel-user.sh`; confirm the VM is up
  and Lima forwards 8123.
- **Pods `ImagePullBackOff`.** The images are local; ensure `02-build-and-load-images.sh`
  ran and that manifests use `imagePullPolicy: IfNotPresent` (they do).
- **Rebuilding an app.** Re-run `02`, then
  `kubectl rollout restart deploy/<app> -n 01-simple-apps`.

## Where this is heading (not built yet)

The flow is designed so each future piece is added for a concrete reason:

1. **Postgres** — QuoteApi persists quotes so a customer can retrieve one later
   (quote history / lifecycle).
2. **Pub/sub** — accepting a quote crosses an async boundary (issue policy:
   generate documents, notify, hand off to underwriting). QuoteApi publishes
   `quote.accepted`; a new worker consumes it.
3. **Dapr** — once there's a sync call + a state store + messaging, Dapr's
   building blocks (service invocation, state, pub/sub) replace the hand-rolled
   plumbing, and the sidecar's auto-emitted spans give a "with/without Dapr"
   comparison.

Collector/app **variants** for side-by-side experiments come after that.
