#!/usr/bin/env bash
# api-health-sweep.sh
# Checks all taskmanager endpoints in one pass — exits 1 if any fail.
# Usage: ./api-health-sweep.sh
#        GATEWAY=http://1.2.3.4:8080 ./api-health-sweep.sh   (override for EC2)

set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"

# --- Config: name → URL ---
# Change these to your EC2 IP when testing against AWS.
GATEWAY="${GATEWAY:-http://localhost:8080}"
USER_SVC="${USER_SVC:-http://localhost:3001}"
TASK_SVC="${TASK_SVC:-http://localhost:3002}"
FRONTEND="${FRONTEND:-http://localhost:3000}"

# Bash "dictionary": parallel arrays (names and URLs at same index)
NAMES=("api-gateway"   "user-service"  "task-service"  "frontend")
URLS=("$GATEWAY/health" "$USER_SVC/health" "$TASK_SVC/health" "$FRONTEND")

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0

# --- check_endpoint: reusable function, called in a loop ---
check_endpoint() {
    local name="$1" url="$2" raw status time_s time_ms

    # -w with two tokens: http_code and time_total (float seconds, e.g. "0.043")
    # Both land in one string separated by a space: "200 0.043"
    raw=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --max-time 5 "$url" || true)
    status="${raw%% *}"          # strip everything from first space onwards → http code
    time_s="${raw##* }"          # strip everything up to last space → float seconds
    status="${status:-000}"

    # Convert seconds to milliseconds — bash can't do float math, so use awk
    time_ms=$(awk "BEGIN{printf \"%.0f\", ${time_s:-0} * 1000}" 2>/dev/null || echo "?")

    if [[ "$status" == "200" ]]; then
        printf "${GREEN}[OK  ]${NC} %-20s %s  %sms\n" "$name" "$status" "$time_ms"
        PASS=$(( PASS + 1 ))
    else
        printf "${RED}[FAIL]${NC} %-20s %s  ← investigate\n" "$name" "$status"
        FAIL=$(( FAIL + 1 ))
    fi
}

# --- Main: loop over the arrays ---
printf '\n=== API Health Sweep  %s ===\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for i in "${!NAMES[@]}"; do          # iterate by index
    check_endpoint "${NAMES[$i]}" "${URLS[$i]}"
done

printf '\n--- %d passed  %d failed ---\n\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1          # non-zero exit = CI pipeline fails the job
# path-routing test — app change only
