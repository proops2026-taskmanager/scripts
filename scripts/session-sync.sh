#!/bin/bash
# session-sync.sh — Interactive end-of-session merge: chautv_devops → main → push
#
# Usage: session-sync.sh <command>
#   setup      Create chautv_devops branch from main (first-time, each new project)
#   status     Show commits and files pending merge to main
#   merge      Squash-merge chautv_devops into main (stages changes, no auto-commit)
#   push       Push main to origin/main
#   mark-done  Write session flag — hook stays silent for 8h
#
# Flow: setup → work on chautv_devops → status → merge → commit → push → mark-done
#
# IRD-30: Squash merge keeps main history linear (one commit per session).
# IRD-19: set -euo pipefail, [[ ]], log/err/die, PATH preflight, domain fns.
set -euo pipefail

# ── stdout / stderr helpers ──────────────────────────────────────────────────
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
err() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

# ── usage ────────────────────────────────────────────────────────────────────
usage() {
  cat >&2 <<'EOF'
Usage: session-sync.sh <command>

Commands:
  setup      Create chautv_devops branch from main (run once per clone)
  status     Show commits and files pending merge from chautv_devops → main
  merge      Squash-merge chautv_devops into main and stage the result
  push       Push main to origin (call after committing the merge)
  mark-done  Mark session as synced — suppresses hook for 8 hours

Typical end-of-session flow:
  1. bash scripts/session-sync.sh status       # review what will merge
  2. git checkout main                          # switch to main
  3. bash scripts/session-sync.sh merge        # squash-merge staged
  4. git commit -m "feat(scope): description"  # commit with conventional format
  5. bash scripts/session-sync.sh push         # push + mark done
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage

# ── config ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "Not inside a git repository. cd into proops2026-taskmanager first."
BRANCH="chautv_devops"
MAIN="main"
REMOTE="origin"
FLAG_FILE="$REPO_ROOT/.session-synced"

# ── PATH preflight ───────────────────────────────────────────────────────────
command -v git >/dev/null || die "missing required tool: git"

# ── domain functions ─────────────────────────────────────────────────────────
branch_exists() {
  git rev-parse --verify "$1" &>/dev/null
}

require_branch() {
  branch_exists "$BRANCH" \
    || die "Branch '$BRANCH' not found. Run: bash scripts/session-sync.sh setup"
}

require_on_main() {
  local current
  current="$(git branch --show-current)"
  [[ "$current" == "$MAIN" ]] \
    || die "Must be on '$MAIN' branch (currently on '$current'). Run: git checkout $MAIN"
}

commits_ahead() {
  git rev-list "${MAIN}..${BRANCH}" --count 2>/dev/null || echo 0
}

# ── commands ─────────────────────────────────────────────────────────────────
cmd_setup() {
  if branch_exists "$BRANCH"; then
    log "Branch '$BRANCH' already exists."
    log "Switching to it now:"
    git checkout "$BRANCH"
    if git log "${MAIN}..${BRANCH}" --oneline 2>/dev/null | head -5; then
      log "↑ commits ahead of main (not yet merged)"
    else
      log "(no commits ahead of main yet — start working!)"
    fi
  else
    log "Creating '$BRANCH' from '$MAIN'..."
    git checkout "$MAIN"
    git pull "$REMOTE" "$MAIN" 2>/dev/null || true
    git checkout -b "$BRANCH"
    log ""
    log "✓ Now on '$BRANCH'. This is your LOCAL practice branch."
    log "  Work here during training sessions — experiment freely."
    log "  At session end: bash scripts/session-sync.sh status → merge → push"
    log ""
    log "Branch strategy (IRD-30):"
    log "  chautv_devops  ← local practice (never pushed)"
    log "  main           ← clean, team-visible, CI-ready (pushed to GitHub)"
  fi
}

cmd_status() {
  require_branch
  local ahead behind
  ahead=$(commits_ahead)
  behind=$(git rev-list "${BRANCH}..${MAIN}" --count 2>/dev/null || echo 0)

  log "Branch status: '$BRANCH' vs '$MAIN'"
  log "  Commits ahead  (to merge → main): $ahead"
  log "  Commits behind (main has new):    $behind"

  if [[ "$ahead" -gt 0 ]]; then
    log ""
    log "Commits that will merge to main:"
    git log "${MAIN}..${BRANCH}" --oneline | sed 's/^/  /'
    log ""
    log "Files changed:"
    git diff --stat "${MAIN}..${BRANCH}"
    log ""
    if [[ "$behind" -gt 0 ]]; then
      log "⚠  main has $behind commit(s) '$BRANCH' doesn't have."
      log "   Consider: git checkout $BRANCH && git rebase $MAIN first."
    fi
  else
    log ""
    log "Nothing to merge — '$BRANCH' is up to date with '$MAIN'."
  fi
}

cmd_merge() {
  require_branch
  require_on_main

  local ahead
  ahead=$(commits_ahead)
  [[ "$ahead" -gt 0 ]] || die "Nothing to merge — '$BRANCH' is already in '$MAIN'."

  log "Squash-merging '$BRANCH' → '$MAIN' ($ahead commit(s))..."
  log "(Squash keeps main history linear — one commit per session, per IRD-30)"
  log ""

  # Squash merge: collapses all chautv_devops commits into staged changes
  # Does NOT auto-commit — user provides the conventional commit message
  if git merge --squash "$BRANCH" 2>&1; then
    log "✓ Merge staged successfully. Staged changes:"
    git diff --cached --stat
    log ""
    log "Next step — commit with Conventional Commits format:"
    log "  git commit -m \"feat(scope): describe what this session added\""
    log ""
    log "Then push:"
    log "  bash scripts/session-sync.sh push"
  else
    log ""
    err "Merge conflicts detected in these files:"
    git diff --name-only --diff-filter=U | sed 's/^/  /'
    log ""
    log "To resolve:"
    log "  1. Open each conflicted file — look for <<<<<<< / ======= / >>>>>>>"
    log "  2. Edit to keep the correct version"
    log "  3. git add <resolved-file>"
    log "  4. Repeat for all conflicts"
    log "  5. git commit -m \"fix(merge): resolve conflicts from chautv_devops\""
    log "  6. bash scripts/session-sync.sh push"
    exit 1
  fi
}

cmd_push() {
  require_on_main

  # Guard: must have at least one commit staged or already committed
  local status
  status="$(git status --porcelain)"
  if [[ -n "$status" ]]; then
    die "Uncommitted changes found. Commit first:\n  git commit -m \"feat(scope): ...\""
  fi

  log "Pushing '$MAIN' → $REMOTE/$MAIN ..."
  git push "$REMOTE" "$MAIN"
  log ""
  log "✓ Push complete."
  log ""
  cmd_mark_done
}

cmd_mark_done() {
  date +%s > "$FLAG_FILE"
  log "✓ Session marked as synced. Hook will stay silent for 8 hours."
  log "  To re-enable: rm $FLAG_FILE"
}

# ── dispatcher ───────────────────────────────────────────────────────────────
case "$1" in
  setup)     cmd_setup ;;
  status)    cmd_status ;;
  merge)     cmd_merge ;;
  push)      cmd_push ;;
  mark-done) cmd_mark_done ;;
  *)         usage ;;
esac
