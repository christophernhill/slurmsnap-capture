# shellcheck shell=bash
# snapshot-lib.sh: helpers shared by the snapshot scripts. Sourced, never executed:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"
#
# It defines functions only; it sets no shell options and touches no variables of the caller.

# show_command WORD...: print a command as "# command:" header lines, wrapped at 80 columns so
# a human can read it or paste it back. Plain words share a line. A word holding control bytes
# is shown $'...'-quoted with \t \x1f \x1e and wrapped after commas; each wrapped line is its
# own $'...' chunk ending in a backslash, because inside $'...' a backslash-newline is not a
# continuation, while adjacent quoted chunks concatenate.
show_command() {
  local width=78 word shown line item
  local -a items
  printf '# command:\n'
  line="#  "
  for word in "$@"; do
    shown="${word//$'\t'/\\t}"
    shown="${shown//$'\x1f'/\\x1f}"
    shown="${shown//$'\x1e'/\\x1e}"
    if [[ "$shown" == "$word" ]]; then
      line+=" $shown"
      continue
    fi
    printf '%s \\\n' "$line"
    IFS=',' read -r -a items <<< "${shown#*=}"
    line="#     ${shown%%=*}=\$'"
    for item in "${items[@]}"; do
      if (( ${#line} + ${#item} + 4 > width )); then  # room for the item, "," and "'\"
        printf '%s\\\n' "$line'"
        line="#     \$'"
      fi
      line+="$item,"
    done
    line="${line%,}'"
  done
  printf '%s\n' "$line"
}

# snapshot_stamp: print the current UTC time as 2026-11-12T22:41:07Z. Read it once per run and
# pass it to write_snapshot, so the "# captured:" line and the file name agree to the second.
snapshot_stamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# cluster_name: print this cluster's ClusterName from "scontrol show config", or nothing. Always
# returns 0, so `name=$(cluster_name)` is safe under set -e. The awk reads to the end on
# purpose: an awk `exit` would make scontrol die of SIGPIPE (status 141) under pipefail.
cluster_name() {
  scontrol show config 2>/dev/null | awk -F' *= *' '$1 == "ClusterName" {print $2}' || true
}

# join_fields PREFIX SUFFIX SEP END: read one name per line on stdin and print PREFIX name
# SUFFIX for each, SEP between them and END after the last, with no newline. squeue's --Format
# is `join_fields '' ':0' "$fs," "$rs"`, a header row `join_fields '' '' "$fs" "$rs"`. The
# arguments reach awk as -v values, so a backslash in one would be read as an escape; the
# separators used here are raw control bytes and contain none.
join_fields() {
  awk -v pre="$1" -v suf="$2" -v sep="$3" -v end="$4" \
    'NR > 1 { printf "%s", sep } { printf "%s%s%s", pre, $0, suf } END { printf "%s", end }'
}

# write_snapshot OUT_DIR NAME CAPTURED FORMAT STATUS BODY EXTRA WORD...: write one snapshot file
# and print its path.
#   OUT_DIR/NAME-<CAPTURED as 20261112T224107Z>.txt.gz holds the common "# key: value" lines
#   (captured, host, cluster, slurm, command, format), then EXTRA (zero or more "# key: value"
#   lines, newline-separated), then "# exit:", then BODY (a file) unchanged.
#   FORMAT is records, text or json; STATUS goes on the "# exit:" line as given.
#   WORD... is the command as it ran, leading NAME=value environment words included; the first
#   word without "=" is the executable whose --version fills the "# slurm:" line.
# The file is written as .tmp and renamed, so it appears whole or not at all.
write_snapshot() {
  local out_dir="$1" name="$2" captured="$3" format="$4" status="$5" body="$6" extra="$7"
  shift 7
  local exe="" word file
  for word in "$@"; do
    if [[ "$word" != *=* ]]; then exe="$word"; break; fi
  done
  file="$out_dir/$name-${captured//[-:]/}.txt.gz"
  {
    printf '# captured: %s\n' "$captured"
    printf '# host: %s\n' "$(hostname -s)"
    printf '# cluster: %s\n' "$(cluster_name)"
    printf '# slurm: %s\n' "$("$exe" --version 2>/dev/null)"
    show_command "$@"
    printf '# format: %s\n' "$format"
    if [[ -n "$extra" ]]; then printf '%s\n' "$extra"; fi
    printf '# exit: %s\n' "$status"
    cat "$body"
  } | gzip > "$file.tmp"
  mv "$file.tmp" "$file"
  printf '%s\n' "$file"
}
