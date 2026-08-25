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
# Copilot's abort record types the same whatever ended the turn; only this
# nested reason says a human asked for it.
ev_abort_reason() { printf '{"type":"abort","data":{"reason":"%s"},"id":"7c1b"}\n' "$1"; }
ev_tool_start() { printf '{"type":"tool.execution_start","data":{"toolName":"shell"},"id":"aa01"}\n'; }
ev_session_start() { printf '{"type":"session.start","data":{"sessionId":"%s"},"id":"0001"}\n' "$1"; }
# The decoy: an assistant message whose own text quotes the close strings.
ev_quoting_message() { printf '{"type":"assistant.message","data":{"model":"gpt-5.4","content":"I will now emit assistant.turn_end and abort."},"id":"bb02"}\n'; }
ev_message() { printf '{"type":"assistant.message","data":{"model":"%s","content":"done"},"id":"cc01","timestamp":"2026-08-25T18:41:14.900Z"}\n' "$1"; }
# A subagent message: same record type, its own model, and the parentToolCallId
# that is the only structural field separating it from the session's own.
ev_subagent_message() { printf '{"type":"assistant.message","data":{"model":"%s","parentToolCallId":"call_eyAKlPdL7lbnEpn1bhzfdoNL","content":"sub"},"id":"cc02"}\n' "$1"; }
# A message with no model at all - common in real logs, and never an answer.
ev_modelless_message() { printf '{"type":"assistant.message","data":{"content":"thinking"},"id":"cc03"}\n'; }
# A message whose PROSE quotes a model id a byte match would seize on, while
# its own record names the model the session is really running.
ev_quoting_model_message() { printf '{"type":"assistant.message","data":{"model":"gpt-5.4","content":"Set \\"model\\":\\"gpt-4.1\\" in the config."},"id":"cc04"}\n'; }

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
# jq happens to be installed. Forcing the awk arm needs an EXCLUSIVE PATH
# holding only the utilities the copilot fold shells out to: prepending a
# directory is not enough, because jq ships in /usr/bin on both platforms this
# suite runs on and any inherited entry would resolve it and silently re-run the
# jq arm. The fold pipes through grep as a prefilter as well as awk, so both are
# linked in; the guard below is what keeps this case from going vacuous again.
awk_bin=$(command -v awk) || fail "awk is required to exercise the no-jq fold"
grep_bin=$(command -v grep) || fail "grep is required to exercise the no-jq fold"
NO_JQ_BIN=$TMP_ROOT/no-jq-bin
mkdir -p "$NO_JQ_BIN"
ln -sf "$awk_bin" "$NO_JQ_BIN/awk"
ln -sf "$grep_bin" "$NO_JQ_BIN/grep"

# Every no-jq case runs through this ONE helper, guard included. A temp-prefix
# assignment before a shell function (PATH=x f) does not flush bash's command
# hash table, so a hashed jq stays reachable inside f while a separate
# `( PATH=x; command -v jq )` probe reports it hidden - a guard using the second
# form would pass while the assertions it guards silently re-ran the jq arm.
# Sharing one form is what keeps the guard's verdict true of the assertions.
no_jq() { ( PATH=$NO_JQ_BIN; "$@" ); }

if no_jq command -v jq >/dev/null 2>&1; then
  fail "the awk-arm PATH still resolves jq, so every assertion below would re-run the jq arm"
fi
pass "busy: the no-jq PATH genuinely hides jq, so the awk-arm cases below are not vacuous"

for sid in s-open s-done s-abort s-quote; do
  L=$CB/home/session-state/$sid/events.jsonl
  a=$(fm_busy_copilot_turn_state "$L")
  b=$(no_jq fm_busy_copilot_turn_state "$L")
  [ "$a" = "$b" ] || fail "the jq and awk folds disagree on $sid ($a vs $b)"
done
pass "busy: the jq and awk folds agree on every fixture"

# Unreachable jq is only half the claim; the awk arm must be what actually
# produced those verdicts. Breaking awk under the same PATH is what proves it:
# if the fold still returned a verdict, something other than awk parsed the log.
BROKEN_AWK_BIN=$TMP_ROOT/broken-awk-bin
mkdir -p "$BROKEN_AWK_BIN"
ln -sf "$grep_bin" "$BROKEN_AWK_BIN/grep"
printf '#!/bin/sh\nexit 1\n' > "$BROKEN_AWK_BIN/awk"
chmod +x "$BROKEN_AWK_BIN/awk"
L=$CB/home/session-state/s-open/events.jsonl
[ "$(fm_busy_copilot_turn_state "$L")" = busy ] \
  || fail "the open-turn fixture must read busy before this case can mean anything"
out=$( PATH=$BROKEN_AWK_BIN; fm_busy_copilot_turn_state "$L" )
[ -z "$out" ] \
  || fail "a broken awk still yielded '$out', so the no-jq verdicts did not come from the awk arm"
pass "busy: breaking awk breaks the no-jq verdict, so the awk arm is what produced it"

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
[ "$(no_jq fm_busy_copilot_abort_count "$log")" = 2 ] \
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

# The two consumers of an abort record deliberately DISAGREE, and that split is
# load-bearing. Any abort ends the turn, so the busy fold must close on it
# whatever the cause - narrowing there would leave a non-user abort's
# assistant.turn_start unmatched and that pane would read busy forever. But
# bin/fm-control.sh turns a growth in the abort COUNT into `cancel=confirmed`, so
# only a human cancellation may be counted; anything else would report an
# interrupt that never landed.
log=$(write_events "$CB/home" s-abort-other < <( { ev_turn_start 0; ev_abort_reason context_limit; } ))
bind_task "$CB/state" t-abort-other "$CB/home" s-abort-other
[ "$(fm_busy_classify tmux w copilot t-abort-other "$CB/state")" = "idle copilot-events" ] \
  || fail "an abort with a non-user reason must still close the turn, never leave it busy"
[ "$(fm_busy_copilot_abort_count "$log")" = 0 ] \
  || fail "an abort with a non-user reason must not be counted as a cancellation"
[ "$(no_jq fm_busy_copilot_abort_count "$log")" = 0 ] \
  || fail "the awk arm must also refuse to count a non-user abort"
[ "$(no_jq fm_busy_copilot_turn_state "$log")" = settled ] \
  || fail "the awk arm must also close the turn on a non-user abort"

log=$(write_events "$CB/home" s-abort-user < <( { ev_turn_start 0; ev_abort_reason user_initiated; } ))
[ "$(fm_busy_copilot_abort_count "$log")" = 1 ] \
  || fail "a user-initiated abort must both close the turn and be counted"
[ "$(no_jq fm_busy_copilot_abort_count "$log")" = 1 ] \
  || fail "the awk arm must count a user-initiated abort identically"

# The legacy spelling carries a SPACE, so a value set split on spaces would tear
# it in half and silently report a real cancellation as unconfirmed.
log=$(write_events "$CB/home" s-abort-legacy < <( { ev_turn_start 0; ev_abort_reason 'user initiated'; } ))
[ "$(fm_busy_copilot_abort_count "$log")" = 1 ] \
  || fail "the spaced legacy reason spelling must still count as a cancellation"
[ "$(no_jq fm_busy_copilot_abort_count "$log")" = 1 ] \
  || fail "the awk arm must accept the spaced legacy reason spelling too"

# A reason nested under some OTHER key must not qualify, or the match is not
# really reading the abort record's own data.reason.
log=$(write_events "$CB/home" s-abort-foreign < <( { ev_turn_start 0; printf '{"type":"abort","data":{"cause":"x"},"meta":{"reason":"user_initiated"},"id":"7c1c"}\n'; } ))
[ "$(fm_busy_copilot_abort_count "$log")" = 0 ] \
  || fail "a reason under a different parent key must not qualify as a cancellation"
[ "$(no_jq fm_busy_copilot_abort_count "$log")" = 0 ] \
  || fail "the awk arm must also require the reason to sit under data"
pass "busy: any abort closes the turn, but only a user-initiated one is a cancellation"

# A lifecycle field whose value is a COMPOSITE must never match, and the two
# arms must say so identically. The awk arm parses arrays element by element, so
# a value that is not restored on the way out leaves the last ELEMENT standing
# where the array should be - and an array ending in a lifecycle string would
# then close a turn, or be counted as a landed cancellation, on exactly the
# hosts that have no jq to disagree.
L=$(write_events "$CB/home" s-arr-type < <( printf '{"type":["assistant.turn_end"],"id":"d1"}\n' ))
bind_task "$CB/state" t-arr-type "$CB/home" s-arr-type
a=$(fm_busy_copilot_turn_state "$L"); b=$(no_jq fm_busy_copilot_turn_state "$L")
[ "$a" = "$b" ] || fail "the arms disagree on an array-valued type ($a vs $b)"
[ "$a" = none ] || fail "an array-valued type must not close a turn (got '$a')"

L=$(write_events "$CB/home" s-obj-type < <( printf '{"type":{"name":"assistant.turn_end"},"id":"d2"}\n' ))
a=$(fm_busy_copilot_turn_state "$L"); b=$(no_jq fm_busy_copilot_turn_state "$L")
[ "$a" = "$b" ] || fail "the arms disagree on an object-valued type ($a vs $b)"
[ "$a" = none ] || fail "an object-valued type must not close a turn (got '$a')"

# The same hole reached through the qualifier, which is what the cancellation
# count rides on.
L=$(write_events "$CB/home" s-arr-reason < <( { ev_turn_start 0; printf '{"type":"abort","data":{"reason":["user_initiated"]},"id":"d3"}\n'; } ))
a=$(fm_busy_copilot_abort_count "$L"); b=$(no_jq fm_busy_copilot_abort_count "$L")
[ "$a" = "$b" ] || fail "the arms disagree on an array-valued reason ($a vs $b)"
[ "$a" = 0 ] || fail "an array-valued reason must not be counted as a cancellation (got '$a')"

L=$(write_events "$CB/home" s-obj-reason < <( { ev_turn_start 0; printf '{"type":"abort","data":{"reason":{"kind":"user_initiated"}},"id":"d4"}\n'; } ))
a=$(fm_busy_copilot_abort_count "$L"); b=$(no_jq fm_busy_copilot_abort_count "$L")
[ "$a" = "$b" ] || fail "the arms disagree on an object-valued reason ($a vs $b)"
[ "$a" = 0 ] || fail "an object-valued reason must not be counted as a cancellation (got '$a')"

# A real reason followed by a composite SIBLING must still qualify: the sibling
# is parsed after the match, so restoring its kind must not undo the verdict.
L=$(write_events "$CB/home" s-sibling < <( { ev_turn_start 0; printf '{"type":"abort","data":{"reason":"user_initiated","tags":["x","y"]},"id":"d5"}\n'; } ))
a=$(fm_busy_copilot_abort_count "$L"); b=$(no_jq fm_busy_copilot_abort_count "$L")
[ "$a" = "$b" ] || fail "the arms disagree when a composite sibling follows the reason ($a vs $b)"
[ "$a" = 1 ] || fail "a real reason must still count when a composite sibling follows it (got '$a')"
pass "busy: a composite lifecycle value never matches, and both arms agree it does not"

# A duplicate top-level key is decided by its LAST occurrence, because that is
# what jq's fromjson does. A flag latched on the first match would let an earlier
# occurrence win, and the two arms would split on identical bytes.
L=$(write_events "$CB/home" s-dup-close-first < <( { ev_turn_start 0; printf '{"type":"assistant.turn_end","type":"assistant.message","id":"e1"}\n'; } ))
a=$(fm_busy_copilot_turn_state "$L"); b=$(no_jq fm_busy_copilot_turn_state "$L")
[ "$a" = "$b" ] || fail "the arms disagree when an earlier duplicate type closes ($a vs $b)"
[ "$a" = busy ] || fail "a later duplicate type that does not close must leave the turn open (got '$a')"

L=$(write_events "$CB/home" s-dup-close-last < <( { ev_turn_start 0; printf '{"type":"assistant.message","type":"assistant.turn_end","id":"e2"}\n'; } ))
a=$(fm_busy_copilot_turn_state "$L"); b=$(no_jq fm_busy_copilot_turn_state "$L")
[ "$a" = "$b" ] || fail "the arms disagree when a later duplicate type closes ($a vs $b)"
[ "$a" = settled ] || fail "a later duplicate type that closes must close the turn (got '$a')"

# The same last-wins rule on the qualifier, which is what the cancellation count
# rides on.
L=$(write_events "$CB/home" s-dup-reason-first < <( { ev_turn_start 0; printf '{"type":"abort","data":{"reason":"user_initiated","reason":"context_limit"},"id":"e3"}\n'; } ))
a=$(fm_busy_copilot_abort_count "$L"); b=$(no_jq fm_busy_copilot_abort_count "$L")
[ "$a" = "$b" ] || fail "the arms disagree when an earlier duplicate reason is user-initiated ($a vs $b)"
[ "$a" = 0 ] || fail "a later duplicate reason must override an earlier user-initiated one (got '$a')"

L=$(write_events "$CB/home" s-dup-reason-last < <( { ev_turn_start 0; printf '{"type":"abort","data":{"reason":"context_limit","reason":"user_initiated"},"id":"e4"}\n'; } ))
a=$(fm_busy_copilot_abort_count "$L"); b=$(no_jq fm_busy_copilot_abort_count "$L")
[ "$a" = "$b" ] || fail "the arms disagree when a later duplicate reason is user-initiated ($a vs $b)"
[ "$a" = 1 ] || fail "a later duplicate reason that is user-initiated must count (got '$a')"

# A duplicate qualifier PARENT is decided the same way: the last data object
# stands, even when it carries no reason at all.
L=$(write_events "$CB/home" s-dup-parent < <( { ev_turn_start 0; printf '{"type":"abort","data":{"reason":"user_initiated"},"data":{"note":"x"},"id":"e5"}\n'; } ))
a=$(fm_busy_copilot_abort_count "$L"); b=$(no_jq fm_busy_copilot_abort_count "$L")
[ "$a" = "$b" ] || fail "the arms disagree when a later duplicate data drops the reason ($a vs $b)"
[ "$a" = 0 ] || fail "a later duplicate data without a reason must override an earlier one (got '$a')"
pass "busy: a duplicate key is decided by its last occurrence, and both arms agree which"

# The qualifier gates the CLOSE test only, so a record that fails it falls
# through to the OPEN test rather than becoming inert. That is invisible to
# today's callers - the abort counter passes an open key nothing can match - but
# it is the contract the next adapter author wires against, so pin the verdict
# both ways round through the classifier itself.
cls() { printf '%s\n' "$2" | _fm_busy_jsonl_turn_events "$1" type abort type abort; }
R_FAIL='{"type":"abort","data":{"reason":"context_limit"}}'
R_PASS='{"type":"abort","data":{"reason":"user_initiated"}}'
Q='data.reason=user_initiated'

a=$(cls "$Q" "$R_FAIL"); b=$(no_jq cls "$Q" "$R_FAIL")
[ "$a" = "$b" ] || fail "the arms disagree on a qualifier-failing record whose key also opens ($a vs $b)"
[ "$a" = open ] || fail "a qualifier-failing close must fall through to the open test (got '$a')"

a=$(cls "$Q" "$R_PASS"); b=$(no_jq cls "$Q" "$R_PASS")
[ "$a" = "$b" ] || fail "the arms disagree on a qualifier-passing record whose key also opens ($a vs $b)"
[ "$a" = close ] || fail "a qualifier-passing record must still close (got '$a')"

# The mitigation the abort counter uses: an open key nothing can match makes the
# same qualifier-failing record inert.
inert() { printf '%s\n' "$R_FAIL" | _fm_busy_jsonl_turn_events "$Q" type __never__ type abort; }
a=$(inert); b=$(no_jq inert)
[ "$a" = "$b" ] || fail "the arms disagree once the open key cannot match ($a vs $b)"
[ "$a" = other ] || fail "an unmatchable open key must leave a qualifier-failing record inert (got '$a')"
pass "busy: the qualifier gates only the close test, and an unmatchable open key is what makes a failure inert"

# --- effective model --------------------------------------------------------

# The substitution warning's whole correctness is about WHEN the model is read.
# copilot writes assistant.message only once the first inference round
# completes, which is strictly later than the assistant.turn_start the launch
# gate returns on, so a read taken at gate-return time finds nothing and the
# warning silently never fires. These cases pin the timing rather than the text.
L=$(write_events "$CB/home" s-model-none < <( ev_turn_start 0 ))
[ -z "$(fm_busy_copilot_effective_model "$L")" ] \
  || fail "a log holding only turn_start must yield no model, the shape the gate returns on"

# The bounded wait must give up rather than fail the spawn or hang.
out=$(fm_busy_copilot_wait_for_effective_model "$L" 3 0.05) && rc=0 || rc=$?
[ "$rc" != 0 ] || fail "the wait must report failure when no model record ever arrives"
[ -z "$out" ] || fail "an exhausted budget must print nothing (got '$out')"
pass "effective model: the record the gate returns on carries none, and the wait gives up bounded"

# The regression itself: a single immediate read - the broken shape - returns
# nothing here, so only a wait that actually polls can see the appended record.
L=$(write_events "$CB/home" s-model-late < <( ev_turn_start 0 ))
( sleep 0.5; ev_message gpt-5.4 >> "$L" ) &
appender=$!
out=$(fm_busy_copilot_wait_for_effective_model "$L" 50 0.1) && rc=0 || rc=$?
wait "$appender"
[ "$rc" = 0 ] || fail "the wait must succeed once the assistant.message lands"
[ "$out" = gpt-5.4 ] || fail "the wait must report the model that landed (got '$out')"
pass "effective model: the wait keeps polling until the record copilot writes late arrives"

# A subagent carries its own data.model and must never be mistaken for the
# session's: in real 1.0.80 logs every non-session model id came from one.
L=$(write_events "$CB/home" s-model-sub < <( { ev_turn_start 0; ev_message gpt-5.4; ev_subagent_message gpt-4.1; } ))
[ "$(fm_busy_copilot_effective_model "$L")" = gpt-5.4 ] \
  || fail "a subagent's model must not be reported as the session's"
# ... including when the subagent message is the newest record in the log.
L=$(write_events "$CB/home" s-model-subtail < <( { ev_turn_start 0; ev_subagent_message gpt-4.1; ev_message gpt-5.4; ev_subagent_message claude-sonnet-4.5; } ))
[ "$(fm_busy_copilot_effective_model "$L")" = gpt-5.4 ] \
  || fail "a trailing subagent message must not decide the session's model"
# A model-less message is skipped rather than answered with.
L=$(write_events "$CB/home" s-model-empty < <( { ev_turn_start 0; ev_modelless_message; ev_message gpt-5.5; } ))
[ "$(fm_busy_copilot_effective_model "$L")" = gpt-5.5 ] \
  || fail "a message carrying no model must be skipped, not treated as an answer"
# A model id quoted inside assistant prose is not a model record.
L=$(write_events "$CB/home" s-model-quote < <( { ev_turn_start 0; ev_quoting_model_message; } ))
[ "$(fm_busy_copilot_effective_model "$L")" = gpt-5.4 ] \
  || fail "the structural read must take the record's own data.model field, not a model id in its prose"
pass "effective model: only the session's own message with a model field decides"

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
