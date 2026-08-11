#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RENDERER="${SCRIPT_DIR}/render-server-pull-templates.py"

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
evidence=''
ssh_target=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) config="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --approve) approval="${2:-}"; shift 2 ;;
    --evidence) evidence="${2:-}"; shift 2 ;;
    --ssh-target) ssh_target="${2:-}"; shift 2 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
for value in "$config" "$bundle" "$approval" "$evidence"; do [ -n "$value" ] || fail 'missing required argument'; done
[ ! -e "$evidence" ] || fail "evidence path already exists: $evidence"
verified_plan="$(python3 "$RENDERER" --config "$config" --verify-output "$bundle")"
[ "$approval" = "$verified_plan" ] || fail 'install requires the exact Server Pull approval identifier'

deploy_path="$(python3 - "$config" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["execution"]["deploy_script_path"])
PY
)"
case "$deploy_path" in /*) ;; *) fail 'deployment script path must be absolute' ;; esac
source_script="$bundle/deploy-from-git.sh"
expected_hash="$(python3 - "$bundle/manifest.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["files"]["deploy-from-git.sh"])
PY
)"
[ "$(hash_file "$source_script")" = "$expected_hash" ] || fail 'approved deployment script hash mismatch'

mkdir -p "$evidence"
chmod 700 "$evidence"
if [ -z "$ssh_target" ]; then
  parent="$(dirname -- "$deploy_path")"
  mkdir -p "$parent"
  [ ! -L "$parent" ] || fail 'deployment script parent must not be a symbolic link'
  [ ! -L "$deploy_path" ] || fail 'deployment script target must not be a symbolic link'
  if [ -f "$deploy_path" ]; then
    cp "$deploy_path" "$evidence/before-deploy-from-git.sh"
    chmod 600 "$evidence/before-deploy-from-git.sh"
  elif [ -e "$deploy_path" ]; then
    fail 'deployment script target exists and is not a regular file'
  fi
  stage="$parent/.deploy-from-git.sh.stage.${approval%%????????????????????????????????????????????????????}"
  [ ! -e "$stage" ] || fail 'deployment script staging path already exists'
  cp "$source_script" "$stage"
  chmod 700 "$stage"
  [ "$(hash_file "$stage")" = "$expected_hash" ] || fail 'staged deployment script hash mismatch'
  mv "$stage" "$deploy_path"
  installed_hash="$(hash_file "$deploy_path")"
else
  case "$ssh_target" in ''|*[!A-Za-z0-9_.@:-]*) fail 'unsafe SSH target' ;; esac
  case "$deploy_path" in *[!A-Za-z0-9_./-]*) fail 'remote deployment script path contains unsupported characters' ;; esac
  command -v ssh >/dev/null 2>&1 || fail 'ssh is required for remote installation'
  command -v scp >/dev/null 2>&1 || fail 'scp is required for remote installation'
  remote_stage="${deploy_path}.stage.${approval%%????????????????????????????????????????????????????}"
  ssh "$ssh_target" "set -eu; mkdir -p '$(dirname -- "$deploy_path")'; [ ! -L '$deploy_path' ]; [ ! -e '$remote_stage' ]"
  scp -q "$source_script" "${ssh_target}:${remote_stage}"
  installed_hash="$(ssh "$ssh_target" "set -eu; chmod 700 '$remote_stage'; if command -v sha256sum >/dev/null; then sha256sum '$remote_stage' | awk '{print \\$1}'; else shasum -a 256 '$remote_stage' | awk '{print \\$1}'; fi")"
  [ "$installed_hash" = "$expected_hash" ] || fail 'remote staged deployment script hash mismatch'
  ssh "$ssh_target" "set -eu; mv '$remote_stage' '$deploy_path'; chmod 700 '$deploy_path'"
fi
[ "$installed_hash" = "$expected_hash" ] || fail 'installed deployment script differs from approved bundle'
printf '%s\n' "$installed_hash" >"$evidence/installed-script.sha256"
printf '%s\n' "$deploy_path" >"$evidence/installed-script.path"
chmod 600 "$evidence"/*
printf 'Installed approved Server Pull deployment script: %s\n' "$deploy_path"
