#!/usr/bin/env bash
# tests/fm-copilot-harness.test.sh - portable regression for the copilot
# (GitHub Copilot CLI) crewmate/scout adapter: harness detection precedence,
# the control-plane mechanics, the session-event-log busy source, the composer
# shape, the dispatch-config verdict, and teardown of the busy binding.
#
# Needs no copilot binary and no credentials, so it runs everywhere CI runs.
# The live per-harness counterpart is
# tests/fm-harness-liveness-drift-live-e2e.test.sh.
#
# The event-log fixtures reproduce Copilot CLI 1.0.80's real record shapes. Two
# of them are load-bearing decoys. `abort` is what closes an INTERRUPTED turn,
# whose assistant.turn_start never gets a matching turn_end, so a fold that knew
# only the turn pair would report an interrupted pane busy forever. And an
# assistant message that merely QUOTES the close string must not close a turn,
# which is what forces the structural top-level-field parse instead of a search.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry, so an ambient
# marker from whichever harness launched this suite would outrank the markers
# under test. Drop them so the asserted verdicts are the code's, not the host's.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS COPILOT_CLI

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# --- event-log fixtures -----------------------------------------------------

ev_turn_start() { printf '{"type":"assistant.turn_start","data":{"turnId":"%s","interactionId":"4a246aad"},"id":"9bcd612e","timestamp":"2026-08-25T18:41:10.360Z"}\n' "$1"; }
ev_turn_end() { printf '{"type":"assistant.turn_end","data":{"turnId":"%s"},"id":"17d0d109","timestamp":"2026-08-25T18:41:15.057Z"}\n' "$1"; }
ev_abort() { printf '{"type":"abort","data":{"reason":"user_initiated"},"id":"7c1a"}\n'; }
ev_tool_start() { printf '{"type":"tool.execution_start","data":{"toolName":"shell"},"id":"aa01"}\n'; }
ev_session_start() { printf '{"type":"session.start","data":{"sessionId":"%s"},"id":"0001"}\n' "$1"; }
# The decoy: an assistant message whose own text quotes the close strings.
ev_quoting_message() { printf '{"type":"assistant.message","data":{"model":"gpt-5.4","content":"I will now emit assistant.turn_end and abort."},"id":"bb02"}\n'; }

# write_events <copilot-home> <session-id>; body records read from stdin.
write_events() {
  local home=$1 sid=$2 dir
  dir="$home/session-state/$sid"
  mkdir -p "$dir"
  ev_session_start "$sid" > "$dir/events.jsonl"
  cat >> "$dir/events.jsonl"
  printf '%s\n' "$dir/events.jsonl"
}

bind_task() {  # <state-dir> <id> <copilot-home> <session-id>
  mkdir -p "$1"
  printf 'copilot_home=%s\nsession_id=%s\n' "$3" "$4" > "$1/$2.copilot-session"
}

# --- detection --------------------------------------------------------------

# The cursor trap in its second form. Copilot does NOT clear an inherited
# CLAUDECODE (verified on 1.0.80: a copilot tool subprocess launched from a
# claude primary carried both), so a copilot worker presents BOTH markers and
# whichever is tested first decides. Testing copilot first is what makes the
# verdict correct; the reversed single-marker case below proves the claude path
# is still intact rather than shadowed.
out=$(COPILOT_CLI=1 CLAUDECODE=1 "$HARNESS")
[ "$out" = copilot ] || fail "copilot's own marker must outrank an inherited CLAUDECODE (got '$out')"
pass "detection: COPILOT_CLI outranks an inherited CLAUDECODE"

out=$(CLAUDECODE=1 "$HARNESS")
[ "$out" = claude ] || fail "CLAUDECODE alone must still resolve claude (got '$out')"
pass "detection: the claude marker is unshadowed by the copilot ordering"

out=$(COPILOT_CLI=0 "$HARNESS" 2>/dev/null || true)
[ "$out" != copilot ] || fail "COPILOT_CLI must be matched on its exact value, not presence"
pass "detection: COPILOT_CLI is matched on value, not presence"

# --- control-plane mechanics ------------------------------------------------

fm_control_harness_supported copilot || fail "copilot must be a supported control harness"
[ "$(fm_control_harness_family copilot-1.0.80)" = copilot ] \
  || fail "a raw-command-recorded copilot harness must resolve to the copilot adapter"

# Escape is the fleet default and is WRONG here: copilot's footer advertises
# `esc interrupt`, but six delivered Escapes left a running turn working, while
# one Ctrl+C cancelled it. This assertion exists to stop that being "fixed"
# back to the default on the strength of the rendered hint.
[ "$(fm_control_interrupt_key copilot)" = C-c ] \
  || fail "copilot must interrupt on Ctrl+C, not the fleet-default Escape"
[ "$(fm_control_interrupt_key claude)" = Escape ] \
  || fail "the fleet default must be unchanged for other adapters"
[ "$(fm_control_interrupt_repeat copilot)" = 1 ] || fail "copilot interrupts on a single press"
[ -z "$(fm_control_interrupt_clear_key copilot)" ] \
  || fail "copilot's composer does not repollute after an interrupt and needs no clear key"
[ "$(fm_control_interrupt_ack_source copilot)" = copilot-events-abort ] \
  || fail "copilot's typed abort record is an observable cancellation acknowledgement"
[ "$(fm_control_exit_command copilot)" = /exit ] || fail "copilot exits on /exit"
pass "control: copilot's interrupt, acknowledgement, and exit mechanics"

fm_control_harness_supports_kind copilot crewmate || fail "copilot must run a crewmate"
fm_control_harness_supports_kind copilot scout || fail "copilot must run a scout"
! fm_control_harness_supports_kind copilot secondmate \
  || fail "copilot must be refused for a secondmate: no verified turn-end hook event"
pass "control: copilot runs crewmate and scout kinds but is refused for secondmate"

out=$(fm_control_harness_wiring_paths copilot /wt /state t-9)
[ "$out" = /state/t-9.copilot-session ] \
  || fail "a relaunch away from copilot must retire its session binding (got '$out')"
pass "control: copilot's session binding is registered as per-task wiring"

# --- busy source ------------------------------------------------------------

CB=$TMP_ROOT/busy
mkdir -p "$CB/home" "$CB/state"

# Nothing is armed for copilot: it is a pull source with no writer, so a seeded
# record could never be cleared.
[ -z "$(fm_busy_sources_for_harness copilot)" ] \
  || fail "copilot must arm no pushed busy sources"
pass "busy: copilot arms no writer-backed source"

log=$(write_events "$CB/home" s-open < <( { ev_turn_start 0; ev_tool_start; } ))
bind_task "$CB/state" t-open "$CB/home" s-open
[ "$(fm_busy_copilot_turn_state "$log")" = busy ] || fail "an open turn must read busy"
# The property that makes this source better than a rendered spinner or
# opencode's native idle: a worker inside a long foreground shell call is busy.
[ "$(fm_busy_classify tmux w copilot t-open "$CB/state")" = "busy copilot-events" ] \
  || fail "a turn open across a running tool call must classify busy"
pass "busy: an open turn reads busy, tool execution included"

log=$(write_events "$CB/home" s-done < <( { ev_turn_start 0; ev_turn_end 0; } ))
bind_task "$CB/state" t-done "$CB/home" s-done
[ "$(fm_busy_classify tmux w copilot t-done "$CB/state")" = "idle copilot-events" ] \
  || fail "a settled turn must classify idle"
pass "busy: a settled turn reads idle"

# The interrupt decoy: turn_start with no matching turn_end, closed only by
# abort. Without abort in the close set this reads busy forever.
log=$(write_events "$CB/home" s-abort < <( { ev_turn_start 0; ev_turn_end 0; ev_turn_start 0; ev_abort; } ))
bind_task "$CB/state" t-abort "$CB/home" s-abort
[ "$(fm_busy_classify tmux w copilot t-abort "$CB/state")" = "idle copilot-events" ] \
  || fail "an interrupted turn is closed by abort, not left busy forever"
pass "busy: abort closes an interrupted turn"

# The quoting decoy: the close strings appear only inside assistant prose.
log=$(write_events "$CB/home" s-quote < <( { ev_turn_start 0; ev_quoting_message; } ))
bind_task "$CB/state" t-quote "$CB/home" s-quote
[ "$(fm_busy_classify tmux w copilot t-quote "$CB/state")" = "busy copilot-events" ] \
  || fail "a message quoting the close string must not close the turn"
pass "busy: a turn whose own text quotes the close string stays open"

# Both parser arms must agree, because which one runs depends only on whether
# jq happens to be installed.
for sid in s-open s-done s-abort s-quote; do
  L=$CB/home/session-state/$sid/events.jsonl
  a=$(fm_busy_copilot_turn_state "$L")
  b=$(PATH=/usr/bin:/bin fm_busy_copilot_turn_state "$L")
  [ "$a" = "$b" ] || fail "the jq and awk folds disagree on $sid ($a vs $b)"
done
pass "busy: the jq and awk folds agree on every fixture"

# A session whose log copilot has not created yet is unknown, never idle: the
# log appears only on the session's first turn.
mkdir -p "$CB/home/session-state/s-nolog"
bind_task "$CB/state" t-nolog "$CB/home" s-nolog
[ "$(fm_busy_classify tmux w copilot t-nolog "$CB/state")" = "unknown copilot-events" ] \
  || fail "a session with no event log yet must be unknown, never idle"
[ "$(fm_busy_classify tmux w copilot t-nobind "$CB/state")" = "unknown copilot-events" ] \
  || fail "an unbound task must be unknown, never idle"
log=$(write_events "$CB/home" s-empty < /dev/null)
bind_task "$CB/state" t-empty "$CB/home" s-empty
[ "$(fm_busy_classify tmux w copilot t-empty "$CB/state")" = "unknown copilot-events" ] \
  || fail "a log with no turn record must be unknown, never idle"
pass "busy: an absent, unbound, or record-free log is unknown rather than idle"

# The interrupt acknowledgement counts closes rather than testing for presence:
# the log keeps every earlier interrupt's abort, so presence alone would confirm
# a cancellation that happened turns ago. bin/fm-control.sh takes this count
# before delivering the key and claims confirmed only when it grows.
log=$(write_events "$CB/home" s-two < <( { ev_turn_start 0; ev_abort; ev_turn_start 0; ev_abort; } ))
[ "$(fm_busy_copilot_abort_count "$log")" = 2 ] \
  || fail "the abort count must see both records (got '$(fm_busy_copilot_abort_count "$log")')"
[ "$(PATH=/usr/bin:/bin fm_busy_copilot_abort_count "$log")" = 2 ] \
  || fail "the awk arm must count aborts identically"
log=$(write_events "$CB/home" s-noabort < <( { ev_turn_start 0; ev_turn_end 0; } ))
[ "$(fm_busy_copilot_abort_count "$log")" = 0 ] \
  || fail "a log with no abort must count zero"
# A quoted abort must not inflate the count, for the same structural reason.
log=$(write_events "$CB/home" s-quoteabort < <( { ev_turn_start 0; ev_quoting_message; } ))
[ "$(fm_busy_copilot_abort_count "$log")" = 0 ] \
  || fail "a message quoting abort must not count as a cancellation"
pass "busy: the interrupt acknowledgement counts real abort records only"

# The shared fold must still serve cursor identically after being parameterized.
CUR=$TMP_ROOT/cursor.jsonl
{ printf '{"role":"user","text":"hi"}\n'; printf '{"type":"turn_ended","status":"aborted"}\n'; } > "$CUR"
[ "$(fm_busy_cursor_turn_state "$CUR")" = settled ] \
  || fail "the shared fold must still close a cursor turn on turn_ended"
pass "busy: the shared JSONL fold still serves cursor's own records"

# --- composer shape ---------------------------------------------------------

# Real captures from Copilot CLI 1.0.80. Copilot draws a bare `❯` glyph row
# between two solid rules, and its brand mark `╭─╮╭─╮` sits above in the same
# screen. Read as a single box top, that mark opened a box nothing closed and
# the unclosed-box rule marked the WHOLE screen unsafe, so every copilot pane
# classified unknown and no steer could confirm an empty composer.
CAPS='styled=1
cursor=1
identity=1
rows=0'
for pair in idle:empty pending:pending; do
  f=${pair%%:*}
  want=${pair##*:}
  fx="$ROOT/tests/fixtures/copilot-composer-$f.ansi"
  [ -f "$fx" ] || fail "missing fixture $fx"
  grep -q '╭─╮╭─╮' "$fx" \
    || fail "fixture $f no longer carries the brand mark, so this case would be vacuous"
  got=$(fm_composer_classify_screen "$CAPS" "$(cat "$fx")" 21 probe-absent)
  [ "$got" = "$want" ] || fail "copilot composer $f must classify $want (got '$got')"
done
pass "composer: copilot's bare glyph row classifies empty and pending past its brand mark"

# Non-vacuity: the decoration guard is what produces those verdicts.
got=$(
  # shellcheck disable=SC2034  # sourced fresh in a subshell to override one function
  . "$ROOT/bin/fm-composer-lib.sh"
  _fm_composer_row_is_multibox() { return 1; }
  fm_composer_classify_screen "$CAPS" "$(cat "$ROOT/tests/fixtures/copilot-composer-idle.ansi")" 21 probe-absent
)
[ "$got" = unknown ] \
  || fail "without the decoration guard the brand mark must poison the screen (got '$got')"
pass "composer: the decoration guard is what keeps the brand mark from poisoning the screen"

# A real composer border carries exactly two corners and must be untouched.
_fm_composer_row_is_multibox '╭────────╮' rounded \
  && fail "a plain box top must not be read as decoration"
_fm_composer_row_is_multibox '╰─ gpt-5.4 ─╯' rounded \
  && fail "a titled bottom border must not be read as decoration"
_fm_composer_row_is_multibox '╭─╮╭─╮' rounded \
  || fail "copilot's side-by-side brand mark must be read as decoration"
pass "composer: only a genuine multi-box row is treated as decoration"

# --- dispatch config verdict ------------------------------------------------

DH=$TMP_ROOT/home
mkdir -p "$DH/config" "$DH/state" "$DH/data"
printf '%s\n' '{"default":{"harness":"copilot","model":"gpt-5.5","effort":"xhigh"}}' \
  > "$DH/config/crew-dispatch.json"
out=$(FM_HOME="$DH" "$BOOTSTRAP" 2>&1 | grep '^CREW_DISPATCH:' || true)
[ -z "$out" ] || fail "copilot must be accepted as a verified dispatch harness (got '$out')"
pass "dispatch: config/crew-dispatch.json accepts copilot"

printf '%s\n' '{"default":{"harness":"copilot","effort":"banana"}}' \
  > "$DH/config/crew-dispatch.json"
out=$(FM_HOME="$DH" "$BOOTSTRAP" 2>&1 | grep '^CREW_DISPATCH:' || true)
assert_contains "$out" 'invalid effort: copilot:banana' \
  "an effort outside copilot's accepted set must still be refused"
pass "dispatch: an unsupported copilot effort is still refused"

printf '%s\n' '{"default":{"harness":"copilot","effort":"minimal"}}' \
  > "$DH/config/crew-dispatch.json"
out=$(FM_HOME="$DH" "$BOOTSTRAP" 2>&1 | grep '^CREW_DISPATCH:' || true)
assert_contains "$out" 'invalid effort: copilot:minimal' \
  "copilot's none/minimal levels sit below the shared vocabulary and stay unreachable"
pass "dispatch: copilot's sub-vocabulary effort levels stay unreachable"

# --- spawn refusal ----------------------------------------------------------

SH_HOME=$TMP_ROOT/spawn
mkdir -p "$SH_HOME/state" "$SH_HOME/data" "$SH_HOME/config"
out=$(FM_HOME="$SH_HOME" "$SPAWN" cp-x "$SH_HOME" --harness copilot --secondmate 2>&1 || true)
assert_contains "$out" 'copilot is a verified crewmate/scout adapter only' \
  "a copilot secondmate spawn must be refused before any endpoint exists"
[ -f "$SH_HOME/state/cp-x.meta" ] && fail "the refused secondmate spawn must leave no task metadata"
pass "spawn: a copilot secondmate launch is refused before an endpoint exists"

echo "# fm-copilot-harness.test.sh: all checks passed"
