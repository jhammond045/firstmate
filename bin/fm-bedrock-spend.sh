#!/usr/bin/env bash
# fm-bedrock-spend.sh - report Amazon Bedrock spend for a configured AWS account.
#
# WHY THIS EXISTS
# Bedrock-routed models bill to AWS rather than to a vendor subscription, so
# their cost does not show up in quota-axi, in a harness per-run figure, or in
# any provider balance firstmate can read. A home that uses Bedrock still needs
# a number the captain can ask for.
#
# WHAT IT REPORTS
# Cost Explorer's unblended cost for the "Amazon Bedrock" service. That is the
# whole service, not just agent traffic - anything else in the account using
# Bedrock is in the same figure. Read it as an upper bound on our usage, not as
# an invoice line for firstmate.
#
# Cost Explorer data lags by up to a day and month-to-date figures are marked
# estimated by AWS; this script reports that flag rather than hiding it.
#
# Configuration. An AWS profile name is somebody's account, so this file
# carries no default. The profile is read from the home's gitignored config/
# directory, or from FM_AWS_PROFILE, and the script refuses with the path to
# write rather than reaching for a value that belongs to another home.
# An explicitly empty FM_AWS_PROFILE uses whatever credentials are already in
# the environment.
#
#   config/aws-profile     FM_AWS_PROFILE     AWS profile.            required
#                                             unless FM_AWS_PROFILE is set empty
#
# Usage:
#   fm-bedrock-spend.sh                # month to date
#   fm-bedrock-spend.sh --days 7       # trailing N days, daily breakdown
#   fm-bedrock-spend.sh --profile foo  # override the configured profile
#   fm-bedrock-spend.sh --help         # print this header
#
# Environment:
#   FM_HOME              operational home whose config/ is used
#   FM_CONFIG_OVERRIDE   alternate config dir, mainly for tests
#   FM_AWS_PROFILE       AWS profile; unset falls through to config/aws-profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'fm-bedrock-spend: %s\n' "$*" >&2; exit 1; }
die_usage() { printf 'fm-bedrock-spend: %s\n' "$*" >&2; exit 2; }

usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       { exit }' "${BASH_SOURCE[0]}"
}

# First non-comment, non-blank line of a config file, or nothing.
read_setting() {  # <file-name>
  local path="$CONFIG/$1" line
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
}

require_setting() {  # <file-name> <env-var> <what>
  local value
  value=$(read_setting "$1")
  [ -n "$value" ] || die "no $3 is configured: write one line into $CONFIG/$1 or set $2"
  printf '%s' "$value"
}

DAYS=""
PROFILE_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      [ -n "${2:-}" ] || die_usage "--days needs a number"
      DAYS=$2
      shift 2
      ;;
    --profile)
      [ -n "${2:-}" ] || die_usage "--profile needs a name"
      PROFILE_FLAG=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1 (try --help)"
      ;;
  esac
done

case "$DAYS" in
  '') ;;
  *[!0-9]*) die_usage "--days needs a positive integer" ;;
  0) die_usage "--days needs a positive integer" ;;
esac

if [ -n "$PROFILE_FLAG" ]; then
  PROFILE=$PROFILE_FLAG
elif [ -n "${FM_AWS_PROFILE+x}" ]; then
  # Unset falls through to config; explicitly empty means ambient credentials.
  PROFILE=$FM_AWS_PROFILE
else
  PROFILE=$(require_setting aws-profile FM_AWS_PROFILE "AWS profile")
fi

command -v aws >/dev/null 2>&1 || die "aws CLI not found"
command -v python3 >/dev/null 2>&1 || die "python3 is required to format Cost Explorer output"

if date -u -v+1d +%F >/dev/null 2>&1; then
  END=$(date -u -v+1d +%F)
  if [ -n "$DAYS" ]; then
    START=$(date -u -v-"${DAYS}"d +%F)
  else
    START=$(date -u +%Y-%m-01)
  fi
else
  END=$(date -u -d 'tomorrow' +%F)
  if [ -n "$DAYS" ]; then
    START=$(date -u -d "${DAYS} days ago" +%F)
  else
    START=$(date -u +%Y-%m-01)
  fi
fi

if [ -n "$DAYS" ]; then
  GRAN=DAILY
else
  GRAN=MONTHLY
fi

aws_call() {
  if [ -z "$PROFILE" ]; then
    aws "$@"
  else
    aws --profile "$PROFILE" "$@"
  fi
}

if ! OUT=$(aws_call ce get-cost-and-usage \
      --time-period "Start=${START},End=${END}" \
      --granularity "$GRAN" \
      --metrics UnblendedCost \
      --filter '{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}' 2>&1); then
  if [ -n "$PROFILE" ]; then
    printf 'fm-bedrock-spend: Cost Explorer query failed for profile %s\n' "$PROFILE" >&2
  else
    printf 'fm-bedrock-spend: Cost Explorer query failed with ambient credentials\n' >&2
  fi
  printf '%s\n' "$OUT" | tail -3 >&2
  printf 'fm-bedrock-spend: the profile may need re-authentication, or lack ce:GetCostAndUsage\n' >&2
  exit 1
fi

ce_json=$(mktemp "${TMPDIR:-/tmp}/fm-bedrock-spend.XXXXXX") || die "could not create a temp file"
trap 'rm -f "$ce_json"' EXIT
printf '%s' "$OUT" > "$ce_json"
python3 - "$ce_json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
rows = d.get("ResultsByTime", [])
if not rows:
    print("no Bedrock cost recorded for this window")
    sys.exit(0)
total = 0.0
estimated = False
for r in rows:
    amt = float(r["Total"]["UnblendedCost"]["Amount"])
    total += amt
    estimated = estimated or r.get("Estimated", False)
    if len(rows) > 1 and amt:
        day = r["TimePeriod"]["Start"]
        print("  %s  $%8.2f" % (day, amt))
label = "estimated, AWS has not finalised it" if estimated else "final"
span_start = rows[0]["TimePeriod"]["Start"]
span_end = rows[-1]["TimePeriod"]["End"]
print("Amazon Bedrock, {} to {}: ${:,.2f} ({})".format(span_start, span_end, total, label))
print("Whole-service figure: includes any Bedrock use in this account, not only agent traffic.")
PY
