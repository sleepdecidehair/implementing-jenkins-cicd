#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PLAN_TOOL="${SCRIPT_DIR}/plan-jenkins.py"
RENDER_TOOL="${SCRIPT_DIR}/render-jenkins-assets.py"
INSTALLER="${SCRIPT_DIR}/install-jenkins-docker.sh"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap-jenkins-cli-profile.sh"
PLUGIN_TOOL="${SCRIPT_DIR}/configure-jenkins-plugins.sh"
JOB_TOOL="${SCRIPT_DIR}/apply-jenkins-job.sh"
VERIFY_TOOL="${SCRIPT_DIR}/verify-jenkins-delivery.sh"
AUDIT_TOOL="${SCRIPT_DIR}/jenkins-readonly-audit.sh"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

plan_path=''
bundle=''
approval=''
project=''
evidence=''
cli_profile=''
trigger_profile=''
deploy_environment=''
backup_evidence=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan_path="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    --project) project="${2:-}"; shift 2 ;;
    --evidence) evidence="${2:-}"; shift 2 ;;
    --cli-profile) cli_profile="${2:-}"; shift 2 ;;
    --trigger-profile) trigger_profile="${2:-}"; shift 2 ;;
    --deploy) deploy_environment="${2:-}"; shift 2 ;;
    --backup-evidence) backup_evidence="${2:-}"; shift 2 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
for required in plan_path bundle approval project evidence; do
  eval "required_value=\${$required}"
  [ -n "$required_value" ] || fail "missing required argument: $required"
done
unset required_value
case "$deploy_environment" in ''|test|production) ;; *) fail '--deploy must be test or production' ;; esac
[ ! -e "$evidence" ] || fail "evidence path already exists: $evidence"
python3 "$PLAN_TOOL" verify --plan "$plan_path" --approve "$approval" --require-ready >/dev/null
python3 "$RENDER_TOOL" --plan "$plan_path" --verify-bundle "$bundle" >/dev/null

plan_values="$(python3 - "$plan_path" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
for value in (
    plan["controller"]["target"],
    plan["controller"]["ssh_target"] or "",
    plan["controller"]["install_dir"],
    plan["discovery"]["project_root"],
):
    if "\n" in str(value):
        raise SystemExit("ERROR: unsafe newline in plan")
    print(value)
PY
)"
target="$(printf '%s\n' "$plan_values" | sed -n '1p')"
ssh_target="$(printf '%s\n' "$plan_values" | sed -n '2p')"
install_dir="$(printf '%s\n' "$plan_values" | sed -n '3p')"
planned_project="$(printf '%s\n' "$plan_values" | sed -n '4p')"
[ "$(CDPATH= cd -- "$project" && pwd -P)" = "$planned_project" ] || fail 'project path differs from the approved plan'

mkdir -p "$evidence"
chmod 700 "$evidence"
python3 "$RENDER_TOOL" --plan "$plan_path" --output "$evidence/project-apply" \
  --apply-project "$project" --approve "$approval"

temporary_controller_env=''
temporary_controller_secret=''
temporary_trigger_secret=''
cleanup() {
  orchestration_rc=$?
  trap - EXIT HUP INT TERM
  if [ -n "$temporary_controller_env" ]; then
    case "$temporary_controller_env" in
      "${TMPDIR:-/tmp}"/jenkins-controller-env.*) find "$temporary_controller_env" -delete 2>/dev/null || true ;;
      *) printf 'Refusing to remove unexpected temporary controller environment path\n' >&2 ;;
    esac
  fi
  if [ -n "$temporary_controller_secret" ]; then
    case "$temporary_controller_secret" in
      "${TMPDIR:-/tmp}"/jenkins-controller-secret.*) find "$temporary_controller_secret" -delete 2>/dev/null || true ;;
      *) printf 'Refusing to remove unexpected temporary controller secret path\n' >&2 ;;
    esac
  fi
  if [ -n "$temporary_trigger_secret" ]; then
    case "$temporary_trigger_secret" in
      "${TMPDIR:-/tmp}"/jenkins-trigger-secret.*) find "$temporary_trigger_secret" -delete 2>/dev/null || true ;;
      *) printf 'Refusing to remove unexpected temporary trigger secret path\n' >&2 ;;
    esac
  fi
  exit "$orchestration_rc"
}
trap cleanup EXIT HUP INT TERM

case "$target" in
  local)
    "$INSTALLER" --plan "$plan_path" --bundle "$bundle" --apply --approve "$approval"
    [ -n "$cli_profile" ] || cli_profile="$install_dir/.jenkins-cli.env"
    [ -n "$trigger_profile" ] || trigger_profile="$install_dir/.jenkins-trigger.env"
    ;;
  ssh)
    [ -n "$cli_profile" ] || cli_profile="$evidence/jenkins-cli.env"
    [ -n "$trigger_profile" ] || trigger_profile="$evidence/jenkins-trigger.env"
    "$INSTALLER" --plan "$plan_path" --bundle "$bundle" --apply --approve "$approval"
    if [ ! -f "$cli_profile" ]; then
      temporary_controller_env="$(mktemp "${TMPDIR:-/tmp}/jenkins-controller-env.XXXXXX")"
      temporary_controller_secret="$(mktemp "${TMPDIR:-/tmp}/jenkins-controller-secret.XXXXXX")"
      temporary_trigger_secret="$(mktemp "${TMPDIR:-/tmp}/jenkins-trigger-secret.XXXXXX")"
      scp -q "${ssh_target}:${install_dir}/.env" "$temporary_controller_env"
      scp -q "${ssh_target}:${install_dir}/secrets/admin_password" "$temporary_controller_secret"
      scp -q "${ssh_target}:${install_dir}/secrets/trigger_password" "$temporary_trigger_secret"
      chmod 600 "$temporary_controller_env" "$temporary_controller_secret" "$temporary_trigger_secret"
      "$BOOTSTRAP" --plan "$plan_path" --approve "$approval" \
        --controller-env "$temporary_controller_env" --controller-secret "$temporary_controller_secret" \
        --output "$cli_profile" --trigger-secret "$temporary_trigger_secret" --trigger-output "$trigger_profile"
      find "$temporary_controller_env" -delete
      find "$temporary_controller_secret" -delete
      find "$temporary_trigger_secret" -delete
      temporary_controller_env=''
      temporary_controller_secret=''
      temporary_trigger_secret=''
    fi
    ;;
  existing)
    [ -n "$cli_profile" ] || fail '--cli-profile is required for an existing Jenkins controller'
    if [ -n "$deploy_environment" ]; then
      [ -n "$trigger_profile" ] || fail '--trigger-profile is required to deploy through an existing Jenkins controller'
    fi
    ;;
  *) fail "unsupported controller target: $target" ;;
esac

[ -f "$cli_profile" ] || fail "Jenkins CLI profile does not exist: $cli_profile"
[ ! -L "$cli_profile" ] || fail 'Jenkins CLI profile must not be a symlink'
profile_mode="$(stat -f '%Lp' "$cli_profile" 2>/dev/null || stat -c '%a' "$cli_profile")"
[ "$profile_mode" = '600' ] || fail 'Jenkins CLI profile permissions must be 0600'
# Profile was generated by bootstrap-jenkins-cli-profile.sh using shlex.quote.
# shellcheck disable=SC1090
. "$cli_profile"
export JENKINS_URL JENKINS_USER_ID JENKINS_API_TOKEN

"$AUDIT_TOOL" "$evidence/read-only-audit"

if [ "$target" = 'existing' ]; then
  plugin_arguments=(--plan "$plan_path" --approve "$approval" --evidence "$evidence/plugins")
  [ -z "$backup_evidence" ] || plugin_arguments+=(--backup-evidence "$backup_evidence")
  "$PLUGIN_TOOL" "${plugin_arguments[@]}"
fi
"$JOB_TOOL" --plan "$plan_path" --bundle "$bundle" --approve "$approval" --evidence "$evidence/job-apply"
"$VERIFY_TOOL" --plan "$plan_path" --bundle "$bundle" --approve "$approval" --output "$evidence/verification"

if [ -n "$deploy_environment" ]; then
  project_trigger="$project/ops/jenkins/trigger-deploy.sh"
  [ -x "$project_trigger" ] || fail "project deployment trigger is unavailable: $project_trigger"
  [ -f "$trigger_profile" ] && [ ! -L "$trigger_profile" ] || fail 'deployment trigger profile is missing or unsafe'
  trigger_profile_mode="$(stat -f '%Lp' "$trigger_profile" 2>/dev/null || stat -c '%a' "$trigger_profile")"
  [ "$trigger_profile_mode" = '600' ] || fail 'deployment trigger profile permissions must be 0600'
  (
    unset JENKINS_URL JENKINS_USER_ID JENKINS_API_TOKEN
    # Generated by bootstrap-jenkins-cli-profile.sh using shlex.quote.
    # shellcheck disable=SC1090
    . "$trigger_profile"
    export JENKINS_URL JENKINS_USER_ID JENKINS_API_TOKEN
    "$project_trigger" --environment "$deploy_environment"
  ) | tee "$evidence/${deploy_environment}-deployment.log"
fi
find "$evidence" -type f -exec chmod 600 {} \;
printf 'Jenkins delivery orchestration completed for plan %s\n' "$approval"
