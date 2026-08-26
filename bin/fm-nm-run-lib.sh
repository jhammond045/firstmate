#!/usr/bin/env bash
# Shared no-mistakes axi run attribution and pipeline-agent liveness primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Also owns the axi-status active_steps + live agent_pid probe the watcher and
# AFK daemon use to tell a quiet validation poll from a wedged pane (#3087).
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" no-mistakes "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" no-mistakes "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" no-mistakes "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
#   - run head is not in this object store: no match here (see
#     fm_nm_head_matches_or_unfetched for current-state reads)
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 if run head $2 cannot be resolved as a commit in worktree $1. Empty heads
# are missing identity, not an unfetched pipeline tip, and reject.
fm_nm_head_unresolvable() {  # <worktree> <run_head>
  local wt=$1 run_head=$2
  [ -n "$run_head" ] || return 1
  git -C "$wt" rev-parse --verify "${run_head}^{commit}" >/dev/null 2>&1 && return 1
  return 0
}

# Current-state attribution: identity match, or the run tip is absent from this
# object store because the pipeline advanced it in another worktree
# (pipeline_owned). Resolvable but diverged or local-ahead heads still reject.
# Teardown abort keeps fm_nm_head_matches_worktree so it never acts on a run
# whose objects this worktree cannot name.
fm_nm_head_matches_or_unfetched() {  # <worktree> <run_head>
  fm_nm_head_matches_worktree "$1" "$2" && return 0
  fm_nm_head_unresolvable "$1" "$2"
}

# Quote-aware CSV field $2 (1-based) from row $1. Used to read axi-status
# active_steps rows, whose last_activity field is quoted and may contain commas.
fm_nm_csv_field() {  # <row> <1-based-n>
  local row=$1 n=$2 i=1 field='' inq=0 c
  row=$(fm_nm_trim "$row")
  while [ "${#row}" -gt 0 ]; do
    c=${row:0:1}
    row=${row:1}
    if [ "$inq" = 1 ]; then
      if [ "$c" = '"' ]; then
        if [ "${row:0:1}" = '"' ]; then
          field="${field}\""
          row=${row:1}
        else
          inq=0
        fi
      else
        field="${field}${c}"
      fi
    else
      case "$c" in
        '"') inq=1 ;;
        ',')
          if [ "$i" -eq "$n" ]; then printf '%s' "$field"; return 0; fi
          i=$((i + 1)); field='' ;;
        *) field="${field}${c}" ;;
      esac
    fi
  done
  if [ "$i" -eq "$n" ]; then printf '%s' "$field"; return 0; fi
  return 1
}

# 0 if pid $1 names a still-running process. Rejects empty, non-numeric, and 0.
# kill -0 succeeds when the caller may signal the pid; ps -p covers EPERM
# (process exists but belongs to another user).
fm_nm_pid_is_live() {  # <pid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" -o pid= >/dev/null 2>&1
}

# 0 if captured axi-status TOON $1 shows an active_steps row whose status is
# running or fixing and whose agent_pid names a live process. 1 for every other
# outcome: no table, no pid, a dead pid, a non-active status. Absence of
# evidence is a negative so callers keep their existing escalation schedule.
# This is the public CLI equivalent of the pipeline's step_results agent_pid
# row: do not read the sqlite file from here.
fm_nm_active_agent_live() {  # <toon-output>
  local toon=$1 line fields status_idx=0 pid_idx=0 i field status pid rest in_table=0
  [ -n "$toon" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      *'active_steps['*'}:'*)
        fields=${line#*\{}
        fields=${fields%%\}*}
        status_idx=0
        pid_idx=0
        i=1
        rest=$fields
        while [ -n "$rest" ]; do
          field=${rest%%,*}
          case "$field" in
            status) status_idx=$i ;;
            agent_pid) pid_idx=$i ;;
          esac
          [ "$field" = "$rest" ] && break
          rest=${rest#*,}
          i=$((i + 1))
        done
        [ "$status_idx" -gt 0 ] && [ "$pid_idx" -gt 0 ] || return 1
        in_table=1
        continue
        ;;
    esac
    [ "$in_table" = 1 ] || continue
    case "$line" in
      *,*) ;;
      *:*) in_table=0; continue ;;
    esac
    line=$(fm_nm_trim "$line")
    [ -n "$line" ] || continue
    status=$(fm_nm_strip_quotes "$(fm_nm_csv_field "$line" "$status_idx")")
    pid=$(fm_nm_strip_quotes "$(fm_nm_csv_field "$line" "$pid_idx")")
    case "$status" in
      running|fixing)
        if [ -z "$pid" ]; then
          case "$line" in
            *'pid='*)
              pid=${line##*pid=}
              pid=${pid%%[!0-9]*}
              ;;
          esac
        fi
        fm_nm_pid_is_live "$pid" && return 0
        ;;
    esac
  done <<< "$toon"
  return 1
}
