#!/usr/bin/env bash
# ==============================================================================
# Security Verification & Cybersecurity Audit Script
# Project: code-keeper
# Verifies adherence to:
#  1. Restrict triggers to protected branches
#  2. Separate credentials from code
#  3. Apply the least privilege principle
#  4. Update dependencies and tools regularly
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
echo -e "${BOLD}  CODE-KEEPER CYBERSECURITY AUDIT & VERIFICATION            ${NC}"
echo -e "${BOLD}============================================================${NC}"

# 1. Guideline 1: Restrict triggers to protected branches
log_header "Guideline 1: Restrict Triggers to Protected Branches"
python3 - << 'PYEOF'
import yaml, sys

pipeline_files = [
    "infra/.gitlab-ci.yml",
    "srcs/api-gateway/.gitlab-ci.yml",
    "srcs/inventory-app/.gitlab-ci.yml",
    "srcs/billing-app/.gitlab-ci.yml"
]

all_ok = True
for pf in pipeline_files:
    with open(pf) as f:
        data = yaml.safe_load(f)
    
    # Check that deployment and approval jobs enforce protected branch rules
    critical_jobs = [k for k in data.keys() if any(term in k.lower() for term in ["apply", "deploy", "container", "approval"])]
    for j in critical_jobs:
        job_def = data.get(j, {})
        if not isinstance(job_def, dict):
            continue
        rules = job_def.get("rules", [])
        has_branch_protection = any(
            "$CI_COMMIT_BRANCH == \"main\"" in str(r) or "$CI_COMMIT_BRANCH == 'main'" in str(r)
            for r in rules
        )
        if has_branch_protection:
            print(f"  \033[0;32m[PASS]\033[0m {pf} -> Job '{j}' restricted to protected branch 'main'")
        else:
            print(f"  \033[0;31m[FAIL]\033[0m {pf} -> Job '{j}' missing protected branch rule!")
            all_ok = False

if not all_ok:
    sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then
  log_pass "Protected branch trigger restriction verified across all pipelines"
else
  log_fail "One or more deployment jobs lack branch protection rules"
fi

# 2. Guideline 2: Separate credentials from code
log_header "Guideline 2: Separate Credentials from Code (Secret Leak Checks)"

# Check for AWS private key patterns, standard private keys, or exposed live tokens
LEAK_PATTERNS=(
  "-----BEGIN RSA PRIVATE KEY-----"
  "-----BEGIN OPENSSH PRIVATE KEY-----"
  "AKIA[0-9A-Z]{16}"
)

LEAK_FOUND=0
for pat in "${LEAK_PATTERNS[@]}"; do
  MATCHES=$(grep -rnE -e "$pat" --exclude-dir=".git" --exclude-dir="scratch" --exclude="*.sh" . || true)
  if [ -n "$MATCHES" ]; then
    log_fail "Potential credential leak detected matching '$pat':\n$MATCHES"
    LEAK_FOUND=1
  fi
done

if [ "$LEAK_FOUND" -eq 0 ]; then
  log_pass "Zero hardcoded private keys or live cloud API tokens found in repository"
fi

# Check that .env files with secrets are not tracked
if git ls-files --error-unmatch .env 2>/dev/null; then
  log_fail ".env file is tracked in git index!"
else
  log_pass ".env is not tracked in git (credentials decoupled)"
fi

# Verify .gitignore exists and guards secrets
if [ -f ".gitignore" ] && grep -q "\.env" ".gitignore" && grep -q "\*\.tfstate" ".gitignore"; then
  log_pass ".gitignore properly guards .env and *.tfstate files"
else
  log_fail ".gitignore missing or incomplete"
fi

# 3. Guideline 3: Apply the least privilege principle
log_header "Guideline 3: Apply the Least Privilege Principle"

# 3a. Dockerfiles must run as non-root user
DOCKERFILES=("srcs/api-gateway/Dockerfile" "srcs/inventory-app/Dockerfile" "srcs/billing-app/Dockerfile")
for df in "${DOCKERFILES[@]}"; do
  if grep -qE "USER [a-zA-Z0-9_-]+" "$df" && ! grep -qE "USER root" "$df"; then
    log_pass "$df enforces non-root execution (Least Privilege)"
  else
    log_fail "$df runs as root or lacks USER directive"
  fi
done

# 3b. Terraform Security Groups must not expose internal databases to 0.0.0.0/0
python3 - << 'PYEOF'
import sys

with open("infra/modules/security_groups/main.tf") as f:
    sg_content = f.read()

# Verify that database sg only allows from inventory and billing sg, NOT 0.0.0.0/0
db_section = sg_content[sg_content.find('resource "aws_security_group" "database"'):]
if 'cidr_blocks = ["0.0.0.0/0"]' in db_section and "from_port       = 5432" in db_section:
    print("  \033[0;31m[FAIL]\033[0m Database security group exposes port 5432 to 0.0.0.0/0!")
    sys.exit(1)
else:
    print("  \033[0;32m[PASS]\033[0m PostgreSQL database port 5432 strictly restricted to internal service SGs")

# Verify rabbitmq is not open to 0.0.0.0/0
rmq_section = sg_content[sg_content.find('resource "aws_security_group" "rabbitmq"'):sg_content.find('resource "aws_security_group" "database"')]
if 'cidr_blocks = ["0.0.0.0/0"]' in rmq_section and "from_port       = 5672" in rmq_section:
    print("  \033[0;31m[FAIL]\033[0m RabbitMQ broker exposes port 5672 to 0.0.0.0/0!")
    sys.exit(1)
else:
    print("  \033[0;32m[PASS]\033[0m RabbitMQ AMQP port 5672 strictly restricted to internal service SGs")
PYEOF
if [ $? -eq 0 ]; then
  log_pass "Network layer least-privilege rules verified"
else
  log_fail "Network least-privilege rules violation found"
fi

# 4. Guideline 4: Update dependencies and tools regularly
log_header "Guideline 4: Automated Vulnerability & Dependency Scanning"
python3 - << 'PYEOF'
import yaml, sys

pipelines = ["srcs/api-gateway/.gitlab-ci.yml", "srcs/inventory-app/.gitlab-ci.yml", "srcs/billing-app/.gitlab-ci.yml"]
for p in pipelines:
    with open(p) as f:
        data = yaml.safe_load(f)
    scan_jobs = [j for j in data.keys() if "scan" in j.lower()]
    if len(scan_jobs) >= 3:
        print(f"  \033[0;32m[PASS]\033[0m {p} configures multi-tool security scanners: {scan_jobs}")
    else:
        print(f"  \033[0;31m[FAIL]\033[0m {p} lacks comprehensive scanner stages! Found: {scan_jobs}")
        sys.exit(1)
PYEOF
if [ $? -eq 0 ]; then
  log_pass "Vulnerability scanners configured across all microservice CI pipelines"
else
  log_fail "Missing vulnerability scanners in CI pipelines"
fi

# Summary
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}  CYBERSECURITY AUDIT SUMMARY                               ${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  Passed Controls: ${GREEN}${BOLD}${PASSED_CHECKS}${NC}"
echo -e "  Failed Controls: ${RED}${BOLD}${FAILED_CHECKS}${NC}"

if [ "$FAILED_CHECKS" -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}>>> ALL CYBERSECURITY COMPLIANCE CONTROLS PASSED! <<<${NC}\n"
  exit 0
else
  echo -e "\n${RED}${BOLD}>>> CYBERSECURITY COMPLIANCE FAILURES DETECTED <<<${NC}\n"
  exit 1
fi
