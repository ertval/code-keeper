# Results

- **Updated:** 2026-10-21 11:04 EEST
- **Scope:** the deploy described in `docs/AWS_SETUP.md`, run against AWS account `REDACTED_AWS_ACCOUNT_ID`
  (us-east-1) from the local test GitLab (`root/code-keeper`), plus what the project still lacks for
  the audit.
- **Code:** `main` at `5d9f578`, on zone01 and on the local GitLab.

## Summary

**Staging and production are both deployed and work end to end.** Pipeline 14 passed every job, from
the tests through both Terraform applies, the manual approvals and the three production deploys.
Requests through each environment's load balancer reach the inventory database, and billing orders
go through RabbitMQ (TLS on port 5671) into the billing database.

**Cost:** both environments together cost about $0.79 an hour. The AWS account is now on the paid
plan, and the remaining **$92.02** of credits pays first, which covers about 4.5 days. After that AWS
bills the card, so take both environments down when testing is over (see "Next").

---

## What is live

| | Staging | Production |
|---|---|---|
| Load balancer | `code-keeper-staging-alb-462510820.us-east-1.elb.amazonaws.com` | `code-keeper-production-alb-291653438.us-east-1.elb.amazonaws.com` |
| `GET /health` | `{"status":"healthy"}` | `{"status":"healthy"}` |
| api-gateway | 2 of 2 tasks | 2 of 2 tasks |
| inventory-app | 2 of 2 tasks | 2 of 2 tasks |
| billing-app | 2 of 2 tasks | 2 of 2 tasks |

End-to-end check, run once per environment through the load balancer:

- `POST /api/movies`, `GET /api/movies?title=...` and `DELETE /api/movies/1`: all `HTTP 200`. The
  test movie was deleted again.
- `POST /api/billing` with `{"user_id":"20","number_of_items":"3","total_amount":"9.99"}`:
  `HTTP 200`. Each billing worker logged "Successfully processed and recorded order #1 for user
  '20'". Those two test orders are still in the billing databases.

Images: `docker.io/sntentop/{api-gateway,inventory-app,billing-app}`, tagged with the commit SHA, plus
`production-latest` for the promoted image.

---

## Pipelines on the local GitLab

| Pipeline | Commit | Result | Cause, and what fixed it |
|---|---|---|---|
| 10 | `a8691d8` | Failed at `infra:validate:syntax` | Both Init jobs save to one cache key and overwrite each other, and the plan and apply jobs never ran `terraform init`. Fixed in `7a9611c`: every Terraform job runs `terraform init` itself |
| 11 | `7a9611c` | Failed at `infra:apply:staging` | `FreeTierRestrictionError`: the Free plan allows at most 1 day of RDS backups, and the code asked for 7. Fixed in `7d77352`: 1 day in both environments |
| 12 | `7d77352` | Staging infra applied, staging deploys failed, production infra failed | `amazon/aws-cli` has no `tar`, so the deploy jobs could not unpack `crane`. Fixed in `5d9f578`, which also replaced the promote jobs' image tag `crane:0.20.2` (does not exist, and the plain crane images have no shell) with crane's `debug` image pinned by digest. Production failed with `InstanceQuotaExceeded`: the Free plan allows only 2 RDS instances, and staging used both. Fixed by upgrading the account to the paid plan |
| 13 | `5d9f578` | Staging deploys passed; approvals left waiting | An app-only push has no infra jobs, so its production deploys would not wait for production infra. Leave its approvals alone |
| 14 | `5d9f578` (started from the API, runs every job) | **Passed, every job** | Production infra added the 6 missing resources, then all three apps were promoted and deployed |

---

## Setup that is done

| Step | What exists |
|---|---|
| 4. State backend | Bucket `code-keeper-tfstate-REDACTED_AWS_ACCOUNT_ID` (versioned, encrypted, public access blocked) and table `code-keeper-tf-locks` |
| 5. CI user | IAM user `code-keeper-ci` with `AdministratorAccess` and one active access key |
| 6. Docker Hub | Account `sntentop` with 3 public repositories |
| 7. Passwords | Generated; a copy is in `~/.config/code-keeper-local-gitlab/aws-tf-passwords.env` (mode 600) |
| 8. CI/CD variables | 11 project variables on the local GitLab: `TF_STATE_BUCKET`, `TF_STATE_REGION`, `TF_STATE_LOCK_TABLE`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `DOCKERHUB_REPO` (`sntentop`) and the 3 `TF_VAR_*` passwords. The secrets are protected and masked |
| 9. First run | Pipeline 14 |
| 10. Checks | See "What is live" |

---

## Next

1. **Test** whatever you want to test now, while it runs.
2. **Take it down.** Tell Claude when testing is over. Claude then runs `terraform destroy` for
   production and then staging (step 11), and checks that nothing billable is left (step 12). The
   state bucket and lock table stay; they cost almost nothing.
3. **Before the audit,** start a pipeline on `main` from the GitLab UI (Build → Pipelines → Run
   pipeline). A pipeline started that way runs every job, including both Terraform applies. Then
   start `infra:approval:production` and the three app approvals. Allow about 45 minutes.

---

## Still missing for the audit, beyond AWS

From the suggested order in `docs/READINESS_REVIEW.md`:

| Item | Status |
|---|---|
| Fix the pipeline and infra bugs | **Done**, including the deploy fixes above |
| AWS deploy with one full green pipeline | **Done**: pipeline 14 |
| Real GitLab and runner installed with the Ansible playbooks | Not started. Needs a host (VM or EC2) |
| One repository per app and one for infra | Not started. Today all four live in one repo |
| Docs match the code | Not started |

Details:

- **Ansible GitLab.** The audit asks for a GitLab instance installed with Ansible and runners
  executing jobs for all repositories. The local test GitLab does not count. Likely problems, not
  yet checked: the runner registration uses legacy tokens and flags that current GitLab rejects,
  `gitlab_version` is unpinned, and the `allowed_to_push` format in `ansible/roles/gitlab/tasks/cicd.yml`
  is probably wrong.
- **Repo split.** The brief requires each app in its own repository and the infra in an
  independent repository with its own pipeline. After the split, the CI/CD variables belong on the
  GitLab group so all four repos share them.
- **Docs.** `README.md` and `docs/AUDIT_GUIDE.md` still describe the old setup (Docker-in-Docker,
  GitLab registry, release tags, main-only pipelines, missing test files). `docs/AWS_SETUP.md` also
  needs the findings from this deploy:
  - the Free plan limits on RDS (at most 2 instances, at most 1 day of backups), and that both
    environments together need the paid plan
  - how to run a full pipeline for a redeploy
  - that the first `terraform apply` seeds task definitions with a `staging-latest` or
    `production-latest` tag, and the first deploy replaces it

  Before submitting, remove or refresh `docs/AUDIT_READINESS_PLAN.md`, `reports/audit_report.json`
  and probably `docs/READINESS_REVIEW.md`, which lists the project's failures and is partly out of
  date. Files in `docs/` are changed by you; Claude drafts the text.

Smaller points:

- `env.example`, committed in `a8691d8` and on zone01, contains the live Docker Hub token for
  `sntentop`. It is there on purpose so a teammate can see it, but it will be part of the
  submission unless it is removed and the token is replaced.
- `Results.md` (this file) was committed in `a8691d8`; decide whether it belongs in the submission.
- `terraform.tfvars` sets `release_tag` to `staging-latest` / `production-latest`, and tfvars take
  priority over the CI's `TF_VAR_release_tag`. Terraform therefore creates task definitions that
  point at tags that do not exist, and services run 0 tasks until the first deploy job. This is how
  the design works, but the CI variable has no effect.
- On the paid plan, RDS backups could go back to 7 days (`backup_retention_period` in
  `infra/environments/*/main.tf`).
- The saved `.tfplan` artifacts contain the passwords and the Docker Hub token, and can be
  downloaded for 7 days.
- `aquasec/trivy:latest` and `amazon/aws-cli:latest` are not pinned to a version.
- The comment in `infra/environments/*/backend.hcl` says the runner uses Terraform 1.9.5; CI uses
  `hashicorp/terraform:1.6`.
- The `image_repository_prefix` description in `infra/environments/*/variables.tf` still mentions
  the GitLab registry (`CI_REGISTRY_IMAGE`).
- SonarQube is not configured, so the SonarQube jobs pass without uploading anything.
