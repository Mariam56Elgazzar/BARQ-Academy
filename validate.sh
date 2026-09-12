#!/usr/bin/env bash
#
# validate.sh — BARQ DevOps Internship Task, Part 3
# Validates public access, all required endpoints, backend identities,
# PostgreSQL/Redis readiness, and network isolation.
# Exits 0 on PASS, non-zero on any FAIL.

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-30}"
POLL_INTERVAL=2
FAILURES=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILURES=$((FAILURES + 1)); }

wait_for_ready() {
    local url="$1"
    local elapsed=0
    while [ "$elapsed" -lt "$MAX_WAIT_SECONDS" ]; do
        if curl -fsS -o /dev/null "$url"; then
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    return 1
}

echo "=== 1. Waiting for public endpoint to become reachable (bounded wait, ${MAX_WAIT_SECONDS}s) ==="
if wait_for_ready "$BASE_URL/health"; then
    pass "Public endpoint reachable within ${MAX_WAIT_SECONDS}s"
else
    fail "Public endpoint did not become reachable within ${MAX_WAIT_SECONDS}s"
fi

echo "=== 2. Checking required endpoints ==="
check_endpoint() {
    local path="$1"
    local expected_status="$2"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL$path")
    if [ "$status" = "$expected_status" ]; then
        pass "$path returned $status"
    else
        fail "$path returned $status (expected $expected_status)"
    fi
}

check_endpoint "/" "200"
check_endpoint "/health" "200"
check_endpoint "/ready" "200"
check_endpoint "/instance" "200"

echo "=== 3. Checking PostgreSQL + Redis readiness via /ready payload ==="
ready_body=$(curl -fsS "$BASE_URL/ready" 2>/dev/null || echo "{}")
if echo "$ready_body" | grep -q '"postgres":"ready"'; then
    pass "PostgreSQL reported ready"
else
    fail "PostgreSQL not reported ready: $ready_body"
fi
if echo "$ready_body" | grep -q '"redis":"ready"'; then
    pass "Redis reported ready"
else
    fail "Redis not reported ready: $ready_body"
fi

echo "=== 4. Confirming both backend instances serve traffic (avoids double-counting) ==="
declare -A seen_instances
SAMPLE_SIZE=20
for _ in $(seq 1 "$SAMPLE_SIZE"); do
    instance_id=$(curl -fsS "$BASE_URL/instance" 2>/dev/null | grep -o '"instance_id":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$instance_id" ]; then
        seen_instances["$instance_id"]=$((${seen_instances["$instance_id"]:-0} + 1))
    fi
done
echo "Distribution over $SAMPLE_SIZE requests:"
for id in "${!seen_instances[@]}"; do
    echo "  $id: ${seen_instances[$id]}"
done
if [ "${#seen_instances[@]}" -ge 2 ]; then
    pass "Both backend instances served at least one request in a $SAMPLE_SIZE-request sample"
else
    fail "Only ${#seen_instances[@]} distinct backend instance(s) observed in $SAMPLE_SIZE requests"
fi

echo "=== 5. Checking /records create + list (real DB operation) ==="
create_status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/records" \
    -H "Content-Type: application/json" \
    -d '{"title":"validate-sh-test-record"}')
if [ "$create_status" = "200" ] || [ "$create_status" = "201" ]; then
    pass "/records POST returned $create_status"
else
    fail "/records POST returned $create_status"
fi
list_status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/records")
if [ "$list_status" = "200" ]; then
    pass "/records GET returned $list_status"
else
    fail "/records GET returned $list_status"
fi

echo "=== 6. Checking /counter (real Redis operation) ==="
counter_body_1=$(curl -fsS "$BASE_URL/counter" 2>/dev/null || echo "{}")
counter_body_2=$(curl -fsS "$BASE_URL/counter" 2>/dev/null || echo "{}")
if [ "$counter_body_1" != "$counter_body_2" ]; then
    pass "/counter value changed between calls (real Redis increment): $counter_body_1 -> $counter_body_2"
else
    fail "/counter value did not change between calls: $counter_body_1"
fi

echo "=== 7. Checking network isolation: prohibited host ports ==="
pg_ports=$(docker inspect postgres --format '{{json .NetworkSettings.Ports}}' 2>/dev/null)
if echo "$pg_ports" | grep -q '"HostPort"'; then
    fail "PostgreSQL port is published to host: $pg_ports"
else
    pass "PostgreSQL is correctly not published to host"
fi

redis_ports=$(docker inspect redis --format '{{json .NetworkSettings.Ports}}' 2>/dev/null)
if echo "$redis_ports" | grep -q '"HostPort"'; then
    fail "Redis port is published to host: $redis_ports"
else
    pass "Redis is correctly not published to host"
fi

echo ""
echo "=== SUMMARY ==="
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
    exit 0
else
    echo "$FAILURES CHECK(S) FAILED"
    exit 1
fi
