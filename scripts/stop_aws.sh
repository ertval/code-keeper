#!/usr/bin/env bash
# ==============================================================================
# Script: stop_aws.sh
# Purpose: Stops the hourly AWS charges of code-keeper between sessions:
#            1. destroys production, then staging, with Terraform. ECS, the load
#               balancer, the NAT gateway, RDS and Amazon MQ cannot be paused, so
#               they are removed, with the test data in the databases.
#            2. stops the GitLab and runner hosts. Their disks and Elastic IPs
#               stay, so GitLab keeps its address, projects, pipeline history,
#               CI/CD variables and runner.
#          scripts/restart_aws.sh brings everything back for the audit.
#
#          Still billed afterwards: the two 40 GB disks and the two Elastic IPs,
#          about $0.45 a day, plus cents for the state bucket and lock table.
#          Removing those as well, GitLab included, is the full teardown in
#          docs/AWS_SETUP.md step 13.
#
# Usage:
#   scripts/stop_aws.sh             # asks before destroying anything
#   scripts/stop_aws.sh --yes       # no question
#   scripts/stop_aws.sh --dry-run   # shows what is running and the destroy plans
#
# Environment:
#   AWS_PROFILE   AWS CLI profile (default: code-keeper)
#   CK_ENV_FILE   file with the CK_* values (default: ~/.config/code-keeper.env)
#   TERRAFORM     Terraform command (default: terraform)
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

export AWS_PROFILE="${AWS_PROFILE:-code-keeper}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export TF_IN_AUTOMATION=1
CK_ENV_FILE="${CK_ENV_FILE:-${HOME}/.config/code-keeper.env}"
TERRAFORM="${TERRAFORM:-terraform}"
HOST_NAMES="code-keeper-gitlab,code-keeper-gitlab-runner"

DRY_RUN=0
ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option '${arg}' (see --help)" >&2
      exit 1
      ;;
  esac
done

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# Settings: the state backend and the Terraform variables come from the same
# private file the Ansible run uses. Destroy needs every variable without a
# default, although their values do not matter to it.
# ------------------------------------------------------------------------------
[ -r "${CK_ENV_FILE}" ] || die "cannot read ${CK_ENV_FILE} (set CK_ENV_FILE)"
# shellcheck source=/dev/null
source "${CK_ENV_FILE}"
for name in CK_TF_STATE_BUCKET CK_TF_STATE_REGION CK_TF_STATE_LOCK_TABLE \
  CK_TF_VAR_inventory_db_password CK_TF_VAR_billing_db_password CK_TF_VAR_rabbitmq_password \
  CK_DOCKERHUB_USERNAME CK_DOCKERHUB_TOKEN; do
  [ -n "${!name:-}" ] || die "${name} is not set in ${CK_ENV_FILE}"
done
for name in inventory_db_password billing_db_password rabbitmq_password; do
  source_name="CK_TF_VAR_${name}"
  export "TF_VAR_${name}=${!source_name}"
done
export TF_VAR_dockerhub_username="${CK_DOCKERHUB_USERNAME}"
export TF_VAR_dockerhub_token="${CK_DOCKERHUB_TOKEN}"
if [ -n "${CK_DOCKERHUB_REPO:-}" ]; then
  export TF_VAR_image_repository_prefix="docker.io/${CK_DOCKERHUB_REPO}"
fi

command -v "${TERRAFORM}" >/dev/null 2>&1 || die "${TERRAFORM} is not installed (set TERRAFORM)"
command -v aws >/dev/null 2>&1 || die "the AWS CLI is not installed"
aws sts get-caller-identity --query Account --output text >/dev/null ||
  die "the AWS CLI cannot sign in with profile ${AWS_PROFILE}"

# ------------------------------------------------------------------------------
# What is billed right now. Every count should be 0 after a run, except the two
# stopped hosts with their Elastic IPs and disks.
# ------------------------------------------------------------------------------
show_resources() {
  local hosts
  # shellcheck disable=SC2016 # backticks are JMESPath literals
  hosts="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${HOST_NAMES}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,State.Name]' --output text |
    awk '{printf "%s%s (%s, %s)", (NR > 1 ? ", " : ""), $1, $2, $3}')"
  printf '    %-24s %s\n' "GitLab hosts" "${hosts:-none}"
  printf '    %-24s %s\n' "Running instances" "$(aws ec2 describe-instances \
    --filters Name=instance-state-name,Values=pending,running \
    --query 'length(Reservations[].Instances[])' --output text)"
  printf '    %-24s %s\n' "NAT gateways" "$(aws ec2 describe-nat-gateways \
    --filter Name=state,Values=pending,available --query 'length(NatGateways)' --output text)"
  printf '    %-24s %s\n' "Load balancers" "$(aws elbv2 describe-load-balancers \
    --query 'length(LoadBalancers)' --output text)"
  printf '    %-24s %s\n' "RDS instances" "$(aws rds describe-db-instances \
    --query 'length(DBInstances)' --output text)"
  printf '    %-24s %s\n' "Amazon MQ brokers" "$(aws mq list-brokers \
    --query 'length(BrokerSummaries)' --output text)"
  printf '    %-24s %s\n' "ECS clusters" "$(aws ecs list-clusters \
    --query 'length(clusterArns)' --output text)"
  printf '    %-24s %s\n' "Elastic IPs" "$(aws ec2 describe-addresses \
    --query 'length(Addresses)' --output text)"
  printf '    %-24s %s\n' "EBS volumes (GB)" "$(aws ec2 describe-volumes \
    --query "join(', ', Volumes[].to_string(Size))" --output text)"
}

tf_init() {
  local out
  if ! out="$("${TERRAFORM}" -chdir="$1" init -input=false -reconfigure -no-color \
    -backend-config=backend.hcl \
    -backend-config="bucket=${CK_TF_STATE_BUCKET}" \
    -backend-config="region=${CK_TF_STATE_REGION}" \
    -backend-config="dynamodb_table=${CK_TF_STATE_LOCK_TABLE}" 2>&1)"; then
    printf '%s\n' "${out}" >&2
    return 1
  fi
}

# The load balancer has deletion protection on (infra/modules/compute/main.tf), so
# Terraform cannot delete it until that is turned off.
destroy_environment() {
  local env="$1" dir="infra/environments/$1" arn
  echo
  log "=== ${env}"
  tf_init "${dir}" || {
    log "terraform init failed in ${dir}"
    return 1
  }
  if [ "${DRY_RUN}" -eq 1 ]; then
    "${TERRAFORM}" -chdir="${dir}" plan -destroy -input=false -no-color |
      grep -E '^Plan:|^No changes' | sed 's/^/    /'
    return "${PIPESTATUS[0]}"
  fi
  arn="$(aws elbv2 describe-load-balancers --names "code-keeper-${env}-alb" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
  if [ -n "${arn}" ] && [ "${arn}" != "None" ]; then
    log "turning off the deletion protection of code-keeper-${env}-alb"
    aws elbv2 modify-load-balancer-attributes --load-balancer-arn "${arn}" \
      --attributes Key=deletion_protection.enabled,Value=false >/dev/null
  fi
  log "terraform destroy in ${dir} (RDS and Amazon MQ take 10 to 15 minutes)"
  "${TERRAFORM}" -chdir="${dir}" destroy -input=false -auto-approve
}

stop_hosts() {
  local ids
  ids="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${HOST_NAMES}" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[].Instances[].InstanceId' --output text | tr '\t' ' ')"
  echo
  if [ -z "${ids}" ]; then
    log "=== GitLab hosts: already stopped"
    return 0
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "=== GitLab hosts: would stop ${ids}"
    return 0
  fi
  log "=== GitLab hosts: stopping ${ids}"
  # shellcheck disable=SC2086 # one argument per instance ID
  aws ec2 stop-instances --instance-ids ${ids} >/dev/null
  # shellcheck disable=SC2086
  aws ec2 wait instance-stopped --instance-ids ${ids}
  log "GitLab and the runner are stopped"
}

echo "============================================================"
echo " code-keeper: stop the AWS charges (account $(aws sts get-caller-identity --query Account --output text), ${AWS_DEFAULT_REGION})"
[ "${DRY_RUN}" -eq 1 ] && echo " Dry run: nothing is destroyed or stopped"
echo "============================================================"
log "billed now:"
show_resources

if [ "${DRY_RUN}" -eq 0 ] && [ "${ASSUME_YES}" -eq 0 ]; then
  echo
  echo "This destroys production and staging (their databases included) and stops"
  echo "GitLab and the runner. GitLab's data stays on its disk."
  # Only opening the terminal is silenced; the question itself goes to stderr.
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    die "no terminal to ask on; run it in a terminal, or with --yes"
  fi
  printf "Type 'stop' to continue: " >&2
  read -r answer <&3 || answer=""
  exec 3<&-
  [ "${answer}" = "stop" ] || die "cancelled, nothing was changed"
fi

START=${SECONDS}
FAILED=()
for env in production staging; do
  destroy_environment "${env}" || FAILED+=("${env}")
done
# The hosts are stopped even when a destroy failed: they cost money too, and
# the destroy runs from this machine, not from GitLab.
stop_hosts

echo
log "billed now:"
show_resources
echo
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[FAILED] could not destroy: ${FAILED[*]}. Read the Terraform error above and run this script again."
  exit 1
fi
if [ "${DRY_RUN}" -eq 1 ]; then
  echo "[DRY RUN] run without --dry-run to destroy the environments and stop the hosts."
else
  echo "[SUCCESS] done in $(((SECONDS - START) / 60)) minutes. Only the stopped hosts' disks and Elastic IPs"
  echo "          are still billed. Bring everything back with scripts/restart_aws.sh."
fi
