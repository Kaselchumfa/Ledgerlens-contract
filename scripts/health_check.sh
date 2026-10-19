#!/usr/bin/env bash
# Read-only health check for a deployed ledgerlens-score contract instance.
#
# Runs only view calls (get_admin, get_service, is_paused, get_version,
# is_service_alive, get_pending_upgrade) — no state-changing invocation is
# ever issued, so this is safe to run against production at any time.
#
# Usage:
#   ./scripts/health_check.sh <network> <contract-id> [source-identity]
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed (contract likely unhealthy or unreachable)

set -euo pipefail

NETWORK="${1:?ERROR: network argument is required (e.g. testnet, mainnet)}"
CONTRACT_ID="${2:?ERROR: contract-id argument is required}"
SOURCE_IDENTITY="${3:-health-check}"

FAILURES=0

# Bounded retry policy for view calls: transient RPC failures should not fail
# the whole verification (and trigger an unnecessary rollback), so each call is
# retried a small number of times with a short linear backoff.
MAX_ATTEMPTS="${HEALTH_CHECK_MAX_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${HEALTH_CHECK_RETRY_DELAY:-2}"

invoke() {
  soroban contract invoke \
    --id "$CONTRACT_ID" \
    --source "$SOURCE_IDENTITY" \
    --network "$NETWORK" \
    -- \
    "$@"
}

# Runs a command up to MAX_ATTEMPTS times, sleeping RETRY_DELAY_SECONDS between
# attempts. On success, sets RETRY_OUTPUT to the command output and
# RETRY_ATTEMPTS to the number of attempts used, and returns 0. On exhaustion,
# sets RETRY_OUTPUT to the last error output and returns 1.
retry() {
  local attempt=1
  RETRY_ATTEMPTS=0
  RETRY_OUTPUT=""
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    RETRY_ATTEMPTS=$attempt
    if RETRY_OUTPUT=$("$@" 2>&1); then
      return 0
    fi
    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
      sleep "$RETRY_DELAY_SECONDS"
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

check() {
  local label="$1"
  shift
  if retry "$@"; then
    echo "PASS  $label: $RETRY_OUTPUT (attempts: $RETRY_ATTEMPTS/$MAX_ATTEMPTS)"
  else
    echo "FAIL  $label: $RETRY_OUTPUT (attempts: $RETRY_ATTEMPTS/$MAX_ATTEMPTS)"
    FAILURES=$((FAILURES + 1))
  fi
}

echo "== ledgerlens-score health check: $CONTRACT_ID on $NETWORK =="

check "admin address"    invoke get_admin
check "service address"  invoke get_service
check "pause state"      invoke is_paused
check "schema version"   invoke get_version
check "service liveness" invoke is_service_alive

# A pending upgrade proposal is optional state: its absence (Error::NoPendingUpgrade,
# discriminant #13) is healthy, not a failure — only a genuine RPC/contract error is.
if retry invoke get_pending_upgrade; then
  echo "INFO  pending upgrade: $RETRY_OUTPUT (attempts: $RETRY_ATTEMPTS/$MAX_ATTEMPTS)"
else
  case "$RETRY_OUTPUT" in
    *NoPendingUpgrade*|*'#13'*)
      echo "PASS  pending upgrade: none (attempts: $RETRY_ATTEMPTS/$MAX_ATTEMPTS)"
      ;;
    *)
      echo "FAIL  pending upgrade: $RETRY_OUTPUT (attempts: $RETRY_ATTEMPTS/$MAX_ATTEMPTS)"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
fi

echo "== $FAILURES check(s) failed =="
[ "$FAILURES" -eq 0 ]
