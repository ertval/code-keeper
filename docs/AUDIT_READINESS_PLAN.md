# Audit Readiness Plan

Status on 2026-10-21 evening: everything the audit needs runs. Ansible installed GitLab CE 19.5.0
and its runner on EC2, the four repositories are published on it, and their first pipelines passed
every job from build to production. This plan lists what is left before the audit, in order.
`docs/READINESS_REVIEW.md` has the status of every earlier finding.

---

## Done

| Part | Result |
|---|---|
| AWS environments | Staging and production applied from the `infra` pipeline; three services with 2 of 2 tasks in each |
| GitLab hosts | `ansible/terraform` created GitLab (`t3.large`) and the runner (`t3.medium`) with Elastic IPs |
| GitLab and runner | `ansible-playbook playbooks/site.yml`; a second run only renews the two one-day API tokens |
| Code | Committed and pushed as `c0c3213` |
| Four repositories | Published with `scripts/publish_repos.sh`: `infra` `c8ec62c`, `api-gateway` `0758a5c`, `inventory-app` `ae7b51d`, `billing-app` `85fb0af` |
| First pipelines | `infra` #1, `api-gateway` #2, `inventory-app` #3, `billing-app` #4: every job passed. Both infra plans "No changes"; production approved by root in the GitLab UI; both environments run the new images and answer `/health`, `/api/movies` and `/docs` |
| Audit script | `scripts/audit_orchestrator.sh` with its live checks on the EC2 hosts: 84 pass, 0 fail, 0 blocked; 4 skipped because checkov, hadolint, tflint and tfsec are not installed |

---

## 1. Move the docs into place and commit

1. Read the drafts, then move them into `docs/`:

   ```bash
   cp drafts/AUDIT_GUIDE.md drafts/AWS_SETUP.md drafts/READINESS_REVIEW.md drafts/AUDIT_READINESS_PLAN.md docs/
   rm -r drafts
   ```

2. Commit and push. This also takes the publish script fix, the runner token placeholder and
   `Results.md`:

   ```bash
   git add -A
   git commit -m "docs: audit guide, AWS setup and readiness for the GitLab on EC2"
   git push
   ```

3. Regenerate the audit report on the clean tree, so it names that commit, and commit it. The
   script needs `terraform`, `ansible-playbook`, `trivy`, `gitleaks` and `shellcheck` in `PATH`;
   missing tools are reported as skipped. It takes about 5 minutes.

   ```bash
   scripts/audit_orchestrator.sh
   git add reports
   git commit -m "chore(reports): regenerate the audit report"
   git push
   ```

No new publish is needed: none of these files are inside `infra/` or `srcs/`, so the four GitLab
projects already have the current code.

---

## 2. Confirm the crud-master claim

`docs/AUDIT_GUIDE.md` section 10.2 tells the auditor that the three services in `srcs/` are the
team's own crud-master code. If they came from somewhere else, change that answer before the audit.

---

## 3. Rehearse the audit

Walk through `docs/AUDIT_GUIDE.md` once, with every command, including:

- a merge request in one app project (pipeline on the MR, merge, staging, approval, production);
- a merge request in `infra` with a visible change (for example a tag);
- `ansible-playbook playbooks/site.yml --list-tasks`, `gitlab-ctl status`, `gitlab-runner list` (with the token hidden, as in the guide).

Each team member should be able to answer the sixteen role-play questions in their own words.

---

## 4. Between the rehearsal and the audit

Everything running costs about $0.93 an hour, about $22 a day. To save money, tear the AWS
environments down after the rehearsal (`docs/AWS_SETUP.md` step 13) and stop the two EC2 hosts;
their Elastic IPs keep the addresses. On the day before the audit, start the hosts and redeploy
(step 12): about an hour.

---

## 5. Optional improvements

Not needed to pass, each small:

| Improvement | Where |
|---|---|
| Pin the Trivy, Gitleaks, SonarQube and AWS CLI images | the four `.gitlab-ci.yml` |
| Keep plan artifacts out of reach (a shorter `expire_in`, or `artifacts:access` once tested with the apply jobs) | `infra/.gitlab-ci.yml` |
| Back to 7 days of RDS backups (the account is on the paid plan) | `backup_retention_period` in `infra/environments/*/main.tf` |
| A deploy-only IAM key for the app projects | `docs/AWS_SETUP.md` step 5 |
| SonarQube server and the two variables | group CI/CD variables |

---

## 6. After the audit

Destroy production, then staging, then the GitLab hosts, and run the leftover checks in
`docs/AWS_SETUP.md` step 14. Keep the state bucket and lock table.
