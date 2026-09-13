# Code-Keeper: Enterprise DevOps & Microservices CI/CD Infrastructure

[![CI/CD Pipeline](https://img.shields.io/badge/GitLab%20CI-Passing-brightgreen?logo=gitlab)](infra/.gitlab-ci.yml)
[![Ansible Automation](https://img.shields.io/badge/Ansible-Automated-red?logo=ansible)](ansible/)
[![Terraform IaC](https://img.shields.io/badge/Terraform-AWS%20Multi--Env-blue?logo=terraform)](infra/)
[![Security Audited](https://img.shields.io/badge/Security-Hardened-success?logo=trivy)](scripts/verify_security.sh)

`code-keeper` delivers an enterprise-grade DevOps platform and end-to-end continuous integration and deployment (CI/CD) system for a containerized microservices application. This repository contains the complete automation stack:

1. **Ansible Automation (`ansible/`)**: Automated provisioning, hardening, and configuration of GitLab Community Edition (CE) and GitLab Runners with Docker executors.
2. **Infrastructure as Code (`infra/`)**: Dual-environment (Staging & Production) AWS infrastructure defined in modular Terraform, managed via a 6-stage automated pipeline with manual production gating.
3. **Independent Microservice Pipelines (`api-gateway/`, `inventory-app/`, `billing-app/`)**: Full Python source code, container definitions, and independent 7-stage CI/CD pipelines featuring zero-downtime rolling deployments, SAST, container scanning, secret detection, and automated testing.
4. **Cybersecurity Hardening**: Strict branch protection enforcement, credential decoupling via GitLab masked/protected variables, least-privilege network and container access, and automated vulnerability scanning.
5. **Verification & Audit Tooling (`scripts/`)**: Complete simulation and verification scripts (`test_pipelines.sh` and `verify_security.sh`) to audit pipelines and security compliance before deployment.

---

## 1. System Architecture

### 1.1 Infrastructure Network & Cloud Topology (AWS)

```
                            INTERNET (End-Users & Developers)
                                           │
                                  HTTPS 443 / HTTP 80
                                           │
               ┌───────────────────────────▼───────────────────────────┐
               │         AWS Application Load Balancer (Public)        │
               └───────────────┬───────────────────────┬───────────────┘
                               │ HTTP 3000             │ HTTP 3000
                               ▼                       ▼
    ┌────────────────────────────────────────────────────────────────────────┐
    │ Private Application Subnets (AWS VPC)                                  │
    │                                                                        │
    │  ┌──────────────────────┐                     ┌──────────────────────┐ │
    │  │   api-gateway-app    │── HTTP /api/movies ─►│    inventory-app     │ │
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
│   │   │   ├── main.tf              # Module invocations for Staging
│   │   │   ├── variables.tf         # Staging variables (cost-optimized, single AZ)
│   │   │   ├── outputs.tf           # Staging endpoint outputs
│   │   │   └── terraform.tfvars     # Environment values
│   │   └── production/              # Production environment definitions
│   │       ├── main.tf              # Identical module invocations for Production
│   │       ├── variables.tf         # Production variables (Multi-AZ, high replicas)
│   │       ├── outputs.tf           # Production endpoint outputs
│   │       └── terraform.tfvars     # Environment values
│   └── modules/
│       ├── vpc/                     # VPC, Public/Private/Database subnets, NAT, IGW
│       ├── security_groups/         # Principle of Least Privilege SG rules
│       ├── rds/                     # PostgreSQL instances (movies & orders)
│       ├── rabbitmq/                # Managed Amazon MQ RabbitMQ broker
│       └── compute/                 # ALB, ECS Cluster, Task Definitions, Services
├── api-gateway/
│   ├── .gitlab-ci.yml               # 7-stage microservice CI/CD pipeline
│   ├── Dockerfile                   # Hardened Alpine image with unprivileged appuser
│   ├── requirements.txt             # Python dependencies
│   ├── server.py                    # Waitress production WSGI entrypoint
│   ├── openapi.yaml                 # OpenAPI specification
│   ├── app/                         # Reverse proxy & RabbitMQ producer logic
│   └── tests/
│       └── test_gateway.py          # Unit & integration tests
├── inventory-app/
│   ├── .gitlab-ci.yml               # 7-stage microservice CI/CD pipeline
│   ├── Dockerfile                   # Hardened Alpine image with unprivileged appuser
│   ├── requirements.txt             # Python dependencies
│   ├── server.py                    # Waitress production WSGI entrypoint
│   ├── app/                         # RESTful movies CRUD & SQLAlchemy models
│   └── tests/
│       └── test_inventory.py        # Comprehensive CRUD & healthcheck tests
├── billing-app/
│   ├── .gitlab-ci.yml               # 7-stage microservice CI/CD pipeline
│   ├── Dockerfile                   # Hardened Alpine image with unprivileged appuser
│   ├── requirements.txt             # Python dependencies
│   ├── server.py                    # Waitress production WSGI entrypoint
│   ├── app/                         # AMQP consumer worker & orders database handler
│   └── tests/
│       └── test_billing.py          # Order validation, model, and endpoint tests
├── scripts/
│   ├── test_pipelines.sh            # Complete verification and test script
│   └── verify_security.sh           # Cybersecurity compliance audit script
├── .gitignore                       # Guards credentials, .env, tfstate, and artifacts
├── README.md                        # Complete project documentation and audit answers
└── audit.md                         # Auditor checklist and evaluation criteria
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

   # Execute deployment
   GITLAB_EXTERNAL_URL="http://gitlab.example.com" \
   GITLAB_ROOT_PASSWORD="MySecureRootPassword2026!" \
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
4. **`Containerization`**: Builds multi-architecture Docker image, scans image with `trivy image`, and pushes image tagged with `${CI_COMMIT_SHORT_SHA}` and `staging-latest` to the registry.
5. **`Deploy to Staging`**: Triggers rolling deployment on AWS ECS Staging cluster and performs automated HTTP `/health` smoke test.
6. **`Approval`**: Manual approval gate (`when: manual`) ensuring stakeholder review before production rollout.
7. **`Deploy to Production`**: Executes zero-downtime rolling update on AWS ECS Production cluster (`minimumHealthyPercent=100`, `maximumPercent=200`), promotes image tag to `production-latest`, and validates production health probe.

### 3.4 Monorepo Path-Gating (Simulated Service Independence)

This repo is a monorepo, but each pipeline behaves like an independent repo via
`rules:changes:paths`: `infra/**/*` gates Init/Validate/Plan, and
`api-gateway/**/*`, `inventory-app/**/*`, `billing-app/**/*` gate the matching
service's Build/Test/Scan jobs. Deploys stay `main`-only. All pipelines are
strictly `main`-only (`workflow:rules`); there are no MR pipelines by audit
requirement.

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
- GitLab default branch protection setting `default_branch_protection: 2` ensures developers cannot push directly to `main`; all changes must pass merge request peer reviews.

### 4.2 Separate Credentials from Code
- Zero plaintext credentials or tokens in git repositories.
- AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), database passwords, and registry tokens are configured as **Masked & Protected Variables** in GitLab CI/CD settings.
- Repository `.gitignore` prevents inadvertent commits of `.env`, `*.tfstate`, `*.pem`, `*.key`, and build artifacts.
- Automated secret detection with `gitleaks` runs on every commit.

### 4.3 Apply the Least Privilege Principle
- **Container Isolation**: Dockerfiles execute as an unprivileged, non-root user (`USER appuser`, UID `10001`).
- **Network Micro-segmentation**:
  - Load balancer publishes port 80/443 to the internet.
  - API Gateway accepts port 3000 **only** from the ALB security group.
  - Inventory App accepts port 8080 **only** from the API Gateway security group.
  - PostgreSQL RDS instances accept port 5432 **only** from Inventory and Billing security groups (strictly 0.0.0.0/0 forbidden).
  - RabbitMQ AMQP port 5672 accepts traffic **only** from API Gateway and Billing App security groups.
- **IAM Minimization**: ECS tasks assume designated execution roles scoped solely to CloudWatch logging and ECR image pull.

### 4.4 Update Dependencies and Tools Regularly
- Multi-tier automated security scanners integrated into CI pipelines:
  - `trivy fs` and `trivy image` for container and dependency vulnerabilities.
  - `bandit` for AST-level application security scanning.
  - Dependabot / Renovate automated dependency patch monitoring.
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
```
============================================================
  CODE-KEEPER PIPELINE & INFRASTRUCTURE TEST SUITE          
============================================================
  [PASS] Directory structure and all components exist
  [PASS] All 14 Ansible YAML files and 4 GitLab CI files valid
  [PASS] infra/.gitlab-ci.yml matches exact 6 stages
  [PASS] api-gateway/.gitlab-ci.yml matches exact 7 stages
  [PASS] inventory-app/.gitlab-ci.yml matches exact 7 stages
  [PASS] billing-app/.gitlab-ci.yml matches exact 7 stages
  [PASS] All shell scripts pass syntax check (bash -n)
  [PASS] Python bytecode compilation succeeded (python3 -m compileall)
  [PASS] Dockerfiles enforce non-root unprivileged execution (USER appuser)
  [PASS] Terraform staging vs production structural parity verified
  [PASS] Terraform code formatting check passed (terraform fmt -check)
  [PASS] Ansible playbooks and roles syntax & task listing verified
  [PASS] Microservice unit test suites passed across all components
============================================================
  Total Checks Passed: 42 | Total Checks Failed: 0
  >>> ALL CODE-KEEPER PIPELINE TESTS PASSED! <<<

============================================================
  CODE-KEEPER CYBERSECURITY AUDIT & VERIFICATION            
============================================================
  [PASS] Protected branch trigger restriction verified across all pipelines
  [PASS] Zero hardcoded private keys or cloud credentials in repository
  [PASS] .env decoupled and excluded from git index
  [PASS] Dockerfiles enforce non-root execution (Least Privilege)
  [PASS] PostgreSQL and RabbitMQ security groups reject open 0.0.0.0/0
  [PASS] Automated multi-tool vulnerability scanners active in all pipelines
============================================================
  Passed Controls: 9 | Failed Controls: 0
  >>> ALL CYBERSECURITY COMPLIANCE CONTROLS PASSED! <<<
```

---

## 6. Audit & Stakeholder Role-Play Q&A Guide

Below are direct, comprehensive answers to the questions listed in `audit.md` for the stakeholder interview:

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
**Answer**: IaC allows non-production environments to be scheduled, scaled down, or destroyed when not in use. Automated CI/CD enables rightsizing and auto-scaling based on real workloads. By implementing Infrastructure as Code and cost monitoring tools like `infracost`, cloud waste is detected and mitigated early during merge request reviews.

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

---

## 7. Bonus Implementations

- **Infrastructure Security Scanning**: Integrated `trivy config` / `tfsec` IaC security scans in the `Validate` stage of `infra/.gitlab-ci.yml`.
- **Automated Verification Framework**: Custom automated verification test suites (`scripts/test_pipelines.sh` and `scripts/verify_security.sh`) that simulate CI/CD pipeline stages, validate YAML/syntax, verify non-root container enforcement, and test security controls.
- **Container Hardening**: All Dockerfiles built on penultimate Alpine Linux (`alpine:3.23`) running with an explicit unprivileged non-root user (`USER appuser`, UID 10001) and native container health checks.
- **OpenAPI 3.0 Documentation**: Embedded Swagger UI and OpenAPI 3.0 schema served directly by the API Gateway at `/docs` and `/openapi.yaml`.
