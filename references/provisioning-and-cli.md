# Jenkins Provisioning and CLI

## Supported Provisioning

Version 1 installs Docker Jenkins locally on macOS/Linux when Docker is already available, or on a POSIX Linux host reached through SSH. It connects to existing controllers without reinstalling them. Do not improvise native package, Kubernetes, or remote Windows installation.

Default controller image is `jenkins/jenkins:2.568.1-jdk21` and the managed agent is `jenkins/ssh-agent:8.6.0-jdk21`. The plan rejects floating tags; update these pins only through a reviewed upgrade plan and re-run verification. Persist `/var/jenkins_home`; keep JCasC and the versioned `plugins.lock.txt` declarations in the private installation directory. The controller has zero executors. A separate SSH-based managed agent performs builds without the host Docker socket.

Plain HTTP binds only to loopback. Use an HTTPS reverse proxy or a loopback SSH tunnel for remote credential-bearing access. Public HTTP is a blocking configuration error. Bootstrap administrator and agent private keys are file-backed under the private installation directory rather than exposed as container environment values.

Do not mount `/var/run/docker.sock` by default. If a project must build containers, design a dedicated least-privilege agent or an explicitly approved TLS Docker-in-Docker path.

Official references: [Docker installation](https://www.jenkins.io/doc/book/installing/docker/), [Java support policy](https://www.jenkins.io/doc/book/platform-information/support-policy-java/), [JCasC](https://www.jenkins.io/doc/book/managing/casc/).

## Minimal Execution Sequence

```bash
SKILL_DIR=/Users/im10furry/.codex/skills/implementing-jenkins-cicd

"$SKILL_DIR/scripts/inspect-project.py" --project PROJECT --output discovery.json
"$SKILL_DIR/scripts/plan-jenkins.py" create \
  --discovery discovery.json \
  --target local \
  --jenkins-url http://localhost:8086 \
  --port 8086 \
  --install-dir /absolute/private/jenkins \
  --repo-url REPOSITORY_URL \
  --scm-key-file /private/path/scm_ed25519 \
  --test-deploy-host DEPLOY_USER@TEST_HOST \
  --production-deploy-host DEPLOY_USER@PRODUCTION_HOST \
  --deployment-known-hosts /private/path/known_hosts \
  --deployment-key-file /private/path/deployment_ed25519 \
  --test-deploy-root /absolute/test/root \
  --production-deploy-root /absolute/production/root \
  --test-health-url TEST_HEALTH_URL \
  --production-health-url PRODUCTION_HEALTH_URL \
  --activation-confirmed \
  --output plan.json

PLAN_ID="$(python3 -c 'import json; print(json.load(open("plan.json"))["plan_id"])')"
"$SKILL_DIR/scripts/render-jenkins-assets.py" --plan plan.json --output bundle
"$SKILL_DIR/scripts/render-jenkins-assets.py" \
  --plan plan.json --output apply-evidence --apply-project PROJECT --approve "$PLAN_ID"
"$SKILL_DIR/scripts/orchestrate-jenkins-delivery.sh" \
  --plan plan.json --bundle bundle --approve "$PLAN_ID" \
  --project PROJECT --evidence evidence
```

The local installer generates random file-backed administrator and deployment-trigger passwords and a persistent agent SSH host key. It starts Jenkins, creates separate API tokens through the authenticated endpoint, writes administrator `.jenkins-cli.env` and least-privilege `.jenkins-trigger.env` profiles with mode `0600`, verifies authentication, and never prints either token. Source the administrator profile only for configuration. The project trigger uses only the trigger account, whose JCasC permissions are `Overall/Read`, `Job/Read`, and `Job/Build`.

For an existing controller, `configure-jenkins-plugins.sh` compares exact plugin names and versions. Before a missing-plugin write it requires structured backup evidence containing an absolute backup path, matching SHA-256, timezone-qualified timestamp, and `restore_tested: true`; a boolean assertion is not sufficient. It installs only missing pinned entries through guarded `install-plugin -deploy` and verifies the resulting inventory. If dynamic loading fails, plan a backed-up safe restart rather than hiding the failure.

## CLI Rules

Use the target controller's `${JENKINS_URL}/jnlpJars/jenkins-cli.jar`. `jenkins-cli-safe.sh` downloads it into a private temporary directory and deletes it on success, failure, or signal. It uses WebSocket transport and `JENKINS_USER_ID` plus `JENKINS_API_TOKEN`; credentials never appear in the command line.

Read commands are allowlisted. Write commands require a valid plan file and its exact SHA-256 identifier. They are bound to the planned controller, job, and plugin set. Job XML is deterministically re-rendered instead of accepting caller stdin. A changed plan or bundle invalidates approval. Job update keeps private prior XML. `build` is deliberately absent: Jenkins CLI configures Jenkins but does not trigger deployment. Never add `build`, `delete-job`, or arbitrary Groovy execution to the general allowlist.

The generated `ops/jenkins/trigger-deploy.sh` owns the deployment request. It uses the official Remote Access API `buildWithParameters` endpoint with API-token authentication, supplies `DEPLOY_ENV`, `GIT_REF`, and `EXPECTED_COMMIT`, and polls the returned queue/build resources. API-token requests are exempt from crumbs in supported Jenkins versions. The script allows HTTPS or loopback HTTP only and keeps credentials out of command arguments and query strings.

Official references: [Jenkins CLI](https://www.jenkins.io/doc/book/managing/cli/), [Remote Access API](https://www.jenkins.io/doc/book/using/remote-access-api/), [CSRF protection](https://www.jenkins.io/doc/book/security/csrf-protection/).

## Existing Controllers

Before writing, run `jenkins-readonly-audit.sh`. It records identity, core and plugin versions, jobs, and a machine-readable `security-baseline.json`; the latter matches installed versions against the fresh official update-center warning feed and exits nonzero on a match. API tokens do not bypass permissions. Refuse an obsolete or known-vulnerable controller until an upgrade and recovery plan exists. Back up relevant configuration and validate restore, not merely backup creation.

Official references: [Permissions](https://www.jenkins.io/doc/book/security/access-control/permissions/), [Security advisories](https://www.jenkins.io/security/advisories/), [Upgrade guides](https://www.jenkins.io/doc/upgrade-guide/), [Backups](https://www.jenkins.io/doc/book/system-administration/backing-up/).
