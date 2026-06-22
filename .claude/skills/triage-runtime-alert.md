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

```bash
curl -s -H "Content-Type: application/json" \
  -d '{"content": "🤖 **AI Investigator** triggered by: <summary>\n\n**Diagnosis:** <cause>\n**Action:** <taken or proposed>\n**Verification:** <before→after, improved?>\n**Confidence:** <low|medium|high> — <1 sentence>\n**Runbook:** <runbook_url>"}' \
  "$PAYLOAD_DISCORD_WEBHOOK_URL"
```

Fill `PAYLOAD_DISCORD_WEBHOOK_URL` from `PAYLOAD.DISCORD_WEBHOOK_URL`. Keep under 1800 chars.

---

## Failure mode

Always post to Discord — even if diagnostics failed. If kubectl unavailable/auth error, report that and stop.
If fix did NOT improve: "Tried X, situation did not improve. Escalating to human review."
