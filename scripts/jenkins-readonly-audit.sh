#!/usr/bin/env bash
set -euo pipefail

umask 077
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REDACTOR="${SCRIPT_DIR}/redact-jenkins-evidence.pl"
SECURITY_CHECKER="${SCRIPT_DIR}/check-jenkins-security-baseline.py"

usage() {
  printf 'Usage: %s OUTPUT_DIRECTORY\n' "$(basename -- "$0")" >&2
  printf 'Required environment: JENKINS_URL, JENKINS_USER_ID, JENKINS_API_TOKEN\n' >&2
}

missing=''
for variable_name in JENKINS_URL JENKINS_USER_ID JENKINS_API_TOKEN; do
  eval "variable_value=\${${variable_name}:-}"
  if [ -z "$variable_value" ]; then
    missing="${missing}${missing:+, }${variable_name}"
  fi
done
unset variable_value

if [ -n "$missing" ]; then
  printf 'Missing required environment variables: %s\n' "$missing" >&2
  usage
  exit 2
fi

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  usage
  exit 2
fi

output_dir="$1"
case "$output_dir" in
  */)
    printf 'OUTPUT_DIRECTORY must not end with a slash.\n' >&2
    exit 2
    ;;
esac
if [ -e "$output_dir" ]; then
  printf 'OUTPUT_DIRECTORY must not already exist: %s\n' "$output_dir" >&2
  exit 2
fi

case "$JENKINS_URL" in
  http://*|https://*) ;;
  *)
    printf 'JENKINS_URL must use http:// or https://.\n' >&2
    exit 2
    ;;
esac

for required_command in curl java perl python3; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$required_command" >&2
    exit 2
  fi
done
if [ ! -f "$REDACTOR" ]; then
  printf 'Evidence redactor is unavailable: %s\n' "$REDACTOR" >&2
  exit 2
fi
if [ ! -x "$SECURITY_CHECKER" ]; then
  printf 'Security baseline checker is unavailable: %s\n' "$SECURITY_CHECKER" >&2
  exit 2
fi
if command -v shasum >/dev/null 2>&1; then
  hash_tool='shasum'
elif command -v sha256sum >/dev/null 2>&1; then
  hash_tool='sha256sum'
else
  printf 'A SHA-256 tool is required (shasum or sha256sum).\n' >&2
  exit 2
fi
url_authority="${JENKINS_URL#*://}"
url_authority="${url_authority%%/*}"
case "$url_authority" in
  *@*)
    printf 'JENKINS_URL must not contain embedded credentials.\n' >&2
    exit 2
    ;;
  *[[:space:]]*)
    printf 'JENKINS_URL contains whitespace.\n' >&2
    exit 2
    ;;
esac
case "$JENKINS_URL" in
  *'?'*|*'#'*)
    printf 'JENKINS_URL must not contain a query or fragment.\n' >&2
    exit 2
    ;;
esac

log_lines="${JENKINS_AUDIT_LOG_LINES:-300}"
case "$log_lines" in
  ''|*[!0-9]*)
    printf 'JENKINS_AUDIT_LOG_LINES must be a positive integer.\n' >&2
    exit 2
    ;;
  0)
    printf 'JENKINS_AUDIT_LOG_LINES must be greater than zero.\n' >&2
    exit 2
    ;;
esac

case "$JENKINS_URL" in
  http://*)
    printf 'WARNING: Jenkins URL uses unencrypted HTTP; credentials and traffic may be exposed in transit.\n' >&2
    ;;
esac

tmp_base="${TMPDIR:-/tmp}"
raw_dir=''
staging_dir="${output_dir}.partial.$$"

remove_raw_evidence() {
  trap - EXIT HUP INT TERM
  if [ -n "$raw_dir" ]; then
    case "$raw_dir" in
      "${tmp_base%/}"/jenkins-readonly-audit.*)
        find "$raw_dir" -depth -delete
        ;;
      *)
        printf 'Refusing to remove unexpected temporary path: %s\n' "$raw_dir" >&2
        ;;
    esac
  fi
  if [ -n "${staging_dir:-}" ] && [ -f "$staging_dir/.audit-staging-marker" ]; then
    find "$staging_dir" -depth -delete
  fi
  unset JENKINS_API_TOKEN
}

cleanup_on_exit() {
  cleanup_status=$?
  remove_raw_evidence
  exit "$cleanup_status"
}

cleanup_on_signal() {
  signal_status="$1"
  remove_raw_evidence
  exit "$signal_status"
}

trap cleanup_on_exit EXIT
trap 'cleanup_on_signal 129' HUP
trap 'cleanup_on_signal 130' INT
trap 'cleanup_on_signal 143' TERM

if [ -e "$staging_dir" ]; then
  printf 'Refusing to reuse staging path: %s\n' "$staging_dir" >&2
  exit 2
fi
mkdir -p -- "$(dirname -- "$output_dir")" "$staging_dir/jobs" "$staging_dir/logs"
printf 'jenkins-readonly-audit staging marker\n' >"$staging_dir/.audit-staging-marker"
chmod 700 "$staging_dir" "$staging_dir/jobs" "$staging_dir/logs"
raw_dir="$(mktemp -d "${tmp_base%/}/jenkins-readonly-audit.XXXXXX")"
printf 'evidence_file\tjob_name\n' >"$raw_dir/jobs-index.tsv"

cli_jar="$raw_dir/jenkins-cli.jar"
curl -fsSL "${JENKINS_URL%/}/jnlpJars/jenkins-cli.jar" -o "$cli_jar"
chmod 600 "$cli_jar"

jenkins_cli() {
  java -jar "$cli_jar" -s "${JENKINS_URL%/}" -webSocket "$@"
}

sanitize() {
  perl "$REDACTOR"
}

job_digest() {
  if [ "$hash_tool" = 'shasum' ]; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 16)}'
  else
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 16)}'
  fi
}

jenkins_cli who-am-i >"$raw_dir/who-am-i.txt"
jenkins_cli version >"$raw_dir/version.txt"
jenkins_cli list-jobs >"$raw_dir/jobs.txt"
jenkins_cli list-plugins >"$raw_dir/plugins.txt"
curl -fsSL 'https://updates.jenkins.io/current/update-center.actual.json' \
  -o "$raw_dir/update-center.actual.json"
security_status=0
if python3 "$SECURITY_CHECKER" \
  --controller-version-file "$raw_dir/version.txt" \
  --plugins-file "$raw_dir/plugins.txt" \
  --update-center-json "$raw_dir/update-center.actual.json" \
  --output "$staging_dir/security-baseline.json"; then
  security_status=0
else
  security_status=$?
fi
case "$security_status" in
  0|3) ;;
  *) printf 'Security baseline evaluation failed.\n' >&2; exit "$security_status" ;;
esac

{
  printf 'Jenkins authenticated read-only audit\n'
  printf 'Mode: READ-ONLY\n'
  printf 'Controller: %s\n' "${JENKINS_URL%/}"
  printf 'CLI source: controller-matched, temporary jnlpJars/jenkins-cli.jar\n'
  printf 'Authenticated identity:\n'
  sanitize <"$raw_dir/who-am-i.txt"
  printf 'Controller version:\n'
  sanitize <"$raw_dir/version.txt"
  printf 'Commands allowed: who-am-i, version, list-jobs, list-plugins, get-job, console\n'
  printf 'Security baseline: official current update-center warning feed; see security-baseline.json\n'
  printf 'Raw XML, raw console logs, and the CLI JAR are deleted on exit.\n'
  printf 'Persisted evidence is best-effort redacted; keep it private and review it before sharing.\n'
} >"$staging_dir/summary.txt"
sanitize <"$raw_dir/plugins.txt" >"$staging_dir/plugins.txt"

while IFS= read -r job_name || [ -n "$job_name" ]; do
  [ -n "$job_name" ] || continue
  case "$job_name" in
    -*|.|..)
      printf 'Skipping unsafe job name returned by Jenkins.\n' >&2
      continue
      ;;
  esac
  if printf '%s' "$job_name" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null 2>&1; then
    printf 'Skipping job name containing control characters.\n' >&2
    continue
  fi

  safe_name="job--$(job_digest "$job_name")"
  if [ -e "$raw_dir/${safe_name}.xml" ] || [ -e "$raw_dir/${safe_name}.log" ]; then
    printf 'Duplicate job entry or SHA-256 filename collision detected.\n' >&2
    exit 4
  fi

  jenkins_cli get-job "$job_name" >"$raw_dir/${safe_name}.xml"
  jenkins_cli console "$job_name" -n "$log_lines" >"$raw_dir/${safe_name}.log"
  sanitize <"$raw_dir/${safe_name}.xml" >"$staging_dir/jobs/${safe_name}.xml"
  sanitize <"$raw_dir/${safe_name}.log" >"$staging_dir/logs/${safe_name}.log"
  printf '%s\t%s\n' "${safe_name}.xml" "$job_name" >>"$raw_dir/jobs-index.tsv"
done <"$raw_dir/jobs.txt"

sanitize <"$raw_dir/jobs-index.tsv" >"$staging_dir/jobs-index.tsv"

find "$staging_dir" -type d -exec chmod 700 {} \;
find "$staging_dir" -type f -exec chmod 600 {} \;
mv -- "$staging_dir" "$output_dir"
staging_dir=''
rm -- "$output_dir/.audit-staging-marker"

printf 'Read-only Jenkins audit complete: %s\n' "$output_dir"
if [ "$security_status" -eq 3 ]; then
  printf 'Installed Jenkins components match current security warnings; mutation is blocked.\n' >&2
  exit 3
fi
