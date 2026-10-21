# Changelog

History of the changes made in this project, oldest first. Each entry says what changed, why,
and when. New entries are appended at the bottom.

## 2026-10-16 18:49 EEST: Add submission readiness review

**What**
- `docs/READINESS_REVIEW.md`: created. Verdict (not ready), the live systems the audit needs that do
  not exist yet, the pipeline bugs, the infra bugs, the repo-layout requirements that fail, the docs
  that contradict the code, what is already good, a suggested fix order and the review method.

**Why**
The user asked for the findings and suggestions from the readiness review as a Markdown file in
`docs/`. The name avoids "report" so it doesn't get mixed up with `reports/audit_report.json`.

**Verified**
Checked the file for em and en dashes with grep; none found. No other files were changed.

## 2026-10-19 19:04 EEST: Fix the two pipeline-creation blockers from the readiness review

**What**
- `srcs/api-gateway/.gitlab-ci.yml`, `srcs/inventory-app/.gitlab-ci.yml`, `srcs/billing-app/.gitlab-ci.yml`:
  added the missing `before_script:` key in `test:unit`, `scan:sast_bandit` and `scan:dependencies`,
  so the `echo`, `cd "${APP_DIR}"` and `pwd` lines leave `rules:` and run before the job script
  again (9 jobs).
- `infra/.gitlab-ci.yml`: gave `infra:approval:production` and `infra:apply:production` the same
  `changes: infra/**/*` filter as `infra:plan:production`, with a short comment on the apply job.

**Why**
Items 1 and 2 of `docs/READINESS_REVIEW.md`: string entries in `rules:` and a `needs:` on a job
that rules exclude both make GitLab refuse to create a pipeline. For item 2 the `changes:` filter
was chosen over `needs: optional: true`, because with `optional` the apply job would still run on
every push to `main` and fail on the missing `production.tfplan`.

**Verified**
A rules and needs simulation of the merged config over 9 pipeline scenarios (push to main or a
branch, merge request, schedule) found 27 non-hash rules and 2 unresolved needs before the change
and none after. A strict YAML load found no duplicate keys. Validation against GitLab's `ci.json`
schema showed the same error count before and after the change; those errors come from a separate
problem (script lines containing `: ` that YAML reads as mappings), which is not fixed yet.

## 2026-10-19 19:33 EEST: Quote the 71 script lines GitLab read as mappings

**What**
- `infra/.gitlab-ci.yml` (13 lines), `srcs/api-gateway/.gitlab-ci.yml` (20),
  `srcs/inventory-app/.gitlab-ci.yml` (19), `srcs/billing-app/.gitlab-ci.yml` (19): wrapped every
  `script:` entry that contains `: ` in single quotes, doubling any inner single quote, the same way
  `srcs/api-gateway/.gitlab-ci.yml:47` already did.
- `docs/READINESS_REVIEW.md`: added item 10 ("Script lines that YAML reads as mappings") under a new
  "Found after the review" heading, pointed the blocker sentence and the suggested order at it, and
  added GitLab's `ci.json` schema to the sources.

**Why**
Without quotes, YAML turns a line like `- echo " Commit: ${CI_COMMIT_SHA}"` into a one-key mapping,
and GitLab rejects the whole configuration because script entries must be strings. This was a third
blocker next to items 1 and 2, missed in the original review.

**Verified**
GitLab 19.5.0's CI Lint API (local instance, see the next entry) returned 32 errors for the HEAD
config (9 `rules should be an array containing hashes`, 23 `script config should be a string`) and
`valid=true` with 0 errors for the working tree. The `ci.json` schema check reports 0 errors in all
five files, every job's script list carries exactly the same commands as before, the rules and
needs simulation still passes, and `scripts/test_pipelines.sh` reports 91 passed, 0 failed.

## 2026-10-19 19:33 EEST: Local GitLab and runner for live pipeline tests

**What**
- Docker images pulled: `gitlab/gitlab-ce:19.5.0-ce.0` (6.08 GB) and `gitlab/gitlab-runner:alpine-v19.5.0`.
- Docker network `ck-gitlab-net` and volumes `ck-gitlab-config`, `ck-gitlab-logs`, `ck-gitlab-data`,
  `ck-runner-config` created.
- Containers started: `ck-gitlab` (GitLab CE, bound to `127.0.0.1:8929` only, service ping off) and
  `ck-gitlab-runner` (Docker executor, 4 concurrent jobs, jobs join `ck-gitlab-net`, host Docker
  socket mounted).
- Inside GitLab: an API token for `root` (`api`, `create_runner`, `write_repository`, expires
  2026-10-26), the private project `root/code-keeper`, and instance runner `ck-local-docker`
  registered with a `glrt-` authentication token.
- `~/.config/code-keeper-local-gitlab/` (mode 700, outside the repo): `root-password`, `api-token`,
  `runner-token`, `gitlab.env`, each mode 600. Helper scripts live in `/tmp/ck-sim/`.

**Why**
The user asked for a live test of the pipeline fixes. No GitLab instance exists, and a local one
needs no outside credentials. This is a test bed only; it is not the Ansible-deployed GitLab the
audit asks for.

**Verified**
`/api/v4/version` reports 19.5.0, and the runner shows `status=online` in `/api/v4/runners/all`.

## 2026-10-20 00:35 EEST: First live pipeline run on the local GitLab

**What**
- No repository files changed. The local runner pulled `python:3.11-alpine`, `hashicorp/terraform:1.6`
  and `gitlab-runner-helper:x86_64-v19.5.0` while running the pipelines for commit `779d895`
  (pushed by the user to the local GitLab as `main` and `fix/pipelines`).

**Why**
Live test of the CI fixes from the previous entries, as the user asked.

**Verified**
- GitLab's dry run accepted both refs (`valid=true`, 0 errors): 50 jobs on `main`, 28 on
  `fix/pipelines`, so items 1, 2 and 10 of `docs/READINESS_REVIEW.md` are fixed on a real GitLab.
- Both real pipelines were created and failed after about 90 seconds. `infra:init:staging` and
  `infra:init:production` stopped on `TF_STATE_BUCKET CI protected variable is unset` (expected
  without AWS). `pipeline:lint` failed on `apk add --no-cache pyyaml` with `pyyaml (no such
  package)`, a new bug. Every other job (47 on `main`, 25 on the branch) was skipped because the
  Init and Validate stages failed, so no test or scan job ran yet.

## 2026-10-20 00:52 EEST: Fix pipeline:lint and install the CI test and scan tools

**What**
- `.gitlab-ci.yml`: `pipeline:lint` now runs `pip install --no-cache-dir pyyaml==6.0.3` instead of
  `apk add --no-cache pyyaml`.
- `srcs/api-gateway/.gitlab-ci.yml`, `srcs/inventory-app/.gitlab-ci.yml`, `srcs/billing-app/.gitlab-ci.yml`:
  added one `pip install` line to each of three jobs per service: `test:unit` installs
  `requirements.txt`, `pytest==9.1.1` and `pytest-cov==7.1.0`; `scan:sast_bandit` installs
  `bandit==1.9.4`; `scan:dependencies` installs `pip-audit==2.10.1`.

**Why**
The first live run showed `pipeline:lint` failing with `pyyaml (no such package)`: Alpine names it
`py3-yaml`, and even that would install for Alpine's Python, not the `/usr/local` Python of
`python:3.11-alpine`. Item 3 of `docs/READINESS_REVIEW.md`: pytest, bandit and pip-audit were never
installed in the job image. The tool versions are pinned to the current PyPI releases so runs are
repeatable; the test set matches what `scripts/test_pipelines.sh` installs locally.

**Verified**
Each changed job was run locally in `python:3.11-alpine` on a copy of the working tree, using the
job's own `before_script` and `script`: all 10 exited 0. pytest passed 7 (api-gateway), 20
(inventory-app) and 32 (billing-app) tests; bandit found no issues; pip-audit found no advisories
for inventory-app and billing-app, and reported PYSEC-2026-2275 in `requests 2.32.5` (fixed in
2.33.0) for api-gateway, which the advisory-only job does not gate on. GitLab 19.5.0's CI Lint
API still returns `valid=true` with 0 errors, and the `ci.json` schema check reports 0 errors.

## 2026-10-20 01:07 EEST: Second live pipeline run: all build, test and scan jobs green

**What**
- No repository files changed. The local runner pulled `aquasec/trivy:latest`,
  `sonarsource/sonar-scanner-cli:latest` and `zricethezav/gitleaks:latest` while running pipeline 3
  for commit `2b54962` on `fix/pipelines` (pushed by the user to the local GitLab).

**Why**
Live test of the `pipeline:lint` and item 3 fixes from the previous entry.

**Verified**
Pipeline 3 passed with 22 of 22 jobs, and no infra jobs were included because the commit did not
touch `infra/`. The logs show the jobs did real work: pytest passed 7, 20 and 32 tests (coverage
31%, 11%, 56%) and uploaded JUnit reports; bandit reported no issues; gitleaks reported no leaks;
Trivy downloaded its database and found no HIGH or CRITICAL issue; pip-audit reported
PYSEC-2026-2275 in `requests 2.32.5` for api-gateway (advisory only); the SonarQube jobs skipped
the upload because no server is configured.

## 2026-10-20 01:16 EEST: Fix review items 4-9 (pipeline) and record item 11

**What**
- `infra/.gitlab-ci.yml`:
  - `infra:validate:security` runs `trivy --version` instead of `terraform --version` (item 4).
  - `infra:apply:staging` only runs on `main` when `infra/**` changed, like `infra:plan:staging` (item 5).
  - `TF_VAR_image_repository_prefix` is now `docker.io/${DOCKERHUB_REPO}` with a job-level default
    `DOCKERHUB_REPO: "grafido"`, and `AWS_DEFAULT_REGION` is a plain `"us-east-1"` (item 7).
- `srcs/api-gateway/.gitlab-ci.yml`, `srcs/inventory-app/.gitlab-ci.yml`, `srcs/billing-app/.gitlab-ci.yml`:
  - `containerize:docker` writes the Kaniko `config.json` with the working `printf` already used by
    `promote:image` (item 6).
  - Image names are `docker.io/${DOCKERHUB_REPO}/<service>:<tag>`, with `DOCKERHUB_REPO: "grafido"`
    as a job-level default, and `AWS_DEFAULT_REGION` is a plain `"us-east-1"` (item 7).
  - The unreachable curl health checks against `*.code-keeper.internal` are gone, in both the
    staging and the production deploy jobs (item 8). api-gateway now looks up the ALB DNS name
    (`ALB_NAME`) with `aws elbv2 describe-load-balancers` and curls its `/health`; inventory-app and
    billing-app rely on `aws ecs wait services-stable`, with a comment saying why.
  - `deploy:production` rolls the service onto the immutable commit tag (`TARGET_IMAGE:
    "${IMAGE_TAG}"`) instead of `production-latest`, and the comment above `promote:image` explains
    why (item 9).
- `infra/modules/compute/main.tf`: added an ECS `healthCheck` to the inventory-app and billing-app
  container definitions, repeating each Dockerfile `HEALTHCHECK`, so `services-stable` only passes
  once new tasks answer `/health` (item 8).
- `docs/READINESS_REVIEW.md`: added item 11 (the Trivy IaC gate fails on 8 CRITICAL `AWS-0036`
  plaintext-password findings) and pointed the suggested order at items 1-11.
- Local GitLab only: scratch project `root/ci-scratch` (id 2) with a one-job variable probe and two
  project variables (`DOCKERHUB_REPO`, `AWS_DEFAULT_REGION`).

**Why**
The user asked for items 4-9. For item 8 the gateway is checked through its public ALB, while
inventory-app and billing-app are only reachable inside the VPC, so ECS health checks replace a
probe the runner could never make. `docker.io/<namespace>/<service>` keeps Docker Hub's two-part
repository names and still passes the Terraform `image_repository_prefix` validation (one slash).
`AWS-0036` was not added to `.trivyignore`; the real fix is Secrets Manager or SSM `secrets`.

**Verified**
- GitLab 19.5.0 CI Lint: `valid=true`, 0 errors. `ci.json` schema: 0 errors in all five files. The
  rules and needs simulation passes all 9 scenarios. `scripts/test_pipelines.sh`: 91 passed,
  0 failed. `pipeline:lint` run locally: all checks OK.
- The new Kaniko `printf` line, run in `python:3.11-alpine`, writes valid JSON.
- Probe on the local GitLab: the old `${DOCKERHUB_REPO:-grafido}/...` value expanded to
  `//api-gateway:<sha>`, even with `DOCKERHUB_REPO` set as a project variable. The new value gave
  `docker.io/grafido/api-gateway:<sha>`, and project variables overrode both the namespace and the
  region.
- `terraform fmt -check` (1.6) passes on the compute module, and `terraform console` evaluates the
  health check command to exactly the Dockerfile probe.
- `trivy config` 0.76.0 fails on HEAD and on the working tree alike with 8 CRITICAL `AWS-0036`
  findings, so item 11 predates these changes.
- Not run: Kaniko push, deploy and Terraform jobs; they need Docker Hub and AWS credentials.

## 2026-10-20 01:29 EEST: Secrets Manager, AMQPS port, KMS key policy, needs: chains, requests bump

**What**
- `infra/modules/compute/main.tf`: the three passwords (`INVENTORY_DB_PASSWORD`, `BILLING_DB_PASSWORD`,
  `RABBITMQ_PASSWORD`) moved from `environment` to ECS `secrets`. Added
  `aws_secretsmanager_secret.task` and `aws_secretsmanager_secret_version.task` (one per password,
  `name_prefix` per environment), an inline execution-role policy allowing
  `secretsmanager:GetSecretValue` on exactly those secrets, and `depends_on` on the three task
  definitions so no task starts before its secret has a value (review item 11).
- `infra/modules/security_groups/main.tf`: `amqp_port` is 5671 instead of 5672, with the rule
  descriptions updated, so the gateway and billing app can reach Amazon MQ over AMQPS.
- `infra/modules/rds/main.tf`: the Performance Insights KMS key policy gains an
  `EnableAccountAdministration` statement (account root, `kms:*`), using new
  `aws_caller_identity` and `aws_partition` data sources, so KMS's lockout safety check no longer
  refuses to create the key.
- `srcs/*/.gitlab-ci.yml`: every app job now has `needs:`. build starts at once (`needs: []`); test
  needs build; the four change-filtered scans need test; `scan:dependencies` needs test as an
  optional need; containerize needs test and all scans (optional where change-filtered,
  `artifacts: false`); `deploy:staging` also needs `containerize:image_scan` and, as an optional
  need, `infra:apply:staging`; `approval:production` needs `deploy:staging`.
- `infra/.gitlab-ci.yml`: `infra:approval:production` needs `infra:apply:staging`.
- `srcs/api-gateway/requirements.txt`: `requests` 2.32.5 to 2.34.2.

**Why**
The user asked for all four follow-ups. App jobs no longer wait for the infra stages that precede
them in `stages:`, so a failing infra job stops only the infra chain. Two gaps closed on the way:
`deploy:staging` used to start in parallel with the image scan, and containerize used to download
test reports into the Kaniko build context. Secrets Manager was chosen over SSM because the review
named it; `requests` 2.34.2 is the current release and clears PYSEC-2026-2275.

**Verified**
- `terraform validate` (1.6, AWS provider 5.100.0 from the lock file) passes for staging and
  production; `terraform fmt -check -recursive` passes.
- `trivy config` 0.76.0 with `infra/.trivyignore` now exits 0; before this change it failed with
  8 CRITICAL `AWS-0036`.
- GitLab 19.5.0 CI Lint: `valid=true`, 0 errors. The rules and needs simulation passes all 9
  scenarios, and no `needs:` points at a later stage. `pipeline:lint` run locally resolves all
  72 `needs:`. `scripts/test_pipelines.sh`: 91 passed, 0 failed.
- api-gateway `test:unit` (7 passed) and `scan:dependencies` ("No known vulnerabilities found")
  run locally in `python:3.11-alpine` with `requests` 2.34.2.
- Not run: `terraform plan`/`apply` (needs AWS).

## 2026-10-20 18:59 EEST: AWS setup guide

**What**
- `AWS_SETUP.md`: new file in the project root. Step-by-step AWS setup for the current Terraform and
  CI: cost estimate, account basics, CLI profile, pre-flight checks (RDS and RabbitMQ engine
  versions, Fargate quota), S3 state bucket and DynamoDB lock table, CI IAM user, Docker Hub
  repositories and token, password generation, the GitLab CI/CD variables table, the first pipeline
  run order, checks, teardown, and the open code changes before the first apply.

**Why**
The user asked for the AWS step-by-step guidelines as a Markdown file. It goes in the project root
because the `docs/` folder is read-only for Claude.

## 2026-10-20 19:41 EEST: Cheapest AWS sizes, current engine versions, Docker Hub pull login, production waits for infra

**What**
- `infra/modules/rds/main.tf`: `engine_version` `15.4` → `15` for both databases (15.4 is no longer
  offered; RDS now picks the current 15.x release).
- `infra/modules/rabbitmq/main.tf`, `variables.tf`: RabbitMQ `3.11.20` → `4.2`; default broker type
  `mq.t3.micro` → `mq.m7g.medium` (mq.t3.micro is no longer offered for RabbitMQ).
- `infra/environments/staging/main.tf`: broker `mq.m7g.medium`.
- `infra/environments/production/main.tf`: sized like staging (db.t3.micro, 20 GB, single-AZ,
  7-day backups; single-instance mq.m7g.medium; 2 tasks per service at the default 256/512), with
  a comment listing the previous high-availability sizes.
- `infra/modules/compute/main.tf`, `variables.tf`, `infra/environments/*/main.tf`, `variables.tf`: a
  fourth Secrets Manager secret `dockerhub-credentials` and `repositoryCredentials` on all three
  containers, so ECS pulls the images as the Docker Hub user. New variables `dockerhub_username`
  and `dockerhub_token`.
- `infra/.gitlab-ci.yml`: both plan jobs set `TF_VAR_dockerhub_username`/`TF_VAR_dockerhub_token`
  from `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` and check they are set.
- `infra/modules/security_groups/main.tf`: the VPC resolver rule is now `<address>/32`; the bare
  address made every plan fail.
- `.gitlab-ci.yml`: "Apply to Production" now comes before "Deploy to Production".
- `srcs/*/.gitlab-ci.yml`: each `deploy:production` has an optional need on
  `infra:apply:production`.

**Why**
The account is on the AWS Free plan ($73.06 credits left), and the user asked for the cheapest
option and for all AWS resources to be removed after testing. The step 3 checks showed that the
pinned RDS and RabbitMQ versions and the staging broker type are no longer offered. The pull login
avoids Docker Hub's per-IP limit on anonymous pulls through the NAT IP. The earlier `AWS_SETUP.md`
entry is outdated in one detail: the user moved the file to `docs/AWS_SETUP.md`, which is read-only
for Claude, so its update was handed to the user as a patch.

**Verified**
- `terraform fmt -check` OK; `terraform validate` OK for staging and production.
- `terraform plan` against the AWS account with a local backend and placeholder secrets: 62 to add
  for each environment, after the CIDR fix (before it, both plans failed). Nothing was created.
- `trivy config --severity HIGH,CRITICAL` on `infra/`: exit 0.
- GitLab 19.5 CI Lint on the merged config: valid. Rules simulator: 9 of 9 scenarios OK.
  `pipeline:lint` run locally: all 75 `needs:` resolve. `scripts/test_pipelines.sh` on a copy: 91
  passed, 0 failed.

## 2026-10-20 20:13 EEST: AWS state backend created, state variables set, Results.md

**What**
- AWS (account REDACTED_AWS_ACCOUNT_ID, us-east-1): created S3 bucket `code-keeper-tfstate-REDACTED_AWS_ACCOUNT_ID`
  (versioning on, AES256, public access blocked, tag `Project=code-keeper`) and DynamoDB table
  `code-keeper-tf-locks` (on-demand, key `LockID`), as in step 4 of `docs/AWS_SETUP.md`.
- Local test GitLab, project `root/code-keeper`: added protected CI variables `TF_STATE_BUCKET`,
  `TF_STATE_REGION` and `TF_STATE_LOCK_TABLE`. Cancelled pipeline 8 by mistake (it was the only
  pipeline testing the code commit) and retried it.
- `Results.md`: filled the empty file with the results of the remaining setup steps, the steps left
  for the user with exact commands, and what the project still lacks for the audit.

**Why**
The user asked to run the remaining AWS setup steps once the pipeline finished and to report what
is missing in `Results.md`. Creating the CI access key and storing the passwords and keys in GitLab
was blocked by Claude Code's safety check, so those steps are written up for the user instead.

**Verified**
- Pipeline 8 (`0cd87d1`): 22 passed; both `infra:init` jobs failed only on the unset (protected)
  state variable, as expected on a branch.
- `terraform init` with the real S3 backend and `terraform plan` with locking, both environments:
  62 to add each, lock acquired and released. Bucket and lock table empty afterwards; credits still
  $73.06.

## 2026-10-20 23:20 EEST: Docker Hub help in Results.md, broken DOCKERHUB_REPO found

**What**
- `Results.md`: rewrote "1. Docker Hub". It now covers:
  - which account to use: your own free account, or `grafido`, the existing account that holds the
    project's images
  - how to find the username, and how to generate a Read & Write token at app.docker.com
  - one snippet that asks for the username, token and namespace, checks the login with Docker Hub,
    and only then replaces `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` and `DOCKERHUB_REPO`
  - a delete command for the broken variable
- The summary and the "Updated" line now match.

**Why**
The user does not know the Docker Hub username or token. A token can't be recovered, only
generated again. The local GitLab has `DOCKERHUB_REPO` set to the literal text `<your-namespace>`,
from the old placeholder snippet. That would turn every image name into
`docker.io/<your-namespace>/...`, so the new snippet prompts for the value instead. Deleting the
variable myself was blocked by the safety check, so it is left to the user.

**Verified**
- `bash -n` on all 5 snippets in `Results.md`: syntax OK. They were not run.
- The login check returns 401 for wrong credentials and 200 for anonymous requests, so it only
  passes with real credentials.

## 2026-10-21 00:38 EEST: Docker Hub snippet in Results.md explains a rejected login

**What**
- `Results.md`, section "1. Docker Hub":
  - the snippet now prints how many characters of token it received, and warns when the input
    does not start with `dckr_pat_`
  - on failure it prints Docker Hub's reason (for example "incorrect username or password")
  - a note on pasting into the hidden prompt: Ctrl+Shift+V or right-click, not Ctrl+V
- The "Updated" line was refreshed.

**Why**
The user's first run said "HTTP 401", and nothing was stored. The check itself works: tested with
dummy credentials against httpbin and Docker Hub. So the token that reached the prompt was wrong,
most likely an empty paste or the password. The old message could not tell those apart.

**Verified**
- The check part, run with an empty, a short and a wrong `dckr_pat_` dummy token, prints the
  length, the warning where expected, and Docker Hub's 401 reason. It stores nothing.
- `bash -n` on all snippets in `Results.md`: syntax OK.

## 2026-10-21 00:49 EEST: CI secrets checked, commit step added before the merge

**What**
- `Results.md`, section "4. First deploy": a `git add CHANGELOG.md` and `git commit` step now
  comes before `git switch main`. There is also a note that `Results.md` stays uncommitted.
  The "Updated" line was refreshed.

**Why**
`CHANGELOG.md` differs between `main` and `aws/cheapest-setup` and has uncommitted changes here,
so `git switch main` would refuse. `Results.md` is a working to-do list, not part of the
submission.

**Verified**
- Local GitLab has all 11 variables with the expected flags. Values were checked by length only:
  - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and the 3 `TF_VAR_*` passwords are protected and
    masked
  - `DOCKERHUB_TOKEN` is protected and masked
  - `DOCKERHUB_USERNAME` and `DOCKERHUB_REPO` are `sntentop`
- IAM user `code-keeper-ci` exists with `AdministratorAccess` and one active key.
- The password file is mode 600 and has 3 entries.
- Docker Hub `sntentop` has 3 public repositories.
- Found an untracked, not ignored `env.example` in the repo root that holds the Docker Hub token.
  The user was told to revoke that token and delete the file.

## 2026-10-21 01:14 EEST: Every Terraform job runs terraform init itself

**What**
- `infra/.gitlab-ci.yml`:
  - `infra:validate:syntax` runs `terraform init -backend=false` in each environment before
    `terraform validate`.
  - `infra:plan:staging`, `infra:plan:production`, `infra:apply:staging` and
    `infra:apply:production` run the same `terraform init` with the S3 backend as the Init jobs
    before they plan or apply.
  - A comment above the shared `cache:` explains why the cache cannot be relied on.

**Why**
Pipeline 10 (`main`, `a8691d8`) was the first in which `infra:init` passed. Its
`infra:validate:syntax` then failed with "Module not installed" for staging. Both Init jobs save
to the same cache key, and each archive holds only its own environment's `.terraform`, so the
production job, which finished last, replaced staging's. The plan and apply jobs never ran
`terraform init` either, although the Init job's comment said they did. They would have failed
the same way. With validate failed, nothing in pipeline 10 reached AWS, and its production
approvals can never open.

**Verified**
- GitLab 19.5.0 CI Lint on the merged config: valid, 0 errors and 0 warnings. The rules
  simulator passes all scenarios. `scripts/test_pipelines.sh` on a copy: all tests passed.
- The new job scripts, run in `hashicorp/terraform:1.6` in fresh checkouts with no
  `.terraform`, against the real S3 backend, with placeholder secrets:
  - validate passes for both environments
  - plan gives 62 to add per environment
  - a second fresh checkout reads the restored plan after `terraform init`, as an apply job
    would, using `terraform show` instead of `apply`
- The state bucket and lock table were empty afterwards. Nothing was applied.

## 2026-10-21 01:56 EEST: RDS backups set to 1 day for the AWS Free plan

**What**
- `infra/environments/staging/main.tf` and `infra/environments/production/main.tf`:
  `backup_retention_period` changed from 7 to 1, with a comment above the `rds` module saying why.
- `infra/modules/rds/variables.tf`: the `backup_retention_period` default changed from 7 to 1,
  and the description now gives the Free plan limit.

**Why**
Pipeline 11 (`7a9611c`) was the first real apply. `infra:apply:staging` created 56 of the 62
staging resources, then both RDS instances failed with "FreeTierRestrictionError: The specified
backup retention period exceeds the maximum available to free tier customers". AWS does not
document the limit, so it was probed with CreateDBInstance calls that name a subnet group that
does not exist. The Free plan check runs first, so nothing can be created: 7 and 2 were refused,
and 1 and 0 passed. 1 keeps automated backups on. Staging stays partly up, and billing, until the
next apply completes it or it is destroyed.

**Verified**
- `terraform fmt -check -recursive` passes. The first version put the comment inside the
  module block, which broke the `=` alignment and would have failed `infra:validate:syntax`, so
  the comment was moved above the block.
- `terraform validate` passes for both environments.
- `trivy config --severity HIGH,CRITICAL` exits 0.
- `describe-orderable-db-instance-options`: db.t3.micro on PostgreSQL 15 supports storage
  encryption and Performance Insights.
- Plan against the real staging state, with placeholder secrets: creates the 2 RDS instances and
  the inventory and billing task definitions and services, changes nothing else, and replaces
  only the 4 secret versions, because the placeholders differ from the real values.

## 2026-10-21 09:35 EEST: Deploy jobs install tar, promote jobs use a crane image that exists

**What**
- `srcs/{api-gateway,inventory-app,billing-app}/.gitlab-ci.yml`:
  - `deploy:staging` and `deploy:production` install `tar` and `gzip` with `jq` (6 jobs).
  - `promote:image` uses `gcr.io/go-containerregistry/crane:debug`, pinned by digest, instead of
    `crane:0.20.2` (3 jobs).

**Why**
- In pipeline 12 (`7d77352`), all three `deploy:staging` jobs failed with "tar: command not
  found". `amazon/aws-cli:latest` has neither `tar` nor `gzip`, and the crane download is a
  `.tar.gz`. Their production approvals were skipped as a result.
- `promote:image` has never run. `crane:0.20.2` does not exist ("not found"), and the published
  plain tags (`v0.20.3` to `v0.22.1`) have no shell, which GitLab needs. Only the moving `debug`
  tag has one, so it is pinned by digest.
- Not changed: `terraform.tfvars` sets `release_tag` to `staging-latest` / `production-latest`,
  and tfvars take priority over the CI's `TF_VAR_release_tag`. Terraform therefore seeds task
  definitions with tags that do not exist yet, and staging runs 0 of 2 tasks per service until
  `deploy:staging` registers the commit tag. That is how the design works, so it was left
  alone.

**Verified**
- The fixed install line in `amazon/aws-cli:latest` installs `tar` and `gzip`, then crane 0.20.2.
  The same container's read-only steps against real staging work: describing the task
  definition and preparing the patched one, with `repositoryCredentials` kept. Nothing was
  registered or updated.
- The pinned crane `debug` image has `sh`, `printf`, `mkdir` and `crane`, and resolves
  `docker.io/sntentop/api-gateway:7d773527`.
- GitLab CI Lint on the merged config: valid, 0 errors. Rules simulator: 9 of 9.
  `scripts/test_pipelines.sh` on a copy: all passed.

## 2026-10-21 11:04 EEST: Both environments deployed; Results.md brought up to date

**What**
- `Results.md`: rewritten for the current state:
  - what is live in staging and production, and the end-to-end check results
  - pipelines 10 to 14, with the cause and fix of each failure
  - the setup that is done, and next steps (testing, teardown, redeploying before the audit)
  - what the audit still needs, and the smaller points, including the Free plan limits that
    `docs/AWS_SETUP.md` should mention

**Why**
Pipeline 14 (`5d9f578`, started from the API so it runs every job) passed every job. The user
had upgraded the AWS account to the paid plan after pipeline 12's production apply failed with
`InstanceQuotaExceeded`. The Free plan allows 2 RDS instances, and staging used both. The
pipeline was started from the API because an app-only push has no infra jobs. On the user's
request, Claude started `infra:approval:production` and the three app approvals through the
GitLab API.

**Verified**
- Both environments: `/health` returns `{"status":"healthy"}`, and all 6 ECS services run 2 of 2
  tasks.
- Movie create, read and delete through each load balancer: `HTTP 200`. The test movies were
  deleted.
- `POST /api/billing`: each environment's billing worker logged the order as recorded, over AMQPS
  on port 5671.
- AWS credits: $92.02, paid plan.

## 2026-10-21 13:46 EEST: Ansible GitLab fixed, four standalone repositories, README and docs drafts

**What**
- Ansible, GitLab role (`ansible/roles/gitlab/`):
  - `gitlab_version` pinned to `19.5.0-ce.0`.
  - `tasks/cicd.yml`: the instance settings go through `PUT /application/settings`, with
    `default_branch_protection_defaults` as `[{access_level: N}]` lists, checked after. Includes
    `shared_runners_text`, which GitLab 19.5 requires.
  - New `tasks/projects.yml` (group `code-keeper`, projects `infra`, `api-gateway`,
    `inventory-app`, `billing-app` with merge rules, team members).
  - New `tasks/variables.yml`: group and project CI/CD variables, read from `CK_<key>` environment
    variables.
  - `tasks/install.yml` writes `gitlab.rb` before the first package install, so
    `initial_root_password` is applied.
  - `defaults`, `handlers` and `configure.yml` updated to match.
- Ansible, other roles:
  - New role `ansible/roles/gitlab_api_token/`: a root API token that expires after one day,
    created with `gitlab-rails runner`.
  - `ansible/roles/gitlab_runner/`: runner `19.5.0-1` and its helper images pinned. The runner
    is created with `POST /user/runners` and registered with its `glrt-` token, which is reused
    while valid. Templated `config.toml` (mode 600).
- Ansible, playbooks, config and scripts:
  - `deploy-runners.yml` has two plays; new `site.yml` runs everything.
  - `ansible.cfg` and `ansible/ansible.cfg` point to the generated `inventory/aws.ini`;
    `hosts.ini` is an example.
  - `ansible/scripts/setup-gitlab.sh` and `register-runner.sh` updated.
- New `ansible/terraform/`: GitLab (t3.large) and runner (t3.medium) on EC2 with security groups,
  Elastic IPs, IMDSv2, encrypted disks and the generated inventory. State in the existing S3 bucket.
- Repository split:
  - `infra/.gitlab-ci.yml` and `srcs/*/.gitlab-ci.yml` are standalone pipelines; merge requests
    build images without pushing.
  - The root `.gitlab-ci.yml` is deleted.
  - New `.gitignore` in `infra/` and each `srcs/<app>/`.
  - New `scripts/publish_repos.sh` (subtree split and push to `code-keeper/<project>`).
- `infra/.gitlab-ci.yml`: `infra:validate:dependencies` called `terraform outdated`, which does not
  exist. It now compares the locked provider versions with the newest allowed and the newest
  released.
- `infra/environments/*/backend.hcl` and `variables.tf`: stale comments about Terraform 1.9.5 and
  the GitLab registry corrected (comments and a variable description only).
- `scripts/test_pipelines.sh`: checks the standalone pipelines, the publish script, the EC2
  Terraform and `site.yml`.
- `scripts/audit_orchestrator.sh`, now executable:
  - checks updated for the new runner and task names;
  - two false positives fixed (a blank line between plays read as a role named `name`; a boolean
    `force_random_password: true` read as a password);
  - the live checks use `inventory/aws.ini` with its user and key when it exists.
- `README.md`: rewritten for the current setup.
- `Results.md`: status and next steps updated.
- `reports/audit_report.json` and `reports/ansible_list_tasks.txt`: regenerated on this machine.
- New `drafts/`: `AUDIT_GUIDE.md`, `AWS_SETUP.md`, `READINESS_REVIEW.md` and
  `AUDIT_READINESS_PLAN.md`, for the user to check and copy into `docs/`. `docs/` is unchanged.

**Why**
The user asked to fix three things:
- the Ansible GitLab problems (legacy runner tokens, unpinned version, wrong `allowed_to_push`
  format);
- the split into four repositories with CI/CD variables on a GitLab group;
- the outdated docs.

The user chose EC2 hosts, folders with a publish script, and drafts outside `docs/`. The
`terraform outdated` job, the stale comments and the audit script problems came up while checking
the docs against the code.

**Verified**
- Ansible roles, run against the local GitLab 19.5:
  - First run creates the settings, group, projects, member and runner.
  - A second run only rotates the API token.
  - An invalid runner token is reset and then verifies.
  - The variables task updates, then creates on 404, against a mock API.
  - All test objects were deleted afterwards and the instance settings restored.
- ansible-lint at the production profile: 0 failures.
- All four pipelines accepted by GitLab's CI lint API.
- The new dependency job script ran in `hashicorp/terraform:1.6`.
- `terraform validate` passes in both environments.
- Local scripts:
  - `scripts/test_pipelines.sh`: 89 pass.
  - `scripts/verify_security.sh`: 78 pass, 1 known false positive.
  - `scripts/audit_orchestrator.sh`: 81 pass, 0 fail, 3 blocked until GitLab runs on EC2.
  - shellcheck clean.
- Not tested yet: the package install on a fresh EC2 host.
