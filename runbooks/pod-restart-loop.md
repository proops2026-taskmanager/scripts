# Runbook: Pod Restart Loop

**Alert name:** PodRestartLoop
**Severity:** warning
**Service:** capstone-app (or any deployment in namespace `app`)
**Namespace:** app (k3s, EC2 `i-0f277a90657999094`)
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
| 2 | **CrashLoopBackOff — bad env var** — missing config at startup | `kubectl logs --previous` shows "Cannot read env" or "ECONNREFUSED" at startup |
| 3 | **OOMKilled** — memory limit too low for the container | `kubectl describe pod` shows `OOMKilled`; `Last State: Terminated Reason: OOMKilled` |
| 4 | **Liveness probe failing** — app starts but probe fails, K8s kills it | `kubectl describe pod` shows "Liveness probe failed" in Events |
| 5 | **Bad deployment** — a flagged/dangerous image was deployed anyway | `kubectl rollout history` matches restart onset; check `agent-ops/state/watch.jsonl` for the SHA |

---

## Diagnostic Commands (run in order)

```bash
# 1. Find which pods are restarting
kubectl get pods -n app
# Look for: high RESTARTS count, status CrashLoopBackOff or ImagePullBackOff

# 2. Describe the crashing pod — Events section is key
kubectl describe pod <pod-name> -n app

# 3. Check current + previous logs
kubectl logs <pod-name> -n app --tail=100
kubectl logs <pod-name> -n app --previous --tail=100

# 4. Check the blackboard for a prior Agent B warning on this SHA
cat agent-ops/state/watch.jsonl

# 5. Check rollout history — did a recent deploy start this?
kubectl rollout history deployment/<service-name> -n app

# 6. Check resource usage vs limits
kubectl describe pod <pod-name> -n app | grep -A5 "Limits\|Requests\|Last State"

# 7. Correlate with recent git commits
git log --oneline --since="20 minutes ago"
```

---

## Fix Actions

### Class 1 — SAFE (when kubectl is reachable — see CLAUDE.md's kubectl note)

**If cause = bad image tag (ImagePullBackOff from recent deploy):**
```bash
kubectl rollout undo deployment/<service-name> -n app
kubectl rollout status deployment/<service-name> -n app
```

**If cause = OOMKilled (pod keeps being killed by memory limit):**
```bash
kubectl rollout restart deployment/<service-name> -n app
# Note: if OOMKill recurs after restart, it's a RISKY fix (needs limit increase)
```

**If cause = single bad pod, others of same deployment healthy:**
```bash
kubectl delete pod <pod-name> -n app
```

**If cause = liveness probe failing after recent deploy:**
```bash
kubectl rollout undo deployment/<service-name> -n app
```

### Class 2 — RISKY (propose PR, do not execute)

**If cause = OOMKilled repeatedly (memory limit needs raising):**
```bash
# DO NOT RUN — propose as PR
# resources.limits.memory: "256Mi" (increase), resources.requests.memory: "128Mi"
```

**If cause = bad env var in ConfigMap/Secret:**
```bash
# DO NOT RUN — propose as PR
kubectl edit configmap <svc>-cm -n app
```

**If cause = liveness probe timeout too tight:**
```bash
# DO NOT RUN — propose as PR
# livenessProbe.initialDelaySeconds / timeoutSeconds: increase
```

---

## Verification

After taking action, wait 60 seconds then:
```bash
kubectl get pods -n app
# RESTARTS column should stabilize (not increment further); status = Running
```

**Success:** Pod status = Running, restart count stable for 2+ minutes.
**Failure:** If pod keeps restarting after rollback, the issue is in the base image or config — escalate to human review.

---

## Grafana Alert Config Reference

```yaml
# Alert rule (Grafana Cloud UI)
# Metric: increase(kube_pod_container_status_restarts_total{namespace="app"}[15m])
# Threshold: > 3
# For: 0m (fire immediately)
# Labels: severity=warning, failure_mode=pod-restart-loop, namespace=app
# Annotations:
#   summary: "Pod restart loop detected in namespace app"
#   runbook_url: "https://github.com/proops2026-taskmanager/scripts/blob/main/runbooks/pod-restart-loop.md"
```
