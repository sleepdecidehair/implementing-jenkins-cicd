# Audit and Design Workflow

## 1. Define the Evidence Boundary

Record the Jenkins controller, authenticated identity, audit time, repository revision, environments, and whether evidence is live or a snapshot. Use read-only access first. Never retrieve Jenkins credential values.

Prefer a controller-matched CLI JAR from `JENKINS_URL/jnlpJars/jenkins-cli.jar`. Treat it and all raw job XML or console logs as temporary sensitive material. The bundled script requires Bash, curl, Java, Perl, and a SHA-256 utility. It stores only best-effort redacted extracts in a private output directory; still treat those extracts as sensitive, scan and review them before sharing, and delete them when no longer needed. The script allowlists:

- `who-am-i`
- `version`
- `list-jobs`
- `list-plugins`
- `get-job`
- `console`

The script intentionally cannot trigger, create, update, disable, delete, restart, or install anything. It publishes output only after all reads succeed, gives each job a hash-suffixed filename to prevent collisions, and removes the raw directory, partial output, and CLI JAR on failure or interruption. Review foldered jobs manually if the controller's `list-jobs` output does not enumerate nested paths.

## 2. Inspect the Repository and Runtime

Read project instructions before proposing changes. Locate:

- build/test manifests and lockfiles;
- branch and environment rules;
- Jenkinsfile or job bootstrap code;
- scripts transitively invoked by Jenkins;
- Dockerfiles, Compose files, service units, reverse proxy configuration;
- database migration and backup procedures;
- deployment copies outside the repository.

Hash duplicate scripts. A matching filename does not establish equivalence or authority.

## 3. Build One Row Per Delivery Path

Capture:

| Field | Evidence to collect |
| --- | --- |
| Trigger | manual, webhook, SCM poll, schedule, upstream job, remote API |
| Source | repository, credential ID, ref, checkout implementation |
| CI | dependency install, lint, unit/integration tests, build, scan |
| Artifact | directory, archive, package, image tag/digest, checksum |
| Deploy | target, account, directory/service/cluster, switching method |
| Health | endpoint, expected result, timeout/retry, failure exit status |
| Rollback | retained good version, command, trigger, time limit, proof |

Follow shell error handling across pipelines and subprocesses. Look for `|| true`, warning-only failures, command substitutions that mask nonzero statuses, skipped tests, stale worktrees, mutable tags, and destructive replacement before health succeeds.

## 4. Reconcile Three States

Keep separate sections for:

1. **Observed current state** — supported by live config/log/runtime evidence.
2. **Source and policy expectation** — supported by version-controlled files.
3. **Proposed target state** — an explicit recommendation.

For every disagreement, record impact, owner, evidence needed, and which action it blocks. Never silently choose one side.

## 5. Produce a Phased Plan

Prioritize:

1. credential exposure and unsafe privilege;
2. false-success behavior and missing recovery;
3. quality gates and artifact traceability;
4. configuration drift and maintainability;
5. delivery optimizations.

Keep the known working path available while the replacement is exercised. Define GO/NO-GO checks for every phase and a bounded rollback path.

Official references: [Pipeline as Code](https://www.jenkins.io/doc/book/pipeline/jenkinsfile/), [Remote Access API](https://www.jenkins.io/doc/book/using/remote-access-api/).
