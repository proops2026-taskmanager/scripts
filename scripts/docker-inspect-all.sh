#!/usr/bin/env bash
# docker-inspect-all.sh
# Single-pass snapshot: status + health + memory for every container (running or stopped).
# Usage: ./docker-inspect-all.sh
#        ./docker-inspect-all.sh --watch   (refresh every 5s like watch)

set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin"

WATCH_MODE=0
[[ "${1:-}" == "--watch" ]] && WATCH_MODE=1

RED='\033[0;31m'; NC='\033[0m'

snapshot() {
    local alert_count=0

    printf '\n=== Container Snapshot  %s ===\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%-45s %-10s %-12s %s\n' "NAME" "STATUS" "HEALTH" "MEMORY"
    printf '%-45s %-10s %-12s %s\n' "----" "------" "------" "------"

    # -aq + label filter: all containers (running + stopped/killed) scoped to this
    # compose project only — without -a a killed container vanishes from the list.
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue

        # docker inspect returns JSON — --format extracts specific fields
        name=$(docker inspect --format '{{.Name}}' "$id" | sed 's|/||')
        status=$(docker inspect --format '{{.State.Status}}' "$id")

        # Health is optional — not all containers define a HEALTHCHECK
        health=$(docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "$id")

        # docker stats only works on running containers; show n/a for stopped ones
        if [[ "$status" == "running" ]]; then
            mem=$(docker stats --no-stream --format "{{.MemUsage}}" "$id" 2>/dev/null || echo "n/a")
        else
            mem="n/a"
        fi

        # Flag anything not running or explicitly unhealthy
        if [[ "$status" != "running" || "$health" == "unhealthy" ]]; then
            printf "${RED}%-45s %-10s %-12s %s  ← ALERT${NC}\n" \
                "$name" "$status" "$health" "$mem"
            alert_count=$(( alert_count + 1 ))

            # Print the last 3 health check log entries for containers that have
            # a HEALTHCHECK defined (health != "—"). Each entry's Output field
            # is the raw stdout of the probe command — first line only to stay compact.
            if [[ "$health" != "—" ]]; then
                docker inspect --format '{{json .State.Health.Log}}' "$id" 2>/dev/null \
                    | python3 -c "
import json, sys
logs = json.load(sys.stdin)
for e in logs[-3:]:
    line = e.get('Output', '').strip().split('\n')[0]
    if line:
        print('    └─', line)
" 2>/dev/null || true
            fi
        else
            printf '%-45s %-10s %-12s %s\n' "$name" "$status" "$health" "$mem"
        fi

    done < <(docker ps -aq --filter "label=com.docker.compose.project=proops2026-taskmanager")

    printf '\n--- %d container(s) need attention ---\n\n' "$alert_count"
    return "$alert_count"
}

if [[ $WATCH_MODE -eq 1 ]]; then
    while true; do
        printf '\033[2J\033[H'  # clear screen + cursor home — works without TERM set
        snapshot || true        # || true: don't exit when alert_count > 0 returns non-zero
        sleep 5
    done
else
    snapshot || true
fi
