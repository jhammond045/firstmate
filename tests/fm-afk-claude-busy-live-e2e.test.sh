#!/usr/bin/env bash
# Opt-in live guard for the away-mode injection busy read on a claude primary.
#
# Whether a Claude pane is mid-turn is a vendor-rendered fact, so no fixture can
# prove it. Herdr's native agent-state read for claude is dominated by the
# terminal's OSC title glyph, and Claude Code animates that glyph as a liveness
# pulse that is not gated on a running turn: an idle pane can report native
# "busy" indefinitely, which silently blocks every away-mode escalation. This
# guard reads a REAL, operator-declared idle Claude pane and fails naming the
# Claude version, the Herdr version, and the agent-detection manifest version
# rather than degrading quietly.
#
# It is opt-in because it needs a running Claude pane the operator can assert is
# idle. Run it after every Claude Code or Herdr upgrade, and after every refresh
# of Herdr's auto-updating detection manifest, before trusting the claude/herdr
# row in docs/verification/runtime-backends.md.
#
# Every Herdr call it makes is read-only (`agent get`, `agent explain`, and the
# backend's pane capture). It drives no Herdr lifecycle behavior and touches no
# firstmate state.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLES=${FM_AFK_CLAUDE_BUSY_LIVE_SAMPLES:-12}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_AFK_CLAUDE_BUSY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AFK_CLAUDE_BUSY_LIVE_E2E=1 to run the live claude-primary busy-read guard"
  exit 0
fi

TARGET=${FM_AFK_CLAUDE_BUSY_LIVE_TARGET:-}
if [ -z "$TARGET" ]; then
  echo "skip: set FM_AFK_CLAUDE_BUSY_LIVE_TARGET=<session>:<pane-id> to an IDLE Claude pane on Herdr"
  exit 0
fi

for tool in herdr claude jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

case "$TARGET" in
  *:*) ;;
  *) fail "FM_AFK_CLAUDE_BUSY_LIVE_TARGET must be '<session>:<pane-id>', got '$TARGET'" ;;
esac
SESSION=${TARGET%%:*}
PANE=${TARGET#*:}

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)
[ -n "$CLAUDE_VERSION" ] || fail "could not read the installed Claude Code version"
[ -n "$HERDR_VERSION" ] || fail "could not read the installed Herdr version"

AGENT_JSON=$(HERDR_SESSION="$SESSION" herdr agent get "$PANE" --session "$SESSION" 2>/dev/null) \
  || fail "herdr could not read agent state for $TARGET ($HERDR_VERSION)"
AGENT=$(printf '%s' "$AGENT_JSON" | jq -er '.result.agent.agent' 2>/dev/null) \
  || fail "herdr reported no agent for $TARGET; point the guard at a running Claude pane"
[ "$AGENT" = claude ] \
  || fail "$TARGET runs '$AGENT', not claude; this guard only covers the claude primary"

MANIFEST=$(HERDR_SESSION="$SESSION" herdr agent explain "$PANE" --session "$SESSION" -v 2>/dev/null \
  | sed -n 's/^manifest: //p' | head -1)
[ -n "$MANIFEST" ] || MANIFEST='(herdr reported no detection manifest)'

# Source the daemon for its pure functions; its main loop is skipped under
# sourcing via a BASH_SOURCE guard.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
FM_DAEMON_PRIMARY_HARNESS=claude
export FM_DAEMON_PRIMARY_HARNESS

NATIVE_BUSY=0
READ=0
i=0
while [ "$i" -lt "$SAMPLES" ]; do
  i=$((i + 1))
  NATIVE=$(fm_backend_busy_state herdr "$TARGET" 2>/dev/null)
  [ -n "$NATIVE" ] || fail "sample $i: herdr returned no native busy state for $TARGET"
  READ=$((READ + 1))
  [ "$NATIVE" = busy ] && NATIVE_BUSY=$((NATIVE_BUSY + 1))
  if pane_is_busy "$TARGET" herdr; then
    TAIL=$(fm_backend_capture herdr "$TARGET" 40 2>/dev/null | grep -v '^[[:space:]]*$' | tail -12)
    fail "sample $i: the declared-idle pane $TARGET read BUSY (native=$NATIVE).
  claude: $CLAUDE_VERSION
  herdr: $HERDR_VERSION
  detection manifest: $MANIFEST
  rendered tail:
$TAIL"
  fi
  [ "$i" -lt "$SAMPLES" ] && sleep 1
done

[ "$READ" -ge 5 ] \
  || fail "the guard read only $READ samples; a pass that checked nothing is not a pass"
pass "declared-idle claude pane $TARGET never read busy across $READ samples"

if [ "$NATIVE_BUSY" -gt 0 ]; then
  pass "rendered corroboration overrode $NATIVE_BUSY/$READ native 'busy' verdicts on the idle pane"
else
  pass "herdr reported no native 'busy' verdict on the idle pane during this run"
fi
printf 'evidence: target=%s samples=%s native_busy=%s claude=%s herdr=%s manifest=%s\n' \
  "$TARGET" "$READ" "$NATIVE_BUSY" "$CLAUDE_VERSION" "$HERDR_VERSION" "$MANIFEST"
