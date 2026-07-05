# proops2026-taskmanager — Capstone Repo

Single git repo (GitHub: `proops2026-taskmanager/scripts`, branch `develop`).
Contains the task-manager app (5 services), its EKS-era IaC, the k3s capstone
demo, and the 3-agent ops fleet. Not a multi-repo workspace — everything below
lives in this one checkout.

---

## Project Overview

A task tracker REST API + React web UI (Jira-lite): `user-service` (3001),
`task-service` (3002), `api-gateway` (8080, JWT + routing + CORS),
`notification-service` (3003, Redis streams), `frontend-service` (3000, React
+ nginx). Stack: Node.js 20 + TypeScript 5 (strict) + Express 4 + PostgreSQL
15-alpine + Docker Compose. All 5 services are built and merged — this is no
longer sprint work, it's the substrate the capstone demo runs on top of.

---

## Architecture

**App layer** (Docker Compose locally, container images built per service):
```
Browser ─▶ frontend-service (:3000) ─▶ api-gateway (:8080, only exposed svc)
                                           ├─▶ user-service (:3001) ─▶ users_db
                                           ├─▶ task-service (:3002) ─▶ tasks_db
                                           └─▶ notification-service (:3003) ─▶ Redis + notifications_db
```

**Capstone demo layer** (what Day 40 actually runs): a single k3s cluster on
EC2 `i-0f277a90657999094` (eu-central-1, `3.76.55.12`) running deployment
`capstone-app` in namespace `app`, image `ghcr.io/chau11ece/capstone-app`.
Same box also runs `fleet.py` (dispatcher, port 9999) tunneled through a
stable ngrok domain (`ovary-stifling-feline.ngrok-free.dev`). See Agent Fleet
below.

**Locked design decisions** (all services): error format
`{ "error": "string" }`, JWT HS256/24h/`{sub,role}` validated only at
api-gateway, cross-service IDs are plain UUIDs (no cross-service FKs), task
status TODO→IN_PROGRESS→DONE (terminal) or →CANCELLED (terminal, no backward
transitions), bcrypt rounds = 12.

---

## How to Operate

**Dashboard:** https://chau11ece.grafana.net/d/taskmanager-red-eks-d45 — look
at the **Errors** panel first (RED: Rate/Errors/Duration). Known gap: this
dashboard was built for the EKS era; panel labels may still say `taskmanager-dev`
even though the demo now runs on k3s/`app` namespace — verify before trusting
a panel value blindly.

**Alert rules → runbooks:**
| Alert | Runbook |
|-------|---------|
| `High5xxErrorRate` | `runbooks/high-5xx.md` |
| `PodRestartLoop` | `runbooks/pod-restart-loop.md` |

---

## CI/CD

- PR → `app-ci-pr.yml` runs tests only (no push, no deploy) via the platform's
  `reusable-app-ci.yml@v1`.
- Merge to `develop` → dev deploy + manual `workflow_dispatch` full-stack smoke
  (`app-cd-dev.yml`, hits `DEV_BASE_URL`, a live ELB).
- Merge `develop`→`release` → `app-cd-staging.yml` builds once via
  `reusable-build.yml@v2` and deploys the same SHA-tagged image via
  `reusable-deploy.yml@v2` — **currently non-functional**: `STAGING_BASE_URL`
  and `KUBE_CONFIG_DATA_STAGING` are not configured and no EKS cluster exists
  (`aws eks list-clusters` → empty). Don't tell anyone this "just works."
- Merge `release`→`main` → `app-cd-prod.yml`, same pattern plus a human
  approval gate — same missing-EKS blocker as staging.
- **The deploy path that actually works today** (used in the live AC-05 drill):
  retag the known-good image directly on the registry —
  `docker buildx imagetools create --tag ghcr.io/chau11ece/capstone-app:<sha> ghcr.io/chau11ece/capstone-app:bootstrap`
  — then `kubectl rollout restart deployment/capstone-app -n app` on the k3s box.

---

## kubectl — Safe / Risky

Source of truth: `.claude/skills/triage-runtime-alert.md`. Full rationale in
IRD-59.

**Safe (agent may run without asking):**
```
kubectl get / describe / logs / top                    — read-only
kubectl rollout status / history                        — read-only
kubectl rollout undo deployment/<n> -n <ns>              — see note below
kubectl rollout restart deployment/<n> -n <ns>           — see note below
kubectl delete pod <n> -n <ns>                           — single pod, k8s recreates
kubectl scale deployment/<n> --replicas=N                — N = 1..current×2, max 4
```
**Note:** `ec2-user` on the fleet box cannot read the root-owned
`/etc/rancher/k3s/k3s.yaml` directly — but has passwordless `sudo` (member of
`wheel`), so every kubectl command the agent runs MUST go through
`sudo kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml <cmd>` (codified in the
`triage-runtime-alert` skill, commit `08b8f2c`, 2026-07-05). This was
previously logged as a known, accepted gap (AC-04/AC-05 of DOP-58) that
blocked autonomous execution entirely — that was wrong, never actually
tested with sudo. Verified fixed with two independent clean drills
(Day 60 dry-run, 2026-07-05): Agent A now executes `rollout undo`/`restart`
for real, not just proposes them.

**Risky (agent MUST ask first):**
```
kubectl edit configmap / secret
kubectl scale deployment --replicas=0
kubectl delete deployment / pvc / statefulset
any kubectl command outside the alert's namespace
any aws / terraform / helm upgrade|uninstall command
```

---

## Agent Fleet

`agent-ops/fleet.py` (systemd-less; started via `~/fleet-start.sh` on the EC2
box) dispatches webhooks to skills:

| Route | Skill | Role |
|-------|-------|------|
| `/alert` | `triage-runtime-alert` | Agent A — runtime alert triage, reads the blackboard first |
| `/ci-failed` (+ PR comment `/why-failed`) | `triage-ci-failure` | Agent B — CI failure triage, posts to blackboard on dangerous commits |
| `/iac-plan-review` (+ PR comment `/review-plan`) | `review-iac-plan` | Agent C — read-only terraform plan review |

**Coordination pattern:** `agent-ops/state/watch.jsonl` is a file-backed
blackboard. Agent B appends `{sha, reason, posted_by, ts}` when it detects a
dangerous commit (skipped test gate). Agent A reads entries from the last 30
minutes before diagnosing an alert, and cites a match in its Discord post
("Agent B previously flagged SHA ..."). Fire-and-forget, no RPC. Proven live
in the AC-05 drill (PR #22, SHA `280e300f`).

---

## On-Call Basics

**High 5xx** (`runbooks/high-5xx.md`): first 90s = check the dashboard's
Errors panel → `kubectl -n app logs -l app=capstone-app --tail=200 | grep -i error` →
`kubectl -n app rollout history deployment/capstone-app`. If a bad deploy,
rollback per the safe/risky table above.

**Pod restart loop** (`runbooks/pod-restart-loop.md`): first 90s =
`kubectl -n app describe pod <name>` for the Events section (ImagePullBackOff /
OOMKilled / liveness-probe-failed / bad env var) → `kubectl logs --previous`
for the crash trace.

---

## Day 40 Demo

Scenario S4 (multi-agent fleet drill) is the centerpiece: push a bad commit →
Agent B flags it and posts to the blackboard → deploy it anyway → alert fires →
Agent A cites Agent B's warning in Discord. Recording:
`capstone-fleet-drill-final.mp4` (committed in the hub repo
`chautv-proops2026`, commit `0489108`). Full rehearsal notes and talk track:
hub repo `memory/day-37-rehearsal-notes.md` and `memory/day-34-demo-flow.md`.

---

## Key Memory Files

Full map: `memory/INDEX.md`. Don't duplicate its contents here — if you're
about to list files, put them there instead.

---

## Session Behavior

**Hub sync check** — at the start of every session, read
`/Users/mac/Desktop/chautv-proops2026/memory/skills-ledger.md` and scan for
`**First solved:**` lines tagged `#new`. If found, stop and ask whether to run
`!hub-sync` before continuing — new hub patterns may make an IRD stale here.

**Auto-skill rule** — call `/save-skill` immediately (don't wait to be asked)
whenever you solve a non-obvious problem that isn't already in the hub's
skills-ledger and would've saved 10+ minutes if known earlier.

**Commands:** `/start-session`, `/save-skill`, `/report`, `!hub-sync`,
`!scope-pivot`, `/deploy-dev` (manual EKS build→push→deploy, see
`.claude/commands/deploy-dev.md` — note this targets the EKS pipeline above,
same missing-cluster caveat applies).

**Cross-service rule placement:** a rule that applies to all 5 services goes
in `docs/docs/IRD-000.md` (Notion), never only in a service's own CLAUDE.md.

---

## Notion

DOP-001 (product): https://www.notion.so/341dde5fafa981fcab12ffb95ef3d115 —
full IRD index (IRD-000 through IRD-004) is linked from there; not duplicated
here.
