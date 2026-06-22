# Day 36 Fleet Test Matrix

**Date:** 2026-06-21

| Agent | Case | Trigger | Expected | Actual | Pass |
|-------|------|---------|----------|--------|------|
| A | A1 — clean | `kubectl set image deployment/<name> main=ghcr.io/<org>/<name>:bogus` | Alert fires within 5 min · agent posts ImagePullBackOff diagnosis + rollback suggestion to Discord | _(fill in)_ | ⬜ |
| A | A2 — ambiguous | `kubectl delete pod -l app=<name> --grace-period=0` in loop for 30 sec | Pod restart loop alert fires · agent posts diagnosis OR "ambiguous — engineer needed" | _(fill in)_ | ⬜ |
| B | B1 — clean | Push commit with syntax error in test file → PR fails on test step → comment `/why-failed` | PR comment from agent: names test file + test name + line | _(fill in)_ | ⬜ |
| B | B2 — multiple failures | Push commit with 2 unrelated bugs (lint + test) → comment `/why-failed` | Agent picks EARLIEST failed step OR posts "multiple failures, engineer needed" | _(fill in)_ | ⬜ |
| C | C1 — safe plan | PR adds 1 tag to existing resource (1 to change) → comment `/review-plan` | Review comment with "OK to apply" verdict | _(fill in)_ | ⬜ |
| C | C2 — risky plan | PR widens `aws_security_group_rule` to `0.0.0.0/0` → comment `/review-plan` | Review comment with "Block" verdict + names the SG rule | _(fill in)_ | ⬜ |

## Summary

- Total: 6 cases
- Pass: ___/6
- Decision: 6/6 = ready for Day 37 · 4/6 = fix gaps · <4/6 = drop one agent + retry
