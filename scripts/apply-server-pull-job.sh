#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLI="${SCRIPT_DIR}/jenkins-cli-safe.sh"
RENDERER="${SCRIPT_DIR}/render-server-pull-templates.py"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

config=''
bundle=''
approval=''
evidence=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) config="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    --evidence) evidence="${2:-}"; shift 2 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
for value in "$config" "$bundle" "$approval" "$evidence"; do [ -n "$value" ] || fail 'missing required argument'; done
[ ! -e "$evidence" ] || fail "evidence path already exists: $evidence"

verified_plan="$(python3 "$RENDERER" --config "$config" --verify-output "$bundle")"
[ "$approval" = "$verified_plan" ] || fail 'apply requires the exact Server Pull approval identifier'
job_name="$(python3 - "$config" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["jenkins_job"])
PY
)"
case "$job_name" in ''|*[!A-Za-z0-9._-]*) fail 'unsafe Server Pull job name' ;; esac

mkdir -p "$evidence"
chmod 700 "$evidence"
"$CLI" read list-jobs >"$evidence/jobs-before.txt"
chmod 600 "$evidence/jobs-before.txt"
if grep -F -x -- "$job_name" "$evidence/jobs-before.txt" >/dev/null 2>&1; then
  "$CLI" read get-job "$job_name" >"$evidence/before-job.xml"
  chmod 600 "$evidence/before-job.xml"
  "$CLI" write --server-pull-config "$config" --approve "$approval" -- update-job "$job_name"
  operation='updated'
else
  "$CLI" write --server-pull-config "$config" --approve "$approval" -- create-job "$job_name"
  operation='created'
fi
"$CLI" read get-job "$job_name" >"$evidence/applied-job.xml"
chmod 600 "$evidence/applied-job.xml"
printf '%s\t%s\t%s\n' "$operation" "$job_name" "$approval" >"$evidence/result.tsv"
chmod 600 "$evidence/result.tsv"
printf 'Jenkins Server Pull job %s: %s\n' "$operation" "$job_name"
