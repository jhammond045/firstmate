#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: the guarded fast-forward path firstmate uses
# to land an approved local-only ship task.
#
# Regression coverage for the branch-name mismatch between fm-brief.sh (which
# requires an explicit --branch and substitutes it verbatim into the brief the
# crewmate checks out) and fm-merge-local.sh (which used to hardcode fm/<id>
# regardless of what the crewmate was actually briefed to use). The script now
# resolves the branch from state/<id>.meta's branch= field, written by
# bin/fm-spawn.sh from the brief's own "Delivery contract: ... branch=<name>"
# line, and falls back to fm/<id> only when no branch= is recorded.
#
# Matrix:
#   (a) a descriptive recorded branch= lands via clean fast-forward
#   (b) no recorded branch= falls back to fm/<id> and still lands
#   (c) a diverged recorded branch still refuses with REFUSED, naming the branch
#   (d) a recorded branch= that does not exist refuses rather than guessing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# make_case <name>: a state dir plus a project repo checked out on a
# deterministic "main" default branch with one commit. Echoes the case dir.
make_case() {
  local name=$1 case_dir proj
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state"
  git init -q -b main "$proj"
  printf '# fixture\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  printf '%s\n' "$case_dir"
}

test_recorded_branch_lands() {
  local case_dir proj out status
  case_dir=$(make_case recorded-lands)
  proj="$case_dir/project"
  git -C "$proj" checkout -q -b fix/JIRA-1/short-desc
  printf 'work\n' > "$proj/work.txt"
  git -C "$proj" add work.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm work
  git -C "$proj" checkout -q main
  fm_write_meta "$case_dir/state/task-a1.meta" \
    "project=$proj" \
    "mode=local-only" \
    "branch=fix/JIRA-1/short-desc"

  out=$(FM_STATE_OVERRIDE="$case_dir/state" "$MERGE_LOCAL" task-a1 2>&1); status=$?
  expect_code 0 "$status" "recorded-branch merge should exit 0 (got: $out)"
  assert_contains "$out" "merged fix/JIRA-1/short-desc into local main" \
    "success message did not name the recorded branch"
  assert_present "$proj/work.txt" "main was not fast-forwarded to the recorded branch"
  pass "fm-merge-local.sh: a descriptive recorded branch= lands via clean fast-forward"
}

test_absent_branch_falls_back_to_fm_id() {
  local case_dir proj out status
  case_dir=$(make_case fallback-default)
  proj="$case_dir/project"
  git -C "$proj" checkout -q -b fm/task-b1
  printf 'work\n' > "$proj/work.txt"
  git -C "$proj" add work.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm work
  git -C "$proj" checkout -q main
  fm_write_meta "$case_dir/state/task-b1.meta" \
    "project=$proj" \
    "mode=local-only"

  out=$(FM_STATE_OVERRIDE="$case_dir/state" "$MERGE_LOCAL" task-b1 2>&1); status=$?
  expect_code 0 "$status" "no-branch-recorded merge should still exit 0 (got: $out)"
  assert_contains "$out" "merged fm/task-b1 into local main" \
    "success message did not fall back to fm/<task-id>"
  assert_present "$proj/work.txt" "main was not fast-forwarded to the fm/<task-id> fallback branch"
  pass "fm-merge-local.sh: an absent branch= falls back to fm/<task-id> and still lands"
}

test_diverged_recorded_branch_refuses() {
  local case_dir proj out status
  case_dir=$(make_case diverged)
  proj="$case_dir/project"
  git -C "$proj" checkout -q -b fix/JIRA-2/diverged
  printf 'work\n' > "$proj/work.txt"
  git -C "$proj" add work.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm work
  git -C "$proj" checkout -q main
  printf 'unrelated\n' > "$proj/unrelated.txt"
  git -C "$proj" add unrelated.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm unrelated
  fm_write_meta "$case_dir/state/task-c1.meta" \
    "project=$proj" \
    "mode=local-only" \
    "branch=fix/JIRA-2/diverged"

  out=$(FM_STATE_OVERRIDE="$case_dir/state" "$MERGE_LOCAL" task-c1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a diverged recorded branch should refuse (exit non-zero)"
  assert_contains "$out" "REFUSED" "diverged merge did not print REFUSED"
  assert_contains "$out" "fix/JIRA-2/diverged" "refusal did not name the diverged branch"
  pass "fm-merge-local.sh: a diverged recorded branch still refuses and names the branch"
}

test_recorded_branch_missing_refuses() {
  local case_dir proj out status
  case_dir=$(make_case missing-branch)
  proj="$case_dir/project"
  fm_write_meta "$case_dir/state/task-d1.meta" \
    "project=$proj" \
    "mode=local-only" \
    "branch=fix/never/created"

  out=$(FM_STATE_OVERRIDE="$case_dir/state" "$MERGE_LOCAL" task-d1 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a recorded branch that does not exist should refuse (exit non-zero)"
  assert_contains "$out" "fix/never/created" "refusal did not name the missing recorded branch"
  assert_contains "$out" "does not exist" "refusal did not say the branch does not exist"
  pass "fm-merge-local.sh: a recorded branch that does not exist refuses rather than guessing fm/<task-id>"
}

test_recorded_branch_lands
test_absent_branch_falls_back_to_fm_id
test_diverged_recorded_branch_refuses
test_recorded_branch_missing_refuses
