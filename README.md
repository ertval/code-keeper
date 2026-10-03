# Code-Keeper: Enterprise DevOps & Microservices CI/CD Infrastructure

[![CI/CD Pipeline](https://img.shields.io/badge/GitLab%20CI-Passing-brightgreen?logo=gitlab)](infra/.gitlab-ci.yml)
[![Ansible Automation](https://img.shields.io/badge/Ansible-Automated-red?logo=ansible)](ansible/)
[![Terraform IaC](https://img.shields.io/badge/Terraform-AWS%20Multi--Env-blue?logo=terraform)](infra/)
[![Security Audited](https://img.shields.io/badge/Security-Hardened-success?logo=trivy)](scripts/verify_security.sh)

`code-keeper` delivers an enterprise-grade DevOps platform and end-to-end continuous integration and deployment (CI/CD) system for a containerized microservices application. This repository contains the complete automation stack:

1. **Ansible Automation (`ansible/`)**: Automated provisioning, hardening, and configuration of GitLab Community Edition (CE) and GitLab Runners with Docker executors.
2. **Infrastructure as Code (`infra/`)**: Dual-environment (Staging & Production) AWS infrastructure defined in modular Terraform, managed via a 6-stage automated pipeline with manual production gating.
3. **Independent Microservice Pipelines (`srcs/api-gateway/`, `srcs/inventory-app/`, `srcs/billing-app/`)**: Full Python source code, container definitions, and independent 7-stage CI/CD pipelines featuring zero-downtime rolling deployments, SAST, container scanning, secret detection, and automated testing.
4. **Cybersecurity Hardening**: Strict branch protection enforcement, credential decoupling via GitLab masked/protected variables, least-privilege network and container access, and automated vulnerability scanning.
5. **Verification & Audit Tooling (`scripts/`)**: Complete simulation and verification scripts (`test_pipelines.sh` and `verify_security.sh`) to audit pipelines and security compliance before deployment.

---

## 1. System Architecture

### 1.1 Infrastructure Network & Cloud Topology (AWS)

```
                            INTERNET (End-Users & Developers)
                                           │
                                    HTTP 80 (ALB listener)
                                           │
               ┌───────────────────────────▼───────────────────────────┐
               │         AWS Application Load Balancer (Public)        │
               │   aws_lb_listener.http — port 80 only (no TLS/ACM)     │
               └───────────────┬───────────────────────┬───────────────┘
                               │ HTTP 3000             │ HTTP 3000
                               ▼                       ▼
    ┌────────────────────────────────────────────────────────────────────────┐
    │ Private Application Subnets (AWS VPC)                                  │
    │                                                                        │
    │  ┌──────────────────────┐                     ┌──────────────────────┐ │
    │  │   api-gateway    │── HTTP /api/movies ─►│    inventory-app     │ │
    │  │ (Waitress/Flask:3000)│                     │ (Waitress/Flask:8080)│ │
    │  └──────────┬───────────┘                     └──────────┬───────────┘ │
    │             │                                            │             │
    │      AMQP   │ POST /api/billing                          │ Port 5432   │
    │      5672   │                                            ▼             │
    │             ▼                                 ┌──────────────────────┐ │
    │  ┌──────────────────────┐     Consume AMQP    │  inventory-database  │ │
    │  │   Amazon MQ /        │◄────────────────────│  (PostgreSQL:5432)   │ │
    │  │   RabbitMQ Broker    │                     └──────────────────────┘ │
    │  └──────────────────────┘                                              │
    │             ▲                                                          │
    │             │ AMQP 5672                                                │
    │  ┌──────────┴───────────┐                                              │
    │  │     billing-app      │─── Port 5432 ──────►┌──────────────────────┐ │
    │  │  (Worker & HTTP:8080)│                     │   billing-database   │ │
    │  └──────────────────────┘                     │  (PostgreSQL:5432)   │ │
    │                                               └──────────────────────┘ │
    └────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Multi-Stage Pipeline Architecture

```
MICROSERVICE PIPELINE:
  [Build] ──► [Test] ──► [Scan] ──► [Containerization] ──► [Deploy to Staging] ──► [Approval] ──► [Deploy to Production]
  - Bytecode   - Pytest   - Bandit    - Docker build        - Rolling update       (Manual Gate    - Zero Downtime
  - Packaging  - Coverage - Trivy FS  - Trivy Container     - Smoke Test            Stakeholder    - Min Healthy 100%
                          - Gitleaks  - Push to Registry                              Sign-off)     - Max Healthy 200%
                          - SonarQube

INFRASTRUCTURE PIPELINE:
  [Init] ──► [Validate] ──► [Plan] ──► [Apply to Staging] ──► [Approval] ──► [Apply to Production]
  - Backend   - tf fmt      - Staging   - Auto-apply           (Manual Gate   - Auto-apply
  - Providers - tf validate - Prod        Staging Plan          Stakeholder     Production Plan
              - Trivy IaC                                         Sign-off)
```

---

## 2. Directory Structure

```
code-keeper/
├── ansible/
│   ├── ansible.cfg                    # Ansible configuration for this subtree
│   ├── inventory/
│   │   └── hosts.ini                # Target servers (gitlab_servers, gitlab_runners)
│   ├── playbooks/
│   │   ├── deploy-gitlab.yml        # Installs and configures GitLab CE omnibus
│   │   └── deploy-runners.yml       # Installs Docker & registers GitLab Runner
│   ├── roles/
│   │   ├── gitlab/                  # GitLab CE deployment role
│   │   │   ├── defaults/main.yml    # Default ports, URLs, backup and admin settings
│   │   │   ├── handlers/main.yml    # Reconfigure & restart handlers
│   │   │   ├── tasks/
│   │   │   │   ├── main.yml         # Role coordinator
│   │   │   │   ├── install.yml      # Package dependencies and apt repo setup
│   │   │   │   ├── configure.yml    # Renders gitlab.rb and runs gitlab-ctl reconfigure
│   │   │   │   └── cicd.yml         # Rails runner configuring branch protection & CI
│   │   │   └── templates/
│   │   │       └── gitlab.rb.j2     # Production Omnibus template
│   │   └── gitlab_runner/           # Runner registration role
│   │       ├── defaults/main.yml    # Docker executor settings, concurrency, tags
│   │       ├── handlers/main.yml    # Runner restart handler
│   │       ├── tasks/
│   │       │   ├── main.yml         # Role coordinator
│   │       │   ├── install.yml      # Installs Docker Engine & gitlab-runner package
│   │       │   ├── register.yml     # Non-interactive CLI runner registration
│   │       │   └── configure.yml    # Concurrency and systemd daemon management
│   │       └── templates/
│   │           └── config.toml.j2   # Runner configuration template
│   └── scripts/
│       ├── setup-gitlab.sh          # Helper to execute deploy-gitlab.yml
│       └── register-runner.sh       # Helper to execute runner registration
├── infra/
│   ├── .gitlab-ci.yml               # 6-stage Infrastructure Pipeline
│   ├── environments/
│   │   ├── staging/                 # Staging environment definitions
│   │   │   ├── main.tf              # Module invocations + partial S3 backend for Staging
│   │   │   ├── backend.hcl          # Partial backend config: bucket/key/DynamoDB lock table
│   │   │   ├── variables.tf         # Staging variables (cost-optimized, single AZ)
│   │   │   ├── outputs.tf           # Staging endpoint outputs
│   │   │   ├── terraform.tfvars     # Environment values
│   │   │   └── .terraform.lock.hcl  # Pinned provider versions
│   │   └── production/              # Production environment definitions
│   │       ├── main.tf              # Identical module invocations for Production
│   │       ├── backend.hcl          # Partial backend config for the production key
│   │       ├── variables.tf         # Production variables (Multi-AZ, high replicas)
│   │       ├── outputs.tf           # Production endpoint outputs
│   │       ├── terraform.tfvars     # Environment values
│   │       └── .terraform.lock.hcl  # Pinned provider versions
│   └── modules/
│       ├── vpc/                     # VPC, Public/Private/Database subnets, NAT, IGW
│       ├── security_groups/         # Principle of Least Privilege SG rules
│       ├── rds/                     # PostgreSQL instances (movies & orders)
│       ├── rabbitmq/                # Managed Amazon MQ RabbitMQ broker
│       └── compute/                 # ALB, ECS Cluster, Task Definitions, Services
├── srcs/                            # Microservice application source code
│   ├── api-gateway/
│   │   ├── .gitlab-ci.yml           # 7-stage microservice CI/CD pipeline
│   │   ├── Dockerfile               # Hardened Alpine image with unprivileged appuser
│   │   ├── requirements.txt         # Python dependencies
│   │   ├── pytest.ini               # pytest/coverage configuration
│   │   ├── server.py                # Waitress production WSGI entrypoint
│   │   ├── openapi.yaml             # OpenAPI specification
│   │   ├── app/                     # Reverse proxy & RabbitMQ producer logic
│   │   └── tests/
│   │       └── test_gateway.py      # Unit & integration tests
│   ├── inventory-app/
│   │   ├── .gitlab-ci.yml           # 7-stage microservice CI/CD pipeline
│   │   ├── Dockerfile               # Hardened Alpine image with unprivileged appuser
│   │   ├── requirements.txt         # Python dependencies
│   │   ├── pytest.ini               # pytest/coverage configuration
│   │   ├── server.py                # Waitress production WSGI entrypoint
│   │   ├── app/                     # RESTful movies CRUD & SQLAlchemy models
│   │   └── tests/
│   │       └── test_inventory.py    # Comprehensive CRUD & healthcheck tests
│   └── billing-app/
│       ├── .gitlab-ci.yml           # 7-stage microservice CI/CD pipeline
│       ├── Dockerfile               # Hardened Alpine image with unprivileged appuser
│       ├── requirements.txt         # Python dependencies
│       ├── pytest.ini               # pytest/coverage configuration
│       ├── server.py                # Waitress production WSGI entrypoint
│       ├── app/                     # AMQP consumer worker & orders database handler
│       └── tests/
│           └── test_billing.py      # Order validation, model, and endpoint tests
├── scripts/
│   ├── test_pipelines.sh            # Complete verification and test script
│   ├── verify_security.sh           # Cybersecurity compliance audit script
│   └── audit_orchestrator.sh        # Audit harness that fans the checks out to per-item verdicts
├── docs/
│   ├── readme.md                    # 01-edu subject requirements (source of truth)
│   ├── audit.md                     # Auditor checklist and evaluation criteria
│   └── AUDIT_GUIDE.md               # Audit defense manual & stakeholder Q&A
├── .github/
│   └── dependabot.yml               # Dependabot schedule (inert on GitLab; see 7.1)
├── ansible.cfg                      # Control-node Ansible configuration
├── .gitignore                       # Guards credentials, .env, tfstate, and artifacts
└── README.md                        # Implementation documentation and audit answers
```

---

## 3. Component Walkthrough & Deployment

### 3.1 GitLab CE & Runner Deployment via Ansible

#### Prerequisites
- Ansible `>= 2.14` and Python 3 on the control node.
- Target Ubuntu/Debian server for GitLab CE and Runner nodes with SSH key access.

#### Target Inventory (`ansible/inventory/hosts.ini`)
```ini
[gitlab_servers]
gitlab-server ansible_host=192.168.56.10 ansible_user=ubuntu ansible_python_interpreter=/usr/bin/python3

[gitlab_runners]
gitlab-runner-01 ansible_host=192.168.56.11 ansible_user=ubuntu ansible_python_interpreter=/usr/bin/python3
```

#### Running Playbooks
1. **Deploy GitLab Server**:
   ```bash
   # Syntax validation
   ./ansible/scripts/setup-gitlab.sh --syntax-check

   # Execute deployment (root password is read from the environment, never committed)
   export GITLAB_ROOT_PASSWORD='<SET_ME_IN_YOUR_SHELL_OR_CI_MASKED_VARIABLE>'
   GITLAB_EXTERNAL_URL="http://gitlab.example.com" \
   ./ansible/scripts/setup-gitlab.sh --run
   ```

2. **Deploy & Register GitLab Runner**:
   ```bash
   GITLAB_EXTERNAL_URL="http://gitlab.example.com" \
   GITLAB_RUNNER_TOKEN="<REGISTRATION_TOKEN_FROM_GITLAB>" \
   ./ansible/scripts/register-runner.sh --ansible
   ```

#### Auditor Verification Commands
```bash
# List all tasks defined in the playbooks
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-gitlab.yml --list-tasks
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-runners.yml --list-tasks

# Verify GitLab services status on target host
gitlab-ctl status
systemctl status gitlab-runsvdir

# Verify Runner status on runner host
gitlab-runner list
systemctl status gitlab-runner
```

---

### 3.2 Infrastructure as Code (Terraform)

The infrastructure provisions two environments with strict architectural parity:

| Resource | Staging Environment | Production Environment | Design Rationale |
|---|---|---|---|
| **VPC CIDR** | `10.10.0.0/16` | `10.20.0.0/16` | Non-overlapping CIDRs for VPC peering |
| **Availability Zones** | `us-east-1a`, `us-east-1b` | `us-east-1a`, `us-east-1b` | High-availability multi-zone distribution |
| **PostgreSQL RDS** | `db.t3.micro`, Single-AZ, 20GB | `db.t3.small`, Multi-AZ, 50GB | Cost-effective in staging; resilient & scalable in prod |
| **RabbitMQ Broker** | `mq.t3.micro`, SINGLE_INSTANCE | `mq.m5.large`, CLUSTER_MULTI_AZ | High-throughput clustered broker in production |
| **ECS Microservices** | 2 replicas each | 4 replicas each (auto-scaling) | Production absorbs peak customer load |
| **ECS Zero-Downtime** | 100% min / 200% max | 100% min / 200% max | Guarantees zero outage during container updates |

#### 6-Stage Infrastructure Pipeline (`infra/.gitlab-ci.yml`)
1. **`Init`**: Runs `terraform init -input=false` for staging and production backends.
2. **`Validate`**: Runs `terraform fmt -check` and `terraform validate`, followed by `trivy config` IaC security scans.
3. **`Plan`**: Generates execution plans (`staging.tfplan` and `production.tfplan`) with changes previewed and saved as artifacts.
4. **`Apply to Staging`**: Automatically applies changes to the staging environment upon merge to `main`.
5. **`Approval`**: Manual gate (`when: manual`, `allow_failure: false`). Requires authorized DevOps engineer sign-off to proceed to production.
6. **`Apply to Production`**: Applies the reviewed `production.tfplan` to the live production environment.

#### Local Validation (no AWS account required)

The Terraform in this repository is **designed and statically validated, not deployed**. There is no committed state file and no AWS account behind these environments, so the following commands are the reproducible evidence of correctness; a live `terraform plan`/`apply` additionally requires `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (or an instance role) and a real `us-east-1` account.

Run from the repository root. Use `-backend=false` for offline validation so Terraform does not try to reach the S3 state bucket; the remote backend is configured separately via `-backend-config=backend.hcl`.

```bash
# Formatting (whole tree, read-only check)
terraform fmt -check -recursive infra/

# Static validation of both environment roots, offline
for env in staging production; do
  ( cd "infra/environments/${env}" \
    && terraform init -backend=false -input=false \
    && terraform validate )
done
```

Both roots currently report `Success! The configuration is valid.` To initialise against real remote state instead, drop `-backend=false` and supply the partial backend:

```bash
( cd infra/environments/staging \
  && terraform init -backend-config=backend.hcl \
  && terraform plan )
```

`backend.hcl` carries the bucket, key, region, DynamoDB lock table, and `encrypt = true`; the roots declare only `backend "s3" {}`, so no state location or credential is committed.

#### Running the Microservice Test Suites

`pytest` is not assumed to be on the control node's `PATH` and the application dependencies are not installed globally, so install them into an ephemeral `uv` environment rather than invoking `python3 -m pytest`. Note the `srcs/` prefix — the applications are subdirectories of this repository, not repository roots.

```bash
for app in api-gateway inventory-app billing-app; do
  ( cd "srcs/${app}" \
    && uv run --with pytest --with pytest-cov \
              --with-requirements requirements.txt \
              pytest -q )
done
```

Each service carries its own `pytest.ini`, so coverage and test paths resolve correctly from inside its directory. All three suites currently pass; read the per-suite summary line pytest prints for the exact counts.

---

### 3.3 Microservices CI/CD Pipelines

Each microservice (`api-gateway`, `inventory-app`, `billing-app`) operates an independent pipeline with 7 stages:

1. **`Build`**: Installs dependencies and compiles Python bytecode (`python3 -m compileall -b .`) to verify packaging integrity.
2. **`Test`**: Executes unit and integration test suites with `pytest` and generates code coverage and JUnit XML reports.
3. **`Scan`**:
   - **SAST**: `bandit -r app/` scans Python AST for insecure patterns.
   - **Secret Scanning**: `gitleaks` checks for exposed API keys, private keys, or passwords.
   - **Filesystem / Dependency Scanning**: `trivy fs --severity HIGH,CRITICAL .` checks for CVEs.
   - **Code Quality**: `sonar-scanner-cli` analyzes code quality and security gates.
4. **`Containerization`**: Builds the Docker image in a `docker:24.0.5` job with a `docker:24.0.5-dind` service, scans the built image with `trivy image`, then pushes two tags to the registry: the immutable `${CI_COMMIT_SHORT_SHA}` and the mutable `staging-latest`. The build is single-architecture (plain `docker build`, no `buildx`/`--platform`).
5. **`Deploy to Staging`**: Triggers rolling deployment on AWS ECS Staging cluster and performs automated HTTP `/health` smoke test.
6. **`Approval`**: Manual approval gate (`when: manual`) ensuring stakeholder review before production rollout.
7. **`Deploy to Production`**: Waits on `approval:production`, then runs `aws ecs update-service --force-new-deployment` against the production service (`minimumHealthyPercent=100`, `maximumPercent=200`), blocks on `aws ecs wait services-stable`, and probes the service health endpoint. The deployment promotes the immutable SHA tag that was already pushed in `Containerization`; no `production-latest` tag is pushed by the pipeline. Because the pipeline targets `staging.code-keeper.internal` / `production.code-keeper.internal`, which are not publicly resolvable names, the health `curl` only succeeds from inside the VPC.

### 3.4 Monorepo Path-Gating (Simulated Service Independence)

This repo is a monorepo, but each pipeline behaves like an independent repo via
`rules:changes:paths`: `infra/**/*` gates Init/Validate/Plan, and
`srcs/api-gateway/**/*`, `srcs/inventory-app/**/*`, `srcs/billing-app/**/*` gate the matching
service's Build/Test/Scan jobs. Deploys stay `main`-only. All four pipelines are
`main`-only via `workflow:rules: - if: $CI_COMMIT_BRANCH == "main" / - when: never`,
so no merge-request pipeline is created; see
[Known deviations from the brief](#known-deviations-from-the-brief).

Upstream mapping (crud-master / cloud-design): service names and variables
mirror the sibling projects — `APP_NAME` (`api-gateway`, `inventory-app`,
`billing-app`), Postgres DBs `movies` (inventory) / `orders` (billing),
`RABBITMQ_QUEUE=billing_queue`, ECS cluster `code-keeper-<env>-cluster` and
services `code-keeper-<env>-<app>` (see `infra/modules/compute/main.tf`),
health endpoint `/health` (`:3000` gateway, `:8080` inventory/billing).

---

## 4. Cybersecurity Compliance & Best Practices

The platform enforces the 4 mandatory cybersecurity pillars:

### 4.1 Restrict Triggers to Protected Branches
- All CD jobs (`containerize:docker`, `deploy:staging`, `approval:production`, `deploy:production`, `apply:staging`, `apply:production`) are locked to the protected `main` branch using GitLab CI rules:
  ```yaml
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  ```
- Pushes to `main` are restricted to Maintainers and force-push is disabled. This is applied by `ansible/roles/gitlab/tasks/cicd.yml`, which sets `default_branch_protection_defaults` with `allowed_to_push => Gitlab::Access::MAINTAINER` and `allow_force_push => false`. Two honest caveats: `allowed_to_merge` is set to `Gitlab::Access::DEVELOPER`, so developers **can** merge into `main`; and the `gitlab_default_branch_protection: 2` key in `ansible/roles/gitlab/defaults/main.yml` is currently declared but not consumed by any task, so it has no effect on the running instance.

### 4.2 Separate Credentials from Code
- Zero plaintext credentials or tokens in git repositories.
- AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), database passwords, and registry tokens are configured as **Masked & Protected Variables** in GitLab CI/CD settings.
- Repository `.gitignore` prevents inadvertent commits of `.env`, `*.tfstate`, `*.pem`, `*.key`, and build artifacts.
- Automated secret detection with `gitleaks` runs on every commit.

### 4.3 Apply the Least Privilege Principle
- **Container Isolation**: Dockerfiles execute as an unprivileged, non-root user (`USER appuser`, UID `10001`).
- **Network Micro-segmentation**:
  - The ALB security group permits inbound 80 and 443 from `0.0.0.0/0`, but `infra/modules/compute/main.tf` defines only an `aws_lb_listener.http` on port 80 — TLS termination is not yet configured (no ACM certificate, no HTTPS listener), so only HTTP is actually served.
  - API Gateway accepts port 3000 **only** from the ALB security group.
  - Inventory App accepts port 8080 **only** from the API Gateway security group.
  - PostgreSQL RDS instances accept port 5432 **only** from Inventory and Billing security groups (strictly 0.0.0.0/0 forbidden).
  - RabbitMQ AMQP port 5672 accepts traffic **only** from API Gateway and Billing App security groups.
- **IAM Minimization**: ECS tasks assume designated execution roles scoped solely to CloudWatch logging and ECR image pull.

### 4.4 Update Dependencies and Tools Regularly
- Multi-tier automated security scanners integrated into CI pipelines:
  - `trivy fs` and `trivy image` for container and dependency vulnerabilities.
  - `bandit` for AST-level application security scanning.
  - Dependabot configuration for `pip` and `docker` ecosystems is committed at `.github/dependabot.yml`; it is currently inert because the project is hosted on GitLab, where `.github/` automation does not execute (see [§7.1](#71-considered-but-not-implemented)).
  - Base Docker images built from stable Alpine Linux releases (`alpine:3.23`).

---

## 5. Verification & Test Execution

Run the provided verification scripts to audit all pipelines and security controls:

```bash
# 1. Validate all pipelines, Ansible playbooks, and Dockerfiles
./scripts/test_pipelines.sh

# 2. Verify cybersecurity compliance, branch protection, and least-privilege rules
./scripts/verify_security.sh
```

### Verification Script Output

Both scripts print one `[PASS]`/`[FAIL]` line per assertion and close with a summary block. Read the totals from that summary block rather than from any number quoted here — the assertion count changes whenever a check is added, and both scripts are actively maintained.

```text
============================================================
  CODE-KEEPER PIPELINE & INFRASTRUCTURE TEST SUITE
============================================================
  [PASS] <check name>
  ...
============================================================
  Total Assertions Passed: <N>
  >>> ALL CODE-KEEPER PIPELINE TESTS PASSED! <<<

============================================================
  CODE-KEEPER CYBERSECURITY AUDIT & VERIFICATION
============================================================
  [PASS] <control name>
  ...
  CYBERSECURITY AUDIT SUMMARY
  Controls Passed: <N>
  Controls Failed: 0
  >>> ALL CYBERSECURITY COMPLIANCE CONTROLS PASSED! <<<
```

A `[FAIL]` line in either output is the signal to act: both scripts exit non-zero when any assertion fails, so they are usable as local gates and as CI checks.

---

## 6. Audit & Stakeholder Role-Play Q&A Guide

Below are direct, comprehensive answers to the questions listed in [`docs/audit.md`](docs/audit.md) for the stakeholder interview. The full defense manual lives in [`docs/AUDIT_GUIDE.md`](docs/AUDIT_GUIDE.md), and the original 01-edu subject requirements are preserved in [`docs/readme.md`](docs/readme.md):

### Q1: Can you explain the concept of DevOps and its benefits for the software development lifecycle?
**Answer**: DevOps is a cultural and technical methodology that bridges the gap between software development (Dev) and IT operations (Ops). By introducing continuous collaboration, automated testing, continuous integration, and automated deployment, DevOps shortens the development life cycle, increases deployment frequency, reduces change failure rates, and accelerates time-to-market while ensuring high quality and system reliability.

### Q2: How do DevOps principles help improve collaboration between development and operations teams?
**Answer**: DevOps eliminates departmental silos through shared responsibility, common metrics, and unified tooling. Developers write code that conforms to containerized environments identical to production, while operations engineers provide automated CI/CD pipelines, reusable Infrastructure as Code (IaC) modules, and observability tools. Both teams collaborate via version control, automated approval gates, and blameless post-mortems.

### Q3: What are some common DevOps practices, and how did you incorporate them into your project?
**Answer**:
- **Continuous Integration (CI)**: Microservice pipelines automatically build bytecode, run unit tests, and perform SAST/container security scanning on every push.
- **Continuous Deployment (CD)**: Automated deployments to staging followed by gated zero-downtime rolling updates to production.
- **Infrastructure as Code (IaC)**: Terraform manages all networking, database, messaging, and compute resources across staging and production environments.
- **Configuration Management**: Ansible automates the deployment and configuration of the GitLab server and GitLab Runners.
- **DevSecOps**: Multi-layer security scanning (Trivy, Bandit, Gitleaks) built directly into the CI pipeline.

### Q4: How does automation play a key role in the DevOps process, and what tools did you use to automate different stages of your project?
**Answer**: Automation eliminates manual human error, ensures repeatability, accelerates cycle times, and enforces compliance. In this project:
- **Ansible**: Automates host provisioning, package installation, and service configuration for GitLab and Runners.
- **Terraform**: Automates cloud infrastructure creation and lifecycle management.
- **GitLab CI/CD**: Automates testing, scanning, container packaging, and deployment orchestration.
- **Docker**: Automates runtime packaging into consistent, immutable container images.

### Q5: Can you discuss the role of CI/CD in a DevOps workflow, and how it helps improve the quality and speed of software delivery?
**Answer**: CI continuously integrates code changes into a shared repository several times a day, catching bugs early via automated tests and scans. CD ensures that validated code can be deployed to staging and production automatically or at the press of a button. This feedback loop reduces integration conflicts, guarantees artifact reproducibility, and enables organizations to deliver features to customers in minutes rather than weeks.

### Q6: Can you explain the importance of Infrastructure as Code (IaC) in a DevOps environment, and how it helps maintain consistency and reproducibility in your project?
**Answer**: IaC treats infrastructure definitions as software code. It eliminates configuration drift, enables version tracking in git, supports peer review via pull requests, and allows environments to be torn down and recreated identically on demand. In this project, `infra/environments/staging` and `infra/environments/production` use the exact same modular blueprints, preventing discrepancies between staging tests and production deployments.

### Q7: How do DevOps practices help improve the security of an application, and what steps did you take to integrate security into your development and deployment processes?
**Answer**: Security is "shifted left" into the development cycle (DevSecOps):
1. Pipelines run automated static analysis (`bandit`), secret scanning (`gitleaks`), and vulnerability scanning (`trivy`).
2. Production deployments require manual approval gates from authorized operators.
3. Deployment jobs only trigger on protected branches (`main`).
4. Credentials are separated into masked GitLab environment variables, preventing secrets from entering version control.
5. Least privilege is enforced at the network (Security Groups) and container level (non-root `appuser`).

### Q8: What challenges did you face when implementing DevOps practices in your project, and how did you overcome them?
**Answer**:
- **Challenge 1: Zero-Downtime Deployments**: Solved by configuring AWS ECS rolling deployments with `minimumHealthyPercent = 100` and `maximumPercent = 200`, ensuring new containers pass health checks before old containers are drained and decommissioned.
- **Challenge 2: Environment Parity vs Cost**: Staging must mirror production architecture but remain cost-effective. Solved by parameterizing Terraform modules (e.g., Single-AZ `db.t3.micro` for staging vs Multi-AZ `db.t3.small` for production).
- **Challenge 3: Multi-Service Asynchronous Communication**: The API Gateway forwards billing orders asynchronously via RabbitMQ to decouple load spikes from database write pressure.

### Q9: How can DevOps practices help optimize resource usage and reduce costs in a cloud-based environment?
**Answer**: IaC allows non-production environments to be scheduled, scaled down, or destroyed when not in use. Automated CI/CD enables rightsizing and auto-scaling based on real workloads: the Terraform modules in `infra/` take instance classes, replica counts, and multi-AZ flags as variables, so the same blueprint can be sized down for staging (`db.t3.micro`, single-AZ, 2 replicas) or up for production (`db.t3.small`, multi-AZ, 4 replicas). Cost-estimate tooling such as Infracost was evaluated but is **not integrated** — the `Plan` stage of `infra/.gitlab-ci.yml` runs `terraform plan` only. Adding shift-left cost visibility remains an open improvement.

### Q10: Can you explain the purpose and benefits of using GitLab and GitLab Runners in your project, and how they improve the development and deployment processes?
**Answer**: GitLab provides an all-in-one DevOps platform housing git repositories, issue tracking, container registry, and CI/CD pipelines in a unified interface. GitLab Runners execute pipeline jobs in isolated Docker containers, allowing elastic scaling of build workloads, distributed caching, and clean execution environments for every commit.

### Q11: What are the advantages of using Ansible for automation in your project, and how did it help you streamline the deployment of GitLab and GitLab Runners?
**Answer**: Ansible is agentless, idempotent, and uses human-readable YAML playbooks. It connects via standard SSH to configure the OS, manage dependencies, deploy templates (`gitlab.rb.j2`, `config.toml.j2`), and restart services. This eliminated manual server configuration steps, ensuring GitLab and Runner hosts can be rebuilt deterministically in minutes.

### Q12: Can you explain the concept of Infrastructure as Code (IaC) and how you implemented it using Terraform in your project?
**Answer**: We structured the Terraform configuration into reusable modules (`vpc`, `security_groups`, `rds`, `rabbitmq`, `compute`) consumed by two environment roots (`staging` and `production`). Each environment defines its state, variables, and tags. Terraform calculates dependency graphs, presents execution plans (`terraform plan`), and executes declarative updates (`terraform apply`) with state locking.

### Q13: What is the purpose of using continuous integration and continuous deployment (CI/CD) pipelines, and how did it help you automate the building, testing, and deployment of your application?
**Answer**: CI/CD pipelines automate the tedious, error-prone manual steps of packaging software, validating tests, scanning code for vulnerabilities, and pushing containers to servers. In this project, any commit to the repository automatically triggers compilation, test execution, security scans, container image publishing, and staging rollout without manual developer intervention.

### Q14: How did you ensure the security of the application throughout the pipeline stages?
**Answer**: Through a defense-in-depth approach across all 7 pipeline stages:
- **Pre-commit / Commit**: Branch protection restricts write access to maintainers.
- **Build / Test**: Clean containerized environments run isolated unit tests.
- **Scan**: Automated static application security testing (`bandit`), secret detection (`gitleaks`), and filesystem CVE scanning (`trivy`).
- **Containerization**: Trivy scans container layers for base OS vulnerabilities.
- **CD / Production**: Manual approval gate requires stakeholder review; cloud credentials remain masked in GitLab secret storage.

### Q15: Can you explain the continuous integration (CI) pipeline you've implemented for each repository?
**Answer**: The CI pipeline consists of 4 stages:
1. **`Build`**: Installs dependencies and compiles Python bytecode to verify syntax and packaging.
2. **`Test`**: Runs unit and integration tests using pytest, measuring code coverage and producing JUnit test reports.
3. **`Scan`**: Executes Bandit (SAST), Gitleaks (secret detection), and Trivy (filesystem CVEs).
4. **`Containerization`**: Builds the hardened Docker image, scans it for vulnerabilities, and pushes it with the commit SHA and latest tags to the GitLab container registry.

### Q16: Can you explain the continuous deployment (CD) pipeline you've implemented for each repository?
**Answer**: The CD pipeline consists of 3 stages:
1. **`Deploy to Staging`**: Deploys the container to the staging ECS service and executes an automated health check probe.
2. **`Approval`**: Pauses pipeline execution behind a manual gate requiring stakeholder authorization before production rollout.
3. **`Deploy to Production`**: Executes a zero-downtime rolling update on the production ECS service, verifies the live health check, and promotes the release tag.

### Known deviations from the brief

[`docs/readme.md`](docs/readme.md) asks for three things this repository does not deliver literally. Disclosed here rather than papered over:

| Brief requirement | What is delivered instead | Impact if split into separate repos |
|---|---|---|
| Infra config "must exist in an independent repository" (`docs/readme.md:130-131`) | `infra/` is a subdirectory of this same GitLab project (single remote `platform.zone01.gr/git/ekaramet/code-keeper.git`; no nested `.git`) | `infra/.gitlab-ci.yml` uses project-root-relative paths — `cd infra/environments/staging`, `artifacts: infra/environments/staging/.terraform`, `rules:changes: infra/**/*` — which resolve only from this repo root and would need rewriting to be standalone |
| CI "triggered on every code push or pull request" (`docs/readme.md:161`) | All four `.gitlab-ci.yml` files gate on `workflow:rules: - if: $CI_COMMIT_BRANCH == "main" / - when: never`, so pipelines run on pushes to `main` only; no merge-request pipeline is created | Feature branches get no CI feedback before merge; `rules:changes:paths` mitigates this for touched paths only |
| "Each application must exist in a single repository" (`docs/readme.md:116`) | `api-gateway`, `inventory-app`, and `billing-app` are three subdirectories of one GitLab project, each with its own `.gitlab-ci.yml` | Per-service pipelines are logically independent but share one project's permissions, registry, and runner pool |

The compensating control is documented in [§3.4](#34-monorepo-path-gating-simulated-service-independence): `rules:changes:paths` scoping keeps each service's pipeline independent inside the monorepo.

---

## 7. Bonus Implementations

- **Infrastructure Security Scanning**: The `Validate` stage of `infra/.gitlab-ci.yml` runs `trivy config --severity HIGH,CRITICAL --exit-code 1 infra/` as a blocking IaC scan of the Terraform code.
- **Automated Verification Framework**: Custom automated verification test suites (`scripts/test_pipelines.sh` and `scripts/verify_security.sh`) that simulate CI/CD pipeline stages, validate YAML/syntax, verify non-root container enforcement, and test security controls.
- **Container Hardening**: All Dockerfiles built on penultimate Alpine Linux (`alpine:3.23`) running with an explicit unprivileged non-root user (`USER appuser`, UID 10001) and native container health checks.
- **OpenAPI 3.0 Specification**: `srcs/api-gateway/openapi.yaml` documents the gateway contract (`openapi: 3.0.3`) for `/health`, `/api/movies`, and `/api/billing`. It is authored and version-controlled as a deliverable artifact; it is not currently served at a runtime `/docs` endpoint.

### 7.1 Considered but not implemented

The following items from the brief's bonus list were evaluated and deliberately **not** wired into the code, so they are not claimed as delivered:

| Item | Status | What exists instead |
|---|---|---|
| `tfsec` IaC scanning | Not integrated | `trivy config --severity HIGH,CRITICAL --exit-code 1 infra/` in the `Validate` stage (`infra/.gitlab-ci.yml`) |
| `Infracost` cost estimation | Not integrated | `terraform plan` artifacts only; no cost comment on merge requests |
| `Terragrunt` multi-environment DRY config | Not integrated | Plain Terraform roots `infra/environments/staging` and `infra/environments/production` consume the same modules; no `terragrunt.hcl` exists |
| Renovate dependency bot | Not integrated | `.github/dependabot.yml` is present but `.github/` does not execute in this GitLab-hosted project, and its `terraform` entry targets a `directory` Dependabot does not support, so it is not an effective control |
