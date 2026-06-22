# Memory Index — Task Management System

> This file maps all in-repo knowledge files under `memory/`.
> Update it whenever a new memory file is added or a topic changes significantly.

---

## Infrastructure & Cloud

| File | Topic | Last Updated |
|------|-------|-------------|
| [eks-practice.md](eks-practice.md) | EKS cluster setup, node groups, kubeconfig | Day 24+ |
| [kubernetes-project.md](kubernetes-project.md) | K8s manifests, namespaces, Deployments, Services | Day 22+ |

## CI/CD & Git

| File | Topic | Last Updated |
|------|-------|-------------|
| [github-actions.md](github-actions.md) | GHA workflows, branch protection, matrix jobs | Day 31 |
| [git-workflows.md](git-workflows.md) | Branch strategy, PR flow, merge rules | Day 23 |

## Agent Fleet

| File | Topic | Last Updated |
|------|-------|-------------|
| [day-36-substrate.md](day-36-substrate.md) | EC2 + k3s substrate check, fleet.py startup, ngrok URL | Day 36 (2026-06-22) |
| [day-36-fleet-tests.md](day-36-fleet-tests.md) | Agent A/B/C test matrix — 6 cases, Expected/Actual/Pass | Day 36 (2026-06-22) |

### Agent Fleet Architecture

```
fleet.py (port 9999, ngrok tunnel)
  ├── /alert        → skill: triage-runtime-alert  (Agent A)
  ├── /ci-failed    → skill: triage-ci-failure      (Agent B)
  └── /iac-plan-review → skill: review-iac-plan     (Agent C)

GHA Triggers:
  why-failed.yml    → issue_comment /why-failed  → POST /ci-failed
  review-plan.yml   → issue_comment /review-plan → POST /iac-plan-review
```

### Key Constraints

- `fleet.py` must run on `develop` branch — skill files only exist on `develop`
- ngrok URL rotates each session — update `FLEET_WEBHOOK_URL` GitHub secret after every `ngrok start`
- k3s kubeconfig at `~/.kube/k3s-capstone.yaml`, needs `insecure-skip-tls-verify: true` (cert SAN is 127.0.0.1)
- EC2 `i-0f277a90657999094` — stop after each session to save cost
- SG port 6443 CIDR must match current laptop IP — update each session if IP changes
