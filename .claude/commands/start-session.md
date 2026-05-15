# /start-session — Begin a Task Manager Session (Parallel)

Run this at the start of every session. Spawns three sub-agents simultaneously
so context is fully loaded in ~15 seconds instead of ~60 seconds sequentially.

---

## Execution Model

**Do not read files yourself. Spawn all three agents in a single message
with `run_in_background: true`. Wait for all three to return, then merge.**

---

## Step 1 — Spawn Three Parallel Agents

Send one message containing all three Agent tool calls at once:

### Agent A — Hub Identity + Skill Ledger Check
```
subagent_type: Explore
run_in_background: true
prompt: |
  Read these two files and report back — nothing else, no tool calls beyond Read:

  1. /Users/mac/Desktop/chautv-proops2026/CLAUDE.md
     Extract: identity summary (2 sentences), operating persona, NEVER rules.

  2. /Users/mac/Desktop/chautv-proops2026/memory/skills-ledger.md
     Scan every line for a #new tag.
     Report: "CLEAN" if none found, or list skill names that have #new.

  Return format:
    HUB_IDENTITY: [2-sentence summary]
    SKILLS_LEDGER: [CLEAN | list of #new skill names]
```

### Agent B — Project State
```
subagent_type: Explore
run_in_background: true
prompt: |
  Read these two files and report back — nothing else, no tool calls beyond Read:

  1. /Users/mac/Desktop/proops2026-taskmanager/docs/WIP.md
     Extract:
       - Last updated date
       - Sprint Phase table: every row and its status
       - Known Gaps table: open gaps only (not ✅ closed)
       - Next Session Checklist: unchecked items only

  2. /Users/mac/.claude/projects/-Users-mac-Desktop-proops2026-taskmanager/memory/MEMORY.md
     Extract: current sprint state line, next phase line, any EKS/AWS state notes.

  Return format:
    WIP_UPDATED: [date]
    PHASES: [table rows as bullet list]
    OPEN_GAPS: [list or "none"]
    CHECKLIST: [unchecked items as bullet list]
    MEMORY_NOTES: [1-3 key lines from MEMORY.md]
```

### Agent C — Git + AWS State
```
subagent_type: Explore
run_in_background: true
prompt: |
  Run these read-only checks and report results. No writes, no side effects.

  1. Git status across service repos:
     git -C /Users/mac/Desktop/proops2026-taskmanager/user-service status --short 2>/dev/null || echo "no repo"
     git -C /Users/mac/Desktop/proops2026-taskmanager/task-service status --short 2>/dev/null || echo "no repo"
     git -C /Users/mac/Desktop/proops2026-taskmanager/api-gateway status --short 2>/dev/null || echo "no repo"
     git -C /Users/mac/Desktop/proops2026-taskmanager/frontend-service status --short 2>/dev/null || echo "no repo"
     git -C /Users/mac/Desktop/proops2026-taskmanager/docs status --short 2>/dev/null || echo "no repo"

  2. EKS cluster status (fast check):
     aws eks describe-cluster --name taskmanager-chau-lab --region eu-central-1 \
       --query "cluster.status" --output text 2>/dev/null || echo "NOT_FOUND"

  Return format:
    GIT_DIRTY: [list of repos with uncommitted changes, or "all clean"]
    EKS_STATUS: [ACTIVE | NOT_FOUND | other status]
```

---

## Step 2 — Wait and Merge

When all three agents return, merge their output into the session plan:

```
=== Session Ready — Task Manager ===
Date: [today]  |  EKS: [ACTIVE / DOWN]

Hub skills-ledger: [✅ Clean  |  ⚠️ N #new tags — run !hub-sync before proceeding]

Sprint phases:
  [paste PHASES from Agent B, emoji ✅/☐ preserved]

Open gaps:
  [paste OPEN_GAPS from Agent B, or "None"]

Next checklist items:
  [paste CHECKLIST from Agent B]

Git state:
  [paste GIT_DIRTY from Agent C]

First action:
  → [derive from checklist + EKS status: if EKS=ACTIVE and checklist has EKS steps, lead with that]
  → [if #new tags found: STOP — run !hub-sync first]

AWS reminder (only if EKS=ACTIVE or checklist has AWS steps):
  source ./scripts/aws-session-init.sh  ← if script exists
```

---

## Step 3 — Gate on #new Tags

- **If `SKILLS_LEDGER` from Agent A = anything other than CLEAN:**
  Print the warning and STOP. Do not proceed to implementation until user
  responds with "run !hub-sync" or "skip".

- **If CLEAN:** proceed immediately, no prompt.

---

## Rules

- Always spawn all three agents in parallel — never read files sequentially
- Never invent task statuses — Agent B reads WIP.md, that is ground truth
- The merge in Step 2 is done by the main agent, not a fourth sub-agent
- If any agent fails (file not found, AWS timeout), note the failure in the
  session plan and continue — don't abort the session
