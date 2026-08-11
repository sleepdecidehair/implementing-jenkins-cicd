#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
AUDIT_SCRIPT="${SCRIPT_DIR}/jenkins-readonly-audit.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-audit-test.XXXXXX")"
trap 'find "$TEST_ROOT" -depth -delete' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  file="$1"
  value="$2"
  grep -F -- "$value" "$file" >/dev/null || fail "$file does not contain: $value"
}

assert_not_contains_tree() {
  root="$1"
  value="$2"
  if grep -R -F -- "$value" "$root" >/dev/null 2>&1; then
    fail "$root leaked: $value"
  fi
}

mkdir -p "$TEST_ROOT/bin"

cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination=''
source_url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      destination="$2"
      shift 2
      ;;
    http://*|https://*)
      source_url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$destination" ] || exit 2
case "$source_url" in
  */update-center.actual.json)
    cp "$FAKE_UPDATE_CENTER_JSON" "$destination"
    ;;
  *)
    printf 'fake controller-matched CLI jar\n' >"$destination"
    ;;
esac
printf '%s\n' "$destination" >"$FAKE_CURL_DEST"
printf '%s\n' "$source_url" >>"$FAKE_CURL_URL"
EOF
chmod 700 "$TEST_ROOT/bin/curl"

cat >"$TEST_ROOT/bin/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command_name=''
job_name=''
expect_job='false'
for argument in "$@"; do
  if [ "$expect_job" = 'true' ]; then
    job_name="$argument"
    expect_job='false'
    continue
  fi
  case "$argument" in
    who-am-i|version|list-jobs|list-plugins)
      command_name="$argument"
      ;;
    get-job|console)
      command_name="$argument"
      expect_job='true'
      ;;
  esac
done
printf '%s %s\n' "$command_name" "$job_name" >>"$FAKE_JAVA_TRACE"
if [ "${FAKE_FAIL_COMMAND:-}" = "$command_name" ]; then
  exit 44
fi
if [ "${FAKE_SLEEP_COMMAND:-}" = "$command_name" ]; then
  printf 'sleeping\n' >"$FAKE_SLEEP_MARKER"
  sleep 3
fi
case "$command_name" in
  who-am-i)
    printf 'Authenticated as: fake-user\nAuthorities: authenticated\n'
    ;;
  version)
    printf '2.555.3\n'
    ;;
  list-jobs)
    printf 'frontend\nbackend\na b\na/b\na@b\n'
    ;;
  list-plugins)
    printf 'git Git plugin 5.0 enabled\nworkflow-aggregator Pipeline 600 enabled\n'
    ;;
  get-job)
    cat <<XML
<project>
  <authToken>job-token-secret-value</authToken>
  <apiToken>api-token-secret-value</apiToken>
  <password>password-secret-value</password>
  <secretBytes>
    multiline-jenkins-secret-value
  </secretBytes>
  <privateKey>
-----BEGIN PRIVATE KEY-----
private-key-secret-value
-----END PRIVATE KEY-----
  </privateKey>
  <description>${job_name} safe description</description>
  <command>API_KEY=third-party-secret-value\nPASSWORD="quoted-password-secret"\nSECRET_TEXT='single-quoted-secret'\npassword=lowercase-password-secret\ncurl 'https://example.invalid/build?token=query-secret-value&amp;token=xml-query-secret-value'</command>
</project>
XML
    ;;
  console)
    printf 'Build %s commit 0123456789abcdef0123456789abcdef01234567\n' "$job_name"
    printf 'Authorization: Bearer bearer-secret-value\n'
    printf 'Authorization: Basic basic-secret-value\n'
    printf 'JWT eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzZWNyZXQifQ.jwt-signature-secret\n'
    printf 'encrypted {AQAAABAAAAAjenkins-encrypted-secret-value}\n'
    printf 'base64 QWxhZGRpbjpvcGVuIHNlc2FtZV9hbm90aGVyX3NlY3JldA==\n'
    printf 'Finished: SUCCESS\n'
    ;;
  *)
    exit 3
    ;;
esac
EOF
chmod 700 "$TEST_ROOT/bin/java"

[ -x "$AUDIT_SCRIPT" ] || fail "audit script is missing or not executable"

missing_output="$TEST_ROOT/missing-output"
if env -u JENKINS_URL -u JENKINS_USER_ID -u JENKINS_API_TOKEN \
  PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$missing_output" \
  >"$TEST_ROOT/missing.stdout" 2>"$TEST_ROOT/missing.stderr"; then
  fail 'audit unexpectedly accepted missing Jenkins environment variables'
fi
assert_contains "$TEST_ROOT/missing.stderr" 'JENKINS_URL'
assert_contains "$TEST_ROOT/missing.stderr" 'JENKINS_USER_ID'
assert_contains "$TEST_ROOT/missing.stderr" 'JENKINS_API_TOKEN'

userinfo_output="$TEST_ROOT/userinfo-output"
if JENKINS_URL='https://name:secret@jenkins.example.invalid' \
  JENKINS_USER_ID='audit-user' JENKINS_API_TOKEN='safe-env-only' \
  PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$userinfo_output" \
  >"$TEST_ROOT/userinfo.stdout" 2>"$TEST_ROOT/userinfo.stderr"; then
  fail 'audit unexpectedly accepted credentials embedded in JENKINS_URL'
fi
assert_contains "$TEST_ROOT/userinfo.stderr" 'must not contain embedded credentials'

query_output="$TEST_ROOT/query-output"
if JENKINS_URL='https://jenkins.example.invalid/root?token=must-not-be-in-url' \
  JENKINS_USER_ID='audit-user' JENKINS_API_TOKEN='safe-env-only' \
  PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$query_output" \
  >"$TEST_ROOT/query.stdout" 2>"$TEST_ROOT/query.stderr"; then
  fail 'audit unexpectedly accepted a query string in JENKINS_URL'
fi
assert_contains "$TEST_ROOT/query.stderr" 'must not contain a query or fragment'

export FAKE_CURL_DEST="$TEST_ROOT/curl-destination"
export FAKE_CURL_URL="$TEST_ROOT/curl-url"
export FAKE_JAVA_TRACE="$TEST_ROOT/java-trace"
export FAKE_SLEEP_MARKER="$TEST_ROOT/sleep-marker"
export FAKE_UPDATE_CENTER_JSON="$TEST_ROOT/update-center-clean.json"
python3 - "$FAKE_UPDATE_CENTER_JSON" <<'PY'
import datetime as dt
import json
import pathlib
import sys

payload = {
    "generationTimestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "warnings": [
        {
            "type": "core",
            "name": "core",
            "message": "old core warning",
            "url": "https://www.jenkins.io/security/advisory/example/",
            "versions": [{"pattern": "2[.]400"}],
        },
        {
            "type": "plugin",
            "name": "git",
            "message": "old Git warning",
            "url": "https://plugins.jenkins.io/git/#security",
            "versions": [{"pattern": "4[.].*"}],
        },
    ],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
export JENKINS_URL='http://jenkins.example.invalid:8080'
export JENKINS_USER_ID='audit-user'
export JENKINS_API_TOKEN='environment-api-token-must-never-leak'
export JENKINS_AUDIT_LOG_LINES='25'

output_dir="$TEST_ROOT/audit-output"
mkdir -p "$output_dir"
printf 'stale evidence\n' >"$output_dir/stale.txt"
if PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$output_dir" \
  >"$TEST_ROOT/existing.stdout" 2>"$TEST_ROOT/existing.stderr"; then
  fail 'audit unexpectedly reused an existing output path'
fi
assert_contains "$TEST_ROOT/existing.stderr" 'must not already exist'
rm "$output_dir/stale.txt"
rmdir "$output_dir"

PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$output_dir" \
  >"$TEST_ROOT/audit.stdout" 2>"$TEST_ROOT/audit.stderr"

[ -f "$output_dir/summary.txt" ] || fail 'summary.txt was not created'
[ -f "$output_dir/plugins.txt" ] || fail 'plugins.txt was not created'
[ -f "$output_dir/security-baseline.json" ] || fail 'security-baseline.json was not created'
frontend_config="$(find "$output_dir/jobs" -type f -name 'job--*.xml' -print -quit)"
backend_log="$(find "$output_dir/logs" -type f -name 'job--*.log' -print -quit)"
[ -f "$frontend_config" ] || fail 'sanitized frontend config missing'
[ -f "$backend_log" ] || fail 'sanitized backend log missing'
[ "$(find "$output_dir/jobs" -type f -name '*.xml' | wc -l | tr -d ' ')" -eq 5 ] || fail 'job evidence count mismatch or filename collision'
[ "$(sed -n '2,$p' "$output_dir/jobs-index.tsv" | cut -f1 | sort -u | wc -l | tr -d ' ')" -eq 5 ] || fail 'colliding display names were not preserved uniquely'
assert_contains "$output_dir/jobs-index.tsv" $'\ta b'
assert_contains "$output_dir/jobs-index.tsv" $'\ta/b'
assert_contains "$output_dir/jobs-index.tsv" $'\ta@b'
assert_contains "$output_dir/summary.txt" 'READ-ONLY'
assert_contains "$output_dir/security-baseline.json" '"status": "clean"'
assert_contains "$frontend_config" '[REDACTED]'
assert_contains "$backend_log" 'Finished: SUCCESS'
assert_contains "$TEST_ROOT/audit.stderr" 'unencrypted HTTP'
assert_contains "$FAKE_CURL_URL" 'http://jenkins.example.invalid:8080/jnlpJars/jenkins-cli.jar'
assert_contains "$FAKE_CURL_URL" 'https://updates.jenkins.io/current/update-center.actual.json'

for secret in \
  'environment-api-token-must-never-leak' \
  'job-token-secret-value' \
  'api-token-secret-value' \
  'password-secret-value' \
  'third-party-secret-value' \
  'quoted-password-secret' \
  'single-quoted-secret' \
  'lowercase-password-secret' \
  'query-secret-value' \
  'xml-query-secret-value' \
  'bearer-secret-value' \
  'basic-secret-value' \
  'multiline-jenkins-secret-value' \
  'private-key-secret-value' \
  'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzZWNyZXQifQ.jwt-signature-secret' \
  '{AQAAABAAAAAjenkins-encrypted-secret-value}' \
  'QWxhZGRpbjpvcGVuIHNlc2FtZV9hbm90aGVyX3NlY3JldA==' \
  '0123456789abcdef0123456789abcdef01234567'; do
  assert_not_contains_tree "$output_dir" "$secret"
done

allowed_commands='who-am-i|version|list-jobs|list-plugins|get-job|console'
if awk '{print $1}' "$FAKE_JAVA_TRACE" | grep -Ev "^(${allowed_commands})$" >/dev/null; then
  fail 'a non-read-only CLI command was executed'
fi
[ "$(grep -c '^who-am-i ' "$FAKE_JAVA_TRACE")" -eq 1 ] || fail 'who-am-i count mismatch'
[ "$(grep -c '^version ' "$FAKE_JAVA_TRACE")" -eq 1 ] || fail 'version count mismatch'
[ "$(grep -c '^list-jobs ' "$FAKE_JAVA_TRACE")" -eq 1 ] || fail 'list-jobs count mismatch'
[ "$(grep -c '^list-plugins ' "$FAKE_JAVA_TRACE")" -eq 1 ] || fail 'list-plugins count mismatch'
[ "$(grep -c '^get-job ' "$FAKE_JAVA_TRACE")" -eq 5 ] || fail 'get-job count mismatch'
[ "$(grep -c '^console ' "$FAKE_JAVA_TRACE")" -eq 5 ] || fail 'console count mismatch'
assert_not_contains_tree "$TEST_ROOT" 'environment-api-token-must-never-leak'

jar_path="$(sed -n '1p' "$FAKE_CURL_DEST")"
[ -n "$jar_path" ] || fail 'fake curl did not record the JAR destination'
[ ! -e "$jar_path" ] || fail "temporary CLI JAR still exists: $jar_path"
raw_dir="$(dirname -- "$jar_path")"
[ ! -e "$raw_dir" ] || fail "temporary raw evidence directory still exists: $raw_dir"

dir_mode="$(stat -f '%Lp' "$output_dir" 2>/dev/null || stat -c '%a' "$output_dir")"
file_mode="$(stat -f '%Lp' "$output_dir/summary.txt" 2>/dev/null || stat -c '%a' "$output_dir/summary.txt")"
[ "$dir_mode" = '700' ] || fail "output directory mode is $dir_mode, expected 700"
[ "$file_mode" = '600' ] || fail "summary file mode is $file_mode, expected 600"

vulnerable_update_center="$TEST_ROOT/update-center-vulnerable.json"
python3 - "$vulnerable_update_center" <<'PY'
import datetime as dt
import json
import pathlib
import sys

payload = {
    "generationTimestamp": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
    "warnings": [{
        "type": "plugin",
        "name": "git",
        "message": "fixture vulnerable Git version",
        "url": "https://plugins.jenkins.io/git/#security",
        "versions": [{"pattern": "5[.]0"}],
    }],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
export FAKE_UPDATE_CENTER_JSON="$vulnerable_update_center"
vulnerable_output="$TEST_ROOT/vulnerable-output"
if PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$vulnerable_output" \
  >"$TEST_ROOT/vulnerable.stdout" 2>"$TEST_ROOT/vulnerable.stderr"; then
  fail 'audit unexpectedly accepted an installed plugin matching a current security warning'
fi
[ -f "$vulnerable_output/security-baseline.json" ] || fail 'vulnerable audit did not retain security evidence'
assert_contains "$vulnerable_output/security-baseline.json" '"status": "vulnerable"'
assert_contains "$vulnerable_output/security-baseline.json" 'fixture vulnerable Git version'
assert_not_contains_tree "$vulnerable_output" 'environment-api-token-must-never-leak'
export FAKE_UPDATE_CENTER_JSON="$TEST_ROOT/update-center-clean.json"

export FAKE_FAIL_COMMAND='get-job'
failure_output="$TEST_ROOT/failure-output"
if PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$failure_output" \
  >"$TEST_ROOT/failure.stdout" 2>"$TEST_ROOT/failure.stderr"; then
  fail 'audit unexpectedly succeeded when a CLI read failed'
fi
unset FAKE_FAIL_COMMAND
failure_jar_path="$(sed -n '1p' "$FAKE_CURL_DEST")"
[ ! -e "$(dirname -- "$failure_jar_path")" ] || fail 'failure path retained raw evidence'
[ ! -e "$failure_output" ] || fail 'failure path published partial evidence'
if find "$TEST_ROOT" -maxdepth 1 -name 'failure-output.partial.*' -print -quit | grep -q .; then
  fail 'failure path retained a partial output directory'
fi

export FAKE_SLEEP_COMMAND='version'
signal_output="$TEST_ROOT/signal-output"
PATH="$TEST_ROOT/bin:$PATH" "$AUDIT_SCRIPT" "$signal_output" \
  >"$TEST_ROOT/signal.stdout" 2>"$TEST_ROOT/signal.stderr" &
audit_pid=$!
signal_wait=0
while [ ! -f "$FAKE_SLEEP_MARKER" ] && [ "$signal_wait" -lt 100 ]; do
  sleep 0.05
  signal_wait=$((signal_wait + 1))
done
[ -f "$FAKE_SLEEP_MARKER" ] || fail 'signal test did not reach the sleeping CLI call'
kill -TERM "$audit_pid"
if wait "$audit_pid"; then
  fail 'audit unexpectedly succeeded after SIGTERM'
fi
unset FAKE_SLEEP_COMMAND
signal_jar_path="$(sed -n '1p' "$FAKE_CURL_DEST")"
[ ! -e "$(dirname -- "$signal_jar_path")" ] || fail 'signal path retained raw evidence'
[ ! -e "$signal_output" ] || fail 'signal path published partial evidence'
if find "$TEST_ROOT" -maxdepth 1 -name 'signal-output.partial.*' -print -quit | grep -q .; then
  fail 'signal path retained a partial output directory'
fi

printf 'PASS: read-only Jenkins audit script\n'
