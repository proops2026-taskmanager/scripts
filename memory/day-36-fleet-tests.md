# Day 36 Fleet Test Matrix

**Date:** 2026-06-22 (initial) · Updated 2026-06-27

| Agent | Case | Trigger | Expected | Actual | Pass |
|-------|------|---------|----------|--------|------|
| A | A1 — clean | Smoke POST to `/alert` with `High5xxErrorRate` payload (namespace: taskmanager-dev) | Agent wakes, posts diagnosis to Discord | ✅ Agent dispatched, Discord notified. Diagnosis: "namespace taskmanager-dev not found on k3s" — correct behavior for smoke payload (only `app` ns exists in k3s cluster) | ✅ |
| A | A2 — noise gate | Send identical payload to `/alert` 3 times within 10 min (locally, no Alertmanager needed) | Hit 1+2 → dispatch; Hit 3 → `[noise-gated]` silenced | ✅ 2026-06-27: fleet.log shows `[dispatch] pid=93102`, `[dispatch] pid=93146`, `[noise-gated] hash=3da14e01f3be hits=3`. Noise gate confirmed at NOISE_LIMIT=3. | ✅ |
| B | B1 — clean | PR #15 branch `test/agent-b-b1` has `calculateDueDate` medium=7days bug → CI fails → comment `/why-failed` on PR | PR comment from agent: names test file + test name + line | ✅ Agent posted diagnosis to https://github.com/proops2026-taskmanager/scripts/pull/15#issuecomment-4770647487 — root cause: `calculateDueDate()` medium urgency returns 7 days (line 22), fix: add `medium` branch returning 3 days | ✅ |
| B | B2 — multiple failures | PR #20 branch `test/agent-b-b2`: Bug 1 = `validateTaskStatus` missing `'completed'` (task-api.js:14); Bug 2 = `priorityFromScore(5)` returns LOW instead of MEDIUM (priority-service.js:22). Both show in CI log. Comment `/why-failed`. | Agent picks EARLIEST failed assertion, names file+line | ✅ 2026-06-27: Agent posted to PR #20 — "Failing step: `npm test` (ci/build). Root cause: `validateTaskStatus('completed')` returns false at `task-api.js:14`." Correctly prioritised Bug 1 (first failure in output). Also noted Bug 2. PR #20 issuecomment-4818887622 + 4818892862 | ✅ |
| C | C1 — safe plan | PR #21 branch `test/agent-c-c1`: `iac/plan.txt` = add 3 tags to `aws_instance.app` (1 to change, 0 to destroy). Comment `/review-plan`. | Review comment with "OK to apply" verdict | ✅ 2026-06-27: Agent posted to PR #21 — "Verdict: OK to apply — all changes are low-risk. Only change: adding Project/Owner/CostCentre tags to aws_instance.app." PR #21 issuecomment-4818921024 | ✅ |
| C | C2 — risky plan | PR #17 branch `test/agent-c-risky-iac` adds `aws_security_group_rule` with `0.0.0.0/0` all-ports + instance type bump → comment `/review-plan` | Review comment with "Block" verdict + names the SG rule | ✅ Agent posted Block verdict to https://github.com/proops2026-taskmanager/scripts/pull/17#issuecomment-4770736185 — HIGH risk: `aws_security_group_rule.app_ingress_all` opens all ports 0–65535 to 0.0.0.0/0; MED risk: instance stop/start for t3.small→t3.medium | ✅ |

## Summary

- Total: 6 cases
- Pass: **6/6** ✅ (A1 ✅ A2 ✅ B1 ✅ B2 ✅ C1 ✅ C2 ✅)
- All agents proven end-to-end

## Key Issues Resolved — Day 36 (2026-06-22)

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| GHA workflows always `skipped` | `if: \|` YAML block scalar preserves newline in expression → evaluates to unknown condition | Changed to `if: "..."` quoted single-line string |
| Workflows not on default branch | `issue_comment` only activates on default branch (main) | PR #16 → merged workflows to main |
| Skill files missing after branch switch | Files committed on `develop`; checkout to main/fix/* removed them | Stay on `develop` during fleet operation |
| Agent B first run skipped triage | PR description said "intentional failing test" → agent correctly treated as known issue | Updated PR description to neutral text |
| review-plan.yml needed AWS OIDC | No OIDC role set up | Removed AWS auth; PR branch embeds `iac/plan.txt` directly |

## Key Issues Resolved — Day 57 (2026-06-27)

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| FLEET_WEBHOOK_URL secret wrong TLD | `gh secret set` with `\|\|` — first command set `.app` TLD (not `.dev`); `\|\|` never ran the correct URL | Always use explicit `gh secret set` without `\|\|` fallback |
| Agent C `review-iac-plan` skill not found | fleet.py prompt "Run the X skill" triggers Skill tool lookup (system registry) — skill not in registry | Changed fleet.py dispatch prompt to "Read the skill file at `.claude/skills/X.md` and follow its instructions exactly" |
| A2 test needed Alertmanager | Original test design assumed Alertmanager → fleet pipeline | Redesigned: noise gate verified locally by sending 3 identical POSTs directly |
