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

The reusable source templates are [assets/templates/trigger-deploy.sh.tmpl](assets/templates/trigger-deploy.sh.tmpl) and [assets/templates/deploy-from-git.sh.tmpl](assets/templates/deploy-from-git.sh.tmpl). Treat rendered output as approval-bound generated material; update the templates only through a reviewed skill change and rerender every affected bundle.

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

---

<a id="中文"></a>

# 中文

## 本仓库提供的能力

本仓库是一个 Codex skill，用于将 Jenkins 交付路径从证据收集推进至经过验证的交付结果。它不是一组通用 Jenkins 片段；其中的脚本和模板定义了受控工作流，可用于：

- 在提出 CI/CD 变更之前检查应用仓库；
- 为新 Jenkins Controller 创建确定性、受审批约束的计划；
- 安装固定版本的 Jenkins LTS Controller 与独立 SSH 构建 Agent，或安全接入既有 Controller；
- 生成项目自有的 Jenkins 资产和 server-pull 部署程序；
- 通过与 Controller 匹配、仅用于配置的 Jenkins CLI 配置插件和 Job；
- 经由 Jenkins Remote Access API 显式触发测试或生产交付；以及
- 验证构建、健康检查、回滚、清理和远端配置结果。

该 skill 将 CI/CD 视为生产变更。它在改动前收集证据，分离管理员与触发身份，并拒绝常见捷径：部署未提交工作区、重建未指定版本、关闭 SSH 主机验证，或将进程成功退出误判为健康发布。

操作入口是 [SKILL.md](SKILL.md)。Codex 通过 [agents/openai.yaml](agents/openai.yaml) 发现该 skill；仓库中的脚本、模板和参考文档共同实现并解释 `SKILL.md` 中的契约。

## 范围与非目标

### 已支持的范围

当前实现支持以下路径：

- 在 Docker 已可用的 macOS/Linux 上新建 Docker Jenkins Controller，或通过 SSH 连接到 POSIX Linux 主机进行安装。
- 接入既有 Jenkins Controller；流程从只读审计和安全基线检查开始。
- 运行零 executor 的 Controller，并使用独立的 SSH 托管 Agent 执行构建。
- 使用受保护、可参数化的 Job 配置及有界配置写入。
- 当项目和目标环境已有相应能力时，使用不可变构件交付边界。
- 当 Jenkins 在应用服务器上运行且服务器需要在构建前拉取已验证远端 commit 时，使用可复用的 **server-pull** 交付边界。
- 显式的 AI 协助交付：先由用户推送 commit，再由用户明确要求部署到测试或生产环境。

### 非目标

本仓库有意不做以下事情：

- 默认启用 webhook、SCM 轮询、定时任务或推送即部署；
- 使用 Jenkins CLI 的 `build` 命令执行部署；
- 使用任意原生软件包、Kubernetes、远程 Windows 安装或未评审拓扑来安装 Jenkins；
- 默认挂载宿主机 Docker socket、静默安装 Docker Desktop，或向部署账号授予宽泛 `sudo`；
- 在受版本控制的配置中接受私钥、API token、密码或仓库凭据；
- 将 Controller 的 built-in node 作为普通构建或部署节点；
- 替代项目特有的运维知识。构建命令、激活命令、部署根目录、代理行为、数据库迁移和健康端点必须来自经过验证的项目与运行时证据。

## 安全模型

每条工作流均以如下不变量为核心。只有在这些约束仍成立时，命令才有意义。

| 不变量 | skill 的执行方式 |
| --- | --- |
| 先检查，后变更 | 在提出写入前读取项目说明、manifest、lockfile、Docker/Compose/service/proxy 文件、既有 Jenkins 资产、分支规则和实时 Jenkins 状态。 |
| 部署具有明确来源 | 每个 Job 选择一种经批准边界：不可变构件交接，或拉取命名远端分支且证明其等于 `EXPECTED_COMMIT` 的 server-pull。 |
| 推送不等于部署 | Job 默认不含自动触发器。用户先推送，再明确要求 `test` 或 `production`。 |
| 发布对应唯一 commit | 项目触发器检查工作区干净、分支匹配，并验证本地 `HEAD` 等于 `origin/<branch>`。Jenkins 和部署程序会独立验证精确 commit。 |
| 凭据具有最小用途 | 受保护的管理员 profile 只配置 Jenkins；独立的最小权限 trigger profile 只能读取并构建指定 Job。凭据值不进入仓库、Job XML、URL、进程参数或渲染产物。 |
| SSH 终端可信 | 远程部署需要 credential ID 或已配置私钥路径，以及已验证的 `known_hosts`。绝不弱化主机密钥校验。 |
| 候选版本必须证明健康 | 发布以版本目录保存，仅通过评审过的命令激活，并使用有界重试健康检查。失败时回滚至前一个健康版本。 |
| 清理不能掩盖失败 | 仅在新版本已激活且健康时执行保留策略。始终保护 current 和 previous，保留数量不得低于两个。 |
| Jenkins 写入保持有界 | 匹配 CLI 只允许受检查的配置操作。计划将写入绑定至 Controller、Job、插件和文件哈希；不允许任意 Groovy、删除或构建操作。 |

任何远程写入之前，都应展示 Controller、Job/环境、预期影响、凭据类别但不展示值、成功条件以及回滚或恢复路径。检查权限不等于配置、触发、部署、重启、切流或回滚的批准。

## 架构与交付模型

### 控制面与交付流程

```text
operator / Codex
  │  检查、渲染、应用配置，并显式请求部署
  ▼
项目 Git 仓库 ── 已推送分支 + 精确 commit ──► 项目自有触发器
  │                                                   │
  │                                                   │ Remote Access API
  │                                                   ▼
  │                                            Jenkins Controller
  │                                            - 仅配置
  │                                            - 零 executors
  │                                                   │
  │                                            已批准 SSH agent/node
  │                                                   │
  └── 不可变构件模式：构建一次、校验、传输          │
      server-pull 模式：拉取分支、验证 EXPECTED_COMMIT ┘
                                                      ▼
                                            部署主机
                                            releases/<release-id>
                                                      │
                              健康成功 ──────────────┼─────── 健康失败
                                                      ▼              │
                                             current 软链接           │
                                                      │              ▼
                                            成功后清理旧版本      恢复 previous
```

Jenkins Controller 持有配置权限，而不是通用构建权限。构建和部署在已批准的执行节点上进行，节点使用受限操作系统账号。server-pull 模式中，该节点可以就是应用主机，但它仍是执行节点，而不是独立项目或仓库。

### 每个 Job 只选择一种来源边界

| 交付模型 | 来源移动方式 | 构建位置 | 适用场景 |
| --- | --- | --- | --- |
| 不可变构件 | Jenkins checkout 精确 commit，执行检查，产出带校验和的归档或不可变镜像，再传送至目标端。 | 受控 Jenkins Agent。 | 需要分离编译与部署权限，或必须在多个环境中提升同一构件。 |
| Server pull | 生成的服务器部署脚本拉取一个命名远端分支；若其不等于 `EXPECTED_COMMIT` 则拒绝继续。 | 经由已批准 Jenkins 执行节点的应用服务器。 | Jenkins 与应用位于同一服务器，且项目设计为在受限账号下在该服务器上构建。 |

不要在同一 Job 中混合两种模型。不可变构件交付不会在目标主机悄悄 clone 源码；server-pull 交付也不会在未证明完整 commit SHA 的情况下接受可变分支顶端。

### Controller 与 Agent 拓扑

新 Controller 的部署使用：

- 固定版本的 `jenkins/jenkins:2.568.1-jdk21` Controller 镜像；
- 固定版本的 `jenkins/ssh-agent:8.6.0-jdk21` 托管 Agent 镜像；
- 持久化 `/var/jenkins_home` 存储；
- JCasC 与锁定版本的 [assets/plugins.lock.txt](assets/plugins.lock.txt) 声明；
- 位于私有安装目录中的文件型 bootstrap secret 与持久化 Agent SSH host key；
- 配置为零 executor 的 Controller；以及
- 仅绑定 loopback 的明文 HTTP。远程携带凭据的访问应使用 HTTPS 反向代理或 loopback SSH tunnel。

不要公开携带凭据的 HTTP 访问。不要默认挂载 `/var/run/docker.sock`。如项目确实要构建容器，应设计专用最小权限 Agent 或明确批准的 TLS Docker-in-Docker 路径，而不是扩大标准 Controller/Agent 权限。

## 前置条件与最小输入集

### 操作方前置条件

脚本预期在与所选路径匹配的 POSIX 环境中运行。具体依赖取决于脚本，但常见要求包括：

- Bash、Python 3、Git、curl、Java、Perl 和 SHA-256 工具；
- 若安装本地 Docker Controller，Docker 必须已安装；
- 能访问所选 Jenkins Controller、Git 远端和部署主机的网络路径；
- 用于配置的 Controller 管理员 profile 和用于发起部署请求的独立 trigger profile；
- 每台远程主机对应的已验证 SSH host-key 条目；以及
- 一个能根据自身 manifest 与运维文件确定构建、测试并提供有意义健康检查的项目。

该 skill 从不要求把 secret 值放入 Git。经批准的 apply 阶段可以提供 credential ID、私有文件路径或 profile 路径，但这些值不得复制到渲染的项目资产或文档。

### 规划前必须取得的证据

| 输入 | 必要原因 |
| --- | --- |
| 项目路径或仓库 | 让 discovery 定位构建、测试、部署、分支和说明文件的证据。 |
| Jenkins 目标与 URL | 区分新建和既有 Controller，并将配置操作绑定到指定 Controller。 |
| 测试与生产目标端 | 决定部署账号、源码/部署根目录、激活方式和 service/proxy 影响。 |
| 健康端点与成功条件 | 让就绪状态可验证，而不是把进程启动误认为健康。 |
| Credential ID 或私钥/profile 路径 | 让计划引用安全材料而不暴露其值。 |
| 已验证的 `known_hosts` | 避免向被冒充的远程终端部署。 |
| 分支/环境规则 | 设置 `test` 与 `production` 映射；`dev -> test` 和 `main -> production` 只是默认值，不能替代仓库证据。 |
| 回滚与清理行为 | 确认最后一个已知正常版本，并证明清理不能删除它。 |

应显式标注 public repository。不要推断未提交的本地改动可以部署。如果仓库策略、实时配置和观察到的运行时状态互相冲突，应记录冲突及其阻断影响，而不是静默选择其中一个事实来源。

## 快速决策指南

在选择工作流前，请按以下问题判断：

1. **尚不存在 Jenkins Controller？** 在确认 Docker 可用或存在受支持的 POSIX Linux SSH 目标后，使用工作流 A。
2. **已经有 Controller？** 使用工作流 B。从只读审计开始；在尝试插件或 Job 写入前先处理版本支持与安全告警问题。
3. **应用服务器是否必须自行拉取并构建命名远端 commit？** 使用工作流 C，即 server-pull 模板。
4. **构建 Agent 是否能构建一个不可变构件并传输至目标端？** 应保持不可变构件边界，而不是把构建迁到部署主机。
5. **是否只是刚推送代码？** 不执行部署，等待明确的测试或生产部署请求。
6. **生产请求是否明确指明环境？** 这就是该环境所需批准；只有环境含义不明确时才询问一次。

## 工作流 A：部署新的 Jenkins Controller

安装前请阅读 [references/provisioning-and-cli.md](references/provisioning-and-cli.md)。以下是最小序列；将大写值替换为证据支持的值，并将私有路径保留在仓库外。

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

### 各阶段所证明的内容

1. `inspect-project.py` 发现项目 manifest、lockfile、说明、容器文件、service/proxy 定义、分支规则、既有交付代码以及其他避免猜测构建和部署行为所需的证据。
2. `plan-jenkins.py create` 产出确定性计划，绑定明确的 Controller、仓库、Agent、目标端、健康检查、凭据来源和激活决策。批准前必须审阅该计划。
3. `render-jenkins-assets.py` 根据计划生成 Controller 和项目资产。使用 `--apply-project` 向 `apply-evidence` 渲染时，只有提供精确 `PLAN_ID` 才会应用经过审阅的项目自有文件。
4. `orchestrate-jenkins-delivery.sh` 应用已批准 bundle，在需要时安装计划中的 Controller，创建独立 profile，应用 Job，并验证托管 Agent。

安装器会在私有文件中生成随机管理员和 trigger 密码，经已认证 Jenkins endpoint 创建 API token，写出权限为 `0600` 的 profile，且不打印 token。Controller 配置时仅 source 管理员 profile。trigger profile 对目标 Job 只有 `Overall/Read`、`Job/Read` 和 `Job/Build` 权限；它应是唯一发起部署请求的 profile。

### 应用前的必要审阅

应用计划前，确认以下全部成立：

- Controller URL 正确，且携带凭据的访问使用 HTTPS 或仅 loopback HTTP；
- 计划使用固定镜像和插件版本，而不是 floating tag；
- 测试与生产目标根目录为绝对路径、互不相同、不嵌套，且归预期受限账号使用；
- SSH key 路径和 `known_hosts` 路径均为私有路径并指向预期主机；
- install、lint、test、build、artifact、activation 和 health 行为均来自项目证据；
- 每个环境的 activation 命令均已审阅；以及
- 预期回滚与保留结果在运维上可接受。

应用前预览生成文件。首次部署前应提交并推送生成的项目资产；生成的 trigger 会有意拒绝未提交的项目配置。

## 工作流 B：接入既有 Jenkins Controller

既有 Controller 不能仅因能返回 HTTP 响应就被视为安全。应从只读开始，并协调三种状态：观察到的实时 Controller/运行时状态、受源码控制的预期状态以及提议的目标状态。[references/audit-and-design.md](references/audit-and-design.md) 描述了证据收集方式。

### 1. 收集只读证据

source 私有管理员 profile，并将只读审计输出到私有目录：

```bash
SKILL_DIR=/absolute/path/to/implementing-jenkins-cicd
source /private/path/.jenkins-cli.env
"$SKILL_DIR/scripts/jenkins-readonly-audit.sh" evidence/audit
```

审计从 `JENKINS_URL/jnlpJars/jenkins-cli.jar` 获取与 Controller 匹配的 CLI JAR，将原始材料保护在临时私有目录，并仅允许 `who-am-i`、`version`、`list-jobs`、`list-plugins`、`get-job` 和 `console`。它不能创建、更新、删除、重启、安装或触发任何内容。即使经过脱敏的审计证据也应视作敏感资料，不再需要时应删除。

审计会记录身份、Jenkins core/plugin 版本、Jobs 和 `security-baseline.json`。若已安装版本与新鲜 official update-center security-warning feed 匹配，则为阻断性失败。对存在已知漏洞或过时的 Controller，在任何配置变更前必须先升级并验证恢复路径。

### 2. 协调现状并规划变更

对每一条交付路径记录 trigger、source、CI 步骤、artifact、deploy target、health 条件和 rollback。贯穿所有调用脚本追踪 `set -e`、`|| true`、跳过的测试、可变 tag、陈旧工作区、破坏性替换和被掩盖的非零退出。相同文件名不等于部署脚本等价；比较时应对重复文件做哈希。

审阅中必须分开以下三类事实：

1. **Observed current state**：仅由实时证据支持。
2. **Source and policy expectation**：由受版本控制的项目文件和说明支持。
3. **Proposed target state**：经过审阅的建议；对每处差异记录 owner 和所需证据。

### 3. 仅应用有界且经批准的配置

仅在完成精确 pinned-plugin 对比并具备结构化备份证据后使用 [scripts/configure-jenkins-plugins.sh](scripts/configure-jenkins-plugins.sh)。所需备份证据包括绝对备份路径、匹配 SHA-256、带时区时间戳和 `restore_tested: true`；仅声称存在备份并不充分。

在只读审计和计划批准后使用 [scripts/apply-jenkins-job.sh](scripts/apply-jenkins-job.sh)。安全 CLI wrapper 会将写入绑定至计划中的 Controller、Job、插件集和精确计划哈希。Job XML 通过确定性渲染产生，而不接受任意标准输入；更新时会保存之前的私有 XML。临时匹配 CLI JAR 在成功、失败或中断后都会删除。

Jenkins CLI 始终只用于配置。不要将 `build`、`delete-job`、任意 Groovy 或宽泛管理员命令加入 allowlist。显式部署请求应由项目自有 trigger script 发起。

## 工作流 C：渲染并运行 Server-pull 交付

当 Jenkins 在应用服务器上运行，且所需来源边界为 **拉取一个命名远端分支、证明它等于请求的精确 commit、然后构建和发布** 时，使用 server-pull。适配项目之前请完整阅读 [references/server-pull-templates.md](references/server-pull-templates.md)。

### Server-pull 契约

1. 用户推送 `dev` 或 `main`；单独的推送不会部署。
2. 用户明确要求测试或生产部署。
3. `ops/jenkins/trigger-deploy.sh` 证明其工作区干净，且本地 commit 已是映射远端分支的顶端。
4. trigger 调用 Jenkins `buildWithParameters`，并传递 `DEPLOY_ENV`、`GIT_REF` 和完整 `EXPECTED_COMMIT`。
5. Jenkins 在已批准节点上调用已安装的 `deploy-from-git.sh`。
6. 服务器拉取映射分支，除非拉取的 commit 等于 `EXPECTED_COMMIT`，否则拒绝构建。
7. 服务器构建版本化候选版本、激活、执行健康检查；失败则回滚，成功后才清理旧成功版本。

renderer 会生成一个新的私有输出目录，包含：

| 生成文件 | 目标位置和职责 |
| --- | --- |
| `trigger-deploy.sh` | 作为 `ops/jenkins/trigger-deploy.sh` 提交到应用仓库；它验证本地 Git 状态并提交显式 Jenkins 构建请求。 |
| `deploy-from-git.sh` | 安装在应用仓库之外、Jenkins 可读可执行且受限的部署主机路径。 |
| `job.xml` | 确定性参数化 Freestyle Job，绑定已批准节点，无自动 trigger 且禁止并发构建。 |
| `manifest.json` | 渲染文件和有界控制面脚本的私有哈希 manifest 与批准标识。编辑 bundle 必须重新渲染并重新批准。 |

渲染脚本权限为 `0700`，manifest 权限为 `0600`。renderer 会拒绝已有输出路径、未知配置字段、不安全或嵌套根目录、内嵌仓库凭据、无效分支映射和小于两个的保留数。

可复用源模板为 [assets/templates/trigger-deploy.sh.tmpl](assets/templates/trigger-deploy.sh.tmpl) 和 [assets/templates/deploy-from-git.sh.tmpl](assets/templates/deploy-from-git.sh.tmpl)。渲染输出是受批准约束的生成材料；仅能通过经过审阅的 skill 变更更新模板，并必须重新渲染所有受影响 bundle。

### 无 secret 的 JSON 配置

在不会存放私有值的路径中创建配置文件。下面的完整示例仅用于说明；其中不含 credential、key、password 或 token。schema 的权威来源是 [references/server-pull-templates.md](references/server-pull-templates.md)。

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

| 字段组 | 含义与约束 |
| --- | --- |
| `schema_version`、`project_name`、`repository_url`、`jenkins_url`、`jenkins_job` | 选择受支持 schema，并指定唯一项目、Git 远端、Controller 和 Job。仓库 URL 不得内嵌凭据。 |
| `branches` | 映射 `test` 与 `production` 允许使用的分支。通常为 `dev` 和 `main`；项目证据可以覆盖。 |
| `source_roots` 和 `deploy_roots` | 每个环境独立的绝对根目录。源码和部署根必须不同且不嵌套。 |
| `commands` | 来自证据的 install、lint、test、build 和 activation shell 片段。activation 必须使用准备好的 current release，不能使用临时 staging 目录。 |
| `artifact_paths` | 复制到候选发布目录的构建输出。会拒绝通过 symbolic link 逃逸的路径。 |
| `health_urls` | 每个环境的有界就绪端点。受鉴权保护的端点不会自动成为有效健康信号。 |
| `execution` | 在线且已批准的 `node_label`、绝对安装脚本路径和绝对部署锁路径。受限 OS 账号必须能执行且只能执行此操作。 |
| `release_retention` | 需要保留的成功发布数。最小值为两个；默认值为五个。 |
| `clean_excludes` | 仅当项目证据要求时才设置明确的 Git-clean 排除项。 |

构建和激活期间，部署脚本会导出 `DEPLOY_ENV`、`GIT_REF`、`EXPECTED_COMMIT`、`SOURCE_ROOT`、`DEPLOY_ROOT` 和 `HEALTH_URL`。activation 还会收到 `CURRENT_RELEASE`、`CURRENT_LINK` 和 `PREVIOUS_RELEASE`。数据库迁移策略另行处理：向后兼容的迁移可以在激活前规划；破坏性迁移需要单独批准的发布与恢复设计。

### 渲染、审阅并验证 bundle

```bash
SKILL_DIR=/absolute/path/to/implementing-jenkins-cicd

python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --output rendered-server-pull
bash -n rendered-server-pull/trigger-deploy.sh
bash -n rendered-server-pull/deploy-from-git.sh
python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --verify-output rendered-server-pull
PLAN_ID="$(python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --print-plan-id)"
```

审阅 `rendered-server-pull/manifest.json` 及每个渲染文件。将 trigger 拷贝进应用项目，审阅、提交并在首次部署前推送：

```bash
mkdir -p PROJECT/ops/jenkins
install -m 0700 rendered-server-pull/trigger-deploy.sh PROJECT/ops/jenkins/trigger-deploy.sh
git -C PROJECT add ops/jenkins/trigger-deploy.sh
git -C PROJECT commit -m "ops: add Jenkins deployment trigger"
git -C PROJECT push
```

上面的安装命令只包含生成的 trigger，不包含任何 profile 或 token。不得把 `.jenkins-cli.env`、`.jenkins-trigger.env`、私钥或私有输出 bundle 放入项目仓库。

### 配置 Jenkins 并安装服务器程序

以下配置操作使用管理员 profile。它们不会触发部署。

```bash
SKILL_DIR=/absolute/path/to/implementing-jenkins-cicd
PLAN_ID="$(python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" --config server-pull.json --print-plan-id)"
source /private/path/.jenkins-cli.env
"$SKILL_DIR/scripts/apply-server-pull-job.sh" --config server-pull.json --bundle rendered-server-pull --approve "$PLAN_ID" --evidence evidence/job-apply
"$SKILL_DIR/scripts/install-server-pull-script.sh" --config server-pull.json --bundle rendered-server-pull --approve "$PLAN_ID" --evidence evidence/script-install
"$SKILL_DIR/scripts/verify-server-pull-delivery.sh" --config server-pull.json --bundle rendered-server-pull --approve "$PLAN_ID" --output evidence/config-verification
```

如部署主机为远程目标，在支持的安装和验证步骤中使用相同、经审阅的 `--ssh-target restricted-user@host` 参数，并在操作方 SSH 配置中保持严格主机密钥验证。`apply-server-pull-job.sh` 更新时会保存之前 XML。临时 CLI JAR 是私有的，并由安全 wrapper 删除。

生成的 Job 仅包含 `DEPLOY_ENV`、`GIT_REF` 和 `EXPECTED_COMMIT` 参数，拥有空 triggers block 并禁用并发构建。其 build step 直接调用已批准的绝对服务器脚本。所选 `node_label` 必须在线，并以受限账号运行；该账号只能访问选定 roots、lock file、仓库和范围很窄的 activation 权限，不得拥有 Jenkins 管理权限、无限制 `sudo` 或 Docker socket。

## 显式部署测试与生产环境

部署必须由用户显式请求。推送代码只是前提，不是授权。通用默认映射是 `dev -> test` 和 `main -> production`；使用前必须读取仓库说明和实时 Job。

### 测试部署

```bash
git switch dev
git status --short
git push origin dev
source /private/path/.jenkins-trigger.env
./ops/jenkins/trigger-deploy.sh --environment test
```

### 生产部署

根据仓库策略提升并验证已审阅的测试 commit。只有预期 commit 已在生产分支且用户明确请求生产时，才执行：

```bash
git switch main
git status --short
git push origin main
source /private/path/.jenkins-trigger.env
./ops/jenkins/trigger-deploy.sh --environment production
```

生成的 trigger 接受 `--environment test|production` 和可选 `--commit FULL_SHA`。向 Jenkins POST 之前，它会验证：

1. 私有 profile 中存在所需 `JENKINS_USER_ID` 和 `JENKINS_API_TOKEN`；
2. Controller URL 为 HTTPS，或为经本地隧道访问的 loopback HTTP；
3. 项目目录是没有 tracked 或 untracked 改动的 Git worktree；
4. 当前本地分支是所请求环境映射的分支；
5. 本地 `HEAD` 是完整 40 字符 SHA，且等于对应的 `origin/<branch>` SHA；以及
6. 可选指定 commit 与完整本地 `HEAD` SHA 相同。

它向 Jenkins `buildWithParameters` 发送 POST，携带 `DEPLOY_ENV`、`GIT_REF` 和 `EXPECTED_COMMIT`，在复用凭据前验证返回的 queue/build URL，跟踪 queue 到具体 build，输出 console text，并仅当 Jenkins 最终结果为 `SUCCESS` 时成功退出。token 保存在私有 curl configuration 文件中，绝不出现在 query string 或命令参数中。

## 发布生命周期、健康检查、回滚与清理

server-pull 的发布序列会明确记录发布状态：

1. 获取有界部署锁，避免两个部署同时修改同一目标。
2. 验证既有 `current` 状态，并拒绝不安全 symlink 或 release root。
3. 带重试拉取选定远端分支，证明它等于完整 `EXPECTED_COMMIT`，reset 到该 commit，并仅在已验证 source root 内 clean。
4. 执行来自证据的 install、lint、test 和 build 阶段。可选阶段只有在命令有意为空时才会被可见地跳过。
5. 在 `DEPLOY_ROOT/releases` 下创建唯一 staging candidate，只复制已批准的非 symlink artifact，并写入发布元数据。
6. 针对 `CURRENT_RELEASE` 或 `CURRENT_LINK` 运行经审阅的环境 activation 命令。
7. 使用有界次数和间隔轮询 health endpoint。健康错误就是部署失败，而不是警告。
8. 成功后将 `DEPLOY_ROOT/current` 原子指向 candidate，标记成功并保留证据。
9. 失败时恢复前一个已知正常 release，对恢复状态健康检查，保留失败 candidate 用于诊断，并跳过清理。
10. 仅在成功后清理旧成功 release。默认保留五个；current 和 previous 永远受保护，不安全清理路径会被拒绝。

发布目录不是通用临时目录。`DEPLOY_ROOT/current` 必须只解析到 `DEPLOY_ROOT/releases` 下的正常成功目录。清理是成功后的维护操作；其失败必须可见，且不得错误表示部署本身已经回滚。

## 脚本与参考文档索引

### 运行脚本

| 路径 | 职责 | 关键安全边界 |
| --- | --- | --- |
| [scripts/inspect-project.py](scripts/inspect-project.py) | 发现交付计划需要的仓库证据。 | 不根据文件名猜测项目行为。 |
| [scripts/plan-jenkins.py](scripts/plan-jenkins.py) | 创建并验证确定性、受审批约束的 Jenkins 计划。 | 计划绑定敏感配置决策和精确批准标识。 |
| [scripts/render-jenkins-assets.py](scripts/render-jenkins-assets.py) | 从计划渲染 Controller 和项目资产。 | 项目应用与精确计划 ID 绑定。 |
| [scripts/orchestrate-jenkins-delivery.sh](scripts/orchestrate-jenkins-delivery.sh) | 应用已批准的新 Controller 交付 bundle。 | 协调已审阅文件、独立 profile、Job 应用和 Agent 验证。 |
| [scripts/install-jenkins-docker.sh](scripts/install-jenkins-docker.sh) | 安装计划中的固定 Docker Controller 拓扑。 | 使用持久存储、私有 bootstrap 材料、loopback HTTP，且无默认 Docker socket。 |
| [scripts/bootstrap-jenkins-cli-profile.sh](scripts/bootstrap-jenkins-cli-profile.sh) | 创建私有管理员和 trigger API-token profile。 | Profile 权限为 `0600`，从不打印 token 值。 |
| [scripts/jenkins-cli-safe.sh](scripts/jenkins-cli-safe.sh) | 运行与 Controller 匹配的 Jenkins CLI 命令。 | 使用私有临时 JAR、WebSocket transport、窄 allowlist，并在所有退出路径清理。 |
| [scripts/jenkins-readonly-audit.sh](scripts/jenkins-readonly-audit.sh) | 收集脱敏、只读的 Controller 证据。 | 不能修改 Job、插件、凭据或构建。 |
| [scripts/check-jenkins-security-baseline.py](scripts/check-jenkins-security-baseline.py) | 将已安装 core/plugin 与 official warning feed 对比。 | 安全告警匹配会阻止之后的变更。 |
| [scripts/configure-jenkins-plugins.sh](scripts/configure-jenkins-plugins.sh) | 协调精确固定版本的插件库存。 | 缺失插件写入前必须具备经过 restore test 的备份证据。 |
| [scripts/apply-jenkins-job.sh](scripts/apply-jenkins-job.sh) | 创建或更新计划中的 Jenkins Job。 | 确定性 XML、计划/哈希绑定，更新时保存之前 XML。 |
| [scripts/render-server-pull-templates.py](scripts/render-server-pull-templates.py) | 验证 JSON 并渲染可复用 server-pull 资产。 | 拒绝不安全 roots、未知字段、内嵌凭据、无效映射和弱保留策略。 |
| [scripts/apply-server-pull-job.sh](scripts/apply-server-pull-job.sh) | 应用确定性的 server-pull Job。 | 需要经批准 bundle 和管理员配置 profile。 |
| [scripts/install-server-pull-script.sh](scripts/install-server-pull-script.sh) | 安装已批准的服务器部署程序。 | 以受限权限安装绑定 manifest 的绝对脚本路径。 |
| [scripts/verify-server-pull-delivery.sh](scripts/verify-server-pull-delivery.sh) | 对照已批准 bundle 验证已安装脚本和实时 Job。 | 验证哈希和配置，不触发部署。 |
| [scripts/verify-jenkins-delivery.sh](scripts/verify-jenkins-delivery.sh) | 验证通用 Jenkins 交付配置和证据。 | 在部署请求前发现不完整配置。 |
| [scripts/redact-jenkins-evidence.pl](scripts/redact-jenkins-evidence.pl) | 对生成证据中的敏感材料脱敏。 | 脱敏只是尽力而为；输出仍应受访问限制并经审阅。 |

### 验证与测试脚本

| 路径 | 覆盖的内容 |
| --- | --- |
| [scripts/test-end-to-end-skill.sh](scripts/test-end-to-end-skill.sh) | 端到端覆盖 discovery、planning、rendering、release activation/rollback/cleanup、受保护 Job 应用、trigger 行为、plugin/configuration 验证及 server-pull 流程。 |
| [scripts/test-jenkins-readonly-audit.sh](scripts/test-jenkins-readonly-audit.sh) | 只读审计限制与生成证据行为。 |
| [scripts/test-server-pull-control-plane.sh](scripts/test-server-pull-control-plane.sh) | 经批准 server-pull Job/script 应用与验证控制。 |
| [scripts/test-server-pull-templates.sh](scripts/test-server-pull-templates.sh) | JSON 验证、渲染、manifest 和生成 trigger/deployment script 行为。 |

### 参考文档

| 文档 | 适用场景 |
| --- | --- |
| [references/provisioning-and-cli.md](references/provisioning-and-cli.md) | 安装受支持 Controller、使用安全匹配 CLI，或接入既有 Controller。 |
| [references/audit-and-design.md](references/audit-and-design.md) | 审计仓库/Controller/runtime，并协调观察、预期和目标状态。 |
| [references/ai-triggered-delivery.md](references/ai-triggered-delivery.md) | 定义显式 AI 触发的测试/生产交付，并选择唯一来源边界。 |
| [references/server-pull-templates.md](references/server-pull-templates.md) | 创建 server-pull JSON 映射、渲染脚本、配置 Job 并运行流程。 |
| [references/security-and-operations.md](references/security-and-operations.md) | 审阅凭据、Controller/Agent 隔离、远程变更批准和运维控制。 |
| [references/deployment-patterns.md](references/deployment-patterns.md) | 选择构件/service 发布模式、健康语义、回滚与清理。 |

## 配置与凭据边界

### 信息应存放的位置

| 信息 | 合规位置 | 绝不应放入 |
| --- | --- | --- |
| Jenkins API token | 私有管理员或 trigger profile；适用时使用 Jenkins credential store。 | Git、带真实值的 README 示例、Job XML、URL query string、进程参数或渲染项目资产。 |
| SSH private key | 仅在经批准 apply 时引用的私有文件，或 Jenkins Credentials。 | `server-pull.json`、仓库源码、证据 bundle 或 shell history。 |
| SSH server identity | 已验证 `known_hosts` 与经审阅 SSH 配置。 | 已关闭主机密钥校验或未验证的首次使用接受流程。 |
| Repository access credential | Jenkins Credentials、受限部署账号或私有 SSH 配置。 | Repository URL user-info、JSON 配置或被复制的 release artifact。 |
| Environment configuration | 已批准 secret store 或部署主机私有配置。 | Git 跟踪的部署脚本，除非该值明确为非 secret。 |
| Credential ID | 必要时作为计划/Job/配置引用。 | 不能用 ID 替代 secret 值，也不能因此就打印实际 secret。 |

masking 不是安全边界。应在使用 secret 时关闭 shell tracing，只将 secret 绑定到最短必要阶段，不在持有 secret 的阶段运行不可信代码，并对在 source、XML、log 或 artifact 中发现的任何 credential 执行轮换。仅删除暴露行不是充分补救。

## 验证与测试套件

发布或修改 skill 前，应在仓库根目录运行完整套件：

```bash
bash scripts/test-end-to-end-skill.sh
```

当所有 mock control-plane 与 delivery 场景成功时，端到端测试输出 `PASS: end-to-end Jenkins skill`。也提供聚焦测试：

```bash
bash scripts/test-jenkins-readonly-audit.sh
bash scripts/test-server-pull-templates.sh
bash scripts/test-server-pull-control-plane.sh
```

真实项目交付的验证不仅是 Jenkins build 结果。应保留仓库 commit 已推送、plan/bundle approval 匹配、Controller 与 Agent 配置匹配、测试执行、candidate health 通过、rollback 行为已演练以及临时敏感材料已删除的证据。完成已批准工作流时，执行 [scripts/verify-jenkins-delivery.sh](scripts/verify-jenkins-delivery.sh) 或 [scripts/verify-server-pull-delivery.sh](scripts/verify-server-pull-delivery.sh)，并同时保存项目自身测试和健康/回滚证据。

## 故障排查

| 现象 | 含义 | 安全的下一步 |
| --- | --- | --- |
| `missing required environment variable: JENKINS_USER_ID` 或 `JENKINS_API_TOKEN` | 未 source 私有 profile、profile 不完整，或权限不正确。 | 在当前 shell source 正确私有 profile；在不打印值的情况下验证其 owner/mode，并为正确操作使用管理员或 trigger profile。 |
| Trigger 提示工作区必须干净 | 本地文件与即将部署的 commit 不同。 | 审阅后提交、stash 或有意丢弃识别出的本地改动；然后从干净 worktree 重试。绝不部署未提交状态。 |
| Trigger 提示本地 `HEAD` 尚未推送 | Jenkins 无法绑定到远端不可变 commit。 | 推送映射分支，并确认 `origin/<branch>` 等于本地完整 SHA。不要强制 trigger 使用其他 ref。 |
| Security baseline 失败 | 已安装 Jenkins core 或 plugin 与官方 warning 匹配。 | 停止配置写入；准备受支持升级、备份、restore test 和恢复计划，然后重复 audit。 |
| 已批准 `node_label` 不可用 | Jenkins 无法在已审阅受限执行节点运行 Job。 | 使预期节点上线，验证其 label 和受限账号访问，然后重跑配置验证。不要退回 Controller built-in node。 |
| SSH host-key verification 失败 | 目标身份缺失或与预期 host key 不同。 | 调查主机身份，只能在带外确认轮换后更新 `known_hosts`。不要关闭严格校验。 |
| Candidate health check 失败 | 发布未达到定义的就绪条件。 | 阅读保留证据，确认 rollback 健康，诊断 candidate，并仅部署经过审阅的修复 commit。清理必须继续跳过。 |
| Server-pull bundle 或 hash verification 失败 | 渲染文件、配置、控制面脚本或批准标识不再匹配。 | 从已审阅无 secret JSON 重新渲染，审阅新 manifest，取得新批准，再应用。不要原地编辑渲染文件。 |
| Jenkins build 最终结果不是 `SUCCESS` | Queue、build、CI、部署、health 或 rollback 阶段失败。 | 阅读具体 build console 和生成证据，定位失败 gate，修复根因后发起新的显式请求。不得把 `UNSTABLE`、`ABORTED` 或 `FAILURE` 当作成功部署。 |
| Plugin dynamic loading 失败 | 缺失 pinned plugin 需要 restart-safe 处理。 | 保留恢复证据，规划带备份的受控重启，并验证重启后 inventory。不要掩盖失败。 |

## 仓库结构

```text
.
├── SKILL.md                         # 操作契约与 Codex 工作流
├── agents/openai.yaml               # Codex 展示元数据和默认 prompt
├── assets/
│   ├── compose.yaml.tmpl             # 固定版本 Controller/Agent 拓扑
│   ├── jenkins.yaml.tmpl             # JCasC 模板
│   ├── plugins.lock.txt              # 固定版本 Jenkins plugin inventory
│   └── templates/                    # Server-pull trigger、部署脚本和 Job XML 模板
├── references/                       # Provisioning、audit、security 和 deployment 的详细说明
├── scripts/                          # Discovery、planning、rendering、configuration、verification 与测试程序
└── docs/                             # 设计记录和实施计划
```

在 Codex 中调用 skill 时先阅读 `SKILL.md`。适配真实项目时先阅读最相关参考文档。除非经过审阅的实现变更明确更新它们，否则应将 assets 视为 renderer 输入，而不是手动编辑的生产文件。

## 贡献

贡献应保持安全模型，而不只是增加一条 happy-path 命令。提交改动前：

1. 阅读 `SKILL.md` 及与受影响工作流最相关的参考文档。
2. 修改脚本行为时，先添加或更新最小相关测试，再运行聚焦测试和完整端到端套件。
3. 保持计划批准、来源可追溯性、凭据分离、主机密钥验证、健康检查、回滚和清理不变量。
4. 不要提交私有 Controller 证据、profile、key、bundle、host 或 token。
5. 修改公开说明行为时，同时更新本 README 的英文和中文部分。

小而有证据支持的变更更容易审阅。不要为了便利而扩大 CLI allowlist 或部署权限。

## 许可证状态

本仓库当前没有 `LICENSE` 文件。本 README 不表示任何许可证授予；在依赖第三方复用权利前，应先添加并审阅明确许可证。
