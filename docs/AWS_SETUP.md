# AWS Setup Guide

Step-by-step setup of everything code-keeper needs in AWS: the account, the Terraform state, the
GitLab hosts, the CI/CD variables, the first deploy, redeploys and teardown. Based on the code as of
2026-10-21, after the first full deploy of both environments and the split into four repositories.

**Region:** everything is in `us-east-1`. It is fixed in the `terraform.tfvars` files, the
availability zones and the ECS log configuration.

**What the `infra` pipeline creates per environment (staging and production):**

- a VPC with public, private and database subnets, one NAT gateway and VPC flow logs
- an ALB on port 80
- an ECS Fargate cluster with the 3 services and private DNS (Cloud Map) between them
- 2 PostgreSQL RDS instances (inventory and billing)
- an Amazon MQ RabbitMQ broker
- a KMS key, 4 Secrets Manager secrets (3 passwords and the Docker Hub pull login), IAM roles and
  CloudWatch log groups

**What `ansible/terraform` creates once:** two EC2 hosts in the default VPC (GitLab on a
`t3.large`, the runner on a `t3.medium`), their security groups, Elastic IPs and SSH key pair.

---

## Step 0. Know the cost and the plan limits first

**Both environments need the AWS paid plan.** The Free plan refused the first deploys twice:

| Free plan limit | What failed | What the code does now |
|---|---|---|
| At most 1 day of RDS automated backups | `CreateDBInstance` with `FreeTierRestrictionError` | `backup_retention_period = 1` (the paid plan allows up to 35) |
| At most 2 RDS instances in the account | production with `InstanceQuotaExceeded`, because staging already had 2 | nothing: 4 instances need the paid plan |

On the paid plan, the remaining Free plan credits are used first and then the card is billed.
Check the credits with:

```bash
aws freetier get-account-plan-state --query accountPlanRemainingCredits
```

Prices are us-east-1 list prices (AWS Pricing API, 2026-10-20):

| Per environment | Size | Per hour |
|---|---|---|
| Amazon MQ | 1 x mq.m7g.medium (the smallest RabbitMQ type), plus storage | about $0.14 to $0.17 |
| Fargate | 6 tasks of 0.25 vCPU / 0.5 GB | about $0.07 |
| RDS | 2 x db.t3.micro, 20 GB, single-AZ | about $0.04 |
| NAT gateway, ALB, 3 public IPv4 addresses | | about $0.09 |
| KMS, Secrets Manager, CloudWatch | | about $0.01 |
| **Total** | | **about $0.35 to $0.40** |

Both environments together measured about $0.79 an hour, about $19 a day. The GitLab hosts add
about $0.14 an hour while running (t3.large $0.083, t3.medium $0.042, 80 GB of gp3 and 2 public
IPv4 addresses); stopped, they still cost about $0.02 an hour for the disks and addresses. Bring
everything up only to test and for the audit, and tear it down right after (steps 13 and 14).

---

## Step 1. Account basics (console)

1. Create the AWS account, or use one that is only for this project, and move it to the paid plan
   (Billing > Plans).
2. Turn on MFA for the root user, and do not use root after this step.
3. Create a budget: Billing > Budgets > "Monthly cost budget", with an email alert (for example at
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

Also install Terraform 1.5 or newer and `ansible-core` 2.15 or newer
(`sudo apt install ansible-core` on Ubuntu).

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

Results on 2026-10-20, and what the code uses:

- **RDS PostgreSQL.** 15.7 to 15.19 are offered; 15.4 is not. The code sets `engine_version = "15"`,
  so RDS picks the current 15.x release.
- **RabbitMQ.** Only 3.13, 4.2 and 4.3 are offered. mq.t3.micro is no longer offered for RabbitMQ,
  and the mq.m5 types only run 3.13. The code uses RabbitMQ 4.2 on mq.m7g.medium. Amazon MQ only
  listens on AMQPS (5671), which is what the security groups and the services use.
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

New S3 buckets are encrypted by default. Everything shares this bucket and table; the state keys
come from the `backend.hcl` files: `infra/environments/<env>/backend.hcl` for the environments and
`ansible/terraform/backend.hcl` (`code-keeper/gitlab/terraform.tfstate`) for the GitLab hosts.

---

## Step 5. A CI user for the pipelines

```bash
aws iam create-user --user-name code-keeper-ci
aws iam attach-user-policy --user-name code-keeper-ci \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam create-access-key --user-name code-keeper-ci
```

Keep the access key ID and secret for step 8, and do not paste them anywhere else.

**Why admin:** Terraform creates IAM roles and policies, and an identity that can do that can make
itself admin anyway, so a narrower policy protects little. Admin also covers Secrets Manager, KMS
and the `elasticloadbalancing:DescribeLoadBalancers` call the health checks use.

**A tighter option now that the repositories are split:** the app projects only need a small deploy
policy, so they could get their own key (as project variables that override the group's):

- ECS: `DescribeTaskDefinition`, `RegisterTaskDefinition`, `UpdateService` and `DescribeServices`
- `iam:PassRole` on the ECS execution role
- `elasticloadbalancing:DescribeLoadBalancers`

---

## Step 6. Docker Hub

1. In the namespace the pipelines push to (`DOCKERHUB_REPO`, `sntentop` in this project), create 3
   **public** repositories: `api-gateway`, `inventory-app` and `billing-app`.
2. Create an access token: Account settings > Personal access tokens, with Read & Write access.
   The pipelines push with it, and ECS pulls with the same user and token (stored in Secrets
   Manager), so pulls are not limited like anonymous pulls through the NAT address.

---

## Step 7. Three passwords

```bash
openssl rand -hex 16    # run 3 times: inventory DB, billing DB, RabbitMQ
```

Hex output meets the RDS rules, the Amazon MQ rules (at least 12 characters, no `,` `:` `=`) and
GitLab's masking rules. Keep the passwords in a password manager.

---

## Step 8. GitLab on EC2, with Ansible

### 8.1 SSH key and hosts

```bash
ssh-keygen -t ed25519 -f ~/.ssh/code-keeper -C code-keeper
MYIP=$(curl -s https://checkip.amazonaws.com)

cd ansible/terraform
terraform init -backend-config=backend.hcl -backend-config="bucket=$BUCKET" \
  -backend-config="region=us-east-1" -backend-config="dynamodb_table=code-keeper-tf-locks"
terraform apply -var "admin_cidrs=[\"${MYIP}/32\"]"
terraform output
cd ../..
```

This writes `ansible/inventory/aws.ini` (git-ignored) with both addresses. SSH to both hosts is
only open to `admin_cidrs`. GitLab's port 80 is open to `team_cidrs`, by default everyone; add
`-var 'team_cidrs=["<team range>/24", ...]'` to narrow it.

### 8.2 CI/CD variables, through Ansible

Ansible creates the variables from `CK_<key>` environment variables, so nothing is typed into the
UI or written to the repository. Keep them in a file outside the repository, readable only by you:

```bash
install -m 600 /dev/null ~/.config/code-keeper.env
cat >> ~/.config/code-keeper.env <<'EOF'
export GITLAB_ROOT_PASSWORD='<at least 12 characters>'
export CK_AWS_ACCESS_KEY_ID='<step 5>'
export CK_AWS_SECRET_ACCESS_KEY='<step 5>'
export CK_DOCKERHUB_USERNAME='<Docker Hub user>'
export CK_DOCKERHUB_TOKEN='<step 6>'
export CK_DOCKERHUB_REPO='<Docker Hub namespace>'
export CK_TF_STATE_BUCKET='code-keeper-tfstate-<ACCOUNT_ID>'
export CK_TF_STATE_REGION='us-east-1'
export CK_TF_STATE_LOCK_TABLE='code-keeper-tf-locks'
export CK_TF_VAR_inventory_db_password='<step 7>'
export CK_TF_VAR_billing_db_password='<step 7>'
export CK_TF_VAR_rabbitmq_password='<step 7>'
EOF
```

| Key | Level | Protected | Masked |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | group `code-keeper` | yes | yes |
| `DOCKERHUB_USERNAME` | group | yes | no |
| `DOCKERHUB_TOKEN` | group | yes | yes |
| `DOCKERHUB_REPO` | group | no | no |
| `TF_STATE_BUCKET`, `TF_STATE_REGION`, `TF_STATE_LOCK_TABLE` | project `infra` | yes | no |
| `TF_VAR_inventory_db_password`, `TF_VAR_billing_db_password`, `TF_VAR_rabbitmq_password` | project `infra` | yes | yes |

- **Docker Hub login for ECS:** no extra variables. The infra plan jobs pass `DOCKERHUB_USERNAME`
  and `DOCKERHUB_TOKEN` to Terraform as `TF_VAR_dockerhub_username` and `TF_VAR_dockerhub_token`.
  To give ECS a separate read-only token, add a masked `TF_VAR_dockerhub_token` on the infra
  project.
- **Environment scope:** "All". The plan jobs do not declare an environment, so variables scoped to
  staging or production would not reach them.
- **Region:** do not set `AWS_DEFAULT_REGION`; the pipelines set `us-east-1`.
- **SonarQube:** `SONAR_HOST_URL` and `SONAR_TOKEN` are optional; add them on the group by hand.
- **Branches:** protected variables only reach pipelines on `main`, which is why Init, Plan, Apply
  and every deploy job run on `main` only.

### 8.3 Run the playbooks

To give teammates accounts, list them in a file outside the repository (access level 30 is
Developer, 40 is Maintainer):

```yaml
# ~/.config/code-keeper-team.yml
gitlab_team_members:
  - { username: "jdoe", name: "Jane Doe", email: "jane@example.com", access_level: 40 }
```

```bash
source ~/.config/code-keeper.env
cd ansible
ansible all -m ping
ansible-playbook playbooks/site.yml -e @$HOME/.config/code-keeper-team.yml
cd ..
```

Without the team file, drop the `-e` option. New accounts get a random password; set a real one
under Admin > Users.

About 15 minutes the first time. Then log in at `terraform -chdir=ansible/terraform output -raw
gitlab_url` as `root` with `GITLAB_ROOT_PASSWORD`, and check Admin > CI/CD > Runners shows the
runner online.

---

## Step 9. Publish the four repositories

Commit everything first; the script publishes committed work only.

```bash
export GITLAB_URL=$(terraform -chdir=ansible/terraform output -raw gitlab_url)
scripts/publish_repos.sh --dry-run
scripts/publish_repos.sh infra
```

The script asks once for the GitLab password of `root` and hands it to git itself, so it works in
an editor terminal (VS Code's git helper is bypassed) and no git credential helper saves it. To
skip the prompt, pass it from the env file of step 8, or set `GITLAB_PUSH_TOKEN` to a personal
access token with `write_repository`:

```bash
GITLAB_PUSH_TOKEN="$GITLAB_ROOT_PASSWORD" scripts/publish_repos.sh infra
```

The push starts the infra pipeline. Publish the three apps once the infra pipeline is past "Apply
to Staging" (step 10):

```bash
scripts/publish_repos.sh api-gateway inventory-app billing-app
```

If both environments are already up, publish all four at once with `scripts/publish_repos.sh`: the
infra plans show no changes.

---

## Step 10. The first run

1. **Staging infra.** In `code-keeper/infra`, the `main` pipeline runs Init, Validate and Plan, then
   `infra:apply:staging` by itself. Expect 15 to 20 minutes, mostly RDS and MQ.
2. **Production infra.** Run `infra:approval:production`; `infra:apply:production` follows. Another
   15 to 20 minutes.
3. **First image tags.** Terraform creates the task definitions with the image tag from
   `terraform.tfvars`: `staging-latest` and `production-latest`. Those tags do not exist yet (the
   pipelines tag images with the commit SHA, and `production-latest` only appears after the first
   promotion), so the services start with 0 running tasks and ECS logs failed task starts. That is
   expected; the first app deploy fixes it. Terraform ignores later task definition changes, so an
   infra apply never rolls back what the app pipelines deployed.
4. **Apps.** Publish the three apps (step 9). Each `main` pipeline builds, tests, scans, pushes the
   image and runs `deploy:staging`, which registers a task definition with the SHA image and waits
   for the service to settle; for the gateway it also checks `http://<ALB DNS>/health`.
5. **Production apps.** Run the three `<app>:approval:production` jobs; `promote:image` and
   `deploy:production` follow.

---

## Step 11. Check it works

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

End to end, through each load balancer:

```bash
curl -s -X POST "http://${DNS}/api/movies" -H 'Content-Type: application/json' -d '{"title":"Alien","description":"1979"}'
curl -s "http://${DNS}/api/movies?title=Alien"
curl -s -X POST "http://${DNS}/api/billing" -H 'Content-Type: application/json' \
  -d '{"user_id":"20","number_of_items":"3","total_amount":"9.99"}'
```

The billing order goes through RabbitMQ; the billing worker's log (CloudWatch,
`/ecs/code-keeper-<env>/billing-app`) shows "Successfully processed and recorded order".

---

## Step 12. Redeploy (for example before the audit)

After a teardown, or to refresh everything:

1. Bring the GitLab hosts back: `terraform -chdir=ansible/terraform apply ...` (step 8.1), then
   `ansible-playbook playbooks/site.yml` (step 8.3). If the hosts were destroyed, GitLab is new and
   empty: publish the repositories again (step 9).
2. In `code-keeper/infra`: Build > Pipelines > Run pipeline on `main`. Run the production approval
   when staging is applied. About 40 minutes from nothing.
3. In each app project: Run pipeline on `main`, then its approval. About 15 minutes, in parallel.
4. Check with step 11.

Allow about an hour in total from a torn-down account.

---

## Step 13. Tear down

There is no destroy job in CI. For each environment, production first, from
`infra/environments/<env>`:

```bash
terraform init -reconfigure -backend-config=backend.hcl -backend-config="bucket=$BUCKET" \
  -backend-config="region=us-east-1" -backend-config="dynamodb_table=code-keeper-tf-locks"
export TF_VAR_inventory_db_password=... TF_VAR_billing_db_password=... TF_VAR_rabbitmq_password=...
export TF_VAR_dockerhub_username=... TF_VAR_dockerhub_token=...
export TF_VAR_image_repository_prefix=docker.io/<Docker Hub namespace>
terraform destroy
```

Then the GitLab hosts, if they are not needed until the next session:

```bash
terraform -chdir=ansible/terraform destroy -var "admin_cidrs=[\"${MYIP}/32\"]"
```

Destroying the hosts deletes GitLab with its projects, pipelines and variables; step 12 rebuilds
it. To keep GitLab, stop the two instances instead (EC2 > Instances > Stop). Keep the state bucket
and lock table; they cost almost nothing.

---

## Step 14. Check that nothing billable is left

Every command should print nothing:

```bash
aws ec2 describe-nat-gateways --region us-east-1 --filter Name=state,Values=pending,available \
  --query 'NatGateways[].NatGatewayId' --output text
aws ec2 describe-addresses --region us-east-1 --query 'Addresses[].PublicIp' --output text
aws ec2 describe-instances --region us-east-1 --filters Name=tag:Project,Values=code-keeper \
  Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
aws ec2 describe-volumes --region us-east-1 --filters Name=tag:Project,Values=code-keeper --query 'Volumes[].VolumeId' --output text
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName' --output text
aws rds describe-db-instances --region us-east-1 --query 'DBInstances[].DBInstanceIdentifier' --output text
aws rds describe-db-snapshots --region us-east-1 --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
aws mq list-brokers --region us-east-1 --query 'BrokerSummaries[].BrokerName' --output text
aws ecs list-clusters --region us-east-1 --query 'clusterArns' --output text
```

Secrets Manager keeps deleted secrets for a recovery window; they are free while scheduled for
deletion.

---

## Findings from the first deploy (2026-10-21)

1. **Free plan limits** on RDS backups and instance count (step 0); the account is on the paid
   plan now.
2. **Terraform cache:** both Init jobs saved to one cache key, and the plan and apply jobs never
   ran `terraform init`. Every Terraform job now runs `terraform init` itself.
3. **Deploy tools:** `amazon/aws-cli` has no `tar` or `gzip`, which the crane download needs; the
   deploy jobs install them.
4. **crane image:** `crane:0.20.2` does not exist and the plain crane images have no shell, so the
   promote jobs use crane's `debug` image pinned by digest.
5. **First image tags** (step 10, item 3).
6. **Engine versions and sizes** (step 3): RDS PostgreSQL `15`, RabbitMQ `4.2` on mq.m7g.medium,
   production sized like staging (`infra/environments/production/main.tf` lists the HA sizes).
