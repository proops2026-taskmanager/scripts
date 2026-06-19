# triage-alert skill

When invoked, you have received a webhook payload from Grafana Cloud about an alert that just fired.
Your job: diagnose the probable cause, take or propose the right action, verify it worked, and post findings to Discord.

---

## Input

You receive these variables in your prompt:
- `ALERT_PAYLOAD` — the full JSON Grafana Cloud sent
- `DISCORD_WEBHOOK_URL` — where to post your findings
- `RUNBOOK_PATH` — absolute local path to the runbook for this alert

---

## Steps (execute in order, do not skip)

### Step 1 — Read the runbook

Open the file at `RUNBOOK_PATH`. Read it fully.
Note:
- The **Probable Causes** table (ordered by likelihood)
- The **Diagnostic Commands** (you will run these)
- The **Fix Actions** (Class 1 = SAFE, Class 2 = RISKY)

If `RUNBOOK_PATH` is empty or the file does not exist:
- Proceed with generic kubectl diagnostics below
- Note "runbook not found" in your Discord report

### Step 2 — Run diagnostics

Extract the namespace from `ALERT_PAYLOAD.labels.namespace` (default: `taskmanager-dev`).
Extract the service name from `ALERT_PAYLOAD.labels.service` or `ALERT_PAYLOAD.labels.app` if present.

Run the runbook's diagnostic commands in order. If no runbook, run:
```bash
kubectl get pods -n taskmanager-dev
kubectl get events -n taskmanager-dev --sort-by='.lastTimestamp' | tail -20
git log --oneline --since="20 minutes ago"
```

Collect outputs. Do NOT print raw outputs to the user — summarize what you observed.

### Step 3 — Diagnose probable cause

Match what you observed against the runbook's Probable Causes table.
Pick the **single most likely cause**.
Write one sentence: "Most likely cause: [cause] because [evidence from diagnostics]."

### Step 4 — Decide action class

**SAFE — you MAY execute autonomously:**
- `kubectl rollout undo deployment/<name> -n <ns>` — reverts to previous replica set
- `kubectl rollout restart deployment/<name> -n <ns>` — recreates pods
- `kubectl delete pod <name> -n <ns>` — single pod restart, K8s recreates it
- `kubectl scale deployment/<name> --replicas=N -n <ns>` where N is between 1 and current*2 (max 4)

**RISKY — DO NOT execute, propose only:**
- `kubectl edit configmap` or `kubectl edit secret`
- `kubectl scale deployment --replicas=0` (scale DOWN to zero)
- `kubectl delete deployment` / `kubectl delete pvc` / `kubectl delete statefulset`
- Any `kubectl` command outside namespace `taskmanager-dev`
- Any `aws`, `terraform`, or `helm upgrade/uninstall` commands

If the fix is RISKY: write the proposed commands as a code block. Do not run them.

### Step 5 — Take action or propose

**If SAFE:**
Run the action. Capture the before-state (pod list) before running and after-state 30 seconds later.

**If RISKY:**
Do NOT run the command. Write:
```
PROPOSED FIX (requires human approval):
<bash commands as a code block>
```

**If uncertain:**
Default to RISKY. It is better to propose and wait than to take an irreversible action on a wrong diagnosis.

### Step 6 — Verify

Wait 30 seconds after any SAFE action, then re-run:
```bash
kubectl get pods -n <namespace>
```

Record:
- Status before action: [e.g., "api-gateway 0/1 CrashLoopBackOff, 5 restarts"]
- Action taken: [e.g., "kubectl rollout undo deployment/api-gateway -n dev"]
- Status after action: [e.g., "api-gateway 1/1 Running, 0 restarts"]
- Did it improve? YES / NO / PARTIAL

If NO: say so clearly. Do not pretend the fix worked.

### Step 7 — Post to Discord

POST a single message to `DISCORD_WEBHOOK_URL` using curl:

```bash
curl -s -H "Content-Type: application/json" \
  -d '{
    "content": "🤖 **AI Investigator** triggered by alert: <alert_summary>\n\n**Diagnosis:** <probable cause — 1 line>\n**Action:** <SAFE: command run> OR <RISKY: proposed command for human approval>\n**Verification:** <before/after state — did it improve?>\n**Confidence:** <low|medium|high> — <1 sentence reasoning>\n**Runbook:** <runbook_url from alert payload annotations>"
  }' \
  "$DISCORD_WEBHOOK_URL"
```

Fill in the placeholders from your investigation. Keep the whole message under 1800 characters.

**Honest reporting is required.** If the action did NOT improve the situation, the message must say:
> "Tried [action], situation did not improve. Escalating to human review."

Never omit the Discord post — even if all diagnostics failed, post what you found and what you couldn't determine.

---

## Rules

1. Do NOT modify resources outside the SAFE list
2. Do NOT touch any namespace other than `taskmanager-dev` (or the namespace in the alert)
3. Do NOT delete data (PVCs, StatefulSets, Secrets)
4. ALWAYS post to Discord — success, failure, or uncertainty
5. One investigation per invocation — do not loop or retry
6. If kubectl is not available or returns auth errors, report that in Discord and stop
