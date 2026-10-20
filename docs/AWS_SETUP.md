# AWS Setup Guide

Step-by-step setup of everything the code-keeper Terraform and CI pipelines need in AWS. Based on
commit `c62effa`; names, region and variables come from `infra/` and the `.gitlab-ci.yml` files.

**Region:** everything is in `us-east-1`. It is fixed in `terraform.tfvars`, the availability zones
and the ECS log configuration.

**What Terraform creates per environment (staging and production):**

- a VPC with public, private and database subnets, one NAT gateway and VPC flow logs
- an ALB on port 80
- an ECS Fargate cluster with the 3 services and private DNS (Cloud Map) between them
- 2 PostgreSQL RDS instances (inventory and billing)
- an Amazon MQ RabbitMQ broker
- a KMS key, 3 Secrets Manager secrets, IAM roles and CloudWatch log groups

---

## Step 0. Know the cost first

Rough monthly cost if everything runs 24/7. These are estimates from us-east-1 list prices; confirm
them with the AWS Pricing Calculator.

| | Staging | Production (as configured) |
|---|---|---|
| Fargate tasks | 6 small, about $55 | 12 larger, about $215 |
| RDS (2 instances) | t3.micro, about $30 | t3.small Multi-AZ, about $130 |
| Amazon MQ | mq.t3.micro, about $20 | 3-node mq.m5.large cluster, about $630 |
| NAT, ALB, public IPs | about $60 | about $60 |
| **Total** | **about $170/month** | **about $1,000/month** |

Production costs about $1.40 an hour, mostly because of the RabbitMQ cluster. Bring staging up
first, bring production up close to the audit, and destroy it afterwards (step 11). See "Open code
changes" at the end for a smaller production option.

---

## Step 1. Account basics (console)

1. Create the AWS account, or use one that is only for this project.
2. Turn on MFA for the root user, and do not use root after this step.
3. Create a budget: Billing → Budgets → "Monthly cost budget", with an email alert (for example at
   $50).
4. Create an admin IAM user for yourself (for example `<you>-admin`) with `AdministratorAccess` and
   MFA, and create an access key for it for the CLI.

---

## Step 2. CLI on your machine

```bash
aws configure --profile code-keeper     # your admin key, region us-east-1, output json
export AWS_PROFILE=code-keeper
aws sts get-caller-identity             # shows your account ID
```

---

## Step 3. Pre-flight checks

```bash
aws rds describe-db-engine-versions --engine postgres --region us-east-1 \
  --query "DBEngineVersions[?starts_with(EngineVersion, '15.')].EngineVersion" --output text
aws mq describe-broker-engine-types --engine-type RABBITMQ --region us-east-1 \
  --query 'BrokerEngineTypes[].EngineVersions[].Name' --output text
aws service-quotas list-service-quotas --service-code fargate --region us-east-1 \
  --query "Quotas[].[QuotaName,Value]" --output table
```

- **Engine versions.** The code pins RDS PostgreSQL `15.4` (`infra/modules/rds/main.tf`) and
  RabbitMQ `3.11.20` (`infra/modules/rabbitmq/main.tf`). If either is not in the lists, the first
  apply fails, so the code must be updated to a listed version first.
- **Fargate quota.** Both environments together need about 7.5 vCPU. New accounts sometimes start
  lower; if so, request an increase in Service Quotas.

---

## Step 4. Terraform state bucket and lock table

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="code-keeper-tfstate-${ACCOUNT_ID}"

aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name code-keeper-tf-locks --region us-east-1 \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST
```

New S3 buckets are encrypted by default. Both environments share this bucket and table; the state
keys come from `infra/environments/*/backend.hcl`.

---

## Step 5. A CI user for the pipeline

```bash
aws iam create-user --user-name code-keeper-ci
aws iam attach-user-policy --user-name code-keeper-ci \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-access-key --user-name code-keeper-ci
```

Copy the access key ID and secret straight into GitLab (step 8). Do not paste them anywhere else.

**Why admin:** Terraform creates IAM roles and policies, and an identity that can do that can make
itself admin anyway, so a narrower policy protects little. Admin also covers Secrets Manager, KMS
and the `elasticloadbalancing:DescribeLoadBalancers` call the health checks use.

**After the repo split:** the app repos only need a small deploy policy:

- ECS: `DescribeTaskDefinition`, `RegisterTaskDefinition`, `UpdateService` and `DescribeServices`
- `iam:PassRole` on the ECS execution role
- `elasticloadbalancing:DescribeLoadBalancers`

---

## Step 6. Docker Hub

1. In the namespace the pipeline pushes to (`grafido` by default), create 3 **public**
   repositories: `api-gateway`, `inventory-app` and `billing-app`. They must be public, because ECS
   pulls without credentials (the task definitions have no registry login).
2. Create an access token: Account settings → Personal access tokens, with Read & Write access.

---

## Step 7. Three passwords

```bash
openssl rand -hex 16    # run 3 times: inventory DB, billing DB, RabbitMQ
```

Hex output meets the RDS rules, the Amazon MQ rules (at least 12 characters, no `,` `:` `=`) and
GitLab's masking rules. Keep the passwords in a password manager; step 11 needs them again.

---

## Step 8. GitLab CI/CD variables

Add these under Settings → CI/CD → Variables, on the GitLab that runs the pipeline. The local test
GitLab works for a first run, which finds AWS problems early while the Ansible GitLab is still being
set up. After the repo split, put them on the GitLab **group** so all four repos share them.

| Key | Value | Protected | Masked |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID` | from step 5 | yes | yes |
| `AWS_SECRET_ACCESS_KEY` | from step 5 | yes | yes |
| `TF_STATE_BUCKET` | `code-keeper-tfstate-<ACCOUNT_ID>` | yes | no |
| `TF_STATE_REGION` | `us-east-1` | yes | no |
| `TF_STATE_LOCK_TABLE` | `code-keeper-tf-locks` | yes | no |
| `TF_VAR_inventory_db_password` | from step 7 | yes | yes |
| `TF_VAR_billing_db_password` | from step 7 | yes | yes |
| `TF_VAR_rabbitmq_password` | from step 7 | yes | yes |
| `DOCKERHUB_USERNAME` | your Docker Hub user | yes | no |
| `DOCKERHUB_TOKEN` | from step 6 | yes | yes |
| `DOCKERHUB_REPO` | only if your namespace is not `grafido` | no | no |

- **Environment scope:** leave it at "All". The plan jobs do not declare an environment, so
  variables scoped to staging or production would not reach them.
- **Region:** do not set `AWS_DEFAULT_REGION`; the YAML already sets `us-east-1`.
- **SonarQube:** `SONAR_HOST_URL` and `SONAR_TOKEN` are optional.
- **Branches:** protected variables only reach pipelines on `main`, so branch pipelines that touch
  `infra/` still stop at `infra:init`. That is by design.

---

## Step 9. The first run

Infra only applies when a commit to `main` changes something under `infra/` (for example the engine
version update from step 3).

1. **Staging infra.** `infra:plan:*` runs, then `infra:apply:staging` runs by itself. Expect 15 to
   20 minutes, mostly RDS and MQ.
2. **App jobs.** Build, test and scan run, then containerize pushes the images to Docker Hub.
3. **Staging deploy.** `deploy:staging` registers a new task definition and waits for the service
   to settle. For the gateway it also checks `http://<ALB DNS>/health`. Until the images exist, ECS
   logs some failed task starts; that is harmless.
4. **Production infra.** Start `infra:approval:production` by hand, then let
   `infra:apply:production` **finish** before the next step. The MQ cluster can take 20 to 30
   minutes.
5. **Production apps.** Only then run the three `approval:production` jobs, followed by
   `promote:image` and `deploy:production`. The app production deploy does not wait for production
   infra yet, so if it is approved too early it fails because the cluster does not exist.

---

## Step 10. Check it works

```bash
for env in staging production; do
  DNS=$(aws elbv2 describe-load-balancers --names "code-keeper-${env}-alb" \
        --query 'LoadBalancers[0].DNSName' --output text)
  echo "$env: $DNS"; curl -s "http://${DNS}/health"; echo
  aws ecs describe-services --cluster "code-keeper-${env}-cluster" \
    --services code-keeper-${env}-api-gateway code-keeper-${env}-inventory-app code-keeper-${env}-billing-app \
    --query 'services[].[serviceName,runningCount,desiredCount]' --output table
done
```

---

## Step 11. Tear down

There is no destroy job in CI. From `infra/environments/<env>`, run:

```bash
terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET" \
  -backend-config="region=us-east-1" -backend-config="dynamodb_table=code-keeper-tf-locks"
export TF_VAR_inventory_db_password=... TF_VAR_billing_db_password=... TF_VAR_rabbitmq_password=...
export TF_VAR_image_repository_prefix=docker.io/grafido
terraform destroy
```

Destroy production first. Keep the state bucket and lock table; they cost almost nothing.

---

## Open code changes before the first apply

1. **Engine versions.** Update RDS and RabbitMQ to versions from the step 3 output.
2. **Docker Hub login for ECS.** ECS pulls anonymously through each environment's single NAT IP,
   and Docker Hub rate-limits anonymous pulls per IP. With 18 tasks, a few redeploys or crash loops
   could hit the limit. A pull secret in Secrets Manager fixes this and allows private repos.
3. **Production waits for infra.** Make the app `deploy:production` jobs wait for
   `infra:apply:production`, as staging already does. This needs the "Apply to Production" stage to
   move before "Deploy to Production".
4. **Production size (a decision).** Keep the full configuration (about $1,000 a month while it
   runs), or shrink it to a single mq.t3.micro broker and 2 tasks per service (about $200 a month),
   at the cost of the high-availability setup.
