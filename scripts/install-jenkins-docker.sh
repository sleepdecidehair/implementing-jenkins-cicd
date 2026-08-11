#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PLAN_TOOL="${SCRIPT_DIR}/plan-jenkins.py"
BOOTSTRAP_CLI="${SCRIPT_DIR}/bootstrap-jenkins-cli-profile.sh"
RENDER_TOOL="${SCRIPT_DIR}/render-jenkins-assets.py"

usage() {
  printf 'Usage: %s --plan PLAN --bundle BUNDLE [--apply --approve PLAN_ID]\n' "$(basename -- "$0")" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

plan_path=''
bundle=''
approval=''
apply='false'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan) [ "$#" -ge 2 ] || fail '--plan requires a value'; plan_path="$2"; shift 2 ;;
    --bundle) [ "$#" -ge 2 ] || fail '--bundle requires a value'; bundle="$2"; shift 2 ;;
    --approve) [ "$#" -ge 2 ] || fail '--approve requires a value'; approval="$2"; shift 2 ;;
    --apply) apply='true'; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unsupported argument: $1" ;;
  esac
done
[ -n "$plan_path" ] || { usage; fail '--plan is required'; }
[ -n "$bundle" ] || { usage; fail '--bundle is required'; }
[ -f "$plan_path" ] || fail "plan does not exist: $plan_path"
[ -d "$bundle/controller" ] || fail "controller bundle does not exist: $bundle/controller"
[ -f "$bundle/manifest.json" ] || fail "bundle manifest does not exist"

python3 "$RENDER_TOOL" --plan "$plan_path" --verify-bundle "$bundle" >/dev/null

read_plan_field() {
  python3 - "$plan_path" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split('.'):
    value = value[part]
if value is None:
    value = ""
print(value)
PY
}

plan_id="$(read_plan_field plan_id)"
target="$(read_plan_field controller.target)"
ssh_target="$(read_plan_field controller.ssh_target)"
install_dir="$(read_plan_field controller.install_dir)"
jenkins_url="$(read_plan_field controller.url)"
jenkins_image="$(read_plan_field controller.image)"
jenkins_agent_image="$(read_plan_field controller.agent_image)"
scm_key_path="$(read_plan_field delivery.credential_sources.scm.path)"
scm_key_sha256="$(read_plan_field delivery.credential_sources.scm.sha256)"
deployment_key_path="$(read_plan_field delivery.credential_sources.deployment.path)"
deployment_key_sha256="$(read_plan_field delivery.credential_sources.deployment.sha256)"

case "$install_dir" in
  /*) ;;
  *) fail 'controller install directory must be absolute' ;;
esac
case "$install_dir" in
  /|"${HOME:-/nonexistent}") fail "unsafe controller install directory: $install_dir" ;;
esac

if [ "$apply" != 'true' ]; then
  printf 'DRY RUN Jenkins Docker installation\n'
  printf 'Plan: %s\nTarget: %s\nInstall directory: %s\nImage: %s\n' \
    "$plan_id" "$target" "$install_dir" "$jenkins_image"
  exit 0
fi
[ "$approval" = "$plan_id" ] || fail 'apply requires the exact plan identifier'
python3 "$PLAN_TOOL" verify --plan "$plan_path" --approve "$approval" >/dev/null

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '\n'
  else
    python3 -c 'import secrets; print(secrets.token_urlsafe(36), end="")'
  fi
}

ensure_agent_key() {
  destination="$1"
  command -v ssh-keygen >/dev/null 2>&1 || fail 'ssh-keygen is required to provision the managed Jenkins agent'
  mkdir -p "$destination/secrets"
  private_key="$destination/secrets/agent_ed25519"
  public_key_file="$destination/secrets/agent_ed25519.pub"
  if [ -e "$private_key" ] || [ -e "$public_key_file" ]; then
    [ -f "$private_key" ] && [ -f "$public_key_file" ] || fail 'managed agent SSH keypair is incomplete'
  else
    ssh-keygen -q -t ed25519 -N '' \
      -C "jenkins-agent-${plan_id%%????????????????????????????????????????????????????}" \
      -f "$private_key"
  fi
  public_key="$(sed -n '1p' "$public_key_file")"
  case "$public_key" in ssh-ed25519\ *) ;; *) fail 'managed agent public key is invalid' ;; esac
  env_file="$destination/.env"
  env_temporary="$destination/.env.agent-key.$$"
  grep -v '^JENKINS_AGENT_SSH_PUBKEY=' "$env_file" >"$env_temporary" || true
  printf 'JENKINS_AGENT_SSH_PUBKEY=%s\n' "$public_key" >>"$env_temporary"
  mv "$env_temporary" "$env_file"
  chmod 600 "$private_key" "$public_key_file" "$env_file"
  unset public_key
}

ensure_agent_host_key() {
  destination="$1"
  command -v ssh-keygen >/dev/null 2>&1 || fail 'ssh-keygen is required to provision the managed Jenkins agent host key'
  mkdir -p "$destination/secrets"
  private_key="$destination/secrets/agent_host_ed25519"
  public_key_file="$destination/secrets/agent_host_ed25519.pub"
  if [ -e "$private_key" ] || [ -e "$public_key_file" ]; then
    [ -f "$private_key" ] && [ ! -L "$private_key" ] && [ -f "$public_key_file" ] && [ ! -L "$public_key_file" ] || \
      fail 'managed agent host SSH keypair is incomplete or unsafe'
  else
    ssh-keygen -q -t ed25519 -N '' -C '' -f "$private_key"
  fi
  host_public_key="$(awk 'NF >= 2 {print $1 " " $2; exit}' "$public_key_file")"
  case "$host_public_key" in ssh-ed25519\ *) ;; *) fail 'managed agent host public key is invalid' ;; esac
  printf '%s\n' "$host_public_key" >"$public_key_file"
  chmod 600 "$private_key" "$public_key_file"
  unset host_public_key
}

ensure_admin_password() {
  destination="$1"
  mkdir -p "$destination/secrets"
  password_file="$destination/secrets/admin_password"
  if [ -e "$password_file" ]; then
    [ -f "$password_file" ] && [ ! -L "$password_file" ] || fail 'controller administrator secret is not a regular file'
    [ -s "$password_file" ] || fail 'controller administrator secret is empty'
  else
    generate_password >"$password_file"
  fi
  chmod 600 "$password_file"
}

ensure_trigger_password() {
  destination="$1"
  mkdir -p "$destination/secrets"
  password_file="$destination/secrets/trigger_password"
  if [ -e "$password_file" ]; then
    [ -f "$password_file" ] && [ ! -L "$password_file" ] || fail 'trigger-user secret is not a regular file'
    [ -s "$password_file" ] || fail 'trigger-user secret is empty'
  else
    generate_password >"$password_file"
  fi
  chmod 600 "$password_file"
}

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else fail 'shasum or sha256sum is required to verify credential sources'
  fi
}

install_credential_secret() {
  source_path="$1"
  expected_sha="$2"
  destination_path="$3"
  [ -n "$source_path" ] || return 0
  [ -f "$source_path" ] && [ ! -L "$source_path" ] || fail "credential source is not a regular file: $source_path"
  [ "$(file_sha256 "$source_path")" = "$expected_sha" ] || fail "credential source changed after plan approval: $source_path"
  cp "$source_path" "$destination_path"
  chmod 600 "$destination_path"
}

temporary_secret_file=''
remote_stage=''
cleanup_temporary_secret() {
  cleanup_rc=$?
  trap - EXIT HUP INT TERM
  if [ -n "$temporary_secret_file" ]; then
    case "$temporary_secret_file" in
      "${TMPDIR:-/tmp}"/jenkins-remote-env.*|"${TMPDIR:-/tmp}"//jenkins-remote-env.*)
        find "$temporary_secret_file" -delete 2>/dev/null || true
        ;;
      *) printf 'Refusing to remove unexpected temporary secret path: %s\n' "$temporary_secret_file" >&2 ;;
    esac
  fi
  if [ -n "$remote_stage" ] && [ -n "$ssh_target" ]; then
    ssh "$ssh_target" "case '$remote_stage' in '${install_dir}.stage.'*) find '$remote_stage' -depth -delete 2>/dev/null || true ;; esac" \
      >/dev/null 2>&1 || true
  fi
  exit "$cleanup_rc"
}
trap cleanup_temporary_secret EXIT HUP INT TERM

prepare_local_files() {
  source_dir="$1"
  destination="$2"
  [ ! -L "$destination" ] || fail "install path must not be a symlink: $destination"
  if [ -e "$destination" ] && [ ! -d "$destination" ]; then
    fail "install path exists and is not a directory: $destination"
  fi
  if [ -d "$destination" ] && [ -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    existing_plan=''
    [ ! -f "$destination/.jenkins-plan-id" ] || existing_plan="$(sed -n '1p' "$destination/.jenkins-plan-id")"
    [ "$existing_plan" = "$plan_id" ] || \
      fail "install directory contains a different controller plan; use an existing-controller upgrade plan with a verified Jenkins home backup"
  fi
  mkdir -p "$destination"
  cp -R "$source_dir"/. "$destination"/
  if [ ! -f "$destination/.env" ]; then
    cp "$destination/.env.example" "$destination/.env"
  fi
  ensure_admin_password "$destination"
  ensure_trigger_password "$destination"
  ensure_agent_key "$destination"
  ensure_agent_host_key "$destination"
  printf '%s\n' "$plan_id" >"$destination/.jenkins-plan-id"
  chmod 700 "$destination"
  find "$destination" -type d -exec chmod 700 {} \;
  find "$destination" -type f -exec chmod 600 {} \;
}

wait_for_controller() {
  [ "${JENKINS_INSTALL_SKIP_HEALTH:-0}" != '1' ] || return 0
  attempt=1
  while [ "$attempt" -le 60 ]; do
    if curl -fsS --connect-timeout 3 --max-time 5 "${jenkins_url%/}/login" >/dev/null; then
      printf 'Jenkins controller is ready: %s\n' "$jenkins_url"
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  printf 'Jenkins did not become ready: %s\n' "$jenkins_url" >&2
  return 1
}

case "$target" in
  local)
    command -v docker >/dev/null 2>&1 || fail 'Docker is required; this installer does not silently install Docker Desktop'
    docker compose version >/dev/null
    prepare_local_files "$bundle/controller" "$install_dir"
    install_credential_secret "$scm_key_path" "$scm_key_sha256" "$install_dir/secrets/scm_key"
    install_credential_secret "$deployment_key_path" "$deployment_key_sha256" "$install_dir/secrets/deployment_key"
    docker pull "$jenkins_image"
    docker pull "$jenkins_agent_image"
    (
      cd "$install_dir"
      docker compose build --pull
      docker compose up -d
    )
    docker image inspect --format '{{index .RepoDigests 0}}' "$jenkins_image" >"$install_dir/.resolved-image"
    grep -E '@sha256:[0-9A-Fa-f]{64}$' "$install_dir/.resolved-image" >/dev/null || \
      fail 'pulled Jenkins image did not resolve to a repository digest'
    chmod 600 "$install_dir/.resolved-image"
    docker image inspect --format '{{index .RepoDigests 0}}' "$jenkins_agent_image" >"$install_dir/.resolved-agent-image"
    grep -E '@sha256:[0-9A-Fa-f]{64}$' "$install_dir/.resolved-agent-image" >/dev/null || \
      fail 'pulled Jenkins agent image did not resolve to a repository digest'
    chmod 600 "$install_dir/.resolved-agent-image"
    wait_for_controller
    if [ "${JENKINS_INSTALL_SKIP_HEALTH:-0}" != '1' ] && [ ! -f "$install_dir/.jenkins-cli.env" ]; then
      "$BOOTSTRAP_CLI" --plan "$plan_path" --approve "$approval" \
        --controller-env "$install_dir/.env" --controller-secret "$install_dir/secrets/admin_password" \
        --output "$install_dir/.jenkins-cli.env" \
        --trigger-secret "$install_dir/secrets/trigger_password" \
        --trigger-output "$install_dir/.jenkins-trigger.env"
    fi
    ;;
  ssh)
    command -v ssh >/dev/null 2>&1 || fail 'ssh is required for a remote controller target'
    command -v scp >/dev/null 2>&1 || fail 'scp is required for a remote controller target'
    case "$ssh_target" in
      ''|*[!A-Za-z0-9_.@:-]*) fail 'unsafe SSH target' ;;
    esac
    case "$install_dir" in
      *[!A-Za-z0-9_./-]*) fail 'remote install directory contains unsupported characters' ;;
    esac
    remote_stage="${install_dir}.stage.${plan_id%%????????????????????????????????????????????????????}"
    ssh "$ssh_target" \
      "set -eu; \
       if [ -n \"\$(find '$install_dir' -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)\" ]; then \
         existing_plan=\$(sed -n '1p' '$install_dir/.jenkins-plan-id' 2>/dev/null || true); \
         [ \"\$existing_plan\" = '$plan_id' ] || { echo 'existing controller plan differs; verified Jenkins home backup and upgrade plan required' >&2; exit 2; }; \
       fi; \
       mkdir -p '$remote_stage/secrets'"
    scp -q -r "$bundle/controller/." "${ssh_target}:${remote_stage}/"
    if [ -n "$scm_key_path" ]; then
      [ "$(file_sha256 "$scm_key_path")" = "$scm_key_sha256" ] || fail 'SCM credential source changed after plan approval'
      scp -q "$scm_key_path" "${ssh_target}:${remote_stage}/secrets/scm_key"
    fi
    if [ -n "$deployment_key_path" ]; then
      [ "$(file_sha256 "$deployment_key_path")" = "$deployment_key_sha256" ] || fail 'deployment credential source changed after plan approval'
      scp -q "$deployment_key_path" "${ssh_target}:${remote_stage}/secrets/deployment_key"
    fi
    remote_env="$(mktemp "${TMPDIR:-/tmp}/jenkins-remote-env.XXXXXX")"
    temporary_secret_file="$remote_env"
    cp "$bundle/controller/.env.example" "$remote_env"
    chmod 600 "$remote_env"
    scp -q "$remote_env" "${ssh_target}:${remote_stage}/.env"
    find "$remote_env" -delete
    temporary_secret_file=''
    ssh "$ssh_target" \
      "set -eu; command -v docker >/dev/null; docker compose version >/dev/null; \
       mkdir -p '$install_dir'; \
       if [ -f '$install_dir/.env' ]; then cp '$install_dir/.env' '$remote_stage/.env'; fi; \
       if [ -f '$install_dir/secrets/agent_ed25519' ]; then \
         mkdir -p '$remote_stage/secrets'; \
         cp '$install_dir/secrets/agent_ed25519' '$remote_stage/secrets/agent_ed25519'; \
         cp '$install_dir/secrets/agent_ed25519.pub' '$remote_stage/secrets/agent_ed25519.pub'; \
       fi; \
       if [ -f '$install_dir/secrets/agent_host_ed25519' ]; then \
         mkdir -p '$remote_stage/secrets'; \
         cp '$install_dir/secrets/agent_host_ed25519' '$remote_stage/secrets/agent_host_ed25519'; \
         cp '$install_dir/secrets/agent_host_ed25519.pub' '$remote_stage/secrets/agent_host_ed25519.pub'; \
       fi; \
       if [ ! -f '$remote_stage/secrets/agent_ed25519' ]; then \
         command -v ssh-keygen >/dev/null; mkdir -p '$remote_stage/secrets'; \
         ssh-keygen -q -t ed25519 -N '' -C 'jenkins-agent-${plan_id%%????????????????????????????????????????????????????}' -f '$remote_stage/secrets/agent_ed25519'; \
       fi; \
       if [ ! -f '$remote_stage/secrets/agent_host_ed25519' ]; then \
         command -v ssh-keygen >/dev/null; mkdir -p '$remote_stage/secrets'; \
         ssh-keygen -q -t ed25519 -N '' -C '' -f '$remote_stage/secrets/agent_host_ed25519'; \
       fi; \
       if [ ! -f '$install_dir/secrets/admin_password' ]; then \
         if command -v openssl >/dev/null 2>&1; then openssl rand -base64 36 | tr -d '\\n' >'$remote_stage/secrets/admin_password'; \
         else python3 -c 'import secrets; print(secrets.token_urlsafe(36), end=\"\")' >'$remote_stage/secrets/admin_password'; fi; \
       else cp '$install_dir/secrets/admin_password' '$remote_stage/secrets/admin_password'; fi; \
       if [ ! -f '$install_dir/secrets/trigger_password' ]; then \
         if command -v openssl >/dev/null 2>&1; then openssl rand -base64 36 | tr -d '\n' >'$remote_stage/secrets/trigger_password'; \
         else python3 -c 'import secrets; print(secrets.token_urlsafe(36), end="")' >'$remote_stage/secrets/trigger_password'; fi; \
       else cp '$install_dir/secrets/trigger_password' '$remote_stage/secrets/trigger_password'; fi; \
       host_public_key=$(awk 'NF >= 2 {print $1 " " $2; exit}' '$remote_stage/secrets/agent_host_ed25519.pub'); \
       case "$host_public_key" in 'ssh-ed25519 '*) ;; *) echo 'invalid managed agent host public key' >&2; exit 2 ;; esac; \
       printf '%s\n' "$host_public_key" >'$remote_stage/secrets/agent_host_ed25519.pub'; \
       public_key=\$(sed -n '1p' '$remote_stage/secrets/agent_ed25519.pub'); \
       case \"\$public_key\" in 'ssh-ed25519 '*) ;; *) echo 'invalid managed agent public key' >&2; exit 2 ;; esac; \
       grep -v '^JENKINS_AGENT_SSH_PUBKEY=' '$remote_stage/.env' >'$remote_stage/.env.agent-key' || true; \
       printf 'JENKINS_AGENT_SSH_PUBKEY=%s\\n' \"\$public_key\" >>'$remote_stage/.env.agent-key'; \
       mv '$remote_stage/.env.agent-key' '$remote_stage/.env'; \
       cp -R '$remote_stage'/.' '$install_dir'/; chmod 700 '$install_dir' '$install_dir/secrets'; chmod 600 '$install_dir/.env' '$install_dir/secrets/'*; \
       printf '%s\\n' '$plan_id' >'$install_dir/.jenkins-plan-id'; \
       cd '$install_dir'; docker pull '$jenkins_image'; docker pull '$jenkins_agent_image'; docker compose build --pull; docker compose up -d; \
       docker image inspect --format '{{index .RepoDigests 0}}' '$jenkins_image' >'$install_dir/.resolved-image'; \
       grep -E '@sha256:[0-9A-Fa-f]{64}$' '$install_dir/.resolved-image' >/dev/null; \
       docker image inspect --format '{{index .RepoDigests 0}}' '$jenkins_agent_image' >'$install_dir/.resolved-agent-image'; \
       grep -E '@sha256:[0-9A-Fa-f]{64}$' '$install_dir/.resolved-agent-image' >/dev/null; \
       chmod 600 '$install_dir/.resolved-image' '$install_dir/.resolved-agent-image'; \
       find '$remote_stage' -depth -delete"
    remote_stage=''
    wait_for_controller
    ;;
  existing)
    fail 'existing controller targets are connected and configured, not installed'
    ;;
  *) fail "unsupported controller target: $target" ;;
esac

printf 'Jenkins Docker installation applied for plan %s\n' "$plan_id"
