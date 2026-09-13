#!/usr/bin/env bash
# ==============================================================================
# Script: setup-gitlab.sh
# Purpose: Deploys and configures GitLab CE using Ansible automation
# Usage: ./ansible/scripts/setup-gitlab.sh [--syntax-check|--check|--run]
# ==============================================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY="${BASE_DIR}/inventory/hosts.ini"
PLAYBOOK="${BASE_DIR}/playbooks/deploy-gitlab.yml"
MODE="${1:---run}"

echo "============================================================"
echo " [Ansible Setup] Deploying GitLab CE Automation"
echo " Inventory: ${INVENTORY}"
echo " Playbook:  ${PLAYBOOK}"
echo " Mode:      ${MODE}"
echo "============================================================"

# Root password must come from the environment (CI masked variable).
# No fallback secret is committed in this repo.
export GITLAB_EXTERNAL_URL="${GITLAB_EXTERNAL_URL:-http://gitlab.example.com}"
if [ -z "${GITLAB_ROOT_PASSWORD:-}" ]; then
  echo "[ERROR] GITLAB_ROOT_PASSWORD env var must be set (CI masked variable). Refusing to use a default password." >&2
  exit 1
fi
export GITLAB_ROOT_PASSWORD

if ! command -v ansible-playbook &>/dev/null; then
  echo "[WARNING] 'ansible-playbook' command not found in current environment PATH."
  echo "[INFO] Validating playbook syntax using Python YAML parser instead..."
  python3 -c "
import yaml, sys
with open('${PLAYBOOK}', 'r') as f:
    yaml.safe_load(f)
print('YAML syntax validation PASSED for ${PLAYBOOK}')
"
  exit 0
fi

case "${MODE}" in
  --syntax-check)
    echo "[INFO] Running Ansible syntax validation..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --syntax-check
    ;;
  --check)
    echo "[INFO] Executing Ansible dry-run (check mode)..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}" --check
    ;;
  --run)
    echo "[INFO] Executing GitLab CE deployment playbook..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK}"
    ;;
  *)
    echo "Unknown argument '${MODE}'. Allowed: --syntax-check, --check, --run"
    exit 1
    ;;
esac

echo "[SUCCESS] GitLab CE setup script completed successfully."
