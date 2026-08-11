# Server-Pull Deployment Templates

Use this mode when Jenkins executes on the same server that hosts the application and the required delivery contract is:

1. A person pushes `dev` or `main`; pushing alone never deploys.
2. The person explicitly asks the AI to deploy test or production.
3. The project-owned `trigger-deploy.sh` proves that local `HEAD` is clean and already present on the matching remote branch.
4. The trigger calls the Jenkins Remote Access API with `DEPLOY_ENV`, `GIT_REF`, and the exact 40-character `EXPECTED_COMMIT`.
5. Jenkins runs the server-owned `deploy-from-git.sh`, which fetches that branch and refuses to build unless the remote branch resolves to the exact requested commit.
6. The server builds a versioned candidate, activates it, verifies health, and rolls back on failure.
7. Old successful releases are pruned only after the new release is successfully active and healthy.

No webhook, SCM polling, or push trigger belongs in this mode. Jenkins CLI may inspect and configure the controller and job, but it must not run `build`; deployment remains an explicit project-script action.

## What Is Generated

`render-server-pull-templates.py` renders a new private directory containing:

- `trigger-deploy.sh`: commit-aware client trigger to commit at `ops/jenkins/trigger-deploy.sh`.
- `deploy-from-git.sh`: server-side deployment program to install outside the repository in a Jenkins-readable, Jenkins-executable path.
- `job.xml`: deterministic Freestyle job bound to the approved node, with no automatic trigger and no concurrent builds.
- `manifest.json`: the approval identifier plus SHA-256 hashes for rendered files and the bounded CLI/apply/install/verify control-plane scripts. Editing any of them requires re-rendering and a new approval.

The renderer refuses an existing output directory, unknown JSON fields, unsafe or nested source/deployment paths, embedded repository credentials, an invalid branch mapping, or retention below two. Rendered scripts are mode `0700`; the manifest is mode `0600`.

## Configuration Contract

Create a secret-free JSON file. Commands are project-specific shell fragments discovered from authoritative manifests and existing operational files. Credentials stay in Jenkins credentials, SSH configuration, or private environment files and never enter this configuration.

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

Render and review:

```bash
python3 "$CODEX_HOME/skills/implementing-jenkins-cicd/scripts/render-server-pull-templates.py" \
  --config server-pull.json \
  --output rendered-server-pull

bash -n rendered-server-pull/trigger-deploy.sh
bash -n rendered-server-pull/deploy-from-git.sh
python3 "$CODEX_HOME/skills/implementing-jenkins-cicd/scripts/render-server-pull-templates.py" \
  --config server-pull.json \
  --verify-output rendered-server-pull
```

The verification command prints the approval identifier. Use the actual absolute Skill path if `CODEX_HOME` is not defined. Copy the trigger into the project, review it, commit it, and push it. Never store either Jenkins profile in the project.

## Map a Project into the Contract

Inspect the source before choosing commands. Prefer lockfile-preserving installation and commands already defined by the project.

| Project evidence | Typical install/build | Candidate artifacts | Activation responsibility |
|---|---|---|---|
| `package.json` plus npm lockfile | `npm ci`, then project lint/test/build scripts | `dist`, `build`, `.next` plus required runtime files | Restart the existing process manager or atomically point the web root at `CURRENT_RELEASE` |
| Maven or Gradle service | Wrapper-based clean test/package | `target/*.jar` or `build/libs/*.jar` | Update the service's release path and restart the existing service unit |
| Static frontend | Lockfile install and production build | Framework output directory | Point Nginx/static root at `CURRENT_RELEASE`, then reload only if configuration requires it |
| Docker Compose application | Project-prescribed image build/test | Compose files and immutable configuration needed at runtime | Run the reviewed Compose command from `CURRENT_RELEASE`; do not place registry secrets in the release |
| Python application | Lock-preserving `uv`, Poetry, or requirements install; project tests; `python -m build` when declared | `dist/*.whl`, `dist/*.tar.gz`, or project runtime tree | Activate through the existing service manager using `CURRENT_RELEASE` |
| Go service | Module-aware `go test ./...`; project-prescribed binary build | Project-declared binary or image | Restart the existing service against the versioned binary/release |
| Rust service | Locked Cargo tests and release build | Reviewed files under `target/release` | Restart the existing service against the versioned binary/release |
| .NET service | Restore, test, and `dotnet publish` | `publish` output | Point the existing service at the versioned publish directory and restart it |

The generated script exports these variables to build and activation commands:

- `DEPLOY_ENV`, `GIT_REF`, `EXPECTED_COMMIT`
- `SOURCE_ROOT`, `DEPLOY_ROOT`, `HEALTH_URL`
- `CURRENT_RELEASE`, `CURRENT_LINK`, `PREVIOUS_RELEASE` during activation

Activation must consume `CURRENT_RELEASE` or `CURRENT_LINK`. Do not hard-code a temporary staging directory. If a project needs database migrations, classify them first: backward-compatible migrations may run before activation; destructive migrations require a separately approved rollout and recovery design.

## Configure Jenkins Without Changing the Trigger Contract

The renderer creates the parameterized Freestyle `job.xml` with exactly these string/choice parameters and an empty `<triggers/>` element:

- `DEPLOY_ENV`: `test` or `production`
- `GIT_REF`: `dev` or `main`, according to the approved mapping
- `EXPECTED_COMMIT`: full remote commit SHA

Its build step invokes the approved absolute server script directly:

```bash
/opt/jenkins-deploy/example-app/deploy-from-git.sh
```

Environment variables supplied by Jenkins parameters are inherited by the script. The generated job disables concurrent builds; the script also takes the approved absolute `lock_file`. A Jenkins Agent is only an execution node. It does not require a separate Git repository or an “agent project.” `node_label` must identify an online, approved node that can execute `deploy_script_path` with a restricted operating-system account. Do not use the controller built-in node. The account needs only the selected source/deployment roots, the lock file, the project activation action, and repository access; it must not receive general `sudo`, the Docker socket, or Jenkins administration rights.

Apply configuration with the administrator CLI profile, install the approved script, and verify both live Jenkins configuration and the installed hash. These steps configure Jenkins only; none triggers a deployment:

```bash
SKILL_DIR="$CODEX_HOME/skills/implementing-jenkins-cicd"
PLAN_ID="$(python3 "$SKILL_DIR/scripts/render-server-pull-templates.py" \
  --config server-pull.json --print-plan-id)"

source /private/path/.jenkins-cli.env
"$SKILL_DIR/scripts/apply-server-pull-job.sh" \
  --config server-pull.json --bundle rendered-server-pull \
  --approve "$PLAN_ID" --evidence evidence/job-apply

"$SKILL_DIR/scripts/install-server-pull-script.sh" \
  --config server-pull.json --bundle rendered-server-pull \
  --approve "$PLAN_ID" --evidence evidence/script-install

"$SKILL_DIR/scripts/verify-server-pull-delivery.sh" \
  --config server-pull.json --bundle rendered-server-pull \
  --approve "$PLAN_ID" --output evidence/config-verification
```

For a remote deployment host, add the same `--ssh-target restricted-user@host` to installation and verification and use strict host-key checking in the operator's SSH configuration. `apply-server-pull-job.sh` saves prior XML on update. The matched CLI JAR is downloaded privately and deleted by the safe wrapper. Do not put either API token into job XML, a URL query string, the project, or rendered files.

## Operate the Flow

Test deployment:

```bash
git switch dev
git status --short
git push origin dev
source /private/path/.jenkins-trigger.env
./ops/jenkins/trigger-deploy.sh --environment test
```

Only after the test environment is verified should the user promote the reviewed change to `main` and request production:

```bash
git switch main
git status --short
git push origin main
source /private/path/.jenkins-trigger.env
./ops/jenkins/trigger-deploy.sh --environment production
```

The trigger waits for the concrete Jenkins build and exits nonzero unless Jenkins finishes with `SUCCESS`. The deployment script independently enforces the environment-to-branch mapping, exact remote commit, versioned releases, activation, bounded health verification, rollback, and post-success retention. A failed managed candidate remains available for diagnosis after that failed run and is removed only after a later deployment succeeds.

## Adaptation Checklist

- Confirm `dev → test` and `main → production`, or record an evidence-based override.
- Confirm the repository URL is reachable from the Jenkins execution user without embedding credentials.
- Give test and production distinct, non-overlapping source and deployment roots.
- Derive install, lint, test, build, artifact, activation, and health settings from source and server evidence.
- Verify service permissions, port ownership, proxy behavior, private configuration injection, and Git host keys.
- Verify `node_label` is online and its restricted OS account can read/execute the installed script without controller or administrator privileges.
- Keep at least current and previous releases; retain five by default.
- Test a bad commit, a failed health check with rollback, a successful test release, then a production release only after explicit instruction.
- Confirm cleanup ran only after success and protected both current and previous releases.
