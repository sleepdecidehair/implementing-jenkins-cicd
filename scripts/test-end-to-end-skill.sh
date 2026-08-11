#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SKILL_DIR="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-skill-test.XXXXXX")"
trap 'find "$TEST_ROOT" -depth -delete' EXIT HUP INT TERM

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

for executable in \
  inspect-project.py \
  check-jenkins-security-baseline.py \
  plan-jenkins.py \
  render-jenkins-assets.py \
  jenkins-cli-safe.sh \
  install-jenkins-docker.sh \
  apply-jenkins-job.sh \
  bootstrap-jenkins-cli-profile.sh \
  verify-jenkins-delivery.sh \
  orchestrate-jenkins-delivery.sh \
  configure-jenkins-plugins.sh; do
  [ -x "$SCRIPT_DIR/$executable" ] || fail "$executable is missing or not executable"
done
[ -x "$SCRIPT_DIR/test-server-pull-control-plane.sh" ] || fail 'Server Pull control-plane test is missing or not executable'
assert_contains "$SCRIPT_DIR/orchestrate-jenkins-delivery.sh" '--trigger-profile'
assert_contains "$SCRIPT_DIR/orchestrate-jenkins-delivery.sh" '.jenkins-trigger.env'
assert_contains "$SCRIPT_DIR/orchestrate-jenkins-delivery.sh" 'jenkins-readonly-audit.sh'
assert_contains "$SKILL_DIR/references/ai-triggered-delivery.md" '| Immutable artifact |'
assert_contains "$SKILL_DIR/references/ai-triggered-delivery.md" '| Server Pull |'
assert_contains "$SKILL_DIR/references/server-pull-templates.md" '"schema_version": 2'
assert_contains "$SKILL_DIR/references/server-pull-templates.md" 'apply-server-pull-job.sh'
assert_contains "$SKILL_DIR/references/server-pull-templates.md" 'verify-server-pull-delivery.sh'
if grep -F 'rollback=verified_by_pipeline_on_failure_not_destructively_exercised' "$SCRIPT_DIR/verify-jenkins-delivery.sh" >/dev/null; then
  fail 'verification script claims rollback verification without exercising rollback'
fi

node_project="$TEST_ROOT/node-app"
mkdir -p "$node_project/src"
printf '%s\n' \
  '{' \
  '  "name": "safe-node-app",' \
  '  "scripts": {' \
  '    "lint": "eslint .",' \
  '    "test": "vitest run",' \
  '    "build": "vite build"' \
  '  }' \
  '}' >"$node_project/package.json"
printf '{"lockfileVersion":3}\n' >"$node_project/package-lock.json"
printf 'FROM node:22-alpine\n' >"$node_project/Dockerfile"
printf 'MUST_NOT_APPEAR=fixture-secret-value\n' >"$node_project/.env"

discovery="$TEST_ROOT/discovery.json"
"$PYTHON_BIN" "$SCRIPT_DIR/inspect-project.py" \
  --project "$node_project" --output "$discovery"

"$PYTHON_BIN" - "$discovery" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["schema_version"] == 1
assert data["project"]["name"] == "safe-node-app"
node = next(app for app in data["applications"] if app["type"] == "node")
assert node["commands"]["install"] == "npm ci"
assert node["commands"]["lint"] == "npm run lint"
assert node["commands"]["test"] == "npm test"
assert node["commands"]["build"] == "npm run build"
assert any(app["type"] == "docker" for app in data["applications"])
PY
assert_not_contains_tree "$discovery" 'fixture-secret-value'

umbrella_project="$TEST_ROOT/umbrella"
nested_project="$umbrella_project/frontend"
mkdir -p "$nested_project"
printf '%s\n' '{"name":"nested-app","scripts":{"build":"vite build"}}' >"$nested_project/package.json"
printf '{"lockfileVersion":3}\n' >"$nested_project/package-lock.json"
git -C "$nested_project" init -q -b dev
git -C "$nested_project" config user.email test@example.invalid
git -C "$nested_project" config user.name 'Nested Fixture'
git -C "$nested_project" remote add origin https://github.com/example/nested-app.git
git -C "$nested_project" add .
git -C "$nested_project" commit -qm 'test: nested fixture'
nested_discovery="$TEST_ROOT/nested-discovery.json"
"$PYTHON_BIN" "$SCRIPT_DIR/inspect-project.py" --project "$umbrella_project" --output "$nested_discovery"
nested_plan="$TEST_ROOT/nested-plan.json"
"$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" create --discovery "$nested_discovery" --output "$nested_plan" \
  --target local --jenkins-url http://localhost:18088 --port 18088 \
  --install-dir "$TEST_ROOT/nested-controller" --job nested-app --app-root frontend \
  --scm-public --allow-agent-local-deploy --activation-confirmed \
  --test-health-url http://127.0.0.1:18080/test-health \
  --production-health-url http://127.0.0.1:18080/production-health
"$PYTHON_BIN" - "$nested_plan" "$nested_project" <<'PY'
import json, pathlib, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert pathlib.Path(plan["discovery"]["project_root"]) == pathlib.Path(sys.argv[2]).resolve()
assert plan["job"]["repository_url"] == "https://github.com/example/nested-app.git"
assert [item["root"] for item in plan["discovery"]["applications"]] == ["."]
assert not plan["questions"], plan["questions"]
PY

maven_project="$TEST_ROOT/maven-app"
mkdir -p "$maven_project/module-a"
printf '<project><modelVersion>4.0.0</modelVersion><modules><module>module-a</module></modules></project>\n' >"$maven_project/pom.xml"
printf '<project><modelVersion>4.0.0</modelVersion></project>\n' >"$maven_project/module-a/pom.xml"
maven_discovery="$TEST_ROOT/maven-discovery.json"
"$PYTHON_BIN" "$SCRIPT_DIR/inspect-project.py" --project "$maven_project" --output "$maven_discovery"
"$PYTHON_BIN" - "$maven_discovery" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
maven = [app for app in data["applications"] if app["type"] == "maven"]
assert len(maven) == 1, maven
assert maven[0]["root"] == "."
PY

polyglot_project="$TEST_ROOT/polyglot"
mkdir -p \
  "$polyglot_project/python-service" \
  "$polyglot_project/go-service" \
  "$polyglot_project/rust-service/src" \
  "$polyglot_project/dotnet-service"
printf '%s\n' \
  '[build-system]' \
  'requires = ["setuptools>=75"]' \
  'build-backend = "setuptools.build_meta"' \
  '[tool.pytest.ini_options]' \
  'testpaths = ["tests"]' >"$polyglot_project/python-service/pyproject.toml"
printf 'setuptools==75.8.0\n' >"$polyglot_project/python-service/requirements.txt"
printf 'module example.invalid/go-service\n\ngo 1.23\n' >"$polyglot_project/go-service/go.mod"
printf '%s\n' \
  '[package]' \
  'name = "rust-service"' \
  'version = "0.1.0"' \
  'edition = "2021"' >"$polyglot_project/rust-service/Cargo.toml"
printf '# lock\n' >"$polyglot_project/rust-service/Cargo.lock"
printf 'fn main() {}\n' >"$polyglot_project/rust-service/src/main.rs"
printf '%s\n' \
  '<Project Sdk="Microsoft.NET.Sdk.Web">' \
  '  <PropertyGroup><TargetFramework>net9.0</TargetFramework></PropertyGroup>' \
  '</Project>' >"$polyglot_project/dotnet-service/App.csproj"
polyglot_discovery="$TEST_ROOT/polyglot-discovery.json"
"$PYTHON_BIN" "$SCRIPT_DIR/inspect-project.py" --project "$polyglot_project" --output "$polyglot_discovery"
"$PYTHON_BIN" - "$polyglot_discovery" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
apps = {app["type"]: app for app in data["applications"]}
assert {"python", "go", "rust", "dotnet"} <= set(apps), apps
assert apps["python"]["commands"] == {
    "install": "python -m pip install -r requirements.txt",
    "test": "python -m pytest",
    "build": "python -m build",
}
assert apps["python"]["artifact_candidates"] == ["dist/*.whl", "dist/*.tar.gz"]
assert apps["go"]["commands"] == {"test": "go test ./...", "build": "go build ./..."}
assert apps["rust"]["commands"] == {
    "test": "cargo test --locked",
    "build": "cargo build --release --locked",
}
assert apps["dotnet"]["commands"] == {
    "install": "dotnet restore",
    "test": "dotnet test --no-restore",
    "build": "dotnet publish --configuration Release --no-restore --output publish",
}
assert apps["dotnet"]["runtime_requirements"] == {"dotnet": "net9.0"}
PY

go_plan="$TEST_ROOT/go-plan.json"
"$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" create \
  --discovery "$polyglot_discovery" --output "$go_plan" \
  --target local --jenkins-url http://localhost:18087 --port 18087 \
  --install-dir "$TEST_ROOT/go-controller" --job go-service --app-root go-service \
  --repo-url https://github.com/example/go-service.git --scm-public \
  --allow-agent-local-deploy --activation-confirmed --agent-toolchain-confirmed \
  --test-health-url http://127.0.0.1:18081/health \
  --production-health-url http://127.0.0.1:18082/health
"$PYTHON_BIN" - "$go_plan" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert any("authoritative deployment artifact output" in item for item in plan["questions"]), plan["questions"]
PY
go_plan_id="$($PYTHON_BIN -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$go_plan")"
if "$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" verify --plan "$go_plan" --approve "$go_plan_id" --require-ready \
  >"$TEST_ROOT/go-ready.stdout" 2>"$TEST_ROOT/go-ready.stderr"; then
  fail 'plan accepted an application with no authoritative deployment artifact output'
fi

plan_one="$TEST_ROOT/plan-one.json"
plan_two="$TEST_ROOT/plan-two.json"
plan_changed="$TEST_ROOT/plan-changed.json"
common_plan_args=(
  create
  --discovery "$discovery"
  --target local
  --jenkins-url http://localhost:18086
  --port 18086
  --job safe-node-app
  --repo-url https://github.com/example/safe-node-app.git
  --scm-public
  --branch master
  --environment test
  --deploy-root "$TEST_ROOT/releases-root"
  --health-url http://127.0.0.1:18080/health
  --install-dir "$TEST_ROOT/jenkins-install"
  --allow-agent-local-deploy
  --activation-confirmed
)
"$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" "${common_plan_args[@]}" --output "$plan_one"
"$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" "${common_plan_args[@]}" --output "$plan_two"
cmp -s "$plan_one" "$plan_two" || fail 'identical evidence did not produce a stable plan'
"$PYTHON_BIN" - "$plan_one" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
assert "build" not in plan["operations"]["allowed_cli_writes"]
assert plan["job"]["trigger_mode"] == "project-script-only"
assert plan["controller"]["image"] == "jenkins/jenkins:2.568.1-jdk21"
assert plan["controller"]["agent_image"] == "jenkins/ssh-agent:8.6.0-jdk21"
assert plan["controller"]["agent_toolchain"]["node"] == "22.18.0"
assert plan["controller"]["agent_toolchain"]["maven"] == "3.9.11"
assert all(":" in plugin for plugin in plan["plugins"]), plan["plugins"]
PY
"$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" "${common_plan_args[@]}" \
  --retention 6 --output "$plan_changed"

plan_id="$($PYTHON_BIN -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$plan_one")"
changed_id="$($PYTHON_BIN -c 'import json,sys; print(json.load(open(sys.argv[1]))["plan_id"])' "$plan_changed")"
[ "$plan_id" != "$changed_id" ] || fail 'material retention change did not invalidate plan approval'
"$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" verify --plan "$plan_one" --approve "$plan_id"
if "$PYTHON_BIN" "$SCRIPT_DIR/plan-jenkins.py" verify --plan "$plan_one" --approve deadbeef \
  >"$TEST_ROOT/bad-plan.stdout" 2>"$TEST_ROOT/bad-plan.stderr"; then
  fail 'invalid plan approval unexpectedly succeeded'
fi

bundle="$TEST_ROOT/bundle"
"$PYTHON_BIN" "$SCRIPT_DIR/render-jenkins-assets.py" \
  --plan "$plan_one" --output "$bundle"
for expected in \
  project/Jenkinsfile \
  project/ops/jenkins/deploy.sh \
  project/ops/jenkins/activate.sh \
  project/ops/jenkins/health-check.sh \
  project/ops/jenkins/rollback.sh \
  project/ops/jenkins/cleanup-releases.sh \
  project/ops/jenkins/trigger-deploy.sh \
  controller/compose.yaml \
  controller/Dockerfile \
  controller/Agent.Dockerfile \
  controller/plugins.txt \
  controller/casc/jenkins.yaml \
  controller/jobs/safe-node-app.xml \
  manifest.json; do
  [ -f "$bundle/$expected" ] || fail "rendered asset is missing: $expected"
done
assert_contains "$bundle/project/Jenkinsfile" 'npm ci'
assert_contains "$bundle/project/Jenkinsfile" 'npm test'
assert_contains "$bundle/project/Jenkinsfile" 'npm run build'
assert_contains "$bundle/project/Jenkinsfile" 'health-check.sh'
assert_contains "$bundle/project/Jenkinsfile" 'cleanup-releases.sh'
assert_contains "$bundle/project/Jenkinsfile" 'GIT_REF'
assert_contains "$bundle/project/Jenkinsfile" 'DEPLOY_ENV'
assert_contains "$bundle/project/Jenkinsfile" 'sshagent'
assert_contains "$bundle/project/Jenkinsfile" 'scp -o BatchMode=yes'
assert_contains "$bundle/project/Jenkinsfile" 'sha256sum -c'
assert_contains "$bundle/project/ops/jenkins/trigger-deploy.sh" 'buildWithParameters'
assert_contains "$bundle/project/ops/jenkins/trigger-deploy.sh" 'DEPLOY_ENV'
assert_contains "$bundle/project/ops/jenkins/trigger-deploy.sh" 'GIT_REF'
assert_contains "$bundle/project/ops/jenkins/trigger-deploy.sh" 'EXPECTED_COMMIT'
assert_contains "$bundle/project/ops/jenkins/trigger-deploy.sh" '/api/json'
assert_contains "$bundle/project/ops/jenkins/trigger-deploy.sh" '/consoleText'
assert_contains "$bundle/controller/jobs/safe-node-app.xml" '<triggers/>'
assert_contains "$bundle/controller/casc/jenkins.yaml" 'name: "jenkins-agent"'
assert_contains "$bundle/controller/casc/jenkins.yaml" 'id: "${JENKINS_TRIGGER_ID}"'
assert_contains "$bundle/controller/casc/jenkins.yaml" 'Job/Build'
assert_contains "$bundle/controller/casc/jenkins.yaml" 'Job/Read'
assert_contains "$bundle/controller/casc/jenkins.yaml" 'manuallyProvidedKeyVerificationStrategy'
assert_contains "$bundle/controller/casc/jenkins.yaml" 'agent_host_ed25519.pub'
if grep -F 'nonVerifyingKeyVerificationStrategy' "$bundle/controller/casc/jenkins.yaml" >/dev/null; then
  fail 'controller configuration disables SSH agent host-key verification'
fi
assert_contains "$bundle/controller/compose.yaml" '127.0.0.1:${JENKINS_HTTP_PORT'
assert_contains "$bundle/controller/compose.yaml" 'agent_host_ed25519:/etc/ssh/ssh_host_ed25519_key:ro'
assert_contains "$bundle/controller/Dockerfile" '--latest=false'
assert_contains "$bundle/controller/Agent.Dockerfile" 'node:22.18.0-bookworm-slim'
assert_contains "$bundle/controller/Agent.Dockerfile" 'maven:3.9.11-eclipse-temurin-21'
if grep -E 'GitHubPushTrigger|SCMTrigger|GenericTrigger' "$bundle/controller/jobs/safe-node-app.xml" >/dev/null; then
  fail 'job XML unexpectedly contains an automatic SCM trigger'
fi
[ -x "$bundle/project/ops/jenkins/trigger-deploy.sh" ] || fail 'project trigger script is not executable'
health_line="$(grep -n 'health-check.sh' "$bundle/project/Jenkinsfile" | head -1 | cut -d: -f1)"
cleanup_line="$(grep -n 'cleanup-releases.sh' "$bundle/project/Jenkinsfile" | head -1 | cut -d: -f1)"
[ "$health_line" -lt "$cleanup_line" ] || fail 'release cleanup is not ordered after health verification'
assert_not_contains_tree "$bundle" '/var/run/docker.sock'
assert_not_contains_tree "$bundle" 'fixture-secret-value'

tampered_bundle="$TEST_ROOT/tampered-bundle"
cp -R "$bundle" "$tampered_bundle"
printf '\n# tampered\n' >>"$tampered_bundle/controller/compose.yaml"
if "$PYTHON_BIN" "$SCRIPT_DIR/render-jenkins-assets.py" --plan "$plan_one" --verify-bundle "$tampered_bundle" \
  >"$TEST_ROOT/tampered.stdout" 2>"$TEST_ROOT/tampered.stderr"; then
  fail 'deterministic bundle verification accepted modified content'
fi

if "$PYTHON_BIN" "$SCRIPT_DIR/render-jenkins-assets.py" \
  --plan "$plan_one" --output "$TEST_ROOT/unapproved-bundle" \
  --apply-project "$node_project" >"$TEST_ROOT/unapproved.stdout" 2>"$TEST_ROOT/unapproved.stderr"; then
  fail 'project files were applied without exact plan approval'
fi

apply_evidence="$TEST_ROOT/apply-evidence"
"$PYTHON_BIN" "$SCRIPT_DIR/render-jenkins-assets.py" \
  --plan "$plan_one" --output "$apply_evidence" \
  --apply-project "$node_project" --approve "$plan_id"
[ -f "$node_project/Jenkinsfile" ] || fail 'approved project apply did not create Jenkinsfile'
[ -x "$node_project/ops/jenkins/cleanup-releases.sh" ] || fail 'cleanup script is not executable'
[ -x "$node_project/ops/jenkins/trigger-deploy.sh" ] || fail 'trigger script is not executable'

deployment_probe="$TEST_ROOT/deployment-probe"
mkdir -p "$deployment_probe/artifact-one" "$deployment_probe/artifact-two"
printf 'one\n' >"$deployment_probe/artifact-one/version.txt"
printf 'two\n' >"$deployment_probe/artifact-two/version.txt"
tar -czf "$deployment_probe/one.tgz" -C "$deployment_probe/artifact-one" .
tar -czf "$deployment_probe/two.tgz" -C "$deployment_probe/artifact-two" .
"$node_project/ops/jenkins/deploy.sh" "$deployment_probe/one.tgz" "$deployment_probe/releases" release-one
"$node_project/ops/jenkins/deploy.sh" "$deployment_probe/two.tgz" "$deployment_probe/releases" release-two
[ "$(readlink "$deployment_probe/releases/current")" = 'releases/release-two' ] || \
  fail 'deploy did not atomically activate the second release'
RELEASES_ROOT="$deployment_probe/releases" "$node_project/ops/jenkins/rollback.sh"
[ "$(readlink "$deployment_probe/releases/current")" = 'releases/release-one' ] || \
  fail 'rollback did not reactivate the previous release'

mkdir -p "$deployment_probe/unsafe-artifact/nested"
ln -s /etc/passwd "$deployment_probe/unsafe-artifact/nested/leak"
tar -czf "$deployment_probe/unsafe-link.tgz" -C "$deployment_probe/unsafe-artifact" .
if "$node_project/ops/jenkins/deploy.sh" "$deployment_probe/unsafe-link.tgz" \
  "$deployment_probe/unsafe-releases" unsafe-link \
  >"$TEST_ROOT/unsafe-artifact.stdout" 2>"$TEST_ROOT/unsafe-artifact.stderr"; then
  fail 'artifact deployment accepted a nested symbolic link'
fi
[ ! -e "$deployment_probe/unsafe-releases/current" ] || fail 'unsafe artifact was activated'

release_root="$TEST_ROOT/releases-root"
mkdir -p "$release_root/releases"
for number in 001 002 003 004 005 006 007; do
  mkdir -p "$release_root/releases/release-$number"
  : >"$release_root/releases/release-$number/.successful"
done
ln -s 'releases/release-007' "$release_root/current"
printf 'release-006\n' >"$release_root/.previous-release"
RELEASES_ROOT="$release_root" RELEASE_RETENTION=5 \
  "$node_project/ops/jenkins/cleanup-releases.sh"
[ "$(find "$release_root/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 5 ] || \
  fail 'cleanup did not retain exactly five successful releases'
[ -d "$release_root/releases/release-007" ] || fail 'cleanup deleted the active release'
[ -d "$release_root/releases/release-006" ] || fail 'cleanup deleted the previous rollback release'
[ ! -e "$release_root/releases/release-001" ] || fail 'cleanup retained an excess old release'
if RELEASES_ROOT='/' RELEASE_RETENTION=5 "$node_project/ops/jenkins/cleanup-releases.sh" \
  >"$TEST_ROOT/unsafe-cleanup.stdout" 2>"$TEST_ROOT/unsafe-cleanup.stderr"; then
  fail 'cleanup accepted filesystem root'
fi

mkdir -p "$TEST_ROOT/bin"
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
    --config|-H|-X|--request|--connect-timeout|--max-time|--retry|--retry-delay)
      shift 2
      ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$destination" ] || exit 2
if [ -n "${FAKE_HTTP_TRACE:-}" ]; then
  printf 'url=%s\n' "$url" >>"$FAKE_HTTP_TRACE"
  if [ -n "$data_values" ]; then
    while IFS= read -r value; do
      printf 'data=%s\n' "$value" >>"$FAKE_HTTP_TRACE"
    done <<DATA
$data_values
DATA
  fi
fi
if [ -n "${FAKE_SLEEP_HTTP_URL:-}" ] && [ "$url" = "$FAKE_SLEEP_HTTP_URL" ]; then
  : >"$FAKE_HTTP_SLEEP_MARKER"
  sleep 3
fi
case "$url" in
  */job/safe-node-app/buildWithParameters)
    [ -n "$headers" ] || exit 3
    printf 'HTTP/1.1 201 Created\r\nLocation: %s\r\n\r\n' "${FAKE_QUEUE_LOCATION:-/queue/item/42/}" >"$headers"
    : >"$destination"
    [ -z "$write_out" ] || printf '201'
    ;;
  */queue/item/42/api/json)
    printf '{"cancelled":false,"executable":{"number":7,"url":"http://localhost:18086/job/safe-node-app/7/"}}\n' >"$destination"
    ;;
  */job/safe-node-app/7/api/json)
    printf '{"building":false,"result":"%s","number":7,"url":"http://localhost:18086/job/safe-node-app/7/"}\n' "${FAKE_BUILD_RESULT:-SUCCESS}" >"$destination"
    ;;
  */job/safe-node-app/7/consoleText)
    printf 'Finished: %s\n' "${FAKE_BUILD_RESULT:-SUCCESS}" >"$destination"
    ;;
  */crumbIssuer/api/json)
    printf '{"crumbRequestField":"Jenkins-Crumb","crumb":"fixture-crumb"}\n' >"$destination"
    ;;
  */generateNewToken)
    printf '{"status":"ok","data":{"tokenValue":"fixture-generated-api-token"}}\n' >"$destination"
    ;;
  */computer/*/api/json)
    printf '{"displayName":"jenkins-agent","offline":false,"temporarilyOffline":false}\n' >"$destination"
    ;;
  *)
    printf 'temporary matched jar\n' >"$destination"
    printf '%s\n' "$destination" >"$FAKE_CLI_JAR_PATH"
    printf '%s\n' "$url" >"$FAKE_CLI_URL"
    ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/curl"

cat >"$TEST_ROOT/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name=''
plugin_name=''
expect_plugin='false'
for argument in "$@"; do
  if [ "$expect_plugin" = 'true' ]; then
    plugin_name="$argument"
    expect_plugin='false'
    continue
  fi
  case "$argument" in
    who-am-i|version|list-jobs|list-plugins|help|get-job|console|create-job|update-job|build|install-plugin|safe-restart|reload-jcasc-configuration)
      command_name="$argument"
      [ "$argument" != 'install-plugin' ] || expect_plugin='true'
      ;;
  esac
done
printf '%s\n' "$command_name" >>"$FAKE_CLI_TRACE"
if [ "${FAKE_SLEEP_COMMAND:-}" = "$command_name" ]; then
  printf 'sleeping\n' >"$FAKE_CLI_SLEEP_MARKER"
  sleep 3
fi
case "$command_name" in
  version) printf '2.568.1\n' ;;
  who-am-i) printf 'Authenticated as: test-user\n' ;;
  list-jobs) printf '%s' "${FAKE_LIST_JOBS:-}" ;;
  list-plugins) [ ! -f "$FAKE_PLUGIN_STATE" ] || cat "$FAKE_PLUGIN_STATE" ;;
  get-job)
    if [ -n "${FAKE_GET_JOB_XML:-}" ]; then cat "$FAKE_GET_JOB_XML"
    else printf '<flow-definition><description>existing</description></flow-definition>\n'; fi
    ;;
  install-plugin)
    plugin_short="${plugin_name%%:*}"
    plugin_version="${plugin_name#*:}"
    printf '%s Fixture %s\n' "$plugin_short" "$plugin_version" >>"$FAKE_PLUGIN_STATE"
    printf 'ok\n'
    ;;
  *) printf 'ok\n' ;;
esac
if [ -n "${FAKE_CLI_STDIN:-}" ] && { [ "$command_name" = 'create-job' ] || [ "$command_name" = 'update-job' ]; }; then
  cat >"$FAKE_CLI_STDIN"
fi
EOF
chmod 700 "$TEST_ROOT/bin/java"

export PATH="$TEST_ROOT/bin:$PATH"
export JENKINS_URL='http://localhost:18086'
export JENKINS_USER_ID='test-user'
export JENKINS_API_TOKEN='cli-secret-must-not-leak'
export FAKE_CLI_JAR_PATH="$TEST_ROOT/cli-jar-path"
export FAKE_CLI_URL="$TEST_ROOT/cli-url"
export FAKE_CLI_TRACE="$TEST_ROOT/cli-trace"
export FAKE_CLI_SLEEP_MARKER="$TEST_ROOT/cli-sleep-marker"
export FAKE_PLUGIN_STATE="$TEST_ROOT/plugin-state"
export FAKE_CLI_STDIN="$TEST_ROOT/cli-stdin.xml"
export FAKE_GET_JOB_XML=''
export FAKE_HTTP_TRACE="$TEST_ROOT/http-trace"
export FAKE_HTTP_SLEEP_MARKER="$TEST_ROOT/http-sleep-marker"

"$SCRIPT_DIR/jenkins-cli-safe.sh" read version >"$TEST_ROOT/version.stdout"
assert_contains "$TEST_ROOT/version.stdout" '2.568.1'
cli_jar="$(sed -n '1p' "$FAKE_CLI_JAR_PATH")"
[ ! -e "$cli_jar" ] || fail 'safe CLI retained its temporary JAR'
export FAKE_SLEEP_COMMAND='version'
"$SCRIPT_DIR/jenkins-cli-safe.sh" read version >"$TEST_ROOT/signal-cli.stdout" 2>"$TEST_ROOT/signal-cli.stderr" &
safe_cli_pid=$!
signal_wait=0
while [ ! -f "$FAKE_CLI_SLEEP_MARKER" ] && [ "$signal_wait" -lt 100 ]; do
  sleep 0.05
  signal_wait=$((signal_wait + 1))
done
[ -f "$FAKE_CLI_SLEEP_MARKER" ] || fail 'safe CLI signal test did not start the Java process'
kill -TERM "$safe_cli_pid"
if wait "$safe_cli_pid"; then
  fail 'safe CLI returned success after SIGTERM'
fi
unset FAKE_SLEEP_COMMAND
signal_cli_jar="$(sed -n '1p' "$FAKE_CLI_JAR_PATH")"
[ ! -e "$(dirname -- "$signal_cli_jar")" ] || fail 'safe CLI signal path retained its temporary JAR directory'
if "$SCRIPT_DIR/jenkins-cli-safe.sh" write update-job safe-node-app \
  >"$TEST_ROOT/no-plan.stdout" 2>"$TEST_ROOT/no-plan.stderr"; then
  fail 'safe CLI allowed a write without an approved plan'
fi
printf '<flow-definition/>\n' | "$SCRIPT_DIR/jenkins-cli-safe.sh" write \
  --plan "$plan_one" --approve "$plan_id" -- update-job safe-node-app
assert_contains "$FAKE_CLI_TRACE" 'update-job'
assert_contains "$FAKE_CLI_STDIN" "$plan_id"
if grep -F '<flow-definition/>' "$FAKE_CLI_STDIN" >/dev/null; then
  fail 'safe CLI forwarded unapproved caller job XML'
fi
if JENKINS_URL='https://wrong-controller.example' "$SCRIPT_DIR/jenkins-cli-safe.sh" write \
  --plan "$plan_one" --approve "$plan_id" -- update-job safe-node-app \
  >"$TEST_ROOT/wrong-controller.stdout" 2>"$TEST_ROOT/wrong-controller.stderr"; then
  fail 'safe CLI allowed a write to a different controller'
fi
if "$SCRIPT_DIR/jenkins-cli-safe.sh" write --plan "$plan_one" --approve "$plan_id" -- update-job other-job \
  >"$TEST_ROOT/wrong-job.stdout" 2>"$TEST_ROOT/wrong-job.stderr"; then
  fail 'safe CLI allowed a different job target'
fi
if "$SCRIPT_DIR/jenkins-cli-safe.sh" write --plan "$plan_one" --approve "$plan_id" -- build safe-node-app \
  -p DEPLOY_ENV=test -p GIT_REF=dev -p EXPECTED_COMMIT=0123456789012345678901234567890123456789 \
  >"$TEST_ROOT/cli-build.stdout" 2>"$TEST_ROOT/cli-build.stderr"; then
  fail 'safe CLI allowed build even though CLI is configuration-only'
fi
assert_not_contains_tree "$TEST_ROOT" 'cli-secret-must-not-leak'

job_create_evidence="$TEST_ROOT/job-create-evidence"
FAKE_LIST_JOBS='' "$SCRIPT_DIR/apply-jenkins-job.sh" \
  --plan "$plan_one" --bundle "$bundle" --evidence "$job_create_evidence" \
  --approve "$plan_id"
assert_contains "$FAKE_CLI_TRACE" 'create-job'
[ -f "$job_create_evidence/applied-job.xml" ] || fail 'job create did not retain applied configuration evidence'

job_update_evidence="$TEST_ROOT/job-update-evidence"
FAKE_LIST_JOBS=$'safe-node-app\n' "$SCRIPT_DIR/apply-jenkins-job.sh" \
  --plan "$plan_one" --bundle "$bundle" --evidence "$job_update_evidence" \
  --approve "$plan_id"
assert_contains "$FAKE_CLI_TRACE" 'update-job'
[ -f "$job_update_evidence/before-job.xml" ] || fail 'job update did not back up prior configuration'

git -C "$node_project" init -q -b dev
git -C "$node_project" config user.email test@example.invalid
git -C "$node_project" config user.name 'Jenkins Skill Test'
git -C "$node_project" add .
git -C "$node_project" commit -qm 'test: fixture'
git init -q --bare "$TEST_ROOT/remote.git"
git -C "$node_project" remote add origin "$TEST_ROOT/remote.git"
git -C "$node_project" push -q -u origin dev
mkdir -p "$TEST_ROOT/trigger-tmp"
TMPDIR="$TEST_ROOT/trigger-tmp" "$node_project/ops/jenkins/trigger-deploy.sh" --environment test
assert_contains "$FAKE_HTTP_TRACE" 'url=http://localhost:18086/job/safe-node-app/buildWithParameters'
assert_contains "$FAKE_HTTP_TRACE" 'data=DEPLOY_ENV=test'
assert_contains "$FAKE_HTTP_TRACE" 'data=GIT_REF=dev'
assert_contains "$FAKE_HTTP_TRACE" "data=EXPECTED_COMMIT=$(git -C "$node_project" rev-parse HEAD)"
if grep -F -x 'build' "$FAKE_CLI_TRACE" >/dev/null; then
  fail 'deployment trigger unexpectedly used the Jenkins CLI build command'
fi
export FAKE_SLEEP_HTTP_URL='http://localhost:18086/queue/item/42/api/json'
TMPDIR="$TEST_ROOT/trigger-tmp" "$node_project/ops/jenkins/trigger-deploy.sh" --environment test \
  >"$TEST_ROOT/signal-trigger.stdout" 2>"$TEST_ROOT/signal-trigger.stderr" &
trigger_pid=$!
trigger_wait=0
while [ ! -f "$FAKE_HTTP_SLEEP_MARKER" ] && [ "$trigger_wait" -lt 100 ]; do
  sleep 0.05
  trigger_wait=$((trigger_wait + 1))
done
[ -f "$FAKE_HTTP_SLEEP_MARKER" ] || fail 'project trigger signal test did not reach queue polling'
kill -TERM "$trigger_pid"
if wait "$trigger_pid"; then
  fail 'project trigger returned success after SIGTERM'
fi
unset FAKE_SLEEP_HTTP_URL
if TMPDIR="$TEST_ROOT/trigger-tmp" FAKE_BUILD_RESULT=FAILURE \
  "$node_project/ops/jenkins/trigger-deploy.sh" --environment test \
  >"$TEST_ROOT/failed-build.stdout" 2>"$TEST_ROOT/failed-build.stderr"; then
  fail 'project trigger reported a failed Jenkins build as successful'
fi
if TMPDIR="$TEST_ROOT/trigger-tmp" FAKE_QUEUE_LOCATION='https://attacker.example/queue/item/42/' \
  "$node_project/ops/jenkins/trigger-deploy.sh" --environment test \
  >"$TEST_ROOT/unsafe-queue.stdout" 2>"$TEST_ROOT/unsafe-queue.stderr"; then
  fail 'project trigger trusted a queue URL on another controller'
fi
if grep -F 'url=https://attacker.example' "$FAKE_HTTP_TRACE" >/dev/null; then
  fail 'project trigger sent Jenkins credentials to an untrusted queue URL'
fi
if find "$TEST_ROOT/trigger-tmp" -mindepth 1 -print -quit | grep -q .; then
  fail 'project trigger retained a temporary credential directory'
fi
assert_not_contains_tree "$TEST_ROOT" 'cli-secret-must-not-leak'
remote_tip="$(git -C "$node_project" rev-parse HEAD)"
if TMPDIR="$TEST_ROOT/trigger-tmp" "$node_project/ops/jenkins/trigger-deploy.sh" \
  --environment production --commit "$remote_tip" \
  >"$TEST_ROOT/branch-bypass.stdout" 2>"$TEST_ROOT/branch-bypass.stderr"; then
  fail '--commit bypassed the required production branch check'
fi

plugin_evidence="$TEST_ROOT/plugin-evidence"
if "$SCRIPT_DIR/configure-jenkins-plugins.sh" \
  --plan "$plan_one" --approve "$plan_id" --evidence "$TEST_ROOT/boolean-backup-evidence" --backup-confirmed \
  >"$TEST_ROOT/boolean-backup.stdout" 2>"$TEST_ROOT/boolean-backup.stderr"; then
  fail 'plugin configuration accepted a boolean-only backup claim'
fi
backup_archive="$TEST_ROOT/jenkins-home-backup.tar"
printf 'verified backup fixture\n' >"$backup_archive"
backup_hash="$(shasum -a 256 "$backup_archive" | awk '{print $1}')"
backup_record="$TEST_ROOT/backup-evidence.json"
"$PYTHON_BIN" - "$backup_record" "$backup_archive" "$backup_hash" <<'PY'
import json, pathlib, sys
payload = {
    "schema_version": 1,
    "backup_id": "fixture-backup-001",
    "path": str(pathlib.Path(sys.argv[2]).resolve()),
    "sha256": sys.argv[3],
    "created_at": "2026-08-05T12:00:00+08:00",
    "restore_tested": True,
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload) + "\n", encoding="utf-8")
PY
"$SCRIPT_DIR/configure-jenkins-plugins.sh" \
  --plan "$plan_one" --approve "$plan_id" --evidence "$plugin_evidence" --backup-evidence "$backup_record"
assert_contains "$FAKE_CLI_TRACE" 'install-plugin'
[ -f "$plugin_evidence/plugins-after.txt" ] || fail 'plugin configuration did not retain verification evidence'

verification_evidence="$TEST_ROOT/verification-evidence"
export FAKE_GET_JOB_XML="$bundle/controller/jobs/safe-node-app.xml"
FAKE_LIST_JOBS=$'safe-node-app\n' "$SCRIPT_DIR/verify-jenkins-delivery.sh" \
  --plan "$plan_one" --bundle "$bundle" --approve "$plan_id" --output "$verification_evidence"
[ -f "$verification_evidence/agent.json" ] || fail 'verification did not retain managed agent evidence'
assert_contains "$verification_evidence/runtime-verification.properties" 'test_build=not_requested'

controller_env="$TEST_ROOT/controller.env"
printf '%s\n' \
  'JENKINS_ADMIN_ID=admin' \
  'JENKINS_TRIGGER_ID=codex-deploy' >"$controller_env"
chmod 600 "$controller_env"
controller_secret="$TEST_ROOT/controller-admin-password"
printf '%s\n' 'bootstrap-password-fixture' >"$controller_secret"
chmod 600 "$controller_secret"
trigger_secret="$TEST_ROOT/controller-trigger-password"
printf '%s\n' 'trigger-password-fixture' >"$trigger_secret"
chmod 600 "$trigger_secret"
cli_profile="$TEST_ROOT/jenkins-cli.env"
trigger_profile="$TEST_ROOT/jenkins-trigger.env"
"$SCRIPT_DIR/bootstrap-jenkins-cli-profile.sh" \
  --plan "$plan_one" --approve "$plan_id" \
  --controller-env "$controller_env" --controller-secret "$controller_secret" --output "$cli_profile" \
  --trigger-secret "$trigger_secret" --trigger-output "$trigger_profile"
assert_contains "$cli_profile" 'JENKINS_API_TOKEN='
assert_contains "$cli_profile" 'fixture-generated-api-token'
assert_contains "$cli_profile" 'JENKINS_USER_ID=admin'
assert_contains "$trigger_profile" 'JENKINS_API_TOKEN='
assert_contains "$trigger_profile" 'JENKINS_USER_ID=codex-deploy'
if grep -F 'JENKINS_USER_ID=admin' "$trigger_profile" >/dev/null; then
  fail 'deployment trigger profile reused the administrator identity'
fi
[ "$(stat -f '%Lp' "$cli_profile" 2>/dev/null || stat -c '%a' "$cli_profile")" = '600' ] || \
  fail 'CLI profile permissions are not 0600'
[ "$(stat -f '%Lp' "$trigger_profile" 2>/dev/null || stat -c '%a' "$trigger_profile")" = '600' ] || \
  fail 'trigger profile permissions are not 0600'

cat >"$TEST_ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_DOCKER_TRACE"
if [ "${1:-}" = 'compose' ] && [ "${2:-}" = 'version' ]; then
  printf 'Docker Compose version v2.30.0\n'
elif [ "${1:-}" = 'image' ] && [ "${2:-}" = 'inspect' ]; then
  printf 'jenkins/jenkins@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
fi
EOF
chmod 700 "$TEST_ROOT/bin/docker"
export FAKE_DOCKER_TRACE="$TEST_ROOT/docker-trace"
export JENKINS_INSTALL_SKIP_HEALTH=1

if "$SCRIPT_DIR/install-jenkins-docker.sh" --plan "$plan_one" --bundle "$bundle" --apply \
  >"$TEST_ROOT/install-no-approval.stdout" 2>"$TEST_ROOT/install-no-approval.stderr"; then
  fail 'installer applied without exact plan approval'
fi
"$SCRIPT_DIR/install-jenkins-docker.sh" --plan "$plan_one" --bundle "$bundle" \
  --apply --approve "$plan_id"
[ -f "$TEST_ROOT/jenkins-install/compose.yaml" ] || fail 'installer did not copy controller assets'
[ -f "$TEST_ROOT/jenkins-install/secrets/agent_ed25519" ] || fail 'installer did not create the managed agent key'
[ -f "$TEST_ROOT/jenkins-install/secrets/agent_host_ed25519" ] || fail 'installer did not create a persistent agent host key'
[ -f "$TEST_ROOT/jenkins-install/secrets/admin_password" ] || fail 'installer did not create the controller secret'
[ -f "$TEST_ROOT/jenkins-install/secrets/trigger_password" ] || fail 'installer did not create the trigger-user secret'
assert_contains "$FAKE_DOCKER_TRACE" 'compose'
assert_not_contains_tree "$TEST_ROOT/jenkins-install" '/var/run/docker.sock'

"$SCRIPT_DIR/test-jenkins-readonly-audit.sh" >/dev/null
"$SCRIPT_DIR/test-server-pull-templates.sh" >/dev/null
"$SCRIPT_DIR/test-server-pull-control-plane.sh" >/dev/null

printf 'PASS: end-to-end Jenkins skill\n'
