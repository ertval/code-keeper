# Audit Readiness Plan — AWS Deployment, Repeatable Up/Down, Full Rubric Coverage

Status: **proposed** · Scope: `code-keeper` (IaC + CI/CD) and the K3s `orchestrator`
environment · Baseline at time of writing: K3s audit **65 PASS / 1 FAIL**

---

## 1. Objective

1. Deploy the `code-keeper` infrastructure to **AWS** for **two environments**
   (staging, production), so `audit.md:65` is satisfied against a named cloud
   platform rather than argued from `readme.md:105`.
2. Make the deployment **repeatable and disposable**: a single `up` and a single
   `down` per environment, so an environment can be torn down between audit
   rehearsals and rebuilt in one command on the day.
3. Satisfy **every** requirement in `docs/readme.md` and **every** graded
   question in `docs/audit.md`, with evidence that can be produced live.
4. Clear the four known blockers: the failing Vagrant rubric item, GitLab
   provisioning, and the four hardcoded credentials.

### Non-goals

- Not re-implementing the Terraform. It is already `validate`-clean in both
  environments; the work is wiring, not authoring.
- Not decommissioning the K3s `orchestrator` cluster. It is the fallback
  demonstration and it currently passes 65/66.
- Not claiming bonus features that are not implemented (see §7).

---

## 2. Current-state summary

### 2.1 What is already true

| Area | Evidence |
|---|---|
| Infra pipeline has the 6 required stages | `infra/.gitlab-ci.yml` `stages` |
| App pipelines have the 7 required stages | `srcs/*/.gitlab-ci.yml` `stages` |
| Protected-branch gating on all destructive jobs | all 4 CI files |
| Terraform `validate` + `fmt` clean, both envs | `terraform validate` → `Success!` |
| IaC hardened: 6 SGs with explicit egress, flow logs, no public IPs | `infra/modules/*` |
| DinD removed, Kaniko + `crane` promotion | `srcs/*/.gitlab-ci.yml` |
| IaC scan gate green against an accepted baseline | `infra/.trivyignore` |
| K3s cluster live, 6 workloads, queue recovery proven | `orchestrator/Scripts/run-audit-checks.sh` |
| Orchestrator audit | **65 PASS / 1 FAIL** |

### 2.2 What is missing or broken

| # | Gap | Blocks |
|---|---|---|
| G1 | No AWS account, no credentials (`aws sts get-caller-identity` → `NoCredentials`) | `readme:119`, `audit:65` |
| G2 | State backend (S3 bucket + DynamoDB table) not created by Terraform and does not exist | any `terraform init` |
| G3 | Images pinned to `code-keeper/*` which is not a real registry; no ECR | ECS cannot pull |
| G4 | Infra lives in a subdirectory of the app repo, not an independent repo | `audit:69` |
| G5 | No GitLab instance anywhere; `hosts.ini` `.10`/`.11` are actually the crud-master VMs | `audit:59`, `audit:61` |
| G6 | 4 hardcoded dev credentials in `srcs/*/app/*.py` | `audit:106` |
| G7 | `Scripts/vagrant.sh status` cannot see the VMs (fails under WSL) | orchestrator rubric item 5 |
| G8 | No SSH key in WSL; Vagrant's per-machine key is rejected | live SSH demos |
| G9 | Docs still carry 6 stale `PENDING WP-F SYNC` markers and stale counts | `audit:116` |
| G10 | `verify_security.sh` can PASS while a port is world-exposed via a `var.*` reference | `audit:108` credibility |

---

## 3. Requirement traceability matrix

`readme.md` requirements are cited as **R**n, `audit.md` graded questions as
**AQ**nn (line numbers from the current files). `docs/audit.md` carries 22
graded `######` questions plus 23 roleplay prompts; the roleplay prompts are
answered in `docs/AUDIT_GUIDE.md` and are covered by the standing instruction
that the guide must contain no claim the repository cannot evidence.

### 3.1 `docs/readme.md`

| ID | Requirement (line) | Current | Work item |
|---|---|---|---|
| R1 | Source control for microservices + infra (`7`) | monorepo | W5 |
| R2 | Pipeline creates/updates/deletes infra for staging **and** prod (`19`) | config only | **W2** |
| R3 | CI pipeline to build, test, scan (`21`) | yes | — |
| R4 | CD pipeline to deploy staging + prod (`23`) | yes, unproven live | **W2**, W3 |
| R5 | Security + reliability throughout (`25`) | yes | W6 |
| R6 | Ansible playbook deploys + configures GitLab (`76`) | playbook exists, never run | **W4** |
| R7 | GitLab on cloud platform **or local**, accessible, supports review (`81`) | none | **W4** |
| R8 | GitLab Runners set up and integrated with the pipeline (`86`) | role exists, never run | **W4** |
| R9 | Use provided `crud-master` + own `cloud-design`/`cloud-kube` (`105`) | derived from crud-master | AQ18 |
| R10 | Each application in a single repository (`116`) | monorepo — see §7 R-A | W5 |
| R11 | Provision infra for **two** environments on a cloud platform using Terraform (`118`) | not deployed | **W1**, W2 |
| R12 | Two environments similar in design, resources, services (`125`,`129`) | yes (deliberate sizing delta) | keep evidence |
| R13 | Infra config in an **independent** repository with a pipeline (`131`) | **subdirectory** | **W5** |
| R14 | Infra stages Init/Validate/Plan/Apply-Staging/Approval/Apply-Prod (`135-158`) | yes | — |
| R15 | CI per repo on every push **or PR** (`160`) | now MR-capable | verify live |
| R16 | CD after CI: Deploy-Staging/Approval/Deploy-Prod (`175`) | yes | W2 |
| R17 | Each repository must have a pipeline (`185`) | yes | W5 |
| R18 | Modification → rebuild → staging → prod after manual approval (`187`) | config only | **W2**, W3 |
| R19 | Restrict triggers to protected branches (`196`) | yes | W6 |
| R20 | Separate credentials from code (`200`) | **4 dev creds** | **W6** |
| R21 | Least privilege (`204`) | yes, one parser gap | **W7** |
| R22 | Update dependencies/tools, automated (`208`) | partial (Dependabot inert on GitLab) | **W7** |
| R23 | `README.md` full documentation (`214`) | 524 lines | W8 |
| R24 | Bonus: tfsec, Infracost, Terragrunt, own crud-master (`222-226`) | none implemented | §7 |

### 3.2 `docs/audit.md` graded questions

| ID | Question (line) | Current verdict | Work item |
|---|---|---|---|
| AQ01 | Required files present (`11`) | PASS | — |
| AQ02 | GitLab deployed + configured via Ansible (`59`) | **FAIL** no instance | **W4** |
| AQ03 | Runners integrated and executing for all repos (`61`) | **FAIL** no runner | **W4** |
| AQ04 | Infra deployed, two envs, cloud platform, Terraform (`65`) | **FAIL** no AWS | **W1**, W2 |
| AQ05 | Two envs similar in design/resources/services (`67`) | PASS | — |
| AQ06 | Infra config in independent repo with pipeline (`69`) | **FAIL** subdirectory | **W5** |
| AQ07 | Six infra stages correct (`71`) | PASS | — |
| AQ08 | Build/Test/Scan/Containerization correct per repo (`80`) | PASS | — |
| AQ09 | Deploy-Staging/Approval/Deploy-Prod correct (`88`) | PASS (config) | W2 |
| AQ10 | Pipelines functional, update after each modification (`90`,`92`) | **FAIL** unproven | **W2**, W3 |
| AQ11 | Triggers restricted to protected branches (`104`) | PASS | — |
| AQ11a | Students understand the concepts and technologies used (`51`) | judgement — guide answers, but 6 stale markers undercut it | **W8** |
| AQ11b | Students communicate effectively and explain decisions (`53`) | judgement — requires a rehearsed narrative, not a doc | rehearsal (§11) |
| AQ11c | Students think critically and consider alternatives (`55`) | judgement — §7 decisions R-A..R-E *are* the evidence | **W8** + §7 |
| AQ12 | Credentials separated from code (`106`) | **FAIL** 4 dev creds | **W6** |
| AQ13 | Least privilege (`108`) | PASS w/ caveat | **W7** |
| AQ14 | Dependencies updated, automated (`110`) | **PARTIAL** | **W7** |
| AQ15 | `README.md` has prerequisites/setup/config/usage (`114`) | PASS | W8 |
| AQ16 | Docs clear, complete, well-diagrammed (`116`) | **PARTIAL** stale markers | **W8** |
| AQ17 | Bonus features (`120`) | **FAIL** claims absent from code | **W8** |
| AQ18 | Own `crud-master` source (`122`) | derived | strengthen evidence |
| AQ19 | Outstanding project (`124`) | judgement | W8 |
| AQ20 | Roleplay: DevOps concepts, CI/CD, IaC, security, GitLab, Ansible, Terraform, challenges, cost (`19-49`) | answered in guide | W8 |

**Projected: 12 FAIL/unproven today → 0 after W1–W8.**

---

## 4. Work streams

Ordered by dependency. `▲` blocks the item below it.

### W1 — AWS account bootstrap ▲ blocks W2, W3

**Owner: user (account creation) + agent (everything after credentials exist).**

The Terraform cannot be applied until an account and a state backend exist.
Note the chicken-and-egg: the S3 bucket and DynamoDB lock table are referenced
by `backend.hcl`/`-backend-config` but are **not** created by this Terraform, so
they must be bootstrapped by hand or by a separate `bootstrap/` stack.

| Step | Who | Action |
|---|---|---|
| 1.1 | user | Create the AWS account; enable MFA on the root user; record the account id |
| 1.2 | user | Create an IAM user or SSO role with `AdministratorAccess` **for bootstrap only**; export `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION=us-east-1` |
| 1.3 | agent | Write `scripts/aws_bootstrap.sh` — idempotent, creates: state bucket (versioned, SSE, public access blocked), DynamoDB lock table, 6 ECR repositories, a deploy IAM role |
| 1.4 | user | Run it once, confirm output |
| 1.5 | agent | Replace the bootstrap credentials with a least-privilege deploy role (§6, W6) |

Cost control is a first-class concern — see §5.3.

### W2 — Wire the existing Terraform to ECR and prove both environments

**Owner: agent. Depends: W1.1, W1.3.**

The resource graph already exists and validates: VPC (2 AZ, NAT, flow logs),
6 security groups, 2× `aws_db_instance`, `aws_mq_broker`, ALB + 3 ECS Fargate
services behind Cloud Map. Nothing needs authoring. What is missing is the
registry the tasks pull from.

| Step | Action | Evidence |
|---|---|---|
| 2.1 | Set `TF_VAR_image_repository_prefix` to the ECR registry namespace; drop the `code-keeper/*` pins from both `terraform.tfvars` | `grep release_tag infra/environments/*/terraform.tfvars` |
| 2.2 | Mirror the 6 already-published `grafido/*` images into ECR (pull → tag → push), with a build-from-Dockerfile fallback | `aws ecr describe-images` |
| 2.3 | `terraform plan` staging → review output for unexpected destroys | plan artifact |
| 2.4 | `terraform apply` staging; wait for ECS `services-stable`; curl the ALB `/health` | apply log + ALB URL |
| 2.5 | Repeat for production | as above |
| 2.6 | Record real apply duration to replace the fabricated "under 15 minutes" claims | timing |

Both environments must be torn down and rebuilt at least once to prove
repeatability before the audit (§5).

### W3 — Prove the CD path end to end ▲ depends on W2

**Owner: agent + user (GitLab instance must exist first, W4).**

`audit.md:90` demands the student *show* that a modification propagates. This
cannot be asserted from config.

| Step | Action |
|---|---|
| 3.1 | Merge a no-op commit to one microservice on `main` |
| 3.2 | Observe: Build → Test → Scan → Kaniko build+push → image scan |
| 3.3 | Confirm `promote:image` copied the SHA tag to `production-latest` and asserted digest equality |
| 3.4 | Confirm `deploy:staging` re-registered the task definition with the **new** SHA, not the mutable alias |
| 3.5 | Confirm the manual `approval:production` gate blocked, then approve |
| 3.6 | Confirm `deploy:production` ran and the service went stable |
| 3.7 | Screenshot/capture the pipeline graph + job log as the `audit.md:92` evidence |

This is also the regression test for the defect found during review: a
docs-only commit to `main` must not promote an unbuilt image.

### W4 — GitLab + Runners (AQ02, AQ03, R6–R8) ▲ depends on W1

**Owner: user + agent. This is the largest remaining unknown.**

Current state: `ansible/inventory/hosts.ini` declares `192.168.56.10` as
`gitlab-server` and `192.168.56.11` as `gitlab-runner-01`, but those IPs are
the **crud-master** `gateway` and `inventory` VMs. There is no GitLab anywhere.
The playbook has never been executed.

Two viable routes — **the user must choose**:

**Route 1 — GitLab on AWS (recommended, satisfies R7 "cloud platform").**
Provision two EC2 instances via a separate `infra/gitlab/` stack
(GitLab CE Omnibus, ~4 vCPU / 8 GB, gp3, single-AZ) or an AWS marketplace
image; point `hosts.ini` at their private/public IPs; run
`deploy-gitlab.yml` then `deploy-runners.yml`; register the runner against the
real GitLab URL with a real token; run a CI job to prove the runner executes
tasks. Cost: roughly USD 60–90/month for both instances, or run them only for
the audit window and destroy after.

**Route 2 — GitLab locally in Docker on this WSL box.**
`readme.md:81` explicitly permits "a cloud platform ... **or in a local
environment**". Cheaper and faster, but weakens R7 and invites the auditor to
ask why the Ansible playbook was not used for a real host.

**Either route requires:**
- an SSH key in WSL (G8) installed to both targets
- `GITLAB_ROOT_PASSWORD`, `GITLAB_EXTERNAL_URL`, `GITLAB_RUNNER_TOKEN` exported
  from the environment, never committed
- the runner registered with `--tag-list docker,shared,ci-cd,linux` and
  `--docker-privileged=false`, plus the Kaniko path already in the pipelines
  (DinD is gone, so a privileged runner is no longer required)
- at least one pipeline run whose job log proves the runner executed it

Deliverable evidence: `ansible-playbook --list-tasks` for both playbooks (already
captured in the guide), `gitlab-ctl status` and `systemctl status
gitlab-runsvdir` over SSH, `gitlab-runner list`, and a real job log.

### W5 — Split the infrastructure into an independent repository (AQ06, R13)

**Owner: user (repo creation) + agent (migration).**

`audit.md:69` is currently a clean FAIL: `infra/` is a subdirectory of the app
repo. Note `infra/.gitlab-ci.yml` uses root-relative paths
(`cd infra/environments/staging`, `changes: - infra/**/*`) that only resolve
from the monorepo root, so this is a real migration, not a copy.

| Step | Action |
|---|---|
| 5.1 | Create the standalone infra repo (same GitLab instance from W4) |
| 5.2 | Move `infra/` into it; rewrite `cd infra/environments/...` → `cd environments/...` and `changes: - infra/**/*` → `changes: - **/*` |
| 5.3 | Re-run `terraform fmt -check`, `validate` both envs, `yamllint`, and both verification scripts from the new root |
| 5.4 | Record the new remote URL as `audit.md:69` evidence |
| 5.5 | Keep a short pointer in the app repo so `audit.md:11` still finds a README |

**On R10 / `readme.md:116`** — see §7, decision R-A. Do not split the three apps
into three repos unless the auditor requires it: the CI files use
`changes: paths: srcs/<service>/**/*`, which is monorepo-shaped by design.

### W6 — Credentials and secrets (AQ12, R20)

**Owner: agent. No dependencies; do this early, it is cheap.**

| Step | Action |
|---|---|
| 6.1 | Remove the four dev fallbacks, making the apps fail closed. Target files: `srcs/api-gateway/app/queue_sender.py:13`, `srcs/inventory-app/app/__init__.py:26`, `srcs/billing-app/app/__init__.py:25`, `srcs/billing-app/app/consume_queue.py:14`. Replace `os.getenv(X, "literal")` with a required-variable read that raises a clear error when unset |
| 6.2 | Add `tests/` cases asserting the app refuses to start without the variable |
| 6.3 | Replace the bootstrap IAM user with a least-privilege deploy role scoped to the resources Terraform creates; keep the account-wide key out of CI |
| 6.4 | Ensure no AWS key, registry token, or DB password is in git history — run `gitleaks detect` over full history, not just the working tree |
| 6.5 | Confirm `verify_security.sh` Guideline 2 goes green and the exit code becomes 0-with-infos |

### W7 — Dependency currency and control soundness (AQ13, AQ14, R21, R22)

**Owner: agent.**

| Step | Action |
|---|---|
| 7.1 | `.github/dependabot.yml` is inert: Dependabot does not support the terraform ecosystem outside the repo root, and a GitHub config cannot run in a GitLab-hosted project. Replace with a GitLab-native mechanism — a scheduled `scan:dependencies` job (already added for pip) plus a `validate:dependencies` job running `terraform outdated`, both reporting into a dashboard or job artifact |
| 7.2 | Fix `verify_security.sh` soundness: resolve `var.*` references, range-check egress ports, add a non-vacuity floor to the ingress loop, count egress *rules* not blocks, reject numeric `USER` UIDs, and make branch-protection matching per-disjunct. A control that passes while the property is false is worse than no control, because the student will assert it to an auditor |
| 7.3 | Remove `.github/` entirely once 7.1 lands, so no dead config remains |

### W8 — Documentation sync (AQ15, AQ16, AQ17, AQ19, R23)

**Owner: agent. Do last, after W1–W7 land, so it describes final reality.**

| Step | Action |
|---|---|
| 8.1 | Delete the 6 stale `PENDING WP-F SYNC` markers and rewrite the surrounding text to the now-implemented behaviour (Kaniko, `crane` promotion, S3 backend, derived branch protection) |
| 8.2 | Replace stale counts: `42` → `90` assertions, `9` → current control count, and state the scanner-job count as 6 |
| 8.3 | Re-derive every `file#Lx-Ly` anchor against the final tree; `infra/**` and `srcs/*/.gitlab-ci.yml` have both shifted repeatedly |
| 8.4 | Add the AWS deployment evidence: both account ids (redacted), apply output, ALB endpoints, ECS service states, and the CD propagation transcript from W3 |
| 8.5 | Add a Mermaid/ASCII architecture diagram of the AWS topology (VPC, 2 AZ, ALB, 3 ECS services, RDS, MQ, ECR, GitLab) |
| 8.6 | Add a "known deviations" section covering only what is genuinely non-compliant, and nothing that has been fixed |
| 8.7 | Remove every `infracost` / `tfsec` / `terragrunt` / `renovate` claim, or implement them (§7, decision R-B) |

---

## 5. Repeatable up/down

### 5.1 Design principles

- **Idempotent.** `up` twice is safe; `down` on a destroyed env is safe.
- **State-external.** State lives in S3 with locking, never in the repo, so
  `down` is always a real `terraform destroy` and never an orphaned stack.
- **One command per environment**, plus a `bootstrap` that is genuinely
  once-per-account.
- **Fail loud.** Any prerequisite missing stops the run with the exact remedy,
  never a partial apply.
- **No secrets on argv.** Use `TF_VAR_*` environment variables, not `-var`.

### 5.2 Command surface

```
scripts/aws_bootstrap.sh                 # once per account: state bucket, lock table, ECR, deploy role
scripts/aws_up.sh    <staging|prod>      # plan -> apply -> wait stable -> health check
scripts/aws_down.sh  <staging|prod>      # destroy, keep state + ECR
scripts/aws_status.sh <staging|prod>     # plan drift, ECS state, ALB health
scripts/aws_logs.sh   <staging|prod> [svc]
```

### 5.3 `up` sequence

1. Preflight — credentials resolve to the expected account id; region matches;
   state bucket and lock table reachable; `terraform` ≥ 1.9.5.
2. `terraform fmt -check -recursive` and `validate` in the target env — refuse
   to proceed on failure.
3. ECR sync — mirror or build the 6 images, tag with the git short SHA.
4. `terraform plan -out=tfplan` — **print a change summary and require
   confirmation** unless `--auto-approve`.
5. `terraform apply tfplan`.
6. Wait for the three ECS services to reach `services-stable` (timeout 10 min).
7. Health check the ALB; print the endpoint.
8. Write a timestamped evidence line to `reports/aws/<env>-<ts>.json`.

### 5.4 `down` sequence

1. Show the destroy plan and its estimated count.
2. `terraform destroy -auto-approve`.
3. Never delete the state bucket or lock table — they are account-scoped
   bootstrap resources. Provide `--purge-state` as an explicit, separate flag.

### 5.5 Cost control

Verified sizing in the current config: staging `db.t3.micro` single-AZ,
production `db.t3.small` multi-AZ, `SINGLE_INSTANCE` MQ, **2 NAT gateways per
environment**. NAT and MQ dominate. Indicative monthly: roughly USD 150–220
per environment.

Mitigations, in order of preference:
- Keep **only staging** running between audit rehearsals; `aws_down.sh prod`
  when not presenting. Production exists as a validated config plus one
  recorded apply.
- Add a `single_nat_gateway` toggle to the VPC module and use it for staging.
- Set an AWS Budget alarm at USD 50 and a CloudWatch billing alarm.

---

## 6. Security posture to hold throughout

- Deploy role scoped to exactly the resources Terraform creates; no
  `AdministratorAccess` outside the one-shot bootstrap.
- Terraform state bucket: versioning on, SSE, public access blocked, bucket
  policy denying non-TLS requests.
- Secrets only as GitLab masked/protected CI variables and `TF_VAR_*`. Never
  in `tfvars` that are committed.
- All six security groups keep explicit minimal egress; `billing_app` keeps
  zero ingress by design (it is a queue worker).
- Every destructive CI job keeps both `$CI_COMMIT_BRANCH == "main"` and
  `schedule -> when: never`.
- Destroy is a local, manual, human-confirmed action — never a CI job.

---

## 7. Open decisions for the user

| ID | Decision | Recommendation |
|---|---|---|
| **R-A** | `readme.md:116` "Each application must exist in a single repository". Monorepo satisfies the literal reading (an app is not fragmented across repos); the stricter reading is three repos. | **Keep the monorepo**, and split only the infra (W5). The CI `changes:` filters are monorepo-shaped, so splitting the apps would mean rewriting all three pipelines for no rubric gain. Disclose the interpretation in the guide rather than hiding it. |
| **R-B** | `audit.md:120` bonus features. Currently the guide claims none that exist. | **Implement `tfsec` + `infracost`** — both are one container image each in the infra pipeline, low effort, and `tfsec`/`infracost` are the two bonus items the brief names first. Alternatively delete the claims and accept a zero on bonus. |
| **R-C** | W4 route: GitLab on AWS vs GitLab locally in Docker. | **AWS** if the budget exists — it satisfies `readme.md:81`'s "cloud platform" unambiguously and proves the Ansible playbook against a real host. Local Docker if speed matters more. |
| **R-D** | Keep K3s `orchestrator` running alongside AWS? | **Yes.** It is the fallback if AWS is unavailable on audit day, and it already passes 65/66. Costs nothing extra (local VMs). |
| **R-E** | Vagrant rubric item: option (a) native Windows shell, or (b) `VBoxManage` fallback? | **(b)** — repeatable and headless. `VBoxManage list runningvms` already works from WSL and equally proves the VMs belong to this project. |

---

## 8. Sequencing

```
W1 AWS bootstrap  ──┬──> W2 ECR + apply both envs ──> W3 prove CD propagation
                    │
                    └──> W4 GitLab + Runners ─────> W3 (needs a real GitLab)

W6 credentials ──────────────────────────────────> (independent, do first)
W7 controls + deps ──────────────────────────────> (independent)
W5 split infra repo ─────────────────────────────> (after W2 stable)
W8 docs sync ────────────────────────────────────> LAST, after everything

Orchestrator (independent track, do in parallel):
  V-E: VBoxManage fallback in Scripts/vagrant.sh   -> clears the 1 failing item
  V-S: SSH key in WSL                              -> unblocks live demos
```

Critical path: **W1 → W2 → W4 → W3 → W8**. Everything else is parallel.

---

## 9. Verification gates

Each gate is a command whose output is the audit evidence. No gate is "looks
right".

| Gate | Command | Pass condition |
|---|---|---|
| G-01 | `aws sts get-caller-identity` | account id matches the recorded one |
| G-02 | `terraform validate` in both envs | `Success!` |
| G-03 | `terraform fmt -check -recursive infra` | exit 0 |
| G-04 | `scripts/aws_up.sh staging` | apply succeeds, 3 services stable, ALB `/health` 200 |
| G-05 | `aws_down.sh staging` then `aws_up.sh staging` | destroy and rebuild both succeed (repeatability proof) |
| G-06 | CD propagation (W3) | new SHA visible in the running task definition |
| G-07 | `ansible-playbook --list-tasks` both playbooks | all roles resolve |
| G-08 | `gitlab-ctl status` over SSH | all services `run` |
| G-09 | `gitlab-runner list` + one job log | runner `online`, job executed by it |
| G-10 | `scripts/test_pipelines.sh` | 0 failures |
| G-11 | `scripts/verify_security.sh` | 0 failures |
| G-12 | `scripts/audit_orchestrator.sh` | 0 `FAIL`, only `PASS`/`INFO` |
| G-13 | `Scripts/run-audit-checks.sh` (orchestrator) | 66 PASS / 0 FAIL |
| G-14 | `grep -rniE 'infracost\|tfsec\|terragrunt\|renovate'` outside disclaimers | every hit is an explicit not-implemented statement |

---

## 10. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| AWS account not approved in time | medium | blocks W1, and AQ04 with it | start signup immediately; K3s remains the fallback (R-D) |
| Cost overrun | medium | unexpected bill | single-NAT toggle for staging, budget alarms, `down` between rehearsals |
| Free-tier capacity unavailable (`db.t3.micro`, Fargate) | medium | apply fails | pin region to one with capacity; keep sizing at the verified defaults |
| GitLab Omnibus install is slow and memory-hungry | high | W4 slips | provision early; consider the marketplace AMI; 8 GB minimum |
| Splitting infra (W5) breaks root-relative CI paths | medium | infra pipeline red | W5 rewrites paths explicitly and re-runs every gate |
| Docs drift again as code changes | high | AQ16 fails | W8 last, then freeze; re-run G-12 after any later edit |
| Auditor rejects the monorepo reading of R10 | low | one rubric item | disclose the interpretation explicitly in the guide (R-A) |

---

## 11. Definition of done

- [ ] `aws sts get-caller-identity` resolves; account id recorded
- [ ] State bucket + lock table + 6 ECR repos bootstrapped
- [ ] `aws_up.sh staging` → apply, 3 services stable, ALB healthy
- [ ] `aws_down.sh staging` → destroy; `aws_up.sh staging` → rebuild
- [ ] Production applied at least once, with recorded output
- [ ] CD propagation demonstrated end to end (W3.1–W3.7)
- [ ] GitLab + runner live, `gitlab-ctl status` and a real job log captured
- [ ] Infra in its own repository with a green pipeline (W5)
- [ ] Zero hardcoded credentials; `verify_security.sh` Guideline 2 green
- [ ] G-10, G-11, G-12, G-13 all green
- [ ] `docs/AUDIT_GUIDE.md` and `README.md` contain no stale marker, count, or anchor
- [ ] Every `infracost`/`tfsec`/`terragrunt`/`renovate` mention is either implemented or an explicit not-implemented disclosure
