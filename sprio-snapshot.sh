#!/usr/bin/env bash
# sprio-snapshot.sh: one sprio snapshot (priority factors of every pending job), gzipped.
#
#   scripts/sprio-snapshot.sh OUT_DIR          -> OUT_DIR/sprio-<UTC time>.txt.gz
#
# Stages, as in squeue-snapshot.sh: discover the format letters this sprio knows
# (--helpformat), build a --format from all of them, run sprio once, write the file. One call
# covers every eligible pending job, once per partition it could run in. Lowercase letters are
# normalized factors and uppercase are weighted ones, so this one row replaces both "sprio -j" and
# "sprio -n -j". There is no "sprio -w" call: "sprio --weights" segfaults on %c (Slurm 26.05.5),
# and the weights are the PriorityWeight* settings of the scontrol config snapshot.
#
# File layout: a few "# key: value" lines, a header row, then one record per pending job per
# partition. Fields are separated by TAB + 0x1f and every record ends with 0x1e + newline, as in
# squeue-snapshot.sh. The header row holds the specifiers themselves (%A, %a, ...), because
# sprio's own titles are ambiguous (AGE for %A and %a, PARTITION for %P, %p and %r). Match them
# case-sensitively. "# names:" pairs each specifier with sprio's title. If sprio is killed by a
# signal, each letter is probed alone. Any letter that kills sprio is left as an empty column
# (the header keeps it), "# blanked:" names it, and sprio runs once more. Design notes:
# snapshot-plans/C14-C16-sprio.md. To look at one:
#
#   gzip -dc FILE | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' '{print $8, $18, $24}'
#
# Needs bash 4.3+, sprio, scontrol, gzip, date. Read-only. Exits with sprio's exit status.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=snapshot-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"   # join_fields, snapshot_stamp, write_snapshot

if (( $# != 1 )); then echo "usage: sprio-snapshot.sh OUT_DIR" >&2; exit 2; fi
out_dir="$1"
mkdir -p "$out_dir"

fs=$'\t\x1f'   # field separator
rs=$'\x1e'     # record terminator (sprio adds the newline)

# 1. Discover the format letters: every %x this sprio accepts, sorted case-insensitively so that
#    the normalized and weighted letter of a factor sit side by side.
letters=$(sprio --helpformat | tr -s '[:space:]' '\n' | awk '/^%[A-Za-z]$/' | LC_ALL=C sort -f)
[[ -n "$letters" ]] || { echo "sprio --helpformat listed no format letters" >&2; exit 1; }

# 2. Build the format: every letter with no width (sprio then prints the whole value), the field
#    separator as its suffix, the last one with the record terminator instead. The header row is
#    the same string: the specifiers are the column names.
format=$(printf '%s\n' "$letters" | join_fields '' '' "$fs" "$rs")
header=$format

# 3. Run sprio once, every pending job. Its own header line is kept for "# names:".
cmd=(sprio "--format=$format")
captured=$(snapshot_stamp)
raw=$(mktemp); body=$(mktemp); trap 'rm -f "$raw" "$body"' EXIT
set +e
"${cmd[@]}" > "$raw"
status=$?
set -e

# 3b. Killed by a signal: find the letters that do it, by probing each one alone against a single
#     job, and run once more with those columns left empty.
blanked=""
if (( status > 128 )); then
  probe=()
  job=$(sprio --noheader --format=%i 2> /dev/null | head -n 1 || true)
  job="${job// /}"
  if [[ "$job" =~ ^[1-9][0-9]*$ ]]; then probe=("--jobs=$job"); fi
  bad=" "
  while IFS= read -r letter; do
    set +e
    sprio --noheader "${probe[@]}" "--format=$letter" > /dev/null 2>&1
    rc=$?
    set -e
    if (( rc > 128 )); then bad+="$letter "; blanked+="${blanked:+ }$letter"; fi
  done <<< "$letters"
  if [[ -n "$blanked" ]]; then
    echo "sprio-snapshot.sh: sprio was killed by signal $(( status - 128 )); blanking $blanked" >&2
    blanked_status=$status
    format=$(printf '%s\n' "$letters" | awk -v bad="$bad" '{ print (index(bad, " " $0 " ") ? "" : $0) }' \
      | join_fields '' '' "$fs" "$rs")
    cmd=(sprio "--format=$format")
    set +e
    "${cmd[@]}" > "$raw"
    status=$?
    set -e
  fi
fi

# 4. Write the file: metadata (with sprio's titles paired to the specifiers), header, records.
names=""
if [[ -s "$raw" ]]; then
  names=$(head -n 1 "$raw" | tr -d '\036' | awk -F "$fs" -v letters="$(printf '%s\n' "$letters" | paste -sd ' ' -)" '
    { n = split(letters, l, " "); line = "# names:"
      for (i = 1; i <= n; i++) { t = $i; gsub(/^ +| +$/, "", t); line = line " " l[i] "=" t }
      print line }')
fi
extra='# separators: TAB+0x1f between fields, 0x1e then newline after each record'
extra+=$'\n# records: one row per eligible pending job per partition'
if [[ -n "$names" ]]; then extra+=$'\n'"$names"; fi
if [[ -n "$blanked" ]]; then
  extra+=$'\n'"# blanked: $blanked (empty columns: sprio was killed by signal $(( blanked_status - 128 )) with them)"
fi
printf '%s\n' "$header" > "$body"
tail -n +2 "$raw" >> "$body"
write_snapshot "$out_dir" sprio "$captured" records "$status" "$body" "$extra" "${cmd[@]}"
exit "$status"
