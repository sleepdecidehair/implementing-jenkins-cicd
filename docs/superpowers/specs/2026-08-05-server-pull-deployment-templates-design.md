# Server-Pull Jenkins Deployment Templates Design

## Objective

Add two reusable templates to `implementing-jenkins-cicd` so Codex can inspect a repository and server description, render project-specific deployment scripts, configure a Jenkins job, and leave deployment under explicit user control.

The required operator flow is:

1. The user pushes `dev`; the push does not trigger Jenkins.
2. The user explicitly asks Codex to deploy the test environment.
3. Codex runs the rendered project trigger script.
4. Jenkins runs the rendered server deployment script, which fetches `dev`, builds, deploys, and verifies the test environment.
5. Only after successful health verification does the script prune excess old releases.
6. The user validates test, promotes and pushes `main`, then explicitly asks Codex to deploy production.
7. The same flow repeats for production with `main`.

## Scope

Create these Skill assets:

- `assets/templates/trigger-deploy.sh.tmpl`
- `assets/templates/deploy-from-git.sh.tmpl`

Update the Skill workflow and renderer to select and fill them when the user chooses server-pull delivery. Do not copy values from the audited `jenkins-deploy-scripts` directory. It is evidence for operational patterns only; real URLs, accounts, tokens, repository names, paths, ports, and credentials must not enter the templates.

This design does not enable webhook, GitHub push trigger, Generic Webhook Trigger, or SCM polling. It does not create a separate application repository for a Jenkins Agent. The Jenkins job may execute on a suitable existing node on the same server.

## Architecture

```text
User push dev/main
        |
        | no Jenkins trigger
        v
Explicit Codex deployment request
        |
        v
project trigger-deploy.sh
  - validates branch and pushed commit
  - POSTs Jenkins build parameters
  - follows queue and concrete build
        |
        v
Jenkins job with empty <triggers/>
        |
        v
server deploy-from-git.sh
  - locks deployment
  - fetches exact remote commit
  - builds candidate
  - activates and checks health
  - rolls back on failure
  - cleans old releases only after success
```

## Trigger Template Contract

The rendered project trigger accepts:

```text
--environment test|production
--commit FULL_SHA            optional assertion
```

Render-time fields are the planned Jenkins URL, Jenkins job, test branch, and production branch. Runtime credentials come only from `JENKINS_USER_ID` and `JENKINS_API_TOKEN`; `JENKINS_URL` may be supplied but must equal the rendered controller URL.

Before calling Jenkins, the trigger must:

- require a clean local Git worktree;
- require `dev` for test and `main` for production unless repository evidence defines another mapping;
- resolve local `HEAD` and `origin/<branch>` and require exact equality;
- send exactly `DEPLOY_ENV`, `GIT_REF`, and `EXPECTED_COMMIT`;
- use the Jenkins Remote Access API, not Jenkins CLI `build`;
- keep credentials in environment/private curl configuration, never source, arguments, query strings, or logs;
- allow HTTPS or loopback HTTP only;
- validate returned queue and build URLs before reusing credentials;
- wait for the queue item, concrete build, final result, and console output;
- return success only when Jenkins reports `SUCCESS`;
- remove temporary credential material on success, failure, or signal.

## Server Deployment Template Contract

The rendered Jenkins-side script receives only the managed job parameters:

```text
DEPLOY_ENV=test|production
GIT_REF=<mapped branch>
EXPECTED_COMMIT=<full 40-character SHA>
```

Render-time fields define:

- project name and repository URL;
- test and production branch mapping;
- separate test and production source/deployment roots;
- repository credential mechanism already configured on the server;
- install, lint, test, build, package, activation, health, and rollback commands derived from source evidence;
- release retention, defaulting to five and never below two;
- optional cache paths that may survive `git clean` only when explicitly planned.

The script must perform these phases in order:

1. Validate all parameters, required commands, absolute paths, environment mapping, and repository target.
2. Acquire a project-wide deployment lock so test and production cannot compete for a shared server build toolchain.
3. Clone only into an empty planned source directory when the repository is absent; otherwise verify the existing `origin` before mutation.
4. Fetch the mapped branch with bounded retry, resolve `origin/<branch>`, and require it to equal `EXPECTED_COMMIT`.
5. Reset and clean only the validated source worktree, then check out the exact expected commit.
6. Run generated install, lint, test, and build commands with strict failure propagation.
7. Package a candidate under `DEPLOY_ROOT/releases/<release-id>` without replacing the active release.
8. Activate the candidate using the generated project strategy and run bounded health checks.
9. On activation or health failure, reactivate the recorded previous release, rerun activation and health verification, and return failure.
10. After successful health only, mark the candidate successful and prune excess successful releases while protecting current and previous.

The release identifier includes the full commit identity or a collision-safe prefix plus Jenkins build number. Cleanup validates the release root and every deletion target, rejects symlinks and broad paths, and never runs before the new version is healthy.

## Project Adaptation

The Skill inspects manifests and deployment evidence before rendering concrete command blocks:

- frontend projects normally build `dist` or the discovered output directory and deploy a versioned static release;
- Java services normally build the discovered JAR/WAR and render the known service activation command;
- Node or Python services render their authoritative package and process-manager commands;
- Docker projects may build and activate a locally tagged image, but only when the repository already provides a verified Docker deployment path;
- multi-component repositories render explicit component commands and health gates rather than silently treating one service as representative of all services.

If authoritative build, activation, health, repository credential, or safe target-path evidence is missing, planning remains blocked and Codex asks only for those critical values.

## Jenkins Configuration

The managed job remains parameterized with `DEPLOY_ENV`, `GIT_REF`, and `EXPECTED_COMMIT`. Its trigger configuration is empty. The job invokes the rendered server deployment script and passes parameters through environment variables. Jenkins CLI remains configuration-only and may create/update the job and plugins, but its `build` command remains disallowed.

No separate Agent project is created. If the Jenkins controller runs in Docker and cannot safely reach the host worktree/toolchain, the installation must use an existing suitable node or a one-time same-server execution node configuration. That infrastructure choice is separate from project source and is never generated as another application repository.

## Error Handling and Evidence

- A trigger request being accepted is not deployment success; the trigger waits for the final result.
- A fetch mismatch, dirty local worktree, wrong branch, unexpected Jenkins URL, build failure, activation failure, health failure, or rollback health failure returns nonzero.
- Logs include environment, branch, commit, release ID, phase, and final result but redact credentials.
- Jenkins archives build/deployment evidence appropriate to the project without archiving secret environment files.
- Failed candidates remain available only when safe and useful for diagnosis; they are never marked successful.

## Verification

Add deterministic tests with fake Git, curl, build, activation, and health commands covering:

- renderer fills all required fields and leaves no unresolved render markers;
- job XML has an empty trigger set;
- Jenkins CLI rejects `build`;
- test maps to `dev` and production maps to `main`;
- local/remote commit mismatch blocks the trigger;
- server remote commit mismatch blocks deployment before build;
- failed build does not activate or clean releases;
- failed health invokes rollback and does not clean releases;
- successful health activates the candidate, then prunes only excess releases;
- current and previous releases are protected;
- unsafe paths, symlink deletion candidates, malicious Jenkins URLs, and signal interruption fail safely;
- credentials and temporary files do not remain in output or test trees.

## Acceptance Criteria

The Skill can take a project path plus Jenkins/server facts, generate the two scripts without secrets, configure a non-automatic Jenkins job, and demonstrate the complete explicit test/production flow in fixtures. A Git push alone performs no deployment. Production cannot use `dev`, test cannot use `main`, Jenkins checks out the exact requested remote commit, and old releases are deleted only after successful health verification.
