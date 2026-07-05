# Git Workflows — proops2026-taskmanager

> **⚠️ Status: partially superseded.** This file documents the Day 30/IRD-30
> decision (GitHub Flow — `main` always deployable, `feature/*` branches only).
> In practice the project grew a `develop` integration branch that most
> `feature/*` work merges into first (confirmed via `git branch -a`, 2026-07-05),
> matching **CLAUDE.md's CI/CD section**, which is the authoritative, current
> description of the pipeline (`feature/* → develop → release → main`).
> The commit format, PR/review rules, and branch-protection settings below are
> still accurate and in effect. One gap CLAUDE.md doesn't call out: the
> `release` branch that `app-cd-staging.yml` triggers on has never actually
> been created (confirmed via `git branch -a` / `git log origin/release` —
> no such ref exists), which is a more fundamental reason staging CD has never
> run than the missing `STAGING_BASE_URL`/`KUBE_CONFIG_DATA_STAGING` secrets alone.

## Group

- **Partners:** chau11ece + walter-dmt88
- **Project:** proops2026-taskmanager
- **Repo:** https://github.com/proops2026-taskmanager/scripts
- **IRD:** IRD-30 — https://www.notion.so/362dde5fafa98101a4e9fd142ef27988

---

## Three Decisions

| Axis | Decision | Reason |
|------|----------|--------|
| Branch model | GitHub Flow — `main` is always deployable; all changes via `feature/*` branches | Simplest model for a 2-person team; no release branches needed; compatible with CI/CD on Days 23–24 |
| Code review gate | Pull Request required; 1 approving review; stale approvals dismissed on new commits; no bypass by owners | Enforces shared understanding before merge; prevents unreviewed deploys once Jenkins/GHA runs on every push to main |
| Merge strategy | Squash only — all other merge types disabled in GitHub repo settings | Keeps `git log --oneline main` readable (one commit per PR); required by semantic-release tooling on Day 24 |

---

## Branch Naming

Pattern: `feature/[github-username]/[short-description]`

| Component | Rule | Example |
|-----------|------|---------|
| prefix | always `feature/` | `feature/` |
| username | GitHub handle of the author | `chau11ece` / `walter-dmt88` |
| description | kebab-case, max 5 words | `add-pr-template` |

Full example: `feature/chau11ece/add-pr-template`

Local practice branch: `chautv_devops` — kept local, never pushed. Squash-merged to `main` at end of each session via `scripts/session-sync.sh`.

---

## Commit Format

Format: `type(scope): subject`

- `type` — one of the vocabulary below
- `scope` — component affected (lowercase, no spaces): `task-api`, `auth`, `db`, `readme`, `docker`, `k8s`, `eks`, `terraform`
- `subject` — imperative, present tense, max 72 chars, no period at end

| Type | When to use | Example |
|------|-------------|---------|
| feat | New feature or capability | `feat(task-api): add filter by status` |
| fix | Bug fix | `fix(auth): handle expired JWT correctly` |
| docs | Documentation only | `docs(readme): add branch strategy section` |
| chore | Maintenance, config, tooling | `chore(deps): upgrade express to 4.19` |
| refactor | Code change, no behavior change | `refactor(task-service): extract validation logic` |
| test | Adding or updating tests | `test(task-api): add integration test for POST /tasks` |
| perf | Performance improvement | `perf(db): add index on tasks.status` |
| build | Build system or CI config | `build(docker): add multi-stage Dockerfile` |
| ci | CI/CD pipeline changes | `ci(github-actions): add lint step` |
| style | Formatting only, no logic change | `style(task-service): fix indentation` |

---

## Branch Protection — Actual Settings

Configured in: GitHub → proops2026-taskmanager/scripts → Settings → Branches → Branch protection rule → `main`

| Setting | Value |
|---------|-------|
| Branch name pattern | `main` |
| Require a pull request before merging | ON |
| Required number of approvals before merging | 1 |
| Dismiss stale PR approvals when new commits are pushed | ON |
| Require status checks to pass before merging | ON (no checks configured yet — toggle only) |
| Require conversation resolution before merging | ON |
| Do not allow bypassing the above settings | ON |
| Allow force pushes | OFF |
| Allow deletions | OFF |

---

## Agent Rules

### ALWAYS
- Use `feature/[github-username]/[short-description]` for all PRs
- Write commit messages as `type(scope): subject` (Conventional Commits)
- Open a PR for every change to main — direct pushes are rejected by branch protection
- Use squash merge when merging PRs (GitHub enforces this; do not select other merge types)
- Delete the source branch after merge (GitHub offers the button post-merge)
- After merge: `git checkout main && git pull` to confirm the squash shape
- Reviewer must leave at least one inline comment (not a rubber-stamp approval)

### NEVER
- Never push directly to `main` (protected; will be rejected)
- Never use merge commits or rebase merges (Squash only is configured)
- Never approve a PR without reading the diff
- Never write a commit message that doesn't match `type(scope): subject`
- Never push the `chautv_devops` branch to the remote — it is a local practice branch only
