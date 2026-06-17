# Runbook: Pod Restart Loop

**Alert name:** Pod Restart Loop
**Severity:** warning
**Service:** any service in namespace dev
**Namespace:** dev
**Grafana panel:** Restart count (kube_pod_container_status_restarts_total)

---

## What This Alert Means

One or more pods have restarted more than 3 times in the last 15 minutes. Kubernetes is catching and restarting a crashing container in a loop — this is `CrashLoopBackOff` or rapid `OOMKill` cycling.

**Real-world analogy:** A new hire keeps showing up, clocking in, immediately fainting, being sent home, and repeating. HR (Kubernetes) keeps rehiring them hoping it'll work this time. It won't — something is structurally wrong.

---

## Probable Causes (in order of likelihood)

| # | Cause | Signal |
|---|-------|--------|
| 1 | **ImagePullBackOff** — bad image tag, image doesn't exist | `kubectl describe pod` shows "ErrImagePull" or "ImagePullBackOff" in Events |
| 2 | **CrashLoopBackOff — bad env var** — missing DATABASE_URL, JWT_SECRET, or wrong service URL | `kubectl logs --previous` shows "Cannot read env" or "ECONNREFUSED" at startup |
| 3 | **OOMKilled** — memory limit too low for the container | `kubectl describe pod` shows `OOMKilled`; `Last State: Terminated Reason: OOMKilled` |
| 4 | **Liveness probe failing** — app starts but probe fails, K8s kills it | `kubectl describe pod` shows "Liveness probe failed" in Events |
| 5 | **Bad deployment** — recent `set image` pushed a broken tag | `kubectl rollout history` shows recent revision matches restart onset |
| 6 | **Init container stuck** — waiting for DB that never becomes ready | `kubectl get pods` shows `Init:0/1` status indefinitely |

---

## Diagnostic Commands (run in order)

```bash
# 1. Find which pods are restarting
kubectl get pods -n dev
# Look for: high RESTARTS count, status CrashLoopBackOff or ImagePullBackOff

# 2. Describe the crashing pod — Events section is key
kubectl describe pod <pod-name> -n dev
# Look for: image pull errors, OOMKilled, liveness probe failures, resource limits

# 3. Check current logs (if container is briefly running)
kubectl logs <pod-name> -n dev --tail=100

# 4. Check PREVIOUS container logs (before the last crash)
kubectl logs <pod-name> -n dev --previous --tail=100
# This is the most useful — shows what the app printed before dying

# 5. Check rollout history — did a recent deploy start this?
kubectl rollout history deployment/<service-name> -n dev

# 6. Check resource usage vs limits
kubectl describe pod <pod-name> -n dev | grep -A5 "Limits\|Requests\|Last State"

# 7. Correlate with recent git commits
git log --oneline --since="20 minutes ago"
```

---

## Fix Actions

### Class 1 — SAFE (agent executes autonomously)

**If cause = bad image tag (ImagePullBackOff from recent deploy):**
```bash
kubectl rollout undo deployment/<service-name> -n dev
# This reverts to the previous known-good image tag
kubectl rollout status deployment/<service-name> -n dev
```

**If cause = OOMKilled (pod keeps being killed by memory limit):**
```bash
# Restart first — sometimes a memory spike is transient
kubectl rollout restart deployment/<service-name> -n dev
# Note: if OOMKill recurs after restart, it's a RISKY fix (needs limit increase)
```

**If cause = single bad pod, others of same deployment healthy:**
```bash
kubectl delete pod <pod-name> -n dev
# K8s schedules a fresh pod from the healthy replica set
```

**If cause = liveness probe failing after recent deploy:**
```bash
kubectl rollout undo deployment/<service-name> -n dev
```

### Class 2 — RISKY (propose PR, do not execute)

**If cause = OOMKilled repeatedly (memory limit needs raising):**
```bash
# DO NOT RUN — propose as PR
# Edit deployment resource limits:
# resources:
#   limits:
#     memory: "256Mi"   # increase from current value
#   requests:
#     memory: "128Mi"
```

**If cause = bad env var in ConfigMap/Secret:**
```bash
# DO NOT RUN — propose as PR
kubectl edit configmap <svc>-cm -n dev
# OR
kubectl edit secret <svc>-secret -n dev
```

**If cause = liveness probe timeout too tight:**
```bash
# DO NOT RUN — propose as PR
# Edit deployment livenessProbe:
#   initialDelaySeconds: 30   # increase
#   timeoutSeconds: 10        # increase
```

---

## Verification

After taking action, wait 60 seconds then:
```bash
# Restart count should stop climbing
kubectl get pods -n dev
# RESTARTS column should stabilize (not increment further)

# Pod status should reach Running
kubectl get pods -n dev | grep <service-name>
```

**Success:** Pod status = Running, restart count stable for 2+ minutes.
**Failure:** If pod keeps restarting after rollback, the issue is in the base image or config — escalate to human review.

---

## Grafana Alert Config Reference

```yaml
# Alert rule (Grafana Cloud UI)
# Metric: increase(kube_pod_container_status_restarts_total{namespace="dev"}[15m])
# Threshold: > 3
# For: 0m (fire immediately)
# Labels: severity=warning, failure_mode=pod-restart-loop, namespace=taskmanager-dev
# Annotations:
#   summary: "Pod restart loop detected in namespace taskmanager-dev"
#   runbook_url: "https://github.com/chau11ece/proops2026-taskmanager/blob/main/runbooks/pod-restart-loop.md"
```
