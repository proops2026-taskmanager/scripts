# SonarCloud — Quality Gate: The 5th Required Check

**First used:** Day 34 (trainer HTML Day 26)
**Connects to:** [[github-actions]] (sonar job in ci.yml), [[git-workflows]] (5th ruleset check blocks merge)

---

## §1 — The 4 Quality Dimensions

SonarCloud classifies every finding into one of four dimensions:

| Dimension | Severity | What It Catches | Example from This Project |
|-----------|----------|-----------------|--------------------------|
| **Bugs** | Critical / Major | Logic errors that cause incorrect behavior; reliability failures | S1764: `role === role` in `src/bad-code.ts:6` — identical operands always return true; Quality Gate fails on any new Bug |
| **Vulnerabilities** | Critical / Major | Security weaknesses exploitable by attackers | S5659: JWT algorithm not validated (`jwt.verify` without `algorithms` option in `api-gateway/src/jwt.ts`) — can allow algorithm-confusion attacks |
| **Code Smells** | Major / Minor | Maintainability issues; increases cognitive complexity | S2228: `console.error(err)` in route catch blocks (task-service, user-service) — logging sensitive error objects to production logs |
| **Coverage** | % | Percentage of new code exercised by tests | Measured via `lcov.info` artifact uploaded from test job; "Sonar way" gate requires ≥80% on new code |

**Mental model:** Bugs break things. Vulnerabilities get you hacked. Code Smells slow future devs down. Coverage shows how much of the new code has actually been exercised.

---

## §2 — Quality Gate: "Sonar way" Logic

The "Sonar way" gate is the SonarCloud default. It gates on **NEW code only** (the delta introduced by this PR or branch), not the entire historical codebase.

| Condition | Threshold | Effect if Violated |
|-----------|-----------|-------------------|
| New Bugs | 0 | Gate FAILS |
| New Vulnerabilities | 0 | Gate FAILS |
| New Security Hotspots reviewed | 100% | Gate FAILS |
| Duplication on new code | ≤3% | Gate FAILS |
| Coverage on new code | ≥80% | Gate FAILS |

**Why new-code-only matters:** A legacy codebase has hundreds of tech-debt issues. Gating on ALL code would make every PR fail permanently. "Sonar way" gates only on what you introduced — you own your changes.

**Status values returned by `/api/qualitygates/project_status`:**
- `OK` → gate passed; merge unblocked
- `ERROR` → gate failed; merge blocked
- `NONE` → analysis not yet complete; poll again
- `WARN` → deprecated; treated as OK in "Sonar way"

---

## §3 — `sonar-project.properties` Template (TypeScript/Node multi-service)

```properties
sonar.projectKey=proops2026-taskmanager_scripts
sonar.organization=proops2026-taskmanager
sonar.host.url=https://sonarcloud.io

# Source roots — include every service directory cloned in the CI job
sonar.sources=src,task-service/src,user-service/src,api-gateway/src,frontend-service/src

# Test inclusions — SonarCloud needs to know which files are tests to exclude
# from coverage calculation denominator
sonar.tests=task-service/src,user-service/src,api-gateway/src,frontend-service/src
sonar.test.inclusions=**/*.test.ts,**/*.spec.ts,**/*.test.tsx

# Exclusions — never analyse compiled output, node_modules, or test files as source
sonar.exclusions=**/node_modules/**,**/dist/**,**/build/**,**/*.test.ts,**/*.spec.ts,**/*.test.tsx

# Coverage paths — must match where the test job uploads lcov.info artifacts
sonar.javascript.lcov.reportPaths=task-service/coverage/lcov.info,user-service/coverage/lcov.info,api-gateway/coverage/lcov.info,frontend-service/coverage/lcov.info
sonar.typescript.lcov.reportPaths=task-service/coverage/lcov.info,user-service/coverage/lcov.info,api-gateway/coverage/lcov.info,frontend-service/coverage/lcov.info
```

**Key constraints:**
- `sonar.sources` lists directories relative to the repo root — they must physically exist on the runner before `sonar-scanner` runs (clone them first)
- `sonar.test.inclusions` must match the actual test file pattern used by Jest/Vitest — wrong patterns cause SonarCloud to count test code as source and inflate coverage percentages
- Both `javascript.lcov` and `typescript.lcov` keys are needed for TypeScript projects

---

## §4 — GHA Sonar Job (ci.yml snippet)

```yaml
sonar:
  name: SonarCloud Code Analysis         # ← name must match ruleset check name exactly
  runs-on: ubuntu-latest
  needs: [test]                          # waits for test job to upload coverage artifacts

  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0                   # MANDATORY — shallow clone breaks blame + PR decoration

    - name: Clone service repos          # services are in separate repos; must clone before scan
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      run: |
        BASE="https://x-access-token:${GH_TOKEN}@github.com/proops2026-taskmanager"
        git clone --depth 1 "${BASE}/task-service.git"    task-service
        git clone --depth 1 "${BASE}/user-service.git"    user-service
        git clone --depth 1 "${BASE}/api-gateway.git"     api-gateway
        git clone --depth 1 "${BASE}/frontend-service.git" frontend-service

    - name: Download task-service coverage    # coverage artifacts from test job
      uses: actions/download-artifact@v4
      with:
        name: coverage-task-service
        path: task-service/coverage

    # ... repeat for user-service, api-gateway, frontend-service ...

    - name: SonarCloud scan
      env:
        SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      run: |
        # Set PR context so SonarCloud decorates the PR correctly
        EXTRA_ARGS=""
        if [ -n "${{ github.event.pull_request.number }}" ]; then
          EXTRA_ARGS="-Dsonar.pullrequest.key=${{ github.event.pull_request.number }} \
            -Dsonar.pullrequest.branch=${{ github.head_ref }} \
            -Dsonar.pullrequest.base=${{ github.base_ref }}"
        else
          EXTRA_ARGS="-Dsonar.branch.name=${GITHUB_REF_NAME}"
        fi
        docker run --rm \
          -e SONAR_HOST_URL=https://sonarcloud.io \
          -e SONAR_TOKEN="${SONAR_TOKEN}" \
          -e GITHUB_TOKEN="${GITHUB_TOKEN}" \
          -v "$(pwd):/usr/src" \
          sonarsource/sonar-scanner-cli \
          sonar-scanner ${EXTRA_ARGS}

    - name: Check Quality Gate
      env:
        SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
      run: |
        # Poll Quality Gate — sonar.qualitygate.wait=true doesn't work for PR analyses
        # (stores under pullRequest=N, not branch=) so we poll the correct endpoint
        if [ -n "${{ github.event.pull_request.number }}" ]; then
          QUERY="pullRequest=${{ github.event.pull_request.number }}"
        else
          QUERY="branch=${GITHUB_REF_NAME}"
        fi
        for i in $(seq 1 10); do
          STATUS=$(curl -sf -u "${SONAR_TOKEN}:" \
            "https://sonarcloud.io/api/qualitygates/project_status?projectKey=proops2026-taskmanager_scripts&${QUERY}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['projectStatus']['status'])" 2>/dev/null || echo "NONE")
          echo "Attempt ${i}/10: status=${STATUS}"
          if   [ "${STATUS}" = "OK"    ]; then echo "Quality Gate PASSED"; exit 0; fi
          if   [ "${STATUS}" = "ERROR" ]; then echo "Quality Gate FAILED"; exit 1; fi
          sleep 10
        done
        echo "Timed out"; exit 1
```

---

## §5 — Top-3 Real Issues (from first scan — to be updated after AC-06)

| # | File | Line | Rule | Dimension | Fix Date |
|---|------|------|------|-----------|----------|
| 1 | `src/bad-code.ts` | 6 | S1764 — Identical expressions on both sides of operator | BUG | Week 6 (deliberately introduced for drill; delete file) |
| 2 | *(fill after first scan)* | | | | |
| 3 | *(fill after first scan)* | | | | |

**Note:** After the bad-PR drill is complete (`src/bad-code.ts` deleted), items 2 and 3 will be real findings from the service code scan. Update this table from the SonarCloud dashboard → Issues tab after first clean-branch run.

---

## §6 — Repository Ruleset

- **Ruleset name:** Day 22 Ruleset (proops2026-taskmanager/scripts)
- **URL:** https://github.com/proops2026-taskmanager/scripts/rules/16692751
- **5th check name in ruleset:** `SonarCloud Code Analysis`
  - Must match the `name:` field of the `sonar` job in `ci.yml` exactly
  - Before adding: push at least one commit so the check name appears in Settings autocomplete

**Required checks after Day 34:**
1. `lint`
2. `test`
3. `build-image` (×4 matrix)
4. `deploy`
5. `SonarCloud Code Analysis`

---

## §7 — Real Errors Hit + Fixes

| Error | Root Cause | Fix |
|-------|-----------|-----|
| Scanner exits with **code 3** — no analysis completes | SonarCloud Automatic Analysis was enabled simultaneously with the manual CI scanner — both ran and conflicted | **Disabled Automatic Analysis** in SonarCloud UI: Administration → Analysis Method → toggle OFF. No code fix exists; this is UI-only. |
| `sonar.qualitygate.wait=true` always reports gate as **NONE** / **OK** even when PR has bugs | `qualitygate.wait=true` queries `/project_status?branch=` but PR analyses are stored under `?pullRequest=N` — the branch query returns "project not found" for PRs | Removed `qualitygate.wait=true`; replaced with explicit API poll step that detects PR vs branch context and queries the correct endpoint |
| `sonar.pullrequest.key` not set on push trigger | `github.event.pull_request.number` is empty on `push:` events; only set on `pull_request:` events | Guard with `if [ -n "${{ github.event.pull_request.number }}" ]`; fall back to `sonar.branch.name` on push |
| `sonar` job skipped in ruleset check | `jobs.sonar:` key was `sonar` but ruleset required exact string `"SonarCloud Code Analysis"` | Added `name: SonarCloud Code Analysis` field to the sonar job — `name:` controls what GitHub reports to the ruleset; `jobs.sonar` is just the internal job ID |
