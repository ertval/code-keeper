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

## 2026-10-21 15:19 EEST: Private variables file for the Ansible run

**What**
- `~/.config/code-keeper.env` (outside the repository, mode 600): created, with
  `GITLAB_ROOT_PASSWORD` (newly generated, the root login of the EC2 GitLab) and the 11 `CK_*`
  values that `ansible/roles/gitlab/tasks/variables.yml` turns into GitLab CI/CD variables.

**Why**
The user ran `terraform apply` in `ansible/terraform` (GitLab at 23.21.56.248, runner at
54.82.149.95) and asked for the next step, which is `docs/AWS_SETUP.md` step 8.2. The values were
copied from the local test GitLab project `root/code-keeper`, which already ran pipeline 14 with
them, so nothing was typed by hand or shown in the terminal.

**Verified**
- The three Terraform passwords match the separate copy in
  `~/.config/code-keeper-local-gitlab/aws-tf-passwords.env`.
- The file parses in bash.
- `ansible all -m ping` reaches both hosts.
- `ansible-playbook playbooks/site.yml --syntax-check` passes with the local ansible-core 2.19.0.

- The 11 CK_* values, copied from the local GitLab project that ran the green pipeline 14. Nothing was printed. The three database and RabbitMQ passwords match your other saved copy.
- GITLAB_ROOT_PASSWORD, newly generated. It's the root login for the new GitLab. To see it: grep GITLAB_ROOT ~/.config/code-keeper.env.

## 2026-10-21 16:43 EEST: GitLab and the runner installed on EC2 with Ansible; three fixes from the first real run

**What**
- On the EC2 hosts:
  - GitLab CE 19.5.0 is installed and configured at http://23.21.56.248, with the group
    `code-keeper`, its 4 projects and the 11 CI/CD variables.
  - The runner `docker-shared-runner-01` on 54.82.149.95 is installed, registered and online.
- `ansible.cfg` and `ansible/ansible.cfg`: new `[ssh_connection]` with
  `ServerAliveInterval=30`.
- `ansible/playbooks/deploy-runners.yml`: the `gitlab-runner list` result is `no_log`, and the
  summary prints it with the token replaced by `<hidden>`.
- `ansible/roles/gitlab/tasks/variables.yml`: each variable is read first. It is updated only when
  its value or flags differ and created when missing.
- `README.md`, `drafts/AUDIT_GUIDE.md`, `drafts/AUDIT_READINESS_PLAN.md`: the
  `gitlab-runner list` demo pipes through `sed` to hide the token.

**Why**
The user asked Claude to run the playbook. The first real run found three problems:
- **The run hung.** The GitLab package install sends nothing for about 15 minutes, and the
  user's router dropped the idle SSH connection. The host finished, with the result stuck in its
  send queue, but Ansible waited forever. The hung run was stopped and rerun.
- **The runner token leaked.** The runner summary printed `gitlab-runner list`, which includes
  the full runner token, into the run log. That token was reset through the GitLab API (the old
  one now gets 403), the log was deleted, and the playbook registered a new token, which it no
  longer prints.
- **Reruns were not idempotent.** The variables task reported all 11 variables as changed on
  every run.

**Verified**
- Five runs. The last two changed only the two one-day API tokens, with 0 changes on the runner
  host and no token in the output.
- The invalid-token path works on the real hosts: the token was detected as invalid, reset,
  written and verified.
- Checked inside GitLab Rails:
  - the root password from `~/.config/code-keeper.env` works;
  - sign-up is disabled and `main` is protected (push and merge 40, no force push);
  - the group is private, with 5 variables, and `infra` has 6;
  - all projects require green pipelines;
  - the runner is online.
- The sign-in page answers 200 from this machine.
- ansible-lint at the production profile: 0 failures.

## 2026-10-21 21:11 EEST: publish script asks for the password itself

**What**
- `scripts/publish_repos.sh`:
  - asks once for the GitLab password (or uses `GITLAB_PUSH_TOKEN`) and sends it to git in a header;
  - unsets `GIT_ASKPASS` and `SSH_ASKPASS`, turns off git's terminal prompt and clears `credential.helper` for its pushes;
  - checks access with `git ls-remote` before splitting, so a wrong password stops early with a clear message;
  - the header comment and the `--help` range are updated to match.

**Why**
The first real publish failed with "HTTP Basic: Access denied". The terminal was a VS Code terminal whose `GIT_ASKPASS` helper was no longer connected, so git sent an empty password instead of prompting. Also, `credential.helper store` in `~/.gitconfig` would have saved the root password in plain text in `~/.git-credentials` after a successful push. No credentials were stored by the failed attempt.

**Verified**
- `bash -n` and shellcheck are clean.
- These tests ran in a throwaway clone with a git shim that replaced every push with `git ls-remote`, so nothing was pushed:
  - `--dry-run` does not prompt;
  - with no terminal and no token, the script exits 1 with a message;
  - a wrong password typed at the prompt, and a wrong `GITLAB_PUSH_TOKEN`, both stop at the access check;
  - with the right password and the VS Code `GIT_ASKPASS` still set, all four splits match the earlier dry run (`c8ec62c`, `0758a5c`, `ae7b51d`, `85fb0af`) and all four projects are reachable;
  - `~/.git-credentials` has no entry for the GitLab host.

## 2026-10-21 22:05 EEST: first EC2 pipelines recorded, audit credential check fixed, drafts brought up to date

**What**
- `ansible/playbooks/deploy-runners.yml`: the runner summary now shows `Token=<redacted>` instead of `Token=<hidden>`.
- `README.md` and `drafts/AUDIT_GUIDE.md`: the masked `gitlab-runner list` demo uses the same `<redacted>` placeholder.
- `scripts/audit_orchestrator.sh`: the live hint for the runner (`RUNNER-LIVE-LIST`) masks the token the same way, instead of suggesting the plain `gitlab-runner list`.
- `reports/audit_report.json`, `reports/ansible_list_tasks.txt`: regenerated with the live checks on the EC2 hosts. Result: 84 pass, 0 fail, 0 blocked, 4 skipped (checkov, hadolint, tflint, tfsec not installed).
- `drafts/AUDIT_READINESS_PLAN.md`: rewritten with what is done and the steps left (docs into place and commit, the crud-master claim, rehearsal, costs, optional items, teardown).
- `drafts/READINESS_REVIEW.md`: verdict and statuses updated (GitLab on EC2 and the repository split done, commit references instead of "uncommitted"), evidence for the EC2 install and the four pipelines added.
- `drafts/AWS_SETUP.md` step 9: the publish script asks for the password itself; how to pass it from the env file; publishing all four at once when the environments are up.
- `Results.md`: header, summary and cost; the GitLab on EC2 table; the four EC2 pipelines; next steps and status table; the two fixes; the crud-master check added to the open items.

**Why**
The four repositories were published to the EC2 GitLab, and their first pipelines (`infra` #1, `api-gateway` #2, `inventory-app` #3, `billing-app` #4) passed every job, including the production approvals done by the user. The first audit rerun then failed one control: its credential grep read the `Token=<hidden>` redaction pattern as a credential. The audit already treats "redact" as a documented non-secret, so the placeholder was renamed rather than the check weakened.

**Verified**
- All 49 jobs in the four pipelines succeeded.
- Both infra plans said "No changes", and the production apply said "0 added, 0 changed, 0 destroyed".
- Staging and production run `api-gateway:0758a5c5`, `inventory-app:ae7b51da` and `billing-app:85fb0afa`, with 2 of 2 tasks each. `/health`, `/api/movies` and `/docs` answer 200 through both ALBs.
- The new audit hint, run on the runner host, prints `Token=<redacted>` and no `glrt-` value.
- shellcheck is clean on the audit script, and `ansible-playbook --syntax-check` passes on the playbook.

## 2026-10-21 22:24 EEST: the local tool wrappers no longer hang in an interactive terminal

**What**
- `/tmp/ck-bin/*` (the seven local Docker wrappers for `ansible-playbook`, `ansible-lint`, `yamllint`, `terraform`, `trivy`, `gitleaks` and `shellcheck`; outside the repository): `docker run` gets `-i` only when stdin is not a terminal.

**Why**
The user's run of `scripts/audit_orchestrator.sh` after commit `6087ae8` hung at `ANSIBLE-SYNTAX`. The script runs tools under `timeout`, which puts them in their own process group. With `-i` and a terminal on stdin, `docker run` tried to read the terminal from the background and was stopped by SIGTTIN, which left the run waiting forever. Earlier runs had no terminal, so they never hit it. No repository file changed.

**Verified**
- In a pseudo-terminal, `timeout 120 /tmp/ck-bin/ansible-playbook ... --syntax-check` finishes with rc 0.
- Piping YAML into `/tmp/ck-bin/yamllint -` still works, so `-i` is still passed when stdin is a pipe.

## 2026-10-21 22:37 EEST: crud-master provenance confirmed

**What**
- `Results.md`: the "confirm the crud-master claim" item is removed from "Still open", and a line records that the team confirmed `srcs/` is its own crud-master code.

**Why**
The user confirmed that `srcs/` is the team's own code, so the "yes" in `docs/AUDIT_GUIDE.md` section 10.2 (the bonus question at `docs/audit.md:122`) is correct as written. `docs/AUDIT_READINESS_PLAN.md` step 2 still asks for the confirmation; the `docs` folder is read-only, so the user was given the text to update it.

## 2026-10-21 23:01 EEST: full audit session guide drafted

**What**
- `drafts/AUDIT_GUIDE.md` (new; `drafts/` is git-ignored): a full replacement for `docs/AUDIT_GUIDE.md`. It walks through every question of `docs/audit.md`, in order, each with what to show, the expected output, what to say, and the follow-up questions with answers. Also:
  - preparation: the day before, one hour before, what to have open, the running order with measured pipeline times, and what never to show on screen;
  - two tested live demos: the OpenAPI title and version in `api-gateway`, and the log retention in `infra`;
  - a zero-downtime probe, an end-to-end test, the teardown steps, a quick reference and a troubleshooting table.
  - It keeps the section numbers other files refer to (2.2, 8.5, 10.2).

**Why**
The user asked for a full guide on what to do during the audit for each question. `docs/` is read-only, so the guide is a draft for the user to copy over `docs/AUDIT_GUIDE.md`.

**Verified**
Every command and expected output was checked against the live system:
- the GitLab settings, runner and job logs via `gitlab-rails`;
- the ECS, RDS, MQ, ALB and CloudWatch state via the AWS CLI;
- `--list-tasks`, `gitlab-ctl status`, `gitlab-runner verify` and the masked `gitlab-runner list`;
- `scripts/test_pipelines.sh` (89 passed) and `scripts/verify_security.sh` (78 passed, the known false positive).

The demo changes were checked before the guide was written:
- the infra change passes `terraform fmt` and the Trivy IaC gate on a scratch copy.

The guide itself:
- passes the audit script's `DOC-GUIDE` heading rules and its question coverage check (22 of 22);
- has no em or en dashes, and gitleaks finds nothing in it.

Found while checking, and recorded in the guide:
- no pipeline schedules and no team accounts exist yet;
- `verify_security.sh` still ends red on its one false positive;
- the environment URLs in GitLab are placeholders;
- the ALBs have deletion protection, which `docs/AWS_SETUP.md` step 13 does not mention.

## 2026-10-21 23:55 EEST: stop and restart scripts for the AWS environments

**What**
- `scripts/stop_aws.sh`: created. Destroys production, then staging, with Terraform (it turns off
  each load balancer's deletion protection first), then stops the GitLab and runner hosts and
  lists what is still billed. Their disks and Elastic IPs stay, so GitLab keeps its address and
  data. Asks for confirmation; `--yes` and `--dry-run`.
- `scripts/restart_aws.sh`: created. Starts the hosts, waits for GitLab, makes a one-day root API
  token over SSH with gitlab-rails (revoked when the script ends), waits for the runner, runs the
  infra pipeline and gives its production approval, starts the three app pipelines once staging
  is applied, gives their approvals once production is applied, then checks /health, /api/movies
  and /docs on both load balancers. `--hosts-only` and `--check`.
- `scripts/test_pipelines.sh`: the syntax check now covers both new scripts.
- `README.md`: the scripts in the directory tree, a "Between sessions" part in section 11, and
  the teardown now uses `scripts/stop_aws.sh`, because the old commands failed on the load
  balancers' deletion protection.

**Why**
The user asked for one script that stops the charges and one that brings everything back for
the audit. NAT gateways, load balancers, RDS and Amazon MQ cannot be paused, so the environments
are destroyed and re-created by their own pipelines; GitLab is only stopped, which leaves about
$0.45 a day for its disks and public IPs.

**Verified**
`scripts/stop_aws.sh --dry-run` against the live account: 62 resources to destroy in each
environment, both hosts would stop, nothing changed. The token code ran on the local GitLab
19.5.0 (token made, admin and runner checks passed, 401 after the revoke). The pipeline and
approval loop ran against a throwaway local group with the same job names; all four pipelines
passed and the app approvals waited for infra production. The group was deleted afterwards.
shellcheck clean; `scripts/test_pipelines.sh` 0 failed. Not run: a real destroy or restart, and
the SSH token step on the EC2 GitLab (the session's safety check blocked it).

## 2026-10-22 00:16 EEST: show the questions in stop_aws.sh and publish_repos.sh

**What**
- `scripts/stop_aws.sh`: the "Type 'stop' to continue" question is printed again. The terminal is
  opened on its own first, and only that step's error is silenced.
- `scripts/publish_repos.sh`: the same fix for the password question.

**Why**
`read -p` prints its question on stderr, and both scripts sent stderr to /dev/null on the same
line to hide the "no terminal" error, so the question was invisible. The user's first real run
of `scripts/stop_aws.sh` was cancelled by pressing Enter at a prompt they could not see; nothing
was changed.

**Verified**
In a simulated terminal both questions appear and a wrong answer cancels; without a terminal
`stop_aws.sh` still says to use a terminal or `--yes`. shellcheck clean.
