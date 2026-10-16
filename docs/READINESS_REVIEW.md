# Code-Keeper: Submission Readiness Review

- **Reviewed:** 2026-10-16, commit `feb4b14` on `main`
- **Question:** is the project ready to be turned in against `docs/readme.md` and `docs/audit.md`?
- **Verdict:** **No, not yet.**

There are two separate problems, and either one on its own would fail the audit:

1. **Nothing is running.** Most of the audit is live demos. The repo's own docs say there is no GitLab
   instance, no runner and no AWS deployment behind any of it.
2. **The pipelines wouldn't run even on a real GitLab.** GitLab would reject the configuration before
   creating a pipeline, and several later steps would fail even after that is fixed.

---

## 1. The audit needs live systems that don't exist

The repository admits this itself:

- `README.md:257`: the Terraform is "designed and statically validated, not deployed. There is no
  committed state file and no AWS account behind these environments".
- `docs/AUDIT_READINESS_PLAN.md`: "No GitLab instance anywhere", the playbook "has never been
  executed", and the `ansible/inventory/hosts.ini` IPs (`192.168.56.10`, `192.168.56.11`) are the
  crud-master VMs. Its own table marks AQ02, AQ03, AQ04, AQ06 and AQ10 as FAIL.

So these audit questions can't pass today:

| Audit question (`docs/audit.md`) | Needs |
|---|---|
| Was the GitLab instance deployed and configured successfully using Ansible? (line 59) | A running GitLab host, shown with `systemctl status` / `gitlab-ctl status` |
| Are the GitLab Runners integrated and executing tasks for all repositories? (line 61) | A registered runner and real job logs |
| Did the student deploy the infrastructure for two environments on a cloud platform using Terraform? (line 65) | Applied staging and production stacks on AWS |
| Are the pipelines working properly and updating the application and infrastructure after each modification? (line 92) | A green pipeline run from commit to production |

`docs/readme.md:241` says: "Your Solution must be running and your users and applications repository
and CI/CD must be configured correctly for the audit session."

---

## 2. Pipeline bugs (confirmed by parsing the YAML)

Line numbers refer to `srcs/api-gateway/.gitlab-ci.yml` unless stated otherwise. The same defects
exist in `srcs/inventory-app/.gitlab-ci.yml` and `srcs/billing-app/.gitlab-ci.yml`, shifted by two
lines after line 28.

The first two stop GitLab from creating any pipeline at all.

1. **Bad `rules:` in 9 jobs.** In `test:unit`, `scan:sast_bandit` and `scan:dependencies` for all three
   services, the `before_script` lines ended up inside the `rules:` list (`:70-72`, `:114-116`,
   `:274-276`). GitLab requires each rule to be a hash, so it rejects the whole configuration. Those
   jobs also lose their `cd "${APP_DIR}"`, so they would run from the repository root.
2. **A `needs:` that points at a missing job.** `infra:apply:production` needs `infra:plan:production`
   (`infra/.gitlab-ci.yml:330-332`). The plan job only exists when `infra/**` changed, and the need is
   not marked `optional: true`, so any other push to `main` gets no pipeline.
3. **Tools are never installed.** `pytest` (`:75`), `bandit` (`:119`) and `pip-audit` (`:280`) run in a
   bare `python:3.11-alpine` image. The Build job's `pip install` happens in a different container and
   does not carry over. pip-audit sits inside an `if/else`, so it "passes" without scanning anything.
4. **The Trivy job calls terraform.** `infra:validate:security` runs `terraform --version`
   (`infra/.gitlab-ci.yml:145-146`) inside the `aquasec/trivy` image, which has no terraform. Validate
   fails, and on any infra change every later stage is skipped, app jobs included.
5. **`infra:apply:staging` runs on every push to main** (`infra/.gitlab-ci.yml:276`, no `changes:`
   rule). Without a plan file it fails. Because "Apply to Staging" comes before "Build" in the root
   `stages:` list, every app pipeline stops there.
6. **The Kaniko login file is broken.** `:329` passes a Python `.format()` template to `printf`. Run
   locally, the output is `{{"auths":{{...{0}...`, which is not valid JSON, so the image push fails. A
   correct version of the same line already exists at `:504`.
7. **Image names don't resolve.** `${DOCKERHUB_REPO:-grafido}` (`:41` and every job, plus
   `infra/.gitlab-ci.yml:52`) is bash syntax. GitLab's `variables:` only expand `$VAR` and `${VAR}`,
   with no `:-` defaults, so the fallback never applies. Even with that fixed,
   `grafido/code-keeper/api-gateway` has three path parts, and Docker Hub only accepts two
   (`namespace/repo`). `AWS_DEFAULT_REGION: "${AWS_DEFAULT_REGION:-us-east-1}"` has the same problem.
8. **The staging health check can never pass.** `curl http://staging.code-keeper.internal/health`
   (`:439`; `:8080` in the other two services) targets a DNS name that nothing creates. The only private
   zone is `${environment}.local` (`infra/modules/compute/main.tf:77`), and the runner sits on a local
   192.168.56.x network anyway. So `deploy:staging` always fails, and production is never reached.
9. **Production stops updating after the first release.** Production deploys the reusable
   `:production-latest` tag (`:542`). From the second release on, the job finds the task definition
   "already runs" that image (`:559`), skips `update-service`, and the old image keeps running. Audit
   line 92 checks exactly this.

Smaller issues:

- `containerize:*` also runs on merge-request pipelines (`:310`), although the README says it is
  restricted to `main`.
- `terraform outdated` (`infra/.gitlab-ci.yml:183`) is not a Terraform command; the job always
  "succeeds" through its `|| echo` fallback.
- `infra:validate:syntax` and the plan jobs never run `terraform init`. They depend on a cache that the
  two parallel init jobs overwrite, so the first run is unreliable.

### Why the committed audit report is green

`reports/audit_report.json` shows 83 PASS and 0 FAIL because `scripts/test_pipelines.sh`,
`scripts/verify_security.sh` and `scripts/audit_orchestrator.sh` only check that the YAML parses and
that the stage names exist. They never validate the configuration against GitLab's schema or run a
job. The report was also generated on another machine (`/home/ertval/...`), against an older commit
(`3128a21`) with uncommitted changes (`"dirty": true`).

---

## 3. Infra bugs

These two would break things for sure:

- **RabbitMQ port mismatch.** Amazon MQ for RabbitMQ only listens on 5671 (AMQPS), and the apps are
  correctly told to use 5671 (`infra/modules/rabbitmq/outputs.tf:28`). But every security group rule
  opens 5672 (`infra/modules/security_groups/main.tf:26`, used at `:116`, `:230` and `:250`), so neither
  the gateway nor the billing app can reach the broker.
- **The KMS key policy locks out its creator.** The policy in `infra/modules/rds/main.tf:12-37` only
  grants `rds.amazonaws.com`. KMS's policy lockout safety check refuses to create a key the caller
  couldn't manage afterwards, so `terraform apply` stops there.

These are likely problems, worth checking on the real targets:

- RDS `engine_version = "15.4"` (`infra/modules/rds/main.tf:66`, `:94`) and Amazon MQ `3.11.20`
  (`infra/modules/rabbitmq/main.tf:14`) are old versions that AWS may no longer allow for new instances.
- The runner registers with `--registration-token` plus `--tag-list`, `--locked` and `--access-level`
  (`ansible/roles/gitlab_runner/tasks/register.yml:27-40`). Current GitLab disables legacy
  registration tokens by default and rejects those flags with the new `glrt-` tokens.
  `gitlab_version` is unpinned, so the playbook installs the latest release.
- `ansible/roles/gitlab/tasks/cicd.yml:17-21` passes `allowed_to_push => [40]`, where GitLab's
  `default_branch_protection_defaults` probably expects `[{access_level: 40}]`, so `update!` would
  raise and the task would fail.

Security notes:

- Database and broker passwords are passed to the task definitions as plain `environment` entries
  (`infra/modules/compute/main.tf`), not as `secrets` from Secrets Manager or SSM.
- The `.tfplan` files saved as job artifacts contain those passwords and can be downloaded for 7 days.

---

## 4. Repo layout fails two requirements

The README admits both (`README.md:494`, "Known deviations from the brief"), but admitting it doesn't
pass the rubric item:

- "Your infrastructure configuration must exist in an independent repository with a configured
  pipeline" (`docs/readme.md:130-131`, audit line 69). Here `infra/` is a subfolder of the same repo.
- "Each application must exist in a single repository" (`docs/readme.md:116`). Here all three apps
  share one repo.

---

## 5. Docs contradict the code

The auditor grades the documentation (audit lines 114 and 116), and these statements no longer match
the code:

- **Image build and registry:** `README.md` §3.3 and Q15 describe Docker-in-Docker with `docker:24.0.5`
  and the GitLab Container Registry. The code builds with Kaniko and pushes to Docker Hub.
- **Release tags:** the README says the pipeline pushes `staging-latest` and never pushes
  `production-latest`. The code pushes no `staging-latest`, and `promote:image` does push
  `production-latest`. It also mentions `--force-new-deployment`, which the code doesn't use.
- **When pipelines run:** README §3.4 and "Known deviations" say pipelines are main-only with no
  merge-request pipelines. The root `workflow:` now allows merge requests and every branch.
- **Branch protection:** README §4.1 says `gitlab_default_branch_protection` is unused and Developers
  can merge. `cicd.yml` now uses it and limits merges to Maintainers.
- **Missing files and features:** the directory tree lists `tests/test_inventory.py` and
  `tests/test_billing.py`, which don't exist. "Auto-scaling" isn't implemented, `config.toml.j2` is
  never deployed, and the "GitLab CI Passing" badge is static.
- **`docs/AUDIT_GUIDE.md`:** §4.4 says "YES", deployed on AWS, while §6.3 says "there is no AWS
  account, no reachable GitLab". It still describes the dev credential fallbacks, an unwired backend
  and DinD, all of which have changed. `infra/environments/*/backend.hcl` says Terraform 1.9.5; CI uses
  `hashicorp/terraform:1.6`.

### Remove or refresh before submitting

- `docs/AUDIT_READINESS_PLAN.md`: an internal work plan that lists the project's audit failures one by
  one.
- `reports/audit_report.json`: stale, generated from another user's path, against an older commit with
  uncommitted changes.

---

## What's already good

- **Application code:** credentials must come from the environment (the apps refuse to start without
  them), broker connections use TLS with certificate checks, and the billing consumer's ack/nack
  handling is careful.
- **Terraform:** shared modules give staging and production real parity, the security groups are tight
  with explicit egress, and there are VPC flow logs and encrypted private RDS instances.
- **Ansible:** the roles are cleanly structured, no secrets are committed, and the runner role checks
  that registration actually took effect.

Most of the remaining work is wiring and live setup, not new design.

---

## Suggested order

1. Fix the pipeline bugs (section 2, items 1-9) and the two confirmed infra bugs (section 3).
2. Bring up a real GitLab instance and runner with the existing playbooks, then confirm runner
   registration and branch protection work on that GitLab version.
3. Split `infra/` and the three apps into their own repositories on that GitLab.
4. Set up the AWS account and the Terraform state bucket, apply staging and production, and get one
   green pipeline from commit to production.
5. Last, update `README.md` and `docs/AUDIT_GUIDE.md` to match what actually ran.

---

## How this review was done

- **Read in full:** the CI files, Terraform, Ansible, application code, Dockerfiles, `README.md`,
  `docs/readme.md`, `docs/audit.md` and `docs/AUDIT_READINESS_PLAN.md`.
- **Skimmed:** `docs/AUDIT_GUIDE.md`, the three scripts in `scripts/`, the tests and `reports/`.
- **Checked by running code:** the YAML problems were confirmed with a parsing script, and the Kaniko
  `printf` line was run to confirm it produces invalid JSON.
- **Not run:** the project's own scripts (they rewrite `reports/audit_report.json`). Terraform and
  Ansible are not installed on the review machine.

## Sources

- [GitLab: where variables can be used](https://docs.gitlab.com/ci/variables/where_variables_can_be_used/)
- [GitLab epic 7437: allow default value for variables](https://gitlab.com/groups/gitlab-org/-/epics/7437)
- [Docker forum: registry v2 spec and repository naming rule](https://forums.docker.com/t/docker-registry-v2-spec-and-repository-naming-rule/5466)
- [Amazon MQ for RabbitMQ brokers](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/rabbitmq-basic-elements.html)
