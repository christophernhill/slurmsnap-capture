#!/usr/bin/env bash
# sshare-snapshot.sh: one sshare snapshot (fair-share shares and usage, whole tree), gzipped.
#
#   scripts/sshare-snapshot.sh OUT_DIR          -> OUT_DIR/sshare-<UTC time>.txt.gz
#
# Stages, as in squeue-snapshot.sh: discover the fields this sshare knows (--helpformat), build a
# --format from all of them, run sshare once for every account and user, write the file. It
# explains sprio's FAIRSHARE factor: configured shares (RawShares, NormShares) against decayed
# usage (RawUsage, EffectvUsage), with LevelFS under Fair Tree. Design notes:
# snapshot-plans/sshare-fairshare.md.
#
# File layout: a few "# key: value" lines, a header row, then one record per association.
# Fields are separated by TAB + 0x1f and every record ends with 0x1e + newline, as in
# squeue-snapshot.sh. Leading spaces in Account are kept: they give the depth in the account
# tree. Rows with an empty User are accounts.
#
# Delimiter: when this sshare offers --delimiter (asked at run time from --help), the separator
# comes from sshare itself. Otherwise sshare prints "|" (--parsable2) and this script translates
# it, after checking that every line has exactly one "|" per field boundary. A line that does
# not means some value contains "|", so the columns would be ambiguous. In that case nothing is
# written, the line numbers go to stderr, and the exit status is 3 ("sshare --json" would be the
# fix). To look at one:
#
#   gzip -dc FILE | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' '{print $1, $15, $5}'
#
# Needs bash 4.3+, sshare, scontrol, gzip, date, awk. Read-only. Exits with sshare's exit status,
# 3 for the ambiguity above, 1 if --helpformat lists no fields, or 2 for a usage error.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=snapshot-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"   # join_fields, snapshot_stamp, write_snapshot

if (( $# != 1 )); then echo "usage: sshare-snapshot.sh OUT_DIR" >&2; exit 2; fi
out_dir="$1"
mkdir -p "$out_dir"

fs=$'\t\x1f'   # field separator
rs=$'\x1e'     # record terminator (added below)

# 1. Discover the fields, and whether this sshare can print our separator itself. --help is
#    read whole: a "| grep -q" would stop reading early and fail under pipefail.
fields=$(sshare --helpformat | tr -s '[:space:]' '\n' | sort -f | awk 'NF')
[[ -n "$fields" ]] || { echo "sshare --helpformat listed no fields" >&2; exit 1; }
count=$(printf '%s\n' "$fields" | wc -l)
help=$(sshare --help 2>&1 || true)

# 2. Build the format: the names joined with commas (--parsable2 never truncates).
format=$(printf '%s\n' "$fields" | join_fields '' '' ',' '')
header=$(printf '%s\n' "$fields" | join_fields '' '' "$fs" "$rs")
cmd=(sshare --all --noheader --parsable2)
if [[ "$help" == *--delimiter* ]]; then
  cmd+=("--delimiter=$fs"); delim=$fs; translated=""
else
  delim='|'; translated="# translated: sshare --parsable2 prints '|'; this script turned it into TAB+0x1f"
fi
cmd+=("--format=$format")

# 3. Run sshare once: every account and user association.
captured=$(snapshot_stamp)
raw=$(mktemp); body=$(mktemp); trap 'rm -f "$raw" "$body"' EXIT
set +e
"${cmd[@]}" > "$raw"
status=$?
set -e

# 3b. Check every line has exactly count fields, then rejoin them with the field separator and
#     end the record with 0x1e. A wrong count means a value holds the delimiter: write nothing.
printf '%s\n' "$header" > "$body"
ambiguous=0
awk -v d="$delim" -v fs="$fs" -v rs="$rs" -v want="$count" '
  $0 == "" { next }
  { n = split($0, v, d) }
  n != want { printf "sshare-snapshot.sh: line %d has %d fields, not %d\n", NR, n, want > "/dev/stderr"; bad = 1; next }
  { out = v[1]; for (i = 2; i <= n; i++) out = out fs v[i]; printf "%s%s\n", out, rs }
  END { exit bad ? 3 : 0 }' "$raw" >> "$body" || ambiguous=$?
if (( ambiguous )); then
  echo "sshare-snapshot.sh: a value contains '$delim'; no snapshot written (try sshare --json)" >&2
  exit 3
fi

# 4. Write the file: metadata, header, records.
extra='# separators: TAB+0x1f between fields, 0x1e then newline after each record'
if [[ -n "$translated" ]]; then extra+=$'\n'"$translated"; fi
write_snapshot "$out_dir" sshare "$captured" records "$status" "$body" "$extra" "${cmd[@]}"
exit "$status"
