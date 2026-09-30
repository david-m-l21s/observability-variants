#!/usr/bin/env bash
# One configuration from the OTel Tracing Configurator -> a running, probed app.
#
#   ./run.sh '<payload>'            payload from the configurator's "Copy run command"
#                                   or "Copy config link" (the whole URL or only the
#                                   part after #)
#   ./run.sh configs/NAME.json      a saved configuration
#   ./run.sh NAME                   the same, short form
#   ./run.sh ~/Downloads/x.json     any JSON file with configurator state
#
# Options:
#   --name NAME        name for a new configuration (default: <service.name>-<6 hex>)
#   --quick            skip the 200-request sampling burst in the probe
#   --no-probe         deploy only, send no traffic
#   --env ENV          ASPNETCORE_ENVIRONMENT (default Production; "Development"
#                      switches on a console exporter set to "only in Development")
#
# Steps: import (configs/NAME.json) -> render (build/NAME/) -> docker build
# (skipped when the image for exactly this rendered app exists) -> kind load
# (skipped when the node already has it) -> kubectl apply -> 06-probe.sh.
#
# Needs: docker, kind, kubectl. Node is optional: without it render.mjs runs in
# the node:22-alpine container.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIANT="$(cd "$HERE/.." && pwd)"
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="07-otel-config-tester"
PF_PORT="${PF_PORT:-18088}"

INPUT=""; NAME_ARG=""; QUICK=""; PROBE=1; ASPNET_ENV="Production"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME_ARG="${2:?--name needs a value}"; shift 2 ;;
    --quick) QUICK="--quick"; shift ;;
    --no-probe) PROBE=0; shift ;;
    --env) ASPNET_ENV="${2:?--env needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) if [ -z "$INPUT" ]; then INPUT="$1"; shift; else echo "Unexpected argument: $1" >&2; exit 1; fi ;;
  esac
done
[ -n "$INPUT" ] || { sed -n '2,24p' "$0"; exit 1; }

render() {
  if command -v node >/dev/null 2>&1; then
    (cd "$VARIANT" && node scripts/render.mjs "$@")
  else
    docker run --rm -v "$VARIANT:/v" -w /v -e VARIANT_HOST_DIR="$VARIANT" node:22-alpine node scripts/render.mjs "$@"
  fi
}

step() { printf '\n==> %s\n' "$*"; }

# --- 1. which configuration ----------------------------------------------------
NAME=""
if [ -f "$VARIANT/configs/$INPUT.json" ]; then
  NAME="$INPUT"
elif [ -f "$INPUT" ] && [ "$(cd "$(dirname "$INPUT")" && pwd)" = "$VARIANT/configs" ]; then
  NAME="$(basename "$INPUT" .json)"
else
  step "Importing configuration"
  payload="$INPUT"
  # A JSON file anywhere: send its content, so the node container can read it too.
  if [ -f "$INPUT" ]; then payload="$(base64 < "$INPUT" | tr -d '\n')"; fi
  if [ -n "$NAME_ARG" ]; then NAME="$(render import "$payload" --name "$NAME_ARG")"
  else NAME="$(render import "$payload")"; fi
  echo "configs/$NAME.json"
fi
[ -z "$NAME_ARG" ] || [ "$NAME_ARG" = "$NAME" ] || echo "note: --name is ignored for an existing configuration ($NAME)."

RUN_ID="$NAME-$(date +%Y%m%d-%H%M%S)"

# --- 2. render -----------------------------------------------------------------------
step "Rendering $NAME (run $RUN_ID)"
assignments="$(render render "configs/$NAME.json" --run-id "$RUN_ID" --aspnet-env "$ASPNET_ENV")"
eval "$assignments"   # NAME RUN_ID IMAGE DOTNET_VERSION BUILD_DIR PROBE_SOURCE FRAMEWORK
BUILD_DIR="$VARIANT/build/$NAME"
echo "image $IMAGE ($FRAMEWORK), generated files in build/$NAME/generated/"

# --- 3. build ------------------------------------------------------------------------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  step "Image $IMAGE exists (same rendered app as before), not rebuilding"
else
  step "Building $IMAGE"
  docker build --build-arg DOTNET_VERSION="$DOTNET_VERSION" -t "$IMAGE" "$BUILD_DIR/app"
fi

# --- 4. load into kind ---------------------------------------------------------------
kubectl config use-context "kind-${CLUSTER}" >/dev/null
need_load=0
for node in $(kind get nodes --name "$CLUSTER"); do
  docker exec "$node" crictl inspecti "docker.io/library/$IMAGE" >/dev/null 2>&1 || need_load=1
done
if [ "$need_load" -eq 1 ]; then
  step "Loading $IMAGE into kind ($CLUSTER)"
  kind load docker-image "$IMAGE" --name "$CLUSTER"
else
  step "kind already has $IMAGE"
fi

# --- 5. deploy -----------------------------------------------------------------------
if ! kubectl get deploy/otel-collector -n "$NS" >/dev/null 2>&1; then
  step "Collector not deployed yet, running 04-deploy.sh"
  "$HERE/04-deploy.sh"
fi
step "Deploying the probe"
kubectl apply -f "$BUILD_DIR/k8s/probe.yaml"
if ! kubectl rollout status deploy/probe -n "$NS" --timeout=180s; then
  echo
  echo "The probe did not become ready. Last log lines:" >&2
  kubectl logs -n "$NS" deploy/probe --tail=40 >&2 || true
  exit 1
fi

# --- 6. probe ------------------------------------------------------------------------
if [ "$PROBE" -eq 1 ]; then
  step "Sending probe traffic"
  kubectl port-forward -n "$NS" svc/probe "$PF_PORT:8080" >/dev/null 2>&1 &
  pf=$!
  trap 'kill "$pf" 2>/dev/null || true' EXIT
  for _ in $(seq 1 20); do curl -s -o /dev/null "http://localhost:$PF_PORT/probe/info" && break; sleep 0.5; done
  # shellcheck disable=SC2086  # QUICK is empty or one word
  EXPECT_RUN_ID="$RUN_ID" "$HERE/06-probe.sh" $QUICK "http://localhost:$PF_PORT"
fi

# --- 7. where to look ----------------------------------------------------------------
link="$(render link "configs/$NAME.json")"
cat <<EOF

Done.
  configuration  configs/$NAME.json
  run id         $RUN_ID
  checks         build/$NAME/generated/checks.txt

  Grafana (needs ./05-port-forward.sh):
    http://localhost:3003/d/otel-config-tester/otel-config-tester?var-run=$RUN_ID

  ClickHouse:
    SELECT ScopeName, SpanKind, SpanName, count() AS spans
    FROM otel_config_tester.otel_traces
    WHERE ResourceAttributes['test.run.id'] = '$RUN_ID'
    GROUP BY ScopeName, SpanKind, SpanName ORDER BY spans DESC;

  Open this configuration in the configurator:
    $link
EOF
