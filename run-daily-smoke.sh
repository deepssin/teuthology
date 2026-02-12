#!/usr/bin/env bash
set -euo pipefail

# Script to run smoke suite daily for both main and tentacle branches
# Usage: run-daily-smoke.sh [override_yaml]
# This script can be called manually or via cron

SCRIPT_DIR="/home/ubuntu/teuthology"
OVERRIDE_YAML="${1:-/home/ubuntu/override.yaml}"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/daily-smoke-$(date +%Y%m%d-%H%M%S).log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Change to script directory
cd "$SCRIPT_DIR"

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Function to construct run name
construct_run_name() {
  local suite="$1"
  local timestamp="$2"
  local ceph_branch="$3"
  local user=$(whoami)
  local kernel_branch="distro"
  local worker="openstack"
  local flavor="default"
  
  suite=$(echo "$suite" | sed 's/\//:/g')
  echo "${user}-${timestamp}-${suite}-${ceph_branch}-${kernel_branch}-${flavor}-${worker}"
}

# Function to run smoke suite for a branch
run_smoke_for_branch() {
  local branch="$1"
  local tmp_err=$(mktemp)
  
  log "Starting smoke suite for branch: $branch"
  
  # Get shaman_id for the branch
  if ! shaman_id=$(python3 getUpstreamBuildDetails.py \
    --branch "$branch" \
    --platform ubuntu-jammy-default,centos-9-default \
    --arch x86_64 2>"$tmp_err"); then
    log "ERROR: Failed to get upstream build details for branch $branch:"
    cat "$tmp_err" | tee -a "$LOG_FILE"
    rm -f "$tmp_err"
    return 1
  fi
  
  log "Using shaman build id (ceph sha) for branch $branch: $shaman_id"
  rm -f "$tmp_err"

  # Use same SHA for suite so QA tests match the installed Ceph build (avoids
  # e.g. ImportError when suite expects symbols not in the build's Python bindings)
  local suite_sha1="$shaman_id"

  # Upload shaman_id to remote server
  sshpass -p "admin" ssh -o StrictHostKeyChecking=no cloud-user@10.0.196.233 \
    "sudo mkdir -p /data/scheduler/cron && echo '${shaman_id}' | sudo tee /data/scheduler/cron/${branch}-$(date "+%Y-%m-%d") > /dev/null" 2>&1 | tee -a "$LOG_FILE"
  
  # Unlock targets before running
  log "Unlocking targets..."
  # List targets - only stdout goes to file (for YAML), stderr goes to log
  if ! teuthology-lock --list-targets --owner scheduled_ubuntu@teuth-teuthology > ~/locked_targets 2>> "$LOG_FILE"; then
    log "WARNING: Failed to list targets, continuing anyway..."
  fi
  # Unlock targets - log both stdout and stderr
  if ! teuthology-lock --owner scheduled_ubuntu@teuth-teuthology --unlock -t ~/locked_targets -vvv >> "$LOG_FILE" 2>&1; then
    log "WARNING: Failed to unlock targets, continuing anyway..."
  fi
  
  # Smoke suite configuration
  local suite="smoke"
  local seed=8446
  
  log "Starting smoke suite for branch $branch with seed=$seed (ceph sha=$shaman_id, suite sha=$suite_sha1)"
  
  # Capture timestamp
  local timestamp=$(date "+%Y-%m-%d_%H:%M:%S")
  
  # Build and run command: use same SHA for both --sha1 (Ceph build) and --suite-sha1 (QA)
  # to avoid build/suite mismatch (e.g. RBD_LOCK_MODE_EXCLUSIVE_TRANSIENT).
  local cmd="teuthology-suite \
      --suite \"$suite\" \
      --machine-type openstack \
      --ceph \"$branch\" \
      --ceph-repo https://github.com/ceph/ceph \
      --priority 50 \
      --force-priority \
      --seed $seed \
      --sha1 $shaman_id \
      --suite-sha1 $suite_sha1 \
      $OVERRIDE_YAML"
  
  log "Running command: $cmd"
  
  # Execute teuthology-suite and capture output to extract run name
  local suite_output=$(mktemp)
  if ! eval "$cmd" > "$suite_output" 2>&1; then
    log "ERROR: Failed to schedule smoke suite for branch $branch"
    cat "$suite_output" >> "$LOG_FILE"
    rm -f "$suite_output"
    return 1
  fi
  
  # Append output to log
  cat "$suite_output" >> "$LOG_FILE"
  
  # Extract run name from teuthology-suite output
  # Format: "Job scheduled with name <run_name> and ID <id>"
  local run_name
  run_name=$(grep -oP "Job scheduled with name \K[^\s]+" "$suite_output" | head -1)
  rm -f "$suite_output"
  
  if [ -z "$run_name" ]; then
    log "WARNING: Could not extract run name from teuthology-suite output, constructing it..."
    run_name=$(construct_run_name "$suite" "$timestamp" "$branch")
  fi
  
  log "Using run name: $run_name"

  # Record run name for rerun-failed-smoke.sh (rerun fail/dead jobs once)
  local runs_file="$LOG_DIR/smoke-runs-$(date '+%Y-%m-%d')"
  echo "$run_name" >> "$runs_file"
  log "Recorded run name to $runs_file"

  # Wait for run to be registered
  log "Waiting 10 seconds for run to be registered on server..."
  sleep 10
  
  # Verify run exists
  log "Verifying run exists on server..."
  local run_exists=false
  local max_attempts=6
  local attempt=0
  
  while [ $attempt -lt $max_attempts ]; do
    if python3 <<EOF 2>/dev/null
from teuthology.report import ResultsReporter
try:
    reporter = ResultsReporter()
    jobs = reporter.get_jobs('$run_name', fields=['job_id'])
    if jobs is not None:
        exit(0)
except Exception as e:
    if '404' in str(e) or 'Not Found' in str(e):
        exit(1)
    exit(0)
EOF
    then
      run_exists=true
      break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -lt $max_attempts ]; then
      log "Run not found yet, waiting 5 seconds... (attempt $attempt/$max_attempts)"
      sleep 5
    fi
  done
  
  if [ "$run_exists" = false ]; then
    log "WARNING: Could not verify run '$run_name' exists after ${max_attempts} attempts."
    log "Will attempt to wait anyway - teuthology-wait will handle this."
  else
    log "Run verified on server: $run_name"
  fi
  
  # Wait for suite to complete using teuthology-wait
  # This ensures the run fully completes before the function returns
  log "Waiting for smoke suite (branch: $branch, run: $run_name) to complete using teuthology-wait..."
  if ! teuthology-wait --run "$run_name" >> "$LOG_FILE" 2>&1; then
    log "WARNING: Smoke suite for branch $branch completed with failures or errors"
    return 1
  else
    log "✓ Smoke suite for branch $branch completed successfully (teuthology-wait confirmed completion)"
    return 0
  fi
}

# Main execution
log "=========================================="
log "Starting daily smoke suite execution"
log "Log file: $LOG_FILE"
log "=========================================="
log ""

# Get day of week (1=Monday, 7=Sunday)
day_of_week=$(date +%u)
day_name=$(date +%A)

# Check if tentacle should run (Monday=1, Wednesday=3)
run_tentacle=false
if [ "$day_of_week" = "1" ] || [ "$day_of_week" = "3" ]; then
    run_tentacle=true
    log "Today is $day_name - will run both tentacle and main branches"
else
    log "Today is $day_name - will run main branch only (tentacle runs only on Monday and Wednesday)"
fi
log ""

# Run tentacle branch first if it's Monday or Wednesday
if [ "$run_tentacle" = true ]; then
    log "Starting smoke suite for 'tentacle' branch..."
    log ""
    if run_smoke_for_branch "tentacle"; then
        log "✓ Smoke suite for 'tentacle' branch completed"
    else
        log "✗ Smoke suite for 'tentacle' branch had errors"
    fi
    log ""
    log "Starting smoke suite for 'main' branch (tentacle run has completed)..."
    log ""
    if run_smoke_for_branch "main"; then
        log "✓ Smoke suite for 'main' branch completed"
    else
        log "✗ Smoke suite for 'main' branch had errors"
    fi
else
    log "Starting smoke suite for 'main' branch..."
    log ""
    if run_smoke_for_branch "main"; then
        log "✓ Smoke suite for 'main' branch completed"
    else
        log "✗ Smoke suite for 'main' branch had errors"
    fi
fi
log ""

# Check for fail/dead jobs and rerun them once (uses logs/smoke-runs-YYYY-MM-DD written above)
log "=========================================="
log "Checking for fail/dead jobs and rerunning once if needed..."
log "=========================================="
runs_file="$LOG_DIR/smoke-runs-$(date '+%Y-%m-%d')"
if [[ -f "$runs_file" ]]; then
  if "$SCRIPT_DIR/rerun-failed-smoke.sh" >> "$LOG_FILE" 2>&1; then
    log "✓ Rerun check completed"
  else
    log "✗ Rerun check had errors (see log)"
  fi
else
  log "No smoke-runs file found ($runs_file), skipping rerun check"
fi
log ""

log "=========================================="
log "Daily smoke suite execution completed"
log "=========================================="
