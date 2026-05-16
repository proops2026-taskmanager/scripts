#!/bin/bash
# session-sync-hook.sh — Stop hook: emit one signal per session when chautv_devops
# has commits ahead of main. Stays silent otherwise.
# Called automatically by Claude Code Stop hook. Never source this.
set -euo pipefail

# ── stdout / stderr helpers ──────────────────────────────────────────────────
log() { echo "[SESSION-SYNC] $*"; }
err() { echo "[SESSION-SYNC] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ── config ───────────────────────────────────────────────────────────────────
REPO_ROOT="/Users/mac/Desktop/proops2026-taskmanager"
BRANCH="chautv_devops"
MAIN="main"
FLAG_FILE="$REPO_ROOT/.session-synced"
SESSION_HOURS=8  # flag auto-expires after 8h (one work session)

# ── PATH preflight ───────────────────────────────────────────────────────────
for cmd in git date; do
  command -v "$cmd" >/dev/null || die "missing required tool: $cmd"
done

# ── guard: session already synced? ───────────────────────────────────────────
if [[ -f "$FLAG_FILE" ]]; then
  flag_ts=$(cat "$FLAG_FILE" 2>/dev/null || echo 0)
  now_ts=$(date +%s)
  age=$(( now_ts - flag_ts ))
  [[ $age -lt $(( SESSION_HOURS * 3600 )) ]] && exit 0
  # expired — remove stale flag so next check can fire
  rm -f "$FLAG_FILE"
fi

# ── guard: branch must exist ─────────────────────────────────────────────────
if ! git -C "$REPO_ROOT" rev-parse --verify "$BRANCH" &>/dev/null; then
  exit 0  # branch not created yet — user runs session-sync.sh setup first
fi

# ── guard: must have commits ahead of main ────────────────────────────────────
AHEAD=$(git -C "$REPO_ROOT" rev-list "${MAIN}..${BRANCH}" --count 2>/dev/null || echo 0)
[[ "$AHEAD" -eq 0 ]] && exit 0

# ── also check for uncommitted changes on chautv_devops ──────────────────────
DIRTY=""
if [[ "$(git -C "$REPO_ROOT" branch --show-current)" == "$BRANCH" ]]; then
  if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || \
     ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
    DIRTY=" (+ uncommitted changes)"
  fi
fi

# ── emit signal ──────────────────────────────────────────────────────────────
log ""
log "Branch '$BRANCH' has ${AHEAD} commit(s) ahead of main${DIRTY}."
log "Latest commits to merge:"
git -C "$REPO_ROOT" log "${MAIN}..${BRANCH}" --oneline 2>/dev/null | head -5 | sed 's/^/  /'
log ""
log "Run \`bash scripts/session-sync.sh status\` to review, or"
log "tell Claude: 'sync session' to start the merge + push flow."
