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

# ------------------------------------------------------------------------------
# Assertion stream protocol
#
# An analysis engine (python3 heredoc) writes one record per line on stdin:
#   PASS|<detail>   -> log_pass, increments PASSED_CHECKS
#   FAIL|<detail>   -> log_fail, increments FAILED_CHECKS
#   DONE|<ok|error> -> terminal sentinel proving the engine ran to completion
#
# The engine's exit status is deliberately NEVER used as the gate: under
# 'set -e' a non-zero heredoc would abort the suite before any counter moved
# (the historical bug this protocol replaces). Counting one counter increment
# per emitted assertion also keeps the summary totals honest.
# ------------------------------------------------------------------------------
report_assertions() {
  local raw seen_done=0 line detail unclassified=""
  raw="$(python3 - 2>&1)" || true

  while IFS= read -r line; do
    case "$line" in
      DONE\|*)
        seen_done=1
        ;;
      PASS\|*)
        detail="${line#PASS|}"
        log_pass "$detail"
        ;;
      FAIL\|*)
        detail="${line#FAIL|}"
        log_fail "$detail"
        ;;
      *)
        unclassified+="${line}"$'\n'
        ;;
    esac
  done <<< "$raw"

  if [ "$seen_done" -eq 0 ]; then
    log_fail "Analysis engine produced no DONE sentinel (crashed before reporting) -- results for this section are untrustworthy"
  fi

  if [ -n "$unclassified" ]; then
    log_info "--- analysis engine diagnostics (not assertions) ---"
    printf '%s' "$unclassified" | sed 's/^/        /'
  fi
}

# Run a command, print its output only when it fails.
run_capture() {
  local label="$1"; shift
  local tmp rc=0
  tmp="$(mktemp)"
  if "$@" >"$tmp" 2>&1; then
    log_pass "$label"
  else
    rc=$?
    log_fail "$label (exit status ${rc})"
    log_info "--- diagnostic output: ${label} ---"
    tail -n 25 "$tmp" | sed 's/^/        /'
  fi
  rm -f "$tmp"
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
  "srcs/api-gateway/app"
  "srcs/api-gateway/tests"
  "srcs/inventory-app/app"
  "srcs/inventory-app/tests"
  "srcs/billing-app/app"
  "srcs/billing-app/tests"
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
report_assertions << 'PYEOF'
import os, sys
import yaml

EXCLUDED_DIRS = {".git", ".terraform", "node_modules", "__pycache__", ".pytest_cache", ".venv", "venv"}
EXCLUDED_SUFFIXES = (".log",)

failures = 0
scanned = 0

for dirpath, dirnames, filenames in os.walk("."):
    dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED_DIRS)
    for fn in sorted(filenames):
        if not fn.endswith((".yml", ".yaml")):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        if path.endswith(EXCLUDED_SUFFIXES):
            continue
        scanned += 1
        try:
            with open(path, "r", encoding="utf-8") as fh:
                yaml.safe_load(fh)
            print(f"PASS|Valid YAML: {path}")
        except Exception as exc:
            print(f"FAIL|Invalid YAML {path}: {exc}")
            failures += 1

if scanned == 0:
    print("FAIL|YAML discovery found zero files -- the glob is broken, refusing to report a vacuous pass")
    failures += 1

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF

# 3-4. Standalone pipeline checks. infra/ and each srcs/<service>/ folder is
# published as its own GitLab project (scripts/publish_repos.sh), where its
# .gitlab-ci.yml is the root pipeline file. Each one must therefore stand on its
# own: declare its stages and workflow, use only those stages, need only jobs of
# the same file, and use paths relative to the folder.
check_standalone_pipeline() {
  PIPELINE="$1" REQUIRED_STAGES="$2" LEFTOVERS="$3" report_assertions << 'PYEOF'
import os
import yaml

PIPELINE = os.environ["PIPELINE"]
REQUIRED = os.environ["REQUIRED_STAGES"].split("|")
LEFTOVERS = os.environ["LEFTOVERS"].split("|")
RESERVED = {"stages", "default", "variables", "workflow", "cache", "include"}
failures = 0

def check(ok, good, bad):
    global failures
    print(("PASS|" + good) if ok else ("FAIL|" + bad))
    failures += 0 if ok else 1

if not os.path.isfile(PIPELINE):
    check(False, "", f"Missing pipeline definition: {PIPELINE}")
else:
    data = yaml.safe_load(open(PIPELINE, encoding="utf-8")) or {}
    jobs = {k: v for k, v in data.items() if k not in RESERVED and isinstance(v, dict)}
    stages = list(data.get("stages") or [])
    check(stages == REQUIRED, f"{PIPELINE} declares its own stages in order: {' -> '.join(stages)}",
          f"{PIPELINE} stages {stages} differ from {REQUIRED}")
    check("workflow" in data, f"{PIPELINE} declares its own workflow", f"{PIPELINE} has no workflow")
    undeclared = sorted(k for k, v in jobs.items() if v.get("stage") not in stages)
    check(not undeclared, f"{PIPELINE}: all {len(jobs)} jobs use a declared stage",
          f"{PIPELINE}: jobs with an undeclared stage: {undeclared}")
    empty = [st for st in stages if not any(v.get("stage") == st for v in jobs.values())]
    check(not empty, f"{PIPELINE}: every stage has at least one job",
          f"{PIPELINE}: stages without a job: {empty}")
    needs = [(k, n.get("job") if isinstance(n, dict) else n)
             for k, v in jobs.items() for n in (v.get("needs") or [])]
    dangling = [f"{k} -> {n}" for k, n in needs if n not in jobs]
    check(not dangling, f"{PIPELINE}: all {len(needs)} needs: name a job of this pipeline",
          f"{PIPELINE}: needs: pointing outside this pipeline: {dangling}")
    text = yaml.safe_dump(data)
    leaked = [w for w in LEFTOVERS if w in text]
    check(not leaked, f"{PIPELINE}: paths are relative to the folder (no monorepo prefixes)",
          f"{PIPELINE}: monorepo leftovers: {leaked}")

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF
}

log_header "3. Validating Infrastructure Pipeline (infra/.gitlab-ci.yml, standalone)"
check_standalone_pipeline "infra/.gitlab-ci.yml" \
  "Init|Validate|Plan|Apply to Staging|Approval|Apply to Production" \
  "srcs/|infra/"

log_header "4. Validating Microservice Pipelines (srcs/<service>/.gitlab-ci.yml, standalone)"
MICROSERVICES=("srcs/api-gateway" "srcs/inventory-app" "srcs/billing-app")
for ms in "${MICROSERVICES[@]}"; do
  check_standalone_pipeline "${ms}/.gitlab-ci.yml" \
    "Build|Test|Scan|Containerization|Deploy to Staging|Approval|Deploy to Production" \
    "srcs/|infra/|APP_DIR"
done

# 5. Shell Script Syntax Validation
log_header "5. Validating Shell Script Syntax (bash -n)"
SCRIPTS=(
  "ansible/scripts/setup-gitlab.sh"
  "ansible/scripts/register-runner.sh"
  "scripts/test_pipelines.sh"
  "scripts/verify_security.sh"
  "scripts/publish_repos.sh"
)
for script in "${SCRIPTS[@]}"; do
  if [ -f "$script" ]; then
    if bash -n "$script" 2>/dev/null; then
      log_pass "Syntax OK: $script"
    else
      log_fail "Syntax ERROR: $script"
    fi
  else
    log_fail "Missing required shell script: $script (coverage silently lost if this is not reported)"
  fi
done

# 6. Python Bytecode Compilation Checks
log_header "6. Validating Python Code Compilation across Microservices"
run_capture "Python bytecode compilation succeeded for all microservices" \
  python3 -m compileall -q srcs/api-gateway srcs/inventory-app srcs/billing-app

# 7. Dockerfile Best Practices Check
log_header "7. Validating Dockerfile Hardening & Non-Root Execution"
DOCKERFILES=("srcs/api-gateway/Dockerfile" "srcs/inventory-app/Dockerfile" "srcs/billing-app/Dockerfile")
for df in "${DOCKERFILES[@]}"; do
  if [ ! -f "$df" ]; then
    log_fail "Missing Dockerfile: $df"
    continue
  fi

  if grep -q "^USER appuser" "$df"; then
    log_pass "$df enforces non-root unprivileged execution (USER appuser)"
  else
    log_fail "$df does not specify non-root execution"
  fi

  if grep -q "^HEALTHCHECK" "$df"; then
    log_pass "$df defines container HEALTHCHECK probe"
  else
    log_fail "$df missing HEALTHCHECK probe"
  fi
done

# 8. Terraform Staging & Production Parity
log_header "8. Validating Terraform Staging vs Production Structural Parity"
report_assertions << 'PYEOF'
import os, sys

failures = 0
expected = {"main.tf", "variables.tf", "outputs.tf", "terraform.tfvars"}

for env in ("staging", "production"):
    env_dir = os.path.join("infra/environments", env)
    if not os.path.isdir(env_dir):
        print(f"FAIL|Environment directory missing: {env_dir}")
        failures += 1
        continue

    present = set(os.listdir(env_dir))
    missing = sorted(expected - present)
    if missing:
        print(f"FAIL|Environment '{env}' is missing required Terraform file(s): {missing} (present: {sorted(present)})")
        failures += 1
    else:
        print(f"PASS|Environment '{env}' defines the full contract: {sorted(expected)}")

if not failures:
    print("PASS|Staging and Production define an identical Terraform file contract")

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF

# 9. Terraform Code Formatting Check
log_header "9. Validating Terraform Code Formatting (terraform fmt -check)"
if command -v terraform &>/dev/null; then
  if terraform fmt -check -recursive infra && terraform fmt -check -recursive ansible/terraform; then
    log_pass "Terraform formatting check passed across infra/ and ansible/terraform/"
  else
    log_fail "Terraform formatting check failed! Run 'terraform fmt -recursive infra ansible/terraform'"
  fi
else
  log_info "terraform binary not installed; skipping format check"
fi

# 10. Ansible Playbooks & Roles Syntax & Task Listing Checks
log_header "10. Validating Ansible Playbooks, Roles & Task Resolution"
if command -v ansible-playbook &>/dev/null; then
  run_capture "Ansible playbooks passed syntax check (--syntax-check)" \
    bash -c 'ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-gitlab.yml --syntax-check >/dev/null &&
             ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-runners.yml --syntax-check >/dev/null &&
             ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/site.yml --syntax-check >/dev/null'

  run_capture "Ansible playbooks resolved roles and listed all tasks (--list-tasks)" \
    bash -c 'ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-gitlab.yml --list-tasks >/dev/null &&
             ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-runners.yml --list-tasks >/dev/null'
else
  log_info "ansible-playbook binary not installed; skipping playbook syntax check"
fi

# 11. Microservice Unit Test Execution
log_header "11. Validating Microservice Unit Test Execution"
SERVICES=("srcs/api-gateway" "srcs/inventory-app" "srcs/billing-app")
for svc in "${SERVICES[@]}"; do
  if command -v uv &>/dev/null; then
    run_capture "Unit test suite passed for $svc" \
      bash -c "cd '$svc' && uv run --with pytest --with pytest-cov --with-requirements requirements.txt pytest -q"
  elif command -v pytest &>/dev/null; then
    run_capture "Unit test suite passed for $svc" \
      bash -c "cd '$svc' && pytest -q"
  else
    log_info "pytest/uv not in PATH; skipping live unit test execution for $svc"
  fi
done

# Summary
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}  PIPELINE VALIDATION SUMMARY                               ${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  Total Assertions Passed: ${GREEN}${BOLD}${PASSED_CHECKS}${NC}"
echo -e "  Total Assertions Failed: ${RED}${BOLD}${FAILED_CHECKS}${NC}"

if [ "$FAILED_CHECKS" -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}>>> ALL CODE-KEEPER PIPELINE TESTS PASSED! <<<${NC}\n"
  exit 0
else
  echo -e "\n${RED}${BOLD}>>> ONE OR MORE VERIFICATION CHECKS FAILED <<<${NC}\n"
  exit 1
fi