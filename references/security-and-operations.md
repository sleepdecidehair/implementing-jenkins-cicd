# Security and Operations

## Credentials

- Store tokens, keys, passwords, certificates, and secret files in Jenkins Credentials or an approved external secret store.
- Reference credential IDs, never credential values, from source-controlled files.
- Bind secrets only for the shortest stage that needs them and disable shell tracing around secret use.
- Avoid interpolation that places secrets in command arguments, process listings, URLs, workspace files, archived artifacts, or logs.
- Treat masking as best-effort, not a security boundary. Do not run untrusted code beside a stage holding secrets.
- Rotate credentials found in job XML, scripts, source, or logs; deletion alone is insufficient.
- Prefer POST for authenticated remote build requests and restrict network reachability and account permissions.

Official reference: [Credentials Binding](https://www.jenkins.io/doc/pipeline/steps/credentials-binding/).

## Controller and Agent Isolation

Run builds on dedicated least-privilege agents, not the built-in controller node. Separate deployment authority from compilation where possible. Limit filesystem, Docker socket, SSH, `sudo`, and production network access. Make agents disposable when the workload permits.

For Server Pull on a co-located application host, bind the job to one explicit node label and run the installed deployment program as a restricted operating-system account. Give that account access only to its source roots, deployment roots, lock file, repository credential, and narrowly scoped activation action. The Jenkins deployment-trigger account is separate again: it has only `Overall/Read`, `Job/Read`, and `Job/Build`. Neither account is a Jenkins administrator, and neither receives unrestricted `sudo` or the Docker socket.

SSH-managed agents must verify a pinned host public key. Persist the agent host key across container recreation; do not use a non-verifying host-key strategy.

Official reference: [Controller Isolation](https://www.jenkins.io/doc/book/security/controller-isolation/).

## Required Pipeline Controls

Apply controls according to risk:

- disable concurrent deployment to the same target;
- bound stage and pipeline duration;
- discard old builds and manage artifact retention intentionally;
- require approval for production when organizational policy calls for it;
- prevent stale builds from overtaking newer releases;
- preserve tests, checksums, approvals, deployment evidence, and rollback results;
- notify owners on failure and on recovery failure.

Plugins being installed does not prove a job uses their controls. Verify live job or Jenkinsfile configuration.

## Mutation Approval

Before any remote write, show:

1. controller and exact job/environment;
2. operation and expected external effect;
3. credentials or permissions involved, without values;
4. validation command or observable success condition;
5. rollback or recovery action.

Obtain explicit approval before job/credential changes, build triggers, deployments, restarts, traffic switches, rollbacks, plugin changes, or controller administration. Approval for inspection is not approval for mutation.

## Verification Checklist

- Trigger cannot target an unintended environment.
- Branch/ref and artifact identity are visible and immutable.
- Test failures, health failures, timeouts, and maintenance failures make the build fail.
- Secrets are absent from repository, job XML, console output, process arguments, and artifacts.
- Controller is isolated from ordinary builds.
- The candidate and last known good release are distinguishable.
- Rollback has been exercised, timed, and health-verified.
- Temporary CLI JARs, raw audit evidence, and partial output are deleted on success, failure, and interruption, and their absence is checked. Best-effort redacted output remains access-restricted and is reviewed before sharing.
