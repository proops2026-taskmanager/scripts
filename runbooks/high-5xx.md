# Runbook: High 5xx Error Rate

**Alert name:** High5xxErrorRate
**Severity:** critical
**Service:** capstone-app
**Namespace:** app (k3s, EC2 `i-0f277a90657999094`)
**Grafana panel:** Errors (RED dashboard)

---

## What This Alert Means

The percentage of HTTP responses with status 5xx (500, 502, 503, 504) has exceeded the threshold for 2 consecutive minutes. Users are receiving errors instead of responses.

**Real-world analogy:** The reception desk at a bank is turning customers away. Every 5xx = one customer turned away. This alert fires when more than X% of customers are being turned away.

---

## Probable Causes (in order of likelihood)

| # | Cause | Signal |
|---|-------|--------|
| 1 | **Bad deployment** — a flagged/dangerous image was deployed anyway | `kubectl rollout history` shows a recent revision; check `agent-ops/state/watch.jsonl` for a matching SHA |
| 2 | **Pod crash / OOMKilled** — pod running out of memory and restarting | `kubectl describe pod` shows OOMKilled; `kubectl logs --previous` has crash trace |
| 3 | **Zero replicas** — deployment scaled down accidentally | `kubectl get deploy` shows 0/0 READY |
| 4 | **Config error** — wrong env var | App logs show "Cannot read property of undefined" or "missing env" |

---

## Diagnostic Commands (run in order)

```bash
# 1. Overall pod health
kubectl get pods -n app

# 2. Check the blackboard for a prior Agent B warning on this SHA
cat agent-ops/state/watch.jsonl

# 3. Check recent deployments — correlate timing with alert
kubectl rollout history deployment/capstone-app -n app

# 4. Describe the pod for events (OOMKilled, image pull errors)
kubectl describe pod -l app=capstone-app -n app

# 5. Check logs — look for error stack traces
kubectl logs -l app=capstone-app -n app --tail=100
kubectl logs -l app=capstone-app -n app --previous --tail=100

# 6. Correlate with recent git commits
git log --oneline --since="20 minutes ago"
```

---

## Fix Actions

### Class 1 — SAFE (when kubectl is reachable — see CLAUDE.md's kubectl note)

**If cause = bad deployment (recent rollout):**
```bash
kubectl rollout undo deployment/capstone-app -n app
kubectl rollout status deployment/capstone-app -n app
```

**If cause = OOMKilled / pod crash:**
```bash
kubectl rollout restart deployment/capstone-app -n app
```

**If cause = zero replicas:**
```bash
kubectl scale deployment/capstone-app --replicas=1 -n app
```

**If cause = single bad pod (others healthy):**
```bash
kubectl delete pod <pod-name> -n app
# K8s recreates it automatically
```

### Class 2 — RISKY (propose PR, do not execute)

**If cause = config error (wrong env var in ConfigMap):**
```bash
# DO NOT RUN — propose as PR
kubectl edit configmap capstone-app-cm -n app
```

---

## Verification

After taking action, wait 30 seconds then:
```bash
kubectl get pods -n app
# Error rate should drop — check the Grafana Errors panel
```

**Success:** Error rate returns to < 1% within 60 seconds of action.
**Failure:** If error rate does not improve, escalate — do not loop rollbacks.

---

## Grafana Alert Config Reference

```yaml
# Alert rule (Grafana Cloud UI)
# Metric: sum(rate(http_requests_total{status=~"5.."}[2m])) / sum(rate(http_requests_total[2m]))
# Threshold: > 0.05 (5%)
# For: 2m
# Labels: severity=critical, failure_mode=high-error-rate, namespace=app, service=capstone-app
# Annotations:
#   summary: "High 5xx Error Rate on capstone-app"
#   runbook_url: "https://github.com/proops2026-taskmanager/scripts/blob/main/runbooks/high-5xx.md"
```
