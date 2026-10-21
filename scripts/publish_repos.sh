#!/usr/bin/env bash
# ==============================================================================
# Script: publish_repos.sh
# Purpose: Publishes the four parts of this monorepo to their own GitLab projects
#          in the code-keeper group (created by ansible/roles/gitlab):
#            infra               -> code-keeper/infra
#            srcs/api-gateway    -> code-keeper/api-gateway
#            srcs/inventory-app  -> code-keeper/inventory-app
#            srcs/billing-app    -> code-keeper/billing-app
#          Each project gets the folder's own history (git subtree split) with the
#          folder as its root, so its .gitlab-ci.yml runs that project's pipeline.
#          Only committed work is published: the split reads HEAD, not the
#          working tree.
#
# Usage:
#   GITLAB_URL=http://<gitlab-ip> scripts/publish_repos.sh [--dry-run] [project...]
#   scripts/publish_repos.sh --dry-run            # show the split commits only
#   scripts/publish_repos.sh infra                # one project
#
# On a new AWS account, publish infra first and let its pipeline reach
# "Apply to Staging": the app pipelines deploy into the ECS services it creates.
#
# Environment:
#   GITLAB_URL          GitLab address (terraform -chdir=ansible/terraform output -raw gitlab_url)
#   GITLAB_GROUP        group path (default: code-keeper)
#   GITLAB_USER         user for HTTP pushes (default: root)
#   GITLAB_PUSH_TOKEN   optional personal access token with write_repository (the
#                       password works too). It is passed to git through the
#                       environment, never on the command line or in .git/config.
#                       Without it, the script asks for the password once.
#   GITLAB_REMOTE_BASE  optional remote prefix that replaces GITLAB_URL/GITLAB_GROUP,
#                       for example git@203.0.113.10:code-keeper to push over SSH
#                       with a key added to your GitLab profile
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

ORDER=(infra api-gateway inventory-app billing-app)
declare -A PREFIX=(
  [infra]="infra"
  [api-gateway]="srcs/api-gateway"
  [inventory-app]="srcs/inventory-app"
  [billing-app]="srcs/billing-app"
)

DRY_RUN=0
SELECTED=()
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      sed -n '2,33p' "$0"
      exit 0
      ;;
    *)
      if [ -z "${PREFIX[${arg}]:-}" ]; then
        echo "Unknown project '${arg}'. Known: ${ORDER[*]}" >&2
        exit 1
      fi
      SELECTED+=("${arg}")
      ;;
  esac
done
[ ${#SELECTED[@]} -gt 0 ] || SELECTED=("${ORDER[@]}")

GITLAB_GROUP="${GITLAB_GROUP:-code-keeper}"
GITLAB_USER="${GITLAB_USER:-root}"

if [ -n "${GITLAB_REMOTE_BASE:-}" ]; then
  REMOTE_BASE="${GITLAB_REMOTE_BASE%/}"
elif [ -n "${GITLAB_URL:-}" ]; then
  REMOTE_BASE="${GITLAB_URL%/}/${GITLAB_GROUP}"
elif [ "${DRY_RUN}" -eq 0 ]; then
  echo "ERROR: set GITLAB_URL (or GITLAB_REMOTE_BASE), for example:" >&2
  echo "  GITLAB_URL=\$(terraform -chdir=ansible/terraform output -raw gitlab_url) $0" >&2
  exit 1
else
  REMOTE_BASE="<GITLAB_URL>/${GITLAB_GROUP}"
fi

# HTTP pushes send the token (or password) in a header built here, and git is kept away
# from askpass programs and credential helpers. Otherwise an editor terminal's askpass
# (VS Code sets GIT_ASKPASS) can answer with an empty password when the editor is not
# connected, and `credential.helper store` would save the root password in plain text
# in ~/.git-credentials. The password is asked for once, not once per project.
if [ -z "${GITLAB_REMOTE_BASE:-}" ] && [ -n "${GITLAB_URL:-}" ] && [ "${DRY_RUN}" -eq 0 ]; then
  if [ -z "${GITLAB_PUSH_TOKEN:-}" ]; then
    # Only opening the terminal is silenced; the question itself goes to stderr.
    if ! { exec 3</dev/tty; } 2>/dev/null; then
      echo "ERROR: no terminal to ask for the password; set GITLAB_PUSH_TOKEN instead" >&2
      exit 1
    fi
    printf 'GitLab password (or token) for %s at %s: ' "${GITLAB_USER}" "${GITLAB_URL%/}" >&2
    read -rs GITLAB_PUSH_TOKEN <&3 || true
    exec 3<&-
    echo
  fi
  if [ -z "${GITLAB_PUSH_TOKEN}" ]; then
    echo "ERROR: the password is empty" >&2
    exit 1
  fi
  unset GIT_ASKPASS SSH_ASKPASS
  export GIT_TERMINAL_PROMPT=0
  export GIT_CONFIG_COUNT=2
  export GIT_CONFIG_KEY_0="credential.helper"
  export GIT_CONFIG_VALUE_0=""
  export GIT_CONFIG_KEY_1="http.extraHeader"
  GIT_CONFIG_VALUE_1="Authorization: Basic $(printf '%s:%s' "${GITLAB_USER}" "${GITLAB_PUSH_TOKEN}" | base64 | tr -d '\n')"
  export GIT_CONFIG_VALUE_1
fi

# Check access once before splitting, so a wrong password stops here with a clear message.
if [ "${DRY_RUN}" -eq 0 ] && ! git ls-remote --heads "${REMOTE_BASE}/${SELECTED[0]}.git" >/dev/null; then
  echo "ERROR: cannot read ${REMOTE_BASE}/${SELECTED[0]}.git as ${GITLAB_USER}." >&2
  echo "       Check the password (or token) and that the project exists in GitLab." >&2
  exit 1
fi

# git subtree relies on GNU dirname ("infra/." -> "infra"). Ubuntu 25.10 ships the
# uutils dirname, which returns "." there, and the split then dies with
# "assertion failed: test README.md = .". Ubuntu keeps the GNU tool as gnudirname,
# so the split runs with that one first in PATH.
SPLIT_PATH="${PATH}"
if [ "$(dirname "infra/.")" != "infra" ]; then
  if ! command -v gnudirname >/dev/null 2>&1; then
    echo "ERROR: this dirname turns 'infra/.' into '$(dirname "infra/.")'; git subtree needs GNU dirname" >&2
    exit 1
  fi
  SHIM_DIR="$(mktemp -d)"
  trap 'rm -rf "${SHIM_DIR}"' EXIT
  ln -s "$(command -v gnudirname)" "${SHIM_DIR}/dirname"
  SPLIT_PATH="${SHIM_DIR}:${PATH}"
fi

echo "============================================================"
echo " Publishing ${#SELECTED[@]} project(s) from $(git rev-parse --short HEAD) to ${REMOTE_BASE}"
[ "${DRY_RUN}" -eq 1 ] && echo " Dry run: nothing is pushed"
echo "============================================================"

for name in "${SELECTED[@]}"; do
  prefix="${PREFIX[${name}]}"
  remote="${REMOTE_BASE}/${name}.git"
  echo
  echo "=== ${prefix} -> ${name}"
  if [ ! -f "${prefix}/.gitlab-ci.yml" ]; then
    echo "ERROR: ${prefix}/.gitlab-ci.yml is missing; the project would have no pipeline" >&2
    exit 1
  fi
  if [ -n "$(git status --porcelain -- "${prefix}")" ]; then
    echo "WARNING: ${prefix} has uncommitted changes; only the committed state is published." >&2
  fi
  split="$(PATH="${SPLIT_PATH}" git subtree split --quiet --prefix="${prefix}" HEAD)"
  echo "    split commit $(git rev-parse --short "${split}") ($(git rev-list --count "${split}") commits of history)"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "    would push it to ${remote} as main"
    continue
  fi
  # A plain push: main is protected against force pushes, and the split of a
  # linear history only ever moves forward.
  git push "${remote}" "${split}:refs/heads/main"
done

echo
echo "[SUCCESS] Each push starts that project's pipeline under ${GITLAB_GROUP}/<project>/-/pipelines."
