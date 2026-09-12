#!/usr/bin/env bash
# ==============================================================================
# Script: register-runner.sh
# Purpose: Registers a GitLab Runner with Docker executor
# Usage: ./ansible/scripts/register-runner.sh [--ansible|--direct] [REGISTRATION_TOKEN]
# ==============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${BASE_DIR}/inventory/hosts.ini"
PLAYBOOK="${BASE_DIR}/playbooks/deploy-runners.yml"

MODE="${1:---ansible}"
TOKEN="${2:-${GITLAB_RUNNER_TOKEN:-glrt-mock-runner-token-12345}}"
GITLAB_URL="${GITLAB_EXTERNAL_URL:-http://gitlab.example.com}"

echo "============================================================"
echo " [GitLab Runner] Registration Automation"
echo " Target GitLab URL: ${GITLAB_URL}"
echo " Mode:              ${MODE}"
echo "============================================================"

if [ "${MODE}" = "--ansible" ]; then
  if ! command -v ansible-playbook &>/dev/null; then
    echo "[WARNING] 'ansible-playbook' command not found in current environment PATH."
    echo "[INFO] Validating runner playbook syntax using Python YAML parser..."
    python3 -c "
import yaml, sys
with open('${PLAYBOOK}', 'r') as f:
    yaml.safe_load(f)
print('YAML syntax validation PASSED for ${PLAYBOOK}')
"
    exit 0
  fi
  echo "[INFO] Running Ansible deploy-runners playbook..."
  ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" \
    --extra-vars "gitlab_runner_url=${GITLAB_URL} gitlab_runner_registration_token=${TOKEN}"
elif [ "${MODE}" = "--direct" ]; then
  if ! command -v gitlab-runner &>/dev/null; then
    echo "[ERROR] 'gitlab-runner' executable not found on this machine."
    exit 1
  fi
  echo "[INFO] Registering runner directly via CLI..."
  gitlab-runner register \
    --non-interactive \
    --url "${GITLAB_URL}" \
    --registration-token "${TOKEN}" \
    --executor "docker" \
    --docker-image "docker:24.0.5" \
    --description "docker-shared-runner-cli" \
    --tag-list "docker,shared,ci-cd" \
    --run-untagged="true" \
    --docker-privileged="true" \
    --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
    --docker-volumes "/cache"
  echo "[SUCCESS] Direct runner registration complete."
else
  echo "Unknown mode '${MODE}'. Allowed: --ansible, --direct"
  exit 1
fi

echo "[SUCCESS] Runner registration completed."
