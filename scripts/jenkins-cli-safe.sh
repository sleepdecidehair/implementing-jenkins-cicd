#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PLAN_TOOL="${SCRIPT_DIR}/plan-jenkins.py"
RENDER_TOOL="${SCRIPT_DIR}/render-jenkins-assets.py"
SERVER_PULL_RENDERER="${SCRIPT_DIR}/render-server-pull-templates.py"

usage() {
  printf 'Usage:\n' >&2
  printf '  %s read COMMAND [ARGUMENT ...]\n' "$(basename -- "$0")" >&2
  printf '  %s write --plan PLAN --approve PLAN_ID -- COMMAND [ARGUMENT ...]\n' "$(basename -- "$0")" >&2
  printf '  %s write --server-pull-config CONFIG --approve PLAN_ID -- create-job|update-job JOB\n' "$(basename -- "$0")" >&2
  printf 'Required environment: JENKINS_URL, JENKINS_USER_ID, JENKINS_API_TOKEN\n' >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

[ "$#" -ge 2 ] || { usage; exit 2; }
mode="$1"
shift
plan_path=''
server_pull_config=''
approval=''

case "$mode" in
  read)
    command_name="$1"
    shift
    case "$command_name" in
      who-am-i|version|list-jobs|list-plugins|help|get-job|console) ;;
      *) fail "command is not in the read allowlist: $command_name" ;;
    esac
    ;;
  write)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --plan)
          [ "$#" -ge 2 ] || fail '--plan requires a value'
          plan_path="$2"
          shift 2
          ;;
        --server-pull-config)
          [ "$#" -ge 2 ] || fail '--server-pull-config requires a value'
          server_pull_config="$2"
          shift 2
          ;;
        --approve)
          [ "$#" -ge 2 ] || fail '--approve requires a value'
          approval="$2"
          shift 2
          ;;
        --)
          shift
          break
          ;;
        *) fail "unsupported write option: $1" ;;
      esac
    done
    [ "$#" -ge 1 ] || fail 'write command is required after --'
    command_name="$1"
    shift
    if [ -n "$plan_path" ] && [ -n "$server_pull_config" ]; then
      fail 'write mode accepts either --plan or --server-pull-config, not both'
    fi
    [ -n "$plan_path" ] || [ -n "$server_pull_config" ] || \
      fail 'write mode requires --plan or --server-pull-config'
    [ -n "$approval" ] || fail 'write mode requires --approve'
    if [ -n "$plan_path" ]; then
      [ -x "$PLAN_TOOL" ] || fail "plan verifier is unavailable: $PLAN_TOOL"
      python3 "$PLAN_TOOL" verify --plan "$plan_path" --approve "$approval" --require-ready >/dev/null
      case "$command_name" in
        create-job|install-plugin|reload-jcasc-configuration|safe-restart|update-job) ;;
        *) fail "command is not in the write allowlist: $command_name" ;;
      esac
      python3 - "$plan_path" "$command_name" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
allowed = plan.get("operations", {}).get("allowed_cli_writes", [])
if sys.argv[2] not in allowed:
    raise SystemExit(f"ERROR: command is not authorized by the plan: {sys.argv[2]}")
PY
    else
      [ -x "$SERVER_PULL_RENDERER" ] || fail "Server Pull verifier is unavailable: $SERVER_PULL_RENDERER"
      [ -f "$server_pull_config" ] || fail 'Server Pull configuration does not exist'
      expected_approval="$(python3 "$SERVER_PULL_RENDERER" --config "$server_pull_config" --print-plan-id)"
      [ "$approval" = "$expected_approval" ] || fail 'Server Pull write requires the exact approval identifier'
      case "$command_name" in create-job|update-job) ;; *) fail "command is not allowed for Server Pull configuration: $command_name" ;; esac
    fi
    ;;
  *)
    usage
    fail "mode must be read or write"
    ;;
esac

missing=''
for variable_name in JENKINS_URL JENKINS_USER_ID JENKINS_API_TOKEN; do
  eval "variable_value=\${${variable_name}:-}"
  if [ -z "$variable_value" ]; then
    missing="${missing}${missing:+, }${variable_name}"
  fi
done
unset variable_value
[ -z "$missing" ] || fail "missing required environment variables: $missing"

case "$JENKINS_URL" in
  http://*|https://*) ;;
  *) fail 'JENKINS_URL must use HTTP or HTTPS' ;;
esac
authority="${JENKINS_URL#*://}"
authority="${authority%%/*}"
case "$authority" in
  *@*) fail 'JENKINS_URL must not contain embedded credentials' ;;
  *[[:space:]]*) fail 'JENKINS_URL must not contain whitespace' ;;
esac
case "$JENKINS_URL" in
  *'?'*|*'#'*) fail 'JENKINS_URL must not contain a query or fragment' ;;
esac
case "$JENKINS_URL" in
  http://localhost|http://localhost/*|http://localhost:*|http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*|http://\[::1\]|http://\[::1\]/*|http://\[::1\]:*) ;;
  http://*) fail 'credential-bearing Jenkins CLI traffic requires HTTPS or a loopback SSH tunnel' ;;
esac

if [ "$mode" = 'write' ]; then
  if [ -n "$plan_path" ]; then
    python3 - "$plan_path" "$JENKINS_URL" "$command_name" "$@" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
actual_url = sys.argv[2].rstrip("/")
command = sys.argv[3]
args = sys.argv[4:]
planned_url = str(plan["controller"]["url"]).rstrip("/")
if actual_url != planned_url:
    raise SystemExit(f"ERROR: write target {actual_url} differs from approved controller {planned_url}")
job_name = plan["job"]["name"]
if command in {"create-job", "update-job"}:
    if args != [job_name]:
        raise SystemExit(f"ERROR: {command} is approved only for job {job_name}")
elif command == "install-plugin":
    if len(args) not in {1, 2} or args[0] not in plan["plugins"] or (len(args) == 2 and args[1] != "-deploy"):
        raise SystemExit("ERROR: plugin mutation differs from the approved plugin set")
elif command in {"safe-restart", "reload-jcasc-configuration"}:
    if args:
        raise SystemExit(f"ERROR: {command} does not accept plan-approved arguments")
PY
  else
    python3 - "$server_pull_config" "$JENKINS_URL" "$command_name" "$@" <<'PY'
import json, sys
config = json.load(open(sys.argv[1], encoding="utf-8"))
actual_url = sys.argv[2].rstrip("/")
command = sys.argv[3]
args = sys.argv[4:]
planned_url = str(config["jenkins_url"]).rstrip("/")
if actual_url != planned_url:
    raise SystemExit(f"ERROR: write target {actual_url} differs from approved controller {planned_url}")
job_name = config["jenkins_job"]
if command not in {"create-job", "update-job"} or args != [job_name]:
    raise SystemExit(f"ERROR: {command} is approved only for Server Pull job {job_name}")
PY
  fi
fi

for required_command in curl java python3; do
  command -v "$required_command" >/dev/null 2>&1 || fail "required command is unavailable: $required_command"
done

for argument in "$@"; do
  case "$argument" in
    *"${JENKINS_API_TOKEN}"*) fail 'a CLI argument contains the Jenkins API token' ;;
    *token=*|*password=*) fail 'credentials must not be passed as CLI arguments' ;;
  esac
done

tmp_base="${TMPDIR:-/tmp}"
private_dir="$(mktemp -d "${tmp_base%/}/jenkins-cli-safe.XXXXXX")"
cli_jar="$private_dir/jenkins-cli.jar"

remove_private_dir() {
  trap - EXIT HUP INT TERM
  case "$private_dir" in
    "${tmp_base%/}"/jenkins-cli-safe.*)
      find "$private_dir" -depth -delete
      ;;
    *)
      printf 'Refusing to remove unexpected temporary path: %s\n' "$private_dir" >&2
      ;;
  esac
  unset JENKINS_API_TOKEN
}

cleanup_on_exit() {
  cleanup_status=$?
  remove_private_dir
  exit "$cleanup_status"
}

cleanup_on_signal() {
  signal_status="$1"
  remove_private_dir
  exit "$signal_status"
}

trap cleanup_on_exit EXIT
trap 'cleanup_on_signal 129' HUP
trap 'cleanup_on_signal 130' INT
trap 'cleanup_on_signal 143' TERM

curl -fsSL "${JENKINS_URL%/}/jnlpJars/jenkins-cli.jar" -o "$cli_jar"
chmod 600 "$cli_jar"

approved_input=''
if [ "$mode" = 'write' ] && { [ "$command_name" = 'create-job' ] || [ "$command_name" = 'update-job' ]; }; then
  approved_bundle="$private_dir/approved-bundle"
  if [ -n "$plan_path" ]; then
    python3 "$RENDER_TOOL" --plan "$plan_path" --output "$approved_bundle" >/dev/null
    approved_input="$approved_bundle/controller/jobs/$1.xml"
  else
    python3 "$SERVER_PULL_RENDERER" --config "$server_pull_config" --output "$approved_bundle" >/dev/null
    approved_input="$approved_bundle/job.xml"
  fi
  [ -f "$approved_input" ] || fail 'approved deterministic job XML was not rendered'
fi

cli_arguments=("$command_name" "$@")

if [ -n "$approved_input" ]; then
  java -jar "$cli_jar" -s "${JENKINS_URL%/}" -webSocket "${cli_arguments[@]}" <"$approved_input"
else
  java -jar "$cli_jar" -s "${JENKINS_URL%/}" -webSocket "${cli_arguments[@]}"
fi
