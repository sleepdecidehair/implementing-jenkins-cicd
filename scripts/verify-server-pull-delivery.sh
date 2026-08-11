#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RENDERER="${SCRIPT_DIR}/render-server-pull-templates.py"
CLI="${SCRIPT_DIR}/jenkins-cli-safe.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
hash_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else fail 'shasum or sha256sum is required'
  fi
}

config=''
bundle=''
approval=''
output=''
ssh_target=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) config="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --ssh-target) ssh_target="${2:-}"; shift 2 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
for value in "$config" "$bundle" "$approval" "$output"; do [ -n "$value" ] || fail 'missing required argument'; done
[ ! -e "$output" ] || fail "verification output already exists: $output"
verified_plan="$(python3 "$RENDERER" --config "$config" --verify-output "$bundle")"
[ "$approval" = "$verified_plan" ] || fail 'verification requires the exact Server Pull approval identifier'

values="$(python3 - "$config" <<'PY'
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
for value in (config["jenkins_job"], config["execution"]["node_label"], config["execution"]["deploy_script_path"]):
    print(value)
PY
)"
job_name="$(printf '%s\n' "$values" | sed -n '1p')"
node_label="$(printf '%s\n' "$values" | sed -n '2p')"
deploy_path="$(printf '%s\n' "$values" | sed -n '3p')"
expected_hash="$(python3 - "$bundle/manifest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["files"]["deploy-from-git.sh"])
PY
)"

mkdir -p "$output"
chmod 700 "$output"
"$CLI" read list-jobs >"$output/jobs.txt"
grep -F -x -- "$job_name" "$output/jobs.txt" >/dev/null || fail "Server Pull job is missing: $job_name"
"$CLI" read get-job "$job_name" >"$output/job.xml"
python3 - "$output/job.xml" "$approval" "$node_label" "$deploy_path" <<'PY'
import pathlib
import sys
import xml.etree.ElementTree as ET

path, approval, node_label, deploy_path = sys.argv[1:]
try:
    root = ET.parse(path).getroot()
except (ET.ParseError, OSError) as error:
    raise SystemExit(f"ERROR: cannot parse live Server Pull job XML: {error}")
if root.tag != "project":
    raise SystemExit("ERROR: live Server Pull job is not a Freestyle project")
if approval not in (root.findtext("description") or ""):
    raise SystemExit("ERROR: live Server Pull job does not contain the approved plan identifier")
parameters = {item.findtext("name") for item in root.findall(".//parameterDefinitions/*")}
if parameters != {"DEPLOY_ENV", "GIT_REF", "EXPECTED_COMMIT"}:
    raise SystemExit(f"ERROR: live Server Pull parameters differ from contract: {parameters}")
triggers = root.find("triggers")
if triggers is None or list(triggers):
    raise SystemExit("ERROR: live Server Pull job contains automatic triggers")
if root.findtext("concurrentBuild") != "false":
    raise SystemExit("ERROR: concurrent Server Pull builds are not disabled")
if root.findtext("assignedNode") != node_label or root.findtext("canRoam") != "false":
    raise SystemExit("ERROR: live Server Pull job is not bound to the approved node")
if root.findtext("./builders/hudson.tasks.Shell/command") != deploy_path:
    raise SystemExit("ERROR: live Server Pull job invokes a different deployment script")
PY

private_dir="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-server-pull-verify.XXXXXX")"
cleanup() {
  cleanup_rc=$?
  trap - EXIT HUP INT TERM
  case "$private_dir" in
    "${TMPDIR:-/tmp}"/jenkins-server-pull-verify.*|"${TMPDIR:-/tmp}"//jenkins-server-pull-verify.*) find "$private_dir" -depth -delete ;;
    *) printf 'Refusing to remove unexpected verification path: %s\n' "$private_dir" >&2 ;;
  esac
  unset JENKINS_API_TOKEN
  exit "$cleanup_rc"
}
trap cleanup EXIT HUP INT TERM
curl_config="$private_dir/curl.conf"
python3 - "$curl_config" "$JENKINS_USER_ID" "$JENKINS_API_TOKEN" <<'PY'
import sys
def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(f'user = "{escape(sys.argv[2])}:{escape(sys.argv[3])}"\n')
PY
chmod 600 "$curl_config"
curl -fsS --config "$curl_config" "${JENKINS_URL%/}/computer/${node_label}/api/json" -o "$output/node.json"
python3 - "$output/node.json" "$node_label" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
if payload.get("displayName") != sys.argv[2]:
    raise SystemExit("ERROR: Jenkins returned a different execution node")
if payload.get("offline") is not False or payload.get("temporarilyOffline") is True:
    raise SystemExit(f"ERROR: Server Pull execution node is offline: {sys.argv[2]}")
PY

if [ -z "$ssh_target" ]; then
  [ -f "$deploy_path" ] && [ ! -L "$deploy_path" ] || fail 'installed deployment script is missing or unsafe'
  installed_hash="$(hash_file "$deploy_path")"
else
  case "$ssh_target" in ''|*[!A-Za-z0-9_.@:-]*) fail 'unsafe SSH target' ;; esac
  case "$deploy_path" in *[!A-Za-z0-9_./-]*) fail 'remote deployment script path contains unsupported characters' ;; esac
  installed_hash="$(ssh "$ssh_target" "set -eu; [ -f '$deploy_path' ] && [ ! -L '$deploy_path' ]; if command -v sha256sum >/dev/null; then sha256sum '$deploy_path' | awk '{print \\$1}'; else shasum -a 256 '$deploy_path' | awk '{print \\$1}'; fi")"
fi
[ "$installed_hash" = "$expected_hash" ] || fail 'installed deployment script hash differs from approved bundle'
printf '%s\n' "$installed_hash" >"$output/installed-script.sha256"
printf 'test_build=not_requested\nrollback=not_exercised\n' >"$output/runtime-verification.properties"
find "$output" -type f -exec chmod 600 {} \;
printf 'Jenkins Server Pull delivery configuration verified: %s\n' "$output"
