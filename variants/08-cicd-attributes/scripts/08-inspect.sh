#!/usr/bin/env bash
# Did the pipeline's facts reach the wide events?
#
# Section 0 asks the running pods (kubectl), sections 1-5 ask ClickHouse
# (database cicd_attributes, via the Lima forward on :8123).
#
# Usage: ./08-inspect.sh [minutes]   (default 30 - only data from that window)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"
MIN="${1:-30}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

echo "== 0. What each process actually sees (PID 1's environment, i.e. AFTER the entrypoint merge)."
echo "   'kubectl exec ... env' would show the manifest value only, because exec skips the entrypoint."
for pod in $(kubectl get pods -n "$NS" -l 'app in (rating-api,quote-api,quote-web)' -o name); do
  echo "-- $pod"
  kubectl exec -n "$NS" "$pod" -- sh -c "tr '\\0' '\\n' < /proc/1/environ | grep '^OTEL_RESOURCE_ATTRIBUTES='" \
    | sed 's/^OTEL_RESOURCE_ATTRIBUTES=//' | tr ',' '\n' | sed 's/^/     /' || echo "     (could not read)"
done

q() { # title, sql
  echo
  echo "== $1"
  curl -sS "$CH" --data-binary "$2 FORMAT PrettyCompactMonoBlock"
}
WIN="Timestamp > now() - INTERVAL $MIN MINUTE"

q "1. Spans per service, pod and build (last $MIN min).
   Expect: every row has version, revision, run id and env. A row with an EMPTY
   version is the naive pod (07-trap.sh on): build attributes overwritten." "
SELECT ServiceName                                       AS service,
       ResourceAttributes['k8s.pod.name']                AS pod,
       ResourceAttributes['service.version']             AS version,
       substring(ResourceAttributes['vcs.ref.head.revision'], 1, 7) AS rev,
       ResourceAttributes['cicd.pipeline.run.id']        AS run_id,
       ResourceAttributes['deployment.environment.name'] AS env,
       count()                                           AS spans,
       formatDateTime(min(Timestamp), '%H:%i:%S')        AS first,
       formatDateTime(max(Timestamp), '%H:%i:%S')        AS last
FROM otel_traces WHERE $WIN
GROUP BY service, pod, version, rev, run_id, env
ORDER BY service, first"

q "2. Completeness check per signal: how many rows LACK each build attribute.
   Expect 0 everywhere while the trap is off. With the trap on, only
   rating-api rows lack them (about half of them)." "
SELECT * FROM (
SELECT 'traces' AS signal, ServiceName AS service, count() AS rows,
       countIf(ResourceAttributes['service.version'] = '')            AS no_version,
       countIf(ResourceAttributes['vcs.ref.head.revision'] = '')      AS no_revision,
       countIf(ResourceAttributes['cicd.pipeline.run.id'] = '')       AS no_run_id,
       countIf(ResourceAttributes['k8s.namespace.name'] = '')         AS no_namespace
FROM otel_traces WHERE $WIN GROUP BY service
UNION ALL
SELECT 'logs', ServiceName, count(),
       countIf(ResourceAttributes['service.version'] = ''),
       countIf(ResourceAttributes['vcs.ref.head.revision'] = ''),
       countIf(ResourceAttributes['cicd.pipeline.run.id'] = ''),
       countIf(ResourceAttributes['k8s.namespace.name'] = '')
FROM otel_logs WHERE $WIN GROUP BY ServiceName
UNION ALL
SELECT 'metrics(sum)', ServiceName, count(),
       countIf(ResourceAttributes['service.version'] = ''),
       countIf(ResourceAttributes['vcs.ref.head.revision'] = ''),
       countIf(ResourceAttributes['cicd.pipeline.run.id'] = ''),
       countIf(ResourceAttributes['k8s.namespace.name'] = '')
FROM otel_metrics_sum WHERE TimeUnix > now() - INTERVAL $MIN MINUTE GROUP BY ServiceName
) ORDER BY signal, service"

q "3. Every resource attribute key and the values seen (rating-api only, to keep it short)." "
SELECT key, groupUniqArray(5)(ResourceAttributes[key]) AS sample_values, count() AS spans
FROM otel_traces ARRAY JOIN mapKeys(ResourceAttributes) AS key
WHERE $WIN AND ServiceName = 'rating-api'
GROUP BY key ORDER BY key"

q "4. Version timeline: which build answered requests, per minute.
   After a second CI build + redeploy you see the cut-over from one version to the next." "
SELECT toStartOfMinute(Timestamp) AS minute,
       ServiceName AS service,
       if(ResourceAttributes['service.version'] = '', '(missing)', ResourceAttributes['service.version']) AS version,
       count() AS spans
FROM otel_traces WHERE $WIN AND SpanKind = 'Server'
GROUP BY minute, service, version ORDER BY minute, service, version"

q "5. The question this variant is for: latency and errors per build.
   One row per (service, version). A regression introduced by a build shows up
   as a jump between two rows of the same service." "
SELECT ServiceName AS service,
       if(ResourceAttributes['service.version'] = '', '(missing)', ResourceAttributes['service.version']) AS version,
       any(ResourceAttributes['cicd.pipeline.run.url.full']) AS run_url,
       count() AS requests,
       countIf(StatusCode = 'Error') AS errors,
       round(quantile(0.5)(Duration) / 1e6, 2)  AS p50_ms,
       round(quantile(0.95)(Duration) / 1e6, 2) AS p95_ms
FROM otel_traces WHERE $WIN AND SpanKind = 'Server'
GROUP BY service, version ORDER BY service, min(Timestamp)"
