#!/usr/bin/env bash
# sacct-snapshot.sh: one sacct snapshot (every job and step active in a time window), gzipped.
#
#   scripts/sacct-snapshot.sh OUT_DIR [SINCE]   -> OUT_DIR/sacct-<UTC time>.txt.gz
#   SINCE: where the window starts (it always ends now). Default now-2hours. Accepted:
#     now-N<unit>  unit s, m, h, d or w, any case, or the word (sec, min, hour, day, week, with
#                  or without a trailing s); m means minutes; no unit means seconds.
#                  Examples: now-1d, now-24H, now-90m, now-2w, now-3600
#     YYYY-MM-DD[THH:MM[:SS]], MM/DD[/YY], today, midnight
#   sacct itself rejects the short units ("now-1d" is an "Invalid time specification": it wants
#   whole words), so this script rewrites them, e.g. now-1d to now-1days.
#
# Stages, as in squeue-snapshot.sh: discover the fields this sacct knows (--helpformat), build a
# --format from all of them, run sacct once, write the file. One query covers every job, array
# task and step of every user in the window. That replaces the per-array "sacct --jobs=<id>"
# calls of capture-raw.sh. The step rows are kept (no --allocations) because they carry the
# CPU and memory use that seff's numbers are computed from (snapshot-plans/C17-seff.md). Array
# tasks are the rows whose JobID has "_". Design notes: snapshot-plans/C11-sacct-array-tasks.md.
#
# File layout: a few "# key: value" lines, a header row, then one record per job or step. Fields
# are separated by TAB + 0x1f (sacct --delimiter) and every record ends with 0x1e + newline, as
# in squeue-snapshot.sh. sacct cannot print a record terminator itself, so this script adds one
# once a record holds every field, counted by its separators. A value with newlines in it (a
# Comment, a SubmitLine) stays inside its record; an empty line inside such a value adds no
# separators and so does not end the record early or late. To look at one (the sed strips only
# the metadata header; a body line may itself start with "#"):
#
#   gzip -dc FILE | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' '{print $1, $2}'
#
# Needs bash 4.3+, sacct, scontrol, gzip, date, awk. Read-only. Exits with sacct's exit status, 3
# when the output ends inside a record, or 2 for a usage error.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=snapshot-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"   # join_fields, snapshot_stamp, write_snapshot

usage='usage: sacct-snapshot.sh OUT_DIR [SINCE]   (SINCE e.g. now-1d, now-24h, now-90m, 2026-11-10)'
if (( $# < 1 || $# > 2 )); then echo "$usage" >&2; exit 2; fi
out_dir="$1"
given="${2:-now-2hours}"

# SINCE: rewrite the short units into the words sacct accepts. Every accepted form is matched
# whole here, so nothing else reaches the argv.
lower="${given,,}"
since=""
if [[ "$lower" =~ ^now-([0-9]{1,9})([a-z]*)$ ]]; then
  case "${BASH_REMATCH[2]}" in
    ""|s|sec|secs|second|seconds) unit=seconds ;;
    m|min|mins|minute|minutes)    unit=minutes ;;
    h|hr|hrs|hour|hours)          unit=hours ;;
    d|day|days)                   unit=days ;;
    w|wk|wks|week|weeks)          unit=weeks ;;
    *)                            unit="" ;;
  esac
  if [[ -n "$unit" ]]; then since="now-${BASH_REMATCH[1]}$unit"; fi
elif [[ "$lower" =~ ^(now|today|midnight)$ ]]; then
  since="$lower"
elif [[ "$given" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$ ||
        "$given" =~ ^[0-9]{1,2}/[0-9]{1,2}(/[0-9]{2})?$ ]]; then
  since="$given"
fi
if [[ -z "$since" ]]; then
  echo "sacct-snapshot.sh: SINCE '$given' not understood: use now-N<unit> (unit s, m, h, d or w;" \
    "m = minutes), YYYY-MM-DD[THH:MM[:SS]], MM/DD[/YY], today or midnight" >&2
  echo "$usage" >&2
  exit 2
fi
mkdir -p "$out_dir"

fs=$'\t\x1f'   # field separator (sacct --delimiter)
rs=$'\x1e'     # record terminator (added below)

# 1. Discover the fields: every name this sacct accepts, sorted.
fields=$(sacct --helpformat | tr -s '[:space:]' '\n' | sort -f | awk 'NF')
[[ -n "$fields" ]] || { echo "sacct --helpformat listed no fields" >&2; exit 1; }
count=$(printf '%s\n' "$fields" | wc -l)

# 2. Build the format: the names joined with commas. --parsable2 never truncates, so no widths.
format=$(printf '%s\n' "$fields" | join_fields '' '' ',' '')
header=$(printf '%s\n' "$fields" | join_fields '' '' "$fs" "$rs")

# 3. Run sacct once: every user, array tasks expanded, steps included, this cluster only, units
#    as stored (--noconvert), epoch-second times. The command is an array so the header below
#    shows exactly what ran.
export SLURM_TIME_FORMAT=%s
cmd=(sacct --allusers --array --local --noconvert --noheader --parsable2 "--delimiter=$fs"
     "--starttime=$since" --endtime=now "--format=$format")
captured=$(snapshot_stamp)
raw=$(mktemp); body=$(mktemp); trap 'rm -f "$raw" "$body"' EXIT
set +e
"${cmd[@]}" > "$raw"
status=$?
set -e

# 3b. Terminate the records: join physical lines until a record holds count-1 separators, then
#     end it with 0x1e. A last record that never fills up is still written, and noted.
#     Separators are counted per physical line as split() - 1, guarded: split("") returns 0, not
#     1, so without the guard an empty line (a blank line inside a SubmitLine) would count -1 and
#     the record would swallow the start of the next one (seen 2026-11-13 on orcd).
printf '%s\n' "$header" > "$body"
partial=0
awk -v fs="$fs" -v rs="$rs" -v want="$(( count - 1 ))" '
  { buf = (have ? buf "\n" : "") $0; have = 1
    n = split($0, parts, fs); if (n > 1) seen += n - 1 }
  seen >= want { printf "%s%s\n", buf, rs; buf = ""; have = 0; seen = 0 }
  END { if (have) { printf "%s%s\n", buf, rs; exit 3 } }' "$raw" >> "$body" || partial=$?

# 4. Write the file: metadata, header, records.
extra='# times: epoch seconds (SLURM_TIME_FORMAT=%s)'
extra+=$'\n# separators: TAB+0x1f between fields, 0x1e then newline after each record'
window="$since .. now"
if [[ "$since" != "$given" ]]; then window+=" (SINCE given as $given)"; fi
extra+=$'\n'"# window: $window"
if (( partial )); then
  extra+=$'\n# warning: the output ended inside a record; the last record is incomplete'
  echo "sacct-snapshot.sh: sacct output ended inside a record" >&2
fi
write_snapshot "$out_dir" sacct "$captured" records "$status" "$body" "$extra" \
  "SLURM_TIME_FORMAT=$SLURM_TIME_FORMAT" "${cmd[@]}"
if (( status == 0 && partial )); then exit 3; fi
exit "$status"
