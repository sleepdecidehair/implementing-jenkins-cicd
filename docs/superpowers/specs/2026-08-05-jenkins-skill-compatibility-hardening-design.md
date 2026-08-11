# Jenkins Skill Compatibility Hardening Design

## Objective

Close the reviewed execution and security gaps without changing the approved operator flow:

`explicit user request -> project trigger script -> Jenkins Remote Access API -> parameterized Jenkins job -> approved same-host execution node -> exact remote commit -> build -> activate -> health check -> rollback on failure -> cleanup only after success`.

Git pushes never trigger deployment. Jenkins CLI remains configuration-only. Test maps to `dev`, production maps to `main`, unless repository evidence records an explicit override.

## Compatibility Approach

Keep the existing immutable-artifact workflow intact and add a complete, approval-bound Server Pull path. Do not reinterpret Server Pull as a legacy exception. Each plan records one delivery mode and its prerequisites.

The Server Pull renderer produces:

- `trigger-deploy.sh` for source control;
- `deploy-from-git.sh` for installation outside the repository;
- deterministic Jenkins `job.xml` with no automatic triggers;
- `manifest.json` containing an approval identifier and hashes for every rendered file.

The safe CLI re-renders approved XML from the reviewed configuration. It never accepts arbitrary job XML from stdin. A dedicated apply script creates or updates the job, retains prior XML, and verifies the live result. A dedicated install script installs the server deployment program locally or through SSH and verifies its hash.

## Execution Node

The Jenkins Controller keeps zero executors. Server Pull jobs target an explicitly named node label. That node is an execution service, not a separate application or repository.

For a Jenkins controller installed beside the application on Linux, use a restricted OS account on that host. The account owns only its source, release, lock, and workspace paths and receives only the narrowly scoped service activation authority required by the project. It cannot read `JENKINS_HOME`, administer Jenkins, access the Docker socket, or use unrestricted `sudo`.

The Skill verifies the node label and online status before declaring configuration usable. Provisioning a host account is a distinct approved host mutation. Existing suitable Jenkins nodes remain supported.

## Authentication and Authorization

New controllers create separate local identities:

- bootstrap administrator: controller configuration only;
- deployment trigger user: Remote Access API requests only.

The trigger identity receives `Overall/Read`, `Job/Read`, and `Job/Build`, not `Overall/Administer`. The installer writes separate private profiles. The project trigger uses only the trigger profile. Administrative API tokens are never reused for deployment.

Controller-to-agent SSH host verification uses a pinned host key. `nonVerifyingKeyVerificationStrategy` is forbidden. Git host verification continues to use approved `known_hosts` data.

## Reproducibility

Controller and managed container-agent images use versioned tags and may include a registry digest. The approved plan records the exact image references used. Plugin inputs use `artifactId:version`, and the Docker build invokes the plugin manager with `--latest=false`. Agent toolchain versions are plan data; confirming a requirement cannot silently leave the value as `distribution`.

Existing-controller plugin mutation requires structured backup evidence containing an identifier, path, timestamp, and SHA-256 checksum. A boolean confirmation alone is insufficient. Upgrade instructions are separate from fresh installation.

## Deployment Safety

Both delivery modes recursively validate artifact trees. Archive extraction rejects absolute paths, parent traversal, symbolic links, hard links, devices, and unsupported entry types before extraction. Server Pull rejects nested symbolic links before copying artifacts.

The deployment lock lives in an approved absolute lock directory, not process-specific `TMPDIR`. Exact-commit verification, branch mapping, versioned release activation, bounded health checks, rollback, and post-success cleanup remain unchanged.

Rollback is reported as verified only after an intentional safe failure test actually activates the previous release and rechecks health. Configuration-only verification reports rollback as not exercised.

## Documentation Contract

References contain one decision table:

- immutable artifact is the general remote-server default;
- Server Pull is the approved same-host workflow when Jenkins executes through a suitable deployment node.

Project inspection has deterministic adapters for Node, Maven, Gradle, Docker, Python, Go, Rust, and .NET. Unsupported stacks produce a structured manual-command contract instead of an invented build.

## Acceptance Criteria

- Server Pull rendering includes a deterministic job, exact manifest approval identifier, empty triggers, disabled concurrency, node label, and absolute deployment program.
- CLI create/update is bound to the Server Pull configuration and cannot use arbitrary XML.
- The installed deployment script hash matches the approved manifest.
- A non-admin trigger profile can submit and follow builds; the admin profile is not used by the project trigger.
- No generated JCasC disables SSH host verification.
- Images, plugins, and declared toolchains are version-pinned in new-controller plans.
- Backup evidence is machine-validated before existing-controller plugin mutation.
- Nested links and unsafe archive entries are rejected by tests.
- Existing Artifact and read-only audit tests remain green.
- The explicit user-triggered test and production workflow is unchanged.
