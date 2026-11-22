#!/usr/bin/env bash
# scontrol-snapshot.sh: one "scontrol show" snapshot, gzipped into a dated file.
#
#   scripts/scontrol-snapshot.sh OUT_DIR OBJECT   -> OUT_DIR/scontrol-<OBJECT>-<UTC time>.txt.gz
#   OBJECT: node | partition | reservation | config | job
#
# Stages, as in squeue-snapshot.sh: discover, build, run once, write. Discover is empty because
# "scontrol show" has no field selection: it prints every field of every object, so no field
# list is hardcoded. Build picks the argv for OBJECT from the table below. That table is the
# one hardcoded part, because scontrol cannot list its "show" entities.
#
# File layout: a few "# key: value" lines, then scontrol's stdout unchanged.
# - node, partition, reservation and config are text ("# format: text"), in scontrol's default
#   multi-line layout. It is not --oneliner: the multi-line form puts free-text values such as
#   OS=, Reason= and Comment= on lines of their own. --oneliner joins everything with spaces, so
#   where such a value ends becomes a guess.
# - job is one line of JSON ("# format: json"), because job text has values with spaces and "="
#   (SubmitLine=) and lacks keys the JSON has (priority_by_partition, job_resources).
# Times are epoch seconds (SLURM_TIME_FORMAT=%s). Design notes: snapshot-plans/C03-*.md. To look
# at one:
#
#   gzip -dc FILE | sed '1,/^# exit:/d' | less
#
# Needs bash 4.3+, scontrol, gzip, date. Read-only. Exits with scontrol's exit status, or 2 for a
# usage error. Under systemd: a oneshot service per OBJECT and a timer
# (snapshot-plans/README.md "Cadence").
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=snapshot-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"   # snapshot_stamp, write_snapshot

usage='usage: scontrol-snapshot.sh OUT_DIR node|partition|reservation|config|job'
if (( $# != 2 )); then printf '%s\n' "$usage" >&2; exit 2; fi
out_dir="$1"
object="$2"

# 1. Discover: nothing to ask (see the header).
# 2. Build: the argv for OBJECT. --all includes hidden partitions and their nodes and jobs.
case "$object" in
  node|partition|reservation) cmd=(scontrol --all show "$object"); format=text ;;
  config)                     cmd=(scontrol show config);           format=text ;;
  job)                        cmd=(scontrol --all --json show job); format=json ;;
  *) printf '%s\n' "$usage" >&2; exit 2 ;;
esac
mkdir -p "$out_dir"

# 3. Run scontrol once, for every object: epoch-second times, and one-line JSON for "job".
#    The command is an array so the header below shows exactly what ran.
export SLURM_TIME_FORMAT=%s SLURM_JSON=compact
captured=$(snapshot_stamp)
body=$(mktemp); trap 'rm -f "$body"' EXIT
set +e
"${cmd[@]}" > "$body"
status=$?
set -e

# 4. Write the file: metadata, then the body unchanged.
write_snapshot "$out_dir" "scontrol-$object" "$captured" "$format" "$status" "$body" "" \
  "SLURM_TIME_FORMAT=$SLURM_TIME_FORMAT" "SLURM_JSON=$SLURM_JSON" "${cmd[@]}"
exit "$status"
