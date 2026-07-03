# triage-runtime-alert

When invoked, a Grafana Cloud alert has fired. Diagnose the probable cause,
take or propose the right action, verify it worked, and post to Discord.

## Trigger
Grafana webhook → fleet `/alert`. Payload (`PAYLOAD` JSON): `DISCORD_WEBHOOK_URL`,
`alerts[0]` (with `RUNBOOK_PATH`, `labels.{namespace,alertname,service}`,
`annotations.{summary,description,runbook_url}`).

## Step 0 — Check blackboard for prior Agent B warnings

Before any kubectl work:
```bash
cat agent-ops/state/watch.jsonl 2>/dev/null
python3 -c "
import json, time
cutoff = time.time() - 1800
for line in open('agent-ops/state/watch.jsonl'):
    e = json.loads(line.strip())
    if e.get('ts', 0) > cutoff: print(e['sha'][:8], e['reason'], e['posted_by'])
" 2>/dev/null
NS=$(echo "$PAYLOAD" | python3 -c "import sys,json; p=json.load(sys.stdin); print(p.get('alerts',[p])[0].get('labels',{}).get('namespace','app'))")
kubectl get pods -n $NS -o jsonpath='{.items[*].spec.containers[*].image}' 2>/dev/null
```
If any watch entry's `sha` (first 8) matches a pod image tag's short SHA, set
`WATCH_CONTEXT = "⚠️ Agent B previously flagged SHA <sha>: <reason>"`. Else `""`.

## Step 1 — Read the runbook, run diagnostics

Open `PAYLOAD.alerts[0].RUNBOOK_PATH` for Probable Causes / Diagnostic Commands /
Fix Actions (Class 1 = SAFE, Class 2 = RISKY) and run those. If empty/missing,
use `namespace` from `PAYLOAD.alerts[0].labels.namespace` (default `app`):
```bash
kubectl get pods -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
git log --oneline --since="20 minutes ago"
```

## Step 2 — Diagnose, decide action class

One sentence: "Most likely cause: X because Y."

**SAFE — execute autonomously:** `kubectl rollout undo/restart deployment/<n> -n <ns>` ·
`kubectl delete pod <n> -n <ns>` · `kubectl scale deployment/<n> --replicas=N` (1..current×2, max 4)

**RISKY — propose only, do NOT execute:** `kubectl edit configmap/secret` ·
`kubectl scale --replicas=0` · `kubectl delete deployment/pvc/statefulset` ·
anything outside the alert namespace · any `aws`/`terraform`/`helm upgrade|uninstall`

## Step 3 — Take action (or propose), then verify

Run SAFE actions; capture before/after state 30s apart. For RISKY: write
`PROPOSED FIX (requires human approval):` + command block — do NOT run it.
Re-run `kubectl get pods -n <namespace>`; record improved (YES/NO/PARTIAL).

## Step 4 — Post to Discord

Include `WATCH_CONTEXT` (if non-empty) on its own line after **Diagnosis**:
```
🤖 **AI Investigator** triggered by: <summary>

**Diagnosis:** <cause>
<WATCH_CONTEXT if non-empty>
**Action:** <taken or proposed>
**Verification:** <before→after, improved?>
**Confidence:** <low|medium|high> — <1 sentence>
**Runbook:** <runbook_url>
```
```bash
curl -s -H "Content-Type: application/json" \
  -d "{\"content\": \"<message above as one string>\"}" "$PAYLOAD_DISCORD_WEBHOOK_URL"
```
Fill from `PAYLOAD.DISCORD_WEBHOOK_URL`. Keep under 1800 chars.

## Failure mode

Always post to Discord, even if diagnostics failed. If kubectl is unavailable
or errors on auth, report that and stop. If the fix did NOT improve: "Tried X,
situation did not improve. Escalating to human review."
