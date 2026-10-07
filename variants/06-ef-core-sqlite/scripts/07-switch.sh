#!/usr/bin/env bash
# Flip one quote-api setting and wait for the new pod.
#
#   none         DB_INSTRUMENTATION=none   - the starting point: no db spans
#   efcore       DB_INSTRUMENTATION=efcore - the fix (default)
#   old-semconv  unset OTEL_SEMCONV_STABILITY_OPT_IN - EF's default: db.statement,
#                span name = database name ("main")
#   new-semconv  OTEL_SEMCONV_STABILITY_OPT_IN=database (default here)
#   ef-logs      EF per-command logs ON  (Information) - see them duplicate the spans
#   ef-logs-off  EF per-command logs at Warning (default here)
#   params       parameter VALUES on the db spans (db.query.parameter.<name>).
#                Test data only - on real data this stores personal data.
#                Needs new-semconv (the default here); ignored under old-semconv.
#   params-off   parameter values off again (default)
#
# Every switch RESTARTS the pod, and the SQLite database lives in the pod's
# memory: all stored quotes are gone afterwards. Run ./06-generate-load.sh again
# after each switch. The telemetry already in ClickHouse is not affected, and
# the resource attribute app.db_instrumentation keeps the runs apart.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
NS="06-ef-core-sqlite"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

EF_LOG_KEY='Logging__LogLevel__Microsoft.EntityFrameworkCore.Database.Command'
PARAM_KEY='OTEL_DOTNET_EXPERIMENTAL_EFCORE_ENABLE_TRACE_DB_QUERY_PARAMETERS'

case "${1:-}" in
  none)        kubectl set env deploy/quote-api -n "$NS" DB_INSTRUMENTATION=none ;;
  efcore)      kubectl set env deploy/quote-api -n "$NS" DB_INSTRUMENTATION=efcore ;;
  old-semconv) kubectl set env deploy/quote-api -n "$NS" OTEL_SEMCONV_STABILITY_OPT_IN- ;;
  new-semconv) kubectl set env deploy/quote-api -n "$NS" OTEL_SEMCONV_STABILITY_OPT_IN=database ;;
  ef-logs)     kubectl set env deploy/quote-api -n "$NS" "${EF_LOG_KEY}=Information" ;;
  ef-logs-off) kubectl set env deploy/quote-api -n "$NS" "${EF_LOG_KEY}=Warning" ;;
  params)      kubectl set env deploy/quote-api -n "$NS" "${PARAM_KEY}=true" ;;
  params-off)  kubectl set env deploy/quote-api -n "$NS" "${PARAM_KEY}-" ;;
  *)
    echo "Usage: $0 {none|efcore|old-semconv|new-semconv|ef-logs|ef-logs-off|params|params-off}" >&2
    exit 1 ;;
esac

kubectl rollout status deploy/quote-api -n "$NS" --timeout=120s
echo
echo "quote-api env now:"
kubectl get deploy/quote-api -n "$NS" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E '^(DB_INSTRUMENTATION|OTEL_SEMCONV_STABILITY_OPT_IN|OTEL_DOTNET_EXPERIMENTAL_|Logging__)' || true
echo
echo "The in-memory database is empty again. Next: ./06-generate-load.sh"
echo "(If ./05-port-forward.sh was running, restart it: the quote-api forward"
echo " pointed at the old pod and is now dead.)"
