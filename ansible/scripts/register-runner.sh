#!/usr/bin/env bash
# ==============================================================================
# Script: register-runner.sh
# Purpose: Installs and registers GitLab Runners with the Docker executor
# Usage: ./ansible/scripts/register-runner.sh [--ansible|--check|--syntax-check|--list-tasks|--direct]
#
# --ansible (default) runs playbooks/deploy-runners.yml. It creates the runner in
# GitLab through the API and writes the returned runner authentication token
# (glrt-...) into config.toml, so no token has to be passed in.
#
# --direct registers the gitlab-runner installed on THIS machine, using a runner
# authentication token created in GitLab (Admin > CI/CD > Runners > New instance
# runner) and passed in GITLAB_RUNNER_AUTH_TOKEN. The legacy registration token is
# disabled by default since GitLab 17.0 and is not used.
#
# Environment:
#   INVENTORY                inventory file (default: inventory/aws.ini from ansible/terraform)
#   GITLAB_EXTERNAL_URL      GitLab URL, for --direct
#   GITLAB_RUNNER_AUTH_TOKEN runner authentication token, for --direct
# ==============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${INVENTORY:-${BASE_DIR}/inventory/aws.ini}"
PLAYBOOK="${BASE_DIR}/playbooks/deploy-runners.yml"
MODE="${1:---ansible}"

echo "============================================================"
echo " [GitLab Runner] Registration Automation"
echo " Mode: ${MODE}"
echo "============================================================"

need_ansible() {
  if ! command -v ansible-playbook &>/dev/null; then
    echo "[ERROR] ansible-playbook not found. Install Ansible first, for example:" >&2
    echo "        pipx install --include-deps ansible   or   sudo apt install ansible" >&2
    exit 1
  fi
  cd "${BASE_DIR}"
}

case "${MODE}" in
  --syntax-check)
    need_ansible
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --syntax-check
    ;;
  --list-tasks)
    need_ansible
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --list-tasks
    ;;
  --check)
    need_ansible
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --check
    ;;
  --ansible)
    need_ansible
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}"
    ;;
  --direct)
    if ! command -v gitlab-runner &>/dev/null; then
      echo "[ERROR] 'gitlab-runner' executable not found on this machine."
      exit 1
    fi
    if [[ -z "${GITLAB_EXTERNAL_URL:-}" || "${GITLAB_RUNNER_AUTH_TOKEN:-}" != glrt-* ]]; then
      echo "ERROR: set GITLAB_EXTERNAL_URL and GITLAB_RUNNER_AUTH_TOKEN (a glrt-... runner authentication token)" >&2
      exit 1
    fi
    # With an authentication token, tags, locking and the access level are runner
    # settings in GitLab, so only connection and executor options are passed here.
    gitlab-runner register \
      --non-interactive \
      --url "${GITLAB_EXTERNAL_URL}" \
      --token "${GITLAB_RUNNER_AUTH_TOKEN}" \
      --name "docker-shared-runner-cli" \
      --executor "docker" \
      --docker-image "alpine:3.24.2" \
      --docker-privileged="false" \
      --docker-volumes "/cache"
    ;;
  *)
    echo "Unknown mode '${MODE}'. Allowed: --ansible, --check, --syntax-check, --list-tasks, --direct"
    exit 1
    ;;
esac

echo "[SUCCESS] Runner registration completed."
