# Benchmark Harness (Uyuni on RKE2)

This directory provides a reproducible benchmark harness for:
- PostgreSQL transaction benchmarking (`pgbench`)
- Uyuni workload benchmarking (`repo_sync_minimal`, `metadata_refresh`, `ui_locust`, `package_download`)
- Prometheus/Grafana observability capture
- Machine-readable summaries (`CSV`, `JSON`) and final markdown report

The workflow is designed to run first on the `local-path` control environment and then be repeated against other StorageClasses with the same protocol.

## Prerequisites
- Kubernetes access (`kubectl`) to your RKE2 cluster.
- Helm (for monitoring stack bootstrap).
- Python 3.
- `jq`.
- Reachable Uyuni namespace and DB pod.
- Working local lab state:
  - namespace `uyuni`
  - FQDN `uyuni.home.arpa`
  - healthy Uyuni + DB + micro-client
  - Salt ping and `pkg.refresh_db` passing

## Environment Setup
1. Copy env example:
```bash
cp benchmark-harness/config/benchmark.env.example benchmark-harness/config/benchmark.env
```
2. Edit `benchmark-harness/config/benchmark.env` to match your environment.

Key variables include:
- cluster and namespace settings
- PostgreSQL connection settings
- profile defaults for `pgbench`, Locust, and package downloads
- observability endpoint (`PROM_URL`)

## Monitoring Install
Run monitoring bootstrap (idempotent):
```bash
bash benchmark-harness/scripts/bootstrap_monitoring.sh
```

Verify target status and save evidence:
```bash
bash benchmark-harness/scripts/verify_metrics.sh
```

## Smoke Profile Run
```bash
bash benchmark-harness/scripts/run_benchmark.sh --profile smoke
```

## Full Profile Run
```bash
bash benchmark-harness/scripts/run_benchmark.sh --profile full
```

## Optional Flags
`run_benchmark.sh` supports:
- `--storage-class <name>`
- `--outdir <dir>`
- `--skip-monitoring`
- `--skip-pgbench`
- `--skip-uyuni`

## Expected Outputs
Each run creates:
```text
benchmark-harness/results/session-<timestamp>-<profile>-<storage>/
```

Inside a session directory:
- `metadata/` cluster + storage context snapshots
- `pg-capabilities.json`
- `sql/` pre/post SQL snapshots (`txt` + `json` + CSV extracts)
- `pgbench/` raw runs + parsed results + markdown summary
- `uyuni/` workload raw runs + parsed results + markdown summary
- `prometheus/` raw `query_range` dumps + reduced summaries
- `benchmark-summary.md`
- `pgbench-summary.csv`
- `uyuni-workload-summary.csv`
- `prometheus-summary.csv`

## Troubleshooting
- If `pgbench` is missing, confirm the DB pod contains `pgbench` or switch to a compatible DB image.
- If ServiceMonitor apply fails, confirm CRDs exist:
  - `servicemonitors.monitoring.coreos.com`
  - `podmonitors.monitoring.coreos.com`
- If Prometheus queries are empty, the run still completes and marks missing metrics in summaries.
- If Locust cannot log in due endpoint differences, update login URLs in `scripts/run_uyuni_workloads.sh` locustfile section.
- For package metadata decompression:
  - `.gz` works via `gzip`
  - `.zst` works via Python `zstandard` if installed, otherwise `zstd` CLI is used.

## Required Completion Commands
After setup, these should work:
```bash
bash benchmark-harness/scripts/bootstrap_monitoring.sh
bash benchmark-harness/scripts/verify_metrics.sh
bash benchmark-harness/scripts/run_benchmark.sh --profile smoke
sed -n '1,200p' benchmark-harness/results/<latest-session>/benchmark-summary.md
```
