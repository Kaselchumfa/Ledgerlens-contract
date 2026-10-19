#!/usr/bin/env bash
# --- usage ---
# Continuously deploy main to the staging instance through the standard
# time-locked proposal flow, then verify and roll back on failure.
#
# Usage:
#   ./scripts/staging-upgrade.sh [options] <network> <admin-identity> <contract-id> <new-wasm-path>
#
# Options:
#   --previous-wasm <path>  WASM to roll back to on verification failure (required
#                           unless --dry-run or --allow-no-rollback; the last
#                           known-good staging artifact).
#   --allow-no-rollback     First-deployment escape hatch: permit a run with no
#                           previous WASM (no automatic rollback coverage).
#                           The CI workflow uses this only when no prior staging
#                           evidence exists; every later run must supply
#                           --previous-wasm.
#   --dry-run               Print the commands that would be executed without running them.
#   --non-interactive       Never prompt; fail closed instead of waiting for input.
#                           Required for CI. Implies no manual confirmations.
#   --skip-delay-wait       Do not poll for the upgrade delay (hermetic rehearsal and
#                           unit tests only; never for real staging — the time-lock
#                           is a security property, see SECURITY.md).
#   --max-wait-secs <n>     Upper bound for polling executable_after (default: 10800).
#   --poll-interval-secs <n> Polling interval while waiting (default: 60).
#   --health-source <id>    Identity used for read-only health checks (default: health-check).
#   --evidence-dir <dir>    Directory for the machine-readable evidence bundle
#                           (default: <repo>/target/staging-evidence).
#   --staging-status <path> Machine-readable status file to update
#                           (default: <repo>/deploy/staging.json).
#   --help                  Show this help message.
#
# Arguments:
#   network           staging network alias (testnet|futurenet — never mainnet)
#   admin-identity    staging-only Soroban CLI identity (see docs/staging-deployment.md)
#   contract-id       staging contract instance to upgrade in place
#   new-wasm-path     release WASM artifact to propose (raw or optimized build)
#
# Flow:
#   1. Baseline health check (fail closed if the instance is already unhealthy).
#   2. propose_upgrade through the standard on-chain time-lock.
#   3. Poll get_pending_upgrade until executable_after (bounded wait).
#   4. execute_upgrade, then health_check.sh + verify-deployment.sh canary checks.
#   5. On any post-execute failure: roll back to --previous-wasm through the
#      same proposal flow, re-run health checks, exit non-zero with evidence.
#
# Exit codes:
#   0  deployed and verified (status=deployed)
#   2  proposal recorded but delay not yet elapsed (status=proposed-pending)
#   1  verification failed; rollback attempted (status=rolled-back|failed)
#
# See docs/staging-deployment.md for secrets scope, rotation, and the CI wiring.
# --- end usage ---

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

print_usage() {
  grep -q '^# --- usage ---$' "$0" || { echo "ERROR: $0 is missing the '# --- usage ---' marker." >&2; return 1; }
  grep -q '^# --- end usage ---$' "$0" || { echo "ERROR: $0 is missing the '# --- end usage ---' marker." >&2; return 1; }
  awk '
    /^# --- usage ---$/     { in_usage = 1; next }
    /^# --- end usage ---$/ { in_usage = 0; next }
    in_usage                { sub(/^# ?/, ""); print }
  ' "$0"
}

DRY_RUN=false
NON_INTERACTIVE=false
SKIP_DELAY_WAIT=false
ALLOW_NO_ROLLBACK=false
MAX_WAIT_SECS="${STAGING_UPGRADE_MAX_WAIT_SECS:-10800}"
POLL_INTERVAL_SECS="${STAGING_UPGRADE_POLL_INTERVAL_SECS:-60}"
HEALTH_SOURCE="${STAGING_HEALTH_SOURCE:-health-check}"
EVIDENCE_DIR="$PROJECT_ROOT/target/staging-evidence"
STAGING_STATUS_FILE="$PROJECT_ROOT/deploy/staging.json"
PREVIOUS_WASM=""
POSITIONAL=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --skip-delay-wait) SKIP_DELAY_WAIT=true; shift ;;
    --max-wait-secs) [ "$#" -ge 2 ] || { echo "ERROR: --max-wait-secs requires a value." >&2; exit 1; }; MAX_WAIT_SECS="$2"; shift 2 ;;
    --poll-interval-secs) [ "$#" -ge 2 ] || { echo "ERROR: --poll-interval-secs requires a value." >&2; exit 1; }; POLL_INTERVAL_SECS="$2"; shift 2 ;;
    --health-source) [ "$#" -ge 2 ] || { echo "ERROR: --health-source requires a value." >&2; exit 1; }; HEALTH_SOURCE="$2"; shift 2 ;;
    --evidence-dir) [ "$#" -ge 2 ] || { echo "ERROR: --evidence-dir requires a value." >&2; exit 1; }; EVIDENCE_DIR="$2"; shift 2 ;;
    --staging-status) [ "$#" -ge 2 ] || { echo "ERROR: --staging-status requires a value." >&2; exit 1; }; STAGING_STATUS_FILE="$2"; shift 2 ;;
    --previous-wasm) [ "$#" -ge 2 ] || { echo "ERROR: --previous-wasm requires a path." >&2; exit 1; }; PREVIOUS_WASM="$2"; shift 2 ;;
    --allow-no-rollback) ALLOW_NO_ROLLBACK=true; shift ;;
    --help) print_usage; exit 0 ;;
    --*) echo "ERROR: unknown option '$1'." >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

NETWORK="${1:?ERROR: network argument is required (testnet|futurenet)}"
ADMIN_IDENTITY="${2:?ERROR: admin-identity argument is required}"
CONTRACT_ID="${3:?ERROR: contract-id argument is required}"
NEW_WASM_PATH="${4:?ERROR: new-wasm-path argument is required}"

TS() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(TS)] $*" | tee -a "$EVIDENCE_DIR/staging-upgrade.log"; }
die() {
  echo "[$(TS)] ERROR: $*" | tee -a "$EVIDENCE_DIR/staging-upgrade.log" >&2
  # Record a terminal status so the status file never stays at "pending".
  write_status "failed" "fail" "fail" "$*" || true
  exit 1
}

run() {
  if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

detect_cli() {
  if command -v stellar >/dev/null 2>&1; then echo "stellar"; return; fi
  if command -v soroban >/dev/null 2>&1; then echo "soroban"; return; fi
  if [ "$DRY_RUN" = true ]; then echo "stellar"; return; fi
  die "neither 'stellar' nor 'soroban' was found in PATH"
}

# ── Guardrails ──────────────────────────────────────────────────────────────
case "$NETWORK" in
  testnet|futurenet) ;;
  *) die "staging upgrades are only supported on testnet|futurenet, not '$NETWORK' (refusing to touch mainnet from CD)" ;;
esac

if [ "$SKIP_DELAY_WAIT" = true ] && [ "${STAGING_ALLOW_SKIP_DELAY_WAIT:-0}" != "1" ] && [ "$DRY_RUN" = false ]; then
  die "--skip-delay-wait is only allowed with STAGING_ALLOW_SKIP_DELAY_WAIT=1 (rehearsal/tests) or --dry-run"
fi

[ -f "$NEW_WASM_PATH" ] || die "new WASM not found at $NEW_WASM_PATH"
if [ -z "$PREVIOUS_WASM" ] && [ "$DRY_RUN" = false ] && [ "$ALLOW_NO_ROLLBACK" = false ]; then
  die "--previous-wasm is required (last known-good staging artifact) for automatic rollback"
fi
if [ -n "$PREVIOUS_WASM" ] && [ ! -f "$PREVIOUS_WASM" ]; then
  die "previous WASM not found at $PREVIOUS_WASM"
fi

mkdir -p "$EVIDENCE_DIR"
: > "$EVIDENCE_DIR/staging-upgrade.log"

CLI_BIN="$(detect_cli)"
ADMIN_ADDRESS="$($CLI_BIN keys address "$ADMIN_IDENTITY" 2>/dev/null || echo '<ADMIN_ADDRESS>')"
NEW_WASM_HASH="$(sha256sum "$NEW_WASM_PATH" | awk '{print $1}')"
PREVIOUS_WASM_HASH=""
if [ -n "$PREVIOUS_WASM" ]; then
  PREVIOUS_WASM_HASH="$(sha256sum "$PREVIOUS_WASM" | awk '{print $1}')"
fi

log "Staging upgrade: network=$NETWORK contract=$CONTRACT_ID admin=$ADMIN_ADDRESS"
log "New WASM: $NEW_WASM_PATH ($NEW_WASM_HASH)"
if [ -n "$PREVIOUS_WASM" ]; then
  log "Rollback WASM: $PREVIOUS_WASM ($PREVIOUS_WASM_HASH)"
else
  log "Rollback WASM: none on this run"
fi

invoke() {
  run "$CLI_BIN" contract invoke \
    --id "$CONTRACT_ID" \
    --source "$ADMIN_IDENTITY" \
    --network "$NETWORK" \
    -- "$@"
}

write_status() {
  # write_status <status> <health> <canary> <note>
  local status="$1" health="$2" canary="$3" note="$4"
  local version="unknown" commit_sha="${GITHUB_SHA:-unknown}" run_url="${GITHUB_RUN_URL:-unknown}"
  if [ "$DRY_RUN" = false ]; then
    version="$(invoke get_version 2>/dev/null || echo 'unknown')"
  else
    version="<VERSION>"
  fi
  if command -v python3 >/dev/null 2>&1; then
    STAGING_STATUS_FILE="$STAGING_STATUS_FILE" STAGING_SCHEMA_FILE="$PROJECT_ROOT/deploy/staging.schema.json" \
      python3 - "$status" "$health" "$canary" "$note" "$CONTRACT_ID" "$NETWORK" "$NEW_WASM_HASH" "$PREVIOUS_WASM_HASH" "$version" "$commit_sha" "$run_url" <<'EOF'
import json, sys, datetime, os
(status, health, canary, note, contract_id, network, wasm, prev_wasm, version, commit, run_url) = sys.argv[1:12]
path = os.environ["STAGING_STATUS_FILE"]
schema_path = os.environ.get("STAGING_SCHEMA_FILE", "")
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data.update({
    "network": network,
    "contract_id": contract_id,
    "wasm_sha256": wasm,
    "previous_wasm_sha256": prev_wasm,
    "version": version,
    "schema_version": data.get("schema_version", 4),
    "status": status,
    "health": health,
    "canary": canary,
    "note": note,
    "commit_sha": commit,
    "workflow_run_url": run_url,
    "last_deploy_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
})

# Validate against the schema's required keys before writing, so a malformed
# status file can never be published.
required = []
if schema_path and os.path.exists(schema_path):
    try:
        with open(schema_path) as f:
            schema = json.load(f)
        required = list(schema.get("required", []))
    except (OSError, json.JSONDecodeError):
        required = []
missing = [k for k in required if k not in data]
if missing:
    sys.stderr.write(f"ERROR: staging status missing required keys {missing}; refusing to write {path}\n")
    sys.exit(1)

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(f"staging status -> {path}: {status}")
EOF
  else
    log "WARN: python3 unavailable; skipping machine-readable status update ($status/$health/$canary: $note)"
  fi
}

rollback() {
  # rollback <reason> — propose + execute the previous WASM, then re-verify health.
  local reason="$1"
  log "ROLLBACK TRIGGERED: $reason"
  if [ -z "$PREVIOUS_WASM" ]; then
    if [ "$ALLOW_NO_ROLLBACK" = true ]; then
      log "ERROR: no rollback coverage on this run (--allow-no-rollback); manual intervention required"
    else
      log "ERROR: no --previous-wasm configured; cannot roll back automatically"
    fi
    write_status "failed" "fail" "fail" "rollback unavailable: $reason"
    return 1
  fi
  log "Rolling back to $PREVIOUS_WASM ($PREVIOUS_WASM_HASH) via scripts/rollback.sh"
  if ! run bash "$SCRIPT_DIR/rollback.sh" --non-interactive \
      "$NETWORK" "$ADMIN_IDENTITY" "$CONTRACT_ID" "$PREVIOUS_WASM" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1; then
    log "ERROR: rollback execution failed"
    write_status "failed" "fail" "fail" "rollback failed after: $reason"
    return 1
  fi
  log "Rollback proposed/executed; re-running health checks to confirm restoration"
  if [ "$DRY_RUN" = false ]; then
    if bash "$SCRIPT_DIR/health_check.sh" "$NETWORK" "$CONTRACT_ID" "$HEALTH_SOURCE" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1; then
      log "Post-rollback health checks PASSED — prior state restored"
      write_status "rolled-back" "pass" "fail" "rolled back after: $reason"
    else
      log "ERROR: post-rollback health checks FAILED — manual intervention required"
      write_status "failed" "fail" "fail" "post-rollback unhealthy after: $reason"
      return 1
    fi
  else
    write_status "rolled-back" "fail" "fail" "dry-run rollback after: $reason"
  fi
  return 1
}

# ── Step 1: baseline health (fail closed on an already-unhealthy instance) ──
log "Step 1: baseline health check (pre-upgrade)"
if [ "$DRY_RUN" = false ]; then
  if ! bash "$SCRIPT_DIR/health_check.sh" "$NETWORK" "$CONTRACT_ID" "$HEALTH_SOURCE" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1; then
    die "baseline health check failed — refusing to deploy onto an unhealthy staging instance"
  fi
  BASELINE_VERSION="$(invoke get_version 2>/dev/null || echo 'unknown')"
  log "Baseline healthy (version=$BASELINE_VERSION)"
else
  log "[dry-run] bash scripts/health_check.sh $NETWORK $CONTRACT_ID $HEALTH_SOURCE"
fi

# ── Step 2: propose through the standard time-lock ──────────────────────────
log "Step 2: proposing upgrade (standard proposal flow)"
if ! PROPOSE_OUT="$(invoke propose_upgrade --admin-signers "[$ADMIN_ADDRESS]" --new-wasm-hash "$NEW_WASM_HASH" 2>&1)"; then
  echo "$PROPOSE_OUT" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1 || true
  die "propose_upgrade failed: $PROPOSE_OUT"
fi
echo "$PROPOSE_OUT" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1 || true
log "Proposal recorded"

# ── Step 3: wait for the executable window (bounded) ────────────────────────
if [ "$SKIP_DELAY_WAIT" = true ]; then
  log "Step 3: SKIPPED delay wait (rehearsal mode)"
else
  log "Step 3: polling get_pending_upgrade for executable_after (max ${MAX_WAIT_SECS}s)"
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] poll get_pending_upgrade until executable_after <= now"
  else
    DEADLINE=$(( $(date +%s) + MAX_WAIT_SECS ))
    while true; do
      PENDING="$(invoke get_pending_upgrade 2>/dev/null || echo 'PENDING_READ_FAILED')"
      log "Pending upgrade state: $PENDING"
      # The contract reports executable_after as a unix timestamp; proceed once reached.
      EXEC_AFTER="$(printf '%s' "$PENDING" | grep -Eo '[0-9]{9,}' | tail -n 1 || true)"
      NOW="$(date +%s)"
      if [ -n "$EXEC_AFTER" ] && [ "$EXEC_AFTER" -le "$NOW" ]; then
        log "Upgrade window reached (executable_after=$EXEC_AFTER <= now=$NOW)"
        break
      fi
      if [ "$NOW" -ge "$DEADLINE" ]; then
        # Only report proposed-pending when the delay genuinely has not elapsed.
        if [ -n "$EXEC_AFTER" ] && [ "$EXEC_AFTER" -gt "$NOW" ]; then
          log "Delay window not yet elapsed within ${MAX_WAIT_SECS}s — leaving proposal pending for the scheduled follow-up"
          write_status "proposed-pending" "pass" "pending" "awaiting executable_after; proposal recorded"
          exit 2
        fi
        # The delay has elapsed (or the pending state is unreadable): this run
        # cannot execute, so record a terminal failure instead of pending.
        log "ERROR: upgrade window elapsed but execute could not proceed (pending state: $PENDING)"
        write_status "failed" "fail" "fail" "executable window reached but execute_upgrade not run"
        exit 1
      fi
      sleep "$POLL_INTERVAL_SECS"
    done
  fi
fi

# ── Step 4: execute ─────────────────────────────────────────────────────────
log "Step 4: executing upgrade"
if [ "$NON_INTERACTIVE" = false ] && [ "$DRY_RUN" = false ]; then
  die "refusing to execute a staging upgrade interactively from CD; re-run with --non-interactive"
fi
if ! EXEC_OUT="$(invoke execute_upgrade --admin-signers "[$ADMIN_ADDRESS]" 2>&1)"; then
  echo "$EXEC_OUT" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1 || true
  # rollback() writes rolled-back on successful restoration, failed otherwise.
  rollback "execute_upgrade failed: $EXEC_OUT"
  exit 1
fi
echo "$EXEC_OUT" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1 || true
log "Upgrade executed"

# ── Step 5: post-deploy verification (health + canary) ─────────────────────
log "Step 5: post-deploy health check"
if [ "$DRY_RUN" = false ]; then
  # Deliberately broken changes are exercised here in rehearsal via
  # STAGING_SMOKE_FAIL=1 (see scripts/test-staging-deploy.sh): the failure
  # must trigger the rollback path below, never a silent success.
  if [ "${STAGING_SMOKE_FAIL:-0}" = "1" ]; then
    log "STAGING_SMOKE_FAIL=1 — simulating post-deploy verification failure"
    rollback "simulated verification failure (STAGING_SMOKE_FAIL=1)"
    exit 1
  fi
  if ! bash "$SCRIPT_DIR/health_check.sh" "$NETWORK" "$CONTRACT_ID" "$HEALTH_SOURCE" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1; then
    rollback "post-deploy health check failed"
    exit 1
  fi
  log "Health checks passed"
  log "Step 6: canary verification (verify-deployment.sh)"
  if ! bash "$SCRIPT_DIR/verify-deployment.sh" "$NETWORK" "$CONTRACT_ID" "$ADMIN_IDENTITY" >>"$EVIDENCE_DIR/staging-upgrade.log" 2>&1; then
    rollback "post-deploy canary verification failed"
    exit 1
  fi
  log "Canary verification passed"
  write_status "deployed" "pass" "pass" "upgrade verified on staging"
else
  log "[dry-run] bash scripts/health_check.sh $NETWORK $CONTRACT_ID $HEALTH_SOURCE"
  log "[dry-run] bash scripts/verify-deployment.sh $NETWORK $CONTRACT_ID $ADMIN_IDENTITY"
  write_status "deployed" "pass" "pass" "dry-run"
fi

log "── Staging upgrade complete and verified ──"
