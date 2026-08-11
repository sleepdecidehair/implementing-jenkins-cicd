#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-server-pull-control-test.XXXXXX")"

cleanup() {
  cleanup_rc=$?
  trap - EXIT HUP INT TERM
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/jenkins-server-pull-control-test.*|"${TMPDIR:-/tmp}"//jenkins-server-pull-control-test.*)
      find "$TEST_ROOT" -depth -delete
      ;;
    *) printf 'Refusing to remove unexpected test path: %s\n' "$TEST_ROOT" >&2 ;;
  esac
  exit "$cleanup_rc"
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 does not contain: $2"; }

for executable in apply-server-pull-job.sh install-server-pull-script.sh verify-server-pull-delivery.sh; do
  [ -x "$SCRIPT_DIR/$executable" ] || fail "$executable is missing or not executable"
done

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/server/bin" "$TEST_ROOT/server/locks"
config="$TEST_ROOT/server-pull.json"
"$PYTHON_BIN" - "$config" "$TEST_ROOT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2]).resolve()
payload = {
    "schema_version": 2,
    "project_name": "control-fixture",
    "repository_url": "https://github.com/example/control-fixture.git",
    "jenkins_url": "http://localhost:18086",
    "jenkins_job": "control-fixture-deploy",
    "branches": {"test": "dev", "production": "main"},
    "source_roots": {
        "test": str(root / "source-test"),
        "production": str(root / "source-production"),
    },
    "deploy_roots": {
        "test": str(root / "deploy-test"),
        "production": str(root / "deploy-production"),
    },
    "commands": {
        "install": "true",
        "lint": "true",
        "test": "true",
        "build": "mkdir -p dist && printf ok > dist/index.html",
        "activate_test": "true",
        "activate_production": "true",
    },
    "artifact_paths": ["dist"],
    "health_urls": {
        "test": "http://127.0.0.1:19001/health",
        "production": "http://127.0.0.1:19002/health",
    },
    "release_retention": 5,
    "clean_excludes": [],
    "execution": {
        "node_label": "control-deploy-node",
        "deploy_script_path": str(root / "server" / "bin" / "deploy-from-git.sh"),
        "lock_file": str(root / "server" / "locks" / "control-fixture.lock"),
    },
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

bundle="$TEST_ROOT/bundle"
"$PYTHON_BIN" "$SCRIPT_DIR/render-server-pull-templates.py" --config "$config" --output "$bundle" >/dev/null
plan_id="$($PYTHON_BIN "$SCRIPT_DIR/render-server-pull-templates.py" --config "$config" --print-plan-id)"

cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) destination="$2"; shift 2 ;;
    --config|--get|--data-urlencode|-H|-X|--connect-timeout|--max-time) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */computer/control-deploy-node/api/json)
    printf '{"displayName":"control-deploy-node","offline":%s,"temporarilyOffline":false}\n' "${FAKE_NODE_OFFLINE:-false}" >"$destination"
    ;;
  *)
    printf 'controller-matched-cli\n' >"$destination"
    ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/curl"

cat >"$TEST_ROOT/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name=''
for argument in "$@"; do
  case "$argument" in create-job|update-job|list-jobs|get-job|who-am-i) command_name="$argument" ;; esac
done
printf '%s\n' "$command_name" >>"$FAKE_CLI_TRACE"
case "$command_name" in
  list-jobs) printf '%s' "${FAKE_LIST_JOBS:-}" ;;
  get-job) cat "$FAKE_GET_JOB_XML" ;;
  create-job|update-job) cat >"$FAKE_CLI_STDIN"; printf 'ok\n' ;;
  who-am-i) printf 'Authenticated as: control-user\n' ;;
  *) printf 'ok\n' ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/java"

export PATH="$TEST_ROOT/bin:$PATH"
export JENKINS_URL='http://localhost:18086'
export JENKINS_USER_ID='control-user'
export JENKINS_API_TOKEN='control-token-must-not-leak'
export FAKE_CLI_TRACE="$TEST_ROOT/cli-trace"
export FAKE_CLI_STDIN="$TEST_ROOT/cli-stdin.xml"
export FAKE_GET_JOB_XML="$bundle/job.xml"

printf '<project><description>attacker XML</description></project>\n' | \
  "$SCRIPT_DIR/jenkins-cli-safe.sh" write --server-pull-config "$config" --approve "$plan_id" -- \
  update-job control-fixture-deploy >/dev/null
assert_contains "$FAKE_CLI_STDIN" "$plan_id"
if grep -F 'attacker XML' "$FAKE_CLI_STDIN" >/dev/null; then
  fail 'safe CLI forwarded caller-controlled Server Pull XML'
fi
if "$SCRIPT_DIR/jenkins-cli-safe.sh" write --server-pull-config "$config" --approve deadbeef -- \
  update-job control-fixture-deploy >"$TEST_ROOT/wrong-approval.stdout" 2>"$TEST_ROOT/wrong-approval.stderr"; then
  fail 'safe CLI accepted the wrong Server Pull approval identifier'
fi

create_evidence="$TEST_ROOT/job-create-evidence"
FAKE_LIST_JOBS='' "$SCRIPT_DIR/apply-server-pull-job.sh" \
  --config "$config" --bundle "$bundle" --approve "$plan_id" --evidence "$create_evidence" >/dev/null
assert_contains "$FAKE_CLI_TRACE" 'create-job'
[ -f "$create_evidence/applied-job.xml" ] || fail 'Server Pull job create evidence is missing'

update_evidence="$TEST_ROOT/job-update-evidence"
FAKE_LIST_JOBS=$'control-fixture-deploy\n' "$SCRIPT_DIR/apply-server-pull-job.sh" \
  --config "$config" --bundle "$bundle" --approve "$plan_id" --evidence "$update_evidence" >/dev/null
assert_contains "$FAKE_CLI_TRACE" 'update-job'
[ -f "$update_evidence/before-job.xml" ] || fail 'Server Pull job update did not retain prior XML'

install_evidence="$TEST_ROOT/install-evidence"
"$SCRIPT_DIR/install-server-pull-script.sh" \
  --config "$config" --bundle "$bundle" --approve "$plan_id" --evidence "$install_evidence" >/dev/null
installed_script="$TEST_ROOT/server/bin/deploy-from-git.sh"
[ -x "$installed_script" ] || fail 'Server Pull deployment script was not installed executable'
cmp -s "$bundle/deploy-from-git.sh" "$installed_script" || fail 'installed deployment script differs from approved bundle'
[ -f "$install_evidence/installed-script.sha256" ] || fail 'installed script checksum evidence is missing'

tampered_bundle="$TEST_ROOT/tampered-bundle"
cp -R "$bundle" "$tampered_bundle"
printf '# tampered\n' >>"$tampered_bundle/deploy-from-git.sh"
if "$SCRIPT_DIR/install-server-pull-script.sh" \
  --config "$config" --bundle "$tampered_bundle" --approve "$plan_id" \
  --evidence "$TEST_ROOT/tampered-evidence" >"$TEST_ROOT/tampered.stdout" 2>"$TEST_ROOT/tampered.stderr"; then
  fail 'deployment script installer accepted a modified bundle'
fi

verify_evidence="$TEST_ROOT/verify-evidence"
FAKE_LIST_JOBS=$'control-fixture-deploy\n' "$SCRIPT_DIR/verify-server-pull-delivery.sh" \
  --config "$config" --bundle "$bundle" --approve "$plan_id" --output "$verify_evidence" >/dev/null
[ -f "$verify_evidence/node.json" ] || fail 'Server Pull verification did not retain node evidence'
assert_contains "$verify_evidence/runtime-verification.properties" 'rollback=not_exercised'

if FAKE_LIST_JOBS=$'control-fixture-deploy\n' FAKE_NODE_OFFLINE=true "$SCRIPT_DIR/verify-server-pull-delivery.sh" \
  --config "$config" --bundle "$bundle" --approve "$plan_id" --output "$TEST_ROOT/offline-evidence" \
  >"$TEST_ROOT/offline.stdout" 2>"$TEST_ROOT/offline.stderr"; then
  fail 'Server Pull verification accepted an offline execution node'
fi

if grep -R -F 'control-token-must-not-leak' "$TEST_ROOT" >/dev/null 2>&1; then
  fail 'Server Pull control plane leaked the API token'
fi

printf 'PASS: server-pull Jenkins control plane\n'
