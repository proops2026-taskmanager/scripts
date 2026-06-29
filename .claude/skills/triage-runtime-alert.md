# triage-runtime-alert

When invoked, a Grafana Cloud alert has fired. Your job: diagnose the probable cause,
take or propose the right action, verify it worked, and post findings to Discord.

---

## Trigger

Grafana webhook → fleet `/alert` endpoint.

Payload fields (all inside the `PAYLOAD` JSON you received):
- `PAYLOAD.DISCORD_WEBHOOK_URL` — where to post findings
- `PAYLOAD.alerts[0]` — the alert object
- `PAYLOAD.alerts[0].RUNBOOK_PATH` — absolute local path to the runbook (may be empty)
- `PAYLOAD.alerts[0].labels` — `namespace`, `alertname`, `service`
- `PAYLOAD.alerts[0].annotations` — `summary`, `description`, `runbook_url`

---

## Steps (execute in order, do not skip)

### Step 0 — Check blackboard for prior Agent B warnings

Before any kubectl work, read the watch blackboard:
```bash
cat agent-ops/state/watch.jsonl 2>/dev/null
```

Filter entries from the last 30 minutes:
```bash
python3 -c "
import json, time
cutoff = time.time() - 1800
try:
    for line in open('agent-ops/state/watch.jsonl'):
        e = json.loads(line.strip())
        if e.get('ts', 0) > cutoff:
            print(e['sha'][:8], e['reason'], e['posted_by'])
except: pass
"
```

Also get the image tag of the affected pod (extract the short SHA after `:`):
```bash
NS=$(echo "$PAYLOAD" | python3 -c "import sys,json; p=json.load(sys.stdin); print(p.get('alerts',[p])[0].get('labels',{}).get('namespace','taskmanager-dev'))")
kubectl get pods -n $NS -o jsonpath='{.items[*].spec.containers[*].image}' 2>/dev/null
```

**Decision:** If any watch entry's `sha` (first 8 chars) matches any pod image tag's short SHA:
- Set `WATCH_CONTEXT = "⚠️ Agent B previously flagged SHA <sha>: <reason>"`

If no match or blackboard empty: `WATCH_CONTEXT = ""` — proceed normally.

---

### Step 1 — Read the runbook

Open the file at `PAYLOAD.alerts[0].RUNBOOK_PATH`. If empty or missing, use generic kubectl diagnostics below.
Note: Probable Causes table, Diagnostic Commands, Fix Actions (Class 1 = SAFE, Class 2 = RISKY).

### Step 2 — Run diagnostics

Extract `namespace` from `PAYLOAD.alerts[0].labels.namespace` (default: `taskmanager-dev`).

Run runbook diagnostics, or if no runbook:
```bash
kubectl get pods -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
git log --oneline --since="20 minutes ago"
```

### Step 3 — Diagnose probable cause
Pick the single most likely cause. One sentence: "Most likely cause: X because Y."

### Step 4 — Decide action class

**SAFE — execute autonomously:**
- `kubectl rollout undo deployment/<name> -n <ns>`
- `kubectl rollout restart deployment/<name> -n <ns>`
- `kubectl delete pod <name> -n <ns>`
- `kubectl scale deployment/<name> --replicas=N` where N is 1 to current×2 (max 4)

**RISKY — propose only, do NOT execute:**
- `kubectl edit configmap/secret`
- `kubectl scale deployment --replicas=0`
- `kubectl delete deployment/pvc/statefulset`
- Any command outside the alert namespace
- Any `aws`, `terraform`, or `helm upgrade/uninstall`

### Step 5 — Take action or propose
Run SAFE actions. Capture before-state, take action, capture after-state (30 sec later).
For RISKY: write `PROPOSED FIX (requires human approval):` + command block. Do NOT run.

### Step 6 — Verify

After any SAFE action, wait 30 sec then re-run `kubectl get pods -n <namespace>`.
Record: status before / action taken / status after / did it improve (YES/NO/PARTIAL).

### Step 7 — Post to Discord

Build the message body. If `WATCH_CONTEXT` is non-empty, include it on its own line after **Diagnosis**:

```
🤖 **AI Investigator** triggered by: <summary>

**Diagnosis:** <cause>
<WATCH_CONTEXT if non-empty>
**Action:** <taken or proposed>
**Verification:** <before→after, improved?>
**Confidence:** <low|medium|high> — <1 sentence>
**Runbook:** <runbook_url>
```

Example with prior Agent B warning:
```
🤖 **AI Investigator** triggered by: HighErrorRate on api

**Diagnosis:** All api pods crashed after latest deploy
⚠️ Agent B previously flagged SHA 4635de3d: skipped test gate — dangerous image built
**Action:** PROPOSED — kubectl rollout undo deployment/api -n taskmanager-dev
**Verification:** pods were 0/1 Running → rollback proposed (not yet applied)
**Confidence:** high — broken image matches Agent B's warning
**Runbook:** https://...
```

```bash
curl -s -H "Content-Type: application/json" \
  -d "{\"content\": \"<full message above as a single string>\"}" \
  "$PAYLOAD_DISCORD_WEBHOOK_URL"
```

Fill `PAYLOAD_DISCORD_WEBHOOK_URL` from `PAYLOAD.DISCORD_WEBHOOK_URL`. Keep under 1800 chars.

---

## Failure mode

Always post to Discord — even if diagnostics failed. If kubectl unavailable/auth error, report that and stop.
If fix did NOT improve: "Tried X, situation did not improve. Escalating to human review."
