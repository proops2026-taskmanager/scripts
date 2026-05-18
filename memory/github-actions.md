# GitHub Actions — CI/CD Foundations

**First used:** Day 31 (trainer HTML Day 23) — task-service CI pipeline
**Connects to:** [[git-workflows]] (branch protection fires GHA triggers), [[kubernetes-project]] (Day 24+ deploys here)

---

## §1 — The 4 Foundations

Every CI/CD system — GitHub Actions, Jenkins, GitLab CI — maps to these 4 concepts:

| Foundation | GHA Keyword | Jenkins Equivalent | What It Does |
|------------|-------------|-------------------|--------------|
| **Trigger** | `on:` | `triggers {}` / webhook | When the pipeline fires (push, PR, schedule, manual) |
| **Runner** | `runs-on:` | `agent {}` | The machine that executes the jobs (GitHub-hosted or self-hosted) |
| **Jobs + Steps** | `jobs:` → `steps:` | `stages {}` → `steps {}` | The units of work; jobs can run parallel or sequential |
| **Artifact propagation** | `actions/upload-artifact@v4` | `archiveArtifacts` | Passing build outputs (compiled binaries, test reports) between jobs or to downstream workflows |

**Mental model:** Trigger → assigns Runner → Runner executes Jobs → Jobs produce Artifacts.

---

## §2 — Canonical Minimal Skeleton

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - run: npm ci
      - run: npm test
```

**Rules baked into this skeleton:**
- `actions/checkout@v4` is ALWAYS first — runner starts with empty workspace
- `cache: 'npm'` keys on `package-lock.json` hash → ~10× faster on re-runs
- `npm ci` not `npm install` — deterministic, fails hard on lock file drift

---

## §3 — Project-Specific Commands (task-service)

| Step | Command | Notes |
|------|---------|-------|
| Install | `npm ci` | Reads `package-lock.json`; fails if lock is stale |
| Build (lint job) | `npm run build` → `tsc` | TypeScript strict mode compile check |
| Test | `npm test` → `jest --runInBand --forceExit` | `--runInBand`: sequential (needed for shared DB state); `--forceExit`: kills Jest after done |
| Test env | `DOTENV_CONFIG_PATH=.env.test` | jest setupFile loads dotenv; CI overrides `DATABASE_URL` via env block so `.env.test` is ignored |

**PostgreSQL service required in test job:**
```yaml
services:
  postgres:
    image: postgres:15-alpine
    env:
      POSTGRES_USER: testuser
      POSTGRES_PASSWORD: testpass
      POSTGRES_DB: tasks_test_db
    ports:
      - 5432:5432
    options: >-
      --health-cmd pg_isready
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5
env:
  DATABASE_URL: postgresql://testuser:testpass@localhost:5432/tasks_test_db
```

**Why override DATABASE_URL:** `.env.test` uses port 5434 (local dev). CI service always binds to 5432. dotenv does not overwrite already-set env vars — so setting it in the workflow env block takes precedence without touching `.env.test`.

---

## §4 — Job Structure Rules

| Pattern | When to Use | GHA Syntax |
|---------|-------------|------------|
| **Parallel (default)** | Independent concerns: lint, test, security scan | Just name multiple jobs — no extra syntax needed |
| **Sequential** | True dependency: deploy must wait for tests; test must wait for lint | Add `needs: [job-name]` to the dependent job |

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps: [...]

  test:
    runs-on: ubuntu-latest
    needs: lint        # test job waits for lint to succeed
    steps: [...]
```

**Rule:** Never make all jobs sequential "to be safe" — pipeline takes 10× longer for no gain. Only add `needs:` when there is a true data or quality dependency.

---

## §5 — Triggers I Will Use

| Trigger | When I Use It | Notes |
|---------|---------------|-------|
| `push` | Every commit to any branch | Default; always included |
| `pull_request` | PR opens, re-push to PR branch | Runs on the merge commit (not PR head); secrets blocked on fork PRs |
| `workflow_dispatch` | Manual "run now" button in Actions tab | Add `inputs:` for parameterized runs (e.g., target env) |
| `schedule` | Nightly builds, dependency checks | Cron syntax: `'0 2 * * *'` = 2am UTC daily |

**Fork PR security:** `pull_request` from a forked repo does NOT get access to repo secrets — by design. Use `pull_request_target` only if you fully understand the security implications (it runs in the base repo context).

---

## §6 — Secrets Rules

**NEVER:**
- Commit any secret value to YAML — even `"placeholder"` normalizes bad habits
- `echo "${{ secrets.NAME }}"` — masking can be defeated with `base64` tricks
- Put secrets in `env:` at workflow level if only one job needs them — scope to the job

**ALWAYS:**
- Store in: GitHub repo → Settings → Secrets and variables → Actions → New repository secret
- Reference via: `${{ secrets.NAME }}` inside `env:` or `with:` blocks
- Verify masking: check that log shows `***` not the raw value
- Print length to verify without leaking: `echo "secret length: ${#SESSION_SECRET}"`

**Secrets plan for Days 24-25:**

| Secret Name | Day | Purpose |
|-------------|-----|---------|
| `SESSION_SECRET` | Day 23 ✅ | Demonstrate masking; used in task-service app |
| `DOCKERHUB_USERNAME` | Day 24 | `docker/login-action` |
| `DOCKERHUB_TOKEN` | Day 24 | `docker/login-action` |
| `AWS_ACCESS_KEY_ID` | Day 24/25 | ECR push via `aws-actions/configure-aws-credentials` |
| `AWS_SECRET_ACCESS_KEY` | Day 24/25 | ECR push |
| `DISCORD_WEBHOOK` | Day 24 | Failure notifications |

---

## §7 — Today's Real Errors (Day 31)

| Error | Root Cause | Fix |
|-------|-----------|-----|
| `non-fast-forward` push rejected | Remote had `9ddba9d add task service` commit added after our local diverged from `4f18045` | `git pull origin main --no-rebase` → resolved conflict in `tasks.ts` (kept HEAD = full G-06 implementation), merged `ioredis` dep from remote |
| `CONFLICT (content): tasks.ts` | Remote's minimal version of routes vs our full G-06 implementation | Kept HEAD entirely — remote was an older/partial version; discarded `=======`/`>>>>>>>` markers |
| IDE warning `Context access might be invalid: SESSION_SECRET` | VS Code GitHub Actions extension can't verify secret exists in repo settings at edit time | Not an error — false positive. Secret added via `gh secret set` before push |

---

## §8 — Anti-Patterns

| Anti-pattern | Why It's Wrong | What to Do Instead |
|--------------|---------------|-------------------|
| `npm install` in CI | Can silently update `package-lock.json`; non-deterministic builds | Always use `npm ci` |
| No `actions/setup-node@v4` | Relies on whatever Node version happens to be on the runner | Pin with `node-version: '20'` |
| No `cache: 'npm'` | Every run downloads all dependencies from scratch (~60s wasted) | Add `cache: 'npm'` — keys on lock file hash |
| `@latest` action tags | Breaking changes in new action versions silently break your pipeline | Pin to `@v4`, `@v3` etc. |
| All jobs sequential with `needs:` | Pipeline takes 10× longer; parallelism is free on GitHub-hosted runners | Parallel by default; `needs:` only for true dependencies |
| Giant single-job pipeline | One failure kills everything; no visibility into which concern failed | Split by concern: lint / test / build / deploy |
| Hardcoded secrets in YAML | Visible in git history forever; can't rotate without code change | `${{ secrets.NAME }}` only |

---

## §9 — Connects To

- **[[git-workflows]]** — branch protection rules determine when CI triggers (push to main requires PR + CI pass)
- **[[kubernetes-project]]** — Day 24+: CI adds Docker build + ECR push step; K8s deployment triggered from pipeline
- **IRD-31** — locked decisions: `ubuntu-latest`, `@v4` pins, `npm ci`, parallel default, secrets in Settings only
