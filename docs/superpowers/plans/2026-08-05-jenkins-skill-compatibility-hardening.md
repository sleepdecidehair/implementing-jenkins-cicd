# Jenkins Skill Compatibility Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development for every behavior change and superpowers:verification-before-completion before reporting completion. Execute inline because this environment forbids delegation for this task.

**Goal:** Close the Jenkins Skill review gaps while preserving the explicit AI-triggered Server Pull deployment flow.

**Architecture:** Preserve the existing Artifact path and add an approval-bound Server Pull bundle containing scripts, job XML, and a hashed manifest. Extend bounded CLI application and verification around that bundle, split administrator and trigger identities, replace unverified agent SSH, pin dependencies, and harden artifact handling.

**Tech Stack:** Python 3.13, POSIX shell/Bash, Jenkins XML/JCasC, Docker Compose, Jenkins CLI, Remote Access API.

## Global Constraints

- Pushes never deploy; only `ops/jenkins/trigger-deploy.sh` calls the Remote Access API.
- Jenkins CLI configures Jenkins and never invokes `build`.
- Default mapping remains `dev -> test` and `main -> production`.
- Jenkins fetches and proves the exact remote `EXPECTED_COMMIT` before building.
- Cleanup runs only after activation and successful health verification.
- No separate Agent application repository is created.
- No secret value enters plans, manifests, job XML, project files, or logs.

---

### Task 1: Server Pull Bundle Contract

**Files:**
- Modify: `scripts/test-server-pull-templates.sh`
- Modify: `scripts/render-server-pull-templates.py`
- Create: `assets/templates/server-pull-job.xml.tmpl`

**Interfaces:**
- Consumes: schema version 2 Server Pull JSON.
- Produces: `trigger-deploy.sh`, `deploy-from-git.sh`, `job.xml`, and `manifest.json` with `plan_id` and file hashes.

- [x] Add assertions for deterministic `job.xml`, empty triggers, disabled concurrency, assigned node label, absolute deployment script, and manifest approval ID.
- [x] Run `scripts/test-server-pull-templates.sh` and confirm failure because `job.xml` and `plan_id` do not exist.
- [x] Extend configuration validation and deterministic rendering with XML escaping.
- [x] Re-run the focused test and confirm it passes.

### Task 2: Approval-Bound CLI Apply and Script Installation

**Files:**
- Modify: `scripts/test-end-to-end-skill.sh`
- Modify: `scripts/jenkins-cli-safe.sh`
- Create: `scripts/apply-server-pull-job.sh`
- Create: `scripts/install-server-pull-script.sh`
- Create: `scripts/verify-server-pull-delivery.sh`

**Interfaces:**
- Consumes: Server Pull config, rendered bundle, exact `plan_id`, private Jenkins profile.
- Produces: live job evidence, prior job XML, installed-script checksum evidence, and node/job verification evidence.

- [x] Add mocked tests proving changed configuration, changed bundle, wrong approval, arbitrary XML, offline node, and script hash mismatch are rejected.
- [x] Run the focused end-to-end test and confirm the new assertions fail because scripts and CLI mode are absent.
- [x] Implement deterministic CLI input re-rendering, create/update, local/SSH installation, and live verification.
- [x] Re-run the focused test and confirm all new cases pass.

### Task 3: Least-Privilege Controller Identities and Agent Host Verification

**Files:**
- Modify: `scripts/test-end-to-end-skill.sh`
- Modify: `assets/jenkins.yaml.tmpl`
- Modify: `assets/compose.yaml.tmpl`
- Modify: `assets/controller.env.example.tmpl`
- Modify: `scripts/install-jenkins-docker.sh`
- Modify: `scripts/bootstrap-jenkins-cli-profile.sh`

**Interfaces:**
- Consumes: file-backed admin, trigger-user, agent-client, and agent-host secrets.
- Produces: separate admin and trigger profiles plus verified controller-to-agent SSH configuration.

- [x] Add tests forbidding `nonVerifyingKeyVerificationStrategy`, requiring a non-admin trigger user and separate profiles, and requiring persistent agent host keys.
- [x] Confirm the test fails on current templates.
- [x] Add trigger identity permissions, separate token generation, persistent host keys, and pinned host-key verification.
- [x] Confirm the focused and existing tests pass.

### Task 4: Reproducible Baseline and Backup Evidence

**Files:**
- Modify: `scripts/test-end-to-end-skill.sh`
- Create: `assets/plugins.lock.txt`
- Modify: `scripts/plan-jenkins.py`
- Modify: `scripts/render-jenkins-assets.py`
- Modify: `assets/controller.Dockerfile.tmpl`
- Modify: `assets/agent.Dockerfile.tmpl`
- Modify: `scripts/configure-jenkins-plugins.sh`

**Interfaces:**
- Consumes: versioned images, versioned plugin lock, explicit toolchain versions, structured backup evidence JSON.
- Produces: reproducible controller bundle and verified backup gate.

- [x] Add tests that reject mutable image tags, unversioned plugins, `distribution` toolchains, and boolean-only backup claims.
- [x] Confirm failures against current behavior.
- [x] Pin the baseline, use `--latest=false`, validate plugin lock syntax, and validate backup path/hash/timestamp.
- [x] Re-run focused tests.

### Task 5: Artifact and Rollback Safety

**Files:**
- Modify: `scripts/test-server-pull-templates.sh`
- Modify: `scripts/test-end-to-end-skill.sh`
- Modify: `assets/templates/deploy-from-git.sh.tmpl`
- Modify: `scripts/render-jenkins-assets.py`
- Modify: `scripts/verify-jenkins-delivery.sh`

**Interfaces:**
- Consumes: build artifact directory/archive and safe failure-test evidence.
- Produces: validated release content and honest rollback status.

- [x] Add tests for nested symbolic links, archive traversal/link/device entries, absolute lock path, and unexercised rollback status.
- [x] Confirm current implementation fails the new assertions.
- [x] Add recursive validation and safe archive extraction; move lock under the approved deployment root; report rollback exercised only after a real safe failure test.
- [x] Re-run focused tests.

### Task 6: Project Adapters and Documentation Consistency

**Files:**
- Modify: `scripts/test-end-to-end-skill.sh`
- Modify: `scripts/inspect-project.py`
- Modify: `SKILL.md`
- Modify: `references/ai-triggered-delivery.md`
- Modify: `references/provisioning-and-cli.md`
- Modify: `references/security-and-operations.md`
- Modify: `references/server-pull-templates.md`

**Interfaces:**
- Consumes: common project manifests and the selected delivery mode.
- Produces: structured discovery plus a single non-contradictory workflow decision.

- [x] Add fixtures for Python, Go, Rust, and .NET discovery and documentation assertions for the delivery-mode decision table.
- [x] Confirm current discovery tests fail.
- [x] Add conservative manifest adapters and update references without changing the explicit trigger contract.
- [x] Re-run all tests.

### Task 7: Full Verification

**Files:**
- Verify all Skill files.

- [x] Run `scripts/test-server-pull-templates.sh`.
- [x] Run `scripts/test-end-to-end-skill.sh`.
- [x] Run `scripts/test-jenkins-readonly-audit.sh`.
- [x] Run `bash -n scripts/*.sh` and Python 3.13 compilation.
- [x] Run the Skill metadata validator in a temporary Python 3.13 environment using the domestic PyPI mirror.
- [x] Inspect all changed files and map each acceptance criterion to test evidence (the Skill directory is not a Git worktree).
