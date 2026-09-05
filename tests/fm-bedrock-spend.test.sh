#!/usr/bin/env bash
# Behavior tests for bin/fm-bedrock-spend.sh.
#
# Covers the public CLI, local profile resolution, and Cost Explorer
# failure and success paths through a fake aws. Does not call a real
# account and does not read the script source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bedrock-spend)
SPEND="$ROOT/bin/fm-bedrock-spend.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

need_python3() {
  command -v python3 >/dev/null 2>&1 \
    || fail "python3 is required to run fm-bedrock-spend tests"
}

install_python3() {
  local fakebin=$1 src
  src=$(command -v python3) || fail "python3 is required to run fm-bedrock-spend tests"
  ln -s "$src" "$fakebin/python3"
}

write_aws_stub() {
  local fakebin=$1
  cat > "$fakebin/aws" <<'SH'
#!/usr/bin/env bash
# Record the invocation, then succeed or fail from FM_FAKE_AWS_*.
printf '%s\n' "$*" > "${FM_FAKE_AWS_LOG:?}"
if [ "${FM_FAKE_AWS_FAIL:-0}" = 1 ]; then
  printf '%s\n' "${FM_FAKE_AWS_ERR:-An error occurred (UnrecognizedClientException) when calling the GetCostAndUsage operation}" >&2
  exit "${FM_FAKE_AWS_RC:-255}"
fi
if [ -n "${FM_FAKE_AWS_BODY_FILE:-}" ]; then
  cat "$FM_FAKE_AWS_BODY_FILE"
  exit 0
fi
printf '%s\n' '{"ResultsByTime":[]}'
exit 0
SH
  chmod +x "$fakebin/aws"
}

make_env() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/config"
  fakebin=$(fm_fakebin "$dir")
  install_python3 "$fakebin"
  write_aws_stub "$fakebin"
  printf '%s\n' "$dir"
}

run_spend() {
  local dir=$1
  shift
  env -u FM_AWS_PROFILE \
    PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_FAKE_AWS_LOG="$dir/aws.log" \
    "$SPEND" "$@"
}

monthly_body() {
  cat <<'JSON'
{"ResultsByTime":[{"TimePeriod":{"Start":"2026-08-01","End":"2026-08-28"},"Total":{"UnblendedCost":{"Amount":"12.5","Unit":"USD"}},"Estimated":true}]}
JSON
}

daily_body() {
  cat <<'JSON'
{"ResultsByTime":[{"TimePeriod":{"Start":"2026-08-21","End":"2026-08-22"},"Total":{"UnblendedCost":{"Amount":"1.25","Unit":"USD"}},"Estimated":false},{"TimePeriod":{"Start":"2026-08-22","End":"2026-08-23"},"Total":{"UnblendedCost":{"Amount":"2.5","Unit":"USD"}},"Estimated":true}]}
JSON
}

test_help_matches_behavior() {
  local dir out rc
  dir=$(make_env help)
  set +e
  out=$(run_spend "$dir" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help should succeed"
  assert_contains "$out" "fm-bedrock-spend.sh --days 7" "--help should show the daily-breakdown usage"
  assert_contains "$out" "fm-bedrock-spend.sh --profile foo" "--help should show the profile override"
  assert_contains "$out" "config/aws-profile" "--help should name the local profile file"
  assert_contains "$out" "month to date" "--help should name the default window"
  assert_not_contains "$out" "neon-dev" "--help must not ship a home-specific default profile"
  [ ! -f "$dir/aws.log" ] || fail "--help must not call aws"
  pass "help describes days, profile, local config, and the default window"
}

test_unknown_and_bad_days_are_usage_errors() {
  local dir out rc
  dir=$(make_env usage)
  set +e
  out=$(run_spend "$dir" --nope 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "unknown argument should exit 2"
  assert_contains "$out" "unknown argument: --nope" "unknown argument should name the token"

  set +e
  out=$(run_spend "$dir" --days 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "missing --days value should exit 2"
  assert_contains "$out" "--days needs a number" "missing --days value should say so"

  set +e
  out=$(run_spend "$dir" --days 0 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "--days 0 should exit 2"
  assert_contains "$out" "--days needs a positive integer" "--days 0 should be rejected"

  set +e
  out=$(run_spend "$dir" --days abc 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "non-numeric --days should exit 2"
  assert_contains "$out" "--days needs a positive integer" "non-numeric --days should be rejected"

  set +e
  out=$(run_spend "$dir" --profile 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "missing --profile value should exit 2"
  assert_contains "$out" "--profile needs a name" "missing --profile value should say so"

  [ ! -f "$dir/aws.log" ] || fail "usage errors must not call aws"
  pass "unknown arguments and bad --days/--profile values exit 2 without calling aws"
}

test_missing_profile_refuses_with_config_path() {
  local dir out rc
  dir=$(make_env noprofile)
  set +e
  out=$(run_spend "$dir" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing profile should exit 1"
  assert_contains "$out" "$dir/home/config/aws-profile" "refusal should name the file to write"
  assert_contains "$out" "FM_AWS_PROFILE" "refusal should name the override variable"
  [ ! -f "$dir/aws.log" ] || fail "a missing profile must not call aws"
  pass "an unconfigured home refuses with the path to write"
}

test_config_profile_is_used() {
  local dir out rc
  dir=$(make_env fromconfig)
  printf 'neon-dev\n' > "$dir/home/config/aws-profile"
  monthly_body > "$dir/body.json"
  set +e
  out=$(env -u FM_AWS_PROFILE \
    PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_FAKE_AWS_LOG="$dir/aws.log" \
    FM_FAKE_AWS_BODY_FILE="$dir/body.json" \
    "$SPEND" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "configured profile should succeed (got: $out)"
  assert_grep "--profile neon-dev" "$dir/aws.log" "config/aws-profile should be passed to aws"
  assert_contains "$(cat "$dir/aws.log")" "granularity MONTHLY" "default window should be monthly"
  assert_contains "$out" "Amazon Bedrock, 2026-08-01 to 2026-08-28: \$12.50 (estimated, AWS has not finalised it)" \
    "month-to-date output should include the total and estimated flag"
  pass "config/aws-profile is passed through and month-to-date output is formatted"
}

test_env_and_flag_override_config() {
  local dir out rc
  dir=$(make_env overrides)
  printf 'from-file\n' > "$dir/home/config/aws-profile"

  set +e
  out=$(env \
    PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_AWS_PROFILE=from-env \
    FM_FAKE_AWS_LOG="$dir/aws.log" \
    "$SPEND" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "FM_AWS_PROFILE should succeed (got: $out)"
  assert_grep "--profile from-env" "$dir/aws.log" "FM_AWS_PROFILE should win over the file"

  set +e
  out=$(env \
    PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_AWS_PROFILE=from-env \
    FM_FAKE_AWS_LOG="$dir/aws.log" \
    "$SPEND" --profile from-flag 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--profile should succeed (got: $out)"
  assert_grep "--profile from-flag" "$dir/aws.log" "--profile should win over FM_AWS_PROFILE"

  : > "$dir/aws.log"
  set +e
  out=$(env \
    PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_AWS_PROFILE= \
    FM_FAKE_AWS_LOG="$dir/aws.log" \
    "$SPEND" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "empty FM_AWS_PROFILE should use ambient credentials (got: $out)"
  if grep -F -- "--profile" "$dir/aws.log" >/dev/null; then
    fail "empty FM_AWS_PROFILE still passed --profile"$'\n'"--- aws ---"$'\n'"$(cat "$dir/aws.log")"
  fi
  pass "FM_AWS_PROFILE and --profile override config; empty env uses ambient credentials"
}

test_missing_aws_is_a_concrete_error() {
  local dir out rc
  dir=$(make_env noaws)
  rm -f "$dir/fakebin/aws"
  printf 'dev\n' > "$dir/home/config/aws-profile"
  set +e
  out=$(run_spend "$dir" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing aws should exit 1"
  assert_contains "$out" "aws CLI not found" "missing aws should say so"
  pass "a missing aws CLI is a concrete error"
}

test_unauthenticated_profile_is_a_concrete_error() {
  local dir out rc
  dir=$(make_env unauth)
  printf 'stale-dev\n' > "$dir/home/config/aws-profile"
  set +e
  out=$(env -u FM_AWS_PROFILE \
    PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_FAKE_AWS_LOG="$dir/aws.log" \
    FM_FAKE_AWS_FAIL=1 \
    "$SPEND" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "Cost Explorer failure should exit 1"
  assert_contains "$out" "Cost Explorer query failed for profile stale-dev" \
    "auth failure should name the profile"
  assert_contains "$out" "UnrecognizedClientException" \
    "auth failure should keep the aws error"
  assert_contains "$out" "the profile may need re-authentication" \
    "auth failure should hint at re-authentication"
  pass "an unauthenticated profile fails with the profile name and a re-auth hint"
}

test_days_requests_daily_breakdown() {
  local dir out rc
  dir=$(make_env days)
  printf 'dev\n' > "$dir/home/config/aws-profile"
  daily_body > "$dir/body.json"
  set +e
  out=$(env -u FM_AWS_PROFILE \
    PATH="$dir/fakebin:$BASE_PATH" \
    FM_HOME="$dir/home" \
    FM_FAKE_AWS_LOG="$dir/aws.log" \
    FM_FAKE_AWS_BODY_FILE="$dir/body.json" \
    "$SPEND" --days 7 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--days 7 should succeed (got: $out)"
  assert_contains "$(cat "$dir/aws.log")" "granularity DAILY" "--days should request daily granularity"
  assert_contains "$out" "2026-08-21" "daily output should include the first day with spend"
  assert_contains "$out" "2026-08-22" "daily output should include the second day with spend"
  assert_contains "$out" "\$3.75" "daily output should include the window total"
  assert_contains "$out" "estimated, AWS has not finalised it" \
    "a window with any estimated day should be marked estimated"
  pass "--days requests a daily breakdown and prints per-day rows"
}

test_empty_window_is_a_clear_result() {
  local dir out rc
  dir=$(make_env empty)
  printf 'dev\n' > "$dir/home/config/aws-profile"
  set +e
  out=$(run_spend "$dir" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "an empty Cost Explorer window should succeed"
  assert_contains "$out" "no Bedrock cost recorded for this window" \
    "an empty window should say so instead of printing \$0.00"
  pass "an empty Cost Explorer window is a clear result"
}

need_python3
test_help_matches_behavior
test_unknown_and_bad_days_are_usage_errors
test_missing_profile_refuses_with_config_path
test_config_profile_is_used
test_env_and_flag_override_config
test_missing_aws_is_a_concrete_error
test_unauthenticated_profile_is_a_concrete_error
test_days_requests_daily_breakdown
test_empty_window_is_a_clear_result

echo '# all fm-bedrock-spend tests passed'
