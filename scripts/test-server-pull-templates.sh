#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SKILL_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
RENDERER="${SCRIPT_DIR}/render-server-pull-templates.py"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-server-pull-test.XXXXXX")"

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/jenkins-server-pull-test.*) find "$TEST_ROOT" -depth -delete ;;
    *) printf 'Refusing to remove unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
  esac
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  grep -F -- "$2" "$1" >/dev/null || fail "$1 does not contain: $2"
}

assert_not_contains_tree() {
  if grep -R -F -- "$2" "$1" >/dev/null 2>&1; then
    fail "$1 contains forbidden value: $2"
  fi
}

line_count() {
  if [ -f "$1" ]; then
    wc -l <"$1" | tr -d ' '
  else
    printf '0\n'
  fi
}

[ -x "$RENDERER" ] || fail 'render-server-pull-templates.py is missing or not executable'
[ -f "$SKILL_DIR/assets/templates/trigger-deploy.sh.tmpl" ] || fail 'trigger template is missing'
[ -f "$SKILL_DIR/assets/templates/deploy-from-git.sh.tmpl" ] || fail 'server deployment template is missing'
[ -f "$SKILL_DIR/references/server-pull-templates.md" ] || fail 'server-pull template reference is missing'
assert_contains "$SKILL_DIR/SKILL.md" 'references/server-pull-templates.md'
assert_contains "$SKILL_DIR/SKILL.md" 'render-server-pull-templates.py'
assert_contains "$SKILL_DIR/SKILL.md" 'agent is an execution node, not a separate project or repository'
assert_contains "$SKILL_DIR/references/server-pull-templates.md" 'deploy-from-git.sh'
assert_contains "$SKILL_DIR/references/server-pull-templates.md" 'successfully active and healthy'
assert_contains "$SKILL_DIR/references/server-pull-templates.md" 'empty `<triggers/>`'
assert_contains "$SKILL_DIR/references/server-pull-templates.md" '`dev` or `main`'
if grep -F 'Never upload an uncommitted workspace or make the deployment server pull source.' \
  "$SKILL_DIR/SKILL.md" >/dev/null; then
  fail 'Skill still prohibits the approved server-pull deployment mode'
fi

fixture="$TEST_ROOT/fixture-app"
remote="$TEST_ROOT/remote.git"
mkdir -p "$fixture"
git -C "$fixture" init -q -b dev
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config user.name 'Server Pull Fixture'
printf 'first\n' >"$fixture/source.txt"
git -C "$fixture" add source.txt
git -C "$fixture" commit -qm 'test: initial dev'
git init -q --bare "$remote"
git -C "$fixture" remote add origin "$remote"
git -C "$fixture" push -q -u origin dev
git -C "$fixture" branch main
git -C "$fixture" push -q origin main

test_source="$TEST_ROOT/server/test-source"
production_source="$TEST_ROOT/server/production-source"
test_deploy="$TEST_ROOT/server/test-deploy"
production_deploy="$TEST_ROOT/server/production-deploy"
config="$TEST_ROOT/server-pull.json"
build_marker="$TEST_ROOT/build-marker"
activation_log="$TEST_ROOT/activation.log"

"$PYTHON_BIN" - "$config" "$remote" "$test_source" "$production_source" \
  "$test_deploy" "$production_deploy" <<'PY'
import json
import pathlib
import sys

config, remote, test_source, production_source, test_deploy, production_deploy = sys.argv[1:]
payload = {
    "schema_version": 2,
    "project_name": "fixture-app",
    "repository_url": pathlib.Path(remote).as_uri(),
    "jenkins_url": "http://localhost:18086",
    "jenkins_job": "fixture-app-deploy",
    "branches": {"test": "dev", "production": "main"},
    "source_roots": {"test": test_source, "production": production_source},
    "deploy_roots": {"test": test_deploy, "production": production_deploy},
    "commands": {
        "install": "true",
        "lint": "true",
        "test": "true",
        "build": "mkdir -p dist && printf '%s\\n' \"$EXPECTED_COMMIT\" > dist/version.txt && : > \"$TEST_BUILD_MARKER\"",
        "activate_test": "printf '%s\\n' \"$CURRENT_RELEASE\" >> \"$TEST_ACTIVATION_LOG\"",
        "activate_production": "printf '%s\\n' \"$CURRENT_RELEASE\" >> \"$TEST_ACTIVATION_LOG\"",
    },
    "artifact_paths": ["dist"],
    "health_urls": {
        "test": "http://127.0.0.1:19001/health",
        "production": "http://127.0.0.1:19002/health",
    },
    "release_retention": 3,
    "clean_excludes": [],
    "execution": {
        "node_label": "fixture-deploy-node",
        "deploy_script_path": str(pathlib.Path(test_deploy).parent / "bin" / "deploy-from-git.sh"),
        "lock_file": str(pathlib.Path(test_deploy).parent / "locks" / "fixture-app.lock"),
    },
}
pathlib.Path(config).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

rendered="$TEST_ROOT/rendered"
"$PYTHON_BIN" "$RENDERER" --config "$config" --output "$rendered"
configured_deploy_script="$($PYTHON_BIN -c 'import json,sys; print(json.load(open(sys.argv[1]))["execution"]["deploy_script_path"])' "$config")"
configured_lock_file="$($PYTHON_BIN -c 'import json,sys; print(json.load(open(sys.argv[1]))["execution"]["lock_file"])' "$config")"
[ -x "$rendered/trigger-deploy.sh" ] || fail 'rendered trigger is missing or not executable'
[ -x "$rendered/deploy-from-git.sh" ] || fail 'rendered deployment is missing or not executable'
[ -f "$rendered/job.xml" ] || fail 'rendered Jenkins job XML is missing'
[ -f "$rendered/manifest.json" ] || fail 'render manifest is missing'
assert_contains "$rendered/trigger-deploy.sh" 'buildWithParameters'
assert_contains "$rendered/deploy-from-git.sh" 'EXPECTED_COMMIT'
assert_contains "$rendered/deploy-from-git.sh" 'cleanup_successful_releases'
assert_contains "$rendered/deploy-from-git.sh" "trap 'cleanup_stage \$?' EXIT"
assert_contains "$rendered/deploy-from-git.sh" "$configured_lock_file"
assert_contains "$rendered/job.xml" '<assignedNode>fixture-deploy-node</assignedNode>'
assert_contains "$rendered/job.xml" '<disabled>false</disabled>'
assert_contains "$rendered/job.xml" '<concurrentBuild>false</concurrentBuild>'
assert_contains "$rendered/job.xml" '<triggers/>'
assert_contains "$rendered/job.xml" "$configured_deploy_script"
if grep -E 'GitHubPushTrigger|SCMTrigger|GenericTrigger' "$rendered/job.xml" >/dev/null; then
  fail 'server-pull job XML unexpectedly contains an automatic trigger'
fi
if grep -R -E '__[A-Z0-9_]+__' "$rendered" >/dev/null; then
  fail 'rendered server-pull output contains unresolved fields'
fi
bash -n "$rendered/trigger-deploy.sh"
bash -n "$rendered/deploy-from-git.sh"
"$PYTHON_BIN" - "$rendered" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
assert manifest["schema_version"] == 2
assert len(manifest["plan_id"]) == 64
assert all(character in "0123456789abcdef" for character in manifest["plan_id"])
assert set(manifest["tooling"]["control_plane"]) == {
    "apply-server-pull-job.sh",
    "install-server-pull-script.sh",
    "jenkins-cli-safe.sh",
    "verify-server-pull-delivery.sh",
}
for name in ("trigger-deploy.sh", "deploy-from-git.sh", "job.xml"):
    assert manifest["files"][name] == hashlib.sha256((root / name).read_bytes()).hexdigest()
PY

bad_config="$TEST_ROOT/bad-config.json"
"$PYTHON_BIN" - "$config" "$bad_config" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
payload["release_retention"] = 1
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
if "$PYTHON_BIN" "$RENDERER" --config "$bad_config" --output "$TEST_ROOT/bad-render" \
  >"$TEST_ROOT/bad-render.stdout" 2>"$TEST_ROOT/bad-render.stderr"; then
  fail 'renderer accepted release retention below two'
fi

nested_config="$TEST_ROOT/nested-config.json"
"$PYTHON_BIN" - "$config" "$nested_config" "$test_source" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
payload["deploy_roots"]["test"] = str(pathlib.Path(sys.argv[3]) / "deployment-inside-source")
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
if "$PYTHON_BIN" "$RENDERER" --config "$nested_config" --output "$TEST_ROOT/nested-render" \
  >"$TEST_ROOT/nested-render.stdout" 2>"$TEST_ROOT/nested-render.stderr"; then
  fail 'renderer accepted nested source and deployment roots'
fi

mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 700 "$TEST_ROOT/bin/flock"

cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=''
headers=''
write_out=''
url=''
data_values=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) destination="$2"; shift 2 ;;
    -D) headers="$2"; shift 2 ;;
    -w) write_out="$2"; shift 2 ;;
    --data-urlencode) data_values="${data_values}${data_values:+
}$2"; shift 2 ;;
    --config|-H|-X|--request|--connect-timeout|--max-time) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_HTTP_TRACE:-}" ]; then
  printf 'url=%s\n' "$url" >>"$FAKE_HTTP_TRACE"
  if [ -n "$data_values" ]; then
    while IFS= read -r value; do printf 'data=%s\n' "$value" >>"$FAKE_HTTP_TRACE"; done <<DATA
$data_values
DATA
  fi
fi
case "$url" in
  */job/fixture-app-deploy/buildWithParameters)
    printf 'HTTP/1.1 201 Created\r\nLocation: /queue/item/42/\r\n\r\n' >"$headers"
    [ -z "$destination" ] || : >"$destination"
    [ -z "$write_out" ] || printf '201'
    ;;
  */queue/item/42/api/json)
    printf '{"cancelled":false,"executable":{"number":7,"url":"http://localhost:18086/job/fixture-app-deploy/7/"}}\n' >"$destination"
    ;;
  */job/fixture-app-deploy/7/api/json)
    printf '{"building":false,"result":"SUCCESS"}\n' >"$destination"
    ;;
  */job/fixture-app-deploy/7/consoleText)
    printf 'Finished: SUCCESS\n' >"$destination"
    ;;
  http://127.0.0.1:19001/health|http://127.0.0.1:19002/health)
    [ -z "$destination" ] || printf 'health\n' >"$destination"
    [ -z "$write_out" ] || printf '%s' "${FAKE_HEALTH_STATUS:-200}"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/curl"
export PATH="$TEST_ROOT/bin:$PATH"
export FAKE_HTTP_TRACE="$TEST_ROOT/http-trace"
export TEST_BUILD_MARKER="$build_marker"
export TEST_ACTIVATION_LOG="$activation_log"

mkdir -p "$fixture/ops/jenkins"
cp "$rendered/trigger-deploy.sh" "$fixture/ops/jenkins/trigger-deploy.sh"
chmod 700 "$fixture/ops/jenkins/trigger-deploy.sh"
git -C "$fixture" add ops/jenkins/trigger-deploy.sh
git -C "$fixture" commit -qm 'test: add trigger'
git -C "$fixture" push -q origin dev
dev_commit="$(git -C "$fixture" rev-parse HEAD)"

export JENKINS_URL='http://localhost:18086'
export JENKINS_USER_ID='fixture-user'
export JENKINS_API_TOKEN='fixture-token-must-not-leak'
TMPDIR="$TEST_ROOT" "$fixture/ops/jenkins/trigger-deploy.sh" --environment test \
  >"$TEST_ROOT/trigger.stdout"
assert_contains "$FAKE_HTTP_TRACE" 'data=DEPLOY_ENV=test'
assert_contains "$FAKE_HTTP_TRACE" 'data=GIT_REF=dev'
assert_contains "$FAKE_HTTP_TRACE" "data=EXPECTED_COMMIT=$dev_commit"
if TMPDIR="$TEST_ROOT" "$fixture/ops/jenkins/trigger-deploy.sh" --environment production \
  >"$TEST_ROOT/wrong-branch.stdout" 2>"$TEST_ROOT/wrong-branch.stderr"; then
  fail 'production trigger accepted the dev branch'
fi
assert_not_contains_tree "$TEST_ROOT" 'fixture-token-must-not-leak'

mkdir -p "$test_deploy/releases"
ln -s 'releases/../../outside-release-root' "$test_deploy/current"
rm -f "$build_marker"
if FAKE_HEALTH_STATUS=200 JENKINS_DEPLOY_HEALTH_ATTEMPTS=1 JENKINS_DEPLOY_HEALTH_INTERVAL_SECONDS=1 \
  DEPLOY_ENV=test GIT_REF=dev EXPECTED_COMMIT="$dev_commit" BUILD_NUMBER=unsafe-current \
  "$rendered/deploy-from-git.sh" >"$TEST_ROOT/unsafe-current.stdout" 2>"$TEST_ROOT/unsafe-current.stderr"; then
  fail 'server deployment accepted current link outside the release root'
fi
[ ! -e "$build_marker" ] || fail 'server deployment built before validating current release state'
unlink "$test_deploy/current"

for old in 1 2 3 4; do
  mkdir -p "$test_deploy/releases/old-$old"
  : >"$test_deploy/releases/old-$old/.successful"
  sleep 0.02
done
ln -s 'releases/old-4' "$test_deploy/current"
printf 'old-3\n' >"$test_deploy/.previous-release"

rm -f "$build_marker"
if DEPLOY_ENV=test GIT_REF=dev EXPECTED_COMMIT=0000000000000000000000000000000000000000 \
  BUILD_NUMBER=1 "$rendered/deploy-from-git.sh" \
  >"$TEST_ROOT/mismatch.stdout" 2>"$TEST_ROOT/mismatch.stderr"; then
  fail 'server deployment accepted a remote commit mismatch'
fi
[ ! -e "$build_marker" ] || fail 'server deployment built before verifying the remote commit'

old_current="$(readlink "$test_deploy/current")"
successful_before="$(find "$test_deploy/releases" -mindepth 2 -maxdepth 2 -name .successful | wc -l | tr -d ' ')"
nested_link_config="$TEST_ROOT/nested-link-config.json"
"$PYTHON_BIN" - "$config" "$nested_link_config" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
payload["commands"]["build"] = "mkdir -p dist/nested && ln -s /etc/passwd dist/nested/leak"
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
nested_link_rendered="$TEST_ROOT/nested-link-rendered"
"$PYTHON_BIN" "$RENDERER" --config "$nested_link_config" --output "$nested_link_rendered" >/dev/null
if FAKE_HEALTH_STATUS=200 JENKINS_DEPLOY_HEALTH_ATTEMPTS=1 JENKINS_DEPLOY_HEALTH_INTERVAL_SECONDS=1 \
  DEPLOY_ENV=test GIT_REF=dev EXPECTED_COMMIT="$dev_commit" BUILD_NUMBER=nested-link \
  "$nested_link_rendered/deploy-from-git.sh" >"$TEST_ROOT/nested-link.stdout" 2>"$TEST_ROOT/nested-link.stderr"; then
  fail 'server deployment accepted a nested symbolic link in an artifact directory'
fi
[ "$(readlink "$test_deploy/current")" = "$old_current" ] || fail 'nested artifact link changed current release'
activation_before_build_failure="$(line_count "$activation_log")"
if TEST_BUILD_MARKER="$TEST_ROOT/missing-parent/build-marker" \
  DEPLOY_ENV=test GIT_REF=dev EXPECTED_COMMIT="$dev_commit" BUILD_NUMBER=build-failure \
  "$rendered/deploy-from-git.sh" >"$TEST_ROOT/build-fail.stdout" 2>"$TEST_ROOT/build-fail.stderr"; then
  fail 'server deployment reported success after a failed build'
fi
[ "$(readlink "$test_deploy/current")" = "$old_current" ] || fail 'build failure changed current release'
[ "$(find "$test_deploy/releases" -mindepth 2 -maxdepth 2 -name .successful | wc -l | tr -d ' ')" -eq "$successful_before" ] || \
  fail 'build failure cleaned successful releases'
activation_after_build_failure="$(line_count "$activation_log")"
[ "$activation_after_build_failure" -eq "$activation_before_build_failure" ] || fail 'build failure ran activation'

if FAKE_HEALTH_STATUS=503 JENKINS_DEPLOY_HEALTH_ATTEMPTS=1 JENKINS_DEPLOY_HEALTH_INTERVAL_SECONDS=1 \
  DEPLOY_ENV=test GIT_REF=dev EXPECTED_COMMIT="$dev_commit" BUILD_NUMBER=2 \
  "$rendered/deploy-from-git.sh" >"$TEST_ROOT/health-fail.stdout" 2>"$TEST_ROOT/health-fail.stderr"; then
  fail 'server deployment reported success after failed health verification'
fi
[ "$(readlink "$test_deploy/current")" = "$old_current" ] || fail 'health failure did not restore current release'
successful_after_failure="$(find "$test_deploy/releases" -mindepth 2 -maxdepth 2 -name .successful | wc -l | tr -d ' ')"
[ "$successful_after_failure" -eq "$successful_before" ] || fail 'health failure cleaned old successful releases'
failed_release="$test_deploy/releases/build-2-${dev_commit:0:12}"
[ -d "$failed_release" ] || fail 'failed candidate was not retained for diagnosis'
[ ! -f "$failed_release/.successful" ] || fail 'failed candidate was marked successful'

printf 'second\n' >>"$fixture/source.txt"
git -C "$fixture" add source.txt
git -C "$fixture" commit -qm 'test: second dev'
git -C "$fixture" push -q origin dev
second_commit="$(git -C "$fixture" rev-parse HEAD)"
FAKE_HEALTH_STATUS=200 JENKINS_DEPLOY_HEALTH_ATTEMPTS=1 JENKINS_DEPLOY_HEALTH_INTERVAL_SECONDS=1 \
  DEPLOY_ENV=test GIT_REF=dev EXPECTED_COMMIT="$second_commit" BUILD_NUMBER=3 \
  "$rendered/deploy-from-git.sh" >"$TEST_ROOT/deploy-success.stdout"
expected_release="build-3-${second_commit:0:12}"
[ "$(readlink "$test_deploy/current")" = "releases/$expected_release" ] || fail 'successful deployment did not activate expected release'
[ -f "$test_deploy/releases/$expected_release/.successful" ] || fail 'successful release was not marked'
successful_after_success="$(find "$test_deploy/releases" -mindepth 2 -maxdepth 2 -name .successful | wc -l | tr -d ' ')"
[ "$successful_after_success" -eq 3 ] || fail 'successful deployment did not enforce retention'
[ -d "$test_deploy/releases/old-4" ] || fail 'cleanup deleted the previous release'
[ ! -e "$failed_release" ] || fail 'later successful deployment retained a stale failed candidate'
if find "$test_deploy/releases" -maxdepth 1 -type d -name '.*.staging.*' -print -quit | grep -q .; then
  fail 'deployment retained a staging directory'
fi

if DEPLOY_ENV=production GIT_REF=dev EXPECTED_COMMIT="$second_commit" BUILD_NUMBER=4 \
  "$rendered/deploy-from-git.sh" >"$TEST_ROOT/env-map.stdout" 2>"$TEST_ROOT/env-map.stderr"; then
  fail 'production deployment accepted the test branch'
fi

printf 'PASS: server-pull Jenkins templates\n'
