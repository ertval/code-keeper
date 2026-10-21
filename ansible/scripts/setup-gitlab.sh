#!/usr/bin/env bash
# ==============================================================================
# Script: setup-gitlab.sh
# Purpose: Deploys and configures GitLab CE using Ansible automation
# Usage: ./ansible/scripts/setup-gitlab.sh [--syntax-check|--check|--list-tasks|--run]
#
# Environment:
#   GITLAB_ROOT_PASSWORD  required for --check and --run (at least 12 characters)
#   CK_<KEY>              optional CI/CD variable values, see roles/gitlab/defaults
#   INVENTORY             inventory file (default: inventory/aws.ini from ansible/terraform)
# ==============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${INVENTORY:-${BASE_DIR}/inventory/aws.ini}"
PLAYBOOK="${BASE_DIR}/playbooks/deploy-gitlab.yml"
MODE="${1:---run}"

echo "============================================================"
echo " [Ansible Setup] Deploying GitLab CE Automation"
echo " Inventory: ${INVENTORY}"
echo " Playbook:  ${PLAYBOOK}"
echo " Mode:      ${MODE}"
echo "============================================================"

if ! command -v ansible-playbook &>/dev/null; then
  echo "[ERROR] ansible-playbook not found. Install Ansible first, for example:" >&2
  echo "        pipx install --include-deps ansible   or   sudo apt install ansible" >&2
  exit 1
fi

cd "${BASE_DIR}"

case "${MODE}" in
  --syntax-check)
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --syntax-check
    ;;
  --list-tasks)
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --list-tasks
    ;;
  --check|--run)
    # Root password must come from the environment; no fallback secret is committed.
    if [ -z "${GITLAB_ROOT_PASSWORD:-}" ] || [ "${#GITLAB_ROOT_PASSWORD}" -lt 12 ]; then
      echo "[ERROR] Set GITLAB_ROOT_PASSWORD (at least 12 characters). Refusing to use a default password." >&2
      exit 1
    fi
    export GITLAB_ROOT_PASSWORD
    if [ "${MODE}" = "--check" ]; then
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --check
    else
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}"
    fi
    ;;
  *)
    echo "Unknown argument '${MODE}'. Allowed: --syntax-check, --list-tasks, --check, --run"
    exit 1
    ;;
esac

echo "[SUCCESS] GitLab CE setup script completed successfully."
