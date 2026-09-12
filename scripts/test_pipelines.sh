#!/usr/bin/env bash
# ==============================================================================
# Pipeline Verification & Simulation Script
# Project: code-keeper
# Validates: All GitLab CI pipelines, Ansible playbooks, Dockerfiles, and Python code
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASSED_CHECKS=0
FAILED_CHECKS=0

log_header() {
  echo -e "\n${BLUE}${BOLD}>>> $1${NC}"
}

log_pass() {
  echo -e "  [${GREEN}PASS${NC}] $1"
  PASSED_CHECKS=$((PASSED_CHECKS + 1))
}

log_fail() {
  echo -e "  [${RED}FAIL${NC}] $1"
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
}

log_info() {
  echo -e "  [${YELLOW}INFO${NC}] $1"
}

echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  CODE-KEEPER PIPELINE & INFRASTRUCTURE TEST SUITE          ${NC}"
echo -e "${BOLD}============================================================${NC}"

# 1. Directory Structure Verification
log_header "1. Validating Repository & Component Structure"
REQUIRED_DIRS=(
  "ansible/inventory"
  "ansible/playbooks"
  "ansible/roles/gitlab"
  "ansible/roles/gitlab_runner"
  "ansible/scripts"
  "infra/environments/staging"
  "infra/environments/production"
  "infra/modules/vpc"
  "infra/modules/security_groups"
  "infra/modules/rds"
  "infra/modules/rabbitmq"
  "infra/modules/compute"
  "api-gateway/app"
  "api-gateway/tests"
  "inventory-app/app"
  "inventory-app/tests"
  "billing-app/app"
  "billing-app/tests"
  "scripts"
)

for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    log_pass "Directory exists: $dir"
  else
    log_fail "Missing directory: $dir"
  fi
done

# 2. YAML Syntax Validation
log_header "2. Validating YAML Syntax across Playbooks and Pipelines"
python3 - << 'PYEOF'
import glob, yaml, sys

yaml_files = (
    glob.glob('ansible/**/*.yml', recursive=True) +
    glob.glob('ansible/**/*.yaml', recursive=True) +
    glob.glob('**/.gitlab-ci.yml', recursive=True) +
    glob.glob('api-gateway/*.yaml', recursive=True)
)

errors = 0
for yf in sorted(set(yaml_files)):
    try:
        with open(yf, 'r') as f:
            yaml.safe_load(f)
        print(f"  \033[0;32m[PASS]\033[0m Valid YAML: {yf}")
    except Exception as e:
        print(f"  \033[0;31m[FAIL]\033[0m Invalid YAML {yf}: {e}")
        errors += 1

if errors > 0:
    sys.exit(1)
PYEOF

if [ $? -eq 0 ]; then
  log_pass "All YAML files parsed successfully without errors"
else
  log_fail "YAML validation failed on one or more files"
fi

# 3. Infrastructure Pipeline Stage Checks
log_header "3. Validating Infrastructure Pipeline Stages (infra/.gitlab-ci.yml)"
python3 - << 'PYEOF'
import yaml, sys

with open("infra/.gitlab-ci.yml") as f:
    data = yaml.safe_load(f)

expected_stages = ["Init", "Validate", "Plan", "Apply to Staging", "Approval", "Apply to Production"]
actual_stages = data.get("stages", [])

if actual_stages == expected_stages:
    print(f"  \033[0;32m[PASS]\033[0m infra/.gitlab-ci.yml stages match exact requirements: {actual_stages}")
else:
    print(f"  \033[0;31m[FAIL]\033[0m Stages mismatch! Expected: {expected_stages}, Got: {actual_stages}")
    sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then log_pass "Infra stages verified"; else log_fail "Infra stages verification failed"; fi

# 4. Microservice Pipeline Stage Checks
log_header "4. Validating Microservice Pipeline Stages (CI/CD)"
MICROSERVICES=("api-gateway" "inventory-app" "billing-app")
for ms in "${MICROSERVICES[@]}"; do
  python3 - << PYEOF
import yaml, sys

ms = "${ms}"
with open(f"{ms}/.gitlab-ci.yml") as f:
    data = yaml.safe_load(f)

expected_stages = ["Build", "Test", "Scan", "Containerization", "Deploy to Staging", "Approval", "Deploy to Production"]
actual_stages = data.get("stages", [])

if actual_stages == expected_stages:
    print(f"  \033[0;32m[PASS]\033[0m {ms}/.gitlab-ci.yml stages verified: {actual_stages}")
else:
    print(f"  \033[0;31m[FAIL]\033[0m {ms}/.gitlab-ci.yml stages mismatch! Got: {actual_stages}")
    sys.exit(1)
PYEOF
  if [ $? -eq 0 ]; then log_pass "$ms pipeline stages verified"; else log_fail "$ms pipeline stages failed"; fi
done

# 5. Shell Script Syntax Validation
log_header "5. Validating Shell Script Syntax (bash -n)"
SCRIPTS=(
  "ansible/scripts/setup-gitlab.sh"
  "ansible/scripts/register-runner.sh"
  "scripts/test_pipelines.sh"
  "scripts/verify_security.sh"
)
for script in "${SCRIPTS[@]}"; do
  if [ -f "$script" ]; then
    if bash -n "$script"; then
      log_pass "Syntax OK: $script"
    else
      log_fail "Syntax ERROR: $script"
    fi
  fi
done

# 6. Python Bytecode Compilation Checks
log_header "6. Validating Python Code Compilation across Microservices"
if python3 -m compileall -q api-gateway inventory-app billing-app; then
  log_pass "Python bytecode compilation succeeded for all microservices"
else
  log_fail "Python syntax / compilation error encountered"
fi

# 7. Dockerfile Best Practices Check
log_header "7. Validating Dockerfile Hardening & Non-Root Execution"
DOCKERFILES=("api-gateway/Dockerfile" "inventory-app/Dockerfile" "billing-app/Dockerfile")
for df in "${DOCKERFILES[@]}"; do
  if grep -q "USER appuser" "$df"; then
    log_pass "$df enforces non-root unprivileged execution (USER appuser)"
  else
    log_fail "$df does not specify non-root execution"
  fi

  if grep -q "HEALTHCHECK" "$df"; then
    log_pass "$df defines container HEALTHCHECK probe"
  else
    log_fail "$df missing HEALTHCHECK probe"
  fi
done

# 8. Terraform Staging & Production Parity
log_header "8. Validating Terraform Staging vs Production Structural Parity"
python3 - << 'PYEOF'
import os, sys

staging_files = set(os.listdir("infra/environments/staging"))
production_files = set(os.listdir("infra/environments/production"))

expected = {"main.tf", "variables.tf", "outputs.tf", "terraform.tfvars"}

if staging_files.issuperset(expected) and production_files.issuperset(expected):
    print("  \033[0;32m[PASS]\033[0m Both staging and production environments define identical file contracts.")
else:
    print(f"  \033[0;31m[FAIL]\033[0m Missing config files in environments! Staging: {staging_files}, Prod: {production_files}")
    sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then log_pass "Terraform parity verified"; else log_fail "Terraform parity failed"; fi

# Summary
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}  PIPELINE VALIDATION SUMMARY                               ${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  Total Checks Passed: ${GREEN}${BOLD}${PASSED_CHECKS}${NC}"
echo -e "  Total Checks Failed: ${RED}${BOLD}${FAILED_CHECKS}${NC}"

if [ "$FAILED_CHECKS" -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}>>> ALL CODE-KEEPER PIPELINE TESTS PASSED! <<<${NC}\n"
  exit 0
else
  echo -e "\n${RED}${BOLD}>>> ONE OR MORE VERIFICATION CHECKS FAILED <<<${NC}\n"
  exit 1
fi
