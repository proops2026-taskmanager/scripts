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

## §3 — Project-Specific Commands (scripts repo — Day 31)

This repo is a scripts + infrastructure repo. The real CI commands are shellcheck + JSON validation, not npm test.

**`lint` job:**

| Step | Command | Notes |
|------|---------|-------|
| Install shellcheck | `sudo apt-get install -y shellcheck` | Ubuntu runners have apt; shellcheck not pre-installed |
| Lint all shell scripts | `shellcheck -x --severity=warning scripts/*.sh scripts/lib/*.sh ecr-push.sh healthcheck.sh` | `-x` follows source statements; `--severity=warning` ignores SC1091 info messages about missing sourced files |

**`validate` job (needs: lint):**

| Step | Command | Notes |
|------|---------|-------|
| Setup Node | `actions/setup-node@v4` node 20, `cache: 'npm'` | Pins toolchain; cache keys on `package-lock.json` hash |
| Install | `npm ci` | Proves lockfile is committed and in sync |
| Validate ECS task defs | `for f in ecs/task-defs/*.json; do python3 -m json.tool "$f" > /dev/null; done` | Malformed task def = silent `register-task-definition` failure in prod |

**For task-service tests (Day 24+ — when services are in CI scope):**
```yaml
services:
  postgres:
    image: postgres:15-alpine
    env:
      POSTGRES_USER: testuser
      POSTGRES_PASSWORD: testpass
      POSTGRES_DB: tasks_test_db
    ports:
      - 5434:5432        # map to 5434 to match .env.test DATABASE_URL
    options: >-
      --health-cmd pg_isready
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5
```
Test command: `DOTENV_CONFIG_PATH=.env.test jest --runInBand --forceExit`

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
| `DOCKERHUB_TOKEN` | Day 31 ✅ | Added today — proved `***` masking; length 19 confirmed in log |
| `DOCKERHUB_USERNAME` | Day 24 | `docker/login-action` |
| `AWS_ACCESS_KEY_ID` | Day 24/25 | ECR push via `aws-actions/configure-aws-credentials` |
| `AWS_SECRET_ACCESS_KEY` | Day 24/25 | ECR push |
| `DISCORD_WEBHOOK` | Day 24 | Failure notifications |

---

## §7 — Today's Real Errors (Day 31)

| Error | Root Cause | Fix |
|-------|-----------|-----|
| `Dependencies lock file is not found` | `package-lock.json` existed locally but was never committed — `actions/setup-node@v4 cache: 'npm'` requires it to be in the repo | `git add package-lock.json && git commit` |
| `ENOENT: no such file or directory, open 'package.json'` | `package.json` also untracked — CI clones the repo and finds neither file | `git add package.json && git commit` |
| `SC2148: Tips depend on target shell and yours is unknown` (shellcheck error) | Library files (`scripts/lib/*.sh`) had no shebang and no `# shellcheck shell=bash` directive — shellcheck couldn't determine the target shell | Added `# shellcheck shell=bash` as first line of each lib file |
| `SC2034: PHASE appears unused` (shellcheck warning) | `PHASE="main"` in `deploy-eks.sh` was set but never read — dead variable from refactoring | Removed the dead assignment |
| `shellcheck exit: 1` despite only info messages | Default shellcheck severity includes `info` (SC1091 source-not-found) — exit 1 on any message | Added `--severity=warning` flag to ignore info-level messages |

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
