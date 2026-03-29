#!/usr/bin/env bash
set -euo pipefail

# Monitoring bootstrap for benchmark sessions.
# Goal: ensure Prometheus Operator stack exists and scrape resources are attached to Uyuni + DB.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: bash benchmark-harness/scripts/bootstrap_monitoring.sh [--session-dir <path>]

Installs/updates monitoring stack and applies ServiceMonitor resources for Uyuni and DB services.
USAGE
}

SESSION_DIR=""
# Keep argument parsing minimal; this script is usually called by run_benchmark.sh.
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
require_cmd kubectl helm jq

# When run standalone, create an ad-hoc monitoring session folder.
if [[ -z "$SESSION_DIR" ]]; then
  SESSION_DIR="$(benchmark_new_session_dir "$BENCHMARK_ROOT/results" "monitoring" "$STORAGE_CLASS")"
fi
mkdir -p "$SESSION_DIR/monitoring"
LOG_FILE="$SESSION_DIR/monitoring/bootstrap-monitoring.log"

{
  log "Bootstrap monitoring start"
  log "Session: $SESSION_DIR"

  # Namespace creation is idempotent, so repeated runs are safe.
  kubectl get ns "$MONITORING_NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$MONITORING_NAMESPACE"

  # Add/update chart repo before install/upgrade to avoid stale chart indexes.
  if ! helm repo list | awk '{print $1}' | grep -q '^prometheus-community$'; then
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  fi
  helm repo update

  # Install (or upgrade) kube-prometheus-stack.
  # SelectorNilUsesHelmValues=false allows our custom ServiceMonitor/PodMonitor resources to be discovered.
  helm upgrade --install kube-prom-stack prometheus-community/kube-prometheus-stack \
    -n "$MONITORING_NAMESPACE" \
    --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --wait

  # CRDs are required for ServiceMonitor/PodMonitor resources.
  # Fail here with clear error rather than continuing with silent scrape gaps.
  kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 \
    || die "ServiceMonitor CRD is missing after monitoring install"
  kubectl get crd podmonitors.monitoring.coreos.com >/dev/null 2>&1 \
    || die "PodMonitor CRD is missing after monitoring install"

  # Detect candidate services dynamically and label them for selector-based monitors.
  # We avoid hardcoding exact service names because labs often differ.
  local_services_json="$(kubectl -n "$UYUNI_NAMESPACE" get svc -o json)"

  uyuni_service="$(echo "$local_services_json" | jq -r '.items[].metadata.name' | grep -E '(web|tomcat|uyuni)' | head -n1 || true)"
  db_service="$(echo "$local_services_json" | jq -r '.items[].metadata.name' | grep -E '^(db|postgres|pgsql|reportdb)' | head -n1 || true)"

  [[ -n "$uyuni_service" ]] || die "Could not detect a Uyuni service in namespace $UYUNI_NAMESPACE"
  [[ -n "$db_service" ]] || die "Could not detect a DB service in namespace $UYUNI_NAMESPACE"

  uyuni_port="$(kubectl -n "$UYUNI_NAMESPACE" get svc "$uyuni_service" -o jsonpath='{.spec.ports[0].port}')"
  db_port="$(kubectl -n "$UYUNI_NAMESPACE" get svc "$db_service" -o jsonpath='{.spec.ports[0].port}')"

  [[ -n "$uyuni_port" ]] || die "Failed to detect target port for service $uyuni_service"
  [[ -n "$db_port" ]] || die "Failed to detect target port for service $db_service"

  kubectl -n "$UYUNI_NAMESPACE" label svc "$uyuni_service" benchmark-harness-target=uyuni --overwrite
  kubectl -n "$UYUNI_NAMESPACE" label svc "$db_service" benchmark-harness-target=db --overwrite

  # Apply ServiceMonitors with dynamic ports and configured namespaces.
  # Inline manifest keeps generated ports in one idempotent apply step.
  cat <<YAML | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: uyuni-benchmark
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/name: benchmark-harness
spec:
  namespaceSelector:
    matchNames:
      - ${UYUNI_NAMESPACE}
  selector:
    matchLabels:
      benchmark-harness-target: uyuni
  endpoints:
    - interval: 15s
      scrapeTimeout: 10s
      path: /metrics
      scheme: http
      targetPort: ${uyuni_port}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: uyuni-db-benchmark
  namespace: ${MONITORING_NAMESPACE}
  labels:
    app.kubernetes.io/name: benchmark-harness
spec:
  namespaceSelector:
    matchNames:
      - ${UYUNI_NAMESPACE}
  selector:
    matchLabels:
      benchmark-harness-target: db
  endpoints:
    - interval: 15s
      scrapeTimeout: 10s
      path: /metrics
      scheme: http
      targetPort: ${db_port}
YAML

  # Optional PodMonitor is best-effort and remains selector-driven.
  # It can be enabled later by labeling pods with benchmark-harness-pod-monitor=true.
  kubectl apply -f "$BENCHMARK_ROOT/manifests/monitoring/podmonitor-optional.yaml" \
    --namespace "$MONITORING_NAMESPACE"

  # Save resolved targets/resources as benchmark evidence.
  kubectl -n "$MONITORING_NAMESPACE" get servicemonitors,podmonitors -o wide \
    > "$SESSION_DIR/monitoring/monitoring-resources.txt"

  {
    echo "uyuni_service=$uyuni_service"
    echo "uyuni_target_port=$uyuni_port"
    echo "db_service=$db_service"
    echo "db_target_port=$db_port"
  } > "$SESSION_DIR/monitoring/detected-targets.txt"

  log "Monitoring bootstrap complete"
} | tee "$LOG_FILE"
