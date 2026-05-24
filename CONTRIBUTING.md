# Contributing to proops2026-taskmanager

## Before You Start

1. Read `memory/git-workflows.md` — it defines all team git decisions
2. Check the open Linear issues for what's in scope this sprint
3. Make sure branch protection is on before opening a PR (Settings → Branches)

## Branch Naming

```
feature/[github-username]/[short-description]
```

Examples:
- `feature/chau11ece/add-filter-by-status`
- `feature/walter-dmt88/fix-auth-jwt`

## Commit Format

All commits must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): subject
```

Where `type` is one of: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `perf`, `build`, `ci`, `style`.

Example: `feat(task-api): add filter by status endpoint`

## PR Workflow

1. Create branch from `main`: `git checkout -b feature/[username]/[desc]`
2. Make changes, commit with Conventional Commits format
3. Push branch: `git push -u origin feature/[username]/[desc]`
4. Open PR on GitHub — the PR template auto-fills with required sections
5. Tag your partner as reviewer
6. Reviewer must leave at least one inline comment (not rubber-stamp)
7. After approval: merge using **Squash and merge** only
8. Delete source branch after merge

## PR Template Sections

Every PR must fill in all four sections:

- **What** — what does this PR change?
- **Why** — why is this change needed? link the Linear issue
- **How to test** — steps a reviewer can follow to verify
- **Risk** — what could break? rollback plan?

## Merge Strategy

**Squash only.** The repo is configured to disable merge commits and rebase merges.
One squash commit per PR keeps `git log --oneline main` readable.

## After Your PR Merges

```bash
git checkout main
git pull
git branch -d feature/[username]/[desc]
```
