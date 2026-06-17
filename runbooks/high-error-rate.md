# Runbook: High 5xx Error Rate

**Alert name:** High 5xx Error Rate
**Severity:** critical
**Service:** api-gateway
**Namespace:** dev
**Grafana panel:** Error Rate (RED dashboard)

---

## What This Alert Means

The percentage of HTTP responses with status 5xx (500, 502, 503, 504) has exceeded the threshold for 2 consecutive minutes. Users are receiving errors instead of responses.

**Real-world analogy:** The reception desk at a bank is turning customers away. Every 5xx = one customer turned away. This alert fires when more than X% of customers are being turned away.

---

## Probable Causes (in order of likelihood)

| # | Cause | Signal |
|---|-------|--------|
| 1 | **Bad deployment** — recent image push introduced a bug or bad config | `kubectl rollout history` shows recent revision; errors started at deploy time |
| 2 | **Pod crash / OOMKilled** — pod running out of memory and restarting | `kubectl describe pod` shows OOMKilled; `kubectl logs --previous` has crash trace |
| 3 | **Database unreachable** — task-db or user-db pod not ready | `kubectl get pods` shows db pod Pending or CrashLoop; app logs show "ECONNREFUSED" |
| 4 | **Zero replicas** — deployment scaled down accidentally | `kubectl get deploy` shows 0/0 READY |
| 5 | **Config error** — wrong env var (bad DB URL, missing JWT_SECRET) | App logs show "Cannot read property of undefined" or "missing env" |

---

## Diagnostic Commands (run in order)

```bash
# 1. Overall pod health in dev namespace
kubectl get pods -n dev

# 2. Check recent deployments — correlate timing with alert
kubectl rollout history deployment/api-gateway -n dev
kubectl rollout history deployment/task-service -n dev
kubectl rollout history deployment/user-service -n dev

# 3. Describe the api-gateway pod for events (OOMKilled, image pull errors)
kubectl describe pod -l app=api-gateway -n dev

# 4. Check api-gateway logs — look for error stack traces
kubectl logs -l app=api-gateway -n dev --tail=100

# 5. Check previous container logs if it restarted
kubectl logs -l app=api-gateway -n dev --previous --tail=100

# 6. Check database pod health
kubectl get pods -l app=task-db -n dev
kubectl get pods -l app=user-db -n dev

# 7. Correlate with recent git commits
git log --oneline --since="20 minutes ago"
```

---

## Fix Actions

### Class 1 — SAFE (agent executes autonomously)

**If cause = bad deployment (recent rollout):**
```bash
kubectl rollout undo deployment/api-gateway -n dev
# Verify recovery:
kubectl rollout status deployment/api-gateway -n dev
```

**If cause = OOMKilled / pod crash:**
```bash
kubectl rollout restart deployment/api-gateway -n dev
```

**If cause = zero replicas:**
```bash
kubectl scale deployment/api-gateway --replicas=1 -n dev
```

**If cause = single bad pod (others healthy):**
```bash
kubectl delete pod <pod-name> -n dev
# K8s recreates it automatically
```

### Class 2 — RISKY (propose PR, do not execute)

**If cause = config error (wrong env var in ConfigMap):**
```bash
# DO NOT RUN — propose as PR
kubectl edit configmap api-gw-cm -n dev
# Change: <key>=<correct-value>
```

**If cause = database down (needs PVC or StatefulSet fix):**
```bash
# DO NOT RUN — propose as PR
# Requires investigation of StatefulSet and PVC state
```

---

## Verification

After taking action, wait 30 seconds then:
```bash
# Pod count should be X/X Ready
kubectl get pods -n dev

# Error rate should drop — check Grafana dashboard
# Or curl the health endpoint:
kubectl port-forward svc/api-gateway 8080:8080 -n dev &
curl localhost:8080/health
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
# Labels: severity=critical, failure_mode=high-error-rate, namespace=taskmanager-dev
# Annotations:
#   summary: "High 5xx Error Rate on api-gateway"
#   runbook_url: "https://github.com/chau11ece/proops2026-taskmanager/blob/main/runbooks/high-error-rate.md"
```
