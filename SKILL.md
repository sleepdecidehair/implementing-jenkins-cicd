---
name: implementing-jenkins-cicd
description: Use when installing or configuring Jenkins and its controller-matched configuration-only CLI, inspecting a project to generate Jenkinsfile plus project-owned trigger and deployment scripts, creating or migrating Jenkins jobs, or operating and troubleshooting AI-triggered CI/CD with tests, health checks, release cleanup, and rollback.
---

# Implementing Jenkins CI/CD

Take minimal inputs to verified delivery. Inspect before changing and ask only when evidence cannot resolve a critical choice.

## Collect the Minimum

Usually require project path/repository, Jenkins target, deployment destination and health endpoint, plus credential IDs or private key paths. Public repositories must be marked explicitly. Credential source hashes are approval-bound; private keys are copied only during apply and never enter the rendered bundle.

Read every applicable `AGENTS.md`, manifest, lockfile, container file, existing Jenkinsfile, deployment script, service/proxy definition, and Git branch rule. Never infer that local uncommitted files are deployable.

## Choose the Workflow

For a new controller, read [provisioning-and-cli.md](references/provisioning-and-cli.md), then use:

```bash
scripts/inspect-project.py --project PROJECT --output discovery.json
scripts/plan-jenkins.py create --discovery discovery.json [TARGET OPTIONS] --output plan.json
scripts/render-jenkins-assets.py --plan plan.json --output bundle
scripts/orchestrate-jenkins-delivery.sh \
  --plan plan.json --bundle bundle --approve PLAN_ID \
  --project PROJECT --evidence EVIDENCE_DIR
```

The orchestrator applies reviewed project files, installs a new controller when planned, creates separate protected administrator and deployment-trigger API-token profiles, applies the job, and verifies the dedicated build agent. Installation uses a version-pinned official Jenkins LTS JDK 21 image, persistent storage, JCasC, version-locked plugins, file-backed bootstrap secrets, and a separate SSH agent. It binds plain HTTP to loopback only. Never mount the host Docker socket by default or silently install Docker Desktop. Jenkins CLI is configuration-only in this Skill: never use its `build` command to deploy.

For an existing controller, start read-only and reconcile live configuration, repository expectations, and target plan with [audit-and-design.md](references/audit-and-design.md). The orchestrator runs `jenkins-readonly-audit.sh` before job or plugin writes and blocks mutation when installed core or plugin versions match the current official update-center security warning feed.

Preview generated files before exact-plan apply. For existing controllers, use `configure-jenkins-plugins.sh`, then `apply-jenkins-job.sh`; updates save prior XML. The matched CLI JAR is temporary and always deleted. Commit and push the generated project assets before the first deployment; the trigger intentionally rejects an uncommitted configuration change.

When Jenkins executes on the application server and the required model is for Jenkins to pull an exact remote commit, use [server-pull-templates.md](references/server-pull-templates.md). Inspect the project, create its secret-free JSON mapping, then render the reusable scripts:

```bash
scripts/render-server-pull-templates.py \
  --config server-pull.json \
  --output rendered-server-pull
```

Review the manifest, commit the rendered trigger as `ops/jenkins/trigger-deploy.sh`, apply the deterministic `job.xml` with `apply-server-pull-job.sh`, install `deploy-from-git.sh` with `install-server-pull-script.sh`, and run `verify-server-pull-delivery.sh`. Use the administrator profile only for configuration and the separate least-privilege trigger profile only for deployment requests. An agent is an execution node, not a separate project or repository; `node_label` must name an online approved node whose restricted OS account can execute the server script locally.

## Deploy Only on Explicit Instruction

Read [ai-triggered-delivery.md](references/ai-triggered-delivery.md). Do not configure webhook, SCM polling, or push-triggered deployment by default. The user pushes code, then explicitly asks the AI to deploy.

Default mapping is `dev → test` and `main → production`; repository evidence may override it. Verify a clean worktree and that local HEAD equals the pushed remote branch, then run:

```bash
source PRIVATE_JENKINS_TRIGGER_PROFILE
PROJECT/ops/jenkins/trigger-deploy.sh --environment test|production
```

The project-owned command verifies the pushed commit, calls Jenkins Remote Access API with the exact deployment parameters, follows the queue into the concrete build, prints its console output, and returns success only for a final `SUCCESS` result. It keeps the API token in environment/private curl configuration, never in the repository or URL. A clear production request is approval; ask once only if the environment is ambiguous.

## Enforce Delivery Gates

Never deploy an uncommitted workspace. Choose one approved delivery boundary: build/test on an agent and transfer one immutable artifact, or use the server-pull mode to fetch a named remote branch and prove it resolves to the exact `EXPECTED_COMMIT` before any build command runs.

Remote deployment requires an SSH credential ID and verified `known_hosts`; never weaken host-key checking. Confirm how the service or proxy consumes `DEPLOY_ROOT/current`, and encode a reviewed test/production activation command when reload or restart is needed. Treat agent-local deployment as a sandbox exception.

Deploy to a versioned candidate, switch only through a validated path, run bounded health checks, and roll back on failure. Only after the new release is active and healthy may the selected cleanup implementation prune old successful versions. Default retention is five; always preserve current and previous, never retain fewer than two, and reject unsafe cleanup paths.

Use [deployment-patterns.md](references/deployment-patterns.md) and [security-and-operations.md](references/security-and-operations.md). Finish with `verify-jenkins-delivery.sh`, project tests, test deployment, health/rollback evidence, and temporary-file cleanup proof.
