#!/usr/bin/env bash
set -euo pipefail

# Metrics health check for benchmark observability.
# Produces machine-readable target dump plus human-readable markdown status.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: bash benchmark-harness/scripts/verify_metrics.sh [--session-dir <path>]

Verifies Prometheus reachability and target categories, then writes evidence artifacts.
USAGE
}

SESSION_DIR=""
# Parsing supports both standalone execution and orchestrated session runs.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-dir)
      SESSION_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

benchmark_load_env
require_cmd kubectl curl jq

# Default session folder for ad-hoc verification runs.
if [[ -z "$SESSION_DIR" ]]; then
  SESSION_DIR="$(benchmark_new_session_dir "$BENCHMARK_ROOT/results" "metrics-verify" "$STORAGE_CLASS")"
fi
mkdir -p "$SESSION_DIR/monitoring"

SM_PM_FILE="$SESSION_DIR/monitoring/servicemonitor-podmonitor-list.txt"
TARGETS_FILE="$SESSION_DIR/monitoring/prometheus-targets.json"
STATUS_MD="$SESSION_DIR/monitoring/metrics-status.md"

# Snapshot monitor resource inventory regardless of Prometheus health.
kubectl get servicemonitors,podmonitors -A > "$SM_PM_FILE"

effective_prom_url="$PROM_URL"
pf_pid=""

# First try direct in-cluster URL. If unavailable from host context, fallback to kubectl port-forward.
if ! curl -fsS "$effective_prom_url/api/v1/status/runtimeinfo" >/dev/null 2>&1; then
  warn "Direct Prometheus URL unreachable from host: $effective_prom_url"
  prom_svc="$(
    kubectl -n "$MONITORING_NAMESPACE" get svc -o json \
      | jq -r '.items[].metadata.name' \
      | grep -E 'prometheus' \
      | head -n1 || true
  )"
  [[ -n "$prom_svc" ]] || die "Could not detect Prometheus service for port-forward fallback"

  log "Using port-forward fallback via service/${prom_svc}"
  kubectl -n "$MONITORING_NAMESPACE" port-forward "svc/${prom_svc}" 19090:9090 >/tmp/benchmark-prom-portforward.log 2>&1 &
  pf_pid=$!
  trap '[[ -n "$pf_pid" ]] && kill "$pf_pid" >/dev/null 2>&1 || true' EXIT
  sleep 3

  effective_prom_url="http://127.0.0.1:19090"
  curl -fsS "$effective_prom_url/api/v1/status/runtimeinfo" >/dev/null 2>&1 \
    || die "Prometheus still unreachable after port-forward fallback"
fi

# Save raw `/targets` response for forensic debugging and later proposal evidence.
curl -fsS "$effective_prom_url/api/v1/targets" > "$TARGETS_FILE" \
  || die "Failed to query Prometheus targets endpoint: $effective_prom_url/api/v1/targets"

# Category checks:
# - Prometheus self targets prove collector is alive.
# - Node exporter/kubelet targets prove node-level metrics path is healthy.
# - Uyuni namespace targets prove application namespace is visible.
prom_up_count="$(jq '[.data.activeTargets[] | select((.labels.job // "") | test("prometheus"; "i")) | select(.health == "up")] | length' "$TARGETS_FILE")"
node_up_count="$(jq '[.data.activeTargets[] | select((.labels.job // "") | test("node|kubelet|node-exporter"; "i")) | select(.health == "up")] | length' "$TARGETS_FILE")"
uyuni_db_up_count="$(jq --arg ns "$UYUNI_NAMESPACE" '[.data.activeTargets[] | select((.labels.namespace // .discoveredLabels.__meta_kubernetes_namespace // "") == $ns) | select(.health == "up")] | length' "$TARGETS_FILE")"

total_active="$(jq '.data.activeTargets | length' "$TARGETS_FILE")"

# Convert counts into explicit yes/no status for markdown summary readability.
prom_ok="no"
node_ok="no"
uyuni_db_ok="no"
[[ "$prom_up_count" -gt 0 ]] && prom_ok="yes"
[[ "$node_up_count" -gt 0 ]] && node_ok="yes"
[[ "$uyuni_db_up_count" -gt 0 ]] && uyuni_db_ok="yes"

{
  echo "# Metrics Verification"
  echo
  echo "- verification_time_utc: $(now_utc)"
  echo "- prom_url: $effective_prom_url"
  echo "- monitoring_namespace: $MONITORING_NAMESPACE"
  echo "- uyuni_namespace: $UYUNI_NAMESPACE"
  echo "- total_active_targets: $total_active"
  echo
  echo "## Category Status"
  echo
  echo "| Category | Up Count | Status |"
  echo "| --- | ---: | --- |"
  echo "| Prometheus self targets | $prom_up_count | $prom_ok |"
  echo "| Node metrics targets | $node_up_count | $node_ok |"
  echo "| Uyuni/DB namespace targets | $uyuni_db_up_count | $uyuni_db_ok |"
  echo
  echo "## Evidence Files"
  echo "- $SM_PM_FILE"
  echo "- $TARGETS_FILE"
} > "$STATUS_MD"

log "Metrics verification summary: $STATUS_MD"
