# code-keeper

[![GitLab CI](https://img.shields.io/badge/GitLab%20CI-4%20pipelines-orange?logo=gitlab)](#7-pipelines-in-detail)
[![Ansible](https://img.shields.io/badge/Ansible-GitLab%20%2B%20Runner-red?logo=ansible)](ansible/)
[![Terraform](https://img.shields.io/badge/Terraform-AWS%20staging%20%2B%20production-blue?logo=terraform)](infra/)
[![Security](https://img.shields.io/badge/Security-scanned-success?logo=trivy)](#9-security)

`code-keeper` builds, scans and deploys the three crud-master microservices in `srcs/` to two AWS
environments, staging and production, with GitLab CI/CD:

- **GitLab and its runner are installed with Ansible** (`ansible/`) on two EC2 hosts that
  Terraform creates (`ansible/terraform/`). Ansible also creates the `code-keeper` group, the four
  projects, the CI/CD variables and the runner.
- **The infrastructure is Terraform** (`infra/`): one set of modules, two identical environments,
  and a six-stage pipeline with a manual gate before production.
- **Each microservice has its own repository and pipeline** (`srcs/<service>/`): build, test,
  scan, containerize, deploy to staging, manual approval, zero-downtime deploy to production.

This repository is the submission. It holds all four parts as folders, and
`scripts/publish_repos.sh` pushes each folder to its own GitLab project, so on GitLab there are
four independent repositories, each with its own pipeline.

## Contents

1. [What is where](#1-what-is-where)
2. [Architecture](#2-architecture)
3. [Directory structure](#3-directory-structure)
4. [Prerequisites](#4-prerequisites)
5. [Setup, first time](#5-setup-first-time)
6. [Usage, day to day](#6-usage-day-to-day)
7. [Pipelines in detail](#7-pipelines-in-detail)
8. [Configuration reference](#8-configuration-reference)
9. [Security](#9-security)
10. [Verification and audit commands](#10-verification-and-audit-commands)
11. [Costs and teardown](#11-costs-and-teardown)
12. [Known limitations](#12-known-limitations)
13. [Role-play questions](#13-role-play-questions)
14. [Bonus](#14-bonus)

---

## 1. What is where

| Requirement from the brief | Where it is |
|---|---|
| GitLab deployed and configured with an Ansible playbook | `ansible/playbooks/site.yml` (`deploy-gitlab.yml` + `deploy-runners.yml`), roles `gitlab`, `gitlab_api_token`, `gitlab_runner` |
| GitLab on a cloud platform, reachable by the team | EC2 hosts from `ansible/terraform/`, GitLab on port 80, sign-up disabled, accounts created by Ansible |
| Runners integrated with the pipelines | Docker executor runner on its own EC2 host, created through the GitLab API by `ansible/roles/gitlab_runner` |
| Each application in its own repository | GitLab projects `code-keeper/api-gateway`, `code-keeper/inventory-app`, `code-keeper/billing-app`, published from `srcs/<service>/` |
| Infrastructure in an independent repository with a pipeline | GitLab project `code-keeper/infra`, published from `infra/` |
| Two similar environments with Terraform | `infra/environments/staging` and `infra/environments/production`, same modules, same sizes |
| Infra stages Init, Validate, Plan, Apply to Staging, Approval, Apply to Production | `infra/.gitlab-ci.yml` |
| CI stages Build, Test, Scan, Containerization | `srcs/<service>/.gitlab-ci.yml` |
| CD stages Deploy to Staging, Approval, Deploy to Production | `srcs/<service>/.gitlab-ci.yml` |
| Cybersecurity guidelines | [Section 9](#9-security) |
| Documentation | This file, plus `docs/` |

---

## 2. Architecture

### 2.1 One AWS environment (staging and production are identical)

```
                        Internet
                            │ HTTP 80
             ┌──────────────▼──────────────┐
 public      │  Application Load Balancer  │   NAT gateway (outbound only)
 subnets     └──────────────┬──────────────┘
                            │ 3000
             ┌──────────────▼──────────────┐
 private     │  api-gateway (Fargate, x2)  │──── /api/movies ────┐
 subnets     └──────────────┬──────────────┘                    │ 8080
                            │ AMQPS 5671                        │
                            │ /api/billing          ┌───────────▼─────────────────┐
             ┌──────────────▼──────────────┐        │ inventory-app (Fargate, x2) │
             │    Amazon MQ for RabbitMQ   │        └───────────┬─────────────────┘
             │     queue: billing_queue    │                    │ 5432
             └──────────────┬──────────────┘                    │
                            │ AMQPS 5671                        │
             ┌──────────────▼──────────────┐                    │
             │  billing-app (Fargate, x2)  │                    │
             └──────────────┬──────────────┘                    │
                            │ 5432                              │
                            │                                   │
                            │                                   │
             ┌──────────────▼──────────────┐        ┌───────────▼─────────────────┐
 database    │   RDS PostgreSQL "orders"   │        │   RDS PostgreSQL "movies"   │
 subnets     └─────────────────────────────┘        └─────────────────────────────┘
```

Each arrow is a security group rule: every hop only accepts traffic from the security group of the
hop before it. The containers get their passwords from AWS Secrets Manager at start-up, and each
service can only read its own.

| | Staging | Production |
|---|---|---|
| VPC | `10.10.0.0/16`, us-east-1a and 1b | `10.20.0.0/16`, us-east-1a and 1b |
| ECS (Fargate) | 2 tasks per service, 256 CPU units, 512 MB | same |
| RDS PostgreSQL 15 | 2 x `db.t3.micro`, 20 GB, single-AZ | same |
| Amazon MQ (RabbitMQ 4.2) | `mq.m7g.medium`, single instance | same |
| Rolling deploys | minimum 100 %, maximum 200 % healthy | same |

Production is sized like staging to fit the budget. The comment in
`infra/environments/production/main.tf` records the high-availability sizes (Multi-AZ RDS, clustered
broker, 4 tasks per service), which are a variable change away.

### 2.2 GitLab platform

```
 your machine                         AWS default VPC (us-east-1)
 ┌──────────────────────┐   SSH      ┌──────────────────────────────────────────┐
 │ terraform            │──────────► │ EC2 t3.large  "code-keeper-gitlab"       │
 │  ansible/terraform   │            │  GitLab CE 19.5.0 (Omnibus, HTTP :80)    │
 │ ansible-playbook     │            │  group code-keeper:                      │
 │  playbooks/site.yml  │            │    infra, api-gateway,                   │
 │ publish_repos.sh     │──git push─►│    inventory-app, billing-app            │
 └──────────────────────┘            └──────────────────▲───────────────────────┘
                                                        │ jobs (HTTP :80)
                                     ┌──────────────────┴───────────────────────┐
                                     │ EC2 t3.medium "code-keeper-gitlab-runner"│
                                     │  gitlab-runner 19.5.0, Docker executor,  │
                                     │  unprivileged, no Docker socket in jobs  │
                                     └──────────┬────────────────────┬──────────┘
                                                │                    │
                                       Docker Hub (images)    AWS APIs (Terraform, ECS)
```

### 2.3 Pipeline design

```
infra:      Init ─► Validate ─► Plan ─► Apply to Staging ─► Approval ─► Apply to Production
                                                            (manual)

each app:   Build ─► Test ─► Scan ─► Containerization ─► Deploy to Staging ─► Approval ─► Deploy to Production
            └──────────── CI ──────────────────────┘ └───────────────────── CD ──────────────────────┘
```

Merge requests run the checks that need no credentials: Validate for infra; Build, Test, Scan and
an image build without push for the apps. Pushing images, applying Terraform and deploying happen
only on the protected `main` branch, after the merge.

---

## 3. Directory structure

```
code-keeper/
├── ansible/                          GitLab and runner, installed with Ansible
│   ├── ansible.cfg                   uses inventory/aws.ini (written by ansible/terraform)
│   ├── inventory/hosts.ini           example inventory for hosts not created by the Terraform
│   ├── playbooks/
│   │   ├── site.yml                  everything: deploy-gitlab.yml, then deploy-runners.yml
│   │   ├── deploy-gitlab.yml         GitLab, settings, group, projects, members, CI/CD variables
│   │   └── deploy-runners.yml        runner install, registration and verification
│   ├── roles/
│   │   ├── gitlab/                   install (pinned), gitlab.rb, settings, projects, variables
│   │   ├── gitlab_api_token/         short-lived admin API token for the tasks above
│   │   └── gitlab_runner/            Docker + gitlab-runner (pinned), registration, config.toml
│   ├── scripts/                      setup-gitlab.sh, register-runner.sh (wrappers)
│   └── terraform/                    the two EC2 hosts, security groups, Elastic IPs, inventory
├── infra/                            published as code-keeper/infra
│   ├── .gitlab-ci.yml                Init, Validate, Plan, Apply to Staging, Approval, Apply to Production
│   ├── environments/{staging,production}/   main.tf, variables.tf, outputs.tf, terraform.tfvars, backend.hcl
│   └── modules/{vpc,security_groups,rds,rabbitmq,compute}/
├── srcs/
│   ├── api-gateway/                  published as code-keeper/api-gateway
│   ├── inventory-app/                published as code-keeper/inventory-app
│   └── billing-app/                  published as code-keeper/billing-app
│       ├── .gitlab-ci.yml            Build ... Deploy to Production
│       ├── Dockerfile                Alpine 3.23, non-root appuser, HEALTHCHECK
│       ├── app/, server.py           the service (Flask on Waitress)
│       └── tests/                    pytest suites
├── scripts/
│   ├── publish_repos.sh              pushes each folder to its own GitLab project
│   ├── stop_aws.sh                   stops the AWS charges between sessions, keeps GitLab
│   ├── restart_aws.sh                brings GitLab and both environments back
│   ├── test_pipelines.sh             structure, pipelines, scripts, Dockerfiles, unit tests
│   ├── verify_security.sh            the four cybersecurity guidelines, checked in code
│   └── audit_orchestrator.sh         every audit question mapped to automated checks
└── docs/                             brief (readme.md), audit sheet (audit.md), guides
```

---

## 4. Prerequisites

**On your machine**

| Tool | Version | Used for |
|---|---|---|
| git | 2.x with `git subtree` (part of the Ubuntu and Debian packages) | publishing the four repositories |
| Terraform | 1.5 or newer (CI uses `hashicorp/terraform:1.6`) | GitLab hosts, and the environments by hand if needed |
| Ansible | `ansible-core` 2.15 or newer; only built-in modules are used (`sudo apt install ansible-core`) | GitLab and runner |
| AWS CLI | v2, a profile for the account | bootstrap and checks |
| SSH key | for example `ssh-keygen -t ed25519 -f ~/.ssh/code-keeper -C code-keeper` | Ansible to both hosts |

The EC2 hosts need nothing beforehand: Ubuntu 24.04 brings SSH and Python 3.

**Accounts**

- **AWS**, region `us-east-1`. Both environments together need the paid plan: the AWS Free plan
  allows at most 2 RDS instances and 1 day of backups, and each environment has 2 databases.
- **Docker Hub**, with an access token (read and write) and the public repositories `api-gateway`,
  `inventory-app` and `billing-app`.

---

## 5. Setup, first time

`docs/AWS_SETUP.md` has the full walkthrough with every command. In short:

### Step 1. AWS bootstrap (once per account)

Create the Terraform state bucket (versioned, encrypted, public access blocked), the DynamoDB lock
table `code-keeper-tf-locks`, and an IAM user for the pipelines with an access key.

### Step 2. The GitLab hosts

```bash
cd ansible/terraform
terraform init -backend-config=backend.hcl \
  -backend-config="bucket=<state bucket>" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=code-keeper-tf-locks"
terraform apply -var 'admin_cidrs=["<your public IP>/32"]'
terraform output gitlab_url
```

This creates a `t3.large` for GitLab and a `t3.medium` for the runner (Ubuntu 24.04, encrypted
40 GB disks, IMDSv2, Elastic IPs) and writes `ansible/inventory/aws.ini`. SSH is only open to
`admin_cidrs`. GitLab's port 80 is open to `team_cidrs` (default: everyone, since sign-up is
disabled); narrow it to your team's addresses when you can.

### Step 3. GitLab and the runner, with Ansible

```bash
cd ansible
export GITLAB_ROOT_PASSWORD='<at least 12 characters>'
# CI/CD variable values, read from CK_<name>; unset ones are skipped (see section 8.1)
export CK_AWS_ACCESS_KEY_ID=... CK_AWS_SECRET_ACCESS_KEY=...
export CK_DOCKERHUB_USERNAME=... CK_DOCKERHUB_TOKEN=... CK_DOCKERHUB_REPO=...
export CK_TF_STATE_BUCKET=... CK_TF_STATE_REGION=us-east-1 CK_TF_STATE_LOCK_TABLE=code-keeper-tf-locks
export CK_TF_VAR_inventory_db_password=... CK_TF_VAR_billing_db_password=... CK_TF_VAR_rabbitmq_password=...
ansible-playbook playbooks/site.yml
```

The run takes about 15 minutes the first time and is safe to repeat. It:

1. installs GitLab CE `19.5.0-ce.0` and writes `gitlab.rb` (URL, root password, Puma and Sidekiq sizing);
2. creates a root API token that expires after one day (each run revokes the previous one);
3. applies the instance settings: sign-up disabled, default branch `main`, default branch protection
   (push and merge: Maintainers, no force push), shared runners on, Auto DevOps off;
4. creates the private group `code-keeper` and the projects `infra`, `api-gateway`,
   `inventory-app`, `billing-app`, each with "pipelines must succeed" and "all threads must be
   resolved" before merging;
5. creates the team members listed in `gitlab_team_members` and adds them to the group;
6. creates or updates the CI/CD variables from the `CK_` values;
7. installs Docker and gitlab-runner `19.5.0-1`, creates the instance runner through the API, writes
   `config.toml` with its authentication token, and checks it with `gitlab-runner verify`.

### Step 4. Publish the four repositories

From the repository root, with everything committed:

```bash
GITLAB_URL=$(terraform -chdir=ansible/terraform output -raw gitlab_url) scripts/publish_repos.sh infra
```

Wait until the infra pipeline has passed "Apply to Staging", run its manual approval, then publish
the apps:

```bash
GITLAB_URL=$(terraform -chdir=ansible/terraform output -raw gitlab_url) \
  scripts/publish_repos.sh api-gateway inventory-app billing-app
```

Each push starts that project's pipeline. `--dry-run` shows what would be pushed. The script asks
for the root password, or uses `GITLAB_PUSH_TOKEN` when set.

### Step 5. First deploy

The first infra apply creates the ECS services with the image tag from `terraform.tfvars`
(`staging-latest` or `production-latest`), which does not exist yet, so the services start with no
running tasks. Each app pipeline then deploys its commit-SHA image to staging, and after its manual
approval to production. Check it:

```bash
ALB=$(aws elbv2 describe-load-balancers --names code-keeper-staging-alb --query 'LoadBalancers[0].DNSName' --output text)
curl "http://${ALB}/health"
curl -X POST "http://${ALB}/api/movies" -H 'Content-Type: application/json' -d '{"title":"Alien","description":"1979"}'
curl "http://${ALB}/api/movies"
```

---

## 6. Usage, day to day

1. Work on a branch in one of the four projects and open a merge request.
2. The merge request pipeline runs the checks. GitLab only allows the merge once it passes and all
   review threads are resolved.
3. A Maintainer merges into `main`, which only Maintainers can push to.
4. The `main` pipeline builds and pushes the image (apps) or plans and applies (infra), and
   deploys to staging.
5. A stakeholder checks staging and runs the manual approval job.
6. Production is updated with a rolling deploy, and the pipeline waits until the services are
   stable.

**Redeploy everything** (for example before a demo): in each project, Build > Pipelines > Run
pipeline on `main`, then run the approvals. Run infra first. `scripts/restart_aws.sh` does the same
from the command line, approvals included (section 11).

**Add a team member**: add them to `gitlab_team_members` in `ansible/roles/gitlab/defaults/main.yml`
(or in the inventory) and run `ansible-playbook playbooks/deploy-gitlab.yml`. The account gets a
random password; set one under Admin > Users.

**Change a CI/CD variable**: export the new `CK_` value and run `deploy-gitlab.yml` again.

---

## 7. Pipelines in detail

### 7.1 Infrastructure (`infra/.gitlab-ci.yml`)

| Stage | Job | Runs on | What it does |
|---|---|---|---|
| Init | `infra:init:staging`, `infra:init:production` | main | `terraform init` against the S3 backend and lock table |
| Validate | `infra:validate:syntax` | every branch and MR | `terraform fmt -check -recursive`, `terraform validate` for both roots |
| Validate | `infra:validate:security` | every branch and MR | `trivy config --severity HIGH,CRITICAL --exit-code 1` (accepted findings in `.trivyignore`, each with its reason) |
| Validate | `infra:validate:dependencies` | main, advisory | provider versions: locked, newest allowed, newest released |
| Plan | `infra:plan:staging`, `infra:plan:production` | main | `terraform plan -out=<env>.tfplan`, kept as an artifact for the apply |
| Apply to Staging | `infra:apply:staging` | main, automatic | applies `staging.tfplan` |
| Approval | `infra:approval:production` | main, **manual**, blocking | the stakeholder's go-ahead |
| Apply to Production | `infra:apply:production` | main, after the approval | applies the reviewed `production.tfplan` |

Init, Plan and Apply need protected variables, which GitLab only passes to protected branches, so
they run on `main`; merge requests get the credential-free Validate jobs.

### 7.2 Microservices (`srcs/<service>/.gitlab-ci.yml`)

| Stage | Job | Runs on | What it does |
|---|---|---|---|
| Build | `build:package` | every branch and MR | installs the requirements, `python3 -m compileall`, keeps `requirements.txt` (and the gateway's `openapi.yaml`) |
| Test | `test:unit` | every branch and MR | `pytest` with coverage and a JUnit report |
| Scan | `scan:sast_bandit` | every branch and MR | Bandit static analysis, blocking on medium or higher |
| Scan | `scan:secret_detection` | every branch and MR | Gitleaks |
| Scan | `scan:trivy_fs` | every branch and MR | Trivy on the code and dependencies, blocking on HIGH and CRITICAL |
| Scan | `scan:sonarqube` | every branch and MR | SonarQube, when `SONAR_HOST_URL` and `SONAR_TOKEN` are set |
| Scan | `scan:dependencies` | every pipeline, also scheduled | `pip-audit`, advisory |
| Containerization | `containerize:docker` | MR (build only) and main (build and push) | Kaniko, unprivileged, pushes `docker.io/<repo>/<service>:<commit SHA>` |
| Containerization | `containerize:image_scan` | main | `trivy image` on the pushed image, blocking |
| Deploy to Staging | `deploy:staging` | main | checks the image exists, registers a task definition revision with it, `aws ecs update-service`, waits for `services-stable`, and for the gateway probes `/health` through the ALB |
| Approval | `approval:production` | main, **manual**, blocking | the stakeholder's go-ahead |
| Deploy to Production | `promote:image` | main, after the approval | copies the SHA tag to `production-latest` in the registry (crane, no Docker daemon) |
| Deploy to Production | `deploy:production` | main, after the approval | the same rolling update on the production cluster, then the health checks |

Job names start with the service name, for example `api-gateway:deploy:staging`.

**Zero downtime.** ECS starts the new tasks first (maximum 200 %), waits until they pass the
container health check and the load balancer health check, and only then stops the old ones
(minimum 100 %). The job waits for `services-stable`, so it fails if the new tasks do not become
healthy.

**Image tags.** Every image is tagged with its commit SHA, which never changes. `production-latest`
is only a record of what production runs; deploys always point ECS at the SHA tag.

---

## 8. Configuration reference

### 8.1 CI/CD variables

Ansible creates them from `CK_<name>` environment variables on the machine that runs it. They are
never written to the repository.

| Variable | Level | Protected | Masked | Used by |
|---|---|---|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | group | yes | yes | Terraform, ECS deploys |
| `DOCKERHUB_USERNAME` | group | yes | no | image push, image scan, ECS image pulls |
| `DOCKERHUB_TOKEN` | group | yes | yes | same |
| `DOCKERHUB_REPO` | group | no | no | image names (`docker.io/<repo>/<service>`) |
| `TF_STATE_BUCKET`, `TF_STATE_REGION`, `TF_STATE_LOCK_TABLE` | project `infra` | yes | no | Terraform backend |
| `TF_VAR_inventory_db_password`, `TF_VAR_billing_db_password`, `TF_VAR_rabbitmq_password` | project `infra` | yes | yes | RDS and Amazon MQ passwords, stored in Secrets Manager for the tasks |

Optional: `SONAR_HOST_URL` and `SONAR_TOKEN` (group) switch on the SonarQube upload.

### 8.2 Ansible

| Setting | Where | Default |
|---|---|---|
| `GITLAB_ROOT_PASSWORD` | environment, required | none |
| `CK_<variable>` | environment, optional | unset values are skipped |
| `gitlab_external_url` | inventory (`aws.ini`) | `http://<GitLab Elastic IP>` |
| `gitlab_version` / `gitlab_runner_version` | role defaults | `19.5.0-ce.0` / `19.5.0-1`; upgrade both together, one step of GitLab's upgrade path at a time |
| `gitlab_projects`, `gitlab_group_path` | `roles/gitlab/defaults/main.yml` | the four projects in `code-keeper` |
| `gitlab_team_members` | same | empty; Developer (30) unless `access_level: 40` |
| `gitlab_default_branch_push_access_level` / `..._merge_access_level` | same | 40 (Maintainer) |
| `gitlab_runner_tags`, `gitlab_runner_concurrent` | `roles/gitlab_runner/defaults/main.yml` | `docker, shared, ci-cd, linux`; 4 |
| `gitlab_runner_docker_privileged` | same | `false` |

### 8.3 Terraform for the GitLab hosts (`ansible/terraform/variables.tf`)

| Variable | Default | Notes |
|---|---|---|
| `admin_cidrs` | required | your address(es) for SSH; `0.0.0.0/0` is refused |
| `team_cidrs` | `["0.0.0.0/0"]` | who can reach GitLab on port 80 and Git over SSH |
| `gitlab_instance_type` / `runner_instance_type` | `t3.large` / `t3.medium` | GitLab needs at least 8 GB of memory |
| `ssh_public_key_path` / `ssh_private_key_path` | `~/.ssh/code-keeper.pub` / `~/.ssh/code-keeper` | |

### 8.4 Environments (`infra/environments/<env>/terraform.tfvars`)

Region, VPC and subnet ranges, availability zones, and `release_tag`, the image tag for the very
first task definitions only (see step 5).

---

## 9. Security

### Restrict triggers to protected branches

- `main` is protected in every project: only Maintainers push or merge, and force pushes are refused.
  Ansible sets this as the instance default for new projects.
- Every job that pushes images, applies Terraform or deploys has a `main`-only rule.
- The deploy credentials are protected variables, so GitLab gives them only to pipelines on protected
  branches. A pipeline on any other branch could not deploy even if its rules were changed.
- Merge request pipelines run the checks without credentials, and a merge needs a passing pipeline.

### Separate credentials from code

- No credential is committed. CI/CD variables (masked where possible) carry the secrets; Ansible
  reads them from the operator's environment, and `GITLAB_ROOT_PASSWORD` the same way.
- Terraform receives passwords as `TF_VAR_*` and stores them in AWS Secrets Manager. ECS injects
  each one into the container that needs it, and the variables are marked `sensitive`.
- The Ansible admin token is generated on each run, passed to GitLab through the environment and
  expires after one day. The runner's authentication token only lives in `config.toml` (mode 600).
  No legacy registration token is used.
- Gitleaks runs in every app pipeline, and `.gitignore` keeps state, plans, keys and `.env` files out.

### Apply the least privilege principle

- The runner is unprivileged and jobs get no Docker socket; images are built with Kaniko.
- Containers run as the non-root `appuser` (UID 10001).
- Network: every security group hop only accepts the hop before it, the databases only accept their
  own service, and nothing but the ALB is reachable from the internet.
- The ECS execution role may read only this environment's secrets.
- GitLab hosts: SSH only from `admin_cidrs`, the runner accepts nothing else, IMDSv2 only, encrypted
  disks. GitLab: sign-up disabled, private group, team members are Developers unless set otherwise,
  infra-only variables live on the infra project instead of the group.
- Known gap: the pipelines' IAM user has `AdministratorAccess`. See section 12.

### Update dependencies and tools regularly

- Versions are pinned so updates are deliberate and reviewable: GitLab and the runner, Terraform
  providers (`.terraform.lock.hcl`), Python packages (`requirements.txt`), Kaniko, crane (by
  digest), and the scanners installed with pip. The Trivy, Gitleaks, SonarQube and AWS CLI images
  still use `:latest` (section 12).
- Advisories are checked on every pipeline: Trivy on code, dependencies, images and Terraform,
  Bandit, Gitleaks and `pip-audit`. `scan:dependencies` also runs on scheduled pipelines, so new
  advisories against unchanged code are reported. Create a schedule per project under
  Build > Pipeline schedules.
- `infra:validate:dependencies` compares the locked provider versions with the newest ones the
  constraints allow and the newest released, on every `main` pipeline.
- `.github/dependabot.yml` describes the update policy for pip, Terraform and Docker. GitLab does not
  run it; Renovate would be the GitLab equivalent.

---

## 10. Verification and audit commands

**Locally, no cloud needed**

```bash
scripts/test_pipelines.sh        # structure, the four standalone pipelines, Dockerfiles, unit tests
scripts/verify_security.sh       # the four cybersecurity guidelines, checked in code
scripts/audit_orchestrator.sh    # every audit question mapped to automated checks
```

**Ansible**

```bash
cd ansible
ansible-playbook playbooks/site.yml --list-tasks
ansible-playbook playbooks/site.yml --syntax-check
ansible all -m ping
```

**On the GitLab host** (`terraform -chdir=ansible/terraform output -raw ssh_gitlab`)

```bash
sudo gitlab-ctl status
systemctl status gitlab-runsvdir
sudo gitlab-rake gitlab:env:info
```

**On the runner host** (`terraform -chdir=ansible/terraform output -raw ssh_runner`)

```bash
systemctl status gitlab-runner
sudo gitlab-runner list 2>&1 | sed -E 's/(Token[^=]*=)[^ ]+/\1<redacted>/'    # hides the runner token
sudo gitlab-runner verify
```

In GitLab: Admin > CI/CD > Runners shows the runner online, and each project's
Build > Pipelines shows its pipelines and the jobs the runner executed.

---

## 11. Costs and teardown

On-demand prices in us-east-1, roughly:

| What | Cost while running |
|---|---|
| Staging and production together (Fargate, 4 RDS, 2 brokers, 2 NAT gateways, 2 ALBs) | about $0.79 an hour |
| GitLab hosts (`t3.large` + `t3.medium`, disks, 2 public IPs) | about $0.14 an hour |

**Between sessions**, stop the hourly charges but keep GitLab:

```bash
scripts/stop_aws.sh      # destroys production, then staging, and stops the GitLab hosts (about 30 minutes)
scripts/restart_aws.sh   # starts the hosts and runs the four pipelines with their approvals (about an hour)
```

While stopped, only the hosts' disks and public IPs are billed, about $0.45 a day. GitLab keeps its
address, projects, history, variables and runner. `scripts/stop_aws.sh --dry-run` shows what is
running without changing anything; `scripts/restart_aws.sh --hosts-only` starts only GitLab and the
runner, and `--check` tests that a restart would work.

**When you are done**, remove everything in this order (the state bucket and lock table can stay):

```bash
# both environments, production first; the script turns off the load balancers' deletion protection
scripts/stop_aws.sh
# the GitLab hosts
terraform -chdir=ansible/terraform destroy -var 'admin_cidrs=["<your public IP>/32"]'
```

`docs/AWS_SETUP.md` lists the checks for anything billable left behind.

---

## 12. Known limitations

- **No TLS.** There is no domain, so there is no certificate: the ALB and GitLab serve plain HTTP.
  Logins to GitLab cross the internet unencrypted, which is why `team_cidrs` should be narrowed. The
  accepted Trivy findings in `infra/.trivyignore` say the same.
- **Plan artifacts contain secrets.** `<env>.tfplan` holds the variable values, and project members
  can download it for 7 days.
- **Some images use `latest`**: Trivy, the AWS CLI, Gitleaks and the SonarQube scanner.
- **SonarQube is not configured**, so that job skips the upload unless the two variables are set.
- **The pipelines' IAM user has `AdministratorAccess`.** A policy limited to the services Terraform
  manages (VPC, EC2, ECS, RDS, MQ, ELB, IAM roles, Secrets Manager, CloudWatch Logs, S3 and DynamoDB
  for state) would be tighter.
- **Production is sized like staging**, and RDS keeps 1 day of backups (the Free plan's maximum;
  the paid plan allows up to 35).

---

## 13. Role-play questions

Short answers to the questions in `docs/audit.md`. `docs/AUDIT_GUIDE.md` has the long versions.

### Q1: Can you explain the concept of DevOps and its benefits for the software development lifecycle?

DevOps puts development and operations on one delivery process, automated end to end: small
changes, tested and shipped often, with fast feedback. The result is shorter lead times, fewer
failed releases and faster recovery when something does break.

### Q2: How do DevOps principles help improve collaboration between development and operations teams?

Both work from the same repositories and the same pipeline. Developers see the production rules
(scans, approval, deploy) in `.gitlab-ci.yml`; operations changes go through merge requests in the
`infra` project like any other code change, reviewed by the same people.

### Q3: What are some common DevOps practices, and how did you incorporate them into your project?

Version control for everything, CI on every merge request, CD with a manual production gate,
infrastructure as code (Terraform), configuration management (Ansible), security scanning inside
the pipeline, and immutable images tagged with their commit.

### Q4: How does automation play a key role in the DevOps process, and what tools did you use to automate different stages of your project?

Automation makes every run identical and removes manual steps that go wrong. Terraform creates the
cloud resources, Ansible installs and configures GitLab and the runner, GitLab CI builds, tests,
scans and deploys, Kaniko packages the services, crane promotes images, and the AWS CLI rolls ECS.

### Q5: Can you discuss the role of continuous integration and continuous deployment (CI/CD) in a DevOps workflow, and how it helps improve the quality and speed of software delivery?

CI catches problems on the merge request, before they reach `main`. CD makes every merge a
deployable release: staging automatically, production after one approval. Quality goes up because
nothing skips the checks, and speed goes up because nothing waits for a manual release process.

### Q6: Can you explain the importance of infrastructure as code (IaC) in a DevOps environment, and how it helps maintain consistency and reproducibility in your project?

Both environments are the same Terraform modules with different variables, so staging really is a
replica of production. Every change is reviewed in a merge request, planned before it is applied,
and the whole environment can be destroyed and rebuilt from the code.

### Q7: How do DevOps practices help improve the security of an application, and what steps did you take to integrate security into your development and deployment processes?

Security checks run on every change instead of once before a release. Here: protected `main` and
protected variables, merge request pipelines without credentials, scanners in every pipeline,
non-root containers, least-privilege network rules, and a manual gate before production.

### Q8: What challenges did you face when implementing DevOps practices in your project, and how did you overcome them?

AWS Free plan limits on RDS (2 instances, 1 day of backups), which the paid plan lifted; image
builds without a Docker daemon on an unprivileged runner (Kaniko); the plain `crane` images having
no shell for GitLab (the pinned debug image); GitLab 17+ disabling registration tokens (runners are
now created through the API); and splitting one repository into four independent pipelines.

### Q9: How can DevOps practices help optimize resource usage and reduce costs in a cloud-based environment?

The sizes are variables, so staging can stay small; everything can be destroyed and recreated from
code, so nothing has to run between sessions; Fargate bills per running task; and the GitLab hosts
can be stopped or destroyed when not in use.

### Q10: Can you explain the purpose and benefits of using GitLab and GitLab Runners in your project, and how they improve the development and deployment processes?

GitLab holds the repositories, merge requests, CI/CD variables and pipeline history in one place.
The runner executes every job in a clean container on its own host, so builds never touch the
GitLab server and can be scaled by adding runners.

### Q11: What are the advantages of using Ansible for automation in your project, and how did it help you streamline the deployment of GitLab and GitLab Runners?

Ansible is agentless (only SSH and Python on the hosts), idempotent and readable. One command
rebuilds GitLab with the same version and settings, and it also configures GitLab itself (settings,
projects, merge rules, variables, runner) through the API.

### Q12: Can you explain the concept of Infrastructure as Code (IaC) and how you implemented it using Terraform in your project?

IaC describes the infrastructure in versioned files instead of console clicks. Terraform modules
for the VPC, security groups, RDS, Amazon MQ and ECS are used by two root modules, one per
environment, with remote state in S3 and DynamoDB locking, and a saved plan that the apply uses.

### Q13: What is the purpose of using continuous integration and continuous deployment (CI/CD) pipelines, and how did it help you automate the building, testing, and deployment of your application?

Every change is built, tested, scanned, packaged and deployed the same way, with a record of who
approved what. A merge to `main` is all it takes to get a change to staging, and one approval
takes it to production.

### Q14: How did you ensure the security of the application throughout the pipeline stages?

Build and Test run in clean containers; Scan runs Bandit, Gitleaks, Trivy and pip-audit;
Containerization builds without privileges and Trivy scans the pushed image; deploys need
protected variables that only `main` gets; production needs a manual approval. Section 9 has the
details.

### Q15: Can you explain the continuous integration (CI) pipeline you've implemented for each repository?

Build (install and compile), Test (pytest with coverage), Scan (Bandit, Gitleaks, Trivy,
SonarQube, pip-audit) and Containerization (Kaniko build and push with the commit SHA tag, then a
Trivy image scan). Section 7.2 lists every job.

### Q16: Can you explain the continuous deployment (CD) pipeline you've implemented for each repository?

Deploy to Staging (new task definition revision with the SHA image, rolling update, wait until
stable, health check), Approval (manual, blocking), Deploy to Production (promote the image, the
same rolling update on production). For the infrastructure: Apply to Staging, Approval, Apply to
Production with the reviewed plan.

---

## 14. Bonus

- **Infrastructure security scan**: `trivy config` in the infra Validate stage, blocking on HIGH and
  CRITICAL. Trivy replaced tfsec, so tfsec itself is not used.
- **GitLab platform as code**: Terraform for the GitLab hosts, and Ansible configures GitLab itself
  through its API (group, projects, merge rules, members, variables, runner).
- **Verification scripts** that check the pipelines, the security guidelines and each audit
  question locally.
- **Unprivileged image builds** with Kaniko, and image builds without push on merge requests.
- **OpenAPI 3 description** of the gateway in `srcs/api-gateway/openapi.yaml`, served by the
  gateway as Swagger UI at `/docs` and as YAML at `/openapi.yaml`.
