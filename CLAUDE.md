# proops2026-taskmanager — Workspace Root

This directory is the local workspace for the Task Manager mock project.
Each subdirectory is an independent git repo. Open sessions per service, not at the workspace root.

---

## What We're Building

A task tracker REST API + React web UI (Jira-lite).
Stack: Node.js 20 + TypeScript 5 + Express 4 + PostgreSQL 15 + Docker Compose.

**GitHub org:** https://github.com/proops2026-taskmanager

---

## Services

| Repo | Port | Responsibility | Status |
|------|------|---------------|--------|
| `user-service/` | 3001 | Register, login, JWT issuance, bcrypt password hashing | Sprint 1 |
| `task-service/` | 3002 | Task CRUD, status transitions, comments | Sprint 1 |
| `api-gateway/` | 8080 | JWT validation, request routing, CORS | Sprint 1 |
| `frontend-service/` | 3000 | React SPA — Vite + nginx | Sprint 2 |
| `docs/` | — | DOP-001, IRD-000 to IRD-004, sprint plans | Always open first |
| `demo-repository/` | — | GitHub org default / template | Reference only |
| `draft-program/` | — | Planning drafts | Reference only |

---

## Architecture

```
Browser
  ├──HTTP :3000──▶  frontend-service  (React + nginx)
  └──HTTP :8080──▶  api-gateway       (JWT + routing + CORS)
                        ├──▶  user-service  :3001  ──▶  users_db (PostgreSQL 15)
                        └──▶  task-service  :3002  ──▶  tasks_db (PostgreSQL 15)
```

Only api-gateway is exposed to the outside. All other services communicate on internal Docker network `app-net`.

---

## Locked Design Decisions (apply to ALL services)

| Decision | Value |
|----------|-------|
| Error format | `{ "error": "human string" }` — no stack traces, no nested objects |
| JWT algorithm | HS256, 24h expiry, payload `{ sub, role }` |
| JWT enforcement | api-gateway validates and strips Authorization header. Downstream services trust X-User-Id / X-User-Role headers only. |
| Cross-service IDs | Plain UUIDs only. No FK constraints across service boundaries. |
| Status transitions | TODO → IN_PROGRESS → DONE (terminal). Any → CANCELLED (terminal). No backward. |
| PostgreSQL version | 15-alpine |
| Node.js version | 20 LTS |
| bcrypt rounds | 12 |
| TypeScript | 5, strict mode |

---

## Notion Links (System B — Project Docs)

| Document | Notion URL |
|----------|-----------|
| DOP-001 (product) | https://www.notion.so/341dde5fafa981fcab12ffb95ef3d115 |
| IRD-000 (shared standards) | https://www.notion.so/344dde5fafa981c196b4e57212bc28cf |
| IRD-001 (user-service) | https://www.notion.so/341dde5fafa981f2906ae06ef131a347 |
| IRD-002 (task-service) | https://www.notion.so/341dde5fafa98107b9f9de9ecf0dae4d |
| IRD-003 (api-gateway) | https://www.notion.so/341dde5fafa981be8ba2e5840eced914 |
| IRD-004 (frontend-service) | https://www.notion.so/342dde5fafa9812f99bff829422341b9 |

---

## Team

| Person | Sprint 1 Tasks | Sprint 2 Tasks |
|--------|---------------|---------------|
| chau_tv | T-01, T-03, T-05, T-06, T-08, T-09, T-15, T-16, T-19 | F-01, F-03, F-04, F-09 |
| thai_dm | T-02, T-04, T-07, T-10, T-11, T-12, T-13, T-14, T-17, T-18 | F-02, F-05, F-06, F-07, F-08 |

---

## Session Model

This workspace root is NOT a git repo and NOT a working session.
Its CLAUDE.md (this file) auto-loads in every session opened inside any subdirectory.

**SPEC session** → open in `docs/`
- Creating/updating IRDs, /review-docs, sprint planning, Linear issues
- Commits go to the docs git repo

**IMPL session** → open in `user-service/`, `task-service/`, `api-gateway/`, or `frontend-service/`
- Writing code, tests, Dockerfiles
- Commits go to that service's git repo
- Reads IRDs from Notion via MCP — no need to open docs/ simultaneously

docs/ is the SPEC layer (defines contracts). Service repos are the IMPL layer (execute contracts).
docs/ does not control services — it writes specs that service agents read.

---

## Session Start

At the start of every session, before any implementation work:

1. **Check Hub skills-ledger for new patterns**
   Read `/Users/mac/Desktop/chautv-proops2026/memory/skills-ledger.md`.
   Scan every `**First solved:**` line for a `#new` tag.

2. **If `#new` tags are found:**
   Immediately stop and prompt:
   > "Hub skills-ledger has [N] new pattern(s) tagged `#new`: [list skill names].
   > These may affect this project's IRDs. Run `!hub-sync` before continuing?"

   Do not begin any implementation task until the user has responded (yes / skip).

3. **If no `#new` tags are found:**
   Proceed normally. No prompt needed.

**Why:** New patterns saved in the Hub (Docker, health-check, Compose, Node.js standards) may require IRD updates before implementation agents act on stale contracts. Catching this at session start prevents drift.

---

## Contact Points — Where New Rules and Problems Go

When you discover something during implementation, use this table to decide where it goes:

| Discovery type | Where it goes | Session to open |
|---|---|---|
| New cross-service rule (applies to all services) | `docs/docs/IRD-000.md` → Notion | SPEC (docs/) |
| New service-specific rule | That service's IRD + its `CLAUDE.md` | SPEC + IMPL |
| Sprint gate blocker | `docs/docs/sprint-01.md` Integration Protocol table | SPEC (docs/) |
| Agent session behavior rule | This workspace `CLAUDE.md` | Any |
| Bug in another team's service | Linear issue — do NOT touch their code | `/create-linear-issue` |
| Test ordering problem | Service IRD test section + `beforeEach` in test file | IMPL (service/) |

**Rule:** Never put a cross-service rule only in a service `CLAUDE.md`. It must go to IRD-000 so all agents see it.

---

## Auto-Skill Rule

**The agent must call `/save-skill` proactively — never wait to be asked.**

Call `/save-skill` immediately when ALL of the following are true:
1. You solved a non-obvious technical problem during this session
2. The solution involved a workaround, hidden constraint, or surprising AWS/K8s/Terraform behaviour
3. The pattern is NOT already in `/Users/mac/Desktop/chautv-proops2026/memory/skills-ledger.md`
4. Knowing it earlier would have saved 10+ minutes

**Trigger examples that ALWAYS qualify:**
- An AWS API call fails with a non-obvious error → you discover the root cause and fix it
- A Terraform plan shows unexpected drift → you find why and how to suppress it correctly
- A K8s pod fails for a non-obvious reason → you find the exact fix (probe timing, PGDATA path, etc.)
- A CLI flag behaves differently than documented → you find the correct flag or workaround

**The Stop hook in `.claude/settings.json` will remind you at the end of every agent turn.
The PostToolUse hook will signal when a Bash error-then-fix pattern is detected.
Neither hook replaces your judgement — they are reminders, not automation.**

---

## 🛠 Commands

These commands are active in every session opened inside this workspace. Invoke them by name.

| Command | When to run | What it does |
|---------|-------------|-------------|
| `/start-session` | First thing, every session | Loads Hub identity → checks skills-ledger for `#new` tags → reads WIP.md → prints session plan |
| `/save-skill` | After solving a non-obvious problem | Formats pattern → saves to Hub's skills-ledger → appends `#new` for cross-project propagation |
| `/report` | End of every session | Updates WIP.md → checks for unsaved skills → audits git state across all service repos → flags Notion sync |
| `!hub-sync` | After `/save-skill` adds a `#new` tag | Scans skills-ledger for `#new` → proposes diffs to affected IRDs → clears tags after acceptance |
| `!scope-pivot` | When a feature is added or removed mid-sprint | Impact audit across DOP + all IRDs + sprint file → classifies REQUIRED / RECOMMENDED / DEFERRED → applies doc changes |

**Command files:** `.claude/commands/` (local) — `start-session.md`, `save-skill.md`, `report.md`, `hub-sync.md`, `scope-pivot.md`

---

## Integration Protocol Summary

Services build in parallel. Integration is phased and gated.

**Phase 1 (parallel):** Each service passes its own tests → merges to `main`. No waiting.
**Phase 2 (sequential):** api-gateway e2e tests start only after both user-service AND task-service show ✅ in `sprint-01.md`.

**Test setup rule:** Every test block creates its own prerequisites in `beforeEach` / `beforeAll`. Never rely on state from a previous test.

Full rules: [IRD-000 §15](https://www.notion.so/344dde5fafa981c196b4e57212bc28cf)
Sprint gate tracker: `docs/docs/sprint-01.md` → Integration Protocol section

---

