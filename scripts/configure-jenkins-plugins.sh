#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CLI="${SCRIPT_DIR}/jenkins-cli-safe.sh"
PLAN_TOOL="${SCRIPT_DIR}/plan-jenkins.py"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

plan_path=''
approval=''
evidence=''
backup_evidence=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) plan_path="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    --evidence) evidence="${2:-}"; shift 2 ;;
    --backup-evidence) backup_evidence="${2:-}"; shift 2 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
[ -f "$plan_path" ] || fail '--plan must point to a plan file'
[ -n "$approval" ] || fail '--approve is required'
[ -n "$evidence" ] || fail '--evidence is required'
[ ! -e "$evidence" ] || fail "evidence path already exists: $evidence"
python3 "$PLAN_TOOL" verify --plan "$plan_path" --approve "$approval" --require-ready >/dev/null

required_plugins="$(python3 - "$plan_path" <<'PY'
import json, re, sys
plan = json.load(open(sys.argv[1], encoding="utf-8"))
for plugin in plan["plugins"]:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}:[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", plugin):
        raise SystemExit(f"ERROR: unsafe versioned plugin identifier: {plugin}")
    print(plugin)
PY
)"
mkdir -p "$evidence"
chmod 700 "$evidence"
"$CLI" read list-plugins >"$evidence/plugins-before.txt"
chmod 600 "$evidence/plugins-before.txt"
: >"$evidence/installed.txt"
chmod 600 "$evidence/installed.txt"

missing_before=''
while IFS= read -r plugin; do
  [ -n "$plugin" ] || continue
  plugin_name="${plugin%%:*}"
  plugin_version="${plugin#*:}"
  if ! awk -v name="$plugin_name" -v version="$plugin_version" '$1 == name && $NF == version {found=1} END {exit !found}' "$evidence/plugins-before.txt"; then
    missing_before="${missing_before}${missing_before:+, }${plugin}"
  fi
done <<EOF
$required_plugins
EOF
if [ -n "$missing_before" ]; then
  [ -n "$backup_evidence" ] || fail "plugin installation requires structured backup evidence; missing plugins: $missing_before"
  [ -f "$backup_evidence" ] && [ ! -L "$backup_evidence" ] || fail 'backup evidence must be a regular file'
  python3 - "$backup_evidence" "$evidence/backup-evidence.json" <<'PY'
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
payload = json.loads(source.read_text(encoding="utf-8"))
required = {"schema_version", "backup_id", "path", "sha256", "created_at", "restore_tested"}
if set(payload) != required or payload["schema_version"] != 1:
    raise SystemExit("ERROR: backup evidence schema is invalid")
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", str(payload["backup_id"])):
    raise SystemExit("ERROR: backup identifier is unsafe")
backup = pathlib.Path(str(payload["path"]))
if not backup.is_absolute() or not backup.is_file() or backup.is_symlink():
    raise SystemExit("ERROR: backup path must be an absolute regular file")
actual = hashlib.sha256(backup.read_bytes()).hexdigest()
if actual != payload["sha256"] or not re.fullmatch(r"[0-9a-f]{64}", str(payload["sha256"])):
    raise SystemExit("ERROR: backup checksum does not match")
try:
    created = dt.datetime.fromisoformat(str(payload["created_at"]))
except ValueError as error:
    raise SystemExit(f"ERROR: backup timestamp is invalid: {error}")
if created.tzinfo is None:
    raise SystemExit("ERROR: backup timestamp must include a timezone")
if payload["restore_tested"] is not True:
    raise SystemExit("ERROR: backup restore has not been tested")
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(sys.argv[2], 0o600)
PY
fi

while IFS= read -r plugin; do
  [ -n "$plugin" ] || continue
  plugin_name="${plugin%%:*}"
  plugin_version="${plugin#*:}"
  if awk -v name="$plugin_name" -v version="$plugin_version" '$1 == name && $NF == version {found=1} END {exit !found}' "$evidence/plugins-before.txt"; then
    continue
  fi
  "$CLI" write --plan "$plan_path" --approve "$approval" -- install-plugin "$plugin" -deploy
  printf '%s\n' "$plugin" >>"$evidence/installed.txt"
done <<EOF
$required_plugins
EOF

"$CLI" read list-plugins >"$evidence/plugins-after.txt"
chmod 600 "$evidence/plugins-after.txt"
missing=''
while IFS= read -r plugin; do
  [ -n "$plugin" ] || continue
  plugin_name="${plugin%%:*}"
  plugin_version="${plugin#*:}"
  if ! awk -v name="$plugin_name" -v version="$plugin_version" '$1 == name && $NF == version {found=1} END {exit !found}' "$evidence/plugins-after.txt"; then
    missing="${missing}${missing:+, }${plugin}"
  fi
done <<EOF
$required_plugins
EOF
[ -z "$missing" ] || fail "plugins are still missing after installation: $missing"
printf 'Required Jenkins plugins are installed. Evidence: %s\n' "$evidence"
