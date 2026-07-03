# triage-ci-failure

When invoked, a GitHub Actions CI run has failed and an engineer commented `/why-failed` on a PR.
Your job: identify the FIRST failing step, determine its root cause, post a 3-line diagnosis as a PR comment.

---

## Trigger

PR comment `/why-failed` → GHA `why-failed.yml` → fleet `/ci-failed`.
Payload: `PAYLOAD.repo` (`owner/repo`), `PAYLOAD.pr_number`, `PAYLOAD.run_id`.

---

## Your job (≤ 5 min budget, then stop)

**Step 1.** Fetch the failed run log: `gh run view <PAYLOAD.run_id> --log-failed --repo <PAYLOAD.repo>`

**Step 2.** Identify the FIRST failed step. Stop at the first red-X — do NOT enumerate the cascade.
Signatures: `lint` → `<file>:<line>: <rule>` · `test` → `FAILED tests/... AssertionError` ·
`build` → `Step N/N — RUN <cmd>` then `ERROR` · `deploy` → `Error from server` / `ImagePullBackOff`.

**Step 3.** Compose a 3-line diagnosis:
```
**Failing step:** <exact step name from the run>
**Root cause:** <one sentence>
**Fix:** <concrete — file:line or exact command to run>
```

**Step 4.** Post the diagnosis as a PR comment:
```bash
gh pr comment <PAYLOAD.pr_number> --repo <PAYLOAD.repo> --body "<3-line diagnosis>"
```

**Step 5.** If and only if root cause class is `test`: post a watch hint so Agent A can correlate.
```bash
# Get the commit SHA for this run
SHA=$(gh run view <PAYLOAD.run_id> --repo <PAYLOAD.repo> --json headSha --jq '.headSha')

# Post to the fleet blackboard
curl -s -X POST http://localhost:9999/watch \
  -H "Content-Type: application/json" \
  -d "{\"sha\":\"$SHA\",\"reason\":\"skipped test gate — dangerous image built\",\"posted_by\":\"agent-b\"}"
```
Skip Step 5 entirely if root cause class is `lint`, `build`, or `deploy`.

**Step 6.** Stop. One failing step identified = job done.

---

## Output

PR comment on `<PAYLOAD.repo>/pull/<PAYLOAD.pr_number>` containing the 3-line diagnosis.

---

## Safe / Risky

**Safe (no confirmation needed):**
- `gh run view / list / download-logs`
- `gh pr view / comment` — read + post comment only
- `git log / diff / show`
- Reading any file in the repo

**Risky (MUST ASK before doing):**
- `gh pr close / merge / edit`
- `git push`
- Editing any source file

**NEVER:**
- Anything not listed under Safe or Risky above

---

## Failure mode

If root cause is unclear after 3 minutes, or multiple unrelated failures exist, post:
> Multiple failures or unclear — engineer needed. Run: https://github.com/<PAYLOAD.repo>/actions/runs/<PAYLOAD.run_id>

Honest "I don't know" beats a wrong diagnosis every time.
