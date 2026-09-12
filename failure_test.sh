#!/usr/bin/env bash
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
TARGET_CONTAINER="${TARGET_CONTAINER:-app-01}"
MAX_RECOVERY_WAIT="${MAX_RECOVERY_WAIT:-30}"
POLL_INTERVAL=2
FAILURES=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILURES=$((FAILURES + 1)); }
info() { echo "[INFO] $1"; }

sample_instances() {
    local n="$1"
    local -A counts
    local ok=0
    local errors=0
    for _ in $(seq 1 "$n"); do
        local status
        status=$(curl -s -o /tmp/failtest_body -w "%{http_code}" --max-time 3 "$BASE_URL/instance")
        if [ "$status" = "200" ]; then
            ok=$((ok + 1))
            local id
            id=$(grep -o '"instance_id":"[^"]*"' /tmp/failtest_body | cut -d'"' -f4)
            [ -n "$id" ] && counts["$id"]=$((${counts["$id"]:-0} + 1))
        else
            errors=$((errors + 1))
        fi
    done
    echo "ok=$ok errors=$errors"
    for id in "${!counts[@]}"; do
        echo "  $id: ${counts[$id]}"
    done
}

echo "=== 1. Baseline: confirm both backends serve traffic before the failure ==="
baseline=$(sample_instances 10)
echo "$baseline"
baseline_distinct=$(echo "$baseline" | grep -c "^  app-")
if [ "$baseline_distinct" -ge 2 ]; then
    pass "Baseline shows both backends responding"
else
    fail "Baseline did NOT show both backends responding — aborting test, fix environment first"
    exit 1
fi

echo ""
echo "=== 2. Stopping $TARGET_CONTAINER to simulate a backend failure ==="
if docker stop "$TARGET_CONTAINER" >/dev/null 2>&1; then
    pass "$TARGET_CONTAINER stopped"
else
    fail "Could not stop $TARGET_CONTAINER"
    exit 1
fi

echo ""
echo "=== 3. Measuring traffic and errors DURING the outage ==="
sleep 1
during=$(sample_instances 10)
echo "$during"
during_ok=$(echo "$during" | grep -o 'ok=[0-9]*' | cut -d= -f2)
during_errors=$(echo "$during" | grep -o 'errors=[0-9]*' | cut -d= -f2)
during_has_stopped_instance=$(echo "$during" | grep -c "^  $TARGET_CONTAINER:")

if [ "$during_ok" -gt 0 ]; then
    pass "Service remained available during outage ($during_ok/10 requests succeeded)"
else
    fail "Service was completely unavailable during outage (0/10 succeeded)"
fi

if [ "$during_has_stopped_instance" -eq 0 ]; then
    pass "Stopped instance ($TARGET_CONTAINER) correctly did not serve any requests during outage"
else
    fail "Stopped instance ($TARGET_CONTAINER) still appeared in responses — outage not real or NGINX misrouted"
fi

info "Errors observed during outage: $during_errors/10 (expected: some transient errors are acceptable while NGINX detects the failure)"

echo ""
echo "=== 4. Restoring $TARGET_CONTAINER ==="
if docker start "$TARGET_CONTAINER" >/dev/null 2>&1; then
    pass "$TARGET_CONTAINER restart command issued"
else
    fail "Could not restart $TARGET_CONTAINER"
    exit 1
fi

echo ""
echo "=== 5. Waiting for $TARGET_CONTAINER to become healthy again (bounded wait, ${MAX_RECOVERY_WAIT}s) ==="
elapsed=0
recovered=0
while [ "$elapsed" -lt "$MAX_RECOVERY_WAIT" ]; do
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "$TARGET_CONTAINER" 2>/dev/null || echo "unknown")
    if [ "$health_status" = "healthy" ]; then
        recovered=1
        break
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
done

if [ "$recovered" -eq 1 ]; then
    pass "$TARGET_CONTAINER reported healthy after ${elapsed}s"
else
    fail "$TARGET_CONTAINER did not become healthy within ${MAX_RECOVERY_WAIT}s"
fi

echo ""
echo "=== 6. Proving recovery: confirming BOTH backends serve traffic again ==="
sleep 2
recovery=$(sample_instances 10)
echo "$recovery"
recovery_distinct=$(echo "$recovery" | grep -c "^  app-")
recovery_has_target=$(echo "$recovery" | grep -c "^  $TARGET_CONTAINER:")

if [ "$recovery_distinct" -ge 2 ] && [ "$recovery_has_target" -ge 1 ]; then
    pass "Both backends serving traffic again; $TARGET_CONTAINER confirmed recovered"
else
    fail "Recovery not proven — $TARGET_CONTAINER did not reappear in post-recovery sample"
fi

echo ""
echo "=== SUMMARY ==="
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL CHECKS PASSED — failure and recovery behavior verified"
    exit 0
else
    echo "$FAILURES CHECK(S) FAILED"
    exit 1
fi
