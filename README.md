# Implementing Jenkins CI/CD

> Guarded Jenkins installation, configuration, and explicit CI/CD delivery with exact commit provenance, health checks, rollback, and release retention.

[English](#english) | [简体中文](#中文)

<a id="english"></a>

# English

## What this repository provides

This repository is a Codex skill for taking a Jenkins delivery path from evidence gathering to a verified result. It is not a generic collection of Jenkins snippets. Its scripts and templates establish a controlled workflow for:

- inspecting an application repository before proposing CI/CD changes;
- creating a deterministic, approval-bound plan for a new Jenkins controller;
- installing a pinned Jenkins LTS controller and a separate SSH build agent, or safely connecting an existing controller;
- generating project-owned Jenkins assets and server-pull deployment programs;
- configuring plugins and Jobs through a controller-matched, configuration-only Jenkins CLI;
- explicitly triggering a test or production delivery through the Jenkins Remote Access API; and
- proving build, health-check, rollback, cleanup, and remote-configuration outcomes.

The skill treats CI/CD as a production change. It gathers evidence before it changes anything, separates administrator and trigger identities, and refuses common shortcuts such as deploying an uncommitted worktree, rebuilding an unspecified revision, disabling SSH host verification, or treating a successful process exit as a healthy release.

The operational entry point is [SKILL.md](SKILL.md). Codex discovers the skill through [agents/openai.yaml](agents/openai.yaml); the repository's scripts, templates, and references implement and explain the contract described there.

## Scope and non-goals

### Supported scope

The current implementation supports these paths:

- A new Docker-based Jenkins controller on macOS/Linux where Docker is already available, or on a POSIX Linux host reachable through SSH.
- A connection to an existing Jenkins controller, beginning with a read-only audit and security-baseline check.
- A controller with no executors and a separate SSH-based managed agent for builds.
- A guarded, parameterized Job configuration with bounded configuration writes.
- An immutable-artifact delivery boundary when a project and target already support it.
- A reusable **server-pull** delivery boundary when Jenkins executes on the application server and the server must fetch a verified remote commit before building.
- Explicit AI-assisted delivery: a person pushes a commit, then explicitly requests test or production deployment.

### Non-goals

This repository deliberately does not:

- enable a webhook, SCM polling, schedule, or push-triggered deployment by default;
- use the Jenkins CLI `build` command to deploy;
- install Jenkins with arbitrary native packages, Kubernetes, remote Windows setup, or an unreviewed topology;
- mount the host Docker socket by default, silently install Docker Desktop, or grant broad `sudo` to a deployment account;
- accept private keys, API tokens, passwords, or repository credentials in source-controlled configuration;
- turn a controller's built-in node into an ordinary build or deployment worker; or
- replace project-specific operational knowledge. Build commands, activation commands, deployment roots, proxy behavior, migrations, and health endpoints must come from verified project and runtime evidence.

## Safety model

Every workflow is built around the following invariants. A command is useful only when these constraints remain true.

| Invariant | How the skill enforces it |
| --- | --- |
| Inspect before mutation | Read repository instructions, manifests, lockfiles, Docker/Compose/service/proxy files, existing Jenkins assets, branch rules, and live Jenkins state before proposing writes. |
| A deployment has an intentional source | A job uses one approved boundary: immutable artifact handoff, or server-pull of a named remote branch proven equal to `EXPECTED_COMMIT`. |
| A push is not a deployment | Jobs have no automatic trigger by default. A user pushes first and explicitly requests `test` or `production`. |
| A release identifies one exact commit | The project trigger checks a clean worktree, its mapped branch, and equality between local `HEAD` and `origin/<branch>`. Jenkins and the deployment program independently validate the exact commit. |
| Credentials have narrow purpose | A protected administrator profile configures Jenkins; a separate least-privilege trigger profile can only read and build the selected Job. Values stay out of repositories, job XML, URLs, process arguments, and rendered bundles. |
| SSH endpoints are authentic | Remote deployment requires a credential ID or configured private key path plus verified `known_hosts`. Host-key checks are never weakened. |
| A candidate must prove healthy | Releases are versioned, activated only through a reviewed command, and health-checked with bounded retries. Failure rolls back to the prior healthy release. |
| Cleanup cannot hide a failure | Retention runs only after the new release is active and healthy. Current and previous releases are always protected; retention is never below two. |
| Jenkins writes remain bounded | The matched CLI allows inspected configuration operations only. Plans bind writes to controller, job, plugins, and file hashes; arbitrary Groovy, delete, and build operations are excluded. |

Before a remote write, show the controller, Job/environment, intended effect, credential type without its value, success condition, and rollback or recovery path. Inspection permission is not approval to configure, trigger, deploy, restart, switch traffic, or roll back.

## Architecture and delivery models

### Control-plane and delivery flow

```text
operator / Codex
  │  inspect, render, apply configuration, explicitly request deployment
  ▼
project Git repository ── pushed branch + exact commit ──► project-owned trigger
  │                                                           │
  │                                                           │ Remote Access API
  │                                                           ▼
  │                                                    Jenkins controller
  │                                                    - configuration only
  │                                                    - zero executors
  │                                                           │
  │                                                    approved SSH agent/node
  │                                                           │
  └── immutable artifact mode: build once, checksum, transfer │
      server-pull mode: fetch branch, verify EXPECTED_COMMIT ──┘
                                                              ▼
                                                    deployment host
                                                    releases/<release-id>
                                                              │
                                      health succeeds ────────┼─────── health fails
                                                              ▼              │
                                                     current symlink          │
                                                              │              ▼
                                                    post-success cleanup   restore previous
```

The Jenkins controller holds configuration authority, not general build authority. Build and deployment run on an approved execution node with a restricted operating-system account. In server-pull mode that node may be the application host, but it remains an execution node rather than a separate project or repository.

### Choose one source boundary per Job

| Delivery model | Source movement | Build location | Choose it when |
| --- | --- | --- | --- |
| Immutable artifact | Jenkins checks out the exact commit, runs checks, produces a checksummed archive or immutable image, and transfers that output to the destination. | Controlled Jenkins agent. | Compilation and deployment authority should be separated, or the same built artifact must be promoted across environments. |
| Server pull | A generated server deployment script fetches one named remote branch and rejects it unless it resolves to `EXPECTED_COMMIT`. | Application server through an approved Jenkins execution node. | Jenkins and the application share a server, and the project is designed to build there under a restricted account. |

Do not combine the models inside one Job. Immutable-artifact delivery does not silently clone source on the destination. Server-pull delivery does not accept a mutable branch tip without proving the requested full commit SHA.

### Controller and agent topology

New-controller provisioning uses:

- `jenkins/jenkins:2.568.1-jdk21` as the version-pinned controller image;
- `jenkins/ssh-agent:8.6.0-jdk21` as the managed agent image;
- persistent `/var/jenkins_home` storage;
- JCasC and version-locked [assets/plugins.lock.txt](assets/plugins.lock.txt) declarations;
- file-backed bootstrap secrets and a persisted agent SSH host key under a private installation directory;
- a controller configured with zero executors; and
- plain HTTP bound to loopback only. Use an HTTPS reverse proxy or a loopback SSH tunnel for remote credential-bearing access.

Never expose public HTTP for credential-bearing access. Never mount `/var/run/docker.sock` by default. If a project must build containers, design a dedicated least-privilege agent or explicitly approved TLS Docker-in-Docker path instead of widening the standard controller/agent permissions.

## Prerequisites and minimum inputs

### Operator prerequisites

The scripts expect a POSIX-compatible operating environment with the tools required by the selected path. The complete requirements vary by script, but common requirements include:

- Bash, Python 3, Git, curl, Java, Perl, and a SHA-256 utility;
- Docker already installed for a new local Docker-controller installation;
- network reachability to the selected Jenkins controller, Git remote, and deployment host;
- a controller administrator profile for configuration and a separate trigger profile for deployment requests;
- a verified SSH host-key entry for every remote host involved; and
- a repository that can build, test, and expose a meaningful health check through commands derived from its own manifests and operational files.

The skill never requires a secret value in Git. A credential ID, private-file path, or profile path may be provided during approved application, but those values must not be copied into rendered project assets or documentation.

### Minimum evidence before planning

| Input | Why it is required |
| --- | --- |
| Project path or repository | Lets discovery locate build, test, deployment, branch, and instruction evidence. |
| Jenkins target and URL | Distinguishes a new controller from an existing one and binds every configuration operation to the intended controller. |
| Test and production destination | Determines deployment account, source/deployment roots, activation method, and service/proxy impact. |
| Health endpoints and success criteria | Makes readiness verifiable rather than assuming a started process is healthy. |
| Credential IDs or private key/profile paths | Allows the plan to reference secure material without exposing values. |
| Verified `known_hosts` | Prevents deploying to an impersonated remote endpoint. |
| Branch/environment rules | Sets `test` and `production` mappings; `dev -> test` and `main -> production` are defaults, not a replacement for repository evidence. |
| Rollback and cleanup behavior | Identifies the last known good release and proves that cleanup cannot remove it. |

Mark a public repository explicitly. Do not infer that uncommitted local changes are deployable. If repository policy, live configuration, and observed runtime disagree, record the disagreement and its blocking effect rather than silently picking one source of truth.

## Quick decision guide

Use this guide before selecting a workflow.

1. **No Jenkins controller exists yet?** Use Workflow A after confirming Docker availability or a supported POSIX Linux SSH target.
2. **A controller already exists?** Use Workflow B. Begin with a read-only audit; resolve supported-version and security-warning issues before attempting plugin or Job writes.
3. **Does the application server need to fetch and build the named remote commit itself?** Use Workflow C, the server-pull templates.
4. **Can a build agent create one immutable artifact and transfer it to the destination?** Keep that immutable-artifact boundary instead of moving builds to the deployment host.
5. **Has code merely been pushed?** Do nothing. Wait for an explicit test or production deployment request.
6. **Does a production request name the environment clearly?** It is the required approval for that environment. Ask once only when the intended environment is ambiguous.

## Workflow A: provision a new controller

Read [references/provisioning-and-cli.md](references/provisioning-and-cli.md) before installation. The following is the minimum sequence; replace uppercase values with evidence-backed values and keep private paths outside the repository.

```bash
SKILL_DIR=/absolute/path/to/implementing-jenkins-cicd
PROJECT=/absolute/path/to/application-repository

"$SKILL_DIR/scripts/inspect-project.py" --project "$PROJECT" --output discovery.json

"$SKILL_DIR/scripts/plan-jenkins.py" create --discovery discovery.json --target local --jenkins-url http://localhost:8086 --port 8086 --install-dir /absolute/private/jenkins --repo-url REPOSITORY_URL --scm-key-file /private/path/scm_ed25519 --test-deploy-host DEPLOY_USER@TEST_HOST --production-deploy-host DEPLOY_USER@PRODUCTION_HOST --deployment-known-hosts /private/path/known_hosts --deployment-key-file /private/path/deployment_ed25519 --test-deploy-root /absolute/test/root --production-deploy-root /absolute/production/root --test-health-url TEST_HEALTH_URL --production-health-url PRODUCTION_HEALTH_URL --activation-confirmed --output plan.json

PLAN_ID="$(python3 -c 'import json; print(json.load(open("plan.json"))["plan_id"])')"

"$SKILL_DIR/scripts/render-jenkins-assets.py" --plan plan.json --output bundle
"$SKILL_DIR/scripts/render-jenkins-assets.py" --plan plan.json --output apply-evidence --apply-project "$PROJECT" --approve "$PLAN_ID"
"$SKILL_DIR/scripts/orchestrate-jenkins-delivery.sh" --plan plan.json --bundle bundle --approve "$PLAN_ID" --project "$PROJECT" --evidence evidence
```

### What each stage proves

1. `inspect-project.py` discovers project manifests, lockfiles, instructions, containers, service/proxy definitions, branch rules, existing delivery code, and other evidence needed to avoid guessing build and deployment behavior.
2. `plan-jenkins.py create` produces a deterministic plan tied to explicit controller, repository, agent, target, health, credential-source, and activation decisions. Review this plan before approving it.
3. `render-jenkins-assets.py` creates controller and project assets from the plan. Rendering to `apply-evidence` with `--apply-project` applies reviewed project-owned files only when the exact `PLAN_ID` is supplied.
4. `orchestrate-jenkins-delivery.sh` applies the approved bundle, installs a planned controller when appropriate, creates distinct profiles, applies the Job, and verifies the managed agent.

The installer generates random administrator and trigger passwords in private files, creates API tokens through authenticated Jenkins endpoints, writes `0600` profiles, and never prints tokens. Source the administrator profile only for controller configuration. The trigger profile has only `Overall/Read`, `Job/Read`, and `Job/Build` for the target job; it is the only profile that should make a deployment request.

### Required review before application

Before applying the plan, confirm all of the following:

- the controller URL is correct and credential-bearing access is HTTPS or loopback-only HTTP;
- the plan uses pinned image and plugin versions rather than floating tags;
- test and production destination roots are absolute, distinct, non-nested, and owned by the intended restricted account;
- SSH key paths and `known_hosts` paths are private and point to the expected hosts;
- install, lint, test, build, artifact, activation, and health behavior came from project evidence;
- the activation command is reviewed for each environment; and
- the expected rollback and retention result is operationally acceptable.

Preview generated files before applying them. Commit and push generated project assets before the first deployment; the generated trigger intentionally rejects an uncommitted project configuration.

## Workflow B: connect an existing controller

An existing controller is never treated as safe merely because it answers HTTP requests. Start read-only and reconcile three states: observed live controller/runtime state, source-controlled expectations, and the proposed target state. [references/audit-and-design.md](references/audit-and-design.md) describes the evidence method.

### 1. Gather read-only evidence

Source a private administrator profile and run the read-only audit against a private output directory:

```bash
SKILL_DIR=/absolute/path/to/implementing-jenkins-cicd
source /private/path/.jenkins-cli.env
"$SKILL_DIR/scripts/jenkins-readonly-audit.sh" evidence/audit
```

The audit uses a controller-matched CLI JAR from `JENKINS_URL/jnlpJars/jenkins-cli.jar`, protects raw material in a temporary private directory, and allowlists only `who-am-i`, `version`, `list-jobs`, `list-plugins`, `get-job`, and `console`. It cannot create, update, delete, restart, install, or trigger anything. Treat even redacted audit evidence as sensitive and remove it when no longer required.

The audit records identity, Jenkins core and plugin versions, jobs, and `security-baseline.json`. A match between installed versions and the fresh official update-center security-warning feed is a blocking failure. Upgrade and validate recovery before making a configuration change on a known-vulnerable or obsolete controller.

### 2. Reconcile and plan changes

For every delivery path, record trigger, source, CI steps, artifact, deploy target, health criteria, and rollback. Trace `set -e`, `|| true`, skipped tests, mutable tags, stale worktrees, destructive replacement, and masked nonzero results through every invoked script. A matching filename does not prove two deployment scripts are equivalent; hash duplicates when comparing them.

Keep these three categories separate in the review:

1. **Observed current state**: live evidence only.
2. **Source and policy expectation**: version-controlled project files and instructions.
3. **Proposed target state**: reviewed recommendation, with owner and evidence needed for any disagreement.

### 3. Apply only bounded, approved configuration

Use [scripts/configure-jenkins-plugins.sh](scripts/configure-jenkins-plugins.sh) only after an exact pinned-plugin comparison and structured backup evidence. Required backup evidence includes an absolute backup path, matching SHA-256, a timezone-qualified timestamp, and `restore_tested: true`; a plain assertion that a backup exists is insufficient.

Use [scripts/apply-jenkins-job.sh](scripts/apply-jenkins-job.sh) after the read-only audit and plan approval. The safe CLI wrapper binds a write to the planned controller, job, plugin set, and exact plan hash. Job XML is deterministically rendered instead of accepted from arbitrary standard input, and an update saves prior private XML. The temporary matched CLI JAR is deleted after success, failure, or interruption.

The Jenkins CLI remains configuration-only. Do not add `build`, `delete-job`, arbitrary Groovy, or broad administrative commands to its allowlist. Use the project-owned trigger script for an explicit deployment request.

## Workflow C: render and operate server-pull delivery

Use server-pull when Jenkins executes on the application server and the required source boundary is: **fetch one named remote branch, prove it resolves to the exact requested commit, then build and release**. Read [references/server-pull-templates.md](references/server-pull-templates.md) in full before adapting a project.

### Server-pull contract

1. A person pushes `dev` or `main`; that push alone does not deploy.
2. A person explicitly asks for test or production deployment.
3. `ops/jenkins/trigger-deploy.sh` proves its worktree is clean and its local commit is already the mapped remote branch tip.
4. The trigger calls Jenkins `buildWithParameters` with `DEPLOY_ENV`, `GIT_REF`, and full `EXPECTED_COMMIT`.
5. Jenkins invokes the installed `deploy-from-git.sh` on the approved node.
6. The server fetches the mapped branch and refuses to build unless the fetched commit equals `EXPECTED_COMMIT`.
7. The server builds a versioned candidate, activates it, health-checks it, rolls back on failure, then prunes old successful releases only after success.

The renderer produces a new private output directory containing:

| Generated file | Destination and role |
| --- | --- |
| `trigger-deploy.sh` | Commit it to the application repository as `ops/jenkins/trigger-deploy.sh`; it validates local Git state and submits an explicit Jenkins build request. |
| `deploy-from-git.sh` | Install it outside the application repository in a Jenkins-readable/executable, restricted path on the deployment host. |
| `job.xml` | Deterministic parameterized Freestyle Job bound to the approved node, with no automatic trigger and no concurrent builds. |
| `manifest.json` | Private hash manifest and approval identifier for the rendered files and bounded control-plane scripts. Editing the bundle requires re-rendering and new approval. |

Rendered scripts are mode `0700`; the manifest is mode `0600`. The renderer rejects existing output paths, unknown configuration fields, nested or unsafe roots, embedded repository credentials, invalid branch mapping, and retention below two.

### Secret-free JSON configuration

Create a configuration file outside any path that would contain private values. The following complete example is illustrative: it contains no credential, key, password, or token. The schema authority is [references/server-pull-templates.md](references/server-pull-templates.md).

```json
{
  "schema_version": 2,
  "project_name": "example-app",
  "repository_url": "git@github.com:example/example-app.git",
  "jenkins_url": "https://jenkins.example.com",
  "jenkins_job": "example-app-deploy",
  "branches": {
    "test": "dev",
    "production": "main"
  },
  "source_roots": {
    "test": "/srv/example-app/source-test",
    "production": "/srv/example-app/source-production"
  },
  "deploy_roots": {
    "test": "/srv/example-app/test",
    "production": "/srv/example-app/production"
  },
  "commands": {
    "install": "npm ci --prefer-offline",
    "lint": "npm run lint",
    "test": "npm test -- --runInBand",
    "build": "npm run build",
    "activate_test": "systemctl --user restart example-app-test.service",
    "activate_production": "systemctl --user restart example-app.service"
  },
  "artifact_paths": ["dist"],
  "health_urls": {
    "test": "http://127.0.0.1:18081/health",
    "production": "http://127.0.0.1:18080/health"
  },
  "execution": {
    "node_label": "jenkins-deploy-host",
    "deploy_script_path": "/opt/jenkins-deploy/example-app/deploy-from-git.sh",
    "lock_file": "/srv/example-app/.deploy.lock"
  },
  "release_retention": 5,
  "clean_excludes": []
}
```

| Field group | Meaning and constraints |
| --- | --- |
| `schema_version`, `project_name`, `repository_url`, `jenkins_url`, `jenkins_job` | Select the supported schema and identify a single project, Git remote, controller, and Job. Repository URLs must not embed credentials. |
| `branches` | Maps `test` and `production` to their allowed branches. The usual mapping is `dev` and `main`; project evidence may override it. |
| `source_roots` and `deploy_roots` | Separate absolute roots for each environment. Source and deployment roots must be distinct and non-nested. |
| `commands` | Evidence-backed install, lint, test, build, and activation shell fragments. Activation must use the prepared current release, not a temporary staging directory. |
| `artifact_paths` | Build outputs copied into the candidate release. Symbolic-link escapes are rejected. |
| `health_urls` | Bounded readiness endpoints for each environment. A protected endpoint is not automatically a valid health signal. |
| `execution` | An online, approved `node_label`, absolute installed script path, and absolute deployment lock path. The restricted OS account must be able to run exactly this operation. |
| `release_retention` | Number of successful releases to retain. The minimum is two; the default is five. |
| `clean_excludes` | Explicit Git-clean exclusions only when project evidence requires them. |

During build and activation, the deployment script exports `DEPLOY_ENV`, `GIT_REF`, `EXPECTED_COMMIT`, `SOURCE_ROOT`, `DEPLOY_ROOT`, and `HEALTH_URL`. Activation also receives `CURRENT_RELEASE`, `CURRENT_LINK`, and `PREVIOUS_RELEASE`. Database migration policy is separate: backward-compatible migrations may be planned before activation; destructive migrations require a separately approved rollout and recovery design.

### Render, review, and verify the bundle

```bash
SKILL_DIR=/absolute/path/to/implementing-jenkins-cicd

python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --output rendered-server-pull
bash -n rendered-server-pull/trigger-deploy.sh
bash -n rendered-server-pull/deploy-from-git.sh
python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --verify-output rendered-server-pull
PLAN_ID="$(python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --print-plan-id)"
```

Review `rendered-server-pull/manifest.json` and every rendered file. Copy the trigger into the application project, review it, commit it, and push it before the first deployment:

```bash
mkdir -p PROJECT/ops/jenkins
install -m 0700 rendered-server-pull/trigger-deploy.sh PROJECT/ops/jenkins/trigger-deploy.sh
git -C PROJECT add ops/jenkins/trigger-deploy.sh
git -C PROJECT commit -m "ops: add Jenkins deployment trigger"
git -C PROJECT push
```

The install command above intentionally contains only a generated trigger and no profile or token. Do not add `.jenkins-cli.env`, `.jenkins-trigger.env`, private keys, or private output bundles to the project repository.

### Configure Jenkins and install the server program

Use the administrator profile for these configuration operations. They do not trigger a deployment.

```bash
SKILL_DIR=/absolute/path/to/implementing-jenkins-cicd
PLAN_ID="$(python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --print-plan-id)"
source /private/path/.jenkins-cli.env
"$SKILL_DIR/scripts/apply-server-pull-job.sh" --config server-pull.json --bundle rendered-server-pull --approve "$PLAN_ID" --evidence evidence/job-apply
"$SKILL_DIR/scripts/install-server-pull-script.sh" --config server-pull.json --bundle rendered-server-pull --approve "$PLAN_ID" --evidence evidence/script-install
"$SKILL_DIR/scripts/verify-server-pull-delivery.sh" --config server-pull.json --bundle rendered-server-pull --approve "$PLAN_ID" --output evidence/config-verification
```

For a remote deployment host, use the same reviewed `--ssh-target restricted-user@host` parameter where supported and configure strict host-key verification in the operator's SSH configuration. `apply-server-pull-job.sh` saves prior XML on update. The temporary CLI JAR is private and deleted by the safe wrapper.

The generated Job has only `DEPLOY_ENV`, `GIT_REF`, and `EXPECTED_COMMIT` parameters, an empty triggers block, and disabled concurrent builds. Its build step calls the approved absolute server script. The selected `node_label` must be online and run under a restricted account with only the selected roots, lock file, repository access, and narrowly scoped activation privilege. It must not receive Jenkins administration, unrestricted `sudo`, or the Docker socket.

## Explicit test and production deployment

Deployment is an explicit user-request action. A code push is a prerequisite, not an authorization. The generic default is `dev -> test` and `main -> production`; read the repository instructions and live Job before relying on it.

### Test deployment

```bash
git switch dev
git status --short
git push origin dev
source /private/path/.jenkins-trigger.env
./ops/jenkins/trigger-deploy.sh --environment test
```

### Production deployment

Promote and validate the reviewed test commit according to the repository's policy. Only after the intended commit is on the production branch and the user explicitly requests production:

```bash
git switch main
git status --short
git push origin main
source /private/path/.jenkins-trigger.env
./ops/jenkins/trigger-deploy.sh --environment production
```

The generated trigger accepts `--environment test|production` and optional `--commit FULL_SHA`. Before it posts to Jenkins, it verifies:

1. required `JENKINS_USER_ID` and `JENKINS_API_TOKEN` variables exist in the private profile;
2. the controller URL is HTTPS, or loopback HTTP through a local tunnel;
3. the project directory is a Git worktree with no tracked or untracked changes;
4. the current local branch is the branch mapped to the requested environment;
5. local `HEAD` is a full 40-character SHA and equals the corresponding `origin/<branch>` SHA; and
6. an optional requested commit is the same full local `HEAD` SHA.

It sends a POST to Jenkins `buildWithParameters` with `DEPLOY_ENV`, `GIT_REF`, and `EXPECTED_COMMIT`, validates returned queue and build URLs before reusing credentials, follows the queue to a concrete build, prints the console text, and exits successfully only when the final Jenkins result is `SUCCESS`. The token is held in a private curl configuration file, never in a query string or command argument.

## Release lifecycle, health checks, rollback, and cleanup

The server-pull release sequence makes release state explicit:

1. Take a bounded deployment lock so two deployments cannot mutate the same target concurrently.
2. Validate existing `current` state and reject unsafe symlinks or release roots.
3. Fetch the selected remote branch with retry, prove it equals full `EXPECTED_COMMIT`, reset to that commit, and clean only within the verified source root.
4. Run evidence-backed install, lint, test, and build phases. An optional phase is visibly skipped only when its command is intentionally empty.
5. Create a unique staged candidate under `DEPLOY_ROOT/releases`, copy only approved non-symlink artifacts, and write release metadata.
6. Run the reviewed environment activation command against `CURRENT_RELEASE` or `CURRENT_LINK`.
7. Poll the health endpoint using bounded attempt and interval settings. A health error is a deployment failure, not a warning.
8. On success, atomically point `DEPLOY_ROOT/current` to the candidate, mark it successful, and retain evidence.
9. On failure, restore the previous known-good release, health-check the restored state, leave the failed candidate available for diagnosis, and skip cleanup.
10. Only after success, prune old successful releases. Default retention is five; current and previous releases remain protected, and unsafe cleanup paths are rejected.

The release directory is not a generic scratch directory. `DEPLOY_ROOT/current` must resolve only to a regular successful directory beneath `DEPLOY_ROOT/releases`. Cleanup is a post-success maintenance operation; its failure must be visible and must not falsely report that the deployment itself was reverted.

## Script and reference catalogue

### Operational scripts

| Path | Responsibility | Key safety boundary |
| --- | --- | --- |
| [scripts/inspect-project.py](scripts/inspect-project.py) | Discovers repository evidence needed for a delivery plan. | Does not infer project behavior from filenames alone. |
| [scripts/plan-jenkins.py](scripts/plan-jenkins.py) | Creates and verifies deterministic, approval-bound Jenkins plans. | Plans bind sensitive configuration decisions and exact approval identifiers. |
| [scripts/render-jenkins-assets.py](scripts/render-jenkins-assets.py) | Renders controller and project assets from a plan. | Approved project application is tied to the exact plan ID. |
| [scripts/orchestrate-jenkins-delivery.sh](scripts/orchestrate-jenkins-delivery.sh) | Applies an approved new-controller delivery bundle. | Coordinates reviewed files, separate profiles, Job application, and agent verification. |
| [scripts/install-jenkins-docker.sh](scripts/install-jenkins-docker.sh) | Installs the planned pinned Docker controller topology. | Uses persistent storage, private bootstrap material, loopback HTTP, and no default Docker socket. |
| [scripts/bootstrap-jenkins-cli-profile.sh](scripts/bootstrap-jenkins-cli-profile.sh) | Creates private administrator and trigger API-token profiles. | Profiles are mode `0600`; token values are never printed. |
| [scripts/jenkins-cli-safe.sh](scripts/jenkins-cli-safe.sh) | Runs a controller-matched Jenkins CLI command. | Uses a private temporary JAR, WebSocket transport, a narrow allowlist, and cleanup on all exits. |
| [scripts/jenkins-readonly-audit.sh](scripts/jenkins-readonly-audit.sh) | Collects redacted, read-only controller evidence. | Cannot mutate Jobs, plugins, credentials, or builds. |
| [scripts/check-jenkins-security-baseline.py](scripts/check-jenkins-security-baseline.py) | Compares installed core/plugins to the official warning feed. | Security-warning matches block later mutation. |
| [scripts/configure-jenkins-plugins.sh](scripts/configure-jenkins-plugins.sh) | Reconciles exact pinned plugin inventory. | Requires restore-tested backup evidence before missing-plugin writes. |
| [scripts/apply-jenkins-job.sh](scripts/apply-jenkins-job.sh) | Creates or updates a planned Jenkins Job. | Deterministic XML, plan/hash binding, and prior XML backup on update. |
| [scripts/render-server-pull-templates.py](scripts/render-server-pull-templates.py) | Validates JSON and renders reusable server-pull assets. | Rejects unsafe roots, unknown fields, embedded credentials, invalid mapping, and weak retention. |
| [scripts/apply-server-pull-job.sh](scripts/apply-server-pull-job.sh) | Applies the deterministic server-pull Job. | Requires approved bundle and administrator configuration profile. |
| [scripts/install-server-pull-script.sh](scripts/install-server-pull-script.sh) | Installs the approved server deployment program. | Installs the manifest-bound absolute script path under restricted permissions. |
| [scripts/verify-server-pull-delivery.sh](scripts/verify-server-pull-delivery.sh) | Verifies installed script and live Job against the approved bundle. | Confirms hashes and configuration without triggering deployment. |
| [scripts/verify-jenkins-delivery.sh](scripts/verify-jenkins-delivery.sh) | Verifies general Jenkins delivery configuration and evidence. | Detects incomplete configuration before a deployment request. |
| [scripts/redact-jenkins-evidence.pl](scripts/redact-jenkins-evidence.pl) | Redacts sensitive material in generated evidence. | Redaction is best effort; output remains access-restricted and reviewable. |

### Verification and test scripts

| Path | What it exercises |
| --- | --- |
| [scripts/test-end-to-end-skill.sh](scripts/test-end-to-end-skill.sh) | End-to-end discovery, planning, rendering, release activation/rollback/cleanup, guarded Job application, trigger behavior, plugin/configuration verification, and server-pull flow. |
| [scripts/test-jenkins-readonly-audit.sh](scripts/test-jenkins-readonly-audit.sh) | Read-only audit restrictions and generated evidence behavior. |
| [scripts/test-server-pull-control-plane.sh](scripts/test-server-pull-control-plane.sh) | Approved server-pull Job/script application and verification controls. |
| [scripts/test-server-pull-templates.sh](scripts/test-server-pull-templates.sh) | JSON validation, rendering, manifest, and generated trigger/deployment-script behavior. |

### Reference documents

| Document | Use it when |
| --- | --- |
| [references/provisioning-and-cli.md](references/provisioning-and-cli.md) | Installing a supported controller, using the safe matched CLI, or connecting an existing controller. |
| [references/audit-and-design.md](references/audit-and-design.md) | Auditing a repository/controller/runtime and reconciling observed, expected, and proposed states. |
| [references/ai-triggered-delivery.md](references/ai-triggered-delivery.md) | Defining explicit AI-triggered test/production delivery and selecting exactly one source boundary. |
| [references/server-pull-templates.md](references/server-pull-templates.md) | Creating the server-pull JSON mapping, rendering scripts, configuring its Job, and operating the flow. |
| [references/security-and-operations.md](references/security-and-operations.md) | Reviewing credentials, controller/agent isolation, remote-mutation approval, and operating controls. |
| [references/deployment-patterns.md](references/deployment-patterns.md) | Choosing artifact/service release patterns, health semantics, rollback, and cleanup. |

## Configuration and credential boundaries

### Where information belongs

| Information | Approved location | Never place it in |
| --- | --- | --- |
| Jenkins API token | Private administrator or trigger profile; Jenkins credential store where applicable. | Git, README examples with values, Job XML, URL query strings, process arguments, or rendered project assets. |
| SSH private key | Private file referenced only at approved apply time, or Jenkins Credentials. | `server-pull.json`, repository source, evidence bundle, or shell history. |
| SSH server identity | Verified `known_hosts` and reviewed SSH configuration. | A disabled host-key check or an unverified first-use acceptance path. |
| Repository access credential | Jenkins Credentials, restricted deployment account, or private SSH configuration. | Repository URL user-info, JSON configuration, or a copied release artifact. |
| Environment configuration | Approved secret store or deployment-host private configuration. | Git-tracked deployment scripts unless the value is deliberately non-secret. |
| Credential ID | Plan/job/configuration reference when necessary. | A substitute for the credential value; IDs do not make it safe to print the underlying secret. |

Masking is not a security boundary. Disable shell tracing around secrets, bind secrets only to the shortest required stage, do not execute untrusted code in a secret-bearing stage, and rotate any credential found in source, XML, logs, or artifacts. Deleting an exposed line alone is not sufficient remediation.

## Verification and test suite

Run the repository suite from this repository root before publishing or modifying the skill:

```bash
bash scripts/test-end-to-end-skill.sh
```

The end-to-end test reports `PASS: end-to-end Jenkins skill` when all mocked control-plane and delivery scenarios succeed. Focused tests are also available:

```bash
bash scripts/test-jenkins-readonly-audit.sh
bash scripts/test-server-pull-templates.sh
bash scripts/test-server-pull-control-plane.sh
```

For a real project delivery, verification is broader than a Jenkins build result. Preserve evidence that the repository commit was pushed, plan/bundle approval matched, controller and agent configuration matched, tests ran, the candidate health check passed, rollback behavior was exercised, and temporary sensitive material was removed. Finish an approved workflow with [scripts/verify-jenkins-delivery.sh](scripts/verify-jenkins-delivery.sh) or [scripts/verify-server-pull-delivery.sh](scripts/verify-server-pull-delivery.sh), plus the project's own tests and health/rollback evidence.

## Troubleshooting

| Symptom | Meaning | Safe next action |
| --- | --- | --- |
| `missing required environment variable: JENKINS_USER_ID` or `JENKINS_API_TOKEN` | The private profile was not sourced, is incomplete, or has inappropriate permissions. | Source the correct private profile in the current shell, verify its ownership/mode without printing values, and use the administrator versus trigger profile for the correct operation. |
| Trigger says the worktree must be clean | Local files differ from the commit that would be deployed. | Commit, stash, or intentionally discard only the identified local work after review; then retry from a clean worktree. Never deploy the uncommitted state. |
| Trigger says local `HEAD` was not pushed | Jenkins could not be tied to a remote immutable commit. | Push the mapped branch and confirm `origin/<branch>` equals local full SHA. Do not force the trigger to use a different ref. |
| Security baseline fails | Installed Jenkins core or plugin version matches an official warning. | Stop configuration writes; prepare a supported upgrade, backup, restore test, and recovery plan, then repeat the audit. |
| Approved `node_label` is unavailable | Jenkins cannot run the Job on the reviewed restricted execution node. | Bring the intended node online, verify its label and restricted account access, then rerun configuration verification. Do not fall back to the controller built-in node. |
| SSH host-key verification fails | The target identity is absent or differs from the expected host key. | Investigate the host identity and update `known_hosts` only after an out-of-band verified rotation. Do not disable strict checking. |
| Candidate health check fails | The release did not meet its defined readiness condition. | Read preserved evidence, confirm rollback health, diagnose the candidate, and redeploy only a reviewed corrected commit. Cleanup must remain skipped. |
| Server-pull bundle or hash verification fails | Rendered files, config, control-plane scripts, or approval identifier no longer match. | Re-render from the reviewed secret-free JSON, review the new manifest, obtain a new approval, and reapply. Do not edit rendered files in place. |
| Jenkins build ends other than `SUCCESS` | Queue, build, CI, deployment, health, or rollback stage failed. | Read the concrete build console and generated evidence, identify the failing gate, correct the underlying cause, then make a new explicit request. Do not treat `UNSTABLE`, `ABORTED`, or `FAILURE` as deployment success. |
| Plugin dynamic loading fails | A missing pinned plugin needs restart-safe handling. | Keep recovery evidence, plan a backed-up controlled restart, and verify the post-restart inventory. Do not conceal the failure. |

## Repository layout

```text
.
├── SKILL.md                         # Operational contract and Codex workflow
├── agents/openai.yaml               # Codex display metadata and default prompt
├── assets/
│   ├── compose.yaml.tmpl             # Pinned controller/agent topology
│   ├── jenkins.yaml.tmpl             # JCasC template
│   ├── plugins.lock.txt              # Pinned Jenkins plugin inventory
│   └── templates/                    # Server-pull trigger, deploy script, and Job XML templates
├── references/                       # Detailed provisioning, audit, security, and deployment guidance
├── scripts/                          # Discovery, planning, rendering, configuration, verification, and test programs
└── docs/                             # Design records and implementation plans
```

Start with `SKILL.md` when invoking the skill in Codex. Start with the relevant reference document when adapting a real project. Treat assets as renderer inputs rather than hand-edited production files unless a reviewed implementation change explicitly updates them.

## Contributing

Contributions should preserve the safety model rather than merely adding a happy-path command. Before opening a change:

1. Read `SKILL.md` and the reference document closest to the affected workflow.
2. Add or update the smallest relevant test first when changing script behavior, then run the focused test and the full end-to-end suite.
3. Keep plan approval, source provenance, credential separation, host-key verification, health, rollback, and cleanup invariants intact.
4. Avoid committing private controller evidence, profiles, keys, bundles, hosts, or tokens.
5. Update this README's English and Chinese sections together when changing publicly documented behavior.

Small, evidence-backed changes are easier to review. Do not broaden the CLI allowlist or deployment authority for convenience.

## Licence status

This repository currently has no `LICENSE` file. No licence grant is represented by this README; add and review an explicit licence before relying on third-party reuse rights.
