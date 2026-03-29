#!/usr/bin/env bash
set -euo pipefail

# Main orchestrator for end-to-end benchmark sessions.
# This script intentionally keeps execution order explicit so artifacts are reproducible.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<USAGE
Usage: bash benchmark-harness/scripts/run_benchmark.sh [options]

Options:
  --profile smoke|full        Profile to run (default: smoke)
  --storage-class <name>      StorageClass context label (default from env)
  --outdir <dir>              Session output parent directory (default: benchmark-harness/results)
  --skip-monitoring           Skip monitoring bootstrap step
  --skip-pgbench              Skip pgbench benchmark matrix
  --skip-uyuni                Skip Uyuni workload benchmarks
USAGE
}

PROFILE="smoke"
OUTDIR=""
SKIP_MONITORING=0
SKIP_PGBENCH=0
SKIP_UYUNI=0

# Parse CLI flags first, then load env defaults from benchmark.env.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --storage-class)
      STORAGE_CLASS="$2"
      shift 2
      ;;
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    --skip-monitoring)
      SKIP_MONITORING=1
      shift
      ;;
    --skip-pgbench)
      SKIP_PGBENCH=1
      shift
      ;;
    --skip-uyuni)
      SKIP_UYUNI=1
      shift
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

[[ "$PROFILE" == "smoke" || "$PROFILE" == "full" ]] || die "--profile must be smoke or full"

benchmark_load_env
require_cmd kubectl python3 jq

# Allow caller to override output root while preserving default result structure.
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="$BENCHMARK_ROOT/results"
fi

# Session dir is created once and passed to all child scripts so evidence is co-located.
SESSION_DIR="$(benchmark_new_session_dir "$OUTDIR" "$PROFILE" "$STORAGE_CLASS")"
mkdir -p "$SESSION_DIR"
LOG_FILE="$SESSION_DIR/benchmark-run.log"

{
  log "Benchmark run start"
  log "Session directory: $SESSION_DIR"
  log "Profile: $PROFILE"
  log "StorageClass context: $STORAGE_CLASS"

  # 1) Capture static metadata up front before any benchmark activity mutates state.
  benchmark_save_metadata_snapshot "$SESSION_DIR"

  # 2) Fail fast when selected storage class is invalid.
  kubectl get sc "$STORAGE_CLASS" >/dev/null 2>&1 || die "StorageClass not found: $STORAGE_CLASS"

  # 3) Install/configure monitoring stack (optional but recommended).
  if [[ "$SKIP_MONITORING" == "0" ]]; then
    bash "$SCRIPT_DIR/bootstrap_monitoring.sh" --session-dir "$SESSION_DIR"
  else
    warn "Skipping monitoring bootstrap (--skip-monitoring)"
  fi

  # 4) Always verify scrape health; this also records target evidence files.
  bash "$SCRIPT_DIR/verify_metrics.sh" --session-dir "$SESSION_DIR"

  # 5) Detect DB observability capabilities and enable optional instrumentation.
  bash "$SCRIPT_DIR/detect_pg_capabilities.sh" --session-dir "$SESSION_DIR"

  # 6) Run transaction-focused matrix (clients/scenarios/runs).
  if [[ "$SKIP_PGBENCH" == "0" ]]; then
    bash "$SCRIPT_DIR/run_pgbench_matrix.sh" --profile "$PROFILE" --session-dir "$SESSION_DIR"
  else
    warn "Skipping pgbench matrix (--skip-pgbench)"
  fi

  # 7) Run application-level workloads (metadata refresh, UI load, package download, etc.).
  if [[ "$SKIP_UYUNI" == "0" ]]; then
    bash "$SCRIPT_DIR/run_uyuni_workloads.sh" --profile "$PROFILE" --session-dir "$SESSION_DIR"
  else
    warn "Skipping Uyuni workloads (--skip-uyuni)"
  fi

  # 8) Build top-level rollup CSV/Markdown from all collected run artifacts.
  python3 "$SCRIPT_DIR/summarize_benchmark.py" "$SESSION_DIR"

  log "Benchmark run complete"
  log "Top-level summary: $SESSION_DIR/benchmark-summary.md"
} | tee "$LOG_FILE"
