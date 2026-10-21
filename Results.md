# Results

- **Updated:** 2026-10-21 13:05 EEST
- **Scope:** the deploy described in `docs/AWS_SETUP.md`, run against AWS account `REDACTED_AWS_ACCOUNT_ID`
  (us-east-1) from the local test GitLab (`root/code-keeper`), plus what the project still lacks for
  the audit.
- **Code:** the deploy ran `5d9f578`. Since then: the Ansible fixes, GitLab on EC2, the split into
  four repositories and the docs refresh, all uncommitted on top of `5f2d0c6`.

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
   production and then staging, and checks that nothing billable is left (`docs/AWS_SETUP.md`). The
   state bucket and lock table stay; they cost almost nothing.
3. **Commit** the uncommitted work and copy the drafts from `drafts/` into `docs/`.
4. **GitLab on EC2:** `ansible/terraform`, then `ansible-playbook playbooks/site.yml`, then
   `scripts/publish_repos.sh` (`drafts/AWS_SETUP.md` steps 8 and 9).
5. **Before the audit,** redeploy from the four projects on that GitLab (`drafts/AWS_SETUP.md`
   step 12). Allow about an hour from a torn-down account.

---

## Status of what the audit still needed

| Item | Status |
|---|---|
| Fix the pipeline and infra bugs | **Done**, including the deploy fixes above |
| AWS deploy with one full green pipeline | **Done**: pipeline 14 |
| GitLab and runner installed with Ansible | **Ready, not run yet.** Fixed and tested against the local GitLab 19.5; the EC2 hosts come from `ansible/terraform/` |
| One repository per app and one for infra | **Ready, not published yet.** Four standalone pipelines, published by `scripts/publish_repos.sh` |
| Docs match the code | **Done for `README.md`.** `docs/` drafts are in `drafts/` |

What changed for each:

- **Ansible GitLab.**
  - GitLab is pinned to `19.5.0-ce.0` and the runner to `19.5.0-1`.
  - The runner is created through the API (`POST /user/runners`) and registered with its `glrt-`
    token, which is reused while it is valid.
  - The branch protection defaults are sent as `[{access_level: 40}]` and checked afterwards.
  - Ansible also creates the group, the four projects with their merge rules, the team members and
    the CI/CD variables.
  - The initial root password is now applied on the first install.
- **Repo split.** `infra/` and each `srcs/<app>/` have a standalone `.gitlab-ci.yml` and
  `.gitignore`; the root `.gitlab-ci.yml` is deleted. The shared CI/CD variables go on the
  `code-keeper` group, the Terraform state and password variables on the `infra` project.
- **Docs.** `README.md` is rewritten. `drafts/` holds new versions of `AUDIT_GUIDE.md`,
  `AWS_SETUP.md`, `READINESS_REVIEW.md` and `AUDIT_READINESS_PLAN.md` for `docs/`.
- **Also fixed:**
  - `infra:validate:dependencies` called `terraform outdated`, which does not exist. It now
    compares the lock file with the newest allowed and the newest released provider versions.
  - The stale `backend.hcl` and `image_repository_prefix` comments are corrected.
  - `scripts/audit_orchestrator.sh` is executable again.
  - `reports/` is regenerated on this machine.

Still open (the code items are also in section 12 of `README.md`):

- `env.example`, committed in `a8691d8` and on zone01, contains the live Docker Hub token for
  `sntentop`. It is there on purpose so a teammate can see it, but it will be part of the
  submission unless it is removed and the token is replaced.
- `Results.md` (this file) was committed in `a8691d8`; decide whether it belongs in the submission.
- On the paid plan, RDS backups could go back to 7 days (`backup_retention_period` in
  `infra/environments/*/main.tf`).
- The saved `.tfplan` artifacts contain the passwords and the Docker Hub token, and can be
  downloaded for 7 days.
- The Trivy, Gitleaks, SonarQube and AWS CLI images use `:latest`.
- SonarQube is not configured, so the SonarQube jobs pass without uploading anything.
- The pipelines' IAM user has `AdministratorAccess`.
