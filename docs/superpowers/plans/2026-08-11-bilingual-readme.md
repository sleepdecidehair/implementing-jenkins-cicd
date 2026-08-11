# Bilingual README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish a detailed English and Simplified Chinese `README.md` that accurately documents the repository's guarded Jenkins CI/CD workflows without exposing credentials or adding behavior.

**Architecture:** Create one top-level README with an English operating guide followed by a semantically equivalent Chinese guide. Both sections point to existing scripts, templates, and references as their source of truth; a final validation pass checks structure, local links, secret-pattern absence, end-to-end behavior, and public remote parity.

**Tech Stack:** GitHub-flavoured Markdown, Bash, Git, GitHub CLI, existing Python/Bash/Perl skill scripts.

## Global Constraints

- Modify only `README.md` for the documentation deliverable; do not alter runtime scripts, templates, Jenkins configuration, or deployment behavior.
- Keep English and Simplified Chinese sections semantically equivalent; commands, paths, options, environment variables, and terminal results stay literal.
- Use uppercase non-secret placeholders such as `PROJECT`, `REPOSITORY_URL`, `TEST_HEALTH_URL`, `PRIVATE_JENKINS_TRIGGER_PROFILE`, and `EVIDENCE_DIR`.
- Never include a real API token, private key, password, credential ID, production host, production endpoint, or absolute local workstation path.
- Document explicit-only deployment: no webhook, SCM polling, or push-triggered deployment is enabled by default.
- Document `dev -> test` and `main -> production` as defaults which repository evidence may override.
- Preserve the current absence of a licence grant: say that no `LICENSE` file is present; do not add one.
- Run `bash scripts/test-end-to-end-skill.sh` before the final documentation commit, then push only a clean `main` branch.

---

### Task 1: Create the English Public Operating Guide

**Files:**
- Create: `README.md`
- Reference: `SKILL.md`
- Reference: `references/provisioning-and-cli.md`
- Reference: `references/audit-and-design.md`
- Reference: `references/ai-triggered-delivery.md`
- Reference: `references/server-pull-templates.md`
- Reference: `references/security-and-operations.md`
- Reference: `references/deployment-patterns.md`

**Interfaces:**
- Consumes: command contracts in `SKILL.md`, `references/`, `assets/templates/`, and `scripts/`.
- Produces: a complete `# English` README section that later receives an equivalent `# 中文` section without changing paths or command syntax.

- [ ] **Step 1: Verify the English README is absent (RED)**

Run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
test -f README.md
```

Expected: exit status `1`, because the repository has no top-level README yet.

- [ ] **Step 2: Add the English section and complete operating guide**

Create `README.md` with this exact opening contract:

```markdown
# Implementing Jenkins CI/CD

> Guarded Jenkins installation, configuration, and explicit CI/CD delivery with exact commit provenance, health checks, rollback, and release retention.

[English](#english) | [简体中文](#中文)

<a id="english"></a>
# English
```

Write detailed English content under these exact headings, in order:

```markdown
## What this repository provides
## Scope and non-goals
## Safety model
## Architecture and delivery models
## Prerequisites and minimum inputs
## Quick decision guide
## Workflow A: provision a new controller
## Workflow B: connect an existing controller
## Workflow C: render and operate server-pull delivery
## Explicit test and production deployment
## Release lifecycle, health checks, rollback, and cleanup
## Script and reference catalogue
## Configuration and credential boundaries
## Verification and test suite
## Troubleshooting
## Repository layout
## Contributing
## Licence status
```

The content must cover each concrete item below.

1. Explain controller-versus-agent responsibility, JCasC, pinned Jenkins LTS/JDK 21 image and plugins, persistent storage, controller zero executors, separate SSH agent, loopback-only plain HTTP, and the prohibition on default Docker-socket mounting.
2. Compare immutable-artifact and server-pull delivery in a Markdown table with source movement, build location, and selection criteria. State that one Job chooses one boundary and server-pull proves its named branch resolves to `EXPECTED_COMMIT`.
3. Show the discovery, planning, rendering, project-asset approval, and orchestration sequence using `SKILL_DIR`, `PROJECT`, `REPOSITORY_URL`, distinct test/production hosts and roots, health URLs, private key paths, and `PLAN_ID`. Link to `references/provisioning-and-cli.md` for the complete option list.
4. Explain the existing-controller flow: read-only audit, private administrator profile, security-warning block, restore-tested backup evidence, pinned plugin reconciliation, deterministic Job application, prior XML protection, and verification. Link to `references/audit-and-design.md` and `references/provisioning-and-cli.md`.
5. Include the complete illustrative secret-free JSON from `references/server-pull-templates.md`; explain `branches`, `source_roots`, `deploy_roots`, `commands`, `artifact_paths`, `health_urls`, `execution`, `release_retention`, and `clean_excludes`; identify the reference document as the schema authority.
6. Show renderer, `bash -n`, rendered-bundle verification, `--print-plan-id`, project-trigger commit/push, Job application, server-script installation, and server-pull verification. Separate administrator-profile setup from trigger-profile deployment.
7. Show `./ops/jenkins/trigger-deploy.sh --environment test` and `./ops/jenkins/trigger-deploy.sh --environment production`; explain its clean-worktree, branch, pushed remote commit, queue/build URL, and terminal `SUCCESS` checks.
8. Describe `DEPLOY_ROOT/releases`, atomic `DEPLOY_ROOT/current` switching, bounded health retries, previous-release rollback, post-success-only cleanup, retention of five successful releases by default, and permanent protection for current and previous releases.
9. Catalogue every non-test operational script in `scripts/` with its responsibility and key safety boundary. Catalogue all six `references/*.md` documents with their intended use, and list test scripts under verification.
10. Add safe troubleshooting rows for missing profiles, unpushed/local commit mismatch, security-baseline failure, unavailable node label, strict SSH host-key failure, health failure/rollback, invalid server-pull hash, and a Jenkins result other than `SUCCESS`.
11. Add a repository tree for `SKILL.md`, `assets/`, `references/`, `scripts/`, `docs/`, and `agents/openai.yaml`; explain that `SKILL.md` is the operational contract and `agents/openai.yaml` registers the skill with Codex.
12. State that contributions must preserve tests and update both language sections, and that no `LICENSE` file currently grants reuse rights.

- [ ] **Step 3: Validate English headings, paths, and secret-free examples (GREEN)**

Run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
bash -ceu '
required_headings=("## What this repository provides" "## Workflow A: provision a new controller" "## Workflow B: connect an existing controller" "## Workflow C: render and operate server-pull delivery" "## Explicit test and production deployment" "## Script and reference catalogue" "## Troubleshooting" "## Licence status")
for heading in "${required_headings[@]}"; do rg -Fqx "$heading" README.md; done
required_paths=(SKILL.md references/provisioning-and-cli.md references/audit-and-design.md references/ai-triggered-delivery.md references/server-pull-templates.md references/security-and-operations.md references/deployment-patterns.md)
for path in "${required_paths[@]}"; do rg -Fq "$path" README.md; test -f "$path"; done
if rg -n "(BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|sk-[A-Za-z0-9_-]{20,})" README.md; then exit 1; fi
'
```

Expected: exit status `0`; all English landmarks and paths exist, and no credential-like token is found.

- [ ] **Step 4: Review and commit the English baseline**

Run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
git diff --check
git diff -- README.md
git add README.md
git commit -m "docs: add English Jenkins CI/CD guide"
```

Expected: one documentation-only commit containing the English baseline and no whitespace errors.

### Task 2: Add a Semantically Equivalent Simplified Chinese Guide

**Files:**
- Modify: `README.md`
- Reference: `docs/superpowers/specs/2026-08-11-bilingual-readme-design.md`
- Reference: `references/server-pull-templates.md`

**Interfaces:**
- Consumes: the English section from Task 1, including every literal command and safety rule.
- Produces: a `# 中文` section that mirrors English content, links, examples, and restrictions.

- [ ] **Step 1: Verify that the Chinese guide is absent (RED)**

Run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
rg -Fqx '# 中文' README.md
```

Expected: exit status `1`, because Task 1 contains the English baseline only.

- [ ] **Step 2: Add the Chinese section with equivalent content**

Append this exact boundary after the English guide:

```markdown
---

<a id="中文"></a>
# 中文
```

Use these exact Chinese headings in English-heading order:

```markdown
## 本仓库提供的能力
## 范围与非目标
## 安全模型
## 架构与交付模型
## 前置条件与最小输入集
## 快速决策指南
## 工作流 A：部署新的 Jenkins Controller
## 工作流 B：接入既有 Jenkins Controller
## 工作流 C：渲染并运行 Server-pull 交付
## 显式部署测试与生产环境
## 发布生命周期、健康检查、回滚与清理
## 脚本与参考文档索引
## 配置与凭据边界
## 验证与测试套件
## 故障排查
## 仓库结构
## 贡献
## 许可证状态
```

Translate all prose, tables, warnings, and troubleshooting actions. Copy shell and JSON commands byte-for-byte from English except prose comments. Keep `SKILL_DIR`, `PROJECT`, `PLAN_ID`, `DEPLOY_ENV`, `GIT_REF`, `EXPECTED_COMMIT`, `SUCCESS`, script paths, options, JSON keys, `dev`, `main`, `test`, and `production` unchanged. Preserve the explicit-only trigger, no-secret, exact-commit, separate-profile, strict-host-key, health-gated activation, rollback, and minimum-two-release rules.

- [ ] **Step 3: Validate the bilingual contract (GREEN)**

Run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
bash -ceu '
test "$(rg -Fxc "# English" README.md)" -eq 1
test "$(rg -Fxc "# 中文" README.md)" -eq 1
required_headings=("## 本仓库提供的能力" "## 工作流 A：部署新的 Jenkins Controller" "## 工作流 B：接入既有 Jenkins Controller" "## 工作流 C：渲染并运行 Server-pull 交付" "## 显式部署测试与生产环境" "## 脚本与参考文档索引" "## 故障排查" "## 许可证状态")
for heading in "${required_headings[@]}"; do rg -Fqx "$heading" README.md; done
for literal in DEPLOY_ENV GIT_REF EXPECTED_COMMIT SUCCESS scripts/render-server-pull-templates.py references/server-pull-templates.md; do test "$(rg -Fc "$literal" README.md)" -ge 2; done
'
```

Expected: exit status `0`; both language roots and Chinese landmarks exist, and key operational literals occur in each guide.

- [ ] **Step 4: Review parity and commit the Chinese guide**

Confirm side by side that every English command, branch-mapping caveat, safety constraint, and troubleshooting outcome is represented in Chinese without changing literal identifiers. Then run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
git diff --check
git diff -- README.md
git add README.md
git commit -m "docs: add Chinese Jenkins CI/CD guide"
```

Expected: one documentation-only commit containing the Chinese mirror.

### Task 3: Validate, Publish, and Verify the Public Documentation

**Files:**
- Verify: `README.md`
- Verify: `scripts/test-end-to-end-skill.sh`
- Verify: every local repository path linked by `README.md`

**Interfaces:**
- Consumes: both committed README language sections.
- Produces: a clean, tested `main` branch whose public GitHub repository renders the completed README.

- [ ] **Step 1: Run structural, local-path, credential-pattern, and diff checks**

Run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
bash -ceu '
test -f README.md
test "$(rg -Fxc "# English" README.md)" -eq 1
test "$(rg -Fxc "# 中文" README.md)" -eq 1
required_paths=(SKILL.md agents/openai.yaml assets/templates/deploy-from-git.sh.tmpl assets/templates/trigger-deploy.sh.tmpl references/provisioning-and-cli.md references/audit-and-design.md references/ai-triggered-delivery.md references/server-pull-templates.md references/security-and-operations.md references/deployment-patterns.md scripts/inspect-project.py scripts/plan-jenkins.py scripts/render-jenkins-assets.py scripts/orchestrate-jenkins-delivery.sh scripts/jenkins-readonly-audit.sh scripts/configure-jenkins-plugins.sh scripts/apply-jenkins-job.sh scripts/render-server-pull-templates.py scripts/apply-server-pull-job.sh scripts/install-server-pull-script.sh scripts/verify-server-pull-delivery.sh scripts/verify-jenkins-delivery.sh)
for path in "${required_paths[@]}"; do rg -Fq "$path" README.md; test -e "$path"; done
if rg -n "(/Users/|BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|sk-[A-Za-z0-9_-]{20,})" README.md; then exit 1; fi
'
git diff --check HEAD~2..HEAD
```

Expected: exit status `0`; both guides are present, every advertised local file exists, and no absolute local path or common credential-token pattern is present.

- [ ] **Step 2: Run the repository end-to-end suite**

Run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
bash scripts/test-end-to-end-skill.sh
```

Expected: exit status `0` and final output `PASS: end-to-end Jenkins skill`.

- [ ] **Step 3: Commit a necessary final README-only correction, push, and prove remote parity**

If validation requires a README correction, apply it, rerun Steps 1 and 2, and commit with `git commit -am "docs: verify bilingual README"`. Do not create an empty commit. Then run:

```bash
cd /Users/im10furry/.codex/skills/implementing-jenkins-cicd
git status --short
git push origin main
local_commit="$(git rev-parse HEAD)"
remote_commit="$(git ls-remote origin refs/heads/main | awk 'NR == 1 {print $1}')"
test "$local_commit" = "$remote_commit"
gh repo view sleepdecidehair/implementing-jenkins-cicd --json url,isPrivate,defaultBranchRef --jq '"url=\(.url) public=\(.isPrivate | not) default_branch=\(.defaultBranchRef.name)"'
```

Expected: clean status output, successful push, matching local/remote `main` commits, `public=true`, and `default_branch=main`.
