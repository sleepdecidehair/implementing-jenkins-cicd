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
evidence=''
approval=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan_path="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --evidence) evidence="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
for value_name in plan_path bundle evidence approval; do
  eval "value=\${$value_name}"
  [ -n "$value" ] || fail "missing required value: $value_name"
done
unset value
[ ! -e "$evidence" ] || fail "evidence path already exists: $evidence"
python3 "$PLAN_TOOL" verify --plan "$plan_path" --approve "$approval" --require-ready >/dev/null

job_name="$(python3 - "$plan_path" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["job"]["name"])
PY
)"
case "$job_name" in
  ''|*[!A-Za-z0-9._-]*) fail 'unsafe job name in plan' ;;
esac
job_xml="$bundle/controller/jobs/$job_name.xml"
[ -f "$job_xml" ] || fail "rendered job XML is missing: $job_xml"
python3 "$RENDER_TOOL" --plan "$plan_path" --verify-bundle "$bundle" >/dev/null

mkdir -p "$evidence"
chmod 700 "$evidence"
job_list="$evidence/jobs-before.txt"
"$CLI" read list-jobs >"$job_list"
chmod 600 "$job_list"

if grep -F -x -- "$job_name" "$job_list" >/dev/null 2>&1; then
  "$CLI" read get-job "$job_name" >"$evidence/before-job.xml"
  chmod 600 "$evidence/before-job.xml"
  if ! "$CLI" write --plan "$plan_path" --approve "$approval" -- update-job "$job_name"; then
    printf 'Job update failed. Prior XML remains at %s\n' "$evidence/before-job.xml" >&2
    exit 1
  fi
  operation='updated'
else
  "$CLI" write --plan "$plan_path" --approve "$approval" -- create-job "$job_name"
  operation='created'
fi

"$CLI" read get-job "$job_name" >"$evidence/applied-job.xml"
chmod 600 "$evidence/applied-job.xml"
printf '%s\t%s\t%s\n' "$operation" "$job_name" "$approval" >"$evidence/result.tsv"
chmod 600 "$evidence/result.tsv"
printf 'Jenkins job %s: %s\n' "$operation" "$job_name"
