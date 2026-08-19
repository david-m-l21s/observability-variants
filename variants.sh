#!/usr/bin/env bash
# Control variant lifecycles so you don't leave every variant running at once.
# A "variant" is a namespace named NN-<something> (01-simple-apps,
# 02-runtime-injection, ...). "stop" scales its pods to 0 (frees CPU/RAM but
# keeps the namespace, collector, config and ClickHouse data — resume is instant).
#
# Usage:
#   ./variants.sh status                 # what's running, per variant
#   ./variants.sh stop   <variant|all>   # scale a variant's pods to 0
#   ./variants.sh resume <variant|all>   # scale a variant back to 1
#
# <variant> may be the full namespace (02-runtime-injection) or any unique
# substring (runtime-injection). To remove a variant entirely, delete its
# namespace: kubectl delete namespace <variant>.
set -euo pipefail
CLUSTER="${CLUSTER:-obs-vm-tests}"
kubectl config use-context "kind-${CLUSTER}" >/dev/null 2>&1 || true

# All variant namespaces = those named like NN-... (two digits + dash).
variant_namespaces() {
  kubectl get ns -o name 2>/dev/null | sed 's|namespace/||' | grep -E '^[0-9]{2}-' | sort
}

# Resolve a user argument to exactly one variant namespace.
resolve() {
  local q="$1" matches count
  if variant_namespaces | grep -qx "$q"; then echo "$q"; return 0; fi
  matches=$(variant_namespaces | grep -F "$q" || true)
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -eq 1 ]; then echo "$matches"; return 0; fi
  if [ "$count" -eq 0 ]; then
    echo "No variant matches '$q'. Known variants:" >&2; variant_namespaces >&2
  else
    echo "'$q' is ambiguous — matches:" >&2; printf '%s\n' "$matches" >&2
  fi
  return 1
}

scale_ns() { # namespace replicas
  local ns="$1" r="$2" deps n
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then echo "  ($ns not found, skipping)"; return; fi
  deps=$(kubectl get deploy -n "$ns" -o name 2>/dev/null || true)
  if [ -z "$deps" ]; then echo "  ($ns has no deployments)"; return; fi
  n=$(printf '%s\n' "$deps" | grep -c .)
  # shellcheck disable=SC2086
  kubectl scale -n "$ns" --replicas="$r" $deps >/dev/null
  echo "  $ns -> replicas=$r ($n deployments)"
}

action="${1:-status}"
target="${2:-}"

case "$action" in
  status|list|ls)
    ns_list=$(variant_namespaces)
    if [ -z "$ns_list" ]; then echo "No variants found in cluster '$CLUSTER'."; exit 0; fi
    printf '%-24s %-9s %s\n' "VARIANT (namespace)" "RUNNING" "DEPLOYMENTS (ready/desired)"
    for ns in $ns_list; do
      running=$(kubectl get pods -n "$ns" --field-selector=status.phase=Running -o name 2>/dev/null | grep -c . || true)
      deps=$(kubectl get deploy -n "$ns" \
        -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}{"/"}{.spec.replicas} {end}' 2>/dev/null \
        | sed 's|=/|=0/|g')
      printf '%-24s %-9s %s\n' "$ns" "${running} pods" "${deps:-none}"
    done
    ;;
  stop|resume)
    [ -n "$target" ] || { echo "Usage: $0 $action <variant|all>" >&2; exit 1; }
    r=0; [ "$action" = resume ] && r=1
    [ "$action" = resume ] && verb="Resuming" || verb="Stopping"
    echo "$verb (replicas=$r):"
    if [ "$target" = all ]; then
      for ns in $(variant_namespaces); do scale_ns "$ns" "$r"; done
    else
      ns=$(resolve "$target") || exit 1
      scale_ns "$ns" "$r"
    fi
    ;;
  *)
    echo "Usage: $0 {status|stop|resume} [variant|all]" >&2
    echo "  status                 list variants and what's running" >&2
    echo "  stop   <variant|all>   scale a variant to 0 (keeps config + data)" >&2
    echo "  resume <variant|all>   scale a variant back to 1" >&2
    exit 1
    ;;
esac
