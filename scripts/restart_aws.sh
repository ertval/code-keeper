#!/usr/bin/env bash
# ==============================================================================
# Script: restart_aws.sh
# Purpose: Brings code-keeper back after scripts/stop_aws.sh, ready for the audit:
#            1. starts the GitLab and runner hosts and waits for GitLab and for
#               the runner to come online
#            2. runs the infra pipeline on main, which creates staging, and gives
#               its production approval (the pipeline's one manual job), so
#               production is created next
#            3. runs the three app pipelines as soon as staging exists, and gives
#               their production approvals once production exists
#            4. checks /health, /api/movies and /docs through both load balancers
#          About an hour from stopped. Running it again is safe: on environments
#          that exist, the pipelines change nothing and redeploy the same images.
#
# Usage:
#   scripts/restart_aws.sh               # everything
#   scripts/restart_aws.sh --hosts-only  # only GitLab and the runner, for example to
#                                        # prepare accounts (about $0.15 an hour)
#   scripts/restart_aws.sh --check       # start nothing: check that AWS, the hosts,
#                                        # GitLab, the runner and the projects are ready
#
# The API calls use a root token that exists only in this script's memory. It is
# made over SSH with gitlab-rails, as the Ansible role does, expires after a day
# and is revoked when the script ends. SSH is open only to admin_cidrs: if your
# public IP changed, the script prints the command that updates it. Setting
# GITLAB_API_TOKEN (a root token with the api scope) skips the SSH step.
#
# Environment:
#   AWS_PROFILE       AWS CLI profile (default: code-keeper)
#   GITLAB_API_TOKEN  optional root token with the api scope
#   GITLAB_GROUP      group of the four projects (default: code-keeper)
#   SSH_KEY           private key for the hosts (default: ~/.ssh/code-keeper)
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export AWS_PROFILE="${AWS_PROFILE:-code-keeper}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
GITLAB_GROUP="${GITLAB_GROUP:-code-keeper}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/code-keeper}"
APPS=(api-gateway inventory-app billing-app)
POLL_SECONDS=20
PIPELINE_TIMEOUT_MINUTES=120

GITLAB_URL=""
API_TOKEN="${GITLAB_API_TOKEN:-}"
TOKEN_CREATED=0
INFRA_STAGING_DONE=0
INFRA_PRODUCTION_DONE=0
declare -A PIPE_ID=() PIPE_URL=() PIPE_DONE=() APPROVED=() LAST_LINE=()

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# GitLab API. The token reaches curl through a file descriptor, never on a
# command line, and failures print GitLab's own message.
# ------------------------------------------------------------------------------
api() {
  curl -sS --fail-with-body --max-time 30 -X "$1" \
    -H @<(printf 'PRIVATE-TOKEN: %s\n' "${API_TOKEN}") \
    "${GITLAB_URL}/api/v4$2"
}

project_ref() { jq -rn --arg path "${GITLAB_GROUP}/$1" '$path | @uri'; }

job_field() { # <jobs json> <job name> <field>
  jq -r --arg name "$2" --arg field "$3" '[.[] | select(.name == $name)][0][$field] // ""' <<<"$1"
}

# ------------------------------------------------------------------------------
# Hosts
# ------------------------------------------------------------------------------
host_field() { # <Name tag> <field>
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[0].Instances[0].$2" --output text
}

start_hosts() {
  local name id state ids=()
  for name in code-keeper-gitlab code-keeper-gitlab-runner; do
    id="$(host_field "${name}" InstanceId)"
    [ -n "${id}" ] && [ "${id}" != "None" ] ||
      die "there is no ${name} instance: the hosts were destroyed, so follow docs/AWS_SETUP.md step 12 instead"
    state="$(host_field "${name}" State.Name)"
    log "${name} (${id}) is ${state}"
    if [ "${state}" = "stopping" ]; then
      aws ec2 wait instance-stopped --instance-ids "${id}"
      state="stopped"
    fi
    if [ "${state}" = "stopped" ]; then
      [ "${MODE}" = "check" ] && die "${name} is stopped; --check starts nothing"
      aws ec2 start-instances --instance-ids "${id}" >/dev/null
      log "${name} starting"
    fi
    ids+=("${id}")
  done
  aws ec2 wait instance-running --instance-ids "${ids[@]}"
  GITLAB_IP="$(host_field code-keeper-gitlab PublicIpAddress)"
  GITLAB_URL="http://${GITLAB_IP}"
}

wait_for_gitlab() {
  local deadline=$((SECONDS + 900)) code
  log "waiting for GitLab at ${GITLAB_URL} (it takes a few minutes after a start)"
  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${GITLAB_URL}/users/sign_in" || true)"
    [ "${code}" = "200" ] && break
    [ "${SECONDS}" -lt "${deadline}" ] || die "GitLab did not answer within 15 minutes (last HTTP code ${code})"
    sleep 15
  done
  log "GitLab is up"
}

# ------------------------------------------------------------------------------
# Temporary API token. gitlab-rails generates the value and prints it; it comes
# back over SSH into a variable, and is never written to a file or an argument.
# The script file holds no secret, and git must be able to read it.
# ------------------------------------------------------------------------------
token_ruby() {
  cat <<'RUBY'
user = User.find_by_username('root')
name = 'code-keeper-restart'
user.personal_access_tokens.active.where(name: name).each(&:revoke!)
value = "glpat-#{SecureRandom.alphanumeric(40)}"
pat = user.personal_access_tokens.create!(scopes: ['api'], name: name, expires_at: 1.day.from_now)
pat.set_token(value)
pat.save!
puts "CK_TOKEN=#{value}"
RUBY
}

get_api_token() {
  local out rc=0 my_ip
  if [ -n "${API_TOKEN}" ]; then
    log "using GITLAB_API_TOKEN"
    return 0
  fi
  log "making a temporary root API token over SSH (gitlab-rails takes a few minutes to start)"
  out="$(token_ruby | ssh -i "${SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new "ubuntu@${GITLAB_IP}" \
    'f=$(mktemp) && cat > "$f" && chmod 644 "$f" && sudo gitlab-rails runner "$f"; rc=$?; rm -f "$f"; exit $rc')" || rc=$?
  if [ "${rc}" -eq 255 ]; then
    my_ip="$(curl -s --max-time 5 https://checkip.amazonaws.com || echo '<your public IP>')"
    echo "SSH to ${GITLAB_IP} failed. SSH is open only to admin_cidrs; if your public IP (${my_ip})" >&2
    echo "changed, allow it (this only updates the security groups):" >&2
    echo "  terraform -chdir=ansible/terraform apply -var 'admin_cidrs=[\"${my_ip}/32\"]'" >&2
    echo "Or create a token with the api scope as root (Edit profile > Access tokens) and run:" >&2
    echo "  GITLAB_API_TOKEN=<token> $0" >&2
    return 1
  fi
  [ "${rc}" -eq 0 ] || {
    echo "gitlab-rails failed on ${GITLAB_IP} (exit ${rc}); its error is above" >&2
    return 1
  }
  API_TOKEN="$(printf '%s\n' "${out}" | sed -n 's/^CK_TOKEN=//p' | tail -n 1)"
  [ -n "${API_TOKEN}" ] || {
    echo "gitlab-rails did not print a token" >&2
    return 1
  }
  TOKEN_CREATED=1
}

revoke_api_token() {
  [ "${TOKEN_CREATED}" -eq 1 ] || return 0
  if api DELETE /personal_access_tokens/self >/dev/null 2>&1; then
    log "temporary API token revoked"
  else
    log "could not revoke the temporary API token; it expires within a day"
  fi
  TOKEN_CREATED=0
}

check_gitlab() {
  local admin project branch deadline=$((SECONDS + 600)) runners
  admin="$(api GET /user | jq -r '.is_admin')" || die "GitLab refused the API token"
  [ "${admin}" = "true" ] || die "the API token does not belong to an administrator"
  for project in infra "${APPS[@]}"; do
    branch="$(api GET "/projects/$(project_ref "${project}")" | jq -r '.default_branch')" ||
      die "project ${GITLAB_GROUP}/${project} not found (publish it with scripts/publish_repos.sh)"
    [ "${branch}" = "main" ] || die "${GITLAB_GROUP}/${project} has no main branch"
  done
  log "projects found: infra ${APPS[*]}"
  log "waiting for an online instance runner"
  while :; do
    runners="$(api GET '/runners/all?type=instance_type&status=online&paused=false' |
      jq -r '[.[].description] | join(", ")')"
    [ -n "${runners}" ] && break
    [ "${SECONDS}" -lt "${deadline}" ] ||
      die "no runner came online within 10 minutes; on the runner host check: sudo gitlab-runner status"
    sleep 15
  done
  log "runner online: ${runners}"
}

# ------------------------------------------------------------------------------
# Pipelines. One loop follows all four: it starts the app pipelines once the
# infra pipeline has applied staging, plays each production approval job, and
# holds the app approvals until production infrastructure exists.
# ------------------------------------------------------------------------------
start_pipeline() {
  local json
  json="$(api POST "/projects/$(project_ref "$1")/pipeline?ref=main")" ||
    die "could not start the $1 pipeline: ${json}"
  PIPE_ID[$1]="$(jq -r '.id' <<<"${json}")"
  PIPE_URL[$1]="$(jq -r '.web_url' <<<"${json}")"
  log "$1: pipeline started, ${PIPE_URL[$1]}"
}

approve_if_ready() {
  local project="$1" jobs="$2" job="$1:approval:production" id
  [ -z "${APPROVED[${project}]:-}" ] || return 0
  [ "$(job_field "${jobs}" "${job}" status)" = "manual" ] || return 0
  [ "${project}" = "infra" ] || [ "${INFRA_PRODUCTION_DONE}" -eq 1 ] || return 0
  id="$(job_field "${jobs}" "${job}" id)"
  api POST "/projects/$(project_ref "${project}")/jobs/${id}/play" >/dev/null ||
    die "could not run ${job}"
  APPROVED[${project}]=1
  log "${project}: production approved (${job})"
}

report() { # prints a line only when the status or the running jobs change
  local project="$1" status="$2" jobs="$3" running line
  running="$(jq -r '[.[] | select(.status == "running") | .name] | join(", ")' <<<"${jobs}")"
  line="${status}${running:+: ${running}}"
  if [ "${LAST_LINE[${project}]:-}" != "${line}" ]; then
    LAST_LINE[${project}]="${line}"
    log "${project}: ${line}"
  fi
}

run_pipelines() {
  local deadline=$((SECONDS + PIPELINE_TIMEOUT_MINUTES * 60)) project ref status jobs all_done app
  start_pipeline infra
  while :; do
    all_done=1
    for project in infra "${APPS[@]}"; do
      if [ -z "${PIPE_ID[${project}]:-}" ]; then
        all_done=0
        continue
      fi
      [ -z "${PIPE_DONE[${project}]:-}" ] || continue
      ref="$(project_ref "${project}")"
      if ! status="$(api GET "/projects/${ref}/pipelines/${PIPE_ID[${project}]}" | jq -r '.status')" ||
        ! jobs="$(api GET "/projects/${ref}/pipelines/${PIPE_ID[${project}]}/jobs?per_page=100")"; then
        log "${project}: GitLab did not answer, trying again"
        all_done=0
        continue
      fi
      if [ "${project}" = "infra" ]; then
        [ "$(job_field "${jobs}" infra:apply:staging status)" != "success" ] || INFRA_STAGING_DONE=1
        [ "$(job_field "${jobs}" infra:apply:production status)" != "success" ] || INFRA_PRODUCTION_DONE=1
      fi
      approve_if_ready "${project}" "${jobs}"
      report "${project}" "${status}" "${jobs}"
      case "${status}" in
        success) PIPE_DONE[${project}]=1 ;;
        failed | canceled | skipped)
          jq -r '.[] | select(.status == "failed" and .allow_failure == false) | "  failed job \(.name): \(.web_url)"' <<<"${jobs}" >&2
          die "the ${project} pipeline ${status}: ${PIPE_URL[${project}]}. Fix it, then retry the job in GitLab or run this script again."
          ;;
        *) all_done=0 ;;
      esac
    done
    if [ "${INFRA_STAGING_DONE}" -eq 1 ] && [ -z "${PIPE_ID[${APPS[0]}]:-}" ]; then
      for app in "${APPS[@]}"; do start_pipeline "${app}"; done
      all_done=0
    fi
    [ "${all_done}" -eq 0 ] || break
    [ "${SECONDS}" -lt "${deadline}" ] ||
      die "the pipelines were still running after ${PIPELINE_TIMEOUT_MINUTES} minutes; follow them in GitLab"
    sleep "${POLL_SECONDS}"
  done
  log "all four pipelines passed"
}

# ------------------------------------------------------------------------------
# The app's own endpoints through each environment's load balancer
# ------------------------------------------------------------------------------
check_endpoints() {
  local env dns path code try bad=0
  for env in staging production; do
    dns="$(aws elbv2 describe-load-balancers --names "code-keeper-${env}-alb" \
      --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || true)"
    if [ -z "${dns}" ] || [ "${dns}" = "None" ]; then
      log "${env}: no load balancer"
      bad=1
      continue
    fi
    ALB_URL[${env}]="http://${dns}"
    for path in /health /api/movies /docs; do
      for try in 1 2 3 4 5 6; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${dns}${path}" || true)"
        [ "${code}" = "200" ] && break
        [ "${try}" -lt 6 ] && sleep 10
      done
      log "${env} ${path}: ${code}"
      [ "${code}" = "200" ] || bad=1
    done
  done
  return "${bad}"
}

main() {
  MODE="all"
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --hosts-only) MODE="hosts" ;;
      --check) MODE="check" ;;
      -h | --help)
        sed -n '2,33p' "$0"
        exit 0
        ;;
      *) die "unknown option '${arg}' (see --help)" ;;
    esac
  done
  cd "${ROOT_DIR}"
  for tool in aws curl jq ssh; do
    command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not installed"
  done
  declare -gA ALB_URL=()
  trap revoke_api_token EXIT

  echo "============================================================"
  echo " code-keeper: restart for the audit (account $(aws sts get-caller-identity --query Account --output text), ${AWS_DEFAULT_REGION})"
  [ "${MODE}" = "check" ] && echo " Check only: nothing is started"
  echo "============================================================"
  local start=${SECONDS}

  start_hosts
  wait_for_gitlab
  if ! get_api_token; then
    [ "${MODE}" = "hosts" ] || die "no API token, so no pipeline was started"
    log "GitLab is up, but the runner was not checked"
    exit 0
  fi
  check_gitlab

  case "${MODE}" in
    check)
      echo
      echo "[READY] scripts/restart_aws.sh would now run the infra pipeline, then the three app"
      echo "        pipelines, and approve production in each."
      return 0
      ;;
    hosts)
      echo
      echo "[SUCCESS] GitLab ${GITLAB_URL} and the runner are up; no environment was created."
      echo "          Sign in as root with GITLAB_ROOT_PASSWORD from ~/.config/code-keeper.env."
      return 0
      ;;
  esac

  run_pipelines
  revoke_api_token
  echo
  local ok=0
  check_endpoints || ok=1
  echo
  echo "============================================================"
  echo " GitLab      ${GITLAB_URL}  (root, GITLAB_ROOT_PASSWORD in ~/.config/code-keeper.env)"
  echo " Staging     ${ALB_URL[staging]:-none}"
  echo " Production  ${ALB_URL[production]:-none}"
  echo " Took $(((SECONDS - start) / 60)) minutes. Stop the charges again with scripts/stop_aws.sh."
  echo "============================================================"
  [ "${ok}" -eq 0 ] || die "an endpoint did not answer 200 (see above)"
}

# Run only when executed, so the functions can be sourced and tested.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
