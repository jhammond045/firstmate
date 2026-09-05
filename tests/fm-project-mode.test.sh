#!/usr/bin/env bash
# Behavioral regressions for bin/fm-project-mode.sh: legacy list format, the
# canonical table format, and a file mixing both.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode)

run_mode() {
  local data=$1 project=$2
  FM_DATA_OVERRIDE="$data" "$MODE" "$project" 2>/dev/null
}

test_legacy_list_format() {
  local data=$TMP_ROOT/legacy
  mkdir -p "$data"
  cat > "$data/projects.md" <<'EOF'
- plain-proj - a plain project (added 2026-01-01)
- moded-proj [direct-PR] - has a mode (added 2026-01-01)
- yolo-proj [local-only +yolo] - has mode and yolo (added 2026-01-01)
EOF
  [ "$(run_mode "$data" plain-proj)" = "no-mistakes off" ] ||
    fail "legacy line with no bracket did not default to no-mistakes off"
  [ "$(run_mode "$data" moded-proj)" = "direct-PR off" ] ||
    fail "legacy line with [mode] did not resolve mode"
  [ "$(run_mode "$data" yolo-proj)" = "local-only on" ] ||
    fail "legacy line with [mode +yolo] did not resolve yolo"
  pass "legacy list format still resolves plain, moded, and yolo entries"
}

test_table_format() {
  local data=$TMP_ROOT/table
  mkdir -p "$data"
  cat > "$data/projects.md" <<'EOF'
# Projects

| project | path | mode | yolo | notes |
|---|---|---|---|---|
| firstmate | ~/firstmate | local-only | off | the fleet tool itself |
| crm-domain-specs | ~/workspace/crm-domain-specs | local-only | on | spec corpus |
| arts-people | ~/workspace/arts-people | no-mistakes | off | product-facing |

## Standing notes
- some prose that is not a table row
EOF
  [ "$(run_mode "$data" firstmate)" = "local-only off" ] ||
    fail "table row did not resolve firstmate to local-only off"
  [ "$(run_mode "$data" crm-domain-specs)" = "local-only on" ] ||
    fail "table row did not resolve crm-domain-specs to local-only on"
  [ "$(run_mode "$data" arts-people)" = "no-mistakes off" ] ||
    fail "table row did not resolve arts-people to no-mistakes off"
  pass "table format resolves registered postures for every row"
}

test_mixed_file() {
  local data=$TMP_ROOT/mixed
  mkdir -p "$data"
  cat > "$data/projects.md" <<'EOF'
| project | path | mode | yolo | notes |
|---|---|---|---|---|
| table-proj | ~/table-proj | direct-PR | off | migrated already |

- legacy-proj [local-only +yolo] - not yet migrated (added 2026-01-01)
EOF
  [ "$(run_mode "$data" table-proj)" = "direct-PR off" ] ||
    fail "mixed file did not resolve the table row"
  [ "$(run_mode "$data" legacy-proj)" = "local-only on" ] ||
    fail "mixed file did not resolve the legacy list row"
  pass "a file mixing table and legacy rows resolves both"
}

test_unknown_project_warns_and_defaults() {
  local data=$TMP_ROOT/table
  local out err errfile=$TMP_ROOT/stderr
  out=$(FM_DATA_OVERRIDE="$data" "$MODE" nope 2>"$errfile") || true
  err=$(cat "$errfile")
  [ "$out" = "no-mistakes off" ] || fail "unknown project did not default to no-mistakes off"
  assert_contains "$err" "not in registry" "unknown project did not warn to stderr"
  pass "unknown project warns and defaults to no-mistakes off"
}

test_legacy_list_format
test_table_format
test_mixed_file
test_unknown_project_warns_and_defaults
