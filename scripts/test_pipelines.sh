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

# 3. Infrastructure Pipeline Stage Checks
log_header "3. Validating Infrastructure Pipeline Stages (infra/.gitlab-ci.yml)"
report_assertions << 'PYEOF'
import os, sys
import yaml

PIPELINE = "infra/.gitlab-ci.yml"
failures = 0

# GitLab resolves exactly one entry point: .gitlab-ci.yml at the repository
# root. Nested .gitlab-ci.yml files are dead configuration unless the root pulls
# them in, so the root's existence is asserted before anything else.
ROOT = ".gitlab-ci.yml"
if not os.path.isfile(ROOT):
    print("FAIL|No root .gitlab-ci.yml: GitLab creates no pipeline at all, whatever the nested files contain")
    failures += 1
    root = {}
else:
    with open(ROOT, encoding="utf-8") as fh:
        root = yaml.safe_load(fh) or {}
    inc = [i.get("local") for i in (root.get("include") or []) if isinstance(i, dict)]
    missing = [f for f in ("infra/.gitlab-ci.yml",
                           "srcs/api-gateway/.gitlab-ci.yml",
                           "srcs/inventory-app/.gitlab-ci.yml",
                           "srcs/billing-app/.gitlab-ci.yml") if f not in inc]
    if missing:
        print(f"FAIL|root .gitlab-ci.yml does not include: {missing}")
        failures += 1
    else:
        print(f"PASS|root .gitlab-ci.yml includes all {len(inc)} pipeline fragments")

if not os.path.isfile(PIPELINE):
    print(f"FAIL|Missing pipeline definition: {PIPELINE}")
    failures += 1
else:
    with open(PIPELINE, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)

    # Fragment invariant: the nested files must not declare stages/default/
    # workflow/variables. In a merged config those keys are singletons and
    # last-one-wins, which is exactly how the original collision bug happened.
    for singleton in ("stages", "default", "workflow", "variables"):
        if singleton in data:
            print(f"FAIL|infra/.gitlab-ci.yml still declares '{singleton}': must be hoisted to the root .gitlab-ci.yml")
            failures += 1
        else:
            print(f"PASS|infra/.gitlab-ci.yml does not re-declare '{singleton}'")
    declared = set(root.get("stages") or [])
    unresolved = sorted({v["stage"] for k, v in data.items()
                         if isinstance(v, dict) and v.get("stage")} - declared)
    if unresolved:
        print(f"FAIL|infra/.gitlab-ci.yml jobs reference stages absent from the root: {unresolved}")
        failures += 1
    else:
        print("PASS|infra/.gitlab-ci.yml job stages all resolve against the root stages list")

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF

# 4. Microservice Pipeline Stage Checks
log_header "4. Validating Microservice Pipeline Stage Checks (CI/CD)"
MICROSERVICES=("srcs/api-gateway" "srcs/inventory-app" "srcs/billing-app")
for ms in "${MICROSERVICES[@]}"; do
  report_assertions << PYEOF
import os, sys
import yaml

PIPELINE = "${ms}/.gitlab-ci.yml"
failures = 0

if not os.path.isfile(PIPELINE):
    print(f"FAIL|Missing pipeline definition: {PIPELINE}")
    failures += 1
else:
    with open(PIPELINE, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)

    with open(".gitlab-ci.yml", encoding="utf-8") as fh:
        root = yaml.safe_load(fh) or {}
    for singleton in ("stages", "default", "workflow", "variables"):
        if singleton in data:
            print(f"FAIL|{PIPELINE} still declares '{singleton}': must be hoisted to the root .gitlab-ci.yml")
            failures += 1
        else:
            print(f"PASS|{PIPELINE} does not re-declare '{singleton}'")
    declared = set(root.get("stages") or [])
    unresolved = sorted({v["stage"] for k, v in data.items()
                         if isinstance(v, dict) and v.get("stage")} - declared)
    if unresolved:
        print(f"FAIL|{PIPELINE} jobs reference stages absent from the root: {unresolved}")
        failures += 1
    else:
        print(f"PASS|{PIPELINE} job stages all resolve against the root stages list")

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF
done

# 4b. Merged-config coverage. Stage coverage is a property of the MERGED config,
# not of any single fragment: a fragment legitimately covers only its own
# stages, so checking coverage per fragment would report the other fragments'
# stages as empty. What must hold is that no stage declared in the root is a
# no-op that passes without ever running a job.
log_header "4b. Validating Merged Stage Coverage (root + fragments)"
report_assertions << 'PYEOF'
import os, yaml

ROOT = ".gitlab-ci.yml"
FRAGMENTS = ["infra/.gitlab-ci.yml", "srcs/api-gateway/.gitlab-ci.yml",
             "srcs/inventory-app/.gitlab-ci.yml", "srcs/billing-app/.gitlab-ci.yml"]
RESERVED = {"stages", "default", "variables", "workflow", "cache", "include"}
failures = 0

if not os.path.isfile(ROOT):
    print("FAIL|no root .gitlab-ci.yml")
else:
    root = yaml.safe_load(open(ROOT, encoding="utf-8")) or {}
    declared = list(root.get("stages") or [])
    owners = {s: [] for s in declared}
    seen_jobs = {}
    for f in FRAGMENTS:
        d = yaml.safe_load(open(f, encoding="utf-8")) or {}
        for k, v in d.items():
            if k in RESERVED or not isinstance(v, dict):
                continue
            seen_jobs.setdefault(k, []).append(f)
            s = v.get("stage")
            if s in owners:
                owners[s].append(k)
    dupes = {k: fs for k, fs in seen_jobs.items() if len(fs) > 1}
    if dupes:
        for k, fs in dupes.items():
            print(f"FAIL|job '{k}' is defined in {len(fs)} fragments -- GitLab keeps only the last")
        failures += 1
    else:
        print(f"PASS|{len(seen_jobs)} jobs, all uniquely named across fragments")
    for s in declared:
        if owners[s]:
            print(f"PASS|stage '{s}' is backed by {len(owners[s])} job(s)")
        else:
            print(f"FAIL|stage '{s}' is declared in the root but no job uses it")
            failures += 1

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF

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
  if terraform fmt -check -recursive infra; then
    log_pass "Terraform formatting check passed across all modules and environments"
  else
    log_fail "Terraform formatting check failed! Run 'terraform fmt -recursive infra'"
  fi
else
  log_info "terraform binary not installed; skipping format check"
fi

# 10. Ansible Playbooks & Roles Syntax & Task Listing Checks
log_header "10. Validating Ansible Playbooks, Roles & Task Resolution"
if command -v ansible-playbook &>/dev/null; then
  run_capture "Ansible playbooks passed syntax check (--syntax-check)" \
    bash -c 'ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-gitlab.yml --syntax-check >/dev/null &&
             ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/deploy-runners.yml --syntax-check >/dev/null'

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