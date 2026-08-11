# Server-Pull Jenkins Deployment Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add reusable, secret-free Jenkins trigger and server-side Git deployment templates that Codex can render from inspected project/server facts for explicit test and production delivery.

**Architecture:** Store the two Bash templates under Skill assets and add a small Python renderer with a validated JSON configuration contract. Reuse the trigger asset from the existing Jenkins bundle renderer, while a dedicated renderer produces both scripts for server-pull jobs. Test through temporary Git remotes, fake Jenkins HTTP responses, fake health responses, release activation, rollback, cleanup ordering, and credential cleanup.

**Tech Stack:** Bash 3.2+/Linux Bash for rendered deployment, Python 3 standard library for rendering/validation, Git, curl, Jenkins Remote Access API, existing shell test harness.

## Global Constraints

- A push to `dev` or `main` must never configure or invoke an automatic Jenkins trigger.
- Default mapping is `dev -> test` and `main -> production`, but rendered configuration may provide repository-evidenced alternatives.
- Jenkins CLI remains configuration-only and must reject `build`.
- Runtime credentials come only from environment/private files and never enter templates, JSON configuration, query strings, process arguments, or logs.
- The server fetches and builds exactly `EXPECTED_COMMIT`; branch head mismatch blocks before build.
- Test and production use separate source and deployment roots.
- Activation and health success precede release cleanup; failure rolls back and skips cleanup.
- Retention defaults to five, never falls below two, and always protects current and previous.
- Skill directory `/Users/im10furry/.codex/skills/implementing-jenkins-cicd` is not a Git worktree, so each task ends with an evidence checkpoint instead of a commit.

---

### Task 1: Add the Server-Pull Template Contract Test

**Files:**
- Create: `scripts/test-server-pull-templates.sh`
- Modify: `scripts/test-end-to-end-skill.sh`

**Interfaces:**
- Consumes: no new production interface.
- Produces: executable regression harness `scripts/test-server-pull-templates.sh` and a call to it from the full Skill test.

- [ ] **Step 1: Write the failing structure and renderer test**

Create a private temporary tree, assign `remote`, `test_source`, `production_source`, `test_deploy`, and `production_deploy` beneath it, initialize a bare Git remote with `dev` and `main`, and write the JSON render configuration with an interpolating heredoc:

```bash
cat >"$config" <<JSON
{
  "schema_version": 1,
  "project_name": "fixture-app",
  "repository_url": "file://${remote}",
  "jenkins_url": "http://localhost:18086",
  "jenkins_job": "fixture-app-deploy",
  "branches": {"test": "dev", "production": "main"},
  "source_roots": {"test": "${test_source}", "production": "${production_source}"},
  "deploy_roots": {"test": "${test_deploy}", "production": "${production_deploy}"},
  "commands": {
    "install": "true",
    "lint": "true",
    "test": "true",
    "build": "mkdir -p dist && printf '%s\\n' \"$EXPECTED_COMMIT\" > dist/version.txt",
    "activate_test": "true",
    "activate_production": "true"
  },
  "artifact_paths": ["dist"],
  "health_urls": {"test": "http://127.0.0.1:19001/health", "production": "http://127.0.0.1:19002/health"},
  "release_retention": 3,
  "clean_excludes": []
}
JSON
```

Assert that these commands fail before implementation because the renderer/assets are absent:

```bash
python3 "$SCRIPT_DIR/render-server-pull-templates.py" --config "$config" --output "$rendered"
test -x "$rendered/trigger-deploy.sh"
test -x "$rendered/deploy-from-git.sh"
```

- [ ] **Step 2: Add behavioral assertions to the same test**

After rendering, assert:

```bash
grep -F 'buildWithParameters' "$rendered/trigger-deploy.sh"
grep -F 'EXPECTED_COMMIT' "$rendered/deploy-from-git.sh"
! grep -R -E '__[A-Z0-9_]+__' "$rendered"
bash -n "$rendered/trigger-deploy.sh"
bash -n "$rendered/deploy-from-git.sh"
```

Use fake `curl` and real temporary Git repositories to prove:

- test trigger submits `DEPLOY_ENV=test`, `GIT_REF=dev`, and the exact remote SHA;
- production trigger rejects the `dev` branch;
- server deployment rejects a remote SHA different from `EXPECTED_COMMIT` before the build command leaves an evidence marker;
- health failure restores the prior `current` symlink and leaves all old releases;
- health success changes `current`, writes `.successful`, and only then reduces successful releases to retention while preserving current/previous;
- trigger and deployment temporary directories are absent after success, failure, and signal;
- the API token does not occur anywhere under the test root.

- [ ] **Step 3: Run the test to verify RED**

Run:

```bash
scripts/test-server-pull-templates.sh
```

Expected: nonzero with `render-server-pull-templates.py is missing or not executable`.

- [ ] **Step 4: Wire the new harness into the complete test**

Append this before the final PASS line in `scripts/test-end-to-end-skill.sh`:

```bash
"$SCRIPT_DIR/test-server-pull-templates.sh" >/dev/null
```

Evidence checkpoint: preserve the expected RED output in the implementation transcript.

### Task 2: Extract the Hardened Trigger into a Reusable Asset

**Files:**
- Create: `assets/templates/trigger-deploy.sh.tmpl`
- Modify: `scripts/render-jenkins-assets.py`
- Test: `scripts/test-end-to-end-skill.sh`
- Test: `scripts/test-server-pull-templates.sh`

**Interfaces:**
- Consumes render fields: `PLANNED_JENKINS_URL`, `JENKINS_JOB`, `TEST_BRANCH`, `PRODUCTION_BRANCH`.
- Produces `render_trigger_script(plan: dict[str, Any]) -> str` from the asset without changing the generated script contract.

- [ ] **Step 1: Copy the existing hardened trigger body into the template**

Move the current Bash body from `render_trigger_script` into `assets/templates/trigger-deploy.sh.tmpl`. Keep these exact render markers at the assignment boundary:

```bash
PLANNED_JENKINS_URL=__PLANNED_JENKINS_URL__
JENKINS_JOB=__JENKINS_JOB__
TEST_BRANCH=__TEST_BRANCH__
PRODUCTION_BRANCH=__PRODUCTION_BRANCH__
```

Preserve clean-worktree verification, local/remote SHA equality, private curl configuration, POST body parameters, controller URL validation, queue/build polling, final `SUCCESS` enforcement, console output, and signal-safe cleanup.

- [ ] **Step 2: Make the existing renderer consume the asset**

Replace the inline body with:

```python
def render_trigger_script(plan: dict[str, Any]) -> str:
    branch_map = plan["job"]["branch_environment_map"]
    test_branch = next(branch for branch, environment in branch_map.items() if environment == "test")
    production_branch = next(branch for branch, environment in branch_map.items() if environment == "production")
    return template(
        "templates/trigger-deploy.sh.tmpl",
        {
            "PLANNED_JENKINS_URL": shell_single(str(plan["controller"]["url"])),
            "JENKINS_JOB": shell_single(str(plan["job"]["name"])),
            "TEST_BRANCH": shell_single(str(test_branch)),
            "PRODUCTION_BRANCH": shell_single(str(production_branch)),
        },
    )
```

- [ ] **Step 3: Run existing trigger regression tests**

Run:

```bash
scripts/test-end-to-end-skill.sh
```

Expected: the pre-existing trigger success/failure/signal/malicious-URL tests continue to pass; the overall test may still fail only at the missing server-pull renderer from Task 1.

Evidence checkpoint: compare a pre-extraction rendered trigger with the asset-rendered trigger or rely on deterministic bundle verification plus behavioral tests.

### Task 3: Implement the Validated Template Renderer

**Files:**
- Create: `scripts/render-server-pull-templates.py`
- Create: `assets/templates/deploy-from-git.sh.tmpl`
- Test: `scripts/test-server-pull-templates.sh`

**Interfaces:**
- Consumes `--config PATH --output DIRECTORY`.
- Produces mode `0700` files `trigger-deploy.sh`, `deploy-from-git.sh`, and mode `0600` `manifest.json`.
- Exposes Python helpers `load_config(path: Path) -> dict[str, Any]`, `validate_config(payload: dict[str, Any]) -> dict[str, Any]`, `render_files(config: dict[str, Any], output: Path) -> None`.

- [ ] **Step 1: Implement strict JSON validation**

Use only the Python standard library. Validate schema version, safe project/job names, HTTP(S) Jenkins URL without credentials/query/fragment, distinct test/production branches, absolute non-root source/deploy paths, separate environment roots, repository URL without embedded HTTP credentials, retention `2..50`, exact command keys, nonempty build command, relative artifact paths without `..`, and relative clean excludes.

Reject unknown top-level and nested keys so misspellings do not silently change deployment behavior. Use this exact top-level set:

```python
EXPECTED_KEYS = {
    "schema_version", "project_name", "repository_url", "jenkins_url", "jenkins_job",
    "branches", "source_roots", "deploy_roots", "commands", "artifact_paths",
    "health_urls", "release_retention", "clean_excludes",
}
```

The `commands` object contains exactly `install`, `lint`, `test`, `build`, `activate_test`, and `activate_production`.

- [ ] **Step 2: Implement deterministic safe rendering**

Render shell values with:

```python
def shell_single(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"
```

Render artifact and clean-exclude arrays as one shell-quoted value per line. Fail if any `__[A-Z0-9_]+__` marker remains. Write into a private staging directory, hash both scripts into `manifest.json`, set scripts to `0700`, set the manifest to `0600`, then atomically rename staging to the requested output. Refuse an existing output path.

- [ ] **Step 3: Implement the deployment template phases**

The template defines rendered constants, selects environment values, validates `DEPLOY_ENV/GIT_REF/EXPECTED_COMMIT`, and requires `git`, `flock`, `curl`, and `python3`.

Implement functions with these contracts:

```bash
fail MESSAGE...
retry_git DESCRIPTION COMMAND...
run_phase NAME COMMAND
replace_symlink TEMP_LINK DESTINATION_LINK
health_check URL
rollback_release PREVIOUS_TARGET
cleanup_successful_releases RELEASES_DIR CURRENT_NAME PREVIOUS_NAME RETENTION
```

Use a project-wide lock, clone only into an empty source root, verify the existing origin URL, fetch the mapped branch, compare remote SHA to `EXPECTED_COMMIT`, reset/clean only after canonical path validation, run commands in order, copy configured artifacts into a staging directory, atomically move to the final release, switch `current`, execute the environment activation command, and run bounded health checks.

Capture nonzero activation/health status without losing strict-mode behavior. On failure after switching, atomically restore the prior symlink, rerun activation and health, and return failure. Write `.successful` and call the cleanup function only after health success. Implement cleanup in the embedded Python block so paths containing whitespace remain safe; require direct child directories, reject symlinks, sort by modification time descending, and protect current plus previous.

- [ ] **Step 4: Render the trigger asset from the same configuration**

Map:

```python
trigger_values = {
    "PLANNED_JENKINS_URL": shell_single(config["jenkins_url"]),
    "JENKINS_JOB": shell_single(config["jenkins_job"]),
    "TEST_BRANCH": shell_single(config["branches"]["test"]),
    "PRODUCTION_BRANCH": shell_single(config["branches"]["production"]),
}
```

The JSON configuration never contains a Jenkins user or API token.

- [ ] **Step 5: Run the server-pull contract test**

Run:

```bash
scripts/test-server-pull-templates.sh
```

Expected: `PASS: server-pull Jenkins templates`.

Evidence checkpoint: retain the manifest hashes and test PASS line in the transcript.

### Task 4: Teach the Skill to Select and Adapt the Templates

**Files:**
- Modify: `SKILL.md`
- Create: `references/server-pull-templates.md`
- Modify: `agents/openai.yaml`
- Test: `scripts/test-server-pull-templates.sh`

**Interfaces:**
- Consumes repository inspection plus Jenkins/server facts.
- Produces documented selection and rendering flow using `render-server-pull-templates.py`.

- [ ] **Step 1: Add the server-pull choice to the core workflow**

State in `SKILL.md` that this mode is selected when the user explicitly wants the Jenkins-side server script to fetch `dev/main` and build on the deployment server. Require reading `references/server-pull-templates.md`, generating a secret-free JSON configuration, rendering into a private review directory, reviewing both scripts, installing/configuring the Jenkins job, and committing the project trigger before use.

Keep artifact delivery as the preferred default when the user has not requested server-side source pull.

- [ ] **Step 2: Document the adaptation map**

In `references/server-pull-templates.md`, define:

- required evidence and the exact JSON schema;
- frontend, Java, Node, Python, and existing-Docker command derivation rules;
- same-server Jenkins execution without a separate Agent application repository;
- Jenkins job parameter and empty-trigger requirements;
- credential boundaries for Git and Jenkins;
- explicit `dev -> test`, validation, promotion, `main -> production` operator flow;
- installation and dry-run checklist;
- the rule that cleanup follows successful health and rollback skips cleanup.

- [ ] **Step 3: Refresh UI metadata**

Use the Skill Creator generator with the existing name and a default prompt that mentions both artifact delivery and explicit server-pull templates without implying push-triggered deployment.

- [ ] **Step 4: Add documentation assertions**

Assert the Skill/reference mention both template assets, the renderer command, `dev`, `main`, explicit user instruction, empty automatic triggers, health-before-cleanup, and no separate Agent project.

- [ ] **Step 5: Run the focused test**

Run:

```bash
scripts/test-server-pull-templates.sh
```

Expected: `PASS: server-pull Jenkins templates`.

Evidence checkpoint: inspect rendered scripts and documentation assertion output.

### Task 5: Complete Static, Structural, and End-to-End Verification

**Files:**
- Verify: `SKILL.md`
- Verify: `agents/openai.yaml`
- Verify: `assets/templates/*.tmpl`
- Verify: `scripts/*.py`
- Verify: `scripts/*.sh`

**Interfaces:**
- Consumes all prior tasks.
- Produces final verification evidence only.

- [ ] **Step 1: Run syntax checks without writing bytecode**

Run:

```bash
for file in scripts/*.sh; do bash -n "$file"; done
python3 - <<'PY'
from pathlib import Path
for path in Path('scripts').glob('*.py'):
    compile(path.read_text(encoding='utf-8'), str(path), 'exec')
print('PASS: syntax')
PY
```

Expected: `PASS: syntax`.

- [ ] **Step 2: Run focused and full regression tests**

Run:

```bash
scripts/test-server-pull-templates.sh
scripts/test-end-to-end-skill.sh
scripts/test-jenkins-readonly-audit.sh
```

Expected: all three print PASS and exit zero.

- [ ] **Step 3: Validate the Skill package**

Run Skill Creator `quick_validate.py` in a temporary Python 3.13 environment with PyYAML installed from `https://pypi.tuna.tsinghua.edu.cn/simple`, then delete that environment.

Expected: `Skill is valid!`.

- [ ] **Step 4: Run secret and trigger-boundary scans**

Run:

```bash
! rg -n 'api-key|build\?token=|password[[:space:]]*=' assets/templates references/server-pull-templates.md
! rg -n 'GitHubPushTrigger|SCMTrigger|GenericTrigger' assets/templates
rg -n 'buildWithParameters' assets/templates/trigger-deploy.sh.tmpl
rg -n 'health|cleanup|rollback' assets/templates/deploy-from-git.sh.tmpl
```

Expected: forbidden scans return no matches; required scans find the hardened API endpoint and deployment gates.

- [ ] **Step 5: Review the final file inventory**

Confirm only the two requested templates, one focused renderer, one focused test, one reference, and necessary Skill metadata/integration changes were added. Remove generated caches and temporary fixtures.

Evidence checkpoint: report exact commands and PASS results without claiming a live server deployment.
