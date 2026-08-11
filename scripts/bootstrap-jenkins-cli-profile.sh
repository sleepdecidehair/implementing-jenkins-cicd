#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PLAN_TOOL="${SCRIPT_DIR}/plan-jenkins.py"
CLI="${SCRIPT_DIR}/jenkins-cli-safe.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

plan_path=''
approval=''
controller_env=''
controller_secret=''
output=''
trigger_secret=''
trigger_output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan_path="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    --controller-env) controller_env="${2:-}"; shift 2 ;;
    --controller-secret) controller_secret="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    --trigger-secret) trigger_secret="${2:-}"; shift 2 ;;
    --trigger-output) trigger_output="${2:-}"; shift 2 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
for value in "$plan_path" "$approval" "$controller_env" "$controller_secret" "$output"; do
  [ -n "$value" ] || fail 'missing required argument'
done
if [ -n "$trigger_secret" ] || [ -n "$trigger_output" ]; then
  [ -n "$trigger_secret" ] && [ -n "$trigger_output" ] || fail 'trigger secret and output must be provided together'
fi
[ -f "$controller_env" ] && [ ! -L "$controller_env" ] || fail 'controller environment must be a regular file'
[ -f "$controller_secret" ] && [ ! -L "$controller_secret" ] || fail 'controller secret must be a regular file'
[ -s "$controller_secret" ] || fail 'controller administrator secret is empty'
[ ! -e "$output" ] || fail "CLI profile already exists: $output"
if [ -n "$trigger_secret" ]; then
  [ -f "$trigger_secret" ] && [ ! -L "$trigger_secret" ] && [ -s "$trigger_secret" ] || fail 'trigger secret must be a non-empty regular file'
  [ ! -e "$trigger_output" ] || fail "trigger profile already exists: $trigger_output"
fi
python3 "$PLAN_TOOL" verify --plan "$plan_path" --approve "$approval" >/dev/null

read_env_value() {
  python3 - "$controller_env" "$1" <<'PY'
import sys
name = sys.argv[2]
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key == name:
        if not value:
            raise SystemExit(f"ERROR: empty {name} in controller environment")
        print(value)
        break
else:
    raise SystemExit(f"ERROR: missing {name} in controller environment")
PY
}

jenkins_url="$(python3 - "$plan_path" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["controller"]["url"])
PY
)"
admin_id="$(read_env_value JENKINS_ADMIN_ID)"
trigger_id=''
[ -z "$trigger_secret" ] || trigger_id="$(read_env_value JENKINS_TRIGGER_ID)"
case "$jenkins_url" in
  https://*|http://localhost|http://localhost/*|http://localhost:*|http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*|http://\[::1\]|http://\[::1\]/*|http://\[::1\]:*) ;;
  http://*) fail 'API token bootstrap requires HTTPS or a loopback SSH tunnel' ;;
  *) fail 'Jenkins URL must use HTTP or HTTPS' ;;
esac

private_dir="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-cli-bootstrap.XXXXXX")"
cleanup() {
  cleanup_rc=$?
  trap - EXIT HUP INT TERM
  case "$private_dir" in
    "${TMPDIR:-/tmp}"/jenkins-cli-bootstrap.*|"${TMPDIR:-/tmp}"//jenkins-cli-bootstrap.*) find "$private_dir" -depth -delete ;;
    *) printf 'Refusing to remove unexpected bootstrap path: %s\n' "$private_dir" >&2 ;;
  esac
  exit "$cleanup_rc"
}
trap cleanup EXIT HUP INT TERM

create_profile() {
  profile_user="$1"
  profile_secret_file="$2"
  profile_output="$3"
  token_role="$4"
  curl_config="$private_dir/${token_role}.curl.conf"
  crumb_json="$private_dir/${token_role}.crumb.json"
  token_json="$private_dir/${token_role}.token.json"
  python3 - "$curl_config" "$profile_user" "$profile_secret_file" <<'PY'
import sys
def escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')
password = open(sys.argv[3], encoding="utf-8").read().strip()
if not password:
    raise SystemExit("ERROR: profile password is empty")
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    stream.write(f'user = "{escape(sys.argv[2])}:{escape(password)}"\n')
PY
  chmod 600 "$curl_config"
  curl -fsS --config "$curl_config" "${jenkins_url%/}/crumbIssuer/api/json" -o "$crumb_json"
  crumb_values="$(python3 - "$crumb_json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
print(payload["crumbRequestField"])
print(payload["crumb"])
PY
)"
  crumb_field="$(printf '%s\n' "$crumb_values" | sed -n '1p')"
  crumb="$(printf '%s\n' "$crumb_values" | sed -n '2p')"
  curl -fsS --config "$curl_config" -H "$crumb_field: $crumb" -X POST \
    --data-urlencode "newTokenName=codex-${token_role}-${approval%????????????????????????????????????????????????????}" \
    "${jenkins_url%/}/me/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken" \
    -o "$token_json"
  python3 - "$profile_output" "$jenkins_url" "$profile_user" "$token_json" <<'PY'
import json, os, pathlib, shlex, sys
token_payload = json.load(open(sys.argv[4], encoding="utf-8"))
token = token_payload.get("data", {}).get("tokenValue")
if not token:
    raise SystemExit("ERROR: Jenkins did not return an API token")
path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("x", encoding="utf-8") as stream:
    stream.write(f"export JENKINS_URL={shlex.quote(sys.argv[2])}\n")
    stream.write(f"export JENKINS_USER_ID={shlex.quote(sys.argv[3])}\n")
    stream.write(f"export JENKINS_API_TOKEN={shlex.quote(token)}\n")
os.chmod(path, 0o600)
PY
  (
    # Generated by shlex.quote and private to this installation.
    # shellcheck disable=SC1090
    . "$profile_output"
    export JENKINS_URL JENKINS_USER_ID JENKINS_API_TOKEN
    "$CLI" read who-am-i >/dev/null
  )
  find "$curl_config" "$crumb_json" "$token_json" -delete
}

create_profile "$admin_id" "$controller_secret" "$output" 'admin-cli'
printf 'Jenkins administrator CLI profile created: %s\n' "$output"
if [ -n "$trigger_secret" ]; then
  create_profile "$trigger_id" "$trigger_secret" "$trigger_output" 'deploy-trigger'
  printf 'Jenkins deployment trigger profile created: %s\n' "$trigger_output"
fi
