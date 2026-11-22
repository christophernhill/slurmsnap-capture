#!/usr/bin/env bash
# squeue-snapshot.sh: one squeue snapshot, gzipped into a dated file.
#
#   scripts/squeue-snapshot.sh OUT_DIR          -> OUT_DIR/squeue-<UTC time>.txt.gz
#
# Stages: discover the fields this squeue knows, build a --Format from them, run squeue once,
# write the file. Nothing is hardcoded about fields: downstream code reads the header row and
# picks the columns it wants by name.
#
# File layout: a few "# key: value" lines, a header row, then one record per job (array tasks
# expanded, every state, hidden partitions too). Fields are separated by TAB + 0x1f and every
# record ends with 0x1e + newline. The two control bytes never occur in squeue output, so a job
# name or comment containing a tab, a comma, a pipe or a newline cannot shift a column or split
# a record; the tab is there so `cat` shows aligned-ish columns. To look at one (this view
# joins a newline inside a field onto one line, which is fine for eyeballing):
#
#   gzip -dc FILE | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' '{print $1, $5}'
#
# Needs bash 4.3+, squeue, scontrol, gzip, date. Read-only. Exits with squeue's exit status,
# 1 if --helpFormat lists no fields, or 2 for a usage error.
# Under systemd: a oneshot service running this with OUT_DIR, and a timer with OnCalendar=*:0/5.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=snapshot-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"   # join_fields, snapshot_stamp, write_snapshot

if (( $# != 1 )); then echo "usage: squeue-snapshot.sh OUT_DIR" >&2; exit 2; fi
out_dir="$1"
mkdir -p "$out_dir"

fs=$'\t\x1f'   # field separator
rs=$'\x1e'     # record terminator (squeue adds the newline)

# 1. Discover the fields: every long-form name this squeue accepts, sorted.
fields=$(squeue --helpFormat | tr -s '[:space:]' '\n' | sort -f | awk 'NF')
[[ -n "$fields" ]] || { echo "squeue --helpFormat listed no fields" >&2; exit 1; }

# 2. Build the format: each field untruncated (:0) with the field separator as its suffix, the
#    last one with the record terminator instead.
format=$(printf '%s\n' "$fields" | join_fields '' ':0' "$fs," "$rs")
header=$(printf '%s\n' "$fields" | join_fields '' '' "$fs" "$rs")

# 3. Run squeue once: every job, every state, hidden partitions included, epoch-second times.
#    The command is an array so the header below shows exactly what ran.
export SLURM_TIME_FORMAT=%s
cmd=(squeue --all --array --noheader --states=all --Format="$format")
captured=$(snapshot_stamp)
body=$(mktemp); trap 'rm -f "$body"' EXIT
printf '%s\n' "$header" > "$body"
set +e
"${cmd[@]}" >> "$body"
status=$?
set -e

# 4. Write the file: metadata, header, records. The .tmp rename makes the file appear whole.
write_snapshot "$out_dir" squeue "$captured" records "$status" "$body" \
  "$(printf '%s\n' '# times: epoch seconds (SLURM_TIME_FORMAT=%s)' \
    '# separators: TAB+0x1f between fields, 0x1e then newline after each record')" \
  "SLURM_TIME_FORMAT=$SLURM_TIME_FORMAT" "${cmd[@]}"
exit "$status"
