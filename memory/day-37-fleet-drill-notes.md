# Day 37 Fleet Drill — Operational Notes

> Condensed from the hub repo's `memory/day-37-rehearsal-notes.md` (full talk
> track + demo script live there). This file keeps only what a session in
> *this* repo needs to operate the fleet/deploy correctly.

## Proven sequence (AC-05 drill, PR #22, SHA `280e300f`)

Push branch (test-class bug) → open PR → CI fails → `/why-failed` comment →
Agent B posts PR reply + `/watch` entry → deploy that SHA to k3s → fire alert
→ Agent A reads blackboard, cites Agent B in Discord. Core sequence once
infra is healthy: **~3 min**. Re-run live 2026-07-03, recorded successfully.

## Known operational gotchas

1. **Claude OAuth on the EC2 box can go empty** (`accessToken`/`refreshToken`
   wiped to `""`) after a fleet restart. Cannot be fixed non-interactively —
   SSH in, run `claude`, `/login`, complete the browser flow.
2. **Deploying a "flagged commit" does not mean rebuilding.** The real
   `capstone-app` image is `ghcr.io/chau11ece/capstone-app:bootstrap`
   (exposes `/health` on 8080). Retag it under the target SHA directly on the
   registry — `docker buildx imagetools create --tag ghcr.io/chau11ece/capstone-app:<sha> ghcr.io/chau11ece/capstone-app:bootstrap`
   — then `kubectl rollout restart deployment/capstone-app -n app`. Do not
   rebuild from the repo-root placeholder Dockerfile — it has no `/health`.
3. **containerd can serve a stale cached image under a reused tag** even when
   the registry digest is correct (`imagePullPolicy: IfNotPresent` never
   re-checks). Fix: `sudo k3s crictl rmi <image:tag>` on the node, then
   rollout restart.
4. **`ec2-user` cannot read `/etc/rancher/k3s/k3s.yaml`** (root-owned) — this
   is why Agent A's `kubectl rollout undo` is PROPOSED, never executed. Use
   `sudo kubectl` for manual operator commands from the EC2 box.
