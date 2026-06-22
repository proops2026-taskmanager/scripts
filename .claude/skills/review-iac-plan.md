# review-iac-plan

When invoked, a PR has changed Terraform files and an engineer commented `/review-plan`.
Your job: fetch the terraform plan artifact, classify each resource change by risk, post a structured review as a PR comment.

---

## Trigger

PR comment `/review-plan` → GHA `review-plan.yml` (runs `terraform plan`, uploads artifact) → fleet `/iac-plan-review`.

Payload fields:
- `PAYLOAD.repo` — `owner/repo`
- `PAYLOAD.pr_number` — integer
- `PAYLOAD.run_id` — integer (GHA run that uploaded the `terraform-plan` artifact)

---

## Your job

**Step 1.** Download the plan artifact:
```bash
gh run download <PAYLOAD.run_id> --name terraform-plan \
  --dir /tmp/plan-<PAYLOAD.run_id> --repo <PAYLOAD.repo>
```

**Step 2.** Read `/tmp/plan-<PAYLOAD.run_id>/plan.txt`

**Step 3.** Parse the summary line: `Plan: X to add, Y to change, Z to destroy`

**Step 4.** For each resource in the plan, classify: `ADD` / `CHANGE` / `DESTROY` / `REPLACE`

**Step 5.** Scan for high-risk patterns:

| Pattern | Risk |
|---------|------|
| `aws_security_group_rule` with `0.0.0.0/0` added | HIGH |
| `aws_db_instance` REPLACE or DESTROY | HIGH |
| `aws_s3_bucket` DESTROY | HIGH |
| `aws_instance` `instance_type` CHANGE | MED |
| Any other CHANGE | LOW |
| ADD only | LOW |

**Verdict rules:** any HIGH → `Block` · any MED + no HIGH → `Caution` · all LOW/ADD → `OK to apply`

**Step 6.** Post the structured review as a PR comment:
```bash
gh pr comment <PAYLOAD.pr_number> --repo <PAYLOAD.repo> --body "<review>"
```

Output format: `## Terraform plan review` → table (Action | Resource | Risk) → `### Verdict` (Block/Caution/OK to apply) → `### Notes` (1–2 sentences on highest-risk item).

---

## Safe / Risky

**Safe (no confirmation needed):**
- `gh run download / view`
- `gh pr view / comment` — read + post comment only
- `terraform plan / show` — read-only only
- File reads, `git log / diff`

**NEVER (even if explicitly asked):**
- `terraform apply`
- `terraform destroy`
- Editing `.tf` files
- `gh pr close / merge / edit`

---

## Failure mode

If artifact download fails or `plan.txt` is empty or unreadable, post:

> Plan artifact unavailable — run `/review-plan` again after the GHA workflow completes.

The verdict is advisory. A human still clicks apply.
