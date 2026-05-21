# /start-session — Begin a Task Manager Session

Run this at the start of every session. Executes all checks directly — no
background agents. Each step prints its status live before running.

Target: complete in under 20 seconds.

---

## Execution Model

**Do NOT spawn sub-agents. Do NOT use run_in_background.**
Run every check yourself using Read and Bash tools directly.
Print a one-line status before EACH tool call so the user sees live progress.

---

## Steps — run in order, print status before each

### [1/5] Skills Ledger

Print: `🔍 [1/5] Checking Hub skills-ledger for #new tags...`

Read: `/Users/mac/Desktop/chautv-proops2026/memory/skills-ledger.md`

Scan every line for `#new`. Record: CLEAN or list of skill names with #new.

Print result immediately:
- CLEAN → `✅ Skills ledger: clean`
- Found → `⚠️  Skills ledger: N #new tag(s) found — [names]`

### [2/5] Project State

Print: `🔍 [2/5] Reading WIP.md...`

Read: `/Users/mac/Desktop/proops2026-taskmanager/docs/WIP.md`

Extract and print immediately:
```
📋 WIP (updated [date]):
  Current phase: [name of ⚠️ In Progress row, or last ✅ if all done]
  Open gaps:     [G-XX HIGH/MED only, comma-separated, or "none"]
  Next actions:  [first 3 unchecked checklist items, numbered]
```

### [3/5] Git Status

Print: `🔍 [3/5] Checking git status across repos...`

Run this single Bash command (10s timeout):
```bash
for repo in user-service task-service api-gateway frontend-service docs; do
  out=$(git -C /Users/mac/Desktop/proops2026-taskmanager/$repo status --short 2>/dev/null)
  if [ -n "$out" ]; then echo "DIRTY $repo"; else echo "CLEAN $repo"; fi
done
```

Print result immediately:
- All clean → `✅ Git: all repos clean`
- Dirty repos → `⚠️  Git dirty: [list repo names]`

### [4/5] EKS / Terraform State

Print: `🔍 [4/5] Checking EKS cluster (5s timeout)...`

Run with strict 5-second timeout:
```bash
timeout 5 aws eks describe-cluster \
  --name taskmanager-dev \
  --region eu-central-1 \
  --query "cluster.status" \
  --output text 2>/dev/null || echo "NOT_FOUND"
```

Print result immediately:
- ACTIVE → `🟢 EKS: ACTIVE — cluster is running (costs money)`
- NOT_FOUND or timeout → `⚫ EKS: not running`

### [5/5] Hub Identity

Print: `🔍 [5/5] Loading Hub identity...`

Read: `/Users/mac/Desktop/chautv-proops2026/CLAUDE.md`

Extract operating persona (1 sentence). Print: `✅ Hub loaded: [persona line]`

---

## Final Output

After all 5 steps, print the full session plan:

```
═══════════════════════════════════════
  Session Ready — Task Manager
  Date: [today]  |  EKS: [ACTIVE 🟢 / Down ⚫]
═══════════════════════════════════════

[If #new tags found — print this block:]
  ⚠️  BLOCKER: Hub skills-ledger has [N] new pattern(s):
      [list each skill name]
      These may require IRD updates before implementation.
      → Run !hub-sync now, or type "skip" to continue anyway.

Sprint phase:
  [current ⚠️ In Progress phase name, or "All complete — pick next"]

Open gaps (HIGH/MED):
  [list G-XX items with priority, or "None blocking"]

Next 3 actions:
  1. [first unchecked checklist item]
  2. [second]
  3. [third]

Git:
  [dirty repo list or "all clean"]

[If AWS work in checklist:]
  AWS reminder: source ./scripts/aws-session-init.sh
```

---

## Gate: #new Tags

After printing the session plan, if skills-ledger had #new tags:

**STOP and ask:**
> "Hub skills-ledger has [N] new pattern(s) tagged `#new`: [names].
> Run `!hub-sync` to push them to the IRDs before we start, or type **skip**?"

Do not proceed to implementation until the user replies.

If CLEAN: no gate, session is ready immediately.

---

## Rules

- Never spawn sub-agents or use run_in_background — it hides failures
- Always print the `🔍 [N/5] ...` line BEFORE the tool call, not after
- AWS check MUST use `timeout 5` — never let it hang
- If any Read fails (file missing), print `❌ [step]: file not found` and continue
- If git Bash fails, print `❌ git check failed` and continue
- Total time budget: under 20 seconds
