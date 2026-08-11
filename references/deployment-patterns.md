# Deployment Patterns

Select patterns from verified constraints. Do not prescribe infrastructure the project does not use.

## CI Gates

Derive commands from repository manifests and instructions. A common order is:

1. clean, deterministic checkout;
2. locked dependency installation;
3. static checks and lint;
4. unit tests;
5. integration or contract tests where available;
6. production build/package;
7. artifact checksum, metadata, and archive.

Do not equate compilation with testing. If tests must be skipped temporarily, label that as an accepted gap with an owner and expiry.

## Artifact Handoff

Build once and promote the same immutable output. Attach commit SHA, branch/ref, Jenkins build number, dependency lock state, checksum, and image digest where applicable. Deployment nodes should consume the artifact rather than rebuild or silently pull a different revision.

## Frontend Release Options

- **Versioned directory plus atomic symlink:** suitable for static assets on one or more hosts. Health-check the candidate, switch atomically, retain numerically or chronologically ordered versions, and roll back the symlink.
- **Object/CDN version promotion:** suitable when static hosting already exists. Promote a versioned prefix and retain the previous pointer.
- **Container image:** use only when the project already standardizes frontend delivery as containers.

Never sort version strings lexically when numeric versions can exceed one digit. Validate deletion candidates before cleanup.

## Service Release Options

- **Rolling restart:** acceptable when replicas and orchestrator health semantics exist.
- **Blue/green or candidate port:** useful on a single Docker host or proxy where parallel versions can run. Start candidate, verify readiness and dependencies, switch traffic, then retire old.
- **In-place restart:** use only when downtime is accepted and recovery is fast and rehearsed. Preserve the prior immutable artifact before stopping it.

Do not remove the last healthy instance before the candidate proves ready unless an explicit operational constraint requires it.

## Health and Rollback

Health checks must have explicit success criteria, bounded retries, and nonzero failure. Include service readiness plus one meaningful dependency or smoke path when safe. Avoid treating an authentication error as health unless documented and tested.

Rollback must identify the last known good artifact, restore configuration/traffic, verify health, and record the outcome. Database rollback is separate: prefer backward-compatible migrations, tested backups, and forward repair where destructive reversal is unsafe.

Release cleanup is a post-success maintenance step, never part of candidate preparation. Mark a release successful only after it is active and healthy. Default to five successful releases, preserve the current and immediately previous known-good release, and never allow retention below two. Validate the releases root and every candidate before deletion; cleanup failure must be visible and must not pretend the deployment did not already switch.

## Jenkins Topology

Prefer a reviewed Jenkinsfile for auditability. Keep separate jobs when permissions, approvals, or operational ownership differ; use a parameterized pipeline only when target validation prevents cross-environment deployment. Introduce shared libraries, Job DSL, or configuration-as-code only when reuse and governance justify their maintenance cost.

Do not enable webhook or SCM-poll deployment merely because Pipeline supports it. In AI-triggered operation, the user pushes first, explicitly requests an environment deployment, and the AI runs the repository's generated `ops/jenkins/trigger-deploy.sh`. That script submits the validated remote commit through Jenkins Remote Access API and waits for the final result. Jenkins CLI remains configuration-only.
