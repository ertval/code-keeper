# Code-Keeper: Submission Readiness Review

- **First review:** 2026-10-16, commit `feb4b14`. **Updated:** 2026-10-21 evening, after commit
  `c0c3213` and the first runs on the EC2 GitLab.
- **Question:** is the project ready to be turned in against `docs/readme.md` and `docs/audit.md`?
- **Verdict:** **Yes, once the docs are in place.** GitLab and its runner were installed on EC2 by
  Ansible, the four repositories are published on it, and their first pipelines passed every job
  from build to production. What is left is moving these drafts into `docs/`, one commit, and a
  rehearsal.

---

## 1. Status of the first review's findings

### Live systems (first review, section 1)

| Finding | Status |
|---|---|
| No AWS deployment | **Done.** Staging and production applied on AWS; pipeline 14 went green from commit to production on 2026-10-21, both `/health` checks answer |
| No GitLab instance, no runner | **Done.** `ansible/terraform/` created the two EC2 hosts and `playbooks/site.yml` installed GitLab CE 19.5.0 and the runner on 2026-10-21; a second run only renews the two one-day API tokens |
| The inventory pointed at the crud-master VMs | **Done.** `ansible/inventory/aws.ini` is written by Terraform; `hosts.ini` is only an example |

### Pipeline bugs (first review, section 2)

| # | Finding | Status |
|---|---|---|
| 1 | `before_script` inside `rules:` | Fixed (`779d895`) |
| 2 | `needs:` on a job that might not exist | Fixed (`779d895`) |
| 3 | pytest, bandit, pip-audit never installed | Fixed, pinned versions installed in each job (`2b54962`) |
| 4 | Trivy job calls terraform | Fixed (`64e81a9`) |
| 5 | Staging apply on every push | Fixed (`64e81a9`); since the split, Init, Plan and Apply run on every `main` pipeline of `infra` |
| 6 | Broken Kaniko login file | Fixed (`64e81a9`) |
| 7 | `${VAR:-default}` and 3-part Docker Hub names | Fixed (`64e81a9`); images are `docker.io/<namespace>/<service>` |
| 8 | Unreachable staging health check | Fixed (`64e81a9`); the gateway is checked through the ALB |
| 9 | Production stops updating after the first release | Fixed (`64e81a9`); every deploy registers the SHA image |
| 10 | Script lines parsed as mappings | Fixed (`779d895`) |
| 11 | Trivy CRITICAL on plaintext passwords | Fixed (`c62effa`); the passwords come from Secrets Manager |
| | `containerize` on merge requests | Now intended: merge requests build without pushing (`--no-push`), `main` pushes |
| | `terraform outdated` is not a command | Fixed (`330e8de`); the job now compares the lock file with the newest allowed and the newest released provider versions |
| | Plan and validate jobs without `terraform init` | Fixed (`7a9611c`) |

### Infrastructure (first review, section 3)

| Finding | Status |
|---|---|
| RabbitMQ security groups on 5672 | Fixed, 5671 (`c62effa`) |
| KMS key policy locks out its creator | Fixed (`c62effa`) |
| RDS 15.4 and RabbitMQ 3.11.20 no longer offered | Fixed, RDS `15` and RabbitMQ `4.2` (`e9ed580`) |
| Legacy runner registration tokens | Fixed (`330e8de`); the runner is created with `POST /user/runners` and registered with its `glrt-` token, which is reused while valid |
| `gitlab_version` unpinned | Fixed (`330e8de`); GitLab `19.5.0-ce.0`, runner `19.5.0-1` and its helper images pinned |
| `allowed_to_push => [40]` | Fixed (`330e8de`); the settings go through the API as `[{access_level: 40}]` and are checked after |
| Passwords as plain `environment` entries | Fixed (`c62effa`) |
| `.tfplan` artifacts contain the passwords | **Open** (section 3) |

### Repository layout (first review, section 4)

| Finding | Status |
|---|---|
| Infra not in an independent repository | **Done.** `infra/` has a standalone pipeline and is published to `code-keeper/infra` by `scripts/publish_repos.sh` |
| Apps share one repository | **Done.** Each `srcs/<app>` has a standalone pipeline and is published to `code-keeper/<app>` |

### Documentation (first review, section 5)

| Finding | Status |
|---|---|
| README describes DinD, GitLab Registry, wrong tags, main-only pipelines, missing files | **Fixed.** `README.md` rewritten against the current code |
| `docs/AUDIT_GUIDE.md` contradicts itself and the code | **Fixed** in this version |
| `docs/AWS_SETUP.md` lacks Free plan limits, redeploy and first image tags | **Fixed** in this version |
| `backend.hcl` says Terraform 1.9.5 | Fixed (`330e8de`) |
| `reports/audit_report.json` stale, from another machine | Regenerated on this machine against the live EC2 hosts. Run `scripts/audit_orchestrator.sh` once more after the commit, so the report names that commit |
| `docs/AUDIT_READINESS_PLAN.md` lists the audit failures | **Fixed:** it now lists the remaining steps |

---

## 2. What has been tested, and how

| Part | Evidence |
|---|---|
| AWS environments | Pipeline 14 on the local GitLab: staging and production applied, three services stable in each, `/health` through both ALBs, image promotion and production deploy |
| GitLab on EC2 | `playbooks/site.yml` on the two hosts from `ansible/terraform/`: GitLab CE 19.5.0 and runner 19.5.0 installed; root password, sign-up off, branch protection, the private group with its four projects ("pipelines must succeed") and CI/CD variables checked in GitLab afterwards; runner online; a rerun changes only the two one-day API tokens; an invalid runner token is detected, reset and verified |
| Four pipelines on EC2 | First run after `scripts/publish_repos.sh`: infra #1, api-gateway #2, inventory-app #3, billing-app #4, every job passed (49 jobs). Both infra plans "No changes"; production apply "0 added, 0 changed, 0 destroyed". Production approved by root; staging and production run the images tagged with the new commits; `/health`, `/api/movies` and `/docs` answer 200 through both ALBs |
| Ansible roles | First against a local GitLab 19.5: instance settings, group, projects, member and runner created; a second run only rotates the API token; an invalid runner token is detected and reset; `config.toml` mode 600. Variables tested against a mock API (update, then create on 404). ansible-lint 0 failures at the production profile |
| Split pipelines | All four files accepted by GitLab's CI lint API, with no dangling `needs:`; the merge request image build (`--no-push`) run locally |
| Publish script | `git subtree split` and push to bare repositories in a throwaway clone; idempotent; shellcheck clean; then the real publish to the EC2 GitLab. It asks for the password itself, so an editor's git helper or `credential.helper store` never sees it |
| Local checks | `scripts/test_pipelines.sh` 89 pass, 0 fail; `scripts/verify_security.sh` 78 pass, 1 known false positive; `scripts/audit_orchestrator.sh` with its live checks on the EC2 hosts in `ansible/inventory/aws.ini`: 84 pass, 0 fail, 0 blocked, 4 skipped for tools that are not installed (checkov, hadolint, tflint, tfsec) |

---

## 3. Still open

These are known, documented in section 12 of `README.md`, and fine to explain in the audit:

- **Plan artifacts contain secrets.** `<env>.tfplan` holds the passwords; project members can
  download it for 7 days. Fix: shorten `expire_in` on the plan jobs, or limit downloads
  with `artifacts:access` (check that the apply jobs still receive the plan).
- **Some job images use `:latest`**: Trivy, Gitleaks, SonarQube scanner, AWS CLI. Fix: pin a version
  or digest, like Kaniko and crane.
- **SonarQube is not configured.** The job skips the upload without `SONAR_HOST_URL` and
  `SONAR_TOKEN`.
- **The pipelines' IAM user has `AdministratorAccess`.** A narrower policy for Terraform, and a
  deploy-only key for the app projects, would follow least privilege more closely.
- **RDS keeps 1 day of backups.** The account is on the paid plan now, so 7 days would be possible
  (`backup_retention_period` in `infra/environments/*/main.tf`).
- **No TLS**, because there is no domain.
- **`scripts/verify_security.sh`** reports one false positive (secret names in
  `infra/modules/compute/main.tf` read as a hardcoded credential).

---

## 4. Steps to submission

See `docs/AUDIT_READINESS_PLAN.md`.

---

## How this update was done

- Each finding of the first review was checked against the current files and the commit that fixed
  it.
- The Ansible roles were run against the local GitLab 19.5 test instance, then every test object
  was removed and the instance settings restored. Then they ran on the EC2 hosts, and the result
  was checked in GitLab itself.
- The four repositories were published to the EC2 GitLab and their pipelines run to production,
  with the approvals done by hand in the GitLab UI.
- The split pipelines were validated with GitLab's CI lint API; Terraform with `fmt`, `validate`;
  the scripts with shellcheck; the roles with ansible-lint.
