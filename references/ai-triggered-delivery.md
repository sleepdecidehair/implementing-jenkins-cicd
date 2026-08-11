# AI-Triggered Delivery

## Default Operator Flow

1. User commits and pushes the intended code to `dev`.
2. User tells the AI to deploy the test environment.
3. AI runs the project-owned `ops/jenkins/trigger-deploy.sh`. The script verifies clean Git state, proves local HEAD equals the pushed `origin/dev` commit, and triggers Jenkins through the Remote Access API.
4. Jenkins runs the one approved delivery mode for that job, verifies the exact commit, deploys test, checks health, and only then prunes excess old successful releases.
5. User validates the test environment and merges or promotes the reviewed commit to `main`.
6. User pushes `main` and explicitly tells the AI to deploy production.
7. AI repeats commit verification and triggers production. The explicit production request is approval; do not ask a redundant confirmation.

There is no deployment merely because `dev` or `main` received a push. Jobs have empty trigger configuration by default.

## Branch Evidence Overrides Defaults

The generic default is `dev → test` and `main → production`. Read repository instructions and live jobs before planning. A repository may use `master`, release tags, or separate component branches. Record every component mapping explicitly rather than silently forcing the default.

For the audited `zhatu` legacy jobs, the current frontend production script pulls `master`, backend production pulls `main`, and both test jobs pull `dev`. Those are observed legacy facts. The Skill may preserve them during migration or standardize them only when the user authorizes a branch-policy change.

## Choose One Source Boundary Per Job

Both supported modes keep the same explicit user-request trigger. Do not combine them inside one job.

| Mode | Source movement | Build location | Use when |
|---|---|---|---|
| Immutable artifact | Jenkins checks out the exact commit, builds once, and transfers a checksummed artifact or immutable image | A controlled build agent | Build and deployment authority should be separated, or the same output must be promoted across environments |
| Server Pull | The approved deployment host fetches one named remote branch and proves it resolves to `EXPECTED_COMMIT` before building | The application server, through an approved Jenkins execution node | Jenkins and the application share a server and the project is designed to build there |

Immutable-artifact flow:

`pushed commit → Jenkins build agent checkout → tests/build → immutable artifact → deployment server → health → cleanup`

Server-Pull flow:

`pushed commit → project trigger → Jenkins API → parameterized job → approved node → server fetches exact commit → tests/build → versioned activation → health → cleanup`

In immutable-artifact mode, the deployment server receives an artifact or image and does not clone source. In Server Pull mode, server-side fetch is the intended boundary; it must use the reviewed deployment program, enforce branch/environment mapping, and reject any remote commit other than `EXPECTED_COMMIT`.

For immutable artifacts, the build agent verifies the checksum before deployment. For a remote destination it transfers the archive and checksum with strict SSH host-key verification, runs activation, checks health, and then marks the release successful. In both modes, health failure restores the previous release and skips cleanup. Cleanup is a separate final action and cannot run after failed deployment or failed rollback.

## Project Trigger Contract

Jenkins CLI installs/configures plugins and jobs but must not trigger a deployment. Every AI-triggered build is submitted by the generated project script with exactly:

- `DEPLOY_ENV`: `test` or `production`;
- `GIT_REF`: the branch mapped to that environment;
- `EXPECTED_COMMIT`: the full 40-character remote commit.

The script accepts only `--environment test|production` and an optional full `--commit`. It requires a clean worktree, the mapped local branch, and equality between local HEAD and `origin/<branch>`. It posts to `buildWithParameters` using `JENKINS_USER_ID` and `JENKINS_API_TOKEN` from the private profile, validates every queue/build URL before reusing credentials, follows the queue to the concrete build, prints `consoleText`, and returns nonzero unless the final result is `SUCCESS`.

The Jenkinsfile independently rejects mismatched environment/branch pairs and commits that differ after checkout. This keeps source selection enforced on both sides of the API boundary.

## Release Cleanup

Deployment creates a versioned candidate and records the previous release. Health failure invokes rollback and skips cleanup. After successful health, mark the release successful and run cleanup. Retain five successful releases by default, always protect current and previous, use modification time or a numeric identifier rather than lexical version ordering, and refuse symlinks or paths outside the releases directory.
