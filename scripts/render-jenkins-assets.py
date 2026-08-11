#!/usr/bin/env python3
"""Render Jenkins controller and project delivery assets from an approved plan."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any, NoReturn


SCRIPT_DIR = Path(__file__).resolve().parent
SKILL_DIR = SCRIPT_DIR.parent
ASSET_DIR = SKILL_DIR / "assets"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
PROJECT_FILES = (
    "Jenkinsfile",
    "ops/jenkins/deploy.sh",
    "ops/jenkins/activate.sh",
    "ops/jenkins/health-check.sh",
    "ops/jenkins/rollback.sh",
    "ops/jenkins/cleanup-releases.sh",
    "ops/jenkins/trigger-deploy.sh",
)


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def canonical(payload: dict[str, Any]) -> bytes:
    clean = dict(payload)
    clean.pop("plan_id", None)
    return json.dumps(clean, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def load_plan(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read plan: {error}")
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        fail("unsupported plan")
    stored = payload.get("plan_id")
    calculated = hashlib.sha256(canonical(payload)).hexdigest()
    if not isinstance(stored, str) or stored != calculated:
        fail("plan content does not match its identifier")
    tooling = payload.get("tooling") if isinstance(payload.get("tooling"), dict) else {}
    asset_digest = hashlib.sha256()
    for asset_path in sorted(path for path in ASSET_DIR.rglob("*") if path.is_file()):
        asset_digest.update(asset_path.relative_to(SKILL_DIR).as_posix().encode("utf-8"))
        asset_digest.update(b"\0")
        asset_digest.update(asset_path.read_bytes())
        asset_digest.update(b"\0")
    if tooling.get("renderer_sha256") != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        fail("renderer changed after plan creation; create and approve a new plan")
    if tooling.get("assets_sha256") != asset_digest.hexdigest():
        fail("templates changed after plan creation; create and approve a new plan")
    script_digest = hashlib.sha256()
    for name in (
        "apply-jenkins-job.sh",
        "bootstrap-jenkins-cli-profile.sh",
        "configure-jenkins-plugins.sh",
        "install-jenkins-docker.sh",
        "jenkins-cli-safe.sh",
        "orchestrate-jenkins-delivery.sh",
        "plan-jenkins.py",
        "render-jenkins-assets.py",
        "verify-jenkins-delivery.sh",
    ):
        script_path = SCRIPT_DIR / name
        script_digest.update(name.encode("utf-8"))
        script_digest.update(b"\0")
        script_digest.update(script_path.read_bytes())
        script_digest.update(b"\0")
    if tooling.get("scripts_sha256") != script_digest.hexdigest():
        fail("plan-bound tooling changed after plan creation; create and approve a new plan")
    return payload


def shell_single(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def groovy_single(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'").replace("${", "\\${")


def template(name: str, replacements: dict[str, str]) -> str:
    path = ASSET_DIR / name
    if not path.is_file():
        fail(f"required template is missing: {path}")
    rendered = path.read_text(encoding="utf-8")
    for key, value in replacements.items():
        rendered = rendered.replace(f"__{key}__", value)
    leftovers = sorted(set(re.findall(r"__[A-Z0-9_]+__", rendered)))
    if leftovers:
        fail(f"template {name} has unresolved fields: {', '.join(leftovers)}")
    return rendered


def project_commands(plan: dict[str, Any]) -> list[tuple[str, str, str]]:
    commands: list[tuple[str, str, str]] = []
    applications = plan["discovery"].get("applications") or []
    seen: set[tuple[str, str]] = set()
    for application in applications:
        if not isinstance(application, dict):
            continue
        root = str(application.get("root") or ".")
        app_type = str(application.get("type") or "application")
        app_commands = application.get("commands") if isinstance(application.get("commands"), dict) else {}
        for phase in ("install", "lint", "test", "build"):
            value = app_commands.get(phase)
            if not isinstance(value, str) or not value.strip():
                continue
            key = (root, value)
            if key in seen:
                continue
            seen.add(key)
            commands.append((root, f"{app_type}: {phase}", value))
    return commands


def artifact_candidates(plan: dict[str, Any]) -> list[str]:
    candidates: list[str] = []
    for application in plan["discovery"].get("applications") or []:
        if not isinstance(application, dict) or application.get("type") == "docker":
            continue
        root = str(application.get("root") or ".")
        for item in application.get("artifact_candidates") or []:
            if not isinstance(item, str) or item.startswith("container-image:"):
                continue
            value = item if root == "." else f"{root}/{item}"
            if value not in candidates:
                candidates.append(value)
    return candidates


def render_jenkinsfile(plan: dict[str, Any]) -> str:
    job = plan["job"]
    delivery = plan["delivery"]
    branch_map = job["branch_environment_map"]
    test_branch = next(branch for branch, environment in branch_map.items() if environment == "test")
    production_branch = next(branch for branch, environment in branch_map.items() if environment == "production")
    repo_url = groovy_single(str(job["repository_url"]))
    credentials_id = groovy_single(str(job["credentials_id"]))
    remote_configuration = f"url: '{repo_url}'"
    if credentials_id:
        remote_configuration += f", credentialsId: '{credentials_id}'"
    test_root = groovy_single(str(delivery["deploy_roots"]["test"]))
    production_root = groovy_single(str(delivery["deploy_roots"]["production"]))
    test_health = groovy_single(str(delivery["health_urls"]["test"]))
    production_health = groovy_single(str(delivery["health_urls"]["production"]))
    test_host = groovy_single(str(delivery["deploy_hosts"]["test"]))
    production_host = groovy_single(str(delivery["deploy_hosts"]["production"]))
    deployment_credentials_id = groovy_single(str(delivery["deployment_credentials_id"]))
    agent_label = groovy_single(str(plan["controller"]["agent_label"]))
    retention = int(delivery["release_retention"])
    build_steps: list[str] = []
    for root, label, command in project_commands(plan):
        escaped_command = groovy_single(command)
        escaped_root = groovy_single(root)
        if root == ".":
            build_steps.append(f"          echo '{groovy_single(label)}'\n          sh '{escaped_command}'")
        else:
            build_steps.append(
                f"          echo '{groovy_single(label)}'\n"
                f"          dir('{escaped_root}') {{\n            sh '{escaped_command}'\n          }}"
            )
    if not build_steps:
        build_steps.append("          error 'No authoritative build command was discovered.'")
    candidates = artifact_candidates(plan)
    candidate_lines = " \\\n".join(f"            {shell_single(item)}" for item in candidates)
    if not candidate_lines:
        candidate_lines = "            ."
    return f"""pipeline {{
  agent {{ label '{agent_label}' }}

  options {{
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
    timeout(time: 60, unit: 'MINUTES')
    timestamps()
    skipDefaultCheckout(true)
  }}

  parameters {{
    choice(name: 'DEPLOY_ENV', choices: ['test', 'production'], description: 'Validated deployment environment')
    string(name: 'GIT_REF', defaultValue: '{groovy_single(test_branch)}', description: 'Remote branch to build')
    string(name: 'EXPECTED_COMMIT', defaultValue: '', description: 'Exact pushed commit required by the AI trigger')
  }}

  stages {{
    stage('Validate request') {{
      steps {{
        script {{
          def expectedBranch = params.DEPLOY_ENV == 'production' ? '{groovy_single(production_branch)}' : '{groovy_single(test_branch)}'
          if (params.GIT_REF != expectedBranch) {{
            error "Environment ${{params.DEPLOY_ENV}} requires branch ${{expectedBranch}}, got ${{params.GIT_REF}}"
          }}
          if (!(params.EXPECTED_COMMIT ==~ /[0-9a-fA-F]{{40}}/)) {{
            error 'EXPECTED_COMMIT must be the full 40-character commit pushed to the remote branch.'
          }}
          env.DEPLOY_ROOT = params.DEPLOY_ENV == 'production' ? '{production_root}' : '{test_root}'
          env.HEALTH_URL = params.DEPLOY_ENV == 'production' ? '{production_health}' : '{test_health}'
          env.DEPLOY_HOST = params.DEPLOY_ENV == 'production' ? '{production_host}' : '{test_host}'
          env.RELEASE_RETENTION = '{retention}'
        }}
      }}
    }}

    stage('Checkout pushed commit') {{
      steps {{
        deleteDir()
        checkout([$class: 'GitSCM',
          branches: [[name: "*/${{params.GIT_REF}}"]],
          userRemoteConfigs: [[{remote_configuration}]]
        ])
        sh '''
          set -eu
          actual_commit="$(git rev-parse HEAD)"
          test "$actual_commit" = "$EXPECTED_COMMIT"
          printf 'commit=%s\\n' "$actual_commit" | tee build-source.properties
        '''
      }}
    }}

    stage('Build and test') {{
      steps {{
{chr(10).join(build_steps)}
      }}
    }}

    stage('Package immutable artifact') {{
      steps {{
        sh '''
          set -eu
          set -- \\
{candidate_lines}
          found=""
          for pattern in "$@"; do
            for candidate in $pattern; do
              if [ -e "$candidate" ]; then
                found="$found $candidate"
              fi
            done
          done
          [ -n "$found" ] || {{ echo "No build artifact candidate exists" >&2; exit 1; }}
          # shellcheck disable=SC2086
          tar -czf delivery-artifact.tgz $found
          sha256sum delivery-artifact.tgz | tee delivery-artifact.sha256
        '''
        archiveArtifacts artifacts: 'delivery-artifact.tgz,delivery-artifact.sha256,build-source.properties', fingerprint: true
      }}
    }}

    stage('Deploy and verify') {{
      steps {{
        script {{
          env.RELEASE_ID = "build-${{env.BUILD_NUMBER}}-${{params.EXPECTED_COMMIT.take(12)}}"
          def activated = false
          if (env.DEPLOY_HOST == 'local') {{
            try {{
              sh 'sha256sum -c delivery-artifact.sha256'
              sh 'ops/jenkins/deploy.sh delivery-artifact.tgz "$DEPLOY_ROOT" "$RELEASE_ID"'
              activated = true
              sh 'ops/jenkins/activate.sh "$DEPLOY_ENV"'
              sh 'ops/jenkins/health-check.sh "$HEALTH_URL"'
              sh 'touch "$DEPLOY_ROOT/releases/$RELEASE_ID/.successful"'
            }} catch (failure) {{
              if (activated) {{
                try {{
                  sh 'RELEASES_ROOT="$DEPLOY_ROOT" ops/jenkins/rollback.sh'
                  sh 'ops/jenkins/activate.sh "$DEPLOY_ENV"'
                  sh 'ops/jenkins/health-check.sh "$HEALTH_URL"'
                }} catch (rollbackFailure) {{
                  error "Deployment failed and rollback health verification also failed: ${{rollbackFailure}}"
                }}
              }}
              throw failure
            }}
          }} else {{
            sshagent(credentials: ['{deployment_credentials_id}']) {{
              try {{
                sh '''
                  set -eu
                  remote_stage="/tmp/jenkins-delivery-${{JOB_NAME}}-${{BUILD_NUMBER}}-${{EXPECTED_COMMIT}}"
                  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" "umask 077; mkdir -p '$remote_stage'"
                  cleanup_remote_best_effort() {{
                    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" "find '$remote_stage' -depth -delete" >/dev/null 2>&1 || true
                  }}
                  trap cleanup_remote_best_effort EXIT HUP INT TERM
                  scp -o BatchMode=yes -o StrictHostKeyChecking=yes delivery-artifact.tgz delivery-artifact.sha256 "$DEPLOY_HOST:$remote_stage/"
                  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" \
                    "cd '$remote_stage' && sha256sum -c delivery-artifact.sha256 && bash -s -- '$remote_stage/delivery-artifact.tgz' '$DEPLOY_ROOT' '$RELEASE_ID'" \
                    < ops/jenkins/deploy.sh
                  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" "find '$remote_stage' -depth -delete"
                  trap - EXIT HUP INT TERM
                '''
                activated = true
                sh '''
                  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" \
                    "bash -s -- '$DEPLOY_ENV'" < ops/jenkins/activate.sh
                '''
                sh 'ops/jenkins/health-check.sh "$HEALTH_URL"'
                sh '''
                  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" \
                    "touch '$DEPLOY_ROOT/releases/$RELEASE_ID/.successful'"
                '''
              }} catch (failure) {{
                if (activated) {{
                  try {{
                    sh '''
                      ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" \
                        "RELEASES_ROOT='$DEPLOY_ROOT' bash -s" < ops/jenkins/rollback.sh
                      ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" \
                        "bash -s -- '$DEPLOY_ENV'" < ops/jenkins/activate.sh
                    '''
                    sh 'ops/jenkins/health-check.sh "$HEALTH_URL"'
                  }} catch (rollbackFailure) {{
                    error "Deployment failed and remote rollback health verification also failed: ${{rollbackFailure}}"
                  }}
                }}
                throw failure
              }}
            }}
          }}
        }}
      }}
    }}

    stage('Prune old successful releases') {{
      steps {{
        script {{
          if (env.DEPLOY_HOST == 'local') {{
            sh 'ops/jenkins/cleanup-releases.sh'
          }} else {{
            sshagent(credentials: ['{deployment_credentials_id}']) {{
              sh '''
                ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$DEPLOY_HOST" \
                  "RELEASES_ROOT='$DEPLOY_ROOT' RELEASE_RETENTION='$RELEASE_RETENTION' bash -s" \
                  < ops/jenkins/cleanup-releases.sh
              '''
            }}
          }}
        }}
      }}
    }}
  }}

  post {{
    always {{
      cleanWs(deleteDirs: true, disableDeferredWipeout: true)
    }}
  }}
}}
"""


def render_deploy_script() -> str:
    return r'''#!/usr/bin/env bash
set -euo pipefail
umask 027

artifact="${1:-}"
release_root="${2:-${RELEASES_ROOT:-}}"
release_id="${3:-${RELEASE_ID:-}}"
[ -e "$artifact" ] || { echo "Artifact does not exist: $artifact" >&2; exit 2; }
case "$release_root" in
  /*) ;;
  *) echo "Release root must be an absolute path" >&2; exit 2 ;;
esac
case "$release_root" in
  /|"${HOME:-/nonexistent}") echo "Unsafe release root: $release_root" >&2; exit 2 ;;
esac
case "$release_id" in
  ''|*[!A-Za-z0-9._-]*|.*|..*) echo "Unsafe release identifier: $release_id" >&2; exit 2 ;;
esac

mkdir -p "$release_root"
release_root="$(cd "$release_root" && pwd -P)"
case "$release_root" in /|"${HOME:-/nonexistent}") echo "Unsafe canonical release root" >&2; exit 2 ;; esac
releases_dir="$release_root/releases"
release_dir="$releases_dir/$release_id"
staging_dir="$releases_dir/.${release_id}.staging.$$"
current_link="$release_root/current"
temporary_link="$release_root/.current.$$.tmp"
activated='false'
mkdir -p "$releases_dir"
[ ! -e "$release_dir" ] || { echo "Release already exists: $release_dir" >&2; exit 2; }
[ ! -e "$staging_dir" ] || { echo "Staging path already exists" >&2; exit 2; }

cleanup_staging() {
  if [ -d "$staging_dir" ]; then
    find "$staging_dir" -depth -delete
  fi
  if [ "$activated" != 'true' ] && [ -d "$release_dir" ]; then
    find "$release_dir" -depth -delete
  fi
  [ ! -L "$temporary_link" ] || unlink "$temporary_link"
}
replace_symlink() {
  source_link="$1"
  destination_link="$2"
  if mv -fT "$source_link" "$destination_link" 2>/dev/null; then return 0; fi
  [ -L "$source_link" ] || { echo "Temporary activation symlink disappeared" >&2; return 1; }
  if mv -fh "$source_link" "$destination_link" 2>/dev/null; then return 0; fi
  echo "Platform cannot atomically replace the active symlink" >&2
  return 1
}
trap cleanup_staging EXIT HUP INT TERM
mkdir "$staging_dir"
python3 - "$artifact" <<'PY'
import pathlib
import sys
import tarfile

artifact = pathlib.Path(sys.argv[1])
if artifact.is_symlink():
    raise SystemExit("ERROR: artifact must not be a symbolic link")
if artifact.is_dir():
    for child in artifact.rglob("*"):
        if child.is_symlink():
            raise SystemExit(f"ERROR: artifact contains a symbolic link: {child.relative_to(artifact)}")
        if not child.is_dir() and not child.is_file():
            raise SystemExit(f"ERROR: artifact contains an unsupported entry: {child.relative_to(artifact)}")
else:
    try:
        archive = tarfile.open(artifact, mode="r:gz")
    except (OSError, tarfile.TarError) as error:
        raise SystemExit(f"ERROR: invalid gzip tar artifact: {error}")
    with archive:
        for member in archive.getmembers():
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or any(part == ".." for part in path.parts):
                raise SystemExit(f"ERROR: archive member escapes the release: {member.name}")
            if not member.isdir() and not member.isreg():
                raise SystemExit(f"ERROR: archive member type is not allowed: {member.name}")
PY
if [ -d "$artifact" ]; then
  cp -R "$artifact"/. "$staging_dir"/
else
  tar --no-same-owner --no-same-permissions -xzf "$artifact" -C "$staging_dir"
fi
[ -n "$(find "$staging_dir" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
  echo "Artifact produced an empty release" >&2
  exit 1
}
mv "$staging_dir" "$release_dir"

if [ -L "$current_link" ]; then
  previous_target="$(readlink "$current_link")"
  previous_name="${previous_target##*/}"
  case "$previous_name" in
    ''|*[!A-Za-z0-9._-]*|.*|..*) echo "Refusing unsafe previous target" >&2; exit 2 ;;
  esac
  if [ -d "$releases_dir/$previous_name" ]; then
    printf '%s\n' "$previous_name" >"$release_root/.previous-release"
  fi
elif [ -e "$current_link" ]; then
  echo "Current path exists but is not a symlink: $current_link" >&2
  exit 2
fi

ln -s "releases/$release_id" "$temporary_link"
replace_symlink "$temporary_link" "$current_link"
activated='true'
trap - EXIT HUP INT TERM
printf 'Activated release: %s\n' "$release_id"
'''


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


def render_health_script() -> str:
    return r'''#!/usr/bin/env bash
set -euo pipefail

health_url="${1:-${HEALTH_URL:-}}"
[ -n "$health_url" ] || { echo "Health URL is required" >&2; exit 2; }
case "$health_url" in
  http://*|https://*) ;;
  *) echo "Health URL must use HTTP or HTTPS" >&2; exit 2 ;;
esac

attempt=1
while [ "$attempt" -le "${HEALTH_ATTEMPTS:-20}" ]; do
  if curl -fsS --connect-timeout 5 --max-time 15 "$health_url" >/dev/null; then
    printf 'Health check passed: %s\n' "$health_url"
    exit 0
  fi
  sleep "${HEALTH_INTERVAL_SECONDS:-3}"
  attempt=$((attempt + 1))
done
printf 'Health check failed after %s attempts: %s\n' "${HEALTH_ATTEMPTS:-20}" "$health_url" >&2
exit 1
'''


def render_activation_script(plan: dict[str, Any]) -> str:
    commands = plan["delivery"]["activation_commands"]
    test_command = str(commands.get("test") or "")
    production_command = str(commands.get("production") or "")
    return f'''#!/usr/bin/env bash
set -euo pipefail

environment="${{1:-${{DEPLOY_ENV:-}}}}"
case "$environment" in
  test) activation_command={shell_single(test_command)} ;;
  production) activation_command={shell_single(production_command)} ;;
  *) echo "Deployment environment must be test or production" >&2; exit 2 ;;
esac
if [ -z "$activation_command" ]; then
  printf 'Symlink activation requires no service command for %s\n' "$environment"
  exit 0
fi
bash -lc "$activation_command"
'''


def render_rollback_script() -> str:
    return r'''#!/usr/bin/env bash
set -euo pipefail

release_root="${RELEASES_ROOT:-${1:-}}"
case "$release_root" in
  /*) ;;
  *) echo "Release root must be an absolute path" >&2; exit 2 ;;
esac
case "$release_root" in
  /|"${HOME:-/nonexistent}") echo "Unsafe release root: $release_root" >&2; exit 2 ;;
esac
release_root="$(cd "$release_root" && pwd -P)"
case "$release_root" in /|"${HOME:-/nonexistent}") echo "Unsafe canonical release root" >&2; exit 2 ;; esac
previous_file="$release_root/.previous-release"
[ -f "$previous_file" ] || { echo "No previous release is recorded" >&2; exit 1; }
previous_name="$(sed -n '1p' "$previous_file")"
case "$previous_name" in
  ''|*[!A-Za-z0-9._-]*|.*|..*) echo "Unsafe previous release identifier" >&2; exit 2 ;;
esac
[ -d "$release_root/releases/$previous_name" ] || { echo "Previous release is missing" >&2; exit 1; }
temporary_link="$release_root/.current.rollback.$$.tmp"
trap '[ ! -L "$temporary_link" ] || unlink "$temporary_link"' EXIT HUP INT TERM
ln -s "releases/$previous_name" "$temporary_link"
if mv -fT "$temporary_link" "$release_root/current" 2>/dev/null; then :
elif [ -L "$temporary_link" ] && mv -fh "$temporary_link" "$release_root/current" 2>/dev/null; then :
else echo "Platform cannot atomically replace the active symlink" >&2; exit 1
fi
trap - EXIT HUP INT TERM
printf 'Rolled back to release: %s\n' "$previous_name"
'''


def render_cleanup_script(default_retention: int) -> str:
    return rf'''#!/usr/bin/env bash
set -euo pipefail
umask 077

release_root="${{RELEASES_ROOT:-${{1:-}}}}"
retention="${{RELEASE_RETENTION:-{default_retention}}}"
case "$release_root" in
  /*) ;;
  *) echo "Release root must be an absolute path" >&2; exit 2 ;;
esac
case "$release_root" in
  /|"${{HOME:-/nonexistent}}") echo "Unsafe release root: $release_root" >&2; exit 2 ;;
esac
release_root="$(cd "$release_root" && pwd -P)"
case "$release_root" in /|"${{HOME:-/nonexistent}}") echo "Unsafe canonical release root" >&2; exit 2 ;; esac
case "$retention" in
  ''|*[!0-9]*) echo "Release retention must be an integer" >&2; exit 2 ;;
esac
[ "$retention" -ge 2 ] || {{ echo "Release retention may not be lower than two" >&2; exit 2; }}

releases_dir="$release_root/releases"
[ -d "$releases_dir" ] || exit 0
[ ! -L "$releases_dir" ] || {{ echo "Releases directory must not be a symlink" >&2; exit 2; }}
current_name=''
if [ -L "$release_root/current" ]; then
  current_target="$(readlink "$release_root/current")"
  current_name="${{current_target##*/}}"
fi
previous_name=''
if [ -f "$release_root/.previous-release" ]; then
  previous_name="$(sed -n '1p' "$release_root/.previous-release")"
fi
for protected_name in "$current_name" "$previous_name"; do
  case "$protected_name" in
    ''|*[!A-Za-z0-9._-]*|.*|..*)
      [ -z "$protected_name" ] || {{ echo "Unsafe protected release identifier" >&2; exit 2; }}
      ;;
  esac
done

index_file="$(mktemp "${{TMPDIR:-/tmp}}/jenkins-release-index.XXXXXX")"
trap 'rm -f -- "$index_file"' EXIT HUP INT TERM
for candidate_path in "$releases_dir"/*; do
  [ -d "$candidate_path" ] || continue
  [ -f "$candidate_path/.successful" ] || continue
  candidate_name="${{candidate_path##*/}}"
  case "$candidate_name" in
    ''|*[!A-Za-z0-9._-]*|.*|..*) echo "Skipping unsafe release name" >&2; continue ;;
  esac
  if modified="$(stat -f '%m' "$candidate_path" 2>/dev/null)"; then :; else
    modified="$(stat -c '%Y' "$candidate_path")"
  fi
  printf '%s\t%s\n' "$modified" "$candidate_name" >>"$index_file"
done

kept=0
sort -rn "$index_file" | while IFS=$'\t' read -r _modified candidate_name; do
  [ -n "$candidate_name" ] || continue
  kept=$((kept + 1))
  [ "$kept" -gt "$retention" ] || continue
  if [ "$candidate_name" = "$current_name" ] || [ "$candidate_name" = "$previous_name" ]; then
    continue
  fi
  candidate_path="$releases_dir/$candidate_name"
  case "$candidate_path" in
    "$releases_dir"/*) ;;
    *) echo "Refusing cleanup outside releases directory" >&2; exit 2 ;;
  esac
  [ ! -L "$candidate_path" ] || {{ echo "Refusing to remove a release symlink" >&2; exit 2; }}
  find "$candidate_path" -depth -delete
  printf 'Removed old successful release: %s\n' "$candidate_name"
done

for candidate_path in "$releases_dir"/*; do
  [ -d "$candidate_path" ] || continue
  [ ! -f "$candidate_path/.successful" ] || continue
  candidate_name="${{candidate_path##*/}}"
  case "$candidate_name" in ''|*[!A-Za-z0-9._-]*|.*|..*) continue ;; esac
  if [ "$candidate_name" = "$current_name" ] || [ "$candidate_name" = "$previous_name" ]; then continue; fi
  [ ! -L "$candidate_path" ] || {{ echo "Refusing to remove a release symlink" >&2; exit 2; }}
  find "$candidate_path" -depth -delete
  printf 'Removed unsuccessful stale release: %s\n' "$candidate_name"
done
'''


def render_job_xml(plan: dict[str, Any]) -> str:
    job = plan["job"]
    escape = lambda value: html.escape(str(value), quote=True)
    pipeline_script = escape(render_jenkinsfile(plan))
    test_branch = next(
        branch for branch, environment in job["branch_environment_map"].items() if environment == "test"
    )
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <actions/>
  <description>Managed by plan {escape(plan["plan_id"])}. Triggered explicitly by the project deployment script through the Jenkins Remote Access API; no SCM push trigger.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.ChoiceParameterDefinition>
          <name>DEPLOY_ENV</name>
          <description>Validated deployment environment</description>
          <choices class="java.util.Arrays$ArrayList"><a class="string-array"><string>test</string><string>production</string></a></choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>GIT_REF</name><description>Remote branch to build</description><defaultValue>{escape(test_branch)}</defaultValue><trim>true</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>EXPECTED_COMMIT</name><description>Exact pushed 40-character commit</description><defaultValue></defaultValue><trim>true</trim>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
    <jenkins.model.BuildDiscarderProperty>
      <strategy class="hudson.tasks.LogRotator"><daysToKeep>-1</daysToKeep><numToKeep>30</numToKeep><artifactDaysToKeep>-1</artifactDaysToKeep><artifactNumToKeep>10</artifactNumToKeep></strategy>
    </jenkins.model.BuildDiscarderProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>{pipeline_script}</script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
'''


def optional_credentials(plan: dict[str, Any]) -> str:
    sources = plan["delivery"]["credential_sources"]
    entries: list[str] = []
    for source_name, credential_id in (
        ("scm", plan["job"]["credentials_id"]),
        ("deployment", plan["delivery"]["deployment_credentials_id"]),
    ):
        source = sources[source_name]
        if not source.get("path"):
            continue
        entries.append(
            "          - basicSSHUserPrivateKey:\n"
            "              scope: GLOBAL\n"
            f"              id: \"{credential_id}\"\n"
            f"              username: \"{source['username']}\"\n"
            f"              description: \"Managed {source_name} credential for plan {plan['plan_id']}\"\n"
            "              privateKeySource:\n"
            "                directEntry:\n"
            f"                  privateKey: \"${{readFile:/run/secrets/{source_name}_key}}\""
        )
    return "\n".join(entries)


def write_file(path: Path, content: str, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o700 if executable else 0o600)


def render_bundle(plan: dict[str, Any], output: Path) -> None:
    if output.exists() or output.is_symlink():
        fail(f"output path already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.partial.", dir=output.parent))
    try:
        staging.chmod(0o700)
        controller = plan["controller"]
        replacements = {
            "JENKINS_IMAGE": str(controller["image"]),
            "JENKINS_AGENT_IMAGE": str(controller["agent_image"]),
            "NODE_VERSION": str(controller["agent_toolchain"]["node"]),
            "MAVEN_VERSION": str(controller["agent_toolchain"]["maven"]),
            "JENKINS_PORT": str(controller["http_port"]),
            "JENKINS_URL": str(controller["url"]),
            "PLAN_ID": str(plan["plan_id"]),
            "PLAN_SHORT": str(plan["plan_id"])[:12],
            "EXECUTORS": str(controller["bootstrap_executors"]),
            "AGENT_LABEL": str(controller["agent_label"]),
            "OPTIONAL_CREDENTIALS": optional_credentials(plan),
        }
        write_file(staging / "project/Jenkinsfile", render_jenkinsfile(plan))
        write_file(staging / "project/ops/jenkins/deploy.sh", render_deploy_script(), True)
        write_file(staging / "project/ops/jenkins/activate.sh", render_activation_script(plan), True)
        write_file(staging / "project/ops/jenkins/health-check.sh", render_health_script(), True)
        write_file(staging / "project/ops/jenkins/rollback.sh", render_rollback_script(), True)
        write_file(
            staging / "project/ops/jenkins/cleanup-releases.sh",
            render_cleanup_script(int(plan["delivery"]["release_retention"])),
            True,
        )
        write_file(staging / "project/ops/jenkins/trigger-deploy.sh", render_trigger_script(plan), True)
        write_file(staging / "controller/Dockerfile", template("controller.Dockerfile.tmpl", replacements))
        write_file(staging / "controller/Agent.Dockerfile", template("agent.Dockerfile.tmpl", replacements))
        write_file(staging / "controller/compose.yaml", template("compose.yaml.tmpl", replacements))
        write_file(staging / "controller/casc/jenkins.yaml", template("jenkins.yaml.tmpl", replacements))
        write_file(staging / "controller/.env.example", template("controller.env.example.tmpl", replacements))
        write_file(staging / "controller/known_hosts", str(plan["delivery"]["known_hosts"]["content"]))
        write_file(staging / "controller/plugins.txt", "\n".join(sorted(plan["plugins"])) + "\n")
        job_name = str(plan["job"]["name"])
        if not SAFE_NAME.fullmatch(job_name):
            fail("unsafe job name in plan")
        write_file(staging / f"controller/jobs/{job_name}.xml", render_job_xml(plan))
        hashes: dict[str, str] = {}
        for path in sorted(item for item in staging.rglob("*") if item.is_file()):
            hashes[path.relative_to(staging).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest = {
            "schema_version": 1,
            "plan_id": plan["plan_id"],
            "files": hashes,
            "trigger": {
                "mode": "project-script-remote-api",
                "automatic_scm_trigger": False,
                "branch_environment_map": plan["job"]["branch_environment_map"],
            },
        }
        write_file(staging / "manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
        os.replace(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def hash_or_none(path: Path) -> str | None:
    if not path.exists():
        return None
    if not path.is_file() or path.is_symlink():
        fail(f"project target is not a regular file: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply_project(plan: dict[str, Any], bundle: Path, project: Path, approval: str | None) -> None:
    if approval != plan["plan_id"]:
        fail("project apply requires the exact plan identifier")
    if plan.get("questions"):
        fail("project apply is blocked by unresolved plan questions: " + " | ".join(plan["questions"]))
    expected_root = Path(str(plan["discovery"]["project_root"])).expanduser().resolve()
    if project != expected_root:
        fail(f"project apply target differs from plan: {project}")
    before_hashes = plan.get("project_changes", {}).get("before_sha256", {})
    backup_root = bundle / "backups/project"
    for relative_name in PROJECT_FILES:
        target = project / relative_name
        expected = before_hashes.get(relative_name)
        actual = hash_or_none(target)
        if actual != expected:
            fail(f"project file changed after plan approval: {relative_name}")
    for relative_name in PROJECT_FILES:
        source = bundle / "project" / relative_name
        target = project / relative_name
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            backup = backup_root / relative_name
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, backup)
            backup.chmod(0o600)
        temporary = target.with_name(f".{target.name}.jenkins-plan-{plan['plan_id'][:12]}")
        if temporary.exists():
            fail(f"temporary apply path already exists: {temporary}")
        shutil.copy2(source, temporary)
        temporary.chmod(source.stat().st_mode & 0o777)
        os.replace(temporary, target)


def file_map(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            fail(f"bundle contains a symlink: {path.relative_to(root)}")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def verify_bundle(plan: dict[str, Any], bundle: Path) -> None:
    if not bundle.is_dir() or bundle.is_symlink():
        fail(f"bundle is not a safe directory: {bundle}")
    temporary_root = Path(tempfile.mkdtemp(prefix="jenkins-bundle-verify."))
    expected = temporary_root / "expected"
    try:
        render_bundle(plan, expected)
        expected_files = file_map(expected)
        actual_files = file_map(bundle)
        if actual_files != expected_files:
            missing = sorted(set(expected_files) - set(actual_files))
            extra = sorted(set(actual_files) - set(expected_files))
            changed = sorted(name for name in set(expected_files) & set(actual_files) if expected_files[name] != actual_files[name])
            fail(
                "bundle differs from the deterministic approved render; "
                f"missing={missing}, extra={extra}, changed={changed}"
            )
    finally:
        shutil.rmtree(temporary_root, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-bundle", type=Path)
    parser.add_argument("--apply-project", type=Path)
    parser.add_argument("--approve")
    arguments = parser.parse_args()
    plan = load_plan(arguments.plan.expanduser().resolve())
    if arguments.verify_bundle:
        if arguments.output or arguments.apply_project:
            fail("--verify-bundle cannot be combined with rendering or project apply")
        verify_bundle(plan, arguments.verify_bundle.expanduser().resolve())
        print(f"Verified deterministic Jenkins delivery bundle: {arguments.verify_bundle}")
        return
    if not arguments.output:
        fail("--output is required when rendering")
    output = arguments.output.expanduser().resolve()
    render_bundle(plan, output)
    if arguments.apply_project:
        apply_project(plan, output, arguments.apply_project.expanduser().resolve(), arguments.approve)
    print(f"Rendered Jenkins delivery bundle: {output}")


if __name__ == "__main__":
    main()
