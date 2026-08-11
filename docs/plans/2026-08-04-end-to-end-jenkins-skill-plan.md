# End-to-End Jenkins Skill Implementation Plan

> Execute continuously. Preserve existing audit behavior, add guarded mutation, and verify each layer before claiming completion.

**Goal:** Make `implementing-jenkins-cicd` capable of taking minimal project and environment information through Jenkins installation, controller-matched CLI operation, project-specific Pipeline generation, job configuration, and verified non-production delivery.

**Architecture:** A Python 3.13 discovery/planning/rendering layer produces deterministic JSON and staged assets. Shell adapters perform Docker, SSH, Jenkins CLI, and verification operations. Every remote or persistent write is bound to the SHA-256 identifier of a reviewed plan. Existing read-only audit remains a separate safe path.

## Task 1: Specify the Skill Contract

- Update `SKILL.md` with minimal-input workflow, automatic discovery, question gates, provisioning, guarded apply, and verification.
- Add focused operational references for installation, CLI mutation, generated assets, credentials, agents, and rollback.
- Update agent metadata so the Skill is discoverable for Jenkins installation as well as CI/CD implementation.

## Task 2: Test Project Discovery and Plan Integrity

- Add fixtures for Node, Maven, Gradle, Docker, and mixed repositories.
- Write failing tests for manifest detection, command derivation, secret-safe output, stable plan IDs, and material-change plan invalidation.
- Implement `inspect-project.py` and `plan-jenkins.py` until tests pass.

## Task 3: Test and Implement Guarded Jenkins CLI

- Write failing tests for read/write allowlists, exact plan approval, URL validation, environment-only authentication, temporary JAR cleanup, standard error paths, and signal cleanup.
- Implement `jenkins-cli-safe.sh` while preserving `jenkins-readonly-audit.sh`.

## Task 4: Test and Implement Asset Rendering

- Write failing tests for Node, Maven/Gradle, and Docker Pipeline generation.
- Assert generated assets contain build/test, artifact identity, bounded timeouts, health failure, rollback, post-success retention cleanup, AI/CLI-only triggering, `dev` to test and `main` to production mapping, credential IDs, and no credential values.
- Implement `render-jenkins-assets.py` and templates for Jenkinsfile, deployment scripts, Docker Compose, JCasC, plugins, and job XML.
- Require exact plan approval for writes into an existing project or installation directory; preview output remains read-only with respect to those targets.

## Task 5: Test and Implement Controller Provisioning

- Write command-level tests with mocked Docker, SSH, SCP, and filesystem targets.
- Implement `install-jenkins-docker.sh` for existing Docker on local macOS/Linux and remote POSIX Linux.
- Record the official LTS JDK 21 image and resolved digest, persist Jenkins home, avoid host Docker socket mounting, and retain recoverable pre-change configuration backups.
- Do not silently install Docker Desktop. Treat Linux Docker Engine installation as a separately planned mutation.

## Task 6: Test and Implement Jenkins Job Application

- Add a wrapper for create/update decisions that exports current job XML before update.
- Render Pipeline-from-SCM job XML from the plan.
- Keep job triggers empty. Have the Skill verify the pushed remote commit, submit parameterized builds through the matched CLI, map `dev` to test and `main` to production by default, and wait for the final Jenkins result. Do not generate a project trigger script.
- Apply via guarded CLI and support an approved verification build.
- Ensure failed create/update/build returns nonzero and keeps recovery evidence private.
- Verify release cleanup runs only after successful health and activation, keeps at least current plus previous, defaults to five releases, and rejects unsafe paths.

## Task 7: Verification and Documentation

- Run all existing and new unit tests.
- Run the Skill validator.
- Run shell syntax checks and Python compilation.
- Scan generated examples and the Skill tree for embedded test secrets and forbidden host Docker socket mounts.
- Run a mocked end-to-end scenario from discovery through plan, render, install command, job apply, and verification.
- If a local disposable Jenkins controller is available without risking user state, run read-only integration checks; do not mutate an existing controller merely to test the Skill.

## Completion Evidence

- Test output showing every suite passes.
- Validator output showing the Skill is structurally valid.
- A generated sample bundle demonstrating the minimal-input flow.
- File inventory and concise usage example in the final handoff.
