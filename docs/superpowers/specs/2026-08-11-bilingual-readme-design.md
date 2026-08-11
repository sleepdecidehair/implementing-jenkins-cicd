# Bilingual README Design

## Objective

Add a public, detailed, bilingual `README.md` that lets an English- or Chinese-speaking operator understand what this Jenkins CI/CD skill does, choose the correct delivery model, run the supported workflows safely, and locate deeper reference material without reading implementation code first.

The README is an entry point and operating guide. It must accurately describe the repository's current behavior; it must not introduce a new deployment model, change the skill contract, or imply that a command is safe without the review and approval gates enforced by the scripts.

## Audience

- Platform engineers installing a new Jenkins controller.
- Operators connecting an existing controller to a project.
- Application owners adapting the server-pull templates to a repository and a deployment host.
- Codex users who need to know when to invoke the skill and what evidence to provide.
- Security reviewers checking credential separation, commit provenance, rollout, and rollback guarantees.

The document assumes shell, Git, Jenkins, and deployment-host familiarity. It explains repository-specific terms and links to the authoritative scripts and references instead of duplicating their full source.

## Information Architecture

The README has two complete, parallel language sections. English is first for GitHub's broadest audience; Simplified Chinese follows under a clearly linked heading. Each section uses the same ordering, concepts, paths, commands, and safety caveats. The top navigation links to both language sections and all major topics.

### English section

1. Title, concise value statement, and navigation.
2. Scope, supported workflows, and explicit non-goals.
3. Safety model: explicit deployment requests, clean pushed commits, least-privilege profiles, verified SSH host keys, health checks, rollback, and safe cleanup.
4. Architecture diagram in text form, showing the operator, repository, Jenkins controller/agent, deployment host, and release directory.
5. Delivery-model comparison: immutable artifact handoff versus server-pull of a verified remote commit; the latter is the repository's reusable rendered-template path.
6. Prerequisites and the minimum input set needed before configuration.
7. New-controller workflow with the existing discovery, planning, rendering, orchestration, and verification commands.
8. Existing-controller workflow, including read-only audit, plugin reconciliation, saved job XML, and controlled job application.
9. Server-pull workflow: JSON mapping, rendering, generated files, Job application, server-script installation, and explicit test/production trigger.
10. Deployment lifecycle: branch-to-environment mapping, exact commit validation, CI phases, versioned releases, health checks, atomic activation, rollback, and retention.
11. Script/reference catalogue with purpose and the most important input/output contract for every operational script.
12. Testing and verification commands, troubleshooting table, repository map, contributing guidance, and licence-status notice.

### Simplified Chinese section

The Chinese section mirrors the English content, including commands unchanged and explanatory text translated. Safety-sensitive terms such as `EXPECTED_COMMIT`, `known_hosts`, `DEPLOY_ROOT/current`, `SUCCESS`, and `main` remain literal where changing them would harm copy/paste correctness.

## Command Examples

Examples are intentionally representative rather than environment-specific. They use uppercase placeholders such as `PROJECT`, `EVIDENCE_DIR`, `PRIVATE_JENKINS_TRIGGER_PROFILE`, `SSH_CREDENTIAL_ID`, and `HEALTH_URL`.

No README example contains a real API token, private key, host, repository URL, credential ID, or password. It explains where a value belongs (private environment/profile, Jenkins credential store, or safe JSON mapping) and where it must not appear (Git history, command URL, rendered project bundle, or public documentation).

The README distinguishes these boundaries:

| Boundary | README treatment |
| --- | --- |
| Planning and configuration | Document command shape and required review/approval, but do not assert that an arbitrary plan is safe to apply. |
| Deployment triggering | Show that the operator first pushes a clean commit and then explicitly requests a named environment. |
| Credentials | Describe identities and credential IDs; never print values or embed them in shell command lines. |
| Infrastructure choices | State only the supported Docker/JCasC/SSH-agent setup and avoid recommending unreviewed topology changes. |

## Accuracy and Maintenance Rules

- Commands must be copied from current `SKILL.md` or script `--help` output and use paths that exist in the repository.
- Claims about a script's safeguards must be traceable to its source or an existing reference document.
- The server-pull configuration field list must be presented as an overview and point to `references/server-pull-templates.md` as the complete contract.
- The README must say that repository evidence can override the default `dev -> test` and `main -> production` mapping.
- It must not claim a licence grant: the repository currently has no `LICENSE` file.
- English and Chinese sections must remain semantically equivalent; a content change in one requires the corresponding change in the other.

## Validation

Before committing the README:

1. Check every linked local path exists and every documented executable script is present.
2. Run Markdown-oriented structural checks: headings, language anchors, relative links, and placeholder-only credential examples.
3. Run `bash scripts/test-end-to-end-skill.sh`; documentation must not alter behavior, and the existing end-to-end suite must remain green.
4. Review the diff for accidental credentials, absolute local paths, unsupported claims, untranslated safety content, and malformed command blocks.
5. Confirm the repository is clean after committing and that the pushed `main` commit matches the remote branch.

## Out of Scope

- Adding a licence, release automation, screenshots, badges, GitHub Actions, or new functional code.
- Replacing the existing detailed reference documents.
- Enabling webhook, polling, or automatic push-triggered deployment.
- Publishing real deployment credentials, production endpoints, or organisation-specific configuration.
