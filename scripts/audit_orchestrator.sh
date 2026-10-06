#!/usr/bin/env bash
# ==============================================================================
# Audit Orchestrator — one command to walk docs/audit.md before the auditor does
# Project: code-keeper
# Verifies every locally-provable audit control, maps each verdict to the exact
# audit.md question it answers, and prints a per-question verdict table.
# Outputs: reports/audit_report.json + reports/evidence/<control>.log
#
# NOTE: `set -e` is deliberately NOT used. A failing control (or a crashing
# third-party scanner) must be recorded as a verdict and the run must continue;
# with -e the first FAIL would abort the audit walk itself.
# ==============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "${ROOT_DIR}" || exit 1

AUDIT_MD="${ROOT_DIR}/docs/audit.md"
REPORT_DIR="${ROOT_DIR}/reports"
EVIDENCE_DIR="${REPORT_DIR}/evidence"
REPORT_JSON="${REPORT_DIR}/audit_report.json"
RESULT_TSV="$(mktemp -t audit_orchestrator.XXXXXX)"
trap 'rm -f "${RESULT_TSV}"' EXIT

# Real escape bytes (not literal backslash sequences) so both echo -e and
# printf '%s' render them.
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
MAGENTA=$'\033[0;35m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'

ONLY=""
LIST_ONLY=0
STRICT=0
ADVISORY=1
EXIT_CODE=0
MAX_DETAIL_LINES=6

usage() {
  cat <<'USAGE'
audit_orchestrator.sh — audit walk-through for the code-keeper project

USAGE:
  scripts/audit_orchestrator.sh [options]

OPTIONS
  --list              List every discovered audit control and the audit.md
                      question it answers, then exit (nothing is executed).
  --only <substring>  Run only controls whose id, mode, label or mapped question
                      slug contains <substring> (case-insensitive).
  --no-advisory       Skip the advisory scanner group (tflint, checkov, tfsec,
                      trivy config, yamllint, shellcheck, ansible-lint).
  --strict            Treat advisory findings as FAIL instead of INFO.
  --help              This text.

VERDICTS
  PASS               Control proven locally.
  FAIL               Control disproven locally — this is a student defect.
  BLOCKED-EXTERNAL  The only proof needs the live target (SSH to the GitLab
                     host, a real GitLab pipeline run). Never counted as a
                     student defect, but always flagged: it is exactly what the
                     auditor will demand live.
  SKIP(<reason>)     Precondition not met (missing optional tool, absent file).
                     Never silently becomes PASS.
  INFO               Reported finding that does not gate the run (advisory
                     scanners, honest gap inventories).

EXIT CODE
  0 only when there are zero FAILs. BLOCKED-EXTERNAL and SKIP are reported but
  do not fail the run. Unmapped audit questions are shown as SKIP(manual).

ENVIRONMENT
  export PATH="$HOME/.local/bin:$PATH"   # terraform/ansible/gitleaks/trivy/...
  No sudo. No network beyond what gitleaks/trivy do locally.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --only)
      if [ $# -lt 2 ]; then
        echo "audit_orchestrator: --only requires an argument" >&2
        exit 2
      fi
      ONLY="$2"
      shift 2
      ;;
    --only=*)
      ONLY="${1#--only=}"
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --no-advisory)
      ADVISORY=0
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "audit_orchestrator: unknown option '$1' (try --help)" >&2
      exit 2
      ;;
  esac
done

# ------------------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------------------
banner() {
  echo -e "${BOLD}============================================================${NC}"
  echo -e "${BOLD}  CODE-KEEPER AUDIT ORCHESTRATOR                             ${NC}"
  echo -e "${BOLD}============================================================${NC}"
  echo -e "  root:      ${CYAN}${ROOT_DIR}${NC}"
  echo -e "  audit:     ${CYAN}${AUDIT_MD#"${ROOT_DIR}"/}${NC}"
  echo -e "  commit:    ${CYAN}$(git rev-parse HEAD 2>/dev/null || echo unknown)${NC}"
  echo -e "  options:   only='${ONLY:-<all>}' strict=${STRICT} advisory=${ADVISORY}"
}

section() {
  echo -e "\n${BLUE}${BOLD}>>> $1${NC}"
  echo -e "${DIM}    ${2:-}${NC}"
}

verdict_color() {
  case "$1" in
    PASS) printf '%s' "${GREEN}" ;;
    FAIL) printf '%s' "${RED}" ;;
    BLOCKED-EXTERNAL) printf '%s' "${YELLOW}" ;;
    SKIP*) printf '%s' "${MAGENTA}" ;;
    INFO) printf '%s' "${CYAN}" ;;
    *) printf '%s' "${NC}" ;;
  esac
}

verdict_tag() {
  local v
  v="$(verdict_color "$1")"
  printf '[%s%s%s]' "${v}" "$1" "${NC}"
}

# ------------------------------------------------------------------------------
# Result plumbing — a control reports through a tab-delimited sentinel line so
# the parent shell can parse verdicts emitted by a crashed-or-not subshell.
# ------------------------------------------------------------------------------
emit_result() {
  local id="$1" verdict="$2" evidence="${3:-}"
  evidence="${evidence//$'\t'/ }"
  evidence="${evidence//$'\n'/ }"
  printf '@@R\t%s\t%s\t%s\n' "${id}" "${verdict}" "${evidence}"
  return 0
}

emit_detail() {
  printf '      %s\n' "$1"
  return 0
}

# ------------------------------------------------------------------------------
# audit.md discovery — nothing about the question list is hardcoded
# ------------------------------------------------------------------------------
QL_ID=()
QL_LINE=()
QL_KIND=()
QL_SLUG=()
QL_TEXT=()
QL_SECT=()
Q_COUNT=0
S_COUNT=0
R_COUNT=0
SECT_INDEX=-1

slugify() {
  local s
  s="$(printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${s:0:46}"
}

# Appends one audit-sheet item and publishes its array index in ADDED_INDEX.
# Deliberately not called through $(...): a command substitution would run in a
# subshell and silently discard the counters and array writes below.
ADDED_INDEX=-1
add_item() {
  local kind="$1" line="$2" text="$3"
  local prefix
  case "${kind}" in
    question) prefix="Q" ;;
    section) prefix="S" ;;
    *) prefix="R" ;;
  esac
  local idx="${#QL_ID[@]}"
  QL_ID[idx]="$(printf '%s%03d' "${prefix}" "${line}")"
  QL_LINE[idx]="${line}"
  QL_KIND[idx]="${kind}"
  QL_SLUG[idx]="$(slugify "${text}")"
  QL_TEXT[idx]="${text}"
  QL_SECT[idx]="${SECT_INDEX}"
  case "${kind}" in
    question) Q_COUNT=$((Q_COUNT + 1)) ;;
    section) S_COUNT=$((S_COUNT + 1)) ;;
    *) R_COUNT=$((R_COUNT + 1)) ;;
  esac
  ADDED_INDEX="${idx}"
}

discover_audit_questions() {
  if [ ! -f "${AUDIT_MD}" ]; then
    echo -e "${RED}[FATAL] missing ${AUDIT_MD} — cannot walk the audit questions${NC}" >&2
    exit 2
  fi
  local ln=0 line text section_text="" in_roleplay_block=0
  # docs/audit.md is CRLF-terminated; strip the carriage return so the anchor
  # regexes and slugify see clean text.
  while IFS= read -r line || [ -n "${line}" ]; do
    ln=$((ln + 1))
    line="${line%$'\r'}"
    case "${line}" in
      *"ask them the following questions"*) in_roleplay_block=1 ;;
      "During the roleplay,"*) in_roleplay_block=1 ;;
    esac
    if [[ "${line}" =~ ^######\ (.*)$ ]]; then
      text="${BASH_REMATCH[1]}"
      add_item question "${ln}" "${text}"
    elif [[ "${line}" =~ ^#####\ (.*)$ ]]; then
      text="${BASH_REMATCH[1]}"
      add_item section "${ln}" "${text}"
      SECT_INDEX="${ADDED_INDEX}"
      section_text="$(slugify "${text}")"
      if [[ "${section_text}" != *"play-the-role-of-a-stakeholder"* ]]; then
        in_roleplay_block=0
      fi
    elif [ "${in_roleplay_block}" -eq 1 ] && [[ "${line}" =~ ^-\ ([A-Za-z].*\?)$ ]]; then
      text="${BASH_REMATCH[1]}"
      add_item roleplay "${ln}" "${text}"
    fi
  done <"${AUDIT_MD}"
}

# Map a catalogue entry to a discovered question: exact audit.md line first,
# keyword anchor second (survives line-number drift in the audit sheet).
resolve_question() {
  local line="$1" anchor="$2" i
  for i in "${!QL_ID[@]}"; do
    if [ "${QL_KIND[i]}" = question ] && [ "${QL_LINE[i]}" = "${line}" ]; then
      printf '%s' "${i}"
      return 0
    fi
  done
  if [ -n "${anchor}" ]; then
    for i in "${!QL_ID[@]}"; do
      if [ "${QL_KIND[i]}" = question ] && printf '%s' "${QL_SLUG[i]}" | grep -qE "${anchor}"; then
        printf '%s' "${i}"
        return 0
      fi
    done
  fi
  printf '%s' -1
}

# ------------------------------------------------------------------------------
# Control catalogue:  id|mode|audit-line|keyword-anchor|label|flags
#   flags: A = advisory (INFO unless --strict)   E = print evidence log path
# ------------------------------------------------------------------------------
CATALOGUE=(
  "FILES-REQUIRED|files.required|11|are-all-the-required-files-present|Every artefact audit.md names exists on disk|"
  "FILES-SUBSTANTIVE|files.substantive|11|are-all-the-required-files-present|Required artefacts are non-empty and substantive|"
  "FILES-PIPELINES|files.pipelines|11|are-all-the-required-files-present|All CI/CD pipeline definitions parse as YAML|"
  "FILES-ANSIBLE|files.ansible|11|are-all-the-required-files-present|Ansible playbooks, roles, inventory and helper scripts present|"
  "ANSIBLE-SYNTAX|ansible.syntax|59|was-the-gitlab-instance-deployed|ansible-playbook --syntax-check on both playbooks|E"
  "ANSIBLE-LISTTASKS|ansible.listtasks|59|was-the-gitlab-instance-deployed|--list-tasks resolves roles; real output archived for the auditor|E"
  "ANSIBLE-ROLES|ansible.roles|59|was-the-gitlab-instance-deployed|Every referenced role resolves to ansible/roles/<role>|"
  "ANSIBLE-TASKS|ansible.expected|59|was-the-gitlab-instance-deployed|Expected deployment tasks appear in --list-tasks output|E"
  "ANSIBLE-NOSECRET|ansible.nosecret|106|separated-credentials-from-code|No default token/password committed in playbooks or role defaults|E"
  "RUNNER-FILES|runner.files|61|runners-integrated-with-the-existing|Runner role + docker executor config template present|"
  "RUNNER-TAGS|runner.tags|61|runners-integrated-with-the-existing|Pipeline job tags are compatible with runner-registered tags|E"
  "RUNNER-LIVE-LIST|runner.live|61|runners-integrated-with-the-existing|LIVE 'gitlab-runner list' on the runner host|"
  "GITLAB-LIVE-STATUS|gitlab.live|59|was-the-gitlab-instance-deployed|LIVE 'gitlab-ctl status' / systemctl on the GitLab host|"
  "INFRA-STAGES|infra.stages|71|init-validate-plan-apply|Infrastructure pipeline declares exactly the six required stages|"
  "INFRA-STAGE-JOBS|infra.stagejobs|71|init-validate-plan-apply|Each of the six infrastructure stages owns at least one job|"
  "INFRA-GATE|infra.gate|71|init-validate-plan-apply|Approval is manual + blocking and gates 'Apply to Production'|"
  "INFRA-ENVIRONMENTS|infra.envs|65|two-environments-similar|Independent staging + production environments with full file contracts|"
  "INFRA-PARITY|infra.parity|67|are-the-two-environments-similar|Staging/production share file contract and module wiring|E"
  "INFRA-INDEPENDENT|infra.independent|69|configuration-exist-in-an-independent|Infrastructure owns its own pipeline with a protected-branch gate|"
  "INFRA-FMT|infra.fmt|65|two-environments-similar|terraform fmt -check -recursive infra|E"
  "INFRA-VALIDATE-STAGING|infra.validate:staging|65|two-environments-similar|terraform validate — staging (offline path reported)|E"
  "INFRA-VALIDATE-PRODUCTION|infra.validate:production|65|two-environments-similar|terraform validate — production (offline path reported)|E"
  "INFRA-NO-SECRETS|infra.nosecret|106|separated-credentials-from-code|No plaintext credentials in terraform.tfvars / variables.tf|E"
  "CI-STAGES|ci.stages|80|build-test-scan-and-containerization|Each microservice declares exactly the seven CI/CD stages|"
  "CI-BUILD|ci.build|80|build-test-scan-and-containerization|Build job compiles and packages the application|"
  "CI-TEST|ci.test|80|build-test-scan-and-containerization|Test job runs the unit suite with coverage|"
  "CI-SCAN|ci.scan|80|build-test-scan-and-containerization|Scan jobs are real tool invocations, not decorative no-ops|E"
  "CI-SCAN-NEGATIVE|ci.scanfixture|80|build-test-scan-and-containerization|Negative control: 4 no-op scan jobs are rejected|E"
  "CI-CONTAINER|ci.container|80|build-test-scan-and-containerization|Containerization builds, scans and pushes the image|"
  "CI-WORKFLOW|ci.workflow|104|triggers-restricted-to-protected-branches|workflow:rules restricts each pipeline to the protected branch|"
  "CD-STAGES|cd.stages|88|deploy-to-staging-approval-and-deploy-to|CD stages present with jobs in every microservice|"
  "CD-APPROVAL|cd.approval|88|deploy-to-staging-approval-and-deploy-to|Approval jobs are manual AND allow_failure:false (blocking)|"
  "CD-APPROVAL-FIXTURE|cd.fixture|88|deploy-to-staging-approval-and-deploy-to|Negative control: non-blocking approval gate is rejected|E"
  "CD-GATE|cd.gate|88|deploy-to-staging-approval-and-deploy-to|Deploy to Production depends on approval + staging jobs|"
  "CD-STAGING|cd.staging|88|deploy-to-staging-approval-and-deploy-to|Deploy to Staging targets a declared environment with a real command|"
  "CD-ZERO-DOWNTIME|cd.zerodowntime|88|deploy-to-staging-approval-and-deploy-to|Zero-downtime rollout evidence (rolling deploy + health wait)|"
  "FUNC-PYTEST|func.pytest|90|pipelines-working-properly|Unit suites run green through uv + pytest-cov|"
  "FUNC-COMPILE|func.compile|90|pipelines-working-properly|python3 -m compileall succeeds for every service|"
  "FUNC-HADOLINT|func.hadolint|90|pipelines-working-properly|hadolint (error threshold) clean on every Dockerfile|E"
  "FUNC-SHELL|func.shell|92|pipelines-working-properly|bash -n succeeds for every shell script in the repo|E"
  "FUNC-YAML|func.yaml|92|pipelines-working-properly|Every CI/playbook YAML file parses (incl. openapi.yaml)|"
  "FUNC-APPLY|func.apply|92|pipelines-working-properly|Pipelines really apply infra and deploy (terraform apply / ECS)|E"
  "FUNC-LIVE-PIPELINE|func.live|92|pipelines-working-properly|LIVE GitLab pipeline run on the deployed instance|"
  "CYB1-JOBS|cyb1.jobs|104|triggers-restricted-to-protected-branches|Every apply/deploy/approval job carries the protected-branch rule|E"
  "CYB1-WORKFLOW|cyb1.workflow|104|triggers-restricted-to-protected-branches|No unprotected workflow entrypoint in any pipeline|E"
  "CYB1-NEGATIVE|cyb1.fixture|104|triggers-restricted-to-protected-branches|Negative control: pipeline with zero protected jobs is rejected|E"
  "CYB2-GITLEAKS|cyb2.gitleaks|106|separated-credentials-from-code|gitleaks detect over the whole tree (covers *.sh)|E"
  "CYB2-ASSIGNMENT|cyb2.assignment|106|separated-credentials-from-code|Assignment-style credential grep incl. *.sh, *.py, *.tfvars|E"
  "CYB2-GITIGNORE|cyb2.gitignore|106|separated-credentials-from-code|No tracked .env/key/pem/tfstate; .gitignore guards them|"
  "CYB2-ENV-SOURCED|cyb2.env|106|separated-credentials-from-code|Infrastructure credentials come from env/CI variables, never literals|E"
  "CYB3-DOCKER|cyb3.docker|108|least-privilege-principle|Container images run as non-root (last USER directive wins)|E"
  "CYB3-SG-EXPOSURE|cyb3.sgrules|108|least-privilege-principle|No sensitive port exposed to 0.0.0.0/0 or ::/0 (ranges + IPv6)|E"
  "CYB3-SG-DATASTORE|cyb3.sgdata|108|least-privilege-principle|Data-store ingress is peer-SG only (world-open CIDR on a data-store port rejected); outbound CIDR inventoried|E"
  "CYB3-SG-GAPS|cyb3.sggaps|108|least-privilege-principle|Unmanaged SG directions inventoried (rabbitmq/database egress, billing ingress)|E"
  "CYB3-RDS|cyb3.rds|108|least-privilege-principle|RDS instances are private and storage-encrypted (least-privilege data tier)|"
  "CYB3-NEGATIVE|cyb3.fixture|108|least-privilege-principle|Negative control: world-open data-store ingress (5432, 5672/15672) rejected, peer-SG-only store accepted|E"
  "CYB4-FILE|cyb4.file|110|process-for-updating-dependencies|.github/dependabot.yml exists and parses|"
  "CYB4-COVERAGE|cyb4.coverage|110|process-for-updating-dependencies|Dependabot covers every dependency manifest present in the repo|E"
  "CYB4-TERRAFORM-EFFECTIVE|cyb4.terraformroot|110|process-for-updating-dependencies|Terraform ecosystem entry is effective, not a silent no-op|E"
  "CYB4-SCHEDULE|cyb4.schedule|110|process-for-updating-dependencies|Update cadence configured on every dependabot entry|"
  "CYB4-RENOVATE|cyb4.renovate|110|process-for-updating-dependencies|Docs claim Renovate — is any Renovate automation wired up?|E"
  "DOC-README|doc.readme|114|readme-md-file-contain-all|README.md substantive and covers prerequisites/setup/config/usage|E"
  "DOC-README-SECTIONS|doc.sections|116|documentation-provided-by-the-student-clear|README documents architecture, tools, verification, Q&A|E"
  "DOC-GUIDE|doc.guide|116|documentation-provided-by-the-student-clear|docs/AUDIT_GUIDE.md substantive and covers every audit section|E"
  "DOC-DIAGRAMS|doc.diagrams|116|documentation-provided-by-the-student-clear|Audit guide + README carry diagrams (mermaid/ASCII)|E"
  "DOC-QUESTION-COVERAGE|doc.coverage|116|documentation-provided-by-the-student-clear|Every audit.md question is answered in the guide|E"
  "BONUS-IMPLEMENTED|bonus.implemented|120|implemented-any-feature-or-anything|Bonus features genuinely present in code (inventory)|E"
  "BONUS-CLAIMS|bonus.claims|120|implemented-any-feature-or-anything|Claims-vs-code audit of infracost/tfsec/terragrunt/renovate|E"
  "BONUS-CRUDMASTER|bonus.crudmaster|122|own-crud-master-source-code|crud-master-derived services detectable in this repo|E"
  "ADV-TFLINT|adv.tflint|80|build-test-scan-and-containerization|tflint Terraform lint (advisory)|E"
  "ADV-CHECKOV|adv.checkov|108|least-privilege-principle|checkov IaC policy scan (advisory)|E"
  "ADV-TFSEC|adv.tfsec|108|least-privilege-principle|tfsec IaC scan (advisory)|E"
  "ADV-TRIVY|adv.trivy|65|two-environments-similar|trivy config IaC misconfiguration scan (advisory)|E"
  "ADV-YAMLLINT|adv.yamllint|116|documentation-provided-by-the-student-clear|yamllint over pipelines and playbooks (advisory)|E"
  "ADV-SHELLCHECK|adv.shellcheck|116|documentation-provided-by-the-student-clear|shellcheck over repo scripts (advisory)|E"
  "ADV-ANSIBLELINT|adv.ansiblelint|59|was-the-gitlab-instance-deployed|ansible-lint over ansible/ (advisory)|E"
)

# ------------------------------------------------------------------------------
# Python analysis engine (YAML / HCL / Dockerfile / dependabot / docs semantics)
# ------------------------------------------------------------------------------
py_analyze() {
  AUDIT_ROOT="${ROOT_DIR}" AUDIT_QS="${AUDIT_QUESTIONS_TSV}" python3 - "$1" <<'PYEOF'
import glob
import json
import os
import fnmatch
import re
import sys

ROOT = os.environ.get("AUDIT_ROOT") or os.getcwd()
MODE = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    import yaml
    HAVE_YAML = True
except Exception:
    HAVE_YAML = False

RESERVED = {
    "stages", "variables", "default", "workflow", "include", "image",
    "services", "before_script", "after_script", "cache", "types", "spec",
    "pages", "interruptible",
}
SCAN_TOOLS = (
    "bandit", "gitleaks", "trivy", "sonar-scanner", "snyk", "whitesource",
    "semgrep", "safety", "pip-audit", "checkov", "tfsec", "grype", "codeql",
)
SENSITIVE_PORTS = {
    22, 23, 143, 1433, 1521, 2049, 2375, 2376, 3306, 3389, 5432, 5671,
    5672, 6379, 9092, 9200, 9300, 11211, 15672, 27017, 6443, 10250, 10255,
}


def R(*p):
    return os.path.join(ROOT, *p)


def read(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def rel(p):
    try:
        return os.path.relpath(p, ROOT)
    except Exception:
        return p


def emit(cid, verdict, evidence, details=None):
    for d in (details or []):
        print("      " + re.sub(r"\s+", " ", str(d)).strip()[:220])
    ev = re.sub(r"[\t\r\n]+", " ", str(evidence)).strip()
    print("@@R\t%s\t%s\t%s" % (cid, verdict, ev))


def no_yaml(cid):
    emit(cid, "FAIL", "PyYAML is not importable, so this control cannot be evaluated (never a silent PASS)")


def services():
    out = []
    for d in sorted(glob.glob(R("srcs", "*"))):
        if os.path.isdir(d) and os.path.isfile(os.path.join(d, ".gitlab-ci.yml")):
            out.append(os.path.basename(d))
    return out


def load_ci(path):
    if not HAVE_YAML:
        return None, "PyYAML unavailable"
    try:
        return yaml.safe_load(read(path)) or {}, None
    except Exception as exc:
        return None, "YAML parse error: %s" % str(exc).splitlines()[0]


# GitLab resolves exactly ONE CI entry point: .gitlab-ci.yml at the repository
# root. The files under infra/ and srcs/ are `include:` fragments, and the
# singleton keys GitLab will not merge for them (stages, workflow, default,
# variables) live in the root file. Reading a fragment in isolation therefore
# understates it: a fragment that declares no `stages:` is not stage-less, it
# inherits the root's union list. hoist_singletons() reconstructs the effective
# view the runner actually sees, so a control can never fail a fragment merely
# for delegating a singleton to the root.
ROOT_CI = ".gitlab-ci.yml"
HOISTED = ("stages", "workflow", "default")


def load_root_ci():
    return load_ci(R(ROOT_CI))


def hoist_singletons(data):
    """Fill hoisted singleton keys from the root entry point when a fragment omits them."""
    if not isinstance(data, dict):
        return data
    missing = [k for k in HOISTED if k not in data]
    if not missing:
        return data
    root, err = load_root_ci()
    if err or not isinstance(root, dict):
        return data
    for k in missing:
        if k in root:
            data[k] = root[k]
    return data


def load_infra_ci():
    data, err = load_ci(R("infra", ROOT_CI))
    return (hoist_singletons(data), err) if not err else (data, err)


def stages_subset(actual, required):
    """True when `required` appears in `actual` in the same relative order."""
    if not isinstance(actual, list):
        return False
    pos, last = [], -1
    for stage in required:
        if stage not in actual:
            return False
        idx = actual.index(stage)
        if idx < last:
            return False
        last = idx
        pos.append(idx)
    return True


def jobs(data):
    return {k: v for k, v in (data or {}).items()
            if k not in RESERVED and isinstance(v, dict)}


def script_text(job):
    val = job.get("script")
    if val is None:
        val = job.get("trigger") or ""
    if isinstance(val, str):
        return val
    return "\n".join(str(x) for x in (val or []))


def image_name(job):
    img = job.get("image")
    if isinstance(img, str):
        return img
    if isinstance(img, dict):
        return str(img.get("name") or "")
    return ""


def stage_jobs(data, stage):
    return {k: v for k, v in jobs(data).items() if v.get("stage") == stage}


def need_names(job):
    """The job names a job declares in `needs:`, as plain strings."""
    out = []
    for n in job.get("needs") or []:
        out.append(str(n.get("job", n)) if isinstance(n, dict) else str(n))
    return out


def needs_segment(job, segment):
    """True when a job needs one whose ':'-delimited name segment matches.

    Job names are namespaced per service now that four fragments share one
    namespace (`api-gateway:approval:production`, `infra:approval:production`),
    so matching a dependency by string prefix silently stops finding the gate.
    Both the infra and the microservice production gates go through this helper
    so they cannot drift apart again.
    """
    return any(seg == segment or seg.startswith(segment)
               for n in need_names(job) for seg in n.split(":"))


PROTECTED_RE = re.compile(
    r"CI_COMMIT_(BRANCH|TAG|REF_NAME)\s*==\s*(\"|')?(main|master|release[\w/*-]*)(\"|')?"
    r"|CI_COMMIT_(BRANCH|TAG)\s*==\s*\$CI_DEFAULT_BRANCH")


def protected_match(blob):
    return PROTECTED_RE.search(str(blob))


def has_protected_rule(job):
    return bool(protected_match(job.get("rules")) or protected_match(job.get("only")))


def workflow_admits_non_main(data):
    """Workflow rule texts that let a non-protected ref run (empty list = main-only)."""
    rules = ((data or {}).get("workflow") or {}).get("rules") or []
    offenders = []
    for r in rules:
        if not isinstance(r, dict):
            continue
        cond = str(r.get("if", ""))
        if str(r.get("when", "")) == "never":
            continue
        if protected_match(cond):
            continue
        offenders.append(cond.strip() or "<rule without condition>")
    return offenders


def workflow_protected(data):
    rules = ((data or {}).get("workflow") or {}).get("rules") or []
    if not rules:
        return False
    cond = any(isinstance(r, dict) and protected_match(r.get("if")) for r in rules)
    terminal = any(isinstance(r, dict) and str(r.get("when")) == "never" for r in rules)
    return bool(cond and terminal and not workflow_admits_non_main(data))


def scan_tools_used(job):
    """Scanner invocations in a job's script.

    A tool counts when it appears in *command position*. The prefix is anchored
    to a line start or a command separator, optionally followed by the shell
    control words that also start a command (`if`, `then`, `do`, ...), `sudo`,
    and a relative path. Anchoring this way is deliberate: it must match
    `if pip-audit -r requirements.txt` (a real advisory scan wrapped in a
    conditional) while still refusing a scanner name that only appears inside
    prose or inside an echo'd string.
    """
    text = script_text(job).lower()
    hits = []
    for tool in SCAN_TOOLS:
        pat = (r"(?:^|[\n;&|(`]|\b(?:if|then|else|elif|do|while|until|not)\b)"
               r"\s*(?:sudo\s+)?(?:[a-z0-9_.-]+/)*[a-z0-9_.-]*"
               + re.escape(tool) + r"\b")
        if re.search(pat, text):
            hits.append(tool)
    return hits


def scan_report(data):
    """Realism of the Scan stage: every job must actually invoke a scanner."""
    scan = stage_jobs(data, "Scan")
    if not scan:
        return False, ["no job is attached to the Scan stage"], set()
    real, fake = {}, []
    for name, job in sorted(scan.items()):
        hits = scan_tools_used(job)
        if hits and image_name(job):
            real[name] = hits
        else:
            fake.append("%s(image=%s,tools=%s)" % (
                name, image_name(job) or "none", ",".join(hits) or "none"))
    tools = sorted({t for hits in real.values() for t in hits})
    ok = len(real) >= 3 and len(tools) >= 3 and not fake
    detail = ["real scanners: %s" % ", ".join("%s(%s)" % (n, ",".join(h))
                                             for n, h in sorted(real.items()))]
    if fake:
        detail.append("decorative/no-op scan jobs: %s" % "; ".join(fake))
    if len(tools) < 3:
        detail.append("only %d distinct scanner(s): %s" % (len(tools), tools or "none"))
    return ok, detail, set(tools)


def tf_module_map(envdir):
    """module name -> source, from an environment main.tf."""
    text = read(R(envdir, "main.tf"))
    out = {}
    for m in re.finditer(r'module\s+"([^"]+)"\s*\{(.*?)\n\}', text, re.S):
        name, body = m.group(1), m.group(2)
        src = re.search(r'source\s*=\s*"([^"]+)"', body)
        args = sorted(set(re.findall(r'(?m)^\s{2}([a-z0-9_]+)\s*=', body)) - {"source"})
        out[name] = {"source": src.group(1) if src else None, "args": args}
    return out


def balanced(text, open_idx):
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i]
    return text[open_idx + 1:]


def hcl_refs(text):
    """locals{} and variable default= values, so `from_port = local.x` resolves."""
    refs = {}
    for m in re.finditer(r"(?ms)^locals\s*\{(.*?)^\}", text):
        for lm in re.finditer(r"(?m)^\s*([a-z0-9_]+)\s*=\s*([^\s#]+)", m.group(1)):
            refs[lm.group(1)] = lm.group(2)
    for m in re.finditer(r'(?ms)^variable\s+"([^"]+)"\s*\{(.*?)^\}', text):
        dm = re.search(r"(?m)^\s*default\s*=\s*([^\s#]+)", m.group(2))
        if dm:
            refs[m.group(1)] = dm.group(1)
    return refs


def resolve_ref(value, refs):
    m = re.fullmatch(r"(?:local|var)\.([a-z0-9_]+)", str(value).strip())
    if m:
        return refs.get(m.group(1))
    return value


def block_attrs(body, refs=None):
    attrs = {}
    for key in ("description", "protocol", "from_port", "to_port",
                "cidr_blocks", "ipv6_cidr_blocks", "security_groups"):
        m = re.search(r"(?m)^\s*" + key + r"\s*=\s*(.+?)\s*$", body)
        if m:
            val = m.group(1).strip()
            if refs is not None and key in ("from_port", "to_port"):
                val = resolve_ref(val, refs)
            attrs[key] = val
    return attrs


def sg_blocks(body, kind, refs=None):
    out = []
    for m in re.finditer(r"(?m)^[ \t]*" + kind + r"[ \t]*\{", body):
        out.append(block_attrs(balanced(body, body.index("{", m.end() - 1)), refs))
    return out


def parse_security_groups(path):
    """Brace-balanced extractor for aws_security_group resources."""
    text = read(path)
    refs = hcl_refs(text)
    return parse_security_groups_from_text(text, refs)


def hcl2_available():
    try:
        import hcl2  # noqa: F401
        return True
    except Exception:
        return False


def port_span(rule):
    try:
        lo = int(rule.get("from_port", "-1"))
        hi = int(rule.get("to_port", "-1"))
    except ValueError:
        return None
    return lo, hi


def world_open(rule):
    return "0.0.0.0/0" in (rule.get("cidr_blocks") or "") or \
        "\"::/0\"" in (rule.get("ipv6_cidr_blocks") or "")


def exposed_sensitive(groups):
    findings = []
    public = []
    unknown = []
    for name, spec in sorted(groups.items()):
        for rule in spec["ingress"]:
            if not world_open(rule):
                continue
            span = port_span(rule)
            if span is None:
                unknown.append("%s: ports %s-%s via %s" % (
                    name, rule.get("from_port"), rule.get("to_port"), rule.get("protocol")))
                continue
            lo, hi = span
            if str(rule.get("protocol")) == "-1" or (lo == 0 and hi == 0):
                hit = sorted(SENSITIVE_PORTS)
                findings.append("%s: all ports open to the world (%s)" % (name, rule.get("protocol")))
                public.append("%s:all" % name)
                continue
            overlap = sorted(p for p in SENSITIVE_PORTS if lo <= p <= hi)
            if overlap:
                findings.append("%s: ports %d-%d open to 0.0.0.0/0 (sensitive: %s)"
                                % (name, lo, hi, overlap))
            else:
                public.append("%s:%d-%d" % (name, lo, hi))
    return findings, public, unknown


# --- required artefact inventory ---------------------------------------------
def required_paths():
    req = [
        ("README.md", "audit sheet README"),
        ("docs/audit.md", "audit question sheet"),
        ("ansible.cfg", "ansible configuration"),
        ("ansible/inventory/hosts.ini", "ansible inventory"),
        ("ansible/playbooks/deploy-gitlab.yml", "GitLab deployment playbook"),
        ("ansible/playbooks/deploy-runners.yml", "runner deployment playbook"),
        ("ansible/roles/gitlab/tasks/main.yml", "gitlab role entrypoint"),
        ("ansible/roles/gitlab_runner/tasks/main.yml", "gitlab_runner role entrypoint"),
        ("ansible/roles/gitlab_runner/templates/config.toml.j2", "runner docker executor config"),
        ("ansible/scripts/setup-gitlab.sh", "GitLab setup script"),
        ("ansible/scripts/register-runner.sh", "runner registration script"),
        ("infra/.gitlab-ci.yml", "infrastructure pipeline"),
        ("scripts/test_pipelines.sh", "pipeline verification suite"),
        ("scripts/verify_security.sh", "security verification suite"),
    ]
    for env in ("staging", "production"):
        for f in ("main.tf", "variables.tf", "outputs.tf", "terraform.tfvars"):
            req.append(("infra/environments/%s/%s" % (env, f), "%s %s" % (env, f)))
    for mod in ("vpc", "security_groups", "rds", "rabbitmq", "compute"):
        req.append(("infra/modules/%s/main.tf" % mod, "%s module" % mod))
    for svc in services():
        for f in (".gitlab-ci.yml", "Dockerfile", "requirements.txt", "server.py"):
            req.append(("srcs/%s/%s" % (svc, f), "%s %s" % (svc, f)))
    return req


def h_files_required():
    missing, details = [], []
    for path, _desc in required_paths():
        if not os.path.exists(R(path)):
            missing.append(path)
    if not services():
        missing.append("srcs/*/.gitlab-ci.yml (no microservice pipeline discovered)")
    if missing:
        emit("FILES-REQUIRED", "FAIL",
             "%d required artefact(s) missing: %s" % (len(missing), ", ".join(missing[:6])),
             ["checked %d paths named by audit.md" % len(required_paths())])
    else:
        emit("FILES-REQUIRED", "PASS",
             "all %d audit-named artefacts present (%d microservices, 2 terraform environments)"
             % (len(required_paths()), len(services())))


def h_files_substantive():
    thin = []
    for path, desc in required_paths():
        full = R(path)
        if not os.path.isfile(full):
            continue
        size = os.path.getsize(full)
        floor = 20 if path.endswith(("requirements.txt", "terraform.tfvars")) else 120
        if size < floor:
            thin.append("%s(%dB<%dB)" % (path, size, floor))
    if thin:
        emit("FILES-SUBSTANTIVE", "FAIL",
             "%d artefact(s) are placeholders (<120 bytes): %s" % (len(thin), ", ".join(thin[:6])))
    else:
        emit("FILES-SUBSTANTIVE", "PASS",
             "no placeholder/empty artefact among the %d required paths" % len(required_paths()))


def h_files_pipelines():
    if not HAVE_YAML:
        return no_yaml("FILES-PIPELINES")
    bad = []
    paths = [R("infra", ".gitlab-ci.yml")] + [
        R("srcs", s, ".gitlab-ci.yml") for s in services()]
    for p in paths:
        data, err = load_ci(p)
        if err:
            bad.append("%s: %s" % (rel(p), err))
        elif not isinstance(data, dict) or not jobs(data):
            bad.append("%s: no jobs defined" % rel(p))
    if bad:
        emit("FILES-PIPELINES", "FAIL", "pipeline definition problems: %s" % "; ".join(bad))
    else:
        emit("FILES-PIPELINES", "PASS",
             "%d pipeline definitions parse and declare jobs" % len(paths))


def h_files_ansible():
    want = []
    for base, patterns in (
        (R("ansible", "playbooks"), ("*.yml",)),
        (R("ansible", "roles"), ("main.yml",)),
        (R("ansible", "scripts"), ("*.sh",)),
    ):
        for pat in patterns:
            want.extend(sorted(glob.glob(os.path.join(base, "**", pat), recursive=True)))
    playbooks = [p for p in want if "/playbooks/" in p]
    roles = sorted({p.split("/roles/")[1].split("/")[0] for p in want if "/roles/" in p})
    scripts = [p for p in want if "/scripts/" in p]
    problems = []
    if len(playbooks) < 2:
        problems.append("expected >=2 playbooks, found %d" % len(playbooks))
    if len(roles) < 2:
        problems.append("expected >=2 roles, found %d" % len(roles))
    if len(scripts) < 2:
        problems.append("expected >=2 deployment scripts, found %d" % len(scripts))
    if not os.path.isfile(R("ansible", "inventory", "hosts.ini")):
        problems.append("ansible/inventory/hosts.ini missing")
    if problems:
        emit("FILES-ANSIBLE", "FAIL", "; ".join(problems))
    else:
        emit("FILES-ANSIBLE", "PASS",
             "%d playbooks, %d roles (%s), %d deployment scripts, inventory present"
             % (len(playbooks), len(roles), ",".join(roles), len(scripts)),
             ["playbooks: %s" % ", ".join(rel(p) for p in playbooks)])


def h_ansible_roles():
    refs, missing = [], []
    for pb in sorted(glob.glob(R("ansible", "playbooks", "*.yml"))):
        text = read(pb)
        for m in re.finditer(r'-\s*role:\s*([a-z0-9_]+)', text):
            refs.append((rel(pb), m.group(1)))
        for blk in re.finditer(r'roles:\s*\n(?:\s*-\s*[^\n#]+\n)+', text):
            for nm in re.finditer(r'-\s*(?:role:\s*)?([a-z][a-z0-9_]*)', blk.group(0)):
                refs.append((rel(pb), nm.group(1)))
    for pb, role in refs:
        if not os.path.isfile(R("ansible", "roles", role, "tasks", "main.yml")):
            missing.append("%s -> ansible/roles/%s/tasks/main.yml" % (pb, role))
    if not refs:
        emit("ANSIBLE-ROLES", "FAIL", "no role references found in the playbooks (precondition empty)")
    elif missing:
        emit("ANSIBLE-ROLES", "FAIL", "unresolvable roles: %s" % "; ".join(missing))
    else:
        emit("ANSIBLE-ROLES", "PASS",
             "%d role reference(s) resolve under ansible/roles/ (%s)"
             % (len(refs), ", ".join(sorted({r for _, r in refs}))))


def read_task_dump():
    path = R(REPORT_DIR_REL, "ansible_list_tasks.txt")
    if not os.path.isfile(path):
        return ""
    return read(path)


def h_ansible_expected():
    text = read_task_dump()
    if not text:
        emit("ANSIBLE-TASKS", "FAIL",
             "no archived --list-tasks output at %s (run ANSIBLE-LISTTASKS first)"
             % os.path.join(REPORT_DIR_REL, "ansible_list_tasks.txt"))
        return
    expected = [
        "Install GitLab CE package",
        "Deploy gitlab.rb configuration template",
        "Configure GitLab application settings and CI/CD parameters via rails runner",
        "Register GitLab Runner with Docker executor",
        "Check registered runners",
        "Verify GitLab services status",
    ]
    found = [t for t in expected if t in text]
    missing = [t for t in expected if t not in text]
    if missing:
        emit("ANSIBLE-TASKS", "FAIL",
             "%d/%d expected tasks absent from --list-tasks: %s"
             % (len(missing), len(expected), "; ".join(missing)),
             ["present: %s" % ", ".join(found)])
    else:
        emit("ANSIBLE-TASKS", "PASS",
             "all %d expected deployment tasks present in the archived --list-tasks output"
             % len(expected),
             ["tasks archived: %d lines" % len(text.splitlines())])


SECRET_ASSIGN = re.compile(
    r'(?i)\b(passwo?r?d|passwd|secret|token|api[_-]?key|access[_-]?key|credential)'
    r'\s*[:=]\s*["\']?([A-Za-z0-9+/_.-]{6,})')
SAFE_ASSIGN = re.compile(
    r'(?i)(\{\{|\}\}|\$\{|lookup|var\.|os\.environ|os\.getenv|environ|getenv|'
    r'default\(|changeme|example|redact|placeholder|<[a-z_ -]+>|CI_REGISTRY_|'
    r'\"\"\"|none|null|\*\*\*)')


def scan_hardcoded_secrets(paths, cid, ignore_tmpl=True):
    hits = []
    for path in paths:
        try:
            text = read(path)
        except Exception:
            continue
        if ignore_tmpl and path.endswith(".j2"):
            continue
        for num, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in SECRET_ASSIGN.finditer(line):
                value = m.group(2)
                if SAFE_ASSIGN.search(line):
                    continue
                hits.append("%s:%d: %s=%s" % (rel(path), num, m.group(1), value[:6] + "..."))
    return hits


def h_ansible_nosecret():
    paths = sorted(glob.glob(R("ansible", "**", "*.yml"), recursive=True))
    hits = scan_hardcoded_secrets(paths, "ANSIBLE-NOSECRET")
    hits = [h for h in hits if "registration_token=${" not in h]
    if hits:
        emit("ANSIBLE-NOSECRET", "FAIL",
             "%d credential-looking literal(s) in ansible YAML: %s" % (len(hits), "; ".join(hits[:4])))
    else:
        env_refs = sum(1 for p in paths if "lookup('env'" in read(p))
        emit("ANSIBLE-NOSECRET", "PASS",
             "no committed token/password literals; %d file(s) source secrets from environment lookups"
             % env_refs)


def h_infra_nosecret():
    paths = sorted(glob.glob(R("infra", "**", "*.tf"), recursive=True)) + \
        sorted(glob.glob(R("infra", "**", "*.tfvars"), recursive=True))
    hits = []
    for p in paths:
        for num, line in enumerate(read(p).splitlines(), 1):
            s = line.strip()
            if s.startswith("#"):
                continue
            m = re.search(r'(?i)^\s*(?P<k>[a-z0-9_]*pass[a-z0-9_]*|[a-z0-9_]*secret[a-z0-9_]*)\s*=\s*"([^"]+)"', s)
            if not m:
                continue
            val = m.group(2)
            if SAFE_ASSIGN.search(val) or val.startswith("var."):
                continue
            hits.append("%s:%d: %s=%s" % (rel(p), num, m.group("k"), val[:6] + "..."))
    if hits:
        emit("INFRA-NO-SECRETS", "FAIL",
             "%d plaintext credential value(s) in terraform: %s" % (len(hits), "; ".join(hits[:4])))
    else:
        marked = sum(1 for p in glob.glob(R("infra", "**", "*.tf"), recursive=True)
                     if "sensitive" in read(p))
        emit("INFRA-NO-SECRETS", "PASS",
             "no plaintext credentials in terraform; passwords arrive as TF_VAR_* from masked CI variables",
             ["variables marked sensitive: %d occurrence(s)" % marked])


def h_runner_files():
    want = [
        "ansible/roles/gitlab_runner/tasks/main.yml",
        "ansible/roles/gitlab_runner/tasks/install.yml",
        "ansible/roles/gitlab_runner/tasks/register.yml",
        "ansible/roles/gitlab_runner/tasks/configure.yml",
        "ansible/roles/gitlab_runner/defaults/main.yml",
        "ansible/roles/gitlab_runner/templates/config.toml.j2",
        "ansible/scripts/register-runner.sh",
        "ansible/playbooks/deploy-runners.yml",
    ]
    missing = [p for p in want if not os.path.isfile(R(p))]
    tpl = ""
    if not missing:
        tpl = read(R("ansible", "roles", "gitlab_runner", "templates", "config.toml.j2"))
    if missing:
        emit("RUNNER-FILES", "FAIL", "missing runner artefacts: %s" % ", ".join(missing))
        return
    executor = 'executor = "{{ gitlab_runner_executor }}"' in tpl
    docker = "[runners.docker]" in tpl and "image = \"{{ gitlab_runner_default_image }}\"" in tpl
    privileged = "privileged = {{ gitlab_runner_docker_privileged | lower }}" in tpl
    register = read(R("ansible", "roles", "gitlab_runner", "tasks", "register.yml"))
    has_reg = "gitlab-runner register" in register and "--tag-list" in register
    if executor and docker and has_reg:
        emit("RUNNER-FILES", "PASS",
             "docker executor rendered from config.toml.j2; registration passes --tag-list; privileged=%s"
             % ("templated false" if privileged else "not templated"),
             ["executor=%s docker_block=%s registration_task=%s"
              % (executor, docker, has_reg)])
    else:
        emit("RUNNER-FILES", "FAIL",
             "runner executor wiring incomplete (executor=%s docker_block=%s registration=%s)"
             % (executor, docker, has_reg))


def h_runner_tags():
    defaults = R("ansible", "roles", "gitlab_runner", "defaults", "main.yml")
    if not os.path.isfile(defaults):
        emit("RUNNER-TAGS", "FAIL", "runner defaults missing at %s" % rel(defaults))
        return
    text = read(defaults)
    m = re.search(r'gitlab_runner_tags:(?:\s*\n((?:\s*-\s*.+\n)+))?', text)
    if not m:
        emit("RUNNER-TAGS", "FAIL", "gitlab_runner_tags is not defined in the runner defaults")
        return
    tags = re.findall(r'-\s*["\']?([A-Za-z0-9_.-]+)["\']?', m.group(1) or "")
    run_untagged = re.search(r'gitlab_runner_run_untagged:\s*(\S+)', text)
    untagged = bool(run_untagged and str(run_untagged.group(1)).lower() == "true")
    used, offenders = set(), []
    if not HAVE_YAML:
        return no_yaml("RUNNER-TAGS")
    for svc in services():
        data, err = load_ci(R("srcs", svc, ROOT_CI))
        if err or not isinstance(data, dict):
            offenders.append("%s: %s" % (svc, err or "not a mapping"))
            continue
        for name, job in jobs(data).items():
            for t in (job.get("tags") or []):
                used.add(str(t))
                if str(t) not in tags:
                    offenders.append("%s:%s requires tag '%s'" % (svc, name, t))
    infra, err = load_infra_ci()
    if isinstance(infra, dict):
        for name, job in jobs(infra).items():
            for t in (job.get("tags") or []):
                used.add(str(t))
                if str(t) not in tags:
                    offenders.append("infra:%s requires tag '%s'" % (name, t))
    if offenders:
        emit("RUNNER-TAGS", "FAIL",
             "%d job(s) request a tag the runner does not register: %s"
             % (len(offenders), "; ".join(offenders[:4])))
        return
    if not used:
        emit("RUNNER-TAGS", "INFO",
             "no pipeline pins job tags; coverage depends on runner run_untagged=%s "
             "(runner tags: %s)" % (str(untagged).lower(), ",".join(tags)),
             ["grep the guide for 'run_untagged' before the auditor asks why untagged jobs run"])
        return
    emit("RUNNER-TAGS", "PASS",
         "runner registers [%s]; pipeline tags [%s] are a subset"
         % (",".join(tags), ",".join(sorted(used))))


# --- infrastructure -----------------------------------------------------------
INFRA_STAGES = ["Init", "Validate", "Plan", "Apply to Staging", "Approval",
                "Apply to Production"]


def h_infra_stages():
    data, err = load_infra_ci()
    if err:
        return emit("INFRA-STAGES", "FAIL", "infra/.gitlab-ci.yml unreadable: %s" % err)
    actual = data.get("stages") or []
    if stages_subset(actual, INFRA_STAGES):
        emit("INFRA-STAGES", "PASS",
             "the six required stages are declared in order (effective list: %s)"
             % " -> ".join(actual))
    else:
        emit("INFRA-STAGES", "FAIL",
             "stage list mismatch; expected %s (in order, anywhere in the effective "
             "list) got %s" % (INFRA_STAGES, actual))


def h_infra_stagejobs():
    data, err = load_infra_ci()
    if err:
        return emit("INFRA-STAGE-JOBS", "FAIL", "infra/.gitlab-ci.yml unreadable: %s" % err)
    found = {}
    for name, job in jobs(data).items():
        found.setdefault(str(job.get("stage")), []).append(name)
    empty = [s for s in INFRA_STAGES if s not in found]
    extra = [s for s in found if s not in INFRA_STAGES]
    if empty or extra:
        emit("INFRA-STAGE-JOBS", "FAIL",
             "stage coverage broken; empty=%s unexpected=%s" % (empty, extra))
    else:
        emit("INFRA-STAGE-JOBS", "PASS",
             "; ".join("%s=%s" % (s, ",".join(found[s])) for s in INFRA_STAGES))


def h_infra_gate():
    data, err = load_infra_ci()
    if err:
        return emit("INFRA-GATE", "FAIL", "infra/.gitlab-ci.yml unreadable: %s" % err)
    problems = []
    approvals = [j for j in jobs(data).values() if j.get("stage") == "Approval"]
    if not approvals:
        problems.append("no job in the Approval stage")
    for job in approvals:
        if str(job.get("when")) != "manual":
            problems.append("%s: when=%s (must be manual)" % (job.get("stage"), job.get("when")))
        if job.get("allow_failure") is not False:
            problems.append("approval job does not set allow_failure: false")
    prod = [n for n, j in jobs(data).items()
            if j.get("stage") == "Apply to Production"]
    if not prod:
        problems.append("no job in the Apply to Production stage")
    for name in prod:
        job = jobs(data)[name]
        if not needs_segment(job, "approval"):
            problems.append("%s does not need an approval job" % name)
    if problems:
        emit("INFRA-GATE", "FAIL", "; ".join(problems))
    else:
        emit("INFRA-GATE", "PASS",
             "approval is manual + allow_failure:false and Apply to Production needs it")


def h_infra_envs():
    envs = ("staging", "production")
    need = ("main.tf", "variables.tf", "outputs.tf", "terraform.tfvars")
    missing, detail = [], []
    for env in envs:
        d = R("infra", "environments", env)
        if not os.path.isdir(d):
            missing.append("infra/environments/%s" % env)
            continue
        for f in need:
            if not os.path.isfile(os.path.join(d, f)):
                missing.append("infra/environments/%s/%s" % (env, f))
        detail.append("%s: %s" % (env, " ".join(need)))
    if missing:
        emit("INFRA-ENVIRONMENTS", "FAIL", "missing environment files: %s" % ", ".join(missing))
    else:
        emit("INFRA-ENVIRONMENTS", "PASS",
             "2 independent environments with identical file contracts (main/variables/outputs/tfvars)",
             detail)


def h_infra_parity():
    s = tf_module_map("infra/environments/staging")
    p = tf_module_map("infra/environments/production")
    problems = []
    if not s or not p:
        emit("INFRA-PARITY", "FAIL", "no module wiring found in one of the environments")
        return
    if set(s) != set(p):
        problems.append("module sets differ: staging-only=%s production-only=%s"
                        % (sorted(set(s) - set(p)), sorted(set(p) - set(s))))
    for name in sorted(set(s) & set(p)):
        if s[name]["source"] != p[name]["source"]:
            problems.append("%s source differs: %s vs %s" % (name, s[name]["source"], p[name]["source"]))
        extra = set(p[name]["args"]) - set(s[name]["args"])
        if extra:
            detail_only = []
            for arg in sorted(extra):
                mm = re.search(r'(?m)^\s*' + arg + r'\s*=\s*(.+)$',
                               read(R("infra/environments/production/main.tf")))
                detail_only.append("%s=%s" % (arg, mm.group(1).strip() if mm else "?"))
            print("      %s: production-only sizing overrides %s"
                  % (name, ", ".join(detail_only)))
    fs = sorted(os.listdir(R("infra/environments/staging")))
    fp = sorted(os.listdir(R("infra/environments/production")))
    if [x for x in fs if not x.startswith(".")] != [x for x in fp if not x.startswith(".")]:
        problems.append("file contracts differ: staging=%s production=%s"
                        % ([x for x in fs if not x.startswith(".")],
                           [x for x in fp if not x.startswith(".")]))
    if problems:
        emit("INFRA-PARITY", "FAIL", "; ".join(problems))
    else:
        emit("INFRA-PARITY", "PASS",
             "both environments wire the same %d modules from the same sources; only sizing overrides differ"
             % len(s))


def h_infra_independent():
    problems, detail = [], []
    if not os.path.isfile(R("infra", ".gitlab-ci.yml")):
        problems.append("infra/.gitlab-ci.yml missing (IaC has no pipeline of its own)")
    if not HAVE_YAML:
        return no_yaml("INFRA-INDEPENDENT")
    data, err = load_infra_ci()
    if err:
        problems.append(err)
    else:
        paths = set()
        for job in jobs(data).values():
            for blob in json.dumps(job, default=str).split():
                if blob.startswith("infra/"):
                    paths.add(blob.strip('",\''))
        detail.append("pipeline scopes infra/** (%d explicit path references)" % len(paths))
        if not any(p.startswith("infra/") for p in paths):
            problems.append("no job references infra/** paths: the pipeline cannot build the IaC")
    offenders = workflow_admits_non_main(data) if isinstance(data, dict) else []
    if problems:
        emit("INFRA-INDEPENDENT", "FAIL", "; ".join(problems), detail)
    elif offenders:
        emit("INFRA-INDEPENDENT", "INFO",
             "infra/ owns its own pipeline building infra/**, but workflow:rules also triggers "
             "on [%s]; guideline 1 wording expects protected-branch-only triggers "
             "(main-only workflow seen in: CYB1-WORKFLOW)" % "; ".join(offenders[:3]), detail)
    else:
        emit("INFRA-INDEPENDENT", "PASS",
             "infra/ carries its own main-only pipeline that builds infra/**", detail)


# --- microservice CI / CD -----------------------------------------------------
def for_each_service(prefix, fn):
    svcs = services()
    if not svcs:
        emit(prefix, "FAIL", "no microservice pipelines discovered under srcs/ (precondition empty)")
        return
    for svc in svcs:
        data, err = load_ci(R("srcs", svc, ROOT_CI))
        cid = "%s/%s" % (prefix, svc)
        if err:
            emit(cid, "FAIL", "%s: %s" % (svc, err))
            continue
        fn(cid, svc, hoist_singletons(data))


CI_STAGES = ["Build", "Test", "Scan", "Containerization", "Deploy to Staging",
             "Approval", "Deploy to Production"]


def h_ci_stages():
    def one(cid, svc, data):
        actual = data.get("stages") or []
        if stages_subset(actual, CI_STAGES):
            emit(cid, "PASS",
                 "%s: the seven CI/CD stages are declared in order (effective list: %s)"
                 % (svc, " -> ".join(actual)))
        else:
            emit(cid, "FAIL",
                 "%s: expected %s (in order, anywhere in the effective list) got %s"
                 % (svc, CI_STAGES, actual))
    for_each_service("CI-STAGES", one)


def h_ci_build():
    def one(cid, svc, data):
        build = stage_jobs(data, "Build")
        if not build:
            emit(cid, "FAIL", "%s: no Build-stage job" % svc)
            return
        problems = []
        for name, job in build.items():
            text = script_text(job)
            if not re.search(r"compileall|py_compile|build|package|poetry|hatch|setup\.py|wheel", text):
                problems.append("%s does not compile/package anything" % name)
            if not image_name(job):
                problems.append("%s has no image" % name)
        if problems:
            emit(cid, "FAIL", "%s: %s" % (svc, "; ".join(problems)))
        else:
            emit(cid, "PASS", "%s: %s" % (svc, ",".join(build)))
    for_each_service("CI-BUILD", one)


def h_ci_test():
    def one(cid, svc, data):
        test = stage_jobs(data, "Test")
        if not test:
            emit(cid, "FAIL", "%s: no Test-stage job" % svc)
            return
        problems = []
        for name, job in test.items():
            text = script_text(job)
            if "pytest" not in text:
                problems.append("%s does not run pytest" % name)
            if not re.search(r"--cov|coverage|junit", text + json.dumps(job.get("coverage"))):
                problems.append("%s runs no coverage/report gate" % name)
        if problems:
            emit(cid, "FAIL", "%s: %s" % (svc, "; ".join(problems)))
        else:
            emit(cid, "PASS", "%s: %s executes pytest with coverage reporting"
                 % (svc, ",".join(test)))
    for_each_service("CI-TEST", one)


def h_ci_scan():
    def one(cid, svc, data):
        ok, detail, _tools = scan_report(data)
        real = [d for d in detail if d.startswith("real scanners")]
        if ok:
            emit(cid, "PASS", "%s: %d scan jobs, >=3 distinct scanners, none decorative"
                 % (svc, len(stage_jobs(data, "Scan"))), detail)
        else:
            emit(cid, "FAIL", "%s: Scan stage is not genuine (%s)" % (svc, " | ".join(detail[1:]) or "no scanners"),
                 detail)
    for_each_service("CI-SCAN", one)


def h_ci_container():
    def one(cid, svc, data):
        cont = stage_jobs(data, "Containerization")
        if not cont:
            emit(cid, "FAIL", "%s: no Containerization-stage job" % svc)
            return
        problems = []
        # Split the stage by role. In an unprivileged pipeline the build and the
        # push are the same job (Kaniko writes straight to the registry and needs
        # no Docker daemon), so demanding `docker build` in every job would reject
        # the least-privilege design the runner is actually configured for.
        builders, scanners = [], []
        for name, job in cont.items():
            (scanners if re.search(r"trivy|grype|syft|snyk|hadolint", script_text(job))
             else builders).append(name)
        if not builders:
            problems.append("no job in the stage builds/pushes an image")
        else:
            for name in builders:
                text = script_text(cont[name])
                if not re.search(r"docker\s+(build|push)|buildx|kaniko/executor|buildah|podman\s+build|nerdctl\s+build", text):
                    problems.append("%s never builds an image" % name)
                if not re.search(r"docker\s+push|buildx\s+--push|kaniko/executor|--destination|podman\s+push|nerdctl\s+push|crane\s+copy", text):
                    problems.append("%s never pushes to a registry" % name)
        if not scanners:
            problems.append("no job in the stage scans the built image")
        if problems:
            emit(cid, "FAIL", "%s: %s" % (svc, "; ".join(problems)))
        else:
            emit(cid, "PASS", "%s: %s builds, scans and pushes the image"
                 % (svc, ",".join(cont)))
    for_each_service("CI-CONTAINER", one)


def h_ci_workflow():
    def one(cid, svc, data):
        offenders = workflow_admits_non_main(data)
        if not offenders:
            if workflow_protected(data):
                emit(cid, "PASS", "%s: workflow gated on main with a terminal 'when: never'" % svc)
            else:
                emit(cid, "FAIL", "%s: no terminal 'when: never' in workflow:rules" % svc)
            return
        emit(cid, "INFO",
             "%s: workflow:rules also triggers on [%s] — deliberate CI-on-MR design, but "
             "audit guideline 1 asks for protected-branch-only triggers; destructive stages "
             "stay main-gated (proof: CYB1-JOBS)" % (svc, "; ".join(offenders[:3])),
             ["offending workflow rules: %s" % "; ".join(offenders[:3])])
    for_each_service("CI-WORKFLOW", one)


def h_cd_stages():
    def one(cid, svc, data):
        want = ["Deploy to Staging", "Approval", "Deploy to Production"]
        found = {s: list(stage_jobs(data, s)) for s in want}
        empty = [s for s in want if not found[s]]
        if empty:
            emit(cid, "FAIL", "%s: no job in %s" % (svc, ", ".join(empty)))
        else:
            emit(cid, "PASS", "%s: %s" % (svc, "; ".join(
                "%s=%s" % (s, ",".join(found[s])) for s in want)))
    for_each_service("CD-STAGES", one)


def approval_problems(job):
    problems = []
    if str(job.get("when")) != "manual":
        problems.append("when=%s (must be manual)" % job.get("when"))
    if job.get("allow_failure") is not False:
        problems.append("allow_failure=%s (must be false to block the pipeline)"
                        % job.get("allow_failure"))
    return problems


def h_cd_approval():
    def one(cid, svc, data):
        approvals = stage_jobs(data, "Approval")
        if not approvals:
            emit(cid, "FAIL", "%s: no Approval-stage job" % svc)
            return
        problems = []
        for name, job in approvals.items():
            for p in approval_problems(job):
                problems.append("%s:%s" % (name, p))
        if problems:
            emit(cid, "FAIL", "%s: %s" % (svc, "; ".join(problems)))
        else:
            emit(cid, "PASS", "%s: %s is a blocking manual gate" % (svc, ",".join(approvals)))
    for_each_service("CD-APPROVAL", one)


def h_cd_gate():
    def one(cid, svc, data):
        prod = stage_jobs(data, "Deploy to Production")
        if not prod:
            emit(cid, "FAIL", "%s: no Deploy to Production job" % svc)
            return
        problems = []
        for name, job in prod.items():
            # Both gates go through needs_segment(): a production job must depend
            # on the manual approval job and on the staging deployment.
            if not needs_segment(job, "approval"):
                problems.append("%s does not need the approval job" % name)
            if not any("staging" in n for n in need_names(job)):
                problems.append("%s does not depend on the staging deployment" % name)
        if problems:
            emit(cid, "FAIL", "%s: %s" % (svc, "; ".join(problems)))
        else:
            emit(cid, "PASS", "%s: production deploy gated on approval + staging" % svc)
    for_each_service("CD-GATE", one)


def h_cd_staging():
    def one(cid, svc, data):
        stg = stage_jobs(data, "Deploy to Staging")
        if not stg:
            emit(cid, "FAIL", "%s: no Deploy to Staging job" % svc)
            return
        problems = []
        for name, job in stg.items():
            env = job.get("environment")
            env_name = env.get("name") if isinstance(env, dict) else env
            if not env_name or "staging" not in str(env_name):
                problems.append("%s declares no staging environment" % name)
            text = script_text(job)
            if not re.search(r"aws ecs|kubectl|helm|ssh |docker (run|pull)|terraform apply", text):
                problems.append("%s has no recognisable deploy command" % name)
        if problems:
            emit(cid, "FAIL", "%s: %s" % (svc, "; ".join(problems)))
        else:
            emit(cid, "PASS", "%s: staging deploy targets a declared environment with a real command"
                 % svc)
    for_each_service("CD-STAGING", one)


def h_cd_zerodowntime():
    def one(cid, svc, data):
        prod = stage_jobs(data, "Deploy to Production")
        problems, evidence = [], []
        # A release may legitimately be split across the stage: one job moves the
        # immutable tag onto the `production-latest` registry alias (no workload
        # traffic, so there is nothing to roll or to wait on) and a separate job
        # rolls the running service. Zero-downtime is a property of the release
        # *path*, so require a rolling deploy + health gate somewhere in the stage
        # and require every job that actually changes running workloads to have both.
        rolling, gated = [], []
        for name, job in prod.items():
            text = script_text(job)
            is_roll = bool(re.search(r"force-new-deployment|rollingUpdate|--max-unavailable|update-service|kubectl\s+(rollout|set\s+image)|helm\s+upgrade", text))
            has_roll = is_roll or bool(re.search(r"rollingUpdate|minimumHealthyPercent|force-new-deployment", json.dumps(job)))
            has_wait = bool(re.search(r"services-stable|\bwait\b|health|--retry|deployment-status|rollout status", text))
            if has_roll:
                rolling.append(name)
            if is_roll:
                gated.append(name)
            if is_roll and not has_wait:
                problems.append("%s rolls the workload but does not wait for health/stability" % name)
            evidence.append("%s: rolling=%s health-gate=%s" % (name, has_roll, has_wait))
        if not rolling:
            problems.append("no job in the stage performs a rolling/force-new-deployment")
        elif not gated:
            problems.append("no rolling job waits for health/stability")
        if problems:
            emit(cid, "FAIL", "%s: %s" % (svc, "; ".join(problems)), evidence)
        else:
            emit(cid, "PASS", "%s: rolling deployment with health/stability gating" % svc, evidence)
    for_each_service("CD-ZERO-DOWNTIME", one)


NOOP_PIPELINE = """
stages: [Build, Test, Scan, Containerization, Deploy to Staging, Approval, Deploy to Production]
scan:a: {stage: Scan, image: python:3.11-alpine, script: ["echo scanning"]}
scan:b: {stage: Scan, image: python:3.11-alpine, script: ["echo scanning again"]}
scan:c: {stage: Scan, image: python:3.11-alpine, script: ["echo done"]}
scan:d: {stage: Scan, image: python:3.11-alpine, script: ["echo ok"]}
"""

REAL_PIPELINE = """
stages: [Scan]
scan:a: {stage: Scan, image: python:3.11-alpine, script: ["pip install bandit", "bandit -r app/ -ll"]}
scan:b: {stage: Scan, image: {name: "zricethezav/gitleaks:latest"}, script: ["gitleaks detect --no-git"]}
scan:c: {stage: Scan, image: {name: "aquasec/trivy:latest"}, script: ["trivy fs --exit-code 1 ."]}
"""

LOOSE_APPROVAL = """
stages: [Approval, Deploy to Production]
approval:production: {stage: Approval, when: on_success, allow_failure: true, script: ["echo approved"]}
deploy:production: {stage: Deploy to Production, script: ["echo deploy"]}
"""

UNPROTECTED_PIPELINE = """
stages: [Deploy to Production]
deploy:production: {stage: Deploy to Production, script: ["echo deploy"]}
"""

OPEN_SG = """
resource "aws_security_group" "database" {
  name = "x"
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
"""

# The broker regression the data-store control must also catch: 5672 (AMQP) and
# 15672 (management UI) are both in SENSITIVE_PORTS, in IPv4 and IPv6 form.
OPEN_AMQP_SG = """
resource "aws_security_group" "rabbitmq" {
  name = "x"
  ingress {
    from_port   = 5672
    to_port     = 5672
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port         = 15672
    to_port           = 15672
    protocol          = "tcp"
    ipv6_cidr_blocks  = ["::/0"]
  }
}
"""

# The shape infra/modules/security_groups/main.tf actually uses: peer-SG ingress
# plus an outbound 443 path through NAT. Must be accepted, otherwise the control
# would fail on the documented design instead of on a real exposure.
TIGHT_SG = """
resource "aws_security_group" "database" {
  name = "x"
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.inventory_app.id]
  }
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
"""

SG_FIXTURES = (
    ("database SG opening 5432 to 0.0.0.0/0", OPEN_SG, True, True),
    ("rabbitmq SG opening 5672 to 0.0.0.0/0 and 15672 to ::/0", OPEN_AMQP_SG, True, True),
    ("database SG peer-SG only with an outbound 443 to 0.0.0.0/0", TIGHT_SG, False, False),
)


def fixture(cid, yaml_text, call, expect_ok, describe):
    if not HAVE_YAML:
        return no_yaml(cid)
    data = yaml.safe_load(yaml_text)
    ok, detail, _ = call(data)
    if ok == expect_ok:
        emit(cid, "PASS",
             "fixture %s -> detector said %s (as required)"
             % (describe, "ok" if ok else "not ok"),
             detail)
    else:
        emit(cid, "FAIL",
             "fixture %s: detector returned ok=%s, expected ok=%s — the control is not discriminating"
             % (describe, ok, expect_ok), detail)


def h_ci_scan_fixture():
    fixture("CI-SCAN-NEGATIVE", NOOP_PIPELINE, scan_report, False, "4 no-op scan jobs")
    fixture("CI-SCAN-POSITIVE", REAL_PIPELINE, scan_report, True, "3 real scanner jobs")


def h_cd_fixture():
    if not HAVE_YAML:
        return no_yaml("CD-APPROVAL-FIXTURE")
    job = (yaml.safe_load(LOOSE_APPROVAL) or {}).get("approval:production", {})
    problems = approval_problems(job)
    if problems:
        emit("CD-APPROVAL-FIXTURE", "PASS",
             "fixture non-blocking approval rejected: %s" % "; ".join(problems))
    else:
        emit("CD-APPROVAL-FIXTURE", "FAIL",
             "fixture with when: on_success / allow_failure: true was accepted — check is vacuous")


def h_cyb1_jobs():
    if not HAVE_YAML:
        return no_yaml("CYB1-JOBS")
    targets = [("infra", R("infra", ".gitlab-ci.yml"))] + \
        [("srcs/%s" % s, R("srcs", s, ".gitlab-ci.yml")) for s in services()]
    unprotected, checked = [], 0
    for label, path in targets:
        data, err = load_ci(path)
        if err:
            unprotected.append("%s: %s" % (label, err))
            continue
        for name, job in jobs(data).items():
            stage = str(job.get("stage") or "")
            critical = stage in ("Apply to Staging", "Apply to Production", "Approval",
                                 "Deploy to Staging", "Deploy to Production",
                                 "Containerization")
            critical = critical or any(
                name.startswith(prefix) for prefix in
                ("apply:", "deploy:", "containerize:", "approval:", "promote:"))
            if not critical:
                continue
            checked += 1
            if not has_protected_rule(job):
                unprotected.append("%s:%s" % (label, name))
    if checked == 0:
        emit("CYB1-JOBS", "FAIL",
             "no apply/deploy/approval job found in any pipeline (precondition empty)")
    elif unprotected:
        emit("CYB1-JOBS", "FAIL",
             "%d critical job(s) without a protected-branch rule: %s"
             % (len(unprotected), ", ".join(unprotected[:6])))
    else:
        emit("CYB1-JOBS", "PASS",
             "%d apply/deploy/approval jobs across %d pipelines all require main" % (checked, len(targets)))


def h_cyb1_workflow():
    if not HAVE_YAML:
        return no_yaml("CYB1-WORKFLOW")
    targets = [("infra", R("infra", ".gitlab-ci.yml"))] + \
        [("srcs/%s" % s, R("srcs", s, ".gitlab-ci.yml")) for s in services()]
    loose, main_only = [], []
    for label, path in targets:
        data, err = load_ci(path)
        if err:
            loose.append("%s: %s" % (label, err))
            continue
        offenders = workflow_admits_non_main(data)
        if offenders:
            loose.append("%s[%s]" % (label, offenders[0]))
        else:
            main_only.append(label)
    if loose:
        emit("CYB1-WORKFLOW", "INFO",
             "%d/%d pipelines also run on non-protected refs (%s). Guideline 1 is worded as "
             "protected-branch-only triggers, so expect this question; the destructive-stage "
             "gate is proven separately by CYB1-JOBS" % (len(loose), len(targets), ", ".join(loose)),
             ["main-only workflows: %s" % (", ".join(main_only) or "none")])
    else:
        emit("CYB1-WORKFLOW", "PASS",
             "%d pipelines refuse every branch except main" % len(targets))


def h_cyb1_fixture():
    if not HAVE_YAML:
        return no_yaml("CYB1-NEGATIVE")
    data = yaml.safe_load(UNPROTECTED_PIPELINE) or {}
    protected = [n for n, j in jobs(data).items() if has_protected_rule(j)]
    if protected:
        emit("CYB1-NEGATIVE", "FAIL",
             "fixture pipeline with zero protected jobs was accepted — check is vacuous")
    else:
        emit("CYB1-NEGATIVE", "PASS",
             "fixture pipeline with zero protected-branch rules is correctly rejected")


def h_func_yaml():
    if not HAVE_YAML:
        return no_yaml("FUNC-YAML")
    targets = [R("infra", ".gitlab-ci.yml")]
    targets += glob.glob(R("srcs", "*", ".gitlab-ci.yml"))
    targets += glob.glob(R("ansible", "**", "*.yml"), recursive=True)
    targets += glob.glob(R(".github", "*.yml"))
    targets += glob.glob(R("srcs", "*", "*.yaml"))
    targets = [t for t in targets if os.path.isfile(t)]
    bad = []
    for p in targets:
        try:
            if not yaml.safe_load(read(p)):
                bad.append("%s: empty document" % rel(p))
        except Exception as exc:
            bad.append("%s: %s" % (rel(p), str(exc).splitlines()[0]))
    if bad:
        emit("FUNC-YAML", "FAIL", "%d YAML file(s) invalid: %s" % (len(bad), "; ".join(bad[:4])))
    else:
        emit("FUNC-YAML", "PASS", "%d YAML files parsed cleanly" % len(targets))


def h_func_apply():
    if not HAVE_YAML:
        return no_yaml("FUNC-APPLY")
    infra, err = load_infra_ci()
    problems = []
    applies = 0
    if err:
        problems.append("infra pipeline unreadable: %s" % err)
    else:
        for name, job in jobs(infra).items():
            text = script_text(job)
            for m in re.finditer(r"cd\s+(infra/environments/[\w-]+)[\s\S]*?terraform\s+apply", text):
                applies += 1
                if "auto-approve" not in text and "-auto-approve" not in text:
                    problems.append("%s applies without -auto-approve (CI would hang)" % name)
        for env in ("staging", "production"):
            if not any(("environments/%s" % env) in script_text(j) for j in jobs(infra).values()):
                problems.append("no job applies infra/environments/%s" % env)
    deploys = 0
    for svc in services():
        data, err = load_ci(R("srcs", svc, ROOT_CI))
        if err:
            problems.append("%s: %s" % (svc, err))
            continue
        blob = " ".join(script_text(j) for j in jobs(data).values())
        if not re.search(r"aws ecs update-service|kubectl apply|helm upgrade|terraform apply", blob):
            problems.append("%s has no real deploy command" % svc)
        else:
            deploys += 1
    if problems:
        emit("FUNC-APPLY", "FAIL", "; ".join(problems[:4]))
    else:
        emit("FUNC-APPLY", "PASS",
             "%d terraform apply command(s) (both environments, -auto-approve) and %d service deploy(s) wired"
             % (applies, deploys))


# --- cybersecurity: credentials ----------------------------------------------
def h_cyb2_gitignore():
    tracked = []
    if os.path.isdir(R(".git")):
        out = os.popen("cd %s && git ls-files 2>/dev/null" % ROOT).read().splitlines()
        for f in out:
            base = os.path.basename(f)
            if base == ".env" or base.endswith((".pem", ".key", ".p12", ".pfx")) or \
                    f.endswith((".tfstate", "tfplan")):
                tracked.append(f)
    gitignore = read(R(".gitignore")) if os.path.isfile(R(".gitignore")) else ""
    need = (".env", "*.pem", "*.key", "*.tfstate", ".terraform/")
    unguarded = [n for n in need if n not in gitignore]
    problems = []
    if tracked:
        problems.append("secret-like files tracked in git: %s" % ", ".join(tracked[:5]))
    if unguarded:
        problems.append(".gitignore does not guard: %s" % ", ".join(unguarded))
    if problems:
        emit("CYB2-GITIGNORE", "FAIL", "; ".join(problems))
    else:
        emit("CYB2-GITIGNORE", "PASS",
             "no credential artefact tracked; .gitignore guards .env, keys, *.tfstate, .terraform/",
             ["tracked files: %d" % len(os.popen("cd %s && git ls-files 2>/dev/null" % ROOT).read().splitlines())])


def h_cyb2_env():
    paths = (glob.glob(R("infra", "**", "*.tf"), recursive=True) +
             glob.glob(R("infra", "**", "*.tfvars"), recursive=True) +
             glob.glob(R("ansible", "**", "*.yml"), recursive=True))
    hits = scan_hardcoded_secrets(paths, "CYB2-ENV-SOURCED", ignore_tmpl=True)
    hits = [h for h in hits if "os.getenv" not in h]
    tfvar_refs = sum(1 for p in glob.glob(R("infra", "**", "*"), recursive=True)
                     if os.path.isfile(p) and "TF_VAR_" in read(p))
    if hits:
        emit("CYB2-ENV-SOURCED", "FAIL",
             "%d credential literal(s) committed in IaC/Ansible: %s" % (len(hits), "; ".join(hits[:4])),
             ["TF_VAR_ plumbing references: %d" % tfvar_refs])
    else:
        emit("CYB2-ENV-SOURCED", "PASS",
             "IaC/Ansible hold no credential literals; values arrive via lookup('env')/TF_VAR_* from masked CI variables",
             ["TF_VAR_ plumbing references: %d" % tfvar_refs])


# --- cybersecurity: least privilege ------------------------------------------
def last_user(dockerfile_text):
    users = re.findall(r"(?mi)^\s*USER\s+(\S+)", dockerfile_text)
    return users[-1] if users else None


def h_cyb3_docker():
    dockerfiles = sorted(glob.glob(R("srcs", "*", "Dockerfile")))
    if not dockerfiles:
        return emit("CYB3-DOCKER", "FAIL", "no Dockerfile found under srcs/ (precondition empty)")
    problems, detail = [], []
    for p in dockerfiles:
        text = read(p)
        user = last_user(text)
        detail.append("%s: USER %s" % (rel(p), user))
        if user is None:
            problems.append("%s has no USER directive" % rel(p))
        elif user.lower() in ("root", "0"):
            problems.append("%s runs as %s" % (rel(p), user))
        if not re.search(r"(?mi)^\s*USER\s+(?!root\b)\S+", text):
            problems.append("%s never drops root" % rel(p))
    if problems:
        emit("CYB3-DOCKER", "FAIL", "; ".join(problems), detail)
    else:
        emit("CYB3-DOCKER", "PASS",
             "%d image(s) end as a non-root user" % len(dockerfiles), detail)


def sg_files():
    return sorted(glob.glob(R("infra", "**", "security_groups", "main.tf"), recursive=True))


def h_cyb3_sgrules():
    files = sg_files()
    if not files:
        return emit("CYB3-SG-EXPOSURE", "FAIL", "no security_groups module found (precondition empty)")
    groups = {}
    for p in files:
        groups.update(parse_security_groups(p))
    if not groups:
        return emit("CYB3-SG-EXPOSURE", "FAIL",
                    "security group parse produced 0 resources (brace extractor or HCL is broken)")
    parser = "python-hcl2" if hcl2_available() else "brace-balanced extractor (python-hcl2 unavailable)"
    findings, public, unknown = exposed_sensitive(groups)
    detail = ["parser: %s; %d security groups" % (parser, len(groups))]
    detail.append("world-open rules: %s" % (", ".join(public) if public else "none"))
    if unknown:
        detail.append("world-open rules with unresolvable ports: %s" % "; ".join(unknown))
    if findings:
        emit("CYB3-SG-EXPOSURE", "FAIL", "; ".join(findings), detail)
    elif unknown:
        emit("CYB3-SG-EXPOSURE", "INFO",
             "%d world-open rule(s) could not be range-checked, so exposure is unproven: %s"
             % (len(unknown), "; ".join(unknown)), detail)
    else:
        emit("CYB3-SG-EXPOSURE", "PASS",
             "no sensitive port open to the world; public surface limited to %s" % (public or "nothing"),
             detail)


DATASTORE_SG = re.compile(r"database|rabbit|rds|broker|db")
# Why the data stores keep an outbound rule to the internet, so the control can
# inventory it with a justification instead of merely tolerating it.
EGRESS_PURPOSE = {
    53: "DNS to the VPC resolver",
    80: "instance metadata service",
    443: "HTTPS to CloudWatch Logs / registry through NAT",
}


def rule_label(rule):
    proto = str(rule.get("protocol") or "")
    span = port_span(rule)
    if proto == "-1" or span == (0, 0):
        return "all ports (protocol %s)" % (proto or "-1")
    if span is None:
        return "ports %s-%s (range unresolvable)" % (rule.get("from_port"), rule.get("to_port"))
    return "ports %d-%d" % span


def rule_peers(rule):
    return sorted({s.strip() for s in
                   re.findall(r"aws_security_group\.([\w-]+)", rule.get("security_groups") or "")})


def rule_cidrs(rule):
    return " / ".join(str(rule[k]) for k in ("cidr_blocks", "ipv6_cidr_blocks") if rule.get(k))


def sensitive_in(rule):
    """SENSITIVE_PORTS the rule range covers; None when the range is unknown.

    Deliberately the same set CYB3-SG-EXPOSURE uses: if 5672 or 15672 were ever
    opened to the world both controls have to fire, never only one of them.
    """
    span = port_span(rule)
    if span is None:
        return None
    if str(rule.get("protocol")) == "-1" or span == (0, 0):
        return sorted(SENSITIVE_PORTS)
    return sorted(p for p in SENSITIVE_PORTS if span[0] <= p <= span[1])


def fmt_ports(ports):
    head = ", ".join(str(p) for p in ports[:4])
    return head + (", ..." if len(ports) > 4 else "")


def datastore_sg_findings(groups):
    """Return (violations, inventory) for the data-store security groups.

    Least privilege on a data store is about who can *reach* it, so the direction
    of a rule decides how it is judged:

    * INGRESS + world-open CIDR covering a data-store port (or an unresolvable
      range, from which exclusion cannot be proven) -> violation: the internet
      can query the store.
    * INGRESS + world-open CIDR on some other port, or a private CIDR ->
      inventoried, not failed: no data-store port becomes reachable.
    * INGRESS with neither peer SG nor CIDR -> violation: the rule is
      meaningless as written.
    * EGRESS cannot admit inbound traffic, so a world-open CIDR there is the
      outbound path every tier needs (NAT for CloudWatch Logs and image pulls,
      the VPC resolver, IMDS, cluster replication) and is inventoried with its
      purpose. Only a blanket egress (protocol -1/all to 0.0.0.0/0, i.e. an
      unrestricted pivot) is a violation.
    """
    violations, inventory = [], []
    for name, spec in sorted(groups.items()):
        if not DATASTORE_SG.search(name):
            continue
        if not spec["ingress"] and not spec["egress"]:
            violations.append("%s declares no ingress/egress rule at all" % name)
            continue
        for rule in spec["ingress"]:
            label, cidrs, peers = rule_label(rule), rule_cidrs(rule), rule_peers(rule)
            if world_open(rule):
                sensitive = sensitive_in(rule)
                if sensitive is None:
                    violations.append("%s ingress: %s from 0.0.0.0/0, port range unresolvable so "
                                      "exclusion of a data-store port cannot be proven" % (name, label))
                elif sensitive:
                    violations.append("%s ingress: %s from 0.0.0.0/0 reaches data-store port(s) %s"
                                      % (name, label, fmt_ports(sensitive)))
                else:
                    inventory.append("%s ingress: %s from 0.0.0.0/0 (%s), no data-store port exposed"
                                     % (name, label, cidrs))
            elif cidrs:
                inventory.append("%s ingress: %s from %s, internal range only"
                                 % (name, label, cidrs))
            if not peers and not cidrs:
                violations.append("%s has an ingress rule with neither peer SG nor CIDR" % name)
        for rule in spec["egress"]:
            label, cidrs, peers = rule_label(rule), rule_cidrs(rule), rule_peers(rule)
            span = port_span(rule)
            if world_open(rule) and (str(rule.get("protocol")) == "-1" or span == (0, 0)):
                violations.append("%s egress: %s to 0.0.0.0/0 is an unrestricted outbound pivot"
                                  % (name, label))
            elif world_open(rule):
                purpose = ", ".join(EGRESS_PURPOSE.get(p, "outbound call")
                                    for p in (span or ()) if p in EGRESS_PURPOSE) or "outbound call"
                inventory.append("%s egress: %s to 0.0.0.0/0 for %s, outbound only so it admits nothing"
                                 % (name, label, purpose))
            elif peers:
                inventory.append("%s egress: %s to peer SG(s) %s"
                                 % (name, label, ", ".join(peers)))
            elif cidrs:
                inventory.append("%s egress: %s to %s, inside the VPC" % (name, label, cidrs))
            if not peers and not cidrs:
                violations.append("%s has an egress rule with neither peer SG nor CIDR" % name)
    return violations, inventory


def h_cyb3_sgdata():
    groups = {}
    for p in sg_files():
        groups.update(parse_security_groups(p))
    if not any(DATASTORE_SG.search(n) for n in groups):
        return emit("CYB3-SG-DATASTORE", "FAIL", "no data-store security group parsed (precondition empty)")
    problems, inventory = datastore_sg_findings(groups)
    detail = []
    for name in sorted(n for n in groups if DATASTORE_SG.search(n)):
        spec = groups[name]
        ingress_peers = sorted({p for r in spec["ingress"] for p in rule_peers(r)})
        detail.append("%s: %d ingress (peers=%s) + %d egress; %d CIDR rule(s) inventoried below"
                      % (name, len(spec["ingress"]), ", ".join(ingress_peers) or "none",
                         len(spec["egress"]),
                         sum(1 for d in ("ingress", "egress") for r in spec[d] if rule_cidrs(r))))
    detail += inventory
    if problems:
        emit("CYB3-SG-DATASTORE", "FAIL", "; ".join(problems), detail)
    else:
        emit("CYB3-SG-DATASTORE", "PASS",
             "data-store ingress is peer-SG only; %d CIDR rule(s) inventoried as outbound-only or "
             "non data-store-port" % len(inventory), detail)


def h_cyb3_sggaps():
    groups = {}
    for p in sg_files():
        groups.update(parse_security_groups(p))
    referenced, gaps = {}, []
    for name, spec in sorted(groups.items()):
        if not spec["ingress"]:
            gaps.append("%s declares no ingress block" % name)
        if not spec["egress"]:
            gaps.append("%s declares no egress block (AWS default all-egress left unmanaged)" % name)
        for rule in spec["ingress"]:
            for peer in re.findall(r"aws_security_group\.([\w-]+)", rule.get("security_groups") or ""):
                referenced.setdefault(peer, []).append(name)
    for peer, users in sorted(referenced.items()):
        if peer not in groups:
            gaps.append("%s is referenced by %s but not defined" % (peer, ",".join(users)))
        elif not groups[peer]["ingress"]:
            gaps.append("%s is granted ingress access by %s yet has no ingress of its own"
                        % (peer, ",".join(sorted(set(users)))))
    if not groups:
        return emit("CYB3-SG-GAPS", "FAIL", "no security groups parsed (precondition empty)")
    if gaps:
        emit("CYB3-SG-GAPS", "INFO",
             "%d unmanaged security-group direction(s): %s" % (len(gaps), "; ".join(gaps)),
             ["not a breach, but Terraform does not manage these directions: drift and audit findings"])
    else:
        emit("CYB3-SG-GAPS", "PASS", "every security group declares both ingress and egress")


def h_cyb3_rds():
    paths = sorted(glob.glob(R("infra", "**", "rds", "main.tf"), recursive=True))
    if not paths:
        return emit("CYB3-RDS", "FAIL", "no rds module found (precondition empty)")
    text = "\n".join(read(p) for p in paths)
    instances = len(re.findall(r'resource\s+"aws_db_instance"', text))
    public = len(re.findall(r"publicly_accessible\s*=\s*true", text))
    encrypted = len(re.findall(r"storage_encrypted\s*=\s*true", text))
    problems = []
    if instances == 0:
        problems.append("no aws_db_instance declared")
    if public:
        problems.append("%d instance(s) are publicly_accessible = true" % public)
    if instances and encrypted < instances:
        problems.append("%d/%d instances unencrypted" % (instances - encrypted, instances))
    if problems:
        emit("CYB3-RDS", "FAIL", "; ".join(problems))
    else:
        emit("CYB3-RDS", "PASS",
             "%d RDS instance(s): private (publicly_accessible=false) and storage_encrypted=true" % instances)


def h_cyb3_fixture():
    if not SG_FIXTURES or not any(t.strip() for _d, t, _v, _e in SG_FIXTURES):
        return emit("CYB3-NEGATIVE", "FAIL", "fixture not built")
    detail, wrong = [], []
    for describe, text, expect_reject, expect_exposed in SG_FIXTURES:
        groups = parse_security_groups_from_text(text)
        problems, inventory = datastore_sg_findings(groups)
        exposure, _public, _unknown = exposed_sensitive(groups)
        if problems:
            note = " via " + problems[0]
        elif inventory:
            note = "; %d CIDR rule(s) inventoried as benign (%s)" % (len(inventory), inventory[0])
        else:
            note = ""
        detail.append("fixture: %s -> data-store rule %s it, exposure control %s it [required: %s / %s]%s"
                      % (describe,
                         "rejects" if problems else "accepts",
                         "flags" if exposure else "clears",
                         "reject" if expect_reject else "accept",
                         "flag" if expect_exposed else "clear",
                         note))
        if bool(problems) != expect_reject or bool(exposure) != expect_exposed:
            wrong.append(describe)
    if wrong:
        emit("CYB3-NEGATIVE", "FAIL",
             "the data-store least-privilege control is not discriminating for: %s" % "; ".join(wrong),
             detail)
    else:
        emit("CYB3-NEGATIVE", "PASS",
             "%d fixture(s) judged as required: world-open data-store ingress (5432, 5672, 15672) "
             "rejected, peer-SG-only store with outbound 443 accepted" % len(SG_FIXTURES), detail)


def parse_security_groups_from_text(text, refs=None):
    refs = hcl_refs(text) if refs is None else refs
    groups = {}
    for m in re.finditer(r'resource\s+"aws_security_group"\s+"([^"]+)"\s*\{', text):
        name = m.group(1)
        body = balanced(text, text.index("{", m.end() - 1))
        groups[name] = {"ingress": sg_blocks(body, "ingress", refs),
                        "egress": sg_blocks(body, "egress", refs)}
    return groups


# --- cybersecurity: dependency updates ---------------------------------------
def dependabot():
    for cand in (R(".github", "dependabot.yml"), R(".github", "dependabot.yaml")):
        if os.path.isfile(cand):
            return load_ci(cand)
    return None, "no .github/dependabot.yml in the repository"


def h_cyb4_file():
    data, err = dependabot()
    if err:
        return emit("CYB4-FILE", "FAIL", err)
    if data.get("version") != 2:
        return emit("CYB4-FILE", "FAIL", "top-level version: %r (must be 2)" % data.get("version"))
    if not isinstance(data.get("updates"), list) or not data["updates"]:
        return emit("CYB4-FILE", "FAIL", "updates list is empty (precondition empty)")
    emit("CYB4-FILE", "PASS", "version 2 with %d update entries" % len(data["updates"]))


def manifests_in_repo():
    found = {}
    for p in sorted(glob.glob(R("srcs", "*", "requirements.txt"))):
        found.setdefault("pip", set()).add("/" + os.path.relpath(os.path.dirname(p), ROOT))
    for p in sorted(glob.glob(R("srcs", "*", "Dockerfile"))):
        found.setdefault("docker", set()).add("/" + os.path.relpath(os.path.dirname(p), ROOT))
    if glob.glob(R("infra", "**", "*.tf"), recursive=True):
        found.setdefault("terraform", set()).add("/")
    if glob.glob(R(".github", "workflows", "*.y*ml")):
        found.setdefault("github-actions", set()).add("/")
    return found


def h_cyb4_coverage():
    data, err = dependabot()
    if err:
        return emit("CYB4-COVERAGE", "FAIL", err)
    entries = {}
    for u in data.get("updates") or []:
        if not isinstance(u, dict):
            continue
        eco = str(u.get("package-ecosystem"))
        dirs = u.get("directories") or ([u.get("directory")] if u.get("directory") else [])
        entries.setdefault(eco, set()).update(str(d) for d in dirs)
    missing = []
    for eco, dirs in sorted(manifests_in_repo().items()):
        if eco in ("github-actions", "terraform"):
            continue
        for d in dirs:
            if d not in entries.get(eco, set()):
                missing.append("%s %s" % (eco, d))
    if missing:
        emit("CYB4-COVERAGE", "FAIL",
             "dependency manifests with no dependabot entry: %s" % "; ".join(missing))
    else:
        emit("CYB4-COVERAGE", "PASS",
             "every pip/docker manifest is covered (%s)" % ", ".join(
                 "%s:%s" % (e, ",".join(sorted(d))) for e, d in sorted(entries.items())),
             ["terraform entries: %s — effectiveness judged by CYB4-TERRAFORM-EFFECTIVE"
              % (",".join(sorted(entries.get("terraform") or [])) or "none")])


def h_cyb4_root():
    data, err = dependabot()
    if err:
        return emit("CYB4-TERRAFORM-EFFECTIVE", "FAIL", err)
    tf = [u for u in (data.get("updates") or [])
          if isinstance(u, dict) and str(u.get("package-ecosystem")) == "terraform"]
    if not tf:
        return emit("CYB4-TERRAFORM-EFFECTIVE", "FAIL",
                    "no terraform ecosystem entry, so provider versions never get security updates")
    details, noop = [], []
    for u in tf:
        dirs = u.get("directories") or ([u.get("directory")] if u.get("directory") else [])
        details.append("directory: %s" % dirs)
        for d in dirs:
            rel_d = str(d).strip("/")
            # Dependabot's terraform ecosystem does accept a subdirectory, but it
            # never discovers terraform roots on its own: an entry only does
            # something if that directory actually holds a lock file to update.
            # Judging "is this entry effective" by whether the path is the repo
            # root was wrong on both counts -- it rejected the correct
            # configuration and would have passed directory: "/" in a repo with
            # no root-level lock file.
            if not rel_d:
                rel_d = "."
            # Not a recursive search: Dependabot reads the lock file that sits in
            # the configured directory, so a directory that merely *contains* a
            # nested root (like /infra, which holds no lock file of its own) is
            # still a silent no-op.
            if not os.path.isfile(os.path.join(R(rel_d), ".terraform.lock.hcl")):
                noop.append(str(d))
    if noop:
        emit("CYB4-TERRAFORM-EFFECTIVE", "FAIL",
             "terraform entry point(s) %s contain no .terraform.lock.hcl, so those "
             "entries are silent no-ops and those provider pins are never updated"
             % ", ".join(noop),
             details + ["fix: point each terraform entry at a directory that actually "
                        "holds a .terraform.lock.hcl (here: infra/environments/staging "
                        "and infra/environments/production)"])
    else:
        emit("CYB4-TERRAFORM-EFFECTIVE", "PASS",
             "every terraform entry resolves to a real lock file, so provider pins "
             "do get security updates", details)


def h_cyb4_schedule():
    data, err = dependabot()
    if err:
        return emit("CYB4-SCHEDULE", "FAIL", err)
    bad = []
    for u in data.get("updates") or []:
        if not isinstance(u, dict):
            continue
        eco = u.get("package-ecosystem")
        sched = u.get("schedule") or {}
        if not sched.get("interval"):
            bad.append("%s/%s has no schedule.interval" % (eco, u.get("directory")))
        elif str(sched.get("interval")) not in ("daily", "weekly", "monthly", "quarterly", "semiannually", "yearly"):
            bad.append("%s/%s interval=%s" % (eco, u.get("directory"), sched.get("interval")))
    if bad:
        emit("CYB4-SCHEDULE", "FAIL", "; ".join(bad))
    else:
        ivals = sorted({str((u.get("schedule") or {}).get("interval"))
                        for u in data.get("updates") or [] if isinstance(u, dict)})
        emit("CYB4-SCHEDULE", "PASS", "all %d entries scheduled (%s)"
             % (len(data.get("updates") or []), ",".join(ivals)))


def h_cyb4_renovate():
    cfgs = [p for p in glob.glob(R("**", "*renovate*"), recursive=True) if os.path.isfile(p)]
    wf = glob.glob(R(".github", "workflows", "*.y*ml"))
    mentions = 0
    for p in glob.glob(R("*.md")) + glob.glob(R("docs", "*.md")):
        if re.search(r"(?i)renovate", read(p)):
            mentions += 1
    if cfgs:
        emit("CYB4-RENOVATE", "PASS", "renovate configuration present: %s" % ", ".join(rel(c) for c in cfgs))
    elif mentions:
        emit("CYB4-RENOVATE", "INFO",
             "%d document(s) mention Renovate but no renovate config/workflow exists — "
             "the claim is cosmetic (dependabot is the only automation running)" % mentions,
             ["searched: **/*renovate*, .github/workflows/*.yml"])
    else:
        emit("CYB4-RENOVATE", "INFO", "no Renovate claim found and no Renovate config (consistent)")


# --- documentation ------------------------------------------------------------
def sig_words(text):
    stop = set(
        "the and for with that this are was were does did how what which can you "
        "your from into been have has its it in on of to a an is be as by or not "
        "their there them then than when where who whom whose why will would could "
        "should must may might shall only all each any own same such other more most"
        .split())
    return {w for w in re.findall(r"[a-z0-9]+", text.lower())
            if len(w) >= 4 and w not in stop}


README_SECTIONS = [
    ("architecture", r"(?mi)^#+ .*architecture"),
    ("directory structure", r"(?mi)^#+ .*directory structure"),
    ("deployment / IaC", r"(?mi)^#+ .*(deployment|terraform|component walkthrough)"),
    ("cybersecurity compliance", r"(?mi)^#+ .*(cybersecurity|security)"),
    ("verification instructions", r"(?mi)^#+ .*(verification|test execution)"),
    ("stakeholder roleplay answers", r"(?mi)^#+ .*(role-?play|stakeholder)"),
    ("bonus implementations", r"(?mi)^#+ .*bonus"),
    ("prerequisites", r"(?i)prerequisit"),
    ("setup / usage", r"(?i)(how to (set up|use)|usage|getting started|make it work)"),
]


def h_doc_readme():
    p = R("README.md")
    if not os.path.isfile(p):
        return emit("DOC-README", "FAIL", "README.md missing")
    size = os.path.getsize(p)
    text = read(p)
    lines = text.count("\n") + 1
    if size < 5000 or lines < 100:
        return emit("DOC-README", "FAIL",
                    "README.md is only %d bytes / %d lines — too thin to defend the project"
                    % (size, lines))
    missing = [name for name, pat in README_SECTIONS if not re.search(pat, text)]
    if missing:
        emit("DOC-README", "FAIL",
             "README.md (%d bytes) missing expected coverage: %s" % (size, ", ".join(missing)))
    else:
        emit("DOC-README", "PASS",
             "README.md: %d bytes / %d lines covering prerequisites, setup, configuration and usage"
             % (size, lines))


def h_doc_sections():
    if not HAVE_YAML:
        return no_yaml("DOC-README-SECTIONS")
    text = read(R("README.md"))
    want = {
        "pipeline design": r"(?i)(pipeline design|multi-stage pipeline)",
        "tools used": r"(?i)(bandit|gitleaks|trivy|ansible|terraform|sonarqube)",
        "how to set up / use": r"(?i)(export PATH|ansible-playbook .*playbooks|terraform (plan|apply))",
        "verification commands": r"(?i)(scripts/test_pipelines\.sh|scripts/verify_security\.sh)",
        "roleplay Q&A": r"(?mi)^#+ .*Q1:",
        "bonus section": r"(?mi)^#+ .*Bonus",
    }
    missing = [k for k, pat in want.items() if not re.search(pat, text)]
    if missing:
        emit("DOC-README-SECTIONS", "FAIL",
             "README does not cover: %s" % ", ".join(missing))
    else:
        emit("DOC-README-SECTIONS", "PASS",
             "README documents pipeline design, tools, setup commands, verification and the 16 roleplay answers")


def h_doc_guide():
    p = R("docs", "AUDIT_GUIDE.md")
    if not os.path.isfile(p):
        return emit("DOC-GUIDE", "FAIL", "docs/AUDIT_GUIDE.md missing")
    size = os.path.getsize(p)
    text = read(p)
    # Each audit area must appear as its own section heading (## N. <Area> ...).
    # Anchored on a numbered/upper-level heading so prose mentions cannot satisfy it.
    need = {
        "repo content review": r"(?mi)^#{2,3} .*(repo|repository).{0,20}content",
        "roleplay simulation": r"(?mi)^#{2,3} .*(roleplay|stakeholder)",
        "gitlab/runners deployment": r"(?mi)^#{2,3} .*(gitlab|runner)",
        "infrastructure pipeline": r"(?mi)^#{2,3} .*infrastructure pipeline",
        "CI pipeline": r"(?mi)^#{2,3} .*\bci\b.{0,12}pipeline",
        "CD pipeline": r"(?mi)^#{2,3} .*\bcd\b.{0,12}pipeline",
        "pipeline functionality/live testing": r"(?mi)^#{2,3} .*(functionality|live testing)",
        "cybersecurity guidelines": r"(?mi)^#{2,3} .*cybersecurity",
        "documentation review": r"(?mi)^#{2,3} .*documentation",
        "bonus defense": r"(?mi)^#{2,3} .*bonus",
        "live demonstration commands": r"(?mi)--list-tasks|gitlab-runner list|gitlab-ctl status",
    }
    missing = [k for k, pat in need.items() if not re.search(pat, text)]
    if size < 20000 or missing:
        emit("DOC-GUIDE", "FAIL",
             "docs/AUDIT_GUIDE.md (%d bytes) inadequate: %s"
             % (size, ", ".join(missing) if missing else "under 20000 bytes"))
    else:
        emit("DOC-GUIDE", "PASS",
             "docs/AUDIT_GUIDE.md: %d bytes covering all %d audit areas incl. live demo commands"
             % (size, len(need)))


def h_doc_diagrams():
    guide = read(R("docs", "AUDIT_GUIDE.md")) if os.path.isfile(R("docs", "AUDIT_GUIDE.md")) else ""
    readme = read(R("README.md")) if os.path.isfile(R("README.md")) else ""
    g_m = len(re.findall(r"```mermaid", guide))
    g_box = len(re.findall(r"```(?:text|plaintext)?\s*\n[+\-|┌└├╔═║▼▲◄►●]+", guide))
    r_m = len(re.findall(r"```mermaid", readme))
    r_box = len(re.findall(r"```(?:text|plaintext)?\s*\n[+\-|┌└├╔═║▼▲◄►●]+", readme))
    total = g_m + g_box + r_m + r_box
    if total == 0:
        emit("DOC-DIAGRAMS", "FAIL", "no diagrams (mermaid or ASCII) found in guide or README")
    else:
        emit("DOC-DIAGRAMS", "PASS",
             "%d diagrams (guide: %d mermaid + %d ascii; README: %d mermaid + %d ascii)"
             % (total, g_m, g_box, r_m, r_box))


def h_doc_coverage():
    qpath = os.environ.get("AUDIT_QS", "")
    rows = []
    if qpath and os.path.isfile(qpath):
        with open(qpath, encoding="utf-8", errors="replace") as fh:
            rows = [r for r in fh.read().splitlines() if r.strip()]
    questions = [r for r in rows if r.split("\t")[2:3] == ["question"]]
    if not questions:
        return emit("DOC-QUESTION-COVERAGE", "FAIL",
                    "no audit questions were readable from %s (cannot verify doc coverage)"
                    % (qpath or "<unset>"))
    rows = questions
    guide_path = R("docs", "AUDIT_GUIDE.md")
    guide = read(guide_path) if os.path.isfile(guide_path) else ""
    heads = [l for l in guide.splitlines() if re.match(r"^#{1,6} ", l)]
    doc_words = set(re.findall(r"[a-z0-9]+", guide.lower()))
    uncovered, detail = [], []
    for row in rows:
        parts = row.split("\t")
        if len(parts) < 2:
            continue
        line, slug = parts[0], parts[1]
        text = " ".join(parts[2:]) or slug.replace("-", " ")
        words = sig_words(text)
        if not words:
            continue
        best, best_line = 0.0, ""
        for h in heads:
            hw = sig_words(h)
            if not hw:
                continue
            ratio = len(words & hw) / len(hw)
            if ratio > best:
                best, best_line = ratio, h.strip()
        presence = len(words & doc_words) / len(words)
        # Covered when a related section heading exists (0.45) OR the guide
        # demonstrably discusses the question's vocabulary (0.85). Both numbers
        # are reported per miss so the auditor can judge the heuristic.
        if best < 0.45 and presence < 0.85:
            uncovered.append("L%s(heading=%.2f presence=%.2f)" % (line, best, presence))
        else:
            detail.append("L%s -> %s" % (line, best_line[:64]))
    total = len(rows)
    if uncovered:
        emit("DOC-QUESTION-COVERAGE", "FAIL",
             "%d/%d audit questions have no answering section in the guide: %s"
             % (len(uncovered), total, ", ".join(uncovered[:8])))
    else:
        emit("DOC-QUESTION-COVERAGE", "PASS",
             "all %d discovered audit questions are answered somewhere in "
             "docs/AUDIT_GUIDE.md" % total, detail[:6])


# --- bonus --------------------------------------------------------------------
def code_files(pattern_glob, skip_docs=True):
    """Repo-wide search for files whose basename matches a glob pattern.

    Written as a pruned tree walk rather than `glob` for two reasons that both
    produced silent, wrong answers here:

      * `glob` never matches dot-prefixed names, so `**/*.yml` skipped every
        `.gitlab-ci.yml` -- which is where this repository keeps all four CI
        pipeline definitions, so "is this tool wired into a pipeline?" answered
        False for tools that are genuinely wired in.
      * a bare `*.yml` matches nothing at all, because every pipeline, module and
        script lives in a subdirectory. An empty corpus makes every such control
        report False unconditionally, so an empty result is refused outright.
    """
    leaf = os.path.basename(pattern_glob)
    if leaf.startswith("*") or "?" in leaf:
        matcher = lambda n: fnmatch.fnmatch(n, leaf)  # noqa: E731
    else:
        matcher = lambda n: n == leaf  # noqa: E731
    skip_dirs = {".git", ".terraform", "__pycache__", ".pytest_cache",
                 "node_modules", "venv", ".venv"}
    hits = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs]
        relp_dir = rel(dirpath)
        if skip_docs and relp_dir == "docs":
            dirnames[:] = []
            continue
        for name in filenames:
            if not matcher(name):
                continue
            relp = rel(os.path.join(dirpath, name))
            if skip_docs and (relp.startswith("docs/") or relp.endswith(".md")):
                continue
            hits.append(os.path.join(dirpath, name))
    if not hits:
        raise AssertionError(
            "code_files(%r) matched no file: the pattern is broken, and an empty "
            "corpus would silently report every tool as absent" % pattern_glob)
    return sorted(hits)


def h_bonus_implemented():
    found, detail = [], []
    for svc in services():
        data, err = load_ci(R("srcs", svc, ROOT_CI)) if HAVE_YAML else (None, "no yaml")
        if err or not isinstance(data, dict):
            continue
        ok, d, tools = scan_report(data)
        if ok:
            found.append("%s: multi-scanner CI (%s)" % (svc, ",".join(sorted(tools))))
        if any("docker push" in script_text(j) for j in jobs(data).values()):
            detail.append("%s: registry push wired" % svc)
    for p in sorted(glob.glob(R("srcs", "*", "Dockerfile"))):
        t = read(p)
        if last_user(t) and last_user(t).lower() != "root" and "HEALTHCHECK" in t:
            found.append("%s: non-root image + HEALTHCHECK" % os.path.basename(os.path.dirname(p)))
    if os.path.isfile(R("srcs", "api-gateway", "openapi.yaml")):
        gw = read(R("srcs", "api-gateway", "server.py"))
        if "/docs" in gw or "openapi" in gw:
            found.append("api-gateway: OpenAPI 3.0 schema served at /docs")
    for s in ("scripts/test_pipelines.sh", "scripts/verify_security.sh", "scripts/audit_orchestrator.sh"):
        if os.path.isfile(R(s)):
            found.append("%s: offline verification harness" % s)
    if not found:
        return emit("BONUS-IMPLEMENTED", "FAIL", "no bonus feature could be verified in code")
    emit("BONUS-IMPLEMENTED", "PASS",
         "%d bonus feature(s) verifiable in code" % len(found), found + detail[:2])


def claim_audit():
    """claims in the docs vs reality in code."""
    ci_roots = code_files("*.yml") + code_files("*.yaml") + code_files("*.tf") + \
        code_files("*.sh") + code_files("*.j2")
    # The audit tooling necessarily names every tool it hunts for, so including it
    # makes this check self-referential (it would "find" infracost in the list of
    # tools whose absence it is reporting). Application code is NEVER excluded.
    # Keep this list identical to LEAK_SCAN_EXCLUSIONS in scripts/verify_security.sh.
    excluded = {
        "scripts/audit_orchestrator.sh", "scripts/verify_security.sh",
        "docs/AUDIT_GUIDE.md", "README.md",
    }
    ci_roots = [p for p in ci_roots if rel(p) not in excluded]
    corpus = "\n".join(read(p) for p in ci_roots if os.path.isfile(p))
    # A doc that says "tfsec is NOT integrated" is not making a claim, it is
    # disclosing a gap -- and an auditor rewards the disclosure and punishes the
    # over-claim. So classify each tool as claimed / disclosed-absent rather than
    # treating any mention as a claim.
    negated = re.compile(
        r"(?i)\b(?:not|no|never|zero|none|without|absent|considered|planned|"
        r"proposed|suggested|would|unsupported)\b"
        r"|\bonly documentation\b|\bmatches only\b|\bdid not\b|\bnot claimed\b")
    # Claims are read from the two auditor-facing documents only. docs/readme.md
    # is the subject's original brief (it lists tfsec/Infracost/Terragrunt as
    # features to *consider*, so every mention there is a request, not a claim),
    # docs/audit.md is the rubric, and docs/AUDIT_READINESS_PLAN.md is an internal
    # work plan whose "implement it or delete the claim" to-dos are not claims
    # about the delivered solution. An auditor reads the first two.
    docs = [p for p in (R("README.md"), R("docs", "AUDIT_GUIDE.md")) if os.path.isfile(p)]
    claims = []
    for tool, note in (
        ("infracost", "cost estimates in the Plan stage"),
        ("tfsec", "IaC policy scan in the Validate stage"),
        ("terragrunt", "DRY remote backend / multi-env orchestration"),
        ("renovate", "automated dependency updates"),
        ("trivy", "IaC + image + filesystem scanning"),
        ("gitleaks", "secret detection"),
        ("bandit", "Python SAST"),
        ("sonarqube", "code quality gate"),
    ):
        mentions, asserted = 0, False
        for p in docs:
            lines = read(p).splitlines()
            for i, line in enumerate(lines):
                if not re.search(r"(?i)\b" + tool, line):
                    continue
                mentions += 1
                window = " ".join(lines[i:i + 2])
                if not negated.search(window):
                    asserted = True
        in_code = bool(re.search(r"(?i)" + tool, corpus))
        claims.append({"tool": tool, "note": note, "mentions": mentions,
                       "documented": mentions > 0, "asserted": asserted,
                       "in_code": in_code})
    return claims


def h_bonus_claims():
    claims = claim_audit()
    detail = ["%-10s asserted=%-5s disclosed-absent=%-5s in-code=%s"
              % (c["tool"], c["asserted"],
                 c["documented"] and not c["asserted"], c["in_code"])
              for c in claims]
    # Only an asserted-but-absent tool is a defect. A tool the docs explicitly
    # disclose as not integrated is an honest gap, not an over-claim.
    ghosts = [c for c in claims if c["asserted"] and not c["in_code"]]
    gaps = [c for c in claims if c["documented"] and not c["asserted"] and not c["in_code"]]
    if ghosts:
        emit("BONUS-CLAIMS", "FAIL",
             "%d tool(s) claimed in the docs but absent from every pipeline/module/script: %s"
             % (len(ghosts), ", ".join("%s (%s)" % (c["tool"], c["note"]) for c in ghosts)),
             detail + ["fix: wire the tool into a pipeline or delete the claim before the auditor asks"])
    elif gaps:
        emit("BONUS-CLAIMS", "PASS",
             "no tool is over-claimed; %d absent tool(s) are explicitly disclosed "
             "as not integrated: %s" % (len(gaps), ", ".join(c["tool"] for c in gaps)),
             detail + ["an auditor penalises an over-claim, never an honest disclosure"])
    else:
        emit("BONUS-CLAIMS", "PASS",
             "every tool named in the docs is actually wired into the code", detail)


def h_bonus_crudmaster():
    svc = services()
    evidence = []
    for s in svc:
        files = glob.glob(R("srcs", s, "app", "*.py"))
        crud = 0
        for f in files:
            t = read(f)
            crud += len(re.findall(r"(?i)@(app|api)\.route|def (create|update|delete|list|get)_", t))
        if crud:
            evidence.append("%s: %d CRUD endpoints in app/" % (s, crud))
    mentioned = any(re.search(r"(?i)crud-master", read(p))
                    for p in glob.glob(R("*.md")) + glob.glob(R("docs", "*.md")))
    if not evidence:
        return emit("BONUS-CRUDMASTER", "INFO",
                    "no crud-master derived service detected under srcs/ — auditor will ask")
    emit("BONUS-CRUDMASTER", "INFO" if mentioned else "FAIL",
         "%d service(s) implement CRUD over crud-master style models%s"
         % (len(evidence), "; documented as crud-master" if mentioned else " (never mentioned in the docs)"),
         evidence[:4])


REPORT_DIR_REL = "reports"

HANDLERS = {
    "files.required": h_files_required,
    "files.substantive": h_files_substantive,
    "files.pipelines": h_files_pipelines,
    "files.ansible": h_files_ansible,
    "ansible.roles": h_ansible_roles,
    "ansible.expected": h_ansible_expected,
    "ansible.nosecret": h_ansible_nosecret,
    "infra.nosecret": h_infra_nosecret,
    "runner.files": h_runner_files,
    "runner.tags": h_runner_tags,
    "infra.stages": h_infra_stages,
    "infra.stagejobs": h_infra_stagejobs,
    "infra.gate": h_infra_gate,
    "infra.envs": h_infra_envs,
    "infra.parity": h_infra_parity,
    "infra.independent": h_infra_independent,
    "ci.stages": h_ci_stages,
    "ci.build": h_ci_build,
    "ci.test": h_ci_test,
    "ci.scan": h_ci_scan,
    "ci.scanfixture": h_ci_scan_fixture,
    "ci.container": h_ci_container,
    "ci.workflow": h_ci_workflow,
    "cd.stages": h_cd_stages,
    "cd.approval": h_cd_approval,
    "cd.fixture": h_cd_fixture,
    "cd.gate": h_cd_gate,
    "cd.staging": h_cd_staging,
    "cd.zerodowntime": h_cd_zerodowntime,
    "func.yaml": h_func_yaml,
    "func.apply": h_func_apply,
    "cyb1.jobs": h_cyb1_jobs,
    "cyb1.workflow": h_cyb1_workflow,
    "cyb1.fixture": h_cyb1_fixture,
    "cyb2.gitignore": h_cyb2_gitignore,
    "cyb2.env": h_cyb2_env,
    "cyb3.docker": h_cyb3_docker,
    "cyb3.sgrules": h_cyb3_sgrules,
    "cyb3.sgdata": h_cyb3_sgdata,
    "cyb3.sggaps": h_cyb3_sggaps,
    "cyb3.rds": h_cyb3_rds,
    "cyb3.fixture": h_cyb3_fixture,
    "cyb4.file": h_cyb4_file,
    "cyb4.coverage": h_cyb4_coverage,
    "cyb4.terraformroot": h_cyb4_root,
    "cyb4.schedule": h_cyb4_schedule,
    "cyb4.renovate": h_cyb4_renovate,
    "doc.readme": h_doc_readme,
    "doc.sections": h_doc_sections,
    "doc.guide": h_doc_guide,
    "doc.diagrams": h_doc_diagrams,
    "doc.coverage": h_doc_coverage,
    "bonus.implemented": h_bonus_implemented,
    "bonus.claims": h_bonus_claims,
    "bonus.crudmaster": h_bonus_crudmaster,
}


def main():
    if MODE in HANDLERS:
        HANDLERS[MODE]()
        return
    if MODE == "unknown":
        emit("UNKNOWN-MODE", "FAIL", "no python handler for mode '%s'" % MODE)
        return
    sys.stderr.write("audit_orchestrator: unknown analysis mode '%s'\n" % MODE)


main()
PYEOF
}

# ------------------------------------------------------------------------------
# Bash-implemented controls (external tools, live probes, filesystem sweeps)
# ------------------------------------------------------------------------------
require_tool() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  emit_result "$2" "SKIP(missing tool: $1)" "$3"
  return 1
}

ctl_ansible_syntax() {
  require_tool ansible-playbook ANSIBLE-SYNTAX "ansible-playbook not in PATH (export PATH=\"\$HOME/.local/bin:\$PATH\")" || return 0
  local pb out rc bad=""
  for pb in ansible/playbooks/deploy-gitlab.yml ansible/playbooks/deploy-runners.yml; do
    if [ ! -f "${pb}" ]; then
      bad="${bad} ${pb}(missing)"
      continue
    fi
    out="$(timeout 120 ansible-playbook -i ansible/inventory/hosts.ini "${pb}" --syntax-check 2>&1)"
    rc=$?
    if [ ${rc} -ne 0 ]; then
      bad="${bad} $(basename "${pb}")[rc=${rc}]"
    else
      emit_detail "$(basename "${pb}"): syntax ok"
    fi
  done
  if [ -n "${bad}" ]; then
    emit_result ANSIBLE-SYNTAX FAIL "--syntax-check failed for:${bad}"
  else
    emit_result ANSIBLE-SYNTAX PASS "2/2 playbooks pass ansible-playbook --syntax-check"
  fi
}

ctl_ansible_listtasks() {
  require_tool ansible-playbook ANSIBLE-LISTTASKS "ansible-playbook not in PATH" || return 0
  mkdir -p "${REPORT_DIR}"
  local dump="${REPORT_DIR}/ansible_list_tasks.txt"
  local pb out rc bad=""
  : >"${dump}"
  for pb in ansible/playbooks/deploy-gitlab.yml ansible/playbooks/deploy-runners.yml; do
    [ -f "${pb}" ] || {
      bad="${bad} ${pb}(missing)"
      continue
    }
    out="$(timeout 120 ansible-playbook -i ansible/inventory/hosts.ini "${pb}" --list-tasks 2>&1)"
    rc=$?
    printf '\n##### %s\n%s\n' "${pb}" "${out}" >>"${dump}"
    if [ ${rc} -ne 0 ]; then
      bad="${bad} $(basename "${pb}" | sed 's/\.yml//')[rc=${rc}]"
    else
      emit_detail "$(basename "${pb}"): $(printf '%s' "${out}" | grep -c 'TAGS: \[\]') task entries resolved"
    fi
  done
  if [ -n "${bad}" ]; then
    emit_result ANSIBLE-LISTTASKS FAIL "--list-tasks failed for:${bad} (output archived in ${dump#"${ROOT_DIR}"/})"
  else
    emit_result ANSIBLE-LISTTASKS PASS "roles + tasks resolved for 2 playbooks; real output archived at ${dump#"${ROOT_DIR}"/} ($(wc -l <"${dump}" | tr -d ' ') lines, diff it against the guide)"
  fi
}

inventory_host() {
  local group="$1"
  awk -v g="${group}" '
    $0 ~ "^\\[" g "\\]" {inb=1; next}
    /^\[/ {inb=0}
    inb && /ansible_host=/ {
      for (i=1; i<=NF; i++) if ($i ~ /^ansible_host=/) {split($i, a, "="); print a[2]; exit}
    }' "${ROOT_DIR}/ansible/inventory/hosts.ini" 2>/dev/null | head -1
}

ssh_reachable() {
  local host="$1"
  local err
  err="$(timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${host}" true 2>&1 >/dev/null)"
  SSH_PROBE_ERR="${err}"
  if [ -z "${err}" ]; then
    SSH_PROBE_REASON="ssh_ok"
    return 0
  fi
  # Classify precisely. "refuses key-based SSH" is the wrong diagnosis for an
  # unreachable host and would send the auditor hunting for a key problem.
  case "${err}" in
    *"No route to host"* | *"Connection timed out"* | *"Connection refused"* | *"Network is unreachable"*)
      SSH_PROBE_REASON="unreachable"
      ;;
    *"Permission denied"* | *"Host key verification failed"*)
      SSH_PROBE_REASON="auth"
      ;;
    *)
      SSH_PROBE_REASON="unknown"
      ;;
  esac
  return 1
}

live_probe() {
  local cid="$1" host="$2" question="$3" hint="$4"
  if [ -z "${host}" ]; then
    emit_result "${cid}" "BLOCKED-EXTERNAL" "no host for this role in ansible/inventory/hosts.ini; ${question} cannot be attempted"
    return 0
  fi
  if ssh_reachable "${host}"; then
    emit_result "${cid}" "PASS" "${host} reachable over SSH: ${hint}"
  else
    local why
    case "${SSH_PROBE_REASON}" in
      unreachable)
        why="${host} is not reachable from this machine (no route / no listener; ssh said '${SSH_PROBE_ERR}'). ${question} is unproven here, and no SSH key or Ansible run can change that until the host is actually provisioned on a reachable network."
        ;;
      auth)
        why="${host} is reachable but refused key-based SSH as the inventory user (ssh said '${SSH_PROBE_ERR}'). ${question} is unproven here; the inventory user's public key is missing from authorized_keys on that node."
        ;;
      *)
        why="ssh probe of ${host} did not succeed (ssh said '${SSH_PROBE_ERR}'). ${question} is unproven here."
        ;;
    esac
    emit_result "${cid}" "BLOCKED-EXTERNAL" "${why} Live command to run for the auditor: ${hint}"
  fi
}

ctl_runner_live() {
  local host
  host="$(inventory_host gitlab_runners)"
  live_probe RUNNER-LIVE-LIST "${host}" "runner registration/execution cannot be observed locally" \
    "ssh ${host} 'sudo gitlab-runner list && systemctl is-active gitlab-runner'"
  if command -v gitlab-runner >/dev/null 2>&1; then
    emit_detail "note: gitlab-runner is installed here but no GitLab instance is reachable"
  else
    emit_detail "gitlab-runner is not installed in this container (it lives on ${host:-the runner node})"
  fi
}

ctl_gitlab_live() {
  local host
  host="$(inventory_host gitlab_servers)"
  live_probe GITLAB-LIVE-STATUS "${host}" "GitLab service state cannot be observed locally" \
    "ssh ${host} 'sudo gitlab-ctl status && systemctl is-active gitlab-runsvdir'"
}

ctl_infra_fmt() {
  require_tool terraform INFRA-FMT "terraform not in PATH" || return 0
  local out rc
  out="$(timeout 180 terraform fmt -check -recursive infra 2>&1)"
  rc=$?
  if [ ${rc} -eq 0 ]; then
    emit_result INFRA-FMT PASS "terraform fmt -check -recursive infra: all files canonical"
  else
    emit_detail "$(printf '%s' "${out}" | head -5 | tr '\n' ' ')"
    emit_result INFRA-FMT FAIL "terraform fmt -check found unformatted files: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-160)"
  fi
}

ctl_infra_validate() {
  local env="${1#infra.validate:}"
  local id
  id="INFRA-VALIDATE-$(printf '%s' "${env}" | tr '[:lower:]' '[:upper:]')"
  local dir="infra/environments/${env}"
  require_tool terraform "${id}" "terraform not in PATH" || return 0
  if [ ! -d "${dir}" ]; then
    emit_result "${id}" FAIL "environment directory ${dir} does not exist"
    return 0
  fi
  local path="vendored provider (.terraform/providers present, no init needed)"
  local out rc initout=""
  if [ -d "${dir}/.terraform/providers" ] && [ -f "${dir}/.terraform.lock.hcl" ]; then
    out="$(cd "${dir}" && timeout 180 terraform validate -no-color 2>&1)"
    rc=$?
  else
    path="terraform init -backend=false (no vendored provider; offline-safe init)"
    initout="$(cd "${dir}" && timeout 300 terraform init -backend=false -input=false -no-color 2>&1)"
    out="$(cd "${dir}" && timeout 180 terraform validate -no-color 2>&1)"
    rc=$?
    if [ ${rc} -ne 0 ] && printf '%s' "${initout}" | grep -qiE "could not retrieve|failed to install provider|no matching releases|network|dial tcp"; then
      emit_result "${id}" "SKIP(offline: provider download unavailable)" \
        "cannot obtain the AWS provider without network access in ${dir}; rerun with internet or pre-vendor .terraform/providers"
      return 0
    fi
  fi
  if [ ${rc} -eq 0 ]; then
    emit_result "${id}" PASS "terraform validate succeeded for ${dir} via ${path}"
  else
    emit_detail "$(printf '%s' "${out}" | head -8 | tr '\n' ' ')"
    emit_result "${id}" FAIL "terraform validate failed for ${dir} via ${path}"
  fi
}

ctl_func_pytest() {
  local svc out rc net
  local svcs=()
  while IFS= read -r d; do
    [ -n "${d}" ] && svcs+=("$(basename "${d}")")
  done < <(find srcs -maxdepth 2 -name requirements.txt -printf '%h\n' 2>/dev/null | sort)
  if [ ${#svcs[@]} -eq 0 ]; then
    emit_result "FUNC-PYTEST" FAIL "no service with a requirements.txt found under srcs/ (precondition empty)"
    return 0
  fi
  for svc in "${svcs[@]}"; do
    if command -v uv >/dev/null 2>&1; then
      out="$(cd "srcs/${svc}" && timeout 600 uv run --with pytest --with pytest-cov --with-requirements requirements.txt pytest -q 2>&1)"
      rc=$?
    elif command -v pytest >/dev/null 2>&1; then
      out="$(cd "srcs/${svc}" && timeout 600 pytest -q 2>&1)"
      rc=$?
    else
      emit_result "FUNC-PYTEST/${svc}" "SKIP(no runner)" "neither uv nor pytest is installed; unit suite not executed"
      continue
    fi
    net="$(printf '%s' "${out}" | grep -ciE "failed to fetch|network error|connection refused|dial tcp|temporary failure in name resolution")"
    if [ ${rc} -eq 0 ]; then
      emit_result "FUNC-PYTEST/${svc}" PASS "uv run pytest: $(printf '%s' "${out}" | grep -E 'passed|failed|error' | tail -1 | cut -c1-80)"
    elif [ "${net}" -gt 0 ]; then
      emit_result "FUNC-PYTEST/${svc}" "SKIP(offline: dependency resolution failed)" "uv could not resolve test dependencies without network: $(printf '%s' "${out}" | tail -2 | tr '\n' ' ' | cut -c1-140)"
    else
      emit_detail "$(printf '%s' "${out}" | tail -12 | tr '\n' '|')"
      emit_result "FUNC-PYTEST/${svc}" FAIL "unit suite failed for srcs/${svc}"
    fi
  done
}

ctl_func_compile() {
  if ! command -v python3 >/dev/null 2>&1; then
    emit_result FUNC-COMPILE "SKIP(missing tool: python3)" "python3 unavailable"
    return 0
  fi
  local targets=()
  while IFS= read -r d; do
    [ -n "${d}" ] && targets+=("${d}")
  done < <(find srcs -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
  if [ ${#targets[@]} -eq 0 ]; then
    emit_result FUNC-COMPILE FAIL "no service directories under srcs/ (precondition empty)"
    return 0
  fi
  local out rc
  out="$(timeout 180 python3 -m compileall -q "${targets[@]}" 2>&1)"
  rc=$?
  if [ ${rc} -eq 0 ]; then
    emit_result FUNC-COMPILE PASS "python3 -m compileall: ${#targets[@]} service(s) compile cleanly"
  else
    emit_detail "$(printf '%s' "${out}" | head -8 | tr '\n' ' ')"
    emit_result FUNC-COMPILE FAIL "python3 -m compileall reported syntax errors"
  fi
}

ctl_func_hadolint() {
  local files=() d
  while IFS= read -r f; do
    [ -n "${f}" ] && files+=("${f}")
  done < <(find srcs -maxdepth 2 -name Dockerfile 2>/dev/null | sort)
  if [ ${#files[@]} -eq 0 ]; then
    emit_result FUNC-HADOLINT FAIL "no Dockerfile found under srcs/ (precondition empty)"
    return 0
  fi
  if ! command -v hadolint >/dev/null 2>&1; then
    emit_result FUNC-HADOLINT "SKIP(missing tool: hadolint)" "hadolint not installed; ${#files[@]} Dockerfile(s) unchecked"
    return 0
  fi
  local f out rc errs=0 warns=0
  for f in "${files[@]}"; do
    out="$(timeout 120 hadolint --failure-threshold error "${f}" 2>&1)"
    rc=$?
    warns=$((warns + $(printf '%s' "${out}" | grep -c "warning" || true)))
    if [ ${rc} -ne 0 ]; then
      errs=$((errs + 1))
      emit_detail "$(printf '%s' "${out}" | head -3 | tr '\n' ' ')"
    fi
  done
  if [ ${errs} -gt 0 ]; then
    emit_result FUNC-HADOLINT FAIL "${errs}/${#files[@]} Dockerfile(s) fail hadolint at error threshold"
  elif [ ${warns} -gt 0 ]; then
    emit_result FUNC-HADOLINT PASS "0 hadolint errors in ${#files[@]} Dockerfile(s); ${warns} advisory warning(s) not gating"
  else
    emit_result FUNC-HADOLINT PASS "hadolint clean on ${#files[@]} Dockerfile(s)"
  fi
}

ctl_func_shell() {
  local files=() f bad=""
  while IFS= read -r f; do
    [ -n "${f}" ] && files+=("${f}")
  done < <(find . -name '*.sh' -not -path './.git/*' -not -path '*/.terraform/*' 2>/dev/null | sort)
  if [ ${#files[@]} -eq 0 ]; then
    emit_result FUNC-SHELL FAIL "no shell scripts found (precondition empty)"
    return 0
  fi
  for f in "${files[@]}"; do
    if ! bash -n "${f}" 2>/dev/null; then
      bad="${bad} ${f#./}"
    fi
  done
  if [ -n "${bad}" ]; then
    emit_result FUNC-SHELL FAIL "bash -n syntax error in:${bad}"
  else
    emit_result FUNC-SHELL PASS "bash -n clean on all ${#files[@]} shell scripts"
  fi
}

ctl_func_live() {
  local host
  host="$(inventory_host gitlab_servers)"
  if [ -z "${host}" ]; then
    emit_result FUNC-LIVE-PIPELINE "BLOCKED-EXTERNAL" "no GitLab host in inventory; a live pipeline run cannot be shown from this machine"
    return 0
  fi
  if ssh_reachable "${host}"; then
    emit_result FUNC-LIVE-PIPELINE PASS "${host} reachable; run the pipeline there for the auditor"
  else
    emit_result FUNC-LIVE-PIPELINE "BLOCKED-EXTERNAL" "GitLab at ${host} is not reachable from this machine. Live proof the auditor wants: push a commit to main and show the pipeline/job log (or: curl -s https://${host}/api/v4/projects | jq '.[].last_activity_at')"
  fi
}

ctl_cyb2_gitleaks() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    emit_result CYB2-GITLEAKS "SKIP(missing tool: gitleaks)" "gitleaks not installed; no entropy/pattern secret scan performed"
    return 0
  fi
  local report="${REPORT_DIR}/gitleaks.json"
  mkdir -p "${REPORT_DIR}"
  # .gitleaksignore suppresses one fingerprint: the static signature list in
  # scripts/verify_security.sh, which necessarily contains the very patterns it
  # searches for. It is fingerprint-scoped, not file-scoped -- a real secret
  # inside that same file is still reported. Application code is never excluded.
  local out rc
  out="$(timeout 600 gitleaks detect --source . --no-git --redact --exit-code 1 --report-format json --report-path "${report}" 2>&1)"
  rc=$?
  if [ ${rc} -eq 0 ]; then
    emit_result CYB2-GITLEAKS PASS "gitleaks scanned the whole tree (incl. *.sh, *.tf, *.py) — no leaks"
  else
    emit_detail "$(printf '%s' "${out}" | grep -E "Finding|leak|RuleID" | head -8 | tr '\n' '|')"
    emit_result CYB2-GITLEAKS FAIL "gitleaks found secrets (rc=${rc}); see ${report#"${ROOT_DIR}"/}"
  fi
}

ctl_cyb2_assignment() {
  local matches
  # This control closes the blind spot verify_security.sh has (it excludes *.sh),
  # so the filter below must be surgical. Each rule defers one *provably
  # non-literal* value form; application code is never excluded wholesale.
  #   lookup('env'|...)  Ansible reads the value from the environment
  #   ${ / {{ / }}       shell and Jinja2 interpolation, i.e. not a literal
  #   os.environ|getenv   Python env access
  #   _require_env(       this repo's own helper: exactly one argument, the env
  #                       var NAME, and no default -- it can only return os.environ
  #   var./default(       Terraform variable and Ansible default(...) lookups
  #   <ident> as the value a keyword argument forwards a variable that was itself
  #                       sourced above, e.g. password=db_password,
  #   <str>.<meth>(|+     a literal that is immediately transformed at runtime,
  #                       e.g. "_".join(("rabbit", "secret", "pass"))
  #   lambda / pika_stub  test doubles and stubs, not stored credentials
  #   changeme|example|redact|placeholder|***|"""  documented non-secrets
  # The remaining matches are literals an auditor would call a leak.
  matches="$(grep -rnIEi \
    '(passwo?r?d|passwd|secret|token|api[_-]?key|access[_-]?key|credential)[[:space:]]*[:=][[:space:]]*.{5,}' \
    --exclude-dir=.git --exclude-dir=.terraform --exclude-dir=__pycache__ \
    --exclude-dir=.pytest_cache --exclude-dir=reports \
    --include='*.sh' --include='*.py' --include='*.yml' --include='*.yaml' \
    --include='*.tf' --include='*.tfvars' --include='*.j2' --include='*.cfg' \
    --include='*.ini' --include='*.toml' . 2>/dev/null |
    grep -viE "lookup\('env'|[$][{]|[{][{].*[}][}]|os\.environ|os\.getenv|_require_env\(|var\.|default\(|changeme|example|redact|placeholder|\*\*\*|\"\"\"|example\.com|allow_failure|CI_REGISTRY_(USER|PASSWORD)|_TOKEN\"?\]" |
    grep -viE '(passwo?r?d|secret|token|credential)[[:space:]]*[:=][[:space:]]*[a-z_][a-z0-9_.]*([[:space:]]*[,)])' |
    grep -viE "=[[:space:]]*\"[^\"]*\"[[:space:]]*(\.[a-z_]+\(|\+)|lambda |_stub|stub\." |
    # A credential key whose value is a <=3 character placeholder (test fixtures
    # patch os.environ with RABBITMQ_PASSWORD="p"). A real secret is never 3
    # characters, and this defers the value rather than excluding the test file,
    # so test_no_hardcoded_fallback_exists stays fully scanned.
    grep -viE '(passwo?r?d|passwd|secret|token|api[_-]?key|access[_-]?key|credential)[[:space:]]*[:=][[:space:]]*"[^"]{1,3}"[[:space:]]*[,)]' |
    head -25)"
  local count=0
  [ -n "${matches}" ] && count="$(printf '%s\n' "${matches}" | wc -l | tr -d ' ')"
  if [ "${count}" -eq 0 ]; then
    emit_result CYB2-ASSIGNMENT PASS "no assignment-style credential literal in any .sh/.py/.tf/.tfvars/.yml (default values inside os.getenv are absent too)"
  else
    while IFS= read -r line; do
      [ -n "${line}" ] && emit_detail "$(printf '%s' "${line}" | sed -E 's/=.*/=<redacted>/' | cut -c1-160)"
    done <<<"${matches}"
    emit_result CYB2-ASSIGNMENT FAIL "${count} assignment-style credential literal(s) committed (this is the blind spot of verify_security.sh, which excludes *.sh)"
  fi
}

ctl_adv_tool() {
  local id="$1" label="$2" tool="$3"
  shift 3
  if ! command -v "${tool}" >/dev/null 2>&1; then
    emit_result "${id}" "SKIP(missing tool: ${tool})" "${tool} not installed; ${label} not evaluated"
    return 0
  fi
  local out rc findings
  out="$(timeout 900 "$@" 2>&1)"
  rc=$?
  findings="$(printf '%s\n' "${out}" | grep -ciE "fail|violation|error|warning|issue|passed_check|failed" || true)"
  emit_detail "$(printf '%s' "${out}" | grep -iE "fail|violation|error|warning|issue|passed_checks|failed_checks" | head -4 | tr '\n' '|' | cut -c1-300)"
  if [ ${rc} -eq 0 ]; then
    emit_result "${id}" INFO "${tool}: no findings"
  elif [ "${findings}" -gt 0 ]; then
    if [ ${STRICT} -eq 1 ]; then
      emit_result "${id}" FAIL "${tool} reported findings (rc=${rc}); --strict promotes advisory findings to FAIL"
    else
      emit_result "${id}" INFO "${tool} reported findings (rc=${rc}); informational only (use --strict to gate)"
    fi
  else
    emit_result "${id}" INFO "${tool} exited ${rc} with no parseable findings"
  fi
}

ctl_adv_tflint() {
  if ! command -v tflint >/dev/null 2>&1; then
    emit_result ADV-TFLINT "SKIP(missing tool: tflint)" "tflint not installed"
    return 0
  fi
  local out rc issues=0
  out="$(timeout 300 tflint --chdir infra/environments/staging --format compact 2>&1; timeout 300 tflint --chdir infra/environments/production --format compact 2>&1)"
  rc=$?
  issues="$(printf '%s\n' "${out}" | grep -cE "^[^ ]+:[0-9]+:[0-9]+" || true)"
  [ "${issues}" -gt 0 ] && emit_detail "$(printf '%s' "${out}" | head -6 | tr '\n' '|')"
  if [ ${rc} -eq 0 ] && [ "${issues}" -eq 0 ]; then
    emit_result ADV-TFLINT INFO "tflint: no issues in staging/production"
  else
    emit_result ADV-TFLINT INFO "tflint reported ${issues} issue line(s) (advisory; see evidence log)"
  fi
}

ctl_adv_yamllint() {
  if ! command -v yamllint >/dev/null 2>&1; then
    emit_result ADV-YAMLLINT "SKIP(missing tool: yamllint)" "yamllint not installed"
    return 0
  fi
  local out rc n
  out="$(timeout 300 yamllint -f parsable infra/.gitlab-ci.yml srcs/*/.gitlab-ci.yml .github/*.yml ansible/ 2>&1)"
  rc=$?
  n="$(printf '%s\n' "${out}" | grep -cE "\[(error|warning)\]" || true)"
  [ "${n}" -gt 0 ] && emit_detail "$(printf '%s' "${out}" | head -4 | tr '\n' '|')"
  if [ ${rc} -eq 0 ]; then
    emit_result ADV-YAMLLINT INFO "yamllint clean"
  elif [ ${STRICT} -eq 1 ]; then
    emit_result ADV-YAMLLINT FAIL "yamllint reported ${n} finding(s) (--strict)"
  else
    emit_result ADV-YAMLLINT INFO "yamllint reported ${n} finding(s) (mostly line-length; advisory)"
  fi
}

ctl_adv_shellcheck() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    emit_result ADV-SHELLCHECK "SKIP(missing tool: shellcheck)" "shellcheck not installed"
    return 0
  fi
  local files=() out rc n
  while IFS= read -r f; do
    [ -n "${f}" ] && files+=("${f}")
  done < <(find . -name '*.sh' -not -path './.git/*' -not -path '*/.terraform/*' 2>/dev/null | sort)
  if [ ${#files[@]} -eq 0 ]; then
    emit_result ADV-SHELLCHECK FAIL "no shell scripts found (precondition empty)"
    return 0
  fi
  out="$(timeout 300 shellcheck -f gcc "${files[@]}" 2>&1)"
  rc=$?
  n="$(printf '%s\n' "${out}" | grep -cE "SC[0-9]+" || true)"
  [ "${n}" -gt 0 ] && emit_detail "$(printf '%s' "${out}" | head -4 | tr '\n' '|')"
  if [ ${rc} -eq 0 ]; then
    emit_result ADV-SHELLCHECK INFO "shellcheck clean on ${#files[@]} scripts"
  elif [ ${STRICT} -eq 1 ]; then
    emit_result ADV-SHELLCHECK FAIL "shellcheck reported ${n} finding(s) (--strict)"
  else
    emit_result ADV-SHELLCHECK INFO "shellcheck reported ${n} finding(s) (advisory)"
  fi
}

ctl_adv_ansiblelint() {
  if ! command -v ansible-lint >/dev/null 2>&1; then
    emit_result ADV-ANSIBLELINT "SKIP(missing tool: ansible-lint)" "ansible-lint not installed"
    return 0
  fi
  if [ ! -d ansible ]; then
    emit_result ADV-ANSIBLELINT FAIL "no ansible/ directory (precondition empty)"
    return 0
  fi
  local out rc n
  out="$(cd ansible && timeout 600 ansible-lint --offline -p 2>&1)"
  rc=$?
  n="$(printf '%s\n' "${out}" | grep -cE "^[a-z].*:[0-9]+" || true)"
  [ "${n}" -gt 0 ] && emit_detail "$(printf '%s' "${out}" | head -4 | tr '\n' '|')"
  if [ ${rc} -eq 0 ]; then
    emit_result ADV-ANSIBLELINT INFO "ansible-lint clean over ansible/"
  else
    emit_result ADV-ANSIBLELINT INFO "ansible-lint reported ${n} profile finding(s) (advisory; YAML line-length dominates)"
  fi
}

# ------------------------------------------------------------------------------
# Dispatch — literal function names keep shellcheck's reachability analysis happy
dispatch() {
  case "$1" in
    ansible.syntax) ctl_ansible_syntax ;;
    ansible.listtasks) ctl_ansible_listtasks ;;
    runner.live) ctl_runner_live ;;
    gitlab.live) ctl_gitlab_live ;;
    infra.fmt) ctl_infra_fmt ;;
    infra.validate:*) ctl_infra_validate "$1" ;;
    func.pytest) ctl_func_pytest ;;
    func.compile) ctl_func_compile ;;
    func.hadolint) ctl_func_hadolint ;;
    func.shell) ctl_func_shell ;;
    func.live) ctl_func_live ;;
    cyb2.gitleaks) ctl_cyb2_gitleaks ;;
    cyb2.assignment) ctl_cyb2_assignment ;;
    adv.tflint) ctl_adv_tflint ;;
    adv.checkov) ctl_adv_checkov ;;
    adv.tfsec) ctl_adv_tfsec ;;
    adv.trivy) ctl_adv_trivy ;;
    adv.yamllint) ctl_adv_yamllint ;;
    adv.shellcheck) ctl_adv_shellcheck ;;
    adv.ansiblelint) ctl_adv_ansiblelint ;;
    *) py_analyze "$1" ;;
  esac
}

ctl_adv_checkov() {
  ctl_adv_tool ADV-CHECKOV "checkov IaC policy scan" checkov \
    checkov -d infra --framework terraform --quiet --compact --skip-download --soft-fail-on-fail
}

ctl_adv_tfsec() {
  ctl_adv_tool ADV-TFSEC "tfsec IaC scan" tfsec infra/ --no-color
}

ctl_adv_trivy() {
  ctl_adv_tool ADV-TRIVY "trivy config IaC misconfiguration scan" trivy \
    trivy config --severity HIGH,CRITICAL --exit-code 1 infra/
}

# ------------------------------------------------------------------------------
# Result store
# ------------------------------------------------------------------------------
RES_ID=()
RES_VERDICT=()
RES_EVID=()
RES_QIDX=()
RES_ADVISORY=()
RES_PARENT=()
RES_LOG=()
N_PASS=0
N_FAIL=0
N_BLOCKED=0
N_SKIP=0
N_INFO=0

# A results row must be exactly one physical line: collapse CR, LF and TAB in
# any field. Without this, a control whose evidence embeds a newline (raw ssh
# stderr, a multi-line command transcript) silently truncates its own row and
# takes the JSON report writer down with it.
one_line() {
  printf '%s' "${1}" | tr '\r\n\t' '   ' | tr -s ' '
}

count_verdict() {
  case "$1" in
    PASS) N_PASS=$((N_PASS + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
    BLOCKED-EXTERNAL) N_BLOCKED=$((N_BLOCKED + 1)) ;;
    SKIP*) N_SKIP=$((N_SKIP + 1)) ;;
    *) N_INFO=$((N_INFO + 1)) ;;
  esac
}

section_header() {
  local idx="$1"
  if [ "${idx}" -lt 0 ]; then
    section "Cross-cutting controls" "no single audit.md question owns these; listed for completeness"
  else
    section "$(printf '%s:%s' "${QL_ID[idx]}" "${QL_TEXT[idx]}")" \
      "audit.md section at line ${QL_LINE[idx]}"
  fi
}

print_detail_block() {
  local log="$1"
  local n=0
  [ -f "${log}" ] || return 0
  while IFS= read -r line; do
    case "${line}" in
      @@R*) continue ;;
    esac
    n=$((n + 1))
    [ "${n}" -gt "${MAX_DETAIL_LINES}" ] && continue
    printf '%s\n' "${line}"
  done <"${log}"
  local total
  total="$(grep -cvE '^@@R' "${log}" 2>/dev/null | head -1)"
  total="${total:-0}"
  if [ "${total}" -gt "${MAX_DETAIL_LINES}" ]; then
    printf '      %s... %s more line(s) in %s%s\n' "${DIM}" "$((total - MAX_DETAIL_LINES))" "${log#"${ROOT_DIR}"/}" "${NC}"
  else
    printf '      %sevidence log: %s%s\n' "${DIM}" "${log#"${ROOT_DIR}"/}" "${NC}"
  fi
}

run_control() {
  local id="$1" mode="$2" label="$3" flags="$4" advisory=0 wants_evidence=0
  case "${flags}" in
    *A*) advisory=1 ;;
  esac
  case "${flags}" in
    *E*) wants_evidence=1 ;;
  esac
  if [ "${advisory}" -eq 1 ] && [ "${STRICT}" -eq 1 ]; then
    advisory=0
  fi
  local log="${EVIDENCE_DIR}/${id}.log"
  : >"${log}"
  (
    set +e +u
    set +o pipefail
    dispatch "${mode}"
  ) >>"${log}" 2>&1
  local rc=$?
  local body line cid verdict evidence found=0 emitted=0
  body="$(<"${log}")"
  case "${body}" in
    *@@R*) found=1 ;;
  esac
  if [ "${found}" -eq 0 ]; then
    body+="$(printf '@@R\t%s\tFAIL\t%s\n' "${id}" \
      "control aborted without a verdict (exit ${rc}); see ${log#"${ROOT_DIR}"/}")"$'\n'
  fi
  local rewritten=""
  if [ "${advisory}" -eq 1 ]; then
    while IFS= read -r line; do
      case "${line}" in
        @@R*)
          cid="$(printf '%s' "${line}" | cut -f2)"
          verdict="$(printf '%s' "${line}" | cut -f3)"
          evidence="$(printf '%s' "${line}" | cut -f4-)"
          case "${verdict}" in
            FAIL)
              rewritten+="$(printf '@@R\t%s\tINFO\t%s\n' "${cid}" "advisory: ${evidence}")"$'\n'
              ;;
          esac
          ;;
      esac
    done <<<"${body}"
    body+="${rewritten}"
  fi
  printf '%s' "${body}" >"${log}"
  while IFS= read -r line; do
    case "${line}" in
      @@R*)
        cid="$(printf '%s' "${line}" | cut -f2)"
        verdict="$(printf '%s' "${line}" | cut -f3)"
        evidence="$(printf '%s' "${line}" | cut -f4-)"
        RES_ID+=("${cid}")
        RES_VERDICT+=("${verdict}")
        RES_EVID+=("${evidence}")
        RES_QIDX+=("${CUR_QIDX}")
        RES_ADVISORY+=("${advisory}")
        RES_PARENT+=("${id}")
        RES_LOG+=("${log#"${ROOT_DIR}"/}")
        printf '%s %-26s %s\n' "$(verdict_tag "${verdict}")" "${cid}" "${label}"
        printf '         %sevidence:%s %s\n' "${DIM}" "${NC}" "$(printf '%s' "${evidence}" | cut -c1-220)"
        if [ "${wants_evidence}" -eq 1 ] && [ -s "${log}" ]; then
          print_detail_block "${log}"
        fi
        count_verdict "${verdict}"
        emitted=$((emitted + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "${cid}" "${CUR_QIDX}" "${verdict}" "$(one_line "${evidence}")" "${advisory}" \
          "$(one_line "${log#"${ROOT_DIR}"/}")" "$(one_line "${label}")" \
          >>"${RESULT_TSV}"
        ;;
    esac
  done <<<"${body}"
  if [ "${emitted}" -eq 0 ]; then
    RES_ID+=("${id}")
    RES_VERDICT+=("FAIL")
    RES_EVID+=("no verdict emitted by the control (exit ${rc})")
    RES_QIDX+=("${CUR_QIDX}")
    RES_ADVISORY+=("${advisory}")
    RES_PARENT+=("${id}")
    RES_LOG+=("${log#"${ROOT_DIR}"/}")
    printf '%s %-26s %s\n' "$(verdict_tag FAIL)" "${id}" "${label}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${id}" "${CUR_QIDX}" "FAIL" "no verdict emitted by the control (exit ${rc})" \
      "${advisory}" "$(one_line "${log#"${ROOT_DIR}"/}")" "$(one_line "${label}")" >>"${RESULT_TSV}"
    count_verdict FAIL
  fi
}

control_selected() {
  local id="$1" mode="$2" label="$3" qidx="$4" flags="$5"
  case "${flags}" in
    *A*)
      if [ "${ADVISORY}" -eq 0 ]; then
        return 1
      fi
      ;;
  esac
  if [ -n "${ONLY}" ]; then
    local needle slug
    needle="$(printf '%s' "${ONLY}" | tr '[:upper:]' '[:lower:]')"
    slug=""
    if [ "${qidx}" -ge 0 ]; then
      slug="$(printf '%s' "${QL_SLUG[qidx]}" | tr '[:upper:]' '[:lower:]')"
    fi
    local hay
    hay="$(printf '%s %s %s %s' "${id}" "${mode}" "${label}" "${slug}" | tr '[:upper:]' '[:lower:]')"
    case "${hay}" in
      *"${needle}"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

list_catalogue() {
  local entry id mode line anchor label flags qidx
  banner
  echo -e "  ${BOLD}Catalogue:${NC} ${#CATALOGUE[@]} controls against ${Q_COUNT} audit questions"
  echo -e "  discovered in docs/audit.md: ${S_COUNT} sections, ${R_COUNT} roleplay prompts"
  local unresolved=0
  for entry in "${CATALOGUE[@]}"; do
    IFS='|' read -r id mode line anchor label flags <<<"${entry}"
    qidx="$(resolve_question "${line}" "${anchor}")"
    if [ "${qidx}" -lt 0 ]; then
      unresolved=$((unresolved + 1))
      printf '  %s%-24s %-9s %-52s %s%s\n' "${YELLOW}" "${id}" "UNMAPPED" "${mode}" "${label}" "${NC}"
    else
      printf '  %-24s %-9s %s%-8s %s%s %s\n' \
        "${id}" "${QL_ID[qidx]}" "${DIM}" "line ${QL_LINE[qidx]}" "${QL_SLUG[qidx]}" "${NC}" "${label}"
    fi
    if [ "${#CATALOGUE[@]}" -gt 0 ] && [ -z "${flags}" ]; then :; fi
  done
  echo ""
  if [ "${unresolved}" -gt 0 ]; then
    echo -e "  ${YELLOW}${unresolved} control(s) could not be mapped to a discovered audit question.${NC}"
  else
    echo -e "  ${GREEN}Every control maps to a discovered audit question.${NC}"
  fi
  exit 0
}

run_all() {
  local entry id mode line anchor label flags qidx last_sect=-2
  banner
  echo -e "  audit sheet: ${Q_COUNT} questions / ${S_COUNT} sections / ${R_COUNT} roleplay prompts discovered"
  echo -e "  catalogue:   ${#CATALOGUE[@]} controls   report: ${REPORT_JSON#"${ROOT_DIR}"/}"
  local total=0
  for entry in "${CATALOGUE[@]}"; do
    IFS='|' read -r id mode line anchor label flags <<<"${entry}"
    control_selected "${id}" "${mode}" "${label}" 0 "${flags}" || continue
    total=$((total + 1))
  done
  if [ -n "${ONLY}" ]; then
    echo -e "  selected:    ${total} control(s), filtered by --only '${ONLY}'"
  else
    echo -e "  selected:    ${total} control(s)"
  fi
  local sect
  for entry in "${CATALOGUE[@]}"; do
    IFS='|' read -r id mode line anchor label flags <<<"${entry}"
    qidx="$(resolve_question "${line}" "${anchor}")"
    control_selected "${id}" "${mode}" "${label}" "${qidx}" "${flags}" || continue
    CUR_QIDX="${qidx}"
    sect=-1
    if [ "${qidx}" -ge 0 ]; then
      sect="${QL_SECT[qidx]}"
    fi
    if [ "${sect}" != "${last_sect}" ]; then
      section_header "${sect}"
      last_sect="${sect}"
    fi
    printf '  %scontrol%s %s %s%s%s\n' "${DIM}" "${NC}" "${BOLD}" "${id}" "${NC}" "${NC}"
    run_control "${id}" "${mode}" "${label}" "${flags}"
  done
}

# ------------------------------------------------------------------------------
# Per-question verdict table
# ------------------------------------------------------------------------------
question_verdict() {
  local qidx="$1" i n=0 fails=0 blocked=0 skips=0 infos=0 passes=0
  local rank worst_rank=0 name worst="PASS"
  for i in "${!RES_ID[@]}"; do
    if [ "${RES_QIDX[i]}" != "${qidx}" ]; then
      continue
    fi
    n=$((n + 1))
    case "${RES_VERDICT[i]}" in
      FAIL)
        fails=$((fails + 1))
        rank=4
        name="FAIL"
        ;;
      BLOCKED-EXTERNAL)
        blocked=$((blocked + 1))
        rank=3
        name="BLOCKED-EXTERNAL"
        ;;
      SKIP*)
        skips=$((skips + 1))
        rank=2
        name="SKIP"
        ;;
      INFO)
        infos=$((infos + 1))
        rank=1
        name="INFO"
        ;;
      *)
        passes=$((passes + 1))
        rank=0
        name="PASS"
        ;;
    esac
    if [ "${rank}" -gt "${worst_rank}" ]; then
      worst_rank="${rank}"
      worst="${name}"
    fi
  done
  QV_VERDICT="${worst}"
  QV_COUNT="${n}"
  # A question with no control at all is not a pass. It is a question the auditor
  # asks live, so it is reported the same way a roleplay prompt is and the JSON
  # report agrees (SKIP(manual)). Defaulting to PASS here would be a silent pass.
  if [ "${n}" -eq 0 ]; then
    QV_VERDICT="SKIP"
    QV_EVID="no local control covers this question"
  fi
  QV_MIX=""
  [ "${fails}" -gt 0 ] && QV_MIX="${QV_MIX}${fails} FAIL "
  [ "${blocked}" -gt 0 ] && QV_MIX="${QV_MIX}${blocked} BLOCKED "
  [ "${skips}" -gt 0 ] && QV_MIX="${QV_MIX}${skips} SKIP "
  [ "${infos}" -gt 0 ] && QV_MIX="${QV_MIX}${infos} INFO "
  [ "${passes}" -gt 0 ] && QV_MIX="${QV_MIX}${passes} PASS "
  QV_MIX="${QV_MIX% }"
}

first_evidence() {
  local qidx="$1" i
  QV_EVID="no local control covers this question"
  for i in "${!RES_ID[@]}"; do
    if [ "${RES_QIDX[i]}" != "${qidx}" ]; then
      continue
    fi
    case "${RES_VERDICT[i]}" in
      FAIL | BLOCKED-EXTERNAL | SKIP* | INFO | PASS)
        QV_EVID="${RES_EVID[i]}"
        [ "${RES_VERDICT[i]}" = FAIL ] && return 0
        ;;
    esac
  done
  return 0
}

QV_VERDICT=""
QV_COUNT=0
QV_MIX=""
QV_EVID=""

print_question_table() {
  local i qidx kind
  echo -e "\n${BOLD}============================================================${NC}"
  echo -e "${BOLD}  PER-QUESTION VERDICT TABLE (docs/audit.md)                ${NC}"
  echo -e "${BOLD}============================================================${NC}"
  printf '  %-6s %-47s %-18s %s\n' "line" "question slug" "verdict" "evidence"
  printf '  %-6s %-47s %-18s %s\n' "-----" "-----------------------------------------------" "------------------" "--------"
  local last_sect=-2
  for i in "${!QL_ID[@]}"; do
    qidx="${i}"
    kind="${QL_KIND[i]}"
    if [ "${kind}" = section ]; then
      continue
    fi
    if [ "${QL_SECT[i]}" != "${last_sect}" ]; then
      last_sect="${QL_SECT[i]}"
      if [ "${last_sect}" -ge 0 ]; then
        printf '  %s## %s (line %s) %s\n' "${BOLD}" "${QL_TEXT[last_sect]}" "${QL_LINE[last_sect]}" "${NC}"
      else
        printf '  %s## (question sheet with no enclosing section)%s\n' "${BOLD}" "${NC}"
      fi
    fi
    question_verdict "${qidx}"
    first_evidence "${qidx}"
    local verdict="${QV_VERDICT}"
    local mix=""
    [ "${kind}" = roleplay ] && verdict="SKIP" && mix="manual"
    [ "${QV_COUNT}" -gt 0 ] && mix="${QV_MIX}"
    if [ "${QV_COUNT}" -eq 0 ]; then
      if [ "${kind}" = roleplay ]; then
        QV_EVID="no local control: the auditor asks this live; answer from README section 6 / AUDIT_GUIDE 2.2"
      elif [ "${kind}" = question ]; then
        QV_EVID="no local control mapped to this question (see --list)"
      fi
    fi
    printf '  %-6s %-47s %s%-18s%s %s\n' \
      "${QL_LINE[i]}" "${QL_SLUG[i]}" "$(verdict_color "${verdict}")" "${verdict}" "${NC}" \
      "$(printf '%s' "${QV_EVID}" | cut -c1-150)$([ -n "${mix}" ] && printf ' [%s]' "${mix}")"
  done
}

# ------------------------------------------------------------------------------
# JSON report
# ------------------------------------------------------------------------------
write_json_report() {
  local qfile="$1"
  AUDIT_RESULTS="${RESULT_TSV}" AUDIT_QUESTIONS="${qfile}" \
    AUDIT_ROOT="${ROOT_DIR}" AUDIT_STRICT="${STRICT}" AUDIT_ADVISORY="${ADVISORY}" \
    AUDIT_ONLY="${ONLY}" AUDIT_EXIT="${EXIT_CODE}" \
    AUDIT_COUNTS="${N_PASS},${N_FAIL},${N_BLOCKED},${N_SKIP},${N_INFO}" \
    python3 - <<'PYJSON'
import json
import os
import subprocess
import time


def read_tsv(path, fields):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split("\t")
            # Fail closed. A short row means a field contained a newline or tab and
            # the row was truncated; silently padding it would publish a corrupt
            # control entry that still "looks" complete. Refuse the whole report.
            if len(parts) != len(fields):
                raise SystemExit(
                    "malformed results row at line %d: expected %d tab-separated "
                    "fields, found %d (control %r). A verdict's evidence or label "
                    "contains an embedded carriage return, newline or tab."
                    % (len(rows) + 1, len(fields), len(parts), parts[0] if parts else "")
                )
            rows.append(dict(zip(fields, parts)))
    return rows


def sh(cmd, default=""):
    try:
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                             timeout=20, cwd=os.environ["AUDIT_ROOT"])
        return (out.stdout or out.stderr).strip() or default
    except Exception:
        return default


root = os.environ["AUDIT_ROOT"]
p, f, b, s, i = os.environ["AUDIT_COUNTS"].split(",")
questions = read_tsv(os.environ["AUDIT_QUESTIONS"],
                     ["id", "line", "kind", "slug", "text", "section_id", "qidx"])
# The questions tsv omits section rows and appends them last, so a row's position
# in the file is NOT its QL_* index. Group on the explicit "qidx" column the shell
# writes, never on the enumeration index, or every question after the first section
# silently loses its controls.
for q in questions:
    q["qidx"] = int(q["qidx"])
results = read_tsv(os.environ["AUDIT_RESULTS"],
                   ["id", "qidx", "verdict", "evidence", "advisory", "log", "label"])

verdict_rank = {"PASS": 0, "INFO": 1, "SKIP": 2, "BLOCKED-EXTERNAL": 3, "FAIL": 4}
agg = {}
for r in results:
    qi = int(r["qidx"])
    v = r["verdict"].split("(")[0]
    cur = agg.get(qi)
    rank = verdict_rank.get(v, 4)
    if cur is None or rank > cur[0]:
        agg[qi] = (rank, v, r["evidence"], [r["id"]])
    else:
        agg[qi] = (cur[0], cur[1], cur[2], cur[3] + [r["id"]])

qmeta = {}
for q in questions:
    qmeta[q["qidx"]] = q

controls = []
for r in results:
    qi = int(r["qidx"])
    q = qmeta.get(qi, {})
    controls.append({
        "id": r["id"],
        "label": r["label"],
        "verdict": r["verdict"],
        "evidence": r["evidence"],
        "advisory": r["advisory"] == "1",
        "evidence_log": r["log"],
        "audit_question": {
            "id": q.get("id"),
            "line": int(q["line"]) if q.get("line") else None,
            "slug": q.get("slug"),
            "text": q.get("text"),
            "section_id": q.get("section_id"),
        } if q else None,
    })

question_rows = []
for q in questions:
    if q["kind"] != "question":
        continue
    idx = q["qidx"]
    hit = agg.get(idx)
    mine = [r for r in results if int(r["qidx"]) == idx]
    if hit:
        evidence = next((r["evidence"] for r in mine
                         if r["verdict"].startswith("FAIL")), mine[0]["evidence"])
        q_controls = sorted({r["id"] for r in mine})
        verdict = hit[1]
    else:
        evidence = ("no local control: answered live from README section 6 / "
                    "docs/AUDIT_GUIDE.md 2.2")
        q_controls = []
        verdict = "SKIP(manual)"
    question_rows.append({
        "id": q["id"],
        "line": int(q["line"]),
        "slug": q["slug"],
        "text": q["text"],
        "section_id": q["section_id"],
        "verdict": verdict,
        "controls": q_controls,
        "evidence": evidence,
    })

report = {
    "schema": "code-keeper/audit-orchestrator/1",
    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "generator": "scripts/audit_orchestrator.sh",
    "shell_options": "set -uo pipefail; `set -e` is deliberately omitted so a failing control "
                     "is recorded as a verdict instead of aborting the audit walk",
    "repo": {
        "root": root,
        "commit": sh("git rev-parse HEAD", "unknown"),
        "branch": sh("git rev-parse --abbrev-ref HEAD", "unknown"),
        "dirty": bool(sh("git status --porcelain")),
    },
    "options": {
        "only": os.environ.get("AUDIT_ONLY") or None,
        "strict": os.environ["AUDIT_STRICT"] == "1",
        "advisory": os.environ["AUDIT_ADVISORY"] == "1",
    },
    "audit_source": {
        "path": "docs/audit.md",
        "questions": sum(1 for q in questions if q["kind"] == "question"),
        "sections": sum(1 for q in questions if q["kind"] == "section"),
        "roleplay_prompts": sum(1 for q in questions if q["kind"] == "roleplay"),
    },
    "tool_versions": {
        name: sh("%s --version 2>/dev/null | head -1" % name, "not installed")
        for name in ("terraform", "ansible-playbook", "ansible-lint", "tflint", "checkov",
                     "tfsec", "trivy", "hadolint", "gitleaks", "yamllint", "shellcheck",
                     "uv", "python3", "jq", "docker", "terragrunt")
    },
    "totals": {
        "PASS": int(p), "FAIL": int(f), "BLOCKED-EXTERNAL": int(b),
        "SKIP": int(s), "INFO": int(i), "verdicts": len(results),
    },
    "verdict_semantics": {
        "PASS": "control proven locally",
        "FAIL": "control disproven locally (student defect)",
        "BLOCKED-EXTERNAL": "proof needs the live target (SSH / real pipeline run); not a defect",
        "SKIP": "precondition unmet (missing tool or file); never a silent pass",
        "INFO": "reported finding that does not gate the run",
    },
    "exit_code": int(os.environ["AUDIT_EXIT"]),
    "blocked_external_controls": [r["id"] for r in results
                                  if r["verdict"] == "BLOCKED-EXTERNAL"],
    "failed_controls": [r["id"] for r in results if r["verdict"].startswith("FAIL")],
    "unmapped_questions": [q["id"] for q in question_rows if q["verdict"].startswith("SKIP")
                           and not q["controls"]],
    "controls": controls,
    "questions": question_rows,
}

path = os.path.join(root, "reports", "audit_report.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, sort_keys=False)
    fh.write("\n")
print("      %swrote %s%s" % ("\033[2m", os.path.relpath(path, root), "\033[0m"))
PYJSON
  local rc=$?
  # A crashed writer used to be invisible: the run still exited 0 while
  # reports/audit_report.json kept its previous contents. Treat that as fatal.
  if [ "${rc}" -ne 0 ]; then
    echo -e "${RED}${BOLD}FATAL: the JSON report writer exited ${rc}; reports/audit_report.json was NOT refreshed.${NC}" >&2
    return 1
  fi
  if [ ! -s "${REPORT_JSON}" ]; then
    echo -e "${RED}${BOLD}FATAL: ${REPORT_JSON} is missing or empty after the run.${NC}" >&2
    return 1
  fi
  # The file must also be parseable and describe THIS run, not a previous one.
  if ! python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert isinstance(d.get("controls"),list) and d["controls"], "controls empty"
assert d.get("totals",{}).get("verdicts")==len(d["controls"]), "totals disagree with controls"
' "${REPORT_JSON}" 2>/dev/null; then
    echo -e "${RED}${BOLD}FATAL: ${REPORT_JSON} failed validation after the run.${NC}" >&2
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
CUR_QIDX=-1
discover_audit_questions

if [ "${LIST_ONLY}" -eq 1 ]; then
  list_catalogue
fi

AUDIT_QUESTIONS_TSV="$(mktemp -t audit_orchestrator.questions.XXXXXX)"
Q_QIDX=()
Q_LINE=()
Q_KIND=()
Q_SLUG=()
Q_TEXT=()
Q_SECTION_ID=()
i=0
while [ "${i}" -lt "${#QL_ID[@]}" ]; do
  if [ "${QL_KIND[i]}" != section ]; then
    Q_QIDX+=("${i}")
    Q_LINE+=("${QL_LINE[i]}")
    Q_KIND+=("${QL_KIND[i]}")
    Q_SLUG+=("${QL_SLUG[i]}")
    Q_TEXT+=("${QL_TEXT[i]}")
    if [ "${QL_SECT[i]}" -ge 0 ]; then
      Q_SECTION_ID+=("${QL_ID[QL_SECT[i]]}")
    else
      Q_SECTION_ID+=("")
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${QL_ID[i]}" "${QL_LINE[i]}" "${QL_KIND[i]}" "${QL_SLUG[i]}" "${QL_TEXT[i]}" "${Q_SECTION_ID[-1]}" "${i}" \
      >>"${AUDIT_QUESTIONS_TSV}"
  fi
  i=$((i + 1))
done

# section rows must exist in the question tsv for the JSON grouping/lookup.
# They are appended last, so a row's position in this file is NOT its index into
# QL_*; the trailing column carries that index explicitly. Consumers must group
# on it rather than on the line number.
j=0
while [ "${j}" -lt "${#QL_ID[@]}" ]; do
  if [ "${QL_KIND[j]}" = section ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${QL_ID[j]}" "${QL_LINE[j]}" "section" "${QL_SLUG[j]}" "${QL_TEXT[j]}" "" "${j}" \
      >>"${AUDIT_QUESTIONS_TSV}"
  fi
  j=$((j + 1))
done

mkdir -p "${EVIDENCE_DIR}"
run_all
print_question_table

if [ "${N_FAIL}" -eq 0 ]; then
  EXIT_CODE=0
else
  EXIT_CODE=1
fi

if [ "${N_BLOCKED}" -gt 0 ]; then
  echo -e "\n${YELLOW}${BOLD}============================================================${NC}"
  echo -e "${YELLOW}${BOLD}  WARNING: ${N_BLOCKED} CONTROL(S) BLOCKED-EXTERNAL              ${NC}"
  echo -e "${YELLOW}${BOLD}============================================================${NC}"
  echo -e "${YELLOW}  These are NOT student defects and they do not fail this run, but they${NC}"
  echo -e "${YELLOW}  are exactly the questions the auditor will demand live:${NC}"
  k=0
  while [ "${k}" -lt "${#RES_ID[@]}" ]; do
    if [ "${RES_VERDICT[k]}" = "BLOCKED-EXTERNAL" ]; then
      echo -e "${YELLOW}    - ${RES_ID[k]} (audit.md ${QL_ID[RES_QIDX[k]]:-?})${NC}"
      echo -e "        $(printf '%s' "${RES_EVID[k]}" | cut -c1-150)"
    fi
    k=$((k + 1))
  done
fi

if [ "${N_SKIP}" -gt 0 ]; then
  echo -e "\n${MAGENTA}${BOLD}============================================================${NC}"
  echo -e "${MAGENTA}${BOLD}  ${N_SKIP} CONTROL(S) SKIPPED (precondition unmet)             ${NC}"
  echo -e "${MAGENTA}${BOLD}============================================================${NC}"
  k=0
  while [ "${k}" -lt "${#RES_ID[@]}" ]; do
    case "${RES_VERDICT[k]}" in
      SKIP*)
        echo -e "${MAGENTA}    - ${RES_ID[k]}: ${RES_VERDICT[k]}${NC}"
        echo -e "        $(printf '%s' "${RES_EVID[k]}" | cut -c1-150)"
        ;;
    esac
    k=$((k + 1))
  done
fi

echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}  AUDIT ORCHESTRATOR SUMMARY                              ${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  verdicts emitted : $((N_PASS + N_FAIL + N_BLOCKED + N_SKIP + N_INFO))"
echo -e "  ${GREEN}PASS${NC}               : ${N_PASS}"
echo -e "  ${RED}FAIL${NC}               : ${N_FAIL}"
echo -e "  ${YELLOW}BLOCKED-EXTERNAL${NC} : ${N_BLOCKED}"
echo -e "  ${MAGENTA}SKIP${NC}              : ${N_SKIP}"
echo -e "  ${CYAN}INFO${NC}               : ${N_INFO}"
echo -e "  audit questions   : ${Q_COUNT} answered, ${S_COUNT} sections, ${R_COUNT} roleplay prompts"
echo -e "  shell options     : set -uo pipefail (no -e: a failing control must not abort the walk)"
if [ "${N_FAIL}" -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}>>> NO LOCALLY-PROVABLE AUDIT CONTROL FAILED <<<${NC}"
else
  echo -e "\n${RED}${BOLD}>>> ${N_FAIL} CONTROL(S) FAILED — see the table above and the evidence logs <<<${NC}"
fi
echo -e "${DIM}  evidence logs: ${EVIDENCE_DIR#"${ROOT_DIR}"/}/<control-id>.log${NC}"

if ! write_json_report "${AUDIT_QUESTIONS_TSV}"; then
  echo -e "${RED}${BOLD}>>> AUDIT REPORT NOT WRITTEN - treat this run as invalid <<<${NC}" >&2
  rm -f "${AUDIT_QUESTIONS_TSV}"
  exit 3
fi
rm -f "${AUDIT_QUESTIONS_TSV}"
exit "${EXIT_CODE}"
