# Changelog

History of the changes made in this project, oldest first. Each entry says what changed, why,
and when. New entries are appended at the bottom.

## 2026-10-16 18:49 EEST: Add submission readiness review

**What**
- `docs/READINESS_REVIEW.md`: created. Verdict (not ready), the live systems the audit needs that do
  not exist yet, the pipeline bugs, the infra bugs, the repo-layout requirements that fail, the docs
  that contradict the code, what is already good, a suggested fix order and the review method.

**Why**
The user asked for the findings and suggestions from the readiness review as a Markdown file in
`docs/`. The name avoids "report" so it doesn't get mixed up with `reports/audit_report.json`.

**Verified**
Checked the file for em and en dashes with grep; none found. No other files were changed.

## 2026-10-19 19:04 EEST: Fix the two pipeline-creation blockers from the readiness review

**What**
- `srcs/api-gateway/.gitlab-ci.yml`, `srcs/inventory-app/.gitlab-ci.yml`, `srcs/billing-app/.gitlab-ci.yml`:
  added the missing `before_script:` key in `test:unit`, `scan:sast_bandit` and `scan:dependencies`,
  so the `echo`, `cd "${APP_DIR}"` and `pwd` lines leave `rules:` and run before the job script
  again (9 jobs).
- `infra/.gitlab-ci.yml`: gave `infra:approval:production` and `infra:apply:production` the same
  `changes: infra/**/*` filter as `infra:plan:production`, with a short comment on the apply job.

**Why**
Items 1 and 2 of `docs/READINESS_REVIEW.md`: string entries in `rules:` and a `needs:` on a job
that rules exclude both make GitLab refuse to create a pipeline. For item 2 the `changes:` filter
was chosen over `needs: optional: true`, because with `optional` the apply job would still run on
every push to `main` and fail on the missing `production.tfplan`.

**Verified**
A rules and needs simulation of the merged config over 9 pipeline scenarios (push to main or a
branch, merge request, schedule) found 27 non-hash rules and 2 unresolved needs before the change
and none after. A strict YAML load found no duplicate keys. Validation against GitLab's `ci.json`
schema showed the same error count before and after the change; those errors come from a separate
problem (script lines containing `: ` that YAML reads as mappings), which is not fixed yet.

## 2026-10-19 19:33 EEST: Quote the 71 script lines GitLab read as mappings

**What**
- `infra/.gitlab-ci.yml` (13 lines), `srcs/api-gateway/.gitlab-ci.yml` (20),
  `srcs/inventory-app/.gitlab-ci.yml` (19), `srcs/billing-app/.gitlab-ci.yml` (19): wrapped every
  `script:` entry that contains `: ` in single quotes, doubling any inner single quote, the same way
  `srcs/api-gateway/.gitlab-ci.yml:47` already did.
- `docs/READINESS_REVIEW.md`: added item 10 ("Script lines that YAML reads as mappings") under a new
  "Found after the review" heading, pointed the blocker sentence and the suggested order at it, and
  added GitLab's `ci.json` schema to the sources.

**Why**
Without quotes, YAML turns a line like `- echo " Commit: ${CI_COMMIT_SHA}"` into a one-key mapping,
and GitLab rejects the whole configuration because script entries must be strings. This was a third
blocker next to items 1 and 2, missed in the original review.

**Verified**
GitLab 19.5.0's CI Lint API (local instance, see the next entry) returned 32 errors for the HEAD
config (9 `rules should be an array containing hashes`, 23 `script config should be a string`) and
`valid=true` with 0 errors for the working tree. The `ci.json` schema check reports 0 errors in all
five files, every job's script list carries exactly the same commands as before, the rules and
needs simulation still passes, and `scripts/test_pipelines.sh` reports 91 passed, 0 failed.

## 2026-10-19 19:33 EEST: Local GitLab and runner for live pipeline tests

**What**
- Docker images pulled: `gitlab/gitlab-ce:19.5.0-ce.0` (6.08 GB) and `gitlab/gitlab-runner:alpine-v19.5.0`.
- Docker network `ck-gitlab-net` and volumes `ck-gitlab-config`, `ck-gitlab-logs`, `ck-gitlab-data`,
  `ck-runner-config` created.
- Containers started: `ck-gitlab` (GitLab CE, bound to `127.0.0.1:8929` only, service ping off) and
  `ck-gitlab-runner` (Docker executor, 4 concurrent jobs, jobs join `ck-gitlab-net`, host Docker
  socket mounted).
- Inside GitLab: an API token for `root` (`api`, `create_runner`, `write_repository`, expires
  2026-10-26), the private project `root/code-keeper`, and instance runner `ck-local-docker`
  registered with a `glrt-` authentication token.
- `~/.config/code-keeper-local-gitlab/` (mode 700, outside the repo): `root-password`, `api-token`,
  `runner-token`, `gitlab.env`, each mode 600. Helper scripts live in `/tmp/ck-sim/`.

**Why**
The user asked for a live test of the pipeline fixes. No GitLab instance exists, and a local one
needs no outside credentials. This is a test bed only; it is not the Ansible-deployed GitLab the
audit asks for.

**Verified**
`/api/v4/version` reports 19.5.0, and the runner shows `status=online` in `/api/v4/runners/all`.
