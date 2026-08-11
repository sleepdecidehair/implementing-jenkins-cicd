#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLI="${SCRIPT_DIR}/jenkins-cli-safe.sh"
PLAN_TOOL="${SCRIPT_DIR}/plan-jenkins.py"
RENDER_TOOL="${SCRIPT_DIR}/render-jenkins-assets.py"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
plan_path=''
bundle=''
approval=''
output=''
run_test_build='false'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan_path="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --run-test-build) run_test_build='true'; shift ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
[ -f "$plan_path" ] || fail '--plan must point to a plan file'
[ -d "$bundle" ] || fail '--bundle must point to a rendered bundle'
[ -n "$approval" ] || fail '--approve is required'
[ -n "$output" ] || fail '--output is required'
[ ! -e "$output" ] || fail "verification output already exists: $output"
python3 "$PLAN_TOOL" verify --plan "$plan_path" --approve "$approval" --require-ready >/dev/null
python3 "$RENDER_TOOL" --plan "$plan_path" --verify-bundle "$bundle" >/dev/null

values="$(python3 - "$plan_path" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
print(plan["job"]["name"])
print(plan["controller"].get("agent_name", "jenkins-agent"))
print(plan["controller"]["url"])
print(plan["delivery"]["health_urls"]["test"])
print(plan["discovery"]["project_root"])
for plugin in plan["plugins"]:
    print(plugin)
PY
)"
job_name="$(printf '%s\n' "$values" | sed -n '1p')"
agent_name="$(printf '%s\n' "$values" | sed -n '2p')"
planned_url="$(printf '%s\n' "$values" | sed -n '3p')"
test_health_url="$(printf '%s\n' "$values" | sed -n '4p')"
project_root="$(printf '%s\n' "$values" | sed -n '5p')"
plugins="$(printf '%s\n' "$values" | sed -n '6,$p')"
[ "${JENKINS_URL%/}" = "${planned_url%/}" ] || fail 'active CLI profile points to a different Jenkins controller'

mkdir -p "$output"
chmod 700 "$output"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-delivery-verify.XXXXXX")"
cleanup() {
  verify_rc=$?
  trap - EXIT HUP INT TERM
  case "$temporary_dir" in
    "${TMPDIR:-/tmp}"/jenkins-delivery-verify.*) find "$temporary_dir" -depth -delete ;;
    *) printf 'Refusing to remove unexpected verification temporary path\n' >&2 ;;
  esac
  exit "$verify_rc"
}
trap cleanup EXIT HUP INT TERM
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'jenkins-cli-safe.*' -print | sort >"$temporary_dir/cli-before.txt"

"$CLI" read who-am-i >"$output/who-am-i.txt"
"$CLI" read version >"$output/version.txt"
"$CLI" read list-plugins >"$output/plugins.txt"
"$CLI" read list-jobs >"$output/jobs.txt"
grep -F -x -- "$job_name" "$output/jobs.txt" >/dev/null || fail "Jenkins job is missing: $job_name"
"$CLI" read get-job "$job_name" >"$output/job.xml"
while IFS= read -r plugin; do
  plugin_name="${plugin%%:*}"
  plugin_version="${plugin#*:}"
  [ -z "$plugin" ] || awk -v name="$plugin_name" -v version="$plugin_version" '$1 == name && $NF == version {found=1} END {exit !found}' "$output/plugins.txt" || \
    fail "required plugin is missing: $plugin"
done <<EOF
$plugins
EOF

expected_job="$bundle/controller/jobs/$job_name.xml"
python3 - "$expected_job" "$output/job.xml" "$approval" "$output/job-pipeline.sha256" <<'PY'
import hashlib, pathlib, sys, xml.etree.ElementTree as ET
expected = ET.parse(sys.argv[1]).getroot()
actual = ET.parse(sys.argv[2]).getroot()
expected_script = expected.findtext("./definition/script") or ""
actual_script = actual.findtext("./definition/script") or ""
if actual_script != expected_script:
    raise SystemExit("ERROR: live Jenkins pipeline differs from the deterministic approved pipeline")
triggers = actual.find("./triggers")
if triggers is None or list(triggers):
    raise SystemExit("ERROR: live Jenkins job contains an automatic trigger")
if sys.argv[3] not in (actual.findtext("./description") or ""):
    raise SystemExit("ERROR: live Jenkins job is not marked with the approved plan")
parameters = {item.findtext("name") for item in actual.findall(".//parameterDefinitions/*")}
if parameters != {"DEPLOY_ENV", "GIT_REF", "EXPECTED_COMMIT"}:
    raise SystemExit(f"ERROR: live Jenkins parameters differ from the managed contract: {parameters}")
pathlib.Path(sys.argv[4]).write_text(hashlib.sha256(actual_script.encode()).hexdigest() + "\n", encoding="utf-8")
PY

curl_config="$temporary_dir/curl.conf"
python3 - "$curl_config" "$JENKINS_USER_ID" "$JENKINS_API_TOKEN" <<'PY'
import sys
def escape(value):
    return value.replace("\\", "\\\\").replace('"', '\\"')
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(f'user = "{escape(sys.argv[2])}:{escape(sys.argv[3])}"\n')
PY
chmod 600 "$curl_config"
curl -fsS --config "$curl_config" --get --data-urlencode 'tree=displayName,offline,temporarilyOffline' \
  "${JENKINS_URL%/}/computer/${agent_name}/api/json" -o "$output/agent.json"
python3 - "$output/agent.json" "$agent_name" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
if payload.get("offline") is not False or payload.get("temporarilyOffline") is True:
    raise SystemExit(f"ERROR: managed Jenkins agent is offline: {sys.argv[2]}")
PY

if [ "$run_test_build" = 'true' ]; then
  project_trigger="$project_root/ops/jenkins/trigger-deploy.sh"
  [ -x "$project_trigger" ] || fail "project deployment trigger is unavailable: $project_trigger"
  "$project_trigger" --environment test \
    | tee "$output/test-deployment.txt"
  curl -fsS --connect-timeout 5 --max-time 15 "$test_health_url" >"$output/test-health-response.txt"
  printf 'test_build=exercised\nrollback=not_exercised\n' \
    >"$output/runtime-verification.properties"
else
  printf 'test_build=not_requested\nrollback=not_exercised\n' >"$output/runtime-verification.properties"
fi

find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'jenkins-cli-safe.*' -print | sort >"$temporary_dir/cli-after.txt"
cmp -s "$temporary_dir/cli-before.txt" "$temporary_dir/cli-after.txt" || \
  fail 'Jenkins CLI left a new temporary directory behind'
find "$output" -type f -exec chmod 600 {} \;
printf 'Jenkins delivery configuration verified: %s\n' "$output"
