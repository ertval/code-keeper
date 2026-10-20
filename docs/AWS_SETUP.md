# AWS Setup Guide

Step-by-step setup of everything the code-keeper Terraform and CI pipelines need in AWS. Based on
the code as of 2026-10-20, after the cheapest-sizing changes; names, region and variables come from
`infra/` and the `.gitlab-ci.yml` files.

**Region:** everything is in `us-east-1`. It is fixed in `terraform.tfvars`, the availability zones
and the ECS log configuration.

**What Terraform creates per environment (staging and production):**

- a VPC with public, private and database subnets, one NAT gateway and VPC flow logs
- an ALB on port 80
- an ECS Fargate cluster with the 3 services and private DNS (Cloud Map) between them
- 2 PostgreSQL RDS instances (inventory and billing)
- an Amazon MQ RabbitMQ broker
- a KMS key, 4 Secrets Manager secrets (3 passwords and the Docker Hub pull login), IAM roles and
  CloudWatch log groups

---

## Step 0. Know the cost first

The account is on the AWS Free plan, so everything is paid from its credits. Check what is left
with:

```bash
aws freetier get-account-plan-state --query accountPlanRemainingCredits
```

Both environments use the cheapest sizes that work, so they cost the same. Prices are us-east-1
list prices from the AWS Pricing API (2026-10-20):

| Per environment | Size | Per hour |
|---|---|---|
| Amazon MQ | 1 x mq.m7g.medium (the smallest RabbitMQ type), plus storage | about $0.14 to $0.17 |
| Fargate | 6 tasks of 0.25 vCPU / 0.5 GB | about $0.07 |
| RDS | 2 x db.t3.micro, 20 GB, single-AZ | about $0.04 |
| NAT gateway, ALB, 3 public IPv4 addresses | | about $0.09 |
| KMS, Secrets Manager, CloudWatch | | about $0.01 |
| **Total** | | **about $0.35 to $0.38** |

Both environments together cost about $0.75 an hour, or about $18 a day. With $73 of credits that
is about 4 days of both running nonstop, so bring them up only to test and for the audit, and
destroy them right after (steps 11 and 12).

---

## Step 1. Account basics (console)

1. Create the AWS account, or use one that is only for this project.
2. Turn on MFA for the root user, and do not use root after this step.
3. Create a budget: Billing → Budgets → "Monthly cost budget", with an email alert (for example at
   $20).
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
aws mq describe-broker-instance-options --engine-type RABBITMQ --region us-east-1 \
  --query 'BrokerInstanceOptions[].[HostInstanceType,join(`,`,SupportedEngineVersions)]' --output table
aws service-quotas list-service-quotas --service-code fargate --region us-east-1 \
  --query "Quotas[].[QuotaName,Value]" --output table
```

Results on 2026-10-20, and what the code uses now:

- **RDS PostgreSQL.** 15.7 to 15.19 are offered; 15.4 is not. The code sets `engine_version = "15"`,
  so RDS picks the current 15.x release.
- **RabbitMQ.** Only 3.13, 4.2 and 4.3 are offered; 3.11 is not. mq.t3.micro is no longer offered
  for RabbitMQ, and the mq.m5 types only run 3.13. The code uses RabbitMQ 4.2 on mq.m7g.medium.
- **Fargate quota.** 30 vCPU; both environments together need 3 vCPU.

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
   repositories: `api-gateway`, `inventory-app` and `billing-app`.
2. Create an access token: Account settings → Personal access tokens, with Read & Write access.
   The pipeline pushes with it, and ECS pulls with the same user and token (stored in Secrets
   Manager), so pulls are not limited like anonymous pulls through the NAT IP.

---

## Step 7. Three passwords

```bash
openssl rand -hex 16    # run 3 times: inventory DB, billing DB, RabbitMQ
```

Hex output meets the RDS rules, the Amazon MQ rules (at least 12 characters, no `,` `:` `=`) and
GitLab's masking rules. Keep the passwords in a password manager.

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

- **Docker Hub login for ECS:** no extra variables. The plan jobs pass `DOCKERHUB_USERNAME` and
  `DOCKERHUB_TOKEN` to Terraform as `TF_VAR_dockerhub_username` and `TF_VAR_dockerhub_token`. To
  give ECS a separate read-only token, add it as a masked `TF_VAR_dockerhub_token` variable.
- **Environment scope:** leave it at "All". The plan jobs do not declare an environment, so
  variables scoped to staging or production would not reach them.
- **Region:** do not set `AWS_DEFAULT_REGION`; the YAML already sets `us-east-1`.
- **SonarQube:** `SONAR_HOST_URL` and `SONAR_TOKEN` are optional.
- **Branches:** protected variables only reach pipelines on `main`, so branch pipelines that touch
  `infra/` still stop at `infra:init`. That is by design.

---

## Step 9. The first run

Infra only applies when a commit to `main` changes something under `infra/`.

1. **Staging infra.** `infra:plan:*` runs, then `infra:apply:staging` runs by itself. Expect 15 to
   20 minutes, mostly RDS and MQ.
2. **App jobs.** Build, test and scan run, then containerize pushes the images to Docker Hub.
3. **Staging deploy.** `deploy:staging` registers a new task definition and waits for the service
   to settle. For the gateway it also checks `http://<ALB DNS>/health`. Until the images exist, ECS
   logs some failed task starts; that is harmless.
4. **Production infra.** Start `infra:approval:production` by hand; `infra:apply:production` then
   runs. Expect another 15 to 20 minutes.
5. **Production apps.** Run the three `approval:production` jobs; `promote:image` and
   `deploy:production` follow. When infra changed in the same push, each `deploy:production` waits
   for `infra:apply:production` to finish.

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
export TF_VAR_dockerhub_username=... TF_VAR_dockerhub_token=...
export TF_VAR_image_repository_prefix=docker.io/grafido
terraform destroy
```

Destroy production first, then staging. Keep the state bucket and lock table; they cost almost
nothing.

---

## Step 12. Check that nothing billable is left

Every command should print nothing:

```bash
aws ec2 describe-nat-gateways --region us-east-1 --filter Name=state,Values=pending,available \
  --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region us-east-1 --query 'Addresses[].PublicIp' --output text
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName' --output text
aws rds describe-db-instances --region us-east-1 --query 'DBInstances[].DBInstanceIdentifier' --output text
aws rds describe-db-snapshots --region us-east-1 --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
aws mq list-brokers --region us-east-1 --query 'BrokerSummaries[].BrokerName' --output text
aws ecs list-clusters --region us-east-1 --query 'clusterArns' --output text
```

---

## Changes already made for AWS (2026-10-20)

1. **Engine versions:** RDS PostgreSQL `15` and RabbitMQ `4.2` on mq.m7g.medium (step 3).
2. **Cheapest sizes:** production is sized like staging: single-AZ db.t3.micro with 20 GB, a
   single-instance broker and 2 small tasks per service. `infra/environments/production/main.tf`
   lists the previous high-availability sizes.
3. **Docker Hub login for ECS:** the tasks pull the images through a Secrets Manager login.
4. **Production waits for infra:** "Apply to Production" now runs before "Deploy to Production",
   and each app `deploy:production` waits for `infra:apply:production` when it is in the pipeline.
5. **VPC DNS rule:** the security group rules for the VPC resolver used a bare address, which
   failed at plan time; it is now a `/32` CIDR.
