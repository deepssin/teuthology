#!/usr/bin/env bash
set -euo pipefail

# Rerun failed and dead jobs from a daily smoke run, once only.
# Usage: rerun-failed-smoke.sh [RUN_NAME]
#        rerun-failed-smoke.sh --check RUN_NAME   # only print branch, fail+dead count, sha1
#   If RUN_NAME is omitted, uses run names from logs/smoke-runs-YYYY-MM-DD
#   (written by run-daily-smoke.sh when it schedules runs).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
OVERRIDE_YAML="${OVERRIDE_YAML:-/home/ubuntu/override.yaml}"
LOG_FILE="${LOG_DIR}/rerun-smoke-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"
cd "$SCRIPT_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Get branch from run name (e.g. ...-smoke-main-distro-... or ...-smoke-tentacle-distro-...)
get_branch_from_run_name() {
  local run_name="$1"
  if [[ "$run_name" =~ -smoke-([^-]+)-distro- ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "main"
  fi
}

# Count fail+dead jobs; output to stdout: first line = count, second line = sha1 from run (if found)
count_fail_dead_and_get_sha() {
  local run_name="$1"
  RUN_NAME="$run_name" python3 <<'PYEOF' 2>/dev/null
import os
import sys
run_name = os.environ.get('RUN_NAME', '')
if not run_name:
    print('0')
    sys.exit(0)
try:
    from teuthology.config import config
    from teuthology.report import ResultsReporter
    reporter = ResultsReporter()
    jobs = reporter.get_jobs(run_name, fields=['status'])
    if not jobs:
        print('0')
        sys.exit(0)
    n = sum(1 for j in jobs if j.get('status') in ('fail', 'dead'))
    print(n)

    archive_base = getattr(config, 'archive_base', '') or ''
    run_archive = os.path.join(archive_base, run_name)
    sha1 = None
    if os.path.isdir(run_archive):
        for name in sorted(os.listdir(run_archive)):
            if name.isdigit():
                job_dir = os.path.join(run_archive, name)
                for yaml in ('config.yaml', 'info.yaml', 'orig.config.yaml'):
                    path = os.path.join(job_dir, yaml)
                    if os.path.isfile(path):
                        try:
                            import yaml
                            with open(path) as f:
                                data = yaml.safe_load(f)
                            if data and isinstance(data, dict):
                                sha1 = data.get('sha1') or data.get('suite_sha1')
                                if sha1:
                                    break
                        except Exception:
                            pass
                if sha1:
                    break
    if sha1:
        print(sha1)
except Exception:
    print('-1')
    sys.exit(1)
PYEOF
}

# --check RUN_NAME: print branch, fail+dead count, and sha1 then exit (no rerun)
if [[ "${1:-}" = "--check" ]]; then
  run_name="${2:-}"
  if [[ -z "$run_name" ]]; then
    echo "Usage: $0 --check RUN_NAME"
    exit 1
  fi
  branch=$(get_branch_from_run_name "$run_name")
  echo "Run:    $run_name"
  echo "Branch: $branch"
  out=$(count_fail_dead_and_get_sha "$run_name")
  fail_dead=$(echo "$out" | head -1)
  sha1=$(echo "$out" | sed -n '2p')
  echo "Fail+dead count: $fail_dead"
  if [[ -n "$sha1" ]]; then
    echo "SHA1 (from run):  $sha1"
  else
    echo "SHA1 (from run):  (not found in archive)"
  fi
  exit 0
fi

# Rerun a single run if it has any fail or dead jobs (once only)
do_rerun_for_run() {
  local run_name="$1"
  local branch
  branch=$(get_branch_from_run_name "$run_name")
  log "Run: $run_name (branch=$branch)"

  local out
  out=$(count_fail_dead_and_get_sha "$run_name")
  local fail_dead
  fail_dead=$(echo "$out" | head -1)
  local shaman_id
  shaman_id=$(echo "$out" | sed -n '2p')

  if [[ "$fail_dead" = "-1" ]]; then
    log "WARNING: Could not query jobs for run $run_name (server unreachable or run missing), skipping"
    return 1
  fi
  if [[ "$fail_dead" -eq 0 ]]; then
    log "No fail/dead jobs for $run_name, skipping rerun"
    return 0
  fi

  log "Found $fail_dead fail/dead job(s); scheduling one-time rerun..."

  # Use the original run's Ceph/suite SHA (from archive); only fall back to latest build if missing
  if [[ -z "$shaman_id" ]]; then
    local tmp_err
    tmp_err=$(mktemp)
    if ! shaman_id=$(python3 getUpstreamBuildDetails.py \
      --branch "$branch" \
      --platform ubuntu-jammy-default,centos-9-default \
      --arch x86_64 2>"$tmp_err"); then
      log "ERROR: No sha1 in run archive and failed to get upstream build for branch $branch:"
      cat "$tmp_err" | tee -a "$LOG_FILE"
      rm -f "$tmp_err"
      return 1
    fi
    rm -f "$tmp_err"
    log "Using latest ceph/suite sha for branch $branch (run archive had no sha1): $shaman_id"
  else
    log "Using original run ceph/suite sha: $shaman_id"
  fi

  # Rerun only fail and dead jobs; use same SHA for build and suite.
  # Suite and rerun-statuses (fail,dead) come from run metadata / defaults.
  local cmd="teuthology-suite \
    --rerun \"$run_name\" \
    -c \"$branch\" \
    -m openstack \
    --ceph-repo https://github.com/ceph/ceph \
    --priority 50 \
    --force-priority \
    --sha1 $shaman_id \
    --suite-sha1 $shaman_id \
    $OVERRIDE_YAML"

  log "Running: $cmd"
  local suite_output
  suite_output=$(mktemp)
  if ! eval "$cmd" > "$suite_output" 2>&1; then
    log "ERROR: Rerun scheduling failed for $run_name"
    cat "$suite_output" >> "$LOG_FILE"
    rm -f "$suite_output"
    return 1
  fi
  cat "$suite_output" >> "$LOG_FILE"

  local rerun_name
  rerun_name=$(grep -oP "Job scheduled with name \K[^\s]+" "$suite_output" | head -1)
  rm -f "$suite_output"

  if [ -z "$rerun_name" ]; then
    log "WARNING: Could not extract rerun name from output"
    return 0
  fi
  log "Rerun scheduled: $rerun_name (one-time; no automatic retry if this fails)"

  log "Waiting for rerun to complete..."
  if ! teuthology-wait --run "$rerun_name" >> "$LOG_FILE" 2>&1; then
    log "WARNING: Rerun $rerun_name finished with failures (no further automatic retries)"
    return 1
  fi
  log "Rerun $rerun_name completed"
  return 0
}

# Resolve list of run names: from args or from today's smoke-runs file
run_names=()
if [[ $# -ge 1 ]]; then
  run_names=("$@")
  log "Using run name(s) from arguments: ${run_names[*]}"
else
  runs_file="${LOG_DIR}/smoke-runs-$(date '+%Y-%m-%d')"
  if [[ ! -f "$runs_file" ]]; then
    log "No run name given and no file $runs_file (run run-daily-smoke.sh first or pass RUN_NAME)"
    exit 1
  fi
  while IFS= read -r line; do
    line=$(echo "$line" | tr -d '\r\n')
    if [[ -n "$line" ]]; then
      # Avoid duplicate run names (e.g. same day manual + cron)
      if [[ " ${run_names[*]} " != *" $line "* ]]; then
        run_names+=("$line")
      fi
    fi
  done < "$runs_file"
  log "Using run name(s) from $runs_file: ${run_names[*]}"
fi

log "=========================================="
log "Rerun failed/dead smoke jobs (one-time)"
log "=========================================="

exit_code=0
for run_name in "${run_names[@]}"; do
  if ! do_rerun_for_run "$run_name"; then
    exit_code=1
  fi
  log ""
done

log "=========================================="
log "Rerun smoke script finished (exit_code=$exit_code)"
log "=========================================="
exit "$exit_code"
