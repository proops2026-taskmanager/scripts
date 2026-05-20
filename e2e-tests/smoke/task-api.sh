#!/usr/bin/env bash
# shellcheck shell=bash
# Smoke test: task-service create → list → delete
# Exits 0 on pass, 1 on any failure.
# Usage: BASE_URL=http://localhost:3002 ./task-api.sh

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3002}"
USER_ID="11111111-1111-1111-1111-111111111111"
ASSIGNEE_ID="33333333-3333-3333-3333-333333333333"

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

# ── 1. Health check ───────────────────────────────────────────────────────────
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "${BASE_URL}/health")
if [ "$STATUS" = "200" ]; then
  pass "GET /health → 200"
else
  fail "GET /health → ${STATUS}"
fi

# ── 2. Create task ────────────────────────────────────────────────────────────
BODY=$(curl -sf -X POST "${BASE_URL}/tasks" \
  -H "Content-Type: application/json" \
  -H "X-User-Id: ${USER_ID}" \
  -d "{
    \"title\": \"CI smoke task\",
    \"description\": \"Created by task-api.sh smoke test\",
    \"assignee_id\": \"${ASSIGNEE_ID}\",
    \"due_date\": \"2026-12-31T00:00:00.000Z\"
  }")

TASK_ID=$(printf '%s' "$BODY" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -n "$TASK_ID" ]; then
  pass "POST /tasks → id=${TASK_ID}"
else
  fail "POST /tasks — no id in response: ${BODY}"
fi

# ── 3. List tasks — verify created task is present ───────────────────────────
LIST=$(curl -sf "${BASE_URL}/tasks" -H "X-User-Id: ${USER_ID}")
if printf '%s' "$LIST" | grep -q "\"id\":${TASK_ID}"; then
  pass "GET /tasks → task ${TASK_ID} present"
else
  fail "GET /tasks — task ${TASK_ID} not found in list"
fi

# ── 4. Delete task ────────────────────────────────────────────────────────────
DEL_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" -X DELETE \
  "${BASE_URL}/tasks/${TASK_ID}" \
  -H "X-User-Id: ${USER_ID}")
if [ "$DEL_STATUS" = "204" ]; then
  pass "DELETE /tasks/${TASK_ID} → 204"
else
  fail "DELETE /tasks/${TASK_ID} → ${DEL_STATUS}"
fi

# ── 5. Verify gone ────────────────────────────────────────────────────────────
AFTER=$(curl -sf "${BASE_URL}/tasks" -H "X-User-Id: ${USER_ID}")
if printf '%s' "$AFTER" | grep -q "\"id\":${TASK_ID}"; then
  fail "GET /tasks — task ${TASK_ID} still present after delete"
else
  pass "GET /tasks → task ${TASK_ID} gone after delete"
fi

printf '\nSmoke passed: health + create + list + delete + verify-gone\n'
