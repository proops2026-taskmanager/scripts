#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 <hostname>" >&2
  exit 2
}

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2; }
die() { err "$@"; exit 1; }

preflight() {
  for cmd in curl ping; do
    command -v "$cmd" >/dev/null || die "missing required tool: $cmd"
  done
}

check_ping() {
  local host="$1"
  if ping -c 1 -t 3 "$host" >/dev/null 2>&1; then
    log "ping OK: $host"
  else
    err "ping FAILED: $host"
    return 1
  fi
}

check_http() {
  local host="$1"
  local status
  status=$(curl -sS --max-time 5 -o /dev/null -w "%{http_code}" "http://${host}/health")
  if [[ "$status" == "200" ]]; then
    log "http OK: $host returned $status"
  else
    err "http FAILED: $host returned $status"
    return 1
  fi
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
  fi
  local host="$1"

  preflight
  check_ping "$host"
  check_http "$host"
  log "all checks passed for $host"
}

main "$@"
