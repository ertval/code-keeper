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

# ------------------------------------------------------------------------------
# Assertion stream protocol
#
# An analysis engine (python3 heredoc) writes one record per line on stdin:
#   PASS|<detail>   -> log_pass, increments PASSED_CHECKS
#   FAIL|<detail>   -> log_fail, increments FAILED_CHECKS
#   INFO|<detail>   -> log_info, no counter movement
#   DONE|<ok|error> -> terminal sentinel proving the engine ran to completion
#
# The engine's exit status is deliberately NEVER used as the gate: under
# 'set -e' a non-zero heredoc would abort the audit before any counter moved,
# and the first 'sys.exit(1)' would hide every sibling control. Counting one
# increment per emitted assertion keeps the summary totals honest and lets all
# controls report before the exit status is decided.
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
      INFO\|*)
        detail="${line#INFO|}"
        log_info "$detail"
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

# Directories and files that never contain reviewable source and would only
# produce false positives or binary noise.
SCAN_EXCLUDE_DIRS=(
  --exclude-dir=".git"
  --exclude-dir=".terraform"
  --exclude-dir="node_modules"
  --exclude-dir="__pycache__"
  --exclude-dir=".pytest_cache"
  --exclude-dir="scratch"
)

# Audit artefacts are excluded from the leak scan because they necessarily
# quote the very signatures and credentials they document, which makes any
# such report self-referential. Application code is NEVER excluded.
# Keep this list identical to the one in scripts/audit_orchestrator.sh.
LEAK_SCAN_EXCLUSIONS=(
  "scripts/audit_orchestrator.sh"
  "scripts/verify_security.sh"
  "docs/AUDIT_GUIDE.md"
  "README.md"
)

SCAN_EXCLUDE_ARGS=()
for excl in "${LEAK_SCAN_EXCLUSIONS[@]}"; do
  SCAN_EXCLUDE_ARGS+=("--exclude=$(basename "${excl}")")
done

echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}  CODE-KEEPER CYBERSECURITY AUDIT & VERIFICATION            ${NC}"
echo -e "${BOLD}============================================================${NC}"

# 1. Guideline 1: Restrict triggers to protected branches
log_header "Guideline 1: Restrict Triggers to Protected Branches"
report_assertions << 'PYEOF'
import os, re, sys
import yaml

PIPELINES = [
    "infra/.gitlab-ci.yml",
    "srcs/api-gateway/.gitlab-ci.yml",
    "srcs/inventory-app/.gitlab-ci.yml",
    "srcs/billing-app/.gitlab-ci.yml",
]

CRITICAL_JOB_TERMS = (
    "apply", "deploy", "container", "approval",
    "promote", "rollout", "release", "publish", "infra",
)

PROTECTED_BRANCHES = {"main", "master", "production", "release", "stable"}

BRANCH_GUARD = re.compile(
    r"""CI_COMMIT_(?:BRANCH|TAG)[ \t]*==[ \t]*['"]?([A-Za-z0-9._/-]+)"""
)

failures = 0


def is_protected(rules):
    """A rule protects only if it compares the ref for EQUALITY to a known
    protected branch. Substring matching is deliberately avoided: 'release'
    is a substring of 'feature/unreleased'."""
    for rule in rules if isinstance(rules, list) else []:
        for expr in re.findall(r'if["\']?[ \t]*:[ \t]*(.+)', str(rule)):
            m = BRANCH_GUARD.search(expr)
            if m and m.group(1) in PROTECTED_BRANCHES:
                return True
    return False

for pf in PIPELINES:
    if not os.path.isfile(pf):
        print(f"FAIL|{pf} is missing, its deployment triggers cannot be audited")
        failures += 1
        continue

    with open(pf, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)

    if not isinstance(data, dict):
        print(f"FAIL|{pf} is not a mapping of GitLab CI jobs")
        failures += 1
        continue

    file_failures = 0
    critical_jobs = [
        k for k in data
        if isinstance(data.get(k), dict)
        and any(term in k.lower() for term in CRITICAL_JOB_TERMS)
    ]

    if not critical_jobs:
        print(f"FAIL|{pf} declares zero protected-branch jobs (no job name matches {list(CRITICAL_JOB_TERMS)}) -- protection cannot be proven, refusing to pass vacuously")
        failures += 1
        continue

    for job in sorted(critical_jobs):
        job_def = data[job]
        rules = job_def.get("rules", [])
        if not isinstance(rules, list) or not rules:
            print(f"FAIL|{pf} -> job '{job}' has no 'rules:' block, so it is not restricted to a protected branch")
            file_failures += 1
            continue

        guarded = is_protected(rules)
        if not guarded:
            print(f"FAIL|{pf} -> job '{job}' is not gated on a protected branch ({'/'.join(sorted(PROTECTED_BRANCHES))}): {rules}")
            file_failures += 1
            continue

        print(f"PASS|{pf} -> job '{job}' restricted to a protected branch")

    if file_failures == 0:
        print(f"PASS|{pf} -> all {len(critical_jobs)} protected-branch job(s) are gated")
    failures += file_failures

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF

# 2. Guideline 2: Separate credentials from code
log_header "Guideline 2: Separate Credentials from Code (Secret Leak Checks)"

# 2a. High-confidence credential signatures
STATIC_LEAK_PATTERNS=(
  "-----BEGIN RSA PRIVATE KEY-----"
  "-----BEGIN OPENSSH PRIVATE KEY-----"
  "-----BEGIN EC PRIVATE KEY-----"
  "-----BEGIN (DSA|PGP) PRIVATE KEY BLOCK-----"
  "AKIA[0-9A-Z]{16}"
  "ASIA[0-9A-Z]{16}"
  "glpat-[A-Za-z0-9_-]{20,}"
  "ghp_[A-Za-z0-9]{36}"
  "gho_[A-Za-z0-9]{36}"
  "github_pat_[A-Za-z0-9_]{22,}"
  "xox[baprs]-[A-Za-z0-9-]{10,}"
  "AIza[0-9A-Za-z_-]{35}"
  "sk-[A-Za-z0-9]{20,}"
)

log_info "Leak scan scope: every tracked and untracked text file, shell scripts included."
log_info "Leak scan excludes ${#LEAK_SCAN_EXCLUSIONS[@]} audit artefact(s) that quote the signatures they detect:"
for excl in "${LEAK_SCAN_EXCLUSIONS[@]}"; do
  log_info "leak scan excluded: ${excl}"
done

LEAK_FOUND=0
for pat in "${STATIC_LEAK_PATTERNS[@]}"; do
  MATCHES="$(grep -rnE -e "$pat" "${SCAN_EXCLUDE_DIRS[@]}" "${SCAN_EXCLUDE_ARGS[@]}" . || true)"
  if [ -n "$MATCHES" ]; then
    log_fail "Credential signature '${pat}' present in repository:"
    printf '%s\n' "$MATCHES" | head -n 20 | sed 's/^/          /'
    LEAK_FOUND=1
  fi
done

if [ "$LEAK_FOUND" -eq 0 ]; then
  log_pass "No hardcoded private keys or live cloud/VCS/SCM API tokens anywhere in the repository"
fi

# 2b. Credential-shaped literals, including environment fallbacks
report_assertions << 'PYEOF'
import os, re

LEAK_SCAN_EXCLUSIONS = (
    "scripts/audit_orchestrator.sh",
    "scripts/verify_security.sh",
    "docs/AUDIT_GUIDE.md",
    "README.md",
)
SKIP_DIRS = {".git", ".terraform", "node_modules", "__pycache__", ".pytest_cache", ".venv", "venv", "reports"}
BINARY_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip", ".gz", ".whl", ".so", ".pyc")

LITERAL = re.compile(
    r"""(?i)(?<![A-Za-z0-9])(password|passwd|secret|token|api_key|access_key|credential|private_key)"""
    r"""["']?[ \t]*[:=,][ \t]*["']([^"'\n]{6,})["']"""
)

TEMPLATE_MARKERS = ("{{", "{%", "lookup(", "| default(")
PLACEHOLDER_TOKENS = {"changeme", "change_me", "change-me", "password", "secret", "token", "null", "none", "todo", "xxx"}


def is_placeholder(value):
    v = value.strip()
    if not v:
        return True
    if v.startswith("<") and v.endswith(">"):
        return True
    if v.startswith("$") or "${" in v:
        return True
    if set(v) <= {"*"}:
        return True
    return v.lower() in PLACEHOLDER_TOKENS


leaks = []
deferred = []

EXCLUDED = set(LEAK_SCAN_EXCLUSIONS)

for dirpath, dirnames, filenames in os.walk("."):
    dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
    for fn in sorted(filenames):
        if fn.endswith(BINARY_SUFFIXES):
            continue
        path = os.path.normpath(os.path.join(dirpath, fn))
        rel = os.path.relpath(path, ".")
        if rel in EXCLUDED:
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(lines, 1):
            m = LITERAL.search(line)
            if not m:
                continue
            entry = f"{path}:{lineno}: {line.strip()[:150]}"
            if any(tok in line for tok in TEMPLATE_MARKERS):
                deferred.append(f"{path}:{lineno}: value resolved from environment/Jinja lookup, not a committed literal")
            elif is_placeholder(m.group(2)):
                deferred.append(f"{path}:{lineno}: value is a placeholder or shell expansion, not a credential")
            else:
                leaks.append(entry)

for entry in leaks:
    print(f"FAIL|Hardcoded credential committed to the repository -> {entry}")

if not leaks:
    print("PASS|No credential-shaped literal assignments committed to the repository")

if deferred:
    print(f"INFO|{len(deferred)} credential-shaped assignment(s) resolve to an environment lookup or a placeholder, so they are not counted as leaked secrets:")
    for entry in deferred[:15]:
        print(f"INFO|      {entry}")

print(f"DONE|{'error' if leaks else 'ok'}")
PYEOF

# 2c. No sensitive artefact may be tracked by git
report_assertions << 'PYEOF'
import re, subprocess, sys

TRACKED = subprocess.run(["git", "ls-files"], capture_output=True, text=True)
if TRACKED.returncode != 0:
    print(f"DONE|error")
    raise SystemExit(0)

SENSITIVE = re.compile(
    r"(?:^|/)\.env(?:\..*)?$"
    r"|\.env$"
    r"|\.pem$"
    r"|\.key$"
    r"|\.p12$"
    r"|\.pfx$"
    r"|\.tfstate(?:\..*)?$"
    r"|\.tfvars\.json$"
    r"|(^|/)id_rsa"
)

tracked = [p for p in TRACKED.stdout.splitlines() if p]
offenders = sorted(p for p in tracked if SENSITIVE.search(p))

if offenders:
    for path in offenders:
        print(f"FAIL|Sensitive file is tracked in the git index: {path}")
else:
    print(f"PASS|None of the {len(tracked)} tracked paths is a .env/.pem/.key/.p12/.tfstate/.tfvars.json credential artefact")

print(f"DONE|{'error' if offenders else 'ok'}")
PYEOF

# 2d. .gitignore must guard the same artefact classes, anchored
log_header "Guideline 2d: .gitignore Secret Guards (anchored patterns)"
REQUIRED_GITIGNORE_PATTERNS=('.env' '*.pem' '*.key' '*.p12' '*.tfstate' '*.tfvars.json')
if [ ! -f ".gitignore" ]; then
  log_fail ".gitignore does not exist, so credential artefacts are not guarded"
else
  for pat in "${REQUIRED_GITIGNORE_PATTERNS[@]}"; do
    if grep -qxF -- "$pat" ".gitignore"; then
      log_pass ".gitignore anchors '${pat}' as a whole-line pattern"
    else
      log_fail ".gitignore lacks a whole-line '${pat}' entry (a loose substring match is not sufficient)"
    fi
  done
fi

# 3. Guideline 3: Apply the least privilege principle
log_header "Guideline 3: Apply the Least Privilege Principle"

# 3a. Dockerfiles must run as non-root user
DOCKERFILES=("srcs/api-gateway/Dockerfile" "srcs/inventory-app/Dockerfile" "srcs/billing-app/Dockerfile")
for df in "${DOCKERFILES[@]}"; do
  if [ ! -f "$df" ]; then
    log_fail "Missing Dockerfile: $df"
    continue
  fi

  if grep -qE '^USER[ \t]+[a-zA-Z0-9_-]+' "$df" && ! grep -qE '^USER[ \t]+root' "$df"; then
    log_pass "$df enforces non-root execution (Least Privilege)"
  else
    log_fail "$df runs as root or lacks USER directive"
  fi
done

# 3b-3e. Terraform security groups: world-exposed sensitive ports, ingress
#       source egress coverage, explicit egress, and unrestricted egress.
report_assertions << 'PYEOF'
import os, re, sys

SG_FILE = "infra/modules/security_groups/main.tf"

SENSITIVE_PORTS = {
    "database": [5432, 5433],
    "rabbitmq": [5672, 15672],
}

WORLD_CIDRS = {"0.0.0.0/0", "::/0", "0.0.0.0", "::"}

failures = 0


def lex(src):
    """Return (structural_view, value_view).

    Both views blank comments. The structural view additionally blanks string
    interiors so brace balancing can never be confused by '{' inside a quoted
    value. The value view keeps strings intact so attribute values stay readable.
    """
    code = list(src)
    vals = list(src)
    n = len(src)
    i = 0
    while i < n:
        c = src[i]
        if c == "#" or (c == "/" and i + 1 < n and src[i + 1] == "/"):
            j = src.find("\n", i)
            j = n if j == -1 else j
            for k in range(i, j):
                code[k] = " "
                vals[k] = " "
            i = j
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j == -1 else j + 2
            for k in range(i, j):
                if src[k] != "\n":
                    code[k] = " "
                    vals[k] = " "
            i = j
        elif c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    break
                j += 1
            for k in range(i + 1, min(j, n)):
                if src[k] != "\n":
                    code[k] = " "
            i = min(j + 1, n)
        elif c == "<" and src.startswith("<<", i):
            m = re.match(r"<<-?([A-Za-z_][A-Za-z0-9_]*)\s*\n", src[i:])
            if not m:
                i += 1
                continue
            tag = m.group(1)
            for k in range(i, i + m.end()):
                code[k] = " "
                vals[k] = " "
            i += m.end()
            while i < n:
                eol = src.find("\n", i)
                eol = n if eol == -1 else eol
                stop = src[i:eol].strip() == tag
                for k in range(i, eol):
                    code[k] = " "
                    vals[k] = " "
                i = eol + 1 if stop else eol + 1
        else:
            i += 1
    return "".join(code), "".join(vals)


def match_brace(code, open_idx):
    depth = 0
    for k in range(open_idx, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return -1


if not os.path.isfile(SG_FILE):
    print(f"FAIL|{SG_FILE} not found, network least-privilege rules cannot be verified")
    print("DONE|error")
    raise SystemExit(0)

SRC = open(SG_FILE, encoding="utf-8").read()
CODE, VALS = lex(SRC)


def top_level_bodies(pattern):
    out = []
    for m in pattern.finditer(VALS):
        ob = m.end() - 1
        cb = match_brace(CODE, ob)
        if cb != -1:
            out.append((m, VALS[ob + 1:cb], CODE[ob + 1:cb]))
    return out


# Resolve locals{} so 'from_port = local.postgres_port' is compared as 5432
# rather than as an opaque expression.
LOCALS = {}
for _ in range(8):
    changed = False
    for m, body_vals, _body_code in top_level_bodies(re.compile(r"(?m)^locals\s*\{")):
        for am in re.finditer(r"(?m)^[ \t]*([A-Za-z0-9_]+)[ \t]*=[ \t]*(.+?)[ \t]*$", body_vals):
            key, raw = am.group(1), am.group(2).strip()
            if raw.startswith("local."):
                raw = LOCALS.get(raw.split(".", 1)[1], raw)
            if LOCALS.get(key) != raw:
                LOCALS[key] = raw
                changed = True
    if not changed:
        break


def expand(raw, depth=0):
    if raw is None or depth > 8:
        return raw
    def repl(m):
        return LOCALS.get(m.group(1), m.group(0))
    return re.sub(r"local\.([A-Za-z0-9_]+)", repl, raw)


SG_RES = re.compile(r'resource\s+"aws_security_group"\s+"([A-Za-z0-9_-]+)"\s*\{')
RULE_RES = {"ingress": re.compile(r"(?m)^[ \t]*ingress\s*\{"),
            "egress": re.compile(r"(?m)^[ \t]*egress\s*\{")}

GROUPS = {}
DUPLICATES = []
for m in SG_RES.finditer(VALS):
    ob = m.end() - 1
    cb = match_brace(CODE, ob)
    if cb == -1:
        print(f"FAIL|Unbalanced braces in {SG_FILE}: resource aws_security_group.{m.group(1)} is never closed")
        failures += 1
        continue
    if m.group(1) in GROUPS:
        DUPLICATES.append(m.group(1))
    GROUPS[m.group(1)] = {"src": SRC[ob + 1:cb], "code": CODE[ob + 1:cb], "vals": VALS[ob + 1:cb],
                          "ingress": [], "egress": []}

for dup in sorted(set(DUPLICATES)):
    print(f"FAIL|aws_security_group '{dup}' is declared more than once in {SG_FILE}; only the final declaration is audited, so the earlier rules are unverified")
    failures += 1

for name, grp in GROUPS.items():
    for kind, rx in RULE_RES.items():
        for rm in rx.finditer(grp["vals"]):
            ob = rm.end() - 1
            cb = match_brace(grp["code"], ob)
            if cb == -1:
                print(f"FAIL|Unbalanced braces in {SG_FILE}: {name} {kind} block is never closed")
                failures += 1
                continue
            grp[kind].append({"src": grp["src"][ob + 1:cb],
                              "code": grp["code"][ob + 1:cb],
                              "vals": grp["vals"][ob + 1:cb]})

if not GROUPS:
    print(f"FAIL|{SG_FILE} declares no aws_security_group resource, so network least-privilege cannot be verified")
    print("DONE|error")
    raise SystemExit(0)


def attr(rule, name):
    m = re.search(r"(?m)^[ \t]*" + name + r"[ \t]*=[ \t]*", rule["vals"])
    if not m:
        return None
    start = m.end()
    if start < len(rule["code"]) and rule["code"][start] == "[":
        depth = 0
        for k in range(start, len(rule["code"])):
            if rule["code"][k] == "[":
                depth += 1
            elif rule["code"][k] == "]":
                depth -= 1
                if depth == 0:
                    return expand(rule["vals"][start:k + 1])
        return expand(rule["vals"][start:])
    eol = rule["vals"].find("\n", start)
    raw = rule["vals"][start:] if eol == -1 else rule["vals"][start:eol]
    return expand(raw.strip())


def as_int(raw):
    if raw is None:
        return None
    m = re.match(r"-?\d+", raw.strip())
    return int(m.group(0)) if m else None


def as_strings(raw):
    return [] if raw is None else re.findall(r'"([^"]*)"', raw)


def as_refs(raw):
    if raw is None:
        return []
    refs = re.findall(r"aws_security_group\.([A-Za-z0-9_-]+)\.id", raw)
    refs += [s for s in as_strings(raw) if s != "self"]
    return refs


def is_world_open(rule):
    v4 = set(as_strings(attr(rule, "cidr_blocks")))
    v6 = set(as_strings(attr(rule, "ipv6_cidr_blocks")))
    return bool(v4 & WORLD_CIDRS) or bool(v6 & WORLD_CIDRS)


def port_verdict(rule, port):
    proto = as_strings(attr(rule, "protocol"))
    proto = proto[0] if proto else ""
    if proto in ("-1", "all"):
        return True, f"protocol '{proto or '-1'}' admits every port including {port}"
    fp = as_int(attr(rule, "from_port"))
    tp = as_int(attr(rule, "to_port"))
    if fp is None:
        return True, f"no resolvable from_port, so exclusion of port {port} cannot be proven"
    if tp is None:
        tp = fp
    if fp <= port <= tp:
        return True, f"port range {fp}-{tp} covers sensitive port {port}"
    return False, f"port range {fp}-{tp} excludes port {port}"


# 3b. Sensitive data-store ports must never be reachable from the world.
print(f"INFO|Parsed {len(GROUPS)} aws_security_group resource(s) from {SG_FILE} with a brace-balanced extractor")

for sg_name, ports in SENSITIVE_PORTS.items():
    grp = GROUPS.get(sg_name)
    if grp is None:
        print(f"FAIL|Expected security group '{sg_name}' is absent from {SG_FILE}, its exposure cannot be verified")
        failures += 1
        continue

    for port in ports:
        offenders = []
        for idx, rule in enumerate(grp["ingress"]):
            if not is_world_open(rule):
                continue
            exposed, why = port_verdict(rule, port)
            if exposed:
                offenders.append(f"ingress #{idx + 1} ({why})")
        if offenders:
            print(f"FAIL|Security group '{sg_name}' exposes sensitive port {port} to the internet: {'; '.join(offenders)}")
            failures += 1
        else:
            print(f"PASS|Security group '{sg_name}' never grants port {port} to an internet-wide CIDR ({len(grp['ingress'])} ingress rule(s) inspected)")

# Separate aws_security_group_rule resources can supply egress that is not
# visible as an inline block.
EXTERNAL_EGRESS = set()
for m in re.finditer(r'resource\s+"aws_security_group_rule"\s+"([A-Za-z0-9_-]+)"\s*\{', VALS):
    ob = m.end() - 1
    cb = match_brace(CODE, ob)
    if cb == -1:
        continue
    body = VALS[ob + 1:cb]
    if re.search(r'"egress"', body):
        EXTERNAL_EGRESS.update(re.findall(r"aws_security_group\.([A-Za-z0-9_-]+)\.id", body))

# 3c. An SG trusted as an ingress source must itself have restricted egress,
#     otherwise the grant is one-directional and the source can pivot freely.
referenced_sources = {}
for grp_name, grp in GROUPS.items():
    for idx, rule in enumerate(grp["ingress"]):
        for ref in as_refs(attr(rule, "security_groups")):
            referenced_sources.setdefault(ref, []).append(f"{grp_name} ingress #{idx + 1}")

if not referenced_sources:
    print("FAIL|No security group is referenced as an ingress security_groups source, so the source-egress cross-reference is vacuous")
    failures += 1
else:
    for ref, grants in sorted(referenced_sources.items()):
        target = GROUPS.get(ref)
        if target is None:
            print(f"FAIL|Ingress source security group '{ref}' ({'; '.join(grants)}) is not declared in {SG_FILE}")
            failures += 1
            continue
        if not target["egress"] and ref not in EXTERNAL_EGRESS:
            print(f"FAIL|Security group '{ref}' is trusted as an ingress source ({'; '.join(grants)}) but declares no egress block, so its outbound traffic is unrestricted")
            failures += 1
        else:
            print(f"PASS|Ingress source security group '{ref}' declares {len(target['egress'])} egress rule(s) for the grant(s) it receives ({'; '.join(grants)})")

# 3d. Omitting the egress block entirely is what makes AWS silently attach a
#     default allow-all egress rule to the group.
for name in sorted(GROUPS):
    grp = GROUPS[name]
    if grp["egress"]:
        print(f"PASS|Security group '{name}' declares {len(grp['egress'])} explicit egress rule(s), so no AWS default allow-all egress is attached")
    elif name in EXTERNAL_EGRESS:
        print(f"PASS|Security group '{name}' receives its egress from a separate aws_security_group_rule")
    else:
        print(f"FAIL|Security group '{name}' declares no egress block and no aws_security_group_rule; AWS attaches a default allow-all egress rule (every port to 0.0.0.0/0 and ::/0), which is unrestricted outbound access")
        failures += 1

# 3e. No egress rule may be a blanket allow.
for name in sorted(GROUPS):
    grp = GROUPS[name]
    blanket = []
    for idx, rule in enumerate(grp["egress"]):
        proto = as_strings(attr(rule, "protocol"))
        proto = proto[0] if proto else ""
        if proto in ("-1", "all") and is_world_open(rule):
            blanket.append(f"egress #{idx + 1} (protocol '{proto}' to {'/'.join(sorted(WORLD_CIDRS & set(as_strings(attr(rule, 'cidr_blocks')) + as_strings(attr(rule, 'ipv6_cidr_blocks')))))})")
    if blanket:
        print(f"FAIL|Security group '{name}' has unrestricted egress to the internet: {'; '.join(blanket)}")
        failures += 1
    elif not grp["egress"] and name not in EXTERNAL_EGRESS:
        print(f"INFO|Security group '{name}' declares no egress rule to assess; the missing-egress control above governs it")
    else:
        print(f"PASS|Security group '{name}' egress is port-scoped, no blanket allow-all rule present")

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF

# 4. Guideline 4: Update dependencies and tools regularly
log_header "Guideline 4: Automated Vulnerability & Dependency Scanning"
report_assertions << 'PYEOF'
import os, sys
import yaml

PIPELINES = [
    "srcs/api-gateway/.gitlab-ci.yml",
    "srcs/inventory-app/.gitlab-ci.yml",
    "srcs/billing-app/.gitlab-ci.yml",
]

REQUIRED_SCANNERS = ("bandit", "trivy", "gitleaks", "secret")
MIN_SCANNERS = 3

failures = 0

for pf in PIPELINES:
    if not os.path.isfile(pf):
        print(f"FAIL|{pf} is missing, its scanning posture cannot be audited")
        failures += 1
        continue

    with open(pf, encoding="utf-8") as fh:
        data = yaml.safe_load(fh)

    if not isinstance(data, dict):
        print(f"FAIL|{pf} is not a mapping of GitLab CI jobs")
        failures += 1
        continue

    scan_jobs = sorted(k for k, v in data.items() if isinstance(v, dict) and "scan" in k.lower())
    if len(scan_jobs) < MIN_SCANNERS:
        print(f"FAIL|{pf} configures only {len(scan_jobs)} scanner job(s) (minimum {MIN_SCANNERS}): {scan_jobs}")
        failures += 1
        continue

    print(f"PASS|{pf} configures {len(scan_jobs)} scanner job(s): {scan_jobs}")

    blob = str({k: data[k] for k in scan_jobs}).lower()
    for scanner in REQUIRED_SCANNERS:
        if scanner in blob:
            print(f"PASS|{pf} scanner stage covers '{scanner}'")
        else:
            print(f"FAIL|{pf} scanner stage does not cover '{scanner}': {scan_jobs}")
            failures += 1

print(f"DONE|{'error' if failures else 'ok'}")
PYEOF

# Summary
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}  CYBERSECURITY AUDIT SUMMARY                               ${NC}"
echo -e "${BOLD}============================================================${NC}"
echo -e "  Controls Passed: ${GREEN}${BOLD}${PASSED_CHECKS}${NC}"
echo -e "  Controls Failed: ${RED}${BOLD}${FAILED_CHECKS}${NC}"

if [ "$FAILED_CHECKS" -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}>>> ALL CYBERSECURITY COMPLIANCE CONTROLS PASSED! <<<${NC}\n"
  exit 0
else
  echo -e "\n${RED}${BOLD}>>> CYBERSECURITY COMPLIANCE FAILURES DETECTED <<<${NC}\n"
  exit 1
fi