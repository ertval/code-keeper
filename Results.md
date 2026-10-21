# Results

- **Updated:** 2026-10-21 22:03 EEST
- **Scope:** the deploy described in `docs/AWS_SETUP.md`, run against AWS account `REDACTED_AWS_ACCOUNT_ID`
  (us-east-1), first from the local test GitLab (`root/code-keeper`), then from the GitLab on EC2
  that Ansible installed, plus what the project still lacks for the audit.
- **Code:** the four EC2 pipelines ran commit `c0c3213`, split into its four repositories. Not yet
  committed: the publish script fix, the runner token placeholder, the regenerated reports and the
  doc drafts.

## Summary

**Everything the audit needs runs.** GitLab CE 19.5.0 and its runner were installed on EC2 by
Ansible, the four repositories are published on it, and their first pipelines passed every job, from
the tests through the infra plans and applies, the manual approvals and the three production deploys.

**Staging and production are both deployed and work end to end.** First pipeline 14 on the local
GitLab, then the four pipelines on the EC2 GitLab, passed every job.
Requests through each environment's load balancer reach the inventory database, and billing orders
go through RabbitMQ (TLS on port 5671) into the billing database.

**Cost:** both environments together cost about $0.79 an hour, and the two GitLab hosts about $0.14,
so about $0.93 an hour or $22 a day. The AWS account is on the paid plan; at 13:05 the remaining
credits were **$92.02**, which pay first. After that AWS bills the card, so take everything down when
testing is over (see "Next").

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
`production-latest` for the promoted image. Both environments now run the images built by the EC2
pipelines: `api-gateway:0758a5c5`, `inventory-app:ae7b51da` and `billing-app:85fb0afa`. After that
deploy, `/health`, `/api/movies` and `/docs` answer `200` through both load balancers.

| GitLab on EC2 | |
|---|---|
| GitLab CE 19.5.0 | `http://23.21.56.248`, `t3.large`; log in as `root` with `GITLAB_ROOT_PASSWORD` from `~/.config/code-keeper.env` |
| Runner 19.5.0 | `54.82.149.95`, `t3.medium`; `docker-shared-runner-01`, Docker executor, online |
| Group `code-keeper` | private; projects `infra`, `api-gateway`, `inventory-app`, `billing-app`, each with "pipelines must succeed"; 5 group CI/CD variables and 6 on `infra` |

---

## Pipelines on the local GitLab

| Pipeline | Commit | Result | Cause, and what fixed it |
|---|---|---|---|
| 10 | `a8691d8` | Failed at `infra:validate:syntax` | Both Init jobs save to one cache key and overwrite each other, and the plan and apply jobs never ran `terraform init`. Fixed in `7a9611c`: every Terraform job runs `terraform init` itself |
| 11 | `7a9611c` | Failed at `infra:apply:staging` | `FreeTierRestrictionError`: the Free plan allows at most 1 day of RDS backups, and the code asked for 7. Fixed in `7d77352`: 1 day in both environments |
| 12 | `7d77352` | Staging infra applied, staging deploys failed, production infra failed | `amazon/aws-cli` has no `tar`, so the deploy jobs could not unpack `crane`. Fixed in `5d9f578`, which also replaced the promote jobs' image tag `crane:0.20.2` (does not exist, and the plain crane images have no shell) with crane's `debug` image pinned by digest. Production failed with `InstanceQuotaExceeded`: the Free plan allows only 2 RDS instances, and staging used both. Fixed by upgrading the account to the paid plan |
| 13 | `5d9f578` | Staging deploys passed; approvals left waiting | An app-only push has no infra jobs, so its production deploys would not wait for production infra. Leave its approvals alone |
| 14 | `5d9f578` (started from the API, runs every job) | **Passed, every job** | Production infra added the 6 missing resources, then all three apps were promoted and deployed |

## Pipelines on the EC2 GitLab

Published with `scripts/publish_repos.sh` from commit `c0c3213` on 2026-10-21 at 21:20 EEST.

| Project | Pipeline | Commit | Result |
|---|---|---|---|
| `infra` | #1 | `c8ec62c` | **Passed, 10 jobs.** Both plans "No changes"; staging applied; production approved by root, apply "0 added, 0 changed, 0 destroyed" |
| `api-gateway` | #2 | `0758a5c` | **Passed, 13 jobs.** Build, test, five scans, image build and scan, staging deploy, approval by root, promote, production deploy |
| `inventory-app` | #3 | `ae7b51d` | **Passed, 13 jobs**, same stages |
| `billing-app` | #4 | `85fb0af` | **Passed, 13 jobs**, same stages |

From the push until all four waited for approval took 14 minutes; the production deploys after the
approvals took 5.
The first publish attempt failed before any push: the terminal was a VS Code terminal whose git
password helper was disconnected, so git sent an empty password. `scripts/publish_repos.sh` now asks
for the password itself and keeps git's helpers out of it.

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

1. **Docs and commit.** Copy the drafts from `drafts/` into `docs/`, commit and push, then run
   `scripts/audit_orchestrator.sh` once more and commit `reports/`, so the report names that commit
   (`docs/AUDIT_READINESS_PLAN.md` step 1).
2. **Rehearse** the audit with `docs/AUDIT_GUIDE.md`, while everything runs.
3. **Take it down.** Tell Claude when testing is over. Claude then runs `terraform destroy` for
   production and then staging, then for the GitLab hosts, and checks that nothing billable is left
   (`docs/AWS_SETUP.md` steps 13 and 14). The state bucket and lock table stay; they cost almost
   nothing.
4. **Before the audit,** bring it back up and redeploy from the four projects (`docs/AWS_SETUP.md`
   step 12). Allow about an hour from a torn-down account.

---

## Status of what the audit still needed

| Item | Status |
|---|---|
| Fix the pipeline and infra bugs | **Done**, including the deploy fixes above |
| AWS deploy with one full green pipeline | **Done**: pipeline 14, then the four EC2 pipelines |
| GitLab and runner installed with Ansible | **Done** on two EC2 hosts from `ansible/terraform/` |
| One repository per app and one for infra | **Done.** Four projects in the `code-keeper` group, published by `scripts/publish_repos.sh`, each pipeline green to production |
| Docs match the code | **Done for `README.md`.** The new `docs/` files are ready in `drafts/` |

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
  - `reports/` is regenerated on this machine, against the live EC2 hosts.
  - The playbook summary printed the runner token from `gitlab-runner list`. That token was reset,
    and the summary, the README demo and the audit script's hint now show `Token=<redacted>`.
  - `scripts/publish_repos.sh` asks for the GitLab password itself (see above).
- **crud-master bonus.** The team confirmed on 2026-10-21 that `srcs/` is its own crud-master code,
  so the answer in `docs/AUDIT_GUIDE.md` section 10.2 stands.

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
