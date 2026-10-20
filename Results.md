# Results

- **Updated:** 2026-10-21 00:49 EEST
- **Scope:** the remaining steps of `docs/AWS_SETUP.md`, run against AWS account `REDACTED_AWS_ACCOUNT_ID`
  (us-east-1) and the local test GitLab (`root/code-keeper`), plus what the project still lacks for
  the audit.
- **Code:** branch `aws/cheapest-setup`, commits `0cd87d1` (code) and `e9ed580` (guide).

## Summary

The AWS side is ready up to the point where secrets are needed. The Terraform state bucket and lock
table exist and work with the real backend, and the code plans cleanly (62 resources per
environment). Nothing billable runs yet: AWS credits are still **$73.06**.

Four things are missing before the first deploy. All four need you:

1. Docker Hub username, token and repositories (step 6), and removing a broken `DOCKERHUB_REPO`
   variable
2. The CI user's access key in GitLab (step 5)
3. The three passwords in GitLab (step 7)
4. Merging `aws/cheapest-setup` into `main` (step 9)

---

## Pipeline on the local GitLab

| Pipeline | Commit | Result |
|---|---|---|
| 8 | `0cd87d1` (code) | 22 passed, 2 failed, 4 skipped |
| 9 | `e9ed580` (guide only) | 4 of 4 passed (only lint and dependency scans run for a docs-only push) |

- **Passed in pipeline 8:** `pipeline:lint`, and build, unit tests (7, 20 and 32 tests passed) and
  all 5 scans for each of the 3 apps.
- **Failed:** `infra:init:staging` and `infra:init:production`, with "TF_STATE_BUCKET CI protected
  variable is unset". This is expected. The state variables now exist, but they are **protected**,
  so only `main` pipelines receive them. Branch pipelines keep stopping at `infra:init` by design.
- **Skipped:** the infra validate and plan jobs that depend on `infra:init`.

---

## Steps done

| Step | Status | What was checked |
|---|---|---|
| 3. Pre-flight checks | Done | Versions and quota as recorded in `docs/AWS_SETUP.md` step 3 |
| 4. State bucket and lock table | **Done** | See below |
| 8. CI/CD variables, non-secret part | **Done** | `TF_STATE_BUCKET`, `TF_STATE_REGION`, `TF_STATE_LOCK_TABLE` set as protected |
| Backend check | **Passed** | See below |

**Step 4:**

- Bucket `code-keeper-tfstate-REDACTED_AWS_ACCOUNT_ID`: versioning `Enabled`, encryption `AES256`, all four
  public access blocks on, tagged `Project=code-keeper`.
- Table `code-keeper-tf-locks`: `ACTIVE`, on-demand billing, key `LockID`.

**Backend check:** `terraform init` with the real S3 backend succeeded for both environments, and
`terraform plan` with locking on acquired and released the lock and planned 62 resources to add per
environment. It ran with placeholder secrets and created nothing; afterwards the bucket held no
objects and the lock table no items.

---

## What you need to do, in this order

Claude Code's safety check does not let Claude create AWS credentials or change the GitLab
variables, so these steps are yours. Every command below runs from the repo root, and none
of them prints a secret.

### 1. Docker Hub (step 6)

**Fix first:** the local GitLab has a variable `DOCKERHUB_REPO` whose value is the literal text
`<your-namespace>`. That came from running the earlier snippet without filling in the
placeholder. Project variables override the YAML default, so every image name would become
`docker.io/<your-namespace>/...` and the build would fail. The snippet in step 4 below replaces it.
Until you run that, delete it in GitLab (Settings → CI/CD → Variables), or run:

```bash
curl -s -o /dev/null -w "DELETE DOCKERHUB_REPO: HTTP %{http_code}\n" -X DELETE \
  -H "PRIVATE-TOKEN: $(cat ~/.config/code-keeper-local-gitlab/api-token)" \
  http://127.0.0.1:8929/api/v4/projects/1/variables/DOCKERHUB_REPO
```

`HTTP 204` means it is gone.

You need two things: the **username** (Docker ID) of an account that can push to the image
namespace, and an **access token** for that account. Docker shows a token only once and does not
store it, so a token you don't have can't be looked up; you generate a new one.

**Which account.** By default the pipeline pushes to `docker.io/grafido/...`. `grafido` is a Docker
Hub user account (joined 2025-04-26) that already holds this project's images, last pushed on
2026-10-03, so someone on the team made it. Pick one:

- **Your own free account.** This is the simplest choice if `grafido` is not yours, because nobody
  has to share a token. Sign up at https://hub.docker.com/signup and confirm your email. Your
  username is also your namespace.
- **The `grafido` account.** Use it only if it is yours, or if its owner generates a token for you
  and sends it privately (not in a group chat or a commit). If you think it is yours but have
  forgotten the login, use "Forgot password" on the Docker sign-in page with your email address.

**Finding your username:** sign in at https://app.docker.com; the username appears when you click
your avatar (top right), and your public page is `https://hub.docker.com/u/<username>`. Use the
username, not your email, for the pipeline.

Then:

1. Create 3 **public** repositories in your namespace: `api-gateway`, `inventory-app`,
   `billing-app` (https://hub.docker.com → Create a repository). You can skip this if you use
   `grafido`, which already has them.
2. Generate a token: at https://app.docker.com, click your avatar → **Account settings** →
   **Personal access tokens** → **Generate new token**. Set access permissions to **Read & Write**
   and an expiration that covers the audit (for example 90 days), then **Generate**. Copy the token
   straight away; Docker shows it only once.
3. Keep the token in a password manager. The script below never prints it.
4. Store everything in the local GitLab. Run this in your own terminal, since it asks for input.
   It asks for the username, the token and the namespace (press Enter to use your username), checks
   the login with Docker Hub, and only stores anything if the login works. It replaces any earlier
   `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` and `DOCKERHUB_REPO`, including the broken one.

```bash
(
T="$(cat ~/.config/code-keeper-local-gitlab/api-token)"; API=http://127.0.0.1:8929/api/v4/projects/1/variables
read -rp "Docker Hub username: " DH_USER
read -rsp "Docker Hub access token: " DH_TOKEN; echo
read -rp "Image namespace [$DH_USER]: " DH_NS; DH_NS="${DH_NS:-$DH_USER}"
echo "Token entered: ${#DH_TOKEN} characters"
case "$DH_TOKEN" in dckr_pat_*) ;; *) echo "Warning: access tokens start with dckr_pat_; this looks like something else.";; esac
resp=$(printf 'user = "%s:%s"\n' "$DH_USER" "$DH_TOKEN" | curl -s -K - -w "\n%{http_code}" \
  "https://auth.docker.io/token?service=registry.docker.io&account=$DH_USER")
code="${resp##*$'\n'}"
[ "$code" = 200 ] || { echo "Docker Hub rejected the login (HTTP $code: $(printf %s "${resp%$'\n'*}" | head -c 200)); nothing was stored."; exit 1; }
echo "Docker Hub login: OK"
for k in DOCKERHUB_USERNAME DOCKERHUB_TOKEN DOCKERHUB_REPO; do
  curl -s -o /dev/null -X DELETE -H "PRIVATE-TOKEN: $T" "$API/$k"
done
curl -s -o /dev/null -w "DOCKERHUB_USERNAME: HTTP %{http_code}\n" -X POST -H "PRIVATE-TOKEN: $T" "$API" \
  --data-urlencode "key=DOCKERHUB_USERNAME" --data-urlencode "value=$DH_USER" -d protected=true -d masked=false -d raw=true
printf %s "$DH_TOKEN" | curl -s -o /dev/null -w "DOCKERHUB_TOKEN: HTTP %{http_code}\n" -X POST -H "PRIVATE-TOKEN: $T" "$API" \
  --data-urlencode "key=DOCKERHUB_TOKEN" --data-urlencode "value@-" -d protected=true -d masked=true -d raw=true
curl -s -o /dev/null -w "DOCKERHUB_REPO: HTTP %{http_code}\n" -X POST -H "PRIVATE-TOKEN: $T" "$API" \
  --data-urlencode "key=DOCKERHUB_REPO" --data-urlencode "value=$DH_NS" -d raw=true
)
```

When you paste the token, nothing appears on screen. In the Ubuntu terminal, paste with
**Ctrl+Shift+V** or right-click → Paste; plain Ctrl+V does not paste there. The script then
shows how many characters it received. A Docker access token starts with `dckr_pat_`, followed by
a long random string. If the count is 0, or the warning appears, the paste did not work or the
password went in instead.

You should see `Docker Hub login: OK` and then `HTTP 201` three times. The check confirms the
username and token, not the Read & Write permission; a read-only token only fails later, when
`containerize:docker` pushes.

### 2. CI user and access key (step 5)

This script creates IAM user `code-keeper-ci` with `AdministratorAccess`, creates its access key,
checks that the key works, and stores it in GitLab as protected, masked `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY`. It refuses to make a second key if one already exists.

```bash
python3 -I /tmp/ck-sim/aws_step5_ci_user.py
```

`/tmp` is cleared on reboot. If the script is gone, do it in the console instead:

1. IAM → Users → Create user `code-keeper-ci`, without console access.
2. Attach `AdministratorAccess`.
3. Open the user → Security credentials → Create access key → "Application running outside AWS".
4. In GitLab (Settings → CI/CD → Variables), add `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
   with Visibility "Masked", "Protect variable" ticked and "Expand variable reference" unticked.

### 3. The three passwords (step 7)

Run once. It generates the passwords, keeps a copy in
`~/.config/code-keeper-local-gitlab/aws-tf-passwords.env` (readable only by you; copy it into a
password manager) and stores them in GitLab as protected, masked variables:

```bash
(
umask 077
T="$(cat ~/.config/code-keeper-local-gitlab/api-token)"
F=~/.config/code-keeper-local-gitlab/aws-tf-passwords.env
for n in TF_VAR_inventory_db_password TF_VAR_billing_db_password TF_VAR_rabbitmq_password; do
  v="$(openssl rand -hex 16)"
  echo "$n=$v" >> "$F"
  printf %s "$v" | curl -s -o /dev/null -w "$n: HTTP %{http_code}\n" -X POST -H "PRIVATE-TOKEN: $T" \
    http://127.0.0.1:8929/api/v4/projects/1/variables \
    --data-urlencode "key=$n" --data-urlencode "value@-" -d protected=true -d masked=true -d raw=true
done
)
```

All three lines should say `HTTP 201`.

### 4. First deploy (step 9)

Only after 1 to 3. **Charges start here:** about $0.37 an hour once staging is applied, and about
$0.75 an hour once production is applied too.

`git switch main` refuses while `CHANGELOG.md` has uncommitted changes, so commit it first.
`Results.md` stays uncommitted on purpose; it is a working to-do list, not part of the submission.

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): record Docker Hub, state backend and CI variable setup"
git switch main
git merge --ff-only aws/cheapest-setup
git push origin main
git push "http://root:$(cat ~/.config/code-keeper-local-gitlab/api-token)@localhost:8929/root/code-keeper.git" main
```

Staging then deploys by itself. For production, start these manual jobs in the pipeline view
(http://localhost:8929/root/code-keeper/-/pipelines): `infra:approval:production`, then the three
`<app>:approval:production` jobs. The local GitLab and its runner must stay up until the pipeline
finishes.

### 5. After the deploy

Tell Claude when the pipeline is done. Claude then runs the checks from step 10 and, when you say
testing is over, tears both environments down (step 11) and confirms nothing billable is left
(step 12).

---

## Still missing for the audit, beyond AWS

From the suggested order in `docs/READINESS_REVIEW.md`:

| Item | Status |
|---|---|
| Fix the pipeline and infra bugs | **Done** (items 1 to 11 and both infra bugs), plus the AWS fixes on `aws/cheapest-setup` |
| Real GitLab and runner installed with the Ansible playbooks | Not started. Needs a host (VM or EC2) |
| One repository per app and one for infra | Not started. Today all four live in one repo |
| AWS deploy with one full green pipeline | In progress: blocked on the four steps above |
| Docs match the code | Not started |

Details:

- **Ansible GitLab.** The audit asks for a GitLab instance installed with Ansible and runners
  executing jobs for all repositories. The local test GitLab does not count. Likely problems, not
  yet checked: the runner registration uses legacy tokens and flags that current GitLab rejects,
  `gitlab_version` is unpinned, and the `allowed_to_push` format in `ansible/roles/gitlab/tasks/cicd.yml`
  is probably wrong.
- **Repo split.** The brief requires each app in its own repository and the infra in an
  independent repository with its own pipeline. After the split, the CI/CD variables belong on the
  GitLab group so all four repos share them.
- **Docs.** `README.md` and `docs/AUDIT_GUIDE.md` still describe the old setup (Docker-in-Docker,
  GitLab registry, release tags, main-only pipelines, missing test files). `docs/AWS_SETUP.md` is
  current. Before submitting, remove or refresh `docs/AUDIT_READINESS_PLAN.md`,
  `reports/audit_report.json` and probably `docs/READINESS_REVIEW.md`, which lists the project's
  failures and is partly out of date. Files in `docs/` are changed by you; Claude drafts the text.
- **Audit timing.** The audit needs the solution running during the session. With $73 of credits
  (about 4 days with both environments up), deploy shortly before the audit and tear down right
  after.

Smaller points:

- The saved `.tfplan` artifacts contain the passwords and the Docker Hub token, and can be
  downloaded for 7 days.
- `aquasec/trivy:latest` is not pinned to a version.
- The comment in `infra/environments/*/backend.hcl` says the runner uses Terraform 1.9.5; CI uses
  `hashicorp/terraform:1.6`.
- The `image_repository_prefix` description in `infra/environments/*/variables.tf` still mentions
  the GitLab registry (`CI_REGISTRY_IMAGE`).
- SonarQube is not configured, so the SonarQube jobs pass without uploading anything.
