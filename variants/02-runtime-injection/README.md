# 02-runtime-injection

A standalone clone of the v1 apps (`01-simple-apps`) with **no in-code OpenTelemetry
SDK**. Instead, the **OpenTelemetry Operator** injects the .NET auto-instrumentation
agent at runtime. The point: test whether zero-code injection can replace the
hand-wired SDK and still produce the same wide events — and at what cost.

What differs from v1:

- **Apps** carry no OTel NuGet packages and no `AddOpenTelemetry()` wiring. They keep
  the `Activity.Current?.SetTag("insurance.*", …)` business enrichment — that's the
  BCL `System.Diagnostics` API, not OTel — so the agent's ASP.NET Core server span
  still becomes a wide event.
- **Images** are separately named (`rating-api-ri`, `quote-api-ri`, `quote-web-ri`)
  so they coexist with v1's images in the same kind cluster.
- **Namespace** `02-runtime-injection`; pods carry
  `instrumentation.opentelemetry.io/inject-dotnet: "runtime-injection"`.
- **Instrumentation CR** points the agent at the collector's **HTTP 4318** port
  (.NET auto-instrumentation defaults to OTLP http/protobuf).
- **Collector** exports to its own ClickHouse database **`runtime_injection`**
  (created automatically via `create_schema`), so this variant's data is isolated
  from v1's `default` database.

## Prerequisites (shared with v1, run once)

From the main `cluster/scripts/`:

1. `./01-create-cluster.sh` — the kind cluster `obs-vm-tests`.
2. `./03-clickhouse-otel-user.sh` — the `otel` user on the VM ClickHouse.

The Lima VM (ClickHouse + Grafana) must be running.

## Run this variant

From this folder's `scripts/`:

```bash
cd scripts
./00-install-operator.sh        # cert-manager + OTel Operator (cluster-wide, once)
./02-build-and-load-images.sh   # build the 3 SDK-free -ri images, load into kind
./04-deploy.sh                  # namespace + Instrumentation CR + collector + apps
./05-port-forward.sh            # quote-web -> http://localhost:8081
```

Open `http://localhost:8081`, click **Get quote**, and the trace flows
`quote-web → quote-api → rating-api` — all instrumented purely by the injected agent.

## Confirm injection actually happened

```bash
# An init container named opentelemetry-auto-instrumentation should be present:
kubectl get pod -n 02-runtime-injection -l app=quote-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name}'; echo

# The Instrumentation CR:
kubectl describe otelinst -n 02-runtime-injection

# Operator logs, if something's off:
kubectl logs -l app.kubernetes.io/name=opentelemetry-operator \
  --container manager -n opentelemetry-operator-system
```

## Verify wide events land (in the variant's own database)

```bash
# spans, newest first — note the runtime_injection database
curl -s 'http://localhost:8123/?user=otel&password=otelpass' --data-binary "
  SELECT Timestamp, ServiceName, SpanName,
         SpanAttributes['insurance.decision']      AS decision,
         SpanAttributes['insurance.final_premium'] AS premium
  FROM runtime_injection.otel_traces
  ORDER BY Timestamp DESC LIMIT 15 FORMAT PrettyCompact"

# span count per service
curl -s 'http://localhost:8123/?user=otel&password=otelpass' --data-binary "
  SELECT ServiceName, count() FROM runtime_injection.otel_traces
  GROUP BY ServiceName ORDER BY ServiceName FORMAT PrettyCompact"
```

Compare against v1 by running the same queries on `default.otel_traces`. In Grafana,
point the query at the `runtime_injection` database.

## Apple Silicon (arm64) caveat

kind runs arm64 nodes on M-series Macs, and .NET ARM64 auto-instrumentation is
**experimental** (the operator's documented RID options are `linux-x64` /
`linux-musl-x64`). If injection misbehaves — pods don't get the init container, or
the agent errors in the app logs — fall back to amd64 (emulated):

```bash
# Recreate the cluster and rebuild everything as amd64:
export DOCKER_DEFAULT_PLATFORM=linux/amd64
# (from cluster/scripts) ./01-create-cluster.sh   # if recreating
PLATFORM=linux/amd64 ./02-build-and-load-images.sh
./04-deploy.sh
```

Emulated amd64 is slower but uses the fully-supported `linux-x64` agent.

## Teardown

```bash
kubectl delete namespace 02-runtime-injection      # removes the variant
# and, in ClickHouse, drop its data:
curl -s 'http://localhost:8123/?user=otel&password=otelpass' \
  --data-binary "DROP DATABASE IF EXISTS runtime_injection"
```

The cluster-wide operator + cert-manager stay installed for other variants.
