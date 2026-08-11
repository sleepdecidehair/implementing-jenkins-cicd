# End-to-End Jenkins Delivery Skill Design

**Date:** 2026-08-04

## Goal

Upgrade `implementing-jenkins-cicd` from a read-only audit and advisory skill into a guided execution skill that can:

1. inspect a project and deployment environment;
2. install or connect to a Docker-based Jenkins controller;
3. obtain that controller's matching Jenkins CLI temporarily;
4. configure plugins, controller settings, credentials references, and jobs;
5. generate source-controlled Pipeline and deployment assets;
6. run a non-production build and verify deployment and rollback behavior;
7. leave reproducible evidence without retaining secrets or the CLI JAR.

The normal user experience should require only a project path or repository, a Jenkins target, and deployment destination information. Detectable details are discovered automatically.

## User Interaction Contract

The skill asks one question at a time and only when an answer cannot be safely discovered or when a critical mutation is about to occur.

Questions are allowed at these gates:

- the project contains multiple plausible applications or build commands;
- the target operating system or deployment topology is unsupported or ambiguous;
- a required credential ID or secret source is unknown;
- an existing Jenkins job, controller configuration, or repository file would be replaced;
- the first test deployment is ready to run;
- a production build, deployment, traffic switch, rollback, restart, plugin installation, or controller upgrade is ready to run;
- cleanup would delete releases, volumes, jobs, or other persistent data.

The skill does not ask about values it can reliably derive from manifests, lockfiles, Jenkins metadata, Docker, SSH, Git, or existing deployment scripts. A production deployment always has its own approval and is never bundled into installation approval.

## Supported Scope for Version 1

### Jenkins targets

- existing Jenkins reachable over HTTP or HTTPS;
- new local Docker Jenkins on macOS or Linux when Docker is already available;
- new remote Docker Jenkins on a POSIX Linux host reached by SSH;
- controller data persisted in a named volume or an explicitly selected host path.

Windows Docker Desktop, native package installations, Kubernetes, and remote Windows services are discovery-only in version 1. The skill explains the gap instead of improvising an untested installation path.

### Project types

- Node.js projects using npm, pnpm, or Yarn lockfiles;
- Maven and Gradle JVM projects;
- Dockerfile and Docker Compose projects;
- mixed repositories and monorepositories when application roots are unambiguous;
- generic projects with repository-provided build and deployment scripts.

Unknown projects receive an evidence report and one focused build-command question. The skill must not invent a successful build path.

## Workflow

### 1. Discover

Collect read-only evidence from the project, Git state, local or SSH host, Docker, open ports, and any existing Jenkins controller. Inspect repository instructions before manifests and scripts. Detect application roots, package managers, runtime versions, build/test commands, artifacts, health endpoints, deploy targets, branch conventions, and existing release/rollback behavior.

Write a machine-readable discovery document. Every field records its source and confidence so inferred values cannot silently become facts.

### 2. Plan

Create a deterministic change plan containing:

- target host and Jenkins URL;
- resolved controller image and Java line;
- ports, data storage, backup path, and agent topology;
- required plugins and their reason;
- files to create or change;
- Jenkins jobs and configuration to create or update;
- build, deployment, health-check, and rollback commands;
- pre-change backup, verification, and recovery operations;
- a SHA-256 plan identifier.

Discovery and planning are read-only. Applying a plan requires the user to approve its exact identifier, preventing a later changed plan from reusing earlier approval.

### 3. Provision or Connect

For a new controller, use the official `jenkins/jenkins` LTS JDK 21 image by default. Resolve and record the pulled image digest. Generate Docker Compose and Jenkins Configuration as Code assets under a user-selected installation directory. Use a persistent volume, health checks, restart policy, resource guidance, and a private environment file when needed.

Do not mount the host Docker socket by default. Projects that build containers use a dedicated agent or an explicitly approved isolated Docker-in-Docker/TLS design. Do not silently install Docker Desktop. Installing Docker Engine on a remote Linux host is a separate approved operation.

For an existing controller, perform version, identity, permission, plugin, and security-floor preflight checks before any write.

### 4. Open a Controller-Matched CLI Session

Download `${JENKINS_URL}/jnlpJars/jenkins-cli.jar` into a private temporary directory, use WebSocket transport by default, authenticate through `JENKINS_USER_ID` and `JENKINS_API_TOKEN`, and delete the JAR on success, failure, or interruption.

The CLI wrapper has two command classes:

- read commands may run during discovery;
- write commands require the approved plan identifier and are allowlisted per operation.

The wrapper rejects credentials embedded in URLs or command arguments. It discovers available commands with `help` because CLI capabilities vary with core and plugins.

### 5. Generate Project Delivery Assets

Generate or update, with a previewed diff:

- `Jenkinsfile` or a clearly named environment-specific Jenkinsfile;
- `ops/jenkins/deploy.sh`;
- `ops/jenkins/health-check.sh`;
- `ops/jenkins/rollback.sh`;
- `ops/jenkins/cleanup-releases.sh`;
- optional job XML, JCasC fragments, and plugin lock metadata outside the application runtime path;
- a concise operator README describing required Jenkins credential IDs and rollback.

For explicitly AI-triggered deployment jobs, apply a deterministic inline copy of the reviewed Jenkinsfile so the test branch can be bootstrapped before that file exists remotely. Use Multibranch Pipeline separately for branch or pull-request validation workflows. Build once and deploy the same immutable artifact. Record commit SHA, build number, checksum, and container digest when applicable. Never place credential values in repository-tracked generated files.

The default delivery trigger is an explicit user instruction to the AI, not an SCM push and not a project-owned trigger program. The generated Jenkins job has no GitHub webhook, SCM polling, or push trigger. The user first pushes the intended commit, then asks the AI to deploy test or production. The AI verifies that the remote branch contains the intended commit and uses the controller-matched Jenkins CLI to submit and follow the parameterized build through its final result.

The default mapping is `dev` to test and `main` to real production. Repository instructions or observed live configuration may override this mapping; for example, the current `zhatu` frontend production job uses `master` while its backend uses `main`. Such a difference remains explicit in the generated plan. Other branches are rejected by default. An explicit user request to deploy production is itself the deployment approval; an ambiguous request is not.

The target architecture checks source out from GitHub on a Jenkins build agent, builds one immutable artifact, and transfers that artifact to the deployment server. It does not upload the developer's uncommitted local workspace and does not make the deployment server clone or pull source. Existing freestyle jobs that currently pull GitHub on the Jenkins host can be operated during migration, but their observed behavior must not be confused with the target design.

Existing files are never overwritten silently. The plan includes their hashes and the apply phase verifies that they have not changed since approval.

### 6. Configure Jenkins

Use the smallest appropriate mechanism:

- JCasC for reproducible controller settings;
- Jenkins CLI `create-job` or `update-job` for bounded job changes;
- the Remote Access API only when a required operation is not safely available through CLI or JCasC;
- Jenkins Credentials or an approved secret store for secret material.

Before a job update, export its current XML to a private backup. Before controller configuration changes, back up the relevant JCasC and Jenkins home state. API-token-authenticated POST requests are used where REST mutation is necessary.

### 7. Verify

Verification is layered:

1. lint and syntax-check generated YAML, XML, shell, Pipeline, and Compose files;
2. run repository-native tests and a production build locally or in an isolated agent where practical;
3. validate Jenkins authentication, permissions, plugins, job configuration, and agent availability;
4. trigger an approved non-production build and follow it to completion;
5. verify artifact identity and the deployed health endpoint;
6. exercise negative health behavior and a rollback in a safe target;
7. after successful health verification and traffic/current-link switching, prune surplus successful releases;
8. verify that temporary JARs, raw evidence, and secret-bearing temporary files were removed.

Installation success is not inferred from a running container alone. A usable result requires controller readiness, authenticated CLI access, a valid job, and a completed verification build unless the user explicitly limits the task.

## Components

The upgraded skill will retain its current read-only audit tools and add:

- `scripts/inspect-project.py` — Python 3.13 project and deployment discovery;
- `scripts/plan-jenkins.py` — validates discovery and creates a hashed change plan;
- `scripts/install-jenkins-docker.sh` — local or SSH Docker controller provisioning;
- `scripts/jenkins-cli-safe.sh` — temporary matched CLI lifecycle and guarded read/write commands;
- `scripts/render-jenkins-assets.py` — renders Pipeline, deployment, JCasC, Compose, and job assets;
- `scripts/verify-jenkins-delivery.sh` — controller, job, build, health, cleanup, and rollback checks;
- `assets/` — Compose, JCasC, plugin, Pipeline, and job templates;
- focused tests for each component plus a mocked end-to-end test.

Python helper code targets Python 3.13 unless an inspected project requires a different runtime for its own build.

## Security and Recovery Invariants

- Tokens and passwords are accepted through environment variables, protected files, or Jenkins credential entry, never positional command arguments.
- Generated configuration contains credential IDs or secret-source expressions, never secret values.
- Files containing sensitive metadata use mode `0600`; private directories use `0700`.
- Jenkins home is backed up before risky controller changes; job XML is backed up before job changes.
- An approved plan cannot apply if the target, source files, or prior configuration changed after approval.
- Builds run on dedicated agents, not the built-in controller executor.
- Existing deployment paths remain available until the replacement passes build, deployment, health, and rollback gates.
- Failed deployments never prune release history. Cleanup runs only after the new release is healthy and active, defaults to retaining the five newest successful releases, and always protects the active and immediately previous known-good release. Retention is configurable but may not be lower than two.
- Cleanup validates the releases root, accepts only generated release identifiers, refuses symlink escape, and never recursively deletes an unresolved path, filesystem root, home directory, workspace root, current target, or previous rollback target.
- Production and test targets use separate credentials and cannot be selected solely by unvalidated user input.
- Plugin health scores are not treated as installed-version security evidence; installed versions are compared with current Jenkins advisories.

## Acceptance Criteria

Version 1 is complete when automated tests demonstrate that the skill can:

1. inspect representative Node, Maven/Gradle, Docker, and mixed projects;
2. generate a stable plan from the same evidence and a different hash when a material input changes;
3. refuse writes without an exact approved plan identifier;
4. provision a reproducible Docker Jenkins configuration without mounting the host Docker socket;
5. download and clean up a controller-matched CLI JAR on success, error, and signal;
6. create or update a Pipeline job while retaining a restorable prior configuration;
7. generate deployment, health, and rollback scripts without embedding secrets;
8. create jobs without SCM/webhook triggers and let the AI trigger and follow `dev` as test or `main` as production only after confirming the intended commit was pushed;
9. prune only surplus successful releases after health passes, while preserving current and previous releases;
10. fail verification when tests, builds, health checks, or required cleanup fail;
11. preserve the existing read-only audit behavior and its tests;
12. guide a real project from minimal inputs to a verified non-production Jenkins build.

## Non-Goals

- automatically creating third-party accounts, DNS records, certificates, or cloud resources without separate authority;
- bypassing Jenkins permissions, host security policy, or repository protection rules;
- storing a permanent universal Jenkins CLI JAR;
- automatically deploying to production as part of installation;
- claiming arbitrary projects are supported when no reliable build or deployment evidence exists.
