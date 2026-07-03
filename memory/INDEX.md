# Memory Index — proops2026-taskmanager

> Map of everything under `memory/`. Update this whenever a file is added or
> a topic changes. Don't duplicate file contents here — pointers only.

## System

| File | Topic |
|------|-------|
| [eks-practice.md](eks-practice.md) | EKS cluster setup, node groups, kubeconfig (historical — no EKS cluster is live today) |
| [kubernetes-project.md](kubernetes-project.md) | K8s manifests, namespaces, Deployments, Services |

## Operations

- Dashboard: https://chau11ece.grafana.net/d/taskmanager-red-eks-d45 (Errors/RED panel first)
- Alert rules: `High5xxErrorRate` → `runbooks/high-5xx.md`; `PodRestartLoop` → `runbooks/pod-restart-loop.md`
- Demo centerpiece: `capstone-fleet-drill-final.mp4` — lives in the hub repo
  `chautv-proops2026` (commit `0489108`), not duplicated here

## CI/CD & Git

| File | Topic |
|------|-------|
| [github-actions.md](github-actions.md) | GHA workflows, branch protection, matrix jobs |
| [git-workflows.md](git-workflows.md) | Branch strategy, PR flow, merge rules |

## Agent Fleet

| File | Topic |
|------|-------|
| [day-36-substrate.md](day-36-substrate.md) | EC2 + k3s substrate check, fleet.py startup, ngrok URL |
| [day-36-fleet-tests.md](day-36-fleet-tests.md) | Agent A/B/C test matrix — 6 cases |
| [day-37-fleet-drill-notes.md](day-37-fleet-drill-notes.md) | Blackboard pattern proof + operational gotchas (OAuth wipe, image retagging, containerd stale cache) |

```
fleet.py (port 9999, ngrok tunnel) — started via ~/fleet-start.sh on the EC2 box
  ├── /alert            → triage-runtime-alert  (Agent A — runtime triage)
  ├── /ci-failed        → triage-ci-failure      (Agent B — CI triage)
  └── /iac-plan-review  → review-iac-plan        (Agent C — terraform review)
blackboard: agent-ops/state/watch.jsonl (Agent B writes, Agent A reads, 30-min window)
```

## Runbooks (in `/runbooks`)

- `high-5xx.md` — first response for elevated 5xx alerts (namespace `app`, deployment `capstone-app`)
- `pod-restart-loop.md` — first response for CrashLoop/restart alerts

## Skills (in `/.claude/skills`)

- `triage-runtime-alert.md`, `triage-ci-failure.md`, `review-iac-plan.md` — see CLAUDE.md's Agent Fleet table for routing

## Key Constraints

- `fleet.py` runs only on `develop` — skill files only exist there
- ngrok URL is stable via reserved authtoken domain (`ovary-stifling-feline.ngrok-free.dev`)
- k3s kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-owned — `ec2-user` needs `sudo kubectl`
- EC2 `i-0f277a90657999094` — stop after every session to save cost
- No EKS cluster is currently live — `app-cd-staging.yml`/`app-cd-prod.yml` will fail if triggered

## Archive

- `day-N-*` per-day notes — kept for reference, not canonical
