#!/usr/bin/env bash
# Full-stack smoke test: register → login → create task → list tasks
# Runs through api-gateway (ELB). Never calls internal services directly.
# Exits 0 on pass, 1 on any failure.
#
# Usage:
#   BASE_URL=http://<elb-hostname> bash full-api.sh
#   BASE_URL=http://localhost:8080  bash full-api.sh   (local dev)

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
# Unique email per run — prevents duplicate-email failures when re-running against the same DB
TS=$(date +%s)
EMAIL="smoke-${TS}@test.com"
PASSWORD="Smoke1234!"
FULL_NAME="Smoke CI User"

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

# ── 1. Health ─────────────────────────────────────────────────────────────────
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "${BASE_URL}/health")
[ "$STATUS" = "200" ] && pass "GET /health → 200" || fail "GET /health → ${STATUS}"

# ── 2. Register ───────────────────────────────────────────────────────────────
REG_BODY=$(curl -sf -X POST "${BASE_URL}/api/users" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\",\"full_name\":\"${FULL_NAME}\",\"role\":\"lead\"}")
REG_ID=$(printf '%s' "$REG_BODY" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
[ -n "$REG_ID" ] && pass "POST /api/users → 201 id=${REG_ID}" || fail "POST /api/users → no id: ${REG_BODY}"

# ── 3. Login ──────────────────────────────────────────────────────────────────
LOGIN_BODY=$(curl -sf -X POST "${BASE_URL}/api/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")
TOKEN=$(printf '%s' "$LOGIN_BODY" | grep -o '"token":"[^"]*"' | sed 's/"token":"//;s/"//')
[ -n "$TOKEN" ] && pass "POST /api/auth/login → token issued" || fail "POST /api/auth/login → no token: ${LOGIN_BODY}"

# ── 4. Create task ────────────────────────────────────────────────────────────
TASK_BODY=$(curl -sf -X POST "${BASE_URL}/api/tasks" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -d "{\"title\":\"Smoke ${TS}\",\"description\":\"CI smoke test\",\"due_date\":\"2026-12-31T00:00:00.000Z\"}")
TASK_ID=$(printf '%s' "$TASK_BODY" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
[ -n "$TASK_ID" ] && pass "POST /api/tasks → id=${TASK_ID}" || fail "POST /api/tasks → no id: ${TASK_BODY}"

# ── 5. List tasks — verify the created task appears ──────────────────────────
LIST=$(curl -sf "${BASE_URL}/api/tasks" -H "Authorization: Bearer ${TOKEN}")
printf '%s' "$LIST" | grep -q "\"id\":\"${TASK_ID}\"" \
  && pass "GET /api/tasks → task ${TASK_ID} present" \
  || fail "GET /api/tasks → task ${TASK_ID} not found in list"

printf '\nSmoke passed ✓ — health + register + login + create-task + list-tasks\n'
